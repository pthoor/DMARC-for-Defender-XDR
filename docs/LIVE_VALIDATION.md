# Manual Live Validation of Detection Rules

`scripts/Test-DetectionRulesLive.ps1` submits each `detections/*.yaml` rule to a real
Microsoft Sentinel workspace to check whether Azure accepts the analytics-rule
payload. It complements the offline checks in `tests/DetectionRules.Tests.ps1`, which
run on every PR and need no Azure access.

This is a maintainer step, not part of public CI. The repository is public, so its
Actions logs and any tenant credentials connected to them would be exposed to more
risk than the extra coverage justifies.

## When to run it

Run it before releasing a change to `detections/**`, especially a KQL change.

Azure accepting a disabled rule does not prove that the rule executes correctly or
detects real events.

## Prerequisites

- PowerShell 7.4+, Azure CLI, and `powershell-yaml` 0.4.7:
  ```powershell
  Install-Module powershell-yaml -RequiredVersion 0.4.7 -Scope CurrentUser
  ```
- A dedicated test workspace with no customer data.
- An identity that can create and delete `Microsoft.SecurityInsights/alertRules` on
  that workspace only. "Microsoft Sentinel Contributor" works but is broader; a
  custom role limited to `Microsoft.SecurityInsights/alertRules/*` is preferred.

## Running it

```powershell
az login
./scripts/Test-DetectionRulesLive.ps1 `
  -SubscriptionId <subscription-id> `
  -ResourceGroupName <resource-group> `
  -WorkspaceName <workspace-name>
```

The script exits with code 1 if any rule fails. Its output does not include raw
Azure responses; to diagnose a rejection, create the rule in the test workspace
directly and inspect the error there.

## What it does

- Creates each rule **disabled**, with a `[CI-VALIDATION]` name prefix and a fixed
  test ID in the pattern `00000000-cccc-cccc-cccc-00000000000N`.
- Deletes those IDs before and after the run. Deletion is best-effort; if a
  `[CI-VALIDATION]` rule remains in the workspace, delete it manually. The IDs are
  listed in the script's `$testRuleIds` map.
- A new detection file needs an entry in `$testRuleIds`, otherwise it is reported
  as a failure.
