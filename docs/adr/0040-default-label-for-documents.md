# 0040 — Default label for documents (`DefaultLabel` advanced setting; #471 row 5)

- **Status:** Accepted
- **Date:** 2026-06-16
- **Gates:** Unblocks the row 5 implementation PR (child of [#471](../../issues/471)); does not appear in `docs/project-plan.md` §8 Open-question ADRs (cross-cutting hardening per [ADR 0030](0030-label-policies-tracked-field-expansion.md)).
- **Deciders:** @contoso

## Context

[ADR 0015](0015-label-policy-shape.md) §"Default-label assignment — none" deliberately deferred the `defaultLabel:` surface:

> "Neither policy assigns a default label. The schema allows an optional `defaultLabel:` field, but its value is `null` in both shipped policies. Auto-applying a default label is the highest-impact end-user change available in this surface; deferring it keeps the first PR's smoke test bounded to 'policy created, policy published, drift report empty' rather than 'every new Word document in the tenant now opens labelled General'."

[ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 mandates a standalone ADR for this specific deferral reversal because "ADR 0015 §'Default-label assignment — none' deferred this specifically and called it out as the loudest possible end-user change. Reversing that deferral is a security decision worth its own record."

Three design questions must be settled before the implementation PR:

1. **Which label** to default to for Office documents (Word, Excel, PowerPoint, and other file types covered by the built-in labeling client).
2. **YAML schema shape** — ADR 0015 §4 anticipated a top-level `defaultLabel:` field. The cmdlet surface, however, maps through `Set-LabelPolicy -AdvancedSettings @{DefaultLabel="<label-GUID>"}` (per the [sensitivity-labels-office-apps advanced settings reference](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings)). These two shapes are not the same; the ADR must resolve which shape the implementation uses.
3. **Interaction with `RequireDowngradeJustification`** and the **rollback ceremony** for clearing a live default.

**Environment context:** Both shipped policies ([`data-plane/information-protection/label-policies.yaml`](../../data-plane/information-protection/label-policies.yaml)) already declare:

```yaml
advancedSettings:
  OutlookDefaultLabel: "General"          # row 1 — PR #488
  RequireDowngradeJustification: "true"
  teamworkdefaultlabelid: "General"       # row 2 — PR #490
```

The `General` label is the chosen default for email and meetings. The label hierarchy in [`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml) runs (lowest → highest): `Public` → `General` → `Confidential/*` → `Highly Confidential/*`.

## Decision

We will:

1. **Enable the document default label** for both shipped policies, set to `General` — the same value used for `OutlookDefaultLabel` and `teamworkdefaultlabelid`. Cross-surface consistency is the primary rationale: a document that opens alongside a `General`-defaulted email should start at the same classification baseline. The blast-radius is bounded to the lab owner's documents (single-user tenant per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)).

   ADR 0030 §3 item 5 recommended `Public` as the document default ("lowest classification, so smallest blast radius"). That recommendation is overridden here in favor of cross-surface consistency. `General` carries no encryption and no access restriction; it is still a low-risk classification. The only observable end-user change is that new Word/Excel/PowerPoint files open with "General" pre-selected in the sensitivity bar — the user can change it before saving.

2. **YAML shape: add `DefaultLabel` to `advancedSettings:` as the sixth AdvancedSettingsAllowlist key**, not as a standalone top-level `defaultLabel:` field. Rationale:
   - The `Set-LabelPolicy -AdvancedSettings` route is the documented cmdlet surface for this setting (reference: [Sensitivity labels for Office apps — configure advanced settings](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings)).
   - `OutlookDefaultLabel` and `teamworkdefaultlabelid` (rows 1 and 2) already live in `advancedSettings:`. Adding `DefaultLabel` there is consistent: same deserialization path, same allowlist gate, same `Resolve-DesiredAdvancedSettingLabel` label-reference resolution, same `Compare-PolicyHash` diff mechanism.
   - A top-level `defaultLabel:` field would require a separate schema branch, a separate reconciler path, and a separate export-emission block — all to deliver the same cmdlet call. The added complexity has no benefit.
   - ADR 0015 §4's schema note ("The schema allows an optional `defaultLabel:` field") is superseded by this decision. The implementation PR will add `DefaultLabel` (note: capital-D, capital-L — the exact casing used in the AdvancedSettings key per the Learn reference) to the schema's `advancedSettings.propertyNames` allowlist pattern, not to the top-level `labelPolicy` schema object.

   `DefaultLabel` is a `LabelReferenceAdvancedSettingsKey` (value is a label reference — composite key or bare display name — resolved to an immutable label GUID by `Resolve-DesiredAdvancedSettingLabel` before the Compare-PolicyHash diff, the same as `OutlookDefaultLabel` and `teamworkdefaultlabelid`).

3. **`RequireDowngradeJustification` interaction.** Both shipped policies carry `RequireDowngradeJustification: "true"`. With `DefaultLabel = "General"`:
   - A user changing a document from `General` to `Public` (lower in the hierarchy) triggers the downgrade-justification prompt. This is intended behavior — the user explicitly acknowledges moving to a lower classification.
   - A user changing from `General` to any `Confidential/*` or `Highly Confidential/*` label (higher) does not trigger the prompt. Upgrades are frictionless.
   - A document that already carries a label higher than `General` (e.g., `Confidential/Internal`) is unaffected — the default label is only applied to new, unlabelled content. The sensitivity bar will show the existing label, not override it.
   - Edge case: `Public` is the lowest classification; an operator who sets `DefaultLabel = "Public"` would see no downgrade prompt from the default (there is no lower label to downgrade to from Public). That scenario is not the lab's chosen configuration, but the interaction is documented here for completeness.

4. **Rollback ceremony.** To clear the document default label after it has been applied to the tenant:
   - In YAML: remove the `DefaultLabel` key from `advancedSettings:` (or set it to the empty string `""`; the reconciler should emit a no-op if the key is absent from YAML and absent from the tenant).
   - The reconciler detects drift: tenant has `DefaultLabel = <GUID>`, desired has no `DefaultLabel` entry → `advancedSettings.DefaultLabel` diff fires.
   - Clearing path: `Set-LabelPolicy -Identity <name> -AdvancedSettings @{DefaultLabel=""}` (passing an empty string is the documented clearing mechanism for AdvancedSettings keys per the [Set-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy)).
   - After the rollback PR merges and the deploy pipeline runs, new documents in the tenant open without a pre-selected label. Existing documents that were already auto-labelled on open retain their user-chosen label (the default label is an open-time suggestion, not a background auto-apply).
   - Rollback is not destructive to existing labelled content; it is low-ceremony and low-risk.

## Consequences

**Easier:**

- The full portal Edit-policy wizard "Default label for documents" step is now tracked. Any portal drift (operator manually changes the default) will surface on the next reconciler `-Apply` or `-WhatIf` run.
- Implementation is additive: add one key (`DefaultLabel`) to `$script:AdvancedSettingsAllowlist` and `$script:LabelReferenceAdvancedSettingsKeys`, extend the schema's `propertyNames` pattern, and populate the YAML. No new schema branch, no new reconciler function.
- ADR 0015 §4 schema note is resolved: the `defaultLabel:` top-level field it anticipated is superseded cleanly; the implementation PR amends ADR 0015 to note this.

**Harder:**

- Every new Office document that a lab-owner session opens will be pre-labelled `General`. The user must actively choose to leave it at `General` or upgrade. For a single-user lab this is low friction; in a multi-user tenant the same approach would require policy-scoping to a pilot group before a broad rollout.
- The `RequireDowngradeJustification` prompt now has a reachable trigger path (General → Public), which was not reachable when no default was set (no label to downgrade from). Lab owners who use `Public` as a working label will see the prompt once per document until they acknowledge the change. This is correct behavior, not a regression.

**Security principles ([`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege / blast radius).** `General` carries no encryption or access restriction. The default label does not silently encrypt or restrict sharing — it is a classification marker only. Blast radius: one user, one tenant, labels that carry no automated enforcement at this classification level.
- **#9 (idempotent and reversible).** The rollback ceremony (Decision §4) is low-ceremony and non-destructive to already-labelled content. The implementation PR ships `-WhatIf` evidence confirming a `NoChange` drift report before and an `Update` report after the YAML is populated.
- **#10 (OWASP-aware).** `DefaultLabel` value is a label reference resolved at deploy time via the existing `Resolve-DesiredAdvancedSettingLabel` helper; no raw GUID or user-controlled string is interpolated into a cmdlet call without sanitization.

## Alternatives considered

1. **Use `Public` as the document default** (per ADR 0030 §3 item 5 recommendation). Rejected: `Public` creates cross-surface inconsistency (email = `General`, meeting = `General`, document = `Public`). A new document opened from a `General`-labelled email would carry a *lower* default classification than the email that prompted its creation. The blast-radius difference between `Public` and `General` is negligible in a single-user lab; consistency wins.

2. **Use a top-level `defaultLabel:` YAML field** (per ADR 0015 §4 schema note). Rejected: the cmdlet maps `DefaultLabel` through `AdvancedSettings`, not through a top-level parameter. A top-level YAML field would require a separate reconciler branch (outside `ConvertTo-PolicyHash` / `ConvertTo-TenantPolicyHash` / `Compare-PolicyHash`'s existing structured-field and AdvancedSettings paths) to achieve the same result. Extra complexity, no benefit.

3. **Continue to defer** (keep ADR 0015 §4's original stance). Rejected: rows 1–4 of ADR 0030's ordered rollout are complete. The lab has exercised the direction-policy contract (ADR 0029) against four fields; the implementation pattern is proven. The remaining blast-radius concern ("every new Word document opens labelled") is real but bounded to the single-user lab and reversible per Decision §4.

## Citations

- [Sensitivity labels for Office apps — configure advanced settings](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings) — documents the `DefaultLabel` AdvancedSettings key and its interaction with `OutlookDefaultLabel`.
- [Set-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) — authoritative parameter list; confirms `AdvancedSettings` is the clearing path (empty string).
- [New-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy) — create path; `AdvancedSettings` accepted on creation.
- [Get-LabelPolicy reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy) — tenant read path; `Settings` property carries AdvancedSettings key-value pairs.
- [Create and configure sensitivity labels and their policies](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels) — overview of default-label behavior in Microsoft Purview.
