# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-11-12

### Security
- Mailbox setup now grants only mailbox-scoped Exchange Application RBAC roles, instead of tenant-wide Microsoft Graph mail application permissions. It stops on existing direct application permissions or conflicting Exchange assignments; an administrator must review and remove unwanted grants before retrying.

### Changed
- Updated deployment guidance for the verified ZIP publishing path, mailbox permission prerequisites, and verification steps.
- Updated remaining DMARC-to-Sentinel labels to DMARC for Defender XDR.

### Fixed
- Version metadata tests now support both LF and CRLF checkouts.

## [1.4.3] - 2026-08-13

### Changed
- Reworded the "SOC Runtime Triage Playbook" guidance for the Event Grid message-ID parsing error - it previously asked the analyst to personally validate Graph webhook payload shapes, which is engineering-level troubleshooting. Now tells the analyst what to capture and escalate instead, and notes there's no immediate data-loss risk.

## [1.4.2] - 2026-08-13

### Fixed
- Two workbook text sections still described the pre-A10 "Fail" semantic (`both SPF and DKIM failed`) after the underlying `failed-messages-grid` and `domain-readiness` (`SuspiciousIPs`) queries were switched to the broader `DmarcPassEffective == false` - the tiles' numbers had changed but their explanations hadn't, so they no longer matched what the tile actually showed.
- The two KQL snippets in "Azure Monitor Alert Rule Templates" (Pass Rate Drop, New Suspicious Source IP) still used the pre-A10 raw `PolicyEvaluated_dkim`/`PolicyEvaluated_spf` pattern - copy-pasting them into a real alert rule would have computed slightly different numbers than the live workbook tiles now do. Updated to the same `DmarcPassEffective` pattern.
- Reworded "Forwarding & Alignment" guidance that referenced the raw `PolicyEvaluated_reason_type` column name in analyst-facing prose to plain language.

## [1.4.1] - 2026-08-13

### Fixed
- `domain-readiness` workbook tile: the `RecommendedAction` message could tell you to "Improve to 99%+ [pass rate] before reject" even when your pass rate was already at or above that threshold, if the real blocker was insufficient days of data (`DaysWithData < 14`). The `case()` logic conflated two independent gates into one message that only named the pass-rate one. Now reports "Pass rate ready - waiting for N more day(s) of data" when that's the actual blocker. Caught via real-world use against a live deployment - pass rate 100%, `DaysWithData=9`, previously showed the misleading message.

## [1.4.0] - 2026-08-13

### Fixed
- Removed the `BIMI Readiness` workbook tile and its mention in the Domain tab description - BIMI is documented as out of scope (`docs/BACKLOG.md`, decided 2026-05-30); the tile predated that decision and contradicted it. The still-valid "domain readiness for policy enforcement" tile (`domain-readiness`) is unaffected.
- `workbook/dmarc-workbook.json`: 23 tiles that compute a combined DMARC pass/fail signal now use the shared `DmarcPassEffective` coalesce pattern (`docs/BACKLOG.md` A10) instead of each recomputing `PolicyEvaluated_dkim`/`PolicyEvaluated_spf` inline. **Numbers may shift slightly:** "Fail" is now the clean negation of "Pass" (`DmarcPassEffective == false`) rather than the narrower `dkim =~ 'fail' and spf =~ 'fail'` used before, which silently excluded rows where a protocol result was `'none'`/`'temperror'` rather than an explicit `'fail'` - Pass + Fail now sum to Total everywhere they're both shown, which wasn't guaranteed before. Tiles with a genuinely different, intentional semantic (protocol-specific trends, the broader "any protocol issue" remediation list, forwarding/alignment pattern detection) were left as-is. `infra/alerts.bicep`'s pass-rate alert is not yet updated to match - tracked as the remainder of A10.
- `subdomain-discovery` workbook tile now filters on `HeaderFromIsSubdomain` and groups by `HeaderFromBaseDomain` (added in 1.2.0) instead of treating every distinct `HeaderFrom` value as a subdomain via a bare `tolower()` - it previously included apex-domain senders and had no real base-domain grouping.

## [1.3.0] - 2026-08-13

### Changed
- **Breaking:** `infra/main.bicep`'s `restrictScmAccess` bool parameter is replaced by `scmAccessMode` (`'restricted'` | `'identity-gated'`). `restricted` (the default, and the exact same behavior `restrictScmAccess=true` had) closes the SCM/Kudu deployment endpoint to the public internet — pair it with a temporary scoped IP allow-rule for manual deploys, or a VNet-integrated/self-hosted CI runner. `identity-gated` opens SCM to the network but disables classic basic-auth publish credentials unconditionally, so only a valid Microsoft Entra ID token from an authorized identity (e.g. OIDC + `Website Contributor`) can deploy — recommended for plain GitHub-hosted Actions runners, whose IP ranges are too large and volatile to allow-list. **Migration:** if you previously pinned `restrictScmAccess=false` to make the old public-GitHub-Actions deploy flow work, switch to `scmAccessMode=identity-gated` and set up OIDC per [docs/DEPLOYING_CODE_UPDATES.md](docs/DEPLOYING_CODE_UPDATES.md) — the old behavior (SCM open + basic auth allowed) is no longer available, since basic auth is now disabled unconditionally.
- Basic (username/password) publish credentials for both SCM and FTP are now always disabled (`basicPublishingCredentialsPolicies`), regardless of `scmAccessMode`. This was implicitly relied upon by nothing in this project (deploys always used `func`/Core Tools or Managed Identity), so it should be a no-op for existing workflows other than closing an unused credential path.

### Added
- [docs/DEPLOYING_CODE_UPDATES.md](docs/DEPLOYING_CODE_UPDATES.md) — the three supported code-deployment flavors (manual with a temporary IP rule, GitHub-hosted Actions via `identity-gated` OIDC, self-hosted/VNet-integrated runners) with exact commands for each.

## [1.2.0] - 2026-08-13

### Added
- `ConvertFrom-DmarcXml` now derives and stores registrable-domain identity for both the policy domain and `HeaderFrom`: `BaseDomain`, `OrgDomain`, `IsSubdomain`, `HeaderFromBaseDomain`, `HeaderFromOrgDomain`, `HeaderFromIsSubdomain`. Adds the matching columns to the `DMARCReports_CL` DCR stream declaration and table schema in `infra/main.bicep` (previously the parser computed these fields but they had no destination column and were silently dropped by the DCR's pass-through transform).
- Added a `DomainPostureCollector` timer function and `DnsPostureHelpers.psm1` module — a foundation for resolving DMARC-authentication DNS records (`_dmarc`, SPF, DKIM selector TXT) per in-scope domain (backlog C0). **Not yet production-wired**: it needs its own `DomainPosture_CL` table/DCR (see `docs/BACKLOG.md` C0) before `DOMAIN_POSTURE_SCOPE` should be set in any environment.

### Changed
- `MessageHash` and `DuplicateTelemetryKey` are now computed from canonicalized values (trimmed, case-folded, trailing-dot-stripped for domains) instead of raw XML text. This improves dedup for reports whose casing/formatting varies between deliveries of the same underlying data.
  - **Compatibility note:** rows already ingested under the previous (raw-value) formula will not match the new hash for the same logical report if the raw values differed only in case or trailing dots. A backfill/reprocess run immediately after this upgrade can therefore produce a small number of new rows for reports that were already ingested pre-upgrade under those specific conditions. This mirrors the existing precedent below for `MessageHash`/`DmarcPass` being `null` on pre-upgrade rows — old and new rows are not guaranteed to dedupe against each other across this boundary.
- Renamed two internal (non-exported) parser helpers to use approved PowerShell verbs: `Normalize-DomainName` → `ConvertTo-DomainName`, `Normalize-DeterministicString` → `ConvertTo-DeterministicString`.

### Fixed
- `DomainPostureCollector`'s DNS resolution now throws instead of silently returning an empty result when neither `Resolve-DnsName` nor `nslookup` is available on the host. Previously this was indistinguishable from a genuine "no DNS record" result, which would have produced false-negative DMARC/SPF/DKIM posture data with no visible error.
- `Send-DomainPostureToLogAnalytics` now reads dedicated `POSTURE_DCR_ENDPOINT`/`POSTURE_DCR_IMMUTABLE_ID`/`POSTURE_DCR_STREAM_NAME` settings instead of the `DCR_*` settings used by DMARC report ingestion, so enabling domain posture collection can never silently post mismatched rows into the `DMARCReports_CL` stream.
- Transient HTTP 502/504 responses are retried with backoff (in addition to 429/503).
- A malformed `<record>` (e.g., non-numeric `<count>` or `<pct>`) no longer aborts processing of the whole report; the bad record is skipped (or its value defaulted) with a warning, so messages cannot get stuck unread in a retry loop.
- A ZIP entry that fails extraction no longer discards entries already extracted from the same archive, and `ZipArchive` handles are always disposed.

### Security
- `DmarcReportProcessor` now fails closed when `GRAPH_CLIENT_STATE` is missing or its Key Vault reference is unresolved (previously it logged a warning and processed the notification unvalidated), and validates the client state with a constant-time comparison.
- `SetupHelper` only accepts `EventGrid:` notification URLs by default. Direct HTTPS webhook URLs (which would receive the client state secret) require the `ALLOW_WEBHOOK_NOTIFICATION_URL=true` app setting.
- Attachment extraction enforces a cumulative 100 MB decompression cap per message (in addition to existing per-entry limits) to prevent memory exhaustion from crafted ZIP attachments.
- `BackfillProcessor` no longer returns internal exception details in HTTP 500 responses.
- Mail subjects are sanitized (control characters stripped, length capped) before logging.
- Mailbox user IDs are URL-encoded consistently in Microsoft Graph request URIs.

### Removed
- The unused `Get-UnreadMessages` helper (superseded by `Get-MailboxMessages`) and the always-zero `skipped` counter from the BackfillProcessor response.

## [1.1.0] - 2026-05-08

### Added
- Added a root `VERSION` file for tenant-deployment-safe artifact version tracking.
- Added `tests/Versioning.Tests.ps1` to validate version metadata consistency and KQL safety guards.

### Changed
- Hardened workbook metric queries against null and divide-by-zero edge cases.
- Updated workbook header to include release metadata (`v1.1.0`).
- Bumped Sentinel detection rule versions to `1.1.0`.

### Fixed
- Corrected policy override detection entity mapping to use a scalar IP field.
- Corrected pass-rate logic in Azure Monitor pass-rate alert to use DMARC semantics (SPF **or** DKIM pass).
- Corrected alert and workbook query calculations for null handling, zero denominators, and safer join-key usage.
