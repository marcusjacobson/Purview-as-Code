# Unified Catalog

Operational guide for [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) — the live
Unified Catalog reconciler for the five preview API operation groups this repo currently manages under
[`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/): business domains, data products, objectives and
key results, critical data elements, and glossary terms. The script reads and writes the
`2026-03-20-preview` Unified Catalog REST surface documented on Microsoft Learn.

## Purpose

This reconciler now applies the live preview surface adopted by
[ADR 0047](../../adr/0047-unified-catalog-preview-api-coexistence.md) and grounded by
[ADR 0048](../../adr/0048-purview-account-discovery-gate.md). It:

1. Validates the desired-state YAML files against their Draft-07 schemas.
2. Reads live tenant state from the tenant-scoped Unified Catalog endpoint
   `https://api.purview-service.microsoft.com`.
3. Emits a categorized drift report (`Create`, `Update`, `NoChange`, `Orphan`, `Conflict`).
4. Applies per-item create/update/delete writes behind `SupportsShouldProcess`.
5. Supports `-ExportCurrentState` to round-trip the live tenant back into the YAML files for the five wired concepts.

`health-controls.yaml` and `data-access-policies.yaml` remain intentionally unwired. They stay schema-only until their
own follow-up reconciler work lands.

## Default state

[`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/) contains seven per-concept YAML files, each paired
with a Draft-07 JSON schema:

| YAML | Concept | Default desired state |
|---|---|---|
| `business-domains.yaml` | Business domains | `items: []` |
| `data-products.yaml` | Data products | `items: []` |
| `critical-data-elements.yaml` | Critical data elements | `items: []` |
| `health-controls.yaml` | Health controls | `items: []` |
| `okrs.yaml` | Objectives and key results | `items: []` |
| `glossary-terms.yaml` | Glossary terms (Unified Catalog, distinct from the classic Data Map glossary) | `items: []` |
| `data-access-policies.yaml` | Data access policies (simplified role-assignment projection) | `items: []` |

The reconciler's live concept table tracks the first five files above. `health-controls.yaml` and
`data-access-policies.yaml` still validate locally but are not part of the live read/write/export loop.

## Authentication

The script reuses the existing Azure CLI token-acquisition ladder from
[`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1) and requests the Purview data-plane audience
documented by Microsoft Learn: `https://purview.azure.net/.default`
([Authenticate to Microsoft Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)).

Contact display names in the YAML are resolved to Microsoft Entra object IDs at deploy time through
[`scripts/Get-EntraPrincipalIdByDisplayName.ps1`](../../../scripts/Get-EntraPrincipalIdByDisplayName.ps1).

## Inputs

| Parameter | Default source | Live behavior |
|---|---|---|
| `-Path` | `data-plane/unified-catalog/` | Folder containing the seven YAML files and seven co-located schemas; live reconcile/export tracks the first five concepts only. |
| `-ParametersFile` | `infra/parameters/lab.yaml` | Read locally to resolve `purviewAccountName`. |
| `-AccountName` / `-PurviewAccountName` | `purviewAccountName:` in the parameters file | Used to validate operator context before the script acquires the Purview data-plane token. |
| `-WhatIf` | Common parameter from `SupportsShouldProcess` | Performs the live read phase, emits the categorized drift report, and suppresses every write. |
| `-PruneMissing` | Switch | Allows per-item deletes for tenant-only objects. Default off. |
| `-Force` | Switch | Allows export overwrite of non-empty YAML files and suppresses confirmation prompts for apply/prune operations. |
| `-ExportCurrentState` | Switch in the `Export` parameter set | Reads live tenant state for the five wired concepts and rewrites their YAML `items:` blocks in deterministic order. |
| `-DirectionPolicy` | `portal-wins` | Applies the shared ADR 0029 update arbitration (`audit`, `portal-wins`, `repo-wins`). |
| `-SkipNames` | empty list | Explicit skip list consumed by the direction-policy pass. |

## Manage Unified Catalog with this repo

The management story is now split:

1. The five wired concepts are managed through YAML plus `Deploy-UnifiedCatalog.ps1`.
2. `health-controls.yaml` and `data-access-policies.yaml` remain schema-only placeholders.
3. Export-first onboarding still applies to an existing tenant: hydrate the YAML with `-ExportCurrentState`, review the
   diff, then run `-WhatIf` and only then apply.

Preview drift from the repo root:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -WhatIf
```

Expected behavior: the script validates the seven YAML files, reads the live state for the five wired concepts, prints a
categorized drift report, and performs no writes.

Bootstrap the YAML from an existing tenant:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -ExportCurrentState -Force
```

Apply desired state after review:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab
```

## References

- **[Learn about Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog)**
  Fetch date: 2026-06-20
  > "Microsoft Purview Unified Catalog provides a platform for data governance and enables you to drive business value creation in your organization."
- **[Authenticate to Microsoft Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)**
  Fetch date: 2026-07-08
  > "All Azure APIs need a valid JWT access token in the authorization header of the request."
- **[Business Domain - Enumerate](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview)**
  Fetch date: 2026-07-08
  > "Enumerates business domains with optional continuation token and write-obligation filtering."
- [ADR 0047 — Unified Catalog preview API coexistence](../../adr/0047-unified-catalog-preview-api-coexistence.md)
- [ADR 0048 — Purview account discovery gate](../../adr/0048-purview-account-discovery-gate.md)
- [ADR 0037 — Microsoft Purview Unified Catalog authoring surface](../../adr/0037-unified-catalog-authoring-surface.md)
- [ADR 0024 — Unified Catalog folder placement and YAML schema split](../../adr/0024-unified-catalog-folder-placement.md)
