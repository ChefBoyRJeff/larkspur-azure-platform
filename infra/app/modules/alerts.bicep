// Session alerting for the app stack (M6). The API is rebuilt every session, so its alert is deployed and torn down
// with it; the action group it notifies is persistent in rg-lark-data (infra/data/modules/monitoring.bicep).
//
// Why a metric alert, not a log search alert: Container Apps publishes Requests (split by status code category) as a
// platform metric about a minute after the fact, while a new diagnostic setting can take up to 90 minutes to start
// delivering logs (M5). It's also cheaper: one monitored time series, inside the 10 free per month.
targetScope = 'resourceGroup'

@description('Standard Larkspur tags')
param tags object

@description('Name of the tracking API container app (deployed in this resource group by container-apps.bicep)')
param apiName string

@description('Resource group that holds the persistent action group')
param dataResourceGroupName string

@description('Action group that receives Larkspur alerts')
param actionGroupName string

@description('Alert when the API returns at least this many 5xx responses within the window')
param errorThreshold int = 5

resource api 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: apiName
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' existing = {
  name: actionGroupName
  scope: resourceGroup(dataResourceGroupName)
}

resource api5xxAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-lark-api-5xx'
  location: 'global'
  tags: tags
  properties: {
    description: 'The tracking API returned ${errorThreshold} or more 5xx responses in 5 minutes. Check /readyz and ContainerAppConsoleLogs.'
    severity: 1
    enabled: true
    scopes: [
      api.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'Api5xx'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'Requests'
          dimensions: [
            {
              name: 'statusCodeCategory'
              operator: 'Include'
              values: [
                '5xx'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: errorThreshold
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output apiAlertName string = api5xxAlert.name
