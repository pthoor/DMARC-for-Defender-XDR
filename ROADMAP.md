# Roadmap

This roadmap tracks the high-level direction of DMARC Analyzer Azure.

## Near term

- Close remaining correctness and security follow-through: workbook/alert `DmarcPassEffective` consistency (count-weighted), Easy Auth admin endpoint cutover, and the archived App Insights API version (hygiene).
- Surface DMARC telemetry natively in the unified Microsoft Defender portal: onboard the Sentinel workspace so `DMARCReports_CL` is queryable in Advanced Hunting, and convert the detection rules to Defender XDR Custom Detections. This is the primary "alert in Defender XDR" surface — distinct from the Azure Monitor alert rules, which are an ops/notification channel only.
- Add suppression primitives and domain inventory so analysts can separate expected onboarding/maintenance from real sender drift.
- Build a **minimal DNS posture collector** (timer Function → `DomainPosture_CL`) that resolves only the DMARC-authentication records, enabling the checks that explain pass/fail: SPF lookup-count exhaustion, DKIM key strength/rotation, and DMARC record validity. Scoped to DMARC auth — not a transport-security prober.
- Expand operational monitoring with Graph subscription health and deployment validation coverage.

## Mid term

- Add the DMARC-authentication DNS checks on top of the collector: SPF 10-lookup exhaustion warnings, DKIM key strength/rotation (including flagging Exchange Online's default RSA-1024 selectors), and DMARC record syntax validation.
- Introduce sender/provider enrichment, curated classification data, and executive reporting/digest automation.

> Scope note: transport security (MTA-STS, DANE, TLS-RPT) and brand display (BIMI) are **out of scope** — a different security domain and audience than DMARC anti-spoofing, not SOC-actionable in Defender XDR, and well covered by existing tooling (Exchange Admin Center transit-security reports, the Remote Connectivity Analyzer, internet.nl/Hardenize/MECSA). "Full-enforcement / BIMI readiness" is already derivable from ingested policy data via the policy-progression playbook.

## Long term

- Adopt Advanced Hunting **graph functions** and Sentinel **data lake** capabilities once they fit the schema (the unified-portal hunting + Custom Detections work above is near term and already available — only graph/data-lake specifics remain long term). Microsoft Sentinel in the Azure portal retires 2027-03-31, making the Defender portal the migration target.
- Expand DMARC analytics and visibility features while keeping privacy constraints and the anti-spoofing focus.

## Detailed planning

For the full prioritized list, see docs/BACKLOG.md.
