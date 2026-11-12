// larkspur-azure-platform, M1: governance foundation.
// Creates the two resource groups and applies guardrails + least-privilege RBAC to each one.
//
// Design decisions:
// - Policies are assigned at RESOURCE GROUP scope, not subscription scope. The subscription also hosts nine other
//   lab projects; a subscription-wide "require costCenter tag" would start denying their redeployments.
// - Access goes to Entra GROUPS, never to individual users, so onboarding/offboarding is a membership change,
//   not an RBAC change.
// - Resource locks are NOT here. A CanNotDelete lock on rg-lark-data would also block deleting the private DNS zone
//   VNet links that the per-session teardown removes (a lock applies to child resources). Locks go on the SQL server
//   and Key Vault themselves in M3.
targetScope = 'subscription'

@description('Region for the Larkspur resource groups')
param location string

@description('Regions allowed by policy in rg-lark-app (global resources are excluded by the built-in policy)')
param allowedLocations array

@description('Regions allowed by policy in rg-lark-data. Wider than rg-lark-app because East US stopped accepting new SQL servers for this subscription (M3 incident INC-001), so the SQL server lives in a second region.')
param dataAllowedLocations array

@description('Tags applied to both resource groups. costCenter is also required on every resource by policy.')
param tags object

@description('Object ID of the lark-ops Entra security group (platform operations)')
param opsGroupObjectId string

@description('Object ID of the lark-dev Entra security group (application developers)')
param devGroupObjectId string

// Built-in role definition IDs (same in every tenant). Verified with az role definition list before deployment.
var roleIds = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  monitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
}

resource rgData 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lark-data'
  location: location
  tags: tags
}

resource rgApp 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-lark-app'
  location: location
  tags: tags
}

// rg-lark-data: persistent data, secrets, monitoring. SQL public network access is denied here.
module govData 'modules/rg-governance.bicep' = {
  name: 'gov-rg-lark-data'
  scope: rgData
  params: {
    allowedLocations: dataAllowedLocations
    requiredTagName: 'costCenter'
    denySqlPublicNetworkAccess: true
    roleAssignments: [
      {
        principalId: opsGroupObjectId
        roleId: roleIds.reader
        description: 'lark-ops: read platform data resources'
      }
      {
        principalId: opsGroupObjectId
        roleId: roleIds.monitoringContributor
        description: 'lark-ops: manage alerts, action groups and workbooks'
      }
    ]
  }
}

// rg-lark-app: torn down every session and redeployed by the pipeline. Humans only read it; the pipeline writes it (M5).
module govApp 'modules/rg-governance.bicep' = {
  name: 'gov-rg-lark-app'
  scope: rgApp
  params: {
    allowedLocations: allowedLocations
    requiredTagName: 'costCenter'
    denySqlPublicNetworkAccess: false
    roleAssignments: [
      {
        principalId: opsGroupObjectId
        roleId: roleIds.reader
        description: 'lark-ops: read application resources'
      }
      {
        principalId: devGroupObjectId
        roleId: roleIds.reader
        description: 'lark-dev: read application resources; changes go through the pipeline'
      }
    ]
  }
}

output resourceGroups array = [
  rgData.name
  rgApp.name
]
output dataPolicyAssignments array = govData.outputs.policyAssignmentNames
output appPolicyAssignments array = govApp.outputs.policyAssignmentNames
