# 0047 — Microsoft Purview Unified Catalog preview REST API: adopt a coexistence track alongside the classic Data Map

- **Status:** Accepted <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-07-06
- **Gates:** Supersedes [ADR 0037](0037-unified-catalog-authoring-surface.md) (§8 Q13); fires ADR 0037 re-open trigger #1. Builds on [ADR 0024](0024-unified-catalog-folder-placement.md) (folder placement, unchanged). Unblocks the follow-up Unified Catalog scaffolding items (folder rename, two new concept manifests, the live reconciler(s), the account-shape probe, and a `/deploy-unified` prompt), each of which branches only after this ADR is Accepted. Closes [#32](../../issues/32).
- **Deciders:** @contoso

## Context

[ADR 0024](0024-unified-catalog-folder-placement.md) resolved the structural questions for Unified Catalog — folder placement at `data-plane/unified-catalog/` and a per-concept YAML split (`governance-domains.yaml`, `data-products.yaml`, `okrs.yaml`, `critical-data-elements.yaml`, `health-controls.yaml`) — and deferred the authoring-surface question. [ADR 0037](0037-unified-catalog-authoring-surface.md) then answered that deferred question on 2026-06-15 with a verified null result: **Microsoft Learn documented no programmatic authoring API for Unified Catalog**, so the Wave 4b reconciler [`scripts/Deploy-UnifiedCatalog.ps1`](../../scripts/Deploy-UnifiedCatalog.ps1) stayed a `-WhatIf`-only placeholder and the five concept YAMLs stayed at `items: []`. ADR 0037 §Decision item 6 defined a **watch list** with explicit re-open triggers, the first of which was:

> "A `unifiedCatalogdataplane` or `datagovernancedataplane` section lands under [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/) (preview or GA) covering any of: governance domains, data products, OKRs, critical data elements, or health controls."

### Re-open trigger #1 has fired (verified 2026-07-06)

Microsoft Learn now documents a Unified Catalog data-plane REST API in **Public Preview**. All three probes below returned HTTP 200 and were fetched on 2026-07-06 (see §Citations and §References for fetch dates and quotes):

| Page | Finding |
|---|---|
| [Unified Catalog API (Public Preview)](https://learn.microsoft.com/en-us/rest/api/purview/unified-catalog-api-overview) | Announces a programmatic API for OKRs, business domains, critical data elements, data products, glossary terms, data access policies, data assets, and data columns. Two preview versions: `2026-03-20-preview` (latest) and `2025-09-15-preview` (first). |
| [Purview Unified Catalog — operation groups](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/operation-groups) | Enumerates eight operation groups for `2026-03-20-preview`: Business Domain, Critical Data Elements, Data Assets, Data Columns, Data Products, Okr, Policies, Terms. |
| [API authentication for Microsoft Purview data planes](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane) | Documents Microsoft Entra ID token-based authentication for the Purview data-plane APIs — the same auth model this repo's `Connect-Purview.ps1` ladder already produces. |

This is the exact inverse of the 2026-06-15 finding ADR 0037 was grounded on. Under ADR 0037's own contract, a fired trigger is "closed and superseded by a new ADR". This ADR is that new ADR.

### Operational driver — new accounts speak only the unified data plane

Independently of the API becoming available, a freshly provisioned Microsoft Purview account in a lab tenant surfaced **only** the new unified experience: the portal at `purview.microsoft.com` and a data-plane host of the shape `{account}.purview-service.microsoft.com`. The classic, Apache Atlas-based Data Map data-plane host `{account}.purview.azure.com` — the target of every existing `scripts/Deploy-*.ps1` Data Map reconciler in this repo — was not exposed on that account. Both account shapes now exist in the wild: classic accounts that expose the Atlas Data Map, and new accounts that expose only the unified data plane. A framework that speaks only one host strands the other.

### Object model — not a 1:1 map to the classic Data Map

The Unified Catalog object model (business domains, data products, OKRs, critical data elements, glossary terms, data access policies, plus read-only data assets and data columns) is a **different surface** from the classic Data Map object model (collections, Data Map business glossary, custom classifications, registered data sources, scans and scan rulesets). [ADR 0020](0020-dspm-before-azure-gov.md) positions the classic Data Map as a *source feeding* Unified Catalog, not as the same surface. The two tracks therefore cannot share manifests or reconcilers; a parallel track is required, not a retrofit of the existing Data Map scripts.

## Decision

We will **adopt Unified Catalog as a parallel "unified" data-plane track that coexists with the classic Data Map track**, and supersede ADR 0037. Specifically:

1. **Supersede [ADR 0037](0037-unified-catalog-authoring-surface.md).** Its portal-only verdict and its "defer the live reconciler" decision are reversed by the fired watch-list trigger. Its Status header flips to `Superseded by [ADR 0047]` in the same PR as this ADR. The Wave 4b placeholder reconciler and the five concept YAMLs are **retained** as the starting point the follow-up items build on — nothing is deleted.

2. **Coexistence, not migration.** We keep the classic Data Map track (manifests under `data-plane/collections/`, `data-plane/glossary/`, `data-plane/classifications/`, `data-plane/data-sources/`, `data-plane/scans/` and their `Deploy-*.ps1` reconcilers) for classic accounts, and we **add** a parallel unified track under `data-plane/unified-catalog/` for accounts that expose the unified data plane. We do **not** pivot the framework to unified-only. Rationale: both account shapes exist, the classic Data Map API still functions for classic accounts, and a unified-only pivot would strand every classic account with no supported track.

3. **Account-shape detection heuristic drives routing.** A deploy run selects a track by detecting which data-plane host the target account exposes:
   - **Classic** — the account answers on the Atlas Data Map host `{account}.purview.azure.com` (path prefix `/catalog/api/atlas`). Route to the existing Data Map reconcilers.
   - **Unified** — the account answers on the unified data-plane endpoint. Learn documents Unified Catalog requests as `{endpoint}/datagovernance/catalog/...?api-version=2026-03-20-preview`, where `{endpoint}` is a required path parameter (the account's Purview endpoint); the new-account host that fills `{endpoint}` was observed empirically as `{account}.purview-service.microsoft.com` (portal `purview.microsoft.com`). Route to the unified track.

   The **strategy** (detect which data-plane endpoint the account exposes, then route) is decided here. The Learn-grounded facts are the request path shape (`/datagovernance/catalog/`) and that `{endpoint}` is a per-account parameter. **Microsoft Learn does not currently document a procedure for programmatically detecting whether an account exposes the classic Data Map data plane or the unified data plane as of 2026-07-06.** The **exact `{endpoint}` host string, the probe request, and its success/failure signal** are therefore an implementation detail deferred to the reconciler follow-up item, which must confirm them against the [`2026-03-20-preview` Swagger specification](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/purviewdatagovernance/data-plane/Azure.Analytics.Purview.UnifiedCatalog/preview/2026-03-20-preview) before any host is hard-coded. Per the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md), the `{account}.purview-service.microsoft.com` host is recorded here as an empirical observation, not a Learn-confirmed literal.

4. **Pin a single preview `api-version`; treat Unified Catalog as its own endpoint family.** The Unified Catalog data-plane API is **preview-only** — no GA version exists as of 2026-07-06. This is precisely the carve-out the repo already permits: [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"Choose the newest GA version" allows a `-preview` `api-version` "when a preview-only endpoint or field is required," with a justification comment immediately above the call. We therefore:
   - Pin the unified track to the single latest preview version **`2026-03-20-preview`** (a superset of `2025-09-15-preview`: it adds the Data Assets and Data Columns operation groups and Count APIs). One version, repo-wide, for the new "Unified Catalog data-plane" endpoint family — satisfying the [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"One version per endpoint family" rule, which is scoped per family (Data Map, Scanning, Account, Policy Store each get their own pin; Unified Catalog is a new family, not a change to any existing pin).
   - Require the `# api-version justification:` comment above every Unified Catalog `Invoke-RestMethod` call, per the same rule.
   - **Re-pin / migration triggers.** Two distinct rules watch this pin: (a) when a **GA** `api-version` for the Unified Catalog data plane is documented on Learn, the "GA-over-preview" rule fires and the next PR touching the reconciler re-pins to GA; (b) when the pinned preview version is marked **retired or scheduled for retirement** on Learn, the separate "deprecation triggers migration" rule fires and the next PR migrates or opens a tracking issue. Preview-to-preview churn (e.g., a `2026-03-20-preview` successor) is evaluated under (a)'s "newest supported version" intent.

5. **Reconcile the object model against the existing `data-plane/unified-catalog/` folder.** The preview API's operation groups do not match the ADR 0024 folder set 1:1. Each delta is resolved as follows (the folder rename and additions are **follow-up items**, not this ADR):

   | Preview API operation group | Existing folder file | Resolution |
   |---|---|---|
   | Business Domain | `governance-domains.yaml` | **Rename** to `business-domains.yaml` to match the API term. The concept is the same; the label changes. |
   | Data Products | `data-products.yaml` | Keep. |
   | Okr | `okrs.yaml` | Keep. |
   | Critical Data Elements | `critical-data-elements.yaml` | Keep. |
   | Terms | *(none)* | **Add** `glossary-terms.yaml` — Unified Catalog glossary terms, distinct from the classic Data Map glossary under `data-plane/glossary/`. |
   | Policies | *(none)* | **Add** `data-access-policies.yaml` — Unified Catalog data access policies. |
   | Data Assets | *(none)* | **Excluded from the initial declarative-YAML scope** as a repo scope choice — not an API limitation. The operation group is write-capable (Learn documents Create, Update, Delete By Id, and relationship operations), but data assets are scan-populated inventory rather than hand-curated desired state, so they are not authored from a `data-plane/**` manifest in the initial track. They are available for `-ExportCurrentState` / read. Bringing them into the declarative track is a future decision. |
   | Data Columns | *(none)* | **Excluded from the initial declarative-YAML scope** as a repo scope choice, same rationale as Data Assets — a write-capable operation group over scan-populated inventory, exported/read-only in the initial track. |
   | *(none)* | `health-controls.yaml` | **Not in the preview API.** Data quality / health-control authoring remains portal-only. The file is retained as a portal-only concept outside the unified reconciler's declarative scope, exactly as ADR 0037 left it, until a future watch trigger adds a health/data-quality authoring surface. |

6. **State the preview-vs-classic capability gaps explicitly — no parity assumption.** The overview page states the API "only covers the Unified Catalog features that are available in General Availability (GA). Any Unified Catalog features that are released as Preview aren't supported by this API." Concretely:
   - The unified track covers **only** the eight operation groups above. It is **not** a replacement for the classic Data Map surface — collections, scans, scan rulesets, registered data sources, and the Atlas business glossary have no Unified Catalog equivalent and stay on the classic track.
   - Health controls / data quality authoring is **absent** from the API (item 5).
   - Any Unified Catalog capability that is still in *preview at the product level* is out of scope of this API and therefore out of scope of the unified reconciler.

7. **Authentication is unchanged — no new secret story.** The unified track authenticates with Microsoft Entra ID data-plane tokens obtained through the existing [`scripts/Connect-Purview.ps1`](../../scripts/Connect-Purview.ps1) ladder (OIDC federated credential in CI per [ADR 0010](0010-automation-identity-subject-model.md), Key Vault-signed certificate for the dev loop per [ADR 0011](0011-certificate-lifecycle.md) / [ADR 0028](0028-co-equal-local-cert-credential.md)). The [data-plane API authentication tutorial](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane) confirms Entra ID token auth is the model for the Purview data-plane APIs. No client secret, no new credential, no new federated subject is introduced by this ADR.

8. **The follow-up live reconciler(s) must ship full-circle from day one.** Per [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) §"New scripts ship full-circle", the promoted `Deploy-UnifiedCatalog.ps1` (or per-concept split) must expose `SupportsShouldProcess` / `-WhatIf`, `-PruneMissing` (off by default), `-Force`, `-ExportCurrentState`, the `-DirectionPolicy` direction-policy surface ([ADR 0029](0029-source-of-truth-direction-policy.md)), and `-SkipNames` for declared-orphan baselines, with per-write `ShouldProcess`, the deterministic export round-trip triangle (`-ExportCurrentState` → empty `git diff` → `-WhatIf` shows only `NoChange`), and the first-run-against-an-existing-tenant contract (export-first, then reconcile). Export-first on first run is the same reason [`docs/getting-started.md`](../getting-started.md) §4 leads with `-ExportCurrentState -Force` — a first unified run against a populated account must not report every live object as `Orphan` drift.

9. **Data access policies get grant/revoke-aware gating, not just prune gating.** The Policies operation group can **grant or revoke access** through a `Create` or `Update` that is not a delete/prune operation, so the default `-PruneMissing`-off protection is not sufficient to keep an access-widening change safe. The follow-up policy reconciler must therefore: (a) treat any policy `Create`/`Update` that changes a subject or permission as a destructive-equivalent change requiring an explicit per-policy `-WhatIf` diff in the plan table and the same lab-owner gating a delete would need; (b) resolve policy subjects through the [ADR 0023](0023-identifier-resolution.md) `displayName` mechanism, never an inline object ID; and (c) preferably ship as its own `Deploy-UnifiedCatalogPolicies.ps1` reconciler and its own `@idea-intake` item, separate from the lower-risk domain/product/OKR/CDE/term concepts, so a policy change never rides in on an unrelated catalog PR.

10. **Scaffolding is follow-up work, gated on this ADR being Accepted.** This ADR decides and enumerates only. The unified track is delivered as separate `@idea-intake` items, one at a time: (a) rename `governance-domains.yaml` → `business-domains.yaml` and add `glossary-terms.yaml` + `data-access-policies.yaml` with their Draft-07 schemas; (b) promote `Deploy-UnifiedCatalog.ps1` to a live full-circle reconciler pinned to `2026-03-20-preview`; (c) build the `Deploy-UnifiedCatalogPolicies.ps1` policy reconciler with the item-9 gating; (d) implement the account-shape probe and routing; (e) add a `/deploy-unified` prompt (or extend `/deploy-datamap` to route on account shape). None of these branch before this ADR is Accepted, per the repo's "the ADR must ship as its own item first" rule.

## Consequences

**Easier**

- New Purview accounts that expose only the unified data plane gain a supported as-code track instead of silently having no reconciler that can talk to them.
- The Wave 4b placeholder reconciler and the five concept YAMLs earn a forward path: ADR 0037's staging cost is realized rather than stranded.
- Classic accounts are untouched — the existing Data Map track keeps working with zero change, so no existing lab state regresses.
- The preview-only pinning is in-rule (the existing preview carve-out), so no instruction file has to be relaxed; only a justification comment is required at the call site.

**Harder**

- The repo now maintains **two** data-plane tracks with a routing decision between them. The account-shape probe is new surface to build, test, and keep current.
- The pin is a preview `api-version`, so the "deprecation triggers migration" rule now watches for a UC GA version and for preview-version churn (the jump from `2025-09-15-preview` to `2026-03-20-preview` in one cadence window shows the surface is still moving).
- The object-model rename (`governance-domains.yaml` → `business-domains.yaml`) is a breaking change to the ADR 0024 folder contract; it is carried in a dedicated follow-up item with its own schema regeneration, not folded into an unrelated PR.
- Data quality / health controls remain a portal-only gap the unified track does not close.

**Security posture** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md))

- **#1 (no secrets in source)** and **#2 (managed-identity ordering)** — upheld. No new credential; the unified track reuses the existing Entra ID token ladder (item 7).
- **#4 (least privilege)** — the follow-up reconciler will need Unified Catalog write roles scoped to the account; role wiring stays with [`scripts/Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) per [ADR 0009](0009-portal-role-group-api-ship-order.md), not introduced here.
- **#9 (idempotent, reversible, auditable)** — the full-circle contract (item 8), `-PruneMissing` off by default, and per-write `ShouldProcess` carry forward unchanged. Data access policies (Policies operation group) are governance-sensitive and can widen access through a non-delete `Create`/`Update`; §Decision item 9 therefore gives them grant/revoke-aware gating (per-policy `-WhatIf` diff, owner gating, a dedicated reconciler) rather than relying on prune gating alone.
- Identifier resolution follows [ADR 0023](0023-identifier-resolution.md) verbatim for any principal (data product owner, domain steward, policy subject) or Azure topology identifier referenced from unified-track YAML.

## Alternatives considered

1. **Migration — pivot the framework to unified-only.** Rejected. The classic Data Map API still functions and classic accounts still exist; a unified-only pivot strands every classic account and discards working reconcilers for no benefit to accounts that cannot speak the unified data plane. Coexistence is the lower-regret choice while both account shapes exist.

2. **Do nothing — keep ADR 0037's portal-only verdict.** Rejected. ADR 0037's own §Decision item 6 says a fired trigger is "closed and superseded by a new ADR". Trigger #1 has verifiably fired (§Context). Leaving the verdict in place would violate the watch-list contract the repo committed to and would keep unified-only accounts unsupported despite a documented API now existing.

3. **Consume Unified Catalog through Microsoft Graph.** Rejected. As ADR 0037 recorded on 2026-06-15 and ADR 0019 / ADR 0022 recorded before it, the only Graph footprint for Unified Catalog is read-only `microsoft.graph.security.*OperationRecord` audit data, not an authoring surface. The purpose-built Purview data-plane REST API is the documented authoring surface; Graph is not.

4. **Reuse the existing classic Data Map (Atlas) endpoints to author Unified Catalog concepts.** Rejected on the same grounds as ADR 0037 §Alternatives item 3: the Data Map glossary and catalog endpoints are a distinct service contract that Microsoft documentation positions as a *source feeding* Unified Catalog, not as Unified Catalog itself. Repurposing them would commit the repo to semantics Microsoft separates.

5. **Author the unified track against the older `2025-09-15-preview` version for stability.** Rejected. `2026-03-20-preview` is a superset (adds Data Assets, Data Columns, and Count APIs) and is the version Microsoft marks "Latest public preview version." Pinning to the older version would forgo documented operation groups with no stability benefit, since both are preview.

## Citations

- [Unified Catalog API (Public Preview)](https://learn.microsoft.com/en-us/rest/api/purview/unified-catalog-api-overview) — fetched 2026-07-06. Establishes the programmatic API, the covered object model, and the two preview versions. Fires ADR 0037 re-open trigger #1.
- [Purview Unified Catalog — operation groups](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/operation-groups) — fetched 2026-07-06. Enumerates the eight `2026-03-20-preview` operation groups used in §Decision item 5.
- [Purview Unified Catalog — Data Assets operations](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-assets) — fetched 2026-07-06. Documents Create, Update, Delete By Id, and relationship operations; grounds the §Decision item 5 statement that Data Assets/Data Columns are write-capable and are excluded from the initial declarative scope by repo choice, not API limitation.
- [Purview Unified Catalog — Business Domain: Get](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/get) — fetched 2026-07-06. Documents the request shape `GET {endpoint}/datagovernance/catalog/businessdomains/{domainId}?api-version=2026-03-20-preview` with `{endpoint}` as a required per-account path parameter; grounds the §Decision item 3 routing facts.
- [API authentication for Microsoft Purview data planes](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane) — fetched 2026-07-06. Confirms Entra ID token-based auth for the Purview data-plane APIs (§Decision item 7).
- [Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview) — classic-vs-new product context for the coexistence rationale.
- [`2026-03-20-preview` Swagger specification](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/purviewdatagovernance/data-plane/Azure.Analytics.Purview.UnifiedCatalog/preview/2026-03-20-preview) — the authoritative source for the exact data-plane host and request shapes the follow-up reconciler item must confirm (§Decision item 3).
- [ADR 0024 — Unified Catalog folder placement](0024-unified-catalog-folder-placement.md) — the structural predecessor this ADR builds on; unchanged.
- [ADR 0037 — Unified Catalog authoring surface](0037-unified-catalog-authoring-surface.md) — the ADR this one supersedes; its watch-list trigger #1 is the mechanism that re-opened the question.
- [ADR 0019 — Communication Compliance Graph pivot](0019-cc-graph-pivot.md) and [ADR 0022 — DSPM for AI authoring surface](0022-dspm-for-ai-authoring-surface.md) — prior watch-list-deferral precedents; cited to explain why Graph is still not the surface (§Alternatives item 3).
- [ADR 0010](0010-automation-identity-subject-model.md), [ADR 0011](0011-certificate-lifecycle.md), [ADR 0028](0028-co-equal-local-cert-credential.md) — the Entra ID auth ladder the unified track reuses.
- [ADR 0023 — Identifier resolution](0023-identifier-resolution.md) — inherited verbatim for principal / topology identifiers in unified-track YAML.
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — §"Choose the newest GA version", §"One version per endpoint family", §"Deprecation triggers migration", and the full-circle reconciler contract cited in §Decision items 4 and 8.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" applied throughout, and "API version pinning".

## References

- **[Unified Catalog API (Public Preview)](https://learn.microsoft.com/en-us/rest/api/purview/unified-catalog-api-overview)**
  Fetch date: 2026-07-06
  > "The Unified Catalog API allows you to programmatically integrate and manage the Microsoft Purview Unified Catalog into your custom apps to automate operations, integrate custom workflows, and so on."
  > "The initial set of APIs is available in Public Preview and only covers the Unified Catalog features that are available in General Availability (GA). Any Unified Catalog features that are released as Preview aren't supported by this API."
- **[Purview Unified Catalog — operation groups](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/operation-groups)**
  Fetch date: 2026-07-06
  > Operation groups (`2026-03-20-preview`): Business Domain, Critical Data Elements, Data Assets, Data Columns, Data Products, Okr, Policies, Terms.
- **[API authentication for Microsoft Purview data planes](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)**
  Fetch date: 2026-07-06
  > "In this tutorial, you learn how to authenticate for the Microsoft Purview data plane APIs. Anyone who wants to submit data to Microsoft Purview, include Microsoft Purview as part of an automated process, or build their own user experience on Microsoft Purview can use the APIs to do so."
