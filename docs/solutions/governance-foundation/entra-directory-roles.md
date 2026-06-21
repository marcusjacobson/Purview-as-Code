# Entra directory-role reconciler

Operational guide for [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../../scripts/Deploy-EntraDirectoryRoles.ps1) — the declarative reconciler for the three Purview-relevant Microsoft Entra directory roles. Composes over the imperative primitive documented on [`rbac.md`](rbac.md#plane-3--entra-directory-roles).

| Artifact | Path |
|---|---|
| Desired-state YAML | [`data-plane/entra-directory-roles/role-assignments.yaml`](../../../data-plane/entra-directory-roles/role-assignments.yaml) |
| Reconciler script | [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../../scripts/Deploy-EntraDirectoryRoles.ps1) |
| Imperative primitive | [`scripts/Grant-EntraDirectoryRole.ps1`](../../../scripts/Grant-EntraDirectoryRole.ps1) |

## Purpose

Reconcile the three directory roles cited as Purview-relevant in [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions):

- `Compliance Administrator`
- `Compliance Data Administrator`
- `Information Protection Administrator`

Roles outside that allow-list are out of scope for Purview-as-Code and are **rejected** by the reconciler if they appear in the YAML. Other directory-role surfaces (groups, S&C role groups, Microsoft Purview Data Map roles) live in their own sibling reconcilers.

## YAML schema

```yaml
directoryRoles:
  - name: Compliance Administrator                       # required (display name)
    templateId: 00000000-0000-0000-0000-000000000000     # recommended; immutable
    description: <one-sentence rationale>                # optional, human-only
    scope: /                                             # directory-wide; AU scope deferred
    members:                                             # required, list of Entra group OIDs
      - <role-assignable-group-object-id>
```

Constraints:

- Prefer `templateId:` over `name:` — the `id` of a built-in directory `roleDefinition` is immutable and equals its `templateId`, which makes resolution stable across tenants and immune to legacy `displayName` drift (e.g. `Information Protection Administrator` is exposed under the legacy display name `Azure Information Protection Administrator` in some tenants).
- `members` are **role-assignable Entra security groups only** — `securityEnabled = true` and `isAssignableToRole = true` per [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept). The unified RBAC API silently no-ops on groups that are not role-assignable.
- `scope:` is currently directory-wide (`/`) only. AU scoping is deferred until the AU scaffold (see [`administrative-units.md`](administrative-units.md)) lists at least one AU; encountering an AU-scoped row is a hard error.

## Behaviour

For each row:

1. Resolve the role definition. Use `templateId:` when present; otherwise filter `/v1.0/roleManagement/directory/roleDefinitions` by `displayName`.
2. Validate every declared member as a role-assignable security group.
3. Read current assignments at the row's `directoryScopeId` filtered by `roleDefinitionId` via [`rbacApplication: list roleAssignments`](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments).
4. Compute drift per `(role, scope, principal)` triple and emit a categorized report (`Create / NoChange / Revoke / NoOp`).
5. Apply `Create` rows always; apply `Revoke` rows only with `-PruneMissing`. Both gated by `ShouldProcess`.

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | No remote calls. Prints planned behaviour and the expected drift shape. |
| (default) | Live diff. Writes `Create` rows; skips `Revoke` rows. |
| `-PruneMissing` | Live diff. Writes `Create` **and** `Revoke` rows. PR must carry the `destructive` label. |
| `-ExportCurrentState` | Reads every in-scope role's current assignments at directory scope `/` and rewrites the `directoryRoles:` block of the YAML, preserving header comments. AU-scoped assignments are a hard error. |

## Authentication

Uses the data-plane Entra app's Key Vault-resident certificate per [ADR 0010](../../adr/0010-automation-identity-subject-model.md) / [ADR 0011](../../adr/0011-certificate-lifecycle.md). The script delegates to [`Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) with `-Scope https://graph.microsoft.com/.default` to mint a Graph access token. The local-PFX `-CertificateThumbprint` path is superseded by ADR 0011 decision #3 (the cert is non-exportable in Key Vault).

## Required roles

| Caller | Role / permission | Scope |
|---|---|---|
| Workload identity (writes) | Graph application permission `RoleManagement.ReadWrite.Directory` | Tenant |
| Workload identity (reads only) | Graph application permission `RoleManagement.Read.Directory` | Tenant |
| Caller in Azure | `Key Vault Crypto User` on the data-plane cert key | Key Vault |

Reference: [`rbacApplication` resource — permissions](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication#permissions).

## First-run-against-an-existing-tenant contract

Same as [`purview-role-groups.md`](purview-role-groups.md#first-run-against-an-existing-tenant-contract): run `-ExportCurrentState` first, merge the resulting YAML, then apply.

## References

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions)
- [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference)
- [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept)
- [`rbacApplication` resource (unified RBAC)](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication)
- [List `unifiedRoleDefinitions`](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roledefinitions)
- [Get `unifiedRoleDefinition` by id](https://learn.microsoft.com/en-us/graph/api/unifiedroledefinition-get)
- [List `unifiedRoleAssignments`](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments)
- [Create `unifiedRoleAssignment`](https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments)
- [Delete `unifiedRoleAssignment`](https://learn.microsoft.com/en-us/graph/api/unifiedroleassignment-delete)
- [ADR 0002 — Administrative units](../../adr/0002-administrative-units.md)
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
