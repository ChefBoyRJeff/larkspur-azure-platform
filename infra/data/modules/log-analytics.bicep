// Log Analytics workspace for the platform (Container Apps console/system logs now; diagnostic settings in M6).
//
// - Daily cap 0.1 GB: the first 5 GB/month of ingestion are free (M0 pricing), so a hard cap keeps a noisy app or a
//   misconfigured diagnostic setting from ever turning into a bill. When the cap is hit, ingestion stops until the
//   next day; that trade-off is acceptable here and documented.
// - 30-day retention: within the included retention, so storage costs nothing extra.
// - Persistent (rg-lark-data): logs from a session must survive that session's teardown.
targetScope = 'resourceGroup'

@description('Region')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Workspace name')
param workspaceName string

@description('Daily ingestion cap in GB')
param dailyQuotaGb string = '0.1'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: json(dailyQuotaGb)
    }
  }
}

output workspaceName string = workspace.name
output workspaceId string = workspace.id
output customerId string = workspace.properties.customerId
