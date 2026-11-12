// larkspur-azure-platform, M0: cost guardrail before anything billable exists.
// Subscription-scope budget filtered to the platform's resource groups.
//
// Pattern reused from azure-backup-dr-lab / azure-compute-hosting-lab:
// - Code instead of the portal: the portal's resource-group filter only lists groups that already have cost data,
//   so brand-new (or not-yet-created) groups can't be selected. The API accepts the names directly.
// - Resource-group filter instead of a tag filter: some resources Azure creates for us (for example the Container
//   Apps managed infrastructure group) don't inherit our tags.
targetScope = 'subscription'

@description('Budget name')
param budgetName string = 'budget-larkspur-platform'

@description('Monthly budget amount in the billing currency (USD)')
@minValue(1)
param amount int = 5

// Fixed dates, not utcNow(): what-if can't evaluate utcNow(), and next month the expression would try to move an
// existing budget's start date. endDate equals Azure's default (start + 10 years) so what-if reports NoChange.
@description('First day of the budget period (must be the first of a month)')
param startDate string = '2026-11-01T00:00:00Z'

@description('Budget end date (Azure\'s default when none is given: start + 10 years)')
param endDate string = '2036-11-01T00:00:00Z'

@description('Resource groups whose cost counts toward this budget')
param resourceGroupNames array = [
  'rg-lark-data'
  'rg-lark-app'
]

@description('Email for budget alerts. Supplied from a gitignored *.local.bicepparam file; @secure() keeps it out of deployment history.')
@secure()
param alertEmail string

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
      endDate: endDate
    }
    filter: {
      dimensions: {
        name: 'ResourceGroupName'
        operator: 'In'
        values: resourceGroupNames
      }
    }
    notifications: {
      Actual_50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
      Actual_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
      Forecasted_100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: [
          alertEmail
        ]
      }
    }
  }
}

output budgetName string = budget.name
output filteredResourceGroups array = resourceGroupNames
