# Getting started

This guide wires the scaffolded repo to your existing `contoso-lab` Microsoft Purview account.

## 1. One-time: deployment identity

GitHub Actions authenticates to Azure via **OIDC federated credentials** — no stored client
secret. Per [ADR 0010](adr/0010-automation-identity-subject-model.md) this repo uses **one Entra
app per workflow file**, not a single shared app:

| Entra app (lab display name) | Bound workflow | Federated-credential subject |
|---|---|---|
| `gh-oidc-purview-control-plane` | [`deploy-infra.yml`](../.github/workflows/deploy-infra.yml) | `repo:<org>/<repo>:environment:lab` |
| `gh-oidc-purview-data-plane` | the per-solution data-plane workflows — [`deploy-labels.yml`](../.github/workflows/deploy-labels.yml), [`deploy-label-policies.yml`](../.github/workflows/deploy-label-policies.yml), [`deploy-auto-label-policies.yml`](../.github/workflows/deploy-auto-label-policies.yml), [`deploy-dlp.yml`](../.github/workflows/deploy-dlp.yml), [`deploy-irm.yml`](../.github/workflows/deploy-irm.yml) — and their `sync-*-from-tenant.yml` reverse companions | `repo:<org>/<repo>:environment:lab` |
| `gh-oidc-purview-kv-unlock` | [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml) | `repo:<org>/<repo>:environment:kv-unlock` |

> [!IMPORTANT]
> The subject **must** be `:environment:<env>` (matching the `environment:` declared by each
> workflow job), **not** `:ref:refs/heads/main`. Each deploy job derives its environment from
> the `environment` dispatch input (`lab` default, `dev` optional; branch `dev` → `dev`, every
> other branch → `lab` per [ADR 0057](adr/0057-multi-environment-and-branch-model.md)), and
> `kv-temp-unlock` pairs to `kv-unlock` / `kv-unlock-dev` — so a `ref:`-shaped credential fails
> `azure/login` with a subject/audience mismatch. See
> [Configuring OpenID Connect in Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
> Running the optional `dev` environment means one **additional** federated credential per app —
> subject `repo:<org>/<repo>:environment:dev` (and `…:environment:kv-unlock-dev` on the
> kv-unlock app). One credential per environment subject; the
> [ADR 0010](adr/0010-automation-identity-subject-model.md) single-credential-per-subject
> invariant is unchanged.

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
  - `AZURE_CLIENT_ID` = the `appId` your deploy workflows authenticate as (consumed by [`deploy-infra.yml`](../.github/workflows/deploy-infra.yml) and by every per-solution data-plane workflow, such as [`deploy-labels.yml`](../.github/workflows/deploy-labels.yml) and [`deploy-dlp.yml`](../.github/workflows/deploy-dlp.yml)). The shipped workflows share this one secret; [ADR 0010](adr/0010-automation-identity-subject-model.md) describes the intended per-plane split (`AZURE_CLIENT_ID_CONTROL_PLANE` / `AZURE_CLIENT_ID_DATA_PLANE`).
  - `AZURE_CLIENT_ID_CONTROL_PLANE` = the **control-plane** app's `appId` (consumed by [`validate-oidc-auth.yml`](../.github/workflows/validate-oidc-auth.yml)).
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
- Secrets (Environment: `kv-unlock`):
  - `AZURE_CLIENT_ID_KV_UNLOCK` = the **kv-unlock** app's `appId` (consumed by [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml)).
  - `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` — the unlock job runs under this Environment, so it reads these from here.
- Variables (Environment: `lab` — per [ADR 0057](adr/0057-multi-environment-and-branch-model.md) the workflows read tenant-specific non-secret values from the selected Environment's variables; each workflow's fail-fast guard checks exactly the variables that workflow consumes):
  - `PURVIEW_ACCOUNT_NAME` = your **classic** Purview account name — **omit this variable on a unified-only tenant.** No workflow fail-fast guard requires it (guards are scoped to what each workflow consumes; [`validate-oidc-auth.yml`](../.github/workflows/validate-oidc-auth.yml) runs green without it, by design). It is consumed only by data-plane reconcilers resolving `${env:PURVIEW_ACCOUNT_NAME}` tokens ([ADR 0023](adr/0023-identifier-resolution.md) Category 2), which fail with a named unset-token error if such a token is reached without the variable — the correct fail-closed outcome on a unified-only tenant, where classic reconcilers cannot run anyway ([ADR 0047](adr/0047-unified-catalog-preview-api-coexistence.md)/[ADR 0048](adr/0048-purview-account-discovery-gate.md)). Never set it to the shipped placeholder as if real, and never to a pay-as-you-go metering resource's name (ADR 0048).
  - `PURVIEW_RG` = `rg-purview-lab` (or your actual resource group)
  - `KEY_VAULT_NAME` = your automation Key Vault name
  - `TENANT_DOMAIN` = your tenant primary domain (for example `contoso.onmicrosoft.com`)
  - `DATA_PLANE_CERT_NAME` = the data-plane automation certificate name in that Key Vault
- Variables (Environment: `kv-unlock`):
  - `PURVIEW_RG` and `KEY_VAULT_NAME` — same values as the paired deployment environment; the unlock job resolves the vault through its own Environment.
- Variables (Repository — not environment-scoped, because [`pr-auto-merge.yml`](../.github/workflows/pr-auto-merge.yml) runs without an `environment:`):
  - `OWNER_APPROVAL_LOGIN` = your GitHub login (the lab owner). Two workflows read it: [`pr-auto-merge.yml`](../.github/workflows/pr-auto-merge.yml) only enables merge when the `owner-approved` label is applied by this login, and [`idea-intake-autoadd.yml`](../.github/workflows/idea-intake-autoadd.yml) only auto-adds `needs-review` to issues you open. Set under **Settings → Secrets and variables → Actions → Variables**. See [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

Create the `lab` environment and the `kv-unlock` environment (Settings → Environments → New environment). The `kv-unlock` environment gates [`kv-temp-unlock.yml`](../.github/workflows/kv-temp-unlock.yml) independently and should carry its own required-reviewer protection rule per [ADR 0010 §3](adr/0010-automation-identity-subject-model.md).

> [!NOTE]
> **GitHub plan prerequisite for required reviewers on private repos.** Deployment branch policies (pinning environment `lab` → branch `lab`) work on all plans. **Required reviewers** on Environment protection rules require GitHub **Pro**, **Team**, or **Enterprise** — on GitHub Free with a private repo, configuring required reviewers returns HTTP 422. Interim posture until plan upgrade: rely on deployment branch policy plus the per-environment OIDC subject as the two-layer guard ([ADR 0010 §3](adr/0010-automation-identity-subject-model.md)); the human-approval click before token mint is the piece lost on Free private repos. Public repos can use required reviewers on Free.

### Optional: add a `dev` environment (ADR 0057)

Single-environment operation needs nothing beyond the above — every workflow defaults to `lab`. To run a second environment per [ADR 0057](adr/0057-multi-environment-and-branch-model.md):

1. **Create the `dev` and `kv-unlock-dev` GitHub Environments** (Settings → Environments), each with the same secret/variable set as its `lab` / `kv-unlock` counterpart, holding the dev tenant's or dev resource set's values. If your repo carries a `dev` branch, add a deployment branch policy pinning environment `dev` → branch `dev` (and `lab` → your lab-deploying branch) per [Deployment branch policies](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#deployment-branches-and-tags).
2. **Add the `dev` federated credentials**: on each Entra app, one additional credential with subject `repo:<org>/<repo>:environment:dev` — and on the kv-unlock app, `repo:<org>/<repo>:environment:kv-unlock-dev` (same `az ad app federated-credential create` shape as §1).
3. **Copy the per-environment configuration files**: `infra/main.bicepparam` → `infra/main.dev.bicepparam` and `infra/parameters/lab.yaml` → `infra/parameters/dev.yaml`, then edit the copies with the dev values. The template ships no dev scaffolds on purpose; `deploy-infra` fails fast if `infra/main.dev.bicepparam` is missing, and the scripts receive `infra/parameters/dev.yaml` through the `PURVIEW_PARAMETERS_FILE` environment variable the workflows set.
4. **Verify**: dispatch [`validate-oidc-auth.yml`](../.github/workflows/validate-oidc-auth.yml) with `environment: dev`. Every tenant-touching workflow then accepts `environment: dev` on manual dispatch, and pushes to a `dev` branch route there automatically.

## 3. Point at the existing Purview account

### Greenfield path (no Purview account yet)

If the tenant has **no** Purview account, bootstrap in this order (full detail in [`automation-identity.md`](solutions/governance-foundation/automation-identity.md)):

1. Create the resource group: `az group create -n rg-purview-lab -l eastus` (or your region from `infra/parameters/lab.yaml`).
2. Run Wave 0 steps 5.0–5a (Log Analytics + Key Vault) via the `New-*.ps1` scripts.
3. Deploy control plane **including the Purview account** with subscription-scope **Owner** or **User Access Administrator** (Contributor cannot create custom role definitions):

   ```bash
   az deployment group create -g rg-purview-lab -f infra/main.bicep -p infra/main.bicepparam
   ```

4. Grant yourself **Key Vault Certificates Officer** on the vault, then run 5b–5d (Entra apps, data-plane certificate, RBAC).
5. Assign Purview data-plane roles to the data-plane SP at the root collection (§1 above), then proceed to §4 export/deploy.

### Brownfield path (account already exists)

The `contoso-lab` account already holds live state in the template's worked example. Before the first run:

1. Edit [`infra/main.bicepparam`](../infra/main.bicepparam) so `purviewAccountName` and `location` match the existing account.
2. Edit [`data-plane/collections/collections.yaml`](../data-plane/collections/collections.yaml) so `rootCollection` equals the existing account name (root collection shares the account name).

### Unified-only path (tenant-level Unified Catalog, no classic account)

If discovery per [ADR 0048](adr/0048-purview-account-discovery-gate.md) confirmed the tenant is on the tenant-level Unified Catalog experience — no classic `Microsoft.Purview/accounts` governance resource exists, and any discovered pay-as-you-go metering resource must **never** be targeted — deploy the control-plane stack **without** the classic account, using the same canonical command:

```bash
az deployment group create -g rg-purview-lab -f infra/main.bicep -p infra/main.bicepparam \
  --parameters deployPurviewAccount=false
```

This still deploys [`infra/modules/role-definitions.bicep`](../infra/modules/role-definitions.bicep) (the KV firewall-toggler custom role that `kv-temp-unlock.yml` depends on) while skipping the `Microsoft.Purview/accounts` resource entirely ([conditional deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment)). Leave `purviewAccountName` at the shipped placeholder (ADR 0048 outcome matrix) and omit the `PURVIEW_ACCOUNT_NAME` Environment variable (§2). The classic §4 export/deploy flow does not apply — classic reconcilers cannot drive the unified data plane ([ADR 0047](adr/0047-unified-catalog-preview-api-coexistence.md)).

## 4. First deploy

> [!IMPORTANT]
> The `contoso-lab` account already holds live state — collections, glossary terms, classifications, and possibly data sources and scans. **Export that state into the YAML before you reconcile.** A first `-WhatIf` against the shipped sample YAML reports every existing object as an `Orphan`, and a later apply with `-PruneMissing` would delete them. Leading with the export is the mandatory first-run contract in [`.github/instructions/powershell.instructions.md`](../.github/instructions/powershell.instructions.md#first-run-against-an-existing-tenant-contract).

### 4a. Export the live tenant into the YAML (bootstrap, once per domain)

This first-deploy flow covers the five classic Data Map domains below (it does not touch the `data-plane/unified-catalog/**` manifests, which are out of scope for `/deploy-datamap`). Hydrate each domain's YAML from the live account — the export **writes to disk only, never to Purview**:

```pwsh
az login
pwsh ./scripts/Deploy-Collections.ps1     -AccountName purview-contoso-lab -ExportCurrentState -Force
pwsh ./scripts/Deploy-Glossary.ps1        -AccountName purview-contoso-lab -ExportCurrentState -Force
pwsh ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -ExportCurrentState -Force
pwsh ./scripts/Deploy-DataSources.ps1     -AccountName purview-contoso-lab -ExportCurrentState -Force
pwsh ./scripts/Deploy-Scans.ps1           -AccountName purview-contoso-lab -ExportCurrentState -Force
```

`-Force` is required on the first export because the repo ships each YAML with a **sample** hierarchy (for example the placeholder collection tree in [`data-plane/collections/collections.yaml`](../data-plane/collections/collections.yaml)); without it the export refuses to overwrite a non-empty file. On the export path `-Force` only permits overwriting that local sample file with live tenant state — it has no effect on the apply path and never authorizes a write to Purview.

The export replaces each YAML body (including the `rootCollection` value) with live state, so on an existing tenant this supersedes the sample content you would otherwise hand-curate — the `collections.yaml` edit in §3 matters only if you skip the export against an empty tenant.

Review the resulting diff, open it as a pull request, and merge. The committed YAML now describes the tenant, so the first reconciler run is a no-op instead of a mass delete.

### 4b. Reconcile per domain (`-WhatIf` → confirm → apply)

Only after the bootstrap PR merges, validate desired-state changes per domain in dependency order — Collections → Glossary → Classifications → DataSources → Scans. For each domain, run `-WhatIf` and inspect the drift report:

```pwsh
pwsh ./scripts/Deploy-Collections.ps1 -AccountName purview-contoso-lab -WhatIf
```

Read the `Create` / `Update` / `NoChange` / `Orphan` / `Conflict` counts. **Stop on any `Orphan` or `Conflict` row** — do not pass `-PruneMissing` or `-Force` to clear them; deletions and portal-overwrites require a `destructive`-labeled PR and a typed confirmation. If only `Create` / `Update` / `NoChange` appear, apply the domain:

```pwsh
pwsh ./scripts/Deploy-Collections.ps1 -AccountName purview-contoso-lab
```

The [`/deploy-datamap`](../.github/prompts/deploy-datamap.prompt.md) prompt automates this exact guarded cycle for all five domains and enforces the stop-on-`Orphan`/`Conflict` rule for you — prefer it over running the scripts by hand.

The normal day-2 path is to commit desired-state edits and let CI apply them: open a PR, merge to `main`, and the deploy workflow that owns whatever changed runs the reconcile (`deploy-infra` when `infra/` changed; the per-solution `deploy-<solution>` workflow when that surface's `data-plane/**` YAML or its reconciler changed).

> **Not every surface has a CI apply path.** Only five surfaces own a per-solution workflow today — sensitivity labels, label policies, auto-labeling policies, DLP, and IRM. For the rest (collections, glossary, classifications, data sources, scans, administrative units, Purview role groups, audit retention, retention/DLM, records/file plan, IRM entity lists, unified catalog), there is **no automated apply path yet**: merging the YAML changes nothing on its own, and you must run the surface's [`scripts/Deploy-*.ps1`](../scripts/) reconciler locally. See [ADR 0051](adr/0051-per-solution-workflow-unit-of-data-plane-apply.md); backfilling the missing workflows is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

Run a local apply for a CI-covered surface only when you deliberately deploy from your workstation — there is then no follow-up CI apply to expect.

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
