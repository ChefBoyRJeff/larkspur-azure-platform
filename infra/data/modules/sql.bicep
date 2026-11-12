// Azure SQL logical server + free-tier database for shipment data.
//
// - Microsoft Entra-only authentication: no SQL logins or passwords exist anywhere. Admin is an Entra GROUP, so
//   admin access is a membership change, and the app (M4) gets its own least-privilege database user.
// - Public network access disabled: the only way in is the private endpoint in snet-pe (M3, app stack). The M1
//   policy 'lark-deny-sql-public-access' denies any attempt to turn it back on.
// - Free tier: 100,000 vCore-seconds, 32 GB data and 32 GB backup per month. AutoPause at the free limit means the
//   database can never bill compute; it goes offline until the next month instead.
// - CanNotDelete lock on the DATABASE, not the server (INC-002). A server lock also covers the server's private
//   endpoint connection records, which Azure deletes whenever a private endpoint is removed, so it blocked the
//   per-session teardown. The database is where the data lives, and its connection records aren't children of it.
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Globally unique logical server name')
param serverName string

@description('Database name')
param databaseName string

@description('Display name of the Entra group that administers the server')
param adminGroupName string

@description('Object ID of that Entra group')
param adminGroupObjectId string

resource server 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'Group'
      login: adminGroupName
      sid: adminGroupObjectId
      tenantId: tenant().tenantId
    }
  }
}

// Settings copied from Microsoft's free-tier ARM sample (sku, maxSizeBytes, backup redundancy, free-limit flags).
resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: server
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    createMode: 'Default'
    maxSizeBytes: 34359738368
    requestedBackupStorageRedundancy: 'Local'
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
  }
}

resource databaseLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'lock-${databaseName}'
  scope: database
  properties: {
    level: 'CanNotDelete'
    notes: 'Larkspur shipment data. Remove only through a planned change (see docs/plan.md).'
  }
}

output serverName string = server.name
output serverFqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
