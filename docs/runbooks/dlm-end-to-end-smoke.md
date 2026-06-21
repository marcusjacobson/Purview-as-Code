# Runbook: end-to-end smoke test for DLM repo governance

Use this runbook to validate that the
[`data-plane/data-lifecycle/retention-policies.yaml`](../../data-plane/data-lifecycle/retention-policies.yaml)
desired-state surface and the
[`scripts/Deploy-RetentionPolicies.ps1`](../../scripts/Deploy-RetentionPolicies.ps1)
reconciler reconcile end-to-end against the `contoso.onmicrosoft.com`
tenant. Authored under issue [#579](../../issues/579) after the
2026-06-07 operator-led smoke surfaced and closed three DLM bugs:

- [#573](../../issues/573) (rule re-create) → PR #574
- [#575](../../issues/575) (`locations.exchange` drift) → PR #576
- [#577](../../issues/577) (`rules:` block dropped on export) → PR #578

This runbook is the durable copy of the original
`.copilot-tracking/handoff/main-20260607-1100-dlm-smoke.md` scratch
brief, which is gitignored and not the source of truth.

Modelled on the sibling [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md).

## When to run

- After any breaking change to
  [`scripts/Deploy-RetentionPolicies.ps1`](../../scripts/Deploy-RetentionPolicies.ps1)
  or to
  [`data-plane/data-lifecycle/retention-policies.schema.json`](../../data-plane/data-lifecycle/retention-policies.schema.json).
- After a new tracked retention rule field is added.
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
| The lab tenant has **zero** retention compliance policies and rules | Baseline assumption; smoke creates a single synthetic policy |

Verify the zero-policy baseline:

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

Expected tail:

```text
Desired policies: 0
Tenant policies : 0
Tenant rules    : 0
```

If non-zero, reconcile drift before starting this smoke.

## Safety constraints

The smoke creates one synthetic retention policy + rule against the
live tenant. Every constraint below is non-negotiable:

- **Action = `Keep` only.** Never use `Delete` or `KeepAndDelete` in
  this smoke — both can mutate user content. `Keep` only preserves;
  it never removes anything.
- **Retention duration = 30 days.** Short enough that any accidental
  preservation lapses quickly.
- **Single-user scope.** Use one `ExchangeLocation` pointing at a
  mailbox the operator controls (their own UPN, or a known test
  mailbox). Do **not** use `'All'` or a tenant-wide bucket.
- **Never enable `RestrictiveRetention`.** Preservation Lock is
  **irreversible**. Always omit or set `false`.
- **Always restore YAML to `policies: []` and run `-PruneMissing`**
  at the end.

## Pick a target identity now

Choose one mailbox UPN this smoke will scope the test policy to.
Substitute it into every `<TARGET-UPN>` placeholder below. Examples
of valid choices:

- The operator's own UPN (single-user blast radius, safest).
- A dedicated test mailbox in the lab tenant.

Do **not** use `user@contoso.com` — the cmdlet rejects identities
that don't resolve in the tenant.

## Procedure

### 1. Baseline confirmation

```pwsh
cd C:\REPO\Purview-as-Code-Generic
git status --short    # must be empty
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: clean working tree; tail reports
`Desired policies: 0 / Tenant policies : 0 / Tenant rules : 0`.

**Evidence**: the three counter lines.

### 2. Author a synthetic test policy in YAML

Replace the trailing `policies: []` in
[`data-plane/data-lifecycle/retention-policies.yaml`](../../data-plane/data-lifecycle/retention-policies.yaml)
with:

```yaml
policies:
  - name: lab-rp-smoke-001
    description: 'E2E smoke test for DLM reconciler. Safe to delete.'
    enabled: true
    locations:
      exchange:
        - <TARGET-UPN>
    rules:
      - name: lab-rule-smoke-001
        description: 'Keep 30 days; no deletion.'
        retentionDuration: 30
        retentionAction: Keep
```

Verify the schema accepts it (no tenant writes):

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: `Desired policies: 1`; plan rows show
`WhatIf Policy lab-rp-smoke-001` (Would create) and
`WhatIf Rule lab-rp-smoke-001\lab-rule-smoke-001` (Would create).

**Evidence**: the two plan rows.

### 3. Apply (Create path)

```pwsh
./scripts/Deploy-RetentionPolicies.ps1
```

**Expected**: 1 policy created, 1 rule created, exit code 0.

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
Get-RetentionCompliancePolicy -Identity lab-rp-smoke-001 -DistributionDetail |
    Select-Object Name, Enabled, @{n='ExchangeLocation';e={$_.ExchangeLocation.Name -join ','}}
Get-RetentionComplianceRule -Policy lab-rp-smoke-001 |
    Select-Object Name, RetentionDuration, RetentionComplianceAction
```

**Expected**: policy `Enabled = True`, `ExchangeLocation` contains
`<TARGET-UPN>`; rule with `RetentionDuration = 30`,
`RetentionComplianceAction = Keep`.

`-DistributionDetail` is required on `Get-RetentionCompliancePolicy`
to populate the `ExchangeLocation` collection — without it the
collection comes back empty (see PR #576 for the rationale).

**Evidence**: the four key=value rows from the two `Get-*` calls.

### 4. Confirm idempotency on the apply path

Re-run without YAML changes:

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: both rows report `NoChange`. No `Create` / `Update`.
This regression-tests PR #574 (rule lookup by friendly Name) and
PR #576 (`-DistributionDetail` + SMTP normalization) together.

**Evidence**: the two `NoChange` rows.

### 5. Modify the YAML (Update path)

Bump `retentionDuration` from `30` to `60` in the YAML. Save.

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: 1 plan row says
`WhatIf Rule lab-rp-smoke-001\lab-rule-smoke-001 Would update: Set-RetentionComplianceRule (Drift in: retentionDuration)`.
Policy row reports `NoChange`.

Apply:

```pwsh
./scripts/Deploy-RetentionPolicies.ps1
```

**Operator note**: if `Set-RetentionComplianceRule` reports `Failed`
once with a `Microsoft.Exchange.Management.UnifiedPolic...` error,
re-run the apply. This is IPPS eventual-consistency on first write
after a Create, not a reconciler bug. Observed in the 2026-06-07
smoke. If recurrence becomes a pattern, file a `fix(scripts)`
issue to add a one-shot retry to `Set-RetentionComplianceRule`.

Verify:

```pwsh
Get-RetentionComplianceRule -Policy lab-rp-smoke-001 |
    Select-Object Name, RetentionDuration
```

**Expected**: `RetentionDuration = 60`.

**Evidence**: the `Update` plan row, followed by the verified
`RetentionDuration = 60`.

### 6. Round-trip via `-ExportCurrentState`

Snapshot the YAML, then re-export and compare:

```pwsh
Copy-Item data-plane/data-lifecycle/retention-policies.yaml `
    "$env:TEMP/dlm-smoke-pre-export.yaml" -Force
./scripts/Deploy-RetentionPolicies.ps1 -ExportCurrentState -Force
@((Compare-Object `
    (Get-Content "$env:TEMP/dlm-smoke-pre-export.yaml") `
    (Get-Content data-plane/data-lifecycle/retention-policies.yaml)
)).Count
```

**Expected**: a non-zero line count (typically ~23 lines on the
synthetic single-policy YAML) reflecting **cosmetic-only** drift:

- 4-space nested indent → 2-space (powershell-yaml default).
- Single-quoted scalar strings → unquoted (powershell-yaml default).
- One leading blank line before `policies:`.

The `rules:` block must be present under the policy with the
correct `name`, `description`, `retentionDuration`, and
`retentionAction`. This is the round-trip contract codified in
PR #578: rules-block correctness is non-negotiable; indent /
quoting style is cosmetic because `ConvertTo-Yaml` does not expose
user-facing knobs to force 4-space + single-quote output.

Verify semantic equivalence by re-running `-WhatIf` against the
exported file:

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: `NoChange / NoChange`. The exported YAML parses to
the same in-memory shape as the input.

**Evidence**: the diff count plus the `NoChange / NoChange` re-apply.

### 7. Remove from YAML (Orphan path, no-op without `-PruneMissing`)

Restore the YAML to `policies: []`:

```pwsh
git checkout -- data-plane/data-lifecycle/retention-policies.yaml
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

**Expected**: 1 plan row says
`Orphan Policy lab-rp-smoke-001 Tenant-only; skipped (no -PruneMissing).`

Verify the apply still skips (no tenant writes):

```pwsh
./scripts/Deploy-RetentionPolicies.ps1
```

**Expected**: same `Orphan` row, no `Removed`. Policy and rule
still present in the tenant.

```pwsh
Get-RetentionCompliancePolicy -Identity lab-rp-smoke-001 |
    Select-Object Name    # still present
```

**Evidence**: the `Orphan` row and the verified presence.

### 8. Preview `-PruneMissing` (Delete plan)

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -PruneMissing -WhatIf
```

**Expected**: 1 plan row says
`WhatIf Policy lab-rp-smoke-001 Would remove: tenant-only orphan.`
No tenant writes.

**Evidence**: the `WhatIf ... Would remove` row.

### 9. Apply `-PruneMissing` (Delete path)

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -PruneMissing
```

**Expected**: policy and rule removed from the tenant.

Verify (allow up to ~60s for IPPS eventual-consistency to settle):

```pwsh
Start-Sleep -Seconds 30
Get-RetentionCompliancePolicy -Identity lab-rp-smoke-001 `
    -ErrorAction SilentlyContinue
# Expected: nothing returned, or "couldn't be found" error
```

**Evidence**: the `Removed` plan row.

### 10. Final baseline confirmation

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
git status --short    # must be empty
```

**Expected** (same as Step 1):
`Desired policies: 0 / Tenant policies : 0 / Tenant rules : 0`.
Working tree must be clean.

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

If Steps 3-9 leave the tenant with `lab-rp-smoke-001` and the YAML
is clean (`policies: []`), recover with:

```pwsh
./scripts/Deploy-RetentionPolicies.ps1 -PruneMissing
```

If the YAML is dirty and the tenant is dirty, decide based on the
diff:

- Tenant has the policy you want → `./scripts/Deploy-RetentionPolicies.ps1 -ExportCurrentState -Force`.
- YAML has the desired state → revert YAML to `policies: []`, then run `-PruneMissing`.

Final check before reporting success: `git status --short` is empty
**and** `Get-RetentionCompliancePolicy` returns no rows for any
`lab-rp-smoke-*`.

## Known gaps surfaced by this smoke

- **No `-DirectionPolicy` / `-SkipNames` on the DLM reconciler.**
  The ADR 0029 contract has not been wired into
  `scripts/Deploy-RetentionPolicies.ps1` yet (chore [#571](../../issues/571)
  is the parking spot). The DLP runbook exercises those switches;
  this runbook does not. File a follow-up when DLM gains the
  switches.
- **Multi-location buckets are out of scope.** Smoke is
  Exchange-only. SharePoint, OneDrive, modernGroup, Teams chat /
  channel / private channel, and publicFolder buckets have
  different recipient-shape semantics that
  [`Get-RetentionLocationIdentity`](../../scripts/Deploy-RetentionPolicies.ps1)
  handles defensively but the smoke does not assert.
- **`RestrictiveRetention` / Preservation Lock untested by
  design.** It is irreversible and inappropriate for a smoke test.
- **`KeepAndDelete` / `Delete` actions intentionally avoided.**
  Both can mutate user content. The smoke covers `Keep` only.
- **`contentMatchQuery` KQL filtering untested.** Add a coverage
  step once the YAML schema or AC requires it.
- **Adaptive scopes are a separate reconciler.** The DLM smoke
  does not touch
  [`scripts/Deploy-AdaptiveScopes.ps1`](../../scripts/Deploy-AdaptiveScopes.ps1).

## See also

- [`scripts/Deploy-RetentionPolicies.ps1`](../../scripts/Deploy-RetentionPolicies.ps1)
- [`data-plane/data-lifecycle/retention-policies.yaml`](../../data-plane/data-lifecycle/retention-policies.yaml)
- [`data-plane/data-lifecycle/retention-policies.schema.json`](../../data-plane/data-lifecycle/retention-policies.schema.json)
- [`tests/scripts/Deploy-RetentionPolicies.Tests.ps1`](../../tests/scripts/Deploy-RetentionPolicies.Tests.ps1)
- [`docs/solutions/governance-foundation/data-lifecycle.md`](../solutions/governance-foundation/data-lifecycle.md)
- [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md) — sibling runbook for the parallel DLP reconciler
- [`kv-temp-unlock.md`](kv-temp-unlock.md) — Key Vault firewall toggle
- [Microsoft Purview Data Lifecycle Management](https://learn.microsoft.com/en-us/purview/data-lifecycle-management)
- [Learn about retention policies](https://learn.microsoft.com/en-us/purview/retention)
- [New-RetentionCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy)
- [Set-RetentionCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy)
- [Get-RetentionCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy)
- [Remove-RetentionCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancepolicy)
- [New-RetentionComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule)
- [Set-RetentionComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancerule)
- [Get-RetentionComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule)
- [Preservation Lock for retention policies](https://learn.microsoft.com/en-us/purview/retention-preservation-lock)
- [Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-ippssession)
