# 0027 — Sensitivity-label `autoApplicationOf` removal: deferred until Microsoft documents a Set-Label clearing sentinel

- **Status:** Accepted
- **Date:** 2026-05-29
- **Gates:** Open-question row Q14 in [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs) (newly added by this PR); governs the `Update` branch in [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) when desired-state YAML in [`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml) omits `autoApplicationOf` for a label whose tenant copy still carries one. Issue [#429](../../issues/429), follow-up to closed [#215](../../issues/215).
- **Deciders:** @contoso

## Context

Issue [#215](../../issues/215) shipped the **add / translate** path for `autoApplicationOf` (sensitivity-label client-side auto-apply). The verified Set-Label sink, captured by the Phase 1B probe on 2026-05-16, is `Set-Label -Conditions <json>` carrying a nested `And` / `Or` / `Settings` JSON blob (see the inline comments at [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) lines 512-521 and the `Merge-LabelConditionsJson` helper). Auto-apply state lives in `Get-Label`''s `Conditions` property, not in `AdvancedSettings`.

PR [#428](../../pull/428) (v2 §5.2 Phase 2 drift closure) exercised `Deploy-Labels.ps1 -WhatIf` against the live tenant `contoso.onmicrosoft.com` and surfaced the gap that closed #215 did not cover: when the desired YAML *removes* an `autoApplicationOf` block that the tenant still carries, the reconciler today emits a `Write-Warning` at line 1869 and the rule must be cleared manually in the Microsoft Purview portal. The operator who hits this drift gets an `Update` row in the `-WhatIf` plan that lies — the subsequent `-Apply` run does not in fact clear the rule.

This ADR records the result of the spike that issue [#429](../../issues/429) called for.

### Spike against `contoso.onmicrosoft.com` on 2026-05-29

The acceptance criteria on [#429](../../issues/429) call for an interactive `Connect-IPPSSession` probe of four candidate `Set-Label -Conditions` clearing shapes against a sublabel that already carries a `Conditions` block:

1. `Set-Label -Identity <id> -Conditions $null`
2. `Set-Label -Identity <id> -Conditions ''`
3. `Set-Label -Identity <id> -Conditions ''{}''`
4. `Set-Label -Identity <id> -Conditions ''{"And":[]}''`

The spike was attempted from a fresh `Connect-IPPSSession` session (`ExchangeOnlineManagement` 3.10.0, interactive sign-in as a lab-owner UPN) on 2026-05-29. `Get-ConnectionInformation` confirmed `State=Connected, TokenStatus=Active`, and `Get-Command Get-Label, Set-Label` resolved to the per-session `tmpEXO_*` proxy module. The probe-candidate enumeration:

```pwsh
Get-Label | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Conditions) } |
    Select-Object DisplayName, Identity, ConditionsPreview
```

…returned **zero rows**. No sublabel in the tenant carried a non-empty `Conditions` block at the time of the spike. The portal removal performed for the `Confidential / Internal` probe rule on 2026-05-29 (workaround referenced in [#428](../../pull/428) / [#429](../../issues/429)) had already cleared the only label that had one. The four probes therefore could not run as designed — each `BEFORE` would have been empty, so each `AFTER` would also be empty, and the result would not distinguish "the probe cleared it" from "it was never there".

We considered seeding a throwaway `Conditions` block on a sublabel just to give the probes a target (Option A in the spike thread). That would have been a valid path, but it has two drawbacks: (a) authoring a `Conditions` block from PowerShell requires the full nested JSON with valid SIT metadata, which means tying the probe to a specific SIT id and rulepackage we would then have to clean up; (b) the result would test the *reconciler-authored* case (auto-apply rule just written, then immediately cleared) which is not the production failure case (operator-authored portal rule whose YAML representation later drops away). The closer fit is to run the spike *naturally* the next time a real `Conditions` block is in flight — for example during the §5.2 [#359](../../issues/359) Auto-labeling policies item, which may itself seed `Conditions` blocks on labels as a side effect.

### Microsoft Learn coverage as of 2026-05-29

- **[Set-Label (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label).** Documents `-Conditions` as a parameter that accepts a string containing an `And` / `Or` JSON expression. Does not document a clearing sentinel for the parameter. Does not document a partner `-Remove*` parameter for `Conditions`.
- **[Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically).** Authoring guidance is portal-only for client-side auto-apply; the page does not document a PowerShell removal step.

Net: Microsoft Learn does not currently document a `Set-Label`-side mechanism to clear an `autoApplicationOf` (`Conditions`) block in-band. The closed-#215 probe and the open-#429 spike, taken together, are the most thorough investigation this lab has done into the surface, and neither produced a sentinel.

## Decision

**We will not ship a `Set-Label`-side clearing path for `autoApplicationOf` in this PR or until one of the re-open triggers in §6 below fires.** Specifically:

1. **Reclassify the planner row.** When [`Compare-LabelHash`](../../scripts/Deploy-Labels.ps1) reports the bare `autoApplicationOf` field as a diff *and* the direction is "desired YAML omits, tenant carries", the reconciler emits a `NeedsPortalAction` report row (with the offending label name, the field name `autoApplicationOf`, and a `Reason` text that names the Microsoft Purview portal as the required action and links back to this ADR) instead of the misleading `Update` row it emits today. The `Update` plan entry, and the corresponding `Set-Label` write at apply time, are not produced for the removed field.

2. **Preserve the desired-set + tenant-omits direction (the #215 add path) unchanged.** The same bare-field diff in the opposite direction stays on the `Update` plan and continues to flow through `Merge-LabelConditionsJson`. Other label-on-label diffs (`tooltip`, `encryption.*`, etc.) that occur on the *same* label as a removal continue to flow through the `Update` plan; the removal only strips the `autoApplicationOf` field, not the rest.

3. **Delete the dead `Write-Warning` removal-not-supported branch** at [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) line 1869. After change 1 the apply-time `Update` branch can never see the bare `autoApplicationOf` field in the removal direction; the warning was unreachable in the new code path and would mislead anyone reading the file.

4. **Add a new open-question row `Q14`** to [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs) §8 carrying this watch-list status. The §5.2 follow-up row for issue [#429](../../issues/429) stays in the Progress checklist; the ADR link makes it explicit that the row is intentionally unticked until Q14 resolves.

5. **No undocumented surface.** We will not consume the Microsoft Purview portal''s internal REST traffic to clear the rule by reverse-engineering the browser dev-tools network tab. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) ("Non-Microsoft sources last … never to produce a final answer") and would break on any backend revision without warning.

### Re-open triggers (the watch list)

This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:

- The [Set-Label](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label) reference page documents an explicit clearing value for `-Conditions` (e.g. `$null`, empty string, `{}`, `{"And":[]}`, or a named sentinel).
- The Set-Label cmdlet gains a documented partner parameter that removes the `Conditions` block (for example a `-ClearConditions` or a `-Conditions:$null` example in the page''s `Examples` section).
- The [Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically) page gains a programmatic-removal section (PowerShell, Microsoft Graph, or REST).
- A `sensitivityLabel.autoApplicationOf` resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0) with a `DELETE` or `PATCH` endpoint that clears the rule.
- The natural spike (a real-tenant `Conditions` block in flight during another item — e.g. §5.2 [#359](../../issues/359) Auto-labeling policies) confirms one of the four candidate sentinels from [#429](../../issues/429) actually clears the rule; the probe captures get pasted into [#429](../../issues/429), Q14 is resolved, this ADR is superseded by 0028+.

### 2026-06-01 re-verification

Path B closure of §5.2 (project-plan row for closed [#429](../../issues/429)) re-checked all four Microsoft Learn re-open triggers above on **2026-06-01** before the §5.2 row was ticked. Live-page evidence captured from the PR-`feat/label-removal-gap-visibility` build loop:

| Trigger | Status (2026-06-01) | Evidence |
|---|---|---|
| 1. `Set-Label -Conditions` clearing sentinel documented | Not fired | Parameter description text: *"The Conditions parameter is used for automatic labeling of files and email for data in use."* No clearing semantics. Page-wide `[regex]::Matches($c,'Conditions[^<]{0,120}(null\|empty\|clear\|remove)').Count` = 0. |
| 2. `-ClearConditions` / `-RemoveConditions` partner parameter | Not fired | Page-wide `[regex]::Matches($c,'ClearConditions\|RemoveConditions').Count` = 0 across 216 KB Set-Label reference page. |
| 3. Apply-sensitivity-label-automatically programmatic-removal section | Not fired | "Use PowerShell for auto-labeling policies" section documents `New-AutoSensitivityLabelPolicy` / `New-AutoSensitivityLabelRule` only — service-side surface (Surface 2, already shipped via [#359](../../issues/359)), not label-attached `Set-Label -Conditions` (Surface 1, this ADR's scope). Zero `Set-Label` mentions on the page. |
| 4. Graph `sensitivityLabel.autoApplicationOf` resource | Not fired | Zero `sensitivityLabel` mentions on Graph `/api/overview` or `/api/resources/security-api-overview`. The extant `informationProtectionLabel` resource at `/api/resources/informationprotectionlabel` is read-only and explicitly *deprecated* (13 mentions of "deprecated"). |
| 5. Natural spike (real-tenant `Conditions` block in flight) | Not fired | [#359](../../issues/359) (Auto-labeling policies) closed via [PR #510](../../pull/510) on 2026-06-01 without seeding any `Conditions` block — `auto-label-policies.yaml` operates against `Get-/Set-AutoSensitivityLabelRule` (service-side), not against `Set-Label -Conditions` (label-attached). The naturally-occurring opportunity ADR 0027 §6 trigger 5 anticipated did not materialize from §5.2. |

**Verdict: zero movement on Microsoft Learn between 2026-05-29 and 2026-06-01. Watch-list status reconfirmed.**

Per [`docs/project-plan.md`](../project-plan.md#4-per-feature-lifecycle-review--close-drift--harden--tick) §4 watch-list-row-closure language ("…the box is ticked on that basis alone, citing the Learn pages confirming 'no programmatic authoring surface' as of the review date"), the §5.2 row for [#429](../../issues/429) is now ticked. Live tracking of the four upstream surfaces continues at [#512](../../issues/512) (replaces closed [#429](../../issues/429)). Operator visibility hardened via:

- Sharpened `NeedsPortalAction` `Reason` string carrying the exact portal click path and `#512` reference at [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) line 1545.
- New `Get-NeedsPortalActionSummary` helper that emits a console block (with the `::warning::` GitHub Actions annotation) and a markdown block to `$GITHUB_STEP_SUMMARY` when any `NeedsPortalAction` rows exist in the run report.
- New operator runbook at [`docs/runbooks/labels-manual-portal-actions.md`](../runbooks/labels-manual-portal-actions.md) covering the portal click path step-by-step.

The next re-verification fires on the next §5.2 item that touches label-attached `Conditions` state, or quarterly under the v2 [#376](../../issues/376) surface-completeness review, whichever comes first.

## Consequences

**Easier:**

- **The reconciler stops lying.** Today an operator looking at a `-WhatIf` plan with a label whose YAML removed `autoApplicationOf` sees an `Update` row that will *not* in fact converge the tenant on the next `-Apply`. After this ADR ships, the same operator sees a `NeedsPortalAction` row with a clear narrative pointing at the Microsoft Purview portal. The plan-row category now correctly predicts what `-Apply` will and will not do.
- **The drift surface stays detectable.** [`Compare-LabelHash`](../../scripts/Deploy-Labels.ps1) is unchanged; it still emits the bare `autoApplicationOf` field on presence asymmetry, so the reconciler still *sees* the drift and still reports it. The only thing that changes is the category and the prescribed action.
- **The repo stays inside the grounding rule.** Every cited Microsoft Learn URL in this ADR was reachable on 2026-05-29 before the ADR was committed.

**Harder:**

- **One-shot drift closure of a YAML that removes an auto-apply rule still requires a portal step.** The `NeedsPortalAction` row tells the operator exactly which label and which field, but the operator must open the Microsoft Purview portal, navigate to the label, and clear the auto-apply rule manually. This is the same workaround [#428](../../pull/428) used for `Confidential / Internal`; this ADR just makes the reconciler-side narrative honest.
- **A future re-open requires a deliberate spike with a probe candidate in flight.** The natural-spike path (§6) depends on the next reconciler item that authors a `Conditions` block. If §5.2 #359 ships before #429 re-opens, the probes from that item''s `-Apply` evidence should be checked for any incidental clearing behavior; if not, a dedicated `Conditions` seed-and-clear spike has to be scheduled.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Trivially satisfied — nothing changes about how the reconciler authenticates (cert-in-Key-Vault, OIDC).
- **#9 (idempotent, reversible, auditable).** Reinforced — emitting a truthful `NeedsPortalAction` row instead of a misleading `Update` row makes the `-WhatIf` plan more accurately auditable and the post-`-Apply` drift more predictable.

## Alternatives considered

1. **Ship a clearing sentinel based on the unverified `$null` / `''` / `''{}''` / `''{"And":[]}''` candidates anyway.** Rejected. The spike could not verify any of them against a real tenant `Conditions` block, and shipping an unverified sentinel risks (a) silent data-loss on labels we did not intend to clear, (b) a service-side error that the reconciler interprets as "Set-Label failed" without distinguishing transient from structural failure, or (c) a value that the service accepts but treats as a no-op, in which case the reconciler claims convergence the next `-WhatIf` will contradict. None of those are acceptable for a label-side write that may also carry `tooltip` / `encryption` updates in the same `Set-Label` call.

2. **Seed a throwaway `Conditions` block to run the four probes.** Rejected for this PR (see Context §Spike Option A). Not foreclosed for a future item; the natural-spike re-open trigger above captures the better-shaped version.

3. **Switch the entire reconciler from `Set-Label` to a hypothetical Microsoft Graph `sensitivityLabel` endpoint.** Rejected. Microsoft Graph does not currently document a `sensitivityLabel` resource at all (verified 2026-05-29 against `https://learn.microsoft.com/en-us/graph/api/resources/`). Adopting an endpoint we cannot cite on Learn would violate the [grounding rule](../../.github/copilot-instructions.md).

4. **Leave the `Write-Warning` in place and call it done.** Rejected. The warning emits at `-Apply` time, after the `-WhatIf` plan has already shown an `Update` row that promised convergence. The operator sees the lie before they see the warning, and CI / log filters that surface only the `-WhatIf` plan miss the warning entirely.

5. **Do nothing — leave issue [#429](../../issues/429) open with no ADR and no reconciler change.** Rejected. The Open-question ADRs sub-section in the Progress checklist exists precisely so deferral is itself a ratified decision with documented re-open triggers, not a silent backlog item.

## Citations

- **[Set-Label (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label)**
  Fetch date: 2026-05-29
  Reference page for the cmdlet whose `-Conditions` parameter is the verified add-path sink. Cited to confirm the page documents no clearing sentinel and no `-Remove*` partner parameter.
- **[Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)**
  Fetch date: 2026-05-29
  Cited to confirm the authoring guidance is portal-only and the page documents no programmatic removal step.
- **[Microsoft Graph API resources index](https://learn.microsoft.com/en-us/graph/api/resources/)**
  Fetch date: 2026-05-29
  Cited in Alternative 3 to confirm Microsoft Graph does not currently document a `sensitivityLabel` resource.
- [ADR 0017](0017-label-auto-application-shape.md) — sets the desired-state YAML shape for `autoApplicationOf` that the reconciler now reads.
- [ADR 0019](0019-cc-graph-pivot.md) — precedent for a watch-list ADR that ratifies deferral with named re-open triggers. Same pattern, different surface.
- [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) lines 512-521 — inline narrative for the verified `Set-Label -Conditions` add-path sink shipped in #215.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" rule applied throughout.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — principles #1 and #9 cited in Consequences.
