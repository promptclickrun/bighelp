// Monthly cost budget for the subscription that holds rg-bighelp-telemetry, with alerts at 50 and 90 percent.
// This subscription runs on monthly credit with a spending limit: when the credit runs out, Azure disables
// the resources until the next cycle. Telemetry would stop, so the 90 percent alert is the one to watch.

targetScope = 'subscription'

@description('Monthly budget in the subscription currency. Use the size of the monthly credit.')
@minValue(1)
param amount int

@description('Email address that gets the budget alerts. There is no default on purpose.')
@minLength(3)
param alertEmail string

@description('Budget name.')
param budgetName string = 'bighelp-monthly'

@description('First day of the month the budget starts, as yyyy-MM-dd. Azure needs a first-of-month date, for example 2026-11-01.')
@minLength(10)
@maxLength(10)
param startDate string

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual_50_percent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
      actual_90_percent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 90
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
      }
    }
  }
}

output budgetId string = budget.id
