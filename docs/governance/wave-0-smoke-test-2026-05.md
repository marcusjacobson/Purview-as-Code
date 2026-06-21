# Wave 0 phase-0 smoke test — 2026-05-04

> Read-only verification of every ticked Wave 0 deliverable in
> [`docs/project-plan.md`](../project-plan.md) §"Progress checklist". Captured
> before Wave 1 (Information Protection) work begins so that any drift is
> caught before label / SIT work depends on it.

## Run metadata

| Field | Value |
|---|---|
| Date | 2026-05-04 |
| Branch | `test/w0-phase-0-smoke-test` |
| Base commit | `93c75f2` (PR #105 merged) |
| Tracking issue | #106 |
| Subscription | `00000000-0000-0000-0000-000000000000` (redacted) |
| Tenant | `00000000-0000-0000-0000-000000000000` (redacted, `contoso.onmicrosoft.com`) |
| Resource group (lab reality) | `rg-purview-lab` |
| Purview account (lab reality) | `purview-contoso-lab` |
| Region | `eastus` |

> **Identifier redaction.** All tenant, subscription, application, service
> principal, and user object IDs in this document are replaced with the
> zero-GUID placeholder (`00000000-0000-0000-0000-000000000000`) per the
> "Environment and identifier boundaries" section of
> [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)
> and per [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md).
> Real values were observed during the run and are not committed.

<!-- separator between adjacent callouts -->

> **Scope correction.** [`docs/project-plan.md`](../project-plan.md) §1 and
> the "Environment and identifier boundaries" section of
> [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)
> name the lab resources as `contoso-lab-purview` in
> `rg-purview-lab`. The live lab is `purview-contoso-lab` in
> `rg-purview-lab`. This document records the verification against lab
> reality. The repo / lab name reconciliation is tracked in **#109** and is
> the only blocker before Wave 1 starts.

## Summary table

| § | Wave 0 row | Verdict |
|---|---|---|
| 1 | `infra/modules/rbac.bicep` | pass (file present, lints) |
| 2 | `scripts/Grant-PurviewDataMapRole.ps1` | pass (file present, lints) — deferred-deploy per Wave 3a |
| 3 | `scripts/Grant-PurviewRoleGroup.ps1` | pass (file present, lints) — live verification deferred (S&C PowerShell) |
| 4 | `data-plane/purview-role-groups/role-groups.yaml` | pass (default-empty as designed) |
| 5 | `scripts/Deploy-PurviewRoleGroups.ps1` | pass (file present, lints) — live verification deferred (S&C PowerShell) |
| 6 | `scripts/Grant-EntraDirectoryRole.ps1` | **drift — 8 PSSA warnings (`Invoke-GraphRequest` alias)** → #110 |
| 7 | `data-plane/entra-directory-roles/role-assignments.yaml` | pass (default-empty as designed) |
| 8 | `scripts/Deploy-EntraDirectoryRoles.ps1` | **drift — 6 PSSA warnings (`Invoke-GraphRequest` alias)** → #110 |
| 9 | `scripts/Enable-UnifiedAuditLog.ps1` | pass (file present, lints) — live state requires S&C PowerShell, deferred |
| 10 | `infra/modules/law.bicep` + `scripts/New-LogAnalyticsWorkspace.ps1` | pass (LAW deployed, `log-contoso-lab` PerGB2018 30d) |
| 11 | `infra/modules/keyvault.bicep` + `scripts/New-AutomationKeyVault.ps1` | pass (KV deployed, RBAC enabled, purge-protected, soft-delete 90d, `publicNetworkAccess: Disabled`) |
| 12 | `scripts/New-AutomationEntraApp.ps1` | pass (two Entra apps with OIDC fed-creds) |
| 13 | `scripts/New-AutomationCertificate.ps1` | verification-deferred (KV firewall blocks local data-plane reads) |
| 14 | `infra/modules/automation-rbac.bicep` + `scripts/New-AutomationRbac.ps1` | pass (RBAC observed on RG + KV) |
| 15 | `.github/workflows/validate-oidc-auth.yml` | pass (run #3 success on `main` 2026-04-26) |
| 16 | `scripts/Test-M365Licensing.ps1` | pass (file present, lints) — live verification deferred (M365) |
| 17 | #61 — `docs/governance/administrative-units.md` | pass (file present) |
| 18 | #62 — `data-plane/administrative-units/administrative-units.yaml` + `scripts/Deploy-AdministrativeUnits.ps1` | pass (default-empty YAML, script lints) — live verification deferred (Graph) |
| 19 | GitHub Actions OIDC auth to Azure ARM and S&C PowerShell | partial pass — Azure ARM verified via `validate-oidc-auth` run #3; S&C PowerShell auth pathway exists in scripts but no validating workflow run captured |

**Follow-up issues filed:**

- #109 — `fix(repo)`: reconcile Purview account + RG names to lab reality (`purview-contoso-lab` / `rg-purview-lab`).
- #110 — `fix(scripts)`: replace `Invoke-GraphRequest` alias with `Invoke-MgGraphRequest` in `Deploy-EntraDirectoryRoles.ps1` and `Grant-EntraDirectoryRole.ps1` (14 PSSA warnings).
- (observation, not blocking) `pr-owner-gate.yml` workflow has 3 recent failure runs on `main`. Out of scope for Wave 0; flagged for separate triage.

**Blockers for Wave 1 kickoff:** #109 must merge before any Bicep `what-if` against `infra/main.bicep` is meaningful. #110 is a P2 lint-only fix and does not block Wave 1.

---

## §1. `infra/modules/rbac.bicep`

```pwsh
Test-Path infra/modules/rbac.bicep
az bicep lint --file infra/modules/rbac.bicep
```

Output: file exists; lint clean (no warnings or errors). Confirmed in latest `validate.yml` run #147 (success, 2026-05-04).

**Verdict:** pass.

## §2. `scripts/Grant-PurviewDataMapRole.ps1`

```pwsh
Test-Path scripts/Grant-PurviewDataMapRole.ps1
Invoke-ScriptAnalyzer -Path scripts/Grant-PurviewDataMapRole.ps1 -Severity Warning,Error
```

Output: file exists; PSSA reports 0 errors, 0 warnings. Live data-map role assignment is deferred to Wave 3a per the Progress checklist annotation.

**Verdict:** pass.

## §3. `scripts/Grant-PurviewRoleGroup.ps1`

PSSA: 0 errors, 0 warnings. Live verification requires Security & Compliance PowerShell session (`Connect-IPPSSession`); not run in this smoke test (read-only against Azure plane only).

**Verdict:** pass (static); live verification deferred.

## §4. `data-plane/purview-role-groups/role-groups.yaml`

```pwsh
Get-Content data-plane/purview-role-groups/role-groups.yaml | Select-Object -Last 5
```

Output: file ends with the documented default-empty `roleGroups: []` block plus the `default steady state empty` first-run-bootstrap notes. Matches ADR 0009 expectation.

**Verdict:** pass.

## §5. `scripts/Deploy-PurviewRoleGroups.ps1`

PSSA: 0 errors, 0 warnings. Live `-WhatIf` requires S&C PowerShell auth; deferred.

**Verdict:** pass (static); live verification deferred.

## §6. `scripts/Grant-EntraDirectoryRole.ps1`

```pwsh
Invoke-ScriptAnalyzer -Path scripts/Grant-EntraDirectoryRole.ps1 -Severity Warning,Error
```

Output (8 hits, all on the same rule):

```text
RuleName                  Line
--------                  ----
PSAvoidUsingCmdletAliases  390
PSAvoidUsingCmdletAliases  410
PSAvoidUsingCmdletAliases  431
PSAvoidUsingCmdletAliases  457
PSAvoidUsingCmdletAliases  479
PSAvoidUsingCmdletAliases  482
PSAvoidUsingCmdletAliases  503
PSAvoidUsingCmdletAliases  506
```

All 8 are `Invoke-GraphRequest` (alias) → should be `Invoke-MgGraphRequest`. The pre-commit checklist in [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) requires `Invoke-ScriptAnalyzer` to pass. These are warnings (not errors), but lint cleanliness has been the standing convention.

**Verdict:** drift. Filed as #110.

## §7. `data-plane/entra-directory-roles/role-assignments.yaml`

```pwsh
Get-Content data-plane/entra-directory-roles/role-assignments.yaml | Select-String -Pattern '^directoryRoles:' -Context 0,5
```

Output: `directoryRoles: []` block present after preamble; matches default-empty steady state.

**Verdict:** pass.

## §8. `scripts/Deploy-EntraDirectoryRoles.ps1`

PSSA: 0 errors, 6 warnings — all `PSAvoidUsingCmdletAliases` for `Invoke-GraphRequest` (lines 375, 390, 418, 445, 922, 958). Same root cause as §6.

**Verdict:** drift. Bundled into #110.

## §9. `scripts/Enable-UnifiedAuditLog.ps1`

PSSA: 0 errors, 0 warnings. Live verification requires `Connect-ExchangeOnline` against the lab tenant and `Get-AdminAuditLogConfig`; not in scope for this smoke test.

**Verdict:** pass (static); live verification deferred.

## §10. `infra/modules/law.bicep` + `scripts/New-LogAnalyticsWorkspace.ps1`

```pwsh
az monitor log-analytics workspace show -g rg-purview-lab -n log-contoso-lab `
  --query "{name:name, sku:sku.name, retentionInDays:retentionInDays, provisioningState:provisioningState}" -o json
```

Output:

```json
{
  "name": "log-contoso-lab",
  "provisioningState": "Succeeded",
  "retentionInDays": 30,
  "sku": "PerGB2018"
}
```

LAW deployed, healthy, PerGB2018 SKU with 30-day retention. PSSA on the script: clean. Bicep module lints clean (validate.yml #147 success).

**Verdict:** pass.

## §11. `infra/modules/keyvault.bicep` + `scripts/New-AutomationKeyVault.ps1`

```pwsh
az keyvault show -n kv-contoso-lab-01 -g rg-purview-lab `
  --query "{rbac:properties.enableRbacAuthorization, purge:properties.enablePurgeProtection, softDelete:properties.softDeleteRetentionInDays, pubNet:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass}" -o json
```

Output:

```json
{
  "rbac": true,
  "purge": true,
  "softDelete": 90,
  "pubNet": "Disabled",
  "defaultAction": "Deny",
  "bypass": "AzureServices"
}
```

All security-instructions.md rule #5 (network isolation) and credential-management defaults are satisfied: RBAC mode, purge protection on, 90-day soft-delete, public access disabled with `Bypass: AzureServices` (Trusted-Microsoft-Services pathway). No private endpoint connection (`privateEndpointConnections.Count == 0`) — acceptable for the lab because the workflow-side firewall toggle in §15 opens narrow ingress for CI runs.

**Verdict:** pass.

## §12. `scripts/New-AutomationEntraApp.ps1`

```pwsh
az ad sp show --id <appId-1> --query "{displayName:displayName, type:servicePrincipalType}" -o json
az ad sp show --id <appId-2> --query "{displayName:displayName, type:servicePrincipalType}" -o json
az ad app federated-credential list --id <appId-1> --query "[].{name:name, subject:subject, issuer:issuer, audiences:audiences}"
az ad app federated-credential list --id <appId-2> --query "[].{name:name, subject:subject, issuer:issuer, audiences:audiences}"
```

Output (redacted):

| Display name | Federated cred subject | Issuer | Audience |
|---|---|---|---|
| `gh-oidc-purview-control-plane` | `repo:contoso/Purview-as-Code-Generic:environment:lab` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` |
| `gh-oidc-purview-data-plane`    | `repo:contoso/Purview-as-Code-Generic:environment:lab` | `https://token.actions.githubusercontent.com` | `api://AzureADTokenExchange` |

Both apps exist with OIDC federated credentials scoped to the `lab` GitHub Environment per security-instructions.md rule #3 (OIDC over stored client secrets). PSSA on the script: clean.

**Verdict:** pass.

## §13. `scripts/New-AutomationCertificate.ps1`

```pwsh
az keyvault certificate list --vault-name kv-contoso-lab-01 -o table
```

Output:

```text
ERROR: (Forbidden) Public network access is disabled and request is not from a trusted service nor via an approved private link.
```

Expected behavior: KV firewall denies the local developer client. Cert presence cannot be confirmed from this machine. The `validate-oidc-auth.yml` workflow (§15) is the supported path for a CI-side `az keyvault certificate list` against this vault. PSSA on the script: clean.

**Verdict:** verification-deferred (the firewall behavior is the security control we want; deferring this row is by design, not drift).

## §14. `infra/modules/automation-rbac.bicep` + `scripts/New-AutomationRbac.ps1`

```pwsh
az role assignment list --scope "/subscriptions/<sub>/resourceGroups/rg-purview-lab" -o table
$kvId = az keyvault show -n kv-contoso-lab-01 -g rg-purview-lab --query id -o tsv
az role assignment list --scope $kvId --query "[].{role:roleDefinitionName, type:principalType}" -o table
```

Output (redacted):

```text
# rg-purview-lab
Principal                              Role         Scope
00000000-0000-0000-0000-000000000000   Contributor  /subscriptions/.../resourceGroups/rg-purview-lab
                                                    (gh-oidc-purview-control-plane)

# kv-contoso-lab-01
Role                            PrincipalType
------------------------------  ----------------
Key Vault Certificates Officer  ServicePrincipal  (gh-oidc-purview-data-plane)
Key Vault Crypto User           ServicePrincipal  (gh-oidc-purview-data-plane)
```

Two automation Entra apps present with the expected least-privilege roles:

- `gh-oidc-purview-control-plane` → `Contributor` on the resource group (per security-instructions.md rule #4: not subscription-wide).
- `gh-oidc-purview-data-plane` → `Key Vault Certificates Officer` + `Key Vault Crypto User` on the KV (cert lifecycle + key-cryptographic operations only).

Bicep module + PowerShell wrapper lint clean.

**Verdict:** pass.

## §15. `.github/workflows/validate-oidc-auth.yml` Key Vault firewall toggle

```pwsh
gh run list --workflow validate-oidc-auth.yml --limit 5 --json status,conclusion,createdAt,headBranch,name,number
```

Output:

```json
[
  {"number":3,"conclusion":"success","headBranch":"main","createdAt":"2026-04-26T00:59:25Z"},
  {"number":2,"conclusion":"failure","headBranch":"main","createdAt":"2026-04-26T00:39:55Z"},
  {"number":1,"conclusion":"failure","headBranch":"main","createdAt":"2026-04-25T23:32:27Z"}
]
```

Most recent run on `main` succeeded; earlier two failures preceded the final fix. Workflow exists, the firewall-toggle pathway works end-to-end against the live KV.

**Verdict:** pass.

## §16. `scripts/Test-M365Licensing.ps1`

PSSA: 0 errors, 0 warnings. Live verification requires `Connect-MgGraph -Scopes Organization.Read.All` against the lab tenant; not run in this read-only Azure-only smoke test (ADR 0001 covers the design).

**Verdict:** pass (static); live verification deferred.

## §17. #61 — `docs/governance/administrative-units.md`

```pwsh
Test-Path docs/governance/administrative-units.md
```

Output: file exists. ADR 0002 covers the design.

**Verdict:** pass.

## §18. #62 — `data-plane/administrative-units/administrative-units.yaml` + `scripts/Deploy-AdministrativeUnits.ps1`

```pwsh
Get-Content data-plane/administrative-units/administrative-units.yaml | Select-String -Pattern '^administrativeUnits:' -Context 0,3
Invoke-ScriptAnalyzer -Path scripts/Deploy-AdministrativeUnits.ps1 -Severity Warning,Error
```

Output: YAML default-empty list per ADR 0002 decision #2; PSSA clean (0 errors, 0 warnings). Live `-WhatIf` against Microsoft Graph not run in this smoke test (read-only Azure-only scope).

**Verdict:** pass.

## §19. GitHub Actions OIDC auth to Azure ARM and S&C PowerShell

- **Azure ARM:** verified — `validate-oidc-auth.yml` run #3 succeeded on `main` 2026-04-26 using the `gh-env-lab` federated credential on `gh-oidc-purview-control-plane`.
- **S&C PowerShell:** the data-plane Entra app `gh-oidc-purview-data-plane` has the same `gh-env-lab` federated credential. No workflow run was captured during this smoke test that exercises `Connect-IPPSSession` end-to-end. The pathway exists in `Connect-Purview.ps1` / `Get-PurviewIPPSAccessToken.ps1` but is not validated in CI.

**Verdict:** partial pass. ARM side verified live; S&C side covered by code but not by a green workflow run. Consider adding a thin `validate-oidc-auth-ipps.yml` smoke workflow as a Wave 0 follow-up.

---

## Out-of-scope observations

1. **`pr-owner-gate.yml` recent failures.** Three failure runs on 2026-05-04 (run #29 on `main`, #30 on `docs/charter-tester-validator-adr-0014-alignment`, #31 on `main`). Not a Wave 0 row; flagged here for visibility. Triage as a separate issue if it persists.
2. **`deploy-infra.yml` historical failure.** Single run on 2026-04-18 ended in failure. Consistent with the #109 naming drift (a `what-if` against the documented `contoso-lab-purview` name in `rg-purview-lab` cannot succeed against `purview-contoso-lab` / `rg-purview-lab`). Resolves with #109.
3. **`deploy-data-plane.yml` never run.** Expected — Wave 0 deliverables don''t exercise the data-plane workflow path; Waves 1–4 will.

## Wave 1 readiness

Wave 1 is **not yet ready to start.** Required precondition before opening any Wave 1 issue:

- [ ] **#109** merged — repo names reconciled to lab reality so `infra/main.bicep` `what-if` and `deploy-infra.yml` are meaningful again.

Recommended (not blocking):

- [ ] **#110** merged — drop the `Invoke-GraphRequest` alias in the two Entra-directory-role scripts so PSSA is fully clean across `scripts/`.

When #109 is in, the next item per [`docs/project-plan.md`](../project-plan.md) §"Progress checklist" — Wave 1 — is #80 (`data-plane/classifications/sit-catalog.yaml`).

## References

- [Microsoft Purview accounts — Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts) — Fetch date: 2026-05-04.
- [Configure Azure Key Vault firewalls and virtual networks](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security) — Fetch date: 2026-05-04.
- [Use GitHub Actions to connect to Azure with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — Fetch date: 2026-05-04.
- [Configure a federated identity credential on an app](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust) — Fetch date: 2026-05-04.
- [PSScriptAnalyzer rule: PSAvoidUsingCmdletAliases](https://learn.microsoft.com/en-us/powershell/utility-modules/psscriptanalyzer/rules/avoidusingcmdletaliases) — Fetch date: 2026-05-04.
