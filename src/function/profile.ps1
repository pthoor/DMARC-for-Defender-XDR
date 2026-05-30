# Azure Functions profile.ps1
#
# This profile runs on every cold start of the Function App.
# Use it for one-time initialization that applies to all functions.

# Ensure TLS 1.2 and 1.3 for legacy WebRequest/WebClient code paths.
# NOTE: Invoke-RestMethod on PowerShell 7 / .NET 6+ uses HttpClient (SocketsHttpHandler),
# which does NOT honour ServicePointManager — TLS for those calls is negotiated by the OS
# (OpenSSL on Linux). Azure Functions on Linux defaults to TLS 1.2+, so outbound REST
# calls to Graph, Key Vault, and the Logs Ingestion API are already secure without this.
# The line below is retained as a safety net for any legacy WebRequest code paths.
[System.Net.ServicePointManager]::SecurityProtocol = (
    [System.Net.SecurityProtocolType]::Tls12 -bor
    [System.Net.SecurityProtocolType]::Tls13
)

# Set Information preference so Write-Information messages appear in logs
$InformationPreference = 'Continue'

Write-Information "DMARC-to-Sentinel Function App initialized. PowerShell $($PSVersionTable.PSVersion)"
