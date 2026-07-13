# Audit log retention policies

Operational guide for [`scripts/Set-AuditRetentionPolicy.ps1`](../../../scripts/Set-AuditRetentionPolicy.ps1) — the reconciler that materializes [`data-plane/audit/retention-policies.yaml`](../../../data-plane/audit/retention-policies.yaml) against the Microsoft 365 unified audit log retention policy surface. Pairs with [`audit-log.md`](audit-log.md) (the tenant-scope ingestion toggle).

## Purpose

Compares each desired-state retention policy entry against the live tenant via [`Get-UnifiedAuditLogRetentionPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy), then emits Create / Update / NoChange decisions. Orphan policies (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied.

The retention model itself is documented at [Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies):

- Microsoft 365 E3 tenants get a built-in **180-day** retention for all audit events. No policy declaration is required to retain at the default.
- Microsoft 365 E5 (or E3 + Audit add-on) tenants can declare per-event-type policies with retention up to **10 years**.
- Tenant-supported `retentionDuration` enum values: `OneYear`, `ThreeYears`, `SevenYears`, `TenYears`.

## Default state

The shipped YAML declares an empty `policies: []` list. With no overrides declared, the built-in 180-day retention applies. The reconciler reports `Tenant policies : 0` / `Desired policies: 0` and exits without writes. Add the first declaration only when an explicit longer-retention policy is required.

## Authentication

Same Key Vault-side JWT signing path as [`audit-log.md`](audit-log.md) and every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT (header `alg=PS256`, `x5t#S256`) and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate's underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/audit/retention-policies.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant policies absent from YAML |
| `-Force` | switch — with `-ExportCurrentState`, allow overwriting a non-empty `policies:` block |
| `-ExportCurrentState` | switch — write tenant state back into YAML (round-trip) |
| `-SkipSchemaValidation` | switch — bypass the JSON Schema gate (emergency only) |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `Get-UnifiedAuditLogRetentionPolicy`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads `Get-UnifiedAuditLogRetentionPolicy`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Skip rows. No writes. |
| (default) | Same read, then per-row `New-UnifiedAuditLogRetentionPolicy` / `Set-UnifiedAuditLogRetentionPolicy` for Create / Update. Orphans skipped unless `-PruneMissing`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_audit_retention='overwrite portal'` token. |

## Schema

YAML conforms to [`data-plane/audit/retention-policies.schema.json`](../../../data-plane/audit/retention-policies.schema.json) (JSON Schema Draft-07). Each entry must declare `name` and `retentionDuration`, plus at least one of `recordTypes` / `operations` / `userIds` (enforced by the cmdlet's parameter contract). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Exchange `Organization Management` role group, or the legacy `Audit Logs` role | Tenant |
| Caller's identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow's `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network). The same `-Interactive` pattern applies; the data-plane app cert in Key Vault is bypassed.

## Smoke test

```pwsh
# Phase 1 / drift report. Safe to run before any change. Default state
# expects `Desired policies: 0` / `Tenant policies : 0` -- no drift.
./scripts/Set-AuditRetentionPolicy.ps1 -WhatIf
```

Expected output tail when YAML is the default empty list:

```text
Desired policies: 0
Tenant policies : 0
```

## CI wiring

> **No automated apply path yet.** No per-solution workflow owns audit retention, so merging `data-plane/audit/**` applies nothing on its own. **Interim apply path: run [`scripts/Set-AuditRetentionPolicy.ps1`](../../../scripts/Set-AuditRetentionPolicy.ps1) locally.** The monolithic `deploy-data-plane.yml` that once carried a `Set audit retention policies` step (inputs `audit_retention_direction_policy`, `confirm_overwrite_audit_retention`, `skip_names_audit_retention`) was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled), so that step never applied anything. Nothing was lost. Backfilling a `deploy-audit-retention.yml` is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## ADR 0029 contract

This reconciler conforms to [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md). The script accepts `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>`. **The `overwrite portal` typed-confirmation gate on `repo-wins` was a workflow pre-flight step, not a script parameter** — running the reconciler locally, `-DirectionPolicy repo-wins` is destructive with no typed-confirmation prompt, so preview with `-DirectionPolicy audit` first. Restoring that gate is part of the per-solution workflow backfill ([#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80)).

## References

- [Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies)
- [`New-UnifiedAuditLogRetentionPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-unifiedauditlogretentionpolicy)
- [`Get-UnifiedAuditLogRetentionPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy)
- [`Set-UnifiedAuditLogRetentionPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-unifiedauditlogretentionpolicy)
- [`Remove-UnifiedAuditLogRetentionPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-unifiedauditlogretentionpolicy)
- [Audited activities (operation names)](https://learn.microsoft.com/en-us/purview/audit-log-activities)
- [AuditLogRecordType enum](https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-schema#auditlogrecordtype)
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)