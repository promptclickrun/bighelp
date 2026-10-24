// bighelp telemetry storage, alerts and workbook. Deploy by hand into rg-bighelp-telemetry; see README.md.
// Nothing here outputs the Application Insights connection string. Read it with `az monitor app-insights
// component show` when you set the Worker secret.

targetScope = 'resourceGroup'

@description('Azure region. The resource group and every resource below use it.')
param location string = 'centralus'

@description('Email address that gets every alert. There is no default on purpose.')
@minLength(3)
param alertEmail string

@description('Optional webhook that posts alerts to the bighelp Feed. Leave empty for email only.')
@secure()
param alertWebhookUrl string = ''

@description('Daily ingestion cap for the Log Analytics workspace, in GB.')
@minValue(1)
param dailyQuotaGb int = 1

@description('How long Log Analytics and Application Insights keep telemetry, in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Turn all alert rules off without deleting them.')
param alertsEnabled bool = true

var workspaceName = 'law-bighelp'
var appInsightsName = 'appi-bighelp'
var actionGroupName = 'ag-bighelp'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Workspace-based. IP masking stays on (DisableIpMasking false), so Azure would not keep a client address
// even if one reached it. The Worker also sends 0.0.0.0. Local auth stays on because the Worker ingests with
// the connection string's instrumentation key; Microsoft Entra ingestion would need a token in the Worker.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    RetentionInDays: retentionInDays
    DisableIpMasking: false
    DisableLocalAuth: false
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: 'bighelp'
    enabled: true
    emailReceivers: [
      {
        name: 'owner'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
    webhookReceivers: empty(alertWebhookUrl) ? [] : [
      {
        name: 'feed'
        serviceUri: alertWebhookUrl
        useCommonAlertSchema: true
      }
    ]
  }
}

// Plan section 8. Every query returns rows only while the condition holds, and each rule fires when any row
// comes back. Events are in customEvents: the event name is `name`, numbers are in customMeasurements,
// strings are in customDimensions, and the install or host ID is user_Id.
//
// Interpretations (see README.md):
// - Push latency and failures look at direct sends only. BuzzKit sends stay about 10 s late until cutover.
// - Each rule needs a minimum number of samples, so one slow push does not page anyone.
// - The baseline rules ask for 7 days of history. Azure caps a rule window at 2 days, so the baseline may be
//   the last 2 days. The workbook shows the full 7 days.
var alertRules = [
  {
    id: 'push-latency'
    displayName: 'bighelp push latency'
    description: 'p95 of notification.received delayMs is over 6 seconds for 15 minutes (direct sends, at least 5 samples).'
    severity: 2
    frequency: 'PT5M'
    window: 'PT15M'
    query: '''
customEvents
| where timestamp > ago(15m) and name == "notification.received"
| where tostring(customDimensions.path) == "direct"
| extend delayMs = todouble(customMeasurements.delayMs)
| where isnotnull(delayMs)
| summarize samples = count(), p95Ms = percentile(delayMs, 95)
| where samples >= 5 and p95Ms > 6000
'''
  }
  {
    id: 'push-failures'
    displayName: 'bighelp push failures'
    description: 'More than 5 percent of direct push.sent events had a status other than 200 in 15 minutes (at least 10 sends).'
    severity: 1
    frequency: 'PT5M'
    window: 'PT15M'
    query: '''
customEvents
| where timestamp > ago(15m) and name == "push.sent"
| where tostring(customDimensions.path) == "direct"
| summarize total = count(), failed = countif(todouble(customMeasurements.status) != 200)
| extend failedPercent = failed * 100.0 / total
| where total >= 10 and failedPercent > 5
'''
  }
  {
    id: 'push-dlq'
    displayName: 'bighelp push dead-letter'
    description: 'A push landed in the dead-letter queue in the last 15 minutes.'
    severity: 1
    frequency: 'PT5M'
    window: 'PT15M'
    query: '''
customEvents
| where timestamp > ago(15m) and name == "push.dlq"
| summarize dlq = count()
'''
  }
  {
    id: 'crash-spike'
    displayName: 'bighelp crash spike'
    description: 'Crashes in the last hour are more than 3 times the hourly average of the previous 7 days (at least 4).'
    severity: 1
    frequency: 'PT15M'
    window: 'P2D'
    query: '''
let baselinePerHour = toscalar(
    customEvents
    | where timestamp between (ago(7d) .. ago(1h)) and name == "crash"
    | summarize crashes = count()
    | extend perHour = todouble(crashes) / (7.0 * 24.0 - 1.0)
    | project perHour);
customEvents
| where timestamp > ago(1h) and name == "crash"
| summarize crashes = count()
| extend baseline = coalesce(baselinePerHour, 0.0)
| where crashes >= 4 and crashes > 3.0 * baseline
'''
  }
  {
    id: 'host-turn-latency'
    displayName: 'bighelp host turn latency'
    description: 'p95 time to first token of host turns in the last hour is over 2 times the p95 of the previous 7 days (at least 10 turns).'
    severity: 2
    frequency: 'PT15M'
    window: 'P2D'
    query: '''
let baselineP95 = toscalar(
    customEvents
    | where timestamp between (ago(7d) .. ago(1h)) and name == "turn.completed"
    | extend firstTokenMs = todouble(customMeasurements.firstTokenMs)
    | where isnotnull(firstTokenMs)
    | summarize p95Ms = percentile(firstTokenMs, 95));
customEvents
| where timestamp > ago(1h) and name == "turn.completed"
| extend firstTokenMs = todouble(customMeasurements.firstTokenMs)
| where isnotnull(firstTokenMs)
| summarize turns = count(), p95Ms = percentile(firstTokenMs, 95)
| where turns >= 10 and isnotnull(baselineP95) and p95Ms > 2.0 * baselineP95
'''
  }
  {
    id: 'ingestion-stalled'
    displayName: 'bighelp ingestion stalled'
    description: 'No app.opened event arrived in 2 hours. The query always returns one row and the rule fires when its count is 0.'
    severity: 2
    frequency: 'PT15M'
    window: 'PT2H'
    query: '''
customEvents
| where timestamp > ago(2h) and name == "app.opened"
| summarize opens = count()
| where opens == 0
'''
  }
]

resource alerts 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = [for rule in alertRules: {
  name: 'alert-bighelp-${rule.id}'
  location: location
  properties: {
    displayName: rule.displayName
    description: rule.description
    enabled: alertsEnabled
    severity: rule.severity
    evaluationFrequency: rule.frequency
    windowSize: rule.window
    scopes: [
      appInsights.id
    ]
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: rule.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
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
}]

// Workbook: one tab-less page, one section per question from plan section 5.
var workbookTimeRange = {
  type: 4
  name: 'timeRange'
  label: 'Time range'
  isRequired: true
  value: {
    durationMs: 604800000
  }
  typeSettings: {
    selectableValues: [
      { durationMs: 86400000 }
      { durationMs: 259200000 }
      { durationMs: 604800000 }
      { durationMs: 2592000000 }
      { durationMs: 7776000000 }
    ]
  }
  timeContext: {
    durationMs: 86400000
  }
}

var workbookPanels = [
  {
    title: 'Push legs: how late does a push arrive (direct sends, ms)'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "notification.received"
| extend path = tostring(customDimensions.path), delayMs = todouble(customMeasurements.delayMs), hostToPhoneMs = todouble(customMeasurements.hostToPhoneMs)
| summarize workerToPhoneP50 = percentile(delayMs, 50), workerToPhoneP95 = percentile(delayMs, 95), hostToPhoneP50 = percentile(hostToPhoneMs, 50), hostToPhoneP95 = percentile(hostToPhoneMs, 95) by bin(timestamp, 1h), path
'''
  }
  {
    title: 'Push legs: host to Worker and APNs call (ms)'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "push.sent"
| extend path = tostring(customDimensions.path)
| summarize hostToWorkerP50 = percentile(todouble(customMeasurements.hostToWorkerMs), 50), hostToWorkerP95 = percentile(todouble(customMeasurements.hostToWorkerMs), 95), providerP50 = percentile(todouble(customMeasurements.providerMs), 50), providerP95 = percentile(todouble(customMeasurements.providerMs), 95) by bin(timestamp, 1h), path
'''
  }
  {
    title: 'Push failures by result'
    visualization: 'barchart'
    query: '''
customEvents
| where name in ("push.sent", "push.token_invalid", "push.retry", "push.dlq", "push.fallback_buzzkit")
| extend result = coalesce(tostring(customDimensions.result), tostring(customDimensions.reason), "none"), status = tostring(toint(customMeasurements.status))
| summarize events = count() by name, result, status
| order by events desc
'''
  }
  {
    title: 'Daily active installs (DAU) and weekly active installs (WAU)'
    visualization: 'timechart'
    query: '''
let dau = customEvents
    | where name == "app.opened"
    | summarize dailyActive = dcount(user_Id) by day = bin(timestamp, 1d);
let wau = customEvents
    | where name == "app.opened"
    | summarize weeklyActive = dcount(user_Id) by day = bin(timestamp, 7d);
dau
| join kind=leftouter wau on day
| project day, dailyActive, weeklyActive
| order by day asc
'''
  }
  {
    title: 'App versions in use (installs that opened the app)'
    visualization: 'barchart'
    query: '''
customEvents
| where name == "app.opened"
| extend appVersion = tostring(customDimensions.appVersion), build = tostring(customDimensions.build), channel = tostring(customDimensions.channel)
| summarize installs = dcount(user_Id) by appVersion, build, channel
| order by installs desc
'''
  }
  {
    title: 'Launch time (median ms by kind)'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "perf.launch"
| extend kind = tostring(customDimensions.kind), medianMs = todouble(customMeasurements.medianMs)
| summarize p50 = percentile(medianMs, 50), p95 = percentile(medianMs, 95) by bin(timestamp, 1d), kind
'''
  }
  {
    title: 'Hangs per day'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "hang"
| extend appVersion = tostring(customDimensions.appVersion)
| summarize hangs = count(), p95DurationMs = percentile(todouble(customMeasurements.durationMs), 95) by bin(timestamp, 1d), appVersion
'''
  }
  {
    title: 'Crashes per day'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "crash"
| extend appVersion = tostring(customDimensions.appVersion)
| summarize crashes = count() by bin(timestamp, 1d), appVersion
'''
  }
  {
    title: 'Host turn latency (ms)'
    visualization: 'timechart'
    query: '''
customEvents
| where name == "turn.completed"
| extend sessionSource = tostring(customDimensions.sessionSource)
| summarize firstTokenP50 = percentile(todouble(customMeasurements.firstTokenMs), 50), firstTokenP95 = percentile(todouble(customMeasurements.firstTokenMs), 95), durationP95 = percentile(todouble(customMeasurements.durationMs), 95) by bin(timestamp, 1d), sessionSource
'''
  }
]

var workbookItems = concat(
  [
    {
      type: 9
      name: 'parameters'
      content: {
        version: 'KqlParameterItem/1.0'
        parameters: [
          workbookTimeRange
        ]
      }
    }
  ],
  map(workbookPanels, panel => {
    type: 3
    name: panel.title
    content: {
      version: 'KqlItem/1.0'
      title: panel.title
      query: panel.query
      size: 1
      timeContext: {
        durationMs: 0
      }
      timeContextFromParameter: 'timeRange'
      queryType: 0
      resourceType: 'microsoft.insights/components'
      visualization: panel.visualization
    }
  })
)

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'bighelp-health')
  location: location
  kind: 'shared'
  properties: {
    displayName: 'bighelp-health'
    category: 'workbook'
    sourceId: appInsights.id
    serializedData: string({
      version: 'Notebook/1.0'
      items: workbookItems
      fallbackResourceIds: [
        appInsights.id
      ]
      '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
    })
  }
}

output appInsightsId string = appInsights.id
output workspaceId string = workspace.id
output actionGroupId string = actionGroup.id
