# Architecture

## Data Flow

```
DMARC Aggregate Reports (ZIP/GZ containing XML)
  │ SMTP delivery
  ▼
Exchange Online Shared Mailbox
  │ Microsoft Graph Change Notification
  ▼
Azure Event Grid (Partner Topic)
  │ Event Subscription (CloudEvents v1.0)
  ▼
Azure Function: DmarcReportProcessor (Event Grid trigger)
  ├─ Graph API → Fetch message + attachments (Managed Identity token)
  ├─ Decompress ZIP/GZ → Extract XML
  ├─ Parse DMARC XML → Flat records (one per <record> element)
  ├─ Logs Ingestion API → POST to DCR endpoint (Managed Identity token)
  └─ Graph API → Mark message as read
  │
  ▼
Log Analytics Workspace (DMARCReports_CL custom table)
  │
  ├──▶ Azure Monitor Workbook (5 tabs, 45+ visualizations)
  ├──▶ Azure Monitor Alert Rules (optional, deployed via alerts.bicep)
  └──▶ Defender XDR Custom Detection Rules (YAML in detections/)
```

## Functions

| Function | Trigger | Purpose |
|---|---|---|
| `DmarcReportProcessor` | Event Grid | Real-time processing of new DMARC reports |
| `RenewGraphSubscription` | Timer (every 2h) | Keeps Graph subscription alive (max 4230 min) |
| `CatchupProcessor` | Timer (daily 06:00 UTC) | Processes any missed unread reports (paged) |
| `BackfillProcessor` | HTTP (admin) | On-demand import of historical DMARC reports |
| `SetupHelper` | HTTP (admin) | Called by setup script to create Graph subscription via MI |

## Authentication & Security

**No app registration or client secrets.** The Function App uses a **system-assigned Managed Identity** for all API calls:

- **Microsoft Graph**: MI is granted `Mail.Read` + `Mail.ReadWrite` app roles, scoped to the DMARC shared mailbox only via Exchange Online Application RBAC (Management Scope).
- **Logs Ingestion API**: MI is granted `Monitoring Metrics Publisher` role on the DCR via Azure RBAC.
- **Azure Key Vault**: MI is granted `Key Vault Secrets User` role to read secrets (such as the Graph client state validation token) via Azure RBAC.

### Secret Management

The `graphClientState` secret (used to validate Graph change notifications) is managed securely:

1. **At deployment time**: The secret is provided via the `GRAPH_CLIENT_STATE` environment variable and read by the `.bicepparam` file using `readEnvironmentVariable()`. This prevents the secret from being stored in source control or parameter files.
2. **In Azure**: The secret is stored in **Azure Key Vault** and referenced in Function App settings using Key Vault references (`@Microsoft.KeyVault(SecretUri=...)`). This ensures the secret is never stored as plain text in application settings.
3. **At runtime**: The `SetupHelper` function reads the resolved secret from the `GRAPH_CLIENT_STATE` environment variable — no Key Vault access from scripts needed.

> **Tip**: Generate the secret safely without it appearing in PowerShell audit logs:
> ```powershell
> $env:GRAPH_CLIENT_STATE = [guid]::NewGuid().ToString()
> ```

### Exchange Application RBAC (replaces Application Access Policies)

Instead of the legacy Application Access Policy (which is being deprecated), this solution uses the modern Exchange Online Application RBAC:

1. A **Management Scope** restricts access to the DMARC shared mailbox only.
2. **Application roles** (`Application Mail.Read`, `Application Mail.ReadWrite`) are assigned to the MI's service principal, scoped to the management scope.
3. The MI **cannot access any other mailbox** in the tenant.

## Graph Change Notifications via Event Grid

Uses Event Grid as the delivery mechanism (not webhooks):

- No public webhook endpoint to validate or secure
- Built-in retry logic (up to 24 hours)
- Dead-letter storage for failed deliveries
- Partner topic auto-created by the Graph subscription
- Partner configuration deployed via Bicep (no manual Portal authorization needed)
- Partner topic activation and event subscription handled by `New-GraphSubscription.ps1`

The Graph subscription watches: `users/{mailboxUserId}/mailFolders('Inbox')/messages`

## Log Analytics Schema

The `DMARCReports_CL` table uses a flat schema — one row per `<record>` element in the DMARC XML. Report metadata and policy are repeated across records from the same report.

### Columns (32)

| Column | Type | Source |
|---|---|---|
| TimeGenerated | datetime | Ingestion time |
| ReportOrgName | string | `report_metadata/org_name` |
| ReportEmail | string | `report_metadata/email` |
| ReportExtraContactInfo | string | `report_metadata/extra_contact_info` |
| ReportId | string | `report_metadata/report_id` |
| ReportDateRangeBegin | datetime | `report_metadata/date_range/begin` (epoch→ISO) |
| ReportDateRangeEnd | datetime | `report_metadata/date_range/end` (epoch→ISO) |
| Domain | string | `policy_published/domain` |
| PolicyPublished_p | string | `policy_published/p` |
| PolicyPublished_sp | string | `policy_published/sp` |
| PolicyPublished_pct | int | `policy_published/pct` |
| PolicyPublished_adkim | string | `policy_published/adkim` |
| PolicyPublished_aspf | string | `policy_published/aspf` |
| PolicyPublished_fo | string | `policy_published/fo` |
| SourceIP | string | `record/row/source_ip` |
| MessageCount | int | `record/row/count` |
| PolicyEvaluated_disposition | string | `record/row/policy_evaluated/disposition` |
| PolicyEvaluated_dkim | string | `record/row/policy_evaluated/dkim` |
| PolicyEvaluated_spf | string | `record/row/policy_evaluated/spf` |
| PolicyEvaluated_reason_type | string | `record/row/policy_evaluated/reason/type` |
| PolicyEvaluated_reason_comment | string | `record/row/policy_evaluated/reason/comment` |
| HeaderFrom | string | `record/identifiers/header_from` |
| EnvelopeFrom | string | `record/identifiers/envelope_from` |
| EnvelopeTo | string | `record/identifiers/envelope_to` |
| DkimResult | string | First `auth_results/dkim/result` |
| DkimDomain | string | First `auth_results/dkim/domain` |
| DkimSelector | string | First `auth_results/dkim/selector` |
| SpfResult | string | First `auth_results/spf/result` |
| SpfDomain | string | First `auth_results/spf/domain` |
| SpfScope | string | First `auth_results/spf/scope` |
| DkimAuthResults | string | Full DKIM results as JSON array |
| SpfAuthResults | string | Full SPF results as JSON array |

## Cost Estimate (typical mid-size org)

| Resource | Monthly Cost |
|---|---|
| Azure Function (Consumption plan) | ~$0 (1M executions/month free) |
| Event Grid | ~$0 (100K operations/month free) |
| Log Analytics (~100-300 MB/month) | ~$0 (5 GB/month free) |
| Storage Account | ~$0.01 |
| Key Vault (1 secret + <1K operations/month) | ~$0.03 |
| **Total** | **~$0.04** |
