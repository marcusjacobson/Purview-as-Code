# RBAC primitives — three planes

This repository deliberately separates three RBAC surfaces. Mixing them breaks least privilege and produces unauditable grants. Every Wave 0 primitive below owns exactly one slice.

| Plane | Surface | Primitive | Scope |
|---|---|---|---|
| Azure RBAC (control plane) | `Microsoft.Authorization/roleAssignments` on Azure resources | [`infra/modules/rbac.bicep`](../../../infra/modules/rbac.bicep) | Subscription / resource group / individual resource |
| Microsoft Purview catalog (data plane) | `/policyStore/metadataPolicies` on a Purview account | [`scripts/Grant-PurviewDataMapRole.ps1`](../../../scripts/Grant-PurviewDataMapRole.ps1) | Collection (lowest that works) |
| Microsoft Entra directory roles | Microsoft Graph `/roleManagement/directory` (unified RBAC) | [`scripts/Grant-EntraDirectoryRole.ps1`](../../../scripts/Grant-EntraDirectoryRole.ps1) | Directory (`/`) |
| Microsoft Purview / M365 portal role groups | Security & Compliance PowerShell `Get/Add/Remove-RoleGroupMember` | [`scripts/Grant-PurviewRoleGroup.ps1`](../../../scripts/Grant-PurviewRoleGroup.ps1) | Role group (e.g. `Compliance Administrator`) |

The reconcilers ([`Deploy-PurviewRoleGroups.ps1`](purview-role-groups.md), [`Deploy-EntraDirectoryRoles.ps1`](entra-directory-roles.md)) compose over the imperative grants on this page.

## Common rules across all three planes

1. **Group-only.** Per [`security.instructions.md`](../../../.github/instructions/security.instructions.md) rule #4, every `-PrincipalId` must be the object ID of a Microsoft Entra security group, not a user. The unified APIs accept user OIDs; this repo intentionally narrows the contract.
2. **Least privilege.** Assign at the narrowest scope that satisfies the workload — collection over root, resource group over subscription, AU scope when AU support ships.
3. **Drift report first, write second.** Each primitive emits a single-row `Create / NoChange / Revoke / NoOp` drift report. Writes happen only when the caller has opted in (`-Confirm` / `-Revoke`).

## Plane 1 — Azure RBAC

Module: [`infra/modules/rbac.bicep`](../../../infra/modules/rbac.bicep). Used by [`automation-rbac.bicep`](../../../infra/modules/automation-rbac.bicep) and any future control-plane assignments.

Role-assignment names are derived from `guid(scope, principalId, roleDefinitionId)` so re-applying the same template is a no-op once converged. The module **does not** assign Purview catalog roles or Entra directory roles.

Required permission for the caller: `Microsoft.Authorization/roleAssignments/write` at the assignment scope, typically delivered via `User Access Administrator` or `Owner`. Reference: [Add or remove Azure role assignments using Bicep](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep).

## Plane 2 — Purview catalog (data plane)

Script: [`scripts/Grant-PurviewDataMapRole.ps1`](../../../scripts/Grant-PurviewDataMapRole.ps1).

Catalog roles live inside a metadata policy attached to a collection. A principal is "in" a role when its object ID is present in the `attributeValueIncludedIn` array of the matching `attributeRule.dnfCondition`.

Behaviour per invocation:

1. `GET /policyStore/metadataPolicies?collectionName={name}` (one policy per collection).
2. Locate the `attributeRule` for the target role.
3. Diff the caller-supplied `-PrincipalId` against the rule's existing membership.
4. Emit a drift row.
5. `PUT` the full policy back, only on `Create` / `Revoke`.

Allowed roles: `CollectionAdmin`, `DataSourceAdmin`, `DataCurator`, `PurviewReader`, `WorkflowAdministrator`. `PolicyAuthor` (DevOps policies) lives on `/policyStore/policies` and is out of scope for this primitive.

Default scope: caller-supplied collection. Root is named after the account, so `-CollectionName $AccountName` grants at root — but prefer the lowest collection that works per [Define least-privilege model](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#define-least-privilege-model).

## Plane 3 — Entra directory roles

Script: [`scripts/Grant-EntraDirectoryRole.ps1`](../../../scripts/Grant-EntraDirectoryRole.ps1). Reconciler: [`Deploy-EntraDirectoryRoles.ps1`](entra-directory-roles.md).

Targets the three directory roles cited as Purview-relevant in [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions):

- `Compliance Administrator`
- `Compliance Data Administrator`
- `Information Protection Administrator`

Behaviour:

1. Mint a Microsoft Graph token (delegated from `az login` for the imperative path; Key Vault-signed JWT for the reconciler path).
2. Resolve the role definition by `templateId` (recommended — immutable across tenants) or by legacy `displayName`.
3. Validate the principal is a security group with `isAssignableToRole = true` per [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept).
4. Probe existing assignments via `GET /v1.0/roleManagement/directory/roleAssignments?$filter=principalId eq ... and roleDefinitionId eq ...` filtered to `directoryScopeId eq '/'`.
5. Emit drift; `POST` or `DELETE` only when the caller opts in.

Directory scope is hardwired to `/`. AU scoping is deferred until the AU scaffold (see [`administrative-units.md`](administrative-units.md)) lists at least one AU.

## Plane 4 — Microsoft Purview / M365 portal role groups

Script: [`scripts/Grant-PurviewRoleGroup.ps1`](../../../scripts/Grant-PurviewRoleGroup.ps1). Reconciler: [`Deploy-PurviewRoleGroups.ps1`](purview-role-groups.md).

API choice and ship order are ratified by [ADR 0009](../../adr/0009-portal-role-group-api-ship-order.md) (supersedes ADR 0008). The primitive ships as Security & Compliance PowerShell only:

1. [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with a Key Vault-signed JWT (the private key never leaves Key Vault — per [ADR 0011 §3 supersession](../../adr/0011-certificate-lifecycle.md)).
2. [`Get-RoleGroupMember -Identity <RoleGroup>`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember).
3. Diff `-PrincipalId` against `ExternalDirectoryObjectId` on the member list.
4. Emit a drift row.
5. [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember) or [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember) only when the drift category requires a write.
6. [`Disconnect-ExchangeOnline -Confirm:$false`](https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline) in a `finally` block.

A future Microsoft Graph code path is documented in ADR 0009 decision §2 with the trigger condition (an Exchange / compliance / `purview` provider appearing on `rbacApplication`). No behavioural code on that path ships today.

## References

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions)
- [Roles and role groups in the Microsoft Defender / Purview portals](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/scc-permissions)
- [Microsoft Purview classic-environment permissions](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)
- [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)
- [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept)
- [`rbacApplication` resource (unified RBAC)](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication)
- [Add or remove Azure role assignments using Bicep](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep)
- [ADR 0009 — Portal role-group API ship order](../../adr/0009-portal-role-group-api-ship-order.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
