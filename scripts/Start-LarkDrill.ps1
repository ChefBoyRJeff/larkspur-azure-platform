<#
.SYNOPSIS
    Runs one M7 recovery drill command in the job-lark-drill Container Apps job and prints its log lines.

.DESCRIPTION
    The drill code (app/larkspur/drill.py) has to run inside the VNet, because the database and Key Vault accept no
    public connections. This script starts ONE execution of job-lark-drill with the drill command you pass, waits for
    it to finish, then reads its LARK-DRILL lines from Log Analytics (ContainerAppConsoleLogs in log-lark).

    How the command is passed: the Jobs - Start REST API accepts an execution template. An override REPLACES the whole
    template for that execution, so the script reads the job's current container (image, command, env, resources)
    and sends it back with only the args changed. The job's stored configuration is not modified.

    Only az CLI calls are used (az containerapp, az rest). Nothing secret is read or printed.

.PARAMETER DrillArgs
    The drill command and its options, one array element each, e.g. 'mark','--count','20','--interval','15'.

.PARAMETER ResourceGroup
    Resource group of the job (the app stack).

.PARAMETER JobName
    Name of the drill job.

.PARAMETER DataResourceGroup
    Resource group of the Log Analytics workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace that receives the environment's console logs.

.PARAMETER TimeoutMinutes
    How long to wait for the execution to finish, and then again for its log lines to arrive.

.EXAMPLE
    ./scripts/Start-LarkDrill.ps1 -DrillArgs 'secret-check'

.EXAMPLE
    ./scripts/Start-LarkDrill.ps1 -DrillArgs 'mark','--count','20','--interval','15'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateCount(1, 10)][string[]]$DrillArgs,
    [ValidateNotNullOrEmpty()][string]$ResourceGroup = 'rg-lark-app',
    [ValidateNotNullOrEmpty()][string]$JobName = 'job-lark-drill',
    [ValidateNotNullOrEmpty()][string]$DataResourceGroup = 'rg-lark-data',
    [ValidateNotNullOrEmpty()][string]$WorkspaceName = 'log-lark',
    [ValidateRange(1, 30)][int]$TimeoutMinutes = 20
)

$ErrorActionPreference = 'Stop'
$knownCommands = @('mark', 'corrupt', 'snapshot', 'compare', 'repair', 'secret-check', 'secret-delete', 'secret-recover')
if ($knownCommands -notcontains $DrillArgs[0]) {
    throw "Unknown drill command '$($DrillArgs[0])'. Expected one of: $($knownCommands -join ', ')"
}

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

function Write-JsonFile {
    # UTF-8 without a byte-order mark (az rest rejects a BOM on Windows PowerShell 5.1).
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Path)
    [System.IO.File]::WriteAllText($Path, ($Object | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
}

$easternZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
function Format-Eastern {
    # Project convention: MM-DD-YYYY hh:mm:ss AM/PM EST.
    param([Parameter(Mandatory)][datetime]$Utc)
    return [TimeZoneInfo]::ConvertTimeFromUtc($Utc, $easternZone).ToString('MM-dd-yyyy hh:mm:ss tt')
}

# 1. Read the job's current container so the override keeps image, command, env and resources.
$job = Invoke-Az @('containerapp', 'job', 'show', '-g', $ResourceGroup, '-n', $JobName, '-o', 'json') | ConvertFrom-Json
$current = @($job.properties.template.containers)
if ($current.Count -ne 1) { throw "Expected exactly one container in $JobName, found $($current.Count)." }
$c = $current[0]

$envList = @(foreach ($e in @($c.env)) { [ordered]@{ name = $e.name; value = $e.value } })
$template = [ordered]@{
    containers = @(
        [ordered]@{
            name      = $c.name
            image     = $c.image
            command   = @($c.command)
            args      = @($DrillArgs)
            env       = $envList
            resources = [ordered]@{ cpu = $c.resources.cpu; memory = $c.resources.memory }
        }
    )
}

$bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "lark-drill-start-$PID.json"
Write-JsonFile -Object $template -Path $bodyFile

# 2. Start one execution with the override.
$startedUtc = (Get-Date).ToUniversalTime()
$startUrl = "https://management.azure.com$($job.id)/start?api-version=2024-03-01"
try {
    $started = Invoke-Az @('rest', '--method', 'post', '--url', $startUrl, '--body', "@$bodyFile", '-o', 'json') | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}
$execution = $started.name
if (-not $execution) {
    # The start call returned no body: take the newest execution of the job instead.
    $all = Invoke-Az @('containerapp', 'job', 'execution', 'list', '-g', $ResourceGroup, '-n', $JobName, '-o', 'json') | ConvertFrom-Json
    $execution = (@($all) | Sort-Object { [datetime]$_.properties.startTime } | Select-Object -Last 1).name
}
if (-not $execution) { throw "Could not find the execution that was just started for $JobName." }
Write-Host "=== drill: $($DrillArgs -join ' ') ==="
Write-Host "execution      $execution"
Write-Host "started        $(Format-Eastern $startedUtc) EST"

# 3. Wait for it to finish.
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$status = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $status = Invoke-Az @('containerapp', 'job', 'execution', 'show', '-g', $ResourceGroup, '-n', $JobName,
        '--job-execution-name', $execution, '--query', 'properties.status', '-o', 'tsv')
    if (@('Succeeded', 'Failed', 'Stopped', 'Degraded') -contains $status) { break }
}
$finishedUtc = (Get-Date).ToUniversalTime()
Write-Host "status         $status at $(Format-Eastern $finishedUtc) EST (checked every 10 seconds)"

# 4. Read the drill's own log lines. Console logs reach Log Analytics a few minutes after they're written.
$customerId = Invoke-Az @('monitor', 'log-analytics', 'workspace', 'show', '-g', $DataResourceGroup, '-n', $WorkspaceName,
    '--query', 'customerId', '-o', 'tsv')
$since = $startedUtc.AddMinutes(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
$kql = "ContainerAppConsoleLogs | where TimeGenerated >= datetime($since) | where ContainerName == 'drill' " +
    "| where Log startswith 'LARK-DRILL' | project TimeGenerated, ContainerGroupName, Log | order by TimeGenerated asc"
$queryFile = Join-Path ([System.IO.Path]::GetTempPath()) "lark-drill-query-$PID.json"
Write-JsonFile -Object ([ordered]@{ query = $kql; timespan = 'PT3H' }) -Path $queryFile
$queryUrl = "https://api.loganalytics.io/v1/workspaces/$customerId/query"

$endPattern = "^LARK-DRILL end $([regex]::Escape($DrillArgs[0])) exit="
$rows = @()
$logDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
try {
    while ((Get-Date) -lt $logDeadline) {
        $result = Invoke-Az @('rest', '--method', 'post', '--url', $queryUrl, '--resource', 'https://api.loganalytics.io',
            '--body', "@$queryFile", '-o', 'json') | ConvertFrom-Json
        $rows = @($result.tables[0].rows)
        if (@($rows | Where-Object { $_[2] -match $endPattern }).Count -gt 0) { break }
        Start-Sleep -Seconds 30
    }
} finally {
    Remove-Item -LiteralPath $queryFile -ErrorAction SilentlyContinue
}

Write-Host "--- LARK-DRILL lines (ContainerAppConsoleLogs, times EST; the drill's own UTC stamps are inside the text) ---"
foreach ($r in $rows) {
    # PowerShell 7's ConvertFrom-Json already turns ISO timestamps into DateTime; 5.1 leaves them as strings.
    if ($r[0] -is [datetime]) { $t = $r[0].ToUniversalTime() }
    else { $t = [DateTimeOffset]::Parse($r[0], [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    Write-Host "$(Format-Eastern $t)  $($r[2])"
}
if (@($rows | Where-Object { $_[2] -match $endPattern }).Count -eq 0) {
    Write-Warning "No 'end' line arrived within $TimeoutMinutes minutes. Re-run the query in log-lark later: $kql"
}
if ($status -ne 'Succeeded') { throw "Drill execution $execution finished with status '$status'." }
