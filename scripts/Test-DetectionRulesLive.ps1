#Requires -Version 7.4

<#!
.SYNOPSIS
  Validates detections/*.yaml against a real Microsoft Sentinel workspace's rule schema.
.DESCRIPTION
  For each detection rule YAML, creates a disabled, distinctively-named/GUIDed
  "[CI-VALIDATION]" copy of the rule via the Microsoft.SecurityInsights REST API,
  confirms Azure's own schema validator accepts it, then deletes it.

  Safety properties:
  - Every test rule is created with enabled=false, so it never actually evaluates
    against real data - this validates schema/KQL-syntax acceptance only.
  - Test rule IDs are fixed, well-known GUIDs distinct from the real detection IDs
    (pattern 00000000-cccc-cccc-cccc-00000000000N) so an orphaned rule is
    unmistakable in the Sentinel rule list and trivial to find/delete by hand.
  - A sweep at the start of every run deletes any pre-existing test rule at those
    fixed IDs first, so a prior run's failed cleanup can never accumulate orphans.
  - Deletion of each rule created THIS run is wrapped in try/finally, so cleanup
    still runs even if that rule's own validation step throws.

  Requires an authenticated `az` CLI session (az login) with a role that can
  create/delete Microsoft.SecurityInsights/alertRules on the target workspace -
  nothing broader. Intended to be run manually by a maintainer against a dedicated
  test workspace (see docs/LIVE_VALIDATION.md).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName,

    [string]$DetectionsPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'detections')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$apiVersion = '2023-02-01-preview'
$resourceBase = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/alertRules"

# Fixed, well-known test-only IDs - deliberately distinct in pattern from the real
# production rule GUIDs so an orphan is instantly recognizable in the rule list.
$testRuleIds = [ordered]@{
    'new-unauthorized-sender.yaml' = '00000000-cccc-cccc-cccc-000000000001'
    'passrate-anomaly.yaml'        = '00000000-cccc-cccc-cccc-000000000002'
    'policy-override-abuse.yaml'   = '00000000-cccc-cccc-cccc-000000000003'
    'spoofing-detection.yaml'      = '00000000-cccc-cccc-cccc-000000000004'
}

$triggerOperatorMap = @{
    'gt' = 'GreaterThan'
    'lt' = 'LessThan'
    'eq' = 'Equal'
    'ne' = 'NotEqual'
}

function Write-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)

    if ($Passed) {
        Write-Host "[PASS] $Name - $Detail" -ForegroundColor Green
        return
    }

    $script:Failures++
    Write-Host "[FAIL] $Name - $Detail" -ForegroundColor Red
}

function Remove-TestRule {
    param([Parameter(Mandatory)][string]$RuleId)

    # 404 is the expected/successful outcome when sweeping before a rule exists -
    # az rest exits non-zero on any non-2xx status, so failure here is not an error.
    az rest --method delete --url "https://management.azure.com$resourceBase/$RuleId`?api-version=$apiVersion" 2>$null | Out-Null
}

function ConvertTo-SentinelRulePayload {
    param([Parameter(Mandatory)][hashtable]$Parsed, [Parameter(Mandatory)][string]$FileName)

    $triggerOperator = $triggerOperatorMap[[string]$Parsed.triggerOperator]
    if (-not $triggerOperator) {
        throw "Unrecognized triggerOperator '$($Parsed.triggerOperator)' in $FileName"
    }

    $entityMappings = @($Parsed.entityMappings | ForEach-Object {
        @{
            entityType     = $_.entityType
            fieldMappings  = @($_.fieldMappings | ForEach-Object {
                @{ identifier = $_.identifier; columnName = $_.columnName }
            })
        }
    })

    $requiredDataConnectors = @($Parsed.requiredDataConnectors | ForEach-Object {
        @{ connectorId = $_.connectorId; dataTypes = @($_.dataTypes) }
    })

    return @{
        kind       = 'Scheduled'
        properties = @{
            displayName             = "[CI-VALIDATION] $($Parsed.name) (auto-deleted)"
            description              = "Live-validation copy of $FileName - created disabled by CI, deleted immediately after. Should never appear as a lasting rule; if you see this, a cleanup step failed and it is safe to delete manually."
            severity                 = $Parsed.severity
            enabled                  = $false
            query                    = $Parsed.query
            queryFrequency           = $Parsed.queryFrequency
            queryPeriod              = $Parsed.queryPeriod
            triggerOperator          = $triggerOperator
            triggerThreshold         = [int]$Parsed.triggerThreshold
            suppressionDuration      = 'PT1H'
            suppressionEnabled       = $false
            tactics                  = @($Parsed.tactics)
            techniques               = @($Parsed.relevantTechniques)
            entityMappings           = $entityMappings
            requiredDataConnectors   = $requiredDataConnectors
        }
    }
}

Import-Module powershell-yaml -RequiredVersion 0.4.7 -ErrorAction Stop

$null = & {
    $ErrorActionPreference = 'Continue'
    az account set --subscription $SubscriptionId 2>&1
}
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to select the Azure subscription. Check the subscription and service principal access.'
}

Write-Host "Sweeping any pre-existing CI-validation rules from a prior run..."
foreach ($ruleId in $testRuleIds.Values) {
    Remove-TestRule -RuleId $ruleId
}

$detectionFiles = Get-ChildItem -Path $DetectionsPath -Filter '*.yaml' -File
$createdRuleIds = [System.Collections.Generic.List[string]]::new()

try {
    foreach ($file in $detectionFiles) {
        if (-not $testRuleIds.Contains($file.Name)) {
            Write-Check -Name $file.Name -Passed $false -Detail "No test rule ID mapped for this file - add one to `$testRuleIds in this script."
            continue
        }

        $ruleId = $testRuleIds[$file.Name]
        $parsed = ConvertFrom-Yaml -Yaml (Get-Content -Path $file.FullName -Raw) -Ordered

        try {
            $payload = ConvertTo-SentinelRulePayload -Parsed $parsed -FileName $file.Name
        }
        catch {
            Write-Check -Name $file.Name -Passed $false -Detail 'Payload construction failed. Check the detection rule locally.'
            continue
        }

        $bodyPath = New-TemporaryFile
        try {
            ($payload | ConvertTo-Json -Depth 10 -Compress) | Set-Content -Path $bodyPath -NoNewline

            # az CLI routinely writes non-fatal warnings to stderr even on success. Merging
            # stderr via 2>&1 while the script-wide $ErrorActionPreference is
            # 'Stop' can turn that merged stderr text into a terminating NativeCommandError -
            # aborting validation for every remaining file instead of just recording a [FAIL]
            # for this one. Run the native call in its own scope with a local, non-terminating
            # ErrorActionPreference so only $LASTEXITCODE (checked below) determines pass/fail.
            $null = & {
                $ErrorActionPreference = 'Continue'
                az rest --method put `
                    --url "https://management.azure.com$resourceBase/$ruleId`?api-version=$apiVersion" `
                    --body "@$bodyPath" `
                    --headers "Content-Type=application/json" 2>&1
            }

            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                $createdRuleIds.Add($ruleId)
                Write-Check -Name $file.Name -Passed $true -Detail "Azure accepted the rule schema (rule id $ruleId, disabled, will be deleted now)."
            }
            else {
                Write-Check -Name $file.Name -Passed $false -Detail 'Azure rejected the rule. Diagnose the response locally in a secure environment.'
            }
        }
        catch {
            Write-Check -Name $file.Name -Passed $false -Detail 'Live validation request failed. Diagnose the request locally in a secure environment.'
        }
        finally {
            Remove-Item -Path $bodyPath -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Write-Host "Cleaning up all CI-validation rules created this run..."
    foreach ($ruleId in $createdRuleIds) {
        Remove-TestRule -RuleId $ruleId
    }
}

if ($script:Failures -gt 0) {
    Write-Host "`n$script:Failures detection rule(s) failed live validation." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll detection rules passed live validation." -ForegroundColor Green
