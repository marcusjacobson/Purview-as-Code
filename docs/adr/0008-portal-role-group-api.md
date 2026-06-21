# 0008 — Portal role-group membership management API: hybrid, Microsoft Graph primary, Security & Compliance PowerShell fallback

- **Status:** Superseded by [ADR 0009](0009-portal-role-group-api-ship-order.md)
- **Date:** 2026-04-18

> **Supersession note (2026-04-19).** The runtime ship-order in this ADR ("Graph primary, S&C PowerShell fallback on 404") was based on an incorrect assumption that Microsoft Graph covers some Purview portal role groups today. Post-acceptance Learn verification showed [`rbacApplication`](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication) supports only `directory` and `entitlementManagement` providers, and [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) documents only portal-UI flows for role-group management — i.e., zero Graph coverage of portal role groups today. [ADR 0009](0009-portal-role-group-api-ship-order.md) reverses the ship-order to S&C PowerShell today and reinstates the hybrid direction when an Exchange / compliance / Purview provider appears on `rbacApplication`. Content below is preserved unchanged for history.
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q8; unblocks Wave 0 deliverable `scripts/Grant-PurviewRoleGroup.ps1` and its desired-state YAML under `data-plane/purview-role-groups/`
- **Deciders:** @contoso

## Context

[Microsoft Purview portal role groups](https://learn.microsoft.com/en-us/purview/purview-permissions) are the top-level governance RBAC surface for the Purview portal and the Microsoft Defender / Purview compliance experience. Built-in role groups include Organization Management, Compliance Administrator, Compliance Data Administrator, eDiscovery Manager, Insider Risk Management, Records Management, Data Loss Prevention Compliance Management, Communication Compliance, Information Protection, Privacy Management, and roughly two dozen others ([Roles and role groups in the Microsoft Defender portal and the Microsoft Purview portal](https://learn.microsoft.com/en-us/defender-office-365/scc-permissions)). These are a **distinct RBAC surface** from:

- **Data Map collection roles** (`Collection Admin`, `Data Source Admin`, `Data Curator`, `Data Reader`, `Insights Reader`), which this repo already ships via [`scripts/Grant-PurviewDataMapRole.ps1`](../../scripts/Grant-PurviewDataMapRole.ps1) against the Purview data-plane `/policyStore/metadataPolicies` endpoint.
- **DevOps / data-owner policies** under `/policyStore/policies`, deferred to a later wave.

Managing portal role-group membership declaratively (YAML → reconciler → idempotent GET / diff / PATCH) requires an API. Two realistic candidates exist:

1. **Microsoft Graph** `/security/...` role-management endpoints. Modern REST surface. Supports managed identity with app-only permissions such as `RoleManagement.ReadWrite.Security` (assigned to the Wave 0 automation identity per the future `New-AutomationIdentity.ps1`). Aligns with [rule #2 in `security.instructions.md`](../../.github/instructions/security.instructions.md) ("managed identity > service principal > key-based auth"). **But coverage is partial and moving** — some portal role groups are exposed under `/security/roleAssignments` and the unified RBAC application namespace, others are not yet surfaced or remain in `/beta`. References: [Microsoft Graph — roleAssignment (security)](https://learn.microsoft.com/en-us/graph/api/resources/security-roleassignment), [Microsoft Graph — RBAC application model](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication).
2. **Security & Compliance PowerShell** via [`Connect-IPPSSession`](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) plus [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember) / [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember) / [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember). **100% coverage** of every portal role group. Supports [certificate-based app-only authentication](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2). **But** — slower cold-connect (remote PowerShell session, seconds not milliseconds per run), a shrinking surface Microsoft is actively migrating off ([Move from REST to Security & Compliance PowerShell — deprecation context](https://learn.microsoft.com/en-us/powershell/exchange/scc-powershell)), and it foregrounds cert-based auth when the rest of the repo standardizes on managed-identity-first.

**Neither is strictly sufficient on its own today.** Graph alone drops role groups that ship only through the compliance PowerShell surface; S&C PowerShell alone locks the whole primitive to cert-based auth and imports a deprecating tail.

A related concern: this decision needs to be narrow. The portal role-group primitive touches four other decisions — auth method, exact Graph app roles required, connection caching across many-member runs, and the per-role-group fallback list. Bundling them into one ADR would delay the build and couple changes that should be able to move independently. This ADR therefore decides **only** the API-choice boundary and explicitly hands off the adjacent decisions.

## Decision

1. **We will use a hybrid API strategy.** [`scripts/Grant-PurviewRoleGroup.ps1`](../../scripts/Grant-PurviewRoleGroup.ps1) **will call Microsoft Graph first** for any portal role group whose membership is supported on Graph's role-management endpoints, and **will fall back to Security & Compliance PowerShell** (`Connect-IPPSSession` + `Add-RoleGroupMember` / `Remove-RoleGroupMember` / `Get-RoleGroupMember`) for role groups Graph does not yet cover.
2. **The fallback trigger is an HTTP 404 from Graph on the target role-group resource**, not a static allow-list inside the ADR. The script will probe Graph, and on 404 (or the documented "unsupported role group" error shape from [`rbacApplication`](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication)), fall through to the S&C PowerShell path. This keeps the ADR stable as Graph coverage grows.
3. **Graph is the preferred long-term path.** When a future Graph release exposes the last role group this repo declares in `data-plane/purview-role-groups/`, we will drop the S&C PowerShell code path, retire the cert-based credential material, and supersede this ADR with a Graph-only decision. There is no fixed date — the trigger is coverage, not calendar.
4. **The desired-state YAML format is API-agnostic.** `data-plane/purview-role-groups/purview-role-groups.yaml` will list `{ roleGroup, members[] }` entries; it will not encode which API moved each entry. The script, not the YAML, owns the fallback matrix.

## Scope — what this ADR does *not* decide

This ADR is deliberately narrow. The following adjacent decisions are out of scope and are owned elsewhere:

- **Auth method for each path.** Graph auth and S&C PowerShell cert-based app-only auth will be decided alongside the Wave 0 automation identity work (`scripts/New-AutomationIdentity.ps1`, tracked in [`docs/project-plan.md`](../project-plan.md) §8 Q3 and §8 Q4). This ADR assumes whichever identities those decisions produce.
- **Exact Graph application permissions and Exchange Online role assignments** required by each path. These will land in the `scripts/Grant-PurviewRoleGroup.ps1` build PR description and the module header comment, cited inline to Learn. Enumerating them here would duplicate a living list.
- **Connection caching and session reuse** across many-member runs (Graph token caching; `Connect-IPPSSession` re-use across a single script invocation). This is a script-implementation concern, not an architectural one.
- **The current per-role-group fallback matrix** (which Graph endpoints cover which role groups today). This belongs in the script's reconciler logic and, optionally, a comment block in the YAML — not in an ADR, because it will change every time Graph adds coverage.

A later PR may tighten any of the above without superseding this ADR, provided the hybrid boundary in §Decision still holds.

## Consequences

**Easier.**

- Full coverage of the portal role-group surface from day one — no role group is undeclarable.
- Graph-first means the managed-identity-preferred path is the default, consistent with [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2. Cert-based auth is scoped to the shrinking tail.
- The fallback trigger is dynamic (HTTP 404 probe), so the ADR does not have to be reopened every time Graph coverage expands.
- The YAML contract stays stable across the eventual cutover to Graph-only.

**Harder.**

- Two code paths to maintain in one script until Graph reaches 100% coverage — two sets of error-handling, two idempotency calculations, two authentication contexts loaded by one workflow run.
- Two sets of Learn citations and two permissions grants to document in the `Grant-PurviewRoleGroup.ps1` build PR. The workflow must provision both credential materials until the retirement ADR lands.
- An S&C PowerShell cold-connect adds seconds of latency to any CI run that touches a fallback-only role group. This is acceptable for the lab but must be called out in the script's runtime notes.
- [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 is *relaxed in the narrow subset* where Graph has no coverage. Justification: without the fallback, affected role groups become undeclarable, which is worse than a scoped cert-based credential. The relaxation is bounded — it retires when Graph coverage reaches 100%.

**Unblocks.**

- §8 Q8 in [`docs/project-plan.md`](../project-plan.md).
- Wave 0 deliverable `scripts/Grant-PurviewRoleGroup.ps1` and its desired-state YAML in `data-plane/purview-role-groups/`.
- The first real build of a declarative reconciler against portal role groups — previously blocked on the API boundary.

**Blocks nothing new.** The pending items `scripts/New-AutomationIdentity.ps1` (§8 Q3 + §8 Q4) and the OIDC workflow wiring remain gated on their own ADRs; this ADR does not resolve them.

## Alternatives considered

- **Graph only.** Rejected — today drops coverage of role groups that are surfaced only through the compliance PowerShell surface. Declaring them in YAML and failing at reconcile time is strictly worse than falling back. Revisit when Graph coverage reaches 100%.
- **Security & Compliance PowerShell only.** Rejected — locks every role-group operation to cert-based app-only auth, foregrounds a deprecating-direction surface ([SCC PowerShell migration context](https://learn.microsoft.com/en-us/powershell/exchange/scc-powershell)), and conflicts with [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 for every role group Graph already covers today. Accepting that cost for the subset Graph *doesn't* cover is defensible; accepting it for the majority is not.
- **Defer — do not ship portal role-group management in Wave 0.** Rejected — portal role groups are the top-level Purview governance primitive per [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions), and several Wave 2 / Wave 4 solutions (DLP, IRM, CC, DSPM) implicitly assume an identity can be assigned into the appropriate role group on demand. Deferring forces every Wave 2 author to re-argue how membership is granted.
- **Static allow-list inside this ADR naming which role groups use which path.** Rejected — Graph coverage changes faster than this ADR can track. The allow-list belongs in script logic so it can be updated in a focused PR without superseding an ADR.
- **Do nothing — leave §8 Q8 open.** Rejected — §8 Q8 currently blocks `scripts/Grant-PurviewRoleGroup.ps1`, which is a Wave 0 item. Leaving it open propagates the block to every downstream wave that needs a portal role-group assignment.

## Citations

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) — portal role-group surface, scope behavior.
- [Roles and role groups in the Microsoft Defender portal and the Microsoft Purview portal](https://learn.microsoft.com/en-us/defender-office-365/scc-permissions) — built-in role-group catalog.
- [Microsoft Graph — roleAssignment (security)](https://learn.microsoft.com/en-us/graph/api/resources/security-roleassignment) — Graph-side role-assignment resource shape.
- [Microsoft Graph — rbacApplication resource type](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication) — unified RBAC application model Graph uses across role-management namespaces.
- [Connect to Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) — `Connect-IPPSSession`, the fallback-path entry point.
- [App-only authentication for unattended scripts in Exchange Online / Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) — cert-based auth for the fallback path.
- [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember), [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember), [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember) — S&C PowerShell cmdlets used by the fallback path.
- [Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/scc-powershell) — migration context framing the "shrinking surface" argument.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — rule #2 (managed identity > service principal > key-based auth); rule #4 (least privilege).
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift-report contract `Grant-PurviewRoleGroup.ps1` will conform to.
- [ADR 0002 — Microsoft Entra administrative units in this repo](0002-administrative-units.md) — adjacent ADR establishing the declarative-reconciler + desired-state pattern used here.
