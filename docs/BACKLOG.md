# DMARC Analyzer Azure Public Backlog

Maintainer-facing planning for upcoming hardening, detection tuning, and product improvements. This file is safe to keep in the public repo because it explains direction and tradeoffs for contributors, but it should stay curated: move accepted work to GitHub issues when it is ready for implementation, and do not use this file for undisclosed security vulnerabilities.

If you find a security issue that is not already public, follow [SECURITY.md](../SECURITY.md) instead of opening a public backlog item.

Originally captured from a code/infra/workbook/ops audit on 2026-05-10. Use this as a prioritization scratchpad — mark items with **PICK** / **DEFER** / **WONT** and re-order as needed.

**Legend**
- **Severity:** P0 (correctness/security blocker) · P1 (high-value gap) · P2 (quality / hardening) · P3 (strategic / deferred)
- **Effort:** S (<½ day) · M (½–2 days) · L (>2 days)
- **Status:** ☐ open · ☑ done · ⏸ deferred

**How an AI coding agent should use this backlog**
- Start on a new branch, never directly on `main`. Use a focused name such as `work/a10-dmarcpass-workbook` or `fix/g6-appinsights-api`.
- Read [README.md](../README.md), [docs/ARCHITECTURE.md](ARCHITECTURE.md), [docs/RUNBOOK.md](RUNBOOK.md), [tests/README.md](../tests/README.md), and the specific files listed in the selected backlog item before editing.
- Pick one open item at a time. Prefer the recommended next slice unless the maintainer asks for a different item: A10, A11, B3, D9, then C0 (which enables D2/D3/D4).
- Treat `Where`, `Problem`, and `Fix` as the task contract. If implementation reality differs from the backlog, update the backlog or explain the mismatch in the PR.
- Keep changes scoped. Do not combine unrelated backlog items in one branch unless one item cannot be completed safely without the other.
- Add or update tests when touching parser logic, KQL generation/parity, Bicep resources, scripts, or detection behavior. For docs-only changes, validate links and Markdown.
- Use existing project patterns: PowerShell Functions under [src/function](../src/function), shared helpers in [src/function/modules/DmarcHelpers.psm1](../src/function/modules/DmarcHelpers.psm1), infrastructure in [infra/main.bicep](../infra/main.bicep), alerts in [infra/alerts.bicep](../infra/alerts.bicep), detections in [detections](../detections), and workbook KQL in [workbook/dmarc-workbook.json](../workbook/dmarc-workbook.json).
- Before marking an item done, verify the relevant tests or static checks, update docs if behavior changes, and record any remaining caveats in the item status note.

**Definition of done for backlog items**
- Code, infrastructure, workbook, detections, docs, and tests are updated for the full user-facing behavior described by the item.
- The change works for a single-tenant Exchange Online deployment and does not introduce RUF/message-content processing.
- KQL remains backward-compatible with older custom table rows when the item touches schema or workbook queries.
- Public docs do not expose secrets, tenant-specific values, or undisclosed vulnerabilities.
- The final PR description names the backlog item ID and lists validation performed.

**Locked decisions**
- Single-tenant only — one Function App per M365 tenant
- RUF (forensic) reports stay off; document the privacy stance more prominently
- Private Endpoints deferred (separate GitHub issue) — but call out resources where PE is the only mitigation
- Defender XDR is the target surface: onboarding the Sentinel workspace to the unified Defender portal makes `DMARCReports_CL` huntable today (Z1a, no data lake needed); only Advanced Hunting **graph functions** + data-lake specifics stay long-term (Z1b)
- **Transport security (MTA-STS, DANE, TLS-RPT) and brand display (BIMI) are out of scope** — they are a different security domain (confidentiality-in-transit / brand) with a different owner (messaging/marketing admins) than DMARC anti-spoofing, they are not SOC-actionable in the Defender XDR incident workflow, and mature tooling already covers them. See "Out of scope — transport security & brand display." Only DNS checks that explain DMARC pass/fail (SPF lookups, DKIM key strength, DMARC record validity) stay in.

**Planning reset — 2026-05-30 (scope narrowed 2026-05-30)**
- Keep the product centered on Exchange Online-hosted DMARC operations and Defender XDR/Sentinel-style analytics. Avoid turning it into a generic email-security platform.
- Live-DNS work is in scope only when it explains a DMARC authentication outcome (why SPF/DKIM/DMARC pass or fail). It is **not** in scope for transport-security or brand-display posture.
- Recommended next slice is now: close stale P0/P1 correctness gaps (A10, A11), add suppressions (B3), add domain inventory (D9), then build the minimal posture collector (C0) that enables the DMARC-auth DNS checks (D2 SPF lookups, D3 DMARC record validity, D4 DKIM key strength).

---

## P0 — Correctness & security blockers

### A1. Fix dedup race on Log Analytics ingestion failure
- **Effort:** M · **Status:** ☑
- **Where:** [src/function/modules/DmarcHelpers.psm1:794-805](../src/function/modules/DmarcHelpers.psm1#L794-L805)
- **Problem:** If any 500-record batch fails, the function throws *before* `Set-MessageRead` runs. CatchupProcessor reprocesses the entire email the next day; previously-succeeded batches duplicate.
- **Fix:** Mark message read only after **all** batches succeed. Add a deterministic `MessageHash` column from `(SourceMessageId, ReportId, RecordIndex, SourceIP, HeaderFrom)` so duplicates can be detected/deduped at query time even if a race slips through.

### A2. Event Grid ↔ CatchupProcessor race
- **Effort:** S · **Status:** ☑ (MessageHash from A1 makes duplicates detectable at query time; runtime in-flight marker is a P1 follow-up)
- **Where:** [src/function/DmarcReportProcessor/run.ps1](../src/function/DmarcReportProcessor/run.ps1) vs [src/function/CatchupProcessor/run.ps1](../src/function/CatchupProcessor/run.ps1)
- **Problem:** Both can pick up the same unread message during delivery delays.
- **Fix:** A1's `MessageHash` makes duplicates detectable; consider a short "in-flight" marker (custom message extended property or storage table) to avoid concurrent processing.

### A3. Transient-error backoff (Graph 429/503, DCR throttling)
- **Effort:** S · **Status:** ☑
- **Where:** [src/function/modules/DmarcHelpers.psm1:110-117](../src/function/modules/DmarcHelpers.psm1#L110-L117), [DmarcHelpers.psm1:723-726](../src/function/modules/DmarcHelpers.psm1#L723-L726)
- **Problem:** 429/503 responses rethrow immediately; the function host retries within seconds and likely fails again, wasting invocations.
- **Fix:** Add `Invoke-WithRetry` wrapper with exponential backoff + jitter, honoring `Retry-After` header.

### A4. Lock down admin HTTP endpoints with Easy Auth + Entra ID
- **Effort:** M · **Status:** ☑ (Bicep `authsettingsV2` resource added, gated on `adminEntraAppClientId` param; after confirming Easy Auth works, change `authLevel` in BackfillProcessor/SetupHelper function.json from `admin` to `anonymous`)
- **Where:** [src/function/BackfillProcessor/function.json](../src/function/BackfillProcessor/function.json), [src/function/SetupHelper/function.json](../src/function/SetupHelper/function.json), [infra/main.bicep](../infra/main.bicep)
- **Problem:** Both use `authLevel: admin`. A leaked host key allows arbitrary mailbox replay or subscription manipulation.
- **Fix:** Configure App Service Authentication (Easy Auth) on the Function App requiring an Entra ID token from a specific app role / security group. Drop `authLevel` to `anonymous` (Easy Auth gates the request before the function runs). Document the bootstrap flow in the README.

### A5. Fail-closed on missing `GRAPH_CLIENT_STATE`
- **Effort:** S · **Status:** ☑
- **Where:** [src/function/SetupHelper/run.ps1:44-47](../src/function/SetupHelper/run.ps1#L44-L47)
- **Problem:** If the Key Vault reference hasn't resolved (MI not yet granted, KV firewall, etc.) the code emits `Write-Warning` and creates the Graph subscription **without** a client state token — every Event Grid notification thereafter is unauthenticated.
- **Fix:** Throw on unresolved KV reference. Document the bootstrap dependency.

### A6. Diagnostic settings to LAW for Function App / Storage / Key Vault / Event Grid
- **Effort:** S · **Status:** ☑ (KV audit, FunctionAppLogs, Storage blob audit forwarded to LAW)
- **Where:** [infra/main.bicep](../infra/main.bicep)
- **Problem:** No central audit trail for secret access, config changes, deployment events. Compliance frameworks (SOC2/ISO27001) require this.
- **Fix:** Add `Microsoft.Insights/diagnosticSettings` resources forwarding to the existing LAW.

### A7. Key Vault `enablePurgeProtection: true`
- **Effort:** S · **Status:** ☑
- **Where:** [infra/main.bicep:257-276](../infra/main.bicep#L257-L276)
- **Problem:** Soft delete only — a compromised admin can permanently destroy `graph-client-state`.
- **Fix:** One-line change. Note: cannot be disabled once enabled (intentional).

### A9. Capture per-record alignment outcome
- **Effort:** S · **Status:** ☑ done-with-caveat (materialized at ingestion; see implementation note below)
- **Where:** [src/function/modules/DmarcHelpers.psm1:711-713](../src/function/modules/DmarcHelpers.psm1#L711-L713)
- **Problem:** Schema stores `PolicyPublished_adkim`/`aspf` (the policy *mode*) but not a single materialized per-record DMARC outcome, so every consumer reimplements the pass expression.
- **Fix (as shipped):** Materialize `Aligned_dkim` / `Aligned_spf` / `DmarcPass` (bool) at ingestion. **Implementation note — the value is derived from the receiver's `policy_evaluated` verdict, not recomputed from `auth_results`:** `DmarcPass = (policy_evaluated.dkim == 'pass') OR (policy_evaluated.spf == 'pass')`. `policy_evaluated/dkim|spf` already fold authentication **and** alignment into one result, so the `Aligned_*` column names are slightly loose (they mean "authenticated and aligned per the receiver," not pure alignment). This buys schema stability and query simplicity, but `DmarcPass` is **identical by construction** to the A10 `DmarcPassEffective` fallback — it is not an independent signal.
- **Optional follow-up (P2, new):** To gain a signal the fallback can't reproduce, recompute alignment from `auth_results` (DKIM `d=` / SPF `mfrom` domain) against the published `adkim`/`aspf` modes. This surfaces receiver **local-policy overrides** (`forwarded`, `mailing_list`, `trusted_forwarder`) where the message was delivered despite failing raw DMARC — the only case where a recomputed value diverges from `policy_evaluated`. Store as a separate column (e.g. `DmarcPassRecomputed`) rather than overwriting `DmarcPass`.

### A10. Normalize workbook and Azure Monitor alerts to `DmarcPassEffective`
- **Effort:** M · **Status:** ☐
- **Where:** [workbook/dmarc-workbook.json](../workbook/dmarc-workbook.json), [infra/alerts.bicep](../infra/alerts.bicep)
- **Problem:** Ingestion and detections now use `DmarcPass`, but many workbook tiles and the pass-rate alert still recompute pass/fail inline from `PolicyEvaluated_dkim` / `PolicyEvaluated_spf`. Because `DmarcPass` is derived from those same fields (see A9), the issue is **inconsistent/duplicated expressions across tiles**, not a true semantic divergence — but inconsistency still produces subtly different numbers when one tile forgets a null guard or weighting. README migration guidance already recommends `DmarcPassEffective` for historical fallback.
- **Note on semantics:** The `DmarcPass`/`DmarcPassEffective` (receiver DMARC verdict) view and the raw `auth_results` SPF/DKIM tiles are **both valid and intentionally different** (overall DMARC outcome vs protocol-specific result). This item normalizes the *DMARC-verdict* tiles only; it must **not** collapse the raw-result tiles into it.
- **Fix:** Introduce one shared KQL pattern in DMARC-verdict workbook tiles and alert queries:
	`DmarcPassEffective = coalesce(tobool(column_ifexists('DmarcPass', bool(null))), PolicyEvaluated_dkim =~ 'pass' or PolicyEvaluated_spf =~ 'pass')`.
	Use it for pass-rate, fail-rate, readiness, map, source, and alert calculations. **Weight all pass/fail aggregations by `sum(MessageCount)`, never by row count** — each report row represents `count` messages. Keep raw SPF/DKIM result tiles where they intentionally show protocol-specific results.

### A11. Complete Easy Auth hardening for admin HTTP functions
- **Effort:** S · **Status:** ☐
- **Where:** [src/function/BackfillProcessor/function.json](../src/function/BackfillProcessor/function.json), [src/function/SetupHelper/function.json](../src/function/SetupHelper/function.json), [infra/main.bicep](../infra/main.bicep)
- **Problem:** `authsettingsV2` can be configured, but operator guidance for ongoing validation is incomplete. The intended security model is defense-in-depth: keep both endpoints at `authLevel: admin` and require Entra bearer auth via Easy Auth.
- **Fix:** Keep both HTTP triggers at `authLevel: admin` (do **not** switch to anonymous), document the required call pattern (Entra bearer token + function key), and add a deployment validation check that fails if Easy Auth is unset or either trigger is changed away from `admin`.

---

## P1 — DMARC correctness & detection tuning

> **Two alerting surfaces — keep them straight.** The project's stated main goal is to *alert in Defender XDR*. The `detections/*.yaml` (Sentinel scheduled analytics rules; convertible to XDR Custom Detections — see Z1a) raise **incidents in the unified Defender XDR queue** and are the **primary** surface for that goal; entity-mapping/threshold work (B1, B2, B5) compounds here. The `infra/alerts.bicep` rules are `Microsoft.Insights/scheduledQueryRules` (Azure Monitor) that fire to **Action Groups (email/SMS/webhook) only — they do not appear in the XDR incident queue**, so treat them as an ops/notification channel, not as "Defender XDR alerting." Prioritize detection-rule coverage over expanding the Azure Monitor alert set when the goal is XDR.

### B1. `policy-override-abuse` threshold + entity mappings
- **Effort:** S · **Status:** ☑ (threshold raised to >=50; DNS + Account entity mappings added)
- **Where:** [detections/policy-override-abuse.yaml](../detections/policy-override-abuse.yaml)
- **Problem:** `OverriddenMessages >= 5` is too low — false-positive prone on small samples. Entity mapping emits only `SampleIP`.
- **Fix:** Raise to ≥50. Add `Domain` (DNS) and `HeaderFrom` (Account) entity mappings.

### B2. Add `Domain` + `HeaderFrom` entities to all detections
- **Effort:** S · **Status:** ☑ (all 4 detection rules now emit DNS + Account entities)
- **Where:** [detections/](../detections/) (4 files)
- **Problem:** Most rules emit only `SourceIP`. SOC analysts need domain + sender for triage.
- **Fix:** Add `entityMappings` blocks for DNS + Account types.

### B3. Suppression mechanism (`DmarcSuppressions_CL` lookup table)
- **Effort:** M · **Status:** ☐
- **Problem:** No way to silence detections during vendor onboarding, server maintenance, or planned policy migrations. Every alert tunes the threshold up; suppression is the right primitive.
- **Fix:** Create a small custom log table (manually populated or via a UI later) with `(Domain, SourceIP, ReasonTag, ExpiresAt)`. Join into each detection query.

### B4. `OverrideReasonCategory` column at ingestion
- **Effort:** S · **Status:** ☑ (derived at parse time and added to LAW/DCR schema + tests)
- **Where:** [src/function/modules/DmarcHelpers.psm1](../src/function/modules/DmarcHelpers.psm1) parser
- **Problem:** Override reasons are stored as raw strings; downstream queries reimplement classification.
- **Fix:** Add a derived `OverrideReasonCategory` column with values `forwarded | mailing_list | trusted_forwarder | local_policy | sampled_out | other`.

### B5. MITRE ATT&CK coverage expansion
- **Effort:** S · **Status:** ☑ (added T1001/T1589 where applicable in detection metadata)
- **Where:** [detections/](../detections/)
- **Problem:** Current rules cover T1566/T1562 only.
- **Fix:** Add T1001 (Data Obfuscation), T1589 (Gather Victim Identity Info) where applicable.

---

## P1 — DMARC-auth DNS posture (explains pass/fail)

These items resolve live DNS **only to explain a DMARC authentication outcome** — why SPF/DKIM/DMARC pass or fail for in-scope domains. None of this data is in the report (RFC 7489 RUA carries only `policy_published` + per-record source IP/count/disposition/SPF-DKIM results/identifiers), and **workbook/KQL cannot resolve DNS** — hence the collector below. The actual checks live in D2 (SPF lookups), D3 (DMARC record validity), and D4 (DKIM key strength).

### C0. Minimal domain posture collector (foundational — enables D2/D3/D4)
- **Effort:** M · **Status:** ☐ PICK before D2/D3/D4
- **Problem:** D2/D3/D4 assume a "workbook tile that resolves `_dmarc`/SPF/selector TXT." **Workbook/KQL cannot perform DNS resolution**, and the repo has no DNS code today. Without a collector these checks are unbuildable.
- **Fix:** Add a timer-triggered PowerShell Function (e.g. `DomainPostureCollector`) that, for each in-scope domain (from `DomainInventory_CL`, D9), runs `Resolve-DnsName` for the DMARC-authentication records only — `_dmarc.<domain>` TXT, the SPF record (recursively, to count lookups), and `<selector>._domainkey.<domain>` TXT for selectors seen in reports — and writes a `DomainPosture_CL` table (`Domain`, `CheckType`, `RecordRaw`, `ParsedFields`, `Status`, `CheckedAt`). Workbook tiles read this table only. Prefer a sibling module over expanding `DmarcHelpers.psm1`.
- **Scope guard:** Keep this collector to DMARC-authentication records. It is deliberately **not** a transport-security/HTTPS prober (no MTA-STS `.well-known` fetch, no TLSA/DNSSEC) — see the out-of-scope decision below.

---

## Out of scope — transport security & brand display (decided 2026-05-30)

> **WONT (by design).** MTA-STS, DNSSEC/DANE, TLS-RPT, and BIMI are **not** built into this tool. They protect a *different* security property (encryption-in-transit / brand display) than DMARC (anti-spoofing), they serve a *different* owner (messaging/marketing admins, not the SOC), and **nothing about them is actionable in a Defender XDR DMARC incident** — they are posture, not detection. They also have no presence in the DMARC report and would require either a separate report pipeline (TLS-RPT) or a full DNS/HTTPS-probing subsystem, duplicating mature tooling.
>
> **Use instead:** Exchange Admin Center "messages in transit" / outbound transit-security report; the [Microsoft Remote Connectivity Analyzer](https://testconnectivity.microsoft.com/tests/o365); and free domain scanners (internet.nl, Hardenize, MECSA) for MTA-STS/DANE/TLS-RPT. BIMI display is an external-receiver concern (Gmail/Apple/Yahoo); Microsoft 365/Outlook does not render BIMI.
>
> **Note:** "Am I ready for BIMI / full enforcement" (`p=quarantine`/`reject`, `pct=100`) is *already* answered from ingested `PolicyPublished_*` data by [docs/POLICY_PROGRESSION_PLAYBOOK.md](POLICY_PROGRESSION_PLAYBOOK.md) and the "Domain Readiness for Policy Enforcement" workbook tile — no new code needed.
>
> Reopen only if the product intentionally pivots from "DMARC SOC tooling" to "domain email-security posture dashboard." Previously tracked here as C1 (TLS-RPT), C2 (MTA-STS), C3 (BIMI), C4 (DANE).

---

## P1 — Visualization feature parity vs Valimail / dmarcian / EasyDMARC

### D1. Threat-intel enrichment of source IPs (ASN, geo, reputation)
- **Effort:** M · **Status:** ☐
- **Problem:** Workbook uses `geo_info_from_ip_address()` only. No ASN, no reputation, no threat-feed correlation.
- **Fix:** Add `ASN` + `ASNOrg` columns at ingestion (resolve via a periodic enrichment job using a static IP→ASN dataset, or external API at query time). Threat-feed correlation can come later via a separate `ThreatIntel_CL`/MISP join.

### D2. SPF lookup-count exhaustion warning
- **Effort:** S · **Status:** ☐ (depends on C0)
- **Data provenance:** Not in the DMARC XML — requires recursively resolving the SPF record. Do it in the **C0 collector** (count `include`/`a`/`mx`/`ptr`/`exists` DNS lookups), write to `DomainPosture_CL`; the workbook only reads it.
- **Problem:** No early warning when an SPF record is approaching the 10-lookup limit (`permerror`).
- **Fix:** C0 computes the resolved lookup count per domain; add a workbook tile + alert rule that flag domains at ≥8 lookups.

### D3. DMARC record syntax validator
- **Effort:** S · **Status:** ☐ (depends on C0)
- **Data provenance:** Not in the DMARC XML (the report only echoes `policy_published`, not the literal TXT). Resolve `_dmarc.<domain>` TXT in the **C0 collector**.
- **Problem:** No surface-area for syntactically-broken records (missing RUA, malformed `pct`, dangling `sp`, deprecated `fo`).
- **Fix:** C0 resolves and validates the `_dmarc.<domain>` TXT structure; the workbook renders a per-domain validity tile from `DomainPosture_CL`. **Note:** a workbook/KQL tile cannot resolve DNS itself.

### D4. DKIM key aging / algorithm-downgrade alerts
- **Effort:** S · **Status:** ☐ (key-size/algorithm checks depend on C0)
- **Where:** workbook lines ~1596–1641 already track first/last seen per selector (from report data)
- **Fix:** Add an alert rule for selectors not rotated in N days (derivable from existing first/last-seen data). For key strength, resolve the selector's `<selector>._domainkey.<domain>` TXT in the **C0 collector** and flag RSA-1024 and weak algorithms.
- **EXO-specific:** Exchange Online provisions DKIM selectors (`selector1`/`selector2`) as **RSA-1024 by default**. Flag in-scope EXO domains still on 1024-bit and recommend rotation to 2048 via `Rotate-DkimSigningConfig -Identity <domain> -KeySize 2048` (selector1/selector2 alternation, ~96h to take effect). See https://learn.microsoft.com/defender-office-365/email-authentication-dkim-configure#rotate-dkim-keys.

### D5. Cousin-domain / lookalike monitoring
- **Effort:** L · **Status:** ☐
- **Problem:** No detection of `target-security.com` style spoofing of registered domains.
- **Fix:** Generate typo-squat candidates (Levenshtein/keyboard-distance) for each protected domain, monitor for any DMARC reports referencing them. Likely a separate generation script + lookup table.

### D6. Compliance / executive-ready PDF export
- **Effort:** M · **Status:** ☐
- **Problem:** Workbook supports CSV per-tile, but no audit-ready single document.
- **Fix:** A second compact workbook (or section of the existing one) optimized for PDF export with the 5–6 metrics auditors care about.

### D7. Drill-down from failing source → message-level
- **Status:** ⏸ WONT (privacy stance — RUF stays off)
- **Note:** Document this decision more prominently in README.

### D8. Curated sender classification catalog (`ProviderIPs_CL`)
- **Effort:** M · **Status:** ☐
- **Problem:** The "Source IP Classification by Provider" workbook tile uses an inline `case` statement covering a handful of providers. Commercial DMARC vendors' central differentiator is a maintained corpus that classifies senders as `Own infrastructure` / `ESP` / `Marketing` / `Forwarder` / `Threat` / `Unknown` for tens of thousands of sending services — analysts immediately know whether a failing source is "Mailchimp legitimately" or "random VPS." Triage time without this is materially worse.
- **Fix:** Externalize to a `ProviderIPs_CL` Log Analytics table seeded from community-maintained mappings (e.g., publicly-published ESP IP ranges, known forwarder ASN lists) plus our own additions. Schema: `(IPPrefix, ASN, OrgName, Category, Confidence, Source, LastUpdated)`. Workbook + detections join against it. Doubles as Z1b prep — promote out of Z1b since it's valuable standalone.

### D9. Domain inventory + subdomain auto-discovery (`DomainInventory_CL`)
- **Effort:** S · **Status:** ☐
- **Problem:** We group by `Domain` from incoming reports but don't track "domains expected in scope" vs "domains actually seen." Subdomain spoofing (e.g., `newsletter.corp.example.com` when only `corp.example.com` is monitored) goes unnoticed, and unexpected new domains in reports aren't surfaced.
- **Fix:** Add a `DomainInventory_CL` lookup table populated at deploy time (or via a small admin endpoint) with `(BaseDomain, OwnerTeam, ExpectedSubdomains, AddedAt)`. Workbook tile: "Unexpected domains in reports last 30d." Also derive `BaseDomain` and `IsSubdomain` columns at ingestion (overlaps with Z1b prep — same change).

### D10. Stakeholder email digest (scheduled push)
- **Effort:** S · **Status:** ☐
- **Problem:** The workbook is pull-only. Stakeholders who care about DMARC health (security leads, comms/marketing owners of sending domains) have to log in to Defender XDR / Azure portal. Commercial vendors send weekly PDF digests.
- **Fix:** Document a Logic App pattern (LAW scheduled query → render → email via Office 365 connector) and ship a template `infra/logicapp-digest.bicep`. Depends on D6 for the compact PDF-friendly workbook section.

---

## P1 — Test coverage gaps

### E1. Transient API failure tests
- **Effort:** M · **Status:** ☐ partial
- **Where:** [tests/DmarcHelpers.Tests.ps1](../tests/DmarcHelpers.Tests.ps1)
- **Problem:** Graph 429/503 retry tests exist, but there is still no coverage for DCR throttling, expired token mid-batch, or partial Log Analytics batch failure.
- **Fix:** Add Pester scenarios mocking DCR 429/503, expired managed identity token during send, and multi-batch partial failure that must not mark the message read.

### E2. Subscription renewal race
- **Effort:** S · **Status:** ☐
- **Problem:** No test exercises subscription expiring mid-batch.
- **Fix:** Add a scenario asserting graceful recreation.

### E3. Bicep deployment sandbox validation in CI
- **Effort:** M · **Status:** ☐
- **Where:** [.github/workflows/ci.yml](../.github/workflows/ci.yml)
- **Problem:** CI does syntax/lint only — no `az deployment group validate` or what-if.
- **Fix:** Add a job that runs validate against a dedicated sandbox subscription (or what-if only, no resources created).

### E4. Multi-domain-in-one-email + ZIP-of-many-GZ scenarios
- **Effort:** S · **Status:** ☐
- **Where:** [tests/GoldenDataset.Tests.ps1](../tests/GoldenDataset.Tests.ps1) + fixtures
- **Fix:** Add fixtures: 1 email containing 5 domain reports; 1 ZIP containing 10 GZ entries.

---

## P2 — Operational documentation

### F1. Incident response runbook
- **Effort:** M · **Status:** ☑
- **Scenarios:** subscription expired, DCR throttled, mailbox full, function failures, clientState rotation, accidental mass backfill.
- **Output:** `docs/RUNBOOK.md`.

### F2. Subscription health monitoring
- **Effort:** S · **Status:** ☐
- **Where:** [infra/alerts.bicep](../infra/alerts.bicep)
- **Fix:** Add a rule that warns when subscription expiry is < 7 days away (read from a custom App Insights metric emitted by `RenewGraphSubscription`).

### F3. Deployment validation script
- **Effort:** S · **Status:** ☑
- **Output:** `scripts/Test-DmarcDeployment.ps1` — asserts RBAC granted → subscription alive → DCR reachable → function responds → end-to-end smoke (synthetic event).

### F4. PII / retention / right-to-erasure summary
- **Effort:** S · **Status:** ☑
- **Output:** `docs/PRIVACY.md` — what's stored where, default retention, GDPR/CCPA handling, IP-as-PII note.

### F5. KQL recipe library
- **Effort:** M · **Status:** ☑
- **Output:** `docs/KQL_RECIPES.md` — 8–10 common queries (top failing IPs, domain pass-rate trend, ESP breakdown, override reason heatmap, etc.).

### F6. Data dictionary with sample values + null semantics
- **Effort:** S · **Status:** ☑ (ARCHITECTURE schema section extended with sample values and null semantics)
- **Where:** extend [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) data section with sample values and null/empty conventions per column.

### F7. clientState rotation procedure
- **Effort:** S · **Status:** ☑ (added to RUNBOOK zero-event-loss procedure)
- **Output:** section in `docs/RUNBOOK.md` describing zero-event-loss rotation.

### F8. Policy progression playbook
- **Effort:** S · **Status:** ☑
- **Output:** `docs/POLICY_PROGRESSION_PLAYBOOK.md` — guided migration from `p=none` → `p=quarantine` → `p=reject`. Includes: per-sender approval checklist, `pct` ramp schedule (10/25/50/100), readiness criteria (pass rate ≥ 98%, zero unclassified high-volume sources for 14d), rollback procedure, and KQL queries to evidence each gate. Commercial vendors offer this as a guided workflow; we cover the same ground via documentation backed by existing workbook tiles ("Per-Domain Risk Level", "Domain Readiness for Policy Enforcement").

---

## P2 — CI / release engineering

### G1. Automated GitHub Releases on version bump
- **Effort:** M · **Status:** ☐
- **Output:** GitHub Action that, on tag push, bundles Bicep + detections + workbook + scripts as a release artifact.

### G2. CodeQL + entropy-based secret scanning
- **Effort:** S · **Status:** ☑ (CodeQL workflow added; CI secret scan moved to TruffleHog)
- **Where:** [.github/workflows/](../.github/workflows/)
- **Fix:** Add `github/codeql-action` workflow; replace regex-only secret scan with TruffleHog or `detect-secrets`.

### G3. SBOM / SLSA provenance
- **Effort:** M · **Status:** ☐
- **Fix:** Generate CycloneDX SBOM during release; sign artifacts with sigstore.

### G4. Dependency pinning beyond GitHub Actions
- **Effort:** S · **Status:** ☐
- **Problem:** Dependabot is GitHub-Actions-only. PowerShell module versions and Bicep provider version aren't pinned.
- **Fix:** Add a `requirements.psd1` lockfile note + Bicep config pinning.

### G5. `mailboxUserId` GUID/UPN validation in Bicep
- **Effort:** S · **Status:** ☑ (`@minLength`/`@maxLength` + GUID/UPN format note in parameter description)
- **Where:** [infra/main.bicep:21](../infra/main.bicep#L21)
- **Fix:** `@minLength`/`@maxLength` + comment on accepted format.

### G6. Bump archived App Insights API version (moved from A8)
- **Effort:** S · **Status:** ☐
- **Where:** [infra/main.bicep:289](../infra/main.bicep#L289)
- **Problem:** `2020-02-02` is archived. **This is hygiene, not a correctness/security blocker** — the archived version still deploys and functions, so it was demoted from P0 to P2.
- **Fix:** Move to `2020-11-01-preview` (or current GA).

---

## P2 — Open-source readiness

### H1. `CODE_OF_CONDUCT.md` (in-repo, not external link)
- **Effort:** S · **Status:** ☑

### H2. `MAINTAINERS.md` with response SLA
- **Effort:** S · **Status:** ☑

### H3. `ROADMAP.md` (high-level — link to this BACKLOG)
- **Effort:** S · **Status:** ☑

### H4. Trademark / branding guidance for forks
- **Effort:** S · **Status:** ☑

### H5. Surface RUF privacy stance more prominently
- **Effort:** S · **Status:** ☑ (README feature list now calls out RUF privacy stance)
- **Where:** README "Why this design" section.

---

## P3 — Strategic / deferred (do NOT pick now)

### Z1a. Surface DMARC telemetry natively in the unified Defender portal (NOT blocked — promote)
- **Effort:** M · **Status:** ☐ PICK — directly serves the "alert/visualize in Defender XDR" goal
- **Correction:** The previous "blocked on Sentinel Data Lake" framing was stale. Microsoft Sentinel is **GA in the unified Microsoft Defender portal** (with or without Defender XDR / E5), and a custom `_CL` table from an onboarded workspace is **queryable in unified Advanced Hunting today** — `DMARCReports_CL` appears under the Schema tab "organized by solution." This needs no data lake.
- **Fix:**
	1. Document onboarding the Sentinel workspace to the Defender portal so analysts hunt `DMARCReports_CL` in Advanced Hunting alongside XDR tables.
	2. Convert the `detections/*.yaml` Sentinel analytics rules into **Defender XDR Custom Detection rules** (Microsoft's recommended path for new rules across Sentinel + XDR), preserving the existing IP/DNS/Account entity mappings.
- **Caveat:** Near-real-time (NRT) frequency is **not** available for Custom Detections that include Microsoft Sentinel (`_CL`) data — keep scheduled frequencies. Custom functions saved in Sentinel aren't usable in Custom Detections.
- **References:** https://learn.microsoft.com/azure/sentinel/microsoft-sentinel-defender-portal · https://learn.microsoft.com/defender-xdr/advanced-hunting-microsoft-defender · https://learn.microsoft.com/azure/sentinel/microsoft-365-defender-sentinel-integration
- **Migration driver:** Microsoft Sentinel in the **Azure portal retires 2027-03-31** — the Defender portal becomes the only surface, so this work is on the critical path regardless.

### Z1b. Advanced Hunting graph functions + Sentinel data lake (still deferred)
- **Status:** ⏸ Deferred — newer/limited capabilities distinct from Z1a.
- **Reference:** https://learn.microsoft.com/defender-xdr/advanced-hunting-graph
- **Prep work:** most schema-shape prep is tracked as standalone P1 items — D1 (`ASN`, `IPReputation`), D8 (`ProviderIPs_CL`), D9 (`BaseDomain`, `IsSubdomain`), B4 (`OverrideReasonCategory`). Remaining graph-specific work: edge metadata (`FirstSeen`/`LastSeen` per IP×Domain pair) and graph-function rewrites of the KQL. Note: after onboarding to the Sentinel **data lake**, auxiliary log tables move to data-lake KQL exploration rather than standard Advanced Hunting.

### Z2. Private Endpoints
- **Status:** ⏸ Tracked in separate GitHub issue.
- **Resources where PE is the only mitigation:** Key Vault, DCE, Log Analytics workspace ingestion/query endpoints, Storage Account (`blob`/`queue`/`table`), Function App SCM site.

### Z3. Multi-tenant / MSP rollup
- **Status:** ⏸ Out of scope (single-tenant only).

### Z4. RUF / forensic report ingestion
- **Status:** ⏸ Out of scope (privacy stance).

---

## Suggested first slice (1 week)

If pressed for an initial cut, I'd take **A1, A3, A4, A5, A6, A7, A9, B1, B2, F2, F3** — that closes the data-integrity holes, hardens the admin surface, and gives you operational visibility. Roughly 5–6 days of focused work. (A8 is now P2 hygiene, below.)
