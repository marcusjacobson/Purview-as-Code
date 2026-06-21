# DSPM for AI — read-only posture verifier

Operational guide for the read-only [`scripts/Test-DSPMforAIPosture.ps1`](../../../scripts/Test-DSPMforAIPosture.ps1) verifier that materializes the [`data-plane/dspm-ai/dspm-ai-config.yaml`](../../../data-plane/dspm-ai/dspm-ai-config.yaml) declarative surface against the [Microsoft Purview DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai) workload.

## Purpose

Per [ADR 0022](../../adr/0022-dspm-for-ai-authoring-surface.md), Microsoft Learn documents **no programmatic authoring API** for DSPM for AI. The "Activate Microsoft Purview for AI" path is a one-click portal action that fans out to already-shipped surfaces (DLP, IRM, Communication Compliance, audit) governed by their own waves. This domain therefore ships a **read-only posture verifier**, not a `Deploy-*.ps1` reconciler:

- **[`Test-DSPMforAIPosture.ps1`](../../../scripts/Test-DSPMforAIPosture.ps1)** — schema-validates the desired-state YAML, resolves the upstream label sources, reports configured workloads and AI role groups, and (with `-ConnectTenant`) confirms the unified audit log is enabled, each declared AI role group exists, and each in-scope label is published. Zero writes.

There is no exporter, no scheduled workflow, no `-PruneMissing` toggle, no destructive code path.

## Default state

The shipped YAML declares:

- `scope.labels.sources` — [`data-plane/information-protection/labels.yaml`](../../../data-plane/information-protection/labels.yaml) (10 lab-authored labels).
- `scope.labels.include` — `all`.
- `scope.workloads` — `M365Copilot, CopilotForSecurity, CopilotStudio` (operators should narrow to actually-deployed Copilot surfaces).
- `scope.roleGroups` — `DataSecurityAIAdmins, DataSecurityAIContentViewers, DataSecurityAIViewers` (the three AI-specific role groups from [Permissions for Microsoft Purview AI features](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions), provisioned via [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1)).
- `posture.cadence` — `weekly` (mirrors [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) Decision 1).

### v2 §5.4 watch-list re-verification (issue [#368](../../../../../issues/368))

Closed 2026-06-14 with outcome **(B)**: ADR 0022 watch-list remains cold. All four [ADR 0022](../../adr/0022-dspm-for-ai-authoring-surface.md) §"Re-open triggers" re-verified against live Microsoft Learn pages on 2026-06-14:

| Trigger | Status | Evidence |
|---|---|---|
| 1. Graph resource (`aiInteraction`/`copilotPolicy`/`dspmForAi`) | Cold | Zero hits across the [Security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview). |
| 2. Programmatic section on DSPM-for-AI pages | Cold | Zero `PowerShell`/`cmdlet`/`REST API`/`programmat` hits on all 4 cited pages; page sizes stable (76/70/58/69 KB today vs 75/70/57/68 KB on 2026-05-17). |
| 3. MS-published reference repo sample | Cold | No new DSPM-for-AI authoring sample on `github.com/microsoft/*` or `github.com/MicrosoftDocs/*`. |
| 4. Communication Compliance cascade reversal | Cold | CC re-verified 2026-06-07 in #367; still no documented authoring surface. |

Drift closure shipped under this lifecycle: `scope.roleGroups` populated with the three AI role groups already provisioned in [`data-plane/purview-role-groups/role-groups.yaml`](../../../data-plane/purview-role-groups/role-groups.yaml). No code changes to the verifier itself.

## Authentication

Same Key Vault-signed JWT path as every other Security & Compliance helper in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate's underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Script | Key parameters | Default source in `lab.yaml` |
|---|---|---|
| `Test-DSPMforAIPosture.ps1` | `-Path`, `-ConnectTenant`, `-ParametersFile`, `-VaultName`, `-CertificateName`, `-DataPlaneAppDisplayName`, `-TenantDomain`, `-SkipSchemaValidation` | `data-plane/dspm-ai/dspm-ai-config.yaml`; rest resolve from `infra/parameters/lab.yaml` when `-ConnectTenant` is supplied |

## Source-of-truth direction policy ([ADR 0029](../../adr/0029-source-of-truth-direction-policy.md))

**N/A for DSPM for AI.** The verifier is read-only with no mutating cmdlet path — there is nothing to reconcile in either direction. The `-DirectionPolicy` / `-SkipNames` / `confirm_overwrite_*` contract that the §5.2 / §5.3 reconcilers carry does not apply here.

## Schema

YAML conforms to [`data-plane/dspm-ai/dspm-ai-config.schema.json`](../../../data-plane/dspm-ai/dspm-ai-config.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (for `-ConnectTenant`) | `Compliance Administrator` (or equivalent that grants `Get-AdminAuditLogConfig` + `Get-RoleGroup` + `Get-Label` read access) | Tenant |
| Caller's identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

The lab does not provision DSPM-for-AI portal role-group membership for any human identity via this domain; that is operator-driven post-"Activate Microsoft Purview for AI".

## Local-dev runs from outside the Key Vault network

CI runs no DSPM-for-AI step that requires `-ConnectTenant` today (the `dspm-ai-posture` validate job is local-only). For local-dev `-ConnectTenant` runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network).

## Smoke test

```pwsh
# Local-only — schema + source-path + roleGroups list (no tenant calls).
./scripts/Test-DSPMforAIPosture.ps1
```

Expected: 7 rows, every `Status = OK`. This is the same path the [`validate.yml`](../../../.github/workflows/validate.yml) `dspm-ai-posture` job runs on every PR.

For an end-to-end live-tenant smoke (`Test-DSPMforAIPosture -ConnectTenant` plus the [ADR 0022](../../adr/0022-dspm-for-ai-authoring-surface.md) watch-list re-verification table), follow [`docs/runbooks/dspm-for-ai-end-to-end-smoke.md`](../../runbooks/dspm-for-ai-end-to-end-smoke.md) or run the wrapper:

```pwsh
./scripts/Invoke-DSPMforAISmokeTest.ps1
```

## CI wiring

One workflow step covers this domain:

- **[`validate.yml`](../../../.github/workflows/validate.yml) `dspm-ai-posture` job** — runs `Test-DSPMforAIPosture.ps1` (local-only, no `-ConnectTenant`) on every PR. Fails the run if any `Status='Fail'` row is reported. Read-only gate. No scheduled live-tenant job — DSPM for AI has no exporter and no quarterly evidence cadence beyond the [ADR 0021](../../adr/0021-dspm-content-explorer-cadence.md) sibling DSPM domain.

## Related ADRs and runbooks

- [ADR 0022 — DSPM for AI authoring surface](../../adr/0022-dspm-for-ai-authoring-surface.md)
- [ADR 0019 — Communication Compliance Graph pivot](../../adr/0019-cc-graph-pivot.md) (cascade source for trigger #4)
- [ADR 0021 — DSPM Content Explorer cadence](../../adr/0021-dspm-content-explorer-cadence.md) (sibling domain)
- [Runbook — DSPM for AI end-to-end smoke](../../runbooks/dspm-for-ai-end-to-end-smoke.md)
- Sibling solution: [`dspm.md`](dspm.md)
