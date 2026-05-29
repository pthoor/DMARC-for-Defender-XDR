#Requires -Version 7.4
#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $versionFile = Join-Path $repoRoot 'VERSION'
    $workbookFile = Join-Path $repoRoot 'workbook/dmarc-workbook.json'
    $alertsBicepFile = Join-Path $repoRoot 'infra/alerts.bicep'
    $detectionFiles = Get-ChildItem -Path (Join-Path $repoRoot 'detections') -Filter '*.yaml' -File

    $version = (Get-Content -Path $versionFile -Raw).Trim()
    $workbookContent = Get-Content -Path $workbookFile -Raw
    $alertsContent = Get-Content -Path $alertsBicepFile -Raw
}

Describe 'Versioning and query safety metadata' {
    Context 'SemVer consistency' {
        It 'VERSION should be valid SemVer' {
            $version | Should -Match '^\d+\.\d+\.\d+$'
        }

        It 'All detection rules should match VERSION metadata' {
            foreach ($file in $detectionFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                $content | Should -Match "(?m)^version:\s+$([regex]::Escape($version))$"
            }
        }

        It 'Workbook header should include workbook release metadata' {
            $workbookContent | Should -Match "Workbook release[:*\s]+v$([regex]::Escape($version))"
        }

        It 'Workbook header should include GitHub release links and update-check guidance' {
            $workbookContent | Should -Match 'https://github\.com/pthoor/DMARC-Analyzer-Azure'
            $workbookContent | Should -Match 'https://github\.com/pthoor/DMARC-Analyzer-Azure/releases/latest'
            $workbookContent | Should -Match 'Update check'
        }
    }

    Context 'KQL safety guardrails' {
        It 'Workbook should include divide-by-zero guards for key metrics and scoring queries' {
            $workbookContent | Should -Match 'PassRate\s*=\s*iff\(TotalMessages\s*>\s*0'
            $workbookContent | Should -Match 'ComplianceScore\s*=\s*iff\('
            $workbookContent | Should -Match 'Messages\s*>\s*0'
            $workbookContent | Should -Match 'VolumeMultiple\s*=\s*iff\(AvgDailyVolume\s*>\s*0'
        }

        It 'Alert pass-rate logic should use DMARC semantics (SPF OR DKIM pass)' {
            $alertsContent | Should -Match 'PassedMessages\s*=\s*sumif\(MessageCountSafe, PolicyEvaluated_dkim =~ "pass" or PolicyEvaluated_spf =~ "pass"\)'
        }
    }
}
