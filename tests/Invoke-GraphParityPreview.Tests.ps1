#Requires -Version 7.4
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for Invoke-GraphParityPreview.ps1 script.
.DESCRIPTION
    Validates script structure and key implementation markers for Graph parity preview.
#>

BeforeAll {
    $scriptPath = "$PSScriptRoot/../scripts/Invoke-GraphParityPreview.ps1"
}

Describe 'Invoke-GraphParityPreview.ps1' {
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

        It 'Should require mailbox and workspace inputs' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$MailboxUserId'
            $content | Should -Match '(?s)\[Parameter\(Mandatory\)\].*?\$WorkspaceId'
        }

        It 'Should expose hardening parameters for lag and triage' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$IngestionLagHours'
            $content | Should -Match '\$SubjectRegex'
            $content | Should -Match '\$RecentDelayMinutes'
            $content | Should -Match '\$SampleSize'
        }

        It 'Should set ErrorActionPreference to Stop' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$ErrorActionPreference\s*=\s*[''\"]Stop[''\"]'
        }
    }

    Context 'Graph Query Path' {
        It 'Should use Azure CLI to get a Microsoft Graph token' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'get-access-token'
            $content | Should -Match 'ms-graph'
        }

        It 'Should call Microsoft Graph messages endpoint' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'graph\.microsoft\.com/v1\.0/users/.+/messages'
        }

        It 'Should handle Graph paging with @odata.nextLink' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '@odata\.nextLink'
            $content | Should -Match 'MaxPages'
        }
    }

    Context 'Log Analytics Parity Path' {
        It 'Should query Log Analytics via Azure CLI' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match "'monitor', 'log-analytics', 'query'"
        }

        It 'Should apply ingestion lag to Log Analytics query window' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'AddHours\(\$IngestionLagHours\)'
            $content | Should -Match 'laQueryWindowEndUtc'
        }

        It 'Should query SourceMessageId in DMARCReports_CL' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'DMARCReports_CL'
            $content | Should -Match 'SourceMessageId'
        }

        It 'Should compute missing and extra ID sets' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'missingInLogAnalytics'
            $content | Should -Match 'extraInLogAnalytics'
        }

        It 'Should expose a match rate percentage' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'matchRatePct'
            $content | Should -Match 'candidateCoveragePct'
        }

        It 'Should generate triage categories for missing candidates' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match 'triageSummary'
            $content | Should -Match 'likelyNonDmarcSubjectCount'
            $content | Should -Match 'likelyPendingIngestionCount'
            $content | Should -Match 'likelyPipelineGapCount'
        }
    }

    Context 'Output and UX' {
        It 'Should support optional JSON report output path' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\$OutputPath'
            $content | Should -Match 'ConvertTo-Json'
            $content | Should -Match 'Set-Content'
        }

        It 'Should show four-step progress output' {
            $content = Get-Content $scriptPath -Raw
            $content | Should -Match '\[1/4\]'
            $content | Should -Match '\[4/4\]'
        }
    }
}
