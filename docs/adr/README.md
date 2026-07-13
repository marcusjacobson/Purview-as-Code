# Architecture Decision Records

This folder holds **Architecture Decision Records (ADRs)** for the Purview-as-Code repo. Every open question in [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs) (the **Open-question ADRs** section) that blocks a checklist item lands here as a numbered ADR before the item it gates can start.

ADRs are immutable once accepted. If a decision is reversed, write a new ADR that `supersedes` the old one — do not edit the old file in place.

## Format

- Filename: `NNNN-kebab-case-title.md` (zero-padded, starting at `0001`).
- Use [`0000-template.md`](0000-template.md) as the starting point.
- Follow the lightweight [MADR](https://adr.github.io/madr/) shape: **Context** → **Decision** → **Consequences** → **Citations**.

## Status values

| Status | Meaning |
|---|---|
| `Proposed` | Draft, open for discussion. Not yet actionable. |
| `Accepted` | Approved and in effect. Code may proceed per the decision. |
| `Superseded by NNNN` | Replaced by a later ADR. Retained for history. |
| `Deprecated` | No longer followed; no replacement exists. |

## Current ADRs

| # | Title | Status | Gates |
|---|---|---|---|
| [0001](0001-m365-licensing-verification.md) | Microsoft 365 licensing: require E5 and verify at deploy time | Accepted | §8 Q1; Wave 0 `Test-M365Licensing.ps1`; unblocks Waves 1 and 2 |
| [0002](0002-administrative-units.md) | Microsoft Entra administrative units in this repo | Accepted | §8 Q2; Wave 0 `Deploy-AdministrativeUnits.ps1` + `data-plane/administrative-units/` |
| [0003](0003-data-plane-folder-naming.md) | Rename `datamap/` folder to `data-plane/` | Accepted | Wave 0 CI/CD hygiene; prerequisite to Wave 1/2/3b/4 folder creation |
| [0008](0008-portal-role-group-api.md) | Portal role-group membership management API: hybrid (Graph primary, S&C PowerShell fallback) | Superseded by [0009](0009-portal-role-group-api-ship-order.md) | §8 Q8; unblocks Wave 0 `Grant-PurviewRoleGroup.ps1` + `data-plane/purview-role-groups/` |
| [0009](0009-portal-role-group-api-ship-order.md) | Portal role-group membership management API: S&C PowerShell today; Graph when a provider lands | Accepted | §8 Q8 (supersedes 0008 ship-order); unblocks Wave 0 `Grant-PurviewRoleGroup.ps1`, `data-plane/purview-role-groups/role-groups.yaml`, and `Deploy-PurviewRoleGroups.ps1` |
| [0010](0010-automation-identity-subject-model.md) | Automation identity subject model: one Entra app per workflow, bound to a GitHub Environment | Accepted | §8 Q3; paired with §8 Q4 unblocks Wave 0 `New-AutomationIdentity.ps1` and transitively a.1, a.3, #3, #4, #8 |
| [0011](0011-certificate-lifecycle.md) | Certificate lifecycle for the automation identity: Key Vault storage, 12-month self-signed cert, automated rotation under human approval, four-layer out-of-band detection | Accepted | §8 Q4; paired with [ADR 0010](0010-automation-identity-subject-model.md) unblocks Wave 0 `New-AutomationIdentity.ps1` and transitively a.1, a.3, #3, #4, #8 |
| [0012](0012-environment-parameters-file.md) | Environment parameters file as the source of truth for the control plane (`infra/parameters/<env>.yaml`) | Accepted | Refactor of Wave 0 #5.0 + #5a orchestrators; establishes the pattern for #5b, #5c, and every future `infra/modules/*.bicep` orchestrator |
| [0013](0013-squad-agents-vs-prompt-pipeline.md) | Squad agents own intake and governance; prompt pipeline owns build | Accepted | Closes [#90](../../issues/90); aligns Squad-agent and prompt-pipeline invocation (superseded in part by [0014](0014-agents-as-default-entry-point.md)) |
| [0014](0014-agents-as-default-entry-point.md) | Squad meta-agents are the default entry point | Accepted | Closes [#102](../../issues/102); makes the `@idea-intake` → `@artifact-resolver` → `@owner-approval` agents the default flow; supersedes-in-part [0013](0013-squad-agents-vs-prompt-pipeline.md) |
| [0015](0015-label-policy-shape.md) | Sensitivity label policy shape (locations, scope, advanced settings) | Accepted | Wave 1 `label-policies.yaml` + `Deploy-LabelPolicies.ps1` ([#66](../../issues/66)); §8 Q9 ([#175](../../issues/175)) |
| [0016](0016-auto-label-policy-shape.md) | Auto-labeling policy shape (mode, scope, rules, advanced settings) | Accepted | Wave 1 `auto-label-policies.yaml` + `Deploy-AutoLabelPolicies.ps1` ([#67](../../issues/67)) |
| [0017](0017-label-auto-application-shape.md) | Per-label client-side auto-application shape (recommendation / automatic conditions on `labels.yaml`) | Accepted | Stress-test campaign [#208](../../issues/208); predecessor to the Information Protection taxonomy rewrite |
| [0018](0018-ediscovery-scope.md) | eDiscovery-as-code: out of scope for this repository | Accepted | §8 Q6; descopes Wave 2f ([#82](../../issues/82)) |
| [0019](0019-cc-graph-pivot.md) | Communication Compliance authoring surface: defer pivot until Microsoft documents one | Accepted | §8 Q10; ratifies `policies: []` in [`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml) and freezes the `Create` / `Update` / `Remove` branches of [`Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1) ([#278](../../issues/278)) |
| [0020](0020-dspm-before-azure-gov.md) | Reorder Waves 3 and 4: DSPM ships before Azure governance | Accepted | Reorders §3 wave table and §4 dependency matrix; Q5 ([#84](../../issues/84)) gates the first DSPM item |
| [0021](0021-dspm-content-explorer-cadence.md) | Content Explorer export cadence for DSPM: weekly automated + on-demand | Accepted | Resolves §8 Q5; unblocks Wave 3a ([#74](../../issues/74)) |
| [0022](0022-dspm-for-ai-authoring-surface.md) | DSPM for AI authoring surface: no programmatic API; read-only posture verifier | Accepted | Adds §8 Q11; governs Wave 3b ([#75](../../issues/75)) |
| [0023](0023-identifier-resolution.md) | Identifier resolution for data-plane reconcilers: three categories, three mechanisms | Accepted | Cross-cutting scaffolding; unblocks [#305](../../issues/305) (Wave 4a-ii) and [#83](../../issues/83) (Wave 4b); establishes binding pattern for every future principal-aware / topology-aware reconciler |
| [0024](0024-unified-catalog-folder-placement.md) | Unified Catalog folder placement and YAML schema split | Accepted | Resolves §8 Q7; unblocks Wave 4b structural questions ([#83](../../issues/83)) |
| [0025](0025-role-group-entra-backing-naming.md) | Entra security-group backing for Purview portal role groups: `sg-purview-<slug>` per role group | Accepted | v2 §5.1 [#355](../../issues/355); ratifies [`Deploy-RoleGroupBackingEntraGroups.ps1`](../../scripts/Deploy-RoleGroupBackingEntraGroups.ps1) and the Phase 2 rebind of [`role-groups.yaml`](../../data-plane/purview-role-groups/role-groups.yaml) ([#383](../../issues/383)) |
| [0026](0026-glossary-custom-classifications-reconciler.md) | Glossary and custom-classifications reconcilers: two scripts, one Data Map api-version pin | Accepted | §8 Q12; unblocks §5.5 Glossary ([#373](../../issues/373)) and §5.5 Custom classifications ([#374](../../issues/374)) |
| [0027](0027-autoapplication-removal-watch-list.md) | Sensitivity-label `autoApplicationOf` removal: deferred pending a documented Set-Label clearing sentinel | Accepted | Adds §8 Q14; governs the `Update` branch of `Deploy-Labels.ps1` ([#429](../../issues/429)) |
| [0028](0028-co-equal-local-cert-credential.md) | Co-equal local-cert credential on the data-plane Entra app for the interactive dev loop | Accepted | Cross-cutting dev-loop infrastructure for IPPS-authenticated reconcilers; unblocks interactive lab runs |
| [0029](0029-source-of-truth-direction-policy.md) | Source-of-truth direction policy for data-plane reconcilers: three modes, two axes, one contract | Accepted | Cross-cutting; sub-issue A of the split that replaced [#454](../../issues/454); binds `Deploy-Labels.ps1` and the `deploy-*.yml` workflows |
| [0030](0030-label-policies-tracked-field-expansion.md) | Label-policies tracked-field expansion: amend ADR 0015 in place, one PR per field | Accepted | Resolves umbrella [#471](../../issues/471); per-field PRs ship as its children |
| [0031](0031-dlp-advancedrule-yaml-shape.md) | DLP AdvancedRule YAML shape: flattened groups, not verbatim JSON | Accepted | Unblocks [#514](../../issues/514) PR A2; follows §5.3 DLP closure ([#362](../../issues/362)) |
| [0032](0032-dlp-generic-locations-shape.md) | DLP generic Locations YAML shape and policyTemplateInfo defensive pattern | Accepted | Unblocks and closes [#515](../../issues/515); surfaces [#519](../../issues/519), [#520](../../issues/520), and [#521](../../issues/521) |
| [0033](0033-dlp-rule-tracked-field-expansion.md) | DLP rule tracked-field expansion: ratify the per-field shape contract, one PR per 1–3 fields | Accepted | Resolves umbrella [#521](../../issues/521); per-field PRs ship as its children |
| [0034](0034-adaptive-scope-schema.md) | Microsoft Purview adaptive scope schema: JSON-string `filterConditions`, allowed-attribute set per `LocationType`, no client-side canonicalisation | Accepted | Issue [#551](../../issues/551); unblocks [#550](../../issues/550) (the `scripts/Deploy-AdaptiveScopes.ps1` reconciler + `data-plane/adaptive-scopes/` YAML schema) |
| [0035](0035-records-seed-content-immovable.md) | File Plan Manager seed content is immovable; treat as permanent declared orphans | Accepted | Adds §8 Q15; governs the `Prune` branch of `Deploy-FilePlan.ps1` ([#582](../../issues/582), [#586](../../issues/586)) |
| [0036](0036-irm-tenant-setting-immovable.md) | IRM tenant-setting policy is system-managed and immovable; treat as permanent declared orphan | Accepted | Adds §8 Q16; governs the `-SkipNames` baseline for `Deploy-IRMPolicies.ps1` ([#603](../../issues/603)) |
| [0037](0037-unified-catalog-authoring-surface.md) | Microsoft Purview Unified Catalog authoring surface: no programmatic API; keep Wave 4b placeholder, defer the live reconciler | Superseded by [0047](0047-unified-catalog-preview-api-coexistence.md) | §8 Q13; watch-list-defers §5.6 row 1 ([#375](../../issues/375)); closes [#638](../../issues/638) |
| [0038](0038-devops-policies-reconciler-retirement.md) | Microsoft Purview DevOps policies reconciler retirement: surface in classic customer-support mode | Accepted | Resolves §5.9 queue item ([#633](../../issues/633)); retires `Deploy-Policies.ps1` and `data-plane/policies/` |
| [0039](0039-irm-entity-list-tracked-fields.md) | IRM entity-list tracked fields and `Set-InsiderRiskPolicyLite` coverage decision | Accepted | Closes [#606](../../issues/606); governs the `Deploy-IRMEntityLists.ps1` field surface and `-SkipNames` baseline |
| [0040](0040-default-label-for-documents.md) | Default label for documents (`DefaultLabel` advanced setting; #471 row 5) | Accepted | Unblocks the [#471](../../issues/471) row 5 child PR; per [ADR 0030](0030-label-policies-tracked-field-expansion.md) |
| [0041](0041-label-policy-fabric-powerbi.md) | Label-policy Fabric and Power BI compliance information (`powerBIComplianceInformation`; #471 row 7) | Accepted | Unblocks the [#471](../../issues/471) row 7 child PR; per [ADR 0030](0030-label-policies-tracked-field-expansion.md) |
| [0042](0042-label-policy-admin-units.md) | Label-policy admin units scope (`includedAdministrativeUnits`; #471 row 6) | Accepted | Unblocks the [#471](../../issues/471) row 6 child PR; per [ADR 0030](0030-label-policies-tracked-field-expansion.md) |
| [0043](0043-model-tier-policy.md) | Model-tier policy: prioritized model arrays across lifecycle and persona agents | Accepted | Establishes [`docs/governance/model-policy.md`](../governance/model-policy.md) and converts the four `.github/agents/*.agent.md` `model:` fields to arrays |
| [0044](0044-currency-watch-loops.md) | Code- and feature-currency watch loops | Accepted | Cross-cutting; no §5 / §8 row. Establishes [`watch-list.yml`](watch-list.yml) and the currency watch loops; its trigger #1 has fired (cited by [0047](0047-unified-catalog-preview-api-coexistence.md)) |
| [0045](0045-template-kickoff-spinoff-model.md) | Template kickoff and spin-off consumption model with a no-push-back guard | Accepted | Cross-cutting; no §5 / §8 row. Ratifies [`scripts/modules/KickoffGuard.psm1`](../../scripts/modules/KickoffGuard.psm1), [`Set-KickoffGuard.ps1`](../../scripts/Set-KickoffGuard.ps1), [`Test-KickoffGuard.ps1`](../../scripts/Test-KickoffGuard.ps1), and the `@operator-kickoff` agent |
| [0046](0046-tenant-placeholder-manifest.md) | Tenant placeholder manifest for template tailoring | Accepted | Cross-cutting template-maintenance infrastructure; no §5 / §8 row. Unblocks reliable `@operator-tenant` tailoring runs (the clone → tailor flow ratified by [0045](0045-template-kickoff-spinoff-model.md)) |
| [0047](0047-unified-catalog-preview-api-coexistence.md) | Microsoft Purview Unified Catalog preview REST API: adopt a coexistence track alongside the classic Data Map | Accepted | Supersedes [0037](0037-unified-catalog-authoring-surface.md) (§8 Q13); fires its watch-list trigger #1; builds on [0024](0024-unified-catalog-folder-placement.md); unblocks the unified-track scaffolding follow-ups; closes [#32](../../issues/32) |
| [0048](0048-purview-account-discovery-gate.md) | Purview account discovery-and-confirmation gate before tenant tailoring writes an account name | Accepted | Complements [0047](0047-unified-catalog-preview-api-coexistence.md) (reconcile-time routing); builds on [0012](0012-environment-parameters-file.md), [0045](0045-template-kickoff-spinoff-model.md), [0046](0046-tenant-placeholder-manifest.md); unblocks the `@operator-tenant` discover-and-confirm step and a `/discover-purview-account` prompt (or `/deploy-datamap` precondition) |
| [0049](0049-data-plane-sp-key-vault-firewall-rbac.md) | Data-plane automation SP holds Key Vault Contributor for the firewall toggle | Proposed | Bootstrap defect; unblocks every data-plane workflow that toggles the lab Key Vault firewall (`deploy-labels`, `deploy-label-policies`, `deploy-auto-label-policies`, the `sync-*-from-tenant` pair, `deploy-data-plane`, `drift-detection`, `kv-temp-unlock`) |

> [!NOTE]
> ADR numbers `0004`–`0007` were never assigned; the sequence jumps from `0003` to `0008`. This is an intentional numbering gap, not a set of missing files.

## Process

1. Copy [`0000-template.md`](0000-template.md) to `NNNN-your-title.md`.
2. Fill every section. Cite at least one Microsoft Learn page under **Citations** per the "Grounding — Microsoft Learn is the central source of truth" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).
3. Open a PR with the Conventional Commits title `docs(repo): ADR NNNN — <title>` per [`.github/instructions/commit-message.instructions.md`](../../.github/instructions/commit-message.instructions.md).
4. On merge, update the table above in the same PR.
5. Tick the matching §8 checklist item in [`docs/project-plan.md`](../project-plan.md) once the ADR is `Accepted`.
