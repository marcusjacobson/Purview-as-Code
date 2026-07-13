# Portal role-group reconciler

Operational guide for [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1) — the declarative reconciler for Microsoft Purview / Microsoft 365 portal role-group membership. Composes over the imperative primitive documented on [`rbac.md`](rbac.md#plane-4--microsoft-purview--m365-portal-role-groups).

| Artifact | Path |
|---|---|
| Desired-state YAML | [`data-plane/purview-role-groups/role-groups.yaml`](../../../data-plane/purview-role-groups/role-groups.yaml) |
| Reconciler script | [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1) |
| Token helper | [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) |
| Decision | [ADR 0009](../../adr/0009-portal-role-group-api-ship-order.md) (supersedes ADR 0008) |

## Purpose

Role groups are a Microsoft 365 compliance-portal construct (`Organization Management`, `Compliance Administrator`, `eDiscovery Manager`, `Insider Risk Management`, `Information Protection Admins`, `Records Management`, `Data Loss Prevention Compliance Management`, `Communication Compliance`, etc.). The YAML is the central source of truth for membership; the reconciler converges the tenant.

Role groups not listed in the YAML are left untouched. Default steady state is an empty `roleGroups:` list — no-op safe on first run against an unconfigured tenant.

## YAML schema

```yaml
roleGroups:
  - name: <exact Microsoft-published display name>     # required, case-sensitive
    description: <one-sentence rationale>              # optional, human-only
    members:                                           # required, list of Entra group OIDs
      - <group-object-id>
```

Constraints, mirrored from the YAML header:

- `name` must match the role-group display name exactly (case-sensitive). The reconciler does not coerce case.
- `members` are **Entra security-group object IDs only**. User UPNs and user OIDs are rejected per [`security.instructions.md`](../../../.github/instructions/security.instructions.md) rule #4.
- Empty `members: []` is valid and means "this role group should have no members" (the reconciler will revoke every Entra-group member when run with `-PruneMissing`).

## Behaviour

Drift contract per [`powershell.instructions.md`](../../../.github/instructions/powershell.instructions.md):

1. `Get-RoleGroupMember -Identity <RoleGroup> -ResultSize Unlimited` for each desired group.
2. Diff Entra group OIDs between desired and current state.
3. Emit categorized rows:

   | Category | Meaning |
   |---|---|
   | `Create` | OID in YAML, not in tenant role group. |
   | `NoChange` | OID in both. |
   | `Revoke` | OID in tenant role group, not in YAML. Written only with `-PruneMissing`. |
   | `NoOp` | A `Revoke` row skipped due to absent `-PruneMissing`. |

   `Update` does not apply (membership is binary). `Conflict` does not apply (role-group members carry no `lastModifiedBy`).
4. Acts only on categories the caller has authorized (`-WhatIf` / `-PruneMissing`).

Within a listed role group, members whose `ExternalDirectoryObjectId` does not match an Entra group OID (user members, on-prem recipients with no Entra OID) are ignored on read and never written.

The reconciler does **not** subprocess-invoke the `Grant-` primitive per row — it inlines the same `Get/Add/Remove-RoleGroupMember` cmdlets and re-uses one Security & Compliance PowerShell session for the whole run (forbidden anti-pattern: per-row `Connect-IPPSSession` cycles).

## First-run-against-an-existing-tenant contract

Before the first `-Apply` run against this file, run:

```pwsh
./scripts/Deploy-PurviewRoleGroups.ps1 -ExportCurrentState
```

That switch populates `roleGroups:` with the live membership of every role group the automation identity can see. Review the resulting diff in a pull request, then merge. Only after that PR lands is it safe to apply — otherwise the reconciler would treat existing portal-configured permissions as drift and remove them.

`-ExportCurrentState` refuses to overwrite a non-empty `roleGroups:` list unless `-Force` is also specified. YAML header comments are preserved by line-splicing.

## Required roles

| Caller | Role | Source |
|---|---|---|
| Data-plane workload identity | Exchange `Organization Management` (admin of role groups) | [Permissions in Exchange Online](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo) |
| Same identity in Azure | `Key Vault Crypto User` on the cert key | granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1) |

## Local-dev runs from outside the Key Vault network

CI runs app-only: workflow → KV `keys/sign` (private endpoint) → JWT assertion → IPPS access token. That path requires the workstation to reach `kv-contoso-lab-01`, which is `publicNetworkAccess: Disabled` per the lab's baseline posture ([Microsoft Purview security best practices — credential management](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management)).

For local-dev runs from a workstation outside the approved network, use `-Interactive` to connect as the calling user via browser MFA. This bypasses the KV entirely.

```pwsh
# Drift report (no writes; safe to run before any change).
./scripts/Deploy-PurviewRoleGroups.ps1 -WhatIf -Interactive

# Apply missing bindings (no destructive removal).
./scripts/Deploy-PurviewRoleGroups.ps1 -Interactive
```

Behavior:

- Skips `Get-PurviewIPPSAccessToken.ps1` and `az ad app list`. Makes zero Key Vault calls.
- Calls `Connect-IPPSSession -UserPrincipalName <UPN>` ([Learn](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession)). MSAL opens a browser sign-in with MFA.
- UPN defaults to `az account show --query user.name -o tsv`; pass `-UserPrincipalName` to override.
- Tenant-side audit logs attribute writes to your user identity, not the workload app.
- Requires your user to hold the same Exchange role group membership the workload identity does (typically `Organization Management`).

**CI must not use `-Interactive`.** Any workflow that runs this reconciler runs unattended, so the switch is rejected by review on any change that introduces it into `.github/workflows/**`.

> **No automated apply path yet.** No per-solution workflow owns Purview role groups, so merging `data-plane/role-groups/**` applies nothing on its own. **Interim apply path: run [`scripts/Deploy-PurviewRoleGroups.ps1`](../../../scripts/Deploy-PurviewRoleGroups.ps1) locally.** The monolithic `deploy-data-plane.yml` that once claimed this surface was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled). Nothing was lost: the apply path it advertised did not exist. Backfilling a `deploy-role-groups.yml` is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## References

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions)
- [Roles and role groups (Defender / Purview)](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/scc-permissions)
- [`Connect-IPPSSession`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession)
- [App-only auth for Exchange / S&C PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2)
- [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember)
- [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember)
- [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember)
- [ADR 0009 — Portal role-group API ship order](../../adr/0009-portal-role-group-api-ship-order.md)
- [ADR 0011 — Certificate lifecycle (decision §3 supersession)](../../adr/0011-certificate-lifecycle.md)
- [ADR 0012 — Environment parameters file](../../adr/0012-environment-parameters-file.md)
