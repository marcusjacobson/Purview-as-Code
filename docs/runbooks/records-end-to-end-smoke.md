# Runbook: end-to-end smoke test for Records Management repo governance

Use this runbook to validate that the
[`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml)
desired-state surface and the
[`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1)
reconciler reconcile end-to-end against the `contoso.onmicrosoft.com`
tenant. Authored under issue [#585](../../issues/585) as Stream B of
the v2 §5.3 Records-Management Phase 3 plan tracked by [#364](../../issues/364).

This runbook is the operator-driven E2E that #364 Phase 3 depends on
for Create / Update / DriftWarn / Orphan / Prune evidence. Per the
artifact-resolver agent contract, AI agents cannot execute live-tenant
writes against the Microsoft Purview compliance portal; the operator
runs each step by hand and pastes captured output into the resumed
#364 PR (or any future PR that touches the Records-Management
reconciler).

Modelled on the sibling [`dlm-end-to-end-smoke.md`](dlm-end-to-end-smoke.md)
and [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md). Differences
from the DLM smoke are flagged inline.

## When to run

- After any breaking change to
  [`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1)
  or to
  [`data-plane/records/file-plan.schema.json`](../../data-plane/records/file-plan.schema.json).
- When the resumed [#364](../../issues/364) Phase 3 PR re-enters the
  build loop.
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven by design. Per the artifact-resolver
agent contract, AI agents cannot execute live-tenant writes against
the Purview account; the operator runs each step by hand and pastes
captured output into the PR opened by `@artifact-resolver`. (The
[automated path](#automated-path--invoke-recordssmoketestps1) below
is also operator-launched — the wrapper script consumes the
operator's `az` / Key Vault session and does not give the agent any
new tenant access.)

## Automated path — `Invoke-RecordsSmokeTest.ps1`

[`scripts/Invoke-RecordsSmokeTest.ps1`](../../scripts/Invoke-RecordsSmokeTest.ps1)
wraps Steps 1–10 below as a single near-unattended operator command,
prompts for `y/yes/confirm` before the two destructive `-PruneMissing`
steps (8 and 9), and writes a timestamped Markdown evidence file
under `.copilot-tracking/smoke/records-<UTC>.md` ready to paste into
the v2 §5.3 close-out PR (replacing the manual Step 12 work). The
manual steps below remain the authoritative source-of-truth and the
fallback path; the wrapper invokes
[`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1)
verbatim and introduces no new auth path or new Microsoft Purview /
IPPS cmdlet.

Preconditions (same as the manual path's [Preconditions](#preconditions)
table — `az login`, Key Vault access, clean working tree under
`data-plane/records/**`, `powershell-yaml` installed):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-RecordsSmokeTest.ps1
```

The wrapper:

- Aborts on any working-tree or staged edit under `data-plane/records/`
  (it relies on `git checkout --` to revert its own transient YAML
  edits between phases; a pre-existing edit would be silently
  discarded).
- Splices the per-phase YAML tail described by the manual steps into
  [`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml)
  in-place, runs each `Deploy-FilePlan.ps1` invocation, and reverts
  the YAML between phases.
- Prompts for explicit `y/yes/confirm` before Step 8
  (`Remove-ComplianceTag <label>`) and Step 9
  (`Remove-FilePlanPropertyCategory <category>`). Any other answer
  aborts and reverts the YAML.
- Emits one `[pscustomobject]` per step on the success stream and
  writes the durable evidence to
  `.copilot-tracking/smoke/records-<UTC>.md` (gitignored at the repo
  root — never commit the evidence file).

Exit codes: `0` every step PASSED (or was SKIPPED by `-WhatIf`),
`1` at least one step FAILED or the operator declined a
destructive-confirmation prompt, `2` preconditions failed.

For a tenant-write-free dry run (every step routes through `-WhatIf`
via the wrapper's `$WhatIfPreference` propagation):

```pwsh
./scripts/Invoke-RecordsSmokeTest.ps1 -SkipDestructiveConfirmation -WhatIf
```

The manual procedure below remains the canonical contract — re-walk
it the first time you ship a new Records reconciler behaviour, then
use the wrapper for subsequent regression-style re-runs. Unit-test
coverage for the wrapper's AST-extracted helpers lives in
[`tests/scripts/Invoke-RecordsSmokeTest.Tests.ps1`](../../tests/scripts/Invoke-RecordsSmokeTest.Tests.ps1).

## Preconditions

| Requirement | Why |
|---|---|
| Active `az login` session, lab subscription selected | The reconciler resolves the data-plane app certificate via `az` |
| Local principal has `Key Vault Certificate User` + `Key Vault Crypto User` on `kv-contoso-lab-01` | Required to sign the IPPS access token |
| `kv-contoso-lab-01` firewall allows the local public IP (see [`kv-temp-unlock.md`](kv-temp-unlock.md)) | Steady state is `publicNetworkAccess: Disabled` |
| Working tree is clean on the smoke-test branch | All transient YAML edits must revert cleanly |
| `powershell-yaml` module installed (`Install-Module powershell-yaml -Scope CurrentUser`) | Required by the reconciler |
| The lab tenant has **zero** retention labels | Baseline assumption; smoke creates a single synthetic label |
| The lab tenant carries the 31 Microsoft File Plan Manager seed property objects | Expected per [ADR 0035](../adr/0035-records-seed-content-immovable.md); the operator does not delete them |

### About the 31 Microsoft seeds

`scripts/Deploy-FilePlan.ps1` against `contoso.onmicrosoft.com` will always
report 31 `Orphan` property objects (3 authorities, 13 categories,
5 citations, 10 departments) shipped by Microsoft into every tenant.
[ADR 0035](../adr/0035-records-seed-content-immovable.md) ratifies
these as permanent declared orphans because every documented
`Remove-FilePlanProperty*` identity form fails with
`ErrorRuleNotFoundException`. The full verbatim list lives in the
ADR's `### The 31 seed names` table.

The runbook works around the noise by passing the 31 names through
`-SkipNames` per the ADR 0029 contract that landed in PR [#588](../../pull/588).
The `$script:Seeds` initializer in [Step 0](#0-define-the-seed-skip-list-once-per-session)
below carries the same list verbatim; if Microsoft ever ships a new
seed (or removes one) in a service revision, update this runbook,
[ADR 0035](../adr/0035-records-seed-content-immovable.md)'s table,
and the workflow baseline together.

Verify the expected baseline:

```pwsh
./scripts/Deploy-FilePlan.ps1 -WhatIf
```

Expected tail:

```text
Tenant props    : authorities=3, categories=13, citations=5, departments=10, referenceIds=0, subCategories=0
Tenant labels   : 0
DirectionPolicy : portal-wins
```

…followed by the 31 `Orphan` rows. If non-zero retention labels are
present, or if the property counts do not match `3/13/5/10/0/0`,
reconcile drift before starting this smoke (or file a follow-up
issue if a new Microsoft seed has appeared since [ADR 0035](../adr/0035-records-seed-content-immovable.md)
was written).

## Safety constraints

The smoke creates one synthetic retention label and one synthetic
file plan category against the live tenant. Every constraint below
is non-negotiable:

- **`isRecordLabel: false` only.** Never set `isRecordLabel: true`
  during this smoke. Record labels are **irreversible** once content
  is tagged — the label cannot be removed or downgraded without
  admin intervention. The first PR that introduces a record label
  is its own `destructive`-labeled change per the YAML header
  comment.
- **`regulatory: false` only (omit the field).** Same irreversibility
  guarantee as `isRecordLabel: true`. Never set `regulatory: true`
  during this smoke.
- **`retentionAction: Keep` only.** Never use `Delete` or
  `KeepAndDelete` in this smoke — both can mutate user content.
  `Keep` preserves content; it never removes anything.
- **`retentionDuration: 30` (days) only.** Short enough that any
  accidental preservation lapses quickly. Edit step bumps to 60 to
  exercise the Update path; never set higher than 365 in this smoke.
- **One synthetic category, one synthetic label.** Do not exercise
  authorities, citations, departments, referenceIds, or subCategories
  in this smoke. Their reconciler shape matches `categories` (Create
  / NoChange / DriftWarn / Orphan, no `Set-*`); proving one kind
  end-to-end proves them all. SubCategories specifically require a
  `parentCategory` reference — a separate runbook step would be
  needed to cover the referential resolution path.
- **Never run `-PruneMissing` without `-SkipNames @($Seeds)`.** Per
  [ADR 0035](../adr/0035-records-seed-content-immovable.md), the 31
  Microsoft seeds reject `Remove-FilePlanProperty*` with
  `ErrorRuleNotFoundException`. A prune without the skip list will
  emit 31 `Failed` plan rows.
- **Always restore YAML to the empty desired state and run a final
  `-WhatIf -SkipNames @($Seeds)`** at the end.

## Pick a synthetic naming pattern now

This smoke uses the `lab-fp-*` prefix:

- Category name: `lab-fp-cat-smoke-001`
- Retention label name: `lab-fp-label-smoke-001`

Substitute these names into the YAML blocks below. Do **not** use a
real organizational category or label name (per
[`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md)).

## Procedure

### 0. Define the seed skip list once per session

Most steps in this runbook pass `-SkipNames @($Seeds)`. Define
`$Seeds` once in the operator shell at the start of the session;
re-source the same value into every subsequent step:

```pwsh
$Seeds = @(
    'Business','Legal','Regulatory',
    'Accounts payable','Accounts receivable','Administration','Compliance',
    'Contracting','Financial statements','Learning and development',
    'Payroll','Planning','Policies and procedures','Procurement',
    'Recruiting and hiring','Research and development',
    'Commodity Exchange Act',
    'Health Insurance Portability and Accountability Act of 1996',
    'OSHA Injury and Illness Recordkeeping and Reporting Requirements',
    'Sarbanes-Oxley Act of 2002','Truth in Lending Act',
    'Finance','Human resources','Information technology','Marketing',
    'Operations','Products','Sales','Services'
)
$Seeds.Count    # must be 29 unique names (Legal and Procurement each appear under two kinds)
```

The `-SkipNames` parameter matches by bare `Name` regardless of
kind, so the list above is 29 unique names even though the tenant
reports 31 property objects (`Legal` and `Procurement` each appear
under two kinds — authority + department, category + department).
Confirm the marker count in Step 1 to verify all 31 tenant rows are
covered.

**Source of truth**: the full per-kind table in
[`docs/adr/0035-records-seed-content-immovable.md`](../adr/0035-records-seed-content-immovable.md)
under `### The 31 seed names`.

### 1. Baseline confirmation

```pwsh
cd C:\REPO\Purview-as-Code-Generic
git status --short    # must be empty
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**:

- Working tree is clean.
- Tail reports `Tenant props : authorities=3, categories=13, citations=5, departments=10, referenceIds=0, subCategories=0`,
  `Tenant labels : 0`, `DirectionPolicy : portal-wins`.
- **31 `Skipped` rows**, zero `Orphan` rows.
- **31 `[ADR0029-SKIP]` markers** in the Information stream.

If the `Skipped` row count or marker count is not exactly 31, stop
and reconcile drift before proceeding. A count of 30 means Microsoft
has either removed a seed (good — file a follow-up to shrink the
list in [ADR 0035](../adr/0035-records-seed-content-immovable.md))
or the operator-supplied `$Seeds` does not match the ADR (fix the
shell variable). A count of 32+ means a new seed has appeared (file
a follow-up to grow the list in [ADR 0035](../adr/0035-records-seed-content-immovable.md)).

**Evidence**: the `Tenant props` / `Tenant labels` lines, the
Skipped row count, the marker count.

### 2. Create supporting property (Create path, category)

Replace the trailing block in
[`data-plane/records/file-plan.yaml`](../../data-plane/records/file-plan.yaml)
with:

```yaml
filePlanProperties:
  authorities: []
  categories:
    - name: lab-fp-cat-smoke-001
  citations: []
  departments: []
  referenceIds: []
  subCategories: []

retentionLabels: []
```

Verify the schema accepts it (no tenant writes):

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 plan row says
`WhatIf Category lab-fp-cat-smoke-001 Would create: New-FilePlanPropertyCategory`.
The 31 `Skipped` rows are still present.

Apply:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds
```

**Expected**: 1 `Create Category lab-fp-cat-smoke-001`, exit code 0.

Verify directly against the tenant (single-line connect uses the
script's auth helper):

```pwsh
$tokenObj = & ./scripts/Get-PurviewIPPSAccessToken.ps1 `
    -VaultName 'kv-contoso-lab-01' `
    -CertificateName 'gh-oidc-purview-data-plane' `
    -AppId (az ad app list --display-name gh-oidc-purview-data-plane --query "[0].appId" -o tsv) `
    -TenantId (az account show --query tenantId -o tsv)
Connect-IPPSSession -AccessToken $tokenObj.AccessToken `
    -Organization 'contoso.onmicrosoft.com' -ShowBanner:$false | Out-Null
Get-FilePlanPropertyCategory -Identity lab-fp-cat-smoke-001 |
    Select-Object Name, FilePlanPropertyType, ReadOnly
```

**Expected**: `Name = lab-fp-cat-smoke-001`,
`FilePlanPropertyType = Category`, `ReadOnly = False`.

**Evidence**: the `Create` plan row + the verified Get-* output.

### 3. Create non-record label bound to the category (Create path, label)

Replace the trailing `retentionLabels: []` block with:

```yaml
retentionLabels:
  - name: lab-fp-label-smoke-001
    description: 'E2E smoke test for Records Management reconciler. Safe to delete.'
    isRecordLabel: false
    retentionDuration: 30
    retentionAction: Keep
    retentionType: ModificationAgeInDays
    filePlanProperty:
      category: lab-fp-cat-smoke-001
```

Verify the schema accepts it:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 plan row says
`WhatIf Label lab-fp-label-smoke-001 Would create: New-ComplianceTag (isRecordLabel=False, regulatory=False)`.
Category row reports `NoChange`.

Apply:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds
```

**Expected**: 1 `Create Label lab-fp-label-smoke-001` + 1 `NoChange Category lab-fp-cat-smoke-001`.

Verify directly:

```pwsh
Get-ComplianceTag -Identity lab-fp-label-smoke-001 |
    Select-Object Name, IsRecordLabel, Regulatory, RetentionAction, RetentionDuration, RetentionType,
                  @{n='Category';e={$_.FilePlanMetadata}}
```

**Expected**: `IsRecordLabel = False`, `Regulatory = False`,
`RetentionAction = Keep`, `RetentionDuration = 30`,
`RetentionType = ModificationAgeInDays`. The `Category` column
shows a JSON blob whose `FilePlanPropertyCategory` field contains
`lab-fp-cat-smoke-001` (the property → label binding round-tripped).

**Evidence**: the `Create` plan row + the verified Get-* output.

### 4. Confirm idempotency on the apply path

Re-run without YAML changes:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: both rows report `NoChange`. No `Create` / `Update`.
Marker count stays at 31.

**Evidence**: the two `NoChange` rows.

### 5. Edit the label (Update path)

Bump `retentionDuration` from `30` to `60` in the YAML. Save.

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 plan row says
`WhatIf Label lab-fp-label-smoke-001 Would update: Drift in: retentionDuration`.
Category row reports `NoChange`.

Apply:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds
```

**Expected**: 1 `Update Label lab-fp-label-smoke-001` + 1 `NoChange Category`.

Verify:

```pwsh
Get-ComplianceTag -Identity lab-fp-label-smoke-001 |
    Select-Object Name, RetentionDuration
```

**Expected**: `RetentionDuration = 60`.

**Evidence**: the `Update` plan row, followed by the verified
`RetentionDuration = 60`.

### 6. DriftWarn smoke (do **not** apply)

Flip `isRecordLabel: false` to `isRecordLabel: true` in the YAML.
Save.

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 plan row says
`DriftWarn Label lab-fp-label-smoke-001 Immutable drift on isRecordLabel; recreate manually after removing dependent retention label policies.`.
**Do NOT apply.** `Set-ComplianceTag` cannot change `IsRecordLabel`
after creation (documented constraint per
[`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1) header
notes); the reconciler correctly refuses to attempt the impossible
update. Promoting a non-record label to a record label requires
removing the label and recreating it — and after content has been
tagged, removal is gated by Microsoft support.

Revert the YAML edit:

```pwsh
git checkout -- data-plane/records/file-plan.yaml
```

…then re-author Step 3's `retentionLabels:` block (since
`git checkout` reverts both the Step 3 and Step 5 edits). Re-verify:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 `Update Label` (Step 5 re-applies the 60-day bump)
+ 1 `NoChange Category`.

Re-apply if needed:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds
```

**Evidence**: the `DriftWarn` plan row from the smoke probe; the
clean `Update` / `NoChange` re-apply after revert.

**Operator alternative**: if reverting via `git checkout` is risky
mid-smoke (because the operator has other in-flight changes to the
YAML), an in-place YAML edit that flips `isRecordLabel` back to
`false` is functionally equivalent — verify the same `NoChange`
post-revert before continuing.

### 7. Remove label from YAML (Orphan path, no-op without `-PruneMissing`)

Remove the entire `retentionLabels:` entry, leaving:

```yaml
retentionLabels: []
```

(The category block from Step 2 stays in place.) Then:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
```

**Expected**: 1 plan row says
`Orphan Label lab-fp-label-smoke-001 Tenant-only; skipped (no -PruneMissing).`.
Category row reports `NoChange`.

Apply with no prune flag to prove the orphan is a no-op:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds
```

**Expected**: same `Orphan` row, no `Removed`. Label still present
in the tenant.

```pwsh
Get-ComplianceTag -Identity lab-fp-label-smoke-001 |
    Select-Object Name    # still present
```

**Evidence**: the `Orphan` row and the verified presence.

### 8. Preview and apply `-PruneMissing` (Delete path, labels before properties)

Preview:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -PruneMissing -WhatIf
```

**Expected**: 1 `WhatIf Label lab-fp-label-smoke-001 Would remove: Remove-ComplianceTag`
+ 1 `NoChange Category lab-fp-cat-smoke-001`. No prune row appears
for the category yet (the operator-owned category is still desired).
The 31 `Skipped` rows for the Microsoft seeds remain `Skipped`, not
`WhatIf ... Would remove` — this is the **critical regression
check** that `-SkipNames` is correctly suppressing the seed prune
that would otherwise produce 31 `Failed` rows per
[#582](../../issues/582).

Apply:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -PruneMissing
```

**Expected**: 1 `Removed Label lab-fp-label-smoke-001`, no Failed
rows. Verify the prune ordering (labels removed before properties
per the reconciler's documented parent-before-children ordering) by
inspecting the label is gone but the category remains:

```pwsh
Start-Sleep -Seconds 30
Get-ComplianceTag -Identity lab-fp-label-smoke-001 -ErrorAction SilentlyContinue
# Expected: nothing returned, or "couldn't be found" error
Get-FilePlanPropertyCategory -Identity lab-fp-cat-smoke-001 |
    Select-Object Name
# Expected: still present
```

**Evidence**: the `Removed Label` row + the gone-label / still-present-category verifications.

### 9. Full prune (category removal)

Remove the category entry from the YAML, restoring:

```yaml
filePlanProperties:
  authorities: []
  categories: []
  citations: []
  departments: []
  referenceIds: []
  subCategories: []

retentionLabels: []
```

Preview the prune:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -PruneMissing -WhatIf
```

**Expected**: 1 `WhatIf Category lab-fp-cat-smoke-001 Would remove: Remove-FilePlanPropertyCategory`.
The 31 Microsoft seeds remain `Skipped` (not `Would remove`).

Apply:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -PruneMissing
```

**Expected**: 1 `Removed Category lab-fp-cat-smoke-001`, no Failed
rows. Verify:

```pwsh
Start-Sleep -Seconds 30
Get-FilePlanPropertyCategory -Identity lab-fp-cat-smoke-001 -ErrorAction SilentlyContinue
# Expected: nothing returned, or "couldn't be found" error
```

**Evidence**: the `Removed Category` row + the gone-category verification.

### 10. Final baseline confirmation

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -WhatIf
git status --short    # must be empty
```

**Expected** (same as Step 1):

- `Tenant props : authorities=3, categories=13, citations=5, departments=10, referenceIds=0, subCategories=0`.
- `Tenant labels : 0`.
- 31 `Skipped` rows, 0 `Orphan`, 0 `Create`, 0 `Update`, 0 `Removed`.
- Working tree clean.

**Evidence**: the three counter lines plus the empty `git status`.

### 11. Disconnect

```pwsh
Disconnect-ExchangeOnline -Confirm:$false
```

Tear down the IPPS session.

### 12. Paste evidence into the PR description

For each step above, paste the named evidence (a count, a diff
line, or a fenced extract from the log) into the corresponding
section of the smoke PR body under a `## Validation evidence` H2.
Strip `Token acquired` lines.

The transient log files under `$env:TEMP` are operator-local. Do
**not** commit them; the runbook plus the PR-body evidence are the
durable artifacts.

## Cleanup if any step fails mid-way

If Steps 2-8 leave the tenant with `lab-fp-cat-smoke-001` and/or
`lab-fp-label-smoke-001` and the YAML is clean (empty), recover with:

```pwsh
./scripts/Deploy-FilePlan.ps1 -DirectionPolicy portal-wins -SkipNames $Seeds -PruneMissing
```

If the YAML is dirty and the tenant is dirty, decide based on the
diff:

- Tenant has the objects you want → `./scripts/Deploy-FilePlan.ps1 -ExportCurrentState -Force`.
- YAML has the desired state → revert YAML to the empty shape, then
  run `-PruneMissing` (with `-SkipNames $Seeds`).

Final check before reporting success: `git status --short` is empty
**and** `Get-ComplianceTag` returns no rows for any `lab-fp-*`
**and** `Get-FilePlanPropertyCategory` returns no rows for any
`lab-fp-*`.

## Known gaps surfaced by this smoke

- **The 31 Microsoft seed property objects are immovable.** Per
  [ADR 0035](../adr/0035-records-seed-content-immovable.md). The
  runbook works around this with `-SkipNames $Seeds` everywhere;
  the underlying IPPS surface still rejects `Remove-FilePlanProperty*`
  for every documented identity form. Watch-list re-open triggers
  in the ADR. The operator-driven test for any documented removal
  path Microsoft ships in the future is a single re-run of #582's
  closed prune attempt with the new identity form.
- **`isRecordLabel: true` / `regulatory: true` paths are intentionally
  untested by design.** Both are irreversible after content is
  tagged. The first PR that introduces a record label is its own
  `destructive`-labeled change per the YAML header comment.
- **`KeepAndDelete` / `Delete` actions intentionally avoided.** Both
  can mutate user content. The smoke covers `Keep` only.
- **Only one property kind (category) exercised end-to-end.** The
  reconciler shape is identical across authorities, citations,
  departments, referenceIds, and subCategories (Create / NoChange
  / DriftWarn / Orphan, no `Set-*`); proving one kind proves them
  all. SubCategories specifically require a `parentCategory`
  reference — a future runbook step would cover that path
  end-to-end.
- **Event-based retention (`retentionType: EventAgeInDays`) untested.**
  Schema currently rejects it per the YAML header comment; deferred
  until issue [#82](../../issues/82) ships the event-type bootstrap.
- **The `-ExportCurrentState` round-trip path is not exercised
  step-by-step.** It works (it powered earlier disposition
  discussions for #364 Phase 2 option (a)), but the smoke focuses
  on the Create → Update → DriftWarn → Orphan → Prune cycle that
  the resumed [#364](../../issues/364) Phase 3 needs.
- **ADR 0029 `direction-policy` `audit` / `repo-wins` branches are
  not exercised by this smoke.** PR [#588](../../pull/588)'s Pester
  suite covers the three direction-policy branches statically;
  the live `audit` / `repo-wins` branches are reserved for the
  Phase 3d CI workflow step that [#586](../../issues/586) wires.

## See also

- [`dlm-end-to-end-smoke.md`](dlm-end-to-end-smoke.md) — DLM
  precedent (issue [#579](../../issues/579)).
- [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md) — DLP
  precedent.
- [`docs/adr/0035-records-seed-content-immovable.md`](../adr/0035-records-seed-content-immovable.md)
  — the 31 Microsoft seed names and the immovability ratification.
- [`docs/adr/0029-source-of-truth-direction-policy.md`](../adr/0029-source-of-truth-direction-policy.md)
  — the `-DirectionPolicy` / `-SkipNames` contract this runbook
  consumes.
- [`scripts/Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1)
  — reconciler source.
- [`data-plane/records/file-plan.schema.json`](../../data-plane/records/file-plan.schema.json)
  — schema reference.
- [#364](../../issues/364) — the v2 §5.3 Records Management
  Phase 3 parent issue this runbook unblocks.
- [#585](../../issues/585) — this runbook's authoring issue.