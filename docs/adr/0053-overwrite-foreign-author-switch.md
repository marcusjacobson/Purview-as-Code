# 0053 — The foreign-author overwrite override gets its own switch, `-OverwriteForeignAuthor`

- **Status:** Accepted
- **Date:** 2026-07-13
- **Gates:** Cross-cutting foundation. **Amends [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md) §6 by supersession** — corrects its false premise that the authorship-conflict override is unimplementable, un-retires that capability, and gives it the dedicated switch ADR 0052 line 120 pre-authorised. ADR 0052 remains `Accepted`; only its §6 authorship clause, its line-118 `Conflict`-category claim, and its §Alternatives-5 rationale are amended. Reconciles the `-Force` definition at [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) line 167 for the second time. **Unblocks [#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83)** (the ADR 0052 ConfirmGate rollout to 18 reconcilers), which cannot proceed while `-Force` still means two things on six of them, and constrains [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84)'s guard test (see Decision #7 — the `Conflict` category is overloaded and #84 must not assert a single semantic for it). Does not appear in [`docs/project-plan.md`](../project-plan.md) §8 — this is implementation-pattern scaffolding, not a wave-blocking question, following ADR 0052's own precedent.
- **Deciders:** @marcusjacobson

## Context

[ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md) §6 settled the meaning of `-Force` and, in doing so, retired one of its three arms — "allow overwriting objects whose `lastModifiedBy` is not the current deploy principal" — on the grounds that it is **unimplementable**. ADR 0052 line 73:

> "A repo-wide grep confirms it: zero reconcilers diff a `lastModifiedBy`, because the IPPS / Security & Compliance cmdlets do not return one. The `Conflict` row … has never been emitted by any reconciler and cannot be."

**The premise is false.** Six reconcilers implement exactly that meaning today, and emit real `Conflict` rows from a real authorship diff against a real authorship field:

| Script | Authorship field diffed | Surface |
|---|---|---|
| [`Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) | `updatedBy` / `createdBy` | Atlas v2 (Data Map) |
| [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) | `lastModifiedBy`, `updatedBy`, `properties.lastModifiedBy`, `systemData.lastModifiedBy` | Scanning REST |
| [`Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) | `updatedBy` / `modifiedBy` / `createdBy` | Atlas v2 (Data Map) |
| [`Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1) | `lastModifiedBy` … `systemData.lastModifiedBy` | Scanning REST |
| [`Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1) | `systemData.lastModifiedBy` | Unified Catalog preview REST |
| [`Deploy-UnifiedCatalogPolicies.ps1`](../../scripts/Deploy-UnifiedCatalogPolicies.ps1) | `LastModifiedBy` | Unified Catalog preview REST |

The surface ADR 0052 called "future" is live, and has been since the Data Map reconcilers first shipped.

### How ADR 0052 got it wrong — the durable lesson

This is the most valuable content in this document, because the failure mode is cheap to repeat and expensive to catch.

**The grep hit.** ADR 0052 did not fail to search; it searched, got results, and misread them. `Deploy-DataSources.ps1` contains a literal `lastModifiedBy` on the authorship-candidate line. It was *in the output*.

**It read the comments and skipped the code.** Three of the hits in that same output are *prose*, not logic — header comments in the IPPS-surface reconcilers stating that the capability is impossible:

- `Deploy-Labels.ps1:33` — "Sensitivity-label cmdlets do not expose a per-label `lastModifiedBy` we can diff against."
- `Deploy-LabelPolicies.ps1:42` — same claim.
- `Deploy-PurviewRoleGroups.ps1:45` — same claim.

Those three comments are **true, and they are scoped to their own surface**. ADR 0052 generalised them into a repo-wide impossibility claim without reading the *code* lines sitting beside them in the identical grep output. A comment asserting "X cannot be done" is evidence about the file it lives in. It is not evidence about the repo. **A grep that returns both prose and logic must be read as two result sets, not one.**

**The reference sample was unrepresentative, and its unrepresentativeness was invisible.** ADR 0052's three reference reconcilers — Labels, FilePlan, DLPPolicies — are all on the **IPPS / Security & Compliance cmdlet** surface, which genuinely returns no authorship field. From inside a sample of three that agree, the conclusion "no reconciler can do this" looks like saturation. It was selection. The repo spans two authoring surfaces, and the **Atlas / Purview Data Map + Scanning + Unified Catalog REST** surface returns authorship as `updatedBy` / `createdBy` / `systemData.lastModifiedBy` on essentially every entity. ADR 0052 sampled one surface and legislated for both.

The generalisable rule, for the next reader and the next ADR: **this repo has two authoring surfaces with materially different capabilities. A capability claim of the form "no reconciler can X" is only sound if it was tested against a reconciler from *each* surface.** ADR 0052's claim was sound for IPPS and false for Atlas/REST, and it shipped as though the distinction did not exist.

### The defect this created, and why it blocks #83

Because `-Force` currently *does* mean "overwrite foreign-authored objects" on these six scripts, the ADR 0052 rollout would weld a second meaning onto it. [#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83) wires `-Force` into `Assert-DestructiveOperationConfirmed -Force:$Force` as "suppress the confirmation prompt". Do that on these six and an operator who types `-Force` to skip a **delete** prompt also enables **clobbering portal-authored objects** — manufacturing the exact conflation ADR 0052 line 120 names as "how this repo got here". #83 cannot proceed until this is settled.

The override is implemented by **two distinct mechanisms**, and they are not interchangeable. Naming the difference is load-bearing, because they need different repairs:

**Mechanism A — silent suppression** (`Deploy-Glossary`, `Deploy-DataSources`, `Deploy-Classifications`, `Deploy-Scans`). The classifier `Test-ConflictRow` opens with `if ($ForceEnabled) { return $false }`, and is called as `Test-ConflictRow … -ForceEnabled $Force.IsPresent`. Under `-Force` the Conflict classification is **suppressed at source**: the row is never emitted, falls through to `Update`, and the portal-authored object is overwritten with **no Conflict row anywhere in the drift report**. The operator is not told.

**Mechanism B — reported overwrite** (`Deploy-UnifiedCatalog`, `Deploy-UnifiedCatalogPolicies`). `Test-IsConflict` is pure; the plan builder receives `-AllowConflictOverwrite:$Force.IsPresent` at the call site. Under `-Force` the Conflict row **is** emitted (`Reason = 'Conflict will be overwritten because -Force was supplied.'`) and the plan action becomes `Update`. The overwrite still happens, but it is *reported*.

Mechanism A is the more serious defect — it destroys the audit record, not just the object. Mechanism B is merely mis-bound. A single fix that papered over both would have to pick one shape and impose it; instead each gets the repair its shape requires.

## Decision

### 1. The foreign-author override is un-retired, and it gets its own switch: `-OverwriteForeignAuthor`

ADR 0052 line 120 already pre-authorised this and named the switch:

> "If a future Purview surface does expose a per-object `lastModifiedBy`, that override gets its **own** switch (`-OverwriteForeignAuthor`). It must not be folded back onto `-Force`."

The condition it set is not future. It is met, and it was met when the sentence was written. `-OverwriteForeignAuthor` is added as a `[switch]` to the **Apply parameter set only** of the six reconcilers above. It is **not** added to the Export parameter set: the export path reads the tenant and writes a local YAML file, so there is no tenant object whose authorship could be in question, and nothing for the switch to mean.

### 2. `-Force` keeps exactly one meaning, and no longer suppresses `Conflict` rows

`-Force` means, as ADR 0052 §6 settled and this ADR retains: ***suppress the safety guard that would otherwise block or question the operation you asked for.*** In the Apply set that guard is the ADR 0052 destructive-operation confirmation prompt; in the Export set it is `-ExportCurrentState`'s refusal to clobber a non-empty managed block. That is the whole of it. `-Force` no longer authorises an authorship overwrite on any script, and it no longer suppresses a `Conflict` row on any script.

### 3. The `Conflict` row is always emitted; the switch authorises the overwrite, it does not hide the finding

This is the substantive behaviour change, and it is a deliberate strengthening beyond a pure rebind. Under Mechanism A the Conflict row used to *vanish* when the override was engaged. It no longer does. Whenever tracked-field drift coincides with foreign authorship, the reconciler emits a `Conflict` row **regardless of `-OverwriteForeignAuthor`**, and the switch decides only whether the write proceeds:

| | `Conflict` row emitted | Object overwritten |
|---|---|---|
| neither switch | yes | no |
| `-Force` alone | **yes** (was: no) | **no** (was: yes) |
| `-OverwriteForeignAuthor` | yes | yes |

A safety override that erases the evidence that it fired is not an override, it is a laundering step. Mechanism B already had this right; Mechanism A is brought up to it.

### 4. Both `$ConfirmPreference = 'None'` self-disarms are deleted

`Deploy-UnifiedCatalog.ps1` and `Deploy-UnifiedCatalogPolicies.ps1` each opened with `if ($Force.IsPresent) { $ConfirmPreference = 'None' }`. ADR 0052 line 89 requires that the gate "cannot be defeated by a caller who sets `$ConfirmPreference = 'None'`" — while two scripts in its own blast radius did exactly that **to themselves**. A self-inflicted defeat is still a defeat.

Both blocks are deleted here, not in #83, because they are `-Force` *semantics* code — precisely what this ADR settles — and both files are already open on this change. Leaving them for #83 would hand #83 a `-Force` that ambiently disarms confirmation, which is the conflation this ADR exists to forbid. Same "rides along because it is already in the blast radius" logic ADR 0052 §8 used for the ADR 0035 repair.

**For `Deploy-UnifiedCatalogPolicies.ps1` this is a real behaviour change, not a tidy-up.** It is the **one reconciler already at `ConfirmImpact = 'High'`**, so that line was precisely what had been neutering the only script that looked correct. With it gone, its per-write `ShouldProcess` calls become live under `-Force` for the first time. Every CI caller already binds `-Confirm:$false`, which is the explicit consent signal ADR 0052 §7 mandates, so no workflow hangs. A **local** `-Force` run of that script will now prompt per write where it previously did not — which is the entire point, and is called out in Consequences. (`Deploy-UnifiedCatalog.ps1` is still `Medium`, so its copy was armed-but-latent; deleting it now means #83 does not inherit a trap when it raises the impact level.)

Raising `ConfirmImpact` to `'High'` on the six is **not** in scope — that is #83's job. Removing a disarm is not the same act as arming a gate.

### 5. Zero callers break — verified, not assumed

Every `-Force` call site against the six scripts, across `.github/workflows/**`, `.github/prompts/**`, `scripts/**`, `tests/**`, `docs/**`, and `index.html`, is an **Export-path** call site (`-ExportCurrentState -Force`, the YAML-clobber guard, untouched by this change):

- [`docs/getting-started.md`](../getting-started.md) §4 — Glossary, Classifications, DataSources, Scans (4)
- `index.html` — generated-site mirror of the same four (4)
- [`.github/prompts/deploy-unified.prompt.md`](../../.github/prompts/deploy-unified.prompt.md) — UnifiedCatalog, UnifiedCatalogPolicies (2)
- [`docs/solutions/unified-catalog/unified-catalog.md`](../solutions/unified-catalog/unified-catalog.md) — UnifiedCatalog, UnifiedCatalogPolicies (2)

**Apply-path `-Force` callers of the six: none. Zero workflow steps, zero scripts, zero runbooks.** No migration note is required and no runbook changes.

Verification method, so it is reproducible rather than asserted: a repo-wide grep for each of the six script names across every file type, filtered to lines containing `-Force`, then each surviving line read in context to classify it Apply-path or Export-path. Every one carried `-ExportCurrentState` on the same line. The count is ten.

### 6. This is *not* the split ADR 0052 rejected — and that objection is the one a reviewer will reach for

ADR 0052 §Alternatives-5 rejected splitting `-Force` as "gratuitously breaking":

> "Four live CI call sites already pass `-Force` on the Export path today."

**That objection does not apply to this split, and the reason is structural, not a matter of degree.** Those call sites are **Export-path**. This split touches **only the Apply path**. The two parameter sets are **disjoint** — `-OverwriteForeignAuthor` is declared in the Apply set and cannot even be bound alongside `-ExportCurrentState`, which is `Mandatory` in the Export set. Every call site ADR 0052 was protecting is in the set this change does not enter. The split ADR 0052 rejected (`-Force` → `-Force` + `-ForceExport`, which *would* have broken all ten of them) is not the split this ADR makes.

ADR 0052 was right to reject the split it considered. It simply was not considering this one — because, per §Context above, it did not believe the Apply-side meaning existed.

### 7. The `Conflict` report category is overloaded — documented, deliberately NOT fixed here

`Category = 'Conflict'` currently means two unrelated things:

- **Authorship conflict** — the six scripts above. "Someone else last modified this."
- **Shape conflict** — [`Deploy-EntraDirectoryRoles.ps1`](../../scripts/Deploy-EntraDirectoryRoles.ps1) ("Declared member is not a security-enabled, role-assignable Entra group; skipped") and [`Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) ("Tenant group is not a pure security group … Overwrite only with `-Force`"). Nothing to do with who authored anything.

And `-Force` in `Deploy-RoleGroupBackingEntraGroups.ps1` means a **third** thing again: "overwrite a shape-mismatched group". That script is out of scope here — it is not an authorship reconciler — but the overload is named so the next reader is not misled the way ADR 0052 was.

**Renaming the shape-conflict category is explicitly deferred.** It is a report-format change touching two scripts and their consumers, and bundling it here would blur a `-Force` semantics ADR into a reporting ADR.

**This constrains [#84](https://github.com/marcusjacobson/Purview-as-Code/issues/84).** #84's repo-wide guard test must **not** assert a single `Conflict` semantic, because no single semantic exists. A guard that asserts "every `Conflict` row means foreign authorship" would be false against two scripts on the day it lands. #84 either scopes its `Conflict` assertions to the six authorship reconcilers by name, or waits for the rename.

## Consequences

**Easier:**

- **`-Force` finally means one thing, and it is the thing the contract says.** ADR 0052 claimed to collapse a three-way overload but collapsed a two-way one, because it could not see the third arm. That collapse is now real.
- **[#83](https://github.com/marcusjacobson/Purview-as-Code/issues/83) is unblocked.** `-Force:$Force` can be wired into `Assert-DestructiveOperationConfirmed` on all 18 remaining reconcilers without the six Atlas/REST scripts silently acquiring a clobber-portal-objects side effect.
- **A `-Force` run can no longer silently overwrite a portal-authored object.** Under Mechanism A this was invisible — no row, no warning, no record. It is now a visible `Conflict` row and a refused write.
- **The audit record survives the override.** Even with `-OverwriteForeignAuthor`, every overwritten object gets a `Conflict` row naming the foreign author. The switch grants permission; it does not buy silence.
- **The ADR 0052 gate is no longer self-defeated** on the two Unified Catalog scripts.

**Harder:**

- **An operator who genuinely wants to overwrite portal-authored objects must now type a second, longer switch.** Intentional. It is a 22-character switch guarding an irreversible clobber of someone else's work, and it is now greppable in CI logs and runbooks in a way `-Force` never was.
- **`Deploy-UnifiedCatalogPolicies.ps1` now prompts per write on a local `-Force` run.** It is at `ConfirmImpact = 'High'` and its self-disarm is gone, so `ShouldProcess` is live. CI is unaffected (every workflow caller binds `-Confirm:$false`), but a local operator who relied on `-Force` to run that script unattended must now bind `-Confirm:$false` explicitly. This is the ADR 0052 §7 consent signal working as designed, and it is a **loud** change (a prompt), not a silent one.
- **The `Conflict` category remains overloaded** until the deferred rename lands, and #84 must be written around that.
- **[`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) has now been corrected twice** on the same lines in two consecutive ADRs. The second correction is the durable one because it is the one grounded in the code rather than in a comment about the code.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Unchanged. Authorship fields are principal identifiers already returned by the API and already printed in existing `Conflict` rows; no new identifier class is surfaced.
- **#4 (least privilege).** **Strengthened.** `-Force` no longer confers an authority the operator did not ask for. The authority to overwrite another principal's work is now separately requested and separately granted.
- **#9 (idempotent, reversible, auditable).** **Strengthened, materially.** The Mechanism A silent-overwrite path destroyed its own audit trail: the object was overwritten *and* the `Conflict` row that would have recorded it was suppressed by the same switch. Both halves are fixed — the row is always emitted, and the overwrite requires its own opt-in.
- **#10 (OWASP-aware).** Upheld. No parsing, no injection surface; the change is parameter binding and report content.

## Alternatives considered

1. **Leave `-Force` as-is and let #83 wire it into the ConfirmGate anyway.** Rejected. This is the status quo plus a new hazard: `-Force` would mean "skip the delete prompt" *and* "clobber portal-authored objects" on six scripts, so an operator suppressing a prompt for a delete they intended would silently authorise an overwrite they did not. ADR 0052 line 120 names this re-conflation as the origin of the whole problem.

2. **Amend ADR 0052 in place.** Rejected — not permitted. [`docs/adr/README.md`](README.md) line 5: "ADRs are immutable once accepted … write a new ADR that supersedes the old one — do not edit the old file in place." Hence supersession-by-amendment: ADR 0052 stays `Accepted` and correct in the large; this ADR carries the correction, and the two are read together.

3. **Ship the ADR now and the code later.** Rejected, emphatically. An ADR-only PR would assert "`-Force` no longer suppresses `Conflict` rows" while the code still suppressed them — shipping a decision document whose factual claims about the code are untrue. **That is the exact failure mode this ADR exists to correct.** Committing it again, inside the correction, would be indefensible. It would also leave #83 blocked, since #83 is blocked by the code and not by the decision.

4. **Reuse `-DirectionPolicy repo-wins` as the authorship override instead of a new switch.** Rejected. They arbitrate different questions. `repo-wins` answers "*which* source of truth wins on a shared-property drift" — a policy about content. The authorship override answers "*may I* write over an object a different principal last touched" — a policy about ownership. A foreign-authored object with tracked-field drift is drift the portal made, so `portal-wins` correctly skips it and `repo-wins` correctly proposes to take it; neither says anything about whether the deploy principal is entitled to overwrite another author's work. Folding one into the other would recreate, on `-DirectionPolicy`, the precise overload this ADR is removing from `-Force`.

5. **Suppress the `Conflict` row when `-OverwriteForeignAuthor` is supplied (i.e. keep Mechanism A's shape and merely rename its parameter).** Rejected. It is the cheaper diff and it is wrong. The row is the only record that a foreign-authored object was overwritten; deleting the record as a side effect of authorising the act leaves an operator unable to answer "what did that run clobber?" from the drift report. The switch grants permission, not silence.

6. **Give `-OverwriteForeignAuthor` to all 21 reconcilers for uniformity.** Rejected. On the IPPS / Security & Compliance surface there is genuinely no authorship field to diff — the three comments ADR 0052 misread are *correct about their own scripts*. A switch that is inert on 15 of 21 scripts is a switch that teaches operators it does nothing, and it would re-import the same false-uniformity assumption, only inverted. The switch exists on exactly the scripts that can honour it.

7. **Fix Mechanism A and Mechanism B with one shared helper.** Rejected as premature. Their plan builders have genuinely different shapes (a `$plan` list with an `Action` string vs. a `Get-ReconciliationPlan` returning a `Report`/`Plan` pair), and the two-line rebind each one needs is smaller and far more reviewable than the refactor that would unify them. A shared conflict-classification helper may be worth extracting when a seventh authorship reconciler appears; extracting it for six existing call sites in the same PR that changes their semantics would make the semantic change hard to see.

## Citations

- [Microsoft Purview Data Map REST API — Entity](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/entity) — Fetch date: 2026-07-13. Documents the Atlas v2 entity payload carrying `updatedBy` / `createdBy`, which is the authorship field `Deploy-Glossary.ps1` and `Deploy-Classifications.ps1` diff. This is the surface ADR 0052 asserted did not exist.
- [Microsoft Purview Scanning REST API — Data Sources: Get](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/get) — Fetch date: 2026-07-13. Documents the Scanning data-source payload whose `lastModifiedBy` / `systemData.lastModifiedBy` is diffed by `Deploy-DataSources.ps1` and `Deploy-Scans.ps1`.
- [Microsoft Purview Unified Catalog REST API — Business Domain](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/) — Fetch date: 2026-07-13. Documents the `systemData.lastModifiedBy` field on Unified Catalog entities, diffed by `Deploy-UnifiedCatalog.ps1`.
- [Microsoft Purview Unified Catalog REST API — Policies: List](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/list) — Fetch date: 2026-07-13. Documents the policy payload whose `LastModifiedBy` is diffed by `Deploy-UnifiedCatalogPolicies.ps1`.
- [about_Functions_Advanced_Parameters — Parameter sets](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters#parameter-sets) — Fetch date: 2026-07-13. Cited for Decision #6: parameter-set disjointness is what makes the Apply-only split non-breaking for the ten Export-path callers, and is the mechanism by which `-OverwriteForeignAuthor` is unbindable alongside `-ExportCurrentState`.
- [Everything about ShouldProcess (PowerShell)](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess) — Fetch date: 2026-07-13. Cited for Decision #4: `$ConfirmPreference = 'None'` disarms `ShouldProcess` prompting, which is what the two deleted self-disarm blocks were doing.
- [about_Preference_Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables) — Fetch date: 2026-07-13. Cited to confirm `$ConfirmPreference` semantics and the `'None'` value the deleted blocks assigned.
- [Microsoft Graph — administrativeUnit resource type](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit) — Fetch date: 2026-07-13. Cited for the `Deploy-AdministrativeUnits.ps1` counter-example: the resource exposes **no** per-AU authorship field, which is why that script's `.PARAMETER Force` help was documenting a capability it cannot implement, and why it does not receive `-OverwriteForeignAuthor`.
- [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md) — the ADR this one amends by supersession: its §6 authorship-retirement clause, its line-118 `Conflict`-category claim, and its §Alternatives-5 rationale.
- [ADR 0029](0029-source-of-truth-direction-policy.md) — the direction-policy contract, kept deliberately separate from the authorship override (see Alternatives 4).
- [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) — adopted the Unified Catalog preview REST surface, two of whose reconcilers are in scope here.
- [ADR 0050](0050-machine-generated-adr-index.md) — why this ADR's H1 / `Status:` / `Gates:` lines are its index row's only inputs, and why [`README.md`](README.md) is not hand-edited by this change.
