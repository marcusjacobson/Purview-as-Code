# Runbook: end-to-end smoke test for DLP repo governance

Use this runbook to validate that the `data-plane/dlp/policies.yaml`
desired-state surface and the `scripts/Deploy-DLPPolicies.ps1`
reconciler reconcile end-to-end against the `contoso.onmicrosoft.com`
tenant. Authored under issue [#560](../../issues/560) after umbrella
[#521](../../issues/521) shipped the 14-tracked-field rule surface on
2026-06-05 and PR #557 wired the ADR 0029 `-DirectionPolicy` /
`-SkipNames` contract into the reconciler.

This is **not** part of the §4 phase-1 review (the §5.3 DLP row is
already ticked). It is a one-time consolidated smoke that exercises
every contract surface against a 5-policy / 16-rule live tenant in a
single sitting so the project can move on to §5.3 Audit retention,
DLM, and Records with high confidence in the DLP foundation.

## When to run

- Once after PR #557 merges (issue [#560](../../issues/560)).
- Re-run on demand after any breaking change to
  `scripts/Deploy-DLPPolicies.ps1` or to
  `data-plane/dlp/policies.schema.json`.
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven by design. Per the artifact-resolver
agent contract, AI agents cannot execute live-tenant writes against
the Purview account; the operator runs each step by hand and pastes
captured output into the PR opened by `@artifact-resolver`.

## Preconditions

| Requirement | Why |
|---|---|
| Active `az login` session, lab subscription selected | The reconciler resolves the data-plane app certificate via `az` |
| Local principal has `Key Vault Certificate User` + `Key Vault Crypto User` on `kv-contoso-lab-01` | Required to sign the IPPS access token |
| `kv-contoso-lab-01` firewall allows the local public IP (see [`kv-temp-unlock.md`](kv-temp-unlock.md)) | Steady state is `publicNetworkAccess: Disabled` |
| Working tree is clean on the smoke-test branch | All transient YAML edits must revert cleanly |
| `powershell-yaml` module installed (`Install-Module powershell-yaml -Scope CurrentUser`) | Required by the reconciler |

Five tenant policies and 16 rules are in scope (the count shipped by
umbrella #521 on 2026-06-05):

```text
Default Office 365 DLP policy
Default policy for Teams
Default policy for devices
Fabric PII Detection - CoA Demo Workspace
Default DLP policy - Protect sensitive M365 Copilot interactions
```

## Procedure

Each numbered step maps to one acceptance-criterion checkbox on issue
[#560](../../issues/560). Run them in order. Where a step requires a
transient YAML edit, the cleanup step is part of the same numbered
section so the working tree is restored before moving on.

Evidence-capture convention: redirect stdout+stderr to a file under
`$env:TEMP`, then strip the `Token acquired` lines before pasting into
the PR. The `Token acquired` line is non-deterministic and noise.

```pwsh
(Get-Content -LiteralPath $logPath) -notmatch '^Token acquired' |
  Set-Clipboard
```

### 1. Schema gate rejects malformed YAML

Verify `Test-Json` against [`policies.schema.json`](../../data-plane/dlp/policies.schema.json)
rejects an entry that violates a schema constraint.

```pwsh
Copy-Item -LiteralPath ./data-plane/dlp/policies.yaml `
  -Destination "$env:TEMP/dlp-smoke-baseline.yaml" -Force

# Edit ./data-plane/dlp/policies.yaml: change the first policy `mode:`
# value from `TestWithoutNotifications` to `NotARealMode`.

./scripts/Deploy-DLPPolicies.ps1 -WhatIf 2>&1 |
  Tee-Object -FilePath "$env:TEMP/dlp-smoke-1-schemafail.log"

# Restore baseline.
Copy-Item -LiteralPath "$env:TEMP/dlp-smoke-baseline.yaml" `
  -Destination ./data-plane/dlp/policies.yaml -Force
```

**Expected**: non-zero exit; error message names the offending field
(`mode`) and the enum constraint. No tenant calls fire.

**Evidence**: `dlp-smoke-1-schemafail.log`.

### 2. `-WhatIf` is idempotent

Two consecutive `-WhatIf` runs against an unchanged YAML produce
byte-identical plan output (Token-acquired lines stripped).

```pwsh
./scripts/Deploy-DLPPolicies.ps1 -WhatIf `
  > "$env:TEMP/dlp-smoke-2-whatif-a.log" 2>&1

./scripts/Deploy-DLPPolicies.ps1 -WhatIf `
  > "$env:TEMP/dlp-smoke-2-whatif-b.log" 2>&1

$a = (Get-Content -LiteralPath "$env:TEMP/dlp-smoke-2-whatif-a.log") `
       -notmatch '^Token acquired'
$b = (Get-Content -LiteralPath "$env:TEMP/dlp-smoke-2-whatif-b.log") `
       -notmatch '^Token acquired'

"diff lines: $(@((Compare-Object $a $b)).Count)"
```

**Expected**: `diff lines: 0`. Same shape as the PR #557 smoke.

**Evidence**: paste the `diff lines: 0` confirmation; attach the two
log files only if the count is non-zero (failure case).

### 3. `-ExportCurrentState` round-trip is loss-less

Drift the YAML back from the tenant and confirm `Compare-Object`
returns zero differences against the committed baseline.

```pwsh
Copy-Item -LiteralPath ./data-plane/dlp/policies.yaml `
  -Destination "$env:TEMP/dlp-smoke-3-pre-export.yaml" -Force

./scripts/Deploy-DLPPolicies.ps1 -ExportCurrentState -Force `
  > "$env:TEMP/dlp-smoke-3-export.log" 2>&1

$diff = Compare-Object `
  (Get-Content -LiteralPath "$env:TEMP/dlp-smoke-3-pre-export.yaml") `
  (Get-Content -LiteralPath ./data-plane/dlp/policies.yaml)

"round-trip diff lines: $(@($diff).Count)"

# Restore baseline (the export may have rewritten formatting even when
# semantically equivalent; smoke is about content, not formatting).
Copy-Item -LiteralPath "$env:TEMP/dlp-smoke-3-pre-export.yaml" `
  -Destination ./data-plane/dlp/policies.yaml -Force
```

**Expected**: `round-trip diff lines: 0` for all 14 tracked fields
across 5 policies and 16 rules. Any non-zero count names a field that
the reconciler is not yet round-tripping cleanly; file a follow-up
issue per the per-field tracking pattern of umbrella #521.

**Evidence**: the count line plus, if non-zero, the `Compare-Object`
output naming the drifted property.

### 4. `-DirectionPolicy audit` is read-only

Audit mode emits the plan plus one `[ADR0029-AUDIT]` marker per
drift; performs no writes.

```pwsh
./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy audit `
  > "$env:TEMP/dlp-smoke-4-audit.log" 2>&1

Select-String -Path "$env:TEMP/dlp-smoke-4-audit.log" -Pattern 'ADR0029-AUDIT'
"exit: $LASTEXITCODE"
```

**Expected**: exit 0; if drift exists (clean tenant should not),
`[ADR0029-AUDIT]` lines are emitted; **zero** `WhatIf` ShouldProcess
prompts, **zero** `New-` / `Set-` / `Remove-DlpCompliance*` calls.

**Evidence**: the `[ADR0029-AUDIT]` line count (which may be 0 on a
clean tenant — that is itself the expected steady-state).

### 5. `-DirectionPolicy portal-wins` reconciles cleanly

Default mode. On a clean tenant, the plan should show **NoChange**
for every entry.

```pwsh
./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy portal-wins -WhatIf `
  > "$env:TEMP/dlp-smoke-5-portal-wins.log" 2>&1

Select-String -Path "$env:TEMP/dlp-smoke-5-portal-wins.log" `
  -Pattern 'Create|Update|Delete|Skip|NoChange'
```

**Expected**: every plan row is `NoChange`. If any `Skip` rows
appear, the reconciler is correctly applying portal-wins to a drifted
field; capture the `[ADR0029-SKIP] <name>` lines as evidence and file
a follow-up issue if the drift is unexpected.

**Evidence**: the plan-row summary.

### 6. `-DirectionPolicy repo-wins` overwrites a tracked field

Make a one-line YAML change to a low-risk field, observe `repo-wins`
plan as `Update`, apply it, confirm `-ExportCurrentState` echoes the
new value back, then revert.

> Operator confirmation gate. This step writes to the live tenant.
> If you are not ready to apply, stop here and tick this AC manually
> after a separate session.

```pwsh
Copy-Item -LiteralPath ./data-plane/dlp/policies.yaml `
  -Destination "$env:TEMP/dlp-smoke-6-baseline.yaml" -Force

# Edit ./data-plane/dlp/policies.yaml: append " (smoke 2026-06-05)" to
# the `description:` of "Default policy for Teams". Save.

./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy repo-wins -WhatIf `
  > "$env:TEMP/dlp-smoke-6-plan.log" 2>&1
Select-String -Path "$env:TEMP/dlp-smoke-6-plan.log" `
  -Pattern 'Update.*Default policy for Teams'

./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy repo-wins `
  > "$env:TEMP/dlp-smoke-6-apply.log" 2>&1

# Verify tenant now matches repo.
./scripts/Deploy-DLPPolicies.ps1 -ExportCurrentState -Force `
  > "$env:TEMP/dlp-smoke-6-postexport.log" 2>&1
Select-String -Path ./data-plane/dlp/policies.yaml -Pattern '(smoke 2026-06-05)'

# Restore baseline + push back to tenant.
Copy-Item -LiteralPath "$env:TEMP/dlp-smoke-6-baseline.yaml" `
  -Destination ./data-plane/dlp/policies.yaml -Force
./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy repo-wins `
  > "$env:TEMP/dlp-smoke-6-revert.log" 2>&1
```

**Expected**: plan shows `Update` on "Default policy for Teams";
apply emits one `Write-Warning` naming the `description` field;
post-export confirms the new description; revert restores baseline
with zero net change on the tenant.

**Evidence**: the four log files (plan / apply / postexport / revert).
Confirm `git diff data-plane/dlp/policies.yaml` is empty at the end.

### 7. `-SkipNames` excludes a named policy

Pass one tenant policy name to `-SkipNames`; confirm the plan row is
absent and the other four policies still reconcile.

```pwsh
./scripts/Deploy-DLPPolicies.ps1 -WhatIf `
  -SkipNames 'Default policy for Teams' `
  > "$env:TEMP/dlp-smoke-7-skip.log" 2>&1

Select-String -Path "$env:TEMP/dlp-smoke-7-skip.log" `
  -Pattern 'ADR0029-SKIP|Default policy for Teams'
```

**Expected**: one `[ADR0029-SKIP] Default policy for Teams` line; the
other four policies still appear in the plan as `NoChange`.

**Evidence**: the matched lines.

### 8. `-PruneMissing` dry-run plans a Delete

Temporarily remove one rule from the YAML so the tenant version is
orphaned; confirm `-WhatIf` (without `-PruneMissing`) reports it as
`Orphan` and `-WhatIf -PruneMissing` reports it as `Delete`. **Do
not** apply the prune; restore the YAML.

> This step deviates from the literal AC wording on #560. The AC's
> "add a synthetic entry" path tests Create-not-Delete because a
> YAML-only addition has no tenant analogue to prune. The semantically
> correct prune-plan smoke is removal-from-YAML, which surfaces the
> Delete branch.

```pwsh
Copy-Item -LiteralPath ./data-plane/dlp/policies.yaml `
  -Destination "$env:TEMP/dlp-smoke-8-baseline.yaml" -Force

# Edit ./data-plane/dlp/policies.yaml: comment out one full rule entry
# under "Default policy for Teams" (the simplest rule is preferred).

./scripts/Deploy-DLPPolicies.ps1 -WhatIf `
  > "$env:TEMP/dlp-smoke-8-orphan.log" 2>&1
Select-String -Path "$env:TEMP/dlp-smoke-8-orphan.log" -Pattern 'Orphan'

./scripts/Deploy-DLPPolicies.ps1 -WhatIf -PruneMissing `
  > "$env:TEMP/dlp-smoke-8-prune.log" 2>&1
Select-String -Path "$env:TEMP/dlp-smoke-8-prune.log" -Pattern 'Delete'

# Restore baseline. Do NOT apply.
Copy-Item -LiteralPath "$env:TEMP/dlp-smoke-8-baseline.yaml" `
  -Destination ./data-plane/dlp/policies.yaml -Force
```

**Expected**: first run shows the rule as `Orphan` (not actioned);
second run reclassifies it as `Delete`. No `Remove-DlpComplianceRule`
call fires because both runs are `-WhatIf`.

**Evidence**: the two matched lines.

### 9. `AdvancedRule` round-trip is byte-identical

Per [ADR 0031](../adr/0031-dlp-advancedrule-yaml-shape.md), the
reconciler must round-trip `AdvancedRule`-shaped rules without
re-serializing the JSON body.

```pwsh
$rulesUsingAdvancedRule = Select-String `
  -Path ./data-plane/dlp/policies.yaml -Pattern '^\s*advancedRule:' |
  Measure-Object | Select-Object -ExpandProperty Count

"rules using AdvancedRule shape in YAML: $rulesUsingAdvancedRule"

# The round-trip evidence is the same as step 3: a clean `Compare-Object`
# from -ExportCurrentState proves AdvancedRule byte-identity because
# AdvancedRule is one of the 14 tracked fields. Re-run step 3 here only
# if step 3 was skipped or the YAML has been edited since.
```

**Expected**: the count is non-zero (umbrella #521 declares 11
`AdvancedRule` rules); the step-3 round-trip evidence covers this AC.

**Evidence**: the count line plus a back-reference to step 3.

### 10. CI workflow exercises the DLP reconciler

Two CI paths now invoke `Deploy-DLPPolicies.ps1`:

- [`deploy-dlp.yml`](../../.github/workflows/deploy-dlp.yml) — the
  dedicated per-domain forward-apply workflow. Runs the surface in
  isolation with the full ADR 0029 enumerate → apply → drift-back
  ceremony (default `direction_policy=portal-wins`), plus a `push:`
  trigger on the DLP data-plane paths. Preferred for DLP-only applies.
- [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) —
  the monolithic `workflow_dispatch:`-only path that still carries a
  `Deploy DLP policies` step inside the Key Vault firewall window
  (shipped under issue #562); it reconciles every data-plane surface in
  one run.

The reverse leg — [`sync-dlp-from-tenant.yml`](../../.github/workflows/sync-dlp-from-tenant.yml) —
runs `-ExportCurrentState` on a daily schedule (07:00 UTC) plus
`workflow_dispatch:` and opens a drift-back PR when the tenant has
moved ahead of the repo.

The dedicated workflow reads two dispatch inputs that thread the
ADR 0029 contract through to `Deploy-DLPPolicies.ps1`:

- `direction_policy` — `audit` / `portal-wins` (default) / `repo-wins`.
- `confirm_overwrite` — typed `overwrite portal` token, gates `repo-wins`.

```pwsh
# Smoke the audit branch end-to-end against the lab tenant.
gh workflow run deploy-dlp.yml `
  --ref main `
  --field direction_policy=audit
```

**Expected**: workflow run succeeds. The `Validate dispatch inputs`
step logs `direction_policy = 'audit'` and exits 0; the read-only plan
pass emits the `[ADR0029-AUDIT]` marker and the 21-row NoChange plan
against the steady-state tenant. To exercise the destructive branch
under typed confirmation, dispatch with `direction_policy=repo-wins`
and `confirm_overwrite='overwrite portal'`.

**Evidence**: link to the successful workflow run.

### 11. Pester suite still green

Confirm the smoke did not regress unit tests.

```pwsh
./tests/Run-Pester.ps1 2>&1 |
  Tee-Object -FilePath "$env:TEMP/dlp-smoke-11-pester.log"
"exit: $LASTEXITCODE"
```

**Expected**: exit 0; the Pester summary line shows zero failures.

**Evidence**: the final summary line.

### 12. Paste evidence into the PR description

For each step above, paste the named evidence (a count, a diff line,
or a fenced extract from the log) into the corresponding section of
the smoke PR body under a `## Validation evidence` H2. Strip
`Token acquired` lines.

The transient log files under `$env:TEMP` are operator-local. Do
**not** commit them; the runbook plus the PR-body evidence are the
durable artifacts.

## Known gaps surfaced by this smoke

- **`-PruneMissing` AC wording on #560 is ambiguous.** Step 8
  documents the semantically correct version. The next smoke run can
  follow this runbook verbatim; the issue body is one-time only.

## See also

- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0031 — DLP AdvancedRule YAML shape](../adr/0031-dlp-advancedrule-yaml-shape.md)
- [ADR 0032 — DLP generic Locations YAML shape](../adr/0032-dlp-generic-locations-shape.md)
- [ADR 0033 — DLP rule tracked-field expansion](../adr/0033-dlp-rule-tracked-field-expansion.md)
- [`scripts/Deploy-DLPPolicies.ps1`](../../scripts/Deploy-DLPPolicies.ps1)
- [`.github/workflows/deploy-dlp.yml`](../../.github/workflows/deploy-dlp.yml) —
  isolated forward-apply workflow (ADR 0029 direction-policy contract)
- [`.github/workflows/sync-dlp-from-tenant.yml`](../../.github/workflows/sync-dlp-from-tenant.yml) —
  scheduled reverse drift-back workflow
- [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml)
- [`data-plane/dlp/policies.schema.json`](../../data-plane/dlp/policies.schema.json)
- [`labels-direction-policy.md`](labels-direction-policy.md) — runbook for the
  parallel sensitivity-label direction-policy contract
- [`kv-temp-unlock.md`](kv-temp-unlock.md) — Key Vault firewall toggle
- [Get-DlpCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy)
- [Set-DlpCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy)
- [New-DlpComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule)
- [Remove-DlpComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-dlpcompliancerule)
- [Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-ippssession)
- [Learn about data loss prevention](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp)