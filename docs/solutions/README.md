# Purview-as-Code solution guides

Operational "how to manage this feature using the repo" guides for every Microsoft Purview
solution this repository governs as code. Each guide maps a feature to its desired-state YAML
under [`data-plane/`](../../data-plane/), its reconciler script under [`scripts/`](../../scripts/),
and the Microsoft Learn entry point that grounds it — then walks the end-to-end steps to add,
change, or remove an item.

This is the steady-state configuration wiki. For incident-style procedures (temporary Key Vault
unlock, 409 cleanup, end-to-end smoke tests) see [`docs/runbooks/`](../runbooks/). For the
strategic roadmap and progress checklist see [`docs/project-plan.md`](../project-plan.md). For the
two-plane architecture see [`docs/architecture.md`](../architecture.md).

## How to use these guides

Every reconciler follows the same full-circle contract, so every feature is managed the same way:

1. **Hydrate** — `./scripts/Deploy-<Domain>.ps1 -ExportCurrentState` writes the live tenant state
   into the matching `data-plane/**` YAML (safe first run against an existing tenant).
2. **Edit** — change the YAML to add, modify, or remove an item. Open a pull request.
3. **Preview** — `./scripts/Deploy-<Domain>.ps1 -WhatIf` emits the drift report
   (Create / Update / NoChange / Orphan / Conflict). No writes.
4. **Apply** — run the reconciler (locally, or dispatch the
   [`deploy-data-plane`](../../.github/workflows/deploy-data-plane.yml) workflow). Destructive
   pruning is opt-in behind `-PruneMissing` and the `destructive` PR label.
5. **Verify** — run the feature's end-to-end smoke runbook under [`docs/runbooks/`](../runbooks/).

The reconciler contract (switches, drift report, direction policy) is defined in
[`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md)
and summarized in [`docs/scripts-reference.md`](../scripts-reference.md).

## Solution areas

| Area | Index | What it covers |
|---|---|---|
| Governance foundation | [`governance-foundation/README.md`](governance-foundation/README.md) | Identity, audit, RBAC, role groups, administrative units, data lifecycle, records, insider risk, DSPM — the primitives every later solution depends on. |
| Information Protection | [`information-protection/README.md`](information-protection/README.md) | Sensitivity labels, label policies, auto-labeling policies. |
| Compliance | [`compliance/README.md`](compliance/README.md) | Data Loss Prevention, sensitive information types / custom classifications, communication compliance, adaptive scopes. |
| Data Map | [`data-map/README.md`](data-map/README.md) | Collections, data sources, scans, business glossary. |
| Unified Catalog | [`unified-catalog/README.md`](unified-catalog/README.md) | Unified Catalog reconciler (watch-list placeholder per [ADR 0037](../adr/0037-unified-catalog-authoring-surface.md)). |

## Feature-to-artifact map

Every governed feature, its solution guide, the desired-state YAML it reconciles, and the
reconciler that applies it.

| Feature | Guide | Desired-state YAML | Reconciler |
|---|---|---|---|
| Sensitivity labels | [`information-protection/labels.md`](information-protection/labels.md) | [`information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml) | [`Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) |
| Label policies | [`information-protection/label-policies.md`](information-protection/label-policies.md) | [`information-protection/label-policies.yaml`](../../data-plane/information-protection/label-policies.yaml) | [`Deploy-LabelPolicies.ps1`](../../scripts/Deploy-LabelPolicies.ps1) |
| Auto-labeling policies | [`information-protection/auto-label-policies.md`](information-protection/auto-label-policies.md) | [`information-protection/auto-label-policies.yaml`](../../data-plane/information-protection/auto-label-policies.yaml) | [`Deploy-AutoLabelPolicies.ps1`](../../scripts/Deploy-AutoLabelPolicies.ps1) |
| Classifications / SIT catalog | [`compliance/classifications.md`](compliance/classifications.md) | [`classifications/sit-catalog.yaml`](../../data-plane/classifications/sit-catalog.yaml), [`classifications/classifications.yaml`](../../data-plane/classifications/classifications.yaml) | [`Sync-SITCatalog.ps1`](../../scripts/Sync-SITCatalog.ps1), [`Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) |
| Data Loss Prevention | [`compliance/dlp.md`](compliance/dlp.md) | [`dlp/policies.yaml`](../../data-plane/dlp/policies.yaml) | [`Deploy-DLPPolicies.ps1`](../../scripts/Deploy-DLPPolicies.ps1) |
| Communication compliance | [`compliance/communication-compliance.md`](compliance/communication-compliance.md) | [`communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml) | [`Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1) |
| Adaptive scopes | [`compliance/adaptive-scopes.md`](compliance/adaptive-scopes.md) | [`adaptive-scopes/scopes.yaml`](../../data-plane/adaptive-scopes/scopes.yaml) | [`Deploy-AdaptiveScopes.ps1`](../../scripts/Deploy-AdaptiveScopes.ps1) |
| Audit | [`governance-foundation/audit-retention.md`](governance-foundation/audit-retention.md) | [`audit/retention-policies.yaml`](../../data-plane/audit/retention-policies.yaml) | [`Set-AuditRetentionPolicy.ps1`](../../scripts/Set-AuditRetentionPolicy.ps1) |
| Data Lifecycle Management | [`governance-foundation/data-lifecycle.md`](governance-foundation/data-lifecycle.md) | [`data-lifecycle/retention-policies.yaml`](../../data-plane/data-lifecycle/retention-policies.yaml) | [`Deploy-RetentionPolicies.ps1`](../../scripts/Deploy-RetentionPolicies.ps1) |
| Records management | [`governance-foundation/records-management.md`](governance-foundation/records-management.md) | [`records/file-plan.yaml`](../../data-plane/records/file-plan.yaml) | [`Deploy-FilePlan.ps1`](../../scripts/Deploy-FilePlan.ps1) |
| Insider Risk Management | [`governance-foundation/insider-risk-management.md`](governance-foundation/insider-risk-management.md) | [`irm/policies.yaml`](../../data-plane/irm/policies.yaml), [`irm/entity-lists.yaml`](../../data-plane/irm/entity-lists.yaml) | [`Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1), [`Deploy-IRMEntityLists.ps1`](../../scripts/Deploy-IRMEntityLists.ps1) |
| DSPM | [`governance-foundation/dspm.md`](governance-foundation/dspm.md) | [`dspm/dspm-config.yaml`](../../data-plane/dspm/dspm-config.yaml) | [`Test-DSPMPosture.ps1`](../../scripts/Test-DSPMPosture.ps1) |
| DSPM for AI | [`governance-foundation/dspm-for-ai.md`](governance-foundation/dspm-for-ai.md) | [`dspm-ai/dspm-ai-config.yaml`](../../data-plane/dspm-ai/dspm-ai-config.yaml) | [`Test-DSPMforAIPosture.ps1`](../../scripts/Test-DSPMforAIPosture.ps1) |
| Data Map — collections | [`data-map/collections.md`](data-map/collections.md) | [`collections/collections.yaml`](../../data-plane/collections/collections.yaml) | [`Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1) |
| Data Map — data sources | [`data-map/data-sources.md`](data-map/data-sources.md) | [`data-sources/data-sources.yaml`](../../data-plane/data-sources/data-sources.yaml) | [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) |
| Data Map — scans | [`data-map/scans.md`](data-map/scans.md) | [`scans/scans.yaml`](../../data-plane/scans/scans.yaml) | [`Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1) |
| Data Map — glossary | [`data-map/glossary.md`](data-map/glossary.md) | [`glossary/glossary.yaml`](../../data-plane/glossary/glossary.yaml) | [`Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) |
| Unified Catalog | [`unified-catalog/unified-catalog.md`](unified-catalog/unified-catalog.md) | [`unified-catalog/`](../../data-plane/unified-catalog/) | [`Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1) |
| Purview role groups | [`governance-foundation/purview-role-groups.md`](governance-foundation/purview-role-groups.md) | [`purview-role-groups/role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) | [`Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) |
| Entra directory roles | [`governance-foundation/entra-directory-roles.md`](governance-foundation/entra-directory-roles.md) | [`entra-directory-roles/role-assignments.yaml`](../../data-plane/entra-directory-roles/role-assignments.yaml) | [`Deploy-EntraDirectoryRoles.ps1`](../../scripts/Deploy-EntraDirectoryRoles.ps1) |
| Administrative units | [`governance-foundation/administrative-units.md`](governance-foundation/administrative-units.md) | [`administrative-units/administrative-units.yaml`](../../data-plane/administrative-units/administrative-units.yaml) | [`Deploy-AdministrativeUnits.ps1`](../../scripts/Deploy-AdministrativeUnits.ps1) |

## Conventions

- Every page that makes a product-capability or role-gating claim ends with a `## References`
  block per the "Evidence pattern for Microsoft Learn citations" section of
  [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).
- Real tenant, subscription, or object IDs never appear here. Placeholders follow the
  "Environment and identifier boundaries" section of the same file
  (`00000000-0000-0000-0000-000000000000`, `contoso`, `purview-contoso-lab`).
- When a reconciler, YAML schema, or parameter surface changes, update the matching solution page
  in the same pull request. The [`docs-freshness`](../../.github/workflows/docs-freshness.yml)
  check flags drift between code and these guides; the
  [`docs-maintenance`](../../.github/skills/docs-maintenance/SKILL.md) skill packages the page
  template and update checklist.
