# 0002 — Administrative Units: scaffold the deployment pattern; keep tenant state empty by default

- **Status:** Accepted
- **Date:** 2026-04-18
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q2, unblocks Wave 0 deliverable `docs/governance/administrative-units.md`
- **Deciders:** @contoso
- **Supersedes:** (none — prior draft in PR branch not merged)

## Context

[Microsoft Entra administrative units](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units) (AUs) subdivide a tenant into delegated-admin scopes. [Microsoft Purview integrates with AUs](https://learn.microsoft.com/en-us/purview/purview-admin-units) for six solutions — Data Loss Prevention, Insider Risk Management, Communication Compliance, Data Lifecycle Management, Records Management, and Sensitivity Labeling — via AU-scoped role groups and policies.

Four facts about AUs that matter for `contoso.onmicrosoft.com`:

1. **Prerequisites.** AUs require Microsoft Entra ID P1 or P2 per administrator managing AU-scoped roles, in addition to the E5 licensing confirmed in [ADR 0001](0001-m365-licensing-verification.md). Source: [Prerequisites for administrative units](https://learn.microsoft.com/en-us/purview/purview-admin-units#prerequisites-for-administrative-units). M365 E5 includes Entra ID P1 via `AAD_PREMIUM`, so the prereq is satisfied.
2. **Entra roles override AU scope.** Per [Role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior), a user who holds an Entra role such as `Compliance Administrator` *and* an AU-scoped Purview role group is evaluated against the Entra role first — AU scoping is bypassed. In a single-admin lab where the one identity holds `Global Administrator`, an AU does not effectively restrict anything.
3. **AUs can't nest, and dynamic group membership isn't supported.** Source: [AU constraints](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#constraints).
4. **What Purview AU integration does not cover.** Purview Data Map, Unified Catalog, eDiscovery, and DSPM are not in the supported-solutions table ([Administrative units in Microsoft Purview](https://learn.microsoft.com/en-us/purview/purview-admin-units#supported-solutions)). Wave 3 work is unaffected by the AU decision either way.

**Single-admin lab reality.** One Entra tenant, one administrator plus the GitHub Actions workload identity, no regional or departmental split. A persistent AU set adds operational overhead (membership bookkeeping, Entra ID P1 accounting per admin, AU-scoped role-group management) for zero effective scope restriction against the admin identity.

**But — capability matters more than static posture.** The original draft of this ADR proposed "do not adopt, do not scaffold." That removes optionality: if a scenario emerges (a second contributor joins the lab, a demo needs to show AU-scoped DLP alerts, a regulator ad-hoc audit requires delegated admin boundaries), we have no exercised pattern to reach for. Shipping untested scaffolding is also rejected — scaffolding that nobody runs rots against the live API.

The decision below lands the capability **and** exercises it end-to-end, then keeps the default tenant state empty.

## Decision

1. **We will land AU deployment capability as a first-class data-plane domain** in this repo:
    - [`data-plane/administrative-units/administrative-units.yaml`](../../data-plane/administrative-units/administrative-units.yaml) — desired-state list of AUs for `contoso.onmicrosoft.com`.
    - [`scripts/Deploy-AdministrativeUnits.ps1`](../../scripts/Deploy-AdministrativeUnits.ps1) — idempotent GET → diff → act against [Microsoft Graph `directory/administrativeUnits`](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit) with `-WhatIf` / `-PruneMissing` / `-Force`, matching the drift-report contract in [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md).
2. **The default steady state is an empty `administrativeUnits: []` list.** When the repo is merged to `main` with no open AU scenario, no AU exists in the tenant. A re-run of the deploy script on an empty YAML is a no-op.
3. **Data-plane scoping for Wave 3a and the M365 solutions in Wave 2 remains collection-scoped Purview RBAC + solution-native policy scoping.** No policy YAML under `data-plane/**` emits an AU reference until a superseding ADR lands. Source: [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).
4. **We will exercise the pattern end-to-end in the lab as part of this PR.** A single test AU (`au-contoso-lab-test`, zero members, visibility `Public`) is created via the new script, confirmed by a Graph GET, and then reverted before merge. Evidence block captured in the `/new-checkin` PR description per [`.github/instructions/pull-request.instructions.md`](../../.github/instructions/pull-request.instructions.md).
5. **We will revisit this decision, and change the default state, when any of the following becomes true** (tracked in [`docs/governance/administrative-units.md`](../governance/administrative-units.md)):
    - A second administrator identity joins the tenant needing a restricted scope.
    - A second suborg, legal entity, or regional workload requires delegated admin separation.
    - A compliance obligation requires cross-admin visibility restrictions for DLP, IRM, or CC.
    - Microsoft changes [role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior) so that AUs meaningfully restrict identities that also hold tenant-wide Entra roles.

## Consequences

**Easier.**

- On-demand AU capability, ready to use without authoring a script from scratch under pressure.
- Pattern has been exercised against the live `contoso.onmicrosoft.com` tenant at least once — `api-version`, Graph permissions, drift semantics, and idempotency are proven, not assumed.
- Default state (empty YAML) means no ongoing membership bookkeeping, no Entra ID P1 administrator-count churn, no AU-scoped role-group noise in the Wave 0 scripts.
- `Grant-PurviewDataMapRole.ps1` and `Grant-M365ComplianceRoles.ps1` stay simple — they assign at the collection / role-group level without an AU-scope parameter.

**Harder.**

- One more `Deploy-*.ps1` in the CI lint surface (`Invoke-ScriptAnalyzer -Path scripts -Recurse`) and one more YAML folder in `yamllint data-plane/`.
- The Wave 0 automation identity (originally tracked as `scripts/New-AutomationIdentity.ps1` in §8 Q3; subsequently decomposed into [`New-AutomationEntraApp.ps1`](../../scripts/New-AutomationEntraApp.ps1), [`New-AutomationCertificate.ps1`](../../scripts/New-AutomationCertificate.ps1), [`New-AutomationKeyVault.ps1`](../../scripts/New-AutomationKeyVault.ps1), and [`New-AutomationRbac.ps1`](../../scripts/New-AutomationRbac.ps1)) needs the Graph application permission `AdministrativeUnit.ReadWrite.All` (or the user running the script needs `Privileged Role Administrator`). This is a new grant to document.
- A future contributor who adds an AU must also remember to remove it on teardown, or add it to the desired state — otherwise `-PruneMissing` will delete it on the next CI run.

**Unblocks.**

- §8 Q2 in [`docs/project-plan.md`](../project-plan.md).
- Wave 0 deliverable `docs/governance/administrative-units.md` — the outcome doc now has both a decision and a pattern to document.
- Any future ADR that flips the default state from empty to a persistent AU set can land as a focused YAML change plus a superseding ADR — no new script surface required.

## Alternatives considered

- **Do not adopt, do not scaffold** (original draft of this ADR). Rejected: removes optionality; if an AU scenario arises mid-wave, the repo has no exercised pattern, and writing one under pressure risks correctness. The original rationale against *persistent* adoption still stands, but that's not the same as against *capability*.
- **Adopt persistently now, one "lab" AU containing everything.** Rejected: a single AU equal to the full tenant provides no scope restriction and triggers the prereq and membership overhead for zero benefit. Source: [AU deployment scenario](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#deployment-scenario).
- **Adopt by persona (one AU per policy area — "DLP admins", "IRM admins").** Rejected: AUs contain users/groups/devices, not policy areas. The native scoping for "who administers DLP" is the DLP role group, not an AU. Source: [AUs — Groups](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#groups).
- **Ship the scaffold without exercising it against the live tenant.** Rejected: untested scaffolding rots. The first real user of an untested script pays the debugging tax on top of their actual work.
- **Do nothing, leave §8 Q2 open.** Rejected: §8 Q2 blocks a Wave 0 deliverable; leaving it open forces every Wave 0 role-assignment PR to re-argue the design.

## Citations

- [Administrative units in Microsoft Purview](https://learn.microsoft.com/en-us/purview/purview-admin-units) — supported solutions, prerequisites, permissions.
- [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units) — deployment scenario, constraints, licensing.
- [Permissions in the Microsoft Purview portal — Role precedence and scope behavior](https://learn.microsoft.com/en-us/purview/purview-permissions#role-precedence-and-scope-behavior) — Entra roles override AU scope.
- [Microsoft Graph — administrativeUnit resource type](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit) — REST shape used by the deploy script.
- [Microsoft Graph — Create administrativeUnit](https://learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits) — POST endpoint and request body.
- [Microsoft Graph — List administrativeUnits](https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits) — GET endpoint used in drift calc.
- [Microsoft Graph — Delete administrativeUnit](https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete) — prune path.
- [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions) — collection-scoped RBAC used in place of AUs for Wave 3a.
- [ADR 0001 — Microsoft 365 licensing: require E5 and verify at deploy time](0001-m365-licensing-verification.md) — confirms the `AAD_PREMIUM` service plan that satisfies the AU prereq.
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift-report contract the new script conforms to.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — Non-negotiable security principles (rule #4, least privilege).
