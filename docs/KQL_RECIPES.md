# KQL Recipes

Reusable queries for DMARCReports_CL.

## 1) Top failing source IPs (last 7d)

```kusto
DMARCReports_CL
| where TimeGenerated > ago(7d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| where DmarcPass == false
| summarize FailedMessages = sum(MessageCountSafe), Domains=dcount(Domain) by SourceIP
| where isnotempty(SourceIP)
| sort by FailedMessages desc
| take 50
```

## 2) Domain pass-rate trend (daily)

```kusto
DMARCReports_CL
| where TimeGenerated > ago(30d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize
    Total = sum(MessageCountSafe),
    Passed = sumif(MessageCountSafe, DmarcPass == true)
    by Domain, bin(TimeGenerated, 1d)
| extend PassRate = iff(Total > 0, round(100.0 * Passed / Total, 2), 0.0)
| sort by TimeGenerated asc
```

## 3) ESP breakdown by SPF domain

```kusto
DMARCReports_CL
| where TimeGenerated > ago(14d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize Messages = sum(MessageCountSafe), DistinctIPs=dcount(SourceIP) by SpfDomain
| where isnotempty(SpfDomain)
| sort by Messages desc
```

## 4) Override reason heatmap

```kusto
DMARCReports_CL
| where TimeGenerated > ago(30d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize Messages = sum(MessageCountSafe) by Domain, OverrideReasonCategory
| order by Messages desc
```

## 5) New failing senders in last 24h

```kusto
let known = DMARCReports_CL
| where TimeGenerated between (ago(14d) .. ago(1d))
| where isnotempty(SourceIP)
| distinct SourceIP;
DMARCReports_CL
| where TimeGenerated > ago(1d)
| where DmarcPass == false
| where isnotempty(SourceIP)
| where SourceIP !in (known)
| summarize FailedMessages=sum(tolong(coalesce(MessageCount,0))), Domains=make_set(Domain, 10) by SourceIP
| sort by FailedMessages desc
```

## 6) Duplicate telemetry keys across runs

```kusto
DMARCReports_CL
| where TimeGenerated > ago(7d)
| where isnotempty(DuplicateTelemetryKey)
| summarize DistinctRuns=dcount(IngestionRunId), Rows=count() by DuplicateTelemetryKey
| where DistinctRuns > 1
| sort by Rows desc
```

## 7) Top reporters by volume

```kusto
DMARCReports_CL
| where TimeGenerated > ago(30d)
| summarize Messages=sum(tolong(coalesce(MessageCount,0))) by ReportOrgName
| where isnotempty(ReportOrgName)
| sort by Messages desc
| take 20
```

## 8) Alignment drift by domain

```kusto
DMARCReports_CL
| where TimeGenerated > ago(14d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize
    Total = sum(MessageCountSafe),
    DkimAligned = sumif(MessageCountSafe, Aligned_dkim == true),
    SpfAligned = sumif(MessageCountSafe, Aligned_spf == true)
    by Domain
| extend
    DkimAlignRate = iff(Total > 0, round(100.0 * DkimAligned / Total, 2), 0.0),
    SpfAlignRate = iff(Total > 0, round(100.0 * SpfAligned / Total, 2), 0.0)
| sort by Total desc
```

## 9) High-risk domains with low pass rate

```kusto
DMARCReports_CL
| where TimeGenerated > ago(7d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize Total=sum(MessageCountSafe), Passed=sumif(MessageCountSafe, DmarcPass == true) by Domain
| extend PassRate = iff(Total > 0, round(100.0 * Passed / Total, 2), 0.0)
| where Total >= 100 and PassRate < 90
| sort by PassRate asc
```

## 10) Unexpected source countries (geo triage)

```kusto
DMARCReports_CL
| where TimeGenerated > ago(7d)
| where isnotempty(SourceIP)
| extend geo = geo_info_from_ip_address(SourceIP)
| extend Country = tostring(geo.country)
| summarize Messages=sum(tolong(coalesce(MessageCount,0))) by Domain, Country
| where isnotempty(Country)
| sort by Messages desc
```
