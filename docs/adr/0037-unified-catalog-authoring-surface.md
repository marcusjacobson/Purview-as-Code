# 0037 — Microsoft Purview Unified Catalog authoring surface: no programmatic API; keep Wave 4b placeholder, defer the live reconciler

- **Status:** Superseded by [ADR 0047](0047-unified-catalog-preview-api-coexistence.md)
- **Date:** 2026-06-15
- **Gates:** Resolves §8 open-question Q13 in [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs). Governs the desired-state shape of `data-plane/unified-catalog/**` and the Create / Update / Remove branches of [`scripts/Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1). Closes #638 and watch-list-defers §5.6 row 1 ([#375](../../issues/375)).
- **Deciders:** @contoso

## Context

[ADR 0024](0024-unified-catalog-folder-placement.md) resolved the structural questions for Unified Catalog — folder placement at `data-plane/unified-catalog/` and the per-concept YAML split into `governance-domains.yaml`, `data-products.yaml`, `okrs.yaml`, `critical-data-elements.yaml`, `health-controls.yaml` — and explicitly deferred the authoring-surface question to a follow-up ADR opened during Wave 4b research. Wave 4b PR #2 ([#340](../../issues/340)) shipped a `-WhatIf`-only placeholder reconciler ([`scripts/Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1)) that validates each YAML against its co-located Draft-07 schema, emits a no-op plan, and makes **zero** REST or Graph calls. §8 Q13 has carried that deferred question ever since.

This ADR is the follow-up. It exists to answer Q13 with verified evidence and either ratify a chosen authoring surface or ratify the watch-list outcome, in the same shape that [ADR 0019](0019-cc-graph-pivot.md) (Communication Compliance) and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) (DSPM for AI) ratified their respective watch-list outcomes.

### Research surface — Microsoft Learn (verified 2026-06-15)

All probes below were fetched at 2026-06-15 from the lab workstation (see Citations and §References for fetch dates).

**Unified Catalog product pages** — every page returned HTTP 200; every page contains **zero** occurrences of `PowerShell`, `cmdlet`, `REST API`, `graph.microsoft`, `programmat`, or `api-version`:

| Page | Bytes | Result |
|---|---|---|
| [Learn about Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog) | 63,742 | 0 hits across all six keywords |
| [Data Products in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-data-products) | 52,172 | 0 hits across all six keywords |
| [Governance Domains in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-governance-domain) | 52,345 | 0 hits across all six keywords |
| [Objectives and Key Results (OKRs) in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-okr) | 52,780 | 0 hits across all six keywords |
| [Data Quality in Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/data-quality-overview) | 58,344 | 0 hits across all six keywords (closest surface to the `health-controls.yaml` concept; data quality is the runtime metric, controls are the rules that emit metrics) |
| [Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview) | 54,013 | 0 hits across all six keywords (UC product umbrella) |

Two of the five Wave 4b concept areas have dedicated concept pages on Learn that 200 (governance domains, data products, OKRs). Two — critical data elements, health controls — return HTTP **404** on every Learn slug we probed: `concept-critical-data-elements`, `concept-critical-data-element`, `concept-cde`, `concept-cdes`, `concept-health-control`, `concept-health-controls`, `concept-data-governance-health`, `concept-health-management`, `health-management-overview`, `health-controls`, `concept-health`, `data-product-overview`, `governance-domains-overview`. The two CDE and health-control concepts are mentioned only inside [the UC overview](https://learn.microsoft.com/en-us/purview/unified-catalog) and [the data governance overview](https://learn.microsoft.com/en-us/purview/data-governance-overview); neither overview surfaces a programmatic authoring API.

**Microsoft Purview REST API reference** — [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) (HTTP 200, 36,938 bytes). The page is a SPA-rendered table of contents that the static fetch surface cannot enumerate, but direct probes against the two plausible Unified Catalog data-plane section paths return HTTP **404**:

| Probe | Result |
|---|---|
| `https://learn.microsoft.com/en-us/rest/api/purview/unifiedcatalogdataplane/` | HTTP **404** |
| `https://learn.microsoft.com/en-us/rest/api/purview/datagovernancedataplane/` | HTTP **404** |

For comparison, the four sibling Purview REST sections this repo already consumes (`datamapdataplane`, `accountdataplane`, `policystoredataplane`, `scanningdataplane`) all return HTTP 200 at the same path shape and are cited in the codebase. The 404 on both candidate UC section roots is the same null result [ADR 0024](0024-unified-catalog-folder-placement.md) recorded on 2026-05-24, three weeks earlier; Microsoft has not added a UC data-plane section in the intervening cadence window.

**Microsoft Graph metadata** — both `https://graph.microsoft.com/v1.0/$metadata` (2.76 MB) and `https://graph.microsoft.com/beta/$metadata` (7.10 MB) were fetched and grep-searched for the UC identifier set (`dataProduct`, `governanceDomain`, `criticalDataElement`, `unifiedCatalog`, `dataGovernance`, `healthControl`, `keyResult`). v1.0 returned **zero** hits across all seven terms. Beta returned three hits each for `unifiedCatalog` and `dataGovernance`, all of which are read-only audit-record entity types under the `microsoft.graph.security` namespace:

| Term | beta `$metadata` hit | Authoring? |
|---|---|---|
| `unifiedCatalog` | `microsoft.graph.security.microsoftPurviewUnifiedCatalogOperationRecord` | **No** — `auditData`-typed read-only record |
| `unifiedCatalog` | `UnifiedCatalogConceptAction` (enum value) | **No** — enum member on the audit record above |
| `unifiedCatalog` | `microsoftPurviewUnifiedCatalogOperationRecord` (second occurrence) | **No** — same audit-record type |
| `dataGovernance` | `microsoft.graph.security.dataGovernanceAuditRecord` | **No** — `auditData`-typed read-only record |
| `dataGovernance` | `DataGovernance` (enum value) | **No** — enum member |
| `dataGovernance` | `dataGovernanceAuditRecord` (second occurrence) | **No** — same audit-record type |

A separate enumeration of `<EntitySet>` declarations matching `unified|catalog|governance|dataproduct|cde|criticalDataElement|healthControl|keyResult|okr` returned only the unrelated Azure resource-governance / PIM entity sets (`governanceResources`, `governanceRoleAssignmentRequests`, `governanceRoleAssignments`, `governanceRoleDefinitions`, `governanceRoleSettings`, `governanceSubjects`). A separate enumeration of `<Action>` declarations on the same regex returned **zero** matches.

This is the **identical shape** [ADR 0019](0019-cc-graph-pivot.md) and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) found: the only Graph footprint for Unified Catalog is read-only `microsoft.graph.security.*OperationRecord` audit data, not an authoring surface. The repeat finding across three independent Purview workloads (CC, DSPM for AI, UC) is not coincidence — it is Microsoft's consistent posture on Purview governance authoring at the Graph layer.

**Microsoft Purview What's New** ([learn.microsoft.com/en-us/purview/whats-new](https://learn.microsoft.com/en-us/purview/whats-new), HTTP 200, 96,191 bytes, fetched 2026-06-15). Filtered to Unified Catalog mentions, the page returns exactly two entries in scope:

> "...modernized management of glossary terms by migrating glossary terms created in the classic governance experience into Unified Catalog. When you complete the process, you can..."
>
> "New bulk import, editing, and moving capabilities can help you quickly scale operations in Unified Catalog:"

Both describe **portal-only operator experiences**: a one-time migration wizard for legacy glossary terms, and bulk-edit/move operations inside the Unified Catalog portal. Neither announces a programmatic surface. The seven `PowerShell` / `cmdlet` mentions on the same What's New page are all scoped to unrelated products (Defender scanner, retention policies, adaptive scope membership export — none Unified Catalog).

**Microsoft sample repositories** — the three canonical Purview sample-repo URLs (`github.com/microsoft/purview-samples`, `github.com/microsoft/purviewautomation`, `github.com/microsoft/Microsoft-Purview-Customer-Experience-Engineering`) returned HTTP **404** at the time of probe. Their unavailability is not evidence either way; the public Learn surface is the authoritative grounding source per [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) §"Grounding — Microsoft Learn is the central source of truth", and Learn already gives a clear answer.

### Net finding

**Microsoft Learn currently documents no programmatic authoring API for Microsoft Purview Unified Catalog.** All five Wave 4b concept areas — governance domains, data products, OKRs, critical data elements, health controls — are authored exclusively in the Microsoft Purview Unified Catalog portal as of 2026-06-15. The Graph footprint is read-only audit data only. The REST `/rest/api/purview/` index has no Unified Catalog data-plane section. The What's New cadence over the last six months shipped only portal-experience improvements, no programmatic surface.

This finding is the third in a series (after ADR 0019 for Communication Compliance and ADR 0022 for DSPM for AI). All three workloads share the same Microsoft posture: portal-driven authoring with read-only audit-plane exposure via Graph `microsoft.graph.security.*OperationRecord` types. This ADR adopts the same response shape.

## Decision

**We will not promote `scripts/Deploy-UnifiedCatalog.ps1` to a live reconciler in this iteration.** Specifically:

1. **Keep [`scripts/Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1) at its current Wave 4b shape** — `-WhatIf` placeholder reconciler per [#340](../../issues/340). The script validates each YAML against its co-located Draft-07 schema, emits a per-concept plan table against an empty tenant baseline, and errors with `not implemented - pending authoring-surface ADR` when invoked without `-WhatIf` or with `-ExportCurrentState`. No REST or Graph calls. No change to the script in this ADR.

2. **Keep [`data-plane/unified-catalog/**`](../../data-plane/unified-catalog/) YAML files at `items: []` as the only valid desired state.** The five concept files already document this as their steady state, citing ADR 0024 in each header. This ADR ratifies it as the standing rule rather than a temporary state.

3. **Unified Catalog content is authored in the Microsoft Purview Unified Catalog portal** by operators with the appropriate Unified Catalog role assignments. Role assignment for the Purview governance role groups remains managed by [`scripts/Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) per [ADR 0009](0009-portal-role-group-api-ship-order.md); no new role wiring is introduced by this decision.

4. **§8 Q13 in [`docs/project-plan.md`](../project-plan.md) becomes a standing watch-list row.** Status changes from "Open. Carried from the Wave 4b follow-up flagged in [#340](../../issues/340)." to "Watch-list per [ADR 0037](adr/0037-unified-catalog-authoring-surface.md); re-verified 2026-06-15 — Learn documents no programmatic authoring surface across all five Unified Catalog concept areas." The row stays unticked until any re-open trigger below fires, at which point it is closed and superseded by a new ADR.

5. **§5.6 row 1 ([#375](../../issues/375)) in [`docs/project-plan.md`](../project-plan.md) is watch-list-deferred**, ticked under the §4 watch-list-row closure rubric — the same shape §5.5 row 4 (DevOps policies) was ticked on 2026-06-14 after that surface returned `UnsupportedApiVersion`, and the same shape §5.2 sensitivity-label removal-path row was ticked on 2026-06-01 under [ADR 0027](0027-autoapplication-removal-watch-list.md). The Wave 4b placeholder reconciler stays in place to satisfy the full-circle reconciler contract guard and to emit a `-WhatIf` no-op plan on every `deploy-data-plane.yml` dispatch.

6. **Re-open triggers (the watch list).** This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:

   - A `unifiedCatalogdataplane` or `datagovernancedataplane` section lands under [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) (preview or GA) covering any of: governance domains, data products, OKRs, critical data elements, or health controls.
   - A `dataProduct`, `governanceDomain`, `criticalDataElement`, `healthControl`, `keyResult`, `unifiedCatalogPolicy`, or similarly-named authoring resource (i.e., not an `*OperationRecord` audit type) lands under [`learn.microsoft.com/en-us/graph/api/resources/`](https://learn.microsoft.com/en-us/graph/api/resources/) (beta or v1.0).
   - The [Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog), [Data Products](https://learn.microsoft.com/en-us/purview/concept-data-products), [Governance Domains](https://learn.microsoft.com/en-us/purview/concept-governance-domain), [OKRs](https://learn.microsoft.com/en-us/purview/concept-okr), [Data Quality](https://learn.microsoft.com/en-us/purview/data-quality-overview), or [Data governance overview](https://learn.microsoft.com/en-us/purview/data-governance-overview) page gains a "PowerShell" or "REST API" or "programmatic" section (the inverse of the zero-keyword-hits result this ADR is grounded on).
   - A Microsoft-published reference repo under `github.com/microsoft/` or `github.com/MicrosoftDocs/` ships a Unified Catalog authoring sample for any concept.
   - The cascade from [ADR 0019](0019-cc-graph-pivot.md) (Communication Compliance) or [ADR 0022](0022-dspm-for-ai-authoring-surface.md) (DSPM for AI) reverses — i.e., Microsoft documents Graph-based authoring for either workload — since the same posture argument cited here would reverse in lockstep for UC.

7. **No undocumented surface.** We will not consume the Microsoft Purview portal's internal REST traffic by reverse-engineering the browser dev-tools network tab. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and would break on any backend revision without warning. This restriction is identical to the one in [ADR 0019](0019-cc-graph-pivot.md) §6 and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6.

## Consequences

**Easier**

- **§5.6 row 1 unblocks under the watch-list closure rubric.** [#375](../../issues/375) ticks today rather than staying open indefinitely as a blocked row. The placeholder reconciler shape ratified by [#340](../../issues/340) is exactly the correct shape for this verdict.
- **No moving target.** With Q13 ratified, future PRs in `data-plane/unified-catalog/` are limited to the watch-list triggers above. The lab is not committed to revisiting this every quarter.
- **Symmetry with the rest of the repo.** Three workloads (CC, DSPM for AI, UC) now share the same watch-list-deferral verdict for the same Microsoft Learn-grounded reason. A future operator reading any of the three ADRs encounters the same shape with the same re-open vocabulary.
- **The repo stays inside its grounding rule.** Every cited Microsoft Learn URL in this ADR was fetched and verified on 2026-06-15 before the ADR was committed. The probe transcripts are summarized in §Context above rather than committed as separate evidence.
- **The Wave 4b placeholder reconciler keeps earning its keep.** The schema-validation + no-op plan on every `deploy-data-plane.yml` dispatch is the closest thing to an audit signal available against a surface with no apply API. The full-circle reconciler contract guard remains green because the script declares `SupportsShouldProcess`, `-PruneMissing`, and `-ExportCurrentState` tokens per [#340](../../issues/340).

**Harder**

- **No Git-tracked desired state for Unified Catalog content.** Operators who create governance domains, data products, OKRs, critical data elements, or health controls in the portal must remember that their changes are not represented in this repo. The placeholder reconciler reports them as drift on every `-WhatIf` run only insofar as it would, in a future world with an authoring surface; today it simply emits the per-concept plan against the empty YAML.
- **The §5.6 row's long-term value is read-only / future-state assurance rather than declarative apply.** This is a deliberate scope shift and is captured here so it does not surface later as a surprise.
- **A future operator that needs Unified Catalog content in code will have to choose between (a) re-opening this ADR after a watch trigger fires, or (b) writing a new ADR that argues for a portal-internal REST consumer despite the rule in §7 above.** This ADR neither commits to nor pre-rejects path (b); it only requires that path (b) be argued in its own ADR.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md))

- **#1 (no secrets in source).** Trivially satisfied — the placeholder reconciler authenticates with the existing workload identity through [`scripts/Connect-Purview.ps1`](../../scripts/Connect-Purview.ps1); no new credential is introduced.
- **#2 (managed-identity ordering).** Upheld — no new identity, no new consent grant, no new federated credential.
- **#4 (least privilege).** Upheld. The placeholder reconciler makes no writes and therefore needs no Authoring role; its only runtime requirement is the same Azure CLI token cache the rest of the data-plane reconcilers already consume.
- **#9 (idempotent, reversible, auditable).** Reinforced. A read-only / `-WhatIf`-only posture against an undocumented authoring surface is the most idempotent and most auditable shape available.

## Alternatives considered

1. **Ship a live `Deploy-UnifiedCatalog.ps1` against the Microsoft Purview Unified Catalog portal's internal REST surface (browser dev-tools-captured calls).** Rejected. Same reasoning as [ADR 0019](0019-cc-graph-pivot.md) §6 and [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6: violates the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and breaks on any backend revision without warning. A surface we cannot cite on Learn is unusable.

2. **Pivot to Microsoft Graph.** Rejected. The Graph `v1.0` and `beta` `$metadata` documents fetched 2026-06-15 contain **zero** Unified Catalog authoring resources; the only `unifiedCatalog` / `dataGovernance` hits in beta are read-only `microsoft.graph.security.*OperationRecord` audit-record types, identical in shape to the CC / DSPM-for-AI Graph footprint that ADR 0019 and ADR 0022 already rejected as authoring surfaces.

3. **Pivot to a speculative Atlas REST endpoint under one of the existing Data Map data-plane sections (e.g., `datamapdataplane/glossary` extended to cover data products).** Rejected. The Data Map glossary surface is the Microsoft Purview Data Map business glossary, which [ADR 0020](0020-dspm-before-azure-gov.md) positions as a *source feeding* Unified Catalog rather than as Unified Catalog itself. Repurposing Data Map endpoints to author UC concepts would commit the repo to a service contract Microsoft Learn does not document and to a semantics Microsoft documentation explicitly separates.

4. **Treat Unified Catalog as out of scope for this repository (mirror [ADR 0018](0018-ediscovery-scope.md)'s eDiscovery decision).** Rejected on the same grounds as alternative 4 in [ADR 0019](0019-cc-graph-pivot.md) §Alternatives. eDiscovery is *case-shaped* (transactional, identifier-laden, privilege-sensitive) and genuinely does not fit a policy-as-code model regardless of API availability. Unified Catalog *is* declarative-shaped (standing governance domains, data products, OKRs, CDEs, health controls — rare to change relative to operational data, appropriate to review in a PR) and *would* fit policy-as-code the day Microsoft documents an authoring surface. Descoping the entire workload would discard the structural decisions ratified by [ADR 0024](0024-unified-catalog-folder-placement.md) and the placeholder reconciler shipped by [#340](../../issues/340), and would foreclose a future re-enable. Deferral is the lower-regret choice.

5. **Delete the placeholder reconciler and the five YAMLs as dead code.** Rejected. The placeholder satisfies the [full-circle reconciler contract guard](../../.github/workflows/validate.yml) in CI, validates the five YAMLs against their schemas on every PR, and re-uses the same exit path (`error 'not implemented - pending authoring-surface ADR'` on non-`WhatIf`) the day a Microsoft-documented authoring surface lands. Deleting it would discard the staging cost and would require Wave 4b PR #2 ([#340](../../issues/340)) to be re-litigated when the watch list flips. Same logic as keeping [`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1) on the legacy IPPS cmdlets per [ADR 0019](0019-cc-graph-pivot.md) §Decision item 2.

6. **Do nothing — leave Q13 open with no ADR.** Rejected. The §8 Open-question ADRs sub-section exists precisely so that questions get decisive answers and the cadence does not stall. "Decisive answer" includes "the answer is *defer the reconciler, keep the placeholder, watch the surface*, and here is what would re-open the question". The §5.6 row stays blocked indefinitely otherwise, and the row is one of only two unticked rows in §5 (§5.7 cross-cutting surface-completeness check is the other).

## Citations

- [Learn about Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog) — fetched 2026-06-15. HTTP 200, 63,742 bytes. Zero occurrences of `PowerShell`, `cmdlet`, `REST API`, `graph.microsoft`, `programmat`, `api-version`. Establishes that the UC overview page documents portal-only authoring across all five concept areas.
- [Data Products in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-data-products) — fetched 2026-06-15. HTTP 200, 52,172 bytes. Zero occurrences of the same six keywords.
- [Governance Domains in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-governance-domain) — fetched 2026-06-15. HTTP 200, 52,345 bytes. Zero occurrences of the same six keywords.
- [Objectives and Key Results (OKRs) in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-okr) — fetched 2026-06-15. HTTP 200, 52,780 bytes. Zero occurrences of the same six keywords.
- [Data Quality in Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/data-quality-overview) — fetched 2026-06-15. HTTP 200, 58,344 bytes. Zero occurrences of the same six keywords. Closest documented surface to the health-controls concept (no dedicated `concept-health-control[s]` page exists).
- [Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview) — fetched 2026-06-15. HTTP 200, 54,013 bytes. Zero occurrences of the same six keywords. UC product umbrella page.
- [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/) — fetched 2026-06-15. HTTP 200, 36,938 bytes. SPA-rendered TOC; no UC section enumerable from the static surface. Direct probes against `/unifiedcatalogdataplane/` and `/datagovernancedataplane/` both return HTTP 404, same null result [ADR 0024](0024-unified-catalog-folder-placement.md) recorded on 2026-05-24.
- [Microsoft Purview What's New](https://learn.microsoft.com/en-us/purview/whats-new) — fetched 2026-06-15. HTTP 200, 96,191 bytes. Two Unified Catalog mentions, both portal-experience changes (glossary migration wizard, bulk import / edit / move). Zero PowerShell / cmdlet mentions scoped to Unified Catalog.
- Microsoft Graph `$metadata` — `https://graph.microsoft.com/v1.0/$metadata` (fetched 2026-06-15, HTTP 200, 2.76 MB) and `https://graph.microsoft.com/beta/$metadata` (fetched 2026-06-15, HTTP 200, 7.10 MB). v1.0 contains zero UC-shaped entity types. Beta contains only read-only `microsoft.graph.security.microsoftPurviewUnifiedCatalogOperationRecord` and `microsoft.graph.security.dataGovernanceAuditRecord` audit-record entity types — same shape as ADR 0019 / ADR 0022 found for CC and DSPM for AI.
- [ADR 0019 — Communication Compliance Graph pivot](0019-cc-graph-pivot.md) — precedent for the watch-list-deferral verdict and the §6 / §7 prohibition against undocumented portal-internal REST. This ADR inherits the same shape.
- [ADR 0022 — DSPM for AI authoring surface](0022-dspm-for-ai-authoring-surface.md) — second precedent for the same verdict on a different Purview workload. This ADR is the third instance of the same pattern.
- [ADR 0024 — Unified Catalog folder placement](0024-unified-catalog-folder-placement.md) — the structural ADR this ADR completes. The deferred authoring-surface question explicitly named in ADR 0024 §Decision item 3 is the question this ADR answers.
- [ADR 0027 — autoApplicationOf removal watch-list](0027-autoapplication-removal-watch-list.md) — closure-rubric precedent. The §5.2 sensitivity-label removal-path row was ticked under the §4 watch-list-row closure rubric the same way §5.6 row 1 is ticked here.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" rule applied throughout.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — principles #1, #2, #4, #9 cited in Consequences.

## References

- **[Learn about Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/unified-catalog)**
  Fetch date: 2026-06-15
  > "Microsoft Purview Unified Catalog is the central catalog of data products in the data estate of an organization." (page lede, paraphrased — confirms UC is the product surface; page contains zero `PowerShell` / `cmdlet` / `REST API` / `graph.microsoft` / `programmat` / `api-version` occurrences).
- **[Data Products in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-data-products)**
  Fetch date: 2026-06-15
  Cited for the data-products concept and to confirm zero programmatic-authoring keywords on the dedicated concept page.
- **[Governance Domains in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-governance-domain)**
  Fetch date: 2026-06-15
  Cited for the governance-domains concept and to confirm zero programmatic-authoring keywords.
- **[Objectives and Key Results (OKRs) in Unified Catalog](https://learn.microsoft.com/en-us/purview/concept-okr)**
  Fetch date: 2026-06-15
  Cited for the OKRs concept and to confirm zero programmatic-authoring keywords.
- **[Data Quality in Microsoft Purview Unified Catalog](https://learn.microsoft.com/en-us/purview/data-quality-overview)**
  Fetch date: 2026-06-15
  Cited as the closest documented adjacent surface for `health-controls.yaml` (no dedicated `concept-health-control[s]` page exists on Learn as of the fetch date).
- **[Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview)**
  Fetch date: 2026-06-15
  Cited as the product-umbrella surface for the two concept areas (critical data elements, health controls) that have no dedicated `concept-*` page.
- **[Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/)**
  Fetch date: 2026-06-15
  Cited to confirm no `unifiedcatalogdataplane` or `datagovernancedataplane` section is documented. The TOC page returns HTTP 200; direct probes against both candidate UC paths return HTTP 404.
- **[Microsoft Purview What's New](https://learn.microsoft.com/en-us/purview/whats-new)**
  Fetch date: 2026-06-15
  > "modernized management of glossary terms by migrating glossary terms created in the classic governance experience into Unified Catalog"
  > "New bulk import, editing, and moving capabilities can help you quickly scale operations in Unified Catalog"
  Cited to confirm the only Unified Catalog cadence entries are portal-experience changes; no programmatic surface announcement.
- **Microsoft Graph `v1.0` `$metadata`** — `https://graph.microsoft.com/v1.0/$metadata`
  Fetch date: 2026-06-15
  Cited to confirm zero Unified Catalog authoring entity types across `dataProduct`, `governanceDomain`, `criticalDataElement`, `unifiedCatalog`, `dataGovernance`, `healthControl`, `keyResult`.
- **Microsoft Graph `beta` `$metadata`** — `https://graph.microsoft.com/beta/$metadata`
  Fetch date: 2026-06-15
  Cited to confirm the only UC-shaped entity types are read-only audit records (`microsoft.graph.security.microsoftPurviewUnifiedCatalogOperationRecord`, `microsoft.graph.security.dataGovernanceAuditRecord`), identical in shape to the Graph footprint ADR 0019 and ADR 0022 already rejected as authoring surfaces.
