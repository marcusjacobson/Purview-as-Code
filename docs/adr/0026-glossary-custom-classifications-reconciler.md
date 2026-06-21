# 0026 — Glossary and custom-classifications reconcilers: two scripts, one Data Map api-version pin

- **Status:** Accepted
- **Date:** 2026-05-28
- **Gates:** Resolves §8 Q12 in [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs). Unblocks §5.5 Glossary ([#373](../../issues/373)) and §5.5 Custom classifications ([#374](../../issues/374)).
- **Deciders:** @contoso

## Context

[`docs/project-plan.md`](../project-plan.md) §8 Q12 has been open since v2 opened:

> Glossary + custom classifications — do we ship one combined reconciler or two? Which API version?

Two §5.5 rows wait on this question: "Glossary — ship reconciler" ([#373](../../issues/373)) and "Custom classifications — ship reconciler" ([#374](../../issues/374)). Today both are scaffold-only files that `throw 'Not implemented yet'`:

- [`scripts/Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) — scaffold against `datamapdataplane/glossary`.
- [`scripts/Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) — scaffold against `datamapdataplane/types` **and** `scanningdataplane/classification-rules`.

The "one reconciler vs two" question is not aesthetic. The custom-classifications surface spans **two different Purview data planes** (Data Map + Scanning) joined by a foreign-key-style reference: a classification rule names the classification *type* it tags. The glossary surface lives entirely on **one** data plane (Data Map) and has no cross-plane join. The two scaffolds already model this by living as separate files with separate YAMLs ([`data-plane/glossary/glossary.yaml`](../../data-plane/glossary/glossary.yaml), [`data-plane/classifications/classifications.yaml`](../../data-plane/classifications/classifications.yaml)).

The api-version question matters because an unpinned `api-version=` query string is non-deterministic, mixes preview and GA shapes, and breaks reproducibility when Microsoft ships a new dated version. [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) requires every reconciler to pin a single Learn-cited api-version per surface, GA-over-preview when both exist. The existing pins in this repo, audited 2026-05-28:

| Reconciler | Surface | Pin | Notes |
|---|---|---|---|
| [`Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1) | `accountdataplane/collections` | `2019-11-01-preview` | preview-only surface (no GA published) |
| [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) | `scanningdataplane/data-sources` | `2023-09-01` | matches Learn-published value |
| [`Deploy-Scans.ps1`](../../scripts/Deploy-Scans.ps1) | `scanningdataplane/scans`, `scan-rulesets`, `triggers` | `2023-09-01` | matches Learn-published value |
| [`Deploy-Policies.ps1`](../../scripts/Deploy-Policies.ps1) | `policystoredataplane/policies` | `2022-08-01-preview` | preview-only surface |

A repo-wide audit (Invoke-WebRequest, 2026-05-28) of the three Learn pages this ADR consumes confirmed each publishes `2023-09-01` plus one or two newer dated versions:

- `datamapdataplane/glossary` → 2023-09-01, 2024-02-13, 2024-05-07
- `datamapdataplane/type` → 2023-09-01, 2024-05-07, 2024-06-18
- `scanningdataplane/classification-rules` → 2023-09-01, 2023-11-22, 2024-05-07

`2023-09-01` is the only value present on all three pages and is the value the two GA-pinned scanning-data-plane reconcilers in the repo already use.

The same fetch identified a defect in the [`scripts/Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) scaffold comment header: it cites `datamapdataplane/types` (plural), which returns HTTP 404. The correct URL is `datamapdataplane/type` (singular). The scaffold fix lands with the §5.5 [#374](../../issues/374) implementation, not in this ADR.

## Decision

We will:

1. **Ship two reconcilers, not one.** [`scripts/Deploy-Glossary.ps1`](../../scripts/Deploy-Glossary.ps1) consumes [`data-plane/glossary/glossary.yaml`](../../data-plane/glossary/glossary.yaml) and resolves §5.5 [#373](../../issues/373). [`scripts/Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) consumes [`data-plane/classifications/classifications.yaml`](../../data-plane/classifications/classifications.yaml) and resolves §5.5 [#374](../../issues/374). Each script owns one §5.5 Progress-checklist row.
2. **Pin all three REST endpoints both reconcilers touch to `api-version=2023-09-01`:**
   - `datamapdataplane/glossary` → `2023-09-01` (Glossary reconciler).
   - `datamapdataplane/type` → `2023-09-01` (Classifications reconciler — classification type definition).
   - `scanningdataplane/classification-rules` → `2023-09-01` (Classifications reconciler — regex / threshold rule).
3. **Each reconciler matches the existing drift contract** from [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"Drift report format" used by [`Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1) and [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1): Create / Update / NoChange / Orphan / Removed, gated by `-WhatIf` and `-PruneMissing`, `[CmdletBinding(SupportsShouldProcess)]`, `-ParametersFile` source-of-truth per [ADR 0012](0012-environment-parameters-file.md).
4. **Identifier handling follows [ADR 0023](0023-identifier-resolution.md).** Both reconcilers consume Category 2 (`PURVIEW_ACCOUNT_NAME` env token); neither needs Category 3 (Entra principal resolution); Category 1 (Key Vault secrets) is unused by the current YAML schemas but the helper remains available for any future SIT-bridging rule.

### Why two reconcilers, not one

| Question | Glossary | Custom classifications |
|---|---|---|
| Number of REST surfaces | 1 (`datamapdataplane/glossary`) | 2 (`datamapdataplane/type` + `scanningdataplane/classification-rules`) |
| Data plane(s) | Data Map | Data Map + Scanning |
| Foreign-key apply order | none | rule `classificationName` must resolve to an existing type — type before rule |
| Drift unit | one term per row | one classification + N rules (1-to-many); drift rows nest |
| YAML schema | `terms[]` | `classifications[]` + `rules[]` (already in [`classifications.yaml`](../../data-plane/classifications/classifications.yaml)) |
| Failure-mode vocabulary | term-not-found, shortDescription drift | type-not-found, regex-rejected, pattern-flag drift, threshold drift |
| §5.5 Progress-checklist row | [#373](../../issues/373) | [#374](../../issues/374) |

A combined reconciler would force one script to host two REST-surface vocabularies, two failure-mode taxonomies, two apply orderings, and a YAML that mixes term content with regex content. The operator running `Deploy-Combined.ps1 -WhatIf` could not visually separate "did the glossary diff?" from "did the classifications diff?" without parsing nested groupings. The combine-argument's wins (one auth call, one workflow step) are small: each existing reconciler already pays the same single-script cost, and [`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) already lists every reconciler as its own step.

### Why a single `2023-09-01` api-version across all three endpoints

- All three endpoints publish `2023-09-01` on their Learn REST pages (verified 2026-05-28). The same value is the only one common to all three.
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) requires GA-over-preview. The newer dated versions on these pages (2023-11-22, 2024-02-13, 2024-05-07, 2024-06-18) carry no explicit GA-or-preview marker in the static page metadata; absent explicit Learn evidence to upgrade, the conservative choice is the value the repo's existing GA-pinned scanning-data-plane reconcilers already use.
- Pinning the same value across these three new endpoints and the two existing GA-pinned reconcilers keeps the repo's api-version matrix as narrow as the Learn-published surface allows. A future ADR may migrate the matrix to a newer dated version once Microsoft publishes explicit GA-vs-preview tagging or once a deprecation notice forces it.
- The two preview-pinned reconcilers ([`Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1), [`Deploy-Policies.ps1`](../../scripts/Deploy-Policies.ps1)) stay as they are. Their surfaces are preview-only on Learn; both will migrate in their own follow-up PRs when GA versions ship. This ADR does not unify those.

## Consequences

**Easier:**

- **§5.5 unblocks for both rows.** [#373](../../issues/373) and [#374](../../issues/374) can each enter `@idea-intake` as separate follow-on items without re-litigating scope or api-version.
- **Drift reporting stays readable.** Each `Deploy-*.ps1 -WhatIf` output owns one feature; reviewers see "glossary: 3 Create, 1 Update, 0 Orphan" without parsing a combined header.
- **API-version matrix shrinks per endpoint.** Three more endpoints pin to `2023-09-01`, the GA-quality value already used by two existing reconcilers, instead of inventing a new pin.
- **Test fan-out is bounded.** Each reconciler gets its own Pester contract under `tests/scripts/` (`Deploy-Glossary.Tests.ps1`, `Deploy-Classifications.Tests.ps1`) mirroring [`tests/scripts/Deploy-DataSources.Tests.ps1`](../../tests/scripts/Deploy-DataSources.Tests.ps1) — no cross-feature mock juggling.
- **Glossary stub stops masking pipeline-health signal.** Today every `deploy-data-plane.yml` dispatch reports a job-level failure because the glossary stub throws. The §5.5 [#373](../../issues/373) implementation that this ADR unblocks turns that step green; a guard-the-stub interim PR (handoff brief follow-up 1) is no longer needed.

**Harder:**

- **Workflow step count increases by one.** [`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) gains one step for the Classifications reconciler. Mechanically trivial; the same per-step pattern exists for Collections, Data Sources, Scans, Policies.
- **Two follow-on implementation items, not one.** The lab owner files [#373](../../issues/373) and [#374](../../issues/374) separately. Each carries its own Exit criteria, its own `-WhatIf` evidence, its own initial-content PR.
- **Foreign-key apply order is the Classifications reconciler's problem.** A rule that references an undeclared classification name must fail validation in the Plan phase before the Apply phase touches the wire. The §5.5 [#374](../../issues/374) implementation must call this out explicitly; the Glossary reconciler has no equivalent join.
- **Scaffold URL defect inherited.** The `Deploy-Classifications.ps1` scaffold cites `datamapdataplane/types` (404). The fix lands in [#374](../../issues/374), not this ADR; tracked here so the follow-on item cannot quietly skip it.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Upheld. Neither YAML schema needs a credential field; classifications carry regex literals and integer thresholds, glossary terms carry descriptive strings.
- **#2 (managed-identity ordering).** Upheld. Both reconcilers authenticate through [`scripts/Connect-Purview.ps1`](../../scripts/Connect-Purview.ps1), inheriting the Azure CLI token cache used by every other Data Map reconciler. No new identity or Graph consent grant is introduced.
- **#10 (OWASP-aware).** Reinforced. The Classifications reconciler validates regex shape against [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) §"Regex rules for classification patterns" (anchored, bounded repetition, no catastrophic-backtracking shapes) before submitting it to the wire.

## Alternatives considered

1. **One combined `Deploy-DataMapContent.ps1` reconciler.** Rejected. Mixes two REST vocabularies, two failure-mode taxonomies, and two §5.5 Progress-checklist rows into one script and one drift report. Wins on script count, loses on diagnosability and on Pester scope.
2. **One reconciler, two `-Mode` parameters (`-Mode Glossary` / `-Mode Classifications`).** Rejected. Functionally identical to two scripts but routes `[CmdletBinding(SupportsShouldProcess)]` through a parameter set the existing reconcilers do not use, and forces shared state between two surfaces that share nothing else.
3. **Pin each endpoint to its most-recent dated version (potentially three different pins).** Rejected. No correctness benefit when all three publish the same `2023-09-01` value; adds matrix complexity for no win. The principle in `powershell.instructions.md` is GA-over-preview, not newest-per-endpoint.
4. **Defer Q12 indefinitely — keep both scaffolds as `throw` stubs.** Rejected. The §8 contract holds each open Q-row as a blocker on its §5 row; deferral keeps two §5.5 rows permanently unstartable and continues to mask `deploy-data-plane.yml` pipeline-health signal via the glossary stub throw.
5. **Do nothing.** Same as alternative 4; rejected for the same reasons.

## Citations

- [Glossary - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary)
- [Type - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type)
- [Classification Rules - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules)
- [Understand business glossary features](https://learn.microsoft.com/en-us/purview/concept-business-glossary)
- [Custom classifications in Microsoft Purview Data Map](https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule)
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift contract, GA-over-preview api-version rule, `-ParametersFile` contract.
- [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) — regex pattern rules the Classifications reconciler enforces in its Plan phase.
- [ADR 0012](0012-environment-parameters-file.md) — `-ParametersFile` contract both reconcilers inherit.
- [ADR 0023](0023-identifier-resolution.md) — identifier-resolution categories both reconcilers consume.

## References

- **[Glossary - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary)**
  Fetch date: 2026-05-28
  > "Glossary - REST API (Azure Purview)" (page title). Page lists api-versions 2023-09-01, 2024-02-13, 2024-05-07; static HTML returns 200; rendered swagger body is SPA-only and was not quotable from this fetch surface.
- **[Type - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type)**
  Fetch date: 2026-05-28
  > "Type - REST API (Azure Purview)" (page title). Page lists api-versions 2023-09-01, 2024-05-07, 2024-06-18; corrects the scaffold comment in [`Deploy-Classifications.ps1`](../../scripts/Deploy-Classifications.ps1) which cites the 404 `datamapdataplane/types` form.
- **[Classification Rules - REST API (Azure Purview)](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules)**
  Fetch date: 2026-05-28
  > "Classification Rules - REST API (Azure Purview)" (page title). Page lists api-versions 2023-09-01, 2023-11-22, 2024-05-07; same scanning data plane already used by `Deploy-DataSources.ps1` and `Deploy-Scans.ps1`.
- **[Understand business glossary features in the classic Microsoft Purview governance portal](https://learn.microsoft.com/en-us/purview/concept-business-glossary)**
  Fetch date: 2026-05-28
  > "Understand business glossary features in the classic Microsoft Purview governance portal" (page title). Confirms the feature this ADR's Glossary reconciler targets is currently documented as part of the classic Microsoft Purview governance portal.
- **[Custom classifications in Microsoft Purview Data Map](https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule)**
  Fetch date: 2026-05-28
  > "Custom classifications in Microsoft Purview Data Map" (page title). Confirms the feature this ADR's Classifications reconciler targets is documented as part of Microsoft Purview Data Map.
