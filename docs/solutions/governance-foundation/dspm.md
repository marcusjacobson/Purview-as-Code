# Data Security Posture Management (DSPM) — signal-source verifier and Content Explorer exporter

Operational guide for the two read-only DSPM helpers — [`scripts/Test-DSPMPosture.ps1`](../../../scripts/Test-DSPMPosture.ps1) and [`scripts/Export-ContentExplorerData.ps1`](../../../scripts/Export-ContentExplorerData.ps1) — that materialize the [`data-plane/dspm/dspm-config.yaml`](../../../data-plane/dspm/dspm-config.yaml) declarative surface against the [Microsoft Purview DSPM](https://learn.microsoft.com/en-us/purview/dspm) workload.

## Purpose

DSPM is a portal-rendered aggregator over signals authored in earlier waves — sensitivity labels, custom SITs, DLP, IRM, the unified audit log — per [Get started with DSPM](https://learn.microsoft.com/en-us/purview/dspm-get-started). There is **no `New-DSPMPolicy` cmdlet surface** to reconcile against; this domain's helpers are therefore not `Deploy-*.ps1` reconcilers. Two read-only scripts back the surface:

- **[`Test-DSPMPosture.ps1`](../../../scripts/Test-DSPMPosture.ps1)** — schema-validates the desired-state YAML, resolves the upstream label and SIT sources, asserts the artifact directory is gitignored, and (with `-ConnectTenant`) confirms the unified audit log is enabled and the `Content Explorer List Viewer` role group exists. Zero writes.
- **[`Export-ContentExplorerData.ps1`](../../../scripts/Export-ContentExplorerData.ps1)** — pages [`Get-ContentExplorerData`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata) once per `(item, Workload)` pair across the resolved scope and writes one JSON per pair plus a `manifest.json` into `verify-dspm-export-output/<UTC>/`. Zero writes.

[ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) governs cadence (weekly Monday 07:00 UTC + `workflow_dispatch`), retention (90 days, mirroring the audit retention horizon), and scope shaping.

## Default state

The shipped YAML declares:

- `scope.labels.sources` — [`data-plane/information-protection/labels.yaml`](../../../data-plane/information-protection/labels.yaml) (10 lab-authored labels).
- `scope.sits.sources` — [`data-plane/classifications/classifications.yaml`](../../../data-plane/classifications/classifications.yaml) (1 lab-authored custom SIT).
- `scope.workloads` — `Exchange, SharePoint, OneDrive, Teams`.
- `export.cadence` — `weekly`; `retentionDays` — `90`; `throttleSeconds` — `1`; `maxRetries` — `3`.

The current resolved plan is 4 × (10 + 1) = **44 `(item, Workload)` pairs per run** — comfortably under the ~25-entry ceiling [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) "Harder" section warns about for the 6-hour GitHub Actions job ceiling. The `scope.entries.ceiling` row in `Test-DSPMPosture.ps1` (issue [#610](../../../../../issues/610)) enforces this on every PR.

### Drift closure (v2 §5.4, issue [#366](../../../../../issues/366))

The v1 scaffold (issue [#74](../../../../../issues/74)) had [`data-plane/classifications/sit-catalog.yaml`](../../../data-plane/classifications/sit-catalog.yaml) enumerated under `scope.sits.sources`. That catalog is Microsoft's 327-entry reference inventory for IP / DLP GUID lookups ([ADR 0016](../../adr/0016-auto-label-policy-shape.md) §4), not a lab-authored set the operator has applied. Enumerating it pushed the weekly run plan to ~1,352 pairs — well above the cited ceiling — and spent `Get-ContentExplorerData` quota on SITs the lab never actually classified content against. The v2 §5.4 drift closure dropped the catalog source from `scope.sits.sources`. The catalog file itself is unchanged and continues to back IP / DLP GUID references.

### Opt-in scoping for selected built-in SITs (issue [#610](../../../../../issues/610))

The follow-up shipped under [#610](../../../../../issues/610) adds two reinforcements so the drift closure cannot regress and so the lab can re-introduce specific Microsoft built-in SITs (per SIT the operator has applied) safely:

1. **Schema contract.** The `scope.labels.include` / `scope.sits.include` arrays in [`data-plane/dspm/dspm-config.schema.json`](../../../data-plane/dspm/dspm-config.schema.json) explicitly document the opt-in shape: pass a string array of names (label `displayName` for labels; SIT `name` or immutable identifier for SITs). The schema already accepted this shape — the description tightening documents it as the supported opt-in path.
2. **Ceiling guard rail.** [`scripts/Test-DSPMPosture.ps1`](../../../scripts/Test-DSPMPosture.ps1) emits a new `scope.entries.ceiling` row classifying the resolved (labels + SITs) entry count:
   - `OK` when entries ≤ 25.
   - `Warn` when entries > 25 and ≤ 100.
   - `Fail` when entries > 100.

   Thresholds are pinned to [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) "Harder" section (`"if either set grows past ~25 entries, the run wall-clock crosses the 6-hour GitHub Actions job ceiling"`). Any future re-tune requires an amendment to ADR 0021, not an inline code change. The `Fail` threshold at 100 entries (4× Warn) keeps a small buffer for one-off explorations while still hard-stopping the pre-drift-closure 337-entry catastrophic case.

**Example — opt in to selected Microsoft built-in SITs.** The pattern below is the **only** supported way to add Microsoft built-in SITs to DSPM scope. The example lives in this solution doc, not in `dspm-config.yaml` itself, so it cannot be copy-pasted into real config without a deliberate edit:

```yaml
# data-plane/dspm/dspm-config.yaml — opt-in scoping example
scope:
  sits:
    sources:
      - data-plane/classifications/classifications.yaml
      - data-plane/classifications/sit-catalog.yaml  # required so include[] can resolve
    include:
      - CUSTOM.EmployeeId                       # lab-authored, from classifications.yaml
      - U.S. Social Security Number (SSN)       # built-in, from sit-catalog.yaml
      - Credit Card Number                      # built-in, from sit-catalog.yaml
```

`Test-DSPMPosture.ps1` resolves `include[]` against the union of `sources[]`, surfaces any requested-but-missing name via the `scope.sits.include` row, and runs the resolved count through the ceiling guard rail. Adding `sit-catalog.yaml` back as a source is **only** safe when paired with an explicit `include[]` array — leaving `include: all` re-enumerates the full 327 entries and trips the `Fail` row.

## Authentication

Same Key Vault-signed JWT path as every other Security & Compliance helper in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate's underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Script | Key parameters | Default source in `lab.yaml` |
|---|---|---|
| `Test-DSPMPosture.ps1` | `-Path`, `-ConnectTenant`, `-ParametersFile`, `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, `-TenantDomain`, `-SkipSchemaValidation` | `data-plane/dspm/dspm-config.yaml`; rest resolve from `infra/parameters/lab.yaml` when `-ConnectTenant` is supplied |
| `Export-ContentExplorerData.ps1` | `-Path`, `-ParametersFile`, `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, `-TenantDomain`, `-OutputRoot`, `-PageSize`, `-WhatIf` | same; `-OutputRoot` defaults to `<repoRoot>/verify-dspm-export-output` |

## Source-of-truth direction policy ([ADR 0029](../../adr/0029-source-of-truth-direction-policy.md))

**N/A for DSPM.** Both scripts are read-only verifiers/exporters with no mutating cmdlet path — there is nothing to reconcile in either direction. The `-DirectionPolicy` / `-SkipNames` / `confirm_overwrite_*` contract that the §5.2 / §5.3 reconcilers carry does not apply here.

## Schema

YAML conforms to [`data-plane/dspm/dspm-config.schema.json`](../../../data-plane/dspm/dspm-config.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Content Explorer List Viewer` | Tenant — minimum role for `Get-ContentExplorerData` per [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) |
| Data-plane OIDC service principal (for `-ConnectTenant` in the verifier) | `Compliance Administrator` (or equivalent that grants `Get-AdminAuditLogConfig` + `Get-RoleGroup` read access) | Tenant |
| Caller's identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

The broader `Content Explorer Content Viewer` role is **not** requested per [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) Decision 4 and security principle #4 (least privilege).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the [`export-content-explorer.yml`](../../../.github/workflows/export-content-explorer.yml) workflow inside the shared `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network).

## Smoke test

```pwsh
# Local-only — schema + source-path + gitignore (no tenant calls).
./scripts/Test-DSPMPosture.ps1
```

Expected: 9 rows, every `Status = OK`. This is the same path the [`validate.yml`](../../../.github/workflows/validate.yml) `dspm-posture` job runs on every PR.

For an end-to-end live-tenant smoke (`Test-DSPMPosture -ConnectTenant` → `Export-ContentExplorerData` → manifest assertion), follow [`docs/runbooks/dspm-end-to-end-smoke.md`](../../runbooks/dspm-end-to-end-smoke.md) or run the wrapper:

```pwsh
./scripts/Invoke-DSPMSmokeTest.ps1
```

## CI wiring

Two workflow steps cover this domain:

- **[`validate.yml`](../../../.github/workflows/validate.yml) `dspm-posture` job** — runs `Test-DSPMPosture.ps1` (local-only, no `-ConnectTenant`) on every PR. Fails the run if any `Status='Fail'` row is reported. Read-only gate.
- **[`export-content-explorer.yml`](../../../.github/workflows/export-content-explorer.yml)** — `schedule: '0 7 * * 1'` (Mondays 07:00 UTC) + `workflow_dispatch`. Invokes [`Export-ContentExplorerData.ps1`](../../../scripts/Export-ContentExplorerData.ps1) under the data-plane OIDC identity and uploads `verify-dspm-export-output/**` as a 90-day GitHub Actions artifact per [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) Decision 5.

## Related ADRs and runbooks

- [ADR 0021 — DSPM Content Explorer cadence](../../adr/0021-dspm-content-explorer-cadence.md)
- [Runbook — DSPM end-to-end smoke](../../runbooks/dspm-end-to-end-smoke.md)
- Sibling domain (read-only posture verifier): [`dspm-ai-config.yaml`](../../../data-plane/dspm-ai/dspm-ai-config.yaml) (§5.4 row 2, issue [#368](../../../../../issues/368))
