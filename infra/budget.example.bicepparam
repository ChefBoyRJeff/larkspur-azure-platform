using './budget.bicep'
param budgetName = 'budget-larkspur-platform'
param amount = 5
param startDate = '2026-11-01T00:00:00Z'
param endDate = '2036-11-01T00:00:00Z'
param resourceGroupNames = ['rg-lark-data', 'rg-lark-app']
param alertEmail = 'you@example.com'
