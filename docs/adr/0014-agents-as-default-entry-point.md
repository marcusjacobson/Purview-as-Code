# 0014 — Squad meta-agents are the default entry point

- **Status:** Accepted
- **Date:** 2026-05-04
- **Supersedes-in-part:** [ADR 0013](0013-squad-agents-vs-prompt-pipeline.md). The two-track split named in 0013 is collapsed into a single agent-led entry point. The §6 / §8 gating that 0013 protected is preserved by inlining it into `@idea-intake` Step 0; all other claims of 0013 stand.
- **Gates:** Closes [#102](https://github.com/contoso/Purview-as-Code-Generic/issues/102). Removes redundancy between the prompt pipeline and the Squad agents.
- **Deciders:** @contoso

## Context

[ADR 0013](0013-squad-agents-vs-prompt-pipeline.md) named two tracks — a project-plan-row "prompt pipeline" track (`/start-item` → `/build-item` → `/new-checkin`) and a cross-cutting "Squad agents" track (`@idea-intake` → `@artifact-resolver` → `@owner-approval`) — and bridged them at `@idea-intake` Step 0 with an explicit hand-off whenever the input mapped to a Progress-checklist row. The split was correct as a stop-gap: it preserved the §6 dependency-matrix and §8 ADR gates without having to re-implement them inside the agents.

Three things changed since 0013 landed:

1. **The agents have been used in anger.** Issues [#90–#101](https://github.com/contoso/Purview-as-Code-Generic/issues) — including ADRs, instruction-file edits, and governance content — all routed cleanly through `@idea-intake` → `@artifact-resolver` → `@owner-approval`. The agent surface is the one contributors actually reach for.
2. **The redundancy is now visible.** `/start-item` and `@idea-intake` both create branches and stop. `/new-checkin` and `@artifact-resolver` + `@owner-approval` both commit, push, open the PR, gate on owner approval, merge, and clean up. Two surfaces, identical lifecycle, drift-prone.
3. **Lifecycle work is a persona, not a task.** Per [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) and [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes), persistent personas with scoped tools and handoffs belong to agents; one-shot task templates belong to prompts. Branching, committing, gating, and merging are persona behavior — they have a tool list (`runCommands`, `githubRepo`), a stop-on-confirmation discipline, and named handoffs to other agents.

The status quo therefore violates the four-primitive model and forces every contributor to hold two parallel decision trees in their head.

## Decision

Promote the three meta-agents to the **default** repo entry point. Reserve `@squad` for content-creation interviews. Retain `/build-item` as the shared validation engine. Retain operational and session-lifecycle prompts as tools the agents call.

Specifically:

1. **Default flow is agent-led.** `@idea-intake` → `@artifact-resolver` → `@owner-approval` is the single entry path for all repo work — Progress-checklist items and cross-cutting work alike. A contributor who does not know which primitive to use should reach for `@idea-intake`.

2. **`@idea-intake` enforces the §6 / §8 gates inline.** Step 0 of [`idea-intake.agent.md`](../../.github/agents/idea-intake.agent.md) now classifies "is this on the Progress checklist?" and, when the answer is yes, runs the dependency-matrix and open-question ADR gates from [`docs/project-plan.md`](../project-plan.md) before drafting the issue. The branch is not created until the gates pass. The legacy hand-off to `/start-item` is removed.

3. **`@artifact-resolver` absorbs commit + PR-open responsibilities.** Steps 1–4 of the deleted `/new-checkin` prompt (staged-paths review, secrets-scan against `git diff --cached`, Conventional Commits message composition, push, and PR open) are inlined into [`artifact-resolver.agent.md`](../../.github/agents/artifact-resolver.agent.md). Validation continues to delegate to `/build-item`.

4. **`@owner-approval` absorbs merge + cleanup + checklist tick.** Steps 5–8 of the deleted `/new-checkin` prompt (squash-merge, remote and local branch deletion, project-plan checkbox tick, session-memory cadence-log update, "what's next" prompt) are inlined into [`owner-approval.agent.md`](../../.github/agents/owner-approval.agent.md), behind the existing exact-confirmation gate.

5. **`@squad` owns content-creation prompts.** The two interview-shaped prompts — [`/add-classification`](../../.github/prompts/add-classification.prompt.md) and [`/add-data-source`](../../.github/prompts/add-data-source.prompt.md) — are referenced from [`squad.agent.md`](../../.github/agents/squad.agent.md) under a new "Content-creation skills" section. They remain prompt files because they are one-shot interviews; `@squad` invokes them when the active persona is Security Specialist or Automation Engineer and the task matches.

6. **`/build-item` is unchanged in behavior.** It remains the single validation engine for both `@artifact-resolver` and any human-driven build loop, per the §2 commitment of ADR 0013. Its lifecycle wording is updated to point at `@artifact-resolver` / `@owner-approval` instead of the deleted prompts.

7. **Operational and session prompts are retained.** `/deploy-infra`, `/deploy-datamap`, and `/security-review` are tools the agents call during build / review. `/prepare-handoff` and `/resume-from-handoff` own the chat-session lifecycle (a different concern from the issue lifecycle the agents own).

8. **Legacy prompts are removed, not demoted.** `/start-item` and `/new-checkin` are deleted from `.github/prompts/`. Keeping them as opt-in fallbacks would re-introduce the redundancy this ADR exists to remove. Every best practice they encoded is preserved in the agent bodies per the redundancy table below.

## Redundancy table — where each prompt''s best practice now lives

Each row cites the source line range in the deleted prompt so reviewers can verify nothing was silently lost. Line numbers reference the deleted files at the SHA prior to this ADR''s landing PR.

| Source | Lines | Practice | Now lives in |
|---|---|---|---|
| `/start-item` | L11–L23 | Confirm checklist item, slug, and Conventional Commits type before any action | `@idea-intake` Step 1 (classification) + Step 4 (branch name) |
| `/start-item` | L25–L33 | §8 ADR open-question gate | `@idea-intake` Step 0 (project-plan gate) |
| `/start-item` | L35–L41 | §6 dependency-matrix gate | `@idea-intake` Step 0 (project-plan gate) |
| `/start-item` | L43–L57 | Clean working tree + on-`main` + up-to-date precondition checks | `@idea-intake` Step 6 (on confirmation) |
| `/start-item` | L59–L77 | Branch-name regex `^(feat|fix|chore|docs|refactor|ci|build|test|perf|revert)/w[0-4]-[a-z0-9-]+$`, `git checkout -b` + `git push -u origin` | `@idea-intake` Step 4 + Step 6 |
| `/start-item` | L93–L98 | Hard rules (no unticked deps; from `main`; no leak; one item at a time) | `@idea-intake` Hard rules |
| `/new-checkin` | L17–L26 | Branch + upstream + working-tree precondition checks | `@artifact-resolver` Scope gates + Step 1 |
| `/new-checkin` | L29–L48 | Staged-paths review + secrets-scan against `git diff --cached` | `@artifact-resolver` Step 4 (pre-PR validation) |
| `/new-checkin` | L52–L60 | Conventional Commits subject + scope + body + Learn citation | `@artifact-resolver` Step 5 (commit) |
| `/new-checkin` | L62–L66 | Push the new commit | `@artifact-resolver` Step 6 (push) |
| `/new-checkin` | L68–L86 | Open PR with all required sections; preferred tool order (GitHub MCP → `gh` → web) | `@artifact-resolver` Step 7 (open PR) |
| `/new-checkin` | L88–L94 | In-chat owner approval gate (now unified with `owner-approved` label) | `@owner-approval` Turn 1 + Turn 2 |
| `/new-checkin` | L96–L120 | Squash-merge with preferred tool order, plus local cleanup (`-D` rationale) | `@owner-approval` Step 3 (post-merge cleanup) |
| `/new-checkin` | L122–L126 | Tick the project-plan checkbox in the same PR | `@owner-approval` Step 4 (project-plan tick) |
| `/new-checkin` | L128–L138 | Session-memory cadence-log update + "what''s next" prompt | `@owner-approval` Step 5 (cadence log) + Step 6 (next item) |
| `/new-checkin` | L140–L150 | Hard rules (exact-token gate; no direct `main` commits; no batching; redaction; no `--force`) | `@owner-approval` Hard rules |

## Consequences

What this unblocks:

- One decision tree for contributors: reach for `@idea-intake`. The agent decides whether the §6 / §8 gates apply and runs them.
- Drift-prone redundancy is gone. There is one place to update branch-name regex, one place to update the secrets-scan invocation, one place to update the squash-merge cleanup recipe.
- The four-primitive model is upheld: lifecycle work is in agents, validation and content interviews are in prompts.
- The `owner-approved` label remains the single merge gate. [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) is unchanged.

What becomes harder:

- `@idea-intake` Step 0 is now the canonical enforcer of `docs/project-plan.md` §6 / §8. A change to the Progress checklist or the dependency matrix must be reflected in the agent body in the same PR.
- `@artifact-resolver` and `@owner-approval` are longer agent files. The trade-off is intentional: longer agent body, fewer files.

What this deliberately does **not** change:

- `@squad` persona definitions (Lead/Architect, Security Specialist, Automation Engineer, Tester/Validator, Scribe).
- The lab-owner identity check in [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) (`actor.login == ''contoso''`).
- `.squad/` charter ownership rules.
- The single `lab` environment scope.

## Alternatives considered

**Alternative A: Demote `/start-item` and `/new-checkin` to opt-in fallbacks behind a banner.** Reject. This re-introduces the redundancy 0013 already identified. A fallback that nobody reaches for accumulates drift.

**Alternative B: Keep both tracks; document the choice better.** Reject. ADR 0013 already tried this. The result was that contributors used the agent track and the prompt track silently bit-rotted.

**Alternative C: Collapse `@idea-intake` into a single end-to-end agent.** Reject. The three-agent split (intake / resolve / approve) maps cleanly onto the three lab-owner gates: "should this exist?", "is the artifact ready?", "should it merge?". Collapsing them loses the two-turn approval flow that protects against accidental merges.

**Alternative D: Move content-creation prompts into `@squad` as a fourth section of the agent body.** Reject. The prompts are interactive interviews with strict input validation (regex safety, sample-data rules). Inlining them into the agent body bloats `@squad`. Referencing them from `@squad` keeps each primitive doing what it does best.

## Citations

- [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes) — agents are persistent personas with scoped tools.
- [Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files) — prompts are one-shot task templates.
- [Customize AI in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview) — the four-primitive model.
- [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) — repo-local primitive-selection rules.
- [ADR 0013](0013-squad-agents-vs-prompt-pipeline.md) — the two-track ADR this one supersedes-in-part.
- [`docs/project-plan.md`](../project-plan.md) — the §6 / §8 gates that `@idea-intake` Step 0 now enforces inline.
