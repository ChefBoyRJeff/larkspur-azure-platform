// Links vnet-lark to the shared private DNS zones in rg-lark-data, so names like
// <server>.database.windows.net resolve to the private endpoint IP from inside the VNet.
// Deployed at the zones' resource group scope (links are child resources of a zone).
targetScope = 'resourceGroup'

@description('Resource ID of the VNet to link')
param vnetId string

@description('Name of the link in every zone')
param linkName string

@description('Private DNS zones (already existing in this resource group) to link')
param zoneNames array

@description('Standard Larkspur tags. Links are taggable, so the costCenter policy applies to them too.')
param tags object

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' existing = [
  for zone in zoneNames: {
    name: zone
  }
]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zone, i) in zoneNames: {
    parent: zones[i]
    name: linkName
    location: 'global'
    tags: tags
    properties: {
      // No auto-registration: nothing in this VNet needs its own DNS record in these zones; the private endpoints
      // write their records through DNS zone groups (M3).
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

output linkedZones array = [for (zone, i) in zoneNames: links[i].id]
