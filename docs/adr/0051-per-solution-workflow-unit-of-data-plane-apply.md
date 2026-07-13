# 0051 — The per-solution workflow is the unit of data-plane apply; the monolithic `deploy-data-plane.yml` is retired

- **Status:** Accepted
- **Date:** 2026-07-13
- **Gates:** Cross-cutting; no [`project-plan.md`](../project-plan.md) §5 / §8 row. Gates the follow-up item that **deletes [`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml)** and performs the **operator-doc sweep** that repoints every surviving reference at either the surface's per-solution workflow or its local `scripts/Deploy-*.ps1` reconciler ([`README.md`](../../README.md), [`docs/architecture.md`](../architecture.md), [`docs/getting-started.md`](../getting-started.md), [`docs/kickoff-guide.md`](../kickoff-guide.md), [`docs/tenant-onboarding.md`](../tenant-onboarding.md), the `docs/solutions/**` guides, and the `docs/runbooks/**` smoke runbooks). Also gates the backfill of the 12 data-plane surfaces that have no per-solution workflow today.
- **Deciders:** @marcusjacobson

## Context

[`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) was scaffolded as a single monolithic forward-apply workflow: one `deploy:` job whose steps walk every data-plane surface in the repo in sequence — administrative units, Purview role groups, sensitivity labels, DLP, audit retention, retention/DLM, records/file plan, IRM policies, IRM entity lists, collections, glossary, classifications, data sources, scans, and a `-WhatIf` pass over the unified catalog. Roughly 14 surfaces, one job, one dispatch form.

Against that, the repo has separately grown a **per-solution** workflow pattern: one workflow per data-plane surface, each owning exactly one `Deploy-*.ps1` reconciler.

This ADR records the ruling on which of the two is the unit of data-plane apply.

### Evidence 1 — the monolith is structurally invalid and has never executed, not once

`deploy-data-plane.yml` declares **32 `workflow_dispatch` inputs**. GitHub caps a `workflow_dispatch` input map at **25 top-level properties**. The file therefore fails at *startup*, before any job is scheduled: GitHub cannot parse the workflow, so it produces a run with **zero jobs**, empty logs, and the message *"This run likely failed because of a workflow file issue."*

This is not a regression that crept in. `git show e30b51f` — the original scaffold commit, `chore(repo): scaffold generic Purview-as-Code template baseline`, 2026-06-21 — already declares **32 inputs**, and `HEAD` still declares **32**. The file has been dead on arrival for its entire life.

The Actions run history confirms it empirically, and does so more strongly than the static reading alone:

| Metric | Value |
|---|---|
| Total runs of `deploy-data-plane.yml` | **90** |
| Successful runs | **0** |
| Jobs scheduled, most recent run | **0** |
| First run | **2026-06-21** — the day the file was scaffolded |

Every one of the 90 runs is a failure with no jobs. Tellingly, the runs are attributed to the **`push`** event even though the file at `HEAD` declares no `push:` trigger at all (only `workflow_dispatch`) — precisely the signature of a workflow whose `on:` block never parses, so GitHub cannot determine which triggers apply and records the startup failure against the triggering push.

**Deleting a workflow that has never once executed is a zero-regression change.** There is no behavior to preserve.

> **Correction to the intake framing, recorded deliberately.** The item that produced this ADR cited GitHub's cap as **10** inputs. That figure is the `repository_dispatch` **`client_payload`** limit ("the maximum number of top-level properties in `client_payload` is 10"), not the `workflow_dispatch` **`inputs`** limit, which the current documentation puts at **25**. The distinction does not disturb the decision or any conclusion drawn from it: **32 exceeds 25, and it also exceeded the 10-input cap that `workflow_dispatch` carried historically**, so the file is invalid under both the current and the former limit, across its entire history. The accurate number is recorded here so that a future author citing this ADR cites a true one.

### Evidence 2 — the repo already chose the per-solution pattern, and executed it five times

Five per-solution forward-apply workflows have landed (PRs #58–#61, #70), each owning exactly one surface, each with an input surface an order of magnitude smaller than the monolith's:

| Workflow | Surface | `workflow_dispatch` inputs |
|---|---|---|
| [`deploy-dlp.yml`](../../.github/workflows/deploy-dlp.yml) | DLP policies | 2 |
| [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml) | IRM policies | 3 |
| [`deploy-labels.yml`](../../.github/workflows/deploy-labels.yml) | Sensitivity labels | 4 |
| [`deploy-label-policies.yml`](../../.github/workflows/deploy-label-policies.yml) | Label policies | 2 |
| [`deploy-auto-label-policies.yml`](../../.github/workflows/deploy-auto-label-policies.yml) | Auto-labeling policies | 2 |
| — | — | — |
| [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) | *all ~14* | **32** — invalid |

The five are not just smaller; they are structurally better formed. `deploy-dlp.yml` carries `permissions: {}` deny-by-default with least-privilege per-job grants, a `concurrency:` group, a `push:` path trigger that auto-applies on merge, and a `drift-back-pr` job. The monolith has **no** `push:` trigger, **no** `concurrency:` block, and a single broad top-level `permissions:` grant covering one giant job.

### Evidence 3 — the repo's own recorded rationale, already written down

The decisive argument is not new. It is already committed to the repository, in [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml) lines 12–17, as that workflow's stated reason for existing:

> Before this workflow, IRM's only forward apply path was one step buried inside the monolithic
> deploy-data-plane.yml, which cannot run IRM in isolation and re-touches every other data-plane
> surface in a single job -- several of which require the control-plane Purview account and go red
> when it is not deployed, producing poor forward-apply evidence for IRM alone.

That is the whole case in four lines: a single-job monolith **cannot apply one surface in isolation**, and it **goes red on surfaces whose prerequisites are absent**, which destroys the forward-apply evidence for the surface you actually wanted.

### Evidence 4 — the monolith is a stale subset, not an umbrella

It is tempting to read the monolith as the "apply everything" superset that the per-solution workflows decompose. It is not. [`deploy-label-policies.yml`](../../.github/workflows/deploy-label-policies.yml) and [`deploy-auto-label-policies.yml`](../../.github/workflows/deploy-auto-label-policies.yml) cover surfaces the monolith **never had a step for at all**. It is a stale, partial snapshot that stopped tracking the repo, not a ceiling over it.

### Evidence 5 — the monolith imposes a maintenance tax while dead

`skip_names_irm` is defined in **three** files that must stay in byte-lockstep — [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml), [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml), and [`sync-irm-from-tenant.yml`](../../.github/workflows/sync-irm-from-tenant.yml) — and one of the three is dead code that has never run. The monolith is not merely inert; it actively taxes every change to a surface it cannot apply.

## Decision

We will treat **the per-solution workflow (`deploy-<solution>.yml`) as the unit of data-plane apply**, and we will **retire the monolithic [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml)**. Specifically:

1. **One workflow, one surface.** Each `deploy-<solution>.yml` owns exactly **one** data-plane surface and exactly one `Deploy-*.ps1` reconciler. No workflow applies a surface it does not name.
2. **`push:` path triggers.** Each workflow auto-applies on merge, triggered by changes to the `data-plane/**` paths and the reconciler it owns.
3. **A small `workflow_dispatch` input surface.** Manual dispatch stays well inside the platform cap. The repo's working ceiling is **≤10 inputs** per workflow — a self-imposed design rule, deliberately far below GitHub's documented 25-property maximum, because an input surface that approaches the platform limit is itself the smell that the workflow is doing too much. The five existing workflows land at 2–4.
4. **`permissions: {}` deny-by-default**, with least-privilege scopes granted per job rather than once at the top of the file.
5. **A `concurrency:` group** per workflow, so two applies of the same surface cannot interleave.
6. **Two-pass deterministic skip enumeration and automated drift-back PRs** where the surface supports export.

The retirement itself — deleting the file and sweeping the docs that reference it — is the **separately gated follow-up item** named in the `Gates:` line above. Consistent with the precedent [ADR 0050](0050-machine-generated-adr-index.md) set, the ruling ships first, on its own, so that it is reviewable as a ruling rather than buried inside a large deletion diff.

## Consequences

**Twelve of ~14 surfaces have no automated apply path, and the docs must say so.** Of the monolith's ~14 surfaces, only **3** have a per-solution workflow today (sensitivity labels, DLP, IRM). The other **12** — administrative units, Purview role groups, audit retention, retention/DLM, records/file plan, IRM entity lists, collections, glossary, classifications, data sources, scans, and unified catalog — have **none**.

This consequence is the honest cost of the decision, and it is accepted with eyes open. It is important to be precise about what is actually lost: **nothing**. Those 12 surfaces did not have a working automated apply path *before* this decision either — they had a step inside a workflow that has never executed. Retiring the monolith does not remove an apply path; it removes the **false appearance** of one.

Accordingly: **until the backfill lands, the documented apply path for those 12 surfaces is the local `scripts/Deploy-*.ps1` reconciler**, and the operator docs must say that plainly rather than pointing at a workflow that cannot run. Backfilling the 12 per-solution workflows is tracked as follow-up items.

**This ADR supersedes the relevant passages of the earlier ADRs that reference `deploy-data-plane`.** Eleven ADRs reference it and are superseded **only in those passages** — their decisions otherwise stand:

| ADR | Current status |
|---|---|
| [0003](0003-data-plane-folder-naming.md) | Accepted |
| [0010](0010-automation-identity-subject-model.md) | Accepted |
| [0011](0011-certificate-lifecycle.md) | Accepted |
| [0021](0021-dspm-content-explorer-cadence.md) | Accepted |
| [0026](0026-glossary-custom-classifications-reconciler.md) | Accepted |
| [0035](0035-records-seed-content-immovable.md) | Accepted |
| [0036](0036-irm-tenant-setting-immovable.md) | Accepted |
| [0037](0037-unified-catalog-authoring-surface.md) | *already* Superseded by [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) |
| [0038](0038-devops-policies-reconciler-retirement.md) | Accepted |
| [0046](0046-tenant-placeholder-manifest.md) | Accepted |
| [0049](0049-data-plane-sp-key-vault-firewall-rbac.md) | Proposed |

> **A `grep` for `deploy-data-plane` under `docs/adr/` returns 12 files, but only these 11 are ADRs.** The twelfth is [`docs/adr/README.md`](README.md), whose "Current ADRs" table is a **machine-generated artifact** under [ADR 0050](0050-machine-generated-adr-index.md). A generated index is not a decision and **cannot be superseded** — it is recomputed from its sources. Do not instruct a future author to supersede a passage in it.

**ADRs are immutable — supersede, never edit.** No superseded ADR above is to be edited by the follow-up item, or by anything else. The supersession is recorded *here*, in the superseding ADR, which is the only place it belongs.

**A `deploy-all.yml` orchestrator is explicitly deferred.** If an "apply everything" entry point is ever wanted, it is **new greenfield work built on `workflow_call`** — not a rehabilitation of this file, and not a reason to keep it. It is out of scope for this decision and for the follow-up it gates.

**Security posture improves.** The per-solution pattern is strictly the stronger of the two on the principles in [`security.instructions.md`](../../.github/instructions/security.instructions.md): it replaces a single broad top-level `permissions:` grant spanning one job that touches every surface with `permissions: {}` deny-by-default and least-privilege scopes granted per job. It also shrinks the blast radius of any single apply from ~14 surfaces to one. Nothing is relaxed.

## Alternatives considered

**Alternative A: Do nothing — keep `deploy-data-plane.yml`.** **Reject.** The status quo is a workflow that has failed 90 times out of 90, scheduled zero jobs, and has never executed since the day it was scaffolded. Keeping it preserves no capability whatsoever, while continuing to (a) advertise an apply path that does not exist, to every operator reading the docs that point at it, and (b) levy the three-way `skip_names_irm` lockstep tax on a file that cannot run.

**Alternative B: Collapse the inputs to fit under the cap** (a JSON overrides blob plus a solutions selector). **Reject.** This makes the file **valid** but not **working**. The single job still runs all ~14 surfaces sequentially, and still goes red on every surface that requires a control-plane Purview account that is not deployed — the exact failure [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml) was written to escape. **A valid-but-always-red monolith is worse than an absent one, because it looks like it should work**: a startup failure is unmistakable, whereas a red job invites operators to debug a workflow that is wrong by design. It also preserves the three-way `skip_names_irm` byte-lockstep tax, one leg of which would remain dead code.

**Alternative C: Reduce it to an orchestrator that calls the per-solution workflows.** **Reject.** There is no coherent contract to orchestrate: only 3 of ~14 surfaces have a workflow to call, so the orchestrator would be mostly empty. It would first require `workflow_call` refactors of all five existing workflows, which is greenfield work that has nothing to do with this file. And a dispatch-triggered orchestrator still has to surface the union of its children's inputs at the top, which walks straight back into the same input-cap wall this file already hit. If an orchestrator is ever wanted, it is built fresh (see Consequences), not salvaged.

## Citations

- **[Events that trigger workflows — `workflow_dispatch`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)**
  Fetch date: 2026-07-13
  > "The maximum number of top-level properties for `inputs` is 25."

  The cap that `deploy-data-plane.yml`'s 32 inputs exceed. The same page states the *separate* `repository_dispatch` limit — "the maximum number of top-level properties in `client_payload` is 10" — which is the figure the intake item mistook for the `workflow_dispatch` cap.
- **[Workflow syntax for GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)**
  Fetch date: 2026-07-13

  Source for the `on.push.paths`, `permissions`, `concurrency`, and `workflow_call` constructs the per-solution pattern is built on.
- **[Well-Architected Framework — Operational Excellence design principles](https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/principles)**
  Fetch date: 2026-07-13
  > "Through automation, you save time, effort, and money, and you avoid mistakes."

  A workflow that has never executed automates nothing; the per-solution workflows are the ones actually delivering this principle.
- **[Well-Architected Framework — Recommendations for safe deployment practices](https://learn.microsoft.com/en-us/azure/well-architected/operational-excellence/safe-deployments)**
  Fetch date: 2026-07-13
  > "Small, incremental, and frequent updates are easier to troubleshoot than large, sweeping updates."

  Grounds the core of this decision: one workflow per surface produces a small, isolable, independently reviewable apply, whereas the monolith's single job re-touches ~14 surfaces per run.
- [`.github/workflows/deploy-irm.yml`](../../.github/workflows/deploy-irm.yml) — lines 12–17 carry the repo's own recorded rationale, quoted verbatim in Context.
- [`.github/instructions/github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) — the "every `Deploy-*.ps1` reconciler gets both companion workflows" rule the per-solution pattern implements.
- [ADR 0050](0050-machine-generated-adr-index.md) — the ADR index is machine-generated; establishes both the "ruling ships first, on its own" precedent followed here and the rule that [`docs/adr/README.md`](README.md) is generated and gets no hand-added row from this PR.
