using 'main.bicep'

param baseName = 'dmarc'
param mailboxUserId = readEnvironmentVariable('MAILBOX_USER_ID', '')
param graphClientState = readEnvironmentVariable('GRAPH_CLIENT_STATE', '')
param retentionInDays = 90

// Optional: use an existing Log Analytics workspace for DMARC data (DMARCReports_CL table)
// param existingWorkspaceId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<dmarc-law-name>'

// Optional: route audit/diagnostic logs (Key Vault, Function App, Storage) to a different LAW.
// Use this when you have a Sentinel-connected LAW or a separate operational LAW.
// Omit (or leave empty) to send diagnostic logs to the same workspace as DMARC data.
// param diagnosticsWorkspaceId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<sentinel-law-name>'

// Optional: deploy Azure Monitor alert rules for DMARC anomaly detection
// param deployAlerts = true
// param alertActionGroupId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/actionGroups/<name>'
