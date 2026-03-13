using 'main.bicep'

param baseName = 'dmarc'
param mailboxUserId = readEnvironmentVariable('MAILBOX_USER_ID', '')
param graphClientState = readEnvironmentVariable('GRAPH_CLIENT_STATE', '')
param retentionInDays = 90

// Optional: use an existing Log Analytics workspace
// param existingWorkspaceId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>'

// Optional: deploy Azure Monitor alert rules for DMARC anomaly detection
// param deployAlerts = true
// param alertActionGroupId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/actionGroups/<name>'
