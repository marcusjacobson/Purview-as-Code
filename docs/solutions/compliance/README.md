# Compliance solutions

Operational documentation for the Microsoft Purview compliance features managed or monitored by this repo. Read these pages as steady-state guides: each page names the data-plane YAML, reconciler script, drift posture, and verification path for one feature.

| Page | Purpose | Primary artifacts |
|---|---|---|
| [`dlp.md`](dlp.md) | Manage Microsoft Purview Data Loss Prevention (DLP) policies and nested rules from YAML. | [`scripts/Deploy-DLPPolicies.ps1`](../../../scripts/Deploy-DLPPolicies.ps1), [`data-plane/dlp/policies.yaml`](../../../data-plane/dlp/policies.yaml), [DLP smoke runbook](../../runbooks/dlp-end-to-end-smoke.md) |
| [`classifications.md`](classifications.md) | Manage the Sensitive Information Type (SIT) catalog view, custom Data Map classifications, and regex classification rules. | [`scripts/Sync-SITCatalog.ps1`](../../../scripts/Sync-SITCatalog.ps1), [`scripts/Deploy-Classifications.ps1`](../../../scripts/Deploy-Classifications.ps1), [`data-plane/classifications/`](../../../data-plane/classifications/), [SIT confidence runbook](../../runbooks/sit-confidence-analysis.md) |
| [`communication-compliance.md`](communication-compliance.md) | Document the portal-authored, drift-detection-only posture for Microsoft Purview Communication Compliance. | [`scripts/Deploy-CommunicationCompliance.ps1`](../../../scripts/Deploy-CommunicationCompliance.ps1), [`data-plane/communication-compliance/policies.yaml`](../../../data-plane/communication-compliance/policies.yaml), [ADR 0019](../../adr/0019-cc-graph-pivot.md) |
| [`adaptive-scopes.md`](adaptive-scopes.md) | Manage adaptive policy scopes used by retention, DLP, Insider Risk Management, and label-policy surfaces. | [`scripts/Deploy-AdaptiveScopes.ps1`](../../../scripts/Deploy-AdaptiveScopes.ps1), [`scripts/New-AdaptiveScope.ps1`](../../../scripts/New-AdaptiveScope.ps1), [`data-plane/adaptive-scopes/scopes.yaml`](../../../data-plane/adaptive-scopes/scopes.yaml), [ADR 0034](../../adr/0034-adaptive-scope-schema.md) |

## How this section relates to the rest of the repo

- **Data plane.** YAML files under [`data-plane/`](../../../data-plane/) are the declared state for each reconciler. DLP, custom classifications, and adaptive scopes can produce apply plans; Communication Compliance is intentionally drift-detection only.
- **Scripts.** PowerShell helpers under [`scripts/`](../../../scripts/) read the YAML, authenticate to either Microsoft Purview Data Map REST or Security & Compliance PowerShell, then emit categorized drift reports.
- **CI/CD.** Only **DLP** has an automated apply path: [`deploy-dlp.yml`](../../../.github/workflows/deploy-dlp.yml), the per-solution workflow that owns that surface ([ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)). **Custom classifications, SIT catalog sync, Communication Compliance drift checks, and adaptive scopes have no automated apply path yet** — they are local/operator-run via their `scripts/Deploy-*.ps1` reconciler until a per-solution workflow is backfilled ([#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80)).
- **Operational runbooks.** End-to-end and probe procedures live under [`docs/runbooks/`](../../runbooks/). The pages here link to those runbooks when a smoke or validation procedure exists.

## Conventions

- Use exact Microsoft product names and the `lab` environment only.
- Use placeholders only: `purview-contoso-lab`, `rg-purview-lab`, `eastus`, `contoso`, `user@contoso.com`, and `00000000-0000-0000-0000-000000000000`.
- Every feature page ends with a `## References` block using Microsoft Learn quotes and links to the governing ADRs.
- Regex examples must be anchored, bounded, and backed only by synthetic values.
