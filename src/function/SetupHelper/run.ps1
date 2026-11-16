# SetupHelper - HTTP Trigger (admin auth)
# Called by New-GraphSubscription.ps1 to create a Graph change notification
# subscription using the Function App's Managed Identity.
#
# This function exists because creating a subscription on another user's
# mailbox requires application-level Mail.Read — which only the MI has.
# The setup script (running as the operator) cannot get that permission,
# so it invokes this function instead.
#
# Reads MAILBOX_USER_ID and GRAPH_CLIENT_STATE from app settings (env vars).
# Accepts notificationUrl, expirationDateTime, and an optional existing subscriptionId.
# notificationUrl must use the "EventGrid:" scheme; direct "https" webhook URLs
# are rejected unless the ALLOW_WEBHOOK_NOTIFICATION_URL=true app setting is present
# (they would deliver notifications, including the clientState secret, to an
# arbitrary external endpoint).

param($Request)

Import-Module "$PSScriptRoot/../modules/DmarcHelpers.psm1" -Force

try {
    $body = $Request.Body

    if (-not $body.notificationUrl -or -not $body.expirationDateTime) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = 400
            Body        = (@{ error = 'Missing required fields: notificationUrl, expirationDateTime' } | ConvertTo-Json)
            ContentType = 'application/json'
        })
        return
    }

    $existingSubscriptionId = $null
    if ($body.subscriptionId) {
        $parsedSubscriptionId = [guid]::Empty
        if (-not [guid]::TryParse([string]$body.subscriptionId, [ref]$parsedSubscriptionId)) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode  = 400
                Body        = (@{ error = 'subscriptionId must be a GUID.' } | ConvertTo-Json)
                ContentType = 'application/json'
            })
            return
        }
        $existingSubscriptionId = $parsedSubscriptionId.ToString()
    }

    # Validate that notificationUrl is a well-formed URL with an accepted scheme.
    # This pipeline delivers Graph notifications via Event Grid, so only the
    # "EventGrid:" scheme is accepted by default. A direct "https" webhook URL would
    # send notifications — including the GRAPH_CLIENT_STATE secret — to an arbitrary
    # external endpoint, so it requires explicit opt-in via the
    # ALLOW_WEBHOOK_NOTIFICATION_URL=true app setting.
    $allowWebhookUrl = $env:ALLOW_WEBHOOK_NOTIFICATION_URL -eq 'true'
    try {
        $parsedUri = [System.Uri]::new([string]$body.notificationUrl)
        $schemeAllowed = ($parsedUri.Scheme -eq 'eventgrid') -or
                         ($allowWebhookUrl -and $parsedUri.Scheme -eq 'https')
        if (-not $schemeAllowed) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode  = 400
                Body        = (@{ error = 'notificationUrl must use the EventGrid scheme. Direct HTTPS webhook URLs require the ALLOW_WEBHOOK_NOTIFICATION_URL=true app setting.' } | ConvertTo-Json)
                ContentType = 'application/json'
            })
            return
        }
    }
    catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = 400
            Body        = (@{ error = 'notificationUrl is not a valid URL.' } | ConvertTo-Json)
            ContentType = 'application/json'
        })
        return
    }

    $mailboxUserId = $env:MAILBOX_USER_ID
    $clientState   = $env:GRAPH_CLIENT_STATE

    if (-not $mailboxUserId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = 500
            Body        = (@{ error = 'MAILBOX_USER_ID is not configured in app settings.' } | ConvertTo-Json)
            ContentType = 'application/json'
        })
        return
    }

    if (-not $clientState) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = 500
            Body        = (@{ error = "GRAPH_CLIENT_STATE is not configured. Every Graph subscription must have a clientState for authenticated notifications." } | ConvertTo-Json)
            ContentType = 'application/json'
        })
        return
    }

    if ($clientState -like '@Microsoft.KeyVault*') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = 500
            Body        = (@{ error = "GRAPH_CLIENT_STATE contains an unresolved Key Vault reference. Ensure the Function App's Managed Identity has been granted 'Key Vault Secrets User' on the vault and that role propagation is complete before calling SetupHelper." } | ConvertTo-Json)
            ContentType = 'application/json'
        })
        return
    }

    $expectedResource = "users/$mailboxUserId/mailFolders('Inbox')/messages"

    $subscriptionBody = @{
        changeType         = 'created'
        notificationUrl    = $body.notificationUrl
        resource           = $expectedResource
        expirationDateTime = $body.expirationDateTime
    }

    if ($clientState) {
        $subscriptionBody['clientState'] = $clientState
    }

    $graphToken = Get-ManagedIdentityToken -Resource 'https://graph.microsoft.com'
    $result = $null
    if ($existingSubscriptionId) {
        Write-Information "Resuming Graph subscription $existingSubscriptionId for user $mailboxUserId"
        $subscriptionUri = "https://graph.microsoft.com/v1.0/subscriptions/$existingSubscriptionId"
        $existingSubscription = $null
        $existingSubscriptionResponse = Invoke-WebRequest -Uri $subscriptionUri `
            -Headers @{ Authorization = "Bearer $graphToken" } -SkipHttpErrorCheck -ErrorAction Stop
        if ($existingSubscriptionResponse.StatusCode -eq 404) {
            Write-Information "Stored Graph subscription $existingSubscriptionId is no longer available; creating a replacement."
        }
        elseif ($existingSubscriptionResponse.StatusCode -ne 200) { # not creating another subscription on ambiguous errors
            throw "Failed to inspect stored Graph subscription (HTTP $($existingSubscriptionResponse.StatusCode)); not creating another subscription."
        }
        else {
            $existingSubscription = $existingSubscriptionResponse.Content | ConvertFrom-Json
        }

        if ($existingSubscription) {
            if ($existingSubscription.resource -ne $expectedResource -or
                $existingSubscription.notificationUrl -ne [string]$body.notificationUrl -or
                $existingSubscription.clientState -cne [string]$clientState) {
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode  = 409
                    Body        = (@{ error = 'Stored subscription does not match this mailbox, notification URL, or client state. Review the existing subscription before continuing.' } | ConvertTo-Json)
                    ContentType = 'application/json'
                })
                return
            }

            $result = Invoke-GraphRequest -Uri $subscriptionUri -Method PATCH `
                -Body @{ expirationDateTime = $body.expirationDateTime } -Token $graphToken
        }
    }

    if (-not $result) {
        Write-Information "Creating Graph subscription for user $mailboxUserId"
        $createResponse = Invoke-WebRequest -Uri 'https://graph.microsoft.com/v1.0/subscriptions' `
            -Method POST `
            -Headers @{ Authorization = "Bearer $graphToken" } `
            -Body ($subscriptionBody | ConvertTo-Json -Depth 10) `
            -ContentType 'application/json' -SkipHttpErrorCheck -ErrorAction Stop
        if ($createResponse.StatusCode -ne 201) {
            throw "Graph subscription creation failed (HTTP $($createResponse.StatusCode)); it was not retried automatically to avoid duplicate subscriptions."
        }
        $result = $createResponse.Content | ConvertFrom-Json
        if (-not $result.id) {
            throw 'Graph subscription creation returned no subscription ID; it was not retried automatically.'
        }
        Write-Information "Subscription created: $($result.id)"
    }
    else {
        Write-Information "Subscription renewed: $($result.id)"
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = 200
        Body        = (@{ subscriptionId = $result.id } | ConvertTo-Json)
        ContentType = 'application/json'
    })
}
catch {
    Write-Error "SetupHelper failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode  = 500
        Body        = (@{ error = 'An internal error occurred. Check the function logs for details.' } | ConvertTo-Json)
        ContentType = 'application/json'
    })
}
