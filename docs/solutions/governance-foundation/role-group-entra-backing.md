# Role-group backing Entra security groups

Operational guide for [`scripts/Deploy-RoleGroupBackingEntraGroups.ps1`](../../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) — the Microsoft Graph reconciler that provisions one Entra security group per Microsoft Purview / Microsoft 365 portal role group declared in [`role-groups.yaml`](../../../data-plane/purview-role-groups/role-groups.yaml). Pair with [`purview-role-groups.md`](purview-role-groups.md) (the portal-side reconciler).

| Artifact | Path |
|---|---|
| Desired-state YAML (source of truth for role-group names) | [`data-plane/purview-role-groups/role-groups.yaml`](../../../data-plane/purview-role-groups/role-groups.yaml) |
| Backing-group reconciler | [`scripts/Deploy-RoleGroupBackingEntraGroups.ps1`](../../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) |
| Pester tests | [`tests/scripts/Deploy-RoleGroupBackingEntraGroups.Tests.ps1`](../../../tests/scripts/Deploy-RoleGroupBackingEntraGroups.Tests.ps1) |
| Decision | [ADR 0025](../../adr/0025-role-group-entra-backing-naming.md) |
| Portal-side reconciler | [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1) (see [`purview-role-groups.md`](purview-role-groups.md)) |

## Purpose

Microsoft Entra is the single governance plane for Microsoft Purview portal role-group access in this lab. Every portal role group declared in `role-groups.yaml` gets a dedicated Microsoft Entra security group `sg-purview-<slug>` so that:

- Access reviews, PIM eligibility, conditional access, and administrative-unit scoping target one role group at a time.
- Adding a member for one purpose cannot accidentally grant nine other role groups (the anti-pattern that exists today with the shared `Contoso-Purview-Administrators` group bound to ten different role groups).
- New role groups added to `role-groups.yaml` automatically get a backing group on the next reconciler run.

## Naming and shape (ADR 0025)

| Aspect | Value |
|---|---|
| `displayName` | `sg-purview-<slug>` where `<slug>` is the kebab-case form of the portal role group's `name`. Insert `-` before any uppercase letter preceded by a lower-case letter or digit, or before any uppercase letter that begins a new word inside a run of capitals (uppercase preceded by uppercase AND followed by lower-case). Acronyms are preserved. |
| `mailNickname` | Same as `displayName`. |
| `mailEnabled` | `false`. |
| `securityEnabled` | `true`. |
| `groupTypes` | `[]` (pure security group; not a Microsoft 365 group). |
| `description` | `Backs the Microsoft Purview portal role group '<RoleGroupName>'. Managed by scripts/Deploy-RoleGroupBackingEntraGroups.ps1. See docs/adr/0025-role-group-entra-backing-naming.md.` |
| `owners` | The automation identity that runs the script (implicit) plus the `-OwnerObjectId` passed at apply time. |

Worked examples:

| Portal role group | Backing Entra group |
|---|---|
| `OrganizationManagement` | `sg-purview-organization-management` |
| `ComplianceAdministrator` | `sg-purview-compliance-administrator` |
| `CommunicationComplianceAdministrators` | `sg-purview-communication-compliance-administrators` |
| `eDiscoveryManager` | `sg-purview-e-discovery-manager` |
| `InformationProtectionAdmins` | `sg-purview-information-protection-admins` |
| `DataSecurityAIAdmins` | `sg-purview-data-security-ai-admins` |
| `IRMContributors` | `sg-purview-irm-contributors` |

## Drift contract

Per [`.github/instructions/powershell.instructions.md`](../../../.github/instructions/powershell.instructions.md):

| Category | Meaning | Action gate |
|---|---|---|
| `Create` | Desired in YAML; not present in tenant. | `-WhatIf` reports; default run applies; requires `-OwnerObjectId`. |
| `NoChange` | Present in tenant and matches the ADR 0025 shape. | None. |
| `Update` | Present in tenant; description differs. | Default run patches the description. |
| `Orphan` | Tenant `sg-purview-*` group not declared in YAML. | Default run skips; `-PruneMissing` deletes. |
| `Conflict` | Present but `securityEnabled`/`mailEnabled`/`groupTypes` mismatch. | Default run skips; `-Force` logs manual-intervention guidance (re-create required). |

Membership of the backing groups is **not** managed by this reconciler. Membership reconciliation of the portal role groups themselves continues to flow through [`Deploy-PurviewRoleGroups.ps1`](purview-role-groups.md).

## First run

Microsoft Graph application scope required: `Group.ReadWrite.All` ([Group permissions — Microsoft Graph](https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions)).

1. **Confirm scope.** From a delegated `az login` session as the lab owner, or from the OIDC-federated GitHub Actions runner:

   ```pwsh
   az ad sp show --id "$env:AZURE_CLIENT_ID" --query "appRoles[?value=='Group.ReadWrite.All']"
   ```

   If the scope is missing, grant it via `New-AutomationRbac.ps1` (or by hand in the Entra portal) before continuing.

2. **Dry-run.** From the repo root:

   ```pwsh
   ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -WhatIf
   ```

   Review the drift report. Every row should be `Create` on a fresh tenant.

3. **Apply.** Supply the lab-owner Entra object ID as `-OwnerObjectId`:

   ```pwsh
   ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -OwnerObjectId <lab-owner-oid>
   ```

   The script creates each `sg-purview-*` group with the automation identity and the lab-owner as co-owners.

4. **Capture the OIDs.** The reconciler returns a report object. Pipe to JSON for the Phase 2 PR:

   ```pwsh
   ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -WhatIf |
       Where-Object Category -in 'NoChange','Update' |
       Select-Object Name, RoleGroupName, ObjectId |
       ConvertTo-Json -Depth 3
   ```

5. **Phase 2 — YAML rebind.** A follow-up PR rewrites every non-empty `members:` binding in `role-groups.yaml` to reference the new `sg-purview-<slug>` OID. The shared `Contoso-Purview-Administrators` group is unbound from Purview role groups (not deleted; it remains available for any non-Purview purpose the lab owner assigns it). After the YAML lands, run `Deploy-PurviewRoleGroups.ps1 -WhatIf` to confirm the expected `Revoke` (old OID) + `Create` (new OID) drift and apply.

## Idempotency

- Re-running the script with no YAML changes produces a report whose every row is `NoChange`.
- Adding a new role group to `role-groups.yaml` produces a single new `Create` row.
- Removing a role group produces an `Orphan` row; deletion requires `-PruneMissing` and follows the destructive-change rule in [`.github/instructions/pre-commit.instructions.md`](../../../.github/instructions/pre-commit.instructions.md).
- Changing the description of an existing backing group (out-of-band edit in the Entra portal) produces an `Update` row on the next run.

## Out of scope

- **Member assignment to the backing groups.** Handled directly in Microsoft Entra (or via a future PIM / access-review automation). The lab-owner is the single approver for backing-group membership.
- **AU-scoping of the backing groups.** Future enhancement. See [ADR 0002](../../adr/0002-administrative-units.md) for the AU layer.
- **Rebinding `role-groups.yaml`.** Phase 2 follow-up PR (see step 5 above).

## References

- **[Create group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-post-groups)** — endpoint the reconciler invokes for `Create` rows.
- **[List groups — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-list)** — endpoint for the initial state read.
- **[Update group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-update)** — endpoint for `Update` rows.
- **[Delete group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-delete)** — endpoint for `Orphan` rows when `-PruneMissing` is set.
- **[Group permissions — Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions)** — `Group.ReadWrite.All` is the required application or delegated scope.
- **[Microsoft Purview roles and groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions)** — portal role-group access-control model.
- **[ADR 0025](../../adr/0025-role-group-entra-backing-naming.md)** — naming convention and lifecycle.
- **[ADR 0009](../../adr/0009-portal-role-group-api-ship-order.md)** — portal-side reconciler API choice.
- **[ADR 0010](../../adr/0010-automation-identity-subject-model.md)** — automation identity that runs this reconciler.
