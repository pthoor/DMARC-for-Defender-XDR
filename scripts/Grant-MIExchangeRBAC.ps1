<#
.SYNOPSIS
    Grants Exchange Online Application RBAC permissions to the Function App's Managed Identity.

.DESCRIPTION
    This script replaces legacy Application Access Policies with the modern
    Application RBAC approach. It checks for existing application permissions,
    creates an Exchange Online service principal and mailbox scope, and assigns
    Exchange Application RBAC roles scoped to the DMARC shared mailbox.

.PARAMETER FunctionAppName
    Name of the Azure Function App (from Bicep output).

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER MailboxAddress
    Email address of the DMARC shared mailbox (e.g., dmarc-reports@contoso.com).

.EXAMPLE
    .\Grant-MIExchangeRBAC.ps1 -FunctionAppName 'dmarc-func-abc123' `
        -ResourceGroupName 'rg-dmarc' -MailboxAddress 'dmarc-reports@contoso.com'

.NOTES
    Prerequisites:
    - Az.Accounts PowerShell module (for Invoke-AzRestMethod)
    - Microsoft.Graph PowerShell module (for service principal and permission lookup)
    - Exchange Online PowerShell module (for Application RBAC)
    - Exchange Administrator and consent to Microsoft Graph Application.Read.All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$MailboxAddress
)

$ErrorActionPreference = 'Stop'

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  DMARC for Defender XDR — Managed Identity Permission Setup" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

# ─────────────────────────────────────────────
# Step 1: Get the Managed Identity details
# ─────────────────────────────────────────────

Write-Host "[1/5] Retrieving Managed Identity details..." -ForegroundColor Yellow

# Get the Function App's MI principal ID via ARM REST (avoids Az.Websites dependency)
$azContext = Get-AzContext
if (-not $azContext.Subscription.Id -or -not $azContext.Tenant.Id) {
    throw 'Connect to the target Azure subscription with Connect-AzAccount before running this script.'
}
$subscriptionId = $azContext.Subscription.Id
$tenantId = $azContext.Tenant.Id
$appResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$appPath = "${appResourceId}?api-version=2024-04-01"
$appResponse = Invoke-AzRestMethod -Path $appPath -Method GET
if ($appResponse.StatusCode -ne 200) {
    throw "Function App '$FunctionAppName' not found in resource group '$ResourceGroupName'."
}
$appJson = $appResponse.Content | ConvertFrom-Json
$miPrincipalId = $appJson.identity.principalId

if (-not $miPrincipalId) {
    throw "Function App '$FunctionAppName' does not have a system-assigned Managed Identity enabled."
}

Write-Host "  MI Principal ID : $miPrincipalId" -ForegroundColor Gray

# Connect to Microsoft Graph (needed for service principal and permission lookup)
$graphContext = Get-MgContext
if (-not $graphContext) {
    Write-Host "  Connecting to Microsoft Graph..." -ForegroundColor Gray
    Connect-MgGraph -TenantId $tenantId -Scopes 'Application.Read.All' -NoWelcome
    $graphContext = Get-MgContext
}
if ($graphContext.TenantId -ne $tenantId -or $graphContext.Scopes -notcontains 'Application.Read.All') {
    throw 'The Microsoft Graph connection must use the Azure tenant and have delegated Application.Read.All. Disconnect and reconnect with the correct tenant and scope.'
}

# Get the full service principal details via Microsoft Graph SDK (need AppId)
$miSp = Get-MgServicePrincipal -ServicePrincipalId $miPrincipalId -ErrorAction Stop
$miAppId = $miSp.AppId
$miObjectId = $miSp.Id
if (-not $miAppId -or $miObjectId -ne $miPrincipalId) {
    throw 'Could not resolve the Function App Managed Identity in the selected tenant.'
}

Write-Host "  MI App ID       : $miAppId" -ForegroundColor Gray
Write-Host "  MI Object ID    : $miObjectId" -ForegroundColor Gray

# ─────────────────────────────────────────────
# Step 2: Check existing application permissions
# ─────────────────────────────────────────────

Write-Host "`n[2/5] Checking existing application permissions..." -ForegroundColor Yellow

$existingAppRoles = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId -All -ErrorAction Stop)
if ($existingAppRoles.Count -gt 0) {
    throw "The Managed Identity has existing application permissions. Review and remove them before setup; Exchange Application RBAC does not restrict independent Entra grants."
}
Write-Host "  No direct application permissions found." -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 3: Create Exchange Online service principal
# ─────────────────────────────────────────────

Write-Host "`n[3/5] Creating Exchange Online service principal pointer..." -ForegroundColor Yellow

# Connect to Exchange Online (if not already)
$exchangeConnections = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' })
if ($exchangeConnections.Count -eq 0) {
    Write-Host "  Connecting to Exchange Online..." -ForegroundColor Gray
    if ($IsLinux) {
        Connect-ExchangeOnline -Organization $tenantId -Device -ShowBanner:$false
    }
    else {
        Connect-ExchangeOnline -Organization $tenantId -ShowBanner:$false
    }
    $exchangeConnections = @(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' })
}
if ($exchangeConnections.Count -ne 1 -or $exchangeConnections[0].TenantID -ne $tenantId) {
    throw 'Connect to Exchange Online for the selected Azure tenant using Connect-ExchangeOnline -Organization <tenant-id>, and disconnect any other Exchange sessions.'
}

try {
    $parsedMailboxAddress = [System.Net.Mail.MailAddress]::new($MailboxAddress)
    if ($parsedMailboxAddress.Address -ine $MailboxAddress) { throw 'Mailbox address must not contain a display name.' }
} catch {
    throw "MailboxAddress '$MailboxAddress' is not a valid email address."
}
$mailbox = Get-EXOMailbox -Identity $MailboxAddress -ErrorAction Stop
if ([string]$mailbox.PrimarySmtpAddress -ine $MailboxAddress) {
    throw "MailboxAddress must be the mailbox's primary SMTP address: $($mailbox.PrimarySmtpAddress)."
}
$settingsResponse = Invoke-AzRestMethod -Path "${appResourceId}/config/appsettings/list?api-version=2024-04-01" -Method POST
if ($settingsResponse.StatusCode -ne 200) {
    throw 'Could not read Function App settings to verify MAILBOX_USER_ID.'
}
$configuredMailbox = ($settingsResponse.Content | ConvertFrom-Json).properties.MAILBOX_USER_ID
if (-not $configuredMailbox -or $configuredMailbox -notin @([string]$mailbox.ExternalDirectoryObjectId, [string]$mailbox.UserPrincipalName)) {
    throw 'The Function App MAILBOX_USER_ID does not match the requested mailbox object ID or user principal name.'
}

$scopeName = "DMARC-Mailbox-$miObjectId"
$recipientFilter = "PrimarySmtpAddress -eq '$($MailboxAddress.Replace("'", "''"))'"
$allScopes = @(Get-ManagementScope -ErrorAction Stop)
$existingScopes = @($allScopes | Where-Object { $_.Name -eq $scopeName })
if ($existingScopes.Count -gt 1 -or ($existingScopes.Count -eq 1 -and ($existingScopes[0].Exclusive -or $existingScopes[0].RecipientFilter -ine $recipientFilter))) {
    throw "Existing management scope '$scopeName' does not match the requested mailbox. Review it before continuing."
}
$matchingScopes = @($allScopes | Where-Object {
    -not $_.Exclusive -and $_.RecipientFilter -ieq $recipientFilter -and [string]::IsNullOrWhiteSpace([string]$_.RecipientRoot)
})
if ($matchingScopes.Count -gt 1) {
    throw 'Multiple management scopes match the requested mailbox. Review them before continuing.'
}
if ($matchingScopes.Count -eq 1) {
    $scopeName = [string]$matchingScopes[0].Name
    $existingScopes = $matchingScopes
}

$existingExoSp = @(Get-ServicePrincipal -ErrorAction Stop | Where-Object { $_.AppId -eq $miAppId })
if ($existingExoSp.Count -gt 1 -or ($existingExoSp.Count -eq 1 -and $existingExoSp[0].ObjectId -ne $miObjectId)) {
    throw 'An Exchange service principal exists with unexpected identity details. Review it before continuing.'
}
$exoRoles = @('Application Mail.Read', 'Application Mail.ReadWrite')
$allAssignments = @(Get-ManagementRoleAssignment -RoleAssigneeType ServicePrincipal -ErrorAction Stop)
$identityAssignments = @($allAssignments | Where-Object { $_.RoleAssignee -eq $miObjectId })
foreach ($assignment in $identityAssignments) {
    $assignedScopes = @($allScopes | Where-Object { $_.Name -eq [string]$assignment.CustomResourceScope })
    if ([string]$assignment.Role -notin $exoRoles -or -not $assignment.Enabled -or $assignedScopes.Count -ne 1 -or $assignedScopes[0].Exclusive -or $assignedScopes[0].RecipientFilter -ine $recipientFilter) {
        throw "The Managed Identity has an unexpected Exchange application role assignment '$($assignment.Name)'. Review it before continuing."
    }
}

if ($existingExoSp) {
    Write-Host "  Exchange service principal already exists." -ForegroundColor Gray
}
else {
    New-ServicePrincipal -AppId $miAppId -ObjectId $miObjectId -DisplayName "DMARC for Defender XDR ($FunctionAppName)" -ErrorAction Stop
    Write-Host "  Exchange service principal created." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 4: Create Management Scope for the DMARC mailbox
# ─────────────────────────────────────────────

Write-Host "`n[4/5] Creating Management Scope for mailbox restriction..." -ForegroundColor Yellow

if ($existingScopes.Count -eq 1) {
    Write-Host "  Management Scope '$scopeName' already exists." -ForegroundColor Gray
}
else {
    # Scope the MI to only the DMARC shared mailbox
    New-ManagementScope -Name $scopeName `
        -RecipientRestrictionFilter $recipientFilter -ErrorAction Stop
    Write-Host "  Management Scope '$scopeName' created." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 5: Assign Application RBAC roles
# ─────────────────────────────────────────────

Write-Host "`n[5/5] Assigning Exchange Application RBAC roles..." -ForegroundColor Yellow

foreach ($roleName in $exoRoles) {
    $roleSuffix = if ($roleName -eq 'Application Mail.Read') { 'Read' } else { 'ReadWrite' }
    $assignmentName = "DMARC-$miObjectId-$roleSuffix"
    $existing = @($identityAssignments | Where-Object { [string]$_.Role -eq $roleName -and [string]$_.CustomResourceScope -eq $scopeName })
    if ($existing) {
        Write-Host "  $roleName — already assigned." -ForegroundColor Gray
    }
    else {
        if (@($allAssignments | Where-Object { $_.Name -eq $assignmentName }).Count -gt 0) {
            throw "Existing assignment '$assignmentName' has unexpected properties. Review it before continuing."
        }
        New-ManagementRoleAssignment `
            -Name $assignmentName `
            -Role $roleName `
            -App $miAppId `
            -CustomResourceScope $scopeName -ErrorAction Stop
        Write-Host "  $roleName — assigned with scope '$scopeName'." -ForegroundColor Green
    }
}

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`n  The Managed Identity for '$FunctionAppName' now has:"
Write-Host "  • Exchange RBAC: Scoped to '$MailboxAddress' only"
Write-Host "`n  Note: Permission changes may take 30 min to 2 hours to propagate."
Write-Host "  Use Test-ServicePrincipalAuthorization to verify:`n"
Write-Host "  Test-ServicePrincipalAuthorization -Identity '$miAppId' -Resource '$MailboxAddress' | Format-Table`n" -ForegroundColor Gray
