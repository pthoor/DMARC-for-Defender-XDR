# DMARC Analyzer Azure Runbook

## Scope

Operational triage and recovery procedures for the DMARC ingestion pipeline.

## Quick Triage Checklist

1. Check Function App health (failures, exceptions, trigger activity).
2. Verify Graph subscription exists and has future expiration.
3. Confirm mailbox ingestion path (unread report backlog, mailbox quota).
4. Validate DCR/API ingestion path and throttling signals.
5. Confirm Event Grid delivery and dead-letter behavior.
6. Decide whether catch-up or backfill is required.

## Scenario: Graph subscription expired or missing

Symptoms:
- No new records in DMARCReports_CL.
- RenewGraphSubscription logs report 404 for subscription ID.

Actions:
1. Read current app setting GRAPH_SUBSCRIPTION_ID.
2. Run scripts/New-GraphSubscription.ps1 (or .sh) to recreate the subscription.
3. Verify partner topic is activated and event subscription exists.
4. Confirm RenewGraphSubscription timer logs successful renewals.
5. Run CatchupProcessor (or BackfillProcessor with small days window) to ingest missed reports.

Validation query:
```kusto
DMARCReports_CL
| where TimeGenerated > ago(2h)
| summarize Records=count(), DistinctReports=dcount(ReportId)
```

## Scenario: DCR throttling or Logs Ingestion retries

Symptoms:
- Function warnings for 429/503 and retries.
- Lag between mailbox arrival and LAW visibility.

Actions:
1. Check AppExceptions/AppTraces for repeated 429/503 signals.
2. Confirm DCR endpoint and immutable ID app settings are correct.
3. Verify Monitoring Metrics Publisher role assignment on DCR for MI principal.
4. If sustained, reduce burst load (smaller backfill windows) and retry later.

Validation query:
```kusto
AppTraces
| where TimeGenerated > ago(6h)
| where Message has_any ("429", "503", "retrying")
| project TimeGenerated, Message
| order by TimeGenerated desc
```

## Scenario: Mailbox full or report backlog

Symptoms:
- Graph notifications continue but processing slows.
- Large unread mailbox count.

Actions:
1. Measure unread message volume in target mailbox.
2. Run CatchupProcessor to process unread messages older than safety window.
3. If backlog is high, run BackfillProcessor in smaller date ranges.
4. Confirm message marking behavior (processed messages become read).

## Scenario: Function failures or runtime regressions

Symptoms:
- Spikes in AppExceptions.
- DmarcReportProcessor invocation failures.

Actions:
1. Review latest AppExceptions stack traces.
2. Check for recent deployment/version changes.
3. Execute scripts/Test-DmarcDeployment.ps1 for environment validation.
4. If needed, redeploy known-good function package and re-run smoke tests.

## Scenario: accidental mass backfill

Symptoms:
- Sudden DMARCReports_CL ingestion spike.
- Duplicate report-key ratio alert triggers.

Actions:
1. Stop further backfill triggers.
2. Confirm whether includeRead=true was used and for how many days.
3. Use DuplicateTelemetryKey and run metadata to estimate replay scope.
4. Communicate expected noise window to SOC.
5. If necessary, filter replay interval in detections/workbook views during cleanup.

Validation query:
```kusto
DMARCReports_CL
| where TimeGenerated > ago(24h)
| summarize DistinctRuns=dcount(IngestionRunId), DistinctKeys=dcount(DuplicateTelemetryKey)
```

## ClientState rotation (zero-event-loss procedure)

Goal: rotate GRAPH_CLIENT_STATE without dropping legitimate notifications.

Procedure:
1. Generate a new random clientState value.
2. Save as new Key Vault secret version for graph-client-state.
3. Wait for Function App Key Vault reference refresh to resolve new value.
4. Immediately recreate Graph subscription using scripts/New-GraphSubscription.ps1.
5. Confirm DmarcReportProcessor accepts notifications with new clientState.
6. Run CatchupProcessor once to cover any short transition gap.

Notes:
- Do not rotate by changing only Function App setting while keeping old subscription alive.
- Keep rotation during low-volume windows.

## Escalation data to collect

- Time window and impacted domains.
- Function App name, resource group, deployment version.
- Graph subscription ID and expiration timestamp.
- Recent AppExceptions/AppTraces excerpts.
- DCR endpoint, immutable ID, and role assignment check results.
