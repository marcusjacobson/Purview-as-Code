# 0013 — Squad agents own intake and governance; prompt pipeline owns build

- **Status:** Accepted
- **Date:** 2026-05-04
- **Gates:** Closes [#90](https://github.com/contoso/Purview-as-Code-Generic/issues/90). Unblocks consistent invocation of the Squad agents and the prompt pipeline across new work.
- **Deciders:** @contoso

## Context

The Squad retrofit ([PR #85](https://github.com/contoso/Purview-as-Code-Generic/pull/85)) introduced four custom agents (`@squad`, `@idea-intake`, `@artifact-resolver`, `@owner-approval`) and five governance workflows alongside the existing prompt pipeline (`/start-item`, `/build-item`, `/new-checkin`). The two systems overlap end-to-end:

- `@idea-intake` creates a branch and files an issue. `/start-item` also creates a branch.
- `@artifact-resolver` resolves an issue and opens a PR. `/new-checkin` also opens a PR.
- `@owner-approval` applies the `owner-approved` merge-gate label. `/new-checkin` historically waited for a typed `approve merge` token.

Nothing in the repo before this ADR reconciled the two. Worse, the two enforce different gates:

- `/start-item` Step 1 enforces the [`docs/project-plan.md`](../project-plan.md) §6 dependency matrix (a checklist row cannot start until all its `●` prerequisites are ticked) and §8 open-question ADR gates (an item gated by Q5 / Q6 / Q7 must wait for the ADR).
- `@idea-intake` skips both. Step 1 classifies the input by topic and produces a draft issue; Step 6 creates the branch on confirmation. Neither step consults `docs/project-plan.md`.

The resulting failure mode: an idea routed through `@idea-intake` for a project-plan-gated item lands as a branch with no enforcement of §6 / §8, and the contributor only learns about the gates if they happen to run `/start-item` afterward (which the agent flow does not require).

[PR #89](https://github.com/contoso/Purview-as-Code-Generic/pull/89) updated `docs/project-plan.md` to call the Squad agents the source of *issue* curation, but kept the three-prompt pipeline as the *cadence*. That implicit split is correct but never named, which means a future contributor (or a future me) cannot tell which entry point to use.

## Decision

We will name the implicit split, restrict each track to the work it is best suited for, and add a single bridge step where they meet. Specifically:

1. **Two tracks, by item provenance.**
   - **Project-plan track (prompt pipeline).** Items whose row already exists on the [`docs/project-plan.md`](../project-plan.md) Progress checklist enter through `/start-item`. The §6 dependency-matrix gate and the §8 ADR-open-question gate run before any branch is created. Implementation iterates through [`/build-item`](../../.github/prompts/build-item.prompt.md). Commit, PR, and merge run through `/new-checkin`.
   - **Cross-cutting track (Squad agents).** Items that do *not* have a row on the Progress checklist — net-new ideas, ADRs, governance changes, instruction-file edits, repo plumbing, and any work that arose from a chat exchange rather than the plan — enter through [`@idea-intake`](../../.github/agents/idea-intake.agent.md). Resolution runs through [`@artifact-resolver`](../../.github/agents/artifact-resolver.agent.md). Approval runs through [`@owner-approval`](../../.github/agents/owner-approval.agent.md), which applies `owner-approved` and lets the [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) workflow merge.

2. **Single shared validation engine.** Both tracks reuse [`/build-item`](../../.github/prompts/build-item.prompt.md) as the lab-deploy-and-verify loop. `@artifact-resolver` must invoke `/build-item` (or its inlined equivalent — see ADR scope below) before opening the PR so the per-domain pre-commit checklists in [`bicep.instructions.md`](../../.github/instructions/bicep.instructions.md), [`data-plane-yaml.instructions.md`](../../.github/instructions/data-plane-yaml.instructions.md), [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md), and [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) get satisfied for agent-resolved PRs the same way they do for human-resolved PRs. The detailed amendment to `@artifact-resolver` to operationalize this is out of scope here and is tracked in [#93](https://github.com/contoso/Purview-as-Code-Generic/issues/93).

3. **One bridge step, not a merge.** When an idea routed to `@idea-intake` turns out to map onto an existing Progress checklist row, the agent must stop, identify the row, and instruct the contributor to use `/start-item` instead. `@idea-intake` does not silently inherit `/start-item` gates; it explicitly hands off. This is enumerated as a new Step 0 in the agent body in the same PR that lands this ADR.

4. **Approval is unified.** Both tracks finish at the `owner-approved` label. The legacy `/new-checkin` "typed `approve merge` token" gate is reframed as "apply `owner-approved` interactively (or via `@owner-approval`)" so the merge gate is the same regardless of which track started the work. The PR-auto-merge workflow ([`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml)) is already the only enforcement point.

## Consequences

What this unblocks or improves:

- A contributor reading the repo for the first time has one decision tree: "is this on the Progress checklist?" Yes → prompt pipeline; no → Squad agents.
- The §6 / §8 gating that protects Wave-by-Wave delivery is preserved exactly where it matters (project-plan items) and not imposed where it is irrelevant (a typo fix, an ADR, an instruction-file edit).
- `@idea-intake`'s scope shrinks to its real job — drafting an issue and a branch for *new* work. It is no longer ambiguously the front door for *every* PR.
- The shared `/build-item` loop means the per-domain pre-commit evidence rules in [`pre-commit.instructions.md`](../../.github/instructions/pre-commit.instructions.md) apply identically to both tracks; reviewers do not have a separate mental model for agent-resolved PRs.
- The same unified merge gate (`owner-approved`) means the [`pr-owner-gate.yml`](../../.github/workflows/pr-owner-gate.yml) sticky comment is meaningful for both flows.

What becomes harder or constrained:

- `@idea-intake` now must classify "is this on the Progress checklist?" up front. This is added as Step 0 in its body in the same PR that lands this ADR.
- `@artifact-resolver` now must run the per-domain validation evidence loop before opening a PR. The detailed change is out of scope here; tracked in [#93](https://github.com/contoso/Purview-as-Code-Generic/issues/93).
- `/new-checkin` documentation must be updated so its gate is named `owner-approved`, not `approve merge`. Tracked as a follow-up; the runtime behavior — squash-merge after the lab owner says yes — is unchanged.

Security posture this upholds:

- Both tracks land at the same merge gate. The single-owner enforcement in [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) (`actor.login == 'contoso'`) remains the only authoritative check.
- The §6 / §8 gates protect against shipping items out of dependency order, which in a control-plane-touching repo is itself a security concern (for example, deploying a scan that depends on a Key Vault secret reference before the secret exists).
- No change to identity, RBAC, or network surface.

Scope deliberately deferred:

- The exact wording of `@artifact-resolver` Step 3 to inline / invoke `/build-item` validation evidence (issue [#93](https://github.com/contoso/Purview-as-Code-Generic/issues/93)).
- A "promote idea to Progress checklist" workflow (today this is a manual edit to `docs/project-plan.md`).
- A reverse bridge: stopping `/start-item` from creating a branch when the work is *not* a Progress checklist item. The current `/start-item` precondition (the user must name the row) already enforces this.

## Alternatives considered

**Alternative A: Prompt pipeline is canonical, agents are auxiliary.** Reject. The agents add real value for net-new ideas, governance, and approval gating that the prompt pipeline does not capture (`@idea-intake`'s natural-language classification and issue drafting; `@owner-approval`'s sticky-comment merge gate). Demoting the agents wastes that surface.

**Alternative B: Squad agents are canonical, prompt pipeline is deprecated.** Reject. The §6 / §8 gates that the prompt pipeline enforces are not an accident — they protect the per-Wave delivery order that [`docs/project-plan.md`](../project-plan.md) ratified across Waves 0–4. Removing them would mean re-implementing the same gating inside `@idea-intake`, which (a) is harder to reason about than a prompt-file step and (b) duplicates the source of truth in `docs/project-plan.md`.

**Alternative C: Do nothing — leave the two tracks ambiguous.** Reject. The status quo is the failure mode this ADR exists to fix. Issue [#90](https://github.com/contoso/Purview-as-Code-Generic/issues/90) documents the contributor confusion.

**Alternative D: Merge `@idea-intake` and `/start-item` into a single primitive.** Reject. They live at different layers — agents are persistent personas with scoped tools per [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes); prompt files are one-shot task templates per [Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files). Collapsing them violates [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) and loses the agent's tool-restriction semantics.

## Citations

- [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes) — agents as persistent personas with scoped tools and pinned models.
- [Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files) — prompt files as one-shot task templates.
- [Customize AI in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview) — the four-primitive model (instructions, prompts, agents, skills) that this ADR's split aligns to.
- [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) — repo-local primitive-selection rules.
- [`docs/project-plan.md`](../project-plan.md) — the §6 dependency matrix and §8 open questions whose gating the prompt pipeline enforces.
- [`.github/agents/idea-intake.agent.md`](../../.github/agents/idea-intake.agent.md), [`.github/agents/artifact-resolver.agent.md`](../../.github/agents/artifact-resolver.agent.md), [`.github/agents/owner-approval.agent.md`](../../.github/agents/owner-approval.agent.md) — the three Squad agents this ADR bounds.
- `.github/prompts/start-item.prompt.md` (deleted; superseded by `@idea-intake` per ADR 0014), [`.github/prompts/build-item.prompt.md`](../../.github/prompts/build-item.prompt.md), `.github/prompts/new-checkin.prompt.md` (deleted; superseded by `@artifact-resolver` + `@owner-approval` per ADR 0014) — the three prompts this ADR bounds.
- [ADR 0010](0010-automation-identity-subject-model.md), [ADR 0012](0012-environment-parameters-file.md) — examples of cross-cutting items that follow the agent track because they have no Progress checklist row.
