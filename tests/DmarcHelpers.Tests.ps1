#Requires -Version 7.4
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester tests for DmarcHelpers PowerShell module.
.DESCRIPTION
    Tests all functions in the DmarcHelpers.psm1 module including:
    - Token acquisition
    - Graph API helpers
    - DMARC attachment extraction
    - DMARC XML parsing
    - Log Analytics ingestion
#>

BeforeAll {
    # Import the module
    Import-Module "$PSScriptRoot/../src/function/modules/DmarcHelpers.psm1" -Force
}

Describe 'DmarcHelpers Module' {
    Context 'Module Import' {
        It 'Should import the module successfully' {
            Get-Module DmarcHelpers | Should -Not -BeNullOrEmpty
        }

        It 'Should export expected functions' {
            $exportedFunctions = (Get-Module DmarcHelpers).ExportedFunctions.Keys
            $exportedFunctions | Should -Contain 'Get-ManagedIdentityToken'
            $exportedFunctions | Should -Contain 'Invoke-GraphRequest'
            $exportedFunctions | Should -Contain 'Get-MailMessage'
            $exportedFunctions | Should -Contain 'Set-MessageRead'
            $exportedFunctions | Should -Contain 'Get-UnreadMessages'
            $exportedFunctions | Should -Contain 'Get-MailboxMessages'
            $exportedFunctions | Should -Contain 'Expand-DmarcAttachments'
            $exportedFunctions | Should -Contain 'ConvertFrom-DmarcXml'
            $exportedFunctions | Should -Contain 'Send-DmarcRecordsToLogAnalytics'
            $exportedFunctions | Should -Contain 'Invoke-DmarcReportProcessing'
        }
    }

    Context 'Get-ManagedIdentityToken' {
        It 'Should require IDENTITY_ENDPOINT environment variable' {
            $env:IDENTITY_ENDPOINT = $null
            $env:IDENTITY_HEADER = 'test'
            { Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com' } | Should -Throw '*IDENTITY_ENDPOINT*'
        }

        It 'Should require IDENTITY_HEADER environment variable' {
            $env:IDENTITY_ENDPOINT = 'https://test.endpoint'
            $env:IDENTITY_HEADER = $null
            { Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com' } | Should -Throw '*IDENTITY_HEADER*'
        }
    }

    Context 'ConvertFrom-DmarcXml' {
        It 'Should parse valid DMARC XML' {
            $validXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>google.com</org_name>
    <email>noreply-dmarc-support@google.com</email>
    <report_id>12345678901234567890</report_id>
    <date_range>
      <begin>1704067200</begin>
      <end>1704153599</end>
    </date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <adkim>r</adkim>
    <aspf>r</aspf>
    <p>none</p>
    <sp>none</sp>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>192.0.2.1</source_ip>
      <count>5</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>pass</spf>
      </policy_evaluated>
    </row>
    <identifiers>
      <header_from>example.com</header_from>
      <envelope_from>example.com</envelope_from>
    </identifiers>
    <auth_results>
      <dkim>
        <domain>example.com</domain>
        <result>pass</result>
        <selector>default</selector>
      </dkim>
      <spf>
        <domain>example.com</domain>
        <result>pass</result>
        <scope>mfrom</scope>
      </spf>
    </auth_results>
  </record>
</feedback>
'@

            $result = ConvertFrom-DmarcXml -XmlContent $validXml
            $result | Should -Not -BeNullOrEmpty
            # When there's one record, it returns a single hashtable, not an array
            if ($result -is [array]) {
                $result.Length | Should -Be 1
                $record = $result[0]
            } else {
                $record = $result
            }
            $record.ReportOrgName | Should -Be 'google.com'
            $record.Domain | Should -Be 'example.com'
            $record.SourceIP | Should -Be '192.0.2.1'
            $record.MessageCount | Should -Be 5
            $record.PolicyEvaluated_dkim | Should -Be 'pass'
            $record.PolicyEvaluated_spf | Should -Be 'pass'
            $record.DkimResult | Should -Be 'pass'
            $record.SpfResult | Should -Be 'pass'
        }

        It 'Should emit duplicate telemetry fields when processing metadata is provided' {
            $validXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>google.com</org_name>
    <email>noreply-dmarc-support@google.com</email>
    <report_id>12345678901234567890</report_id>
    <date_range>
      <begin>1704067200</begin>
      <end>1704153599</end>
    </date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <adkim>r</adkim>
    <aspf>r</aspf>
    <p>none</p>
    <sp>none</sp>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>192.0.2.1</source_ip>
      <count>5</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>pass</spf>
      </policy_evaluated>
    </row>
    <identifiers>
      <header_from>example.com</header_from>
      <envelope_from>example.com</envelope_from>
    </identifiers>
    <auth_results>
      <dkim>
        <domain>example.com</domain>
        <result>pass</result>
      </dkim>
      <spf>
        <domain>example.com</domain>
        <result>pass</result>
      </spf>
    </auth_results>
  </record>
</feedback>
'@

            $result = ConvertFrom-DmarcXml -XmlContent $validXml -SourceMessageId 'msg-123' -IngestionRunId 'run-abc'
            $record = if ($result -is [array]) { $result[0] } else { $result }

            $record.SourceMessageId | Should -Be 'msg-123'
            $record.IngestionRunId | Should -Be 'run-abc'
            $record.DuplicateTelemetryKey | Should -BeLike 'google.com|12345678901234567890|example.com|*|*'
        }

        It 'Should parse XML with multiple records' {
            $multiRecordXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test.com</org_name>
    <email>test@test.com</email>
    <report_id>123</report_id>
    <date_range>
      <begin>1704067200</begin>
      <end>1704153599</end>
    </date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>192.0.2.1</source_ip>
      <count>10</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>pass</spf>
      </policy_evaluated>
    </row>
    <identifiers>
      <header_from>example.com</header_from>
    </identifiers>
    <auth_results>
      <dkim>
        <domain>example.com</domain>
        <result>pass</result>
      </dkim>
      <spf>
        <domain>example.com</domain>
        <result>pass</result>
      </spf>
    </auth_results>
  </record>
  <record>
    <row>
      <source_ip>192.0.2.2</source_ip>
      <count>5</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>fail</dkim>
        <spf>fail</spf>
      </policy_evaluated>
    </row>
    <identifiers>
      <header_from>example.com</header_from>
    </identifiers>
    <auth_results>
      <dkim>
        <domain>example.com</domain>
        <result>fail</result>
      </dkim>
      <spf>
        <domain>example.com</domain>
        <result>fail</result>
      </spf>
    </auth_results>
  </record>
</feedback>
'@

            $result = ConvertFrom-DmarcXml -XmlContent $multiRecordXml
            $result | Should -Not -BeNullOrEmpty
            # Multiple records should return an array
            $result -is [array] | Should -Be $true
            $result.Length | Should -Be 2
            $result[0].SourceIP | Should -Be '192.0.2.1'
            $result[1].SourceIP | Should -Be '192.0.2.2'
        }

        It 'Should handle invalid XML gracefully' {
            $invalidXml = '<invalid>xml</not-closed>'
            $result = ConvertFrom-DmarcXml -XmlContent $invalidXml
            $result | Should -BeNullOrEmpty
        }

        It 'Should handle empty XML' {
            # Empty string is not accepted by the parameter, so we test with whitespace instead
            $result = ConvertFrom-DmarcXml -XmlContent ' '
            $result | Should -BeNullOrEmpty
        }

        It 'Should emit DmarcPass, Aligned_dkim, and Aligned_spf based on policy_evaluated outcome' {
            $alignmentXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test.com</org_name>
    <email>test@test.com</email>
    <report_id>alignment-test</report_id>
    <date_range><begin>1704067200</begin><end>1704153599</end></date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>1.2.3.4</source_ip>
      <count>10</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>fail</spf>
      </policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>pass</result></dkim>
      <spf><domain>example.com</domain><result>fail</result></spf>
    </auth_results>
  </record>
  <record>
    <row>
      <source_ip>5.6.7.8</source_ip>
      <count>5</count>
      <policy_evaluated>
        <disposition>reject</disposition>
        <dkim>fail</dkim>
        <spf>fail</spf>
      </policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>fail</result></dkim>
      <spf><domain>example.com</domain><result>fail</result></spf>
    </auth_results>
  </record>
</feedback>
'@
            $result = ConvertFrom-DmarcXml -XmlContent $alignmentXml
            $result | Should -Not -BeNullOrEmpty
            $result -is [array] | Should -Be $true
            $result.Length | Should -Be 2

            # DKIM pass, SPF fail → DmarcPass = true
            $result[0].Aligned_dkim | Should -Be $true
            $result[0].Aligned_spf  | Should -Be $false
            $result[0].DmarcPass    | Should -Be $true

            # Both fail → DmarcPass = false
            $result[1].Aligned_dkim | Should -Be $false
            $result[1].Aligned_spf  | Should -Be $false
            $result[1].DmarcPass    | Should -Be $false
        }

        It 'Should derive OverrideReasonCategory from policy override reason types' {
            $overrideXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test.com</org_name>
    <email>test@test.com</email>
    <report_id>override-test</report_id>
    <date_range><begin>1704067200</begin><end>1704153599</end></date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>10.0.0.1</source_ip>
      <count>2</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>pass</dkim>
        <spf>pass</spf>
        <reason><type>mailing_list</type></reason>
      </policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>pass</result></dkim>
      <spf><domain>example.com</domain><result>pass</result></spf>
    </auth_results>
  </record>
  <record>
    <row>
      <source_ip>10.0.0.2</source_ip>
      <count>1</count>
      <policy_evaluated>
        <disposition>none</disposition>
        <dkim>fail</dkim>
        <spf>fail</spf>
        <reason><type>custom_receiver_logic</type></reason>
      </policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>fail</result></dkim>
      <spf><domain>example.com</domain><result>fail</result></spf>
    </auth_results>
  </record>
</feedback>
'@

            $result = ConvertFrom-DmarcXml -XmlContent $overrideXml
            $result[0].OverrideReasonCategory | Should -Be 'mailing_list'
            $result[1].OverrideReasonCategory | Should -Be 'other'
        }

        It 'Should emit RecordIndex starting at 0 and incrementing per record' {
            $multiXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test.com</org_name>
    <email>test@test.com</email>
    <report_id>index-test</report_id>
    <date_range><begin>1704067200</begin><end>1704153599</end></date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>1.1.1.1</source_ip>
      <count>1</count>
      <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>pass</spf></policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>pass</result></dkim>
      <spf><domain>example.com</domain><result>pass</result></spf>
    </auth_results>
  </record>
  <record>
    <row>
      <source_ip>2.2.2.2</source_ip>
      <count>2</count>
      <policy_evaluated><disposition>none</disposition><dkim>fail</dkim><spf>fail</spf></policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>fail</result></dkim>
      <spf><domain>example.com</domain><result>fail</result></spf>
    </auth_results>
  </record>
</feedback>
'@
            $result = ConvertFrom-DmarcXml -XmlContent $multiXml
            $result[0].RecordIndex | Should -Be 0
            $result[1].RecordIndex | Should -Be 1
        }

        It 'Should emit a 64-character lowercase hex MessageHash per record' {
            $hashXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test.com</org_name>
    <email>test@test.com</email>
    <report_id>hash-test</report_id>
    <date_range><begin>1704067200</begin><end>1704153599</end></date_range>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
    <pct>100</pct>
  </policy_published>
  <record>
    <row>
      <source_ip>1.1.1.1</source_ip>
      <count>1</count>
      <policy_evaluated><disposition>none</disposition><dkim>pass</dkim><spf>pass</spf></policy_evaluated>
    </row>
    <identifiers><header_from>example.com</header_from></identifiers>
    <auth_results>
      <dkim><domain>example.com</domain><result>pass</result></dkim>
      <spf><domain>example.com</domain><result>pass</result></spf>
    </auth_results>
  </record>
</feedback>
'@
            $r1 = ConvertFrom-DmarcXml -XmlContent $hashXml -SourceMessageId 'msg-A'
            $record = if ($r1 -is [array]) { $r1[0] } else { $r1 }

            # SHA256 → 32 bytes → 64 hex chars, lowercase
            $record.MessageHash | Should -Match '^[0-9a-f]{64}$'

            # Deterministic: same inputs produce same hash
            $r2 = ConvertFrom-DmarcXml -XmlContent $hashXml -SourceMessageId 'msg-A'
            $rec2 = if ($r2 -is [array]) { $r2[0] } else { $r2 }
            $record.MessageHash | Should -Be $rec2.MessageHash

            # Different SourceMessageId → different hash
            $r3 = ConvertFrom-DmarcXml -XmlContent $hashXml -SourceMessageId 'msg-B'
            $rec3 = if ($r3 -is [array]) { $r3[0] } else { $r3 }
            $record.MessageHash | Should -Not -Be $rec3.MessageHash
        }

        It 'Should prohibit DTD processing (security check)' {
            $dtdXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE feedback [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
<feedback>
  <report_metadata>
    <org_name>&xxe;</org_name>
  </report_metadata>
</feedback>
'@
            $result = ConvertFrom-DmarcXml -XmlContent $dtdXml
            # Should either return empty or fail safely (no file read)
            $result | Should -BeNullOrEmpty
        }
    }

    Context 'Expand-DmarcAttachments' {
        It 'Should handle XML attachments and return Xml key' {
            $xmlContent = @'
<?xml version="1.0" encoding="UTF-8"?>
<feedback>
  <report_metadata>
    <org_name>test</org_name>
    <report_id>123</report_id>
  </report_metadata>
  <policy_published>
    <domain>example.com</domain>
    <p>none</p>
  </policy_published>
</feedback>
'@
            $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($xmlContent)
            $base64 = [System.Convert]::ToBase64String($xmlBytes)

            $attachment = @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                'name' = 'report.xml'
                'contentBytes' = $base64
            }

            $result = Expand-DmarcAttachments -Attachments @($attachment)
            $result | Should -Not -BeNullOrEmpty
            $result.Xml | Should -Not -BeNullOrEmpty
            $result.Xml.Count | Should -Be 1
            $result.Xml[0] | Should -BeLike '*<feedback>*'
        }

        It 'Should handle GZIP attachments' {
            $xmlContent = '<feedback><report_metadata><org_name>test</org_name></report_metadata></feedback>'
            $xmlBytes = [System.Text.Encoding]::UTF8.GetBytes($xmlContent)

            # Compress to GZIP
            $memStream = [System.IO.MemoryStream]::new()
            $gzipStream = [System.IO.Compression.GZipStream]::new($memStream, [System.IO.Compression.CompressionMode]::Compress)
            $gzipStream.Write($xmlBytes, 0, $xmlBytes.Length)
            $gzipStream.Close()
            $gzipBytes = $memStream.ToArray()
            $memStream.Dispose()

            $base64 = [System.Convert]::ToBase64String($gzipBytes)
            $attachment = @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                'name' = 'report.xml.gz'
                'contentBytes' = $base64
            }

            $result = Expand-DmarcAttachments -Attachments @($attachment)
            $result | Should -Not -BeNullOrEmpty
            $result.Xml | Should -Not -BeNullOrEmpty
            $result.Xml.Count | Should -Be 1
            $result.Xml[0] | Should -BeLike '*<feedback>*'
        }

        It 'Should skip oversized attachments' {
            # Create a very large content exceeding MaxAttachmentBytes
            $largeBytes = [byte[]]::new(26 * 1024 * 1024)  # 26 MB
            $base64 = [System.Convert]::ToBase64String($largeBytes)

            $attachment = @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                'name' = 'large.xml'
                'contentBytes' = $base64
            }

            $result = Expand-DmarcAttachments -Attachments @($attachment)
            $result.Xml.Count | Should -Be 0
        }

        It 'Should skip non-file attachments' {
            $attachment = @{
                '@odata.type' = '#microsoft.graph.itemAttachment'
                'name' = 'meeting.ics'
            }

            $result = Expand-DmarcAttachments -Attachments @($attachment)
            $result.Xml.Count | Should -Be 0
        }

        It 'Should skip unrecognized file extensions' {
            $content = 'test content'
            $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $base64 = [System.Convert]::ToBase64String($contentBytes)

            $attachment = @{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                'name' = 'document.pdf'
                'contentBytes' = $base64
            }

            $result = Expand-DmarcAttachments -Attachments @($attachment)
            $result.Xml.Count | Should -Be 0
        }
    }

    Context 'Send-DmarcRecordsToLogAnalytics' {
        It 'Should require DCR_ENDPOINT environment variable' {
            $env:DCR_ENDPOINT = $null
            $env:DCR_IMMUTABLE_ID = 'test'
            $env:DCR_STREAM_NAME = 'test'

            $records = @(@{ TestField = 'value' })
            { Send-DmarcRecordsToLogAnalytics -Records $records } | Should -Throw '*DCR*'
        }

        It 'Should require DCR_IMMUTABLE_ID environment variable' {
            $env:DCR_ENDPOINT = 'https://test.endpoint'
            $env:DCR_IMMUTABLE_ID = $null
            $env:DCR_STREAM_NAME = 'test'

            $records = @(@{ TestField = 'value' })
            { Send-DmarcRecordsToLogAnalytics -Records $records } | Should -Throw '*DCR*'
        }

        It 'Should require DCR_STREAM_NAME environment variable' {
            $env:DCR_ENDPOINT = 'https://test.endpoint'
            $env:DCR_IMMUTABLE_ID = 'test-id'
            $env:DCR_STREAM_NAME = $null

            $records = @(@{ TestField = 'value' })
            { Send-DmarcRecordsToLogAnalytics -Records $records } | Should -Throw '*DCR*'
        }
    }

    Context 'Invoke-WithRetry (via Invoke-GraphRequest)' {
        It 'Should succeed on the first attempt when no error occurs' {
            $env:IDENTITY_ENDPOINT = 'https://identity.endpoint'
            $env:IDENTITY_HEADER   = 'test-header'

            $callCount = 0
            Mock -ModuleName DmarcHelpers Invoke-RestMethod {
                $callCount++
                if ($callCount -eq 1 -and $Uri -like '*identity*') { return @{ access_token = 'tok' } }
                return @{ value = 'ok' }
            }

            $result = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/me' -Token 'test-token'
            $result.value | Should -Be 'ok'
        }

        It 'Should rethrow immediately on non-retryable errors (e.g. 404)' {
            $env:IDENTITY_ENDPOINT = 'https://identity.endpoint'
            $env:IDENTITY_HEADER   = 'test-header'

            $script:attempts = 0
            Mock -ModuleName DmarcHelpers Invoke-RestMethod {
                $script:attempts++
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('404', $response)
            }
            Mock -ModuleName DmarcHelpers Start-Sleep { }

            { Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/me' -Token 'test-token' } | Should -Throw
            $script:attempts | Should -Be 1
        }

        It 'Should retry on 429 up to MaxAttempts then rethrow' {
            $env:IDENTITY_ENDPOINT = 'https://identity.endpoint'
            $env:IDENTITY_HEADER   = 'test-header'

            $script:attempts = 0
            Mock -ModuleName DmarcHelpers Invoke-RestMethod {
                $script:attempts++
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::TooManyRequests)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('429', $response)
            }
            Mock -ModuleName DmarcHelpers Start-Sleep { }

            { Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/me' -Token 'test-token' } | Should -Throw
            # Default MaxAttempts = 4
            $script:attempts | Should -Be 4
        }

        It 'Should succeed after a transient 503 on the first attempt' {
            $env:IDENTITY_ENDPOINT = 'https://identity.endpoint'
            $env:IDENTITY_HEADER   = 'test-header'

            $script:attempts = 0
            Mock -ModuleName DmarcHelpers Invoke-RestMethod {
                $script:attempts++
                if ($script:attempts -eq 1) {
                    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::ServiceUnavailable)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('503', $response)
                }
                return @{ value = 'recovered' }
            }
            Mock -ModuleName DmarcHelpers Start-Sleep { }

            $result = Invoke-GraphRequest -Uri 'https://graph.microsoft.com/v1.0/me' -Token 'test-token'
            $result.value | Should -Be 'recovered'
            $script:attempts | Should -Be 2
        }
    }

}
