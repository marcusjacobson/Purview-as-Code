# Getting started

This guide wires the scaffolded repo to your existing `contoso-lab` Microsoft Purview account.

## 1. One-time: deployment identity

Create (or reuse) an Entra application that GitHub Actions will impersonate via OIDC federated credentials. Detailed steps: [Authenticate for APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).

```bash
# Create the app + service principal
az ad app create --display-name "gh-Purview-as-Code-Generic"
APP_ID=$(az ad app list --display-name "gh-Purview-as-Code-Generic" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"
SP_OID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Add a GitHub OIDC federated credential (replace owner/repo/ref)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:contoso/Purview-as-Code-Generic:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Grant the service principal:

1. **Azure RBAC** — `Contributor` on the target resource group (needed for `infra/` deployment).
2. **Purview data plane roles** — assigned at the root collection of the Purview account:
   - `Collection Admin` — required for account/metadata APIs, collection CRUD, role assignments.
   - `Data Curator` — required for glossary, classification typedefs, lineage.
   - `Data Source Administrator` — required for data source registration and scans.

> [!NOTE]
> `Policy Author` is **not** required. This repo does not author DevOps / data-owner policies — that reconciler was retired per [ADR 0038](adr/0038-devops-policies-reconciler-retirement.md).

Assignment UI: Purview portal → Data Map → Collections → root → **Role assignments**. See [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## 2. GitHub configuration

Under **Settings → Secrets and variables → Actions**:

- Secrets (Environment: `lab`):
  - `AZURE_CLIENT_ID` = `$APP_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
- Variables (Environment: `lab`):
  - `PURVIEW_ACCOUNT_NAME` = `purview-contoso-lab` (or your actual account name)

Create the `lab` environment (Settings → Environments → New environment → `lab`).

## 3. Point at the existing Purview account

The `contoso-lab` account already exists, so the control-plane deploy will reconcile its properties (idempotent). Before the first run:

1. Edit [`infra/main.bicepparam`](../infra/main.bicepparam) so `purviewAccountName` and `location` match the existing account.
2. Edit [`data-plane/collections/collections.yaml`](../data-plane/collections/collections.yaml) so `rootCollection` equals the existing account name (root collection shares the account name).

## 4. First deploy

```bash
# Optional local dry run
az login
pwsh ./scripts/Deploy-Collections.ps1     -AccountName purview-contoso-lab -WhatIf
pwsh ./scripts/Deploy-Glossary.ps1        -AccountName purview-contoso-lab -WhatIf
pwsh ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -WhatIf
```

Then push to `main` — `deploy-infra` runs first, followed by `deploy-data-plane`.

## 5. Day-2 workflow

- All changes via pull request.
- `validate` runs on every PR (Bicep lint, yamllint, PSScriptAnalyzer).
- Merging to `main` triggers the deploy workflow for whichever plane changed.
- Destructive operations (collection delete, glossary term delete) are gated behind explicit `-PruneMissing` flags that are deliberately not enabled in CI yet.

## 6. Context handoffs between chat sessions

Long iterations of [`/build-item`](../.github/prompts/build-item.prompt.md) can fill the Copilot Chat context window or span multiple work sessions. Two prompt files manage the handoff:

- [`/prepare-handoff`](../.github/prompts/prepare-handoff.prompt.md) — run **at the end** of a chat session that needs to pause. It writes a single Markdown brief to `.copilot-tracking/handoff/<branch>-<timestamp>.md` describing what was validated, what's left, and which prompt to resume with. The `.copilot-tracking/` folder is gitignored, so the brief is local-only scratch and never lands in a PR.
- [`/resume-from-handoff`](../.github/prompts/resume-from-handoff.prompt.md) — run **at the start** of a fresh chat session. It loads the most recent brief, re-runs branch and working-tree precondition checks, restates the next step, and routes back to `/build-item` (or `@artifact-resolver`, or an ADR draft) per the brief. After a successful hand-off the brief is deleted automatically — briefs are one-shot.

When to use them: context window ≥ 80% full, more than ~30 tool calls accumulated in the session, topic shifting between planes, end of a work day, or handing off to another contributor. See [`.github/instructions/context-handoff.instructions.md`](../.github/instructions/context-handoff.instructions.md) for the full trigger list and the rules on what a brief MUST and MUST NOT contain (no secrets, no real identifiers, no tool-call transcripts).

When **not** to use them: for "ask a quick side question", prefer VS Code's [`/fork`](https://code.visualstudio.com/docs/copilot/chat/chat-sessions#_fork-a-chat-session). For "this iteration went sideways, undo", use [chat checkpoints](https://code.visualstudio.com/docs/copilot/chat/chat-checkpoints). Handoffs are for *cross-session resume*, not undo or branching.
