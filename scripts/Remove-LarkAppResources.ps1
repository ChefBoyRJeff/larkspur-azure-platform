<#
.SYNOPSIS
    End-of-session teardown for the Larkspur application stack.

.DESCRIPTION
    Removes everything INSIDE rg-lark-app, plus vnet-lark's links in the shared private DNS zones, and leaves:
      - rg-lark-app itself, because it carries the M1 policy and RBAC assignments (deleting the group would delete
        them too, and recreating them needs Owner-level rights the pipeline should never have);
      - rg-lark-data (SQL, Key Vault, DNS zones, monitoring), which is persistent and near $0 when idle.

    Order matters: DNS links first (they point at the VNet), then app -> environment -> private endpoints -> VNet ->
    NSGs -> identities. A type not in the known list is reported and left in place, never deleted blindly.

.PARAMETER AppResourceGroup
    Resource group holding the application stack.

.PARAMETER DnsResourceGroup
    Resource group holding the shared private DNS zones.

.PARAMETER LinkName
    Name of the VNet link created in every zone by infra/app/modules/dns-links.bicep.

.PARAMETER InfraResourceGroup
    Platform-managed resource group of the Container Apps environment (load balancer, public IPs). Azure deletes it
    with the environment; the script only verifies that it's gone, because it keeps billing while it exists.

.EXAMPLE
    ./scripts/Remove-LarkAppResources.ps1 -WhatIf
    Lists what would be deleted without deleting anything.

.EXAMPLE
    ./scripts/Remove-LarkAppResources.ps1
    Deletes the stack and verifies the resource group is empty.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()][string]$AppResourceGroup = 'rg-lark-app',
    [ValidateNotNullOrEmpty()][string]$DnsResourceGroup = 'rg-lark-data',
    [ValidateNotNullOrEmpty()][string]$LinkName = 'link-vnet-lark',
    [ValidateNotNullOrEmpty()][string]$InfraResourceGroup = 'rg-lark-app-infra'
)

$ErrorActionPreference = 'Stop'

function Invoke-Az {
    # Runs an az command and throws on a non-zero exit code (native commands don't throw on their own).
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments -join ' ') failed (exit $LASTEXITCODE): $output" }
    return $output
}

$deleteOrder = @(
    'Microsoft.App/containerApps'
    'Microsoft.App/jobs'
    'Microsoft.App/managedEnvironments'
    'Microsoft.Network/privateEndpoints'
    'Microsoft.Network/virtualNetworks'
    'Microsoft.Network/networkSecurityGroups'
    'Microsoft.ManagedIdentity/userAssignedIdentities'
)

# Timestamps are Eastern time, MM-DD-YYYY HH:MM (project convention).
$eastern = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Eastern Standard Time')
Write-Host "=== Teardown: $AppResourceGroup (links in $DnsResourceGroup), $($eastern.ToString('MM-dd-yyyy HH:mm')) EST ==="

# 1. DNS zone links that belong to this stack.
$zones = Invoke-Az @('network', 'private-dns', 'zone', 'list', '--resource-group', $DnsResourceGroup, '--query', '[].name', '-o', 'tsv')
foreach ($zone in @($zones | Where-Object { $_ })) {
    $exists = & az network private-dns link vnet show --resource-group $DnsResourceGroup --zone-name $zone --name $LinkName --query name -o tsv 2>$null
    if ($exists) {
        if ($PSCmdlet.ShouldProcess("$zone/$LinkName", 'Delete private DNS zone VNet link')) {
            Invoke-Az @('network', 'private-dns', 'link', 'vnet', 'delete', '--resource-group', $DnsResourceGroup, '--zone-name', $zone, '--name', $LinkName, '--yes') | Out-Null
            Write-Host "deleted link   $zone/$LinkName"
        }
    }
    else {
        Write-Host "no link        $zone/$LinkName"
    }
}

# 2. Resources in the application resource group, in dependency order.
$resources = Invoke-Az @('resource', 'list', '--resource-group', $AppResourceGroup, '--query', '[].{id:id, name:name, type:type}', '-o', 'json') | ConvertFrom-Json
foreach ($type in $deleteOrder) {
    foreach ($r in @($resources | Where-Object { $_.type -eq $type })) {
        if ($PSCmdlet.ShouldProcess("$($r.type)/$($r.name)", 'Delete')) {
            Invoke-Az @('resource', 'delete', '--ids', $r.id) | Out-Null
            Write-Host "deleted        $($r.type)/$($r.name)"
        }
    }
}

# 3. Verify. Anything left is either a type this script doesn't know about or a NIC still being cleaned up.
if (-not $WhatIfPreference) {
    $left = Invoke-Az @('resource', 'list', '--resource-group', $AppResourceGroup, '--query', '[].{name:name, type:type}', '-o', 'json') | ConvertFrom-Json
    if (@($left).Count -eq 0) {
        Write-Host "verified       $AppResourceGroup is empty"
    }
    else {
        Write-Warning "$(@($left).Count) resource(s) left in ${AppResourceGroup}:"
        $left | ForEach-Object { Write-Warning "  $($_.type)/$($_.name)" }
    }
    # 4. The Container Apps managed group is deleted by Azure with the environment, sometimes a few minutes later.
    $deadline = (Get-Date).AddMinutes(10)
    while (((& az group exists --name $InfraResourceGroup) -eq 'true') -and ((Get-Date) -lt $deadline)) { Start-Sleep -Seconds 30 }
    if ((& az group exists --name $InfraResourceGroup) -eq 'true') {
        Write-Warning "$InfraResourceGroup still exists after 10 minutes (load balancer + public IPs keep billing); check it in the portal"
    }
    else {
        Write-Host "verified       $InfraResourceGroup is gone"
    }
}
