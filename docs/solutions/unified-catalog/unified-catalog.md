# Unified Catalog

This guide covers the Microsoft Purview Unified Catalog reconcilers
[`scripts/Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) and
[`scripts/Deploy-UnifiedCatalogPolicies.ps1`](../../../scripts/Deploy-UnifiedCatalogPolicies.ps1),
plus the desired-state YAML under
[`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/). The scripts drive the
`2026-03-20-preview` Unified Catalog REST surface documented on Microsoft Learn, including the
Policies operation group introduced for grant/revoke-aware data-access governance
([Policies - List](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview),
[Policies - Update](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview)).

## Purpose

The Unified Catalog solution area is now split across two sibling reconcilers:

1. [`Deploy-UnifiedCatalog.ps1`](../../../scripts/Deploy-UnifiedCatalog.ps1) manages business
   domains, data products, objectives and key results, critical data elements, and glossary terms.
2. [`Deploy-UnifiedCatalogPolicies.ps1`](../../../scripts/Deploy-UnifiedCatalogPolicies.ps1)
   manages the simplified role-assignment projection in
   [`data-access-policies.yaml`](../../../data-plane/unified-catalog/data-access-policies.yaml)
   and materializes the full preview `decisionRules` / `attributeRules` policy document for PUT.

Both reconcilers validate YAML against Draft-07 schemas, read live tenant state from the
tenant-scoped Unified Catalog endpoint `https://api.purview-service.microsoft.com`, and emit the
canonical drift categories `Create`, `Update`, `NoChange`, `Orphan`, and `Conflict`.

The policy reconciler is intentionally stricter than the content reconciler. Per
[ADR 0047](../../adr/0047-unified-catalog-preview-api-coexistence.md), every grant, revoke, or
membership rewrite is treated as destructive-equivalent because one PUT can both grant and remove
access. The script therefore always prints a row-level subject/permission diff before any write,
keeps `-PruneMissing` off by default, and uses `SupportsShouldProcess` plus the standard `-Force`
gate only to suppress the interactive confirmation, never the diff visibility.

## Default state

[`data-plane/unified-catalog/`](../../../data-plane/unified-catalog/) contains seven YAML files,
each paired with a Draft-07 JSON schema:

| YAML | Concept | Default desired state |
|---|---|---|
| `business-domains.yaml` | Business domains | `items: []` |
| `data-products.yaml` | Data products | `items: []` |
| `critical-data-elements.yaml` | Critical data elements | `items: []` |
| `health-controls.yaml` | Health controls | `items: []` |
| `okrs.yaml` | Objectives and key results | `items: []` |
| `glossary-terms.yaml` | Glossary terms (Unified Catalog, distinct from the classic Data Map glossary) | `items: []` |
| `data-access-policies.yaml` | Data access policies expressed as `domain` / `role` / `principals` rows | `items: []` |

Operationally:

- `Deploy-UnifiedCatalog.ps1` manages five concept files: business domains, data products,
  critical data elements, OKRs, and glossary terms.
- `Deploy-UnifiedCatalogPolicies.ps1` manages `data-access-policies.yaml`.
- `health-controls.yaml` remains schema-valid and documented, but it is still not part of a live
  reconcile/apply loop.

The policy YAML is intentionally human-authorable. `principals` always use stable Microsoft Entra
ID display names, not object IDs, and the exporter writes the same display-name shape back out so
an `-ExportCurrentState` run can round-trip into a later `-WhatIf`.

## Authentication

Both scripts reuse the Azure CLI token-acquisition flow from
[`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1) and request the Microsoft
Purview data-plane audience documented by Microsoft Learn
([Authenticate to Microsoft Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)).

`Deploy-UnifiedCatalogPolicies.ps1` resolves desired-state `principals` through
[`scripts/Get-EntraPrincipalIdByDisplayName.ps1`](../../../scripts/Get-EntraPrincipalIdByDisplayName.ps1)
at plan-compute time, then reverse-resolves live object IDs back to display names during
`-ExportCurrentState` by calling Microsoft Graph `directoryObjects/getByIds`
([directoryObject: getByIds](https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids?view=graph-rest-1.0)).

In CI, the repo authenticates to Azure through GitHub Actions OpenID Connect and `azure/login@v2`
rather than a stored client secret
([Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)).

## Inputs

The two Unified Catalog reconcilers intentionally share the same parameter surface so operators can
manage content and policy state the same way.

| Parameter | Default source | Live behavior |
|---|---|---|
| `-Path` | `data-plane/unified-catalog/` | Folder containing the Unified Catalog YAML files and co-located schemas. |
| `-ParametersFile` | `infra/parameters/lab.yaml` | Read locally to resolve `purviewAccountName`. |
| `-AccountName` / `-PurviewAccountName` | `purviewAccountName:` in the parameters file | Used to validate operator context before the script acquires the Microsoft Purview data-plane token. |
| `-WhatIf` | Common parameter from `SupportsShouldProcess` | Performs the live read phase, prints the drift report, and suppresses writes. For the policy reconciler, `-WhatIf` still prints the full grant/revoke diff per affected policy row. |
| `-PruneMissing` | Switch | Off by default. For the policy reconciler, turning it on enables explicit revokes for live-only role assignments and treats those revokes as destructive-equivalent. |
| `-Force` | Switch | Suppresses interactive confirmations and allows export overwrite of non-empty YAML files. It never suppresses diff printing. |
| `-ExportCurrentState` | Switch in the `Export` parameter set | Writes live tenant state back into the YAML `items:` blocks. The policy reconciler exports display names, not raw object IDs. |
| `-DirectionPolicy` | `portal-wins` | Applies the shared ADR 0029 arbitration policy (`audit`, `portal-wins`, `repo-wins`). |
| `-SkipNames` | empty list | Explicit skip list consumed by the direction-policy pass. |

## Manage Unified Catalog with this repo

1. **Hydrate the content YAML from the tenant.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -ExportCurrentState -Force
   ```

2. **Hydrate the policy YAML from the tenant.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName purview-contoso-lab -ExportCurrentState -Force
   ```

3. **Edit the YAML.**
   - Use the content files for business objects.
   - Use `data-access-policies.yaml` for role rows. Keep `principals` as Microsoft Entra ID display
     names only; do not paste object IDs.

4. **Preview the content drift.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -WhatIf
   ```

5. **Preview the policy drift.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName purview-contoso-lab -WhatIf
   ```

   Expected behavior: the policy reconciler validates the YAML, resolves display names, reads the
   live Policies set, and prints a row-level grant/revoke diff before suppressing every PUT.

6. **Apply the reviewed content drift.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab
   ```

7. **Apply the reviewed policy drift.**

   ```pwsh
   ./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName purview-contoso-lab
   ```

   Use `-PruneMissing` only when the PR and operator both intend to revoke live-only access. The
   script still prints the per-policy diff before the confirmation gate.

8. **Verify.**
   - Re-run the matching `-WhatIf` command and expect `NoChange`.
   - Follow the Unified Catalog smoke-test or operator runbook for the tenant session you just
     changed.

## References

- **[Authenticate to Microsoft Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)**
  Fetch date: 2026-07-08
  > "All Azure APIs need a valid JWT access token in the authorization header of the request."
- **[Policies - List](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview)**
  Fetch date: 2026-07-08
  > "Lists policies with optional continuation token."
- **[Policies - Update](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview)**
  Fetch date: 2026-07-08
  > "Updates a policy by its identifier."
- **[directoryObject: getByIds](https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids?view=graph-rest-1.0)**
  Fetch date: 2026-07-08
  > "Returns the directory objects specified in a list of IDs."
- **[Authenticate to Azure from GitHub Actions by OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)**
  Fetch date: 2026-07-08
  > "Securely authenticate to Azure services from GitHub Actions workflows using Azure Login action with OpenID Connect (OIDC)."
- Microsoft Learn does not currently document this behavior as of 2026-07-08: the exact mapping
  from a policy `DGDataQualityScopeReference.referenceName` back to the repo's human-authored
  `domain` label in `data-access-policies.yaml`.
- [ADR 0047 - Unified Catalog preview API coexistence](../../adr/0047-unified-catalog-preview-api-coexistence.md)
- [ADR 0048 - Purview account discovery gate](../../adr/0048-purview-account-discovery-gate.md)
- [ADR 0023 - Identifier resolution](../../adr/0023-identifier-resolution.md)
- [ADR 0029 - Direction policy for repo-vs-tenant drift](../../adr/0029-direction-policy.md)
