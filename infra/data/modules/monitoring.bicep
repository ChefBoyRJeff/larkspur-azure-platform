// Persistent alerting for the platform (M6). Lives in rg-lark-data because these watch persistent resources and must
// survive every session's teardown. The API's 5xx alert watches a resource that's rebuilt each session, so it's
// deployed with the app stack instead (infra/app) and uses the action group defined here.
//
// Cost: the SQL metric alert is one monitored time series (the first 10 per month are free); activity log alerts,
// including Resource Health, are free; the first 1,000 emails per month are free.
targetScope = 'resourceGroup'

@description('Standard Larkspur tags')
param tags object

@description('Email that receives alerts. Supplied from the gitignored local parameter file; @secure() keeps it out of deployment history.')
@secure()
param alertEmail string

@description('SQL server name (from the sql module)')
param sqlServerName string

@description('SQL database name (from the sql module)')
param sqlDatabaseName string

@description('Alert when the free tier has fewer vCore-seconds left this month than this (10,000 = 10% of 100,000)')
param freeAmountThreshold int = 10000

resource server 'Microsoft.Sql/servers@2023-08-01' existing = {
  name: sqlServerName
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01' existing = {
  parent: server
  name: sqlDatabaseName
}

// One place every Larkspur alert sends to. Action groups are global resources.
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-lark-ops'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'larkops'
    enabled: true
    emailReceivers: [
      {
        name: 'platform-owner'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// The free tier pauses the database for the rest of the month when its 100,000 vCore-seconds run out (that's the
// option I chose, so it can never bill). Microsoft's guidance: alert below 10,000 so I know before that happens.
// The metric is only published every 15 minutes or more, so the rule checks hourly.
resource sqlFreeAmountAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-lark-sql-free-amount'
  location: 'global'
  tags: tags
  properties: {
    description: 'sqldb-lark-tracking has less than 10% of its monthly free vCore-seconds left; the database pauses until next month when they run out.'
    severity: 2
    enabled: true
    scopes: [
      database.id
    ]
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FreeAmountRemaining'
          metricNamespace: 'Microsoft.Sql/servers/databases'
          metricName: 'free_amount_remaining'
          operator: 'LessThan'
          threshold: freeAmountThreshold
          timeAggregation: 'Minimum'
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

// Azure-side outages of the data tier (SQL, Key Vault): platform-initiated Degraded or Unavailable health events.
// Free. Filtering on PlatformInitiated keeps my own actions (and the free tier's auto-pause) from paging me.
resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: 'alert-lark-data-resource-health'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure reports a platform-initiated health problem with a resource in rg-lark-data.'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          field: 'properties.cause'
          equals: 'PlatformInitiated'
        }
        {
          anyOf: [
            {
              field: 'properties.currentHealthStatus'
              equals: 'Degraded'
            }
            {
              field: 'properties.currentHealthStatus'
              equals: 'Unavailable'
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

output actionGroupName string = actionGroup.name
output actionGroupId string = actionGroup.id
output sqlFreeAmountAlertName string = sqlFreeAmountAlert.name
output resourceHealthAlertName string = resourceHealthAlert.name
