# Option 1 — Maximum Separation of Duties: Agent Provisioning Runbook

**Model:** IAM/Identity team owns and creates every security-sensitive Entra object (blueprint, blueprint principal, credentials). The developer never touches Entra directly — they only receive the blueprint's identifiers over a secure channel and call the Agent Registration API from their pipeline to create the agent identity and register it.

This maps to Microsoft Entra Agent ID (preview) + the Agent Registration API / Agent 365 registry.

---

## Phase 1 — IAM/Identity Team (in Entra)

### Prerequisites (IAM team)
- Role: **Agent ID Administrator** (or **Privileged Role Administrator** for the Graph app-permission grants) — required to create the blueprint *and* add a secret credential.
- PowerShell 7+ with the Microsoft Graph PowerShell SDK, or direct Graph API calls.
- Connect with the scopes needed to do all of the below in one session:

```powershell
Connect-MgGraph -Scopes "AgentIdentityBlueprint.Create", `
  "AgentIdentityBlueprint.AddRemoveCreds.All", `
  "AgentIdentityBlueprint.UpdateAuthProperties.All", `
  "AgentIdentityBlueprintPrincipal.Create" `
  -TenantId <your-tenant-id>
```

### Step 1.1 — Create the agent identity blueprint

```http
POST https://graph.microsoft.com/v1.0/applications/
OData-Version: 4.0
Content-Type: application/json
Authorization: Bearer <iam-team-token>

{
  "@odata.type": "Microsoft.Graph.AgentIdentityBlueprint",
  "displayName": "Contoso-SalesAssistant-Blueprint",
  "sponsors@odata.bind": ["https://graph.microsoft.com/v1.0/users/<sponsor-user-id>"],
  "owners@odata.bind": ["https://graph.microsoft.com/v1.0/users/<iam-owner-id>"]
}
```

Record the returned **`appId`** (Application/Client ID) and **`id`** (Object ID) — these are the two identifiers you'll hand to the developer.

**Object type constraints, learned the hard way:**
- `sponsors@odata.bind` only accepts **dynamic membership groups** or **M365 groups** — a plain assigned security group is rejected with `Invalid sponsor group type`. Create a dedicated M365 group per blueprint (e.g. `Sales-Assistant-Agent-Sponsors`) rather than reusing an existing security group:
  ```http
  POST https://graph.microsoft.com/v1.0/groups
  Content-Type: application/json

  {
    "displayName": "Sales-Assistant-Agent-Sponsors",
    "mailEnabled": true,
    "mailNickname": "salesassistant-sponsors",
    "securityEnabled": false,
    "groupTypes": ["Unified"]
  }
  ```
- `owners@odata.bind` only accepts **users or service principals** — not groups, even the M365 group above. If you omit a valid owner, Entra defaults ownership to the `Agent ID Management App` system service principal, leaving no human able to manage the blueprint day-to-day. Add one explicitly:
  ```http
  POST https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/owners/$ref
  Content-Type: application/json

  { "@odata.id": "https://graph.microsoft.com/v1.0/users/<owner-user-id>" }
  ```

### Step 1.2 — Create the blueprint principal

Do this right after the blueprint app exists — it clears Entra's "not instantiated / search only" warning early and gives you a fully visible object to check as you configure the rest. Nothing in Steps 1.3–1.4 depends on this happening first, but Steps 1.5 and 1.7 (inheritable permissions, tenant-wide consent) both operate on the **principal**, so it has to exist before those.

```http
POST https://graph.microsoft.com/v1.0/serviceprincipals/microsoft.graph.agentIdentityBlueprintPrincipal
OData-Version: 4.0
Content-Type: application/json
Authorization: Bearer <iam-team-token>

{ "appId": "<blueprint-app-id>" }
```

### Step 1.3 — Add a federated credential

Preferred for a pipeline that runs in GitHub Actions: trust GitHub's OIDC issuer directly, so no long-lived secret ever leaves Entra. This is created in addition to the client secret below, per your process — treat the FIC as the credential the pipeline should use, and the secret as a locked-down fallback for local testing only.

```http
POST https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/federatedIdentityCredentials
OData-Version: 4.0
Content-Type: application/json
Authorization: Bearer <iam-team-token>

{
  "name": "github-actions-oidc",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:contoso-org/sales-assistant-agent:environment:production",
  "audiences": ["api://AzureADTokenExchange"]
}
```

Adjust `subject` to match how the developer's workflow will run — e.g. `repo:<org>/<repo>:ref:refs/heads/main` for a branch, or `repo:<org>/<repo>:environment:<name>` for a protected GitHub Environment (recommended, since it lets IAM require manual approval on the GitHub side too).

### Step 1.4 — Add a client secret (fallback / local dev only)

```http
POST https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/addPassword
Content-Type: application/json
Authorization: Bearer <iam-team-token>

{
  "passwordCredential": {
    "displayName": "fallback-secret",
    "endDateTime": "2027-03-01T00:00:00Z"
  }
}
```

Capture the returned secret **once** — it can't be retrieved again.

### Step 1.5 — Configure inheritable permissions

This is two separate actions. The `inheritablePermissions` config alone grants nothing — it only declares which of the scopes the blueprint **principal already holds** get passed down to child agent identities. Skipping part A leaves the config pointing at permissions that don't actually exist yet.

**Part A — Grant the real permissions to the blueprint principal.** Creating an `oauth2PermissionGrants` entry with `consentType: AllPrincipals` **is** the tenant-wide admin consent action — it's not a lesser step that still needs a separate consent click afterward. There are two legitimate ways to perform it, and which one an organization should use depends on how it wants that authority exercised:

**Option A1 — Automated, via IAM's app credential (what was actually used here).** If the client ID/secret IAM is running these calls with already carries `DelegatedPermissionGrant.ReadWrite.All` — check by decoding the access token's `roles` claim, e.g. at [jwt.ms](https://jwt.ms) — then this POST succeeds without any further approval step, because that authority was already granted to the app itself (typically when Agent ID was first enabled in the tenant, by whoever set that up). This is fast and fits a fully automated pipeline, but means whoever holds that app's secret has effectively Global Admin-equivalent consent power *tenant-wide*, not just for this one blueprint — worth weighing against the "maximum separation of duties" goal of this whole runbook, since it quietly collapses the human-review step this design otherwise assumes.

```http
# 1. Get the blueprint PRINCIPAL's object id (not the application's object id)
GET https://graph.microsoft.com/v1.0/serviceprincipals?$filter=appId eq '<blueprint-app-id>'&$select=id,displayName

# 2. Get Microsoft Graph's service principal object id in your tenant
GET https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId eq '00000003-0000-0000-c000-000000000000'&$select=id

# 3. Grant the scopes — succeeds immediately if the calling app already holds
#    DelegatedPermissionGrant.ReadWrite.All; no further click required.
POST https://graph.microsoft.com/v1.0/oauth2PermissionGrants
Content-Type: application/json

{
  "clientId": "<blueprint-principal-object-id-from-1>",
  "consentType": "AllPrincipals",
  "resourceId": "<graph-sp-object-id-from-2>",
  "scope": "Mail.Read Mail.Send Calendars.ReadWrite TeamsActivity.Send"
}
```

**Option A2 — Manual, by a human Global Administrator.** For enterprises that want a person with that role to actually review and click through consent for each blueprint — the more conservative choice, and the one that best matches the "Global Administrator grants tenant-wide consent" line in the original design — do it in the portal instead of via a pre-authorized app credential:

Entra admin center → **Entra ID → Agents → Agent blueprints** *(not Enterprise applications — this object type doesn't appear there; see the note under Step 1.7)* → select the blueprint → **API permissions** (or the equivalent action surfaced on the **Granted permissions** page) → review the requested scopes → **Grant admin consent for `<tenant>`**.

Whichever option is used, the result is the same: scopes appear under the blueprint's **Granted permissions (Preview) → Admin consent** tab, alongside the automatic `AgentIdentity.CreateAsManager` entry. Swap the `scope` string in A1 for whatever the agent actually needs — the example above covers read/send email, send calendar invites, and send Teams notifications.

**Part B — Mark those scopes inheritable.** `resourceAppId` is the primary key on this resource (there's no separate `id` field) — so create it once with `POST`, and if it already exists (e.g. you first created it with the wrong shape), fix it with `PATCH` against the same `resourceAppId` in the URL rather than trying to `POST` again.

```http
# Create (first time)
POST https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/microsoft.graph.agentIdentityBlueprint/inheritablePermissions
Content-Type: application/json

{
  "resourceAppId": "00000003-0000-0000-c000-000000000000",
  "inheritableScopes": {
    "@odata.type": "microsoft.graph.enumeratedScopes",
    "scopes": ["Mail.Read", "Mail.Send", "Calendars.ReadWrite", "TeamsActivity.Send"]
  }
}
```

```http
# Update (if a record for this resourceAppId already exists)
PATCH https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/microsoft.graph.agentIdentityBlueprint/inheritablePermissions/00000003-0000-0000-c000-000000000000
Content-Type: application/json

{
  "inheritableScopes": {
    "@odata.type": "microsoft.graph.enumeratedScopes",
    "scopes": ["Mail.Read", "Mail.Send", "Calendars.ReadWrite", "TeamsActivity.Send"]
  }
}
```

The `inheritableScopes` value must be a **nested object with its own `@odata.type` discriminator** — `allAllowedScopes`, `enumeratedScopes` (requires a non-empty `scopes` array), or `noScopes`. A flat `{"scopesInheritanceKind": "enumerated", "scopes": [...]}` body is silently accepted as valid JSON but produces a `noScopes` record — no error, just the wrong result, so verify with a `GET` after writing:

```http
GET https://graph.microsoft.com/v1.0/applications/<blueprint-object-id>/microsoft.graph.agentIdentityBlueprint/inheritablePermissions
```

**Important:** neither part of this step shows up anywhere in the Entra portal except the effect of Part A on the "Granted permissions" page. There's no UI for `inheritablePermissions` itself yet (preview) — the `GET` above is the only way to confirm it's configured correctly.

### Step 1.6 — Hand off to the developer over a secure channel

Deliver **only**:
- Blueprint **App ID** (`appId`)
- Blueprint **Object ID** (`id`)
- Fallback client secret (if issued)

via a secrets vault (Key Vault, GitHub encrypted environment secret pushed by IAM, PIM-protected sharing) — never email, chat, or a ticket. The developer's GitHub Actions workflow will authenticate as the blueprint using the federated credential from Step 1.2, so the secret ideally never needs to touch GitHub at all.

### Step 1.7 — Global Administrator grants tenant-wide admin consent

**If Step 1.5 was done via Option A2 (manual Global Admin click), this step is already complete** — A2 *is* Step 1.7, just performed earlier in sequence rather than as a separate action afterward.

**If Step 1.5 was done via Option A1 (automated, using IAM's pre-authorized app credential), there is no further click required either** — the `oauth2PermissionGrants` POST with `consentType: AllPrincipals` already *is* the tenant-wide consent grant, exercised through delegated app authority rather than an interactive session. Nothing is left "pending" after A1; there's no separate approval queue it sits in.

So in practice, Step 1.7 isn't a distinct action that always happens after 1.5 — it's the same action, and Step 1.5 is where the organization's choice of *how* to grant it (A1 vs A2) actually gets made. This section is kept as a separate numbered step mainly to flag that decision explicitly for anyone following this runbook, and as the place to note where to find it in the portal if going the manual route:

- **Correct portal location:** Entra admin center → **Entra ID → Agents → Agent blueprints** (agent blueprint principals are a distinct object type and do **not** appear under classic Enterprise applications — don't waste time searching there).
- **Admin consent URL** (works regardless of portal navigation, if preferred):
  ```
  https://login.microsoftonline.com/<tenant-id>/v2.0/adminconsent?client_id=<blueprint-app-id>
  ```

Either way, until *some* form of this consent exists, the blueprint can create agent identities, but those identities can't call any downstream API with the scopes declared in Step 1.5.

---

## Phase 2 — Developer: register the agent and bring it online (GitHub Actions)

The developer never authenticates as themselves against Entra for this. Their workflow authenticates **as the blueprint** (via the FIC from Step 1.2), uses that token to mint a new **agent identity** as a child of the blueprint, then calls the **Agent Registration API** to publish the agent card so it's discoverable/governable in the Agent 365 registry — i.e. "online."

### 2.1 — Repo setup

- Store the two non-secret values as repository/environment variables (not secrets, since they aren't sensitive on their own):
  - `AGENT_BLUEPRINT_APP_ID`
  - `AGENT_BLUEPRINT_OBJECT_ID`
- Grant the workflow `id-token: write` permission so it can request a GitHub OIDC token.
- If IAM only issued a client secret (no FIC), store it as an encrypted GitHub secret, e.g. `AGENT_BLUEPRINT_SECRET`, and swap the token step below accordingly.

### 2.2 — Workflow: `.github/workflows/register-agent.yml`

```yaml
name: Register and activate agent identity

on:
  workflow_dispatch:
  push:
    branches: [main]

permissions:
  id-token: write   # required to request the GitHub OIDC token
  contents: read

env:
  TENANT_ID: <your-tenant-id>
  BLUEPRINT_APP_ID: ${{ vars.AGENT_BLUEPRINT_APP_ID }}
  GRAPH_BASE: https://graph.microsoft.com

jobs:
  register-agent:
    runs-on: ubuntu-latest
    environment: production   # must match the FIC 'subject' IAM configured
    steps:

      - name: Get GitHub OIDC token
        id: idtoken
        run: |
          IDTOKEN=$(curl -sLS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r '.value')
          echo "::add-mask::$IDTOKEN"
          echo "idtoken=$IDTOKEN" >> "$GITHUB_OUTPUT"

      - name: Exchange OIDC token for a blueprint access token
        id: blueprinttoken
        run: |
          RESP=$(curl -sLS -X POST \
            "https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token" \
            -d "client_id=${BLUEPRINT_APP_ID}" \
            -d "scope=https://graph.microsoft.com/.default" \
            -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
            -d "client_assertion=${{ steps.idtoken.outputs.idtoken }}" \
            -d "grant_type=client_credentials")
          TOKEN=$(echo "$RESP" | jq -r '.access_token')
          echo "::add-mask::$TOKEN"
          echo "token=$TOKEN" >> "$GITHUB_OUTPUT"

      - name: Create the agent identity from the blueprint
        id: createidentity
        run: |
          RESP=$(curl -sLS -X POST \
            "${GRAPH_BASE}/beta/serviceprincipals/Microsoft.Graph.AgentIdentity" \
            -H "OData-Version: 4.0" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${{ steps.blueprinttoken.outputs.token }}" \
            -d '{
                  "displayName": "Contoso Sales Assistant Agent",
                  "agentIdentityBlueprintId": "'"${BLUEPRINT_APP_ID}"'"
                }')
          echo "$RESP"
          IDENTITY_ID=$(echo "$RESP" | jq -r '.id')
          echo "identity_id=$IDENTITY_ID" >> "$GITHUB_OUTPUT"

      - name: Register the agent card (bring it online in the Agent 365 registry)
        run: |
          curl -sLS -X POST \
            "${GRAPH_BASE}/beta/copilot/agentRegistrations" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${{ steps.blueprinttoken.outputs.token }}" \
            -d '{
                  "displayName": "Contoso Sales Assistant Agent",
                  "description": "Assists reps with CRM lookups and quote generation",
                  "createdBy": "'"${BLUEPRINT_APP_ID}"'",
                  "sourceCreatedDateTime": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
                  "sourceLastModifiedDateTime": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
                  "agentIdentityId": "'"${{ steps.createidentity.outputs.identity_id }}"'",
                  "agentIdentityBlueprintId": "'"${AGENT_BLUEPRINT_OBJECT_ID}"'",
                  "agentCard": {
                    "name": "Contoso Sales Assistant Agent",
                    "version": "1.0.0",
                    "description": "Assists reps with CRM lookups and quote generation",
                    "provider": "Contoso",
                    "capabilities": { "streaming": false, "pushNotifications": false },
                    "defaultInputModes": ["text"],
                    "defaultOutputModes": ["text"],
                    "skills": [
                      { "id": "crm-lookup", "name": "CRM Lookup", "description": "Look up customer and deal records" }
                    ]
                  }
                }'
```

**Notes on the workflow:**
- No client secret appears anywhere — the trust chain is entirely GitHub OIDC → FIC on the blueprint → Graph token. This is what actually delivers the separation of duties: the developer's pipeline can *only* do what the blueprint's inherited permissions (set by IAM in Step 1.5) and consent (Step 1.7) allow.
- If IAM only gave you a secret instead of a FIC, replace the two token steps with a single `client_credentials` + `client_secret` call against the same token endpoint.
- Both Graph calls used above are **`/beta`** — expect breaking changes and don't treat this as a supported production dependency without a compatibility check against current docs before you rely on it long-term.
- `AgentRegistration.ReadWrite.All` is the least-privileged permission the agent registration call needs — confirm it's included in what IAM granted in Step 1.7.

---

## Why this maximizes separation of duties

| Object / secret | Created by | Ever seen by developer? |
|---|---|---|
| Blueprint app registration | IAM | No |
| Federated credential (GitHub OIDC trust) | IAM | No |
| Client secret (fallback) | IAM | Only via vault, ideally unused |
| Inheritable permissions | IAM | No |
| Tenant-wide consent | Global Admin | No |
| Agent identity (child object) | Developer's pipeline, using blueprint token | Yes — this is the only object the developer's code creates |
| Agent registration / card | Developer's pipeline | Yes |

The developer's blast radius is capped at exactly what the blueprint was pre-authorized to do; they can't widen scope, add credentials, or grant themselves new permissions from the pipeline.

---

## Appendix — Insomnia setup notes (client-credentials testing)

If IAM is testing these calls manually in Insomnia before automating them:

- **Getting a token:** use a plain `POST {{ _.token_url }}` request, body type **Form URL Encoded**, with four separate Name/Value rows — `grant_type`/`client_credentials`, `client_id`/`{{ _.client_id }}`, `client_secret`/`{{ _.client_secret }}`, `scope`/`https://graph.microsoft.com/.default`. Don't paste a multi-line block into a single Value field — Insomnia will send it as one malformed parameter and Entra will reject it (`AADSTS900144` or `AADSTS70003` depending on what got mangled). Check the **Timeline** tab after sending to see the raw outgoing body if a request fails unexpectedly.
- **Using the token:** set the request's **Auth** tab to **Bearer Token** and paste only the raw token string — no surrounding quotes, no `Bearer ` prefix (Insomnia adds that). A stray leading quote copied from a JSON response produces `IDX14102: Unable to decode the header...`.
- **Better long-term setup:** configure Insomnia's built-in **OAuth 2.0** auth type (Grant Type: Client Credentials) once on a parent folder, with `Fetch Tokens` to refresh on demand, and set child requests to **Inherit from parent** — avoids hand-copying tokens between requests entirely, and avoids the ~60–90 minute expiry catching you mid-session.
- **Secret hygiene:** client secrets and access tokens are both plaintext credentials — treat anything pasted outside Insomnia's own environment store (chat, tickets, docs) as compromised and rotate it.
