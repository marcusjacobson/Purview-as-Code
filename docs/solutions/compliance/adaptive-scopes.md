# Microsoft Purview adaptive scopes

Operational guide for [`scripts/Deploy-AdaptiveScopes.ps1`](../../../scripts/Deploy-AdaptiveScopes.ps1), [`scripts/New-AdaptiveScope.ps1`](../../../scripts/New-AdaptiveScope.ps1), and [`data-plane/adaptive-scopes/scopes.yaml`](../../../data-plane/adaptive-scopes/scopes.yaml). Microsoft Learn documents [adaptive scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes) as reusable query-based scope objects for compliance policies.

## Purpose

`Deploy-AdaptiveScopes.ps1` reconciles adaptive policy scopes that retention, Data Loss Prevention (DLP), Insider Risk Management, and sensitivity-label policies can reference by name. It reads live scopes with `Get-AdaptiveScope`, compares tracked fields, and emits `Create`, `Update`, `NoChange`, `Orphan`, `Blocked`, and `Skip` rows.

`LocationType` is immutable. A desired scope whose `locationType` differs from the tenant readback is `Blocked`, not updated in place. `filterConditions` is a JSON string passed through to the cmdlet, validated only for well-formed JSON before the server validates the filter shape.

`New-AdaptiveScope.ps1` is a narrow one-shot helper for creating a single scope during operator testing. Prefer the declarative reconciler for steady state.

## Default state

[`scopes.yaml`](../../../data-plane/adaptive-scopes/scopes.yaml) ships with one synthetic example entry named `lab-as-mailbox-example`. It uses `locationType: User` and a JSON-string `filterConditions` value with the synthetic alias `example`.

Edit, replace, or remove the example before any live apply. Do not commit real UPNs, object IDs, or tenant-specific filter values. If a tenant-side `New-AdaptiveScope` error occurs during apply, stop and capture the sanitized error; ADR 0034 documents the known first-apply blocker.

## Authentication

Adaptive scopes use Security & Compliance PowerShell. Locally, the scripts expect an active `az login` session and either the configured local certificate transport or the Key Vault certificate signing path. `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, and `-TenantDomain` resolve from `infra/parameters/lab.yaml` when omitted.

`Deploy-DLPPolicies.ps1` resolves adaptive-scope references by name during DLP apply, so create or export scopes before applying a DLP policy that depends on them.

## Inputs

### `Deploy-AdaptiveScopes.ps1`

| Parameter | Default / meaning |
|---|---|
| `-Path` | `data-plane/adaptive-scopes/scopes.yaml` |
| `-PruneMissing` | Destructive switch; removes tenant scopes absent from YAML. Preview with `-WhatIf` first. |
| `-Force` | With `-ExportCurrentState`, allows overwriting a non-empty `scopes:` block. |
| `-ExportCurrentState` | Reads live adaptive scopes, writes the YAML `scopes:` block, and exits. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-VaultName` | Key Vault containing the automation certificate; resolved from `-ParametersFile` when omitted. |
| `-CertificateName` | Key Vault certificate and key object; resolved from `-ParametersFile` when omitted. |
| `-DataPlaneAppDisplayName` | Microsoft Entra ID data-plane app display name; resolved from `-ParametersFile` when omitted. |
| `-TenantDomain` | Tenant primary domain passed to `Connect-IPPSSession`; resolved from `-ParametersFile` when omitted. |
| `-DirectionPolicy` | `audit`, `portal-wins` (default), or `repo-wins`. |
| `-SkipNames` | Scope names to skip during `portal-wins`; ignored in `audit`. |
| `-SkipSchemaValidation` | Bypasses JSON Schema validation. Do not use in CI. |
| `-WhatIf` | Supported by `SupportsShouldProcess`; previews writes without changing the tenant. |

### `New-AdaptiveScope.ps1`

| Parameter | Default / meaning |
|---|---|
| `-Name` | Required; `lab-as-` prefixed scope name. |
| `-LocationType` | Required; `User`, `Group`, or `Site`. |
| `-FilterConditions` | Required hashtable passed to `New-AdaptiveScope`; use only synthetic values in examples. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-VaultName` | Key Vault containing the automation certificate; resolved from `-ParametersFile` when omitted. |
| `-CertificateName` | Key Vault certificate and key object; resolved from `-ParametersFile` when omitted. |
| `-DataPlaneAppDisplayName` | Microsoft Entra ID data-plane app display name; resolved from `-ParametersFile` when omitted. |
| `-TenantDomain` | Tenant primary domain passed to `Connect-IPPSSession`; resolved from `-ParametersFile` when omitted. |
| `-WhatIf` | Supported by `SupportsShouldProcess`; previews the single-scope create. |

## Manage adaptive scopes with this repo

1. Export the live scope inventory.

   ```pwsh
   $env:PURVIEW_ACCOUNT_NAME = 'purview-contoso-lab'
   ./scripts/Deploy-AdaptiveScopes.ps1 `
     -ParametersFile ./infra/parameters/lab.yaml `
     -ExportCurrentState `
     -Force
   ```

1. Edit [`scopes.yaml`](../../../data-plane/adaptive-scopes/scopes.yaml). Keep `filterConditions` as a JSON string per ADR 0034.

   ```yaml
   scopes:
     - name: lab-as-mailbox-example
       locationType: User
       filterConditions: '{"Conjunction":"And","Conditions":[{"Name":"Alias","Value":"example","Operator":"Equals"}]}'
       comment: Synthetic example; replace before live apply.
   ```

1. Preview the reconciler plan.

   ```pwsh
   ./scripts/Deploy-AdaptiveScopes.ps1 -DirectionPolicy audit
   ./scripts/Deploy-AdaptiveScopes.ps1 -DirectionPolicy portal-wins -WhatIf
   ./scripts/Deploy-AdaptiveScopes.ps1 -PruneMissing -WhatIf
   ```

1. Apply locally only after reviewing the plan and confirming any tenant-side blocker is resolved.

   ```pwsh
   ./scripts/Deploy-AdaptiveScopes.ps1 -DirectionPolicy portal-wins
   ```

   For one-off operator testing, the helper accepts a hashtable and still supports `-WhatIf`:

   ```pwsh
   ./scripts/New-AdaptiveScope.ps1 `
     -Name lab-as-mailbox-example `
     -LocationType User `
     -FilterConditions @{
       Conditions = @(
         @{ Name = 'Alias'; Operator = 'Equals'; Value = 'example' }
       )
       Conjunction = 'And'
     } `
     -WhatIf
   ```

1. Do not rely on [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) for adaptive scopes today. The workflow does not currently run `Deploy-AdaptiveScopes.ps1`. A future CI wiring PR should mirror the DLP direction-policy inputs and keep `-PruneMissing` off by default.

1. Verify with another read-only plan.

   ```pwsh
   ./scripts/Deploy-AdaptiveScopes.ps1 -DirectionPolicy audit
   ./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy audit
   ```

   There is no adaptive-specific smoke runbook in this repo yet. Use the DLP audit pass to verify DLP policies that reference adaptive scopes still resolve by name.

## References

- **[Adaptive scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes)**
  Fetch date: 2026-06-20
  > "An adaptive scope uses a query that you specify"
- **[Configure Microsoft 365 retention settings](https://learn.microsoft.com/en-us/purview/retention-settings#adaptive-or-static-policy-scopes-for-retention)**
  Fetch date: 2026-06-20
  > "When you've decided whether to use an adaptive or static scope, use the following information to help you configure it:"
- **[New-AdaptiveScope](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-adaptivescope?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the New-AdaptiveScope cmdlet to create adaptive scopes in your organization."
- **[Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Connect-IPPSSession cmdlet in the Exchange Online PowerShell module to connect to Security & Compliance PowerShell using modern authentication."
- **[App-only authentication in Exchange Online PowerShell and Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Certificate based authentication (CBA) or app-only authentication as described in this article supports unattended script and automation scenarios"
- [ADR 0034 — Microsoft Purview adaptive scope schema](../../adr/0034-adaptive-scope-schema.md)
