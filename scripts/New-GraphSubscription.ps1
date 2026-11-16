<#
.SYNOPSIS
    Creates a Microsoft Graph change notification subscription for the DMARC mailbox.

.DESCRIPTION
    Automates the Graph-to-Event Grid pipeline:
    1. Invokes the deployed SetupHelper function to create a Graph subscription
       (uses the Function App's Managed Identity - no Graph permissions needed
       for the operator).
    2. Waits for the partner topic, activates it, and creates an event subscription
       pointing to the DmarcReportProcessor function.
    3. Saves the subscription ID to the Function App's app settings.

.PARAMETER FunctionAppName
    Name of the Azure Function App.

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER SubscriptionId
    Azure subscription ID.

.EXAMPLE
    .\New-GraphSubscription.ps1 `
        -FunctionAppName 'dmarc-func-abc123' `
        -ResourceGroupName 'rg-dmarc' `
        -SubscriptionId '11111111-1111-1111-1111-111111111111'

.NOTES
    Prerequisites:
    - Azure resources deployed via main.bicep (includes partner configuration).
    - Function app published (includes the SetupHelper function).
    - Managed Identity has mailbox-scoped Exchange Application Mail.Read permission
      (run Grant-MIExchangeRBAC.ps1 first).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  DMARC for Defender XDR — Graph Subscription Setup" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────
# Step 1: Prerequisites
# ─────────────────────────────────────────────

Write-Host "[1/4] Checking prerequisites..." -ForegroundColor Yellow

$functionAppResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"

$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/${ResourceGroupName}?api-version=2024-03-01"
$rgResponse = Invoke-AzRestMethod -Path $rgPath -Method GET
if ($rgResponse.StatusCode -ne 200) {
    Write-Error "Resource group '$ResourceGroupName' not found or not accessible."
    throw
}
$resourceGroupLocation = ($rgResponse.Content | ConvertFrom-Json).location
Write-Host "  Resource group: $ResourceGroupName ($resourceGroupLocation)" -ForegroundColor Green

# Get the function app's default hostname from ARM (don't hardcode .azurewebsites.net)
$appPath = "${functionAppResourceId}?api-version=2024-04-01"
$appResponse = Invoke-AzRestMethod -Path $appPath -Method GET
if ($appResponse.StatusCode -ne 200) {
    Write-Error "Function App '$FunctionAppName' not found in resource group '$ResourceGroupName'."
    throw
}
$appJson = $appResponse.Content | ConvertFrom-Json
$defaultHostName = $appJson.properties.defaultHostName
Write-Host "  Function App: $FunctionAppName ($defaultHostName)" -ForegroundColor Green

# Verify the SetupHelper function is deployed
$functionsPath = "${functionAppResourceId}/functions?api-version=2024-04-01"
$functionsResponse = Invoke-AzRestMethod -Path $functionsPath -Method GET
$deployedFunctions = @()
if ($functionsResponse.StatusCode -eq 200) {
    $deployedFunctions = ($functionsResponse.Content | ConvertFrom-Json).value | ForEach-Object { $_.name -replace '.+/', '' }
}

if ('SetupHelper' -notin $deployedFunctions) {
    Write-Error @"
SetupHelper function is not deployed. Deployed functions: [$($deployedFunctions -join ', ')].

Publish the function app code first using the manual ZIP deployment steps in README.md.
"@
    throw
}
Write-Host "  SetupHelper function: deployed" -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 2: Create Graph subscription via SetupHelper
# ─────────────────────────────────────────────

Write-Host "`n[2/4] Creating Graph subscription..." -ForegroundColor Yellow

# Get master host key via ARM
Write-Host "  Retrieving host key..." -ForegroundColor Gray
$keysPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/host/default/listkeys?api-version=2024-04-01"
$keysResponse = Invoke-AzRestMethod -Path $keysPath -Method POST

if ($keysResponse.StatusCode -ne 200) {
    Write-Error "Failed to retrieve host keys (HTTP $($keysResponse.StatusCode)). Ensure the Function App is deployed."
    throw
}
$masterKey = ($keysResponse.Content | ConvertFrom-Json).masterKey

# Read settings before subscription setup so a retry can renew the existing
# subscription instead of creating another one after a partial previous run.
$settingsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings/list?api-version=2024-04-01"
$settingsResponse = Invoke-AzRestMethod -Path $settingsPath -Method POST
if ($settingsResponse.StatusCode -ne 200) {
    throw "Failed to read Function App settings (HTTP $($settingsResponse.StatusCode))."
}
$currentSettings = ($settingsResponse.Content | ConvertFrom-Json).properties
$existingGraphSubscriptionId = [string]$currentSettings.GRAPH_SUBSCRIPTION_ID
if ($existingGraphSubscriptionId) {
    $parsedSubscriptionId = [guid]::Empty
    if (-not [guid]::TryParse($existingGraphSubscriptionId, [ref]$parsedSubscriptionId)) {
        throw 'GRAPH_SUBSCRIPTION_ID is not a valid GUID. Review the existing Function App setting before continuing.'
    }
    $existingGraphSubscriptionId = $parsedSubscriptionId.ToString()
    Write-Host "  Existing Graph subscription found; it will be resumed rather than duplicated." -ForegroundColor Gray
}

# Build notification URL
$partnerTopicName = "DmarcPipeline-$FunctionAppName"
$notificationUrl = "EventGrid:?azuresubscriptionid=$SubscriptionId&resourcegroup=$ResourceGroupName&partnertopic=$partnerTopicName&location=$resourceGroupLocation"
$expirationDateTime = (Get-Date).AddMinutes(4200).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')

Write-Host "  Partner topic: $partnerTopicName" -ForegroundColor Gray
Write-Host "  Expiration: $expirationDateTime" -ForegroundColor Gray

$setupPayload = @{
    notificationUrl    = $notificationUrl
    expirationDateTime = $expirationDateTime
}
if ($existingGraphSubscriptionId) {
    $setupPayload.subscriptionId = $existingGraphSubscriptionId
}
$setupBody = $setupPayload | ConvertTo-Json

# Pass the master key as a request header — never as a query parameter — to keep it
# out of shell history, process listings, server access logs, and exception messages.
$setupUri = "https://$defaultHostName/api/SetupHelper"
$setupHeaders = @{ 'x-functions-key' = $masterKey }

# Retry only a confirmed 404 (cold-start route discovery). A timeout or 5xx may
# follow successful Graph creation, so do not automatically replay the POST.
$graphSubscriptionId = $null
$maxAttempts = 4
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $webResponse = Invoke-WebRequest -Uri $setupUri -Method POST -Headers $setupHeaders -Body $setupBody `
        -ContentType 'application/json' -TimeoutSec 120 -UseBasicParsing -SkipHttpErrorCheck -ErrorAction Stop
    if ($webResponse.StatusCode -ne 404 -or $attempt -eq $maxAttempts) { break }
    Write-Host "  SetupHelper route is not ready (404); retrying in 15s ($attempt/$maxAttempts)..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
}
if ($webResponse.StatusCode -eq 404) {
    throw "SetupHelper route was not available after $maxAttempts attempts. Confirm the function code is deployed."
}
$response = $webResponse.Content | ConvertFrom-Json
if ($webResponse.StatusCode -ne 200 -or -not $response.subscriptionId) {
    $errorMessage = if ($response.error) { [string]$response.error } else { "HTTP $($webResponse.StatusCode) from SetupHelper." }
    throw "SetupHelper failed: $errorMessage. It was not retried automatically to avoid duplicate Graph subscriptions. Inspect the Function App logs and GRAPH_SUBSCRIPTION_ID before retrying."
}
$graphSubscriptionId = [string]$response.subscriptionId

if (-not $graphSubscriptionId) {
    Write-Error "Failed to create Graph subscription. Check that the MI has scoped Exchange Application Mail.Read permission."
    throw
}

Write-Host "  Subscription created: $graphSubscriptionId" -ForegroundColor Green

# Save immediately: if Event Grid setup fails below, the next run renews this
# subscription instead of creating another one.
$updatedProperties = @{}
foreach ($prop in $currentSettings.PSObject.Properties) {
    $updatedProperties[$prop.Name] = $prop.Value
}
$updatedProperties['GRAPH_SUBSCRIPTION_ID'] = $graphSubscriptionId
$updateBody = @{ properties = $updatedProperties } | ConvertTo-Json -Depth 5
$updatePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings?api-version=2024-04-01"
$updateResponse = Invoke-AzRestMethod -Path $updatePath -Method PUT -Payload $updateBody
if ($updateResponse.StatusCode -ne 200) {
    throw "Subscription $graphSubscriptionId was created or renewed, but saving it to app settings failed (HTTP $($updateResponse.StatusCode)). Save GRAPH_SUBSCRIPTION_ID manually before retrying."
}
Write-Host "  GRAPH_SUBSCRIPTION_ID saved before Event Grid setup." -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 3: Activate Partner Topic & create Event Subscription
# ─────────────────────────────────────────────

Write-Host "`n[3/4] Activating Partner Topic..." -ForegroundColor Yellow

$partnerTopicPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$partnerTopicName"
$apiVersion = 'api-version=2022-06-15'

# Wait for partner topic
$topicFound = $false
for ($attempt = 1; $attempt -le 18; $attempt++) {
    $topicResponse = Invoke-AzRestMethod -Path "${partnerTopicPath}?${apiVersion}" -Method GET
    if ($topicResponse.StatusCode -eq 200) {
        $partnerTopic = $topicResponse.Content | ConvertFrom-Json
        $topicFound = $true
        Write-Host "  Partner topic found." -ForegroundColor Green
        break
    }
    Write-Host "  Waiting for partner topic ($attempt/18)..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
}

if (-not $topicFound) {
    Write-Error "Partner topic '$partnerTopicName' did not appear within 3 minutes. Check the Azure Portal under Event Grid > Partner Topics."
    throw
}

if ($partnerTopic.properties.activationState -eq 'Activated') {
    Write-Host "  Partner topic is already activated." -ForegroundColor Gray
}
elseif ($partnerTopic.properties.activationState -eq 'NeverActivated') {
    $activateResponse = Invoke-AzRestMethod -Path "${partnerTopicPath}/activate?${apiVersion}" -Method POST
    if ($activateResponse.StatusCode -notin 200, 202) {
        throw "Failed to activate partner topic (HTTP $($activateResponse.StatusCode))."
    }
    Write-Host "  Partner topic activated." -ForegroundColor Green
}
else {
    throw "Partner topic has unexpected activation state '$($partnerTopic.properties.activationState)'."
}

# Create event subscription
Write-Host "  Creating event subscription..." -ForegroundColor Gray
$functionResourceId = "$functionAppResourceId/functions/DmarcReportProcessor"

$eventSubPath = "${partnerTopicPath}/eventSubscriptions/dmarc-report-processor?${apiVersion}"
$eventSubBody = @{
    properties = @{
        destination = @{
            endpointType = 'AzureFunction'
            properties   = @{
                resourceId                    = $functionResourceId
                maxEventsPerBatch             = 1
                preferredBatchSizeInKilobytes = 64
            }
        }
        eventDeliverySchema = 'CloudEventSchemaV1_0'
    }
} | ConvertTo-Json -Depth 10

$eventSubResponse = Invoke-AzRestMethod -Path $eventSubPath -Method PUT -Payload $eventSubBody
if ($eventSubResponse.StatusCode -notin 200, 201) {
    Write-Error "Failed to create event subscription (HTTP $($eventSubResponse.StatusCode)). Response: $($eventSubResponse.Content)"
    throw
}
Write-Host "  Event subscription created." -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 4: Verify saved subscription ID
# ─────────────────────────────────────────────

Write-Host "`n[4/4] Verifying saved subscription ID..." -ForegroundColor Yellow
$savedSettingsResponse = Invoke-AzRestMethod -Path $settingsPath -Method POST
if ($savedSettingsResponse.StatusCode -ne 200 -or ($savedSettingsResponse.Content | ConvertFrom-Json).properties.GRAPH_SUBSCRIPTION_ID -ne $graphSubscriptionId) {
    throw 'GRAPH_SUBSCRIPTION_ID was not saved correctly. Restore the setting before completing setup.'
}
Write-Host "  GRAPH_SUBSCRIPTION_ID verified." -ForegroundColor Green

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Graph subscription ID: $graphSubscriptionId" -ForegroundColor Green
Write-Host "  The RenewGraphSubscription timer will keep it alive." -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan
