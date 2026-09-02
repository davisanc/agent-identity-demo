#!/usr/bin/env bash
# Local sanity-check script — mirrors the GitHub Actions workflow but uses the
# fallback client secret so you can test outside CI before wiring up the FIC.
#
# Usage:
#   export TENANT_ID=...
#   export AGENT_BLUEPRINT_APP_ID=...
#   export AGENT_BLUEPRINT_OBJECT_ID=...
#   export AGENT_BLUEPRINT_SECRET=...   # fallback secret from IAM, vault only — never commit
#   ./scripts/local-test.sh
#
# Requires: curl, jq

set -euo pipefail

for var in TENANT_ID AGENT_BLUEPRINT_APP_ID AGENT_BLUEPRINT_OBJECT_ID AGENT_BLUEPRINT_SECRET; do
  if [ -z "${!var:-}" ]; then
    echo "Missing required env var: $var" >&2
    exit 1
  fi
done

GRAPH_BASE="https://graph.microsoft.com"

echo "==> Getting blueprint access token (client secret path)..."
TOKEN_RESP=$(curl -sLS -X POST \
  "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
  -d "client_id=${AGENT_BLUEPRINT_APP_ID}" \
  -d "client_secret=${AGENT_BLUEPRINT_SECRET}" \
  -d "scope=https://graph.microsoft.com/.default" \
  -d "grant_type=client_credentials")

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token')
if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
  echo "Token request failed:" >&2
  echo "$TOKEN_RESP" | jq . >&2
  exit 1
fi
echo "    Got token."

echo "==> Creating agent identity from blueprint..."
IDENTITY_RESP=$(curl -sLS -X POST \
  "${GRAPH_BASE}/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" \
  -H "OData-Version: 4.0" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
        "displayName": "Contoso Sales Assistant Agent (local test)",
        "agentIdentityBlueprintId": "'"${AGENT_BLUEPRINT_APP_ID}"'"
      }')

echo "$IDENTITY_RESP" | jq .
IDENTITY_ID=$(echo "$IDENTITY_RESP" | jq -r '.id')
if [ "$IDENTITY_ID" = "null" ] || [ -z "$IDENTITY_ID" ]; then
  echo "Agent identity creation failed — see response above." >&2
  exit 1
fi
echo "    Created agent identity: ${IDENTITY_ID}"

echo "Done. Delete this test identity from Entra > Agents > Agent identities when finished, it's not wired to Step 2 registration."
