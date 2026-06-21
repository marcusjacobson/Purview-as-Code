# Runbook: end-to-end smoke test for Purview Data Map Glossary

Use this runbook to validate that the [`data-plane/glossary/glossary.yaml`](../../data-plane/glossary/glossary.yaml) desired-state surface and the [`scripts/Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) reconciler reconcile end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#644](../../issues/644) as the Phase 3+4 end-to-end verification path for the v2 §5.9 Glossary lifecycle (Phase 1+2 shipped in PR #629).

## Hard rule

**Pre-existing live glossary terms in `contoso.onmicrosoft.com` MUST NOT be mutated by this runbook.** Every step below operates on a **throwaway `e2e-glossary-smoke-*` term** the operator (or [`scripts/Invoke-GlossarySmokeTest.ps1`](../../scripts/Invoke-GlossarySmokeTest.ps1)) creates and tears down. Any plan row that would touch a pre-existing term is a bug — escalate to the lab owner.

## When to run

- After any breaking change to [`scripts/Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1).
- After any reconciler-bug fix to the Glossary Phase 3+4 contract (`-DirectionPolicy`, `-SkipNames`, `-PruneMissing`, term hash helpers).
- Optional: re-run quarterly as a regression check.

The runbook is operator-driven. AI agents cannot execute live-tenant writes against the Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-GlossarySmokeTest.ps1`

[`scripts/Invoke-GlossarySmokeTest.ps1`](../../scripts/Invoke-GlossarySmokeTest.ps1) wraps Steps 1–5 below as a single near-unattended operator command, prompts for `y/yes/confirm` before the destructive cleanup step, and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/glossary-<UTC>.md` ready to paste into the v2 §5.9 close-out PR. The manual steps below remain the authoritative source-of-truth and the fallback path; the wrapper invokes [`scripts/Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) and the [Atlas Glossary REST surface](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary) verbatim and introduces no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table — `az login`, active `az login` session, clean working tree under `data-plane/glossary/`, `powershell-yaml` installed):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-GlossarySmokeTest.ps1
```

Exit codes: `0` every step PASSED, `1` at least one step FAILED or the operator declined the destructive-confirmation prompt, `2` preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Working tree clean under `data-plane/glossary/` | `git status -s data-plane/glossary/` returns empty. |
| `powershell-yaml` installed | `Get-Module -ListAvailable powershell-yaml` returns the module. |
| YAML matches tenant | `./scripts/Deploy-Glossary.ps1 -WhatIf` returns `Plan: <N> NoChange` (no Create / Update / Orphan rows). |

## Step 1 — clean baseline

```pwsh
./scripts/Deploy-Glossary.ps1 -DirectionPolicy audit
```

Expected: `[ADR0029-AUDIT]` marker emitted; categorized plan rows printed; **no writes**. The plan should be `Plan: 1 NoChange, 3 NoChange` (1 Glossary container + 3 terms; adjust if the YAML has grown). Capture the output for the evidence file.

## Step 2 — Resolve glossary container and create a throwaway term

```pwsh
$stamp = (Get-Date).ToString('yyyyMMdd-HHmm')
$smokeName = "e2e-glossary-smoke-$stamp"
$ctx = ./scripts/Connect-Purview.ps1 -AccountName purview-contoso-lab
# Resolve the Glossary container GUID
$glossaries = Invoke-RestMethod -Method GET `
    -Uri "$($ctx.Endpoint)/datamap/api/atlas/v2/glossary?limit=1000&api-version=2023-09-01" `
    -Headers $ctx.DataHeaders
$glossaryGuid = ($glossaries | Where-Object { $_.name -ieq 'Glossary' } | Select-Object -First 1).guid
# POST throwaway term
$body = @{
    name             = $smokeName
    anchor           = @{ glossaryGuid = $glossaryGuid }
    shortDescription = 'E2E smoke throwaway term (delete on sight).'
    status           = 'Draft'
} | ConvertTo-Json -Depth 10 -Compress
$created = Invoke-RestMethod -Method POST `
    -Uri "$($ctx.Endpoint)/datamap/api/atlas/v2/glossary/term?api-version=2023-09-01" `
    -Headers $ctx.DataHeaders -Body $body -ContentType 'application/json'
$smokeGuid = $created.guid
$created | Format-List name, status, guid
```

Expected: returns the new term with `name = $smokeName` and `status = 'Draft'`. Reference: [Create Term](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/create-term).

## Step 3 — Verify the reconciler reports the orphan correctly

```pwsh
./scripts/Deploy-Glossary.ps1 -WhatIf
```

Expected: a single `Orphan` row for `$smokeName` with reason `Tenant-only; skipped (no -PruneMissing).`; every other row remains `NoChange`. Capture for evidence.

## Step 4 — Verify `-SkipNames` suppresses the orphan row

```pwsh
./scripts/Deploy-Glossary.ps1 -WhatIf -SkipNames @($smokeName)
```

Expected: the throwaway row appears as `Skip` with reason `Explicitly skipped by caller (workflow pre-computed skip list).`, plus an `[ADR0029-SKIP] <smokeName>` machine-readable marker.

## Step 5 — Delete the throwaway term

> **Destructive.** Confirm the name matches `^e2e-glossary-smoke-` before proceeding.

```pwsh
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/delete-term
Invoke-RestMethod -Method DELETE `
    -Uri "$($ctx.Endpoint)/datamap/api/atlas/v2/glossary/term/$([uri]::EscapeDataString($smokeGuid))?api-version=2023-09-01" `
    -Headers $ctx.DataHeaders
# Verify gone
try {
    Invoke-RestMethod -Method GET `
        -Uri "$($ctx.Endpoint)/datamap/api/atlas/v2/glossary/term/$([uri]::EscapeDataString($smokeGuid))?api-version=2023-09-01" `
        -Headers $ctx.DataHeaders
    Write-Error "Cleanup failed: $smokeName still resolvable."
} catch {
    Write-Host "Cleanup verified: $smokeName returns $($_.Exception.Response.StatusCode)."
}
```

Expected: `DELETE` returns HTTP 204; the follow-up `GET` returns HTTP 404.

## Step 6 — Final verification

```pwsh
./scripts/Deploy-Glossary.ps1 -WhatIf
```

Expected: tenant term count is back to the pre-smoke baseline; `Plan: <N> NoChange` (no Orphan, no Skip).

## Capturing evidence

Paste the outputs of Steps 1, 3, 4, and 6 into the PR description under a `## Validation evidence — end-to-end smoke` block. The automated wrapper writes this file for you under `.copilot-tracking/smoke/glossary-<UTC>.md`; the manual path requires the operator to assemble it.

## References

- [Atlas Glossary REST API](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary)
- [Understand business glossary features in Microsoft Purview](https://learn.microsoft.com/en-us/purview/concept-business-glossary)
- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
- [`docs/solutions/data-map/glossary.md`](../solutions/data-map/glossary.md) — operational guide for the reconciler.
