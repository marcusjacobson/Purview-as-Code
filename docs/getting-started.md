# Getting started

This guide wires the scaffolded repo to your existing `contoso-lab` Microsoft Purview account.

## 1. One-time: deployment identity

GitHub Actions authenticates to Azure via **OIDC federated credentials** — no stored client
secret. Per [ADR 0010](adr/0010-automation-identity-subject-model.md) this repo uses **one Entra
app per workflow file**, not a single shared app:

| Entra app (lab display name) | Bound workflow | Federated-credential subject |
|---|---|---|
| `gh-oidc-purview-control-plane` | [`deploy-infra.yml`](../.github/workflows/deploy-infra.yml) | `repo:<org>/<repo>:environment:lab` |
| `gh-oidc-purview-data-plane` | [`deploy-data-plane.yml`](../.github/workflows/deploy-data-plane.yml) | `repo:<org>/<repo>:environment:lab` |
| `gh-oidc-purview-kv-unlock` | [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml) | `repo:<org>/<repo>:environment:kv-unlock` |

> [!IMPORTANT]
> The subject **must** be `:environment:<env>` (matching the `environment:` declared by each
> workflow job), **not** `:ref:refs/heads/main`. Each deploy job declares `environment: lab`
> (or `kv-unlock`), so a `ref:`-shaped credential fails `azure/login` with a subject/audience
> mismatch. See [Configuring OpenID Connect in Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).

The recommended path is the idempotent provisioning script
[`scripts/New-AutomationEntraApp.ps1`](../scripts/New-AutomationEntraApp.ps1), which reads the app
display names and subject shape from [`infra/parameters/lab.yaml`](../infra/parameters/lab.yaml)
(`automation.apps.*`) and creates each app + service principal + single federated credential. Run
it once per plane. See [Automation identity](solutions/governance-foundation/automation-identity.md)
for the full 5a–5d provisioning sequence.

To create one app by hand instead (control plane shown; repeat for the data-plane and kv-unlock
apps with their own display names and, for kv-unlock, the `environment:kv-unlock` subject):

```bash
# Create the app + service principal
az ad app create --display-name "gh-oidc-purview-control-plane"
APP_ID=$(az ad app list --display-name "gh-oidc-purview-control-plane" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"

# Add the GitHub OIDC federated credential (replace <org>/<repo>; keep the :environment: subject)
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "gh-env-lab",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:contoso/Purview-as-Code-Generic:environment:lab",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Grant each service principal only what its plane needs (least privilege,
[ADR 0010 §5](adr/0010-automation-identity-subject-model.md)):

1. **Control-plane app** (`gh-oidc-purview-control-plane`) — **Azure RBAC** `Contributor` on the
   target resource group (`rg-purview-lab`), needed for `infra/` deployment. No Purview data-plane
   role.
2. **Data-plane app** (`gh-oidc-purview-data-plane`) — **Purview data-plane roles** assigned at the
   root collection of the Purview account:
   - `Collection Admin` — required for account/metadata APIs, collection CRUD, role assignments.
   - `Data Curator` — required for glossary, classification typedefs, lineage.
   - `Data Source Administrator` — required for data source registration and scans.
3. **kv-unlock app** (`gh-oidc-purview-kv-unlock`) — only the custom `Purview-Lab-KV-Firewall-Toggler`
   role at the Key Vault scope (never Contributor on the RG). See [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml).

> [!NOTE]
> `Policy Author` is **not** required. This repo does not author DevOps / data-owner policies — that reconciler was retired per [ADR 0038](adr/0038-devops-policies-reconciler-retirement.md).

Assignment UI: Purview portal → Data Map → Collections → root → **Role assignments**. See [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## 2. GitHub configuration

Under **Settings → Secrets and variables → Actions**:

- Secrets (Environment: `lab`):
  - `AZURE_CLIENT_ID` = the `appId` your deploy workflows authenticate as (consumed by [`deploy-infra.yml`](../.github/workflows/deploy-infra.yml) and [`deploy-data-plane.yml`](../.github/workflows/deploy-data-plane.yml)). The shipped workflows share this one secret; [ADR 0010](adr/0010-automation-identity-subject-model.md) describes the intended per-plane split (`AZURE_CLIENT_ID_CONTROL_PLANE` / `AZURE_CLIENT_ID_DATA_PLANE`).
  - `AZURE_CLIENT_ID_CONTROL_PLANE` = the **control-plane** app's `appId` (consumed by [`validate-oidc-auth.yml`](../.github/workflows/validate-oidc-auth.yml)).
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
- Secrets (Environment: `kv-unlock`):
  - `AZURE_CLIENT_ID_KV_UNLOCK` = the **kv-unlock** app's `appId` (consumed by [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml)).
- Variables (Environment: `lab`):
  - `PURVIEW_ACCOUNT_NAME` = `purview-contoso-lab` (or your actual account name)
- Variables (Repository — not environment-scoped, because [`pr-auto-merge.yml`](../.github/workflows/pr-auto-merge.yml) runs without an `environment:`):
  - `OWNER_APPROVAL_LOGIN` = your GitHub login (the lab owner). The auto-merge workflow only enables merge when the `owner-approved` label is applied by this login. Set under **Settings → Secrets and variables → Actions → Variables**. See [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

Create the `lab` environment and the `kv-unlock` environment (Settings → Environments → New environment). The `kv-unlock` environment gates [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml) independently and should carry its own required-reviewer protection rule per [ADR 0010 §3](adr/0010-automation-identity-subject-model.md).

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
