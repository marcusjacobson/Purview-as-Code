# Unified Catalog

Operational documentation for the Microsoft Purview Unified Catalog watch-list surface. This section records the
current placeholder posture: live governance is operated in the Microsoft Purview portal, while this repo keeps a
schema-validated `-WhatIf` reconciler ready for a future documented authoring surface.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`unified-catalog.md`](unified-catalog.md) | Explains the Wave 4b-ii placeholder reconciler, empty desired-state YAMLs, and re-open triggers for Microsoft Purview Unified Catalog. | [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1), [`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/), [ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md), [ADR 0024](../../adr/0024-unified-catalog-folder-placement.md) |

## How this section relates to the rest of the repo

- **Infrastructure (control plane).** No Azure resource is provisioned for this section. The Microsoft Purview account
  and its supporting resources stay under [`infra/`](../../../infra/).
- **Data plane.** The files under [`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/) are empty
  `items: []` manifests with co-located schemas. They are retained for validation and future readiness, not for live
  Microsoft Purview Unified Catalog authoring.
- **Scripts.** [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) validates the YAML
  and emits a placeholder `-WhatIf` plan only. Live apply and export remain deferred by
  [ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md).
- **Operational runbooks.** Day-to-day Microsoft Purview Unified Catalog changes happen in the portal until Microsoft
  publishes a documented Graph, REST, or PowerShell authoring surface.

## Conventions

- Every Microsoft Purview Unified Catalog page that makes a product-capability claim cites Microsoft Learn and the
  relevant ADR.
- Real tenant, subscription, object, user, and customer identifiers never appear here. Examples use placeholders such as
  `00000000-0000-0000-0000-000000000000`, `contoso`, `purview-contoso-lab`, `rg-purview-lab`, and `eastus`.
- Do not add non-empty Unified Catalog desired state under `data-plane/unified-catalog/` unless
  [ADR 0037](../../adr/0037-unified-catalog-authoring-surface.md) is re-opened and superseded.
