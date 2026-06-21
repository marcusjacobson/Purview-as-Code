# Purview Data Map

Operational guides for the Microsoft Purview Data Map plane — the collection hierarchy, registered
data sources, scans, and business glossary that catalog the tenant's data estate. Each reconciler
materializes a desired-state YAML under [`data-plane/`](../../../data-plane/) against the Purview
data-plane REST APIs. Read top-down: sources and scans assume the collection hierarchy exists.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`collections.md`](collections.md) | Reconcile the Data Map collection hierarchy. | [`scripts/Deploy-Collections.ps1`](../../../scripts/Deploy-Collections.ps1), [`data-plane/collections/collections.yaml`](../../../data-plane/collections/collections.yaml) |
| [`data-sources.md`](data-sources.md) | Register and reconcile data sources, referencing credentials by Key Vault never inline. | [`scripts/Deploy-DataSources.ps1`](../../../scripts/Deploy-DataSources.ps1), [`data-plane/data-sources/data-sources.yaml`](../../../data-plane/data-sources/data-sources.yaml), [ADR 0023](../../adr/0023-identifier-resolution.md) |
| [`scans.md`](scans.md) | Reconcile scans, scan rulesets, and triggers for registered sources. | [`scripts/Deploy-Scans.ps1`](../../../scripts/Deploy-Scans.ps1), [`data-plane/scans/scans.yaml`](../../../data-plane/scans/scans.yaml) |
| [`glossary.md`](glossary.md) | Reconcile business glossary terms. | [`scripts/Deploy-Glossary.ps1`](../../../scripts/Deploy-Glossary.ps1), [`data-plane/glossary/glossary.yaml`](../../../data-plane/glossary/glossary.yaml), [ADR 0026](../../adr/0026-glossary-custom-classifications-reconciler.md) |

## How this section relates to the rest of the repo

- **Data plane.** YAML files under [`data-plane/`](../../../data-plane/) describe desired state; the
  reconciler scripts apply them via the Purview Data Map / Scanning data-plane REST APIs. Field and
  schema rules live in
  [`.github/instructions/data-plane-yaml.instructions.md`](../../../.github/instructions/data-plane-yaml.instructions.md).
- **Identifier resolution.** Real Azure topology IDs and Entra principal IDs are never inlined into
  Data Map YAML. They resolve at deploy time per
  [ADR 0023](../../adr/0023-identifier-resolution.md) (`${env:VAR}` tokens and `displayName`
  lookups).
- **Governance foundation.** The collection-scoped RBAC and role groups that gate Data Map writes
  are documented under [`../governance-foundation/`](../governance-foundation/README.md).
- **Operational runbooks.** End-to-end smoke tests
  ([`collections-end-to-end-smoke.md`](../../runbooks/collections-end-to-end-smoke.md),
  [`data-sources-end-to-end-smoke.md`](../../runbooks/data-sources-end-to-end-smoke.md),
  [`scans-end-to-end-smoke.md`](../../runbooks/scans-end-to-end-smoke.md),
  [`glossary-end-to-end-smoke.md`](../../runbooks/glossary-end-to-end-smoke.md)) live under
  [`docs/runbooks/`](../../runbooks/). This section documents steady-state configuration, not
  incident response.

## Conventions

- Every page that makes a product-capability or role-gating claim ends with a `## References` block
  per the "Evidence pattern for Microsoft Learn citations" section of
  [`.github/copilot-instructions.md`](../../../.github/copilot-instructions.md).
- Real tenant, subscription, or object IDs never appear here. Placeholders follow the "Environment
  and identifier boundaries" section of the same file.
