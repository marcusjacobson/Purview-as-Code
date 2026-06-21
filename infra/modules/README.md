# `infra/modules/`

Reusable Bicep modules consumed by [`../main.bicep`](../main.bicep). One module per resource type. Every module must follow [`.github/instructions/bicep.instructions.md`](../../.github/instructions/bicep.instructions.md) — pin a GA API version, declare `publicNetworkAccess: 'Disabled'` defaults, never output secrets, and carry a `// Reference: https://learn.microsoft.com/...` comment on every resource block.

## Planned modules

| File | Purpose | Primary Learn reference |
|---|---|---|
| `private-endpoint.bicep` | Private endpoints for Purview sub-resources (`account`, `portal`, `ingestion`) + private DNS zone group wiring | [Use private endpoints for your Microsoft Purview account](https://learn.microsoft.com/en-us/purview/catalog-private-link) |
| `diagnostic-settings.bicep` | `Microsoft.Insights/diagnosticSettings` forwarding Purview logs to a Log Analytics workspace | [Monitor Microsoft Purview](https://learn.microsoft.com/en-us/purview/how-to-manage-resources) |
| `rbac.bicep` | **Azure RBAC** role assignments only (principal → role definition GUID → narrowest Azure scope). Does not assign Purview data-plane roles (use [`scripts/Grant-PurviewDataMapRole.ps1`](../../scripts/)) or Entra directory roles (use [`scripts/Grant-M365ComplianceRoles.ps1`](../../scripts/)). | [Add or remove Azure role assignments using Bicep](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep) |
| `log-analytics.bicep` *(optional)* | Log Analytics workspace for `diagnostic-settings.bicep` when one is not already provided | [Microsoft.OperationalInsights/workspaces](https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces) |

Add a module only when `main.bicep` actually needs to consume it. Do not scaffold speculative modules.

## Authoring rules

- File name: lowercase, hyphen-separated, singular (`private-endpoint.bicep`, not `PrivateEndpoints.bicep`).
- Every module exposes parameters for the caller's naming, scope, and tags — never hard-code a name.
- Prefer an [Azure Verified Module](https://aka.ms/avm) when one exists; pin the version.
- Never `output` a secret, key, or connection string. Return only resource IDs and non-sensitive names.

Reference: [Use Bicep modules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/modules), [Best practices for Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices).
