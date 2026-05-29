# DMARC Policy Progression Playbook

## Goal

Move domains safely from p=none to p=quarantine to p=reject without breaking legitimate mail.

## Stage gates

Readiness criteria before each promotion:
- Pass rate >= 98% over the last 14 days.
- No unclassified high-volume failing sources for 14 days.
- Legitimate sender inventory reviewed and approved.
- Rollback owner and communication plan confirmed.

## Sender approval checklist

1. Sender service owner identified.
2. SPF include/record validated.
3. DKIM signing enabled and passing.
4. HeaderFrom alignment verified.
5. Monitoring owner assigned for post-change period.

## Recommended pct ramp

Use this sequence for p=quarantine:
1. pct=10 for 3-7 days
2. pct=25 for 3-7 days
3. pct=50 for 3-7 days
4. pct=100 for 7-14 days

After stable p=quarantine at pct=100, move to p=reject.

## Evidence queries for each gate

### Pass rate by domain (14d)

```kusto
DMARCReports_CL
| where TimeGenerated > ago(14d)
| extend MessageCountSafe = tolong(coalesce(MessageCount, 0))
| summarize Total=sum(MessageCountSafe), Passed=sumif(MessageCountSafe, DmarcPass == true) by Domain
| extend PassRate = iff(Total > 0, round(100.0 * Passed / Total, 2), 0.0)
| sort by PassRate asc
```

### High-volume unknown failing sources

```kusto
DMARCReports_CL
| where TimeGenerated > ago(14d)
| where DmarcPass == false
| summarize FailedMessages=sum(tolong(coalesce(MessageCount,0))), Domains=make_set(Domain, 10) by SourceIP, SpfDomain
| where FailedMessages >= 100
| sort by FailedMessages desc
```

### Override reason concentration

```kusto
DMARCReports_CL
| where TimeGenerated > ago(14d)
| summarize Messages=sum(tolong(coalesce(MessageCount,0))) by Domain, OverrideReasonCategory
| order by Messages desc
```

## Rollback procedure

Trigger rollback if:
- Legitimate delivery failures are confirmed by domain owners.
- Sudden sustained pass-rate drop > 10 percentage points after policy change.

Rollback steps:
1. Revert DMARC TXT policy to previous stage (for example p=quarantine to p=none).
2. Keep rua reporting unchanged.
3. Capture failing sender examples and assign remediation owners.
4. Resume progression only after two stable reporting cycles.

## Operational cadence

- Weekly: review sender inventory and unknown failures.
- At each ramp step: monitor 24h, 72h, and 7d checkpoints.
- Monthly: review subdomain posture and stale selectors.
