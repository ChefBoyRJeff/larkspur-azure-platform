<#
.SYNOPSIS
    Resolves the SQL server and Key Vault names from INSIDE vnet-lark and prints the answers.

.DESCRIPTION
    My PC resolves the data-tier names through public DNS, so only something inside the VNet shows what the app sees.
    This script starts one execution of job-lark-dnscheck (it prints "LARK-DNS <name> -> <address>" for each name),
    waits for it, and reads its lines from Log Analytics (ContainerAppConsoleLogs in log-lark). Console logs reach Log
    Analytics a few minutes after they're written.

    Expected (healthy): both names resolve to 10.60.1.x, the private endpoints. A public address means the VNet isn't
    using the private DNS zone for that name. Server and vault names are shortened and public addresses masked in the
    output, so it can go into evidence as is.

.PARAMETER ResourceGroup
    Resource group of the job (the app stack).

.PARAMETER JobName
    Name of the DNS check job.

.PARAMETER DataResourceGroup
    Resource group of the Log Analytics workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace that receives the environment's console logs.

.PARAMETER TimeoutMinutes
    How long to wait for the execution to finish, and then again for its log lines to arrive.

.EXAMPLE
    ./scripts/Test-LarkPrivateDns.ps1
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$ResourceGroup = 'rg-lark-app',
    [ValidateNotNullOrEmpty()][string]$JobName = 'job-lark-dnscheck',
    [ValidateNotNullOrEmpty()][string]$DataResourceGroup = 'rg-lark-data',
    [ValidateNotNullOrEmpty()][string]$WorkspaceName = 'log-lark',
    [ValidateRange(1, 30)][int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    # Runs an az command, returns stdout only (warnings on stderr would break JSON), throws on a non-zero exit code.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    $code = $LASTEXITCODE
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    if ($code -ne 0) {
        $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
        throw "az $($Arguments[0..2] -join ' ') failed (exit $code): $stderr"
    }
    return ($stdout -join "`n")
}

$easternZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
function Format-Eastern {
    param([Parameter(Mandatory)][datetime]$Utc)
    return [TimeZoneInfo]::ConvertTimeFromUtc($Utc, $easternZone).ToString('MM-dd-yyyy hh:mm:ss tt')
}

function Protect-Line {
    # Shorten unique resource names and mask any IPv4 address outside the 10.x private range.
    param([string]$Text)
    $t = $Text -replace 'sql-lark-[a-z0-9]+', 'sql-lark-…' -replace 'kv-lark-[a-z0-9]+', 'kv-lark-…'
    return [regex]::Replace($t, '\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', {
        param($m) if ($m.Groups[1].Value -eq '10') { $m.Value } else { '<public-ip>' } })
}

# 1. Start one execution and wait for it.
$startedUtc = (Get-Date).ToUniversalTime()
$execution = Invoke-Az @('containerapp', 'job', 'start', '-g', $ResourceGroup, '-n', $JobName, '--query', 'name', '-o', 'tsv')
Write-Host "=== in-VNet DNS check ==="
Write-Host "execution      $execution"
Write-Host "started        $(Format-Eastern $startedUtc) EST"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $status = Invoke-Az @('containerapp', 'job', 'execution', 'show', '-g', $ResourceGroup, '-n', $JobName,
        '--job-execution-name', $execution, '--query', 'properties.status', '-o', 'tsv')
    if (@('Succeeded', 'Failed', 'Stopped', 'Degraded') -contains $status) { break }
}
Write-Host "status         $status at $(Format-Eastern (Get-Date).ToUniversalTime()) EST"

# 2. Read its LARK-DNS lines (one per name: the SQL server and the Key Vault).
$customerId = Invoke-Az @('monitor', 'log-analytics', 'workspace', 'show', '-g', $DataResourceGroup, '-n', $WorkspaceName,
    '--query', 'customerId', '-o', 'tsv')
$since = $startedUtc.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$kql = "ContainerAppConsoleLogs | where TimeGenerated >= datetime($since) | where ContainerName == 'dnscheck' " +
    "| where Log startswith 'LARK-DNS' | project TimeGenerated, Log | order by TimeGenerated asc"
$queryFile = Join-Path ([System.IO.Path]::GetTempPath()) "lark-dns-query-$PID.json"
[System.IO.File]::WriteAllText($queryFile, (([ordered]@{ query = $kql; timespan = 'PT3H' }) | ConvertTo-Json),
    (New-Object System.Text.UTF8Encoding $false))
$queryUrl = "https://api.loganalytics.io/v1/workspaces/$customerId/query"

$rows = @()
$logDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
try {
    while ((Get-Date) -lt $logDeadline) {
        $result = Invoke-Az @('rest', '--method', 'post', '--url', $queryUrl, '--resource', 'https://api.loganalytics.io',
            '--body', "@$queryFile", '-o', 'json') | ConvertFrom-Json
        $rows = @($result.tables[0].rows)
        if ($rows.Count -ge 2) { break }
        Start-Sleep -Seconds 30
    }
} finally {
    Remove-Item -LiteralPath $queryFile -ErrorAction SilentlyContinue
}

Write-Host "--- LARK-DNS lines (from inside vnet-lark; healthy = 10.60.1.x) ---"
foreach ($r in $rows) {
    if ($r[0] -is [datetime]) { $t = $r[0].ToUniversalTime() }
    else { $t = [DateTimeOffset]::Parse($r[0], [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    Write-Host "$(Format-Eastern $t)  $(Protect-Line $r[1])"
}
if ($rows.Count -lt 2) {
    Write-Warning "Expected 2 LARK-DNS lines within $TimeoutMinutes minutes, got $($rows.Count). If the job failed, a name may not resolve at all; check ContainerAppConsoleLogs for $execution."
}
if ($status -ne 'Succeeded') { throw "DNS check execution $execution finished with status '$status'." }
