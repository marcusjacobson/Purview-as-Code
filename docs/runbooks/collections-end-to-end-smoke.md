# Runbook: end-to-end smoke test for Purview Data Map Collections

Use this runbook to validate that the [`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml) desired-state surface and the [`scripts/Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1) reconciler reconcile end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#614](../../issues/614) as the Phase 3 end-to-end verification path for the v2 §5.5 Collections lifecycle (Phase 1+2 shipped in PR #613).

## Hard rule

**Pre-existing live collections in `contoso.onmicrosoft.com` MUST NOT be mutated by this runbook.** Every step below operates on a **throwaway `e2e-collections-smoke-*` collection** the operator (or [`scripts/Invoke-CollectionsSmokeTest.ps1`](../../scripts/Invoke-CollectionsSmokeTest.ps1)) creates and tears down. Any plan row that would touch a pre-existing collection is a bug — escalate to the lab owner.

## When to run

- After any breaking change to [`scripts/Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1).
- After any reconciler-bug fix to the Collections Phase 3 contract (`-DirectionPolicy`, `-SkipNames`, `-PruneMissing`, name validator, parent normalizer).
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven. AI agents cannot execute live-tenant writes against the Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-CollectionsSmokeTest.ps1`

[`scripts/Invoke-CollectionsSmokeTest.ps1`](../../scripts/Invoke-CollectionsSmokeTest.ps1) wraps Steps 1–5 below as a single near-unattended operator command, prompts for `y/yes/confirm` before the destructive cleanup step, and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/collections-<UTC>.md` ready to paste into the v2 §5.5 close-out PR. The manual steps below remain the authoritative source-of-truth and the fallback path; the wrapper invokes [`scripts/Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1) and the [Collections REST surface](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections) verbatim and introduces no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table — `az login`, `Collection Admin` at the root collection, clean working tree under `data-plane/collections/`, `powershell-yaml` installed):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-CollectionsSmokeTest.ps1
```

Exit codes: `0` every step PASSED, `1` at least one step FAILED or the operator declined the destructive-confirmation prompt, `2` preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Purview `Collection Admin` at root | Resolve via [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions). |
| Working tree clean under `data-plane/collections/` | `git status -s data-plane/collections/` returns empty. |
| `powershell-yaml` installed | `Get-Module -ListAvailable powershell-yaml` returns the module. |
| YAML matches tenant | `./scripts/Deploy-Collections.ps1 -WhatIf` returns `Plan: <N> NoChange` (no Create / Update / Orphan rows). |

## Step 1 — clean baseline

```pwsh
./scripts/Deploy-Collections.ps1 -DirectionPolicy audit
```

Expected: `[ADR0029-AUDIT]` marker emitted; categorized plan rows printed; **no writes**. The plan should be `Plan: 24 NoChange` (24 reflects the imported PR #613 hierarchy; adjust if the YAML has grown). Capture the output for the evidence file.

## Step 2 — Create a throwaway collection

```pwsh
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$smokeName = "e2e-collections-smoke-$stamp"
$ctx = ./scripts/Connect-Purview.ps1 -AccountName purview-contoso-lab
$uri = "$($ctx.Endpoint)/account/collections/$smokeName`?api-version=2019-11-01-preview"
$body = @{
  friendlyName     = 'E2E smoke (delete on sight)'
  description      = "Throwaway collection created by collections-end-to-end-smoke.md at $stamp."
  parentCollection = @{ referenceName = 'purview-contoso-lab' }
} | ConvertTo-Json -Depth 5 -Compress
Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $body | Format-List name, friendlyName, parentCollection
```

Expected: returns the new collection with `parentCollection.referenceName = purview-contoso-lab`. Reference: [Create Or Update Collection](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/create-or-update-collection).

## Step 3 — Verify the reconciler reports the orphan correctly

```pwsh
./scripts/Deploy-Collections.ps1 -WhatIf
```

Expected: a single `Orphan` row for the throwaway name with reason `Tenant-only; skipped (no -PruneMissing).`; every other row remains `NoChange`. Capture for evidence.

## Step 4 — Verify `-SkipNames` suppresses the orphan row

```pwsh
./scripts/Deploy-Collections.ps1 -WhatIf -SkipNames @($smokeName)
```

Expected: the throwaway row appears as `Skip` with reason `Explicitly skipped by caller (workflow pre-computed skip list).`, plus an `[ADR0029-SKIP] <smokeName>` machine-readable marker.

## Step 5 — Delete the throwaway

> **Destructive.** Confirm the name before proceeding.

```pwsh
$uri = "$($ctx.Endpoint)/account/collections/$smokeName`?api-version=2019-11-01-preview"
Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders
# Verify gone
try {
  Invoke-RestMethod -Method GET -Uri $uri -Headers $ctx.DataHeaders
  Write-Error "Cleanup failed: $smokeName still resolvable."
} catch {
  Write-Host "Cleanup verified: $smokeName returns $($_.Exception.Response.StatusCode)."
}
```

Expected: `DELETE` returns HTTP 204; the follow-up `GET` returns HTTP 404. Reference: [Delete Collection](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/delete-collection).

## Step 6 — Final verification

```pwsh
./scripts/Deploy-Collections.ps1 -WhatIf
```

Expected: tenant collection count is back to the pre-smoke baseline; `Plan: <N> NoChange` (no Orphan, no Skip).

## Capturing evidence

Paste the outputs of Steps 1, 3, 4, and 6 into the PR description under a `## Validation evidence — end-to-end smoke` block. The automated wrapper writes this file for you under `.copilot-tracking/smoke/collections-<UTC>.md`; the manual path requires the operator to assemble it.

## References

- [Account Data Plane — Collections REST API](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections)
- [Manage collections in Microsoft Purview](https://learn.microsoft.com/en-us/purview/how-to-create-and-manage-collections)
- [Quickstart: create a collection](https://learn.microsoft.com/en-us/purview/quickstart-create-collection)
- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
- [`docs/solutions/data-map/collections.md`](../solutions/data-map/collections.md) — operational guide for the reconciler.
