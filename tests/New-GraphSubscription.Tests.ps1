#Requires -Version 7.4
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for New-GraphSubscription.ps1 script.
.DESCRIPTION
    Tests the Graph subscription setup script for proper parameter validation,
    error handling, and workflow.
#>

BeforeAll {
    $scriptPath = "$PSScriptRoot/../scripts/New-GraphSubscription.ps1"
    $bashScriptPath = "$PSScriptRoot/../scripts/New-GraphSubscription.sh"
}

Describe 'New-GraphSubscription.ps1' {
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
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$SubscriptionId'
        }

        It 'Should set ErrorActionPreference to Stop' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]'
        }
    }

    Context 'Deployment Verification' {
        It 'Should get default hostname from ARM' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'defaultHostName'
        }

        It 'Should verify SetupHelper function is deployed' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'SetupHelper.*-notin.*deployedFunctions'
        }

        It 'Should reference the documented ZIP deployment if the function is not deployed' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'manual ZIP deployment steps in README\.md'
        }
    }

    Context 'Graph Subscription Creation' {
        It 'Should retrieve master host key via ARM API' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'host/default/listkeys'
            $content | Should -Match 'masterKey'
        }

        It 'Should invoke SetupHelper function endpoint' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'api/SetupHelper'
        }

        It 'Should pass master key as x-functions-key header, not query parameter' {
            $content = Get-Content $scriptPath -Raw
            # Key must be sent as a header to keep it out of shell history and server logs
            $content | Should -Match "x-functions-key"
            $content | Should -Not -Match 'api/SetupHelper\?code='
        }

        It 'Should use hostname from ARM (not hardcoded)' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'defaultHostName'
            # Should not construct URL with hardcoded .azurewebsites.net
            $content | Should -Not -Match '\$FunctionAppName\.azurewebsites\.net'
        }

        It 'Should retry for cold start' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'maxAttempts'
            $content | Should -Match 'StatusCode -ne 404'
            $content | Should -Match 'retrying in 15s'
        }

        It 'Should pass a stored subscription ID to SetupHelper for resume' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'existingGraphSubscriptionId'
            $content | Should -Match 'setupPayload\.subscriptionId'
        }

        It 'Should save the ID before Event Grid setup to support safe reruns' {
            $content = Get-Content $scriptPath -Raw
            $saveIndex = $content.IndexOf('GRAPH_SUBSCRIPTION_ID saved before Event Grid setup')
            $eventGridIndex = $content.IndexOf('[3/4] Activating partner topic', [System.StringComparison]::OrdinalIgnoreCase)
            ($saveIndex -ge 0 -and $eventGridIndex -gt $saveIndex) | Should -Be $true
        }

        It 'Should not automatically replay ambiguous subscription creation failures' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'do not automatically replay the POST'
            $content | Should -Match 'It was not retried automatically'
        }

        It 'Should construct correct notification URL' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'EventGrid:\?azuresubscriptionid='
            $content | Should -Match 'partnertopic='
        }

        It 'Should set expiration to 4200 minutes' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'AddMinutes\(4200\)'
        }

        It 'Should NOT use Connect-MgGraph or Graph PowerShell SDK' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Not -Match 'Connect-MgGraph'
            $content | Should -Not -Match 'Invoke-MgGraphRequest'
        }
    }

    Context 'Partner Topic Activation' {
        It 'Should wait for partner topic to appear' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Waiting for partner topic'
            $content | Should -Match 'partnerTopics'
        }

        It 'Should activate the partner topic' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '(?s)partnerTopics.*activate'
        }

        It 'Should skip partner topic activation when it is already active' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match "activationState -eq 'Activated'"
        }

        It 'Should handle timeout' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'did not appear within'
        }
    }

    Context 'Event Subscription Creation' {
        It 'Should create event subscription on partner topic' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'eventSubscriptions/dmarc-report-processor'
        }

        It 'Should use AzureFunction endpoint targeting DmarcReportProcessor' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'endpointType.*AzureFunction'
            $content | Should -Match 'functions/DmarcReportProcessor'
        }

        It 'Should use CloudEventSchemaV1_0 (required by Graph partner topics)' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'CloudEventSchemaV1_0'
        }
    }

    Context 'Subscription ID Management' {
        It 'Should save GRAPH_SUBSCRIPTION_ID to app settings via ARM REST' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'GRAPH_SUBSCRIPTION_ID'
            $content | Should -Match 'config/appsettings'
        }

        It 'Should NOT use Set-AzWebApp (incompatible with Flex Consumption)' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Not -Match 'Set-AzWebApp'
        }

        It 'Should merge with existing app settings' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'config/appsettings/list'
            $content | Should -Match 'updatedProperties'
        }
    }

    Context 'User Experience' {
        It 'Should display step progress' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\[1/4\]'
            $content | Should -Match '\[4/4\]'
        }

        It 'Should display completion message' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'Setup complete'
            $content | Should -Match 'Graph subscription ID:'
        }

        It 'Should not require manual steps or prompts' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Not -Match 'Read-Host'
        }
    }
}

Describe 'New-GraphSubscription.sh' {
    BeforeAll {
        $content = Get-Content $bashScriptPath -Raw
    }

    It 'passes a validated stored subscription ID to SetupHelper' {
        $content | Should -Match 'EXISTING_GRAPH_SUBSCRIPTION_ID'
        $content | Should -Match 'subscriptionId: \$id'
        $content | Should -Match '\[\[:xdigit:\]\]\{8\}.*\[\[:xdigit:\]\]\{12\}'
    }

    It 'retries only confirmed 404 responses' {
        $content | Should -Match '\[\[ "\$HTTP_CODE" == "404" && \$attempt -lt \$MAX_ATTEMPTS \]\]'
        $content | Should -Match 'retrying in 15s'
        $content | Should -Match 'not retried automatically to avoid duplicate Graph subscriptions'
    }

    It 'saves the subscription ID before Event Grid setup and verifies it afterward' {
        $saveIndex = $content.IndexOf('GRAPH_SUBSCRIPTION_ID saved before Event Grid setup')
        $eventGridIndex = $content.IndexOf('[3/4] Activating partner topic', [System.StringComparison]::OrdinalIgnoreCase)
        $verifyIndex = $content.IndexOf('[4/4] Verifying saved subscription ID', [System.StringComparison]::OrdinalIgnoreCase)
        ($saveIndex -ge 0 -and $eventGridIndex -gt $saveIndex -and $verifyIndex -gt $eventGridIndex) | Should -Be $true
    }

    It 'skips partner-topic activation when it is already active' {
        $content | Should -Match 'properties\.activationState'
        $alreadyActiveIndex = $content.IndexOf('if [[ "$ACTIVATION_STATE" == "Activated" ]]')
        $needsActivationIndex = $content.IndexOf('elif [[ "$ACTIVATION_STATE" == "NeverActivated" ]]')
        $activationRequestIndex = $content.IndexOf('az rest --method post --url "${TOPIC_URL}/activate?${EG_API}"')
        ($alreadyActiveIndex -ge 0 -and $needsActivationIndex -gt $alreadyActiveIndex -and $activationRequestIndex -gt $needsActivationIndex) | Should -Be $true
    }
}
