# Information Protection

Operational documentation for the Microsoft Purview Information Protection features managed by this lab repo.
Start with sensitivity labels, then publish them through label policies, then add service-side auto-labeling
where the policy/rule blast radius is understood.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`labels.md`](labels.md) | Manage the tenant-wide sensitivity-label taxonomy, including content marking, encryption, and label-level client-side auto-apply drift. | [`scripts/Deploy-Labels.ps1`](../../../scripts/Deploy-Labels.ps1), [`data-plane/information-protection/labels.yaml`](../../../data-plane/information-protection/labels.yaml), [ADR 0017](../../adr/0017-label-auto-application-shape.md), [ADR 0027](../../adr/0027-autoapplication-removal-watch-list.md), [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |
| [`label-policies.md`](label-policies.md) | Publish sensitivity labels to Microsoft 365 locations and manage policy settings that affect end-user labeling behavior. | [`scripts/Deploy-LabelPolicies.ps1`](../../../scripts/Deploy-LabelPolicies.ps1), [`data-plane/information-protection/label-policies.yaml`](../../../data-plane/information-protection/label-policies.yaml), [ADR 0015](../../adr/0015-label-policy-shape.md), [ADR 0040](../../adr/0040-default-label-for-documents.md), [ADR 0041](../../adr/0041-label-policy-fabric-powerbi.md), [ADR 0042](../../adr/0042-label-policy-admin-units.md), [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |
| [`auto-label-policies.md`](auto-label-policies.md) | Manage service-side auto-labeling policies and rules that apply labels when content matches Sensitive Information Types. | [`scripts/Deploy-AutoLabelPolicies.ps1`](../../../scripts/Deploy-AutoLabelPolicies.ps1), [`data-plane/information-protection/auto-label-policies.yaml`](../../../data-plane/information-protection/auto-label-policies.yaml), [ADR 0016](../../adr/0016-auto-label-policy-shape.md), [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) |

## How this section relates to the rest of the repo

- **Data plane.** Desired state lives under
  [`data-plane/information-protection/`](../../../data-plane/information-protection/). The PowerShell
  reconcilers apply those YAML manifests through Security & Compliance PowerShell using the shared
  Key Vault-signed app-only authentication path.
- **Workflows.** Every surface in this area has its own per-solution workflow, the unit of data-plane apply
  per [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md): the sensitivity-label
  taxonomy uses [`deploy-labels.yml`](../../../.github/workflows/deploy-labels.yml), label publishing uses
  [`deploy-label-policies.yml`](../../../.github/workflows/deploy-label-policies.yml), and service-side
  auto-labeling uses [`deploy-auto-label-policies.yml`](../../../.github/workflows/deploy-auto-label-policies.yml).
  Information Protection is the best-covered area in the repo — most other data-plane surfaces still have
  **no automated apply path** and are applied by running their reconciler locally
  ([#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80)).
- **Runbooks.** Direction-policy, destructive label pruning, and manual portal follow-up procedures live under
  [`docs/runbooks/`](../../runbooks/). These solution pages describe steady-state operation and link to the
  runbooks where an operator needs a ceremony.

## Conventions

- Product and cmdlet claims cite Microsoft Learn in each feature page's `## References` block.
- Real tenant IDs, subscription IDs, object IDs, UPNs, and customer names do not appear here. Use the zero-GUID
  placeholder `00000000-0000-0000-0000-000000000000`, `contoso`, `user@contoso.com`, account name
  `purview-contoso-lab`, resource group `rg-purview-lab`, and region `eastus` in examples.
- These pages document the `lab` environment only. Do not copy the examples into another environment without a
  design PR and reviewer approval.
