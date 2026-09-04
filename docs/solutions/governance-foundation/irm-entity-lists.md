# Insider Risk Management - entity lists (PARKED SURFACE)

> **This surface is parked. There is nothing to operate.**
> `data-plane/irm/entity-lists.yaml` stays empty permanently, [`scripts/Deploy-IRMEntityLists.ps1`](../../../scripts/Deploy-IRMEntityLists.ps1) is parked and driven by no workflow, and IRM exclusions and priority user groups stay portal-managed. Ratified in [ADR 0064](../../adr/0064-irm-entity-lists-are-microsoft-managed.md), which supersedes [ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md).
>
> This page is retained as the record of why. For the IRM surface that **is** managed as code, see [`insider-risk-management.md`](insider-risk-management.md) (policies).

## What happened

[ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md) (2026-06-16) modelled entity lists as operator-authored desired state: named, typed collections of users, groups, or sites, with a `type` of `UserType` / `GroupType` / `SiteType` and a tracked `entities` membership array. A reconciler shipped against that model with 66 unit tests.

The model was never run against a live tenant. Its unit tests feed stubbed rows straight to the helper functions, and no workflow drove it, so the enumerate path never executed. On 2026-09-03 the backfilled forward-apply workflow ran for the first time, failed at its read step, and two read-only probes established the following on the lab tenant.

| # | Finding |
|---|---|
| 1 | `Get-InsiderRiskEntityList` **rejects a bare call** — `Either Identity or Type should be provided as parameter`. The reconciler calls it bare, so its read phase had never once run. |
| 2 | The `type` enum is **fictional**. `UserType` / `GroupType` / `SiteType` are not members of the live `IrmEntityListType` enum, which has 23 entirely different values. `New-InsiderRiskEntityList -Type` takes the same enum, so Create could never have worked either. |
| 3 | `-IncludeEntities` is **declared by the cmdlet but rejected by the service** as not implemented. |
| 4 | **`.Entities` is empty on every list** — via per-type enumeration and via a single-object `-Identity` fetch. Membership cannot be read, so it cannot be converged. This is the decisive finding. |
| 5 | `.Type` is the constant `InsiderRiskEntityList`; the real discriminator is `.ListType`. |
| 6 | `IRM-Lab-Priority-Users` — the name ADR 0039 pinned into the CI skip baseline — **does not exist** on the tenant. The 2026-06-14 record was portal-read, not cmdlet-read. |
| 7 | All 32 lists on lab are **Microsoft-provisioned configuration containers**. |

Full evidence ladder, with error strings and the run id, is in [ADR 0064](../../adr/0064-irm-entity-lists-are-microsoft-managed.md) §Context.

## What the cmdlets actually manage

Not priority user groups. The `*-InsiderRiskEntityList` family manages the containers behind the Insider Risk Management **settings** pages — global exclusions, excluded domains and sites, excluded printers and applications, indicator policy bindings, DSPM sensitive types, connected AI apps. Lab holds 32 of them across 13 of the 23 list types, every name Microsoft-assigned:

| Type | Count | Examples |
|---|---|---|
| `GlobalExclusionSGMapping` | 10 | `IrmXSGDomains`, `IrmXSGPrinters`, `IrmXSGApplications` |
| `DomainLists` | 4 | `IrmWhitelistDomains`, `IrmBlacklistDomains`, `IrmEnterpriseDomains`, `IrmPublicDomains` |
| `SensitiveTypeLists` | 4 | `IrmCustomExSensitiveTypes`, `IrmDsbldSysExMLClassifiers` |
| `WindowsFilePathRegexLists`, `KeywordLists`, `PrinterLists`, `P4AIAppLists` | 2 each | `IrmExcludedPrinters`, `IrmExcludedKeywords`, `PurviewCopilots` |
| `CriticalAssetLists`, `SiteLists`, `ApplicationLists`, `DlpPolicyLists`, `CcPolicyLists`, `DspmSensitiveTypeLists` | 1 each | `IrmExcludedSites`, `IrmExcludedApplications`, `IrmDlpIndicatorPolicies` |
| the other 10 types | 0 | — |

This is the same class of object as the `IRM_Tenant_Setting_<tenant-guid>` policy that [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) ratified as permanently system-managed — reached through a different cmdlet family.

## Operating guidance

- **Do not populate `data-plane/irm/entity-lists.yaml`.** An export would capture 32 Microsoft containers as if they were desired state.
- **Do not run `Deploy-IRMEntityLists.ps1`.** It is parked. Its read phase cannot succeed, and its Create path targets an enum that does not exist.
- **Do not enable `-PruneMissing` against this surface.** Every container would classify as an orphan. The prune guards do hold — an empty desired set trips guard 1, and 31-of-32 trips the ratio guard — but that is a backstop, not a plan.
- **Manage IRM exclusions and priority user groups in the portal.** See [Insider Risk Management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings).
- **The schema is retained** only so the empty document validates. Its `type` enum is the fictional ADR 0039 one; do not author against it.

## If this ever becomes buildable

[ADR 0064](../../adr/0064-irm-entity-lists-are-microsoft-managed.md) carries the re-open triggers. The load-bearing one is finding 4: if `Get-InsiderRiskEntityList` ever returns populated `Entities`, or implements `-IncludeEntities`, membership becomes readable and the surface becomes reconcilable. Un-parking starts with a new ADR, not with an edit to the YAML or the script.

Whoever picks that up inherits two known repairs: the bare enumerate call needs to become a per-type loop over the real 23-value enum, and `ConvertTo-TenantEntityListHash` needs to read `.ListType` rather than `.Type`.

## The durable lesson

ADR 0039's model was assembled from four documented cmdlet names, a Microsoft Learn concept page, and one portal observation. Every one of those inputs was true, and the model built on them was wrong. Cmdlet existence is not capability; a documented concept is not a documented API; a portal object is not a cmdlet-visible object; and — finding 3 — a declared parameter is not an implemented one.

The repository already required a live `Get-Command -Syntax` probe before trusting Learn docs. That was not enough here: the syntax block advertised `-IncludeEntities` and made every parameter look optional. **A field is not modellable until a live call has been observed returning it.**

## Related

- [ADR 0064](../../adr/0064-irm-entity-lists-are-microsoft-managed.md) — parks this surface (supersedes ADR 0039)
- [ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md) — the superseded model
- [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) — the same disposition for the policy-family analogue
- [`insider-risk-management.md`](insider-risk-management.md) — IRM policies, the surface that **is** managed as code
- [Insider Risk Management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings)
