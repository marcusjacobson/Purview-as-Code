# Administrative units governance

Operational guidance for [Microsoft Entra administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units) (AUs) in the `contoso.onmicrosoft.com` lab. The architectural decision lives in [ADR 0002 — Administrative Units](../adr/0002-administrative-units.md); this document records the boundary, the operating procedure, and the conditions under which the default state changes.

## Boundary statement

AUs are an [Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/) construct, not a [Microsoft Purview](https://learn.microsoft.com/en-us/purview/purview) construct. Purview integrates with AUs as a *consumer* — six [Microsoft Purview solutions](https://learn.microsoft.com/en-us/purview/purview-admin-units#supported-solutions) (Data Loss Prevention, Insider Risk Management, Communication Compliance, Data Lifecycle Management, Records Management, Sensitivity Labeling) accept AU-scoped role-group assignments and policy targeting.

The repo reflects the boundary by domain split:

| Concern | Plane | Tooling | Scope |
| :--- | :--- | :--- | :--- |
| AU object lifecycle (create, update, delete) | Entra | [Microsoft Graph `directory/administrativeUnits`](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit) via [`scripts/Deploy-AdministrativeUnits.ps1`](../../scripts/Deploy-AdministrativeUnits.ps1) | Tenant |
| AU-scoped Purview role-group assignments | Purview data plane | Purview Roles & Scopes APIs via the existing role-group deploy scripts | Per role group |
| Member reconciliation (which users / groups / devices belong to an AU) | Out of scope | Not automated by this repo | n/a |

The `Deploy-AdministrativeUnits.ps1` script deliberately does not reconcile membership. Members are referenced by Entra object ID at AU creation time, then handed off to Entra administrative tooling. The `members:` field on a YAML entry is **not** a desired-state list; it seeds initial membership only and is ignored on subsequent runs.

## Default state

The default tenant state is an empty list:

```yaml
# data-plane/administrative-units/administrative-units.yaml
administrativeUnits: []
```

Per [ADR 0002 §2](../adr/0002-administrative-units.md#decision), an empty list is the steady state on `main`. Re-running [`scripts/Deploy-AdministrativeUnits.ps1`](../../scripts/Deploy-AdministrativeUnits.ps1) against an empty list is a no-op against an AU-free tenant; against a tenant that contains AUs not declared in YAML, the script reports them as `Orphan` rows and leaves them untouched unless `-PruneMissing` is supplied.

The capability is shipped, exercised against the live tenant once at ADR 0002 acceptance time, and otherwise dormant. See ADR 0002's "Decision" and "Consequences" sections for the rationale.

## Operating procedure

### When you need an AU

1. Edit [`data-plane/administrative-units/administrative-units.yaml`](../../data-plane/administrative-units/administrative-units.yaml) and add a single entry:

   ```yaml
   administrativeUnits:
     - displayName: au-<purpose>
       description: <one sentence; why this AU exists>
       visibility: Public            # or HiddenMembership
       members: []                   # optional; seeds initial membership only
   ```

   Naming follows [`naming.instructions.md`](../../.github/instructions/naming.instructions.md). Do not put a real tenant or subscription identifier in the slug.

2. Dry-run the change:

   ```pwsh
   ./scripts/Deploy-AdministrativeUnits.ps1 -WhatIf
   ```

   Confirm the drift report shows a single `Create` row for the new AU and nothing else. If `Update` or `Orphan` rows appear that were not expected, stop and reconcile.

3. Apply:

   ```pwsh
   ./scripts/Deploy-AdministrativeUnits.ps1 -Force
   ```

4. Verify via [Microsoft Graph — List administrativeUnits](https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits):

   ```pwsh
   $tok = az account get-access-token --resource 'https://graph.microsoft.com' --query accessToken -o tsv
   Invoke-RestMethod -Method Get `
     -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=displayName eq 'au-<purpose>'" `
     -Headers @{ Authorization = "Bearer $tok" }
   ```

5. Open the AU-scoped Purview role-group PR that consumes the new AU (separate item).

### When you no longer need an AU

1. Remove the entry from [`data-plane/administrative-units/administrative-units.yaml`](../../data-plane/administrative-units/administrative-units.yaml). Do not delete the file or empty the parent collection.

2. Dry-run with prune:

   ```pwsh
   ./scripts/Deploy-AdministrativeUnits.ps1 -WhatIf
   ```

   The drift report should show the AU as `Orphan`. Without `-PruneMissing` the AU stays. With `-PruneMissing`, it is deleted via [Microsoft Graph — Delete administrativeUnit](https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete).

3. Apply:

   ```pwsh
   ./scripts/Deploy-AdministrativeUnits.ps1 -PruneMissing -Force
   ```

   Per [`pull-request.instructions.md`](../../.github/instructions/pull-request.instructions.md), this PR carries the `destructive` label.

## Permissions

| Caller | Required role or permission | Source |
| :--- | :--- | :--- |
| Interactive user running `Deploy-AdministrativeUnits.ps1` | [`Privileged Role Administrator`](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#privileged-role-administrator) or [`Global Administrator`](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#global-administrator) | [Manage administrative units — permissions](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-manage#permissions-required) |
| Workload identity (delegated) | Microsoft Graph delegated scope `AdministrativeUnit.ReadWrite.All` | [administrativeUnit resource — permissions](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit#permissions) |
| Workload identity (application) | Microsoft Graph application permission `AdministrativeUnit.ReadWrite.All` | same as above |
| Caller assigning a Purview role group to an AU scope | [`Compliance Administrator`](https://learn.microsoft.com/en-us/purview/purview-permissions) and an AU-scoped Purview role group | [Administrative units in Microsoft Purview — permissions](https://learn.microsoft.com/en-us/purview/purview-admin-units#permissions) |

The lab's automation identity, provisioned by the `New-Automation*.ps1` scripts under [`scripts/`](../../scripts/) ([`New-AutomationEntraApp.ps1`](../../scripts/New-AutomationEntraApp.ps1), [`New-AutomationCertificate.ps1`](../../scripts/New-AutomationCertificate.ps1), [`New-AutomationKeyVault.ps1`](../../scripts/New-AutomationKeyVault.ps1), [`New-AutomationRbac.ps1`](../../scripts/New-AutomationRbac.ps1)), does not currently hold `AdministrativeUnit.ReadWrite.All`. Granting it is a separate, opt-in step that lands only when the lab actually adopts an AU; the default-empty steady state never exercises the application permission.

## Solutions that consume AU scope in Purview

Per [Administrative units in Microsoft Purview — supported solutions](https://learn.microsoft.com/en-us/purview/purview-admin-units#supported-solutions):

- [Data Loss Prevention](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp)
- [Insider Risk Management](https://learn.microsoft.com/en-us/purview/insider-risk-management)
- [Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance)
- [Data Lifecycle Management](https://learn.microsoft.com/en-us/purview/data-lifecycle-management)
- [Records Management](https://learn.microsoft.com/en-us/purview/records-management)
- [Sensitivity Labeling](https://learn.microsoft.com/en-us/purview/sensitivity-labels)

Microsoft Purview Data Map, Unified Catalog, eDiscovery, and DSPM are absent from that list. Wave 3 work in this repo therefore proceeds on collection-scoped Purview RBAC (per [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)) regardless of any AU decision.

## Scope limits worth remembering

Two facts shape every "should we use an AU here?" question:

- **Entra roles override AU scope.** A user who holds a tenant-wide Entra role such as `Compliance Administrator` plus an AU-scoped Purview role group is evaluated against the Entra role first; the AU does not effectively restrict that identity. Source: [Role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior). In a single-admin lab where the operator already holds `Global Administrator`, an AU restricts nothing about that operator.
- **AUs cannot nest, and dynamic group membership is not supported.** Source: [Administrative units — constraints](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#constraints). A flat list of AUs with explicit memberships is the only supported shape.

The capability remains shipped because future scenarios — a second contributor, a DLP demo against a regulated subset, an ad-hoc auditor — may need an exercised pattern in a hurry, and writing one under pressure risks correctness.

## Revisit triggers

Flip the default state from empty to a non-empty list, and update this doc plus a superseding ADR, when **any** of the following becomes true (verbatim from [ADR 0002 §5](../adr/0002-administrative-units.md#decision)):

- A second administrator identity joins the tenant needing a restricted scope.
- A second suborg, legal entity, or regional workload requires delegated admin separation.
- A compliance obligation requires cross-admin visibility restrictions for DLP, IRM, or CC.
- Microsoft changes [Role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior) so that AUs meaningfully restrict identities that also hold tenant-wide Entra roles.

A revisit is a doc change plus an ADR. It is not a runtime change to `administrative-units.yaml` alone.

## Out of scope

- **Member reconciliation.** Adding or removing users, groups, or devices from an existing AU is not automated by this repo. Use the Entra portal, [Microsoft Graph — Add a member](https://learn.microsoft.com/en-us/graph/api/administrativeunit-post-members), or [`Microsoft.Graph.Identity.DirectoryManagement`](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.identity.directorymanagement/) cmdlets directly.
- **Dynamic membership rules.** Not supported by AUs.
- **AU-scoped policies for Microsoft Purview Data Map, Unified Catalog, eDiscovery, or DSPM.** Not in the supported-solutions list.
- **Cross-tenant AUs.** Not supported by Entra.

## References

- [ADR 0002 — Administrative Units](../adr/0002-administrative-units.md)
- [Administrative units in Microsoft Purview](https://learn.microsoft.com/en-us/purview/purview-admin-units)
- [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)
- [Manage administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-manage)
- [Microsoft Graph — administrativeUnit resource type](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit)
- [Permissions in the Microsoft Purview portal — Role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior)
- [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift-report contract
