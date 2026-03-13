# DMARC Detection Rules for Microsoft Defender XDR

Sentinel-compatible YAML detection rules for DMARC anomaly detection. These follow the [Azure Sentinel Analytics Rule schema](https://github.com/Azure/Azure-Sentinel) and can be deployed via:

- **Sentinel GitHub connector** (CI/CD pipeline)
- **[XDRConverter](https://github.com/f-bader/XDRConverter)** (convert to Defender XDR Custom Detection Rules)
- **Sentinel REST API** / ARM templates
- **Manual import** in the Defender portal

## Available Detections

| File | Description | Severity | Frequency |
|------|-------------|----------|-----------|
| `spoofing-detection.yaml` | High-volume DMARC failures from a single IP | Medium | 1h |
| `new-unauthorized-sender.yaml` | New source IPs failing authentication | Medium | 6h |
| `passrate-anomaly.yaml` | Per-domain pass rate drops below 30-day baseline | Medium | 1h |
| `policy-override-abuse.yaml` | Unusual DMARC policy override reasons | Low | 6h |

## Prerequisites

- Microsoft Sentinel workspace connected to Defender XDR portal
- `DMARCReports_CL` custom table with DMARC report data ingested by the DMARC Analyzer pipeline

## Deployment

### Option 1: Sentinel Repositories (recommended)

Connect your GitHub repository to Sentinel via **Settings > Repositories** and point to the `detections/` folder. Rules will be deployed and kept in sync automatically.

### Option 2: XDRConverter

```powershell
# Convert to Defender XDR Custom Detection Rules
Install-Module -Name XDRConverter
Get-ChildItem ./detections/*.yaml | ForEach-Object {
    Convert-SentinelToXDR -Path $_.FullName
}
```

### Option 3: Manual

1. Open the [Microsoft Defender portal](https://security.microsoft.com)
2. Navigate to **Hunting** > **Custom detection rules**
3. Create a new rule and paste the KQL query from the `query:` field
4. Set frequency, severity, and entity mappings as defined in the YAML

## Customization

- Adjust thresholds (`FailedMessages >= 50`, pass rate percentages) to match your environment
- Add `| where Domain == "yourdomain.com"` filters for specific domains
- Change `severity` based on your risk tolerance
