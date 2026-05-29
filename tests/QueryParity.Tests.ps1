#Requires -Version 7.4
#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $workbookFile = Join-Path $repoRoot 'workbook/dmarc-workbook.json'
    $alertsBicepFile = Join-Path $repoRoot 'infra/alerts.bicep'

    $workbookContent = Get-Content -Path $workbookFile -Raw
    $alertsContent = Get-Content -Path $alertsBicepFile -Raw
}

Describe 'KQL query parity checks' {
    Context 'Workbook denominator and DMARC semantics guardrails' {
        It 'uses OR semantics for DMARC pass calculations in workbook queries' {
            $workbookContent | Should -Match 'PolicyEvaluated_dkim\s*=~\s*''pass''\s*or\s*PolicyEvaluated_spf\s*=~\s*''pass'''
        }

        It 'uses case-insensitive auth-result comparisons in workbook queries' {
            $workbookContent | Should -Not -Match 'PolicyEvaluated_dkim\s*==\s*''(pass|fail)'''
            $workbookContent | Should -Not -Match 'PolicyEvaluated_spf\s*==\s*''(pass|fail)'''
            $workbookContent | Should -Not -Match 'PolicyEvaluated_dkim\s*!=\s*''pass'''
            $workbookContent | Should -Not -Match 'PolicyEvaluated_spf\s*!=\s*''pass'''
        }

        It 'includes denominator guards for pass-rate style workbook calculations' {
            $workbookContent | Should -Match 'PassRate\s*=\s*iff\(TotalMessages\s*>\s*0'
            $workbookContent | Should -Match 'PassRate\s*=\s*iff\(Messages\s*>\s*0'
            $workbookContent | Should -Match 'SpfPassRate\s*=\s*iff\(TotalMessages\s*>\s*0'
            $workbookContent | Should -Match 'DkimPassRate\s*=\s*iff\(TotalMessages\s*>\s*0'
        }

        It 'does not contain unguarded workbook pass-rate divisions across visuals' {
            $unguardedRateMatches = [regex]::Matches(
                $workbookContent,
                '(DmarcPassRate|SpfPassRate|DkimPassRate|PassRate|AdjustedPassRate)\s*=\s*round\(\s*100\.0\s*\*[^\r\n]*\/[^\r\n]*,\s*1\s*\)'
            )

            $unguardedRateMatches.Count | Should -Be 0
        }

        It 'includes denominator guards for compliance score calculations' {
            $workbookContent | Should -Match 'ComplianceScore\s*=\s*iff\('
            $workbookContent | Should -Match 'Messages\s*>\s*0'
            $workbookContent | Should -Match '0\.40\s*\*\s*\(100\.0\s*\*\s*DmarcPass\s*/\s*Messages\)'
            $workbookContent | Should -Match '0\.25\s*\*\s*\(100\.0\s*\*\s*SpfPassCount\s*/\s*Messages\)'
            $workbookContent | Should -Match '0\.25\s*\*\s*\(100\.0\s*\*\s*DkimPassCount\s*/\s*Messages\)'
        }
    }

    Context 'Workbook anomaly query parity' {
        It 'defines expected anomaly baseline windows and minimum activity' {
            $workbookContent | Should -Match 'let\s+lookback\s*=\s*30d;'
            $workbookContent | Should -Match 'let\s+recentWindow\s*=\s*1d;'
            $workbookContent | Should -Match 'DaysActive\s*>?=\s*3'
        }

        It 'uses guarded anomaly thresholds for z-score and volume multiple' {
            $workbookContent | Should -Match 'ZScore\s*=\s*iff\(StdDevVolume\s*>\s*0'
            $workbookContent | Should -Match 'VolumeMultiple\s*=\s*iff\(AvgDailyVolume\s*>\s*0'
            $workbookContent | Should -Match 'ZScore\s*>\s*2\.0\s*or\s*VolumeMultiple\s*>\s*3\.0'
        }
    }

    Context 'Alert KQL parity with workbook expectations' {
        It 'uses pass-rate threshold parameter and denominator protection' {
            $alertsContent | Should -Match 'param\s+passRateThreshold\s+int\s*=\s*90'
            $alertsContent | Should -Match 'PassRate\s*=\s*iff\(TotalMessages\s*==\s*0,\s*100\.0'
            $alertsContent | Should -Match '\|\s*where\s+PassRate\s*<\s*\$\{passRateThreshold\}'
        }

        It 'uses DMARC pass OR logic in pass-rate alert' {
            $alertsContent | Should -Match 'PassedMessages\s*=\s*sumif\(MessageCountSafe,\s*PolicyEvaluated_dkim\s*=~\s*"pass"\s*or\s*PolicyEvaluated_spf\s*=~\s*"pass"\)'
        }

        It 'uses expected baseline and threshold logic in volume spike alert' {
            $alertsContent | Should -Match 'let\s+baselineStart\s*=\s*ago\(31d\);'
            $alertsContent | Should -Match 'let\s+baselineEnd\s*=\s*ago\(1d\);'
            $alertsContent | Should -Match 'AvgDailyVolume\s*=\s*avg\(DailyVolume\);'
            $alertsContent | Should -Match 'TodayVolume\s*>\s*AvgDailyVolume\s*\*\s*3\s*and\s*AvgDailyVolume\s*>\s*0'
        }

        It 'uses expected suspicious new-source threshold logic' {
            $alertsContent | Should -Match 'let\s+lookbackStart\s*=\s*ago\(31d\);'
            $alertsContent | Should -Match 'let\s+lookbackEnd\s*=\s*ago\(1d\);'
            $alertsContent | Should -Match 'PolicyEvaluated_dkim\s*!~\s*"pass"\s*and\s*PolicyEvaluated_spf\s*!~\s*"pass"'
            $alertsContent | Should -Match 'FailedMessages\s*>=\s*10'
        }

        It 'uses case-insensitive auth-result comparisons in alerts' {
            $alertsContent | Should -Not -Match 'PolicyEvaluated_dkim\s*==\s*"pass"'
            $alertsContent | Should -Not -Match 'PolicyEvaluated_spf\s*==\s*"pass"'
            $alertsContent | Should -Not -Match 'PolicyEvaluated_dkim\s*!=\s*"pass"'
            $alertsContent | Should -Not -Match 'PolicyEvaluated_spf\s*!=\s*"pass"'
        }
    }

    Context 'P2 operational quality controls parity' {
        It 'includes workbook duplicate telemetry visuals and key extraction logic' {
            $workbookContent | Should -Match 'Duplicate Report-Key Ratio \(Daily\)'
            $workbookContent | Should -Match 'Top Duplicate Contributors'
            $workbookContent | Should -Match 'column_ifexists\(''DuplicateTelemetryKey'',\s*''''\)'
            $workbookContent | Should -Match 'DuplicateRatio\s*=\s*iff\(TotalKeys\s*>\s*0'
        }

        It 'includes workbook freshness summary states and counts' {
            $workbookContent | Should -Match 'Freshness State Counts'
            $workbookContent | Should -Match 'Freshness\s*=\s*case\('
            $workbookContent | Should -Match "'Fresh'"
            $workbookContent | Should -Match "'Stale'"
        }

        It 'includes workbook forwarding and ARC operator guidance notes' {
            $workbookContent | Should -Match 'Forwarding and ARC edge-case guidance'
            $workbookContent | Should -Match 'ARC trusted sealer configuration'
        }

        It 'includes stale-reporter and duplicate-ratio alert rules' {
            $alertsContent | Should -Match 'name:\s*''dmarc-stale-reporters'''
            $alertsContent | Should -Match 'name:\s*''dmarc-duplicate-report-key-ratio'''
            $alertsContent | Should -Match 'param\s+duplicateRatioThreshold\s+int\s*=\s*5'
            $alertsContent | Should -Match 'StaleReporterCount\s*=\s*count\(\)'
            $alertsContent | Should -Match 'isnotempty\(ReportOrgName\)'
            $alertsContent | Should -Match 'column_ifexists\("DuplicateTelemetryKey",\s*""\)'
        }
    }
}
