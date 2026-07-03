# ADR 0045 — implementation plan

Tracking plan for implementing [ADR 0045](0045-template-kickoff-spinoff-model.md) — the template
kickoff and spin-off consumption model with a no-push-back guard. Each task below is its own
GitHub issue and ships as its own agent-led item; the tasks are ordered so each one merges before
the next starts.

Issue references (`#N`) are GitHub issue numbers in this repository.

## Lifecycle and gates

Every task runs through the default agent flow — `@idea-intake` → `@artifact-resolver` →
`@owner-approval` — one item at a time, per [ADR 0014](0014-agents-as-default-entry-point.md). The
`needs-review` label is applied only when a task is actively started, not while it sits in the
backlog. Each task's pull request must satisfy the cross-cutting
[pre-commit checklist](../../.github/instructions/pre-commit.instructions.md) (secrets-scan, Learn
citations, CHANGELOG entry) plus the per-domain gates named in its row below.

## Tasks

| Order | Status | Issue | Task | Depends on | Key gates |
|---|:---:|---|---|---|---|
| 0 | ☐ | #6 | Make `pr-auto-merge.yml` owner gate data-driven via the `OWNER_APPROVAL_LOGIN` repo variable (prerequisite — unblocks auto-merge) | — | github-actions pre-commit; docs; CHANGELOG |
| 1 | ☐ | #7 | Add `@operator-kickoff` agent + four-layer no-push-back guard | ADR 0045 (#4) | agents rules; `Invoke-ScriptAnalyzer` + `-WhatIf`; Pester; secrets-scan; CHANGELOG |
| 2 | ☐ | #8 | Rewrite onboarding (README, tenant-onboarding, agents index) for the kickoff flow | #7 | markdown rules; docs-freshness; CHANGELOG |
| 3 | ☐ | #9 | Mark the source repository as a GitHub template | #7 | repo-setting verify (`isTemplate`); markdown; CHANGELOG |

Tick a row's status when its issue's exit criteria are verified and its PR is merged.

## Task detail

### Task 0 — #6 — data-driven auto-merge owner gate

`pr-auto-merge.yml` hardcoded the owner login as `contoso`, so auto-merge failed on any real clone
(this blocked PR #5 and PR #11). The gate now reads the `OWNER_APPROVAL_LOGIN` repository variable
instead — no owner login in source, and a consumer sets the variable once (no per-clone source
edit), aligning with the identifier-boundary principle. Recommended prerequisite because broken
auto-merge affects every later task's merge.

### Task 1 — #7 — `@operator-kickoff` agent and guard

The core ADR 0045 capability: a new front-door agent (sibling of `@operator-tenant`) that offers
the two consumption modes (local-only workspace vs. spin-off GitHub repo), installs the four-layer
no-push-back guard, verifies it, then hands off to `@operator-tenant`. Blocked by nothing beyond
the merged ADR (#4); best sequenced after Task 0 so its own PR can auto-merge.

### Task 2 — #8 — rewrite onboarding for the kickoff flow

Reorder the consumer-facing docs so the kickoff step (`@operator-kickoff`) comes before tenant
tailoring (`@operator-tenant`). Blocked by #7 — the docs must describe an agent that exists.

### Task 3 — #9 — mark the source repository as a GitHub template

Set `is_template: true` on the canonical repo so consumers are steered to "Use this template" (the
spin-off path ADR 0045 prefers, because a template-generated repo cannot open a pull request back
to the source). Blocked by #7 so the kickoff flow that references it is in place.

## References

- [ADR 0045 — Template kickoff and spin-off consumption model with a no-push-back guard](0045-template-kickoff-spinoff-model.md)
- [ADR 0014 — Agents as the default entry point](0014-agents-as-default-entry-point.md)
- [Pre-commit checklist](../../.github/instructions/pre-commit.instructions.md)
