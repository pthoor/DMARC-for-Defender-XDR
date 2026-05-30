#Requires -Version 7.4
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Azure Function run.ps1 scripts.
.DESCRIPTION
    Tests the Azure Function trigger scripts for proper structure,
    error handling, and security validations.
#>

Describe 'DmarcReportProcessor/run.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../src/function/DmarcReportProcessor/run.ps1"
    }

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

        It 'Should accept eventGridEvent parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'param\s*\(.*\$eventGridEvent'
        }

        It 'Should import DmarcHelpers module' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Import-Module.*DmarcHelpers'
        }
    }

    Context 'Security Validations' {
        It 'Should validate client state' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$expectedClientState.*GRAPH_CLIENT_STATE'
            $content | Should -Match '(?s)clientState.*not match'
        }

        It 'Should use case-sensitive comparison for client state' {
            $content = Get-Content $scriptPath -Raw
            # -cne is the case-sensitive operator; -ne would allow case variants of the secret
            $content | Should -Match '\-cne\s+\$expectedClientState'
            $content | Should -Not -Match '[^c]-ne\s+\$expectedClientState'
        }

        It 'Should warn if GRAPH_CLIENT_STATE is not configured' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'if.*-not.*\$expectedClientState'
            $content | Should -Match 'Write-Warning.*GRAPH_CLIENT_STATE'
        }

        It 'Should not log sensitive clientState value' {
            $content = Get-Content $scriptPath -Raw
            # Verify that logging redacts sensitive fields
            $content | Should -Match 'sensitive fields redacted'
        }
    }

    Context 'Event Processing' {
        It 'Should extract message ID from event' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-EventGridMessageId'
            $content | Should -Match 'ResourceData\.id'
            $content | Should -Match 'eventGridEvent\.subject'
        }

        It 'Should handle missing message ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'if.*-not.*\$messageId'
            $content | Should -Match 'Write-Error.*message ID'
        }

        It 'Should call Invoke-DmarcReportProcessing' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Invoke-DmarcReportProcessing.*-MessageId'
        }

        It 'Should handle flexible event structure' {
            $content = Get-Content $scriptPath -Raw
            # Check for alternative paths to extract resourceData
            $content | Should -Match '\$resourceData.*eventGridEvent\.data'
        }
    }

    Context 'Error Handling' {
        It 'Should wrap processing in try-catch' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'try\s*\{'
            $content | Should -Match 'catch\s*\{'
        }

        It 'Should log errors with stack trace' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Error.*\$_'
            $content | Should -Match 'ScriptStackTrace'
        }

        It 'Should re-throw errors for Event Grid retry' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'throw.*Re-throw'
        }
    }

    Context 'Logging' {
        It 'Should log event type' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*eventType'
        }

        It 'Should log message ID being processed' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*message ID'
        }

        It 'Should log success message' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Successfully processed'
        }
    }
}

Describe 'RenewGraphSubscription/run.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../src/function/RenewGraphSubscription/run.ps1"
    }

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

        It 'Should accept Timer parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'param\s*\(.*\$Timer'
        }

        It 'Should import DmarcHelpers module' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Import-Module.*DmarcHelpers'
        }
    }

    Context 'Configuration Validation' {
        It 'Should check for GRAPH_SUBSCRIPTION_ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$subscriptionId.*GRAPH_SUBSCRIPTION_ID'
            $content | Should -Match 'if.*-not.*\$subscriptionId'
        }

        It 'Should provide helpful error if subscription ID missing' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Run New-GraphSubscription\.ps1'
        }
    }

    Context 'Subscription Renewal' {
        It 'Should get Managed Identity token' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ManagedIdentityToken'
        }

        It 'Should set new expiration date' {
            $content = Get-Content $scriptPath -Raw
            # Check expiration is set to 4200 minutes (just under the 4230 max)
            $content | Should -Match 'expirationDateTime'
            $content | Should -Match 'AddMinutes\(4200\)'
        }

        It 'Should use PATCH method to update subscription' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Invoke-GraphRequest.*-Method PATCH'
        }

        It 'Should target correct Graph API endpoint' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'https://graph\.microsoft\.com/v1\.0/subscriptions'
        }
    }

    Context 'Error Handling' {
        It 'Should wrap processing in try-catch' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'try\s*\{'
            $content | Should -Match 'catch\s*\{'
        }

        It 'Should handle 404 (subscription not found) specifically' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'statusCode -eq 404'
            $content | Should -Match 'Subscription.*not found'
        }

        It 'Should re-throw for retry on other errors' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'throw.*Re-throw'
        }
    }

    Context 'Timer Handling' {
        It 'Should check if timer is past due' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$Timer\.IsPastDue'
        }

        It 'Should warn if timer is past due' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Warning.*past due'
        }
    }

    Context 'Logging' {
        It 'Should log renewal action' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Renewing'
        }

        It 'Should log new expiration' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*renewed'
            $content | Should -Match 'expirationDateTime'
        }
    }
}

Describe 'CatchupProcessor/run.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../src/function/CatchupProcessor/run.ps1"
    }

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

        It 'Should accept Timer parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'param\s*\(.*\$Timer'
        }

        It 'Should import DmarcHelpers module' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Import-Module.*DmarcHelpers'
        }
    }

    Context 'Configuration Validation' {
        It 'Should check for MAILBOX_USER_ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$userId.*MAILBOX_USER_ID'
            $content | Should -Match 'if.*-not.*\$userId'
        }
    }

    Context 'Message Processing' {
        It 'Should get Managed Identity token' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ManagedIdentityToken'
        }

        It 'Should query for unread messages via paged helper' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MailboxMessages'
            $content | Should -Match 'Days.*2'
        }

        It 'Should handle no unread messages gracefully' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'if.*-not.*\$unreadMessages.*Count -eq 0'
            $content | Should -Match 'All caught up'
        }

        It 'Should process each message' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'foreach.*\$message.*\$unreadMessages'
            $content | Should -Match 'Invoke-DmarcReportProcessing'
        }

        It 'Should track success and failure counts' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$successCount'
            $content | Should -Match '\$failCount'
        }
    }

    Context 'Error Handling' {
        It 'Should wrap entire processing in try-catch' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'try\s*\{'
            $content | Should -Match 'catch\s*\{'
        }

        It 'Should handle individual message failures gracefully' {
            $content = Get-Content $scriptPath -Raw
            # Check for try-catch handling in the foreach loop
            $content | Should -Match 'foreach.*message'
            $content | Should -Match '(?s)try.*catch'
        }

        It 'Should log individual message failures' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Warning.*Failed to process message'
        }

        It 'Should continue processing after individual failures' {
            $content = Get-Content $scriptPath -Raw
            # Verify it increments fail count but continues
            $content | Should -Match '\$failCount\+\+'
        }
    }

    Context 'Timer Handling' {
        It 'Should check if timer is past due' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$Timer\.IsPastDue'
        }

        It 'Should warn if timer is past due' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Warning.*past due'
        }
    }

    Context 'Logging' {
        It 'Should log start message' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Catchup processor started'
        }

        It 'Should log found message count' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Found.*unread message'
        }

        It 'Should log completion summary' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Catchup complete'
            $content | Should -Match 'Processed.*Failed'
        }
    }
}

Describe 'BackfillProcessor/run.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../src/function/BackfillProcessor/run.ps1"
    }

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

        It 'Should accept Request parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'param\s*\(.*\$Request'
        }

        It 'Should import DmarcHelpers module' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Import-Module.*DmarcHelpers'
        }
    }

    Context 'Configuration Validation' {
        It 'Should check for MAILBOX_USER_ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$userId.*MAILBOX_USER_ID'
            $content | Should -Match 'if.*-not.*\$userId'
        }
    }

    Context 'Query Parameters' {
        It 'Should parse days parameter with validation' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Request\.Query\.days'
            $content | Should -Match '\[int\]::TryParse'
            $content | Should -Match 'between 1 and 365'
        }

        It 'Should default days to 7' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$days = 7'
        }

        It 'Should parse includeRead parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Request\.Query\.includeRead'
        }

        It 'Should default includeRead to false' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$includeRead = \$false'
        }
    }

    Context 'Message Processing' {
        It 'Should use Get-MailboxMessages with paging' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MailboxMessages'
        }

        It 'Should pass days and includeRead parameters' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-MailboxMessages.*-Days.*\$days'
            $content | Should -Match '-IncludeRead.*\$includeRead'
        }

        It 'Should process each message' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'foreach.*\$message.*\$messages'
            $content | Should -Match 'Invoke-DmarcReportProcessing'
        }

        It 'Should track success and failure counts' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$successCount'
            $content | Should -Match '\$failCount'
        }
    }

    Context 'HTTP Response' {
        It 'Should return JSON response with processing summary' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Push-OutputBinding.*Response'
            $content | Should -Match 'processed'
            $content | Should -Match 'failed'
        }

        It 'Should return 400 for invalid days parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'StatusCode.*400'
        }

        It 'Should return 500 for missing MAILBOX_USER_ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'StatusCode.*500'
        }

        It 'Should return 200 with summary on success' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'StatusCode.*200'
        }
    }

    Context 'Error Handling' {
        It 'Should wrap processing in try-catch' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'try\s*\{'
            $content | Should -Match 'catch\s*\{'
        }

        It 'Should handle individual message failures gracefully' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'foreach.*message'
            $content | Should -Match '(?s)try.*catch'
        }

        It 'Should continue processing after individual failures' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$failCount\+\+'
        }
    }

    Context 'Logging' {
        It 'Should log backfill start with parameters' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Backfill started'
            $content | Should -Match 'days.*includeRead'
        }

        It 'Should log found message count' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Write-Information.*Found.*message'
        }

        It 'Should log completion summary' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Backfill complete'
        }
    }
}

Describe 'SetupHelper/run.ps1' {
    BeforeAll {
        $scriptPath = "$PSScriptRoot/../src/function/SetupHelper/run.ps1"
    }

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

        It 'Should accept Request parameter' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'param\s*\(.*\$Request'
        }

        It 'Should import DmarcHelpers module' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Import-Module.*DmarcHelpers'
        }
    }

    Context 'Input Validation' {
        It 'Should require notificationUrl and expirationDateTime' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'notificationUrl'
            $content | Should -Match 'expirationDateTime'
            $content | Should -Match 'Missing required fields'
        }

        It 'Should accept HTTPS scheme for notificationUrl' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match "Scheme -ne 'https'"
        }

        It 'Should accept EventGrid scheme for notificationUrl' {
            $content = Get-Content $scriptPath -Raw
            # EventGrid: is the correct scheme for Graph subscriptions delivered via Event Grid partner topics
            $content | Should -Match "Scheme -ne 'eventgrid'"
        }

        It 'Should reject non-HTTPS non-EventGrid schemes' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'notificationUrl must use the HTTPS or EventGrid scheme'
        }

        It 'Should reject malformed URLs' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'notificationUrl is not a valid URL'
        }
    }

    Context 'Configuration Validation' {
        It 'Should check for MAILBOX_USER_ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'MAILBOX_USER_ID'
            $content | Should -Match 'if.*-not.*\$mailboxUserId'
        }

        It 'Should check for GRAPH_CLIENT_STATE' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'GRAPH_CLIENT_STATE'
            $content | Should -Match 'if.*-not.*\$clientState'
        }

        It 'Should detect unresolved Key Vault references' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '@Microsoft\.KeyVault'
            $content | Should -Match 'unresolved Key Vault reference'
        }
    }

    Context 'Security' {
        It 'Should not return internal exception details in error responses' {
            $content = Get-Content $scriptPath -Raw
            # The top-level catch must not interpolate $_.Exception.Message into the response body
            $content | Should -Match 'An internal error occurred'
            $content | Should -Not -Match 'error.*Exception\.Message'
        }
    }

    Context 'Graph Subscription Creation' {
        It 'Should request a Managed Identity token for Graph' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Get-ManagedIdentityToken.*graph\.microsoft\.com'
        }

        It 'Should POST to the Graph subscriptions endpoint' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'graph\.microsoft\.com/v1\.0/subscriptions'
        }

        It 'Should return the created subscription ID' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'subscriptionId.*result\.id'
        }
    }

    Context 'Error Handling' {
        It 'Should wrap processing in try-catch' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'try\s*\{'
            $content | Should -Match 'catch\s*\{'
        }
    }
}
