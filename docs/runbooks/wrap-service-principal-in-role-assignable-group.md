# Runbook: Wrap a workload identity in a role-assignable group for an Entra directory role

Use this runbook when a service principal or managed identity holds a
Microsoft Entra directory role (for example, `Compliance Administrator`)
**directly**, and you need to bring that assignment under declarative
management in [`data-plane/entra-directory-roles/role-assignments.yaml`](../../data-plane/entra-directory-roles/role-assignments.yaml).

The reconciler ([`scripts/Deploy-EntraDirectoryRoles.ps1`](../../scripts/Deploy-EntraDirectoryRoles.ps1))
accepts **groups only** in its `members:` list per [`security.instructions.md`](../../.github/instructions/security.instructions.md)
rule #4 (least privilege; assign to groups, not principals). Inlining a
service principal OID directly into the YAML will fail the
`isAssignableToRole` probe. The fix is to wrap the principal in a
dedicated role-assignable Entra security group and codify the **group**
binding instead.

This runbook was originally written to wrap `gh-oidc-purview-data-plane`
in `sg-purview-data-plane-compliance-admin` (issue [#407](../../../issues/407)),
but the procedure is general -- substitute names as needed.

## When to use this

- A `Deploy-EntraDirectoryRoles.ps1` drift report shows a
  `servicePrincipal` or `user` principal on an in-scope role that the
  YAML does not declare.
- You want `-PruneMissing` to become safe to run on that role.
- You do **not** want to revoke the principal's role outright (because
  some workflow depends on it).

If the right answer is to **revoke** the principal entirely (no
downstream dependency), skip this runbook and use
[`scripts/Grant-EntraDirectoryRole.ps1 -Revoke`](../../scripts/Grant-EntraDirectoryRole.ps1)
directly.

## Prerequisites

- Active `az login` session as a Microsoft Entra **Privileged Role
  Administrator** (or **Global Administrator**) in `contoso.onmicrosoft.com`.
  This is required for both group creation with `isAssignableToRole=true`
  and for directory-role grant / revoke operations. See [Create a
  role-assignable group](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-create-eligible).
- **Network reachability to `kv-contoso-lab-01`.** Step 3 of this runbook
  invokes [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../scripts/Deploy-EntraDirectoryRoles.ps1),
  which depends on [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1)
  to read the OIDC certificate from the lab Key Vault. The vault is
  hardened with `publicNetworkAccess: Disabled` and
  `networkAcls.defaultAction: Deny`, so the runner must either reach
  the vault via its private endpoint **or** be temporarily allow-listed
  on the vault firewall. For ad-hoc lab runs from a workstation, the
  minimal-blast-radius pattern is:

  ```pwsh
  $myIp = (Invoke-RestMethod 'https://api.ipify.org')
  az keyvault update --name kv-contoso-lab-01 --public-network-access Enabled --query "properties.publicNetworkAccess" -o tsv
  az keyvault network-rule add --name kv-contoso-lab-01 --ip-address "$myIp/32" --query "properties.networkAcls.ipRules" -o json
  # ... run Deploy-EntraDirectoryRoles.ps1 ...
  az keyvault network-rule remove --name kv-contoso-lab-01 --ip-address "$myIp/32" --query "properties.networkAcls.ipRules" -o json
  az keyvault update --name kv-contoso-lab-01 --public-network-access Disabled --query "properties.publicNetworkAccess" -o tsv
  ```

  Always restore `publicNetworkAccess: Disabled` and remove the IP
  rule before ending the session. See [Azure Key Vault network security](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security).
- You have already captured live drift via Microsoft Graph (or via the
  reconciler's own drift report) and know:
  - The display name of the new group (must match the `sg-purview-*`
    convention from [ADR 0025](../adr/0025-role-group-entra-backing-naming.md)).
  - The object ID of the principal to wrap.
  - The directory role(s) the principal currently holds.

## Procedure

### Step 1 - Create the role-assignable group and add the principal

Run the imperative helper. It is idempotent: re-running emits
`NoChange` / `NoOp`.

```pwsh
./scripts/New-RoleAssignableEntraGroup.ps1 `
    -DisplayName 'sg-purview-<workload>-<role-slug>' `
    -Description '<one-line purpose; ADR 0025 requires self-identifying descriptions>' `
    -AddMemberId <principal OID> `
    -WhatIf
```

Inspect the planned actions, then re-run without `-WhatIf`. Capture the
`groupId` from the summary output -- you need it for the YAML edit.

### Step 2 - Codify the group binding in YAML (separate PR)

Open a small `chore(role-groups)` PR that adds the group OID to the
`members:` list for the target role in
[`role-assignments.yaml`](../../data-plane/entra-directory-roles/role-assignments.yaml).
Follow the existing entry shape (OID with a trailing
`# <displayName> (isAssignableToRole=true)` comment).

Run `./scripts/Deploy-EntraDirectoryRoles.ps1 -WhatIf` locally and
paste the planned-behaviour output into the PR description. Merge via
`@artifact-resolver` / `@owner-approval` per the normal lifecycle.

### Step 3 - Apply the reconciler

After the YAML PR merges, run the reconciler against `lab`:

```pwsh
./scripts/Deploy-EntraDirectoryRoles.ps1 `
    -ParametersFile infra/parameters/lab.yaml `
    -Apply
```

Confirm the drift report shows a `Create` row for the new
**group -> role** binding. The principal is now indirectly assigned to
the role through the group.

### Step 4 - Verify the indirect assignment is live

Membership in a role-assignable group propagates immediately to role
evaluation (no PIM activation step required for a permanent
membership). Re-run a representative workflow step or call a
role-gated API as the principal to confirm. For the data-plane SP, the
quickest check is to dispatch [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
and confirm it succeeds.

### Step 5 - Revoke the direct assignment

Once Step 4 confirms the indirect path works, remove the direct
assignment so the YAML becomes the single source of truth:

```pwsh
./scripts/Grant-EntraDirectoryRole.ps1 `
    -RoleName '<role display name>' `
    -PrincipalId <principal OID> `
    -Revoke `
    -WhatIf
```

Review, then re-run without `-WhatIf`. The summary should report
`Revoke`. A subsequent reconciler `-WhatIf` should now show no orphan
rows for that role.

## Rollback

If Step 4 fails (indirect path is not granting the role):

1. Re-grant the direct assignment as a safety net:
   `./scripts/Grant-EntraDirectoryRole.ps1 -RoleName '<role>' -PrincipalId <oid>`
   (idempotent; no-op if still present).
2. Revert the YAML PR from Step 2 (`git revert <merge sha>`).
3. The new group remains in the tenant but is no longer referenced;
   leave it for the next attempt or delete via the Entra portal.

If Step 5 fails (revoke fails or breaks a workflow):

1. Re-grant the direct assignment immediately (idempotent helper above).
2. Investigate why the indirect path is not effective (token caching on
   the runner; principal not actually a member; assignment was
   AU-scoped rather than directory-wide; etc.).

## References

- [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept)
- [Create a role-assignable group in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-create-eligible)
- [Create group (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/group-post-groups)
- [Add member ($ref)](https://learn.microsoft.com/en-us/graph/api/group-post-members)
- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions)
- [Azure Key Vault network security](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [ADR 0025 - Role-group Entra-backing naming](../adr/0025-role-group-entra-backing-naming.md)
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) rule #4