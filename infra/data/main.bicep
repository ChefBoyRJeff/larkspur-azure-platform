// larkspur-azure-platform: persistent data-tier resources in rg-lark-data.
// M2: private DNS zones. M3: Azure SQL (free tier) and Key Vault, both private-only, both locked.
// M6 adds monitoring.
//
// Why these live here and not in rg-lark-app: they hold state (data, secrets, DNS records) and cost ~$0 when idle,
// while rg-lark-app's contents are torn down every session.
targetScope = 'resourceGroup'

import { larkSqlServerName, larkKeyVaultName } from '../shared/naming.bicep'

@description('Region for regional data resources (Key Vault)')
param location string

@description('Region for the SQL server and database. Separate from location because new SQL servers are provisioning-restricted for this subscription in East US (INC-001); the private endpoint stays in vnet-lark (East US), which Private Link supports across regions.')
param sqlLocation string

@description('Standard Larkspur tags. costCenter is required by policy on every resource.')
param tags object

@description('Display name of the Entra group that administers SQL (lark-sql-admins)')
param sqlAdminGroupName string

@description('Object ID of that Entra group (from the gitignored local parameter file)')
param sqlAdminGroupObjectId string

// Zone names come from Microsoft's private endpoint DNS table. The SQL zone is built from environment() so the
// template has no hard-coded cloud-specific hostname (linter rule no-hardcoded-env-urls).
var dnsZoneNames = [
  'privatelink${environment().suffixes.sqlServerHostname}'
  'privatelink.vaultcore.azure.net'
]

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zone in dnsZoneNames: {
    name: zone
    location: 'global'
    tags: tags
  }
]

module sql 'modules/sql.bicep' = {
  name: 'lark-sql'
  params: {
    location: sqlLocation
    tags: tags
    serverName: larkSqlServerName(subscription().subscriptionId, sqlLocation)
    databaseName: 'sqldb-lark-tracking'
    adminGroupName: sqlAdminGroupName
    adminGroupObjectId: sqlAdminGroupObjectId
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'lark-keyvault'
  params: {
    location: location
    tags: tags
    vaultName: larkKeyVaultName(subscription().subscriptionId)
  }
}

output dnsZoneNames array = [for (zone, i) in dnsZoneNames: zones[i].name]
output sqlServerName string = sql.outputs.serverName
output sqlServerFqdn string = sql.outputs.serverFqdn
output sqlDatabaseName string = sql.outputs.databaseName
output keyVaultName string = keyVault.outputs.vaultName
output keyVaultUri string = keyVault.outputs.vaultUri
