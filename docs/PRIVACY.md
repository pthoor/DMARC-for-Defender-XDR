# Privacy and Data Handling

## Purpose

This document summarizes what DMARC Analyzer Azure stores, retention defaults, and privacy controls.

## Data collected

Primary table: DMARCReports_CL

Collected fields include:
- Report metadata (reporting org, report ID, report date range)
- Domain/authentication outcomes (SPF, DKIM, DMARC evaluation)
- Network/sender context (source IP, header/envelope domains)
- Operational correlation fields (SourceMessageId, IngestionRunId, MessageHash)

Not collected:
- Full email bodies
- Attachments beyond DMARC aggregate XML parsing
- RUF forensic per-message content

## PII considerations

- Source IP addresses may be personal data in some jurisdictions.
- HeaderFrom/EnvelopeFrom values may contain tenant-specific identifiers.
- Report metadata email/contact fields can contain personal or role mailbox addresses.

Treat DMARCReports_CL as potentially privacy-relevant telemetry.

## Retention defaults

- Log Analytics workspace retention is configurable at deployment (default 90 days).
- Keep retention aligned with legal, SOC, and incident-response requirements.
- Lower retention reduces exposure and storage cost.

## Access controls

- Runtime uses managed identity; no application secrets in code.
- Key Vault stores GRAPH_CLIENT_STATE and is accessed via RBAC.
- Admin functions should be gated with Easy Auth + Entra ID.
- Use least-privilege RBAC on workspace, function app, and Key Vault.

## GDPR/CCPA operational notes

1. Data minimization:
- Deploy with the shortest retention that still supports security operations.

2. Right to erasure:
- Data is security telemetry, not customer content, but regional obligations may still apply.
- Erasure is handled by retention policy expiration or scoped purge operations in LAW.

3. Access requests:
- Restrict who can query DMARCReports_CL.
- Log privileged access and changes through Azure diagnostics.

4. Cross-border transfer:
- Select Azure region and workspace placement per data residency requirements.

## Privacy stance on RUF

RUF is intentionally out of scope. Forensic/failure reports can contain message-level personal data and increase compliance risk. This project processes aggregate RUA reports only.
