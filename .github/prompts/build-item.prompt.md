---
description: "Iterate: implement, locally validate, and lab smoke-test the scoped item on its issue branch. Loops until the author is satisfied. Never commits or pushes."
mode: agent
---

# Build item (implement + test loop)

Use this prompt as the iteration phase — edit, validate, deploy to the lab, verify, repeat — until the artifact is working. It runs **on the issue branch** created by [`@idea-intake`](../agents/idea-intake.agent.md), and stops before commit/push/PR-open, which belong to [`@artifact-resolver`](../agents/artifact-resolver.agent.md).

Per [ADR 0014](../../docs/adr/0014-agents-as-default-entry-point.md), this prompt is the shared validation engine for both human-driven build loops and the agent flow. The per-domain pre-commit checklists exercised here are the canonical evidence for every PR.

**This prompt never runs `git add`, `git commit`, `git push`, or opens a PR.** Those belong to `@artifact-resolver`. If the agent is tempted to commit mid-build, it has misunderstood the phase boundary.

## Gate ledger (G0-G5)

The build loop is gated. Each gate carries a stable identifier (G0–G5) so every checklist item can cite which gate proves it, and so the GitHub-hosted (headless) [`@artifact-resolver`](../agents/artifact-resolver.agent.md) runs the identical set the local loop does. The gates are **not** extra steps — they map onto the precondition check and Steps A–D below.

| Gate | Name | What it checks | Where it runs in this prompt |
|---|---|---|---|
| G0 | Scope | Branch matches the lifecycle regex; upstream tracks `origin`; the working diff stays inside the issue's file scope | [Precondition check](#precondition-check) (also enforced by [`@idea-intake`](../agents/idea-intake.agent.md) Step 0) |
| G1 | Implement | Only the files named by the chosen item are produced; Microsoft Learn cited inline; synthetic identifiers only | [Step A — Implement or iterate](#step-a--implement-or-iterate) |
| G2 | Lint / build | `az bicep lint` + `az bicep build` (infra); `yamllint` (data plane); `Invoke-ScriptAnalyzer` (scripts); `actionlint` (workflows); markdownlint / visual review (docs) | [Step B — Local validation](#step-b--local-validation) |
| G3 | Unit test | [`./tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) over `tests/**` for any `scripts/**` change | [Step B — Local validation](#step-b--local-validation) |
| G4 | Lab smoke | Item exit-criteria verification against `<tenantDomain>` (read from `infra/parameters/lab.yaml`); docs-only items skip | [Step C — Lab smoke test](#step-c--lab-smoke-test) |
| G5 | Evidence | Per-domain pre-commit output + lab-smoke output + secrets-scan captured for the PR body | [Step D — Decide](#step-d--decide) → `@artifact-resolver` PR body |

## Precondition check

This precondition is gate **G0 (Scope)** in the [gate ledger](#gate-ledger-g0-g5).

```pwsh
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

- Current branch must match `^(feat|fix|chore|docs|refactor|ci|build|test|perf|revert)/(w[0-4]-)?[a-z0-9-]+$`. If not, stop and tell the user to invoke `@idea-intake` to file the issue and create the branch first.
- Upstream must be `origin/<same branch>`.
- Working tree may be clean (first build pass) or dirty (subsequent iterations). Both are fine.

Restate the issue and acceptance criteria the user is building against. If you cannot find them in chat history, ask — do not guess.

## The build loop

Repeat the loop below until the author explicitly says the build is done. There is no fixed iteration count.

### Step A — Implement or iterate

This step is gate **G1 (Implement)**.

Produce **only** the files named by the one chosen checklist item.

- Consult [`.github/copilot-instructions.md`](../copilot-instructions.md) first, then the scoped rule file(s) that match the changed paths (see the Rules map).
- Cite Microsoft Learn inline in every new resource / cmdlet / REST endpoint, per the "Grounding" section of `copilot-instructions.md`.
- Use synthetic identifiers only per [`sample-data.instructions.md`](../instructions/sample-data.instructions.md).
- If the diff starts touching files outside the scoped item, stop. Ask the user whether to (a) split into a separate PR, or (b) narrow the scope.

### Step B — Local validation

This step covers gate **G2 (Lint / build)** and gate **G3 (Unit test)**.

Run the per-domain commands from [`.github/instructions/pre-commit.instructions.md`](../instructions/pre-commit.instructions.md) for every touched folder. Capture the output — the author will need it later for the PR description.

| Touched path | Gate(s) | Commands |
|---|---|---|
| `infra/**` | G2 | `az bicep lint`, `az bicep build`, `az deployment group what-if` (via [`deploy-infra.prompt.md`](deploy-infra.prompt.md)) |
| `data-plane/**` | G2 | `yamllint data-plane/<area>/`, plus `Deploy-*.ps1 -WhatIf` for the script this item touches |
| `scripts/**` | G2 + G3 | `Invoke-ScriptAnalyzer -Path <file>` plus a `-WhatIf` smoke run (G2); then [`./tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) to exercise the matching `tests/**` suite (G3) |
| `.github/workflows/**` | G2 | `actionlint` if installed; otherwise note the successful run URL on a branch push |
| `docs/**` only | G2 | markdownlint if installed; otherwise visual review |

Any `scripts/**` change runs the Pester suite via [`./tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) **before** checkin (gate G3), not only afterward in CI through the [`validate.yml`](../workflows/validate.yml) `pester` job. If the change adds or alters a function, add or update its `tests/scripts/<ScriptName>.Tests.ps1` per [`tests.instructions.md`](../instructions/tests.instructions.md) so the suite stays green.

If any lint / analyzer / test emits an error or warning, stop and fix it. Do not suppress warnings.

### Step C — Lab smoke test

This step is gate **G4 (Lab smoke)**.

Deploy to the lab tenant `<tenantDomain>` — read `automation.tenantDomain` from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml) (the single source of truth per [ADR 0012](../../docs/adr/0012-environment-parameters-file.md)); never hardcode a tenant domain here — and run the item's exit-criteria verification (from the Exit criteria block on the GitHub issue linked from the [`docs/project-plan.md`](../../docs/project-plan.md) Progress checklist row). Examples:

- Unified audit log row → `Get-AdminAuditLogConfig`
- Sensitivity labels row → `Get-Label`
- DLP row → `Get-DlpCompliancePolicy`

Docs-only items (ADRs, README edits) skip Step C — their exit criteria are the review itself.

Redact tenant, subscription, and object IDs to `00000000-0000-0000-0000-000000000000` before pasting anything into chat or a scratch file.

### Step D — Decide

This step produces gate **G5 (Evidence)** — the consolidated evidence block `@artifact-resolver` pastes into the PR description.

Ask the author:

> "Build pass complete. Local validation: <summary>. Lab smoke test: <summary>. Options: (a) `ready for checkin` to hand off to `@artifact-resolver`, (b) describe another change, (c) `abandon` to leave the branch in place and return to it later."

Acceptable responses:

- **`ready for checkin`** — exit the loop. Summarize the final evidence block that `@artifact-resolver` will need in the PR description, then stop.
- **Describe another change** — return to Step A with the new scope.
- **`abandon`** — stop and leave the branch. Remind the user that an abandoned branch must either be resumed or deleted; it must not linger across a second item's `@idea-intake` invocation (hard rule #5 in `@idea-intake`).

## Hard rules (agent must refuse to violate)

1. **Never run `git add`, `git commit`, `git push`, or `gh pr create`.** The author's commit/push/PR work belongs to `@artifact-resolver`.
2. **Never edit files outside the scoped checklist item.** If a refactor is tempting, stop and propose a separate item.
3. **Never suppress a lint or analyzer warning** to make Step B "pass". Fix the underlying code.
4. **Never paste real tenant, subscription, or object IDs** into chat or any file. Redact to the zero GUID.
5. **Never skip Step C for a state-changing item.** If the exit criteria require a lab verification, run it. Docs-only items are the only exception.
6. **Never loop forever without the author's input.** Each loop iteration ends at Step D and waits.
