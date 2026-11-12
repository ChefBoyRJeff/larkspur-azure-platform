using './main.bicep'
param location = 'eastus'
param sqlLocation = 'eastus2'
param tags = {
  project: 'larkspur-azure-platform'
  company: 'Larkspur Logistics (fictional)'
  costCenter: 'CC-LARK-01'
  environment: 'lab'
  owner: 'platform'
}
param sqlAdminGroupName = 'lark-sql-admins'
param sqlAdminGroupObjectId = 'replace-with-lark-sql-admins-object-id'
