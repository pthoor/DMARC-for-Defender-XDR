#Requires -Version 7.4
#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $inputPath = Join-Path $repoRoot 'tests/fixtures/dmarc-golden-input.jsonl'
    $expectedPath = Join-Path $repoRoot 'tests/fixtures/dmarc-golden-expected.json'

    function ConvertTo-Round1 {
        param([double]$Value)
        return [math]::Round($Value, 1, [System.MidpointRounding]::AwayFromZero)
    }

    function ConvertTo-Round0 {
        param([double]$Value)
        return [math]::Round($Value, 0, [System.MidpointRounding]::AwayFromZero)
    }

    function Get-AuthResultLower {
        param([object]$Value)

        if ($null -eq $Value) {
            return ''
        }

        return $Value.ToString().Trim().ToLowerInvariant()
    }

    function Get-MessageCountSafe {
        param([object]$Value)

        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($Value.ToString())) {
            return 0L
        }

        return [long]$Value
    }

    function Assert-DoubleEqual {
        param(
            [double]$Actual,
            [double]$Expected,
            [string]$Label
        )

        $withinTolerance = [math]::Abs($Actual - $Expected) -le 0.0001
        $withinTolerance | Should -Be $true -Because $Label
    }

    $records = Get-Content -Path $inputPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        $raw = $_ | ConvertFrom-Json
        $dkim = Get-AuthResultLower -Value $raw.PolicyEvaluated_dkim
        $spf = Get-AuthResultLower -Value $raw.PolicyEvaluated_spf
        $messageCountSafe = Get-MessageCountSafe -Value $raw.MessageCount

        [pscustomobject]@{
            TimeGenerated         = [datetime]$raw.TimeGenerated
            ReportDateRangeBegin  = [datetime]$raw.ReportDateRangeBegin
            Domain                = [string]$raw.Domain
            ReportOrgName         = [string]$raw.ReportOrgName
            SourceIP              = [string]$raw.SourceIP
            PolicyPublished_p     = [string]$raw.PolicyPublished_p
            PolicyPublished_pNorm = Get-AuthResultLower -Value $raw.PolicyPublished_p
            MessageCountSafe      = $messageCountSafe
            IsPass                = ($dkim -eq 'pass' -or $spf -eq 'pass')
            IsFail                = ($dkim -eq 'fail' -and $spf -eq 'fail')
            SpfPass               = ($spf -eq 'pass')
            DkimPass              = ($dkim -eq 'pass')
        }
    }

    $expected = Get-Content -Path $expectedPath -Raw | ConvertFrom-Json

    $latestPolicyByDomain = $records |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Domain) } |
        Group-Object -Property Domain |
        ForEach-Object {
            $_.Group | Sort-Object -Property TimeGenerated -Descending | Select-Object -First 1
        }

    $totalMessages = [long](($records | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
    $pass = [long](($records | Where-Object { $_.IsPass } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
    $fail = [long](($records | Where-Object { $_.IsFail } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)

    $actualKpi = [ordered]@{
        TotalMessages   = $totalMessages
        Pass            = $pass
        Fail            = $fail
        PassRate        = if ($totalMessages -gt 0) { ConvertTo-Round1 -Value (100.0 * $pass / $totalMessages) } else { 0.0 }
        DomainsMonitored = ($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Domain) } | Select-Object -ExpandProperty Domain -Unique).Count
        UniqueIPs        = ($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.SourceIP) } | Select-Object -ExpandProperty SourceIP -Unique).Count
        UniqueReporters  = ($records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ReportOrgName) } | Select-Object -ExpandProperty ReportOrgName -Unique).Count
        EnforcedDomains  = ($latestPolicyByDomain | Where-Object { $_.PolicyPublished_pNorm -in @('quarantine', 'reject') }).Count
        TotalDomains     = $latestPolicyByDomain.Count
    }

    $actualKpi.EnforcementPct = if ($actualKpi.TotalDomains -gt 0) {
        ConvertTo-Round1 -Value (100.0 * $actualKpi.EnforcedDomains / $actualKpi.TotalDomains)
    } else {
        0.0
    }

    $actualDaily = $records |
        Group-Object -Property { $_.ReportDateRangeBegin.ToString('yyyy-MM-dd') } |
        Sort-Object -Property Name |
        ForEach-Object {
            $groupRecords = $_.Group
            $messages = [long](($groupRecords | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $dailyPass = [long](($groupRecords | Where-Object { $_.IsPass } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $dailyFail = [long](($groupRecords | Where-Object { $_.IsFail } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)

            [pscustomobject]@{
                Date = $_.Name
                Messages = $messages
                Pass = $dailyPass
                Fail = $dailyFail
                PassRate = if ($messages -gt 0) { ConvertTo-Round1 -Value (100.0 * $dailyPass / $messages) } else { 0.0 }
            }
        }

    $actualDomainCompliance = $records |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Domain) } |
        Group-Object -Property Domain |
        Sort-Object -Property Name |
        ForEach-Object {
            $domainRecords = $_.Group
            $messages = [long](($domainRecords | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $dmarcPass = [long](($domainRecords | Where-Object { $_.IsPass } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $spfPass = [long](($domainRecords | Where-Object { $_.SpfPass } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $dkimPass = [long](($domainRecords | Where-Object { $_.DkimPass } | Measure-Object -Property MessageCountSafe -Sum).Sum ?? 0)
            $latestPolicy = $domainRecords | Sort-Object -Property TimeGenerated -Descending | Select-Object -First 1

            $policyScore = switch ($latestPolicy.PolicyPublished_pNorm) {
                'reject' { 100.0 }
                'quarantine' { 60.0 }
                'none' { 20.0 }
                default { 0.0 }
            }

            $passRate = if ($messages -gt 0) {
                ConvertTo-Round1 -Value (100.0 * $dmarcPass / $messages)
            } else {
                0.0
            }

            $complianceScore = if ($messages -gt 0) {
                ConvertTo-Round0 -Value (
                    0.40 * (100.0 * $dmarcPass / $messages) +
                    0.25 * (100.0 * $spfPass / $messages) +
                    0.25 * (100.0 * $dkimPass / $messages) +
                    0.10 * $policyScore
                )
            } else {
                0.0
            }

            $riskLevel = if ($complianceScore -ge 90) {
                'Low'
            } elseif ($complianceScore -ge 70) {
                'Moderate'
            } elseif ($complianceScore -ge 50) {
                'High'
            } else {
                'Critical'
            }

            [pscustomobject]@{
                Domain = $_.Name
                Messages = $messages
                PassRate = $passRate
                ComplianceScore = [int]$complianceScore
                RiskLevel = $riskLevel
            }
        }
}

Describe 'Golden DMARC dataset KPI regression' {
    It 'produces expected top-level KPIs from fixture data' {
        $actualKpi.TotalMessages | Should -Be $expected.kpi.TotalMessages
        $actualKpi.Pass | Should -Be $expected.kpi.Pass
        $actualKpi.Fail | Should -Be $expected.kpi.Fail
        Assert-DoubleEqual -Actual $actualKpi.PassRate -Expected ([double]$expected.kpi.PassRate) -Label 'PassRate'
        $actualKpi.DomainsMonitored | Should -Be $expected.kpi.DomainsMonitored
        $actualKpi.UniqueIPs | Should -Be $expected.kpi.UniqueIPs
        $actualKpi.UniqueReporters | Should -Be $expected.kpi.UniqueReporters
        $actualKpi.EnforcedDomains | Should -Be $expected.kpi.EnforcedDomains
        $actualKpi.TotalDomains | Should -Be $expected.kpi.TotalDomains
        Assert-DoubleEqual -Actual $actualKpi.EnforcementPct -Expected ([double]$expected.kpi.EnforcementPct) -Label 'EnforcementPct'
    }

    It 'produces expected daily pass/fail metrics across time bins' {
        $actualDaily.Count | Should -Be $expected.daily.Count

        for ($i = 0; $i -lt $expected.daily.Count; $i++) {
            $actualDaily[$i].Date | Should -Be $expected.daily[$i].Date
            $actualDaily[$i].Messages | Should -Be $expected.daily[$i].Messages
            $actualDaily[$i].Pass | Should -Be $expected.daily[$i].Pass
            $actualDaily[$i].Fail | Should -Be $expected.daily[$i].Fail
            Assert-DoubleEqual -Actual $actualDaily[$i].PassRate -Expected ([double]$expected.daily[$i].PassRate) -Label "DailyPassRate[$i]"
        }
    }

    It 'produces expected per-domain compliance and risk classification' {
        $actualDomainCompliance.Count | Should -Be $expected.domainCompliance.Count

        for ($i = 0; $i -lt $expected.domainCompliance.Count; $i++) {
            $actualDomainCompliance[$i].Domain | Should -Be $expected.domainCompliance[$i].Domain
            $actualDomainCompliance[$i].Messages | Should -Be $expected.domainCompliance[$i].Messages
            Assert-DoubleEqual -Actual $actualDomainCompliance[$i].PassRate -Expected ([double]$expected.domainCompliance[$i].PassRate) -Label "DomainPassRate[$i]"
            $actualDomainCompliance[$i].ComplianceScore | Should -Be $expected.domainCompliance[$i].ComplianceScore
            $actualDomainCompliance[$i].RiskLevel | Should -Be $expected.domainCompliance[$i].RiskLevel
        }
    }
}
