// larkspur-azure-platform: persistent data-tier resources in rg-lark-data.
// M2: private DNS zones for private endpoints. M3 adds SQL and Key Vault; M6 adds monitoring.
//
// Why the zones live here and not in rg-lark-app: a zone is priced per month (M0 pricing) and rg-lark-app's
// contents are torn down every session. Shared DNS zones are also a platform service in real landing zones;
// workload VNets link to them rather than owning them.
targetScope = 'resourceGroup'

@description('Standard Larkspur tags. costCenter is required by policy on every resource.')
param tags object

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

output dnsZoneNames array = [for (zone, i) in dnsZoneNames: zones[i].name]
