# Runbook: end-to-end smoke test for Purview Data Map Scans

Use this runbook to validate that the [`data-plane/scans/scans.yaml`](../../data-plane/scans/scans.yaml) desired-state surface and the [`scripts/Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1) reconciler reconcile end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#620](../../issues/620) as the Phase 3 end-to-end verification path for the v2 §5.5 row 3 Scans lifecycle (Phase 1+2 shipped in PR #619).

## Hard rule

**Pre-existing live scans, scan rulesets, and triggers in `contoso.onmicrosoft.com` MUST NOT be mutated by this runbook.** Every step below operates on a **throwaway `e2e-scans-smoke-*` scan** the operator (or [`scripts/Invoke-ScansSmokeTest.ps1`](../../scripts/Invoke-ScansSmokeTest.ps1)) creates and tears down. Any plan row that would touch a pre-existing scan, ruleset, or trigger is a bug — escalate to the lab owner.

## When to run

- After any breaking change to [`scripts/Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1).
- After any reconciler-bug fix to the Scans Phase 3 contract (`-DirectionPolicy`, `-SkipNames`, `-PruneMissing`, `-Force` conflict gate).
- After any change to the per-kind validator surface in `ConvertTo-DesiredScanHash` (the per-kind requirement matrix for `AzureSynapseWorkspaceMsi`, `FabricMsi`, `DatabricksUnityCatalog`, etc.).
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven. AI agents cannot execute live-tenant writes against the Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-ScansSmokeTest.ps1`

[`scripts/Invoke-ScansSmokeTest.ps1`](../../scripts/Invoke-ScansSmokeTest.ps1) wraps Steps 1–6 below as a single near-unattended operator command, prompts for `y/yes/confirm` before the destructive cleanup step, and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/scans-<UTC>.md` ready to paste into the v2 §5.5 row 3 close-out PR. The manual steps below remain the authoritative source-of-truth and the fallback path; the wrapper invokes [`scripts/Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1) and the [Scans REST surface](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans) verbatim and introduces no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-ScansSmokeTest.ps1
```

Exit codes: `0` every step PASSED, `1` at least one step FAILED or the operator declined the destructive-confirmation prompt, `2` preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Purview `Data Source Administrator` at root | Resolve via [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions). |
| Working tree clean under `data-plane/scans/` | `git status -s data-plane/scans/` returns empty. |
| `powershell-yaml` installed | `Get-Module -ListAvailable powershell-yaml` returns the module. |
| Parent data source registered | `AzureDataLakeStorage-TestData` exists in the live tenant (it does in `contoso.onmicrosoft.com` per PR #616). |
| YAML matches tenant | `./scripts/Deploy-Scans.ps1 -WhatIf` returns `Plan: <N> NoChange` (no Create / Update / Orphan / Conflict rows). |

## Step 1 — clean baseline

```pwsh
./scripts/Deploy-Scans.ps1 -DirectionPolicy audit
```

Expected: `[ADR0029-AUDIT]` marker emitted; categorized plan rows printed; **no writes**. The plan should be `Plan: 18 NoChange` (18 reflects the imported PR #619 topology of scan rulesets, scans, and triggers; adjust if the YAML has grown). Capture for evidence.

## Step 2 — Create a throwaway scan

The throwaway uses the `AdlsGen2Msi` kind under the existing `AzureDataLakeStorage-TestData` source, with the System-shipped `AdlsGen2` ruleset. The Purview REST surface only validates the body shape; no scan ever runs against this throwaway because it is torn down within seconds.

```pwsh
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$smokeName = "e2e-scans-smoke-$stamp"
$parent = 'AzureDataLakeStorage-TestData'
$ctx = ./scripts/Connect-Purview.ps1 -AccountName purview-contoso-lab
$dsEnc = [uri]::EscapeDataString($parent)
$scanEnc = [uri]::EscapeDataString($smokeName)
$uri = "$($ctx.Endpoint)/scan/datasources/$dsEnc/scans/$scanEnc`?api-version=2023-09-01"
$body = @{
  kind       = 'AdlsGen2Msi'
  properties = @{
    scanRulesetName = 'AdlsGen2'
    scanRulesetType = 'System'
    collection      = @{ referenceName = 'js1tih'; type = 'CollectionReference' }
  }
} | ConvertTo-Json -Depth 5 -Compress
Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $body -ContentType 'application/json' | Format-List name, kind
```

Expected: returns the new scan with `kind = AdlsGen2Msi`. Reference: [Create Or Update Scan](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans/create-or-update).

## Step 3 — Verify the reconciler reports the orphan correctly

```pwsh
./scripts/Deploy-Scans.ps1 -WhatIf
```

Expected: a single `Orphan` row for the composite key `AzureDataLakeStorage-TestData/<smokeName>` with reason `Tenant-only; skipped (no -PruneMissing).`; every other row remains `NoChange`. Capture for evidence.

## Step 4 — Verify `-SkipNames` suppresses the orphan row

```pwsh
$composite = "AzureDataLakeStorage-TestData/$smokeName"
./scripts/Deploy-Scans.ps1 -WhatIf -SkipNames @($composite)
```

Expected: the throwaway row appears as `Skip` with reason `Explicitly skipped by caller (workflow pre-computed skip list).`, plus an `[ADR0029-SKIP] <composite>` machine-readable marker.

## Step 5 — Delete the throwaway

> **Destructive.** Confirm the name before proceeding.

```pwsh
$uri = "$($ctx.Endpoint)/scan/datasources/$dsEnc/scans/$scanEnc`?api-version=2023-09-01"
Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders
# Verify gone
try {
  Invoke-RestMethod -Method GET -Uri $uri -Headers $ctx.DataHeaders
  Write-Error "Cleanup failed: $smokeName still resolvable."
} catch {
  Write-Host "Cleanup verified: $smokeName returns $($_.Exception.Response.StatusCode)."
}
```

Expected: `DELETE` returns HTTP 200/204; the follow-up `GET` returns HTTP 404. Reference: [Delete Scan](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans/delete).

## Step 6 — Final verification

```pwsh
./scripts/Deploy-Scans.ps1 -WhatIf
```

Expected: tenant scan count is back to the pre-smoke baseline; `Plan: <N> NoChange` (no Orphan, no Skip).

## Capturing evidence

Paste the outputs of Steps 1, 3, 4, and 6 into the PR description under a `## Validation evidence — end-to-end smoke` block. The automated wrapper writes this file for you under `.copilot-tracking/smoke/scans-<UTC>.md`; the manual path requires the operator to assemble it.

## References

- [Account Data Plane — Scans REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans)
- [Account Data Plane — Scan Rulesets REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets)
- [Account Data Plane — Triggers REST API](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers)
- [Microsoft Purview connector overview](https://learn.microsoft.com/en-us/purview/microsoft-purview-connector-overview)
- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
- [`docs/solutions/data-map/scans.md`](../solutions/data-map/scans.md) — operational guide for the reconciler.