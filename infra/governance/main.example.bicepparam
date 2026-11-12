using './main.bicep'
param location = 'eastus'
param allowedLocations = ['eastus']
param dataAllowedLocations = ['eastus', 'eastus2']
param tags = {
  project: 'larkspur-azure-platform'
  company: 'Larkspur Logistics (fictional)'
  costCenter: 'CC-LARK-01'
  environment: 'lab'
  owner: 'platform'
}
param opsGroupObjectId = 'replace-with-lark-ops-object-id'
param devGroupObjectId = 'replace-with-lark-dev-object-id'
