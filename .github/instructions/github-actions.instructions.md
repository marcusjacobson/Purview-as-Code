---
description: "Secure-by-design rules for GitHub Actions workflows in this repository."
applyTo: ".github/workflows/**/*.yml,.github/workflows/**/*.yaml"
---

# GitHub Actions secure-by-design rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md), including the **Microsoft Learn is the central source of truth** rule.

## Grounding — Workflows must be verified against Microsoft Learn

Before adding or modifying any step, action, or authentication block:

- Verify Azure authentication patterns against [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) and [Configure a federated identity credential](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust).
- Verify Azure CLI / Azure PowerShell steps (`azure/cli@v2`, `azure/powershell@v2`) against the same Learn page and the action's official README under [`github.com/Azure/*`](https://github.com/Azure).
- Verify Bicep deploy steps against [Deploy Bicep files with GitHub Actions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-github-actions).
- GitHub-side security controls (`permissions:`, environment secrets, OIDC hardening) must match [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions) (accepted as authoritative for GitHub-native behaviour) combined with the Microsoft Learn guidance above for the Azure side.
- Every workflow must link, in its header comment, to the Learn page that authorises its auth pattern.
- If a step pattern is not documented on Learn or the official action README, do not silently emit it. Cite the gap and flag `# TODO: not-on-Learn` for human review.

## Authentication to Azure

- Use `azure/login@v2` with OIDC only. Required inputs: `client-id`, `tenant-id`, `subscription-id` from GitHub Secrets. Never use `creds:` (JSON blob with a secret) or a publish-profile. Source: [Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
- The job requires `permissions: id-token: write` to mint the OIDC token. `contents: read` is usually enough for the rest. Do not grant `write` or `admin` scopes that the job does not need.
- The federated credential on the Entra app / UAMI must be scoped to a specific `repo:owner/name:ref:refs/heads/...` or `:environment:<name>` subject — never `repo:*`.

## Secrets handling

- Store `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` in **environment** secrets (not repo secrets) so the `lab` / `dev` environment gates apply per [ADR 0057](../../docs/adr/0057-multi-environment-and-branch-model.md). Source: [GitHub — environment secrets](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#environment-secrets).
- Never `echo` a secret. Never write a secret to a step output, to an artifact, to a log, or to `$GITHUB_ENV` / `$GITHUB_OUTPUT`. GitHub redacts exact matches, not derived values.
- Do not pass secrets as CLI positional arguments where they land in the process table. Prefer env vars.

## Environments and approvals

- Deployments target one of the two ADR 0057 GitHub Environments — `lab` (default) or `dev` — selected by the `environment` dispatch input with the canonical branch mapping `${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}` (branch `dev` → `dev`, every other branch → `lab`). Keep the expression byte-identical across workflows; [`tests/workflows/EnvironmentRouting.Tests.ps1`](../../tests/workflows/EnvironmentRouting.Tests.ps1) pins it. See [ADR 0057](../../docs/adr/0057-multi-environment-and-branch-model.md).
- Every deploying workflow must declare `environment:` derived from that expression: `deploy-infra` on the control plane, and each per-solution `deploy-<solution>` workflow on the data plane ([ADR 0051](../../docs/adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)). Dispatch-only workflows (no push/schedule trigger) may use `${{ inputs.environment || 'lab' }}`. `kv-temp-unlock.yml` declares the paired unlock Environment (`lab` → `kv-unlock`, `dev` → `kv-unlock-dev`) on both of its jobs.
- Environment protection rules (required reviewers, deployment branch policies pinning `lab` → branch `lab`, `dev` → branch `dev` in an operator repo) are the only gate between a merged PR and a control-plane change.
- Tenant-specific non-secret configuration comes from the selected Environment's **variables** (`PURVIEW_RG`, `TENANT_DOMAIN`, `DATA_PLANE_CERT_NAME`, `KEY_VAULT_NAME`, `PURVIEW_ACCOUNT_NAME`); never as workflow literals. IDs stay in Environment secrets. **Each workflow's fail-fast guard checks exactly the variables that workflow consumes** — no guard demands a variable the workflow never reads. `PURVIEW_ACCOUNT_NAME` in particular is consumed by no workflow guard today: it reaches the classic reconcilers only through `${env:PURVIEW_ACCOUNT_NAME}` tokens resolved by [`scripts/Resolve-EnvTokens.ps1`](../../scripts/Resolve-EnvTokens.ps1) (ADR 0023 Category 2, named unset-token error), and unified-only tenants omit it entirely per [ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md). Reconcilers receive the per-environment parameters file via `PURVIEW_PARAMETERS_FILE: infra/parameters/<environment>.yaml`.

## Action supply chain

- Pin every third-party action to a full-length commit SHA. Official `azure/*`, `actions/*`, and `github/*` actions may be pinned to a major tag (`@v2`, `@v4`) provided the tag is the current recommended one.
- Never use `uses: actions/checkout@master` or any floating branch reference.
- Audit new actions against [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions) before introducing them.

## Input and injection

- Do not interpolate `${{ github.event.* }}` or any attacker-controlled context directly into a `run:` script. Pass through `env:` and reference `$VAR` in the shell so the substitution happens after the shell quoting boundary. Source: [Understanding the risk of script injections](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections).
- Workflows triggered by `pull_request_target`, `issue_comment`, `workflow_run` need extra scrutiny; default to `pull_request` unless you have a documented reason.

## Permissions

- Every workflow must declare top-level `permissions:` with the least scopes required. Start from `permissions: {}` and add only what is needed.
- Never grant `permissions: write-all`.

## What-if before apply

- Any job that runs `az deployment group create` must first run `az deployment group what-if` and surface its output. The two steps live in the same job so a reviewer sees the plan adjacent to the apply.

## Companion workflows for `Deploy-*.ps1` reconcilers

Every `scripts/Deploy-<Domain>.ps1` that conforms to the full-circle reconciler contract in [`powershell.instructions.md`](powershell.instructions.md#required-switches-on-every-deploy-ps1) must ship with two paired workflows so the YAML-as-source-of-truth invariant survives operator edits in the portal:

- **`.github/workflows/sync-<domain>-from-tenant.yml`** — scheduled (typically daily) plus `workflow_dispatch`. Runs `Deploy-<Domain>.ps1 -ExportCurrentState`, then if `git diff` is non-empty, opens a pull request with the re-exported YAML so a reviewer can decide whether to accept the drift back into source. Reference implementation: [`sync-labels-from-tenant.yml`](../workflows/sync-labels-from-tenant.yml) (PR [#149](https://github.com/contoso/Purview-as-Code-Generic/pull/149)).
- **`.github/workflows/deploy-<domain>.yml`** — triggered on PR-merge to `main` for paths under the matching `data-plane/**` folder. Runs `Deploy-<Domain>.ps1 -WhatIf` first, posts the plan-table to the job summary, then runs the apply. Before the apply step, it must include a **pre-write conflict guard** — `git fetch origin main && git diff HEAD origin/main -- <paths>` exits non-zero if the live `main` has moved past the merge commit, so a stale runner cannot overwrite a newer source-of-truth. Reference implementation: [`deploy-labels.yml`](../workflows/deploy-labels.yml) (PR [#144](https://github.com/contoso/Purview-as-Code-Generic/pull/144)).

A new `Deploy-*.ps1` script that does not ship with both companion workflows in the same PR is rejected by review.

### Direction-policy contract (ADR 0029)

Every `.github/workflows/deploy-<domain>.yml` MUST implement the source-of-truth direction policy defined in [ADR 0029](../../docs/adr/0029-source-of-truth-direction-policy.md). Reference implementation: [`deploy-labels.yml`](../workflows/deploy-labels.yml) (PR [#460](https://github.com/contoso/Purview-as-Code-Generic/pull/460); contract proven by 5 acceptance scenarios on `contoso.onmicrosoft.com`, see issue [#459](https://github.com/contoso/Purview-as-Code-Generic/issues/459)). New `deploy-<domain>.yml` workflows copy from that file rather than re-deriving the pattern.

Required surface:

- **`workflow_dispatch` inputs.** Expose `direction_policy` (choice `[audit, portal-wins, repo-wins]`, default `portal-wins`) and `confirm_overwrite` (string, default `''`). Both inputs are flowed through `env:` at job scope so `${{ github.event.inputs.* }}` substitution stays outside the `run:` shell-quoting boundary per [GitHub Docs — script-injection hardening](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections).
- **Pre-flight `Validate dispatch inputs` step.** Fails fast on `direction_policy=repo-wins && confirm_overwrite != 'overwrite portal'` using a case-sensitive `-cne` comparison. Runs **before** Azure login, **before** any Key Vault unlock window, and **before** any data-plane call. Mirrors the existing `confirm_prune` ceremony.
- **Two-pass execution for `portal-wins`.** First pass invokes the script with `-DirectionPolicy portal-wins -WhatIf` and parses `[ADR0029-SKIP] <displayName>` markers from the run log (`Tee-Object` + `Select-String -Pattern '^\[ADR0029-SKIP\] (.+)$' -CaseSensitive`). Second pass re-invokes with `-DirectionPolicy portal-wins -SkipNames @(...)` so the apply pass's skip decisions match the enumerate pass exactly. The `-WhatIf` path is required because `-DirectionPolicy audit` short-circuits before the policy pass and never emits SKIP markers.
- **Symmetry pass for `audit` / `repo-wins`.** Run a read-only `-DirectionPolicy audit` pass before any `repo-wins` apply so the plan table appears in the run log before destructive writes fire.
- **Auto-PR step for `portal-wins` skips.** When `direction_policy=portal-wins` and the enumerate pass produced ≥1 SKIP marker, re-export tenant state and open (or refresh) a drift-back PR on a `auto/<domain>-portal-wins-drift` branch. Reuse the `peter-evans/create-pull-request` pin already in use by the companion `sync-<domain>-from-tenant.yml` workflow (verbatim SHA — do not bump the version unilaterally). PR labels: `needs-review`, `squad:automation-engineer`.
- **Least-privilege job split.** The Azure-OIDC-holding job declares `permissions: id-token: write, contents: read` only — it cannot push branches or open PRs. The PR-opening job declares `permissions: contents: write, pull-requests: write` only — it holds no Azure surface. The two jobs communicate via an `actions/upload-artifact@v4` → `actions/download-artifact@v4` handoff carrying the re-exported (and `-RedactIdentities`) YAML, with `retention-days: 1`. Workflow-scope `permissions: {}` deny-by-default.
- **`push` trigger uses defaults.** A `push` to `main` runs with `direction_policy=portal-wins` and `prune_missing=false` so the merge-to-main path never overwrites a portal edit and never deletes a tenant object.

The reconciler script side of this contract lives in [`powershell.instructions.md`](powershell.instructions.md#direction-policy-contract-adr-0029).

#### Tier-3 (export-incapable) surfaces

The two-pass enumerate + auto-PR drift-back requirements above assume the reconciler is **export-capable** — it exposes `-ExportCurrentState` so tenant state can be round-tripped back into `data-plane/**` YAML as a re-export PR. That assumption does not hold for **Tier-3** surfaces whose underlying cmdlet family has no bulk-export or publish-status equivalent (for example, the `*-InsiderRiskPolicy` family behind [`Deploy-IRMPolicies.ps1`](../workflows/deploy-irm.yml), which exposes **no** `-ExportCurrentState` and **no** `-VerifyPublished` and is on the full-circle reconciler-contract-guard exempt list in [`validate.yml`](../workflows/validate.yml)).

For a Tier-3 forward `deploy-<domain>.yml`, apply the following carve-out. Reference implementation: [`deploy-irm.yml`](../workflows/deploy-irm.yml) (proven end-to-end on `contoso.onmicrosoft.com`; forward twin of the issue-based reverse companion [`sync-irm-from-tenant.yml`](../workflows/sync-irm-from-tenant.yml)).

- **Single apply pass, no enumerate.** The skip list is the **static** ADR-baseline set (e.g. the [ADR 0036](../../docs/adr/0036-irm-tenant-setting-immovable.md) IRM baseline), not a drift-derived set, so there is nothing to enumerate. Invoke the reconciler once with `-DirectionPolicy <mode> -SkipNames @(...)`. There is **no** `-WhatIf` enumerate pass and **no** `[ADR0029-SKIP]` marker parsing.
- **No auto-PR drift-back job.** A Tier-3 reconciler cannot re-export, so there is no YAML to regenerate and no drift-back PR to open. Reverse drift is surfaced as a GitHub **issue** by the companion `sync-<domain>-from-tenant.yml`, not a PR. The workflow therefore holds **no** `contents: write` and **no** `pull-requests` scope.
- **No Verify-Published step.** Same omission already accepted for `deploy-dlp.yml` (DLP has no `-VerifyPublished` switch). The apply pass is the terminal write step.
- **Single apply job.** No least-privilege job split is required because there is no PR-opening job; the one `apply` job declares `id-token: write` + `contents: read` only, under workflow-scope `permissions: {}`.

Everything else in the ADR 0029 contract still applies to Tier-3 workflows: the `workflow_dispatch` inputs (`<domain>_direction_policy`, `confirm_overwrite_<domain>`, `skip_names_<domain>`), the pre-flight typed-confirmation gate for `repo-wins`, read-only `audit` mode, the `push`-uses-defaults behavior, `concurrency`, and the Key Vault temp-open/restore window.

## Concurrency

- Deploy workflows set `concurrency:` with an **environment-derived** group (`deploy-<surface>-${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}`, or the shared `kv-firewall-<env>` group for vault-toggling workflows) and `cancel-in-progress: false`, so two merges cannot race on the same Purview account while runs against different environments never queue behind each other (ADR 0057).

## Runner hygiene

- Use `runs-on: ubuntu-latest` or a pinned version. Do not invoke self-hosted runners in this repo without a documented justification and an isolated runner label.

## Pre-commit checklist — `.github/workflows/**` changes

Run before opening a PR that touches `.github/workflows/**`. See [`pre-commit.instructions.md`](pre-commit.instructions.md) for the cross-cutting checklist that applies to every PR.

- [ ] All new actions are pinned to a full-length commit SHA (official `azure/*`, `actions/*`, `github/*` may use major tags)
- [ ] Job declares least-privilege top-level `permissions:` (`id-token: write` + `contents: read` is the usual baseline for Azure OIDC jobs)
- [ ] Any new deploy job runs `what-if` or `-WhatIf` before the corresponding apply step
- [ ] If the PR introduces a new `Deploy-*.ps1` reconciler, the matching `sync-<domain>-from-tenant.yml` and `deploy-<domain>.yml` ship in the same PR, and the apply job carries the pre-write conflict guard
- [ ] No secret is emitted to logs, `$GITHUB_OUTPUT`, or artifacts
