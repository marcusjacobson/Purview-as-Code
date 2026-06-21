# 0025 — Entra security-group backing for Purview portal role groups

- **Status:** Accepted
- **Date:** 2026-05-27
- **Gates:** Supports v2 §5.1 row "Purview role groups — current-state review and YAML drift closure" ([#355](../../issues/355)) and the implementation work in [#383](../../issues/383). Does not gate any §8 open question.
- **Deciders:** @contoso

## Context

[data-plane/purview-role-groups/role-groups.yaml](../../data-plane/purview-role-groups/role-groups.yaml) is the desired-state file for Microsoft Purview / Microsoft 365 compliance-portal role-group membership. Its `members:` field accepts **Entra security-group object IDs only** — user UPNs and individual user OIDs are rejected per the least-privilege rule in [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) #4. The same rule is restated in the YAML header.

Today the file binds **10 distinct portal role groups** (CommunicationComplianceAdministrators, ComplianceAdministrator, ComplianceDataAdministrator, DataSourceAdministrators, InformationProtectionAdmins, KnowledgeAdministrators, PrivacyManagementAdministrators, PurviewAdministrators, PurviewAgentManagement, PurviewConsumptionManagement) to a **single shared Entra group** (`Contoso-Purview-Administrators`). That shape produces three concrete problems:

1. **Least privilege erosion.** Adding a member to `Contoso-Purview-Administrators` for one purpose (e.g. data-source onboarding) silently grants nine unrelated permissions. The shared group cannot be audited per role-group.
2. **No single governance plane.** Lab-owner intent is for Microsoft Entra to be the single pane of glass for Purview role-group access control. With a shared backing group, Entra access reviews, PIM eligibility, conditional-access binding, and AU scoping cannot target a specific portal role group.
3. **Inconsistent state.** `ContentExplorerListViewer` already follows the per-role-group pattern (its own `Content Explorer List Viewer (Lab)` group, per [ADR 0021](0021-dspm-content-explorer-cadence.md)). Every other binding deviates.

Microsoft documents the access-control surface for portal role groups as Entra group object IDs assigned via `Add-RoleGroupMember` ([Microsoft Purview roles and groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions); [Add-RoleGroupMember](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember)). Entra group lifecycle is documented at [Manage Microsoft Entra groups and group membership](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-manage-groups) and [Create group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-post-groups). Neither surface places a structural cap on the number of role-group-backing groups a tenant may carry, and group creation is free of license cost in this tenant's licensing posture (verified against [ADR 0001](0001-m365-licensing-verification.md)).

## Decision

We will:

1. **Provision one dedicated Microsoft Entra security group per portal role group declared in `role-groups.yaml`**, including role groups that are currently empty. Operational rationale: Entra becomes the single governance plane. Even an empty group is a stable handle for future access reviews, PIM assignments, and AU scoping.

2. **Naming pattern (mandatory):** ``sg-purview-<slug>``, where ``<slug>`` is the kebab-case form of the portal role group's ``name`` field. Conversion rule: insert ``-`` before any uppercase letter preceded by a lower-case letter or digit, or before any uppercase letter that begins a new word inside a run of capitals (uppercase preceded by uppercase AND followed by lower-case). Then lower-case the result. Acronyms are preserved. Examples:

   | Portal role group | Backing Entra group display name |
   |---|---|
   | ``OrganizationManagement`` | ``sg-purview-organization-management`` |
   | ``ComplianceAdministrator`` | ``sg-purview-compliance-administrator`` |
   | ``CommunicationComplianceAdministrators`` | ``sg-purview-communication-compliance-administrators`` |
   | ``eDiscoveryManager`` | ``sg-purview-e-discovery-manager`` |
   | ``InformationProtectionAdmins`` | ``sg-purview-information-protection-admins`` |
   | ``DataSecurityAIAdmins`` | ``sg-purview-data-security-ai-admins`` |
   | ``IRMContributors`` | ``sg-purview-irm-contributors`` |

   The slug is also the `mailNickname`. All groups are `securityEnabled: true`, `mailEnabled: false` (security groups, not Microsoft 365 groups).

3. **Group description (mandatory):** `Backs the Microsoft Purview portal role group '<RoleGroupName>'. Managed by scripts/Deploy-RoleGroupBackingEntraGroups.ps1. See docs/adr/0025-role-group-entra-backing-naming.md.`

4. **Ownership:** the automation identity (`gh-oidc-purview-data-plane` per [ADR 0010](0010-automation-identity-subject-model.md)) plus the lab-owner principal. The script accepts a `-OwnerObjectId` parameter for the lab-owner co-owner; the automation identity is added by the script's runtime context.

5. **Lifecycle:**
   - **Create.** Driven by [scripts/Deploy-RoleGroupBackingEntraGroups.ps1](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1). New role groups added to `role-groups.yaml` are picked up on the next run.
   - **Retire.** Removing a role group from `role-groups.yaml` produces an `Orphan` row in the drift report. Deletion of the backing Entra group requires `-PruneMissing` plus explicit lab-owner approval (destructive-change rule from [`pre-commit.instructions.md`](../../.github/instructions/pre-commit.instructions.md)).
   - **Rebind.** Membership of the backing group is managed in Entra directly (or via a future access-review / PIM rule). The reconciler does not manage user/SPN membership of the backing groups.

6. **YAML drift closure (Phase 2, separate PR).** After [#383](../../issues/383) lands the script and its first `-Apply` run produces the real Entra group OIDs, a follow-up PR rewrites every non-empty binding in `role-groups.yaml` to reference the dedicated `sg-purview-*` OID and retires the shared `Contoso-Purview-Administrators` binding. The shared group is **not** deleted; it remains available for any non-Purview purpose the lab owner assigns it.

7. **Identifier shape in YAML.** The `role-groups.yaml` file continues to use inlined Entra group OIDs with a trailing `# <display name>` comment, matching the existing `Contoso-Purview-Administrators` and `Content Explorer List Viewer (Lab)` precedent. [ADR 0023](0023-identifier-resolution.md) §Decision Category 3 `displayName`-resolution is **not** adopted for this file because (a) the file's existing schema is OID-based and the reconciler reads OIDs directly, and (b) the entire YAML is owned by one reconciler script with one consistent shape; mixing two resolution mechanisms in one file would harm review clarity. The trailing comment satisfies human readability.

## Consequences

**Easier**

- Each portal role group is now independently auditable, reviewable, PIM-eligible, and AU-scopeable in Microsoft Entra.
- Adding a member to one role group cannot accidentally grant the other nine that share `Contoso-Purview-Administrators` today.
- Future `role-groups.yaml` additions automatically get a backing group on the next reconciler run; no per-role-group ADR.
- The naming pattern is mechanically derivable from the portal role-group name — no judgement call per group.

**Harder**

- The tenant carries ~80 additional Entra security groups (one per portal role group). Most start empty. Group creation has no license cost in this tenant ([ADR 0001](0001-m365-licensing-verification.md) verified Microsoft Entra ID Free is sufficient for security-group creation) but the directory becomes denser. Mitigated by the mandatory `sg-purview-` prefix making them filterable and the mandatory description making them self-identifying.
- The first `-Apply` run requires Microsoft Graph `Group.ReadWrite.All` (application or delegated) on the automation identity. If the automation identity does not yet hold this scope, the script blocks at precondition time with a clear error pointing to [Group permissions — Microsoft Graph](https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions).
- Phase 2 (YAML rebind) is a follow-up PR. The script-only Phase 1 PR leaves the YAML temporarily inconsistent with the desired end-state. Mitigated by a follow-up issue filed in the same PR.

**Security posture**

- Strengthened. The shared-group anti-pattern that violated [`security.instructions.md`](../../.github/instructions/security.instructions.md) #4 (least privilege) is eliminated.
- No secrets are introduced. All group creation uses the automation identity's existing OIDC federated credential ([ADR 0010](0010-automation-identity-subject-model.md), [ADR 0011](0011-certificate-lifecycle.md)). No client secret, no certificate change.
- Public network access is unchanged.

## Alternatives considered

1. **Create dedicated groups only for currently-assigned role groups (8 groups instead of ~80).** Rejected. Lab-owner intent is Entra as the single governance plane for **all** portal role groups, not just currently-active ones. A role group with no backing group cannot be PIM-eligible or AU-scoped on day one; adding the backing group later requires either a YAML edit or a manual portal step, both of which break "Entra is the single plane of glass."

2. **One shared group per Purview persona (e.g. `sg-purview-admins`, `sg-purview-readers`, `sg-purview-investigators`).** Rejected. Reproduces the `Contoso-Purview-Administrators` problem with fewer offenders. `sg-purview-admins` would still grant `ComplianceAdministrator` + `DataSourceAdministrators` + `PurviewAdministrators` in one operation, contrary to AC#3 in [#383](../../issues/383).

3. **Use Microsoft Entra administrative units to scope backing groups.** Out of scope for this ADR. AU-scoping is its own dimension; ADR 0002 already defines the AU layer. A future ADR can layer AU-scoping on top of these backing groups without re-litigating the naming pattern. Tracked as a future enhancement, not a blocker.

4. **Use `displayName` resolution per [ADR 0023](0023-identifier-resolution.md) in `role-groups.yaml`.** Rejected for this file only. `role-groups.yaml` predates ADR 0023 with an OID-based schema and an OID-consuming reconciler. Retrofitting `displayName` resolution would require either reconciler changes (out of scope for [#383](../../issues/383)) or a mixed-shape YAML (harms review). Future data-plane files added after ADR 0023 use `displayName` resolution by default; `role-groups.yaml` is grandfathered.

5. **Do nothing — keep the shared `Contoso-Purview-Administrators` binding.** Rejected. Violates least privilege ([`security.instructions.md`](../../.github/instructions/security.instructions.md) #4) and blocks the v2 §5.1 row [#355](../../issues/355) from ticking with a clean security posture.

## Citations

- [Microsoft Purview roles and groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions) — establishes role groups as the portal access-control surface.
- [Add-RoleGroupMember](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember) — confirms Entra group OIDs as the accepted `Member` shape.
- [Create group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-post-groups) — the Graph endpoint the script invokes.
- [Manage Microsoft Entra groups and group membership](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-manage-groups) — lifecycle reference.
- [Group permissions — Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions) — Graph scopes required for group create/update/delete.
- [ADR 0001 — M365 licensing verification](0001-m365-licensing-verification.md) — confirms Microsoft Entra ID Free is sufficient for security-group creation.
- [ADR 0002 — Administrative units](0002-administrative-units.md) — defines the AU layer that can scope these groups in a future enhancement.
- [ADR 0009 — Portal role-group API ship order](0009-portal-role-group-api-ship-order.md) — reconciler API choice for `Deploy-PurviewRoleGroups.ps1`.
- [ADR 0010 — Automation identity subject model](0010-automation-identity-subject-model.md) — the identity that creates and owns the backing groups.
- [ADR 0021 — DSPM Content Explorer cadence](0021-dspm-content-explorer-cadence.md) — precedent for one role group with a purpose-specific backing group (`ContentExplorerListViewer`).
- [ADR 0023 — Identifier resolution in data-plane YAML](0023-identifier-resolution.md) — explains why `role-groups.yaml` is grandfathered to its OID-based shape.
