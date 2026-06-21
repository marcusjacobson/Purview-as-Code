# 0041 — Label-policy Fabric and Power BI compliance information (`powerBIComplianceInformation`; #471 row 7)

- **Status:** Accepted
- **Date:** 2026-06-16
- **Gates:** Unblocks the row 7 implementation PR (child of [#471](../../issues/471)); does not appear in `docs/project-plan.md` §8 Open-question ADRs (cross-cutting hardening per [ADR 0030](0030-label-policies-tracked-field-expansion.md)).
- **Deciders:** @contoso

## Context

[ADR 0015](0015-label-policy-shape.md) §1 "Policy count and surface mix" focused on `*Location` parameters (`ExchangeLocation`, `ModernGroupLocation`, `PurviewLocation`) and did not contemplate the `Set-LabelPolicy -PowerBIComplianceInformation` parameter. That parameter controls whether a label policy extends sensitivity-label enforcement into Microsoft Power BI and Microsoft Fabric workspaces. It is not a `*Location` parameter and is not an `advancedSettings` key — it is a first-class boolean parameter on `Set-LabelPolicy` / `New-LabelPolicy` that activates a cross-product enforcement path.

[ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 mandates a standalone ADR for this field because "a tracked field whose authoring surface crosses out of the Information Protection plane into Fabric, Power BI, Teams, or Engage moves the architecture decision beyond 0015's scope." The specific trigger is **cross-plane or cross-product impact**: enabling `-PowerBIComplianceInformation` on the Purview side changes labeling behavior in Microsoft Fabric workspaces, which is governed by a separate admin-portal surface (Fabric Admin portal → Tenant settings → Information protection).

Three design questions must be settled before the implementation PR:

1. **YAML schema shape** — `powerBIComplianceInformation:` is a top-level boolean cmdlet parameter, not an `advancedSettings` key. The implementation must choose between (a) extending `$script:TrackedScalarFields` with a new normalized boolean entry, or (b) creating a separate boolean-field tracking path in the reconciler.
2. **Desired-state value** — whether both lab policies should enable or disable Power BI / Fabric label enforcement.
3. **Fabric-side prerequisites** — what Fabric tenant setting must be confirmed before the policy change has any visible effect.

**Environment context:** Both shipped policies currently do not declare `powerBIComplianceInformation:`. The default when the parameter is absent from a `New-LabelPolicy` call is `$false` (Power BI / Fabric enforcement disabled per the [Set-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy)).

## Decision

We will:

1. **Enable Power BI / Fabric compliance information** for both shipped policies (`powerBIComplianceInformation: true`) when the implementation PR ships. Rationale: the lab tenant has Microsoft 365 E5 licensing which includes Fabric access. Enabling label enforcement in Fabric is consistent with the lab's goal of end-to-end sensitivity label coverage across all Microsoft 365 and Fabric surfaces. The blast radius is bounded to the lab owner's Fabric workspaces (single-user tenant per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)).

2. **YAML schema shape: new top-level boolean field** `powerBIComplianceInformation:` at the policy level. The field maps directly to `Set-LabelPolicy -PowerBIComplianceInformation <Boolean>` and is **not** routed through `advancedSettings:`. In the reconciler:
   - The field is added to `$script:TrackedScalarFields` alongside `mode`.
   - `ConvertTo-PolicyHash` normalizes the YAML boolean to the lowercase string `"true"` / `"false"` for comparison consistency.
   - `ConvertTo-TenantPolicyHash` normalizes the tenant-side value from `Get-LabelPolicy`'s `PowerBIComplianceInformation` property to the same lowercase string form.
   - `Compare-PolicyHash` uses the existing scalar-field diff loop without modification.
   - The create path passes `-PowerBIComplianceInformation $true` / `$false`; the update path passes `-PowerBIComplianceInformation $true` / `$false` when drift is detected on this field.

   Reference: [`Set-LabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) — `-PowerBIComplianceInformation` parameter.

3. **GA status confirmed.** The `-PowerBIComplianceInformation` parameter appears in the GA [`Set-LabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) reference without a "Preview" designation. No preview-cmdlet exception per ADR 0030 §2 "Preview-only cmdlet on the only documented surface" is required. This row (7) does **not** share the preview-gate concern of row 6 (admin units); that distinction is what makes rows 6 and 7 separate ADRs with separate sequencing rationale.

4. **Fabric-side prerequisite: out of this repo's scope.** The Fabric Admin portal tenant setting "Apply sensitivity labels from data policies" (Admin portal → Tenant settings → Information protection) must be enabled for `powerBIComplianceInformation: true` to produce visible enforcement in Fabric workspaces. This setting is managed through the Fabric Admin portal, not through the Purview Information Protection plane, and is therefore out of scope for this repo. The implementation PR ships `powerBIComplianceInformation: true` as the desired Purview state; the Fabric tenant setting is documented as an operator prerequisite in the implementation PR description and in the lab runbook.

   Reference: [Sensitivity labels in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/governance/sensitivity-labels-in-fabric).

5. **Rollback ceremony.** To revert:
   - Set `powerBIComplianceInformation: false` in both policies in [`data-plane/information-protection/label-policies.yaml`](../../data-plane/information-protection/label-policies.yaml).
   - Run `Deploy-LabelPolicies.ps1 -Apply`.
   - Purview calls `Set-LabelPolicy -PowerBIComplianceInformation $false` for each affected policy.
   - Already-labelled Power BI / Fabric items retain their labels; the rollback only stops the policy from enforcing new label assignments via this policy.
   - No Fabric-side cleanup is required.

6. **ADR 0015 pointer.** ADR 0015 Consequences ("Follow-up issues can add…") is updated to include `powerBIComplianceInformation:` in the additive-field list with a "See ADR 0041" note, per ADR 0030 §2 "new ADR only" contract.

## Consequences

**Easier:**

- The full portal Edit-policy wizard "Microsoft Fabric and Power BI" step is now tracked. Any portal drift (operator manually toggles this setting) surfaces on the next reconciler `-Apply` or `-WhatIf` run.
- Implementation is additive: add `'powerBIComplianceInformation'` to `$script:TrackedScalarFields`, add boolean normalization to `ConvertTo-PolicyHash` / `ConvertTo-TenantPolicyHash`, extend the schema with a new optional boolean field, and populate both YAML policies. No new reconciler function needed beyond the existing scalar-field loop.
- `Compare-PolicyHash` already handles scalar-field drift via the `$script:TrackedScalarFields` loop — no changes required to the diff engine.

**Harder:**

- The reconciler must correctly read back the tenant-side value from `Get-LabelPolicy`. The `PowerBIComplianceInformation` property on the returned object must be normalized to the same lowercase string used on the desired side. Pester tests must cover the normalization path for both `$true` and `$false` tenant values.
- Enabling this setting has no visible effect in Fabric until the Fabric admin also enables the "Apply sensitivity labels from data policies" tenant setting. The implementation PR WhatIf evidence shows the Purview policy change; the Fabric side is an operator-action prerequisite documented out-of-band.

**Security principles ([`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege / blast radius).** Enabling label enforcement in Fabric affects only how Power BI and Fabric items in the lab owner's workspaces respond to sensitivity label prompts. No encryption is added at this classification level; labels carry `EncryptionEnabled = False` for `General` and `Public` per [`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml).
- **#9 (idempotent and reversible).** The rollback ceremony (Decision §5) clears the Purview policy setting in a single `-Apply` run. Already-labelled Fabric items are unaffected by the rollback.
- **#10 (OWASP-aware).** The YAML value is a boolean, not user-controlled input; no injection surface exists. The reconciler normalizes to `"true"` / `"false"` before cmdlet dispatch.

## Alternatives considered

1. **Track as an `advancedSettings:` key.** Rejected: `-PowerBIComplianceInformation` is a top-level cmdlet parameter, not an entry in the `Settings` key-value bag that `Get-LabelPolicy` returns. Routing it through `$script:AdvancedSettingsAllowlist` would require a translation step between the YAML key and the cmdlet parameter, adding complexity with no benefit. The YAML field shape must match the cmdlet's structural reality.

2. **Defer until the Fabric tenant setting is confirmed enabled.** Rejected: this repo expresses the desired Purview state. Whether the Fabric admin tenant setting is enabled is an operator prerequisite, not a gate on the reconciler code. Shipping `powerBIComplianceInformation: true` in desired-state YAML is the correct expression of intent; it produces a Purview-side update immediately and has no Fabric-side effect until the admin enables the tenant setting, which is safe.

3. **Continue to defer** (keep ADR 0015 silent on this parameter). Rejected: rows 1–5 of ADR 0030's ordered rollout are complete. The implementation pattern is proven. Row 7's only blocking gate was this ADR. There is no longer a rationale to defer; the cross-product impact is documented here and does not reveal a new unresolved design question.

## Citations

- [Set-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) — authoritative parameter list; `-PowerBIComplianceInformation` parameter, type `Boolean`.
- [New-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy) — create path; `-PowerBIComplianceInformation` accepted on creation.
- [Get-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy) — tenant read path; `PowerBIComplianceInformation` property on returned object.
- [Sensitivity labels in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/governance/sensitivity-labels-in-fabric) — Fabric-side prerequisites for label enforcement; documents the "Apply sensitivity labels from data policies" tenant setting.
- [Microsoft Purview integration with Microsoft Fabric (governance overview)](https://learn.microsoft.com/en-us/fabric/governance/microsoft-purview-fabric) — cross-product governance integration context cited by ADR 0030 row 7.
- [Create and configure sensitivity labels and their policies](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels) — overview of label policy parameter surface and cross-product scope.
