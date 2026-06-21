# Runbook: end-to-end smoke test for DSPM for AI posture

Use this runbook to validate that the [`data-plane/dspm-ai/dspm-ai-config.yaml`](../../data-plane/dspm-ai/dspm-ai-config.yaml) desired-state surface and the read-only [`scripts/Test-DSPMforAIPosture.ps1`](../../scripts/Test-DSPMforAIPosture.ps1) verifier exercise end-to-end against the `contoso.onmicrosoft.com` tenant. Authored under issue [#368](../../issues/368) as the Phase 3 end-to-end verification path for the v2 §5.4 DSPM for AI watch-list re-verification.

## Read-only by construction

Per [ADR 0022](../adr/0022-dspm-for-ai-authoring-surface.md), Microsoft Learn documents **no programmatic authoring API** for [Microsoft Purview DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai). The "Activate Microsoft Purview for AI" path is a one-click portal action that fans out to already-shipped surfaces (DLP, IRM, Communication Compliance, audit) governed by their own waves. This runbook is therefore read-only by construction — no reconciler, no throwaway policy, no destructive cleanup.

## When to run

- After any breaking change to [`scripts/Test-DSPMforAIPosture.ps1`](../../scripts/Test-DSPMforAIPosture.ps1) or [`data-plane/dspm-ai/dspm-ai-config.schema.json`](../../data-plane/dspm-ai/dspm-ai-config.schema.json).
- When the v2 §5.4 PR re-enters the build loop.
- Quarterly as a watch-list re-verification: confirm none of the four [ADR 0022](../adr/0022-dspm-for-ai-authoring-surface.md) §"Re-open triggers" has fired.

The runbook is operator-driven by design. Per the artifact-resolver agent contract, AI agents cannot execute live-tenant calls against the Microsoft Purview account; the operator runs each step by hand and pastes captured output into the PR opened by `@artifact-resolver`.

## Automated path — `Invoke-DSPMforAISmokeTest.ps1`

[`scripts/Invoke-DSPMforAISmokeTest.ps1`](../../scripts/Invoke-DSPMforAISmokeTest.ps1) wraps Step 1 below as a single near-unattended operator command and writes a timestamped Markdown evidence file under `.copilot-tracking/smoke/dspm-for-ai-<UTC>.md` ready to paste into the v2 §5.4 close-out PR. The manual step below remains the authoritative source-of-truth and the fallback path.

Preconditions (same as the manual path's [Preconditions](#preconditions) table):

```pwsh
cd C:\REPO\Purview-as-Code-Generic
./scripts/Invoke-DSPMforAISmokeTest.ps1
```

The wrapper:

- Runs `Test-DSPMforAIPosture.ps1 -ConnectTenant` and asserts no row has `Status='Fail'` (Warn rows are tolerated).
- Writes a per-step evidence table to `.copilot-tracking/smoke/dspm-for-ai-<UTC>.md`.

Exit codes: `0` step PASSED, `1` step FAILED, `2` preconditions failed.

## Watch-list re-verification (in addition to Step 1)

Per [ADR 0022](../adr/0022-dspm-for-ai-authoring-surface.md) §"Re-open triggers", the lifecycle review must also confirm the four conditions below remain cold. Re-fetch each URL and grep for the cited markers; any non-zero hit means ADR 0022 should be re-opened with a follow-up ADR rather than the v2 §5.4 row ticked.

| # | Trigger | URL | Markers to grep (case-insensitive) |
|---|---|---|---|
| 1 | Graph resource | [Security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview) | `dspmForAi`, `aiInteraction`, `copilotPolicy` |
| 2 | Programmatic section on DSPM for AI pages | [DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai) + [Considerations](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations) + [Permissions](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions) + [Get started](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview) | `PowerShell`, `cmdlet`, `REST API`, `graph.microsoft`, `programmat` |
| 3 | MS-published reference repo sample | `github.com/microsoft/*` + `github.com/MicrosoftDocs/*` | DSPM-for-AI policy authoring sample |
| 4 | Communication Compliance cascade reversal | [ADR 0019](../adr/0019-cc-graph-pivot.md) watch-list status | CC gains a documented authoring surface |

## Preconditions

| Item | Check |
|---|---|
| `az login` against the lab tenant | `az account show` returns the `contoso.onmicrosoft.com` tenant. |
| Key Vault access | Caller has `Key Vault Crypto User` + `Key Vault Certificate User` on `kv-contoso-lab-01`. |
| Working tree clean under `data-plane/dspm-ai/**` | `git status -s data-plane/dspm-ai/` returns empty. |
| Required modules | `Get-Module -ListAvailable powershell-yaml, ExchangeOnlineManagement` returns both. |
| Unified audit log enabled | `Get-AdminAuditLogConfig` returns `UnifiedAuditLogIngestionEnabled = True` per [Audit log enable / disable](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable). |
| AI role groups provisioned | `Get-RoleGroup -Identity DataSecurityAIAdmins`, `DataSecurityAIContentViewers`, `DataSecurityAIViewers` all return a role group. Provisioned via [`scripts/Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) from [`data-plane/purview-role-groups/role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml). |

## Step 1 — `Test-DSPMforAIPosture -ConnectTenant`

```pwsh
./scripts/Test-DSPMforAIPosture.ps1 -ConnectTenant | Format-Table -AutoSize
```

Expected output (every row `Status = OK`):

```text
Check                Status Detail
-----                ------ ------
Load YAML            OK     Loaded '.../data-plane/dspm-ai/dspm-ai-config.yaml'
Schema valid         OK     .../data-plane/dspm-ai/dspm-ai-config.schema.json
scope.labels.source  OK     data-plane/information-protection/labels.yaml
scope.labels.include OK     10 label(s) in scope
scope.workloads      OK     M365Copilot, CopilotForSecurity, CopilotStudio
scope.roleGroups     OK     DataSecurityAIAdmins, DataSecurityAIContentViewers, DataSecurityAIViewers
posture.cadence      OK     weekly
Parameters file      OK     infra/parameters/lab.yaml
Azure CLI session    OK     Subscription '<sub-name>'
Data-plane app       OK     gh-oidc-purview-data-plane
IPPS session         OK     Connected to <tenant>
Unified audit log    OK     UnifiedAuditLogIngestionEnabled = True
RoleGroup DataSecurityAIAdmins          OK Exists in tenant
RoleGroup DataSecurityAIContentViewers  OK Exists in tenant
RoleGroup DataSecurityAIViewers         OK Exists in tenant
Label Confidential                      OK Published
... (one OK row per resolved label)
```

A `Fail` row in this step stops the smoke. The most common cause is an unprovisioned AI role group — verify [`data-plane/purview-role-groups/role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) was applied recently.

## Evidence to paste into the PR

If running the manual path, paste:

1. The full `Test-DSPMforAIPosture -ConnectTenant` table from Step 1.
2. The watch-list re-verification table showing every trigger still cold.

If running `Invoke-DSPMforAISmokeTest.ps1`, paste the contents of the generated `.copilot-tracking/smoke/dspm-for-ai-<UTC>.md` evidence file plus the watch-list table.

## Hard rules

1. **Never modify the YAML to claim policies exist.** Per [ADR 0022](../adr/0022-dspm-for-ai-authoring-surface.md), [`dspm-ai-config.yaml`](../../data-plane/dspm-ai/dspm-ai-config.yaml) intentionally omits a `policies:` field. Adding one without a superseding ADR is a hard rule violation.
2. **Never consume the Microsoft Purview portal's internal REST traffic** by reverse-engineering the browser dev-tools network tab. ADR 0022 §6 explicitly forbids this.
3. **Never bypass `-ConnectTenant` and claim a tenant smoke pass.** Local-only `Test-DSPMforAIPosture` is the schema/lint check; only `-ConnectTenant` exercises the audit-log + role-group + label-published prerequisites.
