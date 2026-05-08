// ──────────────────────────────────────────────────────────────
// DMARC Analyzer — Azure Monitor Scheduled Query Alert Rules
// Monitors the DMARCReports_CL table for anomalies and failures.
// ──────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

// ── Parameters ──

@description('Azure region for all resources.')
param location string

@description('Resource ID of the Log Analytics workspace containing DMARCReports_CL.')
param workspaceId string

@description('Resource ID of an Action Group for alert notifications. Leave empty to create alerts without notifications.')
param actionGroupId string = ''

@description('DMARC pass rate percentage threshold. An alert fires when the pass rate drops below this value.')
@minValue(1)
@maxValue(100)
param passRateThreshold int = 90

@description('Whether the alert rules are enabled.')
param enabled bool = true

// ── Variables ──

var alertEnabled = enabled ? 'true' : 'false'

var actionGroups = empty(actionGroupId) ? [] : [
  actionGroupId
]

// ── Alert 1: DMARC Pass Rate Drop ──

resource passRateDropAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'dmarc-pass-rate-drop'
  location: location
  properties: {
    displayName: 'DMARC Pass Rate Drop'
    description: 'Triggers when the overall DMARC pass rate (at least SPF or DKIM passing) drops below ${passRateThreshold}% over the last 24 hours. A sustained drop may indicate a misconfiguration, a new unauthorized sender, or an active spoofing campaign.'
    severity: 2
    enabled: alertEnabled == 'true'
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
DMARCReports_CL
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize
    TotalMessages = sum(MessageCountSafe),
    PassedMessages = sumif(MessageCountSafe, PolicyEvaluated_dkim == "pass" or PolicyEvaluated_spf == "pass")
| extend PassRate = iff(TotalMessages == 0, 100.0, round(toreal(PassedMessages) / toreal(TotalMessages) * 100, 2))
| where PassRate < ${passRateThreshold}
'''
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
      actionGroups: actionGroups
    }
    autoMitigate: true
  }
}

// ── Alert 2: No Reports Received ──

resource noReportsAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'dmarc-no-reports-received'
  location: location
  properties: {
    displayName: 'No DMARC Reports Received'
    description: 'Triggers when no DMARC reports have been ingested into the DMARCReports_CL table for 48 or more hours. This may indicate a problem with the mail flow, the Function App processing pipeline, or the data collection rule.'
    severity: 1
    enabled: alertEnabled == 'true'
    evaluationFrequency: 'P1D'
    windowSize: 'P2D'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
DMARCReports_CL
| summarize ReportCount = count()
| where ReportCount == 0
'''
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
      actionGroups: actionGroups
    }
    autoMitigate: true
  }
}

// ── Alert 3: New Source IP with High Failure Rate ──

resource newSourceIpFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'dmarc-new-source-ip-high-failure'
  location: location
  properties: {
    displayName: 'New Source IP with High Failure Rate'
    description: 'Triggers when a source IP address not seen in the previous 30 days appears with both SPF and DKIM failing and at least 10 failed messages. This pattern often indicates a new unauthorized sender or spoofing attempt targeting your domain.'
    severity: 2
    enabled: alertEnabled == 'true'
    evaluationFrequency: 'PT6H'
    windowSize: 'P1D'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
let lookbackStart = ago(31d);
let lookbackEnd = ago(1d);
let knownIPs = DMARCReports_CL
    | where TimeGenerated between (lookbackStart .. lookbackEnd)
    | distinct SourceIP;
DMARCReports_CL
| where TimeGenerated >= ago(1d)
| where PolicyEvaluated_dkim != "pass" and PolicyEvaluated_spf != "pass"
| where SourceIP !in (knownIPs)
| summarize FailedMessages = sum(MessageCount) by SourceIP, Domain
| where FailedMessages >= 10
'''
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
      actionGroups: actionGroups
    }
    autoMitigate: true
  }
}

// ── Alert 4: Sudden Volume Spike ──

resource volumeSpikeAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'dmarc-volume-spike'
  location: location
  properties: {
    displayName: 'DMARC Sudden Volume Spike'
    description: 'Triggers when the daily DMARC report message volume exceeds 3x the average daily volume over the previous 30 days. A sudden spike may indicate a large-scale spoofing campaign, a mail loop, or an unexpected configuration change.'
    severity: 3
    enabled: alertEnabled == 'true'
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
let baselineStart = ago(31d);
let baselineEnd = ago(1d);
let baseline = DMARCReports_CL
    | where TimeGenerated between (baselineStart .. baselineEnd)
    | extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
    | summarize DailyVolume = sum(MessageCountSafe) by bin(TimeGenerated, 1d)
    | summarize AvgDailyVolume = avg(DailyVolume);
let todayVolume = DMARCReports_CL
    | where TimeGenerated >= ago(1d)
    | extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
    | summarize TodayVolume = sum(MessageCountSafe);
baseline
| extend JoinKey = 1
| join kind=inner (todayVolume | extend JoinKey = 1) on JoinKey
| where TodayVolume > AvgDailyVolume * 3 and AvgDailyVolume > 0
'''
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
      actionGroups: actionGroups
    }
    autoMitigate: true
  }
}
