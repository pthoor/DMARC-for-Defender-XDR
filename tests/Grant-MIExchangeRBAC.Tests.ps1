#Requires -Version 7.4
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Grant-MIExchangeRBAC.ps1 script.
.DESCRIPTION
    Tests the Exchange RBAC setup script for proper parameter validation,
    security controls, and workflow.
#>

BeforeAll {
    $scriptPath = "$PSScriptRoot/../scripts/Grant-MIExchangeRBAC.ps1"

    function Get-AzContext { }
    function Invoke-AzRestMethod { param($Path, $Method) }
    function Get-MgContext { }
    function Connect-MgGraph { param($TenantId, $Scopes, [switch]$NoWelcome) }
    function Get-MgServicePrincipal { param($ServicePrincipalId) }
    function Get-MgServicePrincipalAppRoleAssignment { param($ServicePrincipalId, [switch]$All) }
    function Get-ConnectionInformation { }
    function Connect-ExchangeOnline { param($Organization, [switch]$Device, [switch]$ShowBanner) }
    function Get-EXOMailbox { param($Identity) }
    function Get-ManagementScope { }
    function Get-ServicePrincipal { }
    function Get-ManagementRoleAssignment { param($RoleAssigneeType) }
    function New-ServicePrincipal { param($AppId, $ObjectId, $DisplayName) }
    function New-ManagementScope { param($Name, $RecipientRestrictionFilter) }
    function New-ManagementRoleAssignment { param($Name, $Role, $App, $CustomResourceScope) }
}

Describe 'Grant-MIExchangeRBAC.ps1' {
    Context 'Script Structure' {
        It 'Should exist' {
            Test-Path $scriptPath | Should -Be $true
        }

        It 'Should have valid PowerShell syntax' {
            $errors = $null
            $null = [System.Management.Automation.PSParser]::Tokenize(
                (Get-Content $scriptPath -Raw), 
                [ref]$errors
            )
            $errors | Should -BeNullOrEmpty
        }

        It 'Should have CmdletBinding attribute' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\[CmdletBinding\(\)\]'
        }

        It 'Should have required parameters' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$FunctionAppName'
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$ResourceGroupName'
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$MailboxAddress'
        }

        It 'Should set ErrorActionPreference to Stop' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]'
        }
    }

    Context 'Managed Identity Operations' {
        It 'Should retrieve Function App Managed Identity via ARM REST' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Invoke-AzRestMethod'
            $content | Should -Match 'identity'
            $content | Should -Match 'principalId'
        }

        It 'Should validate MI is enabled' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'if.*-not.*\$miPrincipalId'
            $content | Should -Match 'Managed Identity'
        }

        It 'Should get service principal details via Microsoft Graph' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MgServicePrincipal'
        }
    }

    Context 'Microsoft Graph API Roles' {
        It 'Should check for existing application permissions and fail closed' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MgServicePrincipalAppRoleAssignment'
            $content | Should -Match 'existingAppRoles\.Count -gt 0'
            $content | Should -Match 'throw.*existing application permissions'
        }

        It 'Should not create unscoped Graph app role assignments' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Not -Match 'New-MgServicePrincipalAppRoleAssignment'
            $content | Should -Not -Match 'AppRoleAssignment\.ReadWrite\.All'
        }

        It 'Should connect to Microsoft Graph if not connected' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MgContext'
            $content | Should -Match 'Connect-MgGraph'
        }
    }

    Context 'Exchange Online RBAC' {
        It 'Should create Exchange service principal' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'New-ServicePrincipal'
            $content | Should -Match '-AppId.*\$miAppId'
        }

        It 'Should check if service principal already exists' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ServicePrincipal.*AppId.*\$miAppId'
        }

        It 'Should create Management Scope for mailbox restriction' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'New-ManagementScope'
            $content | Should -Match 'RecipientRestrictionFilter'
            $content | Should -Match 'PrimarySmtpAddress -eq'
        }

        It 'Should validate mailbox email address format' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\[System\.Net\.Mail\.MailAddress\]'
        }

        It 'Should assign Application RBAC roles' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Application Mail\.Read'
            $content | Should -Match 'Application Mail\.ReadWrite'
            $content | Should -Match 'New-ManagementRoleAssignment'
        }

        It 'Should scope RBAC roles to the specific mailbox' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'CustomResourceScope.*\$scopeName'
        }

        It 'Should connect to Exchange Online if not connected' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ConnectionInformation'
            $content | Should -Match 'Connect-ExchangeOnline'
        }
    }

    Context 'Security Considerations' {
        It 'Should implement least privilege with Management Scope' {
            $content = Get-Content $scriptPath -Raw
            # Verify that scope restricts to specific mailbox
            $content | Should -Match 'PrimarySmtpAddress -eq.*\$MailboxAddress'
        }

        It 'Should provide permission propagation notice' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '30 min.*2 hours.*propagate'
        }

        It 'Should provide verification command' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Test-ServicePrincipalAuthorization'
        }
    }

    Context 'Error Handling' {
        It 'Should handle missing Managed Identity' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'throw.*Managed Identity'
        }

        It 'Should handle invalid email address' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'throw.*email address'
        }

        It 'Should check for existing assignments and handle gracefully' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ManagementRoleAssignment'
            $content | Should -Not -Match 'Remove-ManagementRoleAssignment'
        }
    }

    Context 'User Experience' {
        It 'Should provide clear progress indicators' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\[1/5\].*Retrieving Managed Identity'
            $content | Should -Match '\[2/5\].*application permissions'
            $content | Should -Match '\[3/5\].*service principal'
            $content | Should -Match '\[4/5\].*Management Scope'
            $content | Should -Match '\[5/5\].*RBAC roles'
        }

        It 'Should provide summary output' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Setup complete'
            $content | Should -Match 'Exchange RBAC:.*Scoped'
        }
    }
}

Describe 'Grant-MIExchangeRBAC.ps1 behavior' {
    BeforeEach {
        $script:tenantId = '11111111-1111-1111-1111-111111111111'
        $script:identityId = '22222222-2222-2222-2222-222222222222'
        $script:appId = '33333333-3333-3333-3333-333333333333'
        $script:mailboxId = '44444444-4444-4444-4444-444444444444'
        $script:scopeName = "DMARC-Mailbox-$script:identityId"
        $script:scopes = @()
        $script:assignments = @()
        $script:existingServicePrincipal = @()
        $script:appRoles = @()
        $script:configuredMailbox = $script:mailboxId

        Mock Get-AzContext { @{ Subscription = @{ Id = 'subscription' }; Tenant = @{ Id = $script:tenantId } } }
        Mock Invoke-AzRestMethod {
            if ($Method -eq 'POST') {
                return @{ StatusCode = 200; Content = (@{ properties = @{ MAILBOX_USER_ID = $script:configuredMailbox } } | ConvertTo-Json) }
            }
            return @{ StatusCode = 200; Content = (@{ identity = @{ principalId = $script:identityId } } | ConvertTo-Json) }
        }
        Mock Get-MgContext { @{ TenantId = $script:tenantId; Scopes = @('Application.Read.All') } }
        Mock Get-MgServicePrincipal { @{ Id = $script:identityId; AppId = $script:appId } }
        Mock Get-MgServicePrincipalAppRoleAssignment { $script:appRoles }
        Mock Get-ConnectionInformation { @{ State = 'Connected'; TenantID = $script:tenantId } }
        Mock Get-EXOMailbox { @{ PrimarySmtpAddress = 'dmarc@example.com'; ExternalDirectoryObjectId = $script:mailboxId; UserPrincipalName = 'dmarc@example.com' } }
        Mock Get-ManagementScope { $script:scopes }
        Mock Get-ServicePrincipal { $script:existingServicePrincipal }
        Mock Get-ManagementRoleAssignment { $script:assignments }
        Mock New-ServicePrincipal { }
        Mock New-ManagementScope { }
        Mock New-ManagementRoleAssignment { }
    }

    It 'creates only mailbox-scoped Exchange roles for a new identity' {
        . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com'
        Should -Invoke New-ServicePrincipal -Times 1 -Exactly
        Should -Invoke New-ManagementScope -Times 1 -Exactly -ParameterFilter { $Name -eq $script:scopeName -and $RecipientRestrictionFilter -eq "PrimarySmtpAddress -eq 'dmarc@example.com'" }
        Should -Invoke New-ManagementRoleAssignment -Times 2 -Exactly -ParameterFilter { $App -eq $script:appId -and $CustomResourceScope -eq $script:scopeName }
        Should -Invoke Get-MgServicePrincipalAppRoleAssignment -Times 1 -Exactly -ParameterFilter { $All }
    }

    It 'is idempotent for matching existing roles and scope' {
        $script:existingServicePrincipal = @(@{ AppId = $script:appId; ObjectId = $script:identityId })
        $script:scopes = @(@{ Name = $script:scopeName; RecipientFilter = "PrimarySmtpAddress -eq 'dmarc@example.com'" })
        $script:assignments = @(
            @{ Name = "DMARC-$script:identityId-Read"; RoleAssignee = $script:identityId; Role = 'Application Mail.Read'; CustomResourceScope = $script:scopeName; Enabled = $true }
            @{ Name = "DMARC-$script:identityId-ReadWrite"; RoleAssignee = $script:identityId; Role = 'Application Mail.ReadWrite'; CustomResourceScope = $script:scopeName; Enabled = $true }
        )
        . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
        Should -Invoke New-ManagementScope -Times 0 -Exactly
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'reuses a matching mailbox scope and its existing assignments' {
        $script:existingServicePrincipal = @(@{ AppId = $script:appId; ObjectId = $script:identityId })
        $script:scopes = @(@{ Name = 'existing-mailbox-scope'; RecipientFilter = "PrimarySmtpAddress -eq 'dmarc@example.com'"; Exclusive = $false; RecipientRoot = $null })
        $script:assignments = @(
            @{ Name = 'existing-read'; RoleAssignee = $script:identityId; Role = 'Application Mail.Read'; CustomResourceScope = 'existing-mailbox-scope'; Enabled = $true }
            @{ Name = 'existing-write'; RoleAssignee = $script:identityId; Role = 'Application Mail.ReadWrite'; CustomResourceScope = 'existing-mailbox-scope'; Enabled = $true }
        )
        . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com'
        Should -Invoke New-ManagementScope -Times 0 -Exactly
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'stops when Exchange rejects scope creation' {
        Mock New-ManagementScope { Write-Error 'Scope creation failed' }
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*Scope creation failed*'
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'stops when Exchange rejects an application role assignment' {
        Mock New-ManagementRoleAssignment { Write-Error 'Role assignment failed' }
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*Role assignment failed*'
    }

    It 'rejects existing direct application permissions before Exchange changes' {
        $script:appRoles = @(@{ AppRoleId = 'broad' })
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*existing application permissions*'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'rejects a scope with an unexpected mailbox filter' {
        $script:scopes = @(@{ Name = $script:scopeName; RecipientFilter = "PrimarySmtpAddress -eq 'other@example.com'" })
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*does not match the requested mailbox*'
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'rejects an exclusive management scope' {
        $script:scopes = @(@{ Name = $script:scopeName; RecipientFilter = "PrimarySmtpAddress -eq 'dmarc@example.com'"; Exclusive = $true })
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*does not match the requested mailbox*'
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'rejects an independently granted Exchange role' {
        $script:assignments = @(@{ Name = 'unscoped'; RoleAssignee = $script:identityId; Role = 'Application Mail.Read'; CustomResourceScope = ''; Enabled = $true })
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*unexpected Exchange application role assignment*'
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }

    It 'rejects an Exchange connection to a different tenant' {
        Mock Get-ConnectionInformation { @{ State = 'Connected'; TenantID = 'other-tenant' } }
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*Connect to Exchange Online for the selected Azure tenant*'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
    }

    It 'rejects a Function App configured for a different mailbox' {
        $script:configuredMailbox = '55555555-5555-5555-5555-555555555555'
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*MAILBOX_USER_ID does not match*'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
    }

    It 'rejects a Graph connection to a different tenant' {
        Mock Get-MgContext { @{ TenantId = 'other-tenant'; Scopes = @('Application.Read.All') } }
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*Microsoft Graph connection must use the Azure tenant*'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
    }

    It 'does not continue when Graph permissions cannot be inspected' {
        Mock Get-MgServicePrincipalAppRoleAssignment { throw 'Graph access denied' }
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*Graph access denied*'
        Should -Invoke New-ServicePrincipal -Times 0 -Exactly
    }

    It 'does not replace an assignment owned by another identity' {
        $script:assignments = @(@{ Name = "DMARC-$script:identityId-Read"; RoleAssignee = 'other-identity'; Role = 'Application Mail.Read'; CustomResourceScope = $script:scopeName; Enabled = $true })
        { . $scriptPath -FunctionAppName 'test' -ResourceGroupName 'test' -MailboxAddress 'dmarc@example.com' } | Should -Throw '*unexpected properties*'
        Should -Invoke New-ManagementRoleAssignment -Times 0 -Exactly
    }
}
