# Runbook: end-to-end smoke test for DSPM signal-source posture

Use this runbook to validate that the [`data-plane/dspm/dspm-config.yaml`](../../data-plane/dspm/dspm-config.yaml) desired-state surface and the two read-only DSPM helpers — [`scripts/Test-DSPMPosture.ps1`](../../scripts/Test-DSPMPosture.ps1) and [`scripts/Export-ContentExplorerData.ps1`](../../scripts/Export-ContentExplorerData.ps1) — exercise end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#366](../../issues/366) as the Phase 3 end-to-end verification path for the v2 §5.4 DSPM lifecycle.

## Read-only by construction

Microsoft Purview Data Security Posture Management (DSPM) is a portal-rendered aggregator over signals authored in earlier waves (sensitivity labels, custom SITs, DLP, IRM, the unified audit log) per [Learn about DSPM](https://learn.microsoft.com/en-us/purview/dspm). There is no `New-DSPMPolicy` cmdlet surface, and [`Get-ContentExplorerData`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata) is a read API. Every step in this runbook is read-only — there is no destructive cleanup, no throwaway policy, and no `-PruneMissing` / `-Force` toggle.

## When to run

- After any breaking change to [`scripts/Test-DSPMPosture.ps1`](../../scripts/Test-DSPMPosture.ps1), [`scripts/Export-ContentExplorerData.ps1`](../../scripts/Export-ContentExplorerData.ps1), or [`data-plane/dspm/dspm-config.schema.json`](../../data-plane/dspm/dspm-config.schema.json).
- When the v2 §5.4 PR re-enters the build loop.
- Optional: re-run quarterly as a regression check, mirroring the [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md) weekly cadence.

The runbook is operator-driven by design. Per the artifact-resolver agent contract, AI agents cannot execute live-tenant calls against the Microsoft Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-DSPMSmokeTest.ps1`

[`scripts/Invoke-DSPMSmokeTest.ps1`](../../scripts/Invoke-DSPMSmokeTest.ps1) wraps Steps 1–2 below as a single near-unattended operator command and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/dspm-<UTC>.md` ready to paste into the v2 §5.4 close-out PR. The manual steps below remain the authoritative source-of-truth and the fallback path; the wrapper invokes [`Test-DSPMPosture.ps1`](../../scripts/Test-DSPMPosture.ps1) and [`Export-ContentExplorerData.ps1`](../../scripts/Export-ContentExplorerData.ps1) verbatim and introduces no new auth path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-DSPMSmokeTest.ps1
```

The wrapper:

- Runs `Test-DSPMPosture.ps1 -ConnectTenant` and asserts no row has `Status='Fail'`.
- Runs `Export-ContentExplorerData.ps1`, locates the latest `verify-dspm-export-output/<UTC>/` subdirectory, reads its `manifest.json`, and asserts every `(item, Workload)` row carries `Status='OK'`.
- Writes a per-step evidence table to `.copilot-tracking/smoke/dspm-<UTC>.md`.

Exit codes: `0` every step PASSED, `1` at least one step FAILED, `2` preconditions failed.

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Key Vault access | Caller has `Key Vault Crypto User` + `Key Vault Certificate User` on `kv-contoso-lab-01`. |
| Working tree clean under `data-plane/dspm/**` | `git status -s data-plane/dspm/` returns empty. |
| Required modules | `Get-Module -ListAvailable powershell-yaml, ExchangeOnlineManagement` returns both. |
| `ContentExplorerListViewer` role | The data-plane workload identity is a member of the Microsoft Purview `Content Explorer List Viewer` role group, per [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md) Decision 4. Without it `Get-ContentExplorerData` returns 401/403. |
| Unified audit log enabled | `Get-AdminAuditLogConfig` returns `UnifiedAuditLogIngestionEnabled = True` per [Audit log enable / disable](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable). |

## Step 1 — `Test-DSPMPosture -ConnectTenant`

```pwsh
./scripts/Test-DSPMPosture.ps1 -ConnectTenant | Format-Table -AutoSize
```

Expected output (every row `Status = OK`):

```text
Check                  Status Detail
-----                  ------ ------
Load YAML              OK     Loaded '.../data-plane/dspm/dspm-config.yaml'
Schema valid           OK     .../data-plane/dspm/dspm-config.schema.json
scope.labels.source    OK     data-plane/information-protection/labels.yaml
scope.labels.include   OK     10 entry(ies) in scope
scope.sits.source      OK     data-plane/classifications/classifications.yaml
scope.sits.include     OK     1 entry(ies) in scope
scope.workloads        OK     Exchange, SharePoint, OneDrive, Teams
scope.entries.ceiling  OK     11 scope entries x 4 workloads = 44 (item, Workload) pairs per run. ADR 0021 'Harder' threshold: 25 entries.
artifactDir gitignored OK     verify-dspm-export-output
Parameters file        OK     infra/parameters/lab.yaml
Azure CLI session      OK     Subscription '<sub-name>'
Data-plane app         OK     gh-oidc-purview-data-plane
IPPS session           OK     Connected to <tenant>
Unified audit log      OK     UnifiedAuditLogIngestionEnabled = True
ContentExplorerListViewer role group OK  Exists in tenant
```

A `Fail` row in this step stops the smoke — the export step is not exercised.

## Step 2 — `Export-ContentExplorerData`

```pwsh
./scripts/Export-ContentExplorerData.ps1
```

Expected: the script pages `Get-ContentExplorerData` once per `(item, Workload)` pair across the resolved scope (10 labels + 1 custom SIT × 4 workloads = 44 pairs against the current YAML), writes one JSON per pair, and emits a `manifest.json` summarising the run into `verify-dspm-export-output/<YYYY-MM-DD-HHmm>/`.

Sanity-check the manifest:

```pwsh
$run = Get-ChildItem verify-dspm-export-output -Directory | Sort-Object Name -Descending | Select-Object -First 1
$m = Get-Content (Join-Path $run.FullName 'manifest.json') -Raw | ConvertFrom-Json
$m.rows | Group-Object Status | Format-Table -AutoSize
```

Expected: a single row group with `Name = OK` and `Count = 44`. Any non-OK row should be investigated before the PR merges — partial runs are not acceptable evidence.

## Evidence to paste into the PR

If running the manual path, paste:

1. The full `Test-DSPMPosture -ConnectTenant` table from Step 1.
2. The `Group-Object Status` table from Step 2's manifest check.
3. The path to the `manifest.json` (not its contents — exports are gitignored and may carry tenant data).

If running `Invoke-DSPMSmokeTest.ps1`, paste the contents of the generated `.copilot-tracking/smoke/dspm-<UTC>.md` evidence file plus the manifest path.

## Hard rules

1. **Never commit anything under `verify-dspm-export-output/`.** It is gitignored at repo root per [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md) Decision 5; exports may contain tenant content metadata.
2. **Never widen `scope.sits.sources` to include [`sit-catalog.yaml`](../../data-plane/classifications/sit-catalog.yaml).** That regresses the v2 §5.4 drift closure (issue [#366](../../issues/366)) and pushes the run plan above the ~25-entry ceiling [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md) "Harder" section warns about. Opt-in re-introduction of selected built-in SITs is a separate ADR.
3. **Never bypass `-ConnectTenant` and claim a tenant smoke pass.** Local-only `Test-DSPMPosture` is the schema/lint check; only `-ConnectTenant` exercises the live audit-log + role-group prerequisites.
