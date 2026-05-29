#Requires -Version 7.4

<#!
.SYNOPSIS
  Validates a DMARC Analyzer Azure deployment end-to-end.
.DESCRIPTION
  Runs a practical readiness checklist:
  - Function App and required app settings exist
  - Managed identity RBAC on DCR and Key Vault is present
  - Graph subscription exists and has remaining lifetime
  - DCR ingestion endpoint is reachable
  - Admin HTTP endpoint responds with expected validation error

  Optionally runs a synthetic Event Grid validation event against the runtime webhook.
  This does not ingest mailbox data and is safe for smoke testing routing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [string]$SubscriptionId,

    [switch]$RunSyntheticEventSmoke
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Warnings = 0

function Write-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    if ($Passed) {
        Write-Host "[PASS] $Name - $Detail" -ForegroundColor Green
        return
    }

    $script:Failures++
    Write-Host "[FAIL] $Name - $Detail" -ForegroundColor Red
}

function Write-WarnCheck {
    param(
        [string]$Name,
        [string]$Detail
    )

    $script:Warnings++
    Write-Host "[WARN] $Name - $Detail" -ForegroundColor Yellow
}

function Get-AzJson {
    param([string]$Command)

    $output = Invoke-Expression $Command
    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return $output | ConvertFrom-Json
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId | Out-Null
}

$functionApp = Get-AzJson -Command "az functionapp show -g '$ResourceGroupName' -n '$FunctionAppName' -o json"
Write-Check -Name 'Function App exists' -Passed ($null -ne $functionApp) -Detail $FunctionAppName
if ($null -eq $functionApp) {
    throw 'Stopping validation because Function App was not found.'
}

$principalId = $functionApp.identity.principalId
Write-Check -Name 'Managed identity exists' -Passed (-not [string]::IsNullOrWhiteSpace($principalId)) -Detail $principalId

$appSettingsArray = Get-AzJson -Command "az functionapp config appsettings list -g '$ResourceGroupName' -n '$FunctionAppName' -o json"
$appSettings = @{}
foreach ($entry in $appSettingsArray) {
    $appSettings[$entry.name] = [string]$entry.value
}

$requiredSettings = @('MAILBOX_USER_ID', 'DCR_ENDPOINT', 'DCR_IMMUTABLE_ID', 'DCR_STREAM_NAME', 'GRAPH_CLIENT_STATE')
foreach ($name in $requiredSettings) {
    $value = if ($appSettings.ContainsKey($name)) { $appSettings[$name] } else { '' }
    Write-Check -Name "App setting $name" -Passed (-not [string]::IsNullOrWhiteSpace($value)) -Detail ($value.Substring(0, [Math]::Min(32, $value.Length)))
}

$dcrImmutableId = $appSettings['DCR_IMMUTABLE_ID']
$dcrId = az monitor data-collection rule list -g $ResourceGroupName --query "[?properties.immutableId=='$dcrImmutableId'].id | [0]" -o tsv
$dcrFound = -not [string]::IsNullOrWhiteSpace($dcrId)
Write-Check -Name 'DCR resolved from immutable ID' -Passed $dcrFound -Detail $dcrImmutableId

if ($dcrFound) {
    $dcrRoleCount = [int](az role assignment list --assignee-object-id $principalId --scope $dcrId --query "[?roleDefinitionName=='Monitoring Metrics Publisher'] | length(@)" -o tsv)
    Write-Check -Name 'RBAC on DCR' -Passed ($dcrRoleCount -ge 1) -Detail 'Monitoring Metrics Publisher assigned'
}

$graphClientState = $appSettings['GRAPH_CLIENT_STATE']
if ($graphClientState -match 'SecretUri=https://([^/]+)/') {
    $vaultHost = $Matches[1]
    $keyVaultId = az keyvault list -g $ResourceGroupName --query "[?contains(properties.vaultUri, '$vaultHost')].id | [0]" -o tsv
    if (-not [string]::IsNullOrWhiteSpace($keyVaultId)) {
        $kvRoleCount = [int](az role assignment list --assignee-object-id $principalId --scope $keyVaultId --query "[?roleDefinitionName=='Key Vault Secrets User'] | length(@)" -o tsv)
        Write-Check -Name 'RBAC on Key Vault' -Passed ($kvRoleCount -ge 1) -Detail 'Key Vault Secrets User assigned'
    }
    else {
        Write-WarnCheck -Name 'RBAC on Key Vault' -Detail 'Could not resolve Key Vault resource ID from GRAPH_CLIENT_STATE reference.'
    }
}
else {
    Write-WarnCheck -Name 'GRAPH_CLIENT_STATE reference' -Detail 'Setting is not a Key Vault reference; skipping Key Vault RBAC validation.'
}

$subscriptionGraphId = $appSettings['GRAPH_SUBSCRIPTION_ID']
if ([string]::IsNullOrWhiteSpace($subscriptionGraphId)) {
    Write-WarnCheck -Name 'Graph subscription health' -Detail 'GRAPH_SUBSCRIPTION_ID is empty; run New-GraphSubscription script.'
}
else {
    try {
        $graphSubscription = Get-AzJson -Command "az rest --method GET --url 'https://graph.microsoft.com/v1.0/subscriptions/$subscriptionGraphId' -o json"
        $expiry = [datetime]$graphSubscription.expirationDateTime
        $daysLeft = [int][Math]::Floor(($expiry.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays)
        Write-Check -Name 'Graph subscription alive' -Passed ($expiry -gt (Get-Date).ToUniversalTime()) -Detail "Expires $($expiry.ToUniversalTime().ToString('u')) ($daysLeft days)"
    }
    catch {
        Write-Check -Name 'Graph subscription alive' -Passed $false -Detail $_.Exception.Message
    }
}

$dcrEndpoint = $appSettings['DCR_ENDPOINT']
$dcrStreamName = [uri]::EscapeDataString($appSettings['DCR_STREAM_NAME'])
if (-not [string]::IsNullOrWhiteSpace($dcrEndpoint) -and -not [string]::IsNullOrWhiteSpace($dcrImmutableId)) {
    $probeUri = "$dcrEndpoint/dataCollectionRules/$dcrImmutableId/streams/$dcrStreamName?api-version=2023-01-01"
    try {
        $probe = Invoke-WebRequest -Uri $probeUri -Method Options -TimeoutSec 20 -SkipHttpErrorCheck
        $reachable = ($probe.StatusCode -ge 200 -and $probe.StatusCode -lt 500)
        Write-Check -Name 'DCR endpoint reachable' -Passed $reachable -Detail "HTTP $($probe.StatusCode)"
    }
    catch {
        Write-Check -Name 'DCR endpoint reachable' -Passed $false -Detail $_.Exception.Message
    }
}

$resourceId = $functionApp.id
$hostKeysUri = "$resourceId/host/default/listkeys?api-version=2024-04-01"
$masterKey = az rest --method POST --uri $hostKeysUri --query masterKey -o tsv
if ([string]::IsNullOrWhiteSpace($masterKey)) {
    Write-Check -Name 'Function host key retrieval' -Passed $false -Detail 'No host master key returned.'
}
else {
    Write-Check -Name 'Function host key retrieval' -Passed $true -Detail 'Master key retrieved.'

    # Non-destructive health check: intentionally omit required request fields and expect 400.
    $setupHelperUri = "https://$FunctionAppName.azurewebsites.net/api/SetupHelper"
    try {
        $response = Invoke-WebRequest -Uri $setupHelperUri -Method Post -Headers @{ 'x-functions-key' = $masterKey } -Body '{}' -ContentType 'application/json' -SkipHttpErrorCheck
        $responded = ($response.StatusCode -eq 400)
        Write-Check -Name 'SetupHelper HTTP health' -Passed $responded -Detail "HTTP $($response.StatusCode)"
    }
    catch {
        Write-Check -Name 'SetupHelper HTTP health' -Passed $false -Detail $_.Exception.Message
    }
}

if ($RunSyntheticEventSmoke.IsPresent) {
    $eventGridUri = "https://$FunctionAppName.azurewebsites.net/runtime/webhooks/eventgrid?functionName=DmarcReportProcessor"
    $validationEvent = @(
        @{
            id = [guid]::NewGuid().ToString()
            eventType = 'Microsoft.EventGrid.SubscriptionValidationEvent'
            subject = '/subscriptions/fake-sub/resourceGroups/fake-rg/providers/Microsoft.EventGrid/topics/fake-topic'
            eventTime = (Get-Date).ToUniversalTime().ToString('o')
            dataVersion = '1'
            metadataVersion = '1'
            data = @{
                validationCode = 'smoke-test-code'
                validationUrl = 'https://example.invalid'
            }
        }
    ) | ConvertTo-Json -Depth 8

    try {
        $egResponse = Invoke-WebRequest -Uri $eventGridUri -Method Post -Body $validationEvent -ContentType 'application/json' -SkipHttpErrorCheck
        $ok = ($egResponse.StatusCode -ge 200 -and $egResponse.StatusCode -lt 300)
        Write-Check -Name 'Synthetic Event Grid smoke' -Passed $ok -Detail "HTTP $($egResponse.StatusCode)"
    }
    catch {
        Write-Check -Name 'Synthetic Event Grid smoke' -Passed $false -Detail $_.Exception.Message
    }
}
else {
    Write-WarnCheck -Name 'Synthetic Event Grid smoke' -Detail 'Skipped. Pass -RunSyntheticEventSmoke to execute webhook validation event.'
}

Write-Host "`nValidation summary: Failures=$script:Failures Warnings=$script:Warnings" -ForegroundColor Cyan
if ($script:Failures -gt 0) {
    throw "Deployment validation failed with $script:Failures failing check(s)."
}
