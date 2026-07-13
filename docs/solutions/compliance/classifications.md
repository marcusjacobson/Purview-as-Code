# Sensitive information types and custom classifications

Operational guide for the classification surfaces in this repo: [`scripts/Sync-SITCatalog.ps1`](../../../scripts/Sync-SITCatalog.ps1) exports [`data-plane/classifications/sit-catalog.yaml`](../../../data-plane/classifications/sit-catalog.yaml), [`scripts/Deploy-Classifications.ps1`](../../../scripts/Deploy-Classifications.ps1) reconciles [`data-plane/classifications/classifications.yaml`](../../../data-plane/classifications/classifications.yaml), and [`scripts/Invoke-SITConfidenceAnalysis.ps1`](../../../scripts/Invoke-SITConfidenceAnalysis.ps1) analyzes exported signal volume. Microsoft Learn entry points are [Sensitive Information Type (SIT) entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions) and [custom classifications in Microsoft Purview Data Map](https://learn.microsoft.com/en-us/purview/data-map-classification-custom).

## Purpose

This page covers three related but distinct operations:

- `Sync-SITCatalog.ps1` exports the Microsoft Purview Sensitive Information Type catalog through Security & Compliance PowerShell. It is an export-only catalog view for downstream Data Loss Prevention (DLP), label, and auto-label references.
- `Deploy-Classifications.ps1` reconciles custom Data Map classification typedefs and scanning classification rules through Microsoft Purview REST APIs. It plans `Create`, `Update`, `NoChange`, `Orphan`, and `Conflict` rows.
- `Invoke-SITConfidenceAnalysis.ps1` is local-only. It reads Content Explorer export artifacts and the SIT catalog, then writes a Markdown and CSV signal-volume report.

Regex classification rules must stay anchored, bounded, and synthetic. Do not paste real sample values or real data rows into YAML, docs, issues, or PR descriptions.

## Default state

[`classifications.yaml`](../../../data-plane/classifications/classifications.yaml) ships with a synthetic custom classification and a regex rule for `EMP-####` employee identifiers. The pattern is anchored with word boundaries, uses bounded repetition, and includes a bounded column-name pattern.

[`sit-catalog.yaml`](../../../data-plane/classifications/sit-catalog.yaml) is the exported SIT catalog. Microsoft built-in identifiers are public catalog references; tenant-real publisher, tenant, subscription, and object identifiers are redacted to `00000000-0000-0000-0000-000000000000`.

## Authentication

Custom classification typedefs and rules use Microsoft Purview Data Map and Scanning REST APIs. `Deploy-Classifications.ps1` accepts `-AccountName` / `-PurviewAccountName`, then uses the same Data Map token path as the other REST reconcilers.

The SIT catalog export uses Security & Compliance PowerShell. `Sync-SITCatalog.ps1` resolves the lab Key Vault, certificate, Microsoft Entra ID app display name, and tenant domain from `infra/parameters/lab.yaml`, signs an app-only token, and connects with `Connect-IPPSSession`.

The confidence analyzer is local-only because it reads files already exported to disk.

## Inputs

### `Deploy-Classifications.ps1`

| Parameter | Default / meaning |
|---|---|
| `-Path` | `data-plane/classifications/classifications.yaml` |
| `-PruneMissing` | Destructive switch; removes tenant custom types or rules absent from YAML. Preview with `-WhatIf` first. |
| `-Force` | Allows conflict overwrite and allows export over a non-empty YAML file. |
| `-ExportCurrentState` | Exports live custom classifications and rules to YAML, then exits. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-AccountName` / `-PurviewAccountName` | Microsoft Purview account name, for example `purview-contoso-lab`. |
| `-WhatIf` | Supported by `SupportsShouldProcess`; previews writes without changing the tenant. |

### `Sync-SITCatalog.ps1`

| Parameter | Default / meaning |
|---|---|
| `-Path` | `data-plane/classifications/sit-catalog.yaml` |
| `-Force` | With `-ExportCurrentState`, allows overwriting a non-empty `sits:` block. |
| `-ExportCurrentState` | Mandatory for export; writes every visible SIT to YAML and exits. |
| `-ParametersFile` | `infra/parameters/lab.yaml` resolved from repo root. |
| `-VaultName` | Key Vault containing the automation certificate; resolved from `-ParametersFile` when omitted. |
| `-CertificateName` | Key Vault certificate and key object; resolved from `-ParametersFile` when omitted. |
| `-DataPlaneAppDisplayName` | Microsoft Entra ID data-plane app display name; resolved from `-ParametersFile` when omitted. |
| `-TenantDomain` | Tenant primary domain passed to `Connect-IPPSSession`; resolved from `-ParametersFile` when omitted. |
| `-WhatIf` | Prints the planned auth path and target file without remote calls. |

### `Invoke-SITConfidenceAnalysis.ps1`

| Parameter | Default / meaning |
|---|---|
| `-ExportRoot` | Parent folder containing Content Explorer export run directories. |
| `-RunDirectory` | Specific export run directory with `manifest.json`; overrides `-ExportRoot`. |
| `-SitCatalogPath` | `data-plane/classifications/sit-catalog.yaml` |
| `-OutputRoot` | Parent folder for generated Markdown and CSV reports. |
| `-MinHits` | Inclusive lower bound for the `Retain` recommendation; default `5`. |
| `-CustomOnly` | Filters output to custom SIT rows. |
| `-WhatIf` | Emits report rows without writing files. |

## Manage classifications with this repo

1. Export the current state.

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 `
     -AccountName purview-contoso-lab `
     -ExportCurrentState

   ./scripts/Sync-SITCatalog.ps1 `
     -ParametersFile ./infra/parameters/lab.yaml `
     -ExportCurrentState `
     -Force
   ```

1. Edit [`classifications.yaml`](../../../data-plane/classifications/classifications.yaml) for custom classifications and regex rules. Keep SIT catalog changes export-driven unless a follow-up PR implements custom SIT write-back.

   ```yaml
   classifications:
     - name: CUSTOM.EmployeeId
       description: Synthetic employee identifier such as EMP-1234.

   rules:
     - name: CUSTOM.EmployeeIdRule
       classificationName: CUSTOM.EmployeeId
       kind: Regex
       regex:
         pattern: '\bEMP-\d{4}\b'
   ```

   Synthetic test values such as `EMP-1234`, `123-45-6789`, and `4111 1111 1111 1111` are acceptable in examples. Real names, inboxes, account numbers, and datasets are not.

1. Preview the plan.

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 `
     -AccountName purview-contoso-lab `
     -WhatIf

   ./scripts/Sync-SITCatalog.ps1 `
     -ExportCurrentState `
     -WhatIf

   ./scripts/Invoke-SITConfidenceAnalysis.ps1 `
     -CustomOnly `
     -WhatIf
   ```

1. Apply custom classifications locally after reviewing the plan.

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab
   ```

   To remove tenant-only custom classifications or rules, preview first and treat the apply as destructive:

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 `
     -AccountName purview-contoso-lab `
     -PruneMissing `
     -WhatIf
   ```

1. Apply locally — **there is no automated apply path for custom classifications.**

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab
   ```

   No per-solution workflow owns this surface, so merging `data-plane/classifications/**` applies nothing on its own; the reconciler must be run from your workstation. `Sync-SITCatalog.ps1` and `Invoke-SITConfidenceAnalysis.ps1` are likewise local/operator-run. Backfilling a `deploy-classifications.yml` is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80); see [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md).

1. Verify classification drift and SIT signal.

   ```pwsh
   ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -WhatIf
   ./scripts/Invoke-SITConfidenceAnalysis.ps1 -CustomOnly
   ```

   Use the [SIT confidence analysis runbook](../../runbooks/sit-confidence-analysis.md) before retiring or retuning a custom SIT.

## References

- **[Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions)**
  Fetch date: 2026-06-20
  > "This article is a list of all sensitive information type (SIT) entity definitions."
- **[Custom classifications in Microsoft Purview Data Map](https://learn.microsoft.com/en-us/purview/data-map-classification-custom)**
  Fetch date: 2026-06-20
  > "This article describes how you can create custom classifications in Microsoft Purview Data Map"
- **[Get-DlpSensitiveInformationType](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-dlpsensitiveinformationtype?view=exchange-ps)**
  Fetch date: 2026-06-20
  > "Use the Get-DlpSensitiveInformationType cmdlet to list the sensitive information types that are defined for your organization"
- **[API authentication for Microsoft Purview data planes](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)**
  Fetch date: 2026-06-20
  > "In this tutorial, you learn how to authenticate for the Microsoft Purview data plane APIs."
- **[Get started with content explorer](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)**
  Fetch date: 2026-06-20
  > "Content Explorer (classic) lets you natively view the items summarized on the overview page."
- [ADR 0026 — Glossary and custom-classifications reconcilers](../../adr/0026-glossary-custom-classifications-reconciler.md)
- [Sample-data regex rules](../../../.github/instructions/sample-data.instructions.md)
