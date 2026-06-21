# Runbook: end-to-end smoke test for Purview Data Map Data sources

Use this runbook to validate that the [`data-plane/data-sources/data-sources.yaml`](../../data-plane/data-sources/data-sources.yaml) desired-state surface and the [`scripts/Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) reconciler reconcile end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#617](../../issues/617) as the Phase 3 end-to-end verification path for the v2 §5.5 row 2 Data sources lifecycle (Phase 1+2 shipped in PR #616).

## Hard rule

**Pre-existing live data sources in `contoso.onmicrosoft.com` MUST NOT be mutated by this runbook.** Every step below operates on a **throwaway `e2e-data-sources-smoke-*` source** the operator (or [`scripts/Invoke-DataSourcesSmokeTest.ps1`](../../scripts/Invoke-DataSourcesSmokeTest.ps1)) creates and tears down. Any plan row that would touch a pre-existing source is a bug — escalate to the lab owner.

## When to run

- After any breaking change to [`scripts/Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1).
- After any change to the [ADR 0023](../adr/0023-identifier-resolution.md) allow-list or [`scripts/Resolve-EnvTokens.ps1`](../../scripts/Resolve-EnvTokens.ps1).
- After any reconciler-bug fix to the Data Sources Phase 3 contract (`-DirectionPolicy`, `-SkipNames`, `-PruneMissing`, `-Force` conflict gate).
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven. AI agents cannot execute live-tenant writes against the Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-DataSourcesSmokeTest.ps1`

[`scripts/Invoke-DataSourcesSmokeTest.ps1`](../../scripts/Invoke-DataSourcesSmokeTest.ps1) wraps Steps 1–6 below as a single near-unattended operator command, prompts for `y/yes/confirm` before the destructive cleanup step, and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/data-sources-<UTC>.md` ready to paste into the v2 §5.5 row 2 close-out PR. The manual steps below remain the authoritative source-of-truth and the fallback path; the wrapper invokes [`scripts/Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) and the [Data Sources REST surface](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources) verbatim and introduces no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-DataSourcesSmokeTest.ps1
```

Exit codes: `0` every step PASSED, `1` at least one step FAILED or the operator declined the destructive-confirmation prompt, `2` preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Purview `Data Source Administrator` at root | Resolve via [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions). |
| Working tree clean under `data-plane/data-sources/` | `git status -s data-plane/data-sources/` returns empty. |
| `powershell-yaml` installed | `Get-Module -ListAvailable powershell-yaml` returns the module. |
| ADR 0023 env vars set | `$env:AZURE_TENANT_ID`, `$env:AZURE_SUBSCRIPTION_ID`, `$env:DATABRICKS_METASTORE_ID` all set in the local shell. |
| YAML matches tenant | `./scripts/Deploy-DataSources.ps1 -WhatIf` returns `Plan: <N> NoChange` (no Create / Update / Orphan / Conflict rows). |

## Step 1 — clean baseline

```pwsh
./scripts/Deploy-DataSources.ps1 -DirectionPolicy audit
```

Expected: `[ADR0029-AUDIT]` marker emitted; categorized plan rows printed; **no writes**. The plan should be `Plan: 11 NoChange` (11 reflects the imported PR #616 topology; adjust if the YAML has grown). Capture for evidence.

## Step 2 — Create a throwaway data source

The throwaway uses the `AzureStorage` kind. The Purview REST surface
requires a populated `resourceId` (the registration does not validate
connectivity, but it 404s on a bare body), so the body below references a
synthetic storage account name under `rg-purview-lab`. Nothing in Azure
matches that name and no scan ever runs against it; the throwaway is
torn down within seconds.

```pwsh
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$smokeName = "e2e-data-sources-smoke-$stamp"
$endpointHost = "e2esmoke$($stamp -replace '-','')"
$ctx = ./scripts/Connect-Purview.ps1 -AccountName purview-contoso-lab
$uri = "$($ctx.Endpoint)/scan/datasources/$smokeName`?api-version=2023-09-01"
$body = @{
  kind       = 'AzureStorage'
  properties = @{
    endpoint          = "https://$endpointHost.blob.core.windows.net/"
    resourceName      = $endpointHost
    resourceGroup     = 'rg-purview-lab'
    subscriptionId    = $env:AZURE_SUBSCRIPTION_ID
    resourceId        = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/rg-purview-lab/providers/Microsoft.Storage/storageAccounts/$endpointHost"
    location          = 'eastus'
    collection        = @{ referenceName = 'sandbox'; type = 'CollectionReference' }
    dataUseGovernance = 'Disabled'
  }
} | ConvertTo-Json -Depth 5 -Compress
Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $body -ContentType 'application/json' | Format-List name, kind
```

Expected: returns the new source with `kind = AzureStorage`. Reference: [Create Or Update Data Source](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/create-or-update).

## Step 3 — Verify the reconciler reports the orphan correctly

```pwsh
./scripts/Deploy-DataSources.ps1 -WhatIf
```

Expected: a single `Orphan` row for the throwaway name with reason `Tenant-only; skipped (no -PruneMissing).`; every other row remains `NoChange`. Capture for evidence.

## Step 4 — Verify `-SkipNames` suppresses the orphan row

```pwsh
./scripts/Deploy-DataSources.ps1 -WhatIf -SkipNames @($smokeName)
```

Expected: the throwaway row appears as `Skip` with reason `Explicitly skipped by caller (workflow pre-computed skip list).`, plus an `[ADR0029-SKIP] <smokeName>` machine-readable marker.

## Step 5 — Delete the throwaway

> **Destructive.** Confirm the name before proceeding.

```pwsh
$uri = "$($ctx.Endpoint)/scan/datasources/$smokeName`?api-version=2023-09-01"
Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders
# Verify gone
try {
  Invoke-RestMethod -Method GET -Uri $uri -Headers $ctx.DataHeaders
  Write-Error "Cleanup failed: $smokeName still resolvable."
} catch {
  Write-Host "Cleanup verified: $smokeName returns $($_.Exception.Response.StatusCode)."
}
```

Expected: `DELETE` returns HTTP 200/204; the follow-up `GET` returns HTTP 404. Reference: [Delete Data Source](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/delete).

## Step 6 — Final verification

```pwsh
./scripts/Deploy-DataSources.ps1 -WhatIf
```

Expected: tenant data-source count is back to the pre-smoke baseline; `Plan: <N> NoChange` (no Orphan, no Skip).

## Capturing evidence

Paste the outputs of Steps 1, 3, 4, and 6 into the PR description under a `## Validation evidence — end-to-end smoke` block. The automated wrapper writes this file for you under `.copilot-tracking/smoke/data-sources-<UTC>.md`; the manual path requires the operator to assemble it.

## References

- [Account Data Plane — Data Sources REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources)
- [Microsoft Purview connector overview](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview)
- [ADR 0023 — Identifier resolution](../adr/0023-identifier-resolution.md)
- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
- [`docs/solutions/data-map/data-sources.md`](../solutions/data-map/data-sources.md) — operational guide for the reconciler.
