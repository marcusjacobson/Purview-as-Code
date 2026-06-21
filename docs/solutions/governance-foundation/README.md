# Governance foundation

Process documentation for the Wave 0 governance primitives shipped by the v1 Purview-as-Code build. These orchestrators and reconcilers establish the identity, audit, and RBAC surfaces that every later Purview solution depends on. Read top-down: each page assumes the rows above it have run.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`m365-licensing.md`](m365-licensing.md) | Tenant license preflight called by every M365 / Purview deploy. | [`scripts/Test-M365Licensing.ps1`](../../../scripts/Test-M365Licensing.ps1), [ADR 0001](../../adr/0001-m365-licensing-verification.md) |
| [`log-analytics.md`](log-analytics.md) | Log Analytics workspace that backs the Key Vault `AuditEvent` sink. | [`infra/modules/law.bicep`](../../../infra/modules/law.bicep), [`scripts/New-LogAnalyticsWorkspace.ps1`](../../../scripts/New-LogAnalyticsWorkspace.ps1) |
| [`automation-identity.md`](automation-identity.md) | Two OIDC apps + Key Vault + certificate + RBAC for unattended automation. | `New-AutomationKeyVault.ps1`, `New-AutomationEntraApp.ps1`, `New-AutomationCertificate.ps1`, `New-AutomationRbac.ps1`, [ADR 0010](../../adr/0010-automation-identity-subject-model.md), [ADR 0011](../../adr/0011-certificate-lifecycle.md) |
| [`audit-log.md`](audit-log.md) | Tenant Unified Audit Log ingestion toggle. | [`scripts/Enable-UnifiedAuditLog.ps1`](../../../scripts/Enable-UnifiedAuditLog.ps1) |
| [`rbac.md`](rbac.md) | Three-plane RBAC primitives (Azure / Purview catalog / Entra). | [`infra/modules/rbac.bicep`](../../../infra/modules/rbac.bicep), `Grant-PurviewDataMapRole.ps1`, `Grant-PurviewRoleGroup.ps1`, `Grant-EntraDirectoryRole.ps1` |
| [`purview-role-groups.md`](purview-role-groups.md) | Declarative reconciler for Microsoft Purview / M365 portal role-group membership. | [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1), [ADR 0009](../../adr/0009-portal-role-group-api-ship-order.md) |
| [`role-group-entra-backing.md`](role-group-entra-backing.md) | Microsoft Graph reconciler that provisions one `sg-purview-<slug>` Entra security group per portal role group declared in `role-groups.yaml`. | [`scripts/Deploy-RoleGroupBackingEntraGroups.ps1`](../../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1), [ADR 0025](../../adr/0025-role-group-entra-backing-naming.md) |
| [`entra-directory-roles.md`](entra-directory-roles.md) | Declarative reconciler for the three Purview-relevant Entra directory roles. | [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../../scripts/Deploy-EntraDirectoryRoles.ps1) |
| [`administrative-units.md`](administrative-units.md) | Entra administrative-unit lifecycle. | [`scripts/Deploy-AdministrativeUnits.ps1`](../../../scripts/Deploy-AdministrativeUnits.ps1), [ADR 0002](../../adr/0002-administrative-units.md), [governance/administrative-units.md](../../governance/administrative-units.md) |

## How this section relates to the rest of the repo

- **Infrastructure (control plane).** The Bicep modules under [`infra/modules/`](../../../infra/modules/) define the Azure resources (Log Analytics, Key Vault, role assignments). The PowerShell scripts in this section are thin orchestrators around those modules. See [`.github/instructions/bicep.instructions.md`](../../../.github/instructions/bicep.instructions.md) for module-authoring rules.
- **Data plane.** YAML files under [`data-plane/`](../../../data-plane/) describe desired state for the role-group, directory-role, and administrative-unit reconcilers. The reconciler scripts apply those manifests via Microsoft Graph or Security & Compliance PowerShell. See [`.github/instructions/data-plane-yaml.instructions.md`](../../../.github/instructions/data-plane-yaml.instructions.md).
- **Operational runbooks.** Incident-style procedures (temp Key Vault unlock, 409 cleanup) live under [`docs/runbooks/`](../../runbooks/). This `solutions/` tree documents the steady-state configuration, not incident response.

## Conventions

- Every page that makes a product-capability or role-gating claim ends with a `## References` block per the "Evidence pattern for Microsoft Learn citations" section of [`.github/copilot-instructions.md`](../../../.github/copilot-instructions.md).
- Real tenant / subscription / object IDs never appear here. Placeholders follow the "Environment and identifier boundaries" section of the same file.
- These pages document the v1 build only. The archived strategic roadmap that produced them lives at [`docs/archive/project-plan-v1.md`](../../archive/project-plan-v1.md); the live v2 roadmap is at [`docs/project-plan.md`](../../project-plan.md).
