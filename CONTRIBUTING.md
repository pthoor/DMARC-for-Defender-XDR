# Contributing to DMARC Analyzer for Azure

Thank you for your interest in contributing! 🎉

## How to Report Bugs

1. Check [existing issues](https://github.com/pthoor/DMARC-Analyzer-Azure/issues) first to avoid duplicates.
2. Open a new issue using the **🐛 Bug Report** template.
3. Include clear reproduction steps, expected vs. actual behavior, and relevant logs.

## How to Suggest Features

1. Open a new issue using the **💡 Feature Request** template.
2. Describe the problem/use case, the proposed solution, and any alternatives you considered.

## How to Submit Code

1. **Fork** the repository and clone your fork locally.
2. **Create a feature branch** from `main`:
   ```
   git checkout -b feature/my-change
   ```
3. **Make your changes**, writing or updating tests as needed.
4. **Verify locally** (see [Local Development Setup](#local-development-setup) below).
5. **Open a Pull Request** targeting `main` and fill out the PR template.
6. Address any review feedback and wait for approval.

> **Note:** @pthoor reviews all PRs. Please be patient — every PR will receive a thorough review.

## Local Development Setup

### Run Pester tests
```powershell
Invoke-Pester
```

### Lint PowerShell code
```powershell
# Lint src directory
Invoke-ScriptAnalyzer -Path ./src -Recurse -Severity Warning,Error

# Lint scripts directory
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Severity Warning,Error
```

### Validate Bicep
```bash
az bicep build --file infra/main.bicep
```

## Code Standards

- **PSScriptAnalyzer** — All PowerShell code must pass with no warnings or errors at `Warning` severity and above.
- **Bicep** — All Bicep files must compile without errors (`az bicep build`).
- **Error handling** — Use `try/catch` blocks for all external calls and resource access.
- **No secrets** — Never commit credentials, passwords, API keys, or connection strings. Use Azure Key Vault references.

## Code of Conduct

This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) Code of Conduct. By participating, you agree to uphold these standards.
