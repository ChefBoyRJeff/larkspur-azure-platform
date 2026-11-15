// Session alerting for the app stack (M6). The API is rebuilt every session, so its alert is deployed and torn down
// with it; the action group it notifies is persistent in rg-lark-data (infra/data/modules/monitoring.bicep).
//
// INC-005: my first version was a metric alert on the Container Apps `Requests` metric (statusCodeCategory = 5xx).
// In the M6 controlled failure the API returned 10 x HTTP 500, but `Requests` recorded only 2 of at least 15 requests
// in that session, so the alert never fired. ContainerAppHTTPLogs (the ingress's per-request log) recorded every one,
// so the alert is now a log search alert on that table. It also sees 502/504s that the ingress itself returns.
//
// Ingestion delay: a request's row is stamped with its start time and arrives in the workspace after it finishes
// (the failing requests took 200 seconds). A 15-minute window evaluated every 5 minutes still counts rows that land
// late. Cost: about $1.50/month for a rule that runs all month at a 5-minute frequency; this one exists only during a
// session.
targetScope = 'resourceGroup'

@description('Region for the alert rule (log search alert rules are regional)')
param location string

@description('Standard Larkspur tags')
param tags object

@description('Name of the tracking API container app')
param apiName string

@description('Resource group that holds the persistent action group and Log Analytics workspace')
param dataResourceGroupName string

@description('Action group that receives Larkspur alerts')
param actionGroupName string

@description('Log Analytics workspace that receives the Container Apps logs')
param logAnalyticsWorkspaceName string

@description('Alert when the API returns at least this many 5xx responses within the window')
param errorThreshold int = 5

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' existing = {
  name: actionGroupName
  scope: resourceGroup(dataResourceGroupName)
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: resourceGroup(dataResourceGroupName)
}

resource api5xxAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-lark-api-5xx'
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'alert-lark-api-5xx'
    description: 'The tracking API returned ${errorThreshold} or more 5xx responses in 15 minutes (ContainerAppHTTPLogs). Check /readyz and ContainerAppConsoleLogs.'
    severity: 1
    enabled: true
    scopes: [
      workspace.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: 'ContainerAppHTTPLogs\n| where ContainerAppName == "${apiName}" and StatusCode >= 500'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: errorThreshold
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output apiAlertName string = api5xxAlert.name
