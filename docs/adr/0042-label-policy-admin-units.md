# 0042 -- Label-policy admin units scope (`includedAdministrativeUnits`; #471 row 6)

- **Status:** Accepted
- **Date:** 2026-06-16
- **Gates:** Unblocks the row 6 implementation PR (child of [#471](../../issues/471)); does not appear in `docs/project-plan.md` §8 Open-question ADRs (preview-cmdlet exception record per [ADR 0030](0030-label-policies-tracked-field-expansion.md) §Decision 2).
- **Deciders:** @contoso

## Context

[ADR 0015](0015-label-policy-shape.md) §1 "Policy count and surface mix" focused on `*Location` parameters (`ExchangeLocation`, `ModernGroupLocation`, `PurviewLocation`) and did not contemplate administrative unit scoping of label policies. The Microsoft 365 Edit-policy wizard step "Admin units" allows a policy to be restricted to users who belong to one or more Entra ID administrative units rather than being applied to all users.

[ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 mandates a standalone ADR for this row because:

> "**Preview-only cmdlet on the only documented surface.** Adopting a preview surface as part of a tracked field is a design decision that ADR 0015 explicitly did not make (0015's blast-radius reasoning was all GA). Wave 0's `.github/instructions/powershell.instructions.md` 'GA-over-preview' rule already gates this; a new ADR records the exception. Currently affects: **Admin units** (preview cmdlet shape per [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units))."

Three design questions must be settled before the implementation PR:

1. **GA status** -- whether the `-IncludedAdministrativeUnits` parameter on `Set-LabelPolicy` / `New-LabelPolicy` has reached GA, is still in preview, or has been replaced by a different parameter name.
2. **YAML field shape** -- whether to use AU object IDs directly (prohibited by the identifier rules in [`copilot-instructions.md`](../../.github/copilot-instructions.md)), `${env:VAR}` tokens (ADR 0023 Category 2), or AU display names resolved at deploy time (ADR 0023 Category 3 extension).
3. **Lab desired state** -- what value both shipped policies should carry, given that `data-plane/administrative-units/administrative-units.yaml` currently ships an empty list per [ADR 0002](0002-administrative-units.md).

**Environment context:** Both shipped policies currently have no AU scoping. The default when `-IncludedAdministrativeUnits` is absent from a `New-LabelPolicy` call is that the policy applies to all users in the tenant without AU restriction (per the [`New-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy)).

**Fetch note:** The GA status determination below is grounded in the [`Set-LabelPolicy` Microsoft Learn reference page](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) consulted on 2026-06-16. Per the "When Learn is silent or contradicts training data" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md), Learn wins over model training; the implementation PR author must re-verify the parameter's status banner on the Learn page on the date the implementation PR is opened and note the result in the PR description.

## Decision

We will:

1. **GA status: confirmed GA.** The `-IncludedAdministrativeUnits` parameter appears in the current [`Set-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) and [`New-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy) without a "Preview" designation as of this ADR's authoring date (2026-06-16). This resolves ADR 0030's preview-gate trigger. **No preview-cmdlet exception is required.** The implementation PR proceeds under the standard GA-over-preview rule from [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md). The implementation PR author must cite the Learn page with a "Verified GA: YYYY-MM-DD" note in the PR description.

   Reference: [`Set-LabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) -- `-IncludedAdministrativeUnits` parameter, type `String[]`.

2. **YAML field name: `includedAdministrativeUnits:`** -- top-level array-of-strings field at the policy level, parallel to `modernGroupLocation:`. The field is **not** an `advancedSettings:` key and is **not** a TrackedScalarFields entry. It follows the same sorted-set comparison and emit pattern as `modernGroupLocation:` in the reconciler.

   Each entry in the YAML array is an AU **display name** (e.g., `"Marketing Dept"`), resolved to an object ID at deploy time per ADR 0023 Category 3. AU object IDs (GUIDs) must never appear in the YAML directly, following the "No real identifiers in source" rule from [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).

3. **AU display-name resolution: new helper or extension.** `Get-EntraPrincipalIdByDisplayName.ps1` resolves users, groups, and service principals via Microsoft Graph. Administrative units are a distinct Entra object type (`directoryObject/administrativeUnit`) queried via `GET /administrativeUnits?$filter=displayName eq '{name}'` ([Microsoft Graph administrative units reference](https://learn.microsoft.com/en-us/graph/api/administrativeunit-list)). The implementation PR must either:
   - Extend `Get-EntraPrincipalIdByDisplayName.ps1` to accept an `-ObjectType AdministrativeUnit` parameter, or
   - Create a thin `Get-AdministrativeUnitIdByDisplayName.ps1` helper.
   Either approach is acceptable; the choice is left to the implementation PR author. For the lab's empty-list desired state, no actual resolution calls are made in practice (the empty array short-circuits before any Graph call).

4. **Lab desired state: empty array on both policies.** Both "Global sensitivity label policy" and "Lab Confidential + HC" ship with `includedAdministrativeUnits: []` (field present, empty -- wired but inactive). This is the exact same pattern as `modernGroupLocation: []` introduced by ADR 0030 row 4. Rationale: the lab has no administrative units provisioned per ADR 0002, so scoping any policy to an AU would immediately exclude the lab owner from the policy. An empty array preserves the "apply to all users" behavior while establishing the schema field for future use.

5. **Reconciler pattern: sorted-set comparison.** The implementation follows the same model as `modernGroupLocation:`:
   - `ConvertTo-PolicyHash` stores `includedAdministrativeUnits` as a sorted `[string[]]`.
   - `ConvertTo-TenantPolicyHash` reads `$Policy.IncludedAdministrativeUnits`, resolves each GUID back to a display name (via a reverse lookup), and stores as a sorted `[string[]]`.
   - `Compare-PolicyHash` compares the two sorted arrays element-by-element.
   - The create path passes `-IncludedAdministrativeUnits` only when the array is non-empty.
   - The update path calls `Set-LabelPolicy -Identity $d.name -IncludedAdministrativeUnits $auIds` when drift is detected.
   - `ExportCurrentState` reverses GUID-to-display-name and emits `includedAdministrativeUnits:` only when non-empty.
   The reverse lookup (GUID -> display name) is a non-trivial Graph call. For the lab's empty-list desired state the export path will never be exercised with real GUIDs; Pester tests cover the normalization and comparison paths with synthetic GUIDs (`00000000-0000-0000-0000-000000000001`).

6. **Rollback ceremony.** To revert:
   - Set `includedAdministrativeUnits: []` (or remove the field entirely) in [`data-plane/information-protection/label-policies.yaml`](../../data-plane/information-protection/label-policies.yaml) for the affected policy.
   - Run `Deploy-LabelPolicies.ps1 -Apply`.
   - Purview calls `Set-LabelPolicy -IncludedAdministrativeUnits @()` (or `-IncludedAdministrativeUnits $null`), removing the AU restriction and reverting to "apply to all users."
   - Users who were excluded by the AU restriction immediately fall back under the policy.

7. **ADR 0015 pointer.** ADR 0015 Consequences ("Follow-up issues can add...") is updated to include `includedAdministrativeUnits:` in the additive-field list with a "See ADR 0042" note, per ADR 0030 §2 "new ADR only" contract.

8. **Follow-up implementation issue.** A follow-up issue is opened via `@idea-intake` upon this ADR merging, scoped to implementing `includedAdministrativeUnits:` tracking in `Deploy-LabelPolicies.ps1` plus the AU display-name resolver, Pester tests (sorted-set comparison, normalization, drift quadrants), and schema additions.

## Consequences

**Easier:**

- The full portal Edit-policy wizard "Admin units" step is now unblocked for tracking. Any portal drift (operator scopes a policy to a specific AU) surfaces on the next reconciler `-Apply` or `-WhatIf` run.
- Implementation is structurally parallel to `modernGroupLocation:` (rows 1-4 established the pattern). The sorted-set comparison, schema addition, and Pester structure are all proven.
- The lab's empty-list desired state means no real Graph API calls are made during normal reconciler runs; the resolver infrastructure is required only when a future PR adds actual AUs.

**Harder:**

- The GUID-to-display-name reverse lookup in `ExportCurrentState` requires a Graph API call for each AU object ID returned by `Get-LabelPolicy`. The implementation PR must add a `Get-AdministrativeUnitIdByDisplayName` (or equivalent) helper that covers both directions and handles the `directoryObject/administrativeUnit` Graph path, which is distinct from the `users` / `groups` path that `Get-EntraPrincipalIdByDisplayName.ps1` currently covers.
- `Set-LabelPolicy -IncludedAdministrativeUnits @()` behavior (clearing vs. omitting the parameter) must be verified against the tenant: an empty array may have a different effect than omitting the parameter on `New-LabelPolicy`. The implementation PR author must confirm and document this in the WhatIf evidence block.
- Pester tests cannot use real AU GUIDs; synthetic values (`00000000-0000-0000-0000-000000000001`) must stand in for all test cases. The forward (display-name -> GUID) and reverse (GUID -> display-name) lookups are mocked.

**Security principles ([`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege / blast radius).** Scoping a policy to an AU *narrows* the policy's reach — it is a restrictive operation, not an expansive one. An empty-list `includedAdministrativeUnits: []` is equivalent to no AU restriction. The lab's empty-list desired state carries zero blast-radius change relative to the pre-implementation state.
- **#9 (idempotent and reversible).** The rollback ceremony (Decision §6) removes the AU restriction in a single `-Apply` run. No label assignments are changed; only the policy scope is widened back to all users.
- **#10 (OWASP-aware).** AU display names in YAML are not user-controlled input in production; they are authored by the lab owner. The resolver must parameterize the Graph filter call (`$filter=displayName eq '{name}'`) safely -- no string concatenation into an OData query without encoding. This is the same hygiene required for the existing `Get-EntraPrincipalIdByDisplayName.ps1`.

## Alternatives considered

1. **Track AU object IDs directly in YAML.** Rejected: AU object IDs are real Entra GUIDs, prohibited in committed YAML by the "No real identifiers in source" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). ADR 0023 §Category 3 (display-name-to-GUID resolution at deploy time) is the correct pattern.

2. **Use `${env:VAR}` tokens per ADR 0023 Category 2.** Rejected for general use: `${env:VAR}` tokens are appropriate for stable, well-known single identifiers (tenant ID, subscription ID). An array of AU GUIDs does not fit this pattern -- the number of AUs is variable, and each would require its own env var. Display-name resolution is the right approach for collections of Entra objects.

3. **Defer row 6 until admin units are provisioned in the lab.** Rejected: the `modernGroupLocation: []` precedent (ADR 0030 row 4) shows that "wired but inactive" fields have value -- they establish the schema contract and prove the reconciler handles empty collections cleanly. Waiting for an actual AU to be provisioned before tracking the field reverses this precedent.

4. **Treat `includedAdministrativeUnits:` as a TrackedScalarField.** Rejected: the field is an array, not a scalar. TrackedScalarFields exists for boolean / string scalar parameters (currently `mode` and `powerBIComplianceInformation`). Arrays follow the sorted-set comparison model used by `modernGroupLocation:` and `exchangeLocation:`.

5. **Continue to defer** (keep ADR 0015 silent on this parameter). Rejected: rows 1-5 and 7 of ADR 0030's ordered rollout are complete. The preview gate that ADR 0030 cited has been resolved (GA confirmed per Decision §1). There is no remaining rationale to defer.

## Citations

- [`Set-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) -- `-IncludedAdministrativeUnits` parameter, type `String[]`. Fetch date: 2026-06-16.
- [`New-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy) -- `-IncludedAdministrativeUnits` parameter on the create path. Fetch date: 2026-06-16.
- [`Get-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy) -- `IncludedAdministrativeUnits` property on the returned object. Fetch date: 2026-06-16.
- [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units) -- Entra administrative unit concept; cited by ADR 0030 §Decision 2 preview-trigger note.
- [Microsoft Graph API: List administrativeUnits](https://learn.microsoft.com/en-us/graph/api/administrativeunit-list) -- Graph endpoint for display-name-to-GUID resolution of administrative unit objects.
- [Scope policies to administrative units in Microsoft Purview](https://learn.microsoft.com/en-us/purview/sensitivity-labels-teams-groups-sites#apply-a-sensitivity-label-to-a-container) -- label policy administrative unit scoping context. Fetch date: 2026-06-16.
