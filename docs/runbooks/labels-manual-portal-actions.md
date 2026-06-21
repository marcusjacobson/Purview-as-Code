# Runbook: Manual portal action for sensitivity-label auto-apply removal

Use this runbook when a `Deploy-Labels.ps1` run (CI or local) emits a
`NeedsPortalAction` row, equivalently a `[!] MANUAL PORTAL ACTIONS REQUIRED`
console block, equivalently a `## ⚠ Manual portal actions required` section
on the GitHub Actions run-summary page.

The capability gap is tracked by [issue #512](../../issues/512) (replaces
closed [#429](../../issues/429)) and ratified by
[ADR 0027](../adr/0027-autoapplication-removal-watch-list.md). It fires only
on **removal** of a client-side auto-apply rule from a sensitivity label;
every other auto-labeling operation (add, modify, label create/update/delete,
service-side `auto-label-policies.yaml`) ships end-to-end through the
reconciler with no manual step.

## What "auto-apply rule" means here (Surface 1)

Client-side auto-labeling. The rule lives on the sensitivity label itself,
in the label's `Conditions` JSON blob. Office desktop apps (Word, Excel,
PowerPoint, Outlook) and the MIP / AIP unified labeling client evaluate
this rule against document content and either recommend or auto-apply the
label. The reconciler writes this rule via
[`Set-Label -Conditions <json>`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label).

This is **not** the same as a service-side
auto-labeling policy (Surface 2) — the `New-AutoSensitivityLabelPolicy` /
`-Rule` cmdlet pair documented at
[Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically).
That surface ships end-to-end via
[`scripts/Deploy-AutoLabelPolicies.ps1`](../../scripts/Deploy-AutoLabelPolicies.ps1)
([data-plane/information-protection/auto-label-policies.yaml](../../data-plane/information-protection/auto-label-policies.yaml)).
If a `NeedsPortalAction` row mentions a label, it is always Surface 1.

## Why a manual step is needed

Microsoft Learn does not document a `Set-Label`-side mechanism to clear an
`autoApplicationOf` (`Conditions`) block in-band. The four sentinel
candidates the 2026-05-29 spike could not probe were `$null`, `''`, `'{}'`,
and `'{"And":[]}'`. None are documented; none have been verified against a
live tenant. Shipping any of them blindly risks silent data-loss, a
service-side error, or a no-op the reconciler interprets as convergence.
See ADR 0027 §"Alternatives considered" point 1 for the full rationale.

Re-verification log:

- **2026-05-29 (ADR 0027 §Citations):** Set-Label reference, Apply-auto
  page, Graph API resources index — none document a clearing surface.
- **2026-06-01 (this PR):** Re-checked all four ADR 0027 §6 re-open
  triggers against live Learn pages. Zero movement.

## What the reconciler does instead

When `Compare-LabelHash` reports the bare `autoApplicationOf` field as a
diff in the **removal direction** (desired YAML omits the block, tenant
still carries it), `Resolve-AutoApplyRemovalPlan` strips the field from
the apply set and the planner emits a `NeedsPortalAction` row carrying:

- `Name` — the affected label (e.g. `Confidential\Internal` for a sublabel,
  or `Public` for a top-level label).
- `Field` — always `autoApplicationOf`.
- `Reason` — the one-line operator-facing summary with the portal
  click path and a link to `#512` / ADR 0027.

At end of run the script emits a multi-line summary block listing every
affected label, both to the console (with the `::warning::` GitHub Actions
annotation so the workflow run page surfaces it inline) and to
`$GITHUB_STEP_SUMMARY` when running in CI (so the markdown block lands at
the top of the run-summary page without requiring the workflow to grep
the log).

Other diffs on the same label (`tooltip`, `encryption.*`, `marking_*`,
`autoApplicationOf.mode` / `autoApplicationOf.policyTip` / nested SIT
changes when both sides have a block) continue to flow through the normal
`Update` plan. The portal step covers **only** the bare-field-removal
case.

## Operator steps (one-time per affected label)

1. **Sign in to the Microsoft Purview portal**
   at <https://purview.microsoft.com/> with an account that holds the
   `Compliance Administrator` or `Compliance Data Administrator` role
   (or an equivalent role group with the
   `Information Protection Admin` permission set per
   [Microsoft Purview roles and role groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions)).

2. **Navigate to the label.**
   Left nav → **Solutions** → **Information Protection** →
   **Sensitivity labels** tab.
   For a sublabel (e.g. `Confidential\Internal`), expand the parent
   label (`Confidential`) to see the sublabel row.

3. **Open the label wizard.**
   Click the label row, then **Edit label** at the top.
   Step through the wizard until you reach the
   **"Auto-labeling for files and emails"** page.

4. **Remove the rule.**
   Toggle **"Auto-labeling for files and emails"** **off**, or use
   **Remove** on each condition row. The tenant accepts the change
   immediately; no separate publish step is required for the auto-apply
   block (sensitivity-label policies are a separate publish surface).

5. **Verify.**
   From a shell with `Connect-IPPSSession` active:

   ```pwsh
   Get-Label -Identity '<label-display-name>' |
       Select-Object DisplayName, Conditions
   ```

   The `Conditions` property should be empty or null. If it still
   carries a JSON blob, the portal edit did not save — repeat step 4.

6. **Re-run the reconciler to confirm the drift is closed.**
   Locally:

   ```pwsh
   ./scripts/Deploy-Labels.ps1 -DirectionPolicy audit -Confirm:$false
   ```

   In CI: re-dispatch the `deploy-labels` workflow with
   `direction_policy=audit`. The `NeedsPortalAction` row for the
   affected label should be gone; the run summary should show no
   `## ⚠ Manual portal actions required` block.

## What to do if the rule keeps coming back

If the auto-apply rule reappears on the same label after a portal
removal, an out-of-band author is re-creating it (another admin, a
labeling-policy promotion, or a Compliance Center quick-start template).
File a follow-up issue against `#512` with the audit-log evidence and
the `Get-Label` snapshot; this is not a reconciler bug.

## When this runbook stops being necessary

Any one of these closes [#512](../../issues/512) and obsoletes this
runbook (ADR 0027 §6 re-open triggers):

1. [Set-Label](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label)
   reference page documents an explicit clearing value for `-Conditions`.
2. `Set-Label` gains a documented partner parameter that removes
   `Conditions` (e.g. `-ClearConditions`).
3. [Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)
   gains a programmatic-removal section.
4. A `sensitivityLabel.autoApplicationOf` resource lands at
   `https://learn.microsoft.com/en-us/graph/api/resources/` with
   `DELETE` or `PATCH`.
5. A natural-spike opportunity (a real-tenant `Conditions` block in
   flight during another item) confirms one of the four candidate
   `Set-Label -Conditions` sentinels actually clears the rule.

When that happens: implement the clearing path in
[`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) per the
acceptance criteria on [#512](../../issues/512), and delete this file
in the same PR.

## References

- **[ADR 0027 — autoApplicationOf removal watch list](../adr/0027-autoapplication-removal-watch-list.md)**
  Watch-list ADR ratifying the deferral and naming the five re-open
  triggers above.
- **[Issue #512](../../issues/512)**
  Live tracking of the upstream Microsoft Learn surface.
- **[Closed issue #429](../../issues/429)**
  Original `feat:` issue. Scope (ship the reconciler path) was deferred;
  §5.2 row ticked under the §4 watch-list re-verification rubric.
- **[Set-Label (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label)**
  Reference page for the cmdlet whose `-Conditions` parameter is the
  verified add-path sink, and the page that would document a clearing
  sentinel if one existed.
- **[Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)**
  Authoring guidance; covers service-side auto-labeling via PowerShell,
  documents the client-side auto-apply surface as portal-only.
- **[Microsoft Purview roles and role groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions)**
  Source for the role-requirement statement in step 1.
