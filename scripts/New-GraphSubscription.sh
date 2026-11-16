#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# New-GraphSubscription.sh
#
# Creates a Microsoft Graph change notification subscription for the
# DMARC mailbox and wires up the Event Grid pipeline.
#
# Prerequisites:
#   - Azure resources deployed via main.bicep
#   - Function app published (includes the SetupHelper function)
#   - Managed Identity has mailbox-scoped Exchange Application Mail.Read permission
#   - az CLI authenticated (az login)
#   - jq installed
#
# Usage:
#   ./scripts/New-GraphSubscription.sh \
#     --function-app  dmarc-func-abc123 \
#     --resource-group rg-dmarc \
#     --subscription   11111111-1111-1111-1111-111111111111
# ─────────────────────────────────────────────────────────────────

# ── Parse arguments ──

FUNCTION_APP=""
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --function-app|-f)   FUNCTION_APP="$2";   shift 2 ;;
        --resource-group|-g) RESOURCE_GROUP="$2";  shift 2 ;;
        --subscription|-s)   SUBSCRIPTION_ID="$2"; shift 2 ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 --function-app NAME --resource-group RG --subscription SUB_ID" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$FUNCTION_APP" || -z "$RESOURCE_GROUP" || -z "$SUBSCRIPTION_ID" ]]; then
    echo "Error: --function-app, --resource-group, and --subscription are all required." >&2
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  DMARC for Defender XDR — Graph Subscription Setup"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────
# Step 1: Prerequisites
# ─────────────────────────────────────────────

echo "[1/4] Checking prerequisites..."

LOCATION=$(az group show -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null) || {
    echo "Error: Resource group '$RESOURCE_GROUP' not found." >&2
    exit 1
}
echo "  Resource group: $RESOURCE_GROUP ($LOCATION)"

# Get the function app's default hostname from ARM
FUNC_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP"
DEFAULT_HOSTNAME=$(az rest --method get \
    --url "https://management.azure.com${FUNC_RESOURCE_ID}?api-version=2024-04-01" \
    --query properties.defaultHostName -o tsv 2>/dev/null) || {
    echo "Error: Function App '$FUNCTION_APP' not found in resource group '$RESOURCE_GROUP'." >&2
    exit 1
}
echo "  Function App: $FUNCTION_APP ($DEFAULT_HOSTNAME)"

# Verify SetupHelper function is deployed
DEPLOYED_FUNCS=$(az rest --method get \
    --url "https://management.azure.com${FUNC_RESOURCE_ID}/functions?api-version=2024-04-01" \
    --query "value[].name" -o tsv 2>/dev/null | sed 's|.*/||') || true

if ! echo "$DEPLOYED_FUNCS" | grep -q "SetupHelper"; then
    echo "Error: SetupHelper function is not deployed. Deployed functions: [$(echo "$DEPLOYED_FUNCS" | tr '\n' ',' | sed 's/,$//' )]" >&2
    echo "" >&2
    echo "Publish the function app code first using the manual ZIP deployment steps in README.md." >&2
    echo "" >&2
    exit 1
fi
echo "  SetupHelper function: deployed"

# ─────────────────────────────────────────────
# Step 2: Create Graph subscription via SetupHelper
# ─────────────────────────────────────────────

echo ""
echo "[2/4] Creating Graph subscription..."

# Get master host key via ARM
echo "  Retrieving host key..."
KEYS_PATH="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP/host/default/listkeys?api-version=2024-04-01"
MASTER_KEY=$(az rest --method post --url "https://management.azure.com${KEYS_PATH}" --query masterKey -o tsv 2>/dev/null) || {
    echo "Error: Failed to retrieve host keys. Ensure the Function App is deployed." >&2
    exit 1
}

# Read settings before subscription setup so a retry can renew the existing
# subscription instead of creating another one after a partial previous run.
EXISTING_GRAPH_SUBSCRIPTION_ID=$(az functionapp config appsettings list \
    --subscription "$SUBSCRIPTION_ID" -n "$FUNCTION_APP" -g "$RESOURCE_GROUP" \
    --query "[?name=='GRAPH_SUBSCRIPTION_ID'].value | [0]" -o tsv) || {
    echo "Error: Failed to read Function App settings." >&2
    exit 1
}
if [[ "$EXISTING_GRAPH_SUBSCRIPTION_ID" == "None" ]]; then
    EXISTING_GRAPH_SUBSCRIPTION_ID=""
fi
if [[ -n "$EXISTING_GRAPH_SUBSCRIPTION_ID" ]]; then
    if [[ ! "$EXISTING_GRAPH_SUBSCRIPTION_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
        echo "Error: GRAPH_SUBSCRIPTION_ID is not a valid GUID. Review the Function App setting before continuing." >&2
        exit 1
    fi
    echo "  Existing Graph subscription found; it will be resumed rather than duplicated."
fi

# Build notification URL
PARTNER_TOPIC="DmarcPipeline-$FUNCTION_APP"
NOTIFICATION_URL="EventGrid:?azuresubscriptionid=$SUBSCRIPTION_ID&resourcegroup=$RESOURCE_GROUP&partnertopic=$PARTNER_TOPIC&location=$LOCATION"
EXPIRATION=$(date -u -d "+2916 minutes" '+%Y-%m-%dT%H:%M:%S.0000000Z' 2>/dev/null || date -u -v+2916M '+%Y-%m-%dT%H:%M:%S.0000000Z')

echo "  Partner topic: $PARTNER_TOPIC"
echo "  Expiration: $EXPIRATION"

# Pass the master key as a request header — never as a query parameter — to keep it
# out of shell history, process listings, server access logs, and exception messages.
SETUP_URI="https://$DEFAULT_HOSTNAME/api/SetupHelper"
SETUP_BODY=$(jq -n \
    --arg url "$NOTIFICATION_URL" \
    --arg exp "$EXPIRATION" \
    --arg id "$EXISTING_GRAPH_SUBSCRIPTION_ID" \
    '{ notificationUrl: $url, expirationDateTime: $exp } + (if $id == "" then {} else { subscriptionId: $id } end)')

# Retry only a confirmed 404 from cold-start route discovery. A timeout or 5xx
# may follow successful Graph creation, so do not automatically replay the POST.
GRAPH_SUB_ID=""
MAX_ATTEMPTS=4
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo "  Calling SetupHelper (attempt $attempt/$MAX_ATTEMPTS)..."
    CURL_EXIT=0
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$SETUP_URI" \
        -H "Content-Type: application/json" \
        -H "x-functions-key: $MASTER_KEY" \
        -d "$SETUP_BODY" \
        --max-time 120 2>/dev/null) || CURL_EXIT=$?

    HTTP_CODE=${RESPONSE##*$'\n'}
    BODY=${RESPONSE%$'\n'*}
    if [[ ! "$HTTP_CODE" =~ ^[0-9]{3}$ ]]; then
        echo "Error: SetupHelper returned no HTTP status (curl exit $CURL_EXIT); it was not retried automatically to avoid duplicate Graph subscriptions." >&2
        echo "Inspect the Function App logs and GRAPH_SUBSCRIPTION_ID before retrying." >&2
        exit 1
    fi

    if [[ "$HTTP_CODE" == "200" ]]; then
        GRAPH_SUB_ID=$(jq -er '.subscriptionId | strings' <<< "$BODY" 2>/dev/null) || {
            echo "Error: SetupHelper returned HTTP 200 without a valid subscriptionId." >&2
            exit 1
        }
        if [[ ! "$GRAPH_SUB_ID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
            echo "Error: SetupHelper returned an invalid subscription ID." >&2
            exit 1
        fi
        break
    fi

    if [[ "$HTTP_CODE" == "404" && $attempt -lt $MAX_ATTEMPTS ]]; then
        echo "  SetupHelper route is not ready (404); retrying in 15s ($attempt/$MAX_ATTEMPTS)..."
        sleep 15
        continue
    fi

    if [[ "$HTTP_CODE" == "404" ]]; then
        echo "Error: SetupHelper route was not available after $MAX_ATTEMPTS attempts. Confirm the function code is deployed." >&2
    else
        ERROR=$(jq -r 'if type == "object" then (.error // "") else "" end' <<< "$BODY" 2>/dev/null || true)
        if [[ -n "$ERROR" ]]; then
            echo "Error: SetupHelper failed (HTTP $HTTP_CODE): $ERROR. It was not retried automatically to avoid duplicate Graph subscriptions." >&2
        else
            echo "Error: SetupHelper failed (HTTP $HTTP_CODE). It was not retried automatically to avoid duplicate Graph subscriptions." >&2
        fi
    fi
    exit 1
done

echo "  Subscription created or renewed: $GRAPH_SUB_ID"

# Save immediately: if Event Grid setup fails below, the next run renews this
# subscription instead of creating another one.
echo "  Saving GRAPH_SUBSCRIPTION_ID before Event Grid setup..."
az functionapp config appsettings set \
    --subscription "$SUBSCRIPTION_ID" -n "$FUNCTION_APP" -g "$RESOURCE_GROUP" \
    --settings "GRAPH_SUBSCRIPTION_ID=$GRAPH_SUB_ID" \
    -o none 2>/dev/null || {
    echo "Error: Subscription $GRAPH_SUB_ID was created or renewed, but saving it to app settings failed. Save GRAPH_SUBSCRIPTION_ID manually before retrying." >&2
    exit 1
}
echo "  GRAPH_SUBSCRIPTION_ID saved before Event Grid setup."

# ─────────────────────────────────────────────
# Step 3: Activate Partner Topic & create Event Subscription
# ─────────────────────────────────────────────

echo ""
echo "[3/4] Activating partner topic..."

TOPIC_URL="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.EventGrid/partnerTopics/$PARTNER_TOPIC"
EG_API="api-version=2022-06-15"

# Wait for partner topic
TOPIC_FOUND=false
ACTIVATION_STATE=""
for attempt in $(seq 1 18); do
    ACTIVATION_STATE=$(az rest --method get --url "${TOPIC_URL}?${EG_API}" --query "properties.activationState" -o tsv 2>/dev/null) || true
    if [[ -n "$ACTIVATION_STATE" && "$ACTIVATION_STATE" != "None" ]]; then
        TOPIC_FOUND=true
        echo "  Partner topic found."
        break
    fi
    echo "  Waiting for partner topic ($attempt/18)..."
    sleep 10
done

if [[ "$TOPIC_FOUND" != "true" ]]; then
    echo "Error: Partner topic '$PARTNER_TOPIC' did not appear within 3 minutes." >&2
    exit 1
fi

if [[ "$ACTIVATION_STATE" == "Activated" ]]; then
    echo "  Partner topic is already activated."
elif [[ "$ACTIVATION_STATE" == "NeverActivated" ]]; then
    echo "  Activating partner topic..."
    az rest --method post --url "${TOPIC_URL}/activate?${EG_API}" -o none 2>/dev/null || {
        echo "Error: Failed to activate partner topic." >&2
        exit 1
    }
    echo "  Partner topic activated."
else
    echo "Error: Partner topic has unexpected activation state '$ACTIVATION_STATE'." >&2
    exit 1
fi

# Create event subscription
echo "  Creating event subscription..."
FUNC_RESOURCE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP"
FUNC_ENDPOINT_ID="$FUNC_RESOURCE_ID/functions/DmarcReportProcessor"

EVENT_SUB_BODY=$(jq -n \
    --arg rid "$FUNC_ENDPOINT_ID" \
    '{
        properties: {
            destination: {
                endpointType: "AzureFunction",
                properties: {
                    resourceId: $rid,
                    maxEventsPerBatch: 1,
                    preferredBatchSizeInKilobytes: 64
                }
            },
            eventDeliverySchema: "CloudEventSchemaV1_0"
        }
    }')

az rest --method put \
    --url "${TOPIC_URL}/eventSubscriptions/dmarc-report-processor?${EG_API}" \
    --body "$EVENT_SUB_BODY" \
    -o none 2>/dev/null || {
    echo "Error: Failed to create event subscription." >&2
    exit 1
}
echo "  Event subscription created."

# ─────────────────────────────────────────────
# Step 4: Verify saved subscription ID
# ─────────────────────────────────────────────

echo ""
echo "[4/4] Verifying saved subscription ID..."
SAVED_GRAPH_SUBSCRIPTION_ID=$(az functionapp config appsettings list \
    --subscription "$SUBSCRIPTION_ID" -n "$FUNCTION_APP" -g "$RESOURCE_GROUP" \
    --query "[?name=='GRAPH_SUBSCRIPTION_ID'].value | [0]" -o tsv) || {
    echo "Error: Failed to verify GRAPH_SUBSCRIPTION_ID. Restore it before completing setup." >&2
    exit 1
}
if [[ "$SAVED_GRAPH_SUBSCRIPTION_ID" != "$GRAPH_SUB_ID" ]]; then
    echo "Error: GRAPH_SUBSCRIPTION_ID was not saved correctly. Restore the setting before completing setup." >&2
    exit 1
fi
echo "  GRAPH_SUBSCRIPTION_ID verified."

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Setup complete!"
echo "  Graph subscription ID: $GRAPH_SUB_ID"
echo "  The RenewGraphSubscription timer will keep it alive."
echo "═══════════════════════════════════════════════════════"
echo ""
