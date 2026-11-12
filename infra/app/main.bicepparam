using './main.bicep'
param location = 'eastus'
param tags = {
  project: 'larkspur-azure-platform'
  company: 'Larkspur Logistics (fictional)'
  costCenter: 'CC-LARK-01'
  environment: 'lab'
  owner: 'platform'
}
param vnetAddressPrefix = '10.60.0.0/16'
param acaSubnetPrefix = '10.60.0.0/27'
param peSubnetPrefix = '10.60.1.0/27'
param dataResourceGroupName = 'rg-lark-data'
param sqlLocation = 'eastus2'
