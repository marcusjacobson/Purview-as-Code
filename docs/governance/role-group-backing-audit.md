# Purview role-group backing audit — §5.1 / issue #355 close-out plan

> **Status:** Proposed — awaiting lab-owner decision on Option A vs Option B in §6.
> **Date:** 2026-05-28
> **Owner:** Lead / Architect persona
> **Scope:** Audit of [`data-plane/purview-role-groups/role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) at `HEAD` of `main` (post-PR #413) against [ADR 0025](../adr/0025-role-group-entra-backing-naming.md). No tenant state changes. No YAML edits. No script edits.

This document closes the loop on [`docs/project-plan.md`](../project-plan.md) §5.1 row [#355](../../issues/355) — *Purview role groups — current-state review and YAML drift closure* — by inventorying every portal role group declared in YAML and classifying the work that remains before the row can be ticked.

## 1. Context

[ADR 0025](../adr/0025-role-group-entra-backing-naming.md) ratified the per-role-group [Microsoft Entra security group](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-manage-groups) backing pattern: every portal role group declared in [`role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) gets a dedicated `sg-purview-<slug>` group, even when the role group is currently empty, so Microsoft Entra is the single governance plane for [Microsoft Purview portal role groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions).

The rebind from the shared `Contoso-Purview-Administrators` group to per-role-group dedicated groups was executed across these merged PRs:

| PR | Scope |
| :--- | :--- |
| [#386](../../pull/386) | First rebind wave — move existing non-empty bindings from `Contoso-Purview-Administrators` to dedicated `sg-purview-*` groups. |
| [#408](../../pull/408) | Add [`scripts/New-RoleAssignableEntraGroup.ps1`](../../scripts/New-RoleAssignableEntraGroup.ps1) and the [wrap-service-principal runbook](../runbooks/wrap-service-principal-in-role-assignable-group.md). |
| [#411](../../pull/411) | Bind the wrapper group `sg-purview-data-plane-compliance-admin` (containing the data-plane workload identity) into the `Compliance Administrator` portal role group transitively via membership in `sg-purview-compliance-administrator`. |
| [#413](../../pull/413) | Helper-defect cleanup: GUID redaction, Microsoft Graph eventual-consistency handling, idempotent `already-a-member` classification, and `-WhatIf` action-label fix. |

The reconciler [`scripts/Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) implements ADR 0025 by reading every `roleGroups[].name` from the YAML, deriving the required `sg-purview-<slug>` display name, and emitting a `Create` / `NoChange` / `Update` / `Orphan` / `Conflict` drift report against [Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-list).

## 2. Method

The inventory in §3 was produced by:

1. Reading [`role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) at `HEAD` of `main` after [#413](../../pull/413).
2. Deriving the required backing-group display name for each `roleGroups[].name` per the [ADR 0025 §Decision #2](../adr/0025-role-group-entra-backing-naming.md#decision) kebab-case algorithm (`sg-purview-<slug>`).
3. Comparing the derived display name to the comment annotation on each non-empty `members:` entry in the YAML.
4. Classifying each row into one of: `Rebound`, `Rebound (exception)`, `Pending — provision backing group`, `Blocked`, or `N/A`.

No Microsoft Graph calls were made. No tenant state was read. Object IDs are intentionally omitted from the inventory; rows reference role groups and backing groups by display name only, per the "Environment and identifier boundaries" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).

## 3. Inventory

74 portal role groups are declared in [`role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml). 11 carry a non-empty `members:` binding; 63 are empty.

### 3.1 Rebound to a dedicated `sg-purview-*` group (10)

These rows match the ADR 0025 §Decision #2 naming pattern exactly.

| Portal role group | Backing Entra group (display name) | Source PR |
| :--- | :--- | :--- |
| `CommunicationComplianceAdministrators` | `sg-purview-communication-compliance-administrators` | [#386](../../pull/386) |
| `ComplianceAdministrator` | `sg-purview-compliance-administrator` | [#386](../../pull/386) |
| `ComplianceDataAdministrator` | `sg-purview-compliance-data-administrator` | [#386](../../pull/386) |
| `DataSourceAdministrators` | `sg-purview-data-source-administrators` | [#386](../../pull/386) |
| `InformationProtectionAdmins` | `sg-purview-information-protection-admins` | [#386](../../pull/386) |
| `KnowledgeAdministrators` | `sg-purview-knowledge-administrators` | [#386](../../pull/386) |
| `PrivacyManagementAdministrators` | `sg-purview-privacy-management-administrators` | [#386](../../pull/386) |
| `PurviewAdministrators` | `sg-purview-purview-administrators` | [#386](../../pull/386) |
| `PurviewAgentManagement` | `sg-purview-purview-agent-management` | [#386](../../pull/386) |
| `PurviewConsumptionManagement` | `sg-purview-purview-consumption-management` | [#386](../../pull/386) |

### 3.2 Rebound (exception) (1)

| Portal role group | Backing Entra group (display name) | Notes |
| :--- | :--- | :--- |
| `ContentExplorerListViewer` | `Content Explorer List Viewer (Lab)` | Predates ADR 0025. Provisioned under [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md) as the wrapper for the data-plane workload identity (`gh-oidc-purview-data-plane`) so the [`export-content-explorer.yml`](../../.github/workflows/export-content-explorer.yml) workflow can call `Get-ContentExplorerData`. ADR 0025 is silent on grandfathered ADR 0021 bindings. **Recommended treatment:** accept as-is for #355 close-out; document under "Known exceptions" in this audit. |

### 3.3 Pending — provision backing group (63)

These role groups have an empty `members:` list. Per ADR 0025 §Decision #1, each still requires a dedicated `sg-purview-<slug>` backing group in Microsoft Entra as a stable handle for future access reviews, [Microsoft Entra Privileged Identity Management](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-configure) eligibility, [Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview) binding, and administrative-unit scoping. The work is purely additive (Microsoft Graph `Create` rows from [`Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1)) — no YAML changes required.

| Portal role group | Required backing group display name |
| :--- | :--- |
| `AttackSimAdministrators` | `sg-purview-attack-sim-administrators` |
| `AttackSimPayloadAuthors` | `sg-purview-attack-sim-payload-authors` |
| `AuditManager` | `sg-purview-audit-manager` |
| `AuditReader` | `sg-purview-audit-reader` |
| `BillingAdministrator` | `sg-purview-billing-administrator` |
| `CommunicationCompliance` | `sg-purview-communication-compliance` |
| `CommunicationComplianceAnalysts` | `sg-purview-communication-compliance-analysts` |
| `CommunicationComplianceInvestigators` | `sg-purview-communication-compliance-investigators` |
| `CommunicationComplianceViewers` | `sg-purview-communication-compliance-viewers` |
| `ComplianceManagerAdministrators` | `sg-purview-compliance-manager-administrators` |
| `ComplianceManagerAssessors` | `sg-purview-compliance-manager-assessors` |
| `ComplianceManagerContributors` | `sg-purview-compliance-manager-contributors` |
| `ComplianceManagerReaders` | `sg-purview-compliance-manager-readers` |
| `ContentExplorerContentViewer` | `sg-purview-content-explorer-content-viewer` |
| `DataCatalogCurators` | `sg-purview-data-catalog-curators` |
| `DataEstateInsightsAdmins` | `sg-purview-data-estate-insights-admins` |
| `DataEstateInsightsReaders` | `sg-purview-data-estate-insights-readers` |
| `DataGovernance` | `sg-purview-data-governance` |
| `DataInvestigator` | `sg-purview-data-investigator` |
| `DataSecurityAIAdmins` | `sg-purview-data-security-ai-admins` |
| `DataSecurityAIContentViewers` | `sg-purview-data-security-ai-content-viewers` |
| `DataSecurityAIViewers` | `sg-purview-data-security-ai-viewers` |
| `DataSecurityDLPTriageAgent` | `sg-purview-data-security-dlp-triage-agent` |
| `DataSecurityDSPMPostureAgent` | `sg-purview-data-security-dspm-posture-agent` |
| `DataSecurityInvestigationAdmins` | `sg-purview-data-security-investigation-admins` |
| `DataSecurityInvestigationInvestigators` | `sg-purview-data-security-investigation-investigators` |
| `DataSecurityInvestigationReviewers` | `sg-purview-data-security-investigation-reviewers` |
| `DataSecurityIRMTriageAgent` | `sg-purview-data-security-irm-triage-agent` |
| `DataSecurityManagement` | `sg-purview-data-security-management` |
| `DataSecurityViewers` | `sg-purview-data-security-viewers` |
| `DefaultRoleAssignmentPolicy` | `sg-purview-default-role-assignment-policy` |
| `eDiscoveryManager` | `sg-purview-e-discovery-manager` |
| `ExactDataMatchUploadAdmins` | `sg-purview-exact-data-match-upload-admins` |
| `GlobalReader` | `sg-purview-global-reader` |
| `InformationProtection` | `sg-purview-information-protection` |
| `InformationProtectionAnalysts` | `sg-purview-information-protection-analysts` |
| `InformationProtectionInvestigators` | `sg-purview-information-protection-investigators` |
| `InformationProtectionReaders` | `sg-purview-information-protection-readers` |
| `InsiderRiskManagement` | `sg-purview-insider-risk-management` |
| `InsiderRiskManagementAdmins` | `sg-purview-insider-risk-management-admins` |
| `InsiderRiskManagementAnalysts` | `sg-purview-insider-risk-management-analysts` |
| `InsiderRiskManagementApprovers` | `sg-purview-insider-risk-management-approvers` |
| `InsiderRiskManagementAuditors` | `sg-purview-insider-risk-management-auditors` |
| `InsiderRiskManagementInvestigators` | `sg-purview-insider-risk-management-investigators` |
| `InsiderRiskManagementSessionApprovers` | `sg-purview-insider-risk-management-session-approvers` |
| `IRMContributors` | `sg-purview-irm-contributors` |
| `MailFlowAdministrator` | `sg-purview-mail-flow-administrator` |
| `OrganizationManagement` | `sg-purview-organization-management` |
| `PrivacyManagement` | `sg-purview-privacy-management` |
| `PrivacyManagementAnalysts` | `sg-purview-privacy-management-analysts` |
| `PrivacyManagementContributors` | `sg-purview-privacy-management-contributors` |
| `PrivacyManagementInvestigators` | `sg-purview-privacy-management-investigators` |
| `PrivacyManagementViewers` | `sg-purview-privacy-management-viewers` |
| `QuarantineAdministrator` | `sg-purview-quarantine-administrator` |
| `RecordsManagement` | `sg-purview-records-management` |
| `Reviewer` | `sg-purview-reviewer` |
| `SecurityAdministrator` | `sg-purview-security-administrator` |
| `SecurityOperator` | `sg-purview-security-operator` |
| `SecurityReader` | `sg-purview-security-reader` |
| `ServiceAssuranceUser` | `sg-purview-service-assurance-user` |
| `SubjectRightsRequestAdministrators` | `sg-purview-subject-rights-request-administrators` |
| `SubjectRightsRequestApprovers` | `sg-purview-subject-rights-request-approvers` |
| `SupervisoryReview` | `sg-purview-supervisory-review` |

### 3.4 Blocked or N/A (0)

No rows in this category.

## 4. Summary

| Classification | Count |
| :--- | ---: |
| Rebound (ADR 0025 compliant) | 10 |
| Rebound (exception — ADR 0021 grandfather) | 1 |
| Pending — provision backing group | 63 |
| Blocked / N/A | 0 |
| **Total declared in YAML** | **74** |

## 5. YAML-level drift status

Strictly with respect to *drift between [`role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) desired state and tenant current state* — which is the literal scope phrased in [#355](../../issues/355) (*"current-state review and YAML drift closure"*) — there is **no remaining drift**:

- Every non-empty `members:` binding references a dedicated backing group.
- The shared `Contoso-Purview-Administrators` group is no longer bound to any Purview portal role group, per the YAML header comment.
- The 63 empty `members:` lists match the corresponding tenant role groups (which are also empty, per the `Current tenant assignments:` annotations that accompany each entry).

The remaining work — provisioning backing groups for the 63 currently-empty role groups — is *forward-looking proactive provisioning of stable Entra handles*, not drift closure.

## 6. Close-out decision

Two options were proposed in [#414](../../issues/414):

### Option A — strict ADR 0025 literal reading

Tick [#355](../../issues/355) only after [`Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) has been run to provision the 63 pending backing groups in the tenant.

| Pro | Con |
| :--- | :--- |
| Matches ADR 0025 §Decision #1 literal reading. | Couples #355 close-out to ~63 Microsoft Graph `Create` calls that are operationally trivial but produce 63 net-new Entra objects that need owner sign-off, naming review, and a destructive-change reversal plan. |
| Single ship event for the full pattern. | Inflates the scope of a "review and drift closure" row beyond the work captured in its title. |

### Option B — pragmatic close-out + follow-up (recommended)

Tick [#355](../../issues/355) once this audit is merged. The literal YAML-vs-tenant drift is already closed; ADR 0025 §Decision #1 implementation for currently-empty role groups becomes a separate, explicitly-scoped follow-up issue tracked as `feat(role-groups): provision sg-purview-* backing groups for currently-empty Purview role groups`.

| Pro | Con |
| :--- | :--- |
| Matches the literal scope of [#355](../../issues/355) (*review and drift closure*). | Leaves ADR 0025 §Decision #1 not-fully-implemented for 63 role groups until the follow-up ships. Audit makes this explicit. |
| Keeps the follow-up's operational footprint (~63 Entra `Create` rows, destructive-change reversal plan, owner sign-off) in its own PR where it gets focused review. | Two issues to track instead of one. |
| Unblocks §5.1's last unticked row that has any actual ambiguity. | |

**Recommendation: Option B.**

## 7. Follow-up issue specification (if Option B)

```text
Title: feat(role-groups): provision sg-purview-* backing groups for currently-empty Purview role groups

Summary
-------
Implements ADR 0025 §Decision #1 for the 63 portal role groups currently
listed in data-plane/purview-role-groups/role-groups.yaml with an empty
members: list. Provisions one dedicated Microsoft Entra security group
per role group using scripts/Deploy-RoleGroupBackingEntraGroups.ps1.
No YAML rebind required — these role groups have no current member
bindings to migrate.

Acceptance criteria
-------------------
- ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -WhatIf shows
  exactly 63 Create rows and 0 Orphan/Conflict rows against the YAML.
- Apply run produces 63 net-new sg-purview-* Entra security groups
  whose display names exactly match the "Required backing group
  display name" column in docs/governance/role-group-backing-audit.md
  §3.3 at HEAD of main.
- A reversal plan is documented in the PR description: paste the same
  command with -PruneMissing after reverting any merged YAML changes
  that referenced the new groups.
- Owner sign-off recorded; the PR carries the destructive label only
  if -PruneMissing is supplied for orphan cleanup (the additive Create
  path itself is not destructive).
- ContentExplorerListViewer is not touched — the existing
  Content Explorer List Viewer (Lab) binding is grandfathered per
  ADR 0021 and called out as an exception in
  docs/governance/role-group-backing-audit.md §3.2.

Out of scope
------------
- Adding members to any of the new backing groups. That is a
  per-group, per-role decision tracked separately.
- Rebinding the ContentExplorerListViewer (Lab) wrapper.
- Editing role-groups.yaml beyond cosmetic comment updates.

Squad personas
--------------
Primary:   Automation Engineer
Supporting: Security Specialist, Scribe
```

This issue is filed only after this audit doc merges and the lab owner approves Option B.

## 8. References

- [ADR 0025 — Entra security-group backing for Purview portal role groups](../adr/0025-role-group-entra-backing-naming.md)
- [ADR 0021 — DSPM Content Explorer cadence](../adr/0021-dspm-content-explorer-cadence.md)
- [Microsoft Purview roles and groups](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions)
- [Microsoft Entra group resource (Microsoft Graph v1.0)](https://learn.microsoft.com/en-us/graph/api/resources/group)
- [Create a group (Microsoft Graph v1.0)](https://learn.microsoft.com/en-us/graph/api/group-post-groups)
- [List groups (Microsoft Graph v1.0)](https://learn.microsoft.com/en-us/graph/api/group-list)
- [Manage Microsoft Entra groups and group membership](https://learn.microsoft.com/en-us/entra/fundamentals/how-to-manage-groups)
- [Environment and identifier boundaries](../../.github/copilot-instructions.md)
- Source YAML: [`data-plane/purview-role-groups/role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml)
- Reconciler: [`scripts/Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1)
- Progress checklist row: [`docs/project-plan.md`](../project-plan.md) §5.1 — [#355](../../issues/355)
