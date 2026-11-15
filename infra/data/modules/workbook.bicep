// "Larkspur Operations" Azure Monitor workbook (M6). I built it in the portal against real session data, exported the
// Gallery Template JSON, and replaced the resource IDs with placeholders so no subscription ID is committed. It lives
// in rg-lark-data: the queries read log-lark, which keeps 30 days of logs after each session's teardown.
//
// Saving it from the portal was refused by the M1 tag policy (no costCenter tag), so code is how it's created.
targetScope = 'resourceGroup'

@description('Region for the workbook resource')
param location string

@description('Standard Larkspur tags (costCenter is required by policy)')
param tags object

@description('Log Analytics workspace the queries read')
param logAnalyticsWorkspaceName string

@description('SQL server name (from the sql module)')
param sqlServerName string

@description('SQL database name (from the sql module)')
param sqlDatabaseName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource server 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' existing = {
  parent: server
  name: sqlDatabaseName
}

var template = loadTextContent('../workbooks/larkspur-operations.workbook.json')

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  // Workbook names must be GUIDs; this one is stable for this resource group.
  name: guid(resourceGroup().id, 'larkspur-operations-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Larkspur Operations'
    category: 'workbook'
    sourceId: 'azure monitor'
    serializedData: replace(replace(template, '{workspaceId}', workspace.id), '{sqlDatabaseId}', database.id)
  }
}

output workbookName string = workbook.name
