# 0052 — The destructive-operation confirmation gate belongs at the script layer, via `ShouldContinue`

- **Status:** Accepted
- **Date:** 2026-07-13
- **Gates:** Cross-cutting foundation. Supersedes the "No CI-layer concerns" rule at [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"Direction-policy contract (ADR 0029)" and reconciles the two incompatible definitions of `-Force` in the same file. Amends the "no local-script escape hatch" claim in [ADR 0029](0029-source-of-truth-direction-policy.md) §Consequences. Repairs [ADR 0035](0035-records-seed-content-immovable.md), whose seed-skip baseline was orphaned when [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) retired `deploy-data-plane.yml`. Reference implementation lands on `Deploy-Labels.ps1`, `Deploy-FilePlan.ps1`, and `Deploy-DLPPolicies.ps1`; rollout to the remaining 18 reconcilers is [#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83) and the repo-wide guard test is [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84). Does not appear in [`docs/project-plan.md`](../project-plan.md) §8 — this is implementation-pattern scaffolding, not a wave-blocking question.
- **Deciders:** @marcusjacobson

## Context

[`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"Idempotency and safety" has carried this rule since the reconcilers first shipped:

> Any delete / prune operation must be gated behind an explicit `-PruneMissing` (or equivalent) switch that defaults to `$false` and **emits a confirmation prompt unless `-Force` is also set**.

No such prompt has ever been emitted. Not once, in any of the 21 `Deploy-*.ps1` reconcilers. This ADR is not proposing a new safety feature — it is closing a **live violation of a written contract** that has been silently broken for the entire life of the repo.

### The defect

Twenty of the twenty-one reconcilers declare:

```powershell
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', ...)]
```

PowerShell raises a `ShouldProcess` confirmation prompt **only when `ConfirmImpact >= $ConfirmPreference`**. The default `$ConfirmPreference` is `High`. `Medium < High`, therefore:

> **Every `$PSCmdlet.ShouldProcess(...)` call in every reconciler returns `$true` without ever prompting.**

`-WhatIf` still works correctly (the `WhatIfPreference` check inside `ShouldProcess` is independent of the impact comparison), which is exactly why the defect survived so long: the dry-run path — the path everyone actually exercises — behaves perfectly. The confirm path is dead code. `Deploy-UnifiedCatalogPolicies.ps1` is the sole reconciler already at `ConfirmImpact = 'High'`, and it got there by accident of authoring order, not by design.

A grep for the defect is easy to get wrong, which is worth recording so the next person does not conclude the repo is clean: the on-disk spelling is `ConfirmImpact = 'Medium'` **with spaces around the `=`**. `grep "ConfirmImpact='Medium'"` returns zero matches and a false sense of safety. The whitespace-tolerant pattern `ConfirmImpact\s*=\s*'Medium'` returns 32 files, 20 of them reconcilers.

### Why the workflow gate is necessary but not sufficient

[ADR 0029](0029-source-of-truth-direction-policy.md) put a typed-token confirmation (`confirm_overwrite = 'overwrite portal'`, alongside the pre-existing `confirm_prune = 'confirm prune'`) in the workflow's pre-flight step, and §Consequences claims the result closes the loop:

> "No portal-side workaround, **no local-script escape hatch**."

That claim is false, and it was false the day it was written. **The local script *is* the escape hatch — and always was — because the gate was layered where the local path does not traverse.** A workflow input cannot defend a code path that never enters a workflow. An operator at a terminal running:

```pwsh
./scripts/Deploy-FilePlan.ps1 -PruneMissing
```

clears no token, answers no prompt, and gets no second chance. ADR 0029's gate is real, it works, and it protects the CI path; it simply cannot see the local path.

The evidence that this is not a theoretical concern: `Deploy-FilePlan.ps1` has **no workflow caller at all**. Grep `.github/workflows/` for `Deploy-FilePlan` and you get nothing. Its only caller was the monolithic `deploy-data-plane.yml`, which [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) retired. For that reconciler, "the local terminal" is not one of two paths — it is the *only* path, defended by a prompt that never fires.

### `ShouldProcess` cannot be the fix

The obvious repair — raise `ConfirmImpact` to `'High'` and call it done — is insufficient on its own, because it leaves the safety of the destructive branch coupled to a *caller-controlled preference variable*. Any of the following silently disarms it again:

- a caller (or a profile, or a module) that sets `$ConfirmPreference = 'None'`;
- a future contributor who "tidies" the impact level back to `Medium`, reintroducing the exact defect;
- a reconciler authored from an existing one by copy-paste, inheriting `Medium` from its template.

`ShouldProcess`'s prompting behaviour is, by design, a *negotiation* between the cmdlet's declared impact and the caller's declared preference. That is the right design for a general-purpose cmdlet. It is the wrong design for an irreversible tenant delete, where the answer to "should I ask first?" must not be negotiable.

`ShouldContinue` has no impact/preference comparison at all. It prompts unconditionally, whenever it is reached. That is precisely the property this gate needs, and it is why the fix is a change of *method*, not merely a change of *constant*.

### The `-Force` overload is a three-way collision, and one arm is fiction

`powershell.instructions.md` defines `-Force` twice, incompatibly:

- **Line 167** (`Required switches on every Deploy-*.ps1`): "Allow overwriting objects whose `lastModifiedBy` is not the current deploy principal."
- **Line 267** (`Idempotency and safety`): the switch that suppresses the prune confirmation prompt.

Reading the code reveals a **third** meaning, and it is the only one that is actually implemented. In all three reference reconcilers, `$Force` is consulted at exactly one place: the `-ExportCurrentState` guard that refuses to clobber a non-empty managed block in the target YAML (`Deploy-Labels.ps1`, `Deploy-FilePlan.ps1`, `Deploy-DLPPolicies.ps1`).

The line-167 meaning is not merely unimplemented — it is **unimplementable on this surface**, and `Deploy-Labels.ps1`'s own header has said so all along:

> `Conflict -- not produced. Sensitivity-label cmdlets do not expose a per-label `lastModifiedBy` we can diff against, so `-Force` is reserved for the export path only.`

A repo-wide grep confirms it: zero reconcilers diff a `lastModifiedBy`, because the IPPS / Security & Compliance cmdlets do not return one. The `Conflict` row in the mandated drift-report format (line 251: "in both; last modified by a non-deploy principal") has never been emitted by any reconciler and cannot be.

So the contract defines `-Force` as a thing it cannot do, while the code uses it for a thing the contract never mentions.

## Decision

**The destructive-operation confirmation gate moves to the script layer, implemented with `$PSCmdlet.ShouldContinue()`, and the ADR 0029 workflow-layer typed-token gate is RETAINED as defence-in-depth.** Two gates, at two layers, for two different threat models. The workflow gate defends the CI path against an accidental dispatch; the script gate defends the local path against an accidental keystroke. Only the script layer is traversed by **both** callers, which is why the mandatory gate belongs there.

### 1. `ConfirmImpact = 'High'` on every reconciler

Necessary, not sufficient. It makes the per-write `ShouldProcess` calls actually capable of prompting, restoring `-Confirm` to a working switch. Lowering it back to `'Medium'` is a review-blocker; [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84) will assert it mechanically.

### 2. The destructive branches are gated with `ShouldContinue`, not `ShouldProcess`

Both destructive branches — the `-PruneMissing` **delete** and the `-DirectionPolicy repo-wins` **overwrite** — are gated behind `$PSCmdlet.ShouldContinue()`, via the shared helper [`scripts/modules/ConfirmGate.psm1`](../../scripts/modules/ConfirmGate.psm1).

`ShouldContinue` is chosen **specifically because it ignores `$ConfirmPreference`**. It cannot be silently defeated by the impact/preference mismatch that caused this defect, and it cannot be defeated by a caller who sets `$ConfirmPreference = 'None'`. The per-write `ShouldProcess` calls stay exactly where they are — they are what makes `-WhatIf` enumerate every object — but they are no longer the thing standing between an operator and an irreversible delete.

### 3. One prompt per run, not one per object

The gate uses `ShouldContinue`'s four-argument `yesToAll` / `noToAll` overload. The `[ref]` pair is created once per run and **shared across both gates**, so a run that trips the overwrite gate *and* the prune gate prompts once and carries the answer forward. A reconcile of 40 drifted labels raises one prompt, not 40. A prompt-per-object gate is a gate that gets `-Force`d out of habit, which is worse than no gate at all.

The prompt names the objects and the count (`"-PruneMissing will DELETE 3 orphan sensitivity label(s) from the tenant: Alpha, Beta, Gamma. This cannot be undone. Continue?"`). An operator who cannot see what they are about to destroy is not really being asked.

### 4. Declining aborts the run; it does not partially apply

A declined gate throws. The alternative — "skip the deletes, proceed with the creates" — produces a half-applied state that is hard to audit and harder to reason about on the next run. The operator asked for a destructive run and then said no; re-running without `-PruneMissing` is trivial and unambiguous. No tenant writes have occurred at the point the gate is reached, so the abort is clean.

### 5. `-WhatIf` short-circuits *before* the prompt

A dry run must never block on input. Under `-WhatIf` the gate returns `$true` **without prompting**, and the branch is still walked so the per-write `ShouldProcess` calls render their `What if:` preview lines.

Returning `$false` here would have been the subtle bug: it would suppress the very deletions `-WhatIf` exists to preview, turning `-PruneMissing -WhatIf` into a silent liar. This also means `-DirectionPolicy audit` (which sets `$WhatIfPreference`) never prompts, and `drift-detection.yml` — which runs every reconciler with a bare `-WhatIf` and no `-Confirm:$false` — is unaffected.

### 6. The settled semantics of `-Force`

**`-Force` means one thing, stated at the level of abstraction that covers both parameter sets: *suppress the safety guard that would otherwise block or question this operation*.**

| Parameter set | The guard `-Force` suppresses |
|---|---|
| Apply | The ADR 0052 destructive-operation confirmation prompt (this ADR). |
| Export | `-ExportCurrentState`'s refusal to clobber a non-empty managed block in the target YAML (the existing, implemented behaviour). |

The two never overlap: the destructive gates exist only in the Apply parameter set, the YAML-clobber guard only in the Export parameter set. This resolution is chosen over splitting the switch because it is **non-breaking** — four live CI call sites already pass `-Force` on the Export path, and every operator runbook documents it.

**The line-167 authorship-conflict meaning is RETIRED, not reassigned.** It describes a capability the IPPS surface cannot support (no `lastModifiedBy` is returned to diff against) and that no reconciler has ever implemented. Deleting an unimplementable definition is removing a fiction, not changing a behaviour. The `Conflict` drift-report category is likewise marked **reserved — not currently emitted**.

If a future Purview surface does expose a per-object `lastModifiedBy`, that override gets its **own** switch (`-OverwriteForeignAuthor`). It must not be folded back onto `-Force`. Re-conflating them is how this repo got here.

### 7. The CI path stays unattended — and this was verified, not assumed

`ShouldContinue` ignores `$ConfirmPreference`, so an explicit **`-Confirm:$false`** is what tells a reconciler it is running unattended. The gate honours it as the CI consent signal. Every workflow *apply* step already binds it.

The issue's premise — "zero workflow changes are required" — **was checked against the workflows and found to be wrong.** `Deploy-Labels.ps1` wraps its `-ExportCurrentState` YAML write in `$PSCmdlet.ShouldProcess(...)`, and two workflows invoke that export path **without** `-Confirm:$false`:

- `.github/workflows/deploy-labels.yml` — "Re-export tenant labels for drift-back PR"
- `.github/workflows/sync-labels-from-tenant.yml` — the scheduled drift-back export

At `ConfirmImpact = 'Medium'` those calls never prompted. At `'High'` they would have raised a confirmation prompt that no one can answer on a hosted runner, and **both jobs would have hung**. Raising the impact level without this fix would have converted a silent safety defect into a CI outage. Both call sites now bind `-Confirm:$false`; the two DLP export call sites bind it as well, so the rule "every CI invocation of a reconciler binds `-Confirm:$false`" is true without exception across the touched scripts.

### 8. ADR 0035's seed-skip baseline is relocated to a checked-in data file

[ADR 0035](0035-records-seed-content-immovable.md) Decision #3 mandates a 31-name skip baseline for the Microsoft File Plan Manager seed content, and anchored it to the `skip_names_records` dispatch input of `.github/workflows/deploy-data-plane.yml`. [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) deleted that workflow. The mandated baseline has since lived **nowhere executable** — a safety default attached to a file that does not exist.

The baseline moves to [`data-plane/records/seed-skip-names.yaml`](../../data-plane/records/seed-skip-names.yaml), which `Deploy-FilePlan.ps1` reads and **unions into the effective skip list on every run**. Chosen over a hardcoded array in the script because:

- It is **data, not code** — version-controlled, diffable, reviewable, and revertible in a single PR, which is exactly what ADR 0035 §Consequences promised.
- It keeps the reconciler free of a third hardcoded copy of the 31 names (the ADR table and the `file-plan.yaml` header comment are the other two).
- It is **executable by the only caller that exists**: the local operator run. A workflow input could never be, which is the whole reason the baseline went homeless.

Operators may **extend** the list via `-SkipNames`; they cannot **shrink** it from the command line. Shrinking means editing the data file in a reviewed PR — mechanically enforcing ADR 0035's "may extend … should not shrink it without superseding this ADR."

**The records risk is narrower than it looks, and overstating it would be wrong.** The 31 seeds are *undeletable*: every `Remove-FilePlanProperty*` call against them fails with `ErrorRuleNotFoundException` (ADR 0035 §Context; [#582](https://github.com/marcusjacobson/Purview-as-Code/issues/582)). A local `-PruneMissing` without the skip list therefore produces **31 noisy failures, not 31 deletions**. The seeds were never at risk. The real data-loss exposure — the one this ADR's confirmation gate exists for — is to **operator-authored objects**, which delete just fine. The ADR 0035 repair rides along here only because `Deploy-FilePlan.ps1` is already in this change's blast radius.

## Consequences

**Easier:**

- **The written contract becomes true.** `powershell.instructions.md` line 267 has mandated a confirmation prompt since the beginning; for the first time, one is actually emitted.
- **The local operator path is defended.** The path that had *no* gate — and that is the *only* path for `Deploy-FilePlan.ps1` — now has the same protection as the CI path.
- **The gate cannot be silently disarmed.** `ShouldContinue` ignores `$ConfirmPreference`. Disabling this gate now requires typing `-Force` or `-Confirm:$false` — an explicit, greppable, reviewable act, not an ambient preference variable.
- **`-Force` means one thing.** The three-way overload collapses to a single semantic, and the unimplementable arm is gone rather than quietly retained as a trap.
- **ADR 0035's baseline is executable again**, and defends the exact path (a local run) that its original home could never reach.
- **`-WhatIf` is unchanged**, so every existing dry-run runbook, the `drift-detection.yml` sweep, and `audit` mode all behave exactly as before.

**Harder:**

- **Two more gates to remember on the destructive path.** A local `repo-wins` + `-PruneMissing` run now answers a prompt in addition to the workflow's two typed tokens. Intentional: the tokens defend CI, the prompt defends the terminal, and they are not substitutes.
- **Eighteen reconcilers are still exposed** until [#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83) lands. This ADR ships the pattern and three reference implementations; it does not pretend the rollout is done. Sequencing is deliberate — [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84)'s guard test would red the build if it landed before the rollout it asserts.
- **Every CI invocation must bind `-Confirm:$false`.** Forgetting it on a *new* workflow step that calls a reconciler at `ConfirmImpact = 'High'` hangs the job on an unanswerable prompt. This is now a stated rule in `powershell.instructions.md` and in `github-actions.instructions.md`'s neighbourhood, and it is the one genuinely sharp edge this ADR introduces. It is a loud failure (a hung job), not a silent one (a deleted label), which is the correct direction for the trade.
- **A declined gate aborts the whole run**, including the non-destructive creates it would have applied. Accepted as the price of not inventing a half-applied state.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Unchanged. The gate introduces no credentials; the prompt text names object display names only, never tokens or bodies.
- **#4 (least privilege).** Unchanged. No scope is expanded.
- **#9 (idempotent, reversible, auditable).** **Strengthened, materially.** The single irreversible operation in the repo (a tenant delete) previously ran unattended from a local terminal with no acknowledgment. It now requires an explicit, logged, typed acknowledgment — or an explicit `-Force` / `-Confirm:$false` that a reviewer can grep for.
- **#10 (OWASP-aware).** Upheld. The prompt is a host-rendered choice, not a parsed string; there is no injection surface. The workflow-layer typed-token equality check from ADR 0029 is untouched.

## Alternatives considered

1. **Raise `ConfirmImpact` to `'High'` and keep using `ShouldProcess`.** Rejected. It fixes today's symptom while leaving the gate's existence coupled to a caller-controlled preference variable: `$ConfirmPreference = 'None'` re-disarms it, and a future copy-paste of `ConfirmImpact = 'Medium'` reintroduces the identical defect. The bug is not that the constant was wrong; it is that a negotiable prompt was used to guard a non-negotiable operation. Rejecting this option *is* the substance of the ADR.

2. **Leave the gate in the workflow (status quo) and document the local path as "operator responsibility".** Rejected. It is precisely the "no local-script escape hatch" claim in ADR 0029 §Consequences that this ADR exists to correct. `Deploy-FilePlan.ps1` has no workflow caller at all, so for that reconciler the "operator responsibility" framing is the entire safety model.

3. **Prompt per object rather than once per run.** Rejected. A 40-label reconcile raising 40 prompts trains the operator to reach for `-Force` reflexively, converting a safety feature into a ritual. The `yesToAll` / `noToAll` overload gives the same expressive power at one prompt per run.

4. **A typed-token confirmation at the script layer (`-Confirm 'confirm prune'`), mirroring the workflow ceremony.** Rejected. Typed tokens are the right shape for a *non-interactive* dispatch form, where there is no host to render a choice and the operator is pasting into a web UI. At an interactive terminal there *is* a host, and `ShouldContinue` is the platform-native mechanism with `-WhatIf` / `-Confirm` / `-Force` semantics already wired in. Inventing a parallel token ceremony would fragment the mental model for no safety gain.

5. **Split `-Force` into `-Force` (confirmation suppressor) + `-ForceExport` (YAML clobber).** Rejected as gratuitously breaking. Four live CI call sites and every operator runbook pass `-Force` on the Export path today. The parameter sets are disjoint, so a single switch with one abstraction-level-appropriate meaning ("suppress the guard on the operation you asked for") is unambiguous in practice. The genuinely incoherent arm — the authorship-conflict override — is unimplementable and was retired instead of renamed.

6. **Roll the gate out to all 21 reconcilers in this PR.** Rejected. Twenty-one reconcilers is twenty-one plan/apply shapes to re-read and re-reason about; the three reference implementations here (a simple two-tier, a three-tier with an unusual property/label ordering, and a policy+rule composite) cover the structural variety the rollout will meet. Batching all 21 would produce a diff no reviewer can hold in their head, against the repo's one-item-at-a-time cadence. [#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83) carries the rollout; [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84) then locks it.

## Citations

- [Everything about ShouldProcess (PowerShell)](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess) — Fetch date: 2026-07-13. Documents the `ConfirmImpact` vs. `$ConfirmPreference` comparison that is the root cause, and the `ShouldContinue` alternative that is the fix. Cited for both the defect and the remedy.
- [`Cmdlet.ShouldContinue` (.NET API)](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.cmdlet.shouldcontinue) — Fetch date: 2026-07-13. Documents the four-argument `yesToAll` / `noToAll` overload used for the one-prompt-per-run gate, and confirms `ShouldContinue` performs no `$ConfirmPreference` comparison.
- [about_Preference_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables) — Fetch date: 2026-07-13. Cited to confirm `$ConfirmPreference` defaults to `High`, which is what makes `ConfirmImpact = 'Medium'` a no-op.
- [about_Functions_CmdletBindingAttribute](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute) — Fetch date: 2026-07-13. Cited for the `ConfirmImpact` declaration surface.
- [File plan manager (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/file-plan-manager) — Fetch date: 2026-07-13. Cited for the 31 seed property objects whose skip baseline is relocated in Decision #8.
- [ADR 0029](0029-source-of-truth-direction-policy.md) — the workflow-layer typed-token gate this ADR retains, and whose "no local-script escape hatch" claim it amends.
- [ADR 0035](0035-records-seed-content-immovable.md) — the seed-skip baseline this ADR relocates.
- [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) — retired `deploy-data-plane.yml`, orphaning ADR 0035's baseline and leaving `Deploy-FilePlan.ps1` with no workflow caller.
- [#582](https://github.com/marcusjacobson/Purview-as-Code/issues/582) — the probe evidence that the 31 seeds fail with `ErrorRuleNotFoundException` rather than deleting; the basis for the "31 noisy failures, not seed loss" precision in Decision #8.
