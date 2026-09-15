# 0057 — Multi-environment support: environment-input routing, the operator branch model, and per-environment configuration

- **Status:** Accepted
- **Date:** 2026-07-16
- **Gates:** Cross-cutting; no [`docs/project-plan.md`](../project-plan.md) §5 / §8 row. **Amends the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)** — this ADR is the "design PR first" that section demands before a second environment may exist; the single-environment rule is replaced by the two-environment contract below, and every identifier rule in that section is unchanged. **Extends [ADR 0010](0010-automation-identity-subject-model.md) without weakening it** — the single-federated-credential invariant stands; this ADR adds the per-environment subject set and the bounded repository-migration cutover ADR 0010 never documented. **Scopes [ADR 0056](0056-template-ships-empty-desired-state.md) to the branch it protects** — the empty-desired-state contract is enforced when validation targets `main`; an operator spin-off's `dev` / `lab` branches carry populated desired state by design. **Builds on [ADR 0012](0012-environment-parameters-file.md)** (`infra/parameters/<env>.yaml` stays the per-environment source of truth; this ADR adds the `PURVIEW_PARAMETERS_FILE` selection mechanism). Gates nothing else.
- **Deciders:** @marcusjacobson

## Context

This repository is a public, tenant-neutral template ([ADR 0045](0045-template-kickoff-spinoff-model.md)) that until now targeted exactly one deployment environment: a GitHub Environment named `lab`, holding all OIDC secrets and configuration, declared by every tenant-touching job so the federated-credential subject `repo:<org>/<repo>:environment:lab` matches at token-exchange time ([ADR 0010](0010-automation-identity-subject-model.md)).

The operator of the template runs a private downstream repository (`main` mirroring upstream, plus `dev` and `lab` working branches, with `lab` as the default branch so scheduled syncs run there) and needs a second, independently-credentialed environment — `dev` — without forking the workflow set. Three problems block that today:

1. **Routing.** Workflows hardcoded `environment: lab`, so every push, schedule, and dispatch minted a `lab`-subject OIDC token and read `lab`-scoped secrets. There was no way to aim a run at a second environment.
2. **Configuration literals.** Tenant-specific non-secret values (`kv-contoso-lab-01`, `contoso.onmicrosoft.com`, `rg-purview-lab`, the data-plane certificate name) sat as literals in workflow `env:` blocks, and every script defaulted its `-ParametersFile` to the shipped `infra/parameters/lab.yaml`. A second environment would have required editing 16 workflows and 32 scripts per environment — the antithesis of a template.
3. **Guard-test collision.** [ADR 0056](0056-template-ships-empty-desired-state.md)'s guard suites assert the shipped desired state is empty. That is a property of the *template* (and of the operator `main` that mirrors it) — an operator branch that legitimately adopts governance surfaces carries populated desired state and would fail `validate` on every push, so `validate` simply never ran on operator branches. Un-validated operator branches are worse than either alternative.

Per [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), a GitHub Environment carries its own secrets, variables, and deployment protection rules (including deployment branch policies), which makes it the natural unit of multi-tenancy for this repo: one Environment per target, one OIDC subject per Environment, zero shared credential material.

## Decision

### 1. Every tenant-touching workflow gains an `environment` dispatch input; push/schedule runs map branch → environment

We will give all 16 tenant-touching workflows (`deploy-infra`, `validate-oidc-auth`, `kv-temp-unlock`, the five per-solution `deploy-<solution>`, the five `sync-<solution>-from-tenant`, `drift-detection`, `export-content-explorer`, `code-currency-watch`) a `workflow_dispatch` input `environment` (choice `lab` | `dev`, default `lab`), and route non-dispatch runs by branch: `dev` → `dev`, **every other branch (including `main` and `lab`) → `lab`**. The canonical expression, byte-identical everywhere it appears:

```text
${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}
```

Per [Workflow syntax — `on.workflow_dispatch.inputs`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_dispatchinputs), `inputs.environment` is empty on non-dispatch events, so the `||` fallback carries the branch mapping. `main` → `lab` is deliberate backward compatibility: every existing single-environment spin-off deploys from `main` into `lab` today and must keep doing so with zero configuration changes. Dispatch-only workflows (`deploy-infra`, `validate-oidc-auth` — no push/schedule trigger, so `inputs` is always populated) may use the short form `${{ inputs.environment || 'lab' }}`.

Each job declares the selected GitHub Environment, so the OIDC subject stays `repo:<org>/<repo>:environment:<environment>` per [ADR 0010](0010-automation-identity-subject-model.md) and [Configuring OpenID Connect in Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect). Concurrency groups are environment-derived (`deploy-labels-<env>`, `kv-firewall-<env>`, …) with `cancel-in-progress: false` retained, so runs against different environments never queue behind each other and an in-flight apply always reaches its cleanup steps ([Workflow syntax — `concurrency`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency)).

The contract is pinned by [`tests/workflows/EnvironmentRouting.Tests.ps1`](../../tests/workflows/EnvironmentRouting.Tests.ps1), which reads the shipped workflow files and asserts the dispatch input, the byte-identical expressions, the concurrency shapes, and the absence of functional tenant literals.

### 2. Key Vault unlock pairs independently: `lab` → `kv-unlock`, `dev` → `kv-unlock-dev`

`kv-temp-unlock.yml` does not declare the deployment environment itself — it declares the *paired unlock* Environment (`${{ inputs.environment == 'dev' && 'kv-unlock-dev' || 'kv-unlock' }}`) on **both** of its jobs, because deployment protection rules are evaluated per job and the kv-unlock app's federated subject is `repo:<org>/<repo>:environment:<kv-unlock environment>`. Each unlock Environment carries its own approval rules, `AZURE_CLIENT_ID_KV_UNLOCK` secret, and `PURVIEW_RG` / `KEY_VAULT_NAME` variables, so approving a `dev` vault unlock never exposes the `lab` vault and vice versa.

### 3. Tenant-specific non-secret values move to Environment variables; IDs stay in Environment secrets

We will source every tenant-specific non-secret literal from the selected Environment's variables, with fail-fast guards when unset: `PURVIEW_RG`, `TENANT_DOMAIN`, `DATA_PLANE_CERT_NAME` join the existing `KEY_VAULT_NAME` and `PURVIEW_ACCOUNT_NAME`. Tenant / subscription / client IDs remain Environment **secrets** (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID*`) per the identifier rules in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — they are reconnaissance-grade and stay out of logs; the variables above are non-secret configuration that may legitimately appear in run output. Reference: [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables) and [Environment secrets](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#environment-secrets).

This retires the `.github/workflows/**` entry in [`.github/agents/tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml) as a *tailoring* surface — there is no functional literal left to replace — while its `functionalWorkflowScan` stays as the regression guard proving that stays true.

### 4. Per-environment configuration files: copy the lab files; the template ships no `dev` scaffolds

- **Control plane:** `deploy-infra.yml` selects `infra/main.<environment>.bicepparam` for any non-`lab` environment and fails fast if it is missing; `lab` uses the shipped [`infra/main.bicepparam`](../../infra/main.bicepparam). Reference: [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files).
- **Data plane / scripts:** workflows set `PURVIEW_PARAMETERS_FILE: infra/parameters/<environment>.yaml`. Every script that defaults `-ParametersFile` honors `$env:PURVIEW_PARAMETERS_FILE` when the parameter is omitted, falling back to the shipped [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml) ([ADR 0012](0012-environment-parameters-file.md)). An explicit `-ParametersFile` argument always wins.

An operator adds an environment by **copying the lab files** (`infra/main.bicepparam` → `infra/main.dev.bicepparam`, `infra/parameters/lab.yaml` → `infra/parameters/dev.yaml`) and editing the copies. The template deliberately ships **no** `dev` scaffolds: a shipped `dev.yaml` would be one more file of placeholder values to tailor, drift, and scan — the lab files are already the worked example, and the fail-fast guards turn a missing copy into an explicit error instead of a silent lab-shaped deploy.

### 5. Drift-back branches and PR bases are environment-suffixed

Sync and drift workflows write to `auto/<surface>-drift-<env>` branches, and the drift PR `base` follows `github.ref_name` (the branch whose schedule/push produced the run), so drift detected on an operator's `lab` branch returns to `lab` and drift on `dev` returns to `dev`. Without the suffix, a `dev` drift run and a `lab` drift run would fight over one branch; without the dynamic base, operator drift would PR against the upstream-mirror `main` it did not come from.

### 6. The custom role name is parameterized; renaming mints a NEW role definition

[`infra/modules/role-definitions.bicep`](../../infra/modules/role-definitions.bicep) gains `param kvFirewallTogglerRoleName string = 'Purview-Lab-KV-Firewall-Toggler'` (passed through from [`infra/main.bicep`](../../infra/main.bicep), same default). The default preserves existing deployments byte-for-byte. Because the deterministic role-definition GUID is seeded as `guid(subscription().id, <name>)` ([Microsoft.Authorization/roleDefinitions](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roledefinitions)), **overriding the name does not rename the existing role — it creates a second role definition**. The migration is therefore explicit, never silent:

1. Deploy with the new `kvFirewallTogglerRoleName` value in `infra/main.<environment>.bicepparam` (and the matching `automation.kvFirewallTogglerRoleName` in `infra/parameters/<environment>.yaml`) — this creates the new role definition alongside the old one.
2. Re-run [`scripts/New-KvUnlockRbac.ps1`](../../scripts/New-KvUnlockRbac.ps1) so the kv-unlock service principal holds an assignment of the **new** role at the vault scope. The script resolves the role name from `automation.kvFirewallTogglerRoleName` in the parameters file (or `-RoleName`), not from a hardcoded literal — step 1 and step 2 must agree on the same name.
3. Verify with a `kv-temp-unlock` dispatch (the pre-unlock state guard plus open/re-lock cycle exercises the assignment end to end).
4. Delete the old role definition (`az role definition delete`) only after step 3 passes. Until then both definitions coexist harmlessly — a role definition grants nothing without an assignment.

### 7. ADR 0010's single-federated-credential invariant, with a bounded repository-migration cutover

Per-environment subjects are new federated credentials on **different Environments**, not a relaxation of ADR 0010: each app still carries exactly one credential per subject, and adding `dev` means adding the subject `repo:<org>/<repo>:environment:dev` (and `…:environment:kv-unlock-dev` on the kv-unlock app) via [`az ad app federated-credential create`](https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential) per [Configure an app to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust).

What ADR 0010 never documented is how to move an app between **repositories** (for example, from the public template to the operator's private downstream repo) when the subject embeds `repo:<org>/<repo>`. The invariant "any second credential is an anomaly" would seem to forbid the only safe path. The ruling is a **bounded cutover, inside one change window**:

1. Add a second federated credential for the new repository's subject (`repo:<new-org>/<new-repo>:environment:<env>`). Federated-credential **names** are unique per app — during overlap the new credential may use a non-canonical name (for example `gh-env-lab-ops`) if the canonical `gh-env-<env>` name is still held by the old credential.
2. From the **new** repository, dispatch `validate-oidc-auth.yml` for the environment and confirm token exchange succeeds.
3. Remove the old repository's credential — **within the same change window**. The app ends the window with exactly one credential per environment subject, same as it started.
4. **Canonicalize the credential name (if step 1 used a non-canonical name):** delete the surviving credential and re-run [`scripts/New-AutomationEntraApp.ps1`](../../scripts/New-AutomationEntraApp.ps1) (and [`scripts/New-KvUnlockEntraApp.ps1`](../../scripts/New-KvUnlockEntraApp.ps1) for the kv-unlock app) so the script recreates it under the canonical `gh-env-<env>` / `gh-env-kv-unlock` name. Until then, the provisioning scripts **accept** a credential whose name differs from canonical when issuer, subject, and audiences already match — they emit a warning rather than failing. Only issuer/subject/audiences are security-critical; the name is advisory.

During steps 1–3, [`scripts/New-AutomationEntraApp.ps1`](../../scripts/New-AutomationEntraApp.ps1) **intentionally keeps failing** on the >1-credential state. That is not a defect to be patched: the failure is ADR 0010's credential-addition anomaly detection working exactly as designed, and the operator performing the cutover is the one actor who knows the second credential is expected. The script is not taught to tolerate two credentials, no `-AllowSecondCredential` switch exists, and any >1-credential state observed **outside** a declared cutover window remains an incident signal, not a migration in progress.

### 9. Upstream merges into operator repositories preserve shared history

Operator downstream repositories (ADR 0057 §8) mirror upstream `main` and must stay merge-compatible. **Squash-merging upstream PRs that carry multi-environment support breaks the shared-history contract** that makes `git merge upstream/main` a clean fast-forward: the operator repo fast-forwards onto individual upstream commits during bootstrap, and a later upstream squash produces divergent-but-content-identical histories (merges auto-resolve, but every future sync carries noise).

**Ruling:** upstream changes that establish or extend the multi-environment contract (including PRs like #123) should land on public `main` via **merge commit or rebase merge**, not squash merge, when operator repos are known consumers. Operator sync procedures should prefer `git merge --ff-only upstream/main` after upstream merges; if upstream used squash and histories diverged, `git merge upstream/main` still resolves content but operators should expect a merge commit. Document this in the operator runbook alongside the branch model in §8.


**Extended 2026-09-07 — the same ruling governs `dev` → `lab` promotions.** A promotion is the
identical shape one level down: `lab` mirrors `dev` for everything outside the per-tenant
`data-plane/**` files, and must stay merge-compatible with it. Squash-merging a promotion gives
`lab` the **content** of dev's commits but not their **ancestry**, so
`git merge-base --is-ancestor origin/dev origin/lab` stays false and
`git log origin/lab..origin/dev` reports every already-promoted commit as outstanding, forever.

Measured directly after a squashed promotion on 2026-09-07: git reported **12 unpromoted commits**
where the only real difference outside `data-plane/**` was a single regenerated `docs-regen`
timestamp. The practical cost is not cosmetic — with the ancestry broken, a promotion can no longer
be a plain `git merge origin/dev` (which would conflict only on the per-tenant files, exactly where
a deliberate decision is wanted). It degrades into abort-verify-cherry-pick, done three times that
day, and that manual reconstruction is precisely where a file gets missed.

**Ruling:** `dev` → `lab` promotion PRs land as a **merge commit**, never squashed.
[`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) selects this automatically from the
`promote/` branch prefix — deliberately *not* from the `merge-commit` label, because a rule that
depends on remembering to apply a label is a rule that gets forgotten. The label remains the opt-in
for any other shared-history PR. Feature PRs stay squashed: one tidy commit each is right for them,
and they carry no downstream mirror.
### 8. The operator branch model; `validate` runs on `main`, `dev`, and `lab`; ADR 0056 is enforced for `main`

The downstream operator repository uses: `main` (upstream mirror — empty desired state, template-shaped), `dev` and `lab` (operator branches — populated desired state), with `lab` as the default branch so scheduled workflows run there. Deployment branch policies on each Environment pin `lab` → branch `lab` and `dev` → branch `dev` ([Deployment branch policies](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#deployment-branches-and-tags)), so even a mis-routed expression cannot deploy a branch into the wrong environment — the Environment refuses the deployment before a token is minted.

[`validate.yml`](../../.github/workflows/validate.yml) triggers widen to `branches: [main, dev, lab]` on both `pull_request` and `push`. The [`tests/data-plane/ShippedDesiredState.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.Tests.ps1) and [`ShippedDesiredState.NoOp.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.NoOp.Tests.ps1) suites become branch-aware: the **emptiness** assertions (empty root lists, shipped `mode: Enable`, the CLAIM 1 no-op proofs) run when the target branch is `main` (`GITHUB_BASE_REF` on `pull_request`, `GITHUB_REF_NAME` on `push`, the checked-out branch locally — [Default environment variables](https://docs.github.com/en/actions/reference/workflows-and-actions/variables#default-environment-variables)) and **skip with a printed message on `dev` / `lab` only** — any other branch (template feature branches included) enforces, so the guard cannot be dodged by working on a topic branch. Every "every copy, forever" assertion (parse integrity, carve-out pins, no raw principal GUIDs, `examples/**` is inert) runs on all branches of every copy. ADR 0056 is not weakened for the template: `main` — the only branch a template consumer receives — is guarded exactly as before.

## Consequences

**Easier.**

- One workflow set serves N environments. Adding a third environment is: create the GitHub Environment (+ paired `kv-unlock-<env>` if it needs vault unlocks), add its federated-credential subjects, copy the two lab config files, extend the `environment` input options — no workflow-logic edits.
- Operator branches get CI. `dev` and `lab` pushes now run all ten validate gates; before this ADR they ran none.
- Tailoring shrinks. The `.github/workflows/**` tenant-surface entry is retired; the kickoff flow no longer walks workflow files.
- Isolation is enforced twice: the environment-derived OIDC subject (Entra side) and the deployment branch policy (GitHub side) must both agree before a token exists — the two-layer guard of ADR 0010 §3, now per environment.

**Harder.**

- Two more GitHub Environments (`dev`, `kv-unlock-dev`) and their secrets/variables to provision for multi-env operators (single-env consumers configure nothing new — every default routes to `lab`).
- The byte-identical expression contract must be maintained by hand in 16 files; that is exactly why `EnvironmentRouting.Tests.ps1` pins it.
- The role-name migration (Decision 6) is a four-step manual procedure — the price of a deterministic GUID seed, paid only by operators who choose to de-lab the role name.

**Security posture.** Upholds [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #1 (no secrets in source — literals moved to vars, IDs stay in secrets), rule #3 (OIDC-only, per-environment subjects), rule #4 (least privilege — per-environment credential isolation; the kv-unlock pairing keeps vault-unlock approval separate per environment), and rule #9 (auditable — every environment's deploys carry its own Environment approval trail). The bounded cutover in Decision 7 preserves ADR 0010's anomaly-detection invariant rather than relaxing it.

## Alternatives considered

- **Do nothing (single `lab` environment).** Rejected — the operator's downstream repo needs `dev` today, and hand-forking 16 workflows per environment guarantees drift between the copies.
- **One workflow file per environment (`deploy-labels-dev.yml`, …).** Rejected — doubles the workflow count per environment, and every fix must land N times. The dispatch-input + branch-mapping contract keeps one file authoritative.
- **A matrix strategy over environments.** Rejected — a matrix runs *both* environments per trigger; the requirement is selecting *one*. Matrix jobs also cannot vary `environment:` protection rules meaningfully per leg without the same expression this ADR standardizes.
- **Branch-only routing (no dispatch input).** Rejected — the template's consumers deploy from `main`; without an input there is no way to aim a manual run at `dev` from `main`, and emergency operations (kv-temp-unlock) must be dispatchable at either environment from wherever the operator stands.
- **Tolerating >1 federated credential in `New-AutomationEntraApp.ps1` to smooth migrations.** Rejected — that trades a permanent anomaly-detection control for a convenience used once per repository move. The bounded cutover keeps the control and documents the exception window instead.

## Citations

- [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) — Environment secrets, variables, deployment branch policies, protection rules.
- [Workflow syntax for GitHub Actions — `on.workflow_dispatch.inputs`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onworkflow_dispatchinputs) — dispatch input semantics; empty on non-dispatch events.
- [Workflow syntax for GitHub Actions — `concurrency`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#concurrency) — group expressions and `cancel-in-progress`.
- [Default environment variables](https://docs.github.com/en/actions/reference/workflows-and-actions/variables#default-environment-variables) — `GITHUB_BASE_REF` / `GITHUB_REF_NAME` used by the branch-aware guard tests.
- [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables) — Environment variables for non-secret configuration.
- [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — the GitHub Actions → Azure OIDC pattern.
- [Configure an app to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust) — federated-credential objects and subjects.
- [az ad app federated-credential](https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential) — the cutover commands in Decision 7.
- [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files) — `main.<environment>.bicepparam` selection.
- [Microsoft.Authorization/roleDefinitions](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roledefinitions) — the GUID-named role-definition contract behind Decision 6.
- [ADR 0010](0010-automation-identity-subject-model.md), [ADR 0012](0012-environment-parameters-file.md), [ADR 0045](0045-template-kickoff-spinoff-model.md), [ADR 0046](0046-tenant-placeholder-manifest.md), [ADR 0056](0056-template-ships-empty-desired-state.md) — the decisions this ADR extends, builds on, and scopes.
