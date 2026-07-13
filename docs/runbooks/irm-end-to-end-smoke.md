# Runbook: end-to-end smoke test for Insider Risk Management repo governance

Use this runbook to validate that the
[`data-plane/irm/policies.yaml`](../../data-plane/irm/policies.yaml)
desired-state surface and the
[`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1)
reconciler reconcile end-to-end against the `contoso.onmicrosoft.com`
tenant. Authored under issue [#603](../../issues/603) as the Phase 3
end-to-end verification path for the v2 §5.3 Insider Risk Management
lifecycle.

## Hard rule (issue #603 lab-owner directive)

**Pre-existing live IRM policies in `contoso.onmicrosoft.com` are
mid-testing and MUST NOT be mutated by this runbook.** Every step
below operates on a **throwaway `e2e-irm-smoke-*` policy** the
operator (or [`Invoke-IRMSmokeTest.ps1`](../../scripts/Invoke-IRMSmokeTest.ps1))
creates and tears down. The pre-existing four operator-authored
`IRM Lab — *` names from
[ADR 0036](../adr/0036-irm-tenant-setting-immovable.md) §"The skip
baseline" are always passed via `-SkipNames`; any plan row that
would touch one is a bug. Escalate to the lab owner. The
system-managed `IRM_Tenant_Setting_*` policy is not on the baseline —
the reconciler classifies it `NoChange` via a name-prefix wildcard.

## When to run

- After any breaking change to
  [`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1)
  or to
  [`data-plane/irm/policies.schema.json`](../../data-plane/irm/policies.schema.json).
- When the resumed [#603](../../issues/603) Phase 3 PR re-enters the
  build loop.
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven by design. Per the artifact-resolver
agent contract, AI agents cannot execute live-tenant writes against
the Purview account; the operator runs each step by hand and pastes
captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-IRMSmokeTest.ps1`

[`scripts/Invoke-IRMSmokeTest.ps1`](../../scripts/Invoke-IRMSmokeTest.ps1)
wraps Steps 1–5 below as a single near-unattended operator command,
prompts for `y/yes/confirm` before the destructive cleanup step, and
writes a timestamped Markdown evidence file under
`.copilot-tracking/smoke/irm-<UTC>.md` ready to paste into the v2
§5.3 close-out PR. The manual steps below remain the authoritative
source-of-truth and the fallback path; the wrapper invokes
[`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1)
and `Get-`/`New-`/`Remove-InsiderRiskPolicy` verbatim and introduces
no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions)
table — `az login`, Key Vault access, clean working tree under
`data-plane/irm/**`, `powershell-yaml` + `ExchangeOnlineManagement`
installed):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-IRMSmokeTest.ps1
```

The wrapper:

- Performs an idempotent prefix-only cleanup sweep at start
  (`Get-InsiderRiskPolicy | Where-Object Name -like 'e2e-irm-smoke-*'
  | Remove-InsiderRiskPolicy`) with a hard prefix assert before any
  `Remove-*` runs.
- Creates a throwaway policy named
  `e2e-irm-smoke-<YYYYMMDD-HHmm>` with scenario `LeakOfInformation`,
  mode defaulting to disabled.
- Runs `Get-InsiderRiskPolicy -Identity` on the throwaway and
  asserts shape (name, scenario, IsValid).
- Runs `Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy portal-wins
  -SkipNames <baseline>` and asserts:
  - the throwaway appears as `Orphan` (would be removed under
    `-PruneMissing`),
  - every name from [ADR 0036](../adr/0036-irm-tenant-setting-immovable.md)
    appears as `Skipped`,
  - no `Update` or `Failed` row mentions any pre-existing live policy.
- Removes the throwaway and asserts removal via a second
  `Get-InsiderRiskPolicy -Identity` (expects `ManagementObjectNotFoundException`).

Exit codes: `0` every step PASSED, `1` at least one step FAILED or
the operator declined the destructive-confirmation prompt, `2`
preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Key Vault access | Caller has `Key Vault Crypto User` + `Key Vault Certificate User` on `kv-contoso-lab-01`. |
| Working tree clean under `data-plane/irm/**` | `git status -s data-plane/irm/` returns empty. |
| Required modules | `Get-Module -ListAvailable powershell-yaml, ExchangeOnlineManagement` returns both. |
| Skip baseline current | `Get-InsiderRiskPolicy \| Select-Object -ExpandProperty Name` includes the 4 operator-authored `IRM Lab — *` names in [ADR 0036](../adr/0036-irm-tenant-setting-immovable.md) plus the system-managed `IRM_Tenant_Setting_*` policy. If the operator-authored set differs, stop and update ADR 0036 + the workflow `skip_names_irm` default in the same PR. |

## Step 1 — clean baseline

```pwsh
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy audit
```

Expected output tail:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
Category Name                                                    Reason
-------- ----                                                    ------
Orphan   IRM Lab — Data theft by departing users                 Tenant-only; skipped (no -PruneMissing).
Orphan   IRM Lab — Risky AI usage                                Tenant-only; skipped (no -PruneMissing).
Orphan   IRM Lab — Data leaks by priority users                  Tenant-only; skipped (no -PruneMissing).
NoChange IRM_Tenant_Setting_<guid>                               System-managed tenant policy; not reconciled by this script.
Orphan   IRM Lab — General data leaks                            Tenant-only; skipped (no -PruneMissing).
```

Audit mode intentionally bypasses `-SkipNames`. Skipped categorisation
is exercised in Step 4.

## Step 2 — create throwaway

```pwsh
# Connect via the same auth path the reconciler uses
$slug = (Get-Date).ToString('yyyyMMdd-HHmm')
$name = "e2e-irm-smoke-$slug"
New-InsiderRiskPolicy -Name $name -InsiderRiskScenario LeakOfInformation -Comment 'e2e smoke (issue #603) — safe to remove' -Enabled:$false
```

Expected: cmdlet returns a `Microsoft.Office.CompliancePolicy.PolicyConfig.InsiderRiskPolicy`
object with `Name = e2e-irm-smoke-<slug>`, `InsiderRiskScenario = DataLeaks`,
`Enabled = False`, `IsValid = True`.

## Step 3 — assert shape

```pwsh
$p = Get-InsiderRiskPolicy -Identity $name
$p | Select-Object Name, InsiderRiskScenario, Enabled, IsValid | Format-List
```

Expected fields match Step 2's create.

## Step 4 — reconciler `-WhatIf` with skip baseline

```pwsh
$skipBaseline = @(
  'IRM Lab — Data leaks by priority users',
  'IRM Lab — Data theft by departing users',
  'IRM Lab — General data leaks',
  'IRM Lab — Risky AI usage'
)
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy portal-wins `
  -SkipNames $skipBaseline -PruneMissing
```

Expected:

- Exactly **4 `Skipped` rows** — one per skip-baseline name.
- Exactly **1 `NoChange` row** — the system-managed
  `IRM_Tenant_Setting_<guid>`, classified via the reconciler's
  name-prefix wildcard (not via `-SkipNames`).
- Exactly **1 `Orphan` row** — the throwaway from Step 2, reason
  `Tenant-only; will be removed (-PruneMissing).`
- **Zero `Update`, `Failed`, `Removed` rows.** A row mentioning any
  pre-existing live policy is a bug — escalate.

## Step 5 — destructive cleanup of throwaway

```pwsh
# Hard prefix assert
if ($name -notlike 'e2e-irm-smoke-*') { throw "refusing to delete non-smoke policy: $name" }
Remove-InsiderRiskPolicy -Identity $name -Confirm:$false
```

Expected: cmdlet returns no output; subsequent `Get-InsiderRiskPolicy -Identity $name`
throws `ManagementObjectNotFoundException`.

## Scheduled reverse drift-detection (CI, no operator action)

Between manual smoke runs, the reverse companion workflow
[`.github/workflows/sync-irm-from-tenant.yml`](../../.github/workflows/sync-irm-from-tenant.yml)
watches the same surface daily (08:00 UTC). Because IRM is a Tier-3
surface (no `-ExportCurrentState` on
[`Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1)), it
**cannot** open a re-export PR the way the label / auto-label / DLP
sync workflows do. Instead it runs the reconciler in read-only ADR 0029
audit mode, captures the returned `[pscustomobject]` rows from stream 1,
post-filters the ADR 0036 skip baseline, and opens a GitHub **issue**
(labels `drift-detected`, `needs-review`, `squad:automation-engineer`,
self-provisioning any that are missing) when a `Create` / `Update` /
`Orphan` / `Failed` row survives the filter.

Relationship to this runbook:

- The workflow is the automated watch loop; **this runbook is the
  operator response** when it fires. Triage with Step 1
  (`-DirectionPolicy audit`), then reconcile per the issue's "Next
  steps": **accept into YAML** (edit
  [`data-plane/irm/policies.yaml`](../../data-plane/irm/policies.yaml),
  then re-apply forward via
  [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml) — the
  per-solution forward companion, and the only forward-apply path for IRM
  since [ADR 0051](../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)
  retired the monolithic workflow), **`repo-wins` overwrite** (dispatch `deploy-irm.yml` with
  `irm_direction_policy=repo-wins` and the typed
  `confirm_overwrite_irm=overwrite portal` token), or **extend the skip
  baseline + ADR 0036**.
- The workflow never writes to the tenant and never mutates a
  pre-existing live policy, so it is safe to leave enabled during the
  issue #603 mid-testing window.
- To trigger it on demand: `gh workflow run sync-irm-from-tenant.yml`.

## Safety constraints

- **Never** invoke `Set-InsiderRiskPolicy`, `Remove-InsiderRiskPolicy`,
  or `Set-InsiderRiskPolicyLite` against any name that does not start
  with `e2e-irm-smoke-`.
- **Never** invoke `Deploy-IRMPolicies.ps1 -PruneMissing` without
  `-SkipNames` carrying the 4-name ADR 0036 baseline. (The
  system-managed `IRM_Tenant_Setting_*` policy is safe either way — the
  reconciler short-circuits it to `NoChange` via a name-prefix wildcard
  — but the four operator-authored `IRM Lab — *` policies still need the
  baseline to avoid a prune during the mid-testing window.)
- The reconciler's audit short-circuit (`-DirectionPolicy audit`) is
  the safest read-only verification. Prefer it over `-WhatIf` alone
  when triaging a tenant in an unexpected state.

## References

- [Microsoft Purview Insider Risk Management overview](https://learn.microsoft.com/en-us/purview/insider-risk-management)
- [Get-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy)
- [New-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy)
- [Remove-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy)
- [ADR 0029](../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0036](../adr/0036-irm-tenant-setting-immovable.md)
- Forward companion workflow (preferred): [`deploy-irm.yml`](../../.github/workflows/deploy-irm.yml)
- Reverse companion workflow: [`sync-irm-from-tenant.yml`](../../.github/workflows/sync-irm-from-tenant.yml)
- [Sibling runbook: records-end-to-end-smoke.md](records-end-to-end-smoke.md)