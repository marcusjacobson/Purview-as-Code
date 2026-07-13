# Purview Data Map — Collections

Operational guide for [`scripts/Deploy-Collections.ps1`](../../../scripts/Deploy-Collections.ps1) — the reconciler that materializes [`data-plane/collections/collections.yaml`](../../../data-plane/collections/collections.yaml) against the [Microsoft Purview Data Map collection hierarchy](https://learn.microsoft.com/en-us/purview/concept-best-practices-collections). Pairs with [`audit-log.md`](../governance-foundation/audit-log.md) (collection writes are emitted to the same Unified Audit Log).

## Purpose

Reconciles the [Account Data Plane — Collections](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections) REST surface against a declared collection hierarchy. Emits Create / Update / NoChange / Orphan / Protected / Skip / Removed / Failed decisions per collection. Orphan collections (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline or `protected:` allow-list.

The Collections model is documented at [Collections architecture and best practices](https://learn.microsoft.com/en-us/purview/concept-best-practices-collections):

- Each collection carries a `name` (immutable URL segment), `friendlyName`, `description`, and `parentCollection.referenceName`.
- The root collection shares the Purview account name and is managed by Azure — the reconciler never PUTs or DELETEs it.
- Name validity rule for human-input names is `^[a-z][a-z0-9-]{2,35}$` per [Quickstart: create a collection](https://learn.microsoft.com/en-us/purview/quickstart-create-collection). The portal's create flow auto-generates short URL segments (e.g. `85cv3o`, `1lfhuf`) that fail this rule yet are accepted by the REST surface; the reconciler carves out existing tenant names from the pre-flight check (PR #613).

## Default state

The shipped YAML is the live tenant hierarchy imported in PR #613 (24 non-root collections — `enterprise` + 3 children, `sandbox`, plus the 19-entry `c8iacz` Non-Prod hierarchy and the two top-level `1lfhuf` HR / `9vsaza` Finance entries). `-WhatIf` returns `Plan: 24 NoChange`.

## Authentication

Pure Purview data-plane REST — no Security & Compliance PowerShell, no Key Vault cert path required for the script itself. The script delegates token acquisition to [`scripts/Connect-Purview.ps1`](../../../scripts/Connect-Purview.ps1), which uses the Azure CLI token cache (`az account get-access-token --resource https://purview.azure.net`). In CI the `azure/login@v2` OIDC step (per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)) provides the underlying federated identity.

## Inputs

| Parameter | Default source |
|---|---|
| `-Path` | `data-plane/collections/collections.yaml` |
| `-ParametersFile` | `infra/parameters/lab.yaml` |
| `-PurviewAccountName` / `-AccountName` | `purviewAccountName:` in the parameters file |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant collections. Names on `-SkipNames` or `protected:` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-ExportCurrentState` | switch — round-trip the live tenant back into the YAML (mutually exclusive with `-PruneMissing`) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `List Collections`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No PUT or DELETE writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads `List Collections`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Protected / Skip / Removed rows. No writes. |
| (default) | Same read, then per-row PUT (Create / Update) or DELETE (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_collections='overwrite portal'` token. |

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Collection Admin` | Root collection of the target Purview account |
| Caller's identity in Azure | Active `az login` session | Subscription containing the Purview account |

Reference: [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

## Smoke test

```pwsh
# Audit mode — read-only view of the live tenant vs YAML.
./scripts/Deploy-Collections.ps1 -DirectionPolicy audit
```

Expected output tail when YAML matches the live tenant:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
...
Plan: 24 NoChange
```

For a near-unattended end-to-end smoke that exercises Create → Read → Update → Delete against a throwaway collection, see [`docs/runbooks/collections-end-to-end-smoke.md`](../../runbooks/collections-end-to-end-smoke.md) and the [`scripts/Invoke-CollectionsSmokeTest.ps1`](../../../scripts/Invoke-CollectionsSmokeTest.ps1) wrapper.

## ADR 0029 contract

This reconciler conforms to [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md). The script accepts `-DirectionPolicy {audit, portal-wins, repo-wins}` and `-SkipNames <string[]>`.

> **No automated apply path yet.** No per-solution workflow owns collections, so merging `data-plane/collections/**` applies nothing on its own. **Interim apply path: run [`scripts/Deploy-Collections.ps1`](../../../scripts/Deploy-Collections.ps1) locally.** The monolithic `deploy-data-plane.yml` that once advertised matching `collections_direction_policy` / `confirm_overwrite_collections` / `skip_names_collections` dispatch inputs was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled), so those inputs never applied anything. Nothing was lost. **Note that the `overwrite portal` typed-confirmation gate on `repo-wins` was a workflow pre-flight step, not a script parameter** — running the reconciler locally, `-DirectionPolicy repo-wins` is destructive with no typed-confirmation prompt, so preview with `-DirectionPolicy audit` first. Backfilling a `deploy-collections.yml` (which restores that gate) is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## Phase 1 drift-review evidence (PR #613)

Live tenant on 2026-06-14 carried 24 non-root collections — 5 already declared in the repo YAML (`enterprise` + 3 children, `sandbox`) and 19 portal-authored entries. Phase 2 closed via path (a) update YAML + re-apply: imported the 19 entries; round-trip `-WhatIf` returns 24 NoChange. Two reconciler bugs surfaced and fixed in the same PR:

- `Get-CollectionNameViolation` rejected portal-authored short URL segments that fail the human-input name rule; carved out via `-KnownNames` so the rule still guards new YAML entries.
- `ConvertTo-TenantCollectionHash` returned `parent = $null` for collections whose REST response carries no `parentCollection` property; normalizer now coerces missing / root-matching parents to the account name when `-RootName` is supplied.

## References

- **[Account Data Plane — Collections — List Collections](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/list-collections)**
  Fetch date: 2026-06-14
- **[Collections architecture and best practices](https://learn.microsoft.com/en-us/purview/concept-best-practices-collections)**
  Fetch date: 2026-06-14
- **[Quickstart: create a collection](https://learn.microsoft.com/en-us/purview/quickstart-create-collection)**
  Fetch date: 2026-06-14
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
