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
    - Managed Identity has Graph Mail.Read permission
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
Write-Host "  DMARC Pipeline — Graph Subscription Setup" -ForegroundColor Cyan
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

Publish the function app code first:
  cd src/function
  func azure functionapp publish $FunctionAppName --powershell

If 'func publish' fails, ensure the storage account allows shared key access.
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

# Build notification URL
$partnerTopicName = "DmarcPipeline-$FunctionAppName"
$notificationUrl = "EventGrid:?azuresubscriptionid=$SubscriptionId&resourcegroup=$ResourceGroupName&partnertopic=$partnerTopicName&location=$resourceGroupLocation"
$expirationDateTime = (Get-Date).AddMinutes(4200).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')

Write-Host "  Partner topic: $partnerTopicName" -ForegroundColor Gray
Write-Host "  Expiration: $expirationDateTime" -ForegroundColor Gray

$setupBody = @{
    notificationUrl    = $notificationUrl
    expirationDateTime = $expirationDateTime
} | ConvertTo-Json

# Pass the master key as a request header — never as a query parameter — to keep it
# out of shell history, process listings, server access logs, and exception messages.
$setupUri = "https://$defaultHostName/api/SetupHelper"
$setupHeaders = @{ 'x-functions-key' = $masterKey }

# Invoke SetupHelper (retry for cold start)
$graphSubscriptionId = $null
$maxAttempts = 4
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        Write-Host "  Calling SetupHelper (attempt $attempt/$maxAttempts)..." -ForegroundColor Gray

        # Use Invoke-WebRequest instead of Invoke-RestMethod so we can read
        # the response body on non-2xx status codes (SetupHelper returns
        # { error: "..." } on 400/500 which Invoke-RestMethod would discard).
        $webResponse = Invoke-WebRequest -Uri $setupUri -Method POST -Headers $setupHeaders -Body $setupBody `
            -ContentType 'application/json' -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
        $response = $webResponse.Content | ConvertFrom-Json

        if ($response.subscriptionId) {
            $graphSubscriptionId = $response.subscriptionId
            break
        }
        if ($response.error) {
            Write-Host "  Error: $($response.error)" -ForegroundColor Red
        }
    } catch {
        $statusCode = $null
        $errorBody = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $errorStream = $_.Exception.Response.GetResponseStream()
                $reader = [System.IO.StreamReader]::new($errorStream)
                $errorBody = $reader.ReadToEnd()
                $reader.Dispose()
            } catch { }
        }

        # Parse error message from SetupHelper's JSON response
        $errorMessage = $_.Exception.Message
        if ($errorBody) {
            try {
                $errorJson = $errorBody | ConvertFrom-Json
                if ($errorJson.error) { $errorMessage = $errorJson.error }
            } catch {
                $errorMessage = $errorBody
            }
        }

        if ($statusCode -eq 404) {
            Write-Error @"
SetupHelper returned HTTP 404 (Not Found). The function endpoint is not reachable.

Possible causes:
  1. Function code not published: Run 'func azure functionapp publish $FunctionAppName --powershell' from src/function/
  2. Storage access: If 'func publish' fails, check that the storage account allows shared key access.
  3. Cold start: The Function App may need more time to initialize (Flex Consumption).
"@
            throw
        }

        Write-Host "  HTTP $statusCode — $errorMessage" -ForegroundColor Red

        if ($statusCode -eq 500) {
            Write-Host "" -ForegroundColor Yellow
            Write-Host "  Troubleshooting HTTP 500:" -ForegroundColor Yellow
            Write-Host "    1. Check Function App logs: az functionapp log tail -n $FunctionAppName -g $ResourceGroupName" -ForegroundColor Gray
            Write-Host "    2. Verify MAILBOX_USER_ID app setting is correct (Entra ID object ID of mailbox user)" -ForegroundColor Gray
            Write-Host "    3. Verify Key Vault reference for GRAPH_CLIENT_STATE resolved (check Configuration in Portal)" -ForegroundColor Gray
            Write-Host "    4. Verify MI has Mail.Read permission (run Grant-MIExchangeRBAC.ps1 first)" -ForegroundColor Gray
            Write-Host "    5. Permission propagation can take up to 2 hours after granting" -ForegroundColor Gray
            Write-Host ""
        }

        if ($attempt -lt $maxAttempts) {
            Write-Host "  Retrying in 15s..." -ForegroundColor Gray
            Start-Sleep -Seconds 15
        } else {
            Write-Error "SetupHelper failed after $maxAttempts attempts: $errorMessage"
            throw
        }
    }
}

if (-not $graphSubscriptionId) {
    Write-Error "Failed to create Graph subscription. Check that the MI has Mail.Read application permission and Exchange RBAC is configured."
    throw
}

Write-Host "  Subscription created: $graphSubscriptionId" -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 3: Activate Partner Topic & create Event Subscription
# ─────────────────────────────────────────────

Write-Host "`n[3/4] Activating partner topic..." -ForegroundColor Yellow

$partnerTopicPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.EventGrid/partnerTopics/$partnerTopicName"
$apiVersion = 'api-version=2022-06-15'

# Wait for partner topic
$topicFound = $false
for ($attempt = 1; $attempt -le 18; $attempt++) {
    $topicResponse = Invoke-AzRestMethod -Path "${partnerTopicPath}?${apiVersion}" -Method GET
    if ($topicResponse.StatusCode -eq 200) {
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

# Activate
$activateResponse = Invoke-AzRestMethod -Path "${partnerTopicPath}/activate?${apiVersion}" -Method POST
if ($activateResponse.StatusCode -notin 200, 202) {
    Write-Error "Failed to activate partner topic (HTTP $($activateResponse.StatusCode))."
    throw
}
Write-Host "  Partner topic activated." -ForegroundColor Green

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
# Step 4: Save subscription ID
# ─────────────────────────────────────────────

Write-Host "`n[4/4] Saving subscription ID..." -ForegroundColor Yellow

# Use ARM REST to update app settings (compatible with Flex Consumption plan)
$settingsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings/list?api-version=2024-04-01"
$currentSettings = (Invoke-AzRestMethod -Path $settingsPath -Method POST).Content | ConvertFrom-Json

# Merge existing settings with the new subscription ID
$updatedProperties = @{}
foreach ($prop in $currentSettings.properties.PSObject.Properties) {
    $updatedProperties[$prop.Name] = $prop.Value
}
$updatedProperties['GRAPH_SUBSCRIPTION_ID'] = $graphSubscriptionId

$updateBody = @{ properties = $updatedProperties } | ConvertTo-Json -Depth 5
$updatePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings?api-version=2024-04-01"
$updateResponse = Invoke-AzRestMethod -Path $updatePath -Method PUT -Payload $updateBody

if ($updateResponse.StatusCode -ne 200) {
    Write-Error "Failed to save app settings (HTTP $($updateResponse.StatusCode))."
    throw
}

Write-Host "  GRAPH_SUBSCRIPTION_ID saved." -ForegroundColor Green

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Graph subscription ID: $graphSubscriptionId" -ForegroundColor Green
Write-Host "  The RenewGraphSubscription timer will keep it alive." -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan
