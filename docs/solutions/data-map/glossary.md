# Purview Data Map — Glossary

Operational guide for [`scripts/Deploy-Glossary.ps1`](../../../scripts/Deploy-Glossary.ps1) — the reconciler that materializes [`data-plane/glossary/glossary.yaml`](../../../data-plane/glossary/glossary.yaml) against the [Microsoft Purview Data Map business glossary](https://learn.microsoft.com/en-us/purview/concept-business-glossary). Pairs with [`audit-log.md`](../governance-foundation/audit-log.md) (glossary writes are emitted to the same Unified Audit Log).

## Purpose

Reconciles the [Atlas Glossary REST surface](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary) against a declared set of business glossary terms. Emits Create / Update / NoChange / Orphan / Conflict / Skip decisions per term. Orphan terms (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline.

The Glossary model is documented at [Understand business glossary features in Microsoft Purview](https://learn.microsoft.com/en-us/purview/concept-business-glossary):

- Each glossary has a container name (default `Glossary`) auto-created by Purview on first term write.
- Each term carries a `name` (unique within the glossary), `shortDescription`, optional `longDescription`, and `status` (`Draft` / `Approved` / `Alert` / `Expired`).
- `experts` and `stewards` fields are stripped from comparison pending ADR 0023 Category 3 display-name resolution (deferred follow-up).

## Default state

The shipped YAML declares 1 glossary container (`Glossary`) and 3 scaffold terms (`Customer`, `PII`, `RevenueRecognition`) imported from PR #629. `-WhatIf` returns `Plan: 1 NoChange, 3 NoChange` when the live tenant matches.

## Authentication

Pure Purview data-plane REST — no Security & Compliance PowerShell, no Key Vault cert path required for the script itself. The script delegates token acquisition to [`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1), which uses the Azure CLI token cache (`az account get-access-token --resource https://purview.azure.net`). In CI the `azure/login@v2` OIDC step (per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)) provides the underlying federated identity.

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/glossary/glossary.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-AccountName` | `purviewAccountName:` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant terms. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-ExportCurrentState` | switch — round-trip the live tenant back into the YAML (mutually exclusive with `-PruneMissing`) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads glossaries + terms; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No POST, PUT, or DELETE writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads glossaries + terms; applies the skip baseline; prints Create / Update / NoChange / Orphan / Conflict / Skip rows. No writes. |
| (default) | Same read, then per-row POST (Create) or PUT (Update) or DELETE (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_glossary='overwrite portal'` token. |

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Data Curator` | Root collection of the target Purview account |
| Caller's identity in Azure | Active `az login` session | Subscription containing the Purview account |

Reference: [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## Smoke test

```pwsh
# Audit mode — read-only view of the live tenant vs YAML.
./scripts/Deploy-Glossary.ps1 -DirectionPolicy audit
```

Expected output tail when YAML matches the live tenant:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
...
Plan: 1 NoChange, 3 NoChange
```

For a near-unattended end-to-end smoke that exercises Create → Read → Update → Delete against a throwaway term, see [`docs/runbooks/glossary-end-to-end-smoke.md`](../../runbooks/glossary-end-to-end-smoke.md) and the [`scripts/Invoke-GlossarySmokeTest.ps1`](../../../scripts/Invoke-GlossarySmokeTest.ps1) wrapper.

## ADR 0029 contract

This reconciler conforms to [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md). The script accepts `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>`.

> **No automated apply path yet.** No per-solution workflow owns the glossary, so merging `data-plane/glossary/**` applies nothing on its own. **Interim apply path: run [`scripts/Deploy-Glossary.ps1`](../../../scripts/Deploy-Glossary.ps1) locally.** The monolithic `deploy-data-plane.yml` that once advertised matching `glossary_direction_policy` / `confirm_overwrite_glossary` / `skip_names_glossary` dispatch inputs was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled), so those inputs never applied anything. Nothing was lost. **Note that the `overwrite portal` typed-confirmation gate on `repo-wins` was a workflow pre-flight step, not a script parameter** — running the reconciler locally, `-DirectionPolicy repo-wins` is destructive with no typed-confirmation prompt, so preview with `-DirectionPolicy audit` first. Backfilling a `deploy-glossary.yml` (which restores that gate) is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## Phase 3+4 drift-review notes (PR #644)

The Phase 3+4 retrofit shipped: `-DirectionPolicy` / `-SkipNames` wired through the shared `scripts/modules/DirectionPolicy.psm1` module; `Invoke-GlossarySmokeTest.ps1` near-unattended wrapper; this runbook; and the Pester extension (7 new decision-matrix tests). The `-SkipNames` baseline ships empty — no permanent declared-orphan glossary terms exist in the tenant at the time of this retrofit.

The retrofit also shipped a `Validate glossary dispatch inputs` fail-fast gate and a `Deploy glossary` step in the monolithic data-plane workflow, driven by three dispatch inputs. **Both are gone**: that workflow was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md), having never once executed. The script-side `-DirectionPolicy` / `-SkipNames` contract above is unaffected and remains the live surface.

## References

- **[Atlas Glossary REST API](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary)**
  Fetch date: 2026-06-16
  > "The Microsoft Purview Data Catalog provides a business glossary feature to allow users to manage a glossary of terms."
- **[Understand business glossary features in Microsoft Purview](https://learn.microsoft.com/en-us/purview/concept-business-glossary)**
  Fetch date: 2026-06-16
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0026 — Glossary and custom classifications reconciler](../../adr/0026-glossary-custom-classifications-reconciler.md)
