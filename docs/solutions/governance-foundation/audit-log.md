# Unified Audit Log

Operational guide for [`scripts/Enable-UnifiedAuditLog.ps1`](../../../scripts/Enable-UnifiedAuditLog.ps1) — the tenant-scope toggle that enables Microsoft 365 Unified Audit Log ingestion. Every Purview solution that depends on audit search (Insider Risk, Communication Compliance, DSPM, retention enforcement) requires this flag to be on.

## Purpose

Sets `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` on the tenant and verifies the change with `Get-AdminAuditLogConfig`. Per [Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable) the `Set-AdminAuditLogConfig` cmdlet is exposed by the Exchange Online endpoint, not the Security & Compliance endpoint.

## Authentication

Authenticates via the Key Vault-side JWT signing path defined by [ADR 0011 decision §3](../../adr/0011-certificate-lifecycle.md) (the supersession addendum):

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT (header `alg=PS256`, `x5t#S256`) and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate's underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-ExchangeOnline -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline) (added in `ExchangeOnlineManagement` v3.7.0+).

The same `https://outlook.office365.com/.default` access token works for both Exchange Online and Security & Compliance PowerShell.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-Revoke` | switch — flip the flag to `$false` (emergency disable) |
| `-Interactive` | switch — connect as the calling user via browser MFA; skips Key Vault. See [Local-dev runs from outside the Key Vault network](#local-dev-runs-from-outside-the-key-vault-network) |
| `-UserPrincipalName` | optional UPN for `-Interactive`; defaults to `az account show --query user.name` |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | Prints planned behaviour. No Graph / Key Vault / S&C PowerShell calls. |
| (default) | Reads current state with `Get-AdminAuditLogConfig`. If already in the desired state: single-row `NoChange`. Else: `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled <bool>`, then re-read to confirm. |

Drift shape: a single `Create / NoChange / Revoke / NoOp` row. `Update / Orphan / Conflict` do not apply — this is a scalar tenant flag.

## Propagation caveat

Per the [`Set-AdminAuditLogConfig` Learn page](https://learn.microsoft.com/en-us/powershell/module/exchange/set-adminauditlogconfig), the flag may take up to 60 minutes to fully propagate across Microsoft 365 services. The read-back verification confirms the tenant config object reports the new value immediately; downstream search-ingestion lag is expected.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Exchange `Organization Management` role group, or the legacy `Audit Logs` role | Tenant |
| Caller's identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo), [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only: workflow → KV `keys/sign` (private endpoint) → JWT assertion → Exchange Online access token. That path requires the workstation to reach `kv-contoso-lab-01`, which is `publicNetworkAccess: Disabled` per the lab's baseline posture ([Microsoft Purview security best practices — credential management](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management)).

For local-dev runs from a workstation outside the approved network, use `-Interactive` to connect as the calling user via browser MFA. This bypasses the KV entirely.

```pwsh
# Drift report (no writes; safe to run before any change).
./scripts/Enable-UnifiedAuditLog.ps1 -WhatIf -Interactive

# Re-confirm the flag and (if needed) set it.
./scripts/Enable-UnifiedAuditLog.ps1 -Interactive
```

Behavior:

- Skips `Get-PurviewIPPSAccessToken.ps1` and `az ad app list`. Makes zero Key Vault calls.
- Calls `Connect-ExchangeOnline -UserPrincipalName <UPN>` ([Learn](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline)). MSAL opens a browser sign-in with MFA.
- UPN defaults to `az account show --query user.name -o tsv`; pass `-UserPrincipalName` to override.
- Tenant-side audit logs attribute writes to your user identity, not the workload app.
- Requires your user to hold Exchange `Organization Management` (or the legacy `Audit Logs` role) to run `Set-AdminAuditLogConfig`.

**CI must not use `-Interactive`.** Any workflow that runs this reconciler runs unattended, so the switch is rejected by review on any change that introduces it into `.github/workflows/**`.

> **No automated apply path yet.** No per-solution workflow owns the unified audit log, so nothing applies this surface in CI today. **Interim apply path: run [`scripts/Enable-UnifiedAuditLog.ps1`](../../../scripts/Enable-UnifiedAuditLog.ps1) locally** (with `-Interactive` if you are signing in as yourself). The monolithic `deploy-data-plane.yml` that once claimed this surface was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled). Nothing was lost: the apply path it advertised did not exist. Backfilling a per-solution workflow is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## Smoke test

```pwsh
./scripts/Get-PurviewIPPSAccessToken.ps1 | Connect-ExchangeOnline -AccessToken $_ -Organization 'contoso.onmicrosoft.com'
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
Disconnect-ExchangeOnline -Confirm:$false
```

Expected: `UnifiedAuditLogIngestionEnabled : True`.

## References

- [Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable)
- [`Set-AdminAuditLogConfig`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-adminauditlogconfig)
- [`Get-AdminAuditLogConfig`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig)
- [`Connect-ExchangeOnline`](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline)
- [App-only auth for Exchange / S&C PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2)
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
