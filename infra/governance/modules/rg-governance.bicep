// Guardrails and RBAC for one Larkspur resource group. Called once per group from ../main.bicep.
targetScope = 'resourceGroup'

@description('A role assignment for an Entra group at this resource group')
type roleAssignmentType = {
  @description('Object ID of the Entra security group')
  principalId: string
  @description('Built-in role definition GUID')
  roleId: string
  @description('Why this group needs this role (shown in the portal)')
  description: string
}

@description('Regions allowed for resources in this group')
param allowedLocations array

@description('Tag every resource in this group must carry')
param requiredTagName string

@description('Deny Azure SQL servers that allow public network access in this group')
param denySqlPublicNetworkAccess bool

@description('Group role assignments for this resource group')
param roleAssignments roleAssignmentType[]

// Built-in policy definition IDs (same in every tenant). Verified with az policy definition show before deployment.
var policyIds = {
  requireTagOnResources: '871b6d14-10aa-478d-b590-94f262ecfa99'
  allowedLocations: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
  sqlPublicNetworkAccessDisabled: '1b8ca024-1d5c-4dec-8995-b1a932b41780'
}

resource requireTag 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lark-require-${toLower(requiredTagName)}'
  properties: {
    displayName: 'Larkspur: require ${requiredTagName} tag on resources (${resourceGroup().name})'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyIds.requireTagOnResources)
    // Declared explicitly: Azure defaults it to '1.*.*' (latest 1.x of the built-in), and leaving it out made what-if
    // report Modify on every run (M1 drift check). Pinning the major version also means a breaking 2.x built-in
    // won't silently change behavior.
    definitionVersion: '1.*.*'
    enforcementMode: 'Default'
    parameters: {
      tagName: {
        value: requiredTagName
      }
    }
    nonComplianceMessages: [
      {
        message: 'Every Larkspur resource needs a ${requiredTagName} tag so its cost can be allocated.'
      }
    ]
  }
}

resource allowedLocation 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'lark-allowed-locations'
  properties: {
    displayName: 'Larkspur: allowed locations (${resourceGroup().name})'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyIds.allowedLocations)
    definitionVersion: '1.*.*'
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
    }
    nonComplianceMessages: [
      {
        message: 'Larkspur resources must be deployed to: ${join(allowedLocations, ', ')}.'
      }
    ]
  }
}

resource sqlNoPublicAccess 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (denySqlPublicNetworkAccess) {
  name: 'lark-deny-sql-public-access'
  properties: {
    displayName: 'Larkspur: deny Azure SQL public network access (${resourceGroup().name})'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyIds.sqlPublicNetworkAccessDisabled)
    definitionVersion: '1.*.*'
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'Deny'
      }
    }
    nonComplianceMessages: [
      {
        message: 'Larkspur SQL servers are reachable only through private endpoints. Set publicNetworkAccess to Disabled.'
      }
    ]
  }
}

resource groupRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for ra in roleAssignments: {
    name: guid(resourceGroup().id, ra.principalId, ra.roleId)
    properties: {
      principalId: ra.principalId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', ra.roleId)
      description: ra.description
    }
  }
]

output policyAssignmentNames array = concat(
  [
    requireTag.name
    allowedLocation.name
  ],
  denySqlPublicNetworkAccess ? ['lark-deny-sql-public-access'] : []
)
output roleAssignmentCount int = length(roleAssignments)
