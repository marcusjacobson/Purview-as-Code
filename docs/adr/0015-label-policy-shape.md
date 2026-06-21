# 0015 — Sensitivity label policy shape (locations, scope, advanced settings)

- **Status:** Accepted
- **Date:** 2026-05-10
- **Gates:** Wave 1 — `data-plane/information-protection/label-policies.yaml` + `Deploy-LabelPolicies.ps1` ([#66](../../issues/66)); §8 Q9 ([#175](../../issues/175))
- **Deciders:** @contoso

## Context

[ADR 0015 issue #175](../../issues/175) paused [#66](../../issues/66) at idea-intake because publishing a sensitivity label policy is the first step in this repo where labels stop being declarative metadata and start changing what end-users see in Outlook, Word, SharePoint, and the Microsoft 365 sensitivity bar. Four shape decisions must be written down before code locks them in:

1. **Policy count and surface mix.** A label policy targets one or more `*Location` parameters: `ExchangeLocation` (Files & Emails), `ModernGroupLocation` (Sites & Groups), and the preview `PurviewLocation` (Schematized data assets, Wave 3 territory). Each location has different end-user impact and different rollback cost.
2. **Scope.** A policy is applied to `All` or to a list of Entra ID groups / users. Picking `All` in a single-user lab applies to the lab owner's mailbox immediately; picking a group requires that the group exist first.
3. **Advanced settings.** [`-AdvancedSettings`](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings) accepts 30+ key-value pairs that change downgrade prompts, mandatory labelling, the visibility of the sensitivity bar, color rendering, and dozens of behavioral toggles. Shipping all of them in one PR makes round-trip diffs noisy and makes the schema unwieldy.
4. **Default-label assignment.** A policy can pin a default label that is auto-applied to net-new content. This is the loudest possible end-user change: every new Word document opens with that label set.

The lab targets exactly one tenant (`contoso.onmicrosoft.com`) and exactly one human (the lab owner) per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md), so the blast-radius math is bounded — but the same code paths must remain safe to apply to a multi-user tenant later, which constrains how `*Location = All` and `Scope` are encoded.

This ADR records the minimum-viable shape so that [#66](../../issues/66) can ship a single Published policy, a `*-Disabled` round-trip placeholder, and a small advanced-settings allowlist — and so that follow-up work can extend the YAML schema additively rather than reshape it.

## Decision

We will ship sensitivity label policies under the following shape, all subject to the full-circle reconciler contract formalized in [ADR 0014](0014-agents-as-default-entry-point.md)'s downstream instruction edits ([PR #173](../../pull/173)):

1. **Policy count and surface mix — Option A + C.** The first PR for [#66](../../issues/66) ships exactly two policies in `data-plane/information-protection/label-policies.yaml`:
   - `Lab-Default-Files-Emails` — `ExchangeLocation = All`, `Mode = Enable`, applies all 11 labels from [`labels.yaml`](../../data-plane/information-protection/labels.yaml).
   - `Lab-Disabled-Placeholder` — `ExchangeLocation = All`, `Mode = PendingDeletion` (or equivalent unpublished state), no labels assigned. Exists only to exercise the non-`Published` round-trip path of `Deploy-LabelPolicies.ps1 -ExportCurrentState`.

   `ModernGroupLocation` (Option B) and `PurviewLocation` are **deferred** to follow-up issues. The schema must allow them additively without a breaking change.

   **Updated 2026-06-16 (PR for #653; ADR 0030 row 4).** `ModernGroupLocation` (Option B) is now implemented. The schema gains an optional `modernGroupLocation:` array-of-strings field; both shipped policies carry `modernGroupLocation: []` (field present, empty — wired but inactive until a real Microsoft 365 group is assigned). The reconciler tracks the field as a sorted set with the same diff / apply / export pattern as `exchangeLocation`. Cmdlet reference: [`Set-LabelPolicy -ModernGroupLocation`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy). Per [ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 this addition amends in place. `PurviewLocation` remains deferred.

2. **Scope — Option A.** Both policies use `ExchangeLocation = All`. We do **not** create a `lab-sensitivity-pilot` Entra group at this time — there is no second test identity to scope it against, and creating an empty group only to satisfy a YAML field adds drift surface. The schema must allow a `scope:` field (group object IDs, with the zero-GUID placeholder as the example value) so a future PR can pivot to Option B without reshape.

   **Updated 2026-05-31 (PR for #492; ADR 0030 row 3).** The schema gains an optional `exchangeLocationException:` list — the orthogonal "exclude these mailboxes / mail-enabled groups" knob the Edit-policy wizard exposes alongside the all-mailboxes default. Microsoft Learn investigation: the [`Set-LabelPolicy` `-ExchangeLocationException` parameter](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) accepts mailbox SMTP / DN / GUID or mail-enabled group identifiers verbatim; mail-enabled-group membership is expanded server-side at publish time. **Significantly: no Microsoft Graph principal-id resolution required** (the issue body anticipated [`Get-EntraPrincipalIdByDisplayName.ps1`](../../scripts/Get-EntraPrincipalIdByDisplayName.ps1) per [ADR 0023](0023-identifier-resolution.md) §Category 3, but the investigation found Exchange/SCC accepts these identifiers without Graph translation). Both shipped policies leave the field unset; flipping any policy's scope to a specific exclusion list is its own follow-up per ADR 0030 §5. The deferred `scope:` envelope shape is still future work for any *include* (Option B group scope) flow — this update only delivers the exclusion direction. Per [ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 the row amends in place rather than spawning its own ADR; the blast-radius framing in this section (Option A All-users default; opt-in narrowing) is preserved.

3. **Advanced settings — three keys only.** The first PR allows exactly three keys in the YAML schema's `advancedSettings:` map:
   - `RequireDowngradeJustification = true` — prompt the user when reducing classification.
   - `MandatoryLabelling = false` — do not block save / send on unlabelled items in the lab.
   - `HideBarByDefault = false` — show the sensitivity bar so the lab owner can see the experience under test.

   Any other key in `advancedSettings:` is a schema validation error in the first PR. Additional keys are added one-per-follow-up-issue with a Learn citation justifying each, per the [advanced settings reference](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings).

   **Updated 2026-05-31 (PR #488; ADR 0030 row 1).** The allowlist gains a fourth key, `OutlookDefaultLabel` (value: label reference, composite or bare display name; resolved YAML-side to the immutable label GUID by `Resolve-DesiredAdvancedSettingLabel` in [`scripts/Deploy-LabelPolicies.ps1`](../../scripts/Deploy-LabelPolicies.ps1)). The lab pins both shipped policies to `OutlookDefaultLabel: Public` — the lowest classification, so the pre-selection still lets the user opt up before send. Per [ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 this addition amends in place rather than spawning its own ADR, because the blast-radius framing in §3 above (Outlook-only, user-changeable, no silent application) was already anticipated. Citation: [Outlook-specific options for default label and mandatory labeling](https://learn.microsoft.com/en-us/purview/sensitivity-labels-aip#outlook-specific-options-for-default-label-and-mandatory-labeling).

   **Updated 2026-05-31 (PR #490; ADR 0030 row 2).** The allowlist gains a fifth key, `teamworkdefaultlabelid` (value: label reference, composite or bare display name; resolved via the same `Resolve-DesiredAdvancedSettingLabel` helper used for `OutlookDefaultLabel`). The lab pins both shipped policies to `teamworkdefaultlabelid: Public` for the same lowest-classification rationale; the meetings surface is symmetric to the Outlook-emails surface in blast-radius terms (calendar event opens with the label pre-selected; user may change before send; no silent application). Key name is all-lowercase per the Microsoft Learn example shape (`Set-LabelPolicy -AdvancedSettings @{teamworkdefaultlabelid="General"}`). Per [ADR 0030](0030-label-policies-tracked-field-expansion.md) §2 this addition amends in place — the blast-radius framing applies unchanged. Citations: [`Set-LabelPolicy` reference (teamworkdefaultlabelid)](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy), [Use sensitivity labels to protect calendar items, Teams meetings, and chat](https://learn.microsoft.com/en-us/purview/sensitivity-labels-meetings).

4. **Default-label assignment — none.** Neither policy assigns a default label. The schema allows an optional `defaultLabel:` field, but its value is `null` in both shipped policies. Auto-applying a default label is the highest-impact end-user change available in this surface; deferring it keeps the first PR's smoke test bounded to "policy created, policy published, drift report empty" rather than "every new Word document in the tenant now opens labelled `General`."

   **See [ADR 0040](0040-default-label-for-documents.md).** ADR 0040 reverses this deferral (PR for [#655](../../issues/655); ADR 0030 row 5). The `DefaultLabel` advanced setting is added to `$script:AdvancedSettingsAllowlist` and `$script:LabelReferenceAdvancedSettingsKeys`; the schema's `advancedSettings.propertyNames` pattern is extended. Note: ADR 0040 supersedes this section's schema note — the implementation uses `advancedSettings.DefaultLabel` (AdvancedSettings key), not a top-level `defaultLabel:` YAML field.

## Consequences

**Easier:**

- [#66](../../issues/66) unblocks immediately. The Automation Engineer can implement against a fixed shape.
- The `-WhatIf` plan-table smoke test for [#66](../../issues/66) has a known minimum: one `Create` row for `Lab-Default-Files-Emails`, one `Create` row for `Lab-Disabled-Placeholder`, zero `Update` / `Orphan` / `Conflict` rows. `-ExportCurrentState` round-trip is deterministic by construction (only two objects, three advanced-settings keys, no group resolution).
- Follow-up issues can add `ModernGroupLocation`, `PurviewLocation`, `powerBIComplianceInformation:`, `includedAdministrativeUnits:`, additional `advancedSettings:` keys, group `scope:`, and `defaultLabel:` one-by-one without reshape. **See [ADR 0041](0041-label-policy-fabric-powerbi.md)** for the `powerBIComplianceInformation:` cross-product design decision (ADR 0030 row 7). **See [ADR 0042](0042-label-policy-admin-units.md)** for the `includedAdministrativeUnits:` GA-status and identifier-resolution design decision (ADR 0030 row 6).
- Blast radius is bounded: the lab owner's mailbox sees the labels in Outlook on the web within minutes (per [Microsoft documentation on label propagation](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#when-changes-take-effect)), but no auto-labeling, no mandatory prompts, no default classification.

**Harder:**

- [#67](../../issues/67) (auto-label policies) cannot reuse this YAML structure verbatim — auto-labeling has its own `*Location` parameters and its own simulation lifecycle (`TestWithoutNotifications` → `TestWithNotifications` → `Enable`). It will need its own ADR if shape questions emerge during its `@idea-intake`.
- The `Lab-Disabled-Placeholder` policy adds noise to a real production tenant if the YAML is ever applied without filtering. The schema must require a `mode:` field per policy and `Deploy-LabelPolicies.ps1` must refuse to mark `mode: PendingDeletion` policies as `Published`.
- Adding a `defaultLabel:` later is a real behavior change for end-users; that PR will require the `destructive` label per the [pre-commit checklist](../../.github/instructions/pre-commit.instructions.md).

**Security principles (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege).** `ExchangeLocation = All` in a single-user lab is least-impact, not most-impact: the only mailbox affected is the lab owner's. In a future multi-user tenant, the schema's `scope:` field lets a PR shrink the surface without reshape.
- **#9 (idempotent and reversible).** The `Lab-Disabled-Placeholder` policy explicitly exists to exercise the non-Published export path — without it, the first run of `Deploy-LabelPolicies.ps1 -ExportCurrentState` against any tenant that ever had a disabled policy would produce a drift the script could not reconcile.
- **#10 (OWASP-aware).** `RequireDowngradeJustification = true` ensures audit-log evidence when a user downgrades a label, supporting the broader compliance posture per [Sensitivity labels — what they can do](https://learn.microsoft.com/en-us/purview/sensitivity-labels#what-sensitivity-labels-can-do).

**Project-plan items:**

- Unblocks: [#66](../../issues/66) (label policies). Wave 1c progress can resume.
- Does not affect: [#67](../../issues/67) (auto-labeling — independent shape decision), [#68](../../issues/68) (schemas — consumes the shape this ADR defines), Wave 2 onward.

## Alternatives considered

- **Do nothing / keep the status quo.** Rejected. The status quo is "[#66](../../issues/66) paused indefinitely waiting for the lab owner to make four implicit decisions during code review." That violates the project-plan §1 cadence rule of "one item per PR with explicit acceptance criteria" and forces the policy shape to be re-litigated in the PR review thread instead of in a versioned design document.
- **Ship the kitchen-sink shape.** Two policies × five locations × all 30+ advanced-settings keys × group-scoped × default label assigned. Rejected on three grounds: (a) blast radius is unbounded — the lab owner's experience changes instantly across every M365 surface; (b) the schema becomes large enough that round-trip determinism is harder to prove; (c) adding ten things at once means any one of them failing forces a rollback of all ten.
- **Defer to portal-first authoring, then export.** Author the policies in the Microsoft Purview portal, then run `Deploy-LabelPolicies.ps1 -ExportCurrentState` to seed the YAML. Rejected because it inverts the source-of-truth contract: the YAML is supposed to be authored, the tenant is supposed to be reconciled. Portal-first authoring is the reactive drift-back path (`sync-label-policies-from-tenant.yml`), not the design path. The reconciler can still be exercised via export against this ADR's two policies once they are in YAML, satisfying the first-run-against-an-existing-tenant contract from [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md).

## Citations

- [Sensitivity labels — what they can do](https://learn.microsoft.com/en-us/purview/sensitivity-labels#what-sensitivity-labels-can-do)
- [Publish sensitivity labels by creating a label policy](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#publish-sensitivity-labels-by-creating-a-label-policy)
- [`New-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy)
- [`Set-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy)
- [`Get-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy)
- [Custom configurations for sensitivity labels (advanced settings)](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings)
- [When changes to sensitivity labels take effect](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#when-changes-take-effect)
