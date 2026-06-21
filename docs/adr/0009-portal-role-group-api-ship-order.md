# 0009 — Portal role-group membership management API: Security & Compliance PowerShell today; Microsoft Graph when a provider lands

- **Status:** Accepted
- **Date:** 2026-04-19
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q8; unblocks Wave 0 deliverables `scripts/Grant-PurviewRoleGroup.ps1`, `data-plane/purview-role-groups/role-groups.yaml`, and `scripts/Deploy-PurviewRoleGroups.ps1`
- **Deciders:** @contoso
- **Supersedes:** [ADR 0008](0008-portal-role-group-api.md)

## Context

[ADR 0008](0008-portal-role-group-api.md) accepted a hybrid API strategy for Microsoft Purview portal role-group membership: Microsoft Graph primary, Security & Compliance PowerShell fallback triggered by a Graph 404. That ADR described Graph coverage as "partial and moving" and proposed probing Graph first, expecting coverage to grow toward 100% over time.

When the `scripts/Grant-PurviewRoleGroup.ps1` build started, verifying the Graph endpoint against Learn revealed a factual gap in ADR 0008's context:

1. **`rbacApplication` supports only `directory` and `entitlementManagement` providers today.** Per [`rbacApplication` resource type](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication), the unified RBAC application model exposes role definitions and role assignments for exactly those two Microsoft 365 RBAC providers. There is no `exchange`, `compliance`, `purview`, or `officeEndpoint` provider on `rbacApplication`. Purview portal role groups (Organization Management, Compliance Administrator, eDiscovery Manager, Insider Risk Management, etc.) are not routed through `directory` or `entitlementManagement`; they live behind the Exchange / Security & Compliance compliance backend.
2. **No Graph-surface Purview portal role-group endpoint is documented.** [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) documents every add/remove/create/update/delete flow for portal role groups — and in every case the documented path is the **portal UI**. No `learn.microsoft.com/en-us/graph/` URL is cited for these operations.
3. **S&C PowerShell has 100% coverage today.** [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember), [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember), and [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember) via [`Connect-IPPSSession`](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) cover every portal role group. Certificate-based app-only authentication is supported via [App-only authentication](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2).

**Implication for ADR 0008's ship-order.** "Graph primary, fallback on 404" assumed some role groups work through Graph today. In reality, zero Purview portal role groups work through Graph today. Implementing the primitive per ADR 0008 would produce a script where the 404 fallback fires on every invocation — i.e., a script that always runs the S&C path and never runs the Graph path, but whose code-path complexity (dual auth contexts, dual error handling, dual idempotency calc) exists anyway. That is worse than S&C-only plus a forward-looking extension point.

**The hybrid direction in ADR 0008 is still correct.** Microsoft has telegraphed `rbacApplication` as a unification target for M365 RBAC providers over time. If Microsoft ships an Exchange or compliance provider under that model, Graph becomes the managed-identity-preferred path per [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2, and the fallback framing from ADR 0008 reappears — *on that future day*. The fix is to reverse the ship-order until that day arrives, not to abandon the hybrid goal.

This ADR is also deliberately narrow, matching ADR 0008's scope boundary. It decides the API ship-order only and explicitly defers the four adjacent decisions already deferred in ADR 0008.

### Addendum — known learnings from sibling repo (2026-04-19, editorial)

*Editorial note, not a decision change. Added after the Accepted status to capture implementation signal gathered from the [`Azure-Deployment-Pipelines`](https://github.com/contoso/Azure-Deployment-Pipelines) sibling repository while researching `Connect-IPPSSession` usage. These learnings do not alter the decision above; they pre-answer concrete questions the `scripts/Grant-PurviewRoleGroup.ps1` build PR will otherwise have to re-research. Companion change: [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) gained a `Runtime: pwsh 7.4+ only, and the Connect-IPPSSession auth constraint` section in the PR that landed alongside this addendum.*

1. **Runtime is PowerShell 7.4+, not 5.1.** The sibling repo's `Azure-Deployment-Pipelines/Purview/Purview-AutoLabel-Policy/README.md` troubleshooting section documents that the `msalruntime.dll` / WAM failure under `Connect-IPPSSession` affects *interactive* auth on PowerShell 7. App-only certificate auth works on pwsh 7 and is the mandated path here anyway. The repo-wide rule is captured in [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md); it supersedes any blog-post guidance recommending a 5.1 downgrade.
2. **Session-reuse pattern is already proven.** The `Connect-ComplianceCenter` function shape in the sibling repo (e.g. `Azure-Deployment-Pipelines/Purview/Purview-AutoLabel-Policy/Scripts/Get-PurviewAutoLabelPolicy.ps1` and `New-PurviewAutoLabelPolicy.ps1`) probes for an existing session via `Get-PSSession` before calling `Connect-IPPSSession`, wraps the work in `try { ... } finally { Disconnect-ExchangeOnline -Confirm:$false }`, and passes `-ShowBanner:$false` to keep CI logs clean. This is the reference shape for the reconciler's connect/disconnect contract — no new pattern work required.
3. **Certificate app-only auth is mandatory, not preferred.** The sibling repo confirms Security & Compliance PowerShell app-only auth does not accept client secrets; `-AppId` + `-CertificateThumbprint` + `-Organization` are required inputs for unattended auth. This is a stronger constraint than "prefer certificates" elsewhere in the repo and belongs in the `scripts/Grant-PurviewRoleGroup.ps1` module header as a cited prerequisite.
4. **Exchange `Organization Management` is a chicken-and-egg prereq.** Per the sibling repo's permissions table in `Azure-Deployment-Pipelines/Purview/README.md`, the automation app principal must be a member of the Exchange **Organization Management** role group *before* `Connect-IPPSSession` succeeds for compliance cmdlets. That membership cannot be bootstrapped by the primitive itself — it has to be added manually once per tenant (or by a bootstrap script outside this primitive's scope). The build PR must document this as a manual prerequisite, not attempt to self-provision it.
5. **The 4-step automation-identity setup is already specified elsewhere.** The sibling repo's `Azure-Deployment-Pipelines/SharePoint/SharePoint-File-Labeling/Scripts/` contains a documented four-step setup — `New-ConfidentialClientApp.ps1`, `New-KeyVault.ps1`, `New-AppCertificate.ps1`, `Add-AppPermissions.ps1` — that produces exactly the identity shape this ADR's scope disclaimer defers to §8 Q4. (Note: the sibling repo's fifth script, `Enable-GraphMeteredApiBilling.ps1`, is Graph-metered-billing-only and is not required on the S&C-PowerShell path this ADR ships.) The §8 Q4 resolution for `scripts/New-AutomationIdentity.ps1` should cite this sequence as its canonical reference; a separate PR adds that pointer to the project plan.
6. **SCC-PowerShell app-only cert auth is not yet integrated anywhere in the sibling repo.** The primitives above (items 2–3) exist, but no sibling-repo script stitches cert-based app-only `Connect-IPPSSession` end-to-end. The `scripts/Grant-PurviewRoleGroup.ps1` build is therefore new integration work, not a port — the build PR owns end-to-end validation against a live lab S&C endpoint.

These items are not deferred by this ADR in the sense of §8 Q3/Q4 — they are *already decided* by existing Learn guidance plus the repo's instruction files. They are recorded here so the build PR does not have to re-derive them.

### Addendum — reconciler bootstrap contract (2026-04-19, editorial)

*Editorial note, not a decision change. Added after review of [ADR 0010](0010-automation-identity-subject-model.md) surfaced the "don't drop existing permissions on first run" concern. The reconciler contract lives in [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md); this addendum records the portal-role-group-specific corollary so the a.3 build PR does not have to re-derive it.*

1. **First run against a populated tenant is an export, not an apply.** `scripts/Deploy-PurviewRoleGroups.ps1` must implement the `-ExportCurrentState` switch required by the `First-run-against-an-existing-tenant contract` in `powershell.instructions.md`. The first invocation against the `contoso-lab` tenant (which already has portal-configured role-group membership) must be `-ExportCurrentState`, producing a populated `data-plane/purview-role-groups/role-groups.yaml`. That YAML is reviewed and merged as a PR **before** any `-Apply` run.
2. **`-Apply -PruneMissing` against an empty or skeleton YAML is a destructive operation.** Per [`.github/instructions/pre-commit.instructions.md`](../../.github/instructions/pre-commit.instructions.md), it requires the `destructive` PR label and explicit reviewer approval. The a.3 build PR must not enable it by default or in CI.
3. **The automation identity must be able to read what it manages.** For the export step to produce a complete YAML, the data-plane app registration (per [ADR 0010](0010-automation-identity-subject-model.md)) must hold read permission on every role group it will later reconcile. Exchange `Get-RoleGroupMember` requires the `View-Only Recipients` role or a superset; the build PR lists the minimum set explicitly.
4. **Export-time filtering is explicit, not silent.** When the automation identity lacks read on a role group, `-ExportCurrentState` must log the skipped role group with a named reason, not omit it silently. Silent omission would look like a legitimate empty state on the next `-Apply` run.

This addendum complements — not supersedes — the six sibling-repo learnings above. The ADR Decision, Scope, Consequences, Alternatives, and Citations sections remain untouched.

## Decision

1. **We will ship `scripts/Grant-PurviewRoleGroup.ps1` as Security & Compliance PowerShell-only today.** The script will use [`Connect-IPPSSession`](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) with [certificate-based app-only authentication](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) and call [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember), [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember), and [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember) to implement the GET → diff → act contract used elsewhere in the repo.
2. **The script will define a Graph extension point that is not called today.** A commented block (or a private function that throws `NotImplementedException`-shaped) documents the intended Graph path, the trigger condition for enabling it (the appearance of an Exchange, compliance, or `purview` provider on [`rbacApplication`](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication)), and the Learn references required when that day comes. No behavioral code on that path ships now.
3. **We will revisit this decision when Microsoft publishes an RBAC provider under `rbacApplication` that covers Purview portal role groups.** At that point a new ADR will supersede this one: the trigger is provider availability on Learn, not a calendar date. The hybrid direction from ADR 0008 resumes on that day.
4. **ADR 0008 is moved to Status `Superseded by 0009`.** Its historical content is preserved unchanged; the supersession note is added above its Status line. The ADR README table is updated in the same PR.

## Scope — what this ADR does *not* decide

Matching ADR 0008's narrow framing, the following adjacent decisions stay out of scope:

- **Certificate lifecycle and issuance.** Decided alongside [`docs/project-plan.md`](../project-plan.md) §8 Q4 (`scripts/New-AutomationIdentity.ps1`).
- **Exact Exchange Online role assignments** required by the S&C app-only identity. These will land in the `scripts/Grant-PurviewRoleGroup.ps1` build PR description and the module header, cited inline to Learn.
- **`Connect-IPPSSession` session re-use** across many-member runs. Script-implementation concern, not architectural.
- **The mapping from role-group display name → YAML key.** Belongs in the reconciler (`scripts/Deploy-PurviewRoleGroups.ps1`, tracked separately in the Wave 0 checklist).

## Consequences

**Easier.**

- The primitive works on day one against every portal role group. No synthetic "unsupported role group" error path. Lab smoke test passes against real role groups on the first run.
- One code path, one auth context, one set of error-handling semantics to maintain — not two. The complexity cost of the hybrid shell disappears until Graph coverage actually exists.
- The Graph extension point is documented in the script header, so the day a provider appears, the diff is additive — not a re-architecture.

**Harder.**

- Cert-based app-only authentication becomes the *only* path for portal role-group operations today, not a fallback for a minority. This moves [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 (managed identity > service principal > key-based auth) to a stronger relaxation than ADR 0008 anticipated. Justification: the single available API requires cert auth; the alternative is not shipping the primitive at all. The relaxation is scoped to this one primitive, and retires when a Graph provider lands.
- The cold-connect latency of `Connect-IPPSSession` (seconds per CI run) is on the critical path for every role-group change, not just a minority. Acceptable for the lab; must be called out in the script's runtime notes.
- Certificate rotation cadence matters immediately, not "eventually" — handled by §8 Q4 when `scripts/New-AutomationIdentity.ps1` lands.

**Unblocks.**

- §8 Q8 in [`docs/project-plan.md`](../project-plan.md), now correctly pointed at an ADR whose ship-order matches the API surface on Learn today.
- The three split Wave 0 portal-role-group checklist items — primitive, YAML, and reconciler — can now be built in sequence without a dead Graph code path.

**Does not unblock what it did not unblock before.** `scripts/New-AutomationIdentity.ps1` (§8 Q3, Q4) remains gated on its own ADRs; this ADR does not resolve them.

## Alternatives considered

- **Keep ADR 0008 and build a Graph-primary primitive with a 404 fallback.** Rejected — today's `rbacApplication` has no Purview / Exchange / compliance provider, so the 404 fallback fires on every call. The script would carry two code paths to use one.
- **Amend ADR 0008 in place.** Rejected — the ADR README's immutability rule ("ADRs are immutable once accepted. If a decision is reversed, write a new ADR that supersedes the old one — do not edit the old file in place") applies. ADR 0008's runtime framing ("Graph primary", "fallback on 404") is part of the accepted decision, not errata. Preserving it under supersession keeps the decision trail honest.
- **Graph-only with a throw-stub for role groups that don't have coverage.** Rejected — the stub throws for every portal role group today. Script is a no-op in the lab.
- **Defer — leave §8 Q8 open, block the Wave 0 role-group primitive.** Rejected — the same block rationale in ADR 0008 still applies; portal role groups are a top-level governance primitive and downstream waves assume it works.

## Citations

- [`rbacApplication` resource type](https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication) — "Currently `directory` and `entitlementManagement` are the two RBAC providers supported."
- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) — documents only the portal UI for adding/removing role-group members; no Graph endpoint.
- [Roles and role groups in the Microsoft Defender XDR and Microsoft Purview portals](https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/scc-permissions) — built-in role-group catalog.
- [Connect to Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) — `Connect-IPPSSession`, the shipped-today entry point.
- [App-only authentication for unattended scripts in Exchange Online / Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) — certificate-based app-only auth.
- [`Add-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember), [`Remove-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember), [`Get-RoleGroupMember`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember) — the S&C PowerShell cmdlets used by the shipped-today path.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — rule #2 (managed identity > service principal > key-based auth); rule #4 (least privilege).
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift-report contract the shipped primitive will conform to.
- [ADR 0008 — Portal role-group membership management API: hybrid, Microsoft Graph primary, Security & Compliance PowerShell fallback](0008-portal-role-group-api.md) — superseded by this ADR.
- [ADR 0002 — Microsoft Entra administrative units in this repo](0002-administrative-units.md) — adjacent ADR that established the declarative-reconciler + desired-state pattern used by this primitive.
