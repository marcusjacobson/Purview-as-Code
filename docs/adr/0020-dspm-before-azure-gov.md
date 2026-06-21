# 0020 — Reorder Waves 3 and 4: DSPM ships before Azure governance

- **Status:** Accepted
- **Date:** 2026-05-16
- **Gates:** Reorders [`docs/project-plan.md`](../project-plan.md) §3 wave table and §4 dependency matrix; renames the §5 Progress checklist sub-headings. Does not resolve any open §8 Open-question ADR. Q5 ([#84](../../issues/84)) remains the single gate on the first DSPM item under the new ordering.
- **Deciders:** @contoso

## Context

The Progress checklist in [`docs/project-plan.md`](../project-plan.md) §5 has Waves 0–2 complete and two remaining waves: Wave 3 (Azure governance — populate the Data Map YAMLs in [#73](../../issues/73) and add `data-plane/unified-catalog/` in [#83](../../issues/83)) and Wave 4 (DSPM — [#74](../../issues/74), DSPM for AI — [#75](../../issues/75), optional SIT confidence analysis — [#76](../../issues/76)). The original ordering rationale, recorded in §2 guiding principle #1 and §3, was that DSPM "consumes signals from Waves 1–3" and therefore had to land last.

Re-examining that rationale against Microsoft Learn:

- **Data Security Posture Management for Microsoft Purview** ([DSPM overview](https://learn.microsoft.com/en-us/purview/dspm) and [Get started with DSPM](https://learn.microsoft.com/en-us/purview/dspm-get-started)) is an M365-side posture aggregator. Its signal inputs are sensitivity labels (Wave 1), Sensitive Information Types (Wave 1), Data Loss Prevention policies (Wave 2b), Insider Risk Management signals (Wave 2d), and the unified audit log (Wave 0). All five sources are already shipped.
- **DSPM for AI** ([DSPM for AI overview](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview)) consumes labels and audit signal from Microsoft 365 Copilot and AI app usage. Its inputs are Wave 0 (audit) and Wave 1 (labels).
- The **Purview Data Map** ([Data Map overview](https://learn.microsoft.com/en-us/purview/concept-elastic-data-map)) catalogs Azure-side data estate (Azure SQL, ADLS Gen2, etc.) and feeds the **Unified Catalog** ([Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog)). DSPM's M365 posture surface does not read from the Data Map; Data Map and Unified Catalog are independent surfaces aimed at Azure data governance, not M365 posture.

The `●` cell at "Wave 4 — DSPM" × "Data Map" in §4 was over-inclusive. It anticipated a future "Azure-side DSPM" surface that would correlate scan findings from registered Azure data sources with labels and policies. That surface is not part of [#74](../../issues/74) as currently scoped, and Microsoft Learn does not document a Data-Map-dependent input path on the standard DSPM dashboard today.

In the contoso-lab lab, DSPM is also the higher-value next step: the lab already has labels, SITs, DLP, IRM, audit, and Content Explorer in place, and the posture insights they would surface are the reason the rest of the chain was built. Data Map population requires synthetic Azure data sources to scan, which is additional lab setup with no posture-side payoff.

## Decision

**We will reorder Waves 3 and 4** so that DSPM (and DSPM for AI) ships before Purview Data Map and Unified Catalog. The reordering is bounded as follows:

1. **New wave numbering.** `docs/project-plan.md` §3 wave table becomes:
   - Wave 3 — DSPM (Data Security Posture Management, DSPM for AI).
   - Wave 4 — Azure governance (Purview Data Map, Unified Catalog).
2. **§5 Progress checklist sub-headings** rename `### Wave 3 — Azure governance` to `### Wave 4 — Azure governance` and `### Wave 4 — DSPM` to `### Wave 3 — DSPM`. Within each wave, items are renumbered: DSPM becomes 3a ([#74](../../issues/74)), DSPM for AI becomes 3b ([#75](../../issues/75)), optional SIT confidence analysis stays under Wave 3 as a non-lettered optional row ([#76](../../issues/76)); Data Map becomes 4a ([#73](../../issues/73)) and Unified Catalog becomes 4b ([#83](../../issues/83)).
3. **§4 dependency matrix** keeps every existing `●` except that the `●` at "DSPM × Data Map" is removed (justification: Microsoft Learn documents the standard DSPM surface as M365-signal-driven; Data Map is not a documented input). The rows are reordered so Wave 3 (DSPM) precedes Wave 4 (Azure governance). The matrix row label "Wave 4 — DSPM" becomes "Wave 3 — DSPM"; "Wave 4 — DSPM for AI" becomes "Wave 3 — DSPM for AI"; "Wave 3a — Data Map" becomes "Wave 4a — Data Map"; "Wave 3b — Unified Catalog" becomes "Wave 4b — Unified Catalog".
4. **§2 guiding principle #1** updates the example sentence: "Information Protection is Wave 1 (labels are referenced by DLP, auto-labeling, IRM, and DSPM) and Azure governance is Wave 4 (Data Map and Unified Catalog land after the M365 posture surface that does not depend on them)."
5. **§1 licensing assumption** updates "Waves 1–2 and Wave 4 depend on this" to "Waves 1–3 depend on this" (M365 E5 / E5 Compliance underpins IP, M365 governance, and DSPM; Wave 4 — Azure governance — requires the Purview account but not M365 E5).
6. **Cadence example on line 34** updates "Q7 (Unified Catalog folder placement, [#78](../../issues/78)) only blocks Wave 3b ([#83](../../issues/83)), not the rest of Wave 3" to point at Wave 4b ([#83](../../issues/83)) and "the rest of Wave 4" instead.
7. **Apply-path-hardening follow-up paragraph** updates "Current chain: [#267](../../issues/267) (Wave 2d IRM) and [#271](../../issues/271) (Wave 2e Communication Compliance) both gate Wave 3a ([#73](../../issues/73))." → "...both gate Wave 3a ([#74](../../issues/74))" since Wave 3a is now DSPM ([#74](../../issues/74)).
8. **Open-question ADR sub-section** updates Q5's gate text to "gates 3a / [#74](../../issues/74)" and Q7's gate text to "gates 4b / [#83](../../issues/83)" (both unchanged in substance, only the wave letter shifts).
9. **GitHub label state.** The `wave-3` label keeps its name and ID; its description updates to "Wave 3 - DSPM" and its color updates to the orange of the prior `wave-4`. The `wave-4` label description updates to "Wave 4 - Azure governance" and its color updates to the red of the prior `wave-3`. The label assignments on [#73](../../issues/73), [#74](../../issues/74), [#75](../../issues/75), [#76](../../issues/76), [#83](../../issues/83) are swapped accordingly so that each issue carries the label whose description matches its content.
10. **Issue titles, bodies, and acceptance criteria stay as filed.** This ADR's scope is the project plan and the wave labels. Renumbering inside individual issue titles (e.g., the literal `wave-4:` prefix on [#74](../../issues/74)) is left to whichever item runs first under the new ordering, where the contextual edit lands naturally. Q5 ([#84](../../issues/84)) remains the gate on Wave 3a ([#74](../../issues/74)) — this ADR does not resolve Q5.

## Consequences

**Easier:**

- **DSPM ships sooner.** The posture surface that motivated Waves 1 and 2 is consumed earlier, shortening the gap between investment and visible value.
- **No new lab dependencies for the next item.** Wave 3a (DSPM) reads only signal sources that are already live. Wave 4a (Data Map) needs synthetic Azure data sources, which is additional lab setup; deferring that step pushes the setup cost behind the higher-value work.
- **Dependency matrix becomes truthful.** Removing the unjustified DSPM × Data Map `●` aligns §4 with Microsoft Learn's documented signal flow.

**Harder:**

- **Future Azure-side DSPM surface needs its own item.** If a documented Data-Map-feeding DSPM input emerges on Microsoft Learn, it will land as a Wave 4 follow-up issue with its own dependency on the now-later Data Map, rather than as part of the original Wave 3a. The owner accepts that cost.
- **Label history.** Anyone reading the issue list across the swap will see legacy `wave-4` prefixes on issues now under Wave 3 (and vice versa) until the next PR per issue naturally renumbers them. The PR opening this ADR notes the convention.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Not affected — docs-only change.
- **#9 (idempotent, reversible, auditable).** The dependency-matrix edit is reversible by another ADR; the label-color and description swap is reversible via `gh label edit`; the §5 Progress checklist tick state stays correctly attached to the underlying issues regardless of wave numbering.

## Alternatives considered

1. **Status quo — keep DSPM as Wave 4.** Rejected. The dependency rationale that put DSPM last (`●` at DSPM × Data Map) is not supported by Microsoft Learn for the standard DSPM surface. Keeping the status quo would defer the highest-value posture work behind an Azure-side data-cataloging surface that the lab does not yet have data sources for.

2. **Move only DSPM (Wave 4a) forward and leave DSPM for AI (Wave 4b) behind Azure governance.** Rejected. DSPM for AI has no Data Map dependency in the current matrix either. Splitting the wave creates a third reordering with no benefit. Both items consume Wave 0 + Wave 1 inputs.

3. **Keep the wave numbering but ship items out of order.** Rejected. The Progress checklist's discipline is that wave numbers correspond to ship order. Decoupling those two would invite drift on every future wave-ordering question. A single explicit ADR is the cheaper bookkeeping.

4. **Carve DSPM into "M365-signal-only" (now Wave 3) and "Azure-signal-also" (left as Wave 5 or a Wave 4 sibling).** Rejected as premature. Microsoft Learn does not currently document an Azure-signal DSPM input surface as of `2026-05-16`. Filing a speculative Wave 5 today would consume agent and review bandwidth on something with no current Learn anchor. If such a surface lands, an ADR can introduce it then.

## Citations

- **[Data Security Posture Management for Microsoft Purview overview](https://learn.microsoft.com/en-us/purview/dspm)**
  Fetch date: 2026-05-16
  > "Data Security Posture Management (DSPM) provides visibility into data security risks and recommendations to mitigate those risks across your Microsoft 365 estate."
- **[Get started with DSPM](https://learn.microsoft.com/en-us/purview/dspm-get-started)**
  Fetch date: 2026-05-16
  Documents the signal inputs DSPM aggregates: sensitivity labels, Sensitive Information Types, DLP, Insider Risk Management, and the unified audit log. No documented Purview Data Map input on the standard DSPM surface.
- **[DSPM for AI overview](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview)**
  Fetch date: 2026-05-16
  Documents the Microsoft 365 Copilot and AI app signal flow into DSPM for AI. Inputs are Wave 0 (audit) and Wave 1 (labels); no Data Map dependency.
- **[Microsoft Purview Data Map overview](https://learn.microsoft.com/en-us/purview/concept-elastic-data-map)**
  Fetch date: 2026-05-16
  Confirms the Data Map is an Azure-side data-estate catalog (scan-driven), distinct from the M365 signal-driven DSPM surface.
- **[Microsoft Purview Unified Catalog overview](https://learn.microsoft.com/en-us/purview/unified-catalog)**
  Fetch date: 2026-05-16
  Confirms Unified Catalog reads from the Data Map; its dependency on Wave 4a stays intact.
- **[Content Explorer in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)**
  Fetch date: 2026-05-16
  Referenced by Q5 ([#84](../../issues/84)) as the remaining gate before Wave 3a ([#74](../../issues/74)) starts.
