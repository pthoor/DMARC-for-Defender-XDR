// ──────────────────────────────────────────────────────────────
// DMARC-to-Sentinel Pipeline — Infrastructure
// Deploys: Log Analytics, Custom Table, DCR, Storage, App Insights,
//          Function App (PowerShell 7.4, Flex Consumption) with Managed Identity,
//          and RBAC role assignment for Logs Ingestion.
// ──────────────────────────────────────────────────────────────

targetScope = 'resourceGroup'

// ── Parameters ──

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Base name used to derive resource names (e.g., "dmarc").')
@minLength(3)
@maxLength(16)
param baseName string = 'dmarc'

@description('Object ID (GUID) or user principal name (UPN) of the shared mailbox user in Entra ID.')
@minLength(3)
@maxLength(255)
param mailboxUserId string

@description('Random secret used to validate Graph change notifications.')
@secure()
param graphClientState string

@description('Retention period in days for the Log Analytics workspace.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90

@description('Use an existing Log Analytics workspace. Leave empty to create a new one.')
param existingWorkspaceId string = ''

@description('''Resource ID of the Log Analytics workspace that receives diagnostic/audit logs from the Function App, Key Vault, and Storage Account.

Leave empty (default) to send diagnostic logs to the same workspace as DMARC data — simplest option for single-workspace deployments.

Set to a different workspace when:
  • You have a Sentinel-connected LAW and want audit events to feed into Sentinel analytics rules and incidents.
  • You separate operational/security logs from application data for cost or retention reasons.

Example: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<sentinel-law-name>
''')
param diagnosticsWorkspaceId string = ''

@description('Optional: Resource ID of an existing Application Insights instance.')
param existingAppInsightsId string = ''

@description('Deploy Event Grid partner configuration to authorize Microsoft Graph API. Disable if you already have a partner configuration in this resource group with Graph API authorized.')
param deployPartnerConfig bool = true

@description('Deploy Azure Monitor scheduled query alert rules for DMARC anomaly detection.')
param deployAlerts bool = false

@description('Resource ID of an Action Group to receive alert notifications. Leave empty to create alerts without notifications.')
param alertActionGroupId string = ''

@description('Deployment timestamp for partner authorization expiration. Do not set manually.')
param deploymentTime string = utcNow()

@description('''Allow shared key (account key) access to the storage account.

Set to false (default) for production deployments that use CI/CD pipelines or the Azure Portal to publish the function app — Managed Identity is used for all runtime storage access.

Set to true only when using the Azure Functions Core Tools CLI (func azure functionapp publish) locally, which requires shared key access to upload the deployment package. Disable again after the initial publish if possible.
''')
param allowStorageSharedKeyAccess bool = false

@description('''Block external access to the SCM (Kudu) management endpoint.

When true (default): all access to https://{app}.scm.azurewebsites.net is denied. This is the recommended setting for production. Flex Consumption deployments use blob storage and do not need Kudu. Application logs are available through Application Insights.

When false: the SCM endpoint is publicly reachable. Use only in non-production environments for debugging.
''')
param restrictScmAccess bool = true

@description('''Client ID of the Entra ID app registration whose bearers may call the admin HTTP functions (BackfillProcessor, SetupHelper). When set, Easy Auth is enabled on the Function App and callers must present a valid Entra ID bearer token.

IMPORTANT: Keep authLevel set to "admin" in BackfillProcessor/function.json and SetupHelper/function.json even after enabling Easy Auth. This provides defense-in-depth: if Easy Auth is ever misconfigured or removed, the function-level master key remains as a second layer of protection. Do NOT change authLevel to "anonymous".
''')
param adminEntraAppClientId string = ''

// ── Variables ──

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var workspaceName = '${baseName}-law-${uniqueSuffix}'
var dcrName = '${baseName}-dcr-${uniqueSuffix}'
var storageName = toLower(take('${baseName}st${uniqueSuffix}', 24))
var appInsightsName = '${baseName}-ai-${uniqueSuffix}'
var hostingPlanName = '${baseName}-plan-${uniqueSuffix}'
var functionAppName = '${baseName}-func-${uniqueSuffix}'
// Key Vault names must be 3-24 characters, all lowercase, start with a letter, and contain only letters, numbers, and '-'.
var keyVaultBase = toLower(take(baseName, 24 - 2 - length(uniqueSuffix)))
var keyVaultName = '${keyVaultBase}kv${uniqueSuffix}'
var dceName = '${baseName}-dce-${uniqueSuffix}'
var customTableName = 'DMARCReports_CL'
var streamName = 'Custom-${customTableName}'
var deploymentContainerName = 'deploymentpackage'

// Monitoring Metrics Publisher role definition ID
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Key Vault Secrets User role definition ID
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// Storage RBAC role definition IDs (for MI-based storage auth)
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ── Log Analytics Workspace ──

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (empty(existingWorkspaceId)) {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

var workspaceId = empty(existingWorkspaceId) ? workspace.id : existingWorkspaceId

// Diagnostic logs (Key Vault, Function App, Storage) go here. Defaults to the DMARC LAW;
// set diagnosticsWorkspaceId to a Sentinel or ops LAW to route audit events separately.
var diagnosticsWorkspaceResourceId = empty(diagnosticsWorkspaceId) ? workspaceId : diagnosticsWorkspaceId

var resolvedWorkspaceName = empty(existingWorkspaceId)
  ? workspaceName
  : last(split(existingWorkspaceId, '/'))

// ── Custom Table ──

resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: '${resolvedWorkspaceName}/${customTableName}'
  properties: {
    schema: {
      name: customTableName
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'ReportOrgName', type: 'string' }
        { name: 'ReportEmail', type: 'string' }
        { name: 'ReportExtraContactInfo', type: 'string' }
        { name: 'ReportId', type: 'string' }
        { name: 'SourceMessageId', type: 'string' }
        { name: 'IngestionRunId', type: 'string' }
        { name: 'DuplicateTelemetryKey', type: 'string' }
        { name: 'ReportDateRangeBegin', type: 'dateTime' }
        { name: 'ReportDateRangeEnd', type: 'dateTime' }
        { name: 'Domain', type: 'string' }
        { name: 'PolicyPublished_p', type: 'string' }
        { name: 'PolicyPublished_sp', type: 'string' }
        { name: 'PolicyPublished_pct', type: 'int' }
        { name: 'PolicyPublished_adkim', type: 'string' }
        { name: 'PolicyPublished_aspf', type: 'string' }
        { name: 'PolicyPublished_fo', type: 'string' }
        { name: 'SourceIP', type: 'string' }
        { name: 'MessageCount', type: 'int' }
        { name: 'PolicyEvaluated_disposition', type: 'string' }
        { name: 'PolicyEvaluated_dkim', type: 'string' }
        { name: 'PolicyEvaluated_spf', type: 'string' }
        { name: 'PolicyEvaluated_reason_type', type: 'string' }
        { name: 'PolicyEvaluated_reason_comment', type: 'string' }
        { name: 'OverrideReasonCategory', type: 'string' }
        { name: 'HeaderFrom', type: 'string' }
        { name: 'EnvelopeFrom', type: 'string' }
        { name: 'EnvelopeTo', type: 'string' }
        { name: 'DkimResult', type: 'string' }
        { name: 'DkimDomain', type: 'string' }
        { name: 'DkimSelector', type: 'string' }
        { name: 'SpfResult', type: 'string' }
        { name: 'SpfDomain', type: 'string' }
        { name: 'SpfScope', type: 'string' }
        { name: 'DkimAuthResults', type: 'string' }
        { name: 'SpfAuthResults', type: 'string' }
        { name: 'RecordIndex', type: 'int' }
        { name: 'MessageHash', type: 'string' }
        { name: 'Aligned_dkim', type: 'boolean' }
        { name: 'Aligned_spf', type: 'boolean' }
        { name: 'DmarcPass', type: 'boolean' }
      ]
    }
    retentionInDays: retentionInDays
  }
  dependsOn: empty(existingWorkspaceId) ? [workspace] : []
}

// ── Data Collection Endpoint ──

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ── Data Collection Rule (kind: Direct) ──

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'ReportOrgName', type: 'string' }
          { name: 'ReportEmail', type: 'string' }
          { name: 'ReportExtraContactInfo', type: 'string' }
          { name: 'ReportId', type: 'string' }
          { name: 'SourceMessageId', type: 'string' }
          { name: 'IngestionRunId', type: 'string' }
          { name: 'DuplicateTelemetryKey', type: 'string' }
          { name: 'ReportDateRangeBegin', type: 'datetime' }
          { name: 'ReportDateRangeEnd', type: 'datetime' }
          { name: 'Domain', type: 'string' }
          { name: 'PolicyPublished_p', type: 'string' }
          { name: 'PolicyPublished_sp', type: 'string' }
          { name: 'PolicyPublished_pct', type: 'int' }
          { name: 'PolicyPublished_adkim', type: 'string' }
          { name: 'PolicyPublished_aspf', type: 'string' }
          { name: 'PolicyPublished_fo', type: 'string' }
          { name: 'SourceIP', type: 'string' }
          { name: 'MessageCount', type: 'int' }
          { name: 'PolicyEvaluated_disposition', type: 'string' }
          { name: 'PolicyEvaluated_dkim', type: 'string' }
          { name: 'PolicyEvaluated_spf', type: 'string' }
          { name: 'PolicyEvaluated_reason_type', type: 'string' }
          { name: 'PolicyEvaluated_reason_comment', type: 'string' }
          { name: 'OverrideReasonCategory', type: 'string' }
          { name: 'HeaderFrom', type: 'string' }
          { name: 'EnvelopeFrom', type: 'string' }
          { name: 'EnvelopeTo', type: 'string' }
          { name: 'DkimResult', type: 'string' }
          { name: 'DkimDomain', type: 'string' }
          { name: 'DkimSelector', type: 'string' }
          { name: 'SpfResult', type: 'string' }
          { name: 'SpfDomain', type: 'string' }
          { name: 'SpfScope', type: 'string' }
          { name: 'DkimAuthResults', type: 'string' }
          { name: 'SpfAuthResults', type: 'string' }
          { name: 'RecordIndex', type: 'int' }
          { name: 'MessageHash', type: 'string' }
          { name: 'Aligned_dkim', type: 'boolean' }
          { name: 'Aligned_spf', type: 'boolean' }
          { name: 'DmarcPass', type: 'boolean' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspaceId
          name: 'dmarcWorkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [streamName]
        destinations: ['dmarcWorkspace']
        transformKql: 'source'
        outputStream: streamName
      }
    ]
  }
  dependsOn: [customTable]
}

// ── Storage Account ──

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    defaultToOAuthAuthentication: true
    // The Function App runtime uses Managed Identity for all storage access
    // (see functionAppConfig deployment.storage.authentication).
    // Set allowStorageSharedKeyAccess=true only when publishing via the local
    // Azure Functions Core Tools CLI, which needs shared key access to upload
    // the deployment package. For CI/CD deployments this should remain false.
    allowSharedKeyAccess: allowStorageSharedKeyAccess
  }
}

// Deployment storage container for Flex Consumption plan
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storageAccount.name}/default/${deploymentContainerName}'
}

// ── Key Vault ──

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    // Public network access is enabled to avoid the complexity and cost of private endpoints.
    // Access is controlled via RBAC - only the Function App's managed identity can read secrets.
    publicNetworkAccess: 'Enabled'
  }
}

// Store the Graph client state secret in Key Vault
resource graphClientStateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'graph-client-state'
  properties: {
    value: graphClientState
  }
}

// ── Application Insights ──

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (empty(existingAppInsightsId)) {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspaceId
  }
  dependsOn: empty(existingWorkspaceId) ? [workspace] : []
}

var appInsightsConnectionString = empty(existingAppInsightsId)
  ? appInsights!.properties.ConnectionString
  : reference(existingAppInsightsId, '2020-02-02').ConnectionString

// ── Hosting Plan (Flex Consumption) ──

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux
  }
}

// ── Function App (Flex Consumption) ──
// Uses functionAppConfig for runtime, deployment, and scale settings.
// App settings are defined in a nested config resource.

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      // Block the SCM (Kudu) management endpoint in production.
      // Flex Consumption deployments use blob storage — Kudu is not required.
      // Set restrictScmAccess=false only for non-production debugging.
      scmIpSecurityRestrictionsDefaultAction: restrictScmAccess ? 'Deny' : 'Allow'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
    }
  }

  resource configAppSettings 'config' = {
    name: 'appsettings'
    properties: {
      AzureWebJobsStorage__accountName: storageAccount.name
      APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
      MAILBOX_USER_ID: mailboxUserId
      DCR_ENDPOINT: dce.properties.logsIngestion.endpoint
      DCR_IMMUTABLE_ID: dcr.properties.immutableId
      DCR_STREAM_NAME: streamName
      GRAPH_CLIENT_STATE: '@Microsoft.KeyVault(SecretUri=${graphClientStateSecret.properties.secretUri})'
      // GRAPH_SUBSCRIPTION_ID is set after running New-GraphSubscription.ps1
    }
  }
}

// ── Role Assignment: Function App → Monitoring Metrics Publisher on DCR ──

resource dcrRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, functionApp.id, monitoringMetricsPublisherRoleId)
  scope: dcr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      monitoringMetricsPublisherRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Role Assignment: Function App → Key Vault Secrets User on Key Vault ──

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      keyVaultSecretsUserRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Role Assignments: Function App → Storage Account (MI-based auth) ──
// Required for AzureWebJobsStorage__accountName identity-based connection.

resource storageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageBlobDataOwnerRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageQueueDataContributorRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageTableDataContributorRoleId
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Easy Auth (App Service Authentication) for admin HTTP endpoints ──
// When adminEntraAppClientId is set, all HTTP requests to the Function App must carry
// a valid Entra ID bearer token issued for that app. The Event Grid webhook path is
// excluded so DMARC event delivery is not affected.

resource functionAppAuthSettings 'Microsoft.Web/sites/config@2024-04-01' = if (!empty(adminEntraAppClientId)) {
  name: 'authsettingsV2'
  parent: functionApp
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: [
        '/runtime/webhooks/eventgrid'
      ]
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: adminEntraAppClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${subscription().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${adminEntraAppClientId}'
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
    httpSettings: {
      requireHttps: true
    }
  }
}

// ── Event Grid Partner Configuration ──
// Authorizes Microsoft Graph API as an Event Grid partner so that Graph change
// notification subscriptions can create partner topics in this resource group.
// This replaces the manual Portal step: Event Grid > Partner Configurations > Authorize.

resource partnerConfiguration 'Microsoft.EventGrid/partnerConfigurations@2022-06-15' = if (deployPartnerConfig) {
  name: 'default'
  location: 'global'
  properties: {
    partnerAuthorization: {
      defaultMaximumExpirationTimeInDays: 365
      authorizedPartnersList: [
        {
          partnerName: 'MicrosoftGraphAPI'
          authorizationExpirationTimeInUtc: dateTimeAdd(deploymentTime, 'P365D')
        }
      ]
    }
  }
}

// ── Diagnostic Settings → Log Analytics Workspace ──
// Forwards audit/platform logs to diagnosticsWorkspaceResourceId (defaults to the DMARC LAW;
// override with a Sentinel or ops LAW via the diagnosticsWorkspaceId parameter).

resource keyVaultDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'dmarc-kv-diag'
  scope: keyVault
  properties: {
    workspaceId: diagnosticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
  }
}

resource functionAppDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'dmarc-func-diag'
  scope: functionApp
  properties: {
    workspaceId: diagnosticsWorkspaceResourceId
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
  }
}

resource storageBlobDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'dmarc-blob-diag'
  scope: storageAccountBlobService
  properties: {
    workspaceId: diagnosticsWorkspaceResourceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
  }
}

resource storageAccountBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

// ── Alert Rules (optional) ──

module alerts 'alerts.bicep' = if (deployAlerts) {
  name: 'dmarc-alerts'
  params: {
    location: location
    workspaceId: workspaceId
    actionGroupId: alertActionGroupId
  }
}

// ── Outputs ──

output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output dcrEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output dcrStreamName string = streamName
output workspaceId string = workspaceId
output workspaceName string = resolvedWorkspaceName
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
