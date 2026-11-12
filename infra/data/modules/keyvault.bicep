// Key Vault for application secrets (third-party carrier API keys and similar).
//
// - Azure RBAC authorization (not access policies): the same role model as everything else, assignable to the
//   app's managed identity in M4 at the narrowest scope.
// - Public network access disabled, network ACL default Deny with no trusted-service bypass: only the private
//   endpoint in snet-pe can reach the data plane.
// - Soft delete (7 days, the minimum) + purge protection: a deleted vault or secret can be recovered, and nobody,
//   including an Owner, can permanently purge it early. Purge protection can't be turned off once enabled.
// - No resource lock (INC-002). A CanNotDelete lock also covers the vault's private endpoint connection records,
//   which Azure deletes whenever a private endpoint is removed, so it blocked the per-session teardown. Soft delete +
//   purge protection already guarantee the vault and its secrets are recoverable; the lock only duplicated that.
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Globally unique vault name (3-24 characters)')
@maxLength(24)
param vaultName string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
