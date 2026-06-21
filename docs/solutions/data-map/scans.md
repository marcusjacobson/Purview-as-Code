# Purview Data Map — Scans

Operational guide for [`scripts/Deploy-Scans.ps1`](../../../scripts/Deploy-Scans.ps1) — the reconciler that materializes [`data-plane/scans/scans.yaml`](../../../data-plane/scans/scans.yaml) against the [Microsoft Purview Data Map scans](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans) surface. Pairs with [`data-sources.md`](data-sources.md) (every scan binds to an existing data source) and [`collections.md`](collections.md) (every scan references an existing collection).

## Purpose

Reconciles three Purview entity kinds against a single YAML file:

- **Scan rulesets** — [Scan Rulesets REST](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets). Only `Custom` rulesets are managed; `System*` rulesets are tenant-builtin and filtered out of both the desired and orphan-prune candidate sets.
- **Scans** — [Scans REST](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans). Keyed by the composite `<dataSource>/<scanName>` (case-insensitive). Per-kind shape varies (`AdlsGen2Msi`, `AzureSqlDatabaseMsi`, `AzureSynapseWorkspaceMsi`, `FabricMsi`, `DatabricksUnityCatalog`, `Dataverse`, etc.); the reconciler trusts the REST surface to validate per-kind at apply time rather than re-implementing the requirement matrix client-side.
- **Default triggers** — [Triggers REST](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers). One default trigger per scan. Presence-vs-presence drift surfaces as a Trigger row tied to the scan's composite key.

Emits Create / Update / NoChange / Orphan / Conflict / Skip / Removed / Failed decisions per row. Orphan rows are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline. Conflict rows (tracked-field drift plus `lastModifiedBy` differs from the deploy principal) are reported but never written without `-Force`.

## Default state

The shipped YAML is the live tenant topology imported in PR #619 (18 plan rows across scan rulesets, scans, and triggers spanning ADLS Gen2, Azure Blob, Azure Data Explorer, Azure SQL Database, Azure Synapse, Databricks, Dataverse, Fabric, MySQL, PostgreSQL). `-WhatIf` returns `Plan: 18 NoChange`.

## Cross-domain validation

The reconciler refuses to plan when either gate is broken:

- Every scan's `dataSource` must already be a registered data source in the tenant. Run [`Deploy-DataSources.ps1`](../../../scripts/Deploy-DataSources.ps1) first when a new source is in flight.
- Every scan with `properties.scanRulesetType: Custom` must reference a `scanRulesetName` declared under top-level `scanRulesets:` in the same file. `System` rulesets bypass this check (they exist tenant-wide).

The error message names both sides of the cross-domain mismatch so the operator can resolve it in one PR.

## Authentication

Pure Purview data-plane REST. The script delegates token acquisition to [`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1), which uses the Azure CLI token cache (`az account get-access-token --resource https://purview.azure.net`). In CI the `azure/login@v2` OIDC step (per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)) provides the underlying federated identity.

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/scans/scans.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-AccountName` / `-PurviewAccountName` | `purviewAccountName:` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant scans / scan rulesets / triggers. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-Force` | switch — allow overwriting `Conflict` rows (last-modified-by gate) and overwriting a non-empty YAML on export |
| `-ExportCurrentState` | switch — round-trip the live tenant back into the YAML |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads scans / rulesets / triggers from the tenant; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No PUT or DELETE writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads tenant state; applies the skip baseline; prints Create / Update / NoChange / Orphan / Conflict / Skip / Removed rows. No writes. |
| (default) | Same read, then per-row PUT (Create / Update) or DELETE (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite naming the entity kind and field set. CI gates this on the typed `confirm_overwrite_scans='overwrite portal'` token. Conflict rows still require `-Force`. |

## SkipNames key shapes

`-SkipNames` matches case-insensitively against the bare plan-row `Name` field. The shape differs per kind:

- **Scan ruleset row** — bare ruleset name (e.g. `MyCustomRuleset`).
- **Scan row** — composite `<dataSource>/<scanName>` (e.g. `AzureBlob-SampleData/Scan-DataLakeModernization`).
- **Trigger row** — same composite `<dataSource>/<scanName>` as the parent scan (one default trigger per scan).

A single `-SkipNames` entry matching a scan composite key suppresses both the Scan row and the matching Trigger row, since they share the same display name.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Data Source Administrator` | Root collection of the target Purview account |
| Purview managed identity (scan execution time) | Source-specific reader role (e.g. `Storage Blob Data Reader` for ADLS Gen2, `db_datareader` for Azure SQL) | The data source the scan targets |
| Caller's identity in Azure | Active `az login` session | Subscription containing the Purview account |

Reference: [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## Smoke test

```pwsh
# Audit mode — read-only view of the live tenant vs YAML.
./scripts/Deploy-Scans.ps1 -DirectionPolicy audit
```

Expected output tail when YAML matches the live tenant:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
...
Plan: 18 NoChange
```

For a near-unattended end-to-end smoke that exercises Create → Read → SkipNames → Delete against a throwaway scan, see [`docs/runbooks/scans-end-to-end-smoke.md`](../../runbooks/scans-end-to-end-smoke.md) and the [`scripts/Invoke-ScansSmokeTest.ps1`](../../../scripts/Invoke-ScansSmokeTest.ps1) wrapper.

## ADR 0029 contract

This reconciler conforms to [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md). The script accepts `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>`; the [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) workflow exposes matching `scans_direction_policy`, `confirm_overwrite_scans`, and `skip_names_scans` dispatch inputs with the `overwrite portal` typed-confirmation gate on `repo-wins`. The pre-flight gate-step refuses a `repo-wins` dispatch missing the token.

## Phase 1 drift-review evidence (PR #619)

Live tenant on 2026-06-14 carried 18 portal-authored plan rows; the repo YAML scaffolding was incomplete for several kinds. Phase 2 closed via path (a) update YAML + re-apply: full topology imported with the per-kind shape variation surfaced in `Get-ComparableScanProperty` (Synapse per-resource-type rulesets, Fabric / Databricks ruleset-less). Round-trip `-WhatIf` returns 18 NoChange.

## References

- **[Account Data Plane — Scans REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans)**
  Fetch date: 2026-06-14
- **[Account Data Plane — Scan Rulesets REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets)**
  Fetch date: 2026-06-14
- **[Account Data Plane — Triggers REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers)**
  Fetch date: 2026-06-14
- **[Microsoft Purview connector overview](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview)**
  Fetch date: 2026-06-14
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)