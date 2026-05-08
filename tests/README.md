# DMARC Analyzer - Pester Test Configuration

## Overview

This repository includes comprehensive Pester tests to verify PowerShell scripts work as expected.

## Test Coverage

### DmarcHelpers Module Tests (`tests/DmarcHelpers.Tests.ps1`)
- **Module Import**: Validates the module loads correctly and exports all required functions
- **Get-ManagedIdentityToken**: Tests environment variable requirements and validation
- **ConvertFrom-DmarcXml**: Tests XML parsing, multi-record handling, invalid XML, DTD protection (security)
- **Expand-DmarcAttachments**: Tests XML, GZIP, ZIP extraction, size limits, and file type filtering
- **Send-DmarcRecordsToLogAnalytics**: Tests configuration validation

### Setup Scripts Tests
- **New-GraphSubscription.ps1** (`tests/New-GraphSubscription.Tests.ps1`):
  - Script structure and syntax validation
  - Parameter validation
  - Security considerations (clientState handling)
  - Graph API integration
  - User experience checks

- **Grant-MIExchangeRBAC.ps1** (`tests/Grant-MIExchangeRBAC.Tests.ps1`):
  - Script structure and syntax validation
  - Managed Identity operations
  - Microsoft Graph API role assignments
  - Exchange Online RBAC configuration
  - Security validations (least privilege, scope restrictions)
  - Error handling

### Azure Function Scripts Tests (`tests/FunctionScripts.Tests.ps1`)
- **DmarcReportProcessor/run.ps1**:
  - Event Grid trigger structure
  - Security validations (client state)
  - Event processing and error handling
  - Logging patterns

- **RenewGraphSubscription/run.ps1**:
  - Timer trigger structure
  - Configuration validation
  - Subscription renewal logic
  - Error handling (404 handling)

- **CatchupProcessor/run.ps1**:
  - Timer trigger structure
  - Message processing logic
  - Individual failure handling
  - Success/failure tracking

## Running Tests

### Run All Tests
```powershell
Invoke-Pester -Path ./tests
```

### Run Specific Test File
```powershell
Invoke-Pester -Path ./tests/DmarcHelpers.Tests.ps1
```

### Run with Detailed Output
```powershell
Invoke-Pester -Path ./tests -Output Detailed
```

### Run with Code Coverage
```powershell
Invoke-Pester -Path ./tests -CodeCoverage ./src/function/modules/*.psm1
```

## Test Results

All tests validate:
- ✅ Proper PowerShell syntax
- ✅ Required parameters and validation
- ✅ Security controls (DTD protection, clientState validation, size limits)
- ✅ Error handling patterns
- ✅ Logging and user experience
- ✅ Integration patterns (Graph API, Exchange RBAC)

### Versioning & KQL Guardrails (`tests/Versioning.Tests.ps1`)
- SemVer metadata consistency (`VERSION`, detection `version:` fields, workbook release marker)
- Static guardrails for divide-by-zero protections in workbook KPI/compliance queries
- Alert logic validation for DMARC pass-rate semantics (SPF **or** DKIM pass)

## Requirements

- PowerShell 7.4+
- Pester 5.7+ (included in PowerShell 7)

## Test Philosophy

These tests focus on:
1. **Structure validation**: Ensuring scripts follow proper patterns
2. **Security verification**: Confirming security controls are in place
3. **Error handling**: Validating proper error handling and logging
4. **Integration patterns**: Checking correct API usage and configuration

Tests do NOT require:
- Live Azure resources
- Active Azure credentials
- External API connectivity

This allows tests to run in CI/CD pipelines without authentication.
