# DMARC Analyzer Azure - Open Source Readiness Audit

**Audit date:** 2026-05-08  
**Scope:** DMARC logic gaps, KQL correctness, metric correctness, versioning readiness, Sentinel Workbook Graph Query Language feasibility.

## 1) File-by-file findings (with risk)

| File | Findings | Risk |
|---|---|---|
| `detections/spoofing-detection.yaml` | Query did not normalize `MessageCount` nulls and did not enforce non-empty `SourceIP`. | Medium |
| `detections/new-unauthorized-sender.yaml` | Known-IP baseline could include empty IPs; message math had no null hardening. | Medium |
| `detections/passrate-anomaly.yaml` | Pass-rate math relied on raw `MessageCount` values without null-safe normalization. | Medium |
| `detections/policy-override-abuse.yaml` | IP entity mapping pointed to an array field (`SourceIPs`) instead of scalar IP; case sensitivity could miss known benign reasons. | High |
| `workbook/dmarc-workbook.json` | Multiple KPI/score queries had divide-by-zero risk, null-count risk, and weak one-row join semantics; some daily metrics binned on nullable `ReportDateRangeBegin`. | High |
| `infra/alerts.bicep` | DMARC pass-rate alert used SPF **and** DKIM pass semantics (too strict), and volume spike query used a brittle self-join expression. | High |
| `README.md` | No explicit release/version operations guidance for multi-tenant rollouts. | Medium |

## 2) Corrections implemented (KQL and calculations)

### Detection assets
- Added `MessageCountSafe = tolong(coalesce(MessageCount, 0))` before aggregations.
- Added empty-field guards (`isnotempty(SourceIP)` where required).
- Normalized pass/fail checks with `tolower(...)` in detection rules sensitive to case variance.
- Corrected policy override entity mapping from array (`SourceIPs`) to scalar (`SampleIP`) for Sentinel entity mapping correctness.

### Workbook assets
Updated core KPI/scoring/anomaly queries to:
- Guard all denominator divisions with `iff(denominator > 0, ..., 0.0)`.
- Normalize potentially null `MessageCount` inputs.
- Use robust one-row joins with explicit join keys.
- Improve time binning safety using `coalesce(ReportDateRangeBegin, TimeGenerated)` for daily trend metrics.

### Alert assets (`infra/alerts.bicep`)
- Pass-rate alert now uses DMARC semantics: pass when **SPF or DKIM** passes (not both).
- Added null-safe message normalization for alert math.
- Replaced brittle volume-spike self-join with explicit keyed join.

## 3) Versioning strategy for multi-tenant deployments

### SemVer policy
- Use `MAJOR.MINOR.PATCH` in Git tags and artifact metadata.
- `MAJOR`: breaking query/schema/deployment changes.
- `MINOR`: backward-compatible features/new workbook visuals/new detections.
- `PATCH`: bug fixes and calculation corrections.

### Changelog strategy
- Keep root `CHANGELOG.md` with **Added / Changed / Fixed / Breaking** sections per release.
- Record migration notes whenever `MAJOR` changes occur.

### Where version metadata is embedded
- Root `VERSION` file (`1.1.0`) as source of truth.
- Detection YAML `version:` fields (`1.1.0`).
- Workbook header includes release marker (`Workbook release: v1.1.0`).
- GitHub release tag should match `VERSION` (`v1.1.0`).

### Multi-tenant operational guidance
- Track tenant deployments by storing `{tenantId, workspaceId, deployedVersion, deployedAt}` in your release operations process.
- Require version match checks before tenant updates.
- Rollback by redeploying previous tagged artifacts.

## 4) Sentinel Workbook Graph Query Language feasibility matrix

| Scenario | Current support in Sentinel Workbook | Feasibility | Recommended approach |
|---|---|---|---|
| Log Analytics DMARC analytics (`DMARCReports_CL`) | Native via KQL | ✅ Supported | Keep KQL as authoritative path. |
| Workbook parameter/resource inventory queries (`microsoft.resourcegraph/resources`) | Supported through Azure Resource Graph query provider | ✅ Supported | Continue using Resource Graph for resource pickers only. |
| Microsoft Graph Query Language (Graph API query syntax) directly in workbook data visual queries | Not natively supported as a workbook query engine for Sentinel workbook visuals | ❌ Not currently practical as primary path | Use KQL in workbook; ingest Graph-derived data into Log Analytics if needed. |
| Experimental preview graph-style experiences in Sentinel ecosystem | Preview/region-dependent and not a stable workbook replacement | ⚠️ Limited/conditional | Treat as optional experiment behind documentation and fallback. |

### Fallback guidance
1. Keep workbook visuals KQL-only for deterministic behavior.
2. If graph-preview capability is tested, run side-by-side parity checks against KQL outputs.
3. On unsupported tenants/regions, auto-fallback to KQL queries and document this behavior.

## 5) Actionable remediation checklist and prioritized roadmap

### Immediate (P0)
- [x] Fix high-risk KQL math and entity mapping issues in detections/workbook/alerts.
- [x] Establish SemVer + changelog + embedded version metadata.
- [x] Add lightweight metadata consistency tests.

### Near-term (P1)
- [ ] Add a small synthetic DMARC golden dataset and expected KPI outputs for regression validation.
- [ ] Add query parity checks for key metrics (pass rate, compliance score, anomaly thresholds).
- [ ] Add release workflow checks that block if `VERSION` and detection/workbook metadata diverge.

### Medium-term (P2)
- [ ] Add duplicate suppression telemetry (by `ReportId` + source) to reduce ingestion skew.
- [ ] Add data freshness SLO alerting for stalled reporters.
- [ ] Add explicit workbook notes for forwarded/ARC edge cases to reduce false positives during policy progression.

### Optional/Experimental (P3)
- [ ] Prototype Graph query parity pipeline outside workbook rendering path.
- [ ] Publish support matrix by tenant/region and maintain opt-in preview guidance.
