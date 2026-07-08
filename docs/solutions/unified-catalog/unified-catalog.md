# Unified Catalog

Operational guide for [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) — the Wave
4b-ii placeholder reconciler that validates [`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/)
against the [Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog) concept
surface. The script is intentionally `-WhatIf` only until Microsoft publishes a documented data-plane authoring surface.

## Purpose

This reconciler is a watch-list placeholder per
[ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md). Microsoft has not published a public data-plane
authoring surface for Microsoft Purview Unified Catalog concepts in the Microsoft Learn evidence captured by that ADR,
so the repo does not create, update, remove, or export Unified Catalog content.

The placeholder still matters. It keeps the full-circle reconciler contract guard satisfied, validates the per-concept
YAML files against their schemas, emits a no-op `-WhatIf` plan for the default empty state, and preserves the parameter
surface needed when a documented authoring surface ships.

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

The last two files were added per [ADR 0047](../../adr/0047-unified-catalog-preview-api-coexistence.md) §Decision item 5,
which adopted the `2026-03-20-preview` Unified Catalog API and also renamed `governance-domains.yaml` to
`business-domains.yaml` to match that API's operation-group term. Neither new file is wired into this reconciler's plan
output yet — that ships with the follow-up reconciler items tracked in ADR 0047 §Decision item 10.

With that default, the placeholder plan reports one `NoChange` row per **reconciler-tracked** concept (the five listed
above minus the two additions) with `Name` set to `(none)`. The script's internal planner would label non-empty desired
rows as `Create` against an empty tenant baseline, but [ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md)
kept `items: []` as the standing repo state until a public authoring surface was documented; [ADR 0047](../../adr/0047-unified-catalog-preview-api-coexistence.md)
has since confirmed that surface exists as a `2026-03-20-preview` public preview and adopted it for a follow-up live
reconciler.

## Authentication

The script performs no live authentication today. It does not call Microsoft Purview REST, Microsoft Graph, Security &
Compliance PowerShell, Azure CLI token acquisition, or [`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1).

It reads `infra/parameters/lab.yaml` by default, resolves `purviewAccountName` when `-AccountName` is omitted, echoes the
resolved account name for operator context, validates local YAML and schema files, and then stops unless `-WhatIf` is
present.

## Inputs

| Parameter | Default source | Placeholder behavior |
|---|---|---|
| `-Path` | `data-plane/unified-catalog/` | Folder containing the seven YAML files and seven co-located schemas; the reconciler's placeholder plan tracks the original five. |
| `-ParametersFile` | `infra/parameters/lab.yaml` | Read locally to resolve `purviewAccountName`. |
| `-AccountName` / `-PurviewAccountName` | `purviewAccountName:` in the parameters file | Captured and echoed for downstream parity; no network call uses it today. |
| `-WhatIf` | Common parameter from `SupportsShouldProcess` | Required for the placeholder plan. Without it, the script throws the pending authoring-surface message. |
| `-PruneMissing` | Switch | Accepted and echoed as reserved; no-op because there is no live tenant baseline to prune. |
| `-Force` | Switch | Accepted and echoed as reserved; no-op until live apply exists. |
| `-ExportCurrentState` | Switch in the `Export` parameter set | Throws the pending authoring-surface message because no documented read path exists. |

## Manage Unified Catalog with this repo

Today the management story is deliberately narrow:

1. Live Microsoft Purview Unified Catalog governance content is authored and maintained in the Microsoft Purview portal.
2. [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) is a no-op placeholder reconciler
   that validates YAML and emits a `-WhatIf` plan only.
3. Re-open [ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md) only when Microsoft publishes a documented
   Graph, REST, PowerShell, or official sample authoring surface for governance domains, data products, OKRs, critical
   data elements, health controls, or related Unified Catalog resources.

Confirm the default no-op plan from the repo root:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -WhatIf
```

Expected behavior: the script validates all five YAML files, prints the placeholder mode banner, and reports `NoChange`
for each empty concept. It performs no live reads and no writes.

## References

- **[Learn about Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog)**
  Fetch date: 2026-06-20
  > "Microsoft Purview Unified Catalog provides a platform for data governance and enables you to drive business value creation in your organization."
- [ADR 0047 — Unified Catalog preview API coexistence](../../adr/0047-unified-catalog-preview-api-coexistence.md)
- [ADR 0037 — Microsoft Purview Unified Catalog authoring surface](../../adr/0037-unified-catalog-authoring-surface.md)
- [ADR 0024 — Unified Catalog folder placement and YAML schema split](../../adr/0024-unified-catalog-folder-placement.md)
