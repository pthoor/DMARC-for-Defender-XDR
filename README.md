# DMARC Analyzer Azure

Azure-native DMARC aggregate report analyzer using Azure Functions, Event Grid, and Log Analytics.

## Overview

This solution automatically processes **DMARC Aggregate Reports (RUA)** from your email infrastructure. It provides real-time analysis and visualization of email authentication results, helping you monitor SPF, DKIM, and DMARC compliance, detect spoofing attempts, and progress toward stricter DMARC policies.

### What are DMARC Reports?

DMARC (Domain-based Message Authentication, Reporting & Conformance) defines two types of reports:

#### RUA - Aggregate Reports (Supported ✓)

**This tool processes RUA (Aggregate Reports).**

RUA reports provide statistical summaries of email authentication results:
- **Content**: Aggregate authentication data including pass/fail counts, source IPs, SPF/DKIM/DMARC results, and policy disposition
- **Format**: XML files, typically compressed (ZIP/GZIP), sent as email attachments
- **Frequency**: Usually sent once per day by receiving mail servers (Google, Microsoft, Yahoo, etc.)
- **Volume**: One report per sending organization per day per domain
- **Use Case**: Monitoring overall email authentication health, identifying legitimate vs. unauthorized senders, policy tuning

To receive aggregate reports, configure the `rua=` tag in your DMARC DNS record:
```dns
_dmarc.example.com. IN TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com"
```

#### RUF - Forensic/Failure Reports (Not Supported)

**This tool does NOT process RUF (Forensic/Failure Reports).**

RUF reports provide per-message failure details:
- **Content**: Full headers and sometimes message bodies of individual failed messages
- **Format**: Various formats (ARF, AFRF), sent as individual emails per failure
- **Frequency**: Real-time, one report per authentication failure
- **Volume**: Can be very high for domains with many failures
- **Privacy Concerns**: Contains PII and message content, raising GDPR/privacy issues
- **Industry Trend**: Increasingly deprecated by major providers (Google stopped sending in 2023, Microsoft never implemented) due to privacy and volume concerns

**Recommendation**: Focus on `rua=` configuration only. RUF is largely obsolete and not necessary for DMARC monitoring and policy enforcement.

## Features

- **Real-time Processing**: Automatic ingestion via Microsoft Graph change notifications and Event Grid
- **Rich Analytics**: Azure Monitor Workbook with comprehensive visualizations
- **GeoIP Mapping**: Geographic distribution of email sources with pass/fail rates
- **Sender Identification**: Automatic service recognition via SPF domain matching (Microsoft 365, Google Workspace, SendGrid, Mailchimp, Salesforce, and 16 more)
- **Alignment Analysis**: Detect SPF/DKIM alignment failures with actionable fix guidance
- **Subdomain Discovery**: Track email from all subdomains, detect new subdomains, and flag policy gaps
- **Threat Detection**: Identify spoofing attempts, suspicious source IPs, and volume anomalies
- **Compliance Tracking**: Monitor SPF, DKIM, and DMARC pass rates per domain with policy health checks
- **Policy Guidance**: Built-in recommendations for DMARC policy progression with service-specific fix instructions
- **Proactive Alerting**: Optional Azure Monitor alert rules for pass rate drops, missing reports, stale reporters, duplicate report-key ratio, new threats, and volume spikes
- **Detection Rules**: Sentinel-compatible YAML detection rules for Defender XDR (importable via pipelines or XDRConverter)
- **Zero Secrets**: Uses Azure Managed Identity for authentication (no client secrets)
- **Privacy-first by design**: RUF forensic reports remain intentionally unsupported to avoid message-level PII processing
- **Scalable & Cost-Effective**: Serverless architecture, typically under $1/month

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture, data flow, and security model.

## Operational and Governance Docs

- [docs/RUNBOOK.md](docs/RUNBOOK.md) - incident response and recovery procedures
- [docs/PRIVACY.md](docs/PRIVACY.md) - data handling, retention, and compliance notes
- [docs/KQL_RECIPES.md](docs/KQL_RECIPES.md) - reusable investigation and reporting queries
- [docs/POLICY_PROGRESSION_PLAYBOOK.md](docs/POLICY_PROGRESSION_PLAYBOOK.md) - staged DMARC policy rollout guide
- [scripts/Test-DmarcDeployment.ps1](scripts/Test-DmarcDeployment.ps1) - post-deploy validation script

## Versioning and Release Metadata

This project uses **Semantic Versioning** (`MAJOR.MINOR.PATCH`) to support safe upgrades across multiple tenants.

- Source-of-truth version: [`VERSION`](VERSION)
- Release history: [`CHANGELOG.md`](CHANGELOG.md)
- Workbook release marker: `workbook/dmarc-workbook.json` header
- Workbook update check links: GitHub repository + latest releases link in workbook header
- Detection rule metadata: `detections/*.yaml` (`version:` field)

## Prerequisites

- Azure subscription with permissions to create resources
- Microsoft 365 tenant with Exchange Online
- A shared mailbox to receive DMARC reports (e.g., `dmarc@example.com`)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (>= 2.50)
- [PowerShell 7.4+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-linux) (for setup scripts)
  ```bash
  # Linux / Codespace
  sudo apt-get install -y powershell
  ```
- [Azure Functions Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local) v4 (`func` CLI for publishing)
  ```bash
  npm install -g azure-functions-core-tools@4 --unsafe-perm true
  ```
- PowerShell modules for Step 3 (install once):
  ```powershell
  Install-Module Az.Accounts -Scope CurrentUser -Force
  Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -Scope CurrentUser -Force
  Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
  ```

## Deployment

### 1. Deploy Azure Resources

First, authenticate and select the right subscription:

```bash
az login
az account set --subscription "<your-subscription-id>"
```

Then, set the required environment variables. The `.bicepparam` file uses `readEnvironmentVariable()` to keep secrets and tenant-specific values out of source control.

**PowerShell:**
```powershell
# Shared mailbox Object ID from Entra ID
$env:MAILBOX_USER_ID = '<your-mailbox-object-id>'

# Generates a random GUID in-memory — safe even with PowerShell Script Block Logging enabled
$env:GRAPH_CLIENT_STATE = [guid]::NewGuid().ToString()
```

**Bash:**
```bash
# Shared mailbox Object ID from Entra ID
export MAILBOX_USER_ID='<your-mailbox-object-id>'

export GRAPH_CLIENT_STATE=$(cat /proc/sys/kernel/random/uuid)
```

Then create a new resource group:

**PowerShell:**
```powershell
az group create --name "rg-dmarc-prod" --location "eastus"
```

**Bash:**
```bash
az group create --name "rg-dmarc-prod" --location "eastus"
```

Then deploy:

**PowerShell:**
```powershell
az deployment group create `
  --resource-group "rg-dmarc-prod" `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

**Bash:**
```bash
az deployment group create \
  --resource-group "rg-dmarc-prod" \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

Or use the Azure Portal to deploy `infra/main.bicep` with custom parameters.

**Key Parameters:**
- `baseName`: Base name for all resources (e.g., "dmarc")
- `location`: Azure region
- `mailboxUserId`: Object ID of the shared mailbox user (set via `MAILBOX_USER_ID` env var)
- `existingWorkspaceId`: (Optional) Use an existing Log Analytics Workspace
- `deployPartnerConfig`: (Optional, default `true`) Deploy Event Grid partner configuration for Microsoft Graph API. Set to `false` if you already have a partner configuration in the resource group.
- `deployAlerts`: (Optional, default `false`) Deploy Azure Monitor scheduled query alert rules for DMARC anomaly detection
- `alertActionGroupId`: (Optional) Resource ID of an Action Group to receive alert notifications

The Bicep deployment automatically authorizes Microsoft Graph API as an Event Grid partner — no manual Portal steps required.

### 2. Publish Function Code

Publish the function app code (including the `SetupHelper` function used in the next step):

```bash
cd src/function
func azure functionapp publish <function-app-name> --powershell
```

The function app name is shown in the Bicep deployment output as `functionAppName`.

### 3. Grant Exchange RBAC Permissions

Grant the Function's Managed Identity permissions to access the shared mailbox. **This must be done before creating the Graph subscription.**

Requires PowerShell modules: `Az.Accounts`, `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications`, `ExchangeOnlineManagement` (see Prerequisites).

**PowerShell:**
```powershell
./scripts/Grant-MIExchangeRBAC.ps1 `
  -FunctionAppName "dmarc-func-xyz123" `
  -ResourceGroupName "rg-dmarc-prod" `
  -MailboxAddress "dmarc@example.com"
```

This assigns Graph `Mail.Read`/`Mail.ReadWrite` app roles and creates an Exchange Application RBAC policy scoped to the DMARC mailbox only.

### 4. Create Graph Subscription

Run the setup script to create the Graph change notification subscription and wire up the Event Grid pipeline.

**PowerShell:**
```powershell
./scripts/New-GraphSubscription.ps1 `
  -FunctionAppName "dmarc-func-xyz123" `
  -ResourceGroupName "rg-dmarc-prod" `
  -SubscriptionId "11111111-1111-1111-1111-111111111111"
```

**Bash:**
```bash
./scripts/New-GraphSubscription.sh \
  --function-app "dmarc-func-xyz123" \
  --resource-group "rg-dmarc-prod" \
  --subscription "11111111-1111-1111-1111-111111111111"
```

The script automates:
1. Invokes the `SetupHelper` function (uses the MI to create the Graph subscription)
2. Waits for the Partner Topic, activates it, and creates an Event Subscription
3. Saves the subscription ID to the Function App settings

### 5. Import Existing DMARC Reports (Optional)

If the DMARC mailbox already contains reports (e.g., you had DNS configured before deploying this solution), you can import them using the `BackfillProcessor` function. This is an admin-secured HTTP endpoint — no public access.

**Retrieve the master host key securely via ARM and trigger the backfill:**

**PowerShell:**
```powershell
# Get the master key from ARM (no secrets in shell history)
$keys = az rest --method POST `
  --uri "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Web/sites/<function-app-name>/host/default/listkeys?api-version=2024-04-01" `
  --query masterKey -o tsv

# Import the last 7 days of unread messages
az rest --method POST `
  --url "https://<function-app-name>.azurewebsites.net/api/BackfillProcessor?days=7" `
  --headers "x-functions-key=$keys" `
  --skip-authorization-header
```

**Bash:**
```bash
# Get the master key from ARM
KEY=$(az rest --method POST \
  --uri "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Web/sites/<function-app-name>/host/default/listkeys?api-version=2024-04-01" \
  --query masterKey -o tsv)

# Import the last 7 days of unread messages
curl -s -X POST "https://<function-app-name>.azurewebsites.net/api/BackfillProcessor?days=7" \
  -H "x-functions-key: $KEY"
```

**Parameters:**

| Parameter | Default | Description |
|-----------|---------|-------------|
| `days` | `7` | How far back to look (1–365) |
| `includeRead` | `false` | Set to `true` to re-process already-read messages |

The function returns a JSON summary with `processed`, `failed`, and `skipped` counts. Messages are marked as read after processing, so running it twice is safe — already-processed messages are skipped by default.

> **Tip:** If you have more than 7 days of historical reports, increase the window: `?days=30&includeRead=true`

### 6. Configure DMARC DNS Records

Add or update the `_dmarc` TXT record for your domain to send reports to your shared mailbox.

**Recommended starting record:**
```dns
_dmarc.example.com. IN TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com; adkim=r; aspf=r; pct=100; fo=1"
```

#### DMARC Record Tags Explained

| Tag | Required | Example | Description |
|-----|----------|---------|-------------|
| `v` | Yes | `v=DMARC1` | Protocol version. Must be `DMARC1` and must be the first tag. |
| `p` | Yes | `p=none` | **Policy** for the domain. Tells receiving servers what to do with messages that fail DMARC. See [Policy Progression](#policy-progression) below. |
| `rua` | No* | `rua=mailto:dmarc@example.com` | **Aggregate report recipients.** Where to send daily XML reports. *Required for this solution to receive data.* Multiple addresses supported: `rua=mailto:a@example.com,mailto:b@example.com` |
| `sp` | No | `sp=none` | **Subdomain policy.** Overrides `p` for subdomains (e.g., `sub.example.com`). If omitted, subdomains inherit the `p` policy. Useful when you want a stricter policy on the root domain but need to monitor subdomains separately. |
| `adkim` | No | `adkim=r` | **DKIM alignment mode.** `r` = relaxed (default, recommended) — the DKIM signing domain can be a subdomain of the Header From domain. `s` = strict — must be an exact match. |
| `aspf` | No | `aspf=r` | **SPF alignment mode.** `r` = relaxed (default, recommended) — the envelope from domain can be a subdomain of the Header From domain. `s` = strict — must be an exact match. |
| `pct` | No | `pct=100` | **Percentage** of messages subject to the policy (1–100). Defaults to 100. Can be used to gradually roll out `quarantine` or `reject` (e.g., start with `pct=10` and increase). Has no effect when `p=none`. |
| `fo` | No | `fo=1` | **Failure reporting options.** `0` = report only if both SPF and DKIM fail (default). `1` = report if either SPF or DKIM fails (recommended — provides better visibility). `d` = DKIM failure only. `s` = SPF failure only. |
| `ruf` | No | — | **Forensic report recipients.** Not recommended — see note below. |
| `ri` | No | `ri=86400` | **Reporting interval** in seconds. Defaults to 86400 (24 hours). Most providers ignore this and send daily regardless. |

> **Note on `ruf`:** Do NOT configure `ruf=mailto:...` — forensic/failure reports (RUF) are not supported by this tool and are not recommended. Most major providers (Google, Microsoft) no longer send them due to privacy concerns. Focus on `rua` for aggregate reports.

#### Policy Progression

DMARC policy progression is a journey — rushing to `reject` without data can break legitimate email delivery. Use this workbook to monitor your domain and progress through these stages:

**Stage 1: Monitor (`p=none`)** — Start here
```dns
_dmarc.example.com. IN TXT "v=DMARC1; p=none; rua=mailto:dmarc@example.com; adkim=r; aspf=r; pct=100; fo=1"
```
- No email is blocked or quarantined — receiving servers deliver everything normally
- Reports flow into this solution so you can see who is sending email as your domain
- **Goal:** Identify all legitimate senders (your mail servers, marketing platforms, CRM, ticketing systems, etc.)
- **Duration:** Typically 2–4 weeks minimum. Stay here until you can account for all authorized senders
- **What to look for in the workbook:**
  - **Sources & Senders tab:** Review all source IPs — are they all recognized services?
  - **Authentication tab:** Are SPF and DKIM passing for your legitimate senders?
  - **Domain Compliance tab:** Check subdomain discovery for shadow IT or forgotten services

**Stage 2: Quarantine (`p=quarantine`)** — When legitimate senders all pass
```dns
_dmarc.example.com. IN TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com; adkim=r; aspf=r; pct=25; fo=1"
```
- Messages that fail DMARC are delivered to the recipient's spam/junk folder
- Start with `pct=25` — only 25% of failing messages are quarantined, the rest are still delivered normally
- **Move here when:** All legitimate senders consistently show SPF and/or DKIM pass in the workbook (aim for >95% overall pass rate)
- **Gradually increase `pct`:** `25` → `50` → `75` → `100` over a few weeks while monitoring for issues
- **Watch for:** Any legitimate email landing in spam — check the workbook for new failures after each `pct` increase

**Stage 3: Reject (`p=reject`)** — Full protection
```dns
_dmarc.example.com. IN TXT "v=DMARC1; p=reject; rua=mailto:dmarc@example.com; adkim=r; aspf=r; pct=100; fo=1"
```
- Messages that fail DMARC are rejected outright — they are never delivered
- This is the strongest protection against domain spoofing and phishing
- **Move here when:** You have been at `p=quarantine; pct=100` for several weeks with no legitimate email being affected
- **Use `pct` again if cautious:** Start with `p=reject; pct=10` and increase gradually

> **Tip:** The **Domain Compliance** tab in the workbook includes a policy readiness assessment that helps you determine when your domain is ready to move to the next stage. Look for consistent >99% pass rates across all legitimate senders before progressing to `reject`.

### 7. Import the Workbook

1. Navigate to your Log Analytics Workspace in the Azure Portal
2. Select **Workbooks** > **+ New**
3. Click the **Advanced Editor** button (</> icon)
4. Paste the contents of `workbook/dmarc-workbook.json`
5. Click **Apply**
6. Save the workbook with a name like "DMARC Analytics"

### 8. Run Graph Parity Diagnostic (Optional, Advanced)

If you need ingestion confidence checks (for example during incident response), run the parity preview script:

```powershell
./scripts/Invoke-GraphParityPreview.ps1 `
  -MailboxUserId '<mailbox-object-id>' `
  -WorkspaceId '<log-analytics-workspace-id>' `
  -StartDateUtc (Get-Date).ToUniversalTime().AddDays(-7) `
  -EndDateUtc (Get-Date).ToUniversalTime() `
  -OutputPath './parity-report.json'
```

This compares Graph message IDs with `DMARCReports_CL.SourceMessageId` and produces triage-oriented mismatch output.

- This script is intended to run in the **customer tenant context** (operator machine, automation account, or tenant-owned runner).
- It is not part of the required deployment workflow.
- It should not be used as a hard gate for normal ingestion unless your team explicitly opts in.

## Upgrading an Existing Deployment

Use this when you already have a working deployment and want to apply a new version of the tool. The Bicep deployment is **idempotent** — you run the same command as the initial install and ARM reconciles the diff.

**Required tools** (same as [Prerequisites](#prerequisites)): Azure CLI, PowerShell 7.4+, Azure Functions Core Tools (`func`).

Before running any commands, authenticate and confirm the CLI is targeting the right subscription:

```bash
az login
az account show --query "{name:name, id:id}" -o table
az account set --subscription "<your-subscription-id>"   # if needed
```

> **Critical:** Do **not** regenerate `GRAPH_CLIENT_STATE`. The existing Graph subscription was created with the current value. Replacing it would cause every incoming Event Grid notification to fail client-state validation until you also recreate the subscription.

### Step 1: Retrieve your existing values

Pull the current `MAILBOX_USER_ID` and `GRAPH_CLIENT_STATE` from your live deployment — do not set new ones.

**PowerShell:**
```powershell
$funcName = "dmarc-func-xyz123"   # from original deployment output
$rg       = "rg-dmarc-prod"

$env:MAILBOX_USER_ID = az functionapp config appsettings list `
  --name $funcName --resource-group $rg `
  --query "[?name=='MAILBOX_USER_ID'].value" -o tsv

# Parse the Key Vault name out of the app setting KV reference
$kvRef  = az functionapp config appsettings list `
  --name $funcName --resource-group $rg `
  --query "[?name=='GRAPH_CLIENT_STATE'].value" -o tsv
$kvName = [regex]::Match($kvRef, 'https://([^.]+)\.vault\.azure\.net').Groups[1].Value

$env:GRAPH_CLIENT_STATE = az keyvault secret show `
  --vault-name $kvName --name graph-client-state `
  --query value -o tsv

# If you get a Forbidden error above, grant yourself Key Vault Secrets User first:
# $myOid = az ad signed-in-user show --query id -o tsv
# az role assignment create --role "Key Vault Secrets User" --assignee $myOid `
#   --scope (az keyvault show --name $kvName --query id -o tsv)

# Capture the Graph subscription ID — Bicep will wipe it during redeployment
$graphSubscriptionId = az functionapp config appsettings list `
  --name $funcName --resource-group $rg `
  --query "[?name=='GRAPH_SUBSCRIPTION_ID'].value" -o tsv
```

**Bash:**
```bash
FUNC_NAME="dmarc-func-xyz123"
RG="rg-dmarc-prod"

export MAILBOX_USER_ID=$(az functionapp config appsettings list \
  --name "$FUNC_NAME" --resource-group "$RG" \
  --query "[?name=='MAILBOX_USER_ID'].value" -o tsv)

# Parse the Key Vault name out of the app setting KV reference
KV_REF=$(az functionapp config appsettings list \
  --name "$FUNC_NAME" --resource-group "$RG" \
  --query "[?name=='GRAPH_CLIENT_STATE'].value" -o tsv)
KV_NAME=$(echo "$KV_REF" | grep -oP '(?<=https://)[^.]+')

export GRAPH_CLIENT_STATE=$(az keyvault secret show \
  --vault-name "$KV_NAME" --name graph-client-state \
  --query value -o tsv)

# Capture the Graph subscription ID — Bicep will wipe it during redeployment
GRAPH_SUBSCRIPTION_ID=$(az functionapp config appsettings list \
  --name "$FUNC_NAME" --resource-group "$RG" \
  --query "[?name=='GRAPH_SUBSCRIPTION_ID'].value" -o tsv)
```

### Step 2: Preview changes (recommended)

Use `--what-if` to see exactly what ARM will create, modify, or delete before committing:

**PowerShell:**
```powershell
az deployment group what-if `
  --resource-group $rg `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

**Bash:**
```bash
az deployment group what-if \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

### Step 3: Deploy infrastructure

Same command as the initial deployment — ARM handles the diff:

**PowerShell:**
```powershell
az deployment group create `
  --resource-group $rg `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam
```

**Bash:**
```bash
az deployment group create \
  --resource-group "$RG" \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

### Step 3b: Restore Graph subscription ID

Bicep replaces all Function App settings with only what is defined in the template, wiping `GRAPH_SUBSCRIPTION_ID`. The Graph subscription itself is still alive in Microsoft Graph — restore the pointer:

**PowerShell:**
```powershell
az functionapp config appsettings set `
  --name $funcName --resource-group $rg `
  --settings "GRAPH_SUBSCRIPTION_ID=$graphSubscriptionId"
```

**Bash:**
```bash
az functionapp config appsettings set \
  --name "$FUNC_NAME" --resource-group "$RG" \
  --settings "GRAPH_SUBSCRIPTION_ID=$GRAPH_SUBSCRIPTION_ID"
```

> If `GRAPH_SUBSCRIPTION_ID` was already missing before this upgrade (e.g. first time running these steps), run `New-GraphSubscription.ps1` from Step 4 of the initial deployment instead. The script uses the Az PowerShell module — authenticate first with `Connect-AzAccount -UseDeviceAuthentication` if running on Linux or a Codespace.

### Step 4: Publish function code

**PowerShell:**
```powershell
cd src/function
func azure functionapp publish $funcName --powershell
```

**Bash:**
```bash
cd src/function
func azure functionapp publish "$FUNC_NAME" --powershell
```

**That's it.** You do not need to re-run Exchange RBAC or Graph subscription setup — those are already in place. The Graph subscription ID is restored in Step 3b above.

### What changes between versions

| Component | Behavior on upgrade |
|-----------|-------------------|
| Function App code | Replaced by `func publish` |
| LAW custom table schema | New columns added; existing rows get `null` for them |
| DCR stream declaration | New columns added; no data loss |
| Key Vault purge protection | Enabled if not already set (one-way, intentional) |
| Diagnostic settings | New resources created if not present |
| `GRAPH_CLIENT_STATE` | Unchanged — same value written back to Key Vault |
| Graph subscription | Unchanged — auto-renews via `RenewGraphSubscription` |
| Exchange RBAC | Unchanged |

### Note on schema changes and historical data

New columns (`MessageHash`, `RecordIndex`, `Aligned_dkim`, `Aligned_spf`, `DmarcPass`) are `null` for rows ingested before the upgrade. Workbook queries and detections that filter on `DmarcPass` will silently skip pre-upgrade rows.

To maintain continuity in workbook visuals during the transition window, use a coalesce fallback:

```kql
| extend DmarcPassEffective = coalesce(
    DmarcPass,
    tolower(PolicyEvaluated_dkim) == 'pass' or tolower(PolicyEvaluated_spf) == 'pass'
  )
```

Replace `DmarcPass` with `DmarcPassEffective` in any workbook tiles that show pass-rate trends. Once historical rows age out of your retention window, you can remove the fallback.

## Alerting & Notifications

### Option 1: Deploy Alert Rules via Bicep (Recommended)

The infrastructure includes optional Azure Monitor scheduled query alert rules. Enable them during deployment:

```powershell
$env:MAILBOX_USER_ID = '<your-mailbox-object-id>'
$env:GRAPH_CLIENT_STATE = [guid]::NewGuid().ToString()

az deployment group create `
  --resource-group "rg-dmarc-prod" `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam `
  --parameters deployAlerts=true alertActionGroupId='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/actionGroups/<name>'
```

This deploys 6 alert rules:
- **DMARC Pass Rate Drop** — fires when pass rate drops below threshold (default 90%), runs every 1 hour
- **No Reports Received** — fires when no reports ingested in 48+ hours, runs every 24 hours
- **New Suspicious Source IP** — fires when a new IP appears with both SPF and DKIM failing, runs every 6 hours
- **Volume Spike** — fires when daily volume exceeds 3x the 30-day baseline, runs every 1 hour
- **Stale Reporters** — fires when previously active reporters stop sending for 72+ hours, runs every 12 hours
- **Duplicate Report-Key Ratio** — low-severity signal when duplicate telemetry ratio exceeds threshold, runs every 6 hours

### Option 2: Manual Alert Rules

You can also create alert rules manually via the Azure Portal. The workbook's **Reporting & Ops** tab includes ready-to-use KQL queries for Azure Monitor alerts.

### Action Groups

Configure **Action Groups** to define how you're notified:
- **Email/SMS**: Notify security or operations team
- **Webhook**: Integrate with Microsoft Teams, Slack, PagerDuty, etc.
- **Azure Function/Logic App**: Custom remediation workflows

For more on Azure Monitor Alerts, see: [Microsoft Docs - Create log alert rules](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)

## Detection Rules for Defender XDR

The `detections/` directory contains Sentinel-compatible YAML detection rules for DMARC threat scenarios:

| Detection | Description | Frequency |
|-----------|-------------|-----------|
| `spoofing-detection.yaml` | High-volume DMARC failures from a single IP | 1 hour |
| `new-unauthorized-sender.yaml` | New source IPs failing authentication | 6 hours |
| `passrate-anomaly.yaml` | Per-domain pass rate drops below baseline | 1 hour |
| `policy-override-abuse.yaml` | Unusual DMARC policy override reasons | 6 hours |

### Deployment Options

- **Sentinel Repositories**: Connect your GitHub repo via **Settings > Repositories** and point to `detections/` for automatic deployment
- **[XDRConverter](https://github.com/f-bader/XDRConverter)**: Convert to Defender XDR Custom Detection Rules
- **Manual**: Paste the KQL from the `query:` field when creating rules in the Defender portal

See [`detections/README.md`](detections/README.md) for full instructions.

## Workbook Capabilities

The Azure Monitor Workbook (`workbook/dmarc-workbook.json`) is organized into 5 tabs with the following visualization and operations views:

### Executive Summary
- Total message volume, unique source IPs, reporters, pass rate (KPI tiles)
- Week-over-week comparison with deltas
- Per-domain risk scoring (weighted compliance score with color-coded risk levels)
- Daily pass/fail trend and compliance rate trend
- Priority action items with categorized fix recommendations

### Authentication
- Combined SPF/DKIM/DMARC authentication matrix
- SPF and DKIM pass rate trends over time (using report date range, not ingestion time)
- Failure reason analysis (forwarding, mailing lists, local policy overrides)
- Policy override reasons and forwarding detection
- Envelope vs header from mismatch analysis
- DKIM selector-level detail and alignment mode breakdown
- **Alignment failures**: Messages where raw SPF/DKIM passed but DMARC alignment failed, with fix guidance
- **Service-specific fix recommendations**: Per-sender SPF include and DKIM setup instructions for 14+ known services

### Sources & Senders
- **Top 50 Source IPs** with pass rates, service identification, and IP reputation links
- Authorized vs unknown sender classification (via SPF domain matching, not ASN)
- Source IP classification by provider category (Email Platform, ESP, CRM, SaaS, Security)
- Volume anomaly detection (Z-score based)
- **GeoIP Map** showing geographic distribution of email sources
- **Suspicious IPs** (both SPF and DKIM failing)
- Volume by sending identity (HeaderFrom)

### Domain Compliance
- Per-domain compliance scoring and pass rates
- Domain readiness for policy enforcement progression
- Published DMARC policies
- **DMARC Policy Health Check**: Flags p=none, missing subdomain policy, low pct, and other gaps
- Disposition over time (none/quarantine/reject)
- **Subdomain discovery**: Identify shadow IT, detect new subdomains, and flag subdomain policy gaps
- DKIM selector rotation tracking
- BIMI readiness assessment

### Reporting & Ops
- Report freshness monitor (color-coded per reporter)
- Freshness state counts and stalled-reporter visibility
- Duplicate report-key ratio and top duplicate contributors
- Reporter coverage and missing expected reporters
- Reports by provider and report volume over time
- Azure Monitor alert rule templates (5 ready-to-use KQL queries)
- Policy guidance for DMARC policy progression

## Troubleshooting

### No Data in Workbook

1. **Check Function App logs**: Navigate to Function App → **Functions** → **DmarcReportProcessor** → **Monitor**
2. **Verify Graph subscription**: Check Function App → **Configuration** → Confirm `GRAPH_SUBSCRIPTION_ID` is set
3. **Check shared mailbox**: Ensure DMARC reports are arriving (may take 24-48 hours after DNS change)
4. **Check Event Grid delivery**: Navigate to Partner Topic → **Metrics** → Check for failed deliveries

### Reports Not Processing

1. **Verify Managed Identity permissions**:
   - Graph API: `Mail.Read`, `Mail.ReadWrite` app roles
   - Exchange RBAC: Application permissions scoped to mailbox
   - Log Analytics: `Monitoring Metrics Publisher` on DCR
2. **Check Graph subscription status**: Should be "enabled" and not expired
3. **Review Function logs** for errors

### Data Confidence / Parity Validation (Optional)

If users suspect ingestion gaps, run [scripts/Invoke-GraphParityPreview.ps1](scripts/Invoke-GraphParityPreview.ps1) and review:
- `missingLikelyInLogAnalyticsCount`
- `missingCandidateInLogAnalyticsCount`
- `triageSummary`

Use `sampleMissingTriage` from the output report to separate likely non-DMARC noise from likely processing gaps before taking replay actions.

### Permission Errors

If you see errors like "Access Denied" or "Insufficient privileges":
- Ensure the Managed Identity has been granted permissions (may take 5-10 minutes to propagate)
- Verify Exchange RBAC scope is configured correctly
- Check that the MI has `Monitoring Metrics Publisher` on the DCR

## Security Considerations

- **No Client Secrets**: Uses Azure Managed Identity exclusively
- **Least Privilege**: Exchange RBAC limits MI to the shared mailbox only
- **Key Vault Integration**: Secrets (Graph client state) stored in Key Vault
- **DTD Attack Protection**: XML parsing explicitly disables DTD processing
- **Input Validation**: All report data sanitized before ingestion
- **RBAC**: All Azure resources secured via Azure RBAC

## Testing

The repository includes comprehensive Pester tests to verify PowerShell scripts work as expected:

```powershell
# Run all tests
Invoke-Pester -Path ./tests

# Run with detailed output
Invoke-Pester -Path ./tests -Output Detailed
```

### Test Coverage
- ✅ Comprehensive Pester coverage across PowerShell scripts and deployment helpers
- ✅ Module functions (token acquisition, Graph API, DMARC XML parsing, attachment extraction)
- ✅ Setup scripts (New-GraphSubscription.ps1, Grant-MIExchangeRBAC.ps1)
- ✅ Azure Functions (DmarcReportProcessor, RenewGraphSubscription, CatchupProcessor, BackfillProcessor)
- ✅ Security validations (DTD protection, size limits, client state validation)
- ✅ Error handling and logging patterns

See [tests/README.md](tests/README.md) for detailed test documentation.

## Contributing

Contributions are welcome! Please submit issues or pull requests via GitHub.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For issues, questions, or feature requests, please open a GitHub issue.
