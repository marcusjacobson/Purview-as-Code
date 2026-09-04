# Kickoff guide — stand up your own Purview-as-Code environment

This is the **opinionated, end-to-end walkthrough** for turning this template into a running
Purview-as-Code environment for *your* Microsoft Purview tenant. It orients you through the whole
journey and points to the detailed references at each step:

- [`docs/tenant-onboarding.md`](tenant-onboarding.md) — the exact step-by-step commands.
- [`docs/getting-started.md`](getting-started.md) — the detailed identity, secrets, and deploy setup.
- [`docs/architecture.md`](architecture.md) — the two-plane model and CI/CD flow.

If you just want the command checklist, go straight to the
[tenant onboarding guide](tenant-onboarding.md). Read on for the *why* behind each choice.

## Who this is for

You want your own version of this repository — managing one Microsoft Purview tenant as code —
without any risk of your content flowing back into the source template. This guide assumes you can
create an Entra app registration, deploy into an Azure resource group, and run VS Code with GitHub
Copilot Chat (the custom agents are a VS Code feature).

## The two planes (in one minute)

Microsoft Purview has no single "Purview-as-Code" product, so this repo manages two independent
planes — keep changes to one plane per pull request:

- **Control plane** — the `Microsoft.Purview/accounts` resource and its Azure dependencies, as
  Bicep under [`infra/`](../infra/). Deployed via Azure Resource Manager. See
  [Microsoft.Purview/accounts](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts).
- **Data plane** — sensitivity labels, DLP, lifecycle, DSPM, Data Map collections, glossary,
  classifications, sources, and scans, as YAML under [`data-plane/`](../data-plane/) rendered by
  PowerShell reconcilers in [`scripts/`](../scripts/). Deployed via the Purview data-plane APIs. See
  [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).

Full picture: [`docs/architecture.md`](architecture.md).

## The journey

### 1. Get a copy

**Recommended: click "Use this template" on GitHub.** A template-generated repository starts with a
clean history and *structurally cannot open a pull request back* to this source — the strongest form
of the no-push-back boundary. See
[Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template).

Prefer a local-only workspace instead? `git clone` it and pick the local-workspace mode in the next
step.

**Seed the automation labels.** "Use this template" does not copy labels, so the label-gated
automation (`owner-approved` auto-merge, `needs-review`, `destructive`, `squad:*` routing) starts
dormant — the first merge otherwise fails with `'owner-approved' not found`. Run the idempotent
seeder once with an authenticated `gh` that has push access:

```bash
pwsh ./scripts/New-RepoLabels.ps1
```

### 2. Decouple with the Kickoff agent

Open the copy in VS Code, start Copilot Chat, and run [`@operator-kickoff`](../.github/agents/operator-kickoff.agent.md).
It offers two modes and installs the **no-push-back guard**, then verifies it, per
[ADR 0045](adr/0045-template-kickoff-spinoff-model.md):

- **Local workspace** — removes the source `origin` and resets history for a clean break.
- **Spin-off GitHub repository** — your own repo (preferring "Use this template"); it resolves the
  true source via the GitHub template relationship, never your own `origin`.

If you used "Use this template", GitHub already decoupled you — the agent then installs only the
optional local `pre-push` backstop.

### 3. Tailor for your tenant

Run [`@operator-tenant`](../.github/agents/operator-tenant.agent.md). It interviews you one question
at a time and writes your values into [`infra/parameters/lab.yaml`](../infra/parameters/lab.yaml) and
the identity-boundary statements — **never** a secret or real subscription/tenant/object ID. Review
the diff and commit it on a branch.

### 4. Wire up identity and secrets

Authenticate GitHub Actions to Azure with a Microsoft Entra app + OIDC federated credential — no
stored client secret. Set the environment secrets (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`), the `PURVIEW_ACCOUNT_NAME` variable (classic accounts only — omit it on
a unified-only tenant per [ADR 0048](adr/0048-purview-account-discovery-gate.md)), and the
`OWNER_APPROVAL_LOGIN` repository variable (your GitHub login — both the auto-merge gate and the
idea-intake `needs-review` auto-add read it). Exact commands:
[Getting started §1–§2](getting-started.md). Grounding:
[Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect),
[Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables).

Grant the deploy identity least-privilege roles: **Contributor** on your resource group (control
plane) and the Microsoft Purview roles **Collection Admin**, **Data Curator**, and
**Data Source Administrator** at the root collection (data plane). See
[Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

### 5. Validate, then deploy

Run `az bicep build --file infra/main.bicep` and `pwsh -File tests/Run-Pester.ps1` locally; both must
pass. Then run the `deploy-infra` workflow, followed by the per-solution `deploy-<solution>` workflow
for each data-plane surface you have adopted (`deploy-labels`, `deploy-label-policies`,
`deploy-auto-label-policies`, `deploy-dlp`, `deploy-irm`). Surfaces without a per-solution workflow
have **no automated apply path yet** — run their `scripts/Deploy-*.ps1` reconciler locally
([ADR 0051](adr/0051-per-solution-workflow-unit-of-data-plane-apply.md); backfill tracked in
[#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80)). Exact steps:
[tenant onboarding §6–§7](tenant-onboarding.md) and [Getting started §4](getting-started.md).

### 6. Adopt features, one at a time

Your environment is now live but the feature roadmap ships empty. From here, all work is
**agent-led** and runs one item at a time:

`@idea-intake` → `@artifact-resolver` → `@owner-approval`

Populate [`docs/project-plan.md`](project-plan.md) as you bring each Microsoft Purview feature into
as-code governance. See [`.github/agents/README.md`](../.github/agents/README.md) for the full agent
index and [ADR 0014](adr/0014-agents-as-default-entry-point.md) for why the agents are the default
entry point.

## Guardrails you inherit

- **No push-back to the source template.** The kickoff guard (origin severance, disabled upstream
  push URL, `pre-push` hook, agent refusal) plus the template repository setting make it structurally
  hard for your copy to contribute content back. See [ADR 0045](adr/0045-template-kickoff-spinoff-model.md).
- **No secrets, no real identifiers in source.** Real tenant/subscription/object IDs and the owner
  login live in GitHub secrets/variables, never in committed files.
- **Least privilege and OIDC everywhere.** No long-lived client secrets in CI.

## Teardown / re-run

Rebuilding from scratch — to re-run the kickoff → tailor flow on a clean copy — means deleting the
spin-off repository first, and **that is a manual step in the GitHub UI**. The `gh` CLI and the
automation token used here are deliberately *not* granted the `delete_repo` OAuth scope (least
privilege), so `gh repo delete` fails with an insufficient-scope error by design — this is expected,
not a bug.

To tear down a **spin-off GitHub repository**:

1. Open the repository on GitHub → **Settings** → scroll to the **Danger Zone** at the bottom →
   **Delete this repository**, and complete the typed-confirmation prompt. See
   [Deleting a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/deleting-a-repository).
2. Re-create the copy from the template (step 1 of [The journey](#the-journey)), then re-run
   [`@operator-kickoff`](../.github/agents/operator-kickoff.agent.md) and
   [`@operator-tenant`](../.github/agents/operator-tenant.agent.md).

A **local-workspace** copy needs no GitHub deletion — delete the local folder and re-clone (or re-run
"Use this template").

## References

- **[Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)**
  Fetch date: 2026-07-03
  > "a repository created from a template starts with a single commit."
- **[Microsoft.Purview/accounts (Bicep/ARM)](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts)** — control-plane resource.
- **[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)** — data-plane auth.
- **[Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)** — least-privilege roles.
- **[Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)** — OIDC for CI/CD.
- [Tenant onboarding guide](tenant-onboarding.md) · [Getting started](getting-started.md) · [Architecture](architecture.md) · [ADR 0045](adr/0045-template-kickoff-spinoff-model.md)
