# DMARC Analyzer Azure — Improvement Backlog

Captured from a code/infra/workbook/ops audit on 2026-05-10. Use this as a prioritization scratchpad — mark items with **PICK** / **DEFER** / **WONT** and re-order as needed.

**Legend**
- **Severity:** P0 (correctness/security blocker) · P1 (high-value gap) · P2 (quality / hardening) · P3 (strategic / deferred)
- **Effort:** S (<½ day) · M (½–2 days) · L (>2 days)
- **Status:** ☐ open · ☑ done · ⏸ deferred

**Locked decisions (do not relitigate)**
- Single-tenant only — one Function App per M365 tenant
- RUF (forensic) reports stay off; document the privacy stance more prominently
- Private Endpoints deferred (separate GitHub issue) — but call out resources where PE is the only mitigation
- Migration to Defender XDR Advanced Hunting graph functions is the long-term query target — blocked on Sentinel Data Lake

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

### A8. Bump archived App Insights API version
- **Effort:** S · **Status:** ☐
- **Where:** [infra/main.bicep:289](../infra/main.bicep#L289)
- **Problem:** `2020-02-02` is archived.
- **Fix:** Move to `2020-11-01-preview` (or current GA).

### A9. Capture per-record alignment outcome
- **Effort:** S · **Status:** ☑ (Aligned_dkim / Aligned_spf / DmarcPass materialized at ingestion; detection rules updated to use DmarcPass directly)
- **Where:** [src/function/modules/DmarcHelpers.psm1:572-635](../src/function/modules/DmarcHelpers.psm1#L572-L635)
- **Problem:** Schema stores `PolicyPublished_adkim`/`aspf` (the policy *mode*) but not the per-record alignment *outcome*. RFC 7489 DMARC pass = `(DKIM auth pass AND DKIM aligned) OR (SPF auth pass AND SPF aligned)`. Today every consumer has to reimplement alignment logic.
- **Fix:** Compute and store `Aligned_dkim` / `Aligned_spf` (bool) and a single `DmarcPass` (bool) at ingestion. Update KQL in workbook + detections to use `DmarcPass` directly.

---

## P1 — DMARC correctness & detection tuning

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

## P1 — Adjacent email-auth protocols (verified 2026-05 as supported by EXO)

### C1. TLS-RPT report ingestion
- **Effort:** M · **Status:** ☐
- **Why:** TLS-RPT (RFC 8460) reports arrive in a mailbox via email — same delivery mechanism as DMARC RUA. Microsoft sends them. Reuses the existing pipeline (Exchange mailbox → Graph notification → Function → Log Analytics) almost as-is.
- **Fix:** Add a `TLSReports_CL` table + DCR + parser in [DmarcHelpers.psm1](../src/function/modules/DmarcHelpers.psm1) (or a sibling module). Add a workbook tab.
- **Caveat:** Microsoft sends only to the first `rua` endpoint — single mailbox is fine for this design.

### C2. MTA-STS posture monitoring
- **Effort:** S · **Status:** ☐
- **Why:** EXO enforces remote MTA-STS policies on outbound mail (always-on) and supports tenant-side publishing. We should monitor whether *our* domains have valid published policies.
- **Fix:** A small script + workbook tile that resolves `_mta-sts.<domain>` and `mta-sts.<domain>/.well-known/mta-sts.txt` for each domain in scope and surfaces policy mode/version/staleness.

### C3. BIMI eligibility check (NOT display)
- **Effort:** S · **Status:** ☐
- **Why:** Outlook/M365 don't GA-render BIMI yet (April 2026 status: limited rollout, no GA date). But Gmail/Yahoo/Apple/Fastmail do, and BIMI eligibility (`p=quarantine`/`reject` + `pct=100`) is a useful proxy for DMARC enforcement health.
- **Fix:** A workbook tile per domain showing eligibility status; defer VMC/SVG validation until Microsoft renders BIMI.

---

## P1 — Visualization feature parity vs Valimail / dmarcian / EasyDMARC

### D1. Threat-intel enrichment of source IPs (ASN, geo, reputation)
- **Effort:** M · **Status:** ☐
- **Problem:** Workbook uses `geo_info_from_ip_address()` only. No ASN, no reputation, no threat-feed correlation.
- **Fix:** Add `ASN` + `ASNOrg` columns at ingestion (resolve via a periodic enrichment job using a static IP→ASN dataset, or external API at query time). Threat-feed correlation can come later via a separate `ThreatIntel_CL`/MISP join.

### D2. SPF lookup-count exhaustion warning
- **Effort:** S · **Status:** ☐
- **Problem:** No early warning when an SPF record is approaching the 10-lookup limit (`permerror`).
- **Fix:** Periodic SPF record health check tile in the workbook + an alert rule.

### D3. DMARC record syntax validator
- **Effort:** S · **Status:** ☐
- **Problem:** No surface-area for syntactically-broken records (missing RUA, malformed `pct`, dangling `sp`, deprecated `fo`).
- **Fix:** A workbook tile per domain that resolves the `_dmarc.<domain>` TXT and validates structure.

### D4. DKIM key aging / algorithm-downgrade alerts
- **Effort:** S · **Status:** ☐
- **Where:** workbook lines ~1596–1641 already track first/last seen per selector
- **Fix:** Add an alert rule for selectors not rotated in N days; flag RSA-1024 and weak algorithms.

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
- **Fix:** Externalize to a `ProviderIPs_CL` Log Analytics table seeded from community-maintained mappings (e.g., publicly-published ESP IP ranges, known forwarder ASN lists) plus our own additions. Schema: `(IPPrefix, ASN, OrgName, Category, Confidence, Source, LastUpdated)`. Workbook + detections join against it. Doubles as Z1 prep — promote out of Z1 since it's valuable standalone.

### D9. Domain inventory + subdomain auto-discovery (`DomainInventory_CL`)
- **Effort:** S · **Status:** ☐
- **Problem:** We group by `Domain` from incoming reports but don't track "domains expected in scope" vs "domains actually seen." Subdomain spoofing (e.g., `newsletter.corp.example.com` when only `corp.example.com` is monitored) goes unnoticed, and unexpected new domains in reports aren't surfaced.
- **Fix:** Add a `DomainInventory_CL` lookup table populated at deploy time (or via a small admin endpoint) with `(BaseDomain, OwnerTeam, ExpectedSubdomains, AddedAt)`. Workbook tile: "Unexpected domains in reports last 30d." Also derive `BaseDomain` and `IsSubdomain` columns at ingestion (overlaps with Z1 prep — same change).

### D10. Stakeholder email digest (scheduled push)
- **Effort:** S · **Status:** ☐
- **Problem:** The workbook is pull-only. Stakeholders who care about DMARC health (security leads, comms/marketing owners of sending domains) have to log in to Defender XDR / Azure portal. Commercial vendors send weekly PDF digests.
- **Fix:** Document a Logic App pattern (LAW scheduled query → render → email via Office 365 connector) and ship a template `infra/logicapp-digest.bicep`. Depends on D6 for the compact PDF-friendly workbook section.

---

## P1 — Test coverage gaps

### E1. Transient API failure tests
- **Effort:** M · **Status:** ☐
- **Where:** [tests/DmarcHelpers.Tests.ps1](../tests/DmarcHelpers.Tests.ps1)
- **Problem:** No test for Graph 429/503 retry, DCR throttling, expired token mid-batch, partial batch failure.
- **Fix:** Add Pester scenarios mocking these.

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

### Z1. Defender XDR Advanced Hunting graph migration
- **Status:** ⏸ Blocked on Sentinel Data Lake provisioning.
- **Reference:** https://learn.microsoft.com/en-us/defender-xdr/advanced-hunting-graph
- **When unblocked, prep work:** most schema-shape prep is now tracked as standalone P1 items — D1 (`ASN`, `IPReputation`), D8 (`ProviderIPs_CL`), D9 (`BaseDomain`, `IsSubdomain`), B4 (`OverrideReasonCategory`). Remaining Z1-specific work: edge metadata (`FirstSeen`/`LastSeen` per IP×Domain pair) and graph-function rewrites of the KQL.

### Z2. Private Endpoints
- **Status:** ⏸ Tracked in separate GitHub issue.
- **Resources where PE is the only mitigation:** Key Vault, DCE, Log Analytics workspace ingestion/query endpoints, Storage Account (`blob`/`queue`/`table`), Function App SCM site.

### Z3. Multi-tenant / MSP rollup
- **Status:** ⏸ Out of scope (single-tenant only).

### Z4. RUF / forensic report ingestion
- **Status:** ⏸ Out of scope (privacy stance).

---

## Suggested first slice (1 week)

If pressed for an initial cut, I'd take **A1, A3, A4, A5, A6, A7, A8, A9, B1, B2, F2, F3** — that closes the data-integrity holes, hardens the admin surface, and gives you operational visibility. Roughly 5–6 days of focused work.
