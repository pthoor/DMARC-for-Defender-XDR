#Requires -Version 7.4
#Requires -Modules Pester

# NOTE: rule data must be computed at script (Discovery) scope, not inside BeforeAll -
# BeforeAll runs during Pester's Run phase, which is too late for -TestCases: Discovery
# needs the full test case list up front to generate one It per case.
#
# NOTE: each test case below is a [hashtable], not a [pscustomobject] - Pester's
# -TestCases binding silently drops non-scalar/complex properties (arrays, long
# strings) from pscustomobject test cases in this Pester version, while hashtables
# bind correctly. Verified directly: same YAML-parsed data, pscustomobject loses
# array/string properties inside the It scriptblock, hashtable does not.
#
# NOTE: -TestCases-bound It blocks cannot see script-scope functions, and cannot see
# script-scope *array* variables either (both verified directly - scalar strings like
# $guidPattern below work fine, but the Sentinel enum lists used to validate against
# do not), so both are inlined directly inside the It blocks that need them below
# rather than defined once here.
Import-Module powershell-yaml -RequiredVersion 0.4.7 -ErrorAction Stop

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$detectionFiles = Get-ChildItem -Path (Join-Path $repoRoot 'detections') -Filter '*.yaml' -File

$guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$isoDurationPattern = '^P(?=\d|T\d)(\d+D)?(T(\d+H)?(\d+M)?(\d+S)?)?$'
$techniquePattern = '^T\d{4}(\.\d{3})?$'

$rules = foreach ($file in $detectionFiles) {
    $content = Get-Content -Path $file.FullName -Raw
    $parsed = ConvertFrom-Yaml -Yaml $content -Ordered

    @{
        File               = $file.Name
        Id                 = $parsed.id
        Name               = $parsed.name
        Severity           = $parsed.severity
        TriggerOperator    = $parsed.triggerOperator
        Kind               = $parsed.kind
        Status             = $parsed.status
        QueryFrequency     = $parsed.queryFrequency
        QueryPeriod        = $parsed.queryPeriod
        Tactics            = @($parsed.tactics)
        RelevantTechniques = @($parsed.relevantTechniques)
        EntityTypes        = @($parsed.entityMappings | ForEach-Object { $_.entityType })
        Query              = $parsed.query
    }
}

Describe 'Detection rule schema validation' {
    Context 'Per-file structural checks' {
        It '<File>: id is a well-formed GUID' -TestCases $rules {
            $Id | Should -Match $guidPattern
        }

        It '<File>: severity is a valid Sentinel severity' -TestCases $rules {
            # Inlined (not the script-scope $validSeverities) - see the NOTE at the top of this
            # file: array-typed script-scope variables aren't visible inside -TestCases It blocks
            # in this Pester version, even though scalar-typed ones are.
            @('Informational', 'Low', 'Medium', 'High') | Should -Contain $Severity
        }

        It '<File>: triggerOperator is a recognized shorthand' -TestCases $rules {
            @('gt', 'lt', 'eq', 'ne') | Should -Contain $TriggerOperator
        }

        It '<File>: kind is Scheduled' -TestCases $rules {
            $Kind | Should -Be 'Scheduled'
        }

        It '<File>: status is present' -TestCases $rules {
            $Status | Should -Not -BeNullOrEmpty
        }

        It '<File>: queryFrequency is a valid ISO 8601 duration' -TestCases $rules {
            $QueryFrequency | Should -Match $isoDurationPattern
        }

        It '<File>: queryPeriod is a valid ISO 8601 duration' -TestCases $rules {
            $QueryPeriod | Should -Match $isoDurationPattern
        }

        It '<File>: queryPeriod is greater than or equal to queryFrequency' -TestCases $rules {
            # Sentinel rejects rules whose lookback window is shorter than how often they run -
            # each execution would have gaps with no data coverage between runs. Inlined (not a
            # helper function - see the NOTE at the top of this file) since -TestCases It blocks
            # can't resolve script-scope functions.
            function ConvertTo-Seconds([string]$Iso) {
                $null = $Iso -match '^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$'
                ([int]($Matches[1] ?? 0) * 86400) + ([int]($Matches[2] ?? 0) * 3600) + ([int]($Matches[3] ?? 0) * 60) + [int]($Matches[4] ?? 0)
            }
            (ConvertTo-Seconds $QueryPeriod) | Should -BeGreaterOrEqual (ConvertTo-Seconds $QueryFrequency)
        }

        It '<File>: tactics are all valid MITRE ATT&CK tactic names' -TestCases $rules {
            $Tactics.Count | Should -BeGreaterThan 0
            $tacticNames = @(
                'Reconnaissance', 'ResourceDevelopment', 'InitialAccess', 'Execution', 'Persistence',
                'PrivilegeEscalation', 'DefenseEvasion', 'CredentialAccess', 'Discovery', 'LateralMovement',
                'Collection', 'CommandAndControl', 'Exfiltration', 'Impact', 'ImpairProcessControl',
                'InhibitResponseFunction'
            )
            foreach ($tactic in $Tactics) {
                $tacticNames | Should -Contain $tactic
            }
        }

        It '<File>: relevantTechniques all match the Txxxx[.xxx] format' -TestCases $rules {
            $RelevantTechniques.Count | Should -BeGreaterThan 0
            foreach ($technique in $RelevantTechniques) {
                $technique | Should -Match $techniquePattern
            }
        }

        It '<File>: entityMappings use recognized Sentinel entity types' -TestCases $rules {
            $EntityTypes.Count | Should -BeGreaterThan 0
            $entityTypeNames = @(
                'Account', 'Host', 'IP', 'Malware', 'File', 'Process', 'CloudApplication', 'DNS',
                'AzureResource', 'FileHash', 'RegistryKey', 'RegistryValue', 'SecurityGroup', 'URL',
                'Mailbox', 'MailCluster', 'MailMessage', 'SubmissionMail'
            )
            foreach ($entityType in $EntityTypes) {
                $entityTypeNames | Should -Contain $entityType
            }
        }

        It '<File>: query is non-empty and reads from DMARCReports_CL' -TestCases $rules {
            $Query | Should -Not -BeNullOrEmpty
            $Query | Should -Match 'DMARCReports_CL'
        }

        It '<File>: query has balanced parentheses' -TestCases $rules {
            $openCount = ([regex]::Matches($Query, '\(')).Count
            $closeCount = ([regex]::Matches($Query, '\)')).Count
            $openCount | Should -Be $closeCount
        }
    }

    Context 'Cross-file consistency' {
        BeforeEach {
            # Re-parsed fresh here rather than relying on any outer script-scope variable ($rules,
            # $repoRoot): this Pester version has proven unreliable at carrying script-scope data
            # into BeforeEach/plain It blocks at Run time (see the NOTE at the top of this file),
            # so this Context re-derives everything it needs from $PSScriptRoot directly.
            $detectionsPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'detections'
            $contextRules = foreach ($file in (Get-ChildItem -Path $detectionsPath -Filter '*.yaml' -File)) {
                $parsedContent = ConvertFrom-Yaml -Yaml (Get-Content -Path $file.FullName -Raw) -Ordered
                @{ File = $file.Name; Id = $parsedContent.id; Name = $parsedContent.name; Query = $parsedContent.query }
            }
        }

        It 'has no duplicate rule ids' {
            $duplicates = $contextRules | ForEach-Object { $_.Id } | Group-Object | Where-Object { $_.Count -gt 1 }
            $duplicates | Should -BeNullOrEmpty
        }

        It 'has no duplicate rule names' {
            $duplicates = $contextRules | ForEach-Object { $_.Name } | Group-Object | Where-Object { $_.Count -gt 1 }
            $duplicates | Should -BeNullOrEmpty
        }

        It 'uses a byte-identical DmarcPassEffective coalesce expression everywhere it appears' {
            # A1/A10 (docs/BACKLOG.md): this fragment is deliberately copy-pasted across detection
            # rules rather than shared via a KQL function. If a future edit updates the formula in
            # one file and not the others, detections would silently disagree on what "pass" means -
            # this guards that they never drift out of parity with each other.
            $fragmentPattern = '(?ms)DmarcPassEffective\s*=\s*coalesce\(.*?\)\s*(?=\r?\n)'
            $fragments = foreach ($rule in $contextRules) {
                $fragmentMatches = [regex]::Matches($rule.Query, $fragmentPattern)
                foreach ($fragmentMatch in $fragmentMatches) {
                    [pscustomobject]@{
                        File       = $rule.File
                        # Collapse whitespace so indentation differences between a top-level
                        # `| extend` and a `let`-scoped assignment don't cause a false mismatch.
                        Normalized = ($fragmentMatch.Value -replace '\s+', ' ').Trim()
                    }
                }
            }

            $fragments.Count | Should -BeGreaterThan 0
            $distinct = $fragments.Normalized | Select-Object -Unique
            $distinct.Count | Should -Be 1
        }
    }
}

Describe 'Live detection validation script' {
    It 'is not run from public CI workflows' {
        # Public Actions logs and tenant credentials are out of scope; run it manually instead.
        $workflowsPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) '.github/workflows'
        $references = Get-ChildItem -Path $workflowsPath -Filter '*.yml' -File |
            Select-String -Pattern 'Test-DetectionRulesLive' -SimpleMatch
        $references | Should -BeNullOrEmpty
    }

    It 'does not log a simulated Azure failure response' {
        $scriptPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'scripts/Test-DetectionRulesLive.ps1'
        $quotedScriptPath = $scriptPath.Replace("'", "''")
        $childScript = @"
function global:az {
    `$global:LASTEXITCODE = 0
    if (`$args -contains 'put') {
        `$global:LASTEXITCODE = 1
        Write-Output 'sensitive-azure-response-marker'
    }
}
& '$quotedScriptPath' -SubscriptionId 'test-subscription' -ResourceGroupName 'test-group' -WorkspaceName 'test-workspace'
"@
        $output = & (Get-Process -Id $PID).Path -NoProfile -Command $childScript 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'Azure rejected the rule'
        $output | Should -Not -Match 'sensitive-azure-response-marker|test-workspace'
    }
}
