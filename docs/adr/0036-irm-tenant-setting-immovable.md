# 0036 — IRM tenant-setting policy is system-managed and immovable via documented IPPS surfaces; treat as permanent declared orphan

- **Status:** Accepted
- **Date:** 2026-06-14
- **Gates:** Adds open-question row Q16 in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs. Resolves Phase 2 disposition #2 in [#603](../../issues/603) for the `IRM_Tenant_Setting_*` policy class. Governs the default `-SkipNames` baseline for [`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1) and the workflow input shipped under [#603](../../issues/603). Does not gate any other item.
- **Deciders:** @contoso

> **Update — 2026-07-12:** The real tenant-scoped GUID suffix of the
> system-managed policy name has been **redacted** from every artifact in
> this repository and replaced with the `<tenant-guid>` placeholder. A
> tenant-scoped GUID is a real tenant identifier prohibited by the
> "Environment and identifier boundaries" section of
> [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md)
> (the reviewer grep rejects any non-zero GUID); that rule takes
> precedence over §Security #1 below, which had ratified the GUID as
> acceptable-in-source. §Security #1 is revised accordingly.
>
> In the same change the system-managed name was **dropped from the skip
> baseline** (the workflow `skip_names_irm` defaults, the YAML header, the
> smoke-test baseline, and the source-of-truth table below now list only
> the four operator-authored `IRM Lab — *` policies). This revises the
> §Decision #3 clause that told operators "not to shrink the
> system-managed entry": that entry is redundant. [`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1)
> classifies any `IRM_Tenant_Setting_*` policy as `NoChange` via a
> name-prefix wildcard **before** the orphan / `-PruneMissing` branch, so
> the reconciler never plans a mutation against it regardless of
> `-SkipNames` or `-PruneMissing`. Keeping a placeholder GUID in the
> baseline would also break the live smoke test, whose
> [`Invoke-IRMSmokeTest.ps1`](../../scripts/Invoke-IRMSmokeTest.ps1)
> asserts every baseline name appears as a `Skipped` plan row — a
> placeholder never matches the real tenant name.
>
> Pre-wildcard claims in §Context and §Consequences that `-PruneMissing`
> "would attempt to delete the system policy and fail" are **corrected
> below** — the wildcard short-circuits to `NoChange` first, so no delete
> is ever attempted. The core decision (treat the tenant-setting policy
> as a permanent declared orphan) is **unchanged**.

## Context

[#603](../../issues/603) (v2 §5.3 Insider Risk Management drift closure and reconciler hardening) entered Phase 1 on 2026-06-14 with a read-only `-WhatIf` baseline against `contoso.onmicrosoft.com`. The Phase 1 inventory of `Get-InsiderRiskPolicy` returned 5 policies:

| # | Name | Scenario | Source |
|---|------|----------|--------|
| 1 | `IRM Lab — Data theft by departing users` | IntellectualPropertyTheft | operator-authored (mid-testing) |
| 2 | `IRM Lab — Risky AI usage` | RiskyAIUsage | operator-authored (mid-testing) |
| 3 | `IRM Lab — Data leaks by priority users` | HighValueEmployeeDataLeak | operator-authored (mid-testing) |
| 4 | `IRM_Tenant_Setting_<tenant-guid>` | TenantSetting | system-managed (Microsoft) |
| 5 | `IRM Lab — General data leaks` | LeakOfInformation | operator-authored (mid-testing) |

Entry #4 is the subject of this ADR. The remaining four are operator-authored and held under the [#603](../../issues/603) hard rule (no mutation during active testing); their disposition is a separate follow-up.

### What the tenant-setting policy is

Microsoft Purview Insider Risk Management synthesises a single per-tenant policy of scenario `TenantSetting` to back the global IRM configuration surface (privacy settings, anonymisation, policy timeframes, indicators inventory, intelligent detections). The policy is created automatically when IRM is first configured in a tenant and carries a tenant-scoped GUID suffix on its `Name`. In `contoso.onmicrosoft.com` that name is `IRM_Tenant_Setting_<tenant-guid>` (the real GUID is a tenant identifier and is redacted per the "Environment and identifier boundaries" rule), created 2026-02-13 (the date IRM was first opened in this lab).

`Get-InsiderRiskPolicy` returns it alongside operator-authored policies. The reconciler's plan categoriser classifies it as `NoChange` via a name-prefix wildcard (`IRM_Tenant_Setting_*`) that runs **before** the orphan / `-PruneMissing` branch, so it is never classified as `Orphan` and a `-PruneMissing` run never attempts to delete it.

### Probe against `contoso.onmicrosoft.com` on 2026-06-14

Read-only inspection from the connected Phase 1 IPPS session:

- `Get-InsiderRiskPolicy -Identity 'IRM_Tenant_Setting_<tenant-guid>'` returns the object with `Mode: Enable`, `Enabled: True`, `Priority: 0`, `Comment: ''`, `IsValid: True`. The `Mode: Enable` value matches every operator-authored policy in the tenant, providing no diff signal.
- `Get-Command *InsiderRisk*` lists nine cmdlets: `Get/New/Set/Remove-InsiderRiskPolicy`, `Set-InsiderRiskPolicyLite`, and the four-cmdlet `*-InsiderRiskEntityList` family. None of them accept a parameter that targets or excludes `TenantSetting`-scenario policies specifically.
- No delete was attempted. The [#603](../../issues/603) hard rule forbids `Set-*` / `Remove-*` against any pre-existing live policy regardless of system-managed vs. operator-authored origin.

### Microsoft Learn coverage as of 2026-06-14

- **[Get-InsiderRiskPolicy (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy)** — documents the cmdlet without mentioning `TenantSetting` as a distinct scenario or as a filterable class. The `-Identity` parameter accepts `Name` or `Guid`.
- **[Remove-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy)** — documents `-Identity` only. No `-Force`, no `-Scope`, no parameter that distinguishes system-managed from operator-authored policies.
- **[Insider Risk Management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings)** — describes the global tenant-scope configuration surface IRM exposes in the portal but documents zero PowerShell, Microsoft Graph, or REST endpoints for reading or writing it directly. The page documents portal-only operations.
- **Microsoft Graph probes** — `https://learn.microsoft.com/en-us/graph/api/resources/security-insiderriskpolicy` and `…insiderrisk` return HTTP 404. The Graph `security` namespace overview ([learn.microsoft.com/en-us/graph/api/resources/security-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)) contains zero occurrences of `insiderRisk`, `irm`, or `tenantSetting`.

Net: **Microsoft Learn does not currently document the `IRM_Tenant_Setting_*` policy as an addressable object for delete, nor does it expose a filter or scope on the IRM cmdlets that would exclude it from `-PruneMissing`.** It is created by Microsoft, owned by Microsoft, and operationally inseparable from the rest of the IRM service.

## Decision

**We will not delete, mutate, or attempt to declare the `IRM_Tenant_Setting_*` policy in `contoso.onmicrosoft.com`. We will treat it as a permanent, declared orphan for the lifetime of this ADR.** Specifically:

1. **[#603](../../issues/603) Phase 2 disposition #2 closes as (b) ratify via ADR.** The tenant-setting policy remains in the tenant as an orphan; the reconciler always reports it; the operator-facing surface treats its presence as expected.

2. **The reconciler ships `-DirectionPolicy` and `-SkipNames` per [ADR 0029](0029-source-of-truth-direction-policy.md).** Sibling Phase 3 work in [#603](../../issues/603) wires both onto [`scripts/Deploy-IRMPolicies.ps1`](../../scripts/Deploy-IRMPolicies.ps1). This ADR does not specify the parameter shape; ADR 0029 does.

3. **The CI workflow baseline skip list contains every operator-authored `IRM Lab — *` policy currently held under the [#603](../../issues/603) hard rule.** The `Deploy IRM policies` step in `.github/workflows/deploy-data-plane.yml` defaults `skip_names_irm` to the list in §Consequences below. Operators may extend the list at dispatch time. The system-managed `IRM_Tenant_Setting_*` policy is **not** on this list (see the 2026-07-12 Update above): the reconciler short-circuits it to `NoChange` via a name-prefix wildcard, so an explicit skip entry is redundant. The operator-authored entries shrink only after the active IRM testing window closes and a follow-up issue ratifies their adoption into desired state.

4. **The desired-state YAML header documents the skip baseline and links here.** [`data-plane/irm/policies.yaml`](../../data-plane/irm/policies.yaml) gains a `Skip baseline (see ADR-0036)` paragraph explaining why the declared empty state coexists with tenant entries, names the four operator-authored entries verbatim, and notes that the system-managed policy is handled by the reconciler wildcard rather than the baseline, so the YAML is self-describing without a round-trip to this file.

5. **Add open-question row Q16 to [`docs/project-plan.md`](../project-plan.md) §8** as the standing watch-list. The row is permanently open until any re-open trigger below fires.

6. **No undocumented surface.** We will not reverse-engineer the Microsoft Purview portal's internal REST traffic to mutate the tenant-setting policy. We will not invoke undocumented parameters on `Remove-InsiderRiskPolicy`. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and would break on any backend revision without warning. This restriction is identical to [ADR 0019](0019-cc-graph-pivot.md) §6, [ADR 0022](0022-dspm-for-ai-authoring-surface.md) §6, [ADR 0027](0027-autoapplication-removal-watch-list.md) §5, and [ADR 0035](0035-records-seed-content-immovable.md) §6.

### Re-open triggers (the watch list)

This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:

- The [Get-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy) or [Remove-InsiderRiskPolicy](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy) reference page documents a `-Scenario`, `-Scope`, or `-IncludeSystemManaged` parameter that allows filtering or excluding `TenantSetting`-class policies from enumeration or deletion.
- An `insiderRiskPolicy`, `insiderRiskSettings`, or similarly-named resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0) with read or write coverage for the tenant-setting surface.
- [Insider Risk Management settings](https://learn.microsoft.com/en-us/purview/insider-risk-management-settings) or [Insider Risk Management overview](https://learn.microsoft.com/en-us/purview/insider-risk-management) gains a "programmatically configure tenant-scope IRM settings" section (PowerShell, Microsoft Graph, or REST).
- A Microsoft-published reference repo (under `github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a sample that reads or writes the IRM tenant-setting policy against a non-test tenant via a documented surface.

## Consequences

**Easier:**

- **[#603](../../issues/603) Phase 3 unblocks** without a destructive operation that cannot succeed and would violate the hard rule. The smoke wrapper from sibling [#603](../../issues/603) exercises Create → Get → Delete → Get-gone against synthetic `e2e-irm-smoke-*` policies; the tenant-setting policy is out of frame.
- **Reviews stay signal-only.** With `-SkipNames` defaulting to the skip baseline, every CI `-WhatIf` returns zero plan rows when the YAML matches the (empty) desired state; real drift on future operator-authored policies surfaces unmasked.
- **The repo stays inside its grounding rule.** Every cited Microsoft Learn URL in this ADR was reachable on 2026-06-14 before the ADR was committed.
- **Symmetry with the rest of the repo.** Watch-list ADRs already exist for [ADR 0019](0019-cc-graph-pivot.md) (Communication Compliance), [ADR 0022](0022-dspm-for-ai-authoring-surface.md) (DSPM for AI), [ADR 0027](0027-autoapplication-removal-watch-list.md) (sensitivity-label removal), and [ADR 0035](0035-records-seed-content-immovable.md) (Records seed content). This ADR follows the same shape.

**Harder:**

- **The lab tenant carries the `IRM_Tenant_Setting_*` policy indefinitely.** It has no operational impact (operator-authored policies do not reference it; the reconciler skips it) but it is visible in the Microsoft Purview portal and in every `Get-InsiderRiskPolicy` call.
- **`-PruneMissing` without `-SkipNames` does not touch the tenant-setting policy.** The reconciler classifies any `IRM_Tenant_Setting_*` policy as `NoChange` via a name-prefix wildcard that runs before the orphan / `-PruneMissing` branch, so even a hand-run of `Deploy-IRMPolicies.ps1 -PruneMissing` from a developer's machine without `-SkipNames` never attempts to delete it. (An earlier draft of this ADR claimed the prune would attempt the delete and fail; that predates the wildcard short-circuit and is corrected here per the 2026-07-12 Update.) The operator-authored `IRM Lab — *` policies still require `-SkipNames` to avoid a prune; the Phase 3 operator runbook from [#603](../../issues/603) reminds the operator at Step 0.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** **Revised 2026-07-12 (see Update above).** This ADR introduces no new credentials. The tenant-setting policy name carries a real tenant-scoped GUID; per the "Environment and identifier boundaries" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md), a tenant-scoped GUID is a real tenant identifier and must not appear verbatim in source (the reviewer grep rejects any non-zero GUID). The GUID is therefore redacted to `<tenant-guid>` everywhere; that rule takes precedence over the earlier position that treated it as acceptable-in-source alongside the file-plan property GUIDs in [ADR 0035](0035-records-seed-content-immovable.md) §Probe.
- **#4 (least privilege).** Upheld. The reconciler runs as the data-plane workload identity already gated to the IRM role group; this ADR does not expand scope.
- **#9 (idempotent, reversible, auditable).** Upheld. The decision is captured here in version control; the workflow baseline lists the skip-baseline entries so a future revert is a single-PR change.

### The skip baseline (verbatim, for the workflow default and the YAML header)

The list below is the source of truth for both [`data-plane/irm/policies.yaml`](../../data-plane/irm/policies.yaml)'s header comment and the `skip_names_irm` baseline default in `.github/workflows/deploy-data-plane.yml`. It contains only the four operator-authored `IRM Lab — *` policies (alphabetical). The system-managed `IRM_Tenant_Setting_<tenant-guid>` policy is intentionally **absent** — the reconciler classifies it `NoChange` via a name-prefix wildcard (`IRM_Tenant_Setting_*`), so it never needs a baseline entry (see the 2026-07-12 Update).

| Source | Name |
|---|---|
| operator-authored (mid-testing) | `IRM Lab — Data leaks by priority users` |
| operator-authored (mid-testing) | `IRM Lab — Data theft by departing users` |
| operator-authored (mid-testing) | `IRM Lab — General data leaks` |
| operator-authored (mid-testing) | `IRM Lab — Risky AI usage` |

The operator-authored entries above are a snapshot as of 2026-06-14 Phase 1 and are subject to change only via the follow-up issue that adopts them into desired state once the active testing window closes. The system-managed policy remains a permanent declared orphan for the lifetime of this ADR, handled by the reconciler wildcard rather than this baseline.