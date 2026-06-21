# 0039 - IRM entity-list tracked fields and Set-InsiderRiskPolicyLite coverage decision
- **Status:** Accepted
- **Date:** 2026-06-16
- **Gates:** Closes issue #606 "IRM -- add reconciler coverage for `InsiderRiskEntityList` and `Set-InsiderRiskPolicyLite`" from the §5.9 follow-up queue. Governs the field surface and default `-SkipNames` baseline for [`scripts/Deploy-IRMEntityLists.ps1`](../../scripts/Deploy-IRMEntityLists.ps1) and the CI inputs shipped under this issue. Documents why `Set-InsiderRiskPolicyLite` is not covered by any current reconciler. Does not gate any other item.
- **Deciders:** @contoso

## Context

[#603](../../issues/603) (v2 §5.3 Insider Risk Management drift closure) established [`Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1) as the reconciler for `Get/New/Set/Remove-InsiderRiskPolicy`. The Phase 1 probe on 2026-06-14 also surfaced the full nine-cmdlet IRM surface (recorded in [ADR 0036](0036-irm-tenant-setting-immovable.md) §Context):

- `Get/New/Set/Remove-InsiderRiskPolicy` -- covered by `Deploy-IRMPolicies.ps1`.
- `Get/New/Set/Remove-InsiderRiskEntityList` -- **not yet covered** at the time of #603; deferred to #606 (this ADR).
- `Set-InsiderRiskPolicyLite` -- **not yet covered** at the time of #603; coverage decision deferred to #606 (this ADR).

The Phase 1 probe found that `contoso.onmicrosoft.com` carries one entity list (`IRM-Lab-Priority-Users`, type `UserType`) referenced by the `IRM Lab -- Data leaks by priority users` policy (scenario `HighValueEmployeeDataLeak`). That policy and its entity list are both under the #603 hard rule (no mutation during active testing).

### What entity lists are

Microsoft Purview Insider Risk Management entity lists are named, typed collections of users, groups, or sites used to scope IRM policies. An entity list of type `UserType` holds user principal names or user identifiers; `GroupType` holds distribution group or Microsoft 365 group identifiers; `SiteType` holds SharePoint or Microsoft Teams site URLs.

Reference: [Create and manage insider risk management priority user groups](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups).

### Entity-list cmdlet inventory as of 2026-06-14

All four entity-list cmdlets were confirmed live in the Phase 1 IPPS session under #603.

| Cmdlet | Learn page | Role in reconciler |
|---|---|---|
| `Get-InsiderRiskEntityList` | https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist | Enumerate tenant entity lists |
| `New-InsiderRiskEntityList` | https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist | Create declared list absent from tenant |
| `Set-InsiderRiskEntityList` | https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist | Update displayName / description / entities (full replace via `-Entities`) |
| `Remove-InsiderRiskEntityList` | https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist | Delete orphan lists under `-PruneMissing` |

### Tracked fields

The following fields are tracked by the entity-list reconciler:

| Field | YAML key | `New-` parameter | `Set-` parameter | Notes |
|---|---|---|---|---|
| Name | `name` | `-Name` | `-Identity` | Identifier; immutable after creation |
| Type | `type` | `-Type` | -- (not a `Set-` parameter) | `UserType` / `GroupType` / `SiteType`; immutable after creation; stored in desired hash for Create; not diffed for Update |
| Display name | `displayName` | `-DisplayName` | `-DisplayName` | Optional |
| Description | `description` | `-Description` | `-Description` | Optional |
| Members | `entities` | `-Entities` | `-Entities` (full replace) | Optional array; absent key means "do not manage"; empty array `[]` means desired-empty; comparison is order-insensitive (sorted, case-insensitive) |

`Type` is immutable after creation (analogous to `InsiderRiskScenario` on policies). The reconciler passes `-Type` to `New-InsiderRiskEntityList` and stores it in the desired-state hash, but does **not** include it in the diff comparison for existing lists. If a type change is needed, the operator must delete the entity list and recreate it.

### Set-InsiderRiskPolicyLite

The Phase 1 probe confirmed `Set-InsiderRiskPolicyLite` exists in the tenant. Microsoft Learn documents it at [Set-InsiderRiskPolicyLite (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicylite). The cmdlet accepts `-Identity` plus a subset of the parameters also accepted by `Set-InsiderRiskPolicy` (including `-Enabled`, `-Comment`, and priority-related fields).

`Deploy-IRMPolicies.ps1` already achieves full desired-state convergence for IRM policies using `Set-InsiderRiskPolicy`. Adding a second write path via `Set-InsiderRiskPolicyLite` for the same objects would:

1. Create a dual-write surface with no additional reconciler capability -- every field settable via `Set-InsiderRiskPolicyLite` is already settable via `Set-InsiderRiskPolicy`.
2. Risk silent state divergence if both paths are active in the same CI run.
3. Introduce ambiguity about which cmdlet is authoritative for a given run.

## Decision

### Entity lists

**We will ship a new `Deploy-IRMEntityLists.ps1` reconciler with the tracked fields defined above.** The reconciler follows the same contract as `Deploy-IRMPolicies.ps1`: ADR 0029 `-DirectionPolicy` / `-SkipNames`, Key Vault cert auth, `[ADR0029-SKIP]` / `[ADR0029-AUDIT]` markers, JSON Schema Draft-07 validation, and `ShouldProcess` throughout.

1. **Desired-state YAML ships empty** (`entityLists: []`). The live `IRM-Lab-Priority-Users` entity list is under the #603 hard rule (no mutation during active testing). It is added to the `-SkipNames` CI baseline under this ADR, matching the approach taken for the four `IRM Lab -- *` policies in ADR 0036.

2. **Type is stored but not diffed.** The `type` field is required in YAML for `New-InsiderRiskEntityList` splat construction. It is captured in both the desired hash and the tenant hash but is excluded from `Compare-EntityList`. If a type change is needed, the operator must delete and recreate the list outside this reconciler.

3. **Entities comparison is order-insensitive.** The reconciler normalizes both desired and tenant `entities` arrays to lowercase, sorted order before comparing, so diff noise from reordering does not produce false `Update` rows.

4. **`entities` absent in YAML means "do not manage".** If the `entities` key is omitted in a YAML entry, the reconciler does not diff or overwrite the tenant membership. If the key is present as an empty array (`entities: []`), the desired state is an empty list and any tenant membership is drift.

5. **The CI baseline skip list contains `IRM-Lab-Priority-Users`.** This name is added to the `skip_names_irm_entity_list` workflow dispatch default. It must not be removed without a follow-up ADR. When the #603 testing window closes and the entity list is adopted into desired state, remove it from the default.

6. **No undocumented surface.** The reconciler will not invoke undocumented parameters on `Set-InsiderRiskEntityList` or `Remove-InsiderRiskEntityList`. This restriction is identical to [ADR 0019](0019-cc-graph-pivot.md) §6, [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6, [ADR 0027](0027-autoapplication-removal-watch-list.md) §5, [ADR 0035](0035-records-seed-content-immovable.md) §6, and [ADR 0036](0036-irm-tenant-setting-immovable.md) §6.

### Set-InsiderRiskPolicyLite

**We will not cover `Set-InsiderRiskPolicyLite` in any current reconciler.** `Deploy-IRMPolicies.ps1` achieves full desired-state convergence for IRM policies via `Set-InsiderRiskPolicy`; there is no gap that `Set-InsiderRiskPolicyLite` fills for a declarative reconciler.

This decision is documented as a watch-list item (same shape as [ADR 0019](0019-cc-graph-pivot.md) §6, [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6, [ADR 0027](0027-autoapplication-removal-watch-list.md) §5, [ADR 0035](0035-records-seed-content-immovable.md) §6, and [ADR 0036](0036-irm-tenant-setting-immovable.md) §6). This ADR is to be re-opened if any of the following becomes true on Microsoft Learn:

- The [`Set-InsiderRiskPolicyLite`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicylite) reference page documents a parameter or capability not available on `Set-InsiderRiskPolicy` that is relevant to desired-state reconciliation.
- A Microsoft-published reference repo ships a sample demonstrating `Set-InsiderRiskPolicyLite` achieving a reconciliation outcome not reachable via `Set-InsiderRiskPolicy`.

## Consequences

**Easier:**

- **[#606](../../issues/606) closes** with a new `Deploy-IRMEntityLists.ps1` reconciler, a YAML schema, CI wiring, and Pester tests -- all following the established patterns.
- **The `IRM-Lab-Priority-Users` entity list is protected** by the skip baseline exactly as the four `IRM Lab -- *` policies are protected under ADR 0036.
- **`Set-InsiderRiskPolicyLite` is explicitly documented** as a watch-list item, removing ambiguity about whether the reconciler is incomplete.
- **Symmetry with the rest of the repo.** The entity-list reconciler follows the same ADR 0029 pattern as `Deploy-IRMPolicies.ps1`, `Set-AuditRetentionPolicy.ps1`, `Deploy-Collections.ps1`, and the other ADR 0029 retrofits.

**Harder:**

- **Type-drift edge case requires manual intervention.** If an entity list's type changes out of band in the portal, the reconciler cannot converge it automatically. The operator must delete and recreate the list.
- **Entity-list desired state is empty by default.** Like `policies.yaml`, the shipped `entity-lists.yaml` is empty until the testing window closes and follow-up work adopts the live `IRM-Lab-Priority-Users` list into desired state.

## References

- **[Create and manage insider risk management priority user groups](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups)**
  Fetch date: 2026-06-16
  > "You can create priority user groups to define which users in your organization need closer inspection and risk scoring in insider risk policies."
- **[Get-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist)**
  Fetch date: 2026-06-16
- **[New-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist)**
  Fetch date: 2026-06-16
- **[Set-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist)**
  Fetch date: 2026-06-16
- **[Remove-InsiderRiskEntityList (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist)**
  Fetch date: 2026-06-16
- **[Set-InsiderRiskPolicyLite (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicylite)**
  Fetch date: 2026-06-16
