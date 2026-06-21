# 0029 — Source-of-truth direction policy for data-plane reconcilers: three modes, two axes, one contract

- **Status:** Accepted
- **Date:** 2026-05-30
- **Gates:** Cross-cutting foundation. Sub-issue A of the 4-part split that replaced [#454](../../issues/454). Defines the binding contract that sub-issue B implements in [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1), sub-issue C wires into [`.github/workflows/deploy-labels.yml`](../../.github/workflows/deploy-labels.yml), and sub-issue D rolls out across every remaining `deploy-<domain>.yml` workflow. Does not appear in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs — this is implementation-pattern scaffolding, not a wave-blocking question. Directly unblocks the YAML-first comment edit gap surfaced by [PR #453](../../pull/453).
- **Deciders:** @contoso

## Context

The repository's stated purpose is to manage Microsoft Purview as code: the YAML manifests under [`data-plane/`](../../data-plane/) are the desired state, the `Deploy-*.ps1` reconcilers and `deploy-*.yml` workflows converge the live tenant to that state, and the `sync-*-from-tenant.yml` workflows surface portal-side drift back into committable PRs. Bi-directionality is built into the architecture, but the *direction of resolution when the two sides disagree on a property* has never been documented.

The current [`deploy-labels.yml`](../../.github/workflows/deploy-labels.yml) workflow's "Conflict guard" step runs a strict textual diff between the committed YAML and a fresh tenant export. Any difference fails the job and points the operator at the drift-back PR flow. This implements a *portal-first* model — when the YAML and the tenant disagree on a shared label's property, the workflow assumes the YAML is wrong and refuses to overwrite the portal. That behavior was never the subject of an explicit decision; it emerged from a defensive design choice for the original prune ceremony ([#143](../../issues/143)) and was carried forward unchallenged.

[PR #453](../../pull/453) (the comment-refresh PR for 5 production-shape sensitivity labels) surfaced the gap. The PR's intent was the opposite direction: the YAML was correct (technical accuracy on `protectionType`, rights tiers, offline-access behaviour) and the tenant's user-prose comments — imported earlier by [PR #449](../../pull/449)'s scheduled drift-back — were wrong. A dispatch of `deploy-labels.yml` after the PR merged immediately tripped the conflict guard:

```text
::error::Conflict guard tripped: live tenant has drifted from
data-plane/information-protection/labels.yaml. Run scripts/Deploy-Labels.ps1
-ExportCurrentState -RedactIdentities locally, file the resulting drift-back
PR, merge it, then re-run this workflow against the new SHA.
```

The remediation the error message names — file a drift-back PR — is the *wrong* remediation for this case. A drift-back PR would re-import the tenant's inaccurate comments and overwrite the YAML's intentional correction. The workflow has no in-band way for the operator to say "no, the YAML is right; push it." The only escape hatches are (a) edit the 5 comments in the portal manually to match the YAML, then re-dispatch, or (b) run the reconciler locally outside the workflow, bypassing the guard entirely.

Both escape hatches violate properties the repo has otherwise been careful about:

- **(a)** routes a YAML-first change through the portal UI, which has no audit trail back to the PR and creates a "click here to make the workflow happy" moment that scales badly.
- **(b)** bypasses the [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) → workflow validation chain, leaving the change unaudited at the CI layer.

Neither escape hatch lets the lab-owner toggle direction explicitly. The portal-first assumption is silent in the code and silent in the failure mode.

Eighteen other data-plane domains (classifications, collections, data-sources, glossary, label-policies, auto-label-policies, policies, scans, role-groups, audit-retention, DLP, communication-compliance, IRM, data-lifecycle, records, unified-catalog, DSPM, administrative-units) will hit the same gap as they grow `deploy-<domain>.yml` workflows. Each one solving it independently creates 18 ad hoc shapes, 18 reviewer mental models, and 18 audit surfaces. The cross-cutting rollout planned for sub-issue D requires a binding contract first.

The naive responses each fail an existing rule or principle:

- **Keep the portal-first behavior and document it as the only mode.** Rejected because it permanently locks out YAML-first edits, which the repo's stated source-of-truth model assumes are first-class.
- **Flip to a repo-first default.** Rejected because it silently overwrites portal edits that may be intentional (an admin tweaking a sensitivity-label tooltip in the UI is a normal workflow), and because it removes the safety net for accidental YAML mistakes.
- **Make the operator choose direction in every PR description, enforced by a label.** Rejected because the choice is per-*dispatch*, not per-*PR*: the same YAML can land in `main` and need to be applied with different direction policies on different days (e.g. apply this comment change as repo-wins, then resume daily portal-wins drift-back).
- **Add a `repo_wins=true` boolean dispatch input.** Rejected as a leaky abstraction — it only solves one of the three meaningful modes (the missing third being "audit only, mutate nothing") and conflates "what does the workflow do?" with "is this destructive?".

## Decision

**We will adopt a three-mode `direction_policy` dispatch input on every `deploy-<domain>.yml` workflow, orthogonal to the existing `prune_missing` ceremony, with `portal-wins` as the universal default and `repo-wins` gated by a typed `overwrite portal` confirmation token.** The three modes form a complete and disjoint cover of the meaningful conflict-resolution behaviors. Every reconciler script MUST accept the matching `-DirectionPolicy` parameter so local runs share the workflow's vocabulary exactly.

### The three modes

1. **`audit`** — read-only verification. The reconciler enumerates the tenant, computes the diff, emits the plan table, and exits. No `New-*`, `Set-*`, or `Remove-*` calls fire under any circumstance. Equivalent to a forced `-WhatIf` at the script entry point. Useful for compliance evidence, periodic drift checks, and pre-flight sanity before a real apply.

2. **`portal-wins` (default)** — the existing portal-first model, made explicit and non-fatal. The reconciler:
   - Creates labels declared in YAML but missing from the tenant.
   - Applies updates where the tenant's tracked fields agree with the YAML (a no-op or a non-conflicting field add).
   - **Skips** any shared object where one or more tracked fields differ, naming the skipped objects in the run log.
   - On exit, if any objects were skipped, opens (or refreshes) a drift-back PR via the same [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request) mechanism the `sync-<domain>-from-tenant.yml` workflows already use, listing the skipped objects in the PR body for human review.
   - Exits success even when objects were skipped — the skip + auto-PR is the contract's normal behavior, not a failure mode.

3. **`repo-wins`** — explicit YAML-wins-on-conflict. The reconciler applies the full plan, including shared-object property drift. Tenant fields are overwritten with YAML values via the domain's normal `Set-*` cmdlet. Gated by a typed `overwrite portal` confirmation token mirroring the existing `confirm prune` ceremony from [`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) §"Destructive writes require typed confirmation". A dispatch with `direction_policy=repo-wins` and `confirm_overwrite != 'overwrite portal'` fails fast in a pre-flight validation step *before* any Key Vault unlock, Azure login, or tenant call.

### Orthogonality with `prune_missing`

The existing `prune_missing` dispatch ceremony (orphan tenant objects → `Remove-*`) is a separate axis. The two compose into a five-row truth table — every meaningful dispatch shape is named, nothing is implicit:

| `direction_policy` | `prune_missing` | Tokens required | Shared-drift behavior | Orphan-tenant behavior |
|---|---|---|---|---|
| `audit` | n/a (ignored) | none | report only | report only |
| `portal-wins` (default) | `false` (default) | none | skip + auto-PR | report only |
| `portal-wins` | `true` | `confirm_prune='confirm prune'` | skip + auto-PR | `Remove-*` |
| `repo-wins` | `false` | `confirm_overwrite='overwrite portal'` | `Set-*` overwrites tenant | report only |
| `repo-wins` | `true` | both confirmation tokens | `Set-*` overwrites tenant | `Remove-*` |

The conflict guard logic differs per row, but the script-side branching collapses into two boolean decisions inside the Apply phase: "for each shared-drift object, skip or write?" (controlled by `direction_policy`) and "for each orphan object, ignore or delete?" (controlled by `prune_missing`). The two decisions are made independently.

### Push trigger always uses defaults

The `push: branches: [main]` trigger on every `deploy-<domain>.yml` workflow runs with the input defaults (`direction_policy=portal-wins`, `prune_missing=false`). The repo's normal CI loop therefore preserves the safety property that has held since the workflows shipped: a merge to `main` never overwrites a portal edit and never deletes a tenant object. Mode escalation is workflow-dispatch only and always operator-initiated.

### Binding statement for the rollout

Every `deploy-<domain>.yml` workflow in this repository — present and future — MUST implement this contract:

- Dispatch inputs `direction_policy` (enum `audit | portal-wins | repo-wins`, default `portal-wins`) and `confirm_overwrite` (string, default `''`, required equal to `overwrite portal` when `direction_policy=repo-wins`).
- A pre-flight `Validate dispatch inputs` step that fails fast on missing tokens before any Key Vault unlock or Azure login.
- A conflict-resolution step that branches on `direction_policy` and either skips shared drift (and opens an auto-PR), overwrites it, or short-circuits the entire Apply phase (the `audit` mode).
- A reconciler script that accepts `-DirectionPolicy` and (where the workflow pre-computes a skip list) `-SkipNames`, with the same enum values and default.

Per-domain rollout sequencing is sub-issue D's responsibility. This ADR sets the shape; the rollout PRs implement it one domain at a time.

## Consequences

**Easier:**

- **YAML-first edits stop being a workflow bypass.** A change like [PR #453](../../pull/453)'s comment refresh becomes a normal dispatch with `direction_policy=repo-wins`, gated by the confirmation token, audited end-to-end in the workflow run log. No portal-side workaround, no local-script escape hatch.
- **Cross-domain consistency.** Reviewers, runbook authors, and the lab owner learn one mental model and one set of tokens. A `direction_policy=repo-wins` dispatch on `deploy-classifications.yml` does what a `direction_policy=repo-wins` dispatch on `deploy-labels.yml` does, by contract.
- **Read-only audits become a first-class operation.** `audit` mode replaces the current pattern of "dispatch the workflow with `direction_policy=portal-wins` and hope no drift is present, otherwise the conflict guard fires." Periodic compliance checks no longer have a chance of mutating anything.
- **The portal-wins default is now defensible.** It can be cited as the ratified safety floor rather than the accidental status quo. A future contributor proposing to flip the default has a clear ADR to supersede.
- **Auto-PR for skipped drift completes the bi-directional loop.** Today a `deploy-*.yml` dispatch that hits drift fails and surfaces the failure to the dispatcher; the drift-back PR comes from the separate `sync-*-from-tenant.yml` schedule, which may be hours away. With the contract, the same dispatch both partially applies what it safely can *and* opens the drift-back PR for the rest, closing the operator's loop in a single run.

**Harder:**

- **Every reconciler script grows a new parameter.** `-DirectionPolicy` (and, for workflows that pre-compute skip lists, `-SkipNames`) must be plumbed through the Apply phase. The wave of per-domain rollout PRs (sub-issue D) is real work; eighteen domains is eighteen PRs at a minimum.
- **The Pester contract widens.** Every reconciler's test file gains coverage of the three branches (audit / portal-wins skip path / repo-wins write path). This is mechanical to add but requires per-domain test fixtures.
- **Two confirmation ceremonies on the destructive path.** A `direction_policy=repo-wins prune_missing=true` dispatch requires both `confirm_overwrite='overwrite portal'` and `confirm_prune='confirm prune'`. This is intentional belt-and-braces — the two axes are independent and each warrants its own typed acknowledgment — but the dispatcher must remember both tokens.
- **Drift-back PR fatigue.** A `portal-wins` dispatch on a tenant that has accumulated many small portal edits will open a single auto-PR listing all skipped objects. The PR is reviewable, but if portal edits are frequent and unintentional this PR will fire often. Mitigation: contributors who notice the same labels drifting back repeatedly should propose a `portal-wins` → `repo-wins` dispatch to assert the YAML, or correct the YAML to match the recurring portal state.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Unchanged. Confirmation tokens are public literals, not secrets — they exist to defeat accidental dispatch, not to authenticate.
- **#9 (idempotent, reversible, auditable).** Strengthened. `audit` mode is purely auditable. `portal-wins` is idempotent and reversible (the auto-PR is the reversal mechanism). `repo-wins` is auditable through the typed-token requirement and the workflow run log; reversal is via `sync-<domain>-from-tenant.yml` on the next schedule or dispatch.
- **#10 (OWASP-aware).** Upheld. The pre-flight validation step prevents injection via the `confirm_overwrite` input — it's a case-sensitive equality check against a literal, not a substring or regex match, mirroring the existing `confirm_prune` gate per [GitHub Actions: script injections](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections).

## Alternatives considered

1. **Do nothing — keep the portal-first conflict guard as the only behavior.** Rejected. Permanently locks out YAML-first edits, makes [PR #453](../../pull/453)'s scenario impossible to resolve in-band, and forces eighteen future per-domain workflows to either copy the limitation or invent their own per-domain escape hatch.

2. **One-way YAML-first only — strip the conflict guard, always overwrite.** Rejected. Removes the safety net for accidental YAML mistakes (an editor typo could silently wipe a label's encryption block on the next push to `main`), and discards the legitimate use case of a portal admin tweaking a sensitivity-label tooltip in the UI without round-tripping through a PR.

3. **Free-for-all per reconciler — each domain picks its own model.** Rejected. Creates eighteen ad hoc shapes, eighteen runbooks, eighteen reviewer mental models. The audit story degenerates from "what does the contract say?" to "what does this specific workflow's authoring history say?" Per [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md), uniformity of contract is the whole point of having a contract.

4. **A single `repo_wins=true` boolean dispatch input.** Rejected as an incomplete cover. Only solves the YAML-first case, leaves `audit` mode either unaddressed (no read-only ceremony) or paradoxically named (`repo_wins=false` doing two different things depending on whether drift exists). The three-mode enum is two extra values for a strictly better mental model.

5. **Compose the existing `prune_missing` and a new `force_overwrite` flag, no `audit` mode.** Rejected. The truth table degenerates into four rows that don't cleanly express "read only, change nothing" — the closest expression would be `prune_missing=false force_overwrite=false` plus the conflict guard, which is what we have today (and is precisely the gap this ADR closes). `audit` deserves to be its own named row.

6. **Defer the cross-domain contract to per-domain ADRs.** Rejected. Each per-domain ADR would either reproduce most of this document (yielding eighteen near-duplicate ADRs) or pick a different shape (yielding fragmentation the sub-issue D rollout is meant to prevent). Ratifying once here and citing back from per-domain runbooks is the small-blast-radius choice.

## Citations

- [`deploy-labels.yml`](../../.github/workflows/deploy-labels.yml) — the workflow whose unratified portal-first behavior motivated this ADR.
- [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml) — the drift-back companion whose `peter-evans/create-pull-request` recipe the auto-PR step will reuse verbatim.
- [`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) §"Destructive writes require typed confirmation" — the source rule for the `overwrite portal` token shape, paralleling the existing `confirm prune` ceremony.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — security principles upheld in §Consequences.
- [`.github/instructions/primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) — uniformity-of-contract rationale referenced in §Alternatives #3.
- [Set-Label (Exchange / Security & Compliance PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label) — the cmdlet a `repo-wins` apply ultimately calls for sensitivity labels.
- [Manage sensitivity labels (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels) — Microsoft Learn surface that documents the bi-directional admin model this ADR aligns with.
- [GitHub Actions — workflow_dispatch inputs](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions#onworkflow_dispatchinputs) — the dispatch-input contract every `deploy-<domain>.yml` workflow consumes.
- [GitHub Actions — security hardening, script injections](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections) — the injection-safety pattern the pre-flight validation step follows.
- [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) — auto-PR mechanism for the `portal-wins` skip-drift case.
- [ADR 0023](0023-identifier-resolution.md) — companion cross-cutting contract that this ADR follows in shape (three-category model, binding statement for future reconcilers).
