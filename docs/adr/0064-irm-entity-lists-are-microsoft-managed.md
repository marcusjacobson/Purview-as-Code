# 0064 — IRM entity lists are Microsoft-managed tenant configuration: park the reconciler, never populate the desired state

- **Status:** Accepted <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-09-03
- **Gates:** Supersedes [ADR 0039](0039-irm-entity-list-tracked-fields.md) in full. Governs `data-plane/irm/entity-lists.yaml` (permanently empty), the parked status of [`scripts/Deploy-IRMEntityLists.ps1`](../../scripts/Deploy-IRMEntityLists.ps1), and the removal of `.github/workflows/deploy-irm-entity-lists.yml`. Retires the ADR 0039 skip-baseline name `IRM-Lab-Priority-Users`, which ADR 0039 Decision #5 required a follow-up ADR to remove. Carries forward ADR 0039's `Set-InsiderRiskPolicyLite` watch-list unchanged. Part of the seventh per-feature convergence pass ([#177](../../issues/177)). Does not gate any other item.
- **Deciders:** @contoso

## Context

[ADR 0039](0039-irm-entity-list-tracked-fields.md) (2026-06-16) modelled Microsoft Purview Insider Risk Management entity lists as operator-authorable desired state: named, typed collections of users, groups, or sites, with a `type` field constrained to `UserType | GroupType | SiteType`, a tracked `entities` membership array, and a reconciler (`Deploy-IRMEntityLists.ps1`) following the full ADR 0029 contract. It was grounded on a 2026-06-14 Phase 1 probe that recorded one live entity list, `IRM-Lab-Priority-Users` of type `UserType`, backing the `IRM Lab — Data leaks by priority users` policy.

That model was never executed against a live tenant. The reconciler shipped with unit tests that feed stubbed rows directly to its helper functions, and no workflow drove it, so its enumerate path never ran. The `-ExportCurrentState` retrofit added under [#177](../../issues/177) inherited the same untested path.

On 2026-09-03 the backfilled forward-apply workflow ran for the first time and failed at its read step. Two owner-run read-only probes then established the following, all against the lab tenant.

### Finding 1 — the cmdlet cannot enumerate

`Get-InsiderRiskEntityList` with no parameters is rejected by the service:

```
|Microsoft.Exchange.Management.UnifiedPolicy.ErrorIrmEntityListInvalidGetParametersException|
Either Identity or Type should be provided as parameter.
```

`Deploy-IRMEntityLists.ps1` calls it bare, exactly as `Deploy-IRMPolicies.ps1` calls `Get-InsiderRiskPolicy`. The two cmdlets are not symmetric: the policy cmdlet enumerates, the entity-list cmdlet refuses. Evidence: `deploy-irm-entity-lists` run [33757744245](../../actions/runs/33757744245) on `dev`, step "Enumerate skipped objects (portal-wins read-only pass)".

Note the cmdlet's own declared surface does not express this. `Get-Command -Syntax` reports a single parameter set with **every** parameter optional:

```
Get-InsiderRiskEntityList [[-Identity] <Object>] [-IncludeDeleted] [-IncludeEntities] [-Type <Object>] [<CommonParameters>]
```

The one-of-two requirement is enforced server-side only.

### Finding 2 — the `type` enum in ADR 0039 does not exist

`-Type UserType` fails argument transformation. The live `IrmEntityListType` enum has 23 values, and none of ADR 0039's three are among them:

```
Unable to match the identifier name UserType to a valid enumerator name.
Specify one of the following enumerator names and try again:
HveLists, DomainLists, CriticalAssetLists, WindowsFilePathRegexLists,
SensitiveTypeLists, SiteLists, KeywordLists, CustomDomainLists, CustomSiteLists,
CustomKeywordLists, CustomFileTypeLists, CustomFilePathRegexLists,
CustomSensitiveInformationTypeLists, CustomMLClassifierTypeLists,
GlobalExclusionSGMapping, DlpPolicyLists, CcPolicyLists, ApplicationLists,
CustomApplicationLists, PrinterLists, CustomPrinterLists,
DspmSensitiveTypeLists, P4AIAppLists
```

`GroupType` and `SiteType` fail identically. Because `New-InsiderRiskEntityList -Type` takes the same enum, the reconciler's Create path could never have succeeded either. This is the same defect class as the `RecipientTypeDetails -eq 'Group'` filter corrected under [#57/#58](../../issues/57) — a value asserted from documentation prose that the live enum does not define.

### Finding 3 — `-IncludeEntities` is declared but not implemented

Passing the switch the cmdlet advertises throws:

```
|Microsoft.Exchange.Management.UnifiedPolicy.ErrorEntityListParameterNotImplementedException|
This parameter IncludeEntities is not supported.
```

A declared-but-unimplemented parameter. `Get-Command -Syntax` is therefore necessary but not sufficient evidence that a parameter can be used.

### Finding 4 — membership is not readable at all

`.Entities` is empty on every one of the 32 lists on lab, through per-type enumeration **and** through a single-object `-Identity` fetch. Rows carry a separate `EntitiesCount` property, also 0. With `-IncludeEntities` rejected (finding 3), there is no documented path that returns membership.

This is the finding that decides the disposition. A reconciler that cannot read a field cannot converge it, so `entities` — the only field on this surface that carries operator intent — is not reconcilable. The model is unbuildable, not merely mis-typed.

### Finding 5 — the `type` property is not the list type

Every returned row reports `Type = 'InsiderRiskEntityList'`, a constant naming the object class. The list-type discriminator is a separate `ListType` property. `ConvertTo-TenantEntityListHash` reads `.Type`, so it would have mapped the same constant onto every row regardless of the enum problem in finding 2.

### Finding 6 — the ADR 0039 baseline names an object that is not there

`IRM-Lab-Priority-Users` does not exist on the lab tenant, and `HveLists` — the list type whose name corresponds to the high-value-employee / priority-user concept ADR 0039 cited — is empty. The 2026-06-14 record was, on the evidence, read from the Microsoft Purview portal rather than from these cmdlets. ADR 0039 Decision #5 pinned that name into the CI skip baseline and required a follow-up ADR to remove it; this ADR is that follow-up.

### Finding 7 — what the surface actually holds

Lab carries 32 lists across 13 of the 23 types. Every name is Microsoft-provisioned:

| Type | Count | Names |
|---|---|---|
| `DomainLists` | 4 | `IrmWhitelistDomains`, `IrmBlacklistDomains`, `IrmEnterpriseDomains`, `IrmPublicDomains` |
| `GlobalExclusionSGMapping` | 10 | `IrmXSGDomains`, `IrmXSGSites`, `IrmXSGExcludedKeywords`, `IrmXSGExceptionKeywords`, `IrmXSGFiletypes`, `IrmXSGFilePaths`, `IrmXSGSensitiveInfoTypes`, `IrmXSGMLClassifierTypes`, `IrmXSGApplications`, `IrmXSGPrinters` |
| `SensitiveTypeLists` | 4 | `IrmCustomExMLClassifiers`, `IrmDsbldSysExMLClassifiers`, `IrmCustomExSensitiveTypes`, `IrmDsbldSysExSensitiveTypes` |
| `WindowsFilePathRegexLists` | 2 | `IrmCustomExWinFilePaths`, `IrmDsbldSysExWinFilePaths` |
| `KeywordLists` | 2 | `IrmExcludedKeywords`, `IrmNotExcludedKeywords` |
| `PrinterLists` | 2 | `IrmDsbldSysExPrinters`, `IrmExcludedPrinters` |
| `P4AIAppLists` | 2 | `PurviewCopilots`, `PurviewConnectedAIApps` |
| `CriticalAssetLists` | 1 | `IrmPhysicalBadgeAssets` |
| `SiteLists` | 1 | `IrmExcludedSites` |
| `ApplicationLists` | 1 | `IrmExcludedApplications` |
| `DlpPolicyLists` | 1 | `IrmDlpIndicatorPolicies` |
| `CcPolicyLists` | 1 | `IrmCcIndicatorPolicies` |
| `DspmSensitiveTypeLists` | 1 | `DspmSensitiveTypes` |
| the other 10 types | 0 | — |

These are the containers behind the Insider Risk Management **settings** pages — global exclusions, excluded domains and sites, excluded printers and applications, indicator policy bindings, DSPM sensitive types, connected AI apps. None is an operator-authored object; the naming (`Irm*`, `Dspm*`, `Purview*`) and the presence of an `IsSystemDefined` property on every row both point the same way. The exact value of `IsSystemDefined` was not captured by the probes and is recorded here as unverified; it does not change the disposition, because findings 2 and 4 are independently decisive.

The surface is therefore the direct analogue of the `IRM_Tenant_Setting_<tenant-guid>` policy ratified as permanently system-managed in [ADR 0036](0036-irm-tenant-setting-immovable.md) — the same shape of object, reached through a different cmdlet family.

### The dev tenant

Dev is not inventoried. The first dev probe passed `-IncludeEntities` on every call and so queried nothing (finding 3). A corrected read-only inventory is the opening step of the [#177](../../issues/177) discovery phase. The disposition below does not depend on it: findings 1–5 are properties of the cmdlet surface, not of a tenant's contents.

### Why ADR 0039's watch list did not catch this

ADR 0039 carried re-open triggers, but they scoped only the `Set-InsiderRiskPolicyLite` coverage decision. Nothing in that ADR anticipated its own entity-list field model being wrong, because the model read as settled: four documented cmdlets, a Learn page describing priority user groups, and a portal-observed example. No trigger fired here. The lesson is recorded in Consequences.

## Decision

**1. IRM entity lists are Microsoft-managed tenant configuration, not operator desired state.** `data-plane/irm/entity-lists.yaml` remains `entityLists: []` permanently. It is not populated from a tenant export and no operator entry is added to it. This mirrors [ADR 0036](0036-irm-tenant-setting-immovable.md)'s treatment of the tenant-setting policy.

**2. `Deploy-IRMEntityLists.ps1` is PARKED, and retained on disk.** Its comment header and `.SYNOPSIS` carry a `PARKED (ADR 0064)` marker naming this ADR and the reason. Its logic is left unchanged.

Retained rather than deleted for three reasons. It is the honest record of an attempted model, in a repository whose ADR trail is deliberately append-only. Its helper functions and their 66 unit tests remain a correct, self-consistent body of work that documents the shape a working entity-list reconciler would need. And it is the reference implementation for several AST-derived contract suites — the ADR 0052 gate class map, the [#13](../../issues/13) prune-guard rollout tables, the `validate.yml` full-circle exempt list — which assert over the reconciler set as discovered from disk; deleting the script would require reversing count pins in four suites for no behavioural gain. Precedent: [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) Decision #1 retained ADR 0037's placeholder reconciler and its five concept YAMLs when it superseded that ADR.

**3. `.github/workflows/deploy-irm-entity-lists.yml` is removed.** Backfilled under [#177](../../issues/177), its only run failed at finding 1, and it can never succeed while the read path is broken. A workflow that cannot run green is worse than no workflow: it trains reviewers to ignore a red check. Removal reverses the four contract-table rows it required.

**4. The `IRM-Lab-Priority-Users` skip baseline is retired.** The name does not exist on the tenant (finding 6). It is removed from `data-plane/irm/entity-lists.yaml`'s header. No workflow default carries it any more, because Decision #3 removes the only workflow that did.

**5. `Set-InsiderRiskPolicyLite` remains uncovered, on ADR 0039's terms.** Nothing found here bears on it. ADR 0039's reasoning (a dual-write surface with no capability `Set-InsiderRiskPolicy` lacks) and its two re-open triggers are carried forward verbatim and now belong to this ADR.

**6. No undocumented surface.** We will not reverse-engineer the portal's REST traffic to read or write entity-list membership, and we will not invoke undocumented parameters on the `*-InsiderRiskEntityList` cmdlets. Identical to [ADR 0019](0019-cc-graph-pivot.md) §6, [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6, [ADR 0027](0027-autoapplication-removal-watch-list.md) §5, [ADR 0035](0035-records-seed-content-immovable.md) §6 and [ADR 0036](0036-irm-tenant-setting-immovable.md) §6.

### Re-open triggers (the watch list)

Re-open with a follow-up ADR if any of the following becomes true:

- [`Get-InsiderRiskEntityList`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist) returns populated `Entities`, or implements `-IncludeEntities`, or its reference page documents any other read path for membership. This reverses finding 4, the decisive one.
- [`New-InsiderRiskEntityList`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist) documents a user-, group-, or site-scoped list type that an operator is expected to create — that is, the `IrmEntityListType` enum gains a member outside Microsoft's own configuration containers.
- [Create and manage insider risk management priority user groups](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups) gains a PowerShell, Microsoft Graph, or REST section for managing priority user groups programmatically.
- An `insiderRiskEntityList`-shaped resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` with read or write coverage for membership.
- A Microsoft-published reference repo (`github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a sample managing priority user groups or any operator-authored entity list through these cmdlets.

Plus the two `Set-InsiderRiskPolicyLite` triggers carried forward from ADR 0039 Decision §Set-InsiderRiskPolicyLite.

## Consequences

**Easier:**

- **The IRM convergence pass ([#177](../../issues/177)) proceeds on policies alone**, which are a separate cmdlet family, unaffected by every finding here, and already export-capable and drift-back-wired.
- **No permanently red check.** Removing the workflow removes the only IRM check that cannot pass.
- **The desired-state file is honest.** Its header now describes what the tenant actually holds and says not to populate it, instead of instructing an operator to run an export that would capture 32 Microsoft containers.
- **The contract suites stay untouched.** Parking rather than deleting keeps the reconciler in the discovered set, so the ADR 0052, prune-guard and full-circle tables need no count edits.

**Harder:**

- **No as-code management of IRM exclusions.** Global exclusions, excluded domains, sites, printers and applications stay portal-managed. This is a real capability gap, and it is Microsoft's, not the repo's: the read path required to converge them does not exist.
- **A parked script invites confusion.** Mitigated by the marker in the header and `.SYNOPSIS` (so the machine-generated [`docs/scripts-reference.md`](../scripts-reference.md) shows it), a parked-surface solution page, and a source test asserting the marker is present.
- **`Deploy-IRMEntityLists.ps1` keeps a broken enumerate call.** Deliberately: it is parked, nothing invokes it, and "fix the read path" is not achievable (finding 1's fix is a per-type loop, which finding 4 then makes pointless). A future un-parking ADR owns that repair.
- **The upstream template carries the same wrong ADR 0039 and the same reconciler.** It must be told; the [#177](../../issues/177) close-out notes this delta for the next `@upstream-handoff` cycle.

**The durable lesson.** ADR 0039's model was assembled from four documented cmdlet names, a Learn concept page, and one portal observation — and every one of those was true while the model built on them was wrong. Cmdlet existence is not capability; a documented concept is not a documented API; a portal object is not a cmdlet-visible object; and a declared parameter is not an implemented one. The repository already required a live `Get-Command -Syntax` probe before trusting Learn docs; finding 3 shows that is insufficient. **A field is not modellable until a live call has been observed returning it.** Two prior passes reached the same conclusion from the write side ([#92/#93](../../issues/93) label `Name` vs `DisplayName`, [#160](../../issues/160) `Set-DlpComplianceRule`); this is the first time it has bitten the read side.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Upheld. Every list name recorded above is a Microsoft-assigned constant carrying no tenant identifier; no GUID, UPN, domain, or site URL appears in this ADR. The ADR 0055 identifier scan passes with zero unclaimed identifiers.
- **#4 (least privilege).** Upheld. This ADR removes a workflow and adds no permission.
- **#9 (idempotent, reversible, auditable).** Upheld. The reconciler and schema are retained, so un-parking is a header edit plus a new ADR; the removed workflow is recoverable from history.

## Alternatives considered

**Delete the surface entirely** — reconciler, schema, YAML, tests, console panel and solution-map rows. Rejected. It is the largest blast radius of the three options: the ADR 0052 class map, the prune-guard rollout tables and the full-circle exempt list all pin counts over the discovered reconciler set, so four suites would need count reversals to buy nothing behavioural. The repository has no precedent for deleting a reconciler, and its ADR trail is deliberately append-only. Parking preserves the decision record at a fraction of the churn.

**Fix the model forward** against the real `ListType` discriminator and the 23-value enum. Rejected. Finding 4 is not a modelling error to correct: with membership unreadable, the reconciler would compare `displayName` and `description` on 32 Microsoft-owned containers and converge nothing an operator authored. It would also make `-PruneMissing` genuinely dangerous, since every container would classify as an orphan. (The existing guards do hold — an empty desired set trips guard 1, and 31-of-32 trips the ratio guard — but a reconciler whose correct behaviour depends on its safety guards firing is the wrong design.) Worth revisiting only if the first re-open trigger fires.

**Leave the workflow in place, red.** Rejected. A check that can never pass erodes the signal value of every other check.

## References

- **[Get-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist)**
  Fetch date: 2026-09-03. The reference page documents `-Identity`, `-Type`, `-IncludeDeleted` and `-IncludeEntities` without recording that one of `-Identity`/`-Type` is required (finding 1), that `-IncludeEntities` is unimplemented (finding 3), or which values `-Type` accepts (finding 2).
- **[New-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist)**
  Fetch date: 2026-09-03.
- **[Set-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist)**
  Fetch date: 2026-09-03.
- **[Remove-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist)**
  Fetch date: 2026-09-03.
- **[Create and manage insider risk management priority user groups](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups)**
  Fetch date: 2026-09-03. Describes priority user groups as a portal concept; documents no programmatic management surface, which is consistent with findings 2 and 6.
- **[Insider Risk Management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings)**
  Fetch date: 2026-09-03. The settings surface whose containers finding 7 enumerates.
- **[Set-InsiderRiskPolicyLite (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicylite)**
  Fetch date: 2026-09-03. Carried forward from ADR 0039 for Decision #5.
- [ADR 0039 — IRM entity-list tracked fields and Set-InsiderRiskPolicyLite coverage decision](0039-irm-entity-list-tracked-fields.md) — the ADR this one supersedes.
- [ADR 0036 — IRM tenant-setting policy is system-managed and immovable](0036-irm-tenant-setting-immovable.md) — the same disposition for the policy-family analogue.
- [ADR 0029 — Source-of-truth direction policy](0029-source-of-truth-direction-policy.md) — the contract the parked reconciler still implements.
- [ADR 0047 — Unified Catalog preview REST API coexistence](0047-unified-catalog-preview-api-coexistence.md) — the retain-don't-delete precedent followed by Decision #2.
- [ADR 0056 — The template ships empty desired state](0056-template-ships-empty-desired-state.md) — why an empty `entity-lists.yaml` is the normal shipped state.
