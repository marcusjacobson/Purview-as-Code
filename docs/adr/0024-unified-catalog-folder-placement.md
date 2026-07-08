# 0024 — Unified Catalog folder placement and YAML schema split

- **Status:** Accepted
- **Date:** 2026-05-24
- **Gates:** Resolves §8 open question Q7. Unblocks Wave 4b ([#83](../../issues/83)) on the structural questions only; authoring-surface selection is deferred to a follow-up ADR opened during Wave 4b research.
- **Deciders:** @contoso

## Context

The Progress checklist in [`docs/project-plan.md`](../project-plan.md) §5 carries Wave 4b — `data-plane/unified-catalog/` folder + YAMLs + deploy script ([#83](../../issues/83)) — as the last unticked deliverable in Wave 4. The §8 row for Q7 ([#78](../../issues/78)) gates that item with a structural question: where does the folder live, and how are its YAML manifests split?

Three constraints frame the answer:

1. **Two-plane separation, single sibling level.** [ADR 0003](0003-data-plane-folder-naming.md) established `data-plane/` as the data-plane root and explicitly listed `data-plane/unified-catalog/` as a planned Wave 4b sibling. It also rejected nesting Unified Catalog under any existing folder — `catalog/` was rejected as colliding with Unified Catalog, and `data-plane/glossary/` is the Data Map business glossary, a different product surface that [ADR 0020](0020-dspm-before-azure-gov.md) calls out as feeding *into* Unified Catalog rather than being part of it. Putting Unified Catalog content anywhere other than a new top-level sibling under `data-plane/` would either reopen ADR 0003's naming decision or hide a distinct product surface inside an unrelated one.

2. **Unified Catalog is multi-concept by design.** [Microsoft Purview Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) describes the surface as a composition of distinct concepts — governance domains, data products, OKRs, critical data elements, and health controls — that are managed and ship at different cadences. Existing data-plane folders in this repo use one YAML file per top-level concept (`collections.yaml`, `data-sources.yaml`, `scans.yaml`, `policies.yaml`, `classifications.yaml`, `glossary.yaml`). A single `unified-catalog.yaml` would cross-cut all five concepts in one file and force unrelated diffs to land together; the existing per-concept convention keeps PRs scoped and reviewable.

3. **Programmatic authoring surface for Unified Catalog is partially documented.** [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) (fetched 2026-05-24) lists the Data Map data-plane, Account data-plane, Policy Store data-plane, Scanning data-plane, and Share data-plane reference sections. As of the same fetch date, Unified Catalog does not appear as a peer section in that index. The "Unified Catalog overview" page links to portal workflows and PowerShell-free management UIs rather than to a REST reference. Resolving which API surface `Deploy-UnifiedCatalog.ps1` will call requires Wave 4b implementation research — the same shape that produced [ADR 0019](0019-cc-graph-pivot.md) for Communication Compliance and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) for DSPM for AI when their nominal authoring surfaces turned out to be partially documented. Forcing that question into this ADR would either delay the structural decision (which is well grounded) or commit to an endpoint that has not been verified.

This ADR therefore resolves the two structural questions and explicitly defers the authoring-surface question to Wave 4b.

## Decision

We will:

1. **Place Unified Catalog content at `data-plane/unified-catalog/`**, a new top-level sibling under `data-plane/`. No nesting under `glossary/`, `dspm/`, `collections/`, or any other existing folder. The folder is created in the Wave 4b PR ([#83](../../issues/83)), not in this ADR.

2. **Split the YAML manifests one file per Unified Catalog concept**, inside `data-plane/unified-catalog/`:

   | File | Concept | Microsoft Learn anchor |
   |---|---|---|
   | `governance-domains.yaml` | Governance domains | [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — domain organisation |
   | `data-products.yaml` | Data products | [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — data products |
   | `okrs.yaml` | OKRs (objectives and key results) | [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — OKRs |
   | `critical-data-elements.yaml` | Critical data elements | [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — CDEs |
   | `health-controls.yaml` | Health controls and health actions | [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — data governance health |

   Each file ships with a Draft-07 JSON schema as `<concept>.schema.json` (matching the Wave 1 Information Protection precedent set by [#68](../../issues/68)). Empty `items: []` is the default state, identical to the existing `purview-role-groups/role-groups.yaml` and `administrative-units/administrative-units.yaml` pattern.

   > **Update (2026-07-06, non-substantive):** [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) §Decision item 5 renamed `governance-domains.yaml` / `governance-domains.schema.json` to `business-domains.yaml` / `business-domains.schema.json` to match the 2026-03-20-preview API's "Business Domain" operation-group term, and added two additional per-concept files this ADR did not enumerate: `glossary-terms.yaml` (Terms operation group; distinct from `data-plane/glossary/`) and `data-access-policies.yaml` (Policies operation group). The folder-placement and per-concept-file decision below is otherwise unchanged.

3. **Defer the authoring-surface decision** (which REST endpoint, Graph endpoint, or PowerShell module `Deploy-UnifiedCatalog.ps1` will call) to a follow-up ADR opened during Wave 4b research. If [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) does not document a Unified Catalog data-plane REST section by the time Wave 4b starts, the follow-up ADR will ratify a read-only or portal-only posture (the [ADR 0022](0022-dspm-for-ai-authoring-surface.md) shape) or pivot to whichever Microsoft Learn-documented surface ships first (the [ADR 0019](0019-cc-graph-pivot.md) shape).

4. **Identifier resolution follows [ADR 0023](0023-identifier-resolution.md) without re-litigation.** Any Entra principal referenced from `data-plane/unified-catalog/**` YAML (data product owners, governance domain stewards, health control owners) uses the stable `displayName` shape resolved at deploy time. Any Azure topology identifier uses the `${env:VAR}` token shape. This ADR adds no new resolution mechanism; it inherits ADR 0023's contract verbatim.

## Consequences

**Easier**

- Wave 4b ([#83](../../issues/83)) can start its structural scaffolding (folder, empty YAMLs, schemas) without waiting on the authoring-surface question. The empty manifests are deployable as no-ops in the same way `purview-role-groups/role-groups.yaml: []` is today.
- Reviewers can scope a Unified Catalog change to one concept file. A change to OKR taxonomy does not touch governance domains, and vice versa.
- Schema diffs stay small. Adding a new field to `data-products.yaml` does not force a schema regeneration for unrelated concepts.
- The §5 Progress checklist row for [#83](../../issues/83) stays as a single Wave 4b deliverable; the follow-up ADR for the authoring surface lands on §8 as a new Q-row alongside Q10 ([#278](../../issues/278)) and Q11 ([#302](../../issues/302)), not as a new Progress row.

**Harder**

- Five files instead of one. The Wave 4b PR review surface is slightly larger than a single-file alternative. Mitigated by per-concept ownership being explicit.
- A follow-up ADR is still required before `Deploy-UnifiedCatalog.ps1` is implemented end-to-end. Wave 4b's first PR will ship the folder structure, schemas, and a `-WhatIf`-only reconciler that validates YAML against the schemas; the second PR ships the live reconciler after the authoring-surface ADR is accepted. This matches the staging pattern already used for [#74](../../issues/74) (Wave 3a DSPM) and [#75](../../issues/75) (Wave 3b DSPM for AI).

**Security posture**

- Unchanged. No identity, secret, role assignment, endpoint, or public-network setting is altered by this ADR. The [non-negotiable security principles](../../.github/instructions/security.instructions.md) apply to `data-plane/unified-catalog/**` exactly as they apply to every other data-plane folder. Principle #1 (no secrets in source) and principle #4 (least privilege) flow forward unchanged. ADR 0023's identifier-resolution contract is the only secrets-adjacent rule that touches this folder, and it is inherited verbatim.

## Alternatives considered

1. **Single `data-plane/unified-catalog/unified-catalog.yaml`.** Rejected. Cross-cuts five independent concepts (governance domains, data products, OKRs, critical data elements, health controls) into one file. A change to OKR shape would force unrelated diffs and balloon PR review surface. Inconsistent with every other data-plane folder in the repo, which already follows the per-concept-file pattern.

2. **Nest under `data-plane/glossary/`.** Rejected. [Microsoft Purview Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) treats Unified Catalog as a peer surface to the Data Map glossary, not a child of it. [ADR 0020](0020-dspm-before-azure-gov.md) explicitly positions the Data Map (which owns `data-plane/glossary/`) as a *source* feeding Unified Catalog, not as its parent. Nesting would imply ownership the product does not document.

3. **Decide the authoring surface here in the same ADR.** Rejected. [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) (fetched 2026-05-24) does not list a Unified Catalog REST data-plane section. Committing to a surface without a Learn reference would violate the "Grounding — Microsoft Learn is the central source of truth" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). The [ADR 0019](0019-cc-graph-pivot.md) (Communication Compliance) and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) (DSPM for AI) precedents both deferred the authoring-surface decision to a follow-up ADR when Learn was incomplete; this ADR does the same.

4. **Do nothing — leave Q7 open and block Wave 4b.** Rejected. The structural questions (folder placement, YAML split) are well grounded and answerable today. Continuing to block all of [#83](../../issues/83) on a question that is partly answerable contradicts the §3 cadence note "ADRs block the first item they gate, not the whole wave"; the same logic applies within an item — answer the answerable parts now, defer the rest.

## Citations

- [Microsoft Purview Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog) — fetched 2026-05-24. Establishes governance domains, data products, OKRs, critical data elements, and health controls as the top-level Unified Catalog concepts.
- [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/) — fetched 2026-05-24. Lists Data Map, Account, Policy Store, Scanning, and Share data-plane sections; no Unified Catalog data-plane section is present, which motivates deferring the authoring-surface decision.
- [Purview Data Map elastic data map overview](https://learn.microsoft.com/en-us/purview/concept-elastic-data-map) — fetched 2026-05-24. Establishes the Data Map as the surface feeding Unified Catalog (cited by [ADR 0020](0020-dspm-before-azure-gov.md)).
- [ADR 0003 — Rename `datamap/` folder to `data-plane/`](0003-data-plane-folder-naming.md) — named `data-plane/unified-catalog/` as the planned Wave 4b sibling.
- [ADR 0019 — Communication Compliance Graph pivot](0019-cc-graph-pivot.md) — precedent for deferring an authoring-surface decision when Learn is incomplete.
- [ADR 0022 — DSPM for AI authoring surface](0022-dspm-for-ai-authoring-surface.md) — precedent for shipping a read-only posture when no GA authoring surface is documented.
- [ADR 0023 — Identifier resolution in data-plane YAML](0023-identifier-resolution.md) — inherited verbatim for any principal or topology identifier referenced from `data-plane/unified-catalog/**`.
