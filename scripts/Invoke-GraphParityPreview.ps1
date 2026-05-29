<#
.SYNOPSIS
    Compares Microsoft Graph mailbox message IDs with DMARC ingestion IDs in Log Analytics.

.DESCRIPTION
    This preview script helps validate ingestion parity outside workbook rendering.
    It queries Microsoft Graph for inbox messages (with attachments) in a time window,
    then compares those message IDs against distinct SourceMessageId values in
    DMARCReports_CL.

    Use this as an opt-in diagnostic before enabling broader Graph exploration work.

.PARAMETER MailboxUserId
    Entra object ID (GUID) of the shared mailbox user.

.PARAMETER WorkspaceId
    Log Analytics workspace ID (GUID) or resource ID accepted by Azure CLI.

.PARAMETER StartDateUtc
    Inclusive UTC start time. Defaults to now minus 7 days.

.PARAMETER EndDateUtc
    Inclusive UTC end time. Defaults to now.

.PARAMETER MaxPages
    Maximum Graph pages to fetch (999 messages/page). Defaults to 25.

.PARAMETER IngestionLagHours
    Extends the Log Analytics query window end to account for delayed ingestion.
    Defaults to 24 hours.

.PARAMETER SubjectRegex
    Regex used to identify DMARC-likely mailbox messages. Messages that do not
    match are still counted in candidate scope but excluded from strict parity.

.PARAMETER RecentDelayMinutes
    Messages newer than this threshold are triaged as likely ingestion delay.

.PARAMETER SampleSize
    Max number of records included in sample arrays in the output report.

.PARAMETER OutputPath
    Optional path to write the parity report as JSON.

.EXAMPLE
    ./scripts/Invoke-GraphParityPreview.ps1 \
      -MailboxUserId '11111111-1111-1111-1111-111111111111' \
      -WorkspaceId '22222222-2222-2222-2222-222222222222' \
      -StartDateUtc (Get-Date).ToUniversalTime().AddDays(-7) \
      -EndDateUtc (Get-Date).ToUniversalTime() \
      -OutputPath './parity-report.json'

.NOTES
    Prerequisites:
    - Azure CLI (az) installed
    - az login completed
    - Access to Microsoft Graph for the target mailbox
    - Access to query the target Log Analytics workspace
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$MailboxUserId,

    [Parameter(Mandatory)]
    [string]$WorkspaceId,

    [datetime]$StartDateUtc = (Get-Date).ToUniversalTime().AddDays(-7),

    [datetime]$EndDateUtc = (Get-Date).ToUniversalTime(),

    [ValidateRange(1, 200)]
    [int]$MaxPages = 25,

    [ValidateRange(0, 168)]
    [int]$IngestionLagHours = 24,

    [string]$SubjectRegex = '(?i)(dmarc|aggregate report|report domain:)',

    [ValidateRange(1, 1440)]
    [int]$RecentDelayMinutes = 120,

    [ValidateRange(1, 200)]
    [int]$SampleSize = 20,

    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$ErrorContext
    )

    $raw = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorContext`n$($raw -join "`n")"
    }

    $payload = $raw -join "`n"
    if ([string]::IsNullOrWhiteSpace($payload)) {
        return $null
    }

    return ($payload | ConvertFrom-Json)
}

if ($StartDateUtc -ge $EndDateUtc) {
    throw 'StartDateUtc must be earlier than EndDateUtc.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI 'az' is required but was not found in PATH."
}

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host '  DMARC Pipeline — Graph Parity Preview' -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════`n" -ForegroundColor Cyan

Write-Host '[1/4] Validating Azure CLI session...' -ForegroundColor Yellow
$null = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json') -ErrorContext 'Failed to read Azure account context. Run az login first.'

Write-Host '[2/4] Querying Microsoft Graph message IDs...' -ForegroundColor Yellow
$tokenResponse = Invoke-AzJson -Arguments @('account', 'get-access-token', '--resource-type', 'ms-graph', '--output', 'json') -ErrorContext 'Failed to get Graph access token from Azure CLI.'
$graphToken = $tokenResponse.accessToken
if (-not $graphToken) {
    throw 'Azure CLI did not return an accessToken for Microsoft Graph.'
}

$startIso = $StartDateUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$endIso = $EndDateUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$laEndIso = $EndDateUtc.ToUniversalTime().AddHours($IngestionLagHours).ToString('yyyy-MM-ddTHH:mm:ssZ')

$filter = "receivedDateTime ge $startIso and receivedDateTime le $endIso and hasAttachments eq true"
$encodedFilter = [Uri]::EscapeDataString($filter)
$url = "https://graph.microsoft.com/v1.0/users/$MailboxUserId/messages?`$top=999&`$select=id,receivedDateTime,subject,hasAttachments,isRead,from&`$orderby=receivedDateTime asc&`$filter=$encodedFilter"

$graphMessages = New-Object System.Collections.Generic.List[object]
$page = 0
while ($url -and $page -lt $MaxPages) {
    $page++
    Write-Host "  Graph page $page" -ForegroundColor Gray

    try {
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers @{ Authorization = "Bearer $graphToken" }
    }
    catch {
        throw "Graph request failed on page ${page}: $($_.Exception.Message)"
    }

    if ($response.value) {
        foreach ($message in $response.value) {
            $graphMessages.Add($message)
        }
    }

    $url = $response.'@odata.nextLink'
}

if ($url) {
    Write-Warning "Graph query stopped after MaxPages=$MaxPages. Results may be partial."
}

$graphCandidateIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$graphLikelyDmarcIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$graphMessageIndex = @{}

foreach ($message in $graphMessages) {
    if (-not $message.id) {
        continue
    }

    $id = [string]$message.id
    $subject = [string]$message.subject
    $isRead = [bool]$message.isRead
    $receivedDateTime = [string]$message.receivedDateTime
    $fromAddress = $null
    if ($message.from -and $message.from.emailAddress -and $message.from.emailAddress.address) {
        $fromAddress = [string]$message.from.emailAddress.address
    }

    $subjectMatched = $true
    if (-not [string]::IsNullOrWhiteSpace($SubjectRegex)) {
        $subjectMatched = ($subject -match $SubjectRegex)
    }

    $entry = [pscustomobject]@{
        id = $id
        subject = $subject
        receivedDateTime = $receivedDateTime
        isRead = $isRead
        fromAddress = $fromAddress
        subjectMatched = $subjectMatched
    }

    $graphMessageIndex[$id] = $entry
    $null = $graphCandidateIds.Add($id)
    if ($subjectMatched) {
        $null = $graphLikelyDmarcIds.Add($id)
    }
}

if ($graphCandidateIds.Count -gt 0 -and $graphLikelyDmarcIds.Count -eq 0) {
    Write-Warning "No messages matched SubjectRegex. Strict parity scope is empty; consider adjusting -SubjectRegex."
}

Write-Host '[3/4] Querying Log Analytics SourceMessageId values...' -ForegroundColor Yellow
$kql = @"
DMARCReports_CL
| where TimeGenerated between (datetime($startIso) .. datetime($laEndIso))
| where isnotempty(SourceMessageId)
| summarize by SourceMessageId = tostring(SourceMessageId)
| project SourceMessageId
"@

$laResponse = Invoke-AzJson -Arguments @(
    'monitor', 'log-analytics', 'query',
    '--workspace', $WorkspaceId,
    '--analytics-query', $kql,
    '--output', 'json'
) -ErrorContext 'Failed to query Log Analytics for SourceMessageId values.'

$laRows = @()
if ($laResponse.tables -and $laResponse.tables.Count -gt 0) {
    $laRows = $laResponse.tables[0].rows
}

$laIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $laRows) {
    if ($row.Count -gt 0 -and $row[0]) {
        $null = $laIds.Add([string]$row[0])
    }
}

Write-Host '[4/4] Building parity mismatch report...' -ForegroundColor Yellow

$missingLikelyInLogAnalytics = New-Object System.Collections.Generic.List[string]
foreach ($id in $graphLikelyDmarcIds) {
    if (-not $laIds.Contains($id)) {
        $missingLikelyInLogAnalytics.Add($id)
    }
}

$missingCandidateInLogAnalytics = New-Object System.Collections.Generic.List[string]
foreach ($id in $graphCandidateIds) {
    if (-not $laIds.Contains($id)) {
        $missingCandidateInLogAnalytics.Add($id)
    }
}

$extraInLogAnalytics = New-Object System.Collections.Generic.List[string]
foreach ($id in $laIds) {
    if (-not $graphCandidateIds.Contains($id)) {
        $extraInLogAnalytics.Add($id)
    }
}

$missingDetails = New-Object System.Collections.Generic.List[object]
foreach ($id in $missingCandidateInLogAnalytics) {
    $msg = $graphMessageIndex[$id]
    if (-not $msg) {
        continue
    }

    $receivedUtc = $null
    if ($msg.receivedDateTime) {
        try {
            $receivedUtc = [datetime]::Parse($msg.receivedDateTime).ToUniversalTime()
        }
        catch {
            $receivedUtc = $null
        }
    }

    $isRecent = $false
    if ($receivedUtc) {
        $ageMinutes = ((Get-Date).ToUniversalTime() - $receivedUtc).TotalMinutes
        $isRecent = ($ageMinutes -lt $RecentDelayMinutes)
    }

    $suspectedReason = if (-not $msg.subjectMatched) {
        'Likely non-DMARC message in Graph candidate set'
    }
    elseif ($isRecent -or (-not $msg.isRead)) {
        'Likely ingestion delay or pending catch-up processing'
    }
    else {
        'Likely processing or ingestion gap; inspect function logs and replay options'
    }

    $missingDetails.Add([pscustomobject]@{
        id = $msg.id
        receivedDateTime = $msg.receivedDateTime
        isRead = $msg.isRead
        fromAddress = $msg.fromAddress
        subject = $msg.subject
        subjectMatched = $msg.subjectMatched
        suspectedReason = $suspectedReason
    })
}

$likelyNonDmarcCount = @($missingDetails | Where-Object { $_.suspectedReason -eq 'Likely non-DMARC message in Graph candidate set' }).Count
$likelyPendingCount = @($missingDetails | Where-Object { $_.suspectedReason -eq 'Likely ingestion delay or pending catch-up processing' }).Count
$likelyGapCount = @($missingDetails | Where-Object { $_.suspectedReason -eq 'Likely processing or ingestion gap; inspect function logs and replay options' }).Count

$matchRatePct = if ($graphLikelyDmarcIds.Count -eq 0) {
    100
}
else {
    [Math]::Round((($graphLikelyDmarcIds.Count - $missingLikelyInLogAnalytics.Count) / [double]$graphLikelyDmarcIds.Count) * 100, 2)
}

$candidateCoveragePct = if ($graphCandidateIds.Count -eq 0) {
    100
}
else {
    [Math]::Round((($graphCandidateIds.Count - $missingCandidateInLogAnalytics.Count) / [double]$graphCandidateIds.Count) * 100, 2)
}

$report = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    windowStartUtc = $startIso
    windowEndUtc = $endIso
    laQueryWindowEndUtc = $laEndIso
    ingestionLagHours = $IngestionLagHours
    subjectRegex = $SubjectRegex
    recentDelayMinutes = $RecentDelayMinutes
    graphMailboxUserId = $MailboxUserId
    graphCandidateMessageCount = $graphCandidateIds.Count
    graphLikelyDmarcMessageCount = $graphLikelyDmarcIds.Count
    logAnalyticsSourceMessageIdCount = $laIds.Count
    missingInLogAnalyticsCount = $missingLikelyInLogAnalytics.Count
    missingLikelyInLogAnalyticsCount = $missingLikelyInLogAnalytics.Count
    missingCandidateInLogAnalyticsCount = $missingCandidateInLogAnalytics.Count
    extraInLogAnalyticsCount = $extraInLogAnalytics.Count
    matchRatePct = $matchRatePct
    candidateCoveragePct = $candidateCoveragePct
    triageSummary = [ordered]@{
        likelyNonDmarcSubjectCount = $likelyNonDmarcCount
        likelyPendingIngestionCount = $likelyPendingCount
        likelyPipelineGapCount = $likelyGapCount
    }
    sampleMissingInLogAnalytics = @($missingLikelyInLogAnalytics | Select-Object -First $SampleSize)
    sampleMissingCandidateInLogAnalytics = @($missingCandidateInLogAnalytics | Select-Object -First $SampleSize)
    sampleExtraInLogAnalytics = @($extraInLogAnalytics | Select-Object -First $SampleSize)
    sampleMissingTriage = @($missingDetails | Select-Object -First $SampleSize)
}

if ($OutputPath) {
    $outputDir = Split-Path -Parent $OutputPath
    if ($outputDir -and -not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "  Report written: $OutputPath" -ForegroundColor Green
}

Write-Host "`n═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host '  Parity Preview Summary' -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Window: $startIso .. $endIso"
Write-Host "  Log Analytics query end (with lag): $laEndIso"
Write-Host "  Graph candidate IDs (attachments): $($graphCandidateIds.Count)"
Write-Host "  Graph likely-DMARC IDs (subject regex): $($graphLikelyDmarcIds.Count)"
Write-Host "  Log Analytics IDs: $($laIds.Count)"
Write-Host "  Missing in Log Analytics (strict likely-DMARC): $($missingLikelyInLogAnalytics.Count)"
Write-Host "  Missing in Log Analytics (all Graph candidates): $($missingCandidateInLogAnalytics.Count)"
Write-Host "  Extra in Log Analytics: $($extraInLogAnalytics.Count)"
Write-Host "  Match rate (strict likely-DMARC scope): $matchRatePct%"
Write-Host "  Coverage (all Graph candidates): $candidateCoveragePct%"
Write-Host "  Triage likely non-DMARC: $likelyNonDmarcCount"
Write-Host "  Triage likely pending delay: $likelyPendingCount"
Write-Host "  Triage likely pipeline gap: $likelyGapCount`n"

[pscustomobject]$report
