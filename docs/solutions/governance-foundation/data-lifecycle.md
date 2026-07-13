# Data Lifecycle Management — retention policies

Operational guide for [`scripts/Deploy-RetentionPolicies.ps1`](../../../scripts/Deploy-RetentionPolicies.ps1) — the reconciler that materializes [`data-plane/data-lifecycle/retention-policies.yaml`](../../../data-plane/data-lifecycle/retention-policies.yaml) against the Microsoft 365 Data Lifecycle Management surface (retention compliance policies + retention compliance rules). Pairs with [`audit-log.md`](audit-log.md) (the tenant-scope ingestion toggle audit retention depends on) and [`audit-retention.md`](audit-retention.md) (the audit log retention surface).

## Purpose

Reconciles two cmdlet families in lockstep:

- [`*-RetentionCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy) — the policy header (name, enabled state, per-workload location buckets, RestrictiveRetention / Preservation Lock).
- [`*-RetentionComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule) — the child rules (retention duration, retention action, optional KQL `contentMatchQuery`, optional `expirationDateOption`).

Emits Create / Update / NoChange / Orphan decisions per (policy, rule) pair. Orphan policies and rules (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied.

The retention model is documented at [Learn about retention policies](https://learn.microsoft.com/en-us/purview/retention):

- Up to **9** location buckets per policy: `exchange`, `sharePoint`, `oneDrive`, `modernGroup`, `skype`, `teamsChannel`, `teamsChat`, `teamsPrivateChannel`, `publicFolder`. Use the literal string `'All'` to scope a bucket tenant-wide; otherwise list explicit identities (UPNs, group names, site URLs).
- `retentionDuration` accepts either an integer day count or the string sentinel `'Unlimited'`.
- `retentionAction` is one of `Keep` / `Delete` / `KeepAndDelete`.
- `RestrictiveRetention` enables [Preservation Lock](https://learn.microsoft.com/en-us/purview/retention-preservation-lock) and is **irreversible**. The reconciler honours the YAML declaration; flipping it to `true` cannot be undone via this script.

## Default state

The shipped YAML declares an empty `policies: []` list. With no policies declared, no DLM retention is enforced. The reconciler reports `Desired policies: 0` / `Tenant policies : 0` / `Tenant rules : 0` and exits without writes. Add the first declaration only when an explicit retention requirement applies.

## Authentication

Same Key Vault-side JWT signing path as every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT (header `alg=PS256`, `x5t#S256`) and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate''s underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/data-lifecycle/retention-policies.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant policies and rules |
| `-Force` | switch — with `-ExportCurrentState`, allow overwriting non-empty `policies:` |
| `-ExportCurrentState` | switch — write tenant state back into YAML (round-trip) |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — ADR 0029 source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-SkipSchemaValidation` | switch — bypass the JSON Schema gate (emergency only) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | Reads `Get-RetentionCompliancePolicy` + `Get-RetentionComplianceRule`; prints planned Create / Update / NoChange / Orphan rows for both policies and rules. No writes. |
| (default) | Same read, then per-row `New-` / `Set-RetentionCompliancePolicy` and `New-` / `Set-RetentionComplianceRule` for Create / Update. Orphans skipped unless `-PruneMissing`. Every write is gated by `$PSCmdlet.ShouldProcess`. |

## Schema

YAML conforms to [`data-plane/data-lifecycle/retention-policies.schema.json`](../../../data-plane/data-lifecycle/retention-policies.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Compliance Administrator` (or `Retention Management` role group) | Tenant |
| Caller''s identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow''s `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network). The same pattern applies.

## Smoke test

```pwsh
# Phase 1 / drift report. Safe to run before any change. Default state
# expects 0 / 0 / 0 -- no drift.
./scripts/Deploy-RetentionPolicies.ps1 -WhatIf
```

Expected output tail when YAML is the default empty list:

```text
Desired policies: 0
Tenant policies : 0
Tenant rules    : 0
```

For an end-to-end live-tenant smoke (Create → Update → Round-trip →
Orphan → Prune lifecycle), follow [`docs/runbooks/dlm-end-to-end-smoke.md`](../../runbooks/dlm-end-to-end-smoke.md).

## CI wiring

> **No automated apply path yet.** No per-solution workflow owns retention / data lifecycle management, so merging `data-plane/retention/**` applies nothing on its own. **Interim apply path: run [`scripts/Deploy-RetentionPolicies.ps1`](../../../scripts/Deploy-RetentionPolicies.ps1) locally.** The monolithic `deploy-data-plane.yml` that once carried a `Deploy retention policies` step (inputs `retention_direction_policy`, `confirm_overwrite_retention`, `skip_names_retention`) was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled), so that step never applied anything. Nothing was lost. Backfilling a `deploy-retention.yml` is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

The script-side ADR 0029 contract is unaffected and remains the live surface: pass `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>` on the local command line. **The typed `overwrite portal` confirmation that gated `repo-wins` was a workflow pre-flight step, not a script parameter** — locally, `-DirectionPolicy repo-wins` is destructive with no prompt, so preview with `-DirectionPolicy audit` first. With desired state at `policies: []` the apply is a no-op regardless; the contract is scaffolding for the day the first retention policy is declared.

## ADR 0029 source-of-truth direction policy

The reconciler honours the [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy via the shared decision helper at [`scripts/modules/DirectionPolicy.psm1`](../../../scripts/modules/DirectionPolicy.psm1):

| Mode | Behaviour for shared-property drift |
|---|---|
| `audit` | Emits the `[ADR0029-AUDIT]` marker, flips `$WhatIfPreference = $true`, and lets every `ShouldProcess` call fall into its `Would …` branch. No writes under any condition. |
| `portal-wins` (default) | Skips every policy and rule whose tracked fields differ; emits a `Skip` plan row plus a `[ADR0029-SKIP] <name>` marker per skipped object for the upstream workflow to collect into an auto-PR. |
| `repo-wins` | Applies the full plan including drift; emits one `Write-Warning` per overwritten policy / rule naming the drifted field set. Typed-confirmation (`overwrite portal`) is enforced at the CI layer. |

`Create`, `NoChange`, and `Orphan` plan rows are unaffected by the direction policy. Orphan removal is gated by `-PruneMissing`, not by the direction-policy contract. The `-SkipNames` switch matches case-insensitively against the policy `Name` (for policy-level entries) and the rule `Name` (for rule-level entries); composite `Policy\Rule` keys are not matched.

## Pester coverage

Unit tests for the eight AST-extractable helper functions live at [`tests/scripts/Deploy-RetentionPolicies.Tests.ps1`](../../../tests/scripts/Deploy-RetentionPolicies.Tests.ps1) and cover hashtable normalization, drift detection (YAML-declared-fields-only), and splat-building for both `New-` and `Set-` cmdlet forms. Synthetic inputs only; no live-tenant calls.

## References

- [Learn about Microsoft Purview Data Lifecycle Management](https://learn.microsoft.com/en-us/purview/data-lifecycle-management)
- [Learn about retention policies](https://learn.microsoft.com/en-us/purview/retention)
- [`New-RetentionCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy)
- [`Get-RetentionCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy)
- [`Set-RetentionCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy)
- [`Remove-RetentionCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancepolicy)
- [`New-RetentionComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule)
- [`Get-RetentionComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule)
- [`Set-RetentionComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancerule)
- [Preservation Lock for retention policies](https://learn.microsoft.com/en-us/purview/retention-preservation-lock)
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)