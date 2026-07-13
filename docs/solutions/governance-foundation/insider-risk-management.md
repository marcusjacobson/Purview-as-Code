# Insider Risk Management — policies

Operational guide for [`scripts/Deploy-IRMPolicies.ps1`](../../../scripts/Deploy-IRMPolicies.ps1) — the reconciler that materializes [`data-plane/irm/policies.yaml`](../../../data-plane/irm/policies.yaml) against the [Microsoft Purview Insider Risk Management](https://learn.microsoft.com/en-us/purview/insider-risk-management) surface. Pairs with [`audit-log.md`](audit-log.md) (the tenant-scope ingestion source IRM depends on).

## Purpose

Reconciles the [`Get/New/Set/Remove-InsiderRiskPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy) cmdlet family against a declared list of IRM policy entries. Emits Create / Update / NoChange / Orphan / Skipped decisions per policy. Orphan policies (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline.

The IRM model is documented at [Insider Risk Management overview](https://learn.microsoft.com/en-us/purview/insider-risk-management):

- Each policy carries a `Name` (string), `InsiderRiskScenario` (template enum), and optional `Comment` and `Enabled` flag.
- `Priority` is a read-only field on `Get-InsiderRiskPolicy` — neither `New-` nor `Set-InsiderRiskPolicy` accept a `-Priority` parameter (verified in issue #267), so the reconciler does not track it.
- The Microsoft service synthesises one per-tenant `IRM_Tenant_Setting_<guid>` policy of scenario `TenantSetting` to back the global IRM configuration. Microsoft Learn documents no path to delete or scope-out this entry; [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) ratifies it as a permanent declared orphan.

## Default state

The shipped YAML declares an empty `policies: []` list per the v2 §5.3 lifecycle pass on 2026-06-14 (issue [#603](../../../../../issues/603)). With no policies declared and the ADR 0036 skip baseline wired into CI, the reconciler emits one `Skipped` row per baselined name and exits without writes. Adoption of the four operator-authored `IRM Lab — *` policies into desired state is tracked under follow-up [#604](../../../../../issues/604), gated on the active testing window closing.

## Authentication

Same Key Vault-side JWT signing path as every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate''s underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/irm/policies.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant policies. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-SkipSchemaValidation` | switch — bypass the JSON Schema gate (emergency only) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `Get-InsiderRiskPolicy`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No writes under any circumstance.** Skip-baseline bypass intentional — see live tenant raw vs YAML. |
| `-WhatIf` (default `portal-wins`) | Reads `Get-InsiderRiskPolicy`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Skipped rows. No writes. |
| (default) | Same read, then per-row `New-`, `Set-`, or `Remove-InsiderRiskPolicy` for Create / Update / (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_irm='overwrite portal'` token. |

## Schema

YAML conforms to [`data-plane/irm/policies.schema.json`](../../../data-plane/irm/policies.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Insider Risk Management` (or `Compliance Administrator`) | Tenant |
| Caller''s identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow''s `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network).

## Smoke test

```pwsh
# Audit mode — read-only view of the raw live tenant vs YAML.
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy audit
```

Expected output tail when YAML is the default empty list and the ADR 0036 baseline policies are present in the tenant:

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

For the noise-free `portal-wins` view (matches what CI runs):

```pwsh
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy portal-wins `
  -SkipNames @(
    'IRM Lab — Data leaks by priority users',
    'IRM Lab — Data theft by departing users',
    'IRM Lab — General data leaks',
    'IRM Lab — Risky AI usage')
```

Expected: 4 `Skipped` rows (the operator-authored `IRM Lab — *`
policies) plus 1 `NoChange` row — the system-managed
`IRM_Tenant_Setting_<guid>`, classified via the reconciler's
name-prefix wildcard, not `-SkipNames` — and zero anything else.

For an end-to-end live-tenant smoke (Create → Get → Plan-shape assert → Delete → Get-gone) against a throwaway `e2e-irm-smoke-*` policy, follow [`docs/runbooks/irm-end-to-end-smoke.md`](../../runbooks/irm-end-to-end-smoke.md) or run the wrapper:

```pwsh
./scripts/Invoke-IRMSmokeTest.ps1
```

## CI wiring

IRM has **two** forward apply paths. Prefer the isolated
[`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml).

### Isolated forward workflow — `deploy-irm.yml` (preferred)

[`.github/workflows/deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
runs the reconciler on its own — one `apply` job, one idempotent apply
pass — so IRM can be applied in isolation without re-touching (and
red-lighting) every other data-plane surface the monolith runs in the same
job. It is the **forward twin** of the reverse companion
[`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml)
and mirrors the [`deploy-dlp.yml`](../../../.github/workflows/deploy-dlp.yml)
precedent, adapted for a Tier-3 surface. Triggers on `workflow_dispatch`
plus `push` to `main` under `data-plane/irm/**`,
`scripts/Deploy-IRMPolicies.ps1`, `scripts/modules/DirectionPolicy.psm1`,
and the workflow file itself. Three `workflow_dispatch` inputs thread the
ADR 0029 contract:

- `irm_direction_policy` — `audit` / `portal-wins` (default) / `repo-wins`.
- `confirm_overwrite_irm` — typed `overwrite portal` token, gates `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md).
- `skip_names_irm` — comma list passed through to `-SkipNames`; defaults to the 4-name [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) baseline. This default is byte-matched against [`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml) — a **two-way** lockstep. It was a three-way lockstep until [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) retired the monolithic `deploy-data-plane.yml`, whose copy was the third leg (and was dead code that never once ran).

A fail-fast `Validate dispatch inputs` step runs before Azure login and
rejects a `repo-wins` dispatch without the typed token. Workflow-scope
`permissions: {}`; the `apply` job holds only `id-token: write` +
`contents: read` (no `contents: write`, no `pull-requests`). Because IRM is
**Tier-3** — `Deploy-IRMPolicies.ps1` exposes no `-ExportCurrentState` and
no `-VerifyPublished` — this workflow is a **single apply pass**: no
two-pass portal-wins enumerate (the skip list is the static ADR 0036
baseline, not drift-derived), no drift-back PR (reverse drift is
issue-based via `sync-irm-from-tenant.yml`), and no verify-published step.
See the Tier-3 (export-incapable) surfaces carve-out in
[`.github/instructions/github-actions.instructions.md`](../../../.github/instructions/github-actions.instructions.md).

```pwsh
gh workflow run deploy-irm.yml
gh workflow run deploy-irm.yml -f irm_direction_policy=repo-wins -f confirm_overwrite_irm='overwrite portal'
```

### The retired monolithic step

[`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml) is the **only**
forward-apply path for IRM policies. The monolithic `deploy-data-plane.yml`,
which once carried a `Deploy IRM policies` step threading the same three
inputs, was retired by
[ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md):
it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap, so
it failed at startup and **never once executed** (90 runs, 0 successes, 0 jobs
scheduled). There is no "apply the whole data plane together" entry point, and a
`deploy-all.yml` orchestrator is explicitly deferred as greenfield
`workflow_call` work.

This surface is in fact ADR 0051's own Evidence 3: `deploy-irm.yml` exists
*because* a single-job monolith cannot apply one surface in isolation and goes
red on surfaces whose prerequisites are absent, destroying the forward-apply
evidence for the surface you actually wanted.

## Reverse drift-detection (Tier-3 — issue, not PR)

The forward apply leg above is paired with a reverse companion,
[`.github/workflows/sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml),
that watches for portal-only edits to the IRM policy surface. It runs
daily (08:00 UTC) plus on demand.

IRM is a **Tier-3** surface: `Deploy-IRMPolicies.ps1` exposes no
`-ExportCurrentState` (and no `-VerifyPublished`) switch, so — unlike
the sensitivity-label, auto-label, and DLP surfaces — the reverse leg
**cannot** round-trip tenant state back into
[`data-plane/irm/policies.yaml`](../../../data-plane/irm/policies.yaml)
as a re-export pull request. Instead it opens a GitHub **issue** so a
human reconciles by hand. The workflow declares
`permissions: issues: write` (no `pull-requests` scope).

How it detects drift, without the pitfalls of the retired generic
`drift-detection.yml`:

- **Audit mode, always.** The reconciler is invoked with
  `-DirectionPolicy audit`, which forces `$WhatIfPreference` so every
  `New-`/`Set-`/`Remove-InsiderRiskPolicy` short-circuits to its
  "Would …" branch. No write fires ([ADR 0029](../../adr/0029-source-of-truth-direction-policy.md)).
  It does **not** use `portal-wins -WhatIf`, which would mask an
  `Update` as a `Skip`.
- **Object-based, not text-scraped.** It captures the reconciler's
  returned `[pscustomobject]` rows from the success stream (stream 1)
  and filters on `.Category` / `.Name` / `.Reason`. Drift is any row
  whose `Category` is `Create`, `Update`, `Orphan`, or `Failed`. It
  never greps stdout/stderr and never relies on `2>&1`.
- **Skip baseline is a post-filter.** `-SkipNames` is inert in audit
  mode (the audit short-circuit runs before the ADR 0029 skip pass),
  so the workflow does **not** pass `-SkipNames`. It removes the
  [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) baseline
  names from the returned rows after the fact. The `skip_names_irm`
  input default mirrors the [`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
  default verbatim — the surviving two-way byte-lockstep.
- **Self-provisioned labels.** `gh issue create --label <name>` fails
  the whole call if a referenced label is missing (a fresh fork lacks
  `drift-detected`), so the issue step reads the existing label set and
  creates only the missing labels before creating the issue. The issue
  carries `drift-detected`, `needs-review`, and
  `squad:automation-engineer`.
- **Idempotent.** If an open IRM drift issue already exists, the run
  adds a refresh comment instead of opening a duplicate.

```pwsh
gh workflow run sync-irm-from-tenant.yml
```

## Related ADRs and runbooks

- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0036 — IRM tenant-setting immovable](../../adr/0036-irm-tenant-setting-immovable.md)
- [Runbook — IRM end-to-end smoke](../../runbooks/irm-end-to-end-smoke.md)
- Forward companion workflow (preferred): [`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
- Reverse companion workflow: [`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml)
- Sibling solution: [`records-management.md`](records-management.md)

## Follow-ups

- [#604](../../../../../issues/604) — Adopt live IRM Lab pilot policies into desired state (post-testing-window)
- [#605](../../../../../issues/605) — Author lab IRM policy in YAML (post-#603 decision)
- [#606](../../../../../issues/606) — Reconciler coverage for `InsiderRiskEntityList` and `Set-InsiderRiskPolicyLite`