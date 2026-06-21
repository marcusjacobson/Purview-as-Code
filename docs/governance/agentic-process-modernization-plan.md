# Agentic process modernization plan

> Maintained by the Lead / Architect persona. Tracking issue: #680.
> This is a plan, not an implementation. It enumerates and sequences the work; each
> numbered slice ships later as its own `@idea-intake` -> `@artifact-resolver` ->
> `@owner-approval` item, one at a time, per the [`docs/project-plan.md`](../project-plan.md)
> one-feature-at-a-time cadence.

## Run metadata

| Field | Value |
|---|---|
| Date | 2026-06-18 |
| Branch | `docs/agentic-process-modernization-plan` |
| Tracking issue | #680 |
| Scope (this PR) | Documentation only (`docs/governance/`) |
| Scope (future slices) | Meta plane only (`docs/**`, `.github/**`) |
| Primary persona | Lead / Architect |
| Supporting personas | Automation Engineer, Scribe, Security Specialist |

## Purpose

We modernize this repo's agentic process across three goals without disturbing the
governance that already works:

1. **Purview-as-code structural automation** — make the build loop's gates explicit and
   give the GitHub-hosted (headless) agent the same environment the local loop has.
2. **Consistent, clean, secure code review** — package the existing hard rules as agent
   skills and a code-review surface so review quality does not depend on which model is
   loaded that day.
3. **Automated documentation** — keep the ADR index and script reference current through a
   scheduled loop that only ever *proposes* changes.

We add capability through three primitives only — **skills**, **scheduled loops**, and the
**GitHub-hosted coding agent** — and a **model-tier policy**. None of them introduces a new
lifecycle stage. See [Customize AI in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview).

## The non-negotiable invariant — augment, never replace

The lifecycle defined by [ADR 0014](../adr/0014-agents-as-default-entry-point.md) and
[ADR 0013](../adr/0013-squad-agents-vs-prompt-pipeline.md) is fixed. Every modernization in
this plan attaches to it; nothing inside the dashed box changes.

```text
        (new, optional)                  +=================================+
   scheduled loops ----> open issue ---> |  @idea-intake                   |
   (drift / surface /                    |     |                           |
    docs regen)                          |     v                           |
                                         |  /build-item  (G0-G5 gates)     |
   skills = knowledge the agents load -->|     |                           |
                                         |     v                           |
   GitHub coding agent =                 |  @artifact-resolver             |
   headless @artifact-resolver --------->|     |                           |
                                         |     v                           |
                                         |  @owner-approval (owner-only)   |
                                         +=================================+
                                                   |
                                                   v
                                          owner-approved -> merge
```

The four rules that make this an augmentation and not a replacement:

- **Skills are knowledge, not stages.** A skill is reference material an existing agent loads
  on demand. It never runs, never commits, never merges. It only changes what an agent
  *knows*, per [Customize AI in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview).
- **Loops only produce issues.** A scheduled loop runs read-only, detects a condition, and
  files a GitHub issue *upstream* of `@idea-intake`. It never deploys and never edits the data
  plane. The issue then flows through the unchanged lifecycle.
- **The GitHub-hosted coding agent is a headless `@artifact-resolver`.** It implements on a
  branch, validates, and opens a PR. It does not merge and does not deploy to the live Purview
  account. Merge stays with `@owner-approval` and the `owner-approved` label.
- **No new lifecycle stage.** There is exactly one entry (`@idea-intake`) and exactly one merge
  trigger (`owner-approved`). This plan adds zero stages between them.

## Gate ledger (G0-G5)

`/build-item` ([`build-item.prompt.md`](../../.github/prompts/build-item.prompt.md)) is the
single validation engine for both the local loop and the GitHub-hosted agent. We name its
gates explicitly so every slice can cite which gate proves it, and so the headless agent runs
the identical set.

| Gate | Name | What it checks | Where it runs today |
|---|---|---|---|
| G0 | Scope | Branch matches the lifecycle regex; upstream tracks `origin`; the diff stays inside the issue's file scope | `build-item` precondition check; `@idea-intake` Step 0 |
| G1 | Implement | Only the files named by the chosen item are produced; Microsoft Learn cited inline; synthetic identifiers only | `build-item` Step A |
| G2 | Lint / build | `az bicep lint` + `az bicep build` (infra); `yamllint` (data plane); `Invoke-ScriptAnalyzer` (scripts); `actionlint` (workflows); markdownlint / visual review (docs) | `build-item` Step B |
| G3 | Unit test | `./tests/Run-Pester.ps1` over `tests/**` for any `scripts/**` change | **Gap — see below** |
| G4 | Lab smoke | Item exit-criteria verification against `contoso.onmicrosoft.com` (`Get-AdminAuditLogConfig`, `Get-Label`, `Get-DlpCompliancePolicy`, ...); docs-only items skip | `build-item` Step C |
| G5 | Evidence | Per-domain pre-commit output + lab-smoke output + secrets-scan captured for the PR body | `build-item` Step D -> `@artifact-resolver` PR body |

### The G3 gap

[`build-item.prompt.md`](../../.github/prompts/build-item.prompt.md) Step B maps the
`scripts/**` path to `Invoke-ScriptAnalyzer` plus a `-WhatIf` smoke run, but it does **not**
name [`./tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1). The Pester suite therefore runs in
CI through the [`validate.yml`](../../.github/workflows/validate.yml) Pester job but is not a
named gate in the local or headless build loop. Slice 1 closes this gap so G3 is exercised
before a PR is opened, not only after.

## Model-tier policy

Models available in VS Code Chat change over time, and a hard-pinned single model fails the
agent when that model is briefly unavailable. The `model:` field on a custom agent accepts a
prioritized array — VS Code tries each entry until one is available — per the
[custom agent header schema](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional).
We standardize three tiers, each expressed as a vendor-mixed prioritized array.

| Tier | Use for | Illustrative prioritized `model:` array |
|---|---|---|
| `fast` | High-volume, deterministic, low-ambiguity work: label routing, ADR-index and script-reference regeneration, surface-diff loops | a small/fast model first, falling back across the Microsoft MAI, OpenAI GPT, and Anthropic Claude small tiers |
| `balanced` | Default implement-and-validate work: `@idea-intake` classification, `@artifact-resolver` implementation, `/build-item` iteration | a mid-tier GPT first, falling back to a mid-tier Claude and a Microsoft MAI model |
| `reasoning` | Deep analysis: ADR authoring, `/security-review`, architectural design, the model-policy review itself | a top-tier reasoning model first (Claude or GPT), falling back across vendors |

Rules:

- **Arrays, not single names.** Every lifecycle and persona agent uses a prioritized array so a
  transient model outage degrades gracefully instead of breaking the agent. The current pin of
  a single model is the state slice 3 replaces.
- **Mix vendors.** Each array spans Microsoft MAI, OpenAI GPT, and Anthropic Claude so no single
  vendor's availability is a single point of failure.
- **Behavior is the contract, not the model.** Tool lists and instructions define what an agent
  may do. Changing the tier never widens an agent's tool surface.
- **Recurring review cadence.** The tier-to-array mapping is reviewed on a fixed cadence
  (proposed: quarterly) as its own `@idea-intake` item. The review re-checks each array against
  the models actually offered in the VS Code model picker and updates the canonical
  `docs/governance/model-policy.md`. Illustrative identifiers above are not authoritative —
  the policy doc is.

## Cross-cutting invariants — the "didn't break anything" guardrails

Every slice below preserves all of the following. A slice that cannot is not ready to ship.

- **Lifecycle unchanged.** `@idea-intake` -> `/build-item` -> `@artifact-resolver` ->
  `@owner-approval` is the only path. No slice adds, removes, or reorders a stage.
- **`owner-approved` is the only merge trigger.** Enforced by
  [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) and the owner identity gate.
- **Loops produce issues only.** No scheduled workflow deploys, mutates the data plane, or
  edits source. It opens an issue (or, for slice 9, a docs-only PR) and stops.
- **The headless agent never deploys.** The GitHub-hosted coding agent authors PRs; it does not
  call the live Purview account.
- **New workflows are secure by default.** OIDC federated auth, third-party actions pinned to a
  commit SHA, least-privilege `permissions:`, and no script-injection sinks, per
  [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md)
  and [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions).
- **Microsoft Learn cited on every new capability.** Per the grounding rules in
  [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).
- **No secrets, no real identifiers.** Zero-GUID placeholders and synthetic sample data only,
  per [`security.instructions.md`](../../.github/instructions/security.instructions.md) and
  [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md).

## Reviewing loop output (the review queue)

Every scheduled loop's only output is a GitHub issue (the "augment, never replace" invariant above). To
keep those suggestions discoverable instead of lost in the backlog, each loop stamps a **stable per-loop
marker label**, the `squad:*` routing labels applied by
[`issue-triage.yml`](../../.github/workflows/issue-triage.yml), and `needs-review`, and dedupes against the
open issue carrying its marker label before filing a second one. The open marker-labeled issues are the
**review queue**:

| Loop | Marker label | Review queue (open issues) |
|---|---|---|
| Slice 7 — drift-detection | `drift-detected` | [open `drift-detected`](../../issues?q=is%3Aissue+is%3Aopen+label%3Adrift-detected) |
| Slice 8 — surface-watch | `surface-watch` | [open `surface-watch`](../../issues?q=is%3Aissue+is%3Aopen+label%3Asurface-watch) |
| Slice 12 — code-currency | `code-currency` | [open `code-currency`](../../issues?q=is%3Aissue+is%3Aopen+label%3Acode-currency) |
| Slice 13 — feature-currency | `feature-currency` | [open `feature-currency`](../../issues?q=is%3Aissue+is%3Aopen+label%3Afeature-currency) |

The `code-currency` and `feature-currency` labels are created when their slices ship. A reviewer triages
the queue and runs each issue through the unchanged `@idea-intake` → `/build-item` → `@artifact-resolver`
→ `@owner-approval` lifecycle — the loop output is an *input* to that flow, never a merge. This is decided
by [ADR 0044](../adr/0044-currency-watch-loops.md).

## Rollout — numbered slices

Each slice is one deliverable, shipped on its own branch through the full lifecycle, in the
order below. Earlier slices harden the loop that later slices rely on. Every slice lists a
**simple check** (the one verification that proves it works) and a **regression guard** (what
must still pass to prove nothing broke).

### Slice 1 — Gate ledger and the G3 Pester gap

| Field | Value |
|---|---|
| Deliverable | Document G0-G5 in the build loop and add `./tests/Run-Pester.ps1` as the named G3 gate for `scripts/**` changes |
| Files touched | [`.github/prompts/build-item.prompt.md`](../../.github/prompts/build-item.prompt.md) |
| Simple check | Step B's `scripts/**` row names `./tests/Run-Pester.ps1`; the prompt enumerates G0-G5; markdownlint / visual review clean |
| Regression guard | Steps A-D and all hard rules preserved; ADR 0014 links intact; the [`validate.yml`](../../.github/workflows/validate.yml) Pester job is unchanged |
| Future commit | `feat(instructions)` |
| Primary persona | Tester / Validator (supporting: Automation Engineer) |
| Governing instructions | [`tests.instructions.md`](../../.github/instructions/tests.instructions.md), [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) |

### Slice 2 — `copilot-setup-steps.yml` for cloud parity

| Field | Value |
|---|---|
| Deliverable | A `copilot-setup-steps.yml` workflow that installs the build-loop toolchain so the GitHub-hosted agent runs the same G2/G3 gates as the local loop |
| Files touched | `.github/workflows/copilot-setup-steps.yml` (new) |
| Simple check | `actionlint` clean; the job installs Pester, PSScriptAnalyzer, `powershell-yaml`, and the Bicep CLI |
| Regression guard | [`validate.yml`](../../.github/workflows/validate.yml) untouched; pinned action SHAs; OIDC retained; least-privilege `permissions:` |
| Future commit | `ci(ci)` |
| Primary persona | Automation Engineer |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) |

### Slice 3 — Model-tier policy

| Field | Value |
|---|---|
| Deliverable | An ADR for the model-tier policy, a canonical `docs/governance/model-policy.md`, and conversion of the lifecycle and persona agents' `model:` field to prioritized arrays |
| Files touched | `docs/adr/<next>-model-tier-policy.md` (new), `docs/governance/model-policy.md` (new), [`.github/agents/`](../../.github/agents/) `*.agent.md` |
| Simple check | Each `*.agent.md` parses without error in Chat agent diagnostics; each `model:` array is valid YAML |
| Regression guard | Every agent's `tools:` list and instructions are byte-for-byte unchanged; behavior preserved; [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) model-field requirement still satisfied |
| Future commit | `docs(docs)` for the policy artifacts; `refactor(instructions)` for the agent-array conversion |
| Primary persona | Lead / Architect (supporting: Automation Engineer) |
| Governing instructions | [`agents.instructions.md`](../../.github/instructions/agents.instructions.md), [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) |

### Slice 4 — `code-review` skill

| Field | Value |
|---|---|
| Deliverable | A `.github/skills/code-review/SKILL.md` that packages the repo's existing review hard rules (secrets-scan regex, identifier placeholders, Learn-citation requirement) as loadable knowledge |
| Files touched | `.github/skills/code-review/SKILL.md` (new) |
| Simple check | The skill validates; secrets-scan regex, zero-GUID placeholder rule, and Learn-citation rule are all represented |
| Regression guard | The skill *single-sources* from the existing `.instructions.md` files (it restates, never diverges); no instruction file is edited to fit the skill |
| Future commit | `feat(instructions)` |
| Primary persona | Security Specialist |
| Governing instructions | [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md), [`security.instructions.md`](../../.github/instructions/security.instructions.md), [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) |

### Slice 5 — `purview-reconciler`, `learn-grounding`, and `adr-author` skills

| Field | Value |
|---|---|
| Deliverable | Three skills: reconciler authoring conventions, Microsoft Learn grounding discipline, and ADR authoring |
| Files touched | `.github/skills/purview-reconciler/SKILL.md`, `.github/skills/learn-grounding/SKILL.md`, `.github/skills/adr-author/SKILL.md` (all new) |
| Simple check | Each `SKILL.md` validates; the reconciler skill names the `SupportsShouldProcess` / `PruneMissing` / `ExportCurrentState` tokens the [`validate.yml`](../../.github/workflows/validate.yml) full-circle-contract guard checks |
| Regression guard | No prompt file is duplicated into a skill; the reconciler contract matches `powershell.instructions.md`; the full-circle guard still passes |
| Future commit | `feat(instructions)` |
| Primary persona | Automation Engineer (supporting: Scribe) |
| Governing instructions | [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md), [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md) |

### Slice 6 — Handoffs frontmatter

| Field | Value |
|---|---|
| Deliverable | Declare `handoffs` frontmatter across the three lifecycle agents so the flow is explicit in the agent definitions |
| Files touched | [`.github/agents/idea-intake.agent.md`](../../.github/agents/idea-intake.agent.md), [`.github/agents/artifact-resolver.agent.md`](../../.github/agents/artifact-resolver.agent.md), [`.github/agents/owner-approval.agent.md`](../../.github/agents/owner-approval.agent.md) |
| Simple check | Each handoff target exists; `send: false` into every write-capable target (no auto-dispatch into an implementer or merger) |
| Regression guard | The ADR 0014 flow is unchanged; [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) handoff rules satisfied; tool lists unchanged |
| Future commit | `refactor(instructions)` |
| Primary persona | Automation Engineer |
| Governing instructions | [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) |

### Slice 7 — Drift-detection loop

| Field | Value |
|---|---|
| Deliverable | A scheduled workflow that runs the reconcilers read-only, detects drift between the repo and the live tenant, and opens an issue routed to `@idea-intake` |
| Files touched | `.github/workflows/drift-detection.yml` (new) |
| Simple check | On simulated drift the workflow opens exactly one issue; every tenant call is `-WhatIf` / read-only; no deploy step exists |
| Regression guard | Read-only default per [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) and security principle #9; [`issue-triage.yml`](../../.github/workflows/issue-triage.yml) routing still applies |
| Future commit | `feat(ci)` |
| Primary persona | Automation Engineer (supporting: Security Specialist) |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md), [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md), [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) |

### Slice 8 — Surface-watch loop

| Field | Value |
|---|---|
| Deliverable | A scheduled workflow that diffs the Microsoft Purview documentation surface against the [`docs/project-plan.md`](../project-plan.md) section 3 feature inventory and opens an issue when they diverge |
| Files touched | `.github/workflows/surface-watch.yml` (new) |
| Simple check | The workflow opens an issue when the section 3 inventory diff is non-empty, and stays silent when it is empty |
| Regression guard | Reuses the section 3 surface-completeness contract; read-only; opens issues only |
| Future commit | `feat(ci)` |
| Primary persona | Automation Engineer (supporting: Scribe) |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md), [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md) |

### Slice 9 — Automated documentation loop

| Field | Value |
|---|---|
| Deliverable | A scheduled workflow that regenerates the ADR index and the script reference and opens a docs-only PR when they are stale |
| Files touched | `.github/workflows/docs-regen.yml` (new); regenerates [`docs/adr/README.md`](../adr/README.md) and the script reference |
| Simple check | The regenerated ADR index matches the ADR set on disk; the workflow opens a docs-only PR, never a mixed-plane PR |
| Regression guard | Docs-only PRs stay docs-only per [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md); markdown rules per [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md); `owner-approved` still gates merge |
| Future commit | `feat(ci)` |
| Primary persona | Scribe (supporting: Automation Engineer) |
| Governing instructions | [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md), [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) |

### Slice 10 — Solution-doc freshness loop

| Field | Value |
|---|---|
| Deliverable | An advisory per-PR workflow that flags when a Microsoft Purview solution's reconciler or desired-state YAML changes without its guide under [`docs/solutions/`](../solutions/), driven by a feature-to-doc map |
| Files touched | `.github/workflows/docs-freshness.yml` (new), [`docs/solutions/.solution-map.yml`](../solutions/.solution-map.yml) (new) |
| Simple check | On a PR that edits a reconciler without its guide, the job emits a `::warning::` naming the guide and exits 0; on an aligned PR it is silent |
| Regression guard | Read-only (git + filesystem only); least-privilege `permissions:` (`contents: read`); advisory-only (always exits 0) so it never gates merge; complements [`docs-regen.yml`](../../.github/workflows/docs-regen.yml) (mechanical indexes) with no overlap |
| Future commit | `feat(ci)` |
| Primary persona | Automation Engineer (supporting: Scribe) |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md), [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md) |

### Slice 11 — Solution-guide wiki and `docs-maintenance` skill

| Field | Value |
|---|---|
| Deliverable | Per-feature operational guides under [`docs/solutions/`](../solutions/) for every governed Purview solution (information protection, compliance, Data Map, Unified Catalog), plus a `docs-maintenance` skill packaging the page template, the Learn evidence pattern, and the freshness checklist |
| Files touched | `docs/solutions/**` (new guides + area indexes + top-level index), `.github/skills/docs-maintenance/SKILL.md` (new) |
| Simple check | Every row in [`docs/solutions/.solution-map.yml`](../solutions/.solution-map.yml) resolves to an existing guide; the skill validates and single-sources from `markdown.instructions.md` + `copilot-instructions.md` |
| Regression guard | Guides cite Microsoft Learn per the evidence pattern; no real identifiers; the skill restates — never diverges from — the canonical instruction files; docs-only PRs stay docs-only |
| Future commit | `docs(docs)` for the guides; `feat(instructions)` for the skill |
| Primary persona | Scribe (supporting: Automation Engineer, Security Specialist) |
| Governing instructions | [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md), [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md), [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) |

### Slice 12 — Code-currency watch loop

| Field | Value |
|---|---|
| Deliverable | A scheduled GitHub Actions workflow that inventories the pinned REST `api-version` literals and cmdlet / module surface in `scripts/**` (and `infra/**`), fetches the matching Microsoft Learn reference pages read-only, and opens an issue routed to `@idea-intake` (stamped `code-currency` + `squad:*` + `needs-review`; see [Reviewing loop output](#reviewing-loop-output-the-review-queue)) when a page is marked retired / deprecated or documents a newer GA `api-version`. Decided by [ADR 0044](../adr/0044-currency-watch-loops.md) |
| Files touched | `.github/workflows/code-currency-watch.yml` (new) |
| Simple check | On a simulated stale `api-version` the workflow opens exactly one issue and dedupes against an open `code-currency` issue; on a current surface it stays silent; every fetch is read-only and no deploy / auth step exists |
| Regression guard | Read-only default per [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) and security principle #9; pinned action SHAs; least-privilege `permissions:` (`contents: read`, `issues: write`); reuses the surface-watch issue-dedupe pattern; the `powershell` / `bicep` "deprecation triggers migration" rules are unchanged |
| Future commit | `feat(ci)` |
| Primary persona | Automation Engineer (supporting: Security Specialist) |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md), [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md), [`bicep.instructions.md`](../../.github/instructions/bicep.instructions.md), [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) |

### Slice 13 — Feature-currency ("what's new") watch loop

| Field | Value |
|---|---|
| Deliverable | A scheduled GitHub Copilot cloud-agent automation that reads the [What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new) page, cross-references the [`docs/project-plan.md`](../project-plan.md) §3 inventory and §7 out-of-scope list, and opens an issue routed to `@idea-intake` (stamped `feature-currency` + `squad:*` + `needs-review`; see [Reviewing loop output](#reviewing-loop-output-the-review-queue)) summarizing net-new Purview features and any newly-documented as-code (PowerShell / REST / Graph) surface. Decided by [ADR 0044](../adr/0044-currency-watch-loops.md) |
| Files touched | A committed canonical copy of the automation prompt + operator note under `.github/copilot-automations/` (the live automation is configured in the GitHub UI per [Creating automations with Copilot cloud agent](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-automations)) |
| Simple check | On its schedule the automation opens exactly one issue summarizing What's-new deltas; on an empty delta it stays silent; its tool list permits issue creation only — no pull request, no deploy, no data-plane call |
| Regression guard | "Loops produce issues only" invariant preserved by the issue-only tool scope; depends on the repo staying **private or internal** (Copilot automations are unavailable in public repos) — if the repo goes public this slice falls back to a deterministic surface-watch extension; `surface-watch.yml` (Slice 8) deterministic contract untouched (this loop complements, not replaces it); model-tier `reasoning` per [ADR 0043](../adr/0043-model-tier-policy.md) |
| Future commit | `feat(ci)` for the automation wiring; `docs(docs)` for the committed prompt artifact |
| Primary persona | Automation Engineer (supporting: Scribe, Lead / Architect) |
| Governing instructions | [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md), [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md), [`primitives.instructions.md`](../../.github/instructions/primitives.instructions.md), [`markdown.instructions.md`](../../.github/instructions/markdown.instructions.md) |

## Sequencing and dependencies

- **Slice 1 before slice 2.** The cloud setup workflow mirrors the gate ledger, so the ledger
  must be named first.
- **Slice 4 before slice 5.** The `code-review` skill establishes the single-source-from-
  instructions pattern that the other skills follow.
- **Slices 7-9 last.** The loops feed the lifecycle, so the lifecycle hardening (slices 1-6)
  ships first.
- **Slices 10-11 extend the documentation track.** Slice 10 reuses the docs-only-PR discipline
  from slice 9 and the read-only-loop pattern from slices 7-8; slice 11 follows the
  single-source-from-instructions skill pattern from slices 4-5. Slice 11's guides are the target
  the slice-10 freshness check measures against, so they ship together.
- **Slices 12-13 are the currency track.** They follow the read-only-loop, issue-only pattern from
  slices 7-8. Slice 12 (code-currency) reuses the deterministic GitHub Actions mechanism; slice 13
  (feature-currency "what's new") uses a Copilot cloud-agent automation for the open-ended
  "now as-code / in scope" judgment a deterministic diff cannot make. Both are decided by
  [ADR 0044](../adr/0044-currency-watch-loops.md). Slice 13 requires the repo to stay private or internal.
- **Downstream ADRs (enumerated, not authored here):** the model-tier policy ADR (slice 3) and
  an "augment, never replace" principle ADR. Both take the next free ADR number at authoring
  time (the ADR set currently runs through `0042`).
- **Commit-scope follow-up.** [`commit-message.instructions.md`](../../.github/instructions/commit-message.instructions.md)
  has no `skills` scope today. Slices 4 and 5 either map skill changes to the meta
  `instructions` scope or add a `skills` scope in the same PR; the plan flags this so the choice
  is deliberate, not accidental.

## Out of scope for this plan

- Implementing any slice. Each slice is a separate future `@idea-intake` item.
- Authoring the model-policy ADR or the "augment, never replace" ADR. This document *enumerates*
  them; it does not write them.
- Any change to `.github/agents/**`, `.github/workflows/**`, `.github/skills/**`, or
  `build-item.prompt.md` in this PR. This PR is the plan, not the build.
- Any live-tenant call.

## References

- **[Customize AI responses in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview)**
  — the customization model (instructions, prompt files, custom agents, skills) this plan builds on.
- **[Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes)**
  — custom agent definition and the optional `model:` header used by the model-tier policy.
- **[Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files)**
  — why `/build-item` is a prompt file and not a lifecycle stage.
- **[Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions)**
  — OIDC, pinned actions, least-privilege `permissions:`, and script-injection avoidance for slices 2 and 7-9.
- **[Best practices for using GitHub Copilot](https://docs.github.com/en/copilot/get-started/best-practices)**
  — guidance on scoping work and starting clean sessions, which the loop-produces-issues model follows.
- **[About GitHub Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent)**
  and **[About Copilot automations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations)**
  — the scheduled cloud-agent automation primitive used by slice 13 (private-repo only).
- **[What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new)**
  — the feature-currency source the slice-13 automation reads.
- [ADR 0013 — Squad agents vs. prompt pipeline](../adr/0013-squad-agents-vs-prompt-pipeline.md)
- [ADR 0014 — Agents as the default entry point](../adr/0014-agents-as-default-entry-point.md)
- [ADR 0044 — Code- and feature-currency watch loops](../adr/0044-currency-watch-loops.md) — decides slices 12-13.
- [`build-item.prompt.md`](../../.github/prompts/build-item.prompt.md) — the validation engine the gate ledger formalizes.
