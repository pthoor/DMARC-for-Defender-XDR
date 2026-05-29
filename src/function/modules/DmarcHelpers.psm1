#Requires -Version 7.4

<#
.SYNOPSIS
    Shared helper functions for the DMARC-to-Sentinel pipeline.
.DESCRIPTION
    Provides token acquisition (Managed Identity), Microsoft Graph API calls,
    DMARC XML parsing, and Log Analytics ingestion via the Logs Ingestion API (DCR).
    All operations use raw REST API calls — no external PowerShell modules.
#>

# ─────────────────────────────────────────────
# Token Acquisition (Managed Identity)
# ─────────────────────────────────────────────

function Get-ManagedIdentityToken {
    <#
    .SYNOPSIS
        Acquires an access token using the Function App's system-assigned Managed Identity.
    .PARAMETER Resource
        The resource URI to request a token for.
        Use 'https://graph.microsoft.com' for Graph API.
        Use 'https://monitor.azure.com' for Logs Ingestion API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Resource
    )

    $identityEndpoint = $env:IDENTITY_ENDPOINT
    $identityHeader   = $env:IDENTITY_HEADER

    if ([string]::IsNullOrEmpty($identityEndpoint)) {
        $msg = "Managed Identity is not properly configured: environment variable 'IDENTITY_ENDPOINT' is not set or is empty. This is required to acquire a Managed Identity token (resource '$Resource')."
        Write-Error $msg
        throw [System.InvalidOperationException]::new($msg)
    }

    if ([string]::IsNullOrEmpty($identityHeader)) {
        $msg = "Managed Identity is not properly configured: environment variable 'IDENTITY_HEADER' is not set or is empty. This is required to acquire a Managed Identity token (resource '$Resource')."
        Write-Error $msg
        throw [System.InvalidOperationException]::new($msg)
    }

    # URL-encode the resource parameter — values like 'https://graph.microsoft.com'
    # contain '://' which can break URI parsing on Flex Consumption infrastructure.
    $encodedResource = [System.Uri]::EscapeDataString($Resource)
    $tokenUri = "${identityEndpoint}?resource=${encodedResource}&api-version=2019-08-01"
    $headers  = @{ 'X-IDENTITY-HEADER' = $identityHeader }
    try {
        $response = Invoke-RestMethod -Uri $tokenUri -Headers $headers -Method Get
        return $response.access_token
    }
    catch {
        Write-Error "Failed to acquire Managed Identity token for resource '$Resource': $_"
        throw
    }
}

# ─────────────────────────────────────────────
# Microsoft Graph API Helpers
# ─────────────────────────────────────────────

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Makes an authenticated request to the Microsoft Graph API.
    .PARAMETER Uri
        The full Graph API URI (e.g., https://graph.microsoft.com/v1.0/users/...)
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, DELETE). Default: GET.
    .PARAMETER Body
        Optional request body (will be serialized to JSON).
    .PARAMETER Token
        Optional pre-acquired token. If not provided, acquires one via MI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [object]$Body,

        [string]$Token
    )

    if (-not $Token) {
        $Token = Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com'
    }

    $headers = @{
        'Authorization' = "Bearer $Token"
        'Content-Type'  = 'application/json'
    }

    $params = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }

    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        return Invoke-WithRetry -ScriptBlock { Invoke-RestMethod @params }
    }
    catch {
        $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'N/A' }
        Write-Error "Graph API request failed [$Method $Uri] - HTTP $statusCode : $_"
        throw
    }
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Retries a scriptblock on transient HTTP 429/503 errors with exponential backoff and jitter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 4,
        [int]$BaseDelayMs = 1000
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $response   = $_.Exception.Response
            $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }

            if ($attempt -ge $MaxAttempts -or $statusCode -notin @(429, 503)) {
                throw
            }

            $delayMs = [int]($BaseDelayMs * [Math]::Pow(2, $attempt - 1))

            # Honor Retry-After header (seconds integer) when present on 429
            if ($statusCode -eq 429 -and $response) {
                $retryAfterValues = $null
                if ($response.Headers.TryGetValues('Retry-After', [ref]$retryAfterValues)) {
                    $retryAfterSec = 0
                    if ([int]::TryParse(($retryAfterValues | Select-Object -First 1), [ref]$retryAfterSec) -and $retryAfterSec -gt 0) {
                        $delayMs = $retryAfterSec * 1000
                    }
                }
            }

            $jitter   = Get-Random -Minimum 0 -Maximum ([Math]::Max(1, [int]($delayMs * 0.2)))
            $delayMs += $jitter
            Write-Warning "HTTP $statusCode — attempt $attempt/$MaxAttempts, retrying in ${delayMs}ms..."
            Start-Sleep -Milliseconds $delayMs
        }
    }
}

function Get-MailMessage {
    <#
    .SYNOPSIS
        Fetches a mail message and its attachments from a mailbox.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        [string]$MessageId,

        [string]$Token
    )

    $uri = "https://graph.microsoft.com/v1.0/users/$UserId/messages/$MessageId"
    $message = Invoke-GraphRequest -Uri $uri -Token $Token

    # Fetch attachments
    $attachmentsUri = "$uri/attachments"
    $attachments = Invoke-GraphRequest -Uri $attachmentsUri -Token $Token

    return @{
        Message     = $message
        Attachments = $attachments.value
    }
}

function Set-MessageRead {
    <#
    .SYNOPSIS
        Marks a mail message as read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        [string]$MessageId,

        [string]$Token
    )

    $uri = "https://graph.microsoft.com/v1.0/users/$UserId/messages/$MessageId"
    $null = Invoke-GraphRequest -Uri $uri -Method PATCH -Body @{ isRead = $true } -Token $Token
}

function Get-UnreadMessages {
    <#
    .SYNOPSIS
        Gets unread messages from the mailbox, optionally filtered by age.
    .PARAMETER OlderThanMinutes
        Only return messages received more than this many minutes ago.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [int]$OlderThanMinutes = 60,

        [string]$Token
    )

    $cutoff = (Get-Date).AddMinutes(-$OlderThanMinutes).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = "isRead eq false and receivedDateTime lt $cutoff and hasAttachments eq true"
    $uri = "https://graph.microsoft.com/v1.0/users/$UserId/messages?`$filter=$filter&`$orderby=receivedDateTime asc&`$top=50&`$select=id,subject,receivedDateTime"

    $result = Invoke-GraphRequest -Uri $uri -Token $Token
    return $result.value
}

function Get-MailboxMessages {
    <#
    .SYNOPSIS
        Gets messages from a mailbox with paging, date range, and optional read-state filter.
    .DESCRIPTION
        Queries the Graph API for messages with attachments within a date range.
        Follows @odata.nextLink for full paging (no 50-message cap).
        Used by BackfillProcessor for on-demand historical import.
    .PARAMETER UserId
        The mailbox user ID (object ID or UPN).
    .PARAMETER Days
        How many days back to look. Default 7, max 365.
    .PARAMETER IncludeRead
        If true, returns both read and unread messages. Default false (unread only).
    .PARAMETER Token
        Pre-acquired Graph API token.
    .PARAMETER MaxMessages
        Safety cap to prevent runaway queries. Default 500.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserId,

        [ValidateRange(1, 365)]
        [int]$Days = 7,

        [bool]$IncludeRead = $false,

        [string]$Token,

        [ValidateRange(1, 5000)]
        [int]$MaxMessages = 500
    )

    $cutoff = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter = "receivedDateTime ge $cutoff and hasAttachments eq true"
    if (-not $IncludeRead) {
        $filter = "isRead eq false and $filter"
    }

    $uri = "https://graph.microsoft.com/v1.0/users/$UserId/messages?`$filter=$filter&`$orderby=receivedDateTime asc&`$top=50&`$select=id,subject,receivedDateTime,isRead"

    $allMessages = [System.Collections.Generic.List[object]]::new()

    do {
        $result = Invoke-GraphRequest -Uri $uri -Token $Token

        if ($result.value) {
            $allMessages.AddRange([object[]]$result.value)
        }

        # Follow paging link if present
        $uri = $result.'@odata.nextLink'

        if ($allMessages.Count -ge $MaxMessages) {
            Write-Warning "Reached max message limit ($MaxMessages). Some messages may not be processed."
            break
        }
    } while ($uri)

    return $allMessages.ToArray()
}

# ─────────────────────────────────────────────
# Attachment Extraction
# ─────────────────────────────────────────────

# Safety limits to prevent memory exhaustion from oversized or crafted attachments.
# DMARC reports are typically <1 MB compressed / <5 MB decompressed. These limits
# are generous enough for the largest legitimate reports from major providers.
$script:MaxAttachmentBytes  = 25 * 1024 * 1024   # 25 MB compressed input per attachment
$script:MaxDecompressedBytes = 50 * 1024 * 1024   # 50 MB decompressed output per entry
$script:MaxZipEntries        = 50                  # max entries processed per ZIP archive

function Expand-DmarcAttachments {
    <#
    .SYNOPSIS
        Extracts DMARC XML content from mail attachments.
    .DESCRIPTION
        Handles .xml, .xml.gz, .gz, and .zip file attachments.
        Returns a hashtable with 'Xml' (array of XML strings).
        Enforces size limits to guard against oversized or decompression-bomb attachments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Attachments
    )

    $xmlContents = [System.Collections.Generic.List[string]]::new()

    foreach ($attachment in $Attachments) {
        if ($attachment.'@odata.type' -ne '#microsoft.graph.fileAttachment') {
            Write-Verbose "Skipping non-file attachment: $($attachment.name)"
            continue
        }

        $name = $attachment.name.ToLower()

        try {
            $contentBytes = [System.Convert]::FromBase64String($attachment.contentBytes)

            if ($null -eq $contentBytes) {
                Write-Warning "Skipping attachment '$($attachment.name)': content is null or empty."
                continue
            }

            if ($contentBytes.Length -gt $script:MaxAttachmentBytes) {
                Write-Warning "Skipping attachment '$($attachment.name)': size $($contentBytes.Length) bytes exceeds limit of $($script:MaxAttachmentBytes) bytes."
                continue
            }
            if ($name.EndsWith('.zip')) {
                $extracted = Expand-ZipAttachment -ContentBytes $contentBytes
                foreach ($content in @($extracted)) {
                    $xmlContents.Add($content)
                }
            }
            elseif ($name.EndsWith('.gz') -or $name.EndsWith('.xml.gz')) {
                $xmlContents.Add((Expand-GzipAttachment -ContentBytes $contentBytes))
            }
            elseif ($name.EndsWith('.xml')) {
                $xmlContents.Add([System.Text.Encoding]::UTF8.GetString($contentBytes))
            }
            else {
                Write-Verbose "Skipping unrecognized attachment: $($attachment.name)"
            }
        }
        catch {
            Write-Warning "Failed to extract attachment '$($attachment.name)': $_"
        }
    }

    return @{
        Xml = $xmlContents.ToArray()
    }
}

function Expand-ZipAttachment {
    [CmdletBinding()]
    param([byte[]]$ContentBytes)

    $xmlContents = [System.Collections.Generic.List[string]]::new()
    $memStream = [System.IO.MemoryStream]::new($ContentBytes)

    try {
        $archive = [System.IO.Compression.ZipArchive]::new($memStream, [System.IO.Compression.ZipArchiveMode]::Read)
        $entriesProcessed = 0

        foreach ($entry in $archive.Entries) {
            if ($entriesProcessed -ge $script:MaxZipEntries) {
                Write-Warning "ZIP entry limit reached ($($script:MaxZipEntries)). Remaining entries skipped."
                break
            }

            $entryName = $entry.Name.ToLower()

            if ($entryName.EndsWith('.xml')) {
                $xmlContents.Add((Read-StreamWithLimit -Stream $entry.Open() -Limit $script:MaxDecompressedBytes -EntryName $entry.Name))
                $entriesProcessed++
            }
            elseif ($entryName.EndsWith('.gz')) {
                # Handle nested .xml.gz inside .zip
                $entryStream = $entry.Open()
                try {
                    $entryMemStream = [System.IO.MemoryStream]::new()
                    try {
                        Copy-StreamWithLimit -Source $entryStream -Destination $entryMemStream -Limit $script:MaxAttachmentBytes -EntryName $entry.Name
                        $xmlContents.Add((Expand-GzipAttachment -ContentBytes $entryMemStream.ToArray()))
                    }
                    finally {
                        $entryMemStream.Dispose()
                    }
                }
                finally {
                    $entryStream.Dispose()
                }
                $entriesProcessed++
            }
        }

        $archive.Dispose()
    }
    finally {
        $memStream.Dispose()
    }

    return $xmlContents.ToArray()
}

function Expand-GzipAttachment {
    [CmdletBinding()]
    param([byte[]]$ContentBytes)

    $inputStream = [System.IO.MemoryStream]::new($ContentBytes)
    $gzipStream = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
    $outputStream = [System.IO.MemoryStream]::new()

    try {
        Copy-StreamWithLimit -Source $gzipStream -Destination $outputStream -Limit $script:MaxDecompressedBytes -EntryName 'gzip'
        return [System.Text.Encoding]::UTF8.GetString($outputStream.ToArray())
    }
    finally {
        $gzipStream.Dispose()
        $inputStream.Dispose()
        $outputStream.Dispose()
    }
}

function Copy-StreamWithLimit {
    <#
    .SYNOPSIS
        Copies from source to destination stream, aborting if the limit is exceeded.
        Prevents decompression bombs from consuming unbounded memory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Source,
        [Parameter(Mandatory)][System.IO.Stream]$Destination,
        [Parameter(Mandatory)][long]$Limit,
        [string]$EntryName = 'stream'
    )

    $buffer = [byte[]]::new(81920)
    $totalRead = [long]0

    while ($true) {
        $bytesRead = $Source.Read($buffer, 0, $buffer.Length)
        if ($bytesRead -eq 0) { break }
        $totalRead += $bytesRead
        if ($totalRead -gt $Limit) {
            throw "Stream size for '$EntryName' exceeds limit of $Limit bytes. Aborting to prevent memory exhaustion."
        }
        $Destination.Write($buffer, 0, $bytesRead)
    }
}

function Read-StreamWithLimit {
    <#
    .SYNOPSIS
        Reads a stream to a UTF-8 string, aborting if the byte limit is exceeded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][long]$Limit,
        [string]$EntryName = 'stream'
    )

    $outputStream = [System.IO.MemoryStream]::new()
    try {
        Copy-StreamWithLimit -Source $Stream -Destination $outputStream -Limit $Limit -EntryName $EntryName
        return [System.Text.Encoding]::UTF8.GetString($outputStream.ToArray())
    }
    finally {
        $outputStream.Dispose()
        $Stream.Dispose()
    }
}

# ─────────────────────────────────────────────
# DMARC XML Parsing
# ─────────────────────────────────────────────

function ConvertFrom-DmarcXml {
    <#
    .SYNOPSIS
        Parses DMARC aggregate report XML into flat record objects.
    .DESCRIPTION
        Each <record> element becomes one output object containing:
        - Report metadata (org_name, report_id, date range)
        - Policy published (domain, p, sp, pct, adkim, aspf)
        - Row data (source_ip, count, disposition, dkim/spf evaluation)
        - Identifiers (header_from, envelope_from, envelope_to)
        - Auth results (primary + full JSON arrays)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$XmlContent,

        [string]$SourceMessageId,

        [string]$IngestionRunId
    )

    $records = [System.Collections.Generic.List[hashtable]]::new()

    # Use XmlReaderSettings to prohibit DTD processing (defense against XML bombs)
    $readerSettings = [System.Xml.XmlReaderSettings]::new()
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null

    $stringReader = $null
    $xmlReader = $null

    try {
        $stringReader = [System.IO.StringReader]::new($XmlContent)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader, $readerSettings)
        $xml = [System.Xml.XmlDocument]::new()
        $xml.Load($xmlReader)
    }
    catch {
        Write-Warning "Failed to parse DMARC XML: $_"
        return @()
    }
    finally {
        if ($null -ne $xmlReader) {
            $xmlReader.Dispose()
        }
        if ($null -ne $stringReader) {
            $stringReader.Dispose()
        }
    }

    $feedback = $xml.feedback
    if (-not $feedback) {
        Write-Warning "XML does not contain a <feedback> root element."
        return @()
    }

    # ── Report metadata ──
    $meta = $feedback.report_metadata
    $orgName   = $meta.org_name
    $email     = $meta.email
    $extraContact = $meta.extra_contact_info
    $reportId  = $meta.report_id

    $dateBegin = $null
    $dateEnd   = $null
    if ($meta.date_range) {
        $dateBegin = Convert-EpochToIso -Epoch $meta.date_range.begin
        $dateEnd   = Convert-EpochToIso -Epoch $meta.date_range.end
    }

    # ── Policy published ──
    $policy = $feedback.policy_published
    $domain = $policy.domain
    $policyP   = $policy.p
    $policySp  = $policy.sp
    $policyPct = if ($policy.pct) { [int]$policy.pct } else { 100 }
    $adkim     = $policy.adkim
    $aspf      = $policy.aspf
    $fo        = $policy.fo

    # Duplicate telemetry key scopes report identity by source organization and policy domain.
    # Report IDs are not guaranteed to be globally unique across providers.
    $duplicateTelemetryKey = '{0}|{1}|{2}|{3}|{4}' -f `
        [string]$orgName,
        [string]$reportId,
        [string]$domain,
        [string]$dateBegin,
        [string]$dateEnd

    # ── Records ──
    $recordElements = $feedback.record
    if (-not $recordElements) {
        Write-Warning "No <record> elements found in report $reportId"
        return @()
    }

    # Handle single record (PowerShell XML treats single child differently)
    if ($recordElements -isnot [System.Array]) {
        $recordElements = @($recordElements)
    }

    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $recordIdx = -1

    foreach ($rec in $recordElements) {
        $recordIdx++
        $row = $rec.row
        $identifiers = $rec.identifiers
        $authResults = $rec.auth_results

        $reasonType = if ($row.policy_evaluated.reason -is [System.Array]) {
            ($row.policy_evaluated.reason | ForEach-Object { $_.type }) -join '; '
        } else { $row.policy_evaluated.reason.type }

        $reasonComment = if ($row.policy_evaluated.reason -is [System.Array]) {
            ($row.policy_evaluated.reason | ForEach-Object { $_.comment }) -join '; '
        } else { $row.policy_evaluated.reason.comment }

        $overrideReasonCategory = Get-OverrideReasonCategory -ReasonType $reasonType

        # ── Primary DKIM result ──
        $dkimResults = @($authResults.dkim)
        $primaryDkim = $null
        $primaryDkimDomain = $null
        $primaryDkimSelector = $null
        $dkimJson = '[]'

        if ($dkimResults.Count -gt 0 -and $dkimResults[0]) {
            $primaryDkim = $dkimResults[0].result
            $primaryDkimDomain = $dkimResults[0].domain
            $primaryDkimSelector = $dkimResults[0].selector

            $dkimArray = foreach ($d in $dkimResults) {
                @{
                    domain       = $d.domain
                    result       = $d.result
                    selector     = $d.selector
                    human_result = $d.human_result
                }
            }
            $dkimJson = ($dkimArray | ConvertTo-Json -Depth 5 -Compress)
            if ($dkimResults.Count -eq 1) { $dkimJson = "[$dkimJson]" }
        }

        # ── Primary SPF result ──
        $spfResults = @($authResults.spf)
        $primarySpf = $null
        $primarySpfDomain = $null
        $primarySpfScope = $null
        $spfJson = '[]'

        if ($spfResults.Count -gt 0 -and $spfResults[0]) {
            $primarySpf = $spfResults[0].result
            $primarySpfDomain = $spfResults[0].domain
            $primarySpfScope = $spfResults[0].scope

            $spfArray = foreach ($s in $spfResults) {
                @{
                    domain = $s.domain
                    result = $s.result
                    scope  = $s.scope
                }
            }
            $spfJson = ($spfArray | ConvertTo-Json -Depth 5 -Compress)
            if ($spfResults.Count -eq 1) { $spfJson = "[$spfJson]" }
        }

        # ── Build flat record ──
        $record = @{
            TimeGenerated                  = [datetime]::UtcNow.ToString('o')
            ReportOrgName                  = $orgName
            ReportEmail                    = $email
            ReportExtraContactInfo         = $extraContact
            ReportId                       = $reportId
            SourceMessageId                = $SourceMessageId
            IngestionRunId                 = $IngestionRunId
            DuplicateTelemetryKey          = $duplicateTelemetryKey
            ReportDateRangeBegin           = $dateBegin
            ReportDateRangeEnd             = $dateEnd
            Domain                         = $domain
            PolicyPublished_p              = $policyP
            PolicyPublished_sp             = $policySp
            PolicyPublished_pct            = $policyPct
            PolicyPublished_adkim          = $adkim
            PolicyPublished_aspf           = $aspf
            PolicyPublished_fo             = $fo
            SourceIP                       = $row.source_ip
            MessageCount                   = [int]$row.count
            PolicyEvaluated_disposition    = $row.policy_evaluated.disposition
            PolicyEvaluated_dkim           = $row.policy_evaluated.dkim
            PolicyEvaluated_spf            = $row.policy_evaluated.spf
            PolicyEvaluated_reason_type    = $reasonType
            PolicyEvaluated_reason_comment = $reasonComment
            OverrideReasonCategory         = $overrideReasonCategory
            HeaderFrom                     = $identifiers.header_from
            EnvelopeFrom                   = $identifiers.envelope_from
            EnvelopeTo                     = $identifiers.envelope_to
            DkimResult                     = $primaryDkim
            DkimDomain                     = $primaryDkimDomain
            DkimSelector                   = $primaryDkimSelector
            SpfResult                      = $primarySpf
            SpfDomain                      = $primarySpfDomain
            SpfScope                       = $primarySpfScope
            DkimAuthResults                = $dkimJson
            SpfAuthResults                 = $spfJson
            RecordIndex                    = $recordIdx
            Aligned_dkim                   = ($row.policy_evaluated.dkim -ieq 'pass')
            Aligned_spf                    = ($row.policy_evaluated.spf  -ieq 'pass')
            DmarcPass                      = ($row.policy_evaluated.dkim -ieq 'pass' -or $row.policy_evaluated.spf -ieq 'pass')
        }

        # Deterministic hash for cross-run deduplication (SourceMessageId|ReportId|RecordIndex|SourceIP|HeaderFrom)
        $hashInput       = [System.Text.Encoding]::UTF8.GetBytes(
            "$SourceMessageId|$reportId|$recordIdx|$($row.source_ip)|$($identifiers.header_from)")
        $record['MessageHash'] = [System.BitConverter]::ToString($sha256.ComputeHash($hashInput)).Replace('-', '').ToLower()

        $records.Add($record)
    }

    $sha256.Dispose()
    return $records.ToArray()
}

function Get-OverrideReasonCategory {
    [CmdletBinding()]
    param(
        [string]$ReasonType
    )

    if ([string]::IsNullOrWhiteSpace($ReasonType)) {
        return $null
    }

    $normalizedReasons = @($ReasonType -split ';' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($knownReason in @('forwarded', 'mailing_list', 'trusted_forwarder', 'local_policy', 'sampled_out')) {
        if ($normalizedReasons -contains $knownReason) {
            return $knownReason
        }
    }

    return 'other'
}

function Convert-EpochToIso {
    [CmdletBinding()]
    param([string]$Epoch)

    if ([string]::IsNullOrWhiteSpace($Epoch)) { return $null }

    try {
        $epochInt = [long]$Epoch
        return [DateTimeOffset]::FromUnixTimeSeconds($epochInt).UtcDateTime.ToString('o')
    }
    catch {
        Write-Warning "Failed to convert epoch '$Epoch' to ISO: $_"
        return $null
    }
}

# ─────────────────────────────────────────────
# Logs Ingestion API
# ─────────────────────────────────────────────

function Send-DmarcRecordsToLogAnalytics {
    <#
    .SYNOPSIS
        Sends DMARC records to Log Analytics via the Logs Ingestion API (DCR).
    .DESCRIPTION
        Uses Managed Identity to authenticate against https://monitor.azure.com.
        Posts records to the DCR's built-in logsIngestion endpoint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Records
    )

    $dcrEndpoint   = $env:DCR_ENDPOINT
    $dcrImmutableId = $env:DCR_IMMUTABLE_ID
    $streamName    = $env:DCR_STREAM_NAME

    if (-not $dcrEndpoint -or -not $dcrImmutableId -or -not $streamName) {
        throw "Missing DCR configuration. Ensure DCR_ENDPOINT, DCR_IMMUTABLE_ID, and DCR_STREAM_NAME are set."
    }

    $token = Get-ManagedIdentityToken -Resource 'https://monitor.azure.com'

    $encodedStreamName = [System.Uri]::EscapeDataString($streamName)
    $uri = "$dcrEndpoint/dataCollectionRules/$dcrImmutableId/streams/${encodedStreamName}?api-version=2023-01-01"

    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $body = $Records | ConvertTo-Json -Depth 10 -Compress
    # Ensure it's always a JSON array
    if ($Records.Count -eq 1) {
        $body = "[$body]"
    }

    try {
        Invoke-WithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body }
        Write-Information "Successfully sent $($Records.Count) records to Log Analytics."
    }
    catch {
        $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 'N/A' }
        Write-Error "Logs Ingestion API request failed - HTTP $statusCode : $_"
        throw
    }
}

# ─────────────────────────────────────────────
# Orchestration
# ─────────────────────────────────────────────

function Invoke-DmarcReportProcessing {
    <#
    .SYNOPSIS
        End-to-end processing of a single mail message containing DMARC aggregate reports.
    .DESCRIPTION
        Fetches the message, extracts XML attachments, parses DMARC aggregate report XML,
        sends records to Log Analytics via the Logs Ingestion API, and marks the message as read.
    .PARAMETER MessageId
        The Graph API message ID.
    .PARAMETER UserId
        The mailbox user ID (object ID of the shared mailbox).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MessageId,

        [string]$UserId = $env:MAILBOX_USER_ID
    )

    Write-Information "Processing message: $MessageId"
    $ingestionRunId = [guid]::NewGuid().ToString()
    Write-Information "Ingestion run ID: $ingestionRunId"

    # Get Graph token once for all operations
    $graphToken = Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com'

    # Fetch message and attachments
    $mail = Get-MailMessage -UserId $UserId -MessageId $MessageId -Token $graphToken
    $subject = $mail.Message.subject
    Write-Information "Message subject: $subject"

    if (-not $mail.Attachments -or $mail.Attachments.Count -eq 0) {
        Write-Warning "Message $MessageId has no attachments. Marking as read."
        Set-MessageRead -UserId $UserId -MessageId $MessageId -Token $graphToken
        return
    }

    # Extract XML from attachments
    $extracted = Expand-DmarcAttachments -Attachments $mail.Attachments
    $xmlContents = $extracted.Xml
    Write-Information "Extracted $($xmlContents.Count) XML content(s) from attachments."

    if ($xmlContents.Count -eq 0) {
        Write-Warning "No DMARC XML found in attachments for message $MessageId"
        Set-MessageRead -UserId $UserId -MessageId $MessageId -Token $graphToken
        return
    }

    # Parse DMARC XML contents
    $allDmarcRecords = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($xmlContent in $xmlContents) {
        $parsed = @(ConvertFrom-DmarcXml -XmlContent $xmlContent -SourceMessageId $MessageId -IngestionRunId $ingestionRunId)
        foreach ($rec in $parsed) {
            $allDmarcRecords.Add($rec)
        }
    }

    Write-Information "Parsed $($allDmarcRecords.Count) total DMARC records."

    if ($allDmarcRecords.Count -gt 0) {
        $batchSize = 500
        $recordsArray = $allDmarcRecords.ToArray()
        for ($i = 0; $i -lt $recordsArray.Length; $i += $batchSize) {
            $batch = @($recordsArray | Select-Object -Skip $i -First $batchSize)
            Send-DmarcRecordsToLogAnalytics -Records $batch
            Write-Information "Sent DMARC batch: $($batch.Count) records (offset $i)."
        }
    }

    # Mark message as read
    Set-MessageRead -UserId $UserId -MessageId $MessageId -Token $graphToken
    Write-Information "Message $MessageId processed and marked as read."
}

# Export all public functions
Export-ModuleMember -Function @(
    'Get-ManagedIdentityToken'
    'Invoke-GraphRequest'
    'Get-MailMessage'
    'Set-MessageRead'
    'Get-UnreadMessages'
    'Get-MailboxMessages'
    'Expand-DmarcAttachments'
    'ConvertFrom-DmarcXml'
    'Send-DmarcRecordsToLogAnalytics'
    'Invoke-DmarcReportProcessing'
)
