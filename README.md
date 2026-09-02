# Sales Assistant Agent — Developer-Side Repo (Option 1: Max Separation of Duties)

This repo plays the **developer** side of the split-responsibility model: it never creates or touches the blueprint, its credentials, or its permissions. It only takes the identifiers IAM/Identity hand over, authenticates as the blueprint via GitHub OIDC, and calls the Agent Registration API to spin up an **agent identity** and bring it online.

See the [provisioning runbook](./docs/option1-agent-provisioning-runbook.md) for the full IAM-side process this repo assumes has already happened.

## What you receive from IAM (over a secure channel — never paste these into this repo or a chat)

| Value | Where it's used |
|---|---|
| Blueprint **App ID** (`appId`) | `AGENT_BLUEPRINT_APP_ID` repo variable |
| Blueprint **Object ID** (`id`) | `AGENT_BLUEPRINT_OBJECT_ID` repo variable |
| Tenant ID | `TENANT_ID` repo variable |
| *(fallback only)* client secret | `AGENT_BLUEPRINT_SECRET` repo **secret** — only needed if IAM didn't set up the federated credential below |

None of these are sensitive enough on their own to compromise the tenant **except** the fallback secret — the App ID, Object ID, and Tenant ID are all discoverable via Graph anyway. Still, treat all four the way IAM handed them to you: repo variables/secrets, not code, not commit history, not chat.

## One-time repo setup

1. **Settings → Secrets and variables → Actions → Variables** — add:
   - `AGENT_BLUEPRINT_APP_ID`
   - `AGENT_BLUEPRINT_OBJECT_ID`
   - `TENANT_ID`
2. **Settings → Environments** — create an environment named `production` (must match whatever `subject` IAM configured on the blueprint's federated credential — confirm the exact string with them, e.g. `repo:davisanc/agent-identity-demo:environment:production`).
3. *(Only if IAM issued a fallback secret instead of / in addition to a federated credential)* **Settings → Secrets and variables → Actions → Secrets** — add `AGENT_BLUEPRINT_SECRET`.
4. Confirm with IAM that the federated credential's `subject` claim matches your repo + environment exactly — a mismatch here is the most common cause of `AADSTS70021` on first run.

## Running it

- **Automatically:** every push to `main` runs [`.github/workflows/register-agent.yml`](./.github/workflows/register-agent.yml).
- **Manually:** Actions tab → **Register and activate agent identity** → **Run workflow**.

The workflow:
1. Requests a GitHub OIDC token
2. Exchanges it for a Graph access token, authenticating **as the blueprint** (no secret involved if using the FIC path)
3. Calls `POST /beta/serviceprincipals/Microsoft.Graph.AgentIdentity` to create the agent identity as a child of the blueprint
4. Calls `POST /beta/copilot/agentRegistrations` to publish the agent card — this is what brings it "online" / discoverable in the Agent 365 registry

## What this repo can and can't do

By design, this pipeline can only do what the blueprint's **inheritable permissions** (configured by IAM) and **tenant-wide consent** (granted by IAM/Global Admin) already allow. It cannot request new scopes, add credentials to the blueprint, or widen its own access — if the agent identity it creates can't call an API it needs, that's a change to request from IAM, not something to work around here.
