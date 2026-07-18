# 0035 — Microsoft File Plan Manager seed content is immovable via documented IPPS surfaces; treat as permanent declared orphans

- **Status:** Accepted
- **Date:** 2026-06-07
- **Gates:** Adds open-question row Q15 in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs. Resolves the implicit Phase 2 gate surfaced during [#582](../../issues/582) (closed `not feasible`). Governs the `Prune` planner branch in [`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1) for the 31 named property objects below, and the baseline skip list now carried by [`data-plane/records/seed-skip-names.yaml`](../../data-plane/records/seed-skip-names.yaml) (originally the ``skip_names_records`` workflow input shipped by sibling [#586](../../issues/586); relocated by [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md) — see the Update note below). Does not gate any other item.
- **Deciders:** @contoso

> **Update 2026-07-13 (link maintenance, not a decision change — [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md), issue [#85](https://github.com/marcusjacobson/Purview-as-Code/issues/85)).**
>
> This ADR's Decision #3 anchored the 31-name baseline skip list to the `skip_names_records` `workflow_dispatch` input of `.github/workflows/deploy-data-plane.yml`. [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) retired that workflow (PR [#82](https://github.com/marcusjacobson/Purview-as-Code/pull/82)), which left the mandated baseline pointing at a file that no longer exists — and therefore living **nowhere executable**. `scripts/Deploy-FilePlan.ps1` has no other workflow caller, so its only remaining caller is an operator at a local terminal, which a workflow input could never defend.
>
> **The decision below is unchanged: the 31 seeds are still not deleted, and the baseline skip list is still mandatory.** Only its *home* moved. The baseline now lives in the checked-in data file [`data-plane/records/seed-skip-names.yaml`](../../data-plane/records/seed-skip-names.yaml), which `Deploy-FilePlan.ps1` reads and unions into the effective skip list on **every** run — including the local run that is now the only run there is. Operators may still extend the list via `-SkipNames`; they can no longer shrink it from the command line, which enforces Decision #3's "may extend … should not shrink it without superseding this ADR" mechanically rather than by convention.
>
> Three references below are stale as written and are corrected by this note rather than by rewriting the Accepted text: **Decision #3** and the **§"The 31 seed names"** preamble both name `.github/workflows/deploy-data-plane.yml` as the baseline's home; read both as naming `data-plane/records/seed-skip-names.yaml` instead. The `-PruneMissing` bullet in §Consequences ("Harder") likewise names the [#586](../../issues/586) workflow input; the local-run hazard it describes is now closed by the script-side default, and the residual hazard it was really about — an unconfirmed destructive prune — is closed by ADR 0052's confirmation gate.
>
> **Precision preserved:** the 31 seeds are **undeletable** (all 31 `Remove-FilePlanProperty*` calls fail with `ErrorRuleNotFoundException` — see §Context). A `-PruneMissing` run without the skip list therefore produces **31 noisy failures, not 31 deletions**. The seeds were never at risk of loss, and this note does not claim otherwise. The genuine data-loss exposure that ADR 0052 addresses is to **operator-authored** objects, which delete normally.

> **Update 2026-07-18 (provenance resolved, not a decision change — issue [#98](https://github.com/marcusjacobson/Purview-as-Code/issues/98)).**
>
> The `Finance` department's `Guid` (`5ff13e11-12ad-466d-bf6e-a2c9966fb36e`) and `Policy` GUID (`c25c0d36-48f0-45d8-babe-521127b3fa96`) captured in the probe transcript below (§Context, "Probe against `contoso.onmicrosoft.com`") sat in [`.github/agents/tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml)'s `identifierScan.reviewRequired` quarantine from [#94](https://github.com/marcusjacobson/Purview-as-Code/issues/94)/[#97](https://github.com/marcusjacobson/Purview-as-Code/pull/97) onward: this ADR's line 61 *inferred* they were Microsoft-managed but that inference was never verified, so the resolver declined to launder it into `identifierScan.microsoftConstants`.
>
> **Provenance is now established.** `Get-FilePlanPropertyDepartment` was run against a second, independently-provisioned Microsoft 365 tenant, distinct from the tenant this ADR's original probe used. Result: the `Finance` department's `Guid` was identical to the value recorded below, and the `Policy` GUID was not only identical but shared across all ten seeded departments in the second tenant too — the signature of a hardcoded Microsoft-shipped constant applied uniformly to seed content, not a tenant-generated value. Both GUIDs are promoted to `identifierScan.microsoftConstants` in the manifest, with the empirical cross-tenant methodology recorded as the citation (no Microsoft Learn page indexes either literal value). The `reviewRequired` quarantine is now empty, and `.github/workflows/validate.yml` runs `Test-IdentifierResidue.ps1 -FailOnReview`, so the scan fails closed with no standing exceptions. This does not change the Decision above: the 31 seeds remain undeletable, declared orphans; only the provenance of two incidentally-disclosed GUIDs in this ADR's probe transcript was resolved.

## Context

[#364](../../issues/364) (v2 §5.3 Records Management drift closure and end-to-end file-plan reconciler validation) entered Phase 2 on 2026-06-07 with a Phase 1 `-WhatIf` baseline that surfaced **31 tenant-only file plan property objects** in `contoso.onmicrosoft.com`:

- Authorities (3): Business, Legal, Regulatory
- Categories (13): Accounts payable, Accounts receivable, Administration, Compliance, Contracting, Financial statements, Learning and development, Payroll, Planning, Policies and procedures, Procurement, Recruiting and hiring, Research and development
- Citations (5): Commodity Exchange Act, Health Insurance Portability and Accountability Act of 1996, OSHA Injury and Illness Recordkeeping and Reporting Requirements, Sarbanes-Oxley Act of 2002, Truth in Lending Act
- Departments (10): Finance, Human resources, Information technology, Legal, Marketing, Operations, Procurement, Products, Sales, Services
- ReferenceIds: 0, SubCategories: 0, RetentionLabels: 0

These match the Microsoft-shipped File Plan Manager sample content documented at [File plan manager](https://learn.microsoft.com/en-us/purview/file-plan-manager). Zero retention labels in the tenant reference any of them, so they are unused content.

The lab owner selected **Path A** (destructive prune of the seeds before resuming Phase 3 against a clean tenant). The follow-up issue [#582](../../issues/582) was filed to carry out the prune on its own `chore/records-prune-seed-orphans` branch with the `destructive` label and the owner-approval gate.

### Probe against `contoso.onmicrosoft.com` on 2026-06-07

The Phase 2 attempt invoked `scripts/Deploy-FilePlan.ps1 -PruneMissing` after a clean `-WhatIf` baseline confirmed 31 orphans and 0 labels. Result: **all 31 `Remove-FilePlanProperty*` calls failed identically with `Microsoft.Exchange.Management.UnifiedPolicy.ErrorRuleNotFoundException`.**

The reconciler's plan-row report (captured in the [#582](../../issues/582) close-comment) attributed every failure to the documented IPPS error. The script invoked the documented cmdlet (`Remove-FilePlanProperty<Kind>`) with the documented `-Identity` parameter using the object's `Name` field as returned by the corresponding `Get-*` cmdlet.

To rule out a reconciler bug, an interactive operator probe followed against the same tenant on the same date. `Get-FilePlanPropertyDepartment` for the `Finance` entry returned:

```text
Name                 : Finance
Guid                 : 5ff13e11-12ad-466d-bf6e-a2c9966fb36e
Identity             : CN=5ff13e11-12ad-466d-bf6e-a2c9966fb36e
ReadOnly             : False
Mode                 : Enforce
FilePlanPropertyType : Department
Workload             : Exchange, SharePoint
Policy               : c25c0d36-48f0-45d8-babe-521127b3fa96
Disabled             : False
Priority             : 0
```

Three deletion attempts using documented identity forms, each via `-WhatIf` (no tenant write):

| Identity form | Cmdlet call | Result |
|---|---|---|
| Name | `Remove-FilePlanPropertyDepartment -Identity 'Finance' -WhatIf` | `ErrorRuleNotFoundException`: "There is no rule matching identity 'Finance'." |
| Guid | `Remove-FilePlanPropertyDepartment -Identity '5ff13e11-12ad-466d-bf6e-a2c9966fb36e' -WhatIf` | `ErrorRuleNotFoundException`: "There is no rule matching identity '5ff13e11-12ad-466d-bf6e-a2c9966fb36e'." |
| `CN=<guid>` (the `Identity` property value verbatim) | `Remove-FilePlanPropertyDepartment -Identity 'CN=5ff13e11-12ad-466d-bf6e-a2c9966fb36e' -WhatIf` | `ErrorRuleNotFoundException`: "There is no rule matching identity 'CN=5ff13e11-12ad-466d-bf6e-a2c9966fb36e'." |

`ReadOnly: False` rules out the obvious "read-only flag" explanation. The non-default `Policy: c25c0d36-48f0-45d8-babe-521127b3fa96` GUID identifies a Microsoft-managed policy scope (compare: every non-seed property created via `New-FilePlanProperty*` carries the tenant's default policy GUID). The `Remove-FilePlanProperty*` cmdlets do not expose a `-Policy` parameter; Microsoft Learn documents only `-Identity`, `-Confirm`, and the common parameters.

This is not a reconciler bug. The IPPS surface itself, as documented, has no path that finds these entries for deletion.

### Microsoft Learn coverage as of 2026-06-07

- **[Remove-FilePlanPropertyAuthority (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyauthority)** — documents `-Identity` (Name or GUID) only. No `-Policy`, no `-Force`, no scope-targeting parameter. Sibling pages [`-Category`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertycategory), [`-Citation`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertycitation), [`-Department`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertydepartment), [`-ReferenceId`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyreferenceid), [`-SubCategory`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertysubcategory) match the same shape.
- **[File plan manager](https://learn.microsoft.com/en-us/purview/file-plan-manager)** — describes the seed authorities, categories, citations, and departments as starter content shipped with the experience. Page documents portal-only operations for authoring and removal; zero `PowerShell`, `cmdlet`, `Graph`, or `REST` occurrences for the seed-removal path.
- **[Records management overview](https://learn.microsoft.com/en-us/purview/records-management)** — references file plan property objects throughout. No removal-path guidance for seed entries.
- **Microsoft Graph probes** — `https://learn.microsoft.com/en-us/graph/api/resources/security-fileplanproperty` returns HTTP 404 (resource not indexed). The Graph `security` namespace overview ([learn.microsoft.com/en-us/graph/api/resources/security-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)) contains zero occurrences of `fileplan`, `filePlan`, `filePlanProperty`, or `recordLabel`.

Net: **Microsoft Learn does not currently document any path — PowerShell, Microsoft Graph, or REST — to delete the seeded File Plan Manager property objects.** The portal does expose a per-entry deletion experience for some property kinds, but its outcome against the specific 31 seeds in this lab has not been tested and is not the path this repo would take if a programmatic alternative existed.

## Decision

**We will not delete the 31 Microsoft File Plan Manager seed property objects from `contoso.onmicrosoft.com`. We will treat them as permanent, declared orphans for the lifetime of this ADR.** Specifically:

1. **#364 Phase 2 disposition redirects from (c) destructive prune to (b) ratify via ADR.** The 31 seeds remain in the tenant as orphans; the reconciler always reports them; the operator-facing surface treats their presence as expected. The [#582](../../issues/582) `chore/records-prune-seed-orphans` branch was deleted with zero commits; no PR was opened.

2. **The reconciler gains a `-SkipNames` parameter** (shipped by sibling [#584](../../issues/584) as a `chore(scripts)` retrofit, modelled on [#571](../../issues/571) / [#569](../../issues/569)). `-SkipNames` filters both label and property plan rows by `Name`. This ADR does not specify the parameter shape; [#584](../../issues/584) does.

3. **The baseline skip list lists all 31 seed names verbatim.** Operators may extend the list; they should not shrink it without superseding this ADR.

   > **Corrected 2026-07-13 per [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md).** As originally written, this decision read: *"(shipped by sibling [#586](../../issues/586) under the `skip_names_records` `workflow_dispatch` input). The `Deploy file plan` step in `.github/workflows/deploy-data-plane.yml` defaults `skip_names_records` to the list in §Consequences below. Operators may extend the list at dispatch time …"* — but [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) deleted that workflow. The baseline now lives in [`data-plane/records/seed-skip-names.yaml`](../../data-plane/records/seed-skip-names.yaml) and is unioned into the effective skip list by [`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1) on every run. Operators extend it via `-SkipNames`; shrinking it requires editing that data file in a reviewed PR. The mandate is unchanged — only its executable home moved.

4. **The desired-state YAML header documents the seeds and links here.** [`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml) gains a `Microsoft seed content (see ADR-0035)` paragraph explaining why the declared empty state coexists with 31 tenant entries. The same paragraph names the 31 entries verbatim so the YAML is self-describing without a round-trip to this file.

5. **Add open-question row Q15 to [`docs/project-plan.md`](../project-plan.md) §8** as the standing watch-list. The row is permanently open until any re-open trigger below fires.

6. **No undocumented surface.** We will not invoke an undocumented `-Policy` parameter on `Remove-FilePlanProperty*`. We will not consume the Microsoft Purview portal's internal REST traffic to delete the seeds by reverse-engineering the browser dev-tools network tab. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) ("Non-Microsoft sources last … never to produce a final answer") and would break on any backend revision without warning. This restriction is identical to the one in [ADR 0019](0019-cc-graph-pivot.md) §6, [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6, and [ADR 0027](0027-autoapplication-removal-watch-list.md) §5.

### Re-open triggers (the watch list)

This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:

- The [Remove-FilePlanPropertyAuthority](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyauthority) reference page (or any sibling `Remove-FilePlanProperty*` page) documents a `-Policy` parameter or any other parameter that targets the Microsoft-managed seed policy scope.
- A `filePlanProperty`, `recordLabel`, or similarly-named resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0) with a `DELETE` endpoint that accepts the seed identifiers.
- [Records management overview](https://learn.microsoft.com/en-us/purview/records-management) or [File plan manager](https://learn.microsoft.com/en-us/purview/file-plan-manager) gains a "programmatically remove the default seed content" section (PowerShell, Microsoft Graph, or REST).
- A Microsoft-published reference repo (under `github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a sample that deletes seeded file plan property objects against a non-test tenant via a documented surface.
- The portal-only removal path is verified end-to-end against `contoso.onmicrosoft.com` and confirmed to delete one of the 31 seeds without violating Microsoft support terms. (Watch-list trigger only — the portal path is not adopted as the lab's source of truth even if it works; that change would require a separate ADR arguing why a portal-click workflow belongs in a code-driven repo.)

## Consequences

**Easier:**

- **[#364](../../issues/364) Phase 3 unblocks** without a destructive operation that cannot succeed. The runbook from sibling [#585](../../issues/585) exercises Create → Update → DriftWarn → Orphan → Prune against synthetic objects; the seeds are out of frame.
- **Reviews stay signal-only.** With `-SkipNames` defaulting to the 31 seed names in the workflow, every CI `-WhatIf` returns zero plan rows when the YAML matches the (empty) desired state; real drift on operator-authored property objects or labels surfaces unmasked.
- **The repo stays inside its grounding rule.** Every cited Microsoft Learn URL in this ADR was reachable on 2026-06-07 before the ADR was committed.
- **Symmetry with the rest of the repo.** Watch-list ADRs already exist for [ADR 0019](0019-cc-graph-pivot.md) (Communication Compliance), [ADR 0022](0022-dspm-for-ai-authoring-surface.md) (DSPM for AI), and [ADR 0027](0027-autoapplication-removal-watch-list.md) (sensitivity-label removal). This ADR follows the same shape.

**Harder:**

- **The lab tenant carries 31 unused property objects indefinitely.** They have no operational impact (zero labels reference them, the reconciler skips them, no scan or policy depends on them) but they are visible in the Microsoft Purview portal and in any `Get-FilePlanProperty*` call. An operator unaware of this ADR may attempt manual portal removal; this ADR neither blesses nor blocks that — see watch-list trigger #5.
- **`-PruneMissing` without `-SkipNames` will produce 31 `Failed` plan rows forever.** The operator-facing surface should default `-SkipNames` correctly (workflow input from [#586](../../issues/586)); a hand-run of `Deploy-FilePlan.ps1 -PruneMissing` from a developer's machine without `-SkipNames` will reproduce the [#582](../../issues/582) failure. The [`docs/runbooks/records-end-to-end-smoke.md`](../runbooks/records-end-to-end-smoke.md) runbook from [#585](../../issues/585) reminds the operator at Step 0.
- **A future shrink of the seed list (Microsoft removes one of the 31 in a service revision) would surface as a `Skipped name not found in tenant` warning** from the reconciler. Sibling [#584](../../issues/584) defines that behaviour; this ADR does not.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Trivially satisfied — this ADR introduces no new credentials.
- **#4 (least privilege).** Upheld. The reconciler runs as the data-plane workload identity already gated to the Records Management role group; this ADR does not expand scope.
- **#9 (idempotent, reversible, auditable).** Upheld. The decision is captured here in version control; the workflow baseline lists the 31 seed names so a future revert is a single-PR change.

### The 31 seed names (verbatim, for the workflow baseline and the YAML header)

The list below is the source of truth for both [`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml)'s header comment and the baseline skip list in [`data-plane/records/seed-skip-names.yaml`](../../data-plane/records/seed-skip-names.yaml). Order: Authorities, Categories, Citations, Departments — alphabetical within each kind.

> **Corrected 2026-07-13 per [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md).** This preamble originally named "the `skip_names_records` baseline default in `.github/workflows/deploy-data-plane.yml`", a file [ADR 0051](0051-per-solution-workflow-unit-of-data-plane-apply.md) deleted. The consuming file is now `data-plane/records/seed-skip-names.yaml`. The 31 rows themselves are unchanged.
>
> Note for implementers: the skip filter matches on `Name`, and two names each appear under two kinds — **Legal** (Authority + Department) and **Procurement** (Category + Department). The 31 rows therefore carry 29 distinct names. This is harmless for a name-based filter (both kinds are skipped, which is the intent) and is why `seed-skip-names.yaml` reproduces all 31 rows rather than deduplicating them.

| Kind | Name |
|---|---|
| Authority | Business |
| Authority | Legal |
| Authority | Regulatory |
| Category | Accounts payable |
| Category | Accounts receivable |
| Category | Administration |
| Category | Compliance |
| Category | Contracting |
| Category | Financial statements |
| Category | Learning and development |
| Category | Payroll |
| Category | Planning |
| Category | Policies and procedures |
| Category | Procurement |
| Category | Recruiting and hiring |
| Category | Research and development |
| Citation | Commodity Exchange Act |
| Citation | Health Insurance Portability and Accountability Act of 1996 |
| Citation | OSHA Injury and Illness Recordkeeping and Reporting Requirements |
| Citation | Sarbanes-Oxley Act of 2002 |
| Citation | Truth in Lending Act |
| Department | Finance |
| Department | Human resources |
| Department | Information technology |
| Department | Legal |
| Department | Marketing |
| Department | Operations |
| Department | Procurement |
| Department | Products |
| Department | Sales |
| Department | Services |

Sibling [#584](../../issues/584) does not enforce per-kind disambiguation; the IPPS surface forbids duplicate `Name` values across these kinds within a tenant, so the flat list is sufficient. If Microsoft ever ships a seed entry whose `Name` collides across kinds, this ADR is superseded.

## Alternatives considered

1. **Delete the seeds via an undocumented `-Policy` parameter on `Remove-FilePlanProperty*`.** Rejected. Microsoft Learn does not document the parameter; any code path that invokes it would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and would break silently on any backend revision.

2. **Delete the seeds via the Microsoft Purview portal click path.** Not adopted as the repo's source of truth. The portal is not version-controlled; a portal-click solution leaves no diff and no audit trail. Listed as watch-list trigger #5 only because evidence that the portal can in fact delete a seed would inform a future re-open.

3. **Declare the 31 seeds in [`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml) as desired state (Phase 2 option (a)).** Rejected. The YAML would then encode the *Microsoft default content* as if the lab authored it. That obscures the actual provenance and would carry tenant-specific seed names into any future tenant the repo is cloned to, even if those tenants ship a different seed list. The `-SkipNames` baseline preserves provenance correctly: the seeds belong to Microsoft, the empty `[]` lists belong to the lab.

4. **Treat Records Management as out of scope for the repo (mirror [ADR 0018](0018-ediscovery-scope.md)'s eDiscovery decision).** Rejected. Retention labels and operator-authored file plan property objects are policy-as-code-shaped. Only the *Microsoft-seeded subset* is unbuildable, and that subset has a documented quantity (31) and a stable shape. Descoping the entire feature would discard the reconciler [#586](../../issues/586) and runbook [#585](../../issues/585) work and would foreclose any future label-and-property declaration. The narrow descoping of the 31 seeds is the lower-regret choice.

5. **Do nothing — leave [#364](../../issues/364) Phase 2 open with no ADR.** Rejected. The Open-question ADRs sub-section in the Progress checklist exists precisely so that questions get decisive answers and the cadence does not stall. Decisive answer: defer the seed deletion, ship the skip-list, and document the re-open triggers.

## Citations

- **[Remove-FilePlanPropertyAuthority (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyauthority)**
  Fetch date: 2026-06-07
  > "Use the Remove-FilePlanPropertyAuthority cmdlet to remove file plan property authorities in the compliance portal."
  Cited to confirm `-Identity` is the only targeting parameter documented; no `-Policy`, no `-Force`, no scope-aware delete.
- **[File plan manager (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/file-plan-manager)**
  Fetch date: 2026-06-07
  Cited to confirm the seed authorities, categories, citations, and departments are Microsoft-shipped starter content; page describes portal-only operations and contains zero `PowerShell`, `cmdlet`, `Graph`, or `REST` occurrences for the seed-removal path.
- **[Records management overview (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/records-management)**
  Fetch date: 2026-06-07
  Cited to confirm the feature surface; contains no seed-removal guidance.
- **[Microsoft Graph security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)**
  Fetch date: 2026-06-07
  Cited to confirm the Graph `security` namespace overview contains zero occurrences of `fileplan`, `filePlan`, `filePlanProperty`, or `recordLabel` as of the fetch date.
- **[ADR 0019 — Communication Compliance Graph pivot watch list](0019-cc-graph-pivot.md)** — pattern precedent for "Microsoft Learn documents no programmatic surface; defer with watch list".
- **[ADR 0022 — DSPM for AI authoring surface watch list](0022-dspm-for-ai-authoring-surface.md)** — pattern precedent for "ship a read-only / read-mostly capability around an unbuildable surface".
- **[ADR 0027 — Sensitivity-label `autoApplicationOf` removal watch list](0027-autoapplication-removal-watch-list.md)** — pattern precedent for "the reconciler must not lie when it cannot in fact converge".
- **[#582](../../issues/582) close-comment** — verbatim probe transcripts; primary evidence for the Decision.

Microsoft Learn does not currently document this behavior as of `2026-06-07`.
