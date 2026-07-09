# Unified Catalog

Operational documentation for the Microsoft Purview Unified Catalog solution area.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`unified-catalog.md`](unified-catalog.md) | Explains the live Unified Catalog content reconciler and the separate grant/revoke-aware data-access policy reconciler. | [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1), [`scripts/Deploy-UnifiedCatalogPolicies.ps1`](../../../scripts/Deploy-UnifiedCatalogPolicies.ps1), [`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/), [ADR 0047](../../adr/0047-unified-catalog-preview-api-coexistence.md), [ADR 0023](../../adr/0023-identifier-resolution.md) |

## How this section relates to the rest of the repo

- **Infrastructure (control plane).** No Azure resource is provisioned for this section. The Microsoft Purview account
  and its supporting resources stay under [`infra/`](../../../infra/).
- **Data plane.** The files under
  [`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/) carry the desired-state
  YAML for Unified Catalog business objects plus the simplified data-access policy projection.
- **Scripts.** [`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1)
  manages five content concepts. [`scripts/Deploy-UnifiedCatalogPolicies.ps1`](../../../scripts/Deploy-UnifiedCatalogPolicies.ps1)
  manages `data-access-policies.yaml` with stricter grant/revoke-aware confirmation rules.
- **Operational runbooks.** Live validation still belongs in the operator smoke-test flow after a
  reconcile run.

## Conventions

- Every Microsoft Purview Unified Catalog page that makes a product-capability claim cites Microsoft Learn and the
  relevant ADR.
- Real tenant, subscription, object, user, and customer identifiers never appear here. Examples use placeholders such as
  `00000000-0000-0000-0000-000000000000`, `contoso`, `purview-contoso-lab`, `rg-purview-lab`, and `eastus`.
- `data-access-policies.yaml` uses Microsoft Entra ID display names for principals. The reconciler
  resolves object IDs at deploy time; do not author raw object IDs in the YAML.
