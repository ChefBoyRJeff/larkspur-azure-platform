// Private endpoints for the data tier: SQL and Key Vault each get a private IP in snet-pe.
//
// Each endpoint has a DNS zone group, which writes (and on deletion removes) the A record in the matching shared
// private DNS zone. That is what makes <server>.database.windows.net resolve to 10.60.1.x from inside vnet-lark,
// while the public name still exists but refuses connections (publicNetworkAccess = Disabled).
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Resource ID of snet-pe')
param subnetId string

@description('Resource group holding the SQL server, Key Vault and private DNS zones')
param dataResourceGroupName string

@description('SQL logical server name')
param sqlServerName string

@description('Key Vault name')
param keyVaultName string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
  scope: resourceGroup(dataResourceGroupName)
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  scope: resourceGroup(dataResourceGroupName)
}

var endpoints = [
  {
    name: 'pe-lark-sql'
    targetId: sqlServer.id
    groupId: 'sqlServer'
    zoneName: 'privatelink${environment().suffixes.sqlServerHostname}'
  }
  {
    name: 'pe-lark-kv'
    targetId: vault.id
    groupId: 'vault'
    zoneName: 'privatelink.vaultcore.azure.net'
  }
]

resource privateEndpoints 'Microsoft.Network/privateEndpoints@2024-05-01' = [
  for ep in endpoints: {
    name: ep.name
    location: location
    tags: tags
    properties: {
      subnet: {
        id: subnetId
      }
      // Predictable NIC name instead of an auto-generated one, so the NIC is recognizable in the portal and logs.
      customNetworkInterfaceName: 'nic-${ep.name}'
      // Declared at the value Azure stores by default; leaving it out made what-if report a change (M3 drift check).
      // Azure returns this property, but Bicep's type definitions don't include it for any API version (checked
      // against Microsoft's privateEndpoints change log), so the type warning is suppressed on purpose.
      #disable-next-line BCP037
      isIPv6EnabledPrivateEndpoint: false
      privateLinkServiceConnections: [
        {
          name: ep.name
          properties: {
            privateLinkServiceId: ep.targetId
            groupIds: [
              ep.groupId
            ]
          }
        }
      ]
    }
  }
]

resource zoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = [
  for (ep, i) in endpoints: {
    parent: privateEndpoints[i]
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: replace(ep.zoneName, '.', '-')
          properties: {
            privateDnsZoneId: resourceId(dataResourceGroupName, 'Microsoft.Network/privateDnsZones', ep.zoneName)
          }
        }
      ]
    }
  }
]

output privateEndpointNames array = [for (ep, i) in endpoints: privateEndpoints[i].name]
