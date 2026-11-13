<#
.SYNOPSIS
  Creates the Azure and Microsoft Entra ID setup for the larkspur-azure-platform GitHub Actions workflows:
  two custom roles, two app registrations with GitHub OIDC federated credentials (no secrets), and
  resource-group-scoped role assignments.

.DESCRIPTION
  Adapted from my azure-bicep-cicd-pipeline project. Idempotent: every step checks what exists and only creates
  what's missing, so re-running is safe. The output contains names, roles and scopes only (no subscription, tenant,
  client or object IDs), so the -OutFile log can be committed as evidence after the usual leak check.

  Identities
    gh-lark-plan    pull requests: read + what-if + validate (custom role "Larkspur What-If Reader")
                    on rg-lark-app and rg-lark-data. Cannot deploy anything.
    gh-lark-deploy  the "production" GitHub environment (required reviewer): Contributor on rg-lark-app, and
                    "Larkspur Data-Tier Integrator" on rg-lark-data (DNS links, endpoint approval, identity assign).

  The pipeline deploys ONLY the app stack (rg-lark-app). Governance and the data tier hold policies, locks, role
  assignments and data, and stay admin-deployed.

.EXAMPLE
  .\scripts\Initialize-LarkPipeline.ps1 -OutFile docs\evidence\m5-01-pipeline-identity.txt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$OutFile,

  [string]$Repo = 'ChefBoyRJeff/larkspur-azure-platform',

  # GitHub's immutable numeric owner ID (public). Repositories created after 07-15-2026 send OIDC subjects in the
  # immutable format repo:<owner>@<ownerId>/<repo>@<repoId>:..., which Entra ID must match exactly.
  [long]$OwnerId = 156028335,

  [string]$RoleDir = (Join-Path $PSScriptRoot '..\identity')
)

$ErrorActionPreference = 'Stop'

function Log([string]$Message) { $Message | Tee-Object -FilePath $OutFile -Append }

function Invoke-Az {
  $output = & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed with exit code $LASTEXITCODE" }
  return $output
}

function New-TempJson([string]$Json) {
  $path = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($path, $Json)   # no BOM: az can't parse one
  return $path
}

function Get-AppId([string]$DisplayName) {
  $ids = @(Invoke-Az ad app list --display-name $DisplayName --query '[].appId' -o tsv | Where-Object { $_ })
  if ($ids.Count -gt 1) { throw "More than one app registration is named '$DisplayName'. Resolve this in the portal first." }
  return $ids | Select-Object -First 1
}

function Get-SpObjectId([string]$AppId) { Invoke-Az ad sp list --filter "appId eq '$AppId'" --query '[0].id' -o tsv }

$eastern = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId((Get-Date), 'Eastern Standard Time')
$SubscriptionId = Invoke-Az account show --query id -o tsv
function Get-RgScope([string]$Name) { "/subscriptions/$SubscriptionId/resourceGroups/$Name" }

# --- Design (single source of truth) ----------------------------------------------------------
$RepoId = (Invoke-RestMethod "https://api.github.com/repos/$Repo").id   # public repo metadata
$Owner, $RepoName = $Repo -split '/', 2
$SubjectPrefix = "repo:${Owner}@${OwnerId}/${RepoName}@${RepoId}"

$Roles = @(
  @{ Name = 'Larkspur What-If Reader';       File = 'larkspur-whatif-reader.role.json';       CheckScope = 'rg-lark-app' }
  @{ Name = 'Larkspur Data-Tier Integrator'; File = 'larkspur-data-tier-integrator.role.json'; CheckScope = 'rg-lark-data' }
)

$Identities = @(
  @{ Name = 'gh-lark-plan';   CredName = 'github-pull-request';   Subject = "${SubjectPrefix}:pull_request" }
  @{ Name = 'gh-lark-deploy'; CredName = 'github-env-production'; Subject = "${SubjectPrefix}:environment:production" }
)

$Assignments = @(
  @{ Identity = 'gh-lark-plan';   Role = 'Larkspur What-If Reader';       ResourceGroup = 'rg-lark-app' }
  @{ Identity = 'gh-lark-plan';   Role = 'Larkspur What-If Reader';       ResourceGroup = 'rg-lark-data' }
  @{ Identity = 'gh-lark-deploy'; Role = 'Contributor';                   ResourceGroup = 'rg-lark-app' }
  @{ Identity = 'gh-lark-deploy'; Role = 'Larkspur Data-Tier Integrator'; ResourceGroup = 'rg-lark-data' }
)

"=== Initialize-LarkPipeline, $($eastern.ToString('MM-dd-yyyy HH:mm')) EST, repo $Repo ===" | Set-Content $OutFile

# --- 1. Custom roles --------------------------------------------------------------------------
Log '--- 1. Custom roles ---'
# Role definition IDs (GUIDs). Assignments use the ID, not the name: a new custom role's NAME can't be resolved at
# every scope until it replicates, but its ID is known the moment it's created.
$RoleIds = @{ 'Contributor' = 'b24988ac-6180-42a0-ab88-20f7382dd24c' }   # built-in, same ID in every tenant
foreach ($r in $Roles) {
  $found = Invoke-Az role definition list --custom-role-only true --name $r.Name --scope (Get-RgScope $r.CheckScope) --query '[0].name' -o tsv
  if ($found) { $RoleIds[$r.Name] = $found; Log "  exists   $($r.Name)"; continue }
  $json = (Get-Content (Join-Path $RoleDir $r.File) -Raw).Replace('{subscriptionId}', $SubscriptionId)
  $tmp = New-TempJson $json
  try { $RoleIds[$r.Name] = Invoke-Az role definition create --role-definition "@$tmp" --query name -o tsv } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  Log "  created  $($r.Name)"
}

# --- 2. App registrations + service principals (no secrets) -------------------------------------
Log '--- 2. App registrations and service principals ---'
foreach ($id in $Identities) {
  $appId = Get-AppId $id.Name
  if ($appId) { Log "  exists   app $($id.Name)" }
  else { $appId = Invoke-Az ad app create --display-name $id.Name --query appId -o tsv; Log "  created  app $($id.Name)" }
  if (Get-SpObjectId $appId) { Log "  exists   service principal $($id.Name)" }
  else { Invoke-Az ad sp create --id $appId -o none; Log "  created  service principal $($id.Name)" }
}

# --- 3. Federated credentials (GitHub OIDC trust) ---------------------------------------------
Log '--- 3. Federated credentials ---'
foreach ($id in $Identities) {
  $appId = Get-AppId $id.Name
  $existing = @((Invoke-Az ad app federated-credential list --id $appId -o json) -join "`n" | ConvertFrom-Json)
  foreach ($c in $existing | Where-Object { $_.subject -ne $id.Subject }) {
    Invoke-Az ad app federated-credential delete --id $appId --federated-credential-id $c.id -o none
    Log "  removed  $($id.Name) <- $($c.subject)"
  }
  if ($existing.subject -contains $id.Subject) { Log "  exists   $($id.Name) <- $($id.Subject)"; continue }
  $body = @{
    name        = $id.CredName
    issuer      = 'https://token.actions.githubusercontent.com'
    subject     = $id.Subject
    description = "GitHub Actions OIDC for $Repo"
    audiences   = @('api://AzureADTokenExchange')
  } | ConvertTo-Json -Compress
  $tmp = New-TempJson $body
  try { Invoke-Az ad app federated-credential create --id $appId --parameters "@$tmp" -o none } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
  Log "  created  $($id.Name) <- $($id.Subject)"
}

# --- 4. Role assignments (resource-group scope only) --------------------------------------------
Log '--- 4. Role assignments ---'
foreach ($a in $Assignments) {
  $spId = Get-SpObjectId (Get-AppId $a.Identity)
  $scope = Get-RgScope $a.ResourceGroup
  $roleId = $RoleIds[$a.Role]
  $count = @((Invoke-Az role assignment list --assignee $spId --scope $scope -o json) -join "`n" | ConvertFrom-Json |
    Where-Object { $_.roleDefinitionId -like "*/$roleId" }).Count
  if ($count -gt 0) { Log "  exists   $($a.Identity) -> $($a.Role) @ $($a.ResourceGroup)"; continue }
  for ($try = 1; $try -le 8; $try++) {   # new principals and custom roles take a minute to replicate
    & az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal --role $roleId --scope $scope -o none 2>$null
    if ($LASTEXITCODE -eq 0) { break }
    if ($try -eq 8) { throw "Role assignment failed after 8 attempts: $($a.Identity) -> $($a.Role) @ $($a.ResourceGroup)" }
    Log "  waiting  for replication (attempt $try of 8)"
    Start-Sleep -Seconds 15
  }
  Log "  created  $($a.Identity) -> $($a.Role) @ $($a.ResourceGroup)"
}

# --- 5. Verify (read-only) ------------------------------------------------------------------
Log '--- 5. Verify ---'
foreach ($id in $Identities) {
  $appId = Get-AppId $id.Name
  $secrets = @((Invoke-Az ad app credential list --id $appId -o json) -join "`n" | ConvertFrom-Json).Count
  $certs = @((Invoke-Az ad app credential list --id $appId --cert -o json) -join "`n" | ConvertFrom-Json).Count
  Log ("  {0,-15} secrets={1} certificates={2} (expect 0 and 0)" -f $id.Name, $secrets, $certs)
  foreach ($c in (Invoke-Az ad app federated-credential list --id $appId -o json) -join "`n" | ConvertFrom-Json) {
    Log ("  {0,-15} trusts {1}" -f $id.Name, $c.subject)
  }
  $spId = Get-SpObjectId $appId
  foreach ($ra in (Invoke-Az role assignment list --assignee $spId --all -o json) -join "`n" | ConvertFrom-Json) {
    $where = if ($ra.scope -match '/resourceGroups/([^/]+)$') { "resource group $($Matches[1])" } else { 'UNEXPECTED SCOPE' }
    $roleName = ($RoleIds.GetEnumerator() | Where-Object { $ra.roleDefinitionId -like "*/$($_.Value)" } | Select-Object -First 1).Key
    if (-not $roleName) { $roleName = $ra.roleDefinitionName }
    Log ("  {0,-15} {1,-30} @ {2}" -f $id.Name, $roleName, $where)
  }
}
Log 'Done.'
