# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| main    | ✅        |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly:

1. **Do NOT open a public GitHub issue** for security vulnerabilities.
2. Use [GitHub Private Vulnerability Reporting](https://github.com/pthoor/DMARC-Analyzer-Azure/security/advisories/new) to report the issue privately.
3. Provide as much detail as possible, including steps to reproduce and potential impact.

You can expect:
- **Acknowledgment within 48 hours**
- **A plan for a fix within 7 days**
- Credit in the release notes (unless you prefer to remain anonymous)

## Project Security Design

This project is built with security as a first-class concern:

- **Managed Identity** — The Azure Function uses a system-assigned Managed Identity. No client secrets or passwords are stored in configuration.
- **No client secrets** — OAuth flows use Managed Identity exclusively; no credentials are embedded in code or settings.
- **Key Vault** — Sensitive values (e.g., `GRAPH_CLIENT_STATE`) are stored in Azure Key Vault and referenced via `@Microsoft.KeyVault` references in the Function App settings.
- **DTD protection** — XML parsing explicitly disables DTD processing to prevent XXE attacks.
- **Input validation** — All incoming payloads are validated (size limits, client state verification, schema checks) before processing.
- **CI hardened with SHA-pinned actions** — The CI pipeline uses GitHub Actions pinned to full commit SHAs (not mutable version tags) to prevent supply-chain attacks.
