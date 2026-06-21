# 0016 — Auto-labeling policy shape (mode, scope, rules, advanced settings)

- **Status:** Accepted
- **Date:** 2026-05-13
- **Gates:** Wave 1 — `data-plane/information-protection/auto-label-policies.yaml` + `Deploy-AutoLabelPolicies.ps1` ([#67](../../issues/67))
- **Deciders:** @contoso
- **Related:** [ADR 0015](0015-label-policy-shape.md) (sibling shape decision for sensitivity-label *publishing* policies — this ADR is its mirror for *auto-labeling*).

## Context

Sensitivity labels are declarative metadata (#65). Label policies (#66, [ADR 0015](0015-label-policy-shape.md)) publish those labels to end-user surfaces, but a user still has to click the label. **Auto-labeling policies** ([#67](../../issues/67)) inspect content server-side and apply a label automatically when it matches a rule — typically `ContentContainsSensitiveInformation` against one or more Sensitive Information Types (SITs) from #80's `sit-catalog.yaml`. They are a distinct construct with their own cmdlet family (`*-AutoSensitivityLabelPolicy`, `*-AutoSensitivityLabelRule`), their own mode vocabulary (which doubles as the simulation lifecycle), and their own blast-radius math — they can re-classify mailbox / SharePoint / OneDrive content without user interaction.

[ADR 0015](0015-label-policy-shape.md) "Consequences" called this out: "[#67](../../issues/67) cannot reuse this YAML structure verbatim — auto-labeling has its own `*Location` parameters and its own simulation lifecycle (`TestWithoutNotifications` → `TestWithNotifications` → `Enable`). It will need its own ADR if shape questions emerge during its `@idea-intake`." This ADR records those decisions before [#67](../../issues/67) commits code, so the YAML schema, the reconciler's tracked-field set, the `advancedSettings` allowlist, and the simulation contract are versioned design choices rather than choices made implicitly in PR review.

The lab targets a single tenant (`contoso.onmicrosoft.com`) and a single human (the lab owner) per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md), so the blast radius is bounded — but the same code path must remain safe to apply to a multi-user tenant later. That constrains how `mode`, `*Location`, and rule scoping are encoded today.

## Decision

We will ship auto-labeling policies under the following shape, all subject to the full-circle reconciler contract from [ADR 0014](0014-agents-as-default-entry-point.md) and the lessons learned on `Deploy-LabelPolicies.ps1` (PRs #193, #196, #198, #201):

1. **Policy and rule count — one of each.** The first PR for [#67](../../issues/67) ships exactly one policy and one rule in `data-plane/information-protection/auto-label-policies.yaml`:
   - Policy `Lab-AutoLabel-CreditCards` — `Mode = TestWithoutNotifications`, `ExchangeLocation = All`, `ApplyLabel = Confidential/Extended` (composite key resolved against `labels.yaml`).
   - Rule `Lab-AutoLabel-CreditCards-Rule` — single `ContentContainsSensitiveInformation` entry referencing the **Credit Card Number** SIT (`50842eb7-edc8-4019-85dd-5a5c1f2bb085`, Microsoft built-in, schema-reference GUID per `sit-catalog.yaml`).

   Additional policies and additional rules per policy are deferred to follow-up issues. The schema must allow both additively without reshape.

2. **Workload scope — Exchange only.** The first PR's policy uses `ExchangeLocation = All` and **does not** include `SharePointLocation`, `OneDriveLocation`, or `Teams*Location`. This matches the [ADR 0015](0015-label-policy-shape.md) §1 boundary for the sibling publishing policy: the lab owner's mailbox is the only end-user surface that already sees the label taxonomy. Site- and Teams-scoped auto-labeling expands the surface area to content the lab owner has not yet exercised through the publishing policy, and is the larger of two blast-radius increases — sequenced last. The schema must accept the other `*Location` fields additively without reshape.

3. **Mode default + simulation contract — `TestWithoutNotifications`, with implicit `-StartSimulation` for any `Test*` policy the reconciler touches.** The first PR ships `mode: TestWithoutNotifications`, which corresponds to the auto-labeling lifecycle state "simulation only — no end-user impact." This satisfies the [#67](../../issues/67) exit criterion "one policy in `TestWithoutNotifications` mode with simulation started against synthetic data." The cmdlet family emits a warning on every `New-AutoSensitivityLabelPolicy` / `New-AutoSensitivityLabelRule` / `Set-AutoSensitivityLabelRule` call instructing the operator to also call `Set-AutoSensitivityLabelPolicy -StartSimulation $true` for the change to take effect (verified against the lab tenant 2026-05-13). Rather than expose a parallel `-StartSimulation` switch on the reconciler — which would create a class of bug where `mode:` and the switch disagree — the reconciler treats `Set-AutoSensitivityLabelPolicy -StartSimulation $true` as an **internal post-write step** that fires automatically for every `Test*`-mode policy the Apply phase Created or Updated, AND for every `Test*`-mode policy whose rule(s) the Apply phase Created or Updated (CCSI changes require a simulation restart). `mode:` remains the single committed-YAML control surface; the `-StartSimulation` call is unconditional plumbing, not a user-facing knob. Lifecycle promotion (`TestWithoutNotifications` → `TestWithNotifications` → `Enable`) is performed exclusively by editing the `mode:` field in committed YAML and re-running Apply. Demotion is the same path in reverse; the move from `Enable` back to any `Test*` mode must carry the `destructive` PR label per [`pre-commit.instructions.md`](../../.github/instructions/pre-commit.instructions.md).

4. **Rule shape — minimum viable, allowlisted fields only.** The rule schema in the first PR accepts these tracked fields:
   - `name` (string, required, unique within the file).
   - `policy` (string, required, must reference an existing `policies[].name`).
   - `workload` (string, required) — the rule's target workload. `New-AutoSensitivityLabelRule` requires this at create time; the first PR uses `Exchange` to match the policy's `exchangeLocation:`. **The reconciler does not track `workload` in its drift set**: verified against the lab tenant 2026-05-13, the cmdlet accepts the input but the read-back always returns the full expanded workload string (`Exchange, SharePoint, OneDriveForBusiness, PowerBI, Applications, Azure, AWS`) regardless of the input value. Tracking it would produce perpetual false-positive drift. The field is therefore write-only at create time; mutating it post-create requires `-PruneMissing` + recreate (no `Set-AutoSensitivityLabelRule -Workload` exists either).
   - `contentContainsSensitiveInformation` (list of SIT references; required, non-empty). Each entry has:
     - `sitId` (string, required, GUID present in `sit-catalog.yaml`).
     - `minCount` (int, optional, default `1`).
     - `minConfidence` (int, optional, default `75`).
   - `groupingOperator` — intentionally **not** part of the rule schema. `New-AutoSensitivityLabelRule` / `Set-AutoSensitivityLabelRule` do not expose `-GroupingOperator` (verified against the lab tenant 2026-05-13); multi-SIT grouping, when it arrives, is expressed inside `contentContainsSensitiveInformation` itself.

   All other `New-AutoSensitivityLabelRule` parameters (`AccessScope`, `AnyOfRecipientAddressContainsWords`, `FromAddressContainsWords`, `HeaderMatchesPatterns`, `DocumentIsPasswordProtected`, etc.) are **schema validation errors** in the first PR. Adding any one requires a follow-up issue with a Microsoft Learn citation, same gating principle as the `advancedSettings` allowlist in [ADR 0015](0015-label-policy-shape.md) §3.

5. **Advanced settings allowlist — empty.** `auto-label-policies.yaml` may declare an `advancedSettings:` map per policy, but the first PR's allowlist is `@()` — any non-empty map is a schema validation error. The reconciler ships with `$script:AdvancedSettingsAllowlist = @()` from commit 1; adding the first key requires a new ADR follow-up issue and a Microsoft Learn citation. Tenant-side keys observed during `-ExportCurrentState` are filtered to the same (empty) allowlist before being written back to YAML, so a round-trip Export → Apply against an existing tenant cannot smuggle in unaudited settings.

6. **`ApplyLabel` reference shape — composite key.** Each policy declares exactly one `applyLabel:` field, using the same composite-key shape as `labels.yaml` and `label-policies.yaml` (`<parent>/<displayName>` for sublabels, bare `<displayName>` for top-level). The reconciler resolves the composite key against `Get-Label` at Apply time and passes the immutable label GUID to `New-/Set-AutoSensitivityLabelPolicy`. PR #196's "rendered name vs GUID" lesson on `Deploy-LabelPolicies.ps1` carries over verbatim: `Get-AutoSensitivityLabelPolicy.ApplyLabel` may return a rendered display name rather than a GUID, and `ConvertTo-TenantPolicyHash` MUST translate via the `Get-Label` lookup before diffing.

7. **Tracked scalar fields and runtime-state map.** The reconciler's `$script:TrackedPolicyScalarFields` is exactly `@('mode', 'applyLabel')` and `$script:TrackedRuleScalarFields` is exactly `@('policy')` in commit 1, plus the list-typed field `exchangeLocation` (policy) and `contentContainsSensitiveInformation` (rule). `workload` is deliberately excluded from the rule tracked set per Decision 4 (write-only behavior). `policy` is diff-blocking (re-parenting isn't supported by the cmdlet family). The runtime-state map `$script:RuntimePolicyModeMap` ships empty in commit 1 and gains entries only when `Get-AutoSensitivityLabelPolicy.Mode` is observed to return a value that `Set-AutoSensitivityLabelPolicy -Mode` rejects. PR #193's throw-on-unmapped contract on `Deploy-LabelPolicies.ps1` carries over verbatim — unmapped values surface as a loud failure rather than as silent drift.

8. **First-run-against-existing-tenant contract.** `Deploy-AutoLabelPolicies.ps1` REQUIRES `-ExportCurrentState` before the first `-Apply` against any tenant, same as `Deploy-LabelPolicies.ps1` and `Deploy-Labels.ps1`. The YAML header must call this out prominently, and the script `.NOTES` must reference [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) "First-run-against-an-existing-tenant contract."

9. **Verify-Published semantics — presence-only across all modes.** The reconciler's `-VerifyPublished` switch checks that every declared policy exists in the tenant. Verified against the lab tenant 2026-05-13: `Get-AutoSensitivityLabelPolicy.Status`, `.TestModeStatus`, and `.TestModeVerdict` are all blank on both `Enable` and `Test*` policies. There is no mode-derived runtime field exposed by the cmdlet that we can assert against. Consequently:
   - Policy present in tenant → `Pass` (regardless of declared `mode:`).
   - Policy not in tenant → `Missing` → `Fail`.
   The verify report includes the tenant's `Mode` value for human inspection. A richer mode-aware verify will be added if and when Microsoft populates a usable runtime status field; that change is out of scope for this ADR.

10. **Tombstone (`PendingDeletion`) Mode values are filtered at read time.** Verified against the lab tenant 2026-05-13 during the Enable-mode follow-up (#203): immediately after `Remove-AutoSensitivityLabelPolicy`, the tenant continues to return the deleted policy from `Get-AutoSensitivityLabelPolicy` for several minutes with `Mode = 'PendingDeletion'`. This is a Microsoft-side tombstone marker, not a valid input mode (`Set-AutoSensitivityLabelPolicy -Mode PendingDeletion` is not accepted by the cmdlet — see [`new-autosensitivitylabelpolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy)). The reconciler filters these rows out via `Test-IsTombstonePolicy` at every read site (Apply, Verify, Export) BEFORE `ConvertTo-PolicyInputMode` runs, so the strict throw-on-unmapped contract from Decision 7 stays loud for genuine drift while a perfectly normal delete-then-recreate cycle does not blow up the reconciler. The tombstone list is `$script:TombstonePolicyModes = @('PendingDeletion')`; new tombstone values discovered against the lab tenant are added there with a comment citing the date verified.

11. **Enable-mode coverage (#203 follow-up).** Verified against the lab tenant 2026-05-13: an `Enable`-mode auto-label policy + rule pair is created/updated/deleted by the same cmdlet sequence as `Test*` modes, with two operationally relevant differences:
    - The Phase-4 implicit `Set-AutoSensitivityLabelPolicy -StartSimulation $true` step from Decision 3 MUST be skipped for `Enable`-mode policies (simulation is a Test*-only concept). The reconciler's `($entry.Desired.mode -like 'Test*')` guard already enforces this; verified no `Started simulation on...` line emitted for `Enable`-mode Create or Update.
    - The cmdlet's stock `WARNING: Any updates to auto labeling policy requires simulation to be restarted...` fires on every `Enable`-mode Create/Update regardless. This is Microsoft-side noise; the reconciler does not invoke `-StartSimulation` and the warning has no effect for Enable.
    - `Enable`-mode policies do not require an Exchange transport-rule companion; `-VerifyPublished` Pass on a freshly-created `Enable`-mode policy is sufficient evidence the policy is published.

## Consequences

**Easier:**

- [#67](../../issues/67) unblocks immediately with a fixed shape. The Automation Engineer can implement against a definite tracked-field surface.
- The `-WhatIf` plan-table smoke test for [#67](../../issues/67) has a known minimum: one `Create` row for the policy, one `Create` row for the rule, zero `Update` / `Orphan` / `Conflict` rows. `-ExportCurrentState` round-trip is deterministic by construction (one policy, one rule, two tracked scalar fields, empty advanced-settings, one SIT reference).
- Blast radius is bounded: `TestWithoutNotifications` is simulation-only, no user prompts, no actual label assignment until the lab owner reviews simulation results and promotes the policy in a separate PR.
- Follow-up issues can add additional policies, additional rules, additional workloads (`SharePointLocation`, `OneDriveLocation`), additional rule conditions, and additional advanced-settings keys one-by-one without reshape.

**Harder:**

- The reconciler must handle a two-object identity (policy + rule) per logical "auto-labeling policy" — both must be created/updated atomically from a write-failure perspective, and the rule's `Policy` field becomes a foreign-key reference. A rule whose `policy:` references a name not in `policies[]` is a schema validation error.
- Promotion to `mode: Enable` is the loudest possible end-user change in this surface (Microsoft Purview server-side will start labelling matching content in the lab owner's mailbox). That PR will require the `destructive` label and explicit reviewer approval, per the [pre-commit checklist](../../.github/instructions/pre-commit.instructions.md).
- The first reconciler run against a tenant that has portal-authored auto-labeling policies will report them as `Orphan` (or surface them via `-ExportCurrentState`). The first-run contract from §8 mitigates this but does not eliminate it — operators must remember to seed the YAML before Apply.

**Security principles (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege).** `ExchangeLocation = All` in a single-user lab is bounded scope. The schema's `*Location` and rule-scoping fields let a future PR shrink the surface without reshape.
- **#9 (idempotent and reversible).** `mode: TestWithoutNotifications` is intrinsically reversible — no production label assignments occur. Demotion from `Enable` is a same-shape YAML edit; deletion is `-PruneMissing` and carries the `destructive` label.
- **#10 (OWASP-aware).** SIT references are GUIDs from a vetted catalog (#80), not free-form regex strings — auto-labeling cannot be tricked into matching arbitrary content by editing the auto-label YAML alone.

**Sample-data rule (from [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md)):**

- The Credit Card Number SIT is a Microsoft built-in detector with bounded false-positive behaviour against synthetic test data (the Visa test number `4111 1111 1111 1111` and its peers are documented brand-published test PANs that this SIT is designed to match). No real PAN appears in this repo at any point.

**Project-plan items:**

- Unblocks: [#67](../../issues/67) (auto-label policies). Wave 1d progress can resume.
- Does not affect: [#68](../../issues/68) (schemas — consumes the shape this ADR defines), Wave 2 onward.

## Alternatives considered

- **Reuse the `label-policies.yaml` shape verbatim.** Rejected for the reason called out in [ADR 0015](0015-label-policy-shape.md) "Consequences": the cmdlet families are different, the mode vocabulary is different (auto-labeling overloads `Mode` as the simulation switch), and the rule construct has no analogue in publishing policies. Forcing a single schema means either every publishing policy carries an unused `rules:` block or every auto-label policy carries unused publishing fields — both are drift surface.
- **Author the policy and rule in one YAML node.** Collapse `policies[]` and `rules[]` into a single nested block, e.g. `policies[].rule:`. Rejected because the cmdlet API treats them as independent objects with independent identifiers and independent write paths; collapsing them in YAML obscures the two-step create / two-step update / two-step prune the reconciler has to perform anyway. The flat shape (`policies:` plus `rules:` with a `policy:` foreign key) maps 1:1 to the cmdlets and to `-ExportCurrentState`.
- **Ship the kitchen-sink rule schema** with every `New-AutoSensitivityLabelRule` parameter exposed in YAML. Rejected on the same grounds as [ADR 0015](0015-label-policy-shape.md): unbounded blast radius (rule fields like `DocumentIsPasswordProtected` change which content gets re-classified server-side), large round-trip surface, and any one field's bug forces a rollback of all of them.
- **Defer to portal-first authoring, then export.** Rejected for the same reason as [ADR 0015](0015-label-policy-shape.md): the YAML is the source of truth, the tenant is the target. Portal-first is the reactive drift-back path, not the design path.
- **Expose `-StartSimulation` / `-StopSimulation` switches on the reconciler.** Rejected for the same reason — `mode:` stays the single committed-YAML control surface, and `-StartSimulation` fires implicitly for any `Test*`-mode policy the Apply phase touched. See Decision 3 for the cmdlet-warning rationale.

## Citations

- [Learn about auto-labeling policies](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)
- [`New-AutoSensitivityLabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy)
- [`Get-AutoSensitivityLabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy)
- [`Set-AutoSensitivityLabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy)
- [`Remove-AutoSensitivityLabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelpolicy)
- [`New-AutoSensitivityLabelRule`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule)
- [`Get-AutoSensitivityLabelRule`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule)
- [`Set-AutoSensitivityLabelRule`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelrule)
- [`Remove-AutoSensitivityLabelRule`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelrule)
- [`Get-Label`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label)
- [ADR 0015 — Sensitivity label policy shape](0015-label-policy-shape.md)