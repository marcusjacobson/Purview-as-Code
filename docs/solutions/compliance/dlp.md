# Microsoft Purview Data Loss Prevention

Operational guide for [`scripts/Deploy-DLPPolicies.ps1`](../../../scripts/Deploy-DLPPolicies.ps1), the reconciler that materializes [`data-plane/dlp/policies.yaml`](../../../data-plane/dlp/policies.yaml) against [Microsoft Purview Data Loss Prevention](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp) (DLP).

## Purpose

The reconciler manages Microsoft Purview Data Loss Prevention policies and their nested rules through Security & Compliance PowerShell. It reads every declared policy and rule, compares them to the live tenant by policy name and rule name, then emits categorized plan rows: `Create`, `Update`, `NoChange`, `Orphan`, and `Skip`.

Orphan policies and rules are reported but not removed unless `-PruneMissing` is supplied. Shared-property drift follows the ADR 0029 direction policy: `audit` is read-only, `portal-wins` skips shared drift, and `repo-wins` overwrites tenant fields from YAML after review.

## Default state

The shipped YAML is an exported DLP baseline with `policies:` entries. Each policy entry can carry `name`, `description`, `mode`, `priority`, workload `locations`, `genericLocations`, `enforcementPlanes`, and nested `rules`. Each rule can carry sensitive information type references, sensitivity-label references, `advancedRule`, notification fields, endpoint restrictions, alert properties, and other tracked fields ratified by ADRs 0031 through 0033.

Do not add tenant IDs, object IDs, UPNs, or real sample payloads to this file. Use Microsoft-published SIT identifiers already present in the catalog or the zero-GUID placeholder where a tenant-specific identifier would otherwise appear.

## Authentication

This surface uses Security & Compliance PowerShell, not the Microsoft Purview Data Map REST token path. Locally, the script expects an active `az login` session and uses the lab automation identity to sign an app-only token with the Key Vault certificate resolved from `infra/parameters/lab.yaml`. In CI, [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) runs the same script inside the Key Vault open/close window.

The script resolves `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, and `-TenantDomain` from the parameters file when they are not passed explicitly.

## Inputs

| Parameter | Default / meaning |
|---|---|
| `-Path` | `data-plane/dlp/policies.yaml` |
| `-PruneMissing` | Destructive switch; removes tenant policies or rules absent from YAML. Preview with `-WhatIf` first. |
| `-Force` | With `-ExportCurrentState`, allows overwriting a non-empty `policies:` block. |
| `-ExportCurrentState` | Reads live DLP policies and rules, writes the YAML `policies:` block, and exits. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-VaultName` | Key Vault containing the automation certificate; resolved from `-ParametersFile` when omitted. |
| `-CertificateName` | Key Vault certificate and key object; resolved from `-ParametersFile` when omitted. |
| `-DataPlaneAppDisplayName` | Microsoft Entra ID data-plane app display name; resolved from `-ParametersFile` when omitted. |
| `-TenantDomain` | Tenant primary domain passed to `Connect-IPPSSession`; resolved from `-ParametersFile` when omitted. |
| `-DirectionPolicy` | `audit`, `portal-wins` (default), or `repo-wins`. |
| `-SkipNames` | Case-insensitive policy or rule names to skip during `portal-wins`; ignored in `audit`. |
| `-SkipSchemaValidation` | Bypasses JSON Schema validation. Do not use in CI. |
| `-WhatIf` | Supported by `SupportsShouldProcess`; previews writes without changing the tenant. |

## Manage DLP with this repo

1. Export the live state when starting from portal-authored changes.

   ```pwsh
   $env:PURVIEW_ACCOUNT_NAME = 'purview-contoso-lab'
   ./scripts/Deploy-DLPPolicies.ps1 `
     -ParametersFile ./infra/parameters/lab.yaml `
     -ExportCurrentState `
     -Force
   ```

1. Edit [`data-plane/dlp/policies.yaml`](../../../data-plane/dlp/policies.yaml). Add or change policy fields in YAML, keep `mode` simulation-first unless the change is explicitly ready for enforcement, and model advanced predicates with ADR 0031 `advancedRule` and ADR 0032 `genericLocations` shapes.

1. Preview before any apply.

   ```pwsh
   ./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy audit
   ./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy portal-wins -WhatIf
   ./scripts/Deploy-DLPPolicies.ps1 -PruneMissing -WhatIf
   ```

1. Apply locally only after reviewing the plan.

   ```pwsh
   ./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy portal-wins
   ```

   Use `repo-wins` only when the PR and operator evidence explicitly approve overwriting tenant fields:

   ```pwsh
   ./scripts/Deploy-DLPPolicies.ps1 -DirectionPolicy repo-wins -WhatIf
   ```

1. Apply through the data-plane workflow after the PR is reviewed.

   ```pwsh
   gh workflow run deploy-data-plane.yml `
     -f dlp_direction_policy=portal-wins `
     -f skip_names_dlp=''
   ```

   For `repo-wins`, the workflow requires the typed confirmation token:

   ```pwsh
   gh workflow run deploy-data-plane.yml `
     -f dlp_direction_policy=repo-wins `
     -f confirm_overwrite_dlp='overwrite portal'
   ```

1. Verify with the [DLP end-to-end smoke runbook](../../runbooks/dlp-end-to-end-smoke.md). At minimum, rerun `-WhatIf` and confirm the plan returns only `NoChange` or documented `Skip` rows.

## References

- **[Learn about data loss prevention](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp)**
  Fetch date: 2026-06-20
  > "In Microsoft Purview, you implement data loss prevention by defining and applying DLP policies."
- **[Get-DlpCompliancePolicy](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-dlpcompliancepolicy?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-DlpCompliancePolicy to view data loss prevention (DLP) policies in the Microsoft Purview compliance portal."
- **[Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Connect-IPPSSession cmdlet in the Exchange Online PowerShell module to connect to Security & Compliance PowerShell using modern authentication."
- **[App-only authentication in Exchange Online PowerShell and Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Certificate based authentication (CBA) or app-only authentication as described in this article supports unattended script and automation scenarios"
- [ADR 0031 — DLP AdvancedRule YAML shape](../../adr/0031-dlp-advancedrule-yaml-shape.md)
- [ADR 0032 — DLP generic Locations YAML shape](../../adr/0032-dlp-generic-locations-shape.md)
- [ADR 0033 — DLP rule tracked-field expansion](../../adr/0033-dlp-rule-tracked-field-expansion.md)
