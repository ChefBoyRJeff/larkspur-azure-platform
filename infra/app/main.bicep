// larkspur-azure-platform: application stack in rg-lark-app.
// The resource group itself is persistent (it carries the M1 policy and RBAC assignments); everything inside it is
// torn down at the end of every session by scripts/Remove-LarkAppResources.ps1 and redeployed from this template.
// M2: network and private DNS links. M3: private endpoints to SQL and Key Vault. M4a: Container Apps environment. M4b: tracking API + migration job.
targetScope = 'resourceGroup'

import { larkSqlServerName, larkKeyVaultName } from '../shared/naming.bicep'

@description('Region for the application stack')
param location string

@description('Standard Larkspur tags. costCenter is required by policy on every resource.')
param tags object

@description('Address space of vnet-lark')
param vnetAddressPrefix string

@description('Subnet for the Container Apps environment (minimum /27 for workload-profiles environments)')
param acaSubnetPrefix string

@description('Subnet for private endpoints')
param peSubnetPrefix string

@description('Resource group that owns the persistent data tier: private DNS zones, SQL server, Key Vault')
param dataResourceGroupName string

@description('Region of the SQL server (must match infra/data). The private endpoint stays in this stack\'s region.')
param sqlLocation string

@description('Log Analytics workspace in the data resource group (created by infra/data)')
param logAnalyticsWorkspaceName string

@description('Name for the platform-managed resource group the Container Apps environment creates (load balancer, public IPs)')
param containerAppsInfraResourceGroupName string

@description('Container image for the tracking API and the migration job')
param containerImage string

@description('SQL database name (created by infra/data)')
param sqlDatabaseName string

@description('User-assigned identity of the tracking API (created by infra/data)')
param appIdentityName string

@description('User-assigned identity of the migration job (created by infra/data)')
param migratorIdentityName string

// Must match the zone names created by infra/data/main.bicep.
var dnsZoneNames = [
  'privatelink${environment().suffixes.sqlServerHostname}'
  'privatelink.vaultcore.azure.net'
]

module network 'modules/network.bicep' = {
  name: 'lark-network'
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-lark'
    vnetAddressPrefix: vnetAddressPrefix
    acaSubnetPrefix: acaSubnetPrefix
    peSubnetPrefix: peSubnetPrefix
  }
}

// The links are child resources of the zones, so they deploy into the zones' resource group even though they
// belong to this stack's lifecycle. The teardown script deletes them before the VNet.
module dnsLinks 'modules/dns-links.bicep' = {
  name: 'lark-dns-links'
  scope: resourceGroup(dataResourceGroupName)
  params: {
    vnetId: network.outputs.vnetId
    linkName: 'link-vnet-lark'
    zoneNames: dnsZoneNames
    tags: tags
  }
}

module privateEndpoints 'modules/private-endpoints.bicep' = {
  name: 'lark-private-endpoints'
  params: {
    location: location
    tags: tags
    subnetId: network.outputs.peSubnetId
    dataResourceGroupName: dataResourceGroupName
    sqlServerName: sqlServerName
    keyVaultName: keyVaultName
  }
}

var sqlServerName = larkSqlServerName(subscription().subscriptionId, sqlLocation)
var keyVaultName = larkKeyVaultName(subscription().subscriptionId)

module containerApps 'modules/container-apps.bicep' = {
  name: 'lark-container-apps'
  params: {
    location: location
    tags: tags
    acaSubnetId: network.outputs.acaSubnetId
    infrastructureResourceGroupName: containerAppsInfraResourceGroupName
    dataResourceGroupName: dataResourceGroupName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    sqlServerFqdn: '${sqlServerName}${environment().suffixes.sqlServerHostname}'
    sqlDatabaseName: sqlDatabaseName
    keyVaultFqdn: '${keyVaultName}${environment().suffixes.keyvaultDns}'
    containerImage: containerImage
    appIdentityName: appIdentityName
    migratorIdentityName: migratorIdentityName
  }
  // The DNS check is only meaningful once the private A records and VNet links exist.
  dependsOn: [
    privateEndpoints
    dnsLinks
  ]
}

output vnetId string = network.outputs.vnetId
output acaSubnetId string = network.outputs.acaSubnetId
output peSubnetId string = network.outputs.peSubnetId
output linkedZones array = dnsLinks.outputs.linkedZones
output privateEndpoints array = privateEndpoints.outputs.privateEndpointNames
output containerAppsEnvironment string = containerApps.outputs.environmentName
output apiFqdn string = containerApps.outputs.apiFqdn
output migrateJobName string = containerApps.outputs.migrateJobName
output dnsCheckJobName string = containerApps.outputs.dnsCheckJobName
