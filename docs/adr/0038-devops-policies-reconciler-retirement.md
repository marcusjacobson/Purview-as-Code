# 0038 — Microsoft Purview DevOps policies reconciler retirement: surface in classic customer-support mode

- **Status:** Accepted
- **Date:** 2026-06-16
- **Gates:** Resolves §5.9 follow-up queue item ([#633](../../issues/633)). Retires `scripts/Deploy-Policies.ps1`, `data-plane/policies/`, and `tests/scripts/Deploy-Policies.Tests.ps1`. Updates `docs/project-plan.md` §5.5 row 4.
- **Deciders:** @contoso

## Context

The §5.5 DevOps policies row was ticked in [PR #625](../../pull/625) as a no-drift Phase 1+2 closure. The closure surfaced a disqualifying constraint: the lab tenant returns `UnsupportedApiVersion` on every call to the `policystoredataplane` surface because no DUM (Data Use Management)-enabled data source is registered. The `policies.yaml` desired state is `policies: []` and the tenant carries zero portal-authored policies. There is nothing to reconcile.

The issue filed for Phase 3+4 hardening ([#633](../../issues/633)) deferred work until one of four re-open triggers fired. Picking the issue up in the §5.9 ready queue and performing the required research reaches the retirement decision documented here.

### Research surface — Microsoft Learn (verified 2026-06-14 per §5.5 row evidence)

**DevOps policies concept page** — [`learn.microsoft.com/en-us/purview/concept-policies-devops`](https://learn.microsoft.com/en-us/purview/concept-policies-devops) carries the classic-customer-support-mode banner; documentation is mirrored under `/purview/legacy/`. The classic Microsoft Purview governance experience is in customer-support mode and no longer receiving new investments. No GA successor to `policystoredataplane` is documented anywhere under `/purview/` (non-legacy path).

**Policy Store REST API** — [`learn.microsoft.com/en-us/rest/api/purview/policystoredataplane`](https://learn.microsoft.com/en-us/rest/api/purview/policystoredataplane) — the only documented `api-version` is `2022-08-01-preview`, approximately four years old with no GA stamp published in the intervening window.

**Re-open trigger evaluation** (from issue #633):

| Trigger | Status |
|---|---|
| DUM-enabled data source registered | Not fired — no source in `data-sources.yaml` has `dataUseGovernance: Enabled` |
| GA `api-version` for `policystoredataplane` | Not fired — `2022-08-01-preview` remains the only documented version |
| Successor surface documented under `/purview/` (non-legacy) | Not fired — documentation moved to `/purview/legacy/`; no successor announced |
| Deprecation / retirement notice for `2022-08-01-preview` | Effectively fired — the legacy-path mirror and classic-customer-support-mode banner are the practical end-of-investment signal |

The fourth trigger is the closest match: moving documentation to `/purview/legacy/` with a classic-customer-support-mode banner is the practical equivalent of a retirement notice. Retrofitting a reconciler against a surface that is in customer-support mode, uses a 4-year-old preview API, and cannot execute against the lab tenant (`UnsupportedApiVersion`) provides no value.

**Contrast with Unified Catalog ([ADR 0037](0037-unified-catalog-authoring-surface.md))** — that ADR kept the `Deploy-UnifiedCatalog.ps1` placeholder because no public retirement signal exists and a successor authoring surface is plausible. The DevOps policies surface is the inverse: the retirement signal is explicit (legacy path, classic-support mode banner), no successor is documented, and the reconciler cannot reach the surface on the lab tenant.

## Decision

**Retire the DevOps policies reconciler.** Specifically:

1. **Delete [`scripts/Deploy-Policies.ps1`](../../scripts/Deploy-Policies.ps1).** The reconciler cannot execute against the lab tenant and the surface is in end-of-investment mode. No retrofit of ADR 0029 will be performed.

2. **Delete [`data-plane/policies/`](../../data-plane/policies/).** The desired-state YAML is `policies: []` and has never carried a real entry. No tenant state is associated with it; no rollback is required.

3. **Delete [`tests/scripts/Deploy-Policies.Tests.ps1`](../../tests/scripts/Deploy-Policies.Tests.ps1).** The tests validate helpers inside `Deploy-Policies.ps1`; removing the script removes the test surface.

4. **Remove the `Deploy policies` step from [`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml).** The step has been a graceful-degrade no-op (`UnsupportedApiVersion` warning) on every dispatch since it was added. Removing it eliminates dead-code CI work.

5. **Update `docs/project-plan.md` §5.5 row 4** to reference this ADR and the retirement PR.

## Consequences

### Positive

- Removes dead code (`Deploy-Policies.ps1`, `policies.yaml`, tests) that cannot execute and provides no value.
- Eliminates the `UnsupportedApiVersion` graceful-degrade warning from every `deploy-data-plane.yml` dispatch run.
- The `full-circle reconciler contract guard` in `validate.yml` no longer scans the file (it was passing only because the script was already fully implemented, not because it was exercisable).
- No tenant state is affected: the tenant carries zero policies; `policies.yaml` was always `policies: []`.

### Neutral

- If any of the four issue #633 re-open triggers fires in the future, the reconciler must be authored from scratch against the then-current surface. Issue #633 retains the acceptance criteria and re-open trigger definitions as a forward pointer.

### Risk

- None beyond normal PR review. No live Purview objects are deleted; no role assignments are removed; no OIDC credentials are touched.

## Re-open triggers (retained from issue #633)

If any of the following fires, re-open issue #633 and author a new reconciler against the activated or successor surface:

1. A DUM-enabled data source is registered against the Purview account (`Deploy-Policies.ps1 -WhatIf` returns a non-warning plan — script must be recreated first).
2. Microsoft publishes a GA `api-version` for `policystoredataplane` (Learn page exists at the REST reference with a non-preview stamp).
3. Microsoft documents a successor surface under `/purview/` (not `/purview/legacy/`) naming the replacement API and a migration guide.
4. Microsoft publishes an explicit deprecation notice with a sunset date for `2022-08-01-preview`.

## References

- **[DevOps policies concepts](https://learn.microsoft.com/en-us/purview/concept-policies-devops)**
  Fetch date: 2026-06-14 (per §5.5 row evidence in `docs/project-plan.md`)
  Classic customer-support-mode banner; documentation mirrored under `/purview/legacy/`.
- **[Policy Store data plane REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/policystoredataplane)**
  Fetch date: 2026-06-14 (per §5.5 row evidence)
  Only `api-version=2022-08-01-preview` documented; no GA version published.
- [ADR 0037](0037-unified-catalog-authoring-surface.md) — contrasting watch-list-defer case (no retirement signal, placeholder retained).
- [Issue #633](../../issues/633) — original deferred follow-up with re-open triggers and acceptance criteria.
- [PR #625](../../pull/625) — Phase 1+2 closure (no-drift tick).
