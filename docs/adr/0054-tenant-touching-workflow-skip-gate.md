# 0054 — Un-onboarded copies SKIP tenant-touching workflows; they never FAIL

- **Status:** Accepted
- **Date:** 2026-07-17
- **Gates:** Cross-cutting; no [`project-plan.md`](../project-plan.md) §5 / §8 row. Extends [ADR 0045](0045-template-kickoff-spinoff-model.md) — a template-kickoff copy with no tenant onboarded yet is a normal, expected state, and this ADR names the runtime behavior ADR 0045 never specified for it. Builds on [ADR 0057](0057-multi-environment-and-branch-model.md) — the `preflight` job binds the SAME canonical `environment:` expression as the tenant-touching job it gates, so the onboarding signal it tests is scoped to whichever environment (`lab` or `dev`) a given run actually targets. Governs all 13 workflows named in [#91](https://github.com/marcusjacobson/Purview-as-Code/issues/91); this PR pilots the mechanism on **`drift-detection.yml` only** — see "Ship shape" below. The remaining 12 are rollout scope for the follow-up PR that closes #91.
- **Deciders:** marcusjacobson

## Context

This repository is a **tenant-neutral template** ([ADR 0045](0045-template-kickoff-spinoff-model.md)). A freshly cloned or template-spawned copy carries an empty `lab` GitHub Environment — zero secrets, zero variables — **by design**. That is correct and must not be "fixed" by shipping lab-shaped secrets.

The defect is that 13 tenant-touching workflows carry automatic triggers (`schedule` and/or `push`) and unconditionally assume the environment is configured. On an un-onboarded copy they fire on schedule or on push and can never succeed — verified run history: 84 runs, 84 failures, 0 successes, every one dying at `azure/login (OIDC)` with `Not all values are present. Ensure 'client-id' and 'tenant-id' are supplied`, because `secrets.AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` and `vars.KEY_VAULT_NAME` all interpolate to the empty string.

`drift-detection.yml` additionally carries a **misplaced** guard: a `KEY_VAULT_NAME` check that **throws** (hard fail) at step 5 ("Temporarily allow Key Vault public access") — sitting unreachable behind the `azure/login` failure that already kills the run at step 3, and using the wrong verb (a template repo running its own scheduled workflow should not look like an incident).

The precedent for the right verb already exists in-repo: [`.github/workflows/idea-intake-autoadd.yml`](../../.github/workflows/idea-intake-autoadd.yml) checks `OWNER_APPROVAL_LOGIN` and **warns and skips** rather than failing, because it fires on every issue open and a hard failure would litter the timeline. This ADR generalizes that pattern to tenant-touching workflows: **on an un-onboarded copy, SKIP — never FAIL.**

### Docs research (fetched 2026-07-13, re-verified live 2026-07-17)

From the GitHub Actions [context availability table](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability) (re-fetched from the `github/docs` source, `content/actions/reference/workflows-and-actions/contexts.md`, 2026-07-17 — table unchanged since the issue's original research):

| Workflow key | Contexts available |
|---|---|
| `jobs.<job_id>.if` | `github, needs, vars, inputs` |
| `jobs.<job_id>.steps.if` | `github, needs, strategy, matrix, job, runner, env, vars, steps, inputs` |
| `jobs.<job_id>.env` | `github, needs, strategy, matrix, vars, secrets, inputs` |
| `jobs.<job_id>.environment` | `github, needs, strategy, matrix, vars, inputs` |

Three consequences drive the design, unchanged from the issue's research:

1. **`secrets` is not available in a job-level `if:` nor a step-level `if:`.** It is only available in `env` / `run` / `with` (and a handful of other non-`if` keys). No gate can test a secret directly in *any* `if:`; the secret must first be mapped into `env:`.
2. **`vars` is available in a job-level `if:`** — and *repository-level* vars unambiguously resolve there.
3. **Environment-scoped `vars` in a job-level `if:` is not settled by this table.** `jobs.<job_id>.environment` itself only sees `vars` (not the environment's own vars, which do not exist yet at that evaluation point) — a chicken-and-egg that is at minimum suggestive that a job's *own* environment-scoped vars are not yet bound when its `if:` is evaluated, since environment binding and `if:` evaluation order is not specified by this table alone. [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) (re-fetched 2026-07-17, `github/docs` source `content/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments.md`) states environment secrets "are only available to workflow jobs that use the environment" and that a job "can only access these secrets after any configured rules (for example, required reviewers) pass" — i.e., after binding. **This remains suggestive, not dispositive, and is not re-litigated by this ADR** — approach (c) below sidesteps the question entirely rather than resolving it.

Also unchanged: an unset configuration variable resolves to an empty string in any context that can read it ([Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables), re-fetched 2026-07-17) — which is exactly why the pre-fix workflows interpolate empties and die at `azure/login` instead of failing fast with a named cause.

### New research for this ADR — does GitHub batch approval across two jobs bound to the same environment in one run?

The design below adds a **second** job (`preflight`) that binds the same GitHub Environment as the existing tenant-touching job, in the same workflow run, with `needs:` making them sequential. Because a downstream operator repository already runs this workflow against a real, secret-bearing `lab` environment, the operator-compatibility question is: **if that environment ever gains a required-reviewers protection rule, does doubling the environment binding double the number of manual approvals per run?**

Re-fetched 2026-07-17 from the `github/docs` sources for [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), [Reviewing deployments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments), [Controlling deployments in GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments), and the [Deployments and environments reference](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments):

- "Deployment protection rules require specific conditions to pass before **a job** referencing the environment can proceed." (`deployments-and-environments.md`)
- "If the environment requires approval, **a job** cannot access environment secrets until one of the required reviewers approves **it**." (same page)
- "Jobs that reference an environment configured with required reviewers will wait for an approval before starting. While **a job** is awaiting approval, it has a status of 'Waiting'." (`control-deployments.md`)
- "Once **a job** is approved (and any other deployment protection rules have passed), the job will proceed." (`review-deployments.md`)

**Finding: this is genuinely ambiguous from the docs, and we say so rather than asserting a false certainty.** Every sentence in every one of these four pages that describes required-reviewer approval scopes the wait/approval state to the singular "a job" or "jobs" (plural, but never described as deduplicated across a single run). **Nowhere do the docs state whether a reviewer's single approval batches across two sequential jobs that reference the same environment in the same workflow run, and nowhere do the docs state that it does not.** No page we found addresses within-run reuse of an approval decision at all — the closest is the environment secrets sentence above, which is about secret *access* per job, not approval *reuse* across jobs.

**Practical resolution for this pilot, stated plainly:**

1. **No behavior changes today.** Per the issue's own verified state, this template's `lab` environment carries **zero protection rules** — `preflight` binding it costs nothing here, approval-wise, regardless of how the ambiguous question above resolves.
2. **The downstream operator repository is the compatibility target, and it too currently has no required-reviewers rule on `lab`** (per the task that authorized this pilot). State 2 of the non-vacuity proof (a fake secret present → the tenant-touching job runs) is *also* the proof that an already-onboarded copy — including that operator repo, today — keeps working exactly as it does now: two jobs run, zero approvals required either way, because there is nothing to approve.
3. **If the operator repository (or any consumer) ever adds required reviewers to `lab`,** the honest answer is: **it is unverified whether that costs one approval or two per run.** This ADR does not claim it is safe and does not claim it doubles the burden — it names the open question so a future operator who adds required reviewers tests it empirically (dispatch once, observe whether one approval unblocks both `preflight` and the gated job, or whether a second "Waiting" appears after `preflight` completes) before relying on an assumption either way. This is recorded as an explicit residual risk, not resolved by this ADR.

This is consistent with this repository's convention (per [ADR 0057](0057-multi-environment-and-branch-model.md) and the "vacuous guard" pattern recorded across the CHANGELOG) of marking a claim "verified" only when it has actually been proven, empirically or by an unambiguous documented statement — neither exists here.

## Decision

### 1. The rule

**A tenant-touching workflow running on a copy where the target GitHub Environment is not onboarded to a real Purview tenant SKIPS the tenant-touching job. It never FAILS.** "Not onboarded" is defined precisely by the onboarding signal below — not by branch, not by repository visibility, not by actor.

### 2. The onboarding signal, and where it is evaluated

The onboarding signal is **the presence of a real, non-empty `secrets.AZURE_CLIENT_ID` on the target GitHub Environment** (the same Environment the tenant-touching job would bind, selected by the [ADR 0057](0057-multi-environment-and-branch-model.md) canonical expression), **and**, for any workflow that also needs the automation Key Vault, **a non-empty `vars.KEY_VAULT_NAME` on that same Environment.**

It is evaluated in a **dedicated `preflight` job** — not a step-level `if:`, not a job-level `if:` placed directly on the tenant-touching job. Per the context-availability table above, `secrets` cannot be tested in any `if:` at all, so the secret must first be read from inside a running job (`env:` → a step). A dedicated job is what makes that legal without also making the tenant-touching job itself run just to fail its own steps.

### 3. The mechanism (design (c) from the issue, adapted to ADR 0057's multi-environment model)

```yaml
jobs:
  preflight:
    environment: ${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}
    permissions:
      contents: read
    outputs:
      configured: ${{ steps.check.outputs.configured }}
    env:
      AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
      KEY_VAULT_NAME: ${{ vars.KEY_VAULT_NAME }}
    steps:
      - id: check
        run: |
          # emits configured=true|false to $GITHUB_OUTPUT

  detect-drift:
    needs: preflight
    if: needs.preflight.outputs.configured == 'true'
    environment: ${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}
    # ...unchanged otherwise
```

`preflight` binds `environment:` using the **byte-identical ADR 0057 canonical expression** the gated job already uses — not a hardcoded `lab` — so the signal it tests is scoped to whichever environment (`lab` or `dev`) the run actually targets, and so [`tests/workflows/EnvironmentRouting.Tests.ps1`](../../tests/workflows/EnvironmentRouting.Tests.ps1)'s existing per-workflow assertions (which iterate every job-level `environment:` declaration and require the canonical expression) continue to pass without modification. It maps `secrets.AZURE_CLIENT_ID` into `env:` — legal per `jobs.<job_id>.env`'s context table — tests it inside a step, and emits a `configured` output. The gated job declares `needs: preflight` and `if: needs.preflight.outputs.configured == 'true'` — `needs` **is** available in a job-level `if:` per the table above, so this works regardless of how the environment-scoped-vars-in-`if:` question resolves; the gate never needs to test that question at all.

This is why approach (c) wins over the alternatives: its correctness does not depend on the unresolved environment-var-in-`if:` question. It tests the *actual* failing precondition — the OIDC secret — from inside a running job where `secrets` is genuinely in scope, per the table. It cannot pass vacuously, and it cannot silently skip an already-onboarded copy.

### 4. `drift-detection.yml`'s misplaced guard folds into `preflight`

The existing `KEY_VAULT_NAME` check (previously at step 5, "Temporarily allow Key Vault public access", using `throw`) is removed from that step and its logic moved into `preflight`, mapped as `vars.KEY_VAULT_NAME` in the same `env:` block as the secret. `preflight` now checks **both** signals — the OIDC secret and the Key Vault name — and skips on either being absent, changing the verb from **throw** (hard fail, wrong verb, unreachable behind the earlier `azure/login` failure) to **skip** (correct verb, evaluated first, before any Azure call).

### 5. Rejected alternatives (from the issue's own research)

- **Reuse `OWNER_APPROVAL_LOGIN`.** Dead on arrival: that repository variable **is set in this very template repo** (`marcusjacobson`). A gate keyed on it would evaluate to "configured" here, the tenant-touching job would run, and it would still fail at `azure/login` — zero behavior change while looking like a fix. It also conflates two orthogonal axes: "who owns this repo" versus "does this copy have a Purview tenant wired up."
- **New repo-level `vars.LAB_CONFIGURED` set by kickoff.** Mechanically sound (repo-level vars do resolve in a job `if:`) and the smallest diff, but it is a **second source of truth**: an operator who provisions the secrets but forgets to set the flag gets a silent skip and believes they deployed. Rejected as the primary mechanism; not needed as a fallback either, since (c) works.
- **Step-level `if:` guards on every step.** Rejected: `secrets` is not available in a step `if:` either, so every step still needs `env:`-mapping gymnastics; the job still starts and still binds the environment; and a job whose steps all skip reports **success** — green means "it ran," which is a worse signal than a clean `skipped` job conclusion.

### 6. Ship shape — this PR is the pilot only

Following the in-repo precedent of ADR 0051 (#79) → implementation (#82), this ADR's *mechanism* is ratified here with empirical, two-state, non-vacuity proof on **one** workflow — `drift-detection.yml`, chosen because it is weekly (low blast radius) and it is the workflow already carrying the misplaced throw guard this ADR also fixes. The remaining 12 tenant-touching workflows named in [#91](https://github.com/marcusjacobson/Purview-as-Code/issues/91), plus the repo-wide static regression guard (every `azure/login`-using workflow with an automatic trigger must carry the gate), are **rollout scope for the follow-up PR that closes #91.** Splitting de-risks the failure mode this ADR exists to prevent: if the mechanism had turned out vacuous, that would have been one file of rework instead of thirteen.

## Consequences

**Easier.**

- A scheduled or push-triggered tenant-touching workflow on an un-onboarded template copy (including this repository itself) now reports a clean `skipped` conclusion instead of a red `azure/login` failure, on every run, forever — no more manufactured incident signal on a correctly-empty template.
- The `drift-detection.yml` `KEY_VAULT_NAME` guard moves from an unreachable throw at step 5 to a reachable skip at step 0, with the correct verb.
- The mechanism generalizes cleanly to the remaining 12 workflows in the follow-up PR: each gains the same `preflight` job shape (with per-workflow variation only in which Environment variables it additionally checks), plus `needs: preflight` / the `if:` on its existing tenant-touching job.

**Harder / accepted trade-offs.**

- Every gated workflow gains one extra job in its run graph. For a scheduled workflow this is a negligible cost (one short-lived job that reads two config values).
- The environment-approval-batching question (see Context) is **left open, not resolved**, for any consumer who adds required reviewers to a gated environment in the future. This is a known, named residual risk rather than a silent one.
- `preflight`'s `environment:` binding means a **future** protection rule change on that Environment (branch policy, wait timer) also gates `preflight`, not just the job that actually calls Azure. This is intentional — `preflight` reads real secrets and must be subject to the same Environment controls as any other job that does — but it means an operator who tightens `lab`'s protection rules affects one more job per gated workflow than before this ADR.

**Security posture.** Upholds [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #1 (no secrets in source — the secret is read, never echoed, never written to `$GITHUB_OUTPUT`/logs/artifacts) and rule #4 (least privilege — `preflight` declares `permissions: contents: read` only; it holds no `id-token: write` because it never calls `azure/login`).

## Alternatives considered

See "Rejected alternatives" in the Decision section above — the issue's own design research already enumerated and eliminated the field; this ADR does not re-litigate it, only records it.

## Citations

- [GitHub Actions contexts — context availability](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability) — fetch date 2026-07-13, re-verified live 2026-07-17 (table unchanged).
- [Managing environments for deployment](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) — fetch date 2026-07-13, re-verified live 2026-07-17.
- [Reviewing deployments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments) — fetch date 2026-07-17 (new research for this ADR's approval-batching question).
- [Controlling deployments in GitHub Actions](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments) — fetch date 2026-07-17 (new research for this ADR's approval-batching question).
- [Deployments and environments reference](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) — fetch date 2026-07-17 (new research for this ADR's approval-batching question).
- [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables) — fetch date 2026-07-13, re-verified live 2026-07-17.
- [ADR 0010](0010-automation-identity-subject-model.md), [ADR 0045](0045-template-kickoff-spinoff-model.md), [ADR 0057](0057-multi-environment-and-branch-model.md) — the decisions this ADR extends and builds on.
- [Issue #91](https://github.com/marcusjacobson/Purview-as-Code/issues/91) — full design research, non-vacuity proof plan, and the "ship shape — recommend split" rationale this ADR and its pilot PR follow.
