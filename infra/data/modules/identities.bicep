// User-assigned managed identities for the application tier, and their Key Vault roles.
//
// Why user-assigned and why here (rg-lark-data, persistent):
// - The app stack in rg-lark-app is rebuilt every session. A system-assigned identity, or a user-assigned one in
//   rg-lark-app, would get a NEW client ID each session, so its SQL user and role assignments would go stale.
//   Persistent identities keep a stable client ID, so the database user and RBAC are created once.
// - Two identities, two blast radiuses:
//     id-lark-tracking-api  the API: read one secret family (Key Vault Secrets User) and SELECT on dbo.Shipments
//                           (granted inside the database by the migration job)
//     id-lark-migrator      the migration job: SQL admin through the lark-sql-admins group, and Key Vault Secrets
//                           Officer so it can create the generated carrier API key
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Key Vault the identities need access to')
param keyVaultName string

// Built-in role definition IDs (same in every tenant).
var roleIds = {
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-lark-tracking-api'
  location: location
  tags: tags
}

resource migratorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-lark-migrator'
  location: location
  tags: tags
}

resource appSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, appIdentity.id, roleIds.keyVaultSecretsUser)
  scope: vault
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
    description: 'tracking-api: read application secrets'
  }
}

resource migratorSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, migratorIdentity.id, roleIds.keyVaultSecretsOfficer)
  scope: vault
  properties: {
    principalId: migratorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsOfficer)
    description: 'migration job: create generated application secrets'
  }
}

output appIdentityName string = appIdentity.name
output appIdentityClientId string = appIdentity.properties.clientId
output migratorIdentityName string = migratorIdentity.name
output migratorPrincipalId string = migratorIdentity.properties.principalId
