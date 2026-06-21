# Purview Data Map — Data sources

Operational guide for [`scripts/Deploy-DataSources.ps1`](../../../scripts/Deploy-DataSources.ps1) — the reconciler that materializes [`data-plane/data-sources/data-sources.yaml`](../../../data-plane/data-sources/data-sources.yaml) against the [Microsoft Purview Data Map data sources](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview) surface. Pairs with [`collections.md`](collections.md) (every data source must reference an existing collection).

## Purpose

Reconciles the [Account Data Plane — Data Sources](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources) REST surface against a declared list of registered sources. Emits Create / Update / NoChange / Orphan / Conflict / Skip / Removed / Failed decisions per source. Orphan sources are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline. Conflict rows (tracked-field drift plus `lastModifiedBy` differs from the deploy principal) are reported but never written without `-Force`.

The data sources model is documented at [Microsoft Purview connector overview](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview):

- Each source carries a `name` (immutable URL segment), `kind` (`AdlsGen2`, `AzureSqlDatabase`, `AzureStorage`, `AzureDataExplorer`, `AzureSynapseWorkspace`, `DatabricksUnityCatalog`, `Dataverse`, `Fabric`, `MySql`, `PostgreSql`, etc.), and a `properties` bag whose required fields depend on `kind`.
- `properties.collection.referenceName` must target an existing collection (see [`collections.md`](collections.md)).
- `properties.credential` holds only Key Vault references (`vaultName` + `secretName`) — never inline secret values, per [`security.instructions.md`](../../../.github/instructions/security.instructions.md) rule #1.
- For sources that support it, prefer `authType: ManagedIdentity` over Key Vault-backed credentials.

## Default state

The shipped YAML is the live tenant topology imported in PR #616 (11 sources spanning ADLS / Blob storage, Azure SQL DB, Azure Synapse, Databricks Unity Catalog, Dataverse, Fabric, MySQL Flexible, PostgreSQL Flexible, Azure Data Explorer). `-WhatIf` returns `Plan: 11 NoChange`.

## Identifier resolution (ADR 0023)

Real Azure topology IDs and the Databricks metastore GUID never land in source. The YAML carries `${env:VAR}` tokens resolved at apply time by [`scripts/Resolve-EnvTokens.ps1`](../../../scripts/Resolve-EnvTokens.ps1) against the [ADR 0023](../../adr/0023-identifier-resolution.md) allow-list. As of 2026-06-14 the data sources file uses three tokens:

- `${env:AZURE_SUBSCRIPTION_ID}` — appears inside every `resourceId` and the top-level `subscriptionId` field.
- `${env:AZURE_TENANT_ID}` — appears as `properties.tenant` on the Fabric source.
- `${env:DATABRICKS_METASTORE_ID}` — appears as `properties.metastoreId` on the `DatabricksUnityCatalog-TestData` source. Added under PR #616.

`Resolve-EnvTokens.ps1` fails fast if any token references an unset environment variable. The `lab` GitHub environment must carry all three as Variables before any CI dispatch resolves them.

## Authentication

Pure Purview data-plane REST. The script delegates token acquisition to [`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1), which uses the Azure CLI token cache (`az account get-access-token --resource https://purview.azure.net`). In CI the `azure/login@v2` OIDC step (per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)) provides the underlying federated identity.

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/data-sources/data-sources.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-AccountName` / `-PurviewAccountName` | `purviewAccountName:` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant sources. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-Force` | switch — allow overwriting `Conflict` rows (last-modified-by gate) and overwriting a non-empty YAML on export |
| `-ExportCurrentState` | switch — round-trip the live tenant back into the YAML |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `List Data Sources`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No PUT or DELETE writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads `List Data Sources`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Conflict / Skip / Removed rows. No writes. |
| (default) | Same read, then per-row PUT (Create / Update) or DELETE (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_data_sources='overwrite portal'` token. Conflict rows still require `-Force`. |

## Credential-resolution chain

For sources that cannot use managed identity (e.g. legacy SQL with `SqlAuthentication`), the YAML carries a `credential` block referencing a Key Vault entry by `vaultName` + `secretName`. Resolution at scan time is the responsibility of the Purview managed identity, which must hold `Key Vault Secrets User` on the target vault. The reconciler does **not** verify the secret exists at apply time; an actual scan that consumes the credential is the end-to-end verification path, covered under §5.5 row 3 (Scans).

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Data Source Administrator` | Root collection of the target Purview account |
| Purview managed identity (scan time, for credential-backed sources) | `Key Vault Secrets User` | The Key Vault holding the source credential |
| Caller's identity in Azure | Active `az login` session | Subscription containing the Purview account |

Reference: [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## Smoke test

```pwsh
# Audit mode — read-only view of the live tenant vs YAML.
./scripts/Deploy-DataSources.ps1 -DirectionPolicy audit
```

Expected output tail when YAML matches the live tenant:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
...
Plan: 11 NoChange
```

For a near-unattended end-to-end smoke that exercises Create → Read → SkipNames → Delete against a throwaway source, see [`docs/runbooks/data-sources-end-to-end-smoke.md`](../../runbooks/data-sources-end-to-end-smoke.md) and the [`scripts/Invoke-DataSourcesSmokeTest.ps1`](../../../scripts/Invoke-DataSourcesSmokeTest.ps1) wrapper.

## ADR 0029 contract

This reconciler conforms to [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md). The script accepts `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>`; the [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) workflow exposes matching `data_sources_direction_policy`, `confirm_overwrite_data_sources`, and `skip_names_data_sources` dispatch inputs with the `overwrite portal` typed-confirmation gate on `repo-wins`. The pre-flight gate-step refuses a `repo-wins` dispatch missing the token.

## Phase 1 drift-review evidence (PR #616)

Live tenant on 2026-06-14 carried 11 portal-authored data sources; the repo YAML carried 2 stale Wave 1 scaffolding entries with zero-GUID subscription IDs pointing at non-existent Azure resources. Phase 2 closed via path (a) update YAML + re-apply: 11 entries imported with full env-token tokenization; 2 stale entries dropped; ADR 0023 allow-list extended with `DATABRICKS_METASTORE_ID`. Round-trip `-WhatIf` returns 11 NoChange.

## References

- **[Account Data Plane — Data Sources REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources)**
  Fetch date: 2026-06-14
- **[Microsoft Purview connector overview](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview)**
  Fetch date: 2026-06-14
- **[Credentials for source authentication](https://learn.microsoft.com/en-us/purview/data-map-data-scan-credentials)**
  Fetch date: 2026-06-14
- [ADR 0023 — Identifier resolution](../../adr/0023-identifier-resolution.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
