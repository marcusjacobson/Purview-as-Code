---
name: purview-reconciler
description: >
  PowerShell reconciler authoring conventions for the Purview-as-Code lab repository.
  Packages the full-circle contract: SupportsShouldProcess, -PruneMissing, -ExportCurrentState,
  the direction-policy surface (ADR 0029), per-write gating, deterministic export round-trips,
  and the -ParametersFile contract (ADR 0012). Single-sources from powershell.instructions.md.
---

# Purview Reconciler Skill

This skill packages the non-negotiable PowerShell reconciler authoring conventions for `scripts/Deploy-*.ps1` scripts in the Purview-as-Code (`contoso-lab`) repository. It is the on-demand loadable companion to the always-on [`.github/instructions/powershell.instructions.md`](../../instructions/powershell.instructions.md), designed to give agents consistent guidance when authoring, reviewing, or refactoring reconciler scripts.

**Primitive:** Skill (per [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md)). **Not** an instruction (skills are loaded on demand, instructions are always-on) and not a prompt (skills provide knowledge, prompts provide task sequences).

**Canonical source:** This skill single-sources from:
- [`.github/instructions/powershell.instructions.md`](../../instructions/powershell.instructions.md) — §"Drift and reconciliation discipline" and §"Runtime: pwsh 7.4+ only".

When the canonical instruction file changes, this skill must be updated to reflect it — never the reverse.

---

## The full-circle contract — required surface on every `Deploy-*.ps1`

Every `scripts/Deploy-*.ps1` reconciler that backs a `data-plane/**` YAML file or a `.github/workflows/deploy-*.yml` workflow must expose the surface below. A script that omits any element is rejected by review.

### Required: `[CmdletBinding(SupportsShouldProcess)]`

The script must declare `SupportsShouldProcess = $true` in its `CmdletBinding` so `-WhatIf` and `-Confirm` work. `-WhatIf` produces the drift report and makes **no writes**. `-Confirm` prompts before each write.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Per-write `ShouldProcess` is mandatory".

### Required switches

| Switch | Type | Default | Effect |
|---|---|---|---|
| `-WhatIf` | `[switch]` | off | Built into `SupportsShouldProcess`. Produce the drift report; make no writes. |
| `-PruneMissing` | `[switch]` | `$false` | Allow deletion of objects that are in Purview but not in YAML. Without it, orphans are reported and skipped. |
| `-Force` | `[switch]` | `$false` | Allow overwriting objects whose `lastModifiedBy` is not the current deploy principal. Without it, such conflicts are reported and skipped. |
| `-ExportCurrentState` | `[switch]` | off | Read the live tenant and write its current state into the corresponding `data-plane/**` YAML. Makes no writes to Purview. Used to bootstrap a YAML file from an existing tenant. Must fail if the YAML already has non-empty managed content, unless `-Force` is also specified. |

**Default behavior is non-destructive:** scripts create and update; scripts **do not** delete orphans or overwrite conflict objects unless the caller explicitly opts in.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Required switches on every `Deploy-*.ps1`".

### Required: `-ParametersFile` (ADR 0012)

Every reconciler must accept a `-ParametersFile <path>` parameter, defaulting to `infra/parameters/lab.yaml` resolved relative to the repo root. This is the source-of-truth contract defined by [ADR 0012](../../../docs/adr/0012-environment-parameters-file.md).

Rules:

- The script loads the YAML via `powershell-yaml`'s `ConvertFrom-Yaml` and hard-errors if the file is missing, empty, or missing a required key, naming the missing key.
- Value resolution order: **explicit CLI parameter → value read from `-ParametersFile` → hard error**. No hardcoded defaults for resource names, resource group, region, or tags.
- Subscription ID, tenant ID, and any secret value must **not** be read from `-ParametersFile`. Those flow via `az account set` locally and GitHub Environment secrets in CI.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Required `-ParametersFile` switch on every orchestrator".

### Required: direction-policy surface (ADR 0029)

Every `scripts/Deploy-<Domain>.ps1` that backs a `.github/workflows/deploy-<domain>.yml` must expose the direction-policy parameters defined in [ADR 0029](../../../docs/adr/0029-source-of-truth-direction-policy.md):

| Parameter | Type | Default | Effect |
|---|---|---|---|
| `-DirectionPolicy` | `[ValidateSet('audit', 'portal-wins', 'repo-wins')] [string]` | `'portal-wins'` | Arbitrates shared-property drift on `Update` plan entries. |
| `-SkipNames` | `[string[]]` | `@()` | Explicit deterministic skip list, threaded in by the workflow. |

Required behavior:

- **Import the shared module.** The decision function `Resolve-DirectionPolicyAction` lives in [`scripts/modules/DirectionPolicy.psm1`](../../../scripts/modules/DirectionPolicy.psm1). Each consumer imports it via `Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop` in its `#region Module dependencies` block. Do **not** re-inline the function — extend the shared module instead.
- **Audit short-circuit.** When `-DirectionPolicy audit`, after the plan is computed and before writes, empty the plan and emit `[ADR0029-AUDIT] DirectionPolicy=audit — no writes would have fired.` via `Write-Information -InformationAction Continue`.
- **Skip markers.** When `-DirectionPolicy portal-wins` skips a shared label, emit `[ADR0029-SKIP] <displayName>` via `Write-Information -InformationAction Continue` — one line per skipped object, exact format `^\[ADR0029-SKIP\] (.+)$`.
- **Overwrite warnings.** When `-DirectionPolicy repo-wins` overwrites a shared label, emit `Write-Warning` naming the overwritten object and drifted fields.
- **Pester coverage.** Test the helper by importing the shared module in the test file's `BeforeAll` so all three policy branches, SKIP-marker emission, and AUDIT short-circuit are covered.

Reference implementation: [`scripts/Deploy-Labels.ps1`](../../../scripts/Deploy-Labels.ps1) (PR [#458](https://github.com/contoso/Purview-as-Code-Generic/pull/458)); shared module extracted in PR [#473](https://github.com/contoso/Purview-as-Code-Generic/pull/473).

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Direction-policy contract (ADR 0029)".

### Required: per-write `ShouldProcess` gating

Declaring `SupportsShouldProcess` is necessary but not sufficient. Every state-changing call inside the script must be individually gated by `$PSCmdlet.ShouldProcess(...)`:

```powershell
if ($PSCmdlet.ShouldProcess($target, $action)) {
    # New-Label / Set-Label / Remove-Label
    # New-RoleGroup / Update-RoleGroupMember / Remove-RoleGroup
    # Invoke-RestMethod -Method PUT / PATCH / DELETE
}
```

Where `$target` is the human-readable identity of the object being changed, and `$action` is a short imperative verb phrase (`'Create label'`, `'Update label policy'`, `'Remove orphan classification'`).

A script that wraps the *outer* loop in `ShouldProcess` but lets individual writes fall through is rejected — `-WhatIf` then runs every API write while only suppressing the loop banner.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Per-write `ShouldProcess` is mandatory".

**Learn citation:** [Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).

### Required: deterministic `-ExportCurrentState` round-trip

`-ExportCurrentState` must satisfy all three rules below or it is rejected by review:

1. **Stable key order.** Top-level and nested mapping keys serialize in a fixed, documented order. The order is documented in a comment near the export function.
2. **Omitted-field preservation.** Fields that the tenant returns but that the schema treats as omittable (defaults, computed metadata, system-generated identifiers) are *not* serialized into the YAML. A round-trip Apply against the exported YAML must produce zero `Update` rows in the drift report.
3. **Re-import idempotency.** `Deploy-<Domain>.ps1 -ExportCurrentState` → `git diff` (zero diff if no tenant change) → `Deploy-<Domain>.ps1 -WhatIf` (only `NoChange` rows).

A `-WhatIf` smoke run that exercises this triangle is required in the PR description for any change that touches an export path.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Deterministic `-ExportCurrentState` round-trip".

---

## Drift report format

Every `-WhatIf` run must emit a categorized report in this order:

1. **Create** — in YAML, not in Purview.
2. **Update** — in both; content differs.
3. **NoChange** — in both; content identical.
4. **Orphan** — in Purview, not in YAML. Would be deleted only with `-PruneMissing`.
5. **Conflict** — in both; content differs but `lastModifiedBy` is not the current principal. Would be overwritten only with `-Force`.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Drift report format".

---

## First-run-against-an-existing-tenant contract

A reconciler's first run on a tenant that already has live state **must not** destructively reconcile an empty or skeleton YAML against that live state. The safe-by-default workflow is:

1. Run `./scripts/Deploy-<Domain>.ps1 -ExportCurrentState` to hydrate the YAML from the live tenant.
2. Open the resulting diff as a pull request, review, and merge.
3. Only then run `-WhatIf` → `-Apply` (or `-Apply -PruneMissing` once the managed state matches reality).

This contract is why `-ExportCurrentState` is required on every `Deploy-*.ps1`, not optional.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"First-run-against-an-existing-tenant contract".

---

## Reference implementation and known gaps

[`scripts/Deploy-Labels.ps1`](../../../scripts/Deploy-Labels.ps1) is the reference implementation for the full-circle reconciler contract. [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1) and [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../../scripts/Deploy-EntraDirectoryRoles.ps1) also conform.

Known gaps tracked under epic [#172](https://github.com/contoso/Purview-as-Code-Generic/issues/172):

- [#165](https://github.com/contoso/Purview-as-Code-Generic/issues/165) — `Deploy-AdministrativeUnits.ps1` (missing `-ExportCurrentState`).
- [#166](https://github.com/contoso/Purview-as-Code-Generic/issues/166) — `Deploy-Classifications.ps1` (all four switches).
- [#167](https://github.com/contoso/Purview-as-Code-Generic/issues/167) — `Deploy-Collections.ps1` (`ShouldProcess` + export).
- [#168](https://github.com/contoso/Purview-as-Code-Generic/issues/168) — `Deploy-DataSources.ps1` (all four switches).
- [#169](https://github.com/contoso/Purview-as-Code-Generic/issues/169) — `Deploy-Glossary.ps1` (all four switches).
- [#171](https://github.com/contoso/Purview-as-Code-Generic/issues/171) — `Deploy-Scans.ps1` (all four switches).

New `Deploy-*.ps1` scripts must ship full-circle from day one.

**Source:** [powershell.instructions.md](../../instructions/powershell.instructions.md) §"Reference implementation and known gaps".

---

## Usage

Load this skill on demand when:
- Authoring a new `Deploy-*.ps1` reconciler script.
- Reviewing a PR that touches `scripts/Deploy-*.ps1`.
- Retrofitting an existing reconciler to add missing `-PruneMissing`, `-ExportCurrentState`, or direction-policy surface.
- Triaging a drift-report issue or validating a round-trip export.

Do not load this skill:
- For control-plane Bicep scripts (`New-*.ps1`).
- For helper scripts that do not reconcile YAML against a tenant (`Get-*.ps1`, `Connect-*.ps1`).
- When the task is to edit the canonical [`powershell.instructions.md`](../../instructions/powershell.instructions.md) file itself.

---

## References

- **[Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess)**
  Fetch date: 2026-06-19
  > "The ShouldProcess method is called by commands to confirm with the user that a command is about to make a change to the system."
- **[Customize AI in VS Code — Skills](https://code.visualstudio.com/docs/copilot/customization/overview)**
  Fetch date: 2026-06-19
  > "Skills are reusable capabilities that agents can load on demand to help with specific tasks."
- [ADR 0012 — Environment parameters file](../../../docs/adr/0012-environment-parameters-file.md)
- [ADR 0029 — Source-of-truth direction policy](../../../docs/adr/0029-source-of-truth-direction-policy.md)
- [`.github/instructions/powershell.instructions.md`](../../instructions/powershell.instructions.md) — canonical source for this skill.
- [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md) — why this is a skill.
- [`scripts/Deploy-Labels.ps1`](../../../scripts/Deploy-Labels.ps1) — reference implementation.
- [`scripts/modules/DirectionPolicy.psm1`](../../../scripts/modules/DirectionPolicy.psm1) — shared direction-policy decision function.
