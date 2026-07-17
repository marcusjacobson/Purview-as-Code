# Tenant onboarding

This guide takes a fresh clone of the **Purview-as-Code generic template** from zero to a
tailored, deployable repository for **your** Microsoft Purview tenant. It orchestrates the
clone → decouple → tailor → wire-up → deploy flow and hands off to [Getting started](getting-started.md)
for the detailed identity setup.

> Prefer a narrative overview first? See the [Kickoff guide](kickoff-guide.md) — this page is the
> detailed step reference it links to.

> This template ships tenant-neutral. Every tenant-specific value is a Microsoft-documented
> placeholder (`contoso`, `contoso.onmicrosoft.com`, zero-GUID). It will **not** deploy against
> a real tenant until you complete Step 3.

## Prerequisites

- An **Azure subscription** and a **resource group** you can deploy into (the deploy identity is
  Contributor-scoped to that group; it must already exist).
- A **Microsoft Entra tenant** where you can create an app registration and (optionally) security
  groups.
- A **Microsoft Purview account** (existing, or one you will create via `infra/`).
- A **GitHub repository** created from this template (see Step 1).
- **VS Code** with **GitHub Copilot Chat** (custom agents are a VS Code feature, per
  [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes)).
- Local tooling for validation: **Azure CLI** (`az`, includes Bicep), **PowerShell 7.4+**, and
  **Pester 5.x** (the test runner installs it if missing).

## Step 1 — Get a copy of the template

Use either path:

- **GitHub UI (recommended for a spin-off repo):** click **Use this template → Create a new
  repository**. A template-generated repository starts from a single commit with unrelated
  history, so it cannot open a pull request back to the source template. See
  [Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template).
- **Command line (for a local workspace):**

  ```bash
  git clone https://github.com/<your-org>/<your-repo>.git
  cd <your-repo>
  ```

## Step 2 — Decouple your copy with the Kickoff agent

Sever your copy from the source template so it can never contribute content back, per
[ADR 0045](adr/0045-template-kickoff-spinoff-model.md).

- If you used **Use this template** (Step 1), GitHub already decoupled you: a template-generated
  repository has unrelated history and cannot open a pull request back to the source. You can skip
  to Step 3. (If you run `@operator-kickoff` here anyway, it resolves the true source via the
  GitHub template relationship, not `origin`, and installs only the optional pre-push backstop.)
- If you **cloned** the template, open the repo in VS Code, start Copilot Chat, and run the
  **Kickoff** agent:

  ```text
  @operator-kickoff
  ```

  The agent ([`.github/agents/operator-kickoff.agent.md`](../.github/agents/operator-kickoff.agent.md))
  offers **Local workspace** (removes the source `origin` and resets history) or **Spin-off GitHub
  repository** (creates your own repo and repoints `origin`), installs the no-push-back guard
  ([`scripts/Set-KickoffGuard.ps1`](../scripts/Set-KickoffGuard.ps1)), verifies it
  ([`scripts/Test-KickoffGuard.ps1`](../scripts/Test-KickoffGuard.ps1)), then hands off to the
  Tenant Intake agent.

## Step 3 — Tailor the copy with the Tenant Intake agent

Create a working branch so the tailoring lands as a reviewable diff:

> **Operator downstream repos ([ADR 0057 §8](adr/0057-multi-environment-and-branch-model.md)):**
> cut the branch from `dev` or `lab`, **not from `main`**. `main` is the upstream mirror and must
> stay tenant-neutral (empty desired state). Never merge tailoring into `main`. Example:
> `git checkout -b chore/tenant-intake-lab lab`.

```bash
git checkout -b chore/tenant-intake
```

Open the repo in VS Code, start Copilot Chat, and invoke the **Tenant Intake** agent:

```text
@operator-tenant
```

The agent ([`.github/agents/operator-tenant.agent.md`](../.github/agents/operator-tenant.agent.md))
interviews you for your tenant values one question at a time, then — only after you confirm — writes
them into:

- [`infra/parameters/lab.yaml`](../infra/parameters/lab.yaml) — the single source of truth for
  environment, region, resource group, Purview account, Key Vault, Log Analytics, tenant domain,
  and the OIDC app display names. Per
  [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files).
- [`infra/main.bicepparam`](../infra/main.bicepparam) — the control-plane parameters.
- The **identity-boundary statements** in
  [`.github/copilot-instructions.md`](../.github/copilot-instructions.md), `README.md`,
  [`.github/CODEOWNERS`](../.github/CODEOWNERS), and the naming instructions.

What the agent **never** does: store a secret or real subscription/tenant/object ID in any file,
and never deploy. Subscription and tenant IDs belong in GitHub secrets, not in source (Step 5).

> Prefer to edit by hand? Open [`infra/parameters/lab.yaml`](../infra/parameters/lab.yaml) and
> replace the values in the `TEMPLATE — replace the placeholder values below` header block.

## Step 4 — Review the tailoring diff

```bash
git --no-pager diff
```

Confirm the placeholders are gone and replaced with your values. To scan for any leftover
placeholder without the sample-data noise, generate the exact scan command from the tenant
manifest (it excludes the intentional-sample paths per [ADR 0046](adr/0046-tenant-placeholder-manifest.md))
and run it:

```pwsh
./scripts/Get-TenantResidualScanCommand.ps1 -Kind Residual | Invoke-Expression
./scripts/Get-TenantResidualScanCommand.ps1 -Kind Functional | Invoke-Expression
```

Remaining matches in the MIXED surfaces (`copilot-instructions.md`, `README.md`,
`getting-started.md`) are expected convention prose, not misses — see the `@operator-tenant`
Step 6 notes for how to triage each line.

Commit when satisfied:

```bash
git add -A && git commit -m "chore(repo): tailor template for <your-tenant>"
```

## Step 5 — Wire up the deployment identity and secrets

The repository authenticates to Azure from GitHub Actions using a **Microsoft Entra app + OIDC
federated credential** — no stored client secret. Per
[Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).

Follow [Getting started §1–§2](getting-started.md) for the exact `az ad app` commands. In short:

1. Create the Entra app + service principal and add a federated credential whose subject is
   `repo:<your-org>/<your-repo>:environment:<env>`.
2. Grant it **Contributor** on your resource group (control plane) and the Microsoft Purview
   data-plane roles **Collection Admin**, **Data Curator**, and **Data Source Administrator** at the
   root collection — per
   [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).
3. In **Settings → Environments → `<env>`**, set secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID` and the variables `PURVIEW_ACCOUNT_NAME`, `PURVIEW_RG`,
   `KEY_VAULT_NAME`, `TENANT_DOMAIN`, and `DATA_PLANE_CERT_NAME` — the workflows read
   tenant-specific non-secret values from the selected Environment's variables, and each
   workflow's fail-fast guard checks exactly the variables that workflow consumes, per
   [ADR 0057](adr/0057-multi-environment-and-branch-model.md). **Unified-only tenants omit
   `PURVIEW_ACCOUNT_NAME`** — no workflow guard requires it; it feeds only the classic
   reconcilers' `${env:PURVIEW_ACCOUNT_NAME}` tokens ([ADR 0023](adr/0023-identifier-resolution.md)
   Category 2), and per the [ADR 0048](adr/0048-purview-account-discovery-gate.md) outcome matrix
   the `purviewAccountName` surfaces keep the shipped placeholder on a confirmed-unified tenant.
   See [Getting started §2](getting-started.md) for the per-environment breakdown (including the
   `kv-unlock` Environment's own secret and variables).
4. In **Settings → Secrets and variables → Actions → Variables**, set the repository variable
   `OWNER_APPROVAL_LOGIN` to your GitHub login. Two workflows read it: the
   [`pr-auto-merge.yml`](../.github/workflows/pr-auto-merge.yml) workflow only enables auto-merge
   when the `owner-approved` label is applied by this login (if it is unset, auto-merge fails with a
   configuration error), and [`idea-intake-autoadd.yml`](../.github/workflows/idea-intake-autoadd.yml)
   only auto-adds the `needs-review` label to issues you open (if it is unset, that workflow warns
   and skips rather than failing). It is a repository variable (not environment-scoped) because
   those workflows run without an `environment:`. See
   [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

   **Required reviewers on private repos** need GitHub Pro/Team/Enterprise — see
   [Getting started §2](getting-started.md) for the interim posture on Free private repos.

> Never commit any of these values. They live only in GitHub secrets and in your local
> `az account set` context.

### Optional — add a second (`dev`) environment

The tailored repo runs single-environment (`lab`) with no further setup — every workflow defaults
there. If you want an independent `dev` environment (own OIDC credentials, Azure resources, and
configuration), follow [Getting started § Optional: add a `dev` environment](getting-started.md)
after this step: create the `dev` / `kv-unlock-dev` GitHub Environments, add the additional
federated-credential subjects, and copy `infra/main.bicepparam` / `infra/parameters/lab.yaml` to
their `dev` counterparts. Contract details in
[ADR 0057](adr/0057-multi-environment-and-branch-model.md).

## Step 6 — Validate locally

```bash
# Control plane compiles
az bicep build --file infra/main.bicep

# Unit tests (no live tenant required)
pwsh -File tests/Run-Pester.ps1
```

Both must pass before you deploy.

## Step 7 — First deploy

Run the workflows from the **Actions** tab (or follow [Getting started §4](getting-started.md)):

1. **`deploy-infra`** — provisions / reconciles the `Microsoft.Purview/accounts` resource and its
   dependencies. See [Microsoft.Purview/accounts (Bicep)](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts).
2. **The per-solution `deploy-<solution>` workflows** — each applies the desired-state content for
   exactly **one** data-plane surface under `data-plane/`, per
   [ADR 0051](adr/0051-per-solution-workflow-unit-of-data-plane-apply.md). Five exist today:
   [`deploy-labels`](../.github/workflows/deploy-labels.yml),
   [`deploy-label-policies`](../.github/workflows/deploy-label-policies.yml),
   [`deploy-auto-label-policies`](../.github/workflows/deploy-auto-label-policies.yml),
   [`deploy-dlp`](../.github/workflows/deploy-dlp.yml), and
   [`deploy-irm`](../.github/workflows/deploy-irm.yml).

   > **Every other data-plane surface has no automated apply path yet.** Collections, glossary,
   > classifications, data sources, scans, administrative units, Purview role groups, audit
   > retention, retention/DLM, records/file plan, IRM entity lists, and unified catalog are applied
   > by running their [`scripts/Deploy-*.ps1`](../scripts/) reconciler **locally** from your
   > workstation. This is the honest state of the repo, not an omission: backfilling the missing
   > per-solution workflows is tracked in
   > [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

After the first deploy, the ongoing per-feature lifecycle is agent-led
(`@idea-intake` → `@artifact-resolver` → `@owner-approval`); populate
[`docs/project-plan.md`](project-plan.md) as you adopt features.

## References

- **[Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)**
  Fetch date: 2026-06-21
  > "Securely authenticate to Azure services from GitHub Actions workflows using Azure Login action with OpenID Connect (OIDC)."
- **[Access control in the classic Microsoft Purview governance portal](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)**
  Fetch date: 2026-06-21
  > "The Microsoft Purview governance portal uses Collections in the Microsoft Purview Data Map to organize and manage access across its sources, assets, and other artifacts."
- [Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)
- [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files)
- [Microsoft.Purview/accounts (Bicep)](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts)
- [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes)
- [Getting started](getting-started.md) — detailed identity, secrets, and deploy walkthrough.
