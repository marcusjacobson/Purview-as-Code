# 0018 — eDiscovery-as-code: out of scope for this repository

- **Status:** Accepted
- **Date:** 2026-05-16
- **Gates:** Open-question ADR Q6 ([#77](../../issues/77)); descopes Wave 2f ([#82](../../issues/82)) from the Progress checklist.
- **Deciders:** @contoso

## Context

The Open-question ADRs sub-section of the project plan carried Q6 — "Is eDiscovery (cases, holds, exports) in scope for this lab's data-plane-as-code?" — as the gate for Wave 2f. Wave 2f's planned shape ([#82](../../issues/82)) was `data-plane/ediscovery/cases.yaml` plus `Deploy-eDiscovery.ps1`, mirroring the YAML-plus-reconciler pattern used by every other Wave 1 and Wave 2 item.

Microsoft Purview eDiscovery covers a fixed object set documented at the [Microsoft Purview eDiscovery overview](https://learn.microsoft.com/en-us/purview/edisc) and [Get started with the new Microsoft Purview eDiscovery](https://learn.microsoft.com/en-us/purview/ediscovery-get-started): **cases** (containers for a single legal / HR / regulatory matter), **custodians** (named users with their mailbox / OneDrive / Teams / SharePoint associations), **non-custodial data sources**, **holds** (in-place preservation rules active for the case duration), **searches** (KQL queries that pull content into the case), **review sets** (working copies of collected content with near-dup / threading / predictive coding), **tags** / reviewer annotations, and **exports** (PST / native output with a chain-of-custody manifest). The Microsoft Graph eDiscovery API exposes most of those objects under `/security/cases/ediscoveryCases` and children (see [Microsoft Graph eDiscovery resource model — ediscoveryCase](https://learn.microsoft.com/en-us/graph/api/resources/security-ediscoverycase) and the [Use the Microsoft Graph eDiscovery API](https://learn.microsoft.com/en-us/graph/api/resources/security-ediscovery-overview) landing page). The same surface is reachable from Security & Compliance PowerShell through `Connect-IPPSSession` and the case / hold / search cmdlets documented in the [Exchange and Security & Compliance PowerShell module reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/), which this repo already uses for retention, DLP, IRM, and Communication Compliance.

The repo's policy-as-code thesis (declared in §1 of [`docs/project-plan.md`](../project-plan.md)) is **declarative standing policy + idempotent reconciler + Git as the audit trail**. Every other Wave 1 and Wave 2 item conforms: sensitivity labels, label / auto-label policies, audit retention, DLP, retention and records, IRM, and Communication Compliance are all standing org-wide rules that change rarely, contain no individual-identifier payload, and are appropriate to review in a PR. eDiscovery objects do not have any of those properties. The question Q6 asked is whether to extend the policy-as-code pattern into a domain whose state model is **transactional case management**, where each object is owned by a named matter and a reviewer workflow rather than by a standing policy.

## Decision

**We will treat eDiscovery (Standard and Premium) as out of scope for this repository's data-plane-as-code surface.** This decision applies specifically to case-state objects (cases, custodians, holds, searches, review sets, tags, exports). It is bounded as follows:

1. **No `data-plane/ediscovery/` folder, no `cases.yaml`, no `Deploy-eDiscovery.ps1`.** Wave 2f ([#82](../../issues/82)) is closed as `wontfix` with a link to this ADR. The Progress checklist row for 2f is marked complete with an out-of-scope note pointing here.

2. **The governance pieces of eDiscovery that are standing policy stay in scope where they already are.** Specifically:
   - The `eDiscoveryManager` portal role group and its members are managed by Wave 0 / [ADR 0009](0009-portal-role-group-api-ship-order.md) through `data-plane/purview-role-groups/role-groups.yaml` and `Deploy-PurviewRoleGroups.ps1`.
   - The unified audit log records eDiscovery activity ([Audit log activities](https://learn.microsoft.com/en-us/purview/audit-log-activities)) and is enabled by Wave 0 audit-log readiness; audit retention for eDiscovery activities falls under Wave 2a `data-plane/audit/retention-policies.yaml`.

   Neither of those concerns reopens Wave 2f.

3. **Carve-out for future, narrower work.** This ADR does not pre-decide a separate, smaller question: "Should the repository codify reusable **hold and search query templates** that an operator could apply by hand when opening a real case?" Templates are identifier-free, policy-shaped, and rare-to-change, so the principal objections in §3 below do not apply to them. If a real need surfaces, that question will be filed as its own Open-question ADR with its own gate and a new project-plan row. This ADR neither commits to nor forbids that future work.

4. **Project-plan touch-ups land in this PR.** The Progress checklist's `[#82]` row is ticked with an out-of-scope note. Q6 in the Open-question ADRs sub-section is ticked and points here. The §3 wave-ordering table removes "eDiscovery" from the Wave 2 solutions cell and adds it to the §3 "Solutions not in scope" list with a back-link. The §4 dependency matrix removes the Wave 2f row. The §5 Out of scope list gains a bullet for eDiscovery-as-code. The line-34 cadence example that used Q6 / 2f is replaced with the still-open Q7 / 3b pairing so the example stays live.

## Consequences

**Easier:**

- **Wave 2 closes after 2e.** Audit retention, DLP, Data Lifecycle Management + Records, IRM, and Communication Compliance remain the full Wave 2 surface. There is no trailing item blocked on an ADR.
- **No real-identifier exfiltration risk added to the repo.** Custodian YAML would have to name real users by UPN, list real SharePoint site URLs, and embed real KQL strings, all of which would conflict with [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) and the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).
- **No privilege / discoverability surface added.** Cases are commonly opened in response to litigation, internal investigations, or regulatory matters where the existence of the case is itself privileged or restricted. The repository — even private — is a discoverable artifact; mirroring case state into it would broaden the discovery surface and create privilege-waiver risk.
- **No chain-of-custody mismatch.** The evidentiary record for an eDiscovery export rests on the Purview audit trail and the export manifest documented under [Audit logs for eDiscovery activities](https://learn.microsoft.com/en-us/purview/audit-search). Git history is not an evidentiary substitute.
- **Reconciler shape stays consistent across all in-scope items.** All `Deploy-*.ps1` scripts in this repo follow "read desired → diff → apply → re-read." Cases break that contract because reviewer state (added tags, expanded holds, refined searches) is intentional drift over the case lifetime, not error to flatten.

**Harder:**

- **No coverage of eDiscovery configuration as code.** If Microsoft introduces a tenant-wide eDiscovery configuration surface that genuinely is standing policy (today the relevant settings are mostly per-case or in-portal), this repository will not pick it up automatically. The owner accepts that cost.
- **Operators run eDiscovery cases in the Microsoft Purview portal and Security & Compliance PowerShell directly.** This repo does not offer a helper script. The carve-out in §2 above leaves room to add reusable templates later if friction surfaces.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Trivially satisfied — nothing eDiscovery-shaped lands in source.
- **#4 (least privilege).** Reinforced — the `eDiscoveryManager` role group stays managed via the existing Wave 0 surface; this ADR does not introduce any new role assignments.
- **#9 (idempotent, reversible, auditable).** Reinforced — by declining to codify a domain whose state model is non-idempotent, the repo avoids shipping a reconciler that could silently revert reviewer state.

## Alternatives considered

1. **In scope, full surface (cases + custodians + holds + searches + review sets).** Rejected. Every object in the surface carries either real identifiers (custodian UPNs, SharePoint site URLs), privileged subject matter (case names, KQL terms), or workflow state (review-set tags) that fails the repo's identifier-boundary and reconciler-shape rules. The fact that the original Wave 2f file name was `cases.yaml` is itself a tell: a case is a work item, not configuration.

2. **In scope, templates only (hold templates + search query templates, no case state).** Deferred, not rejected. Templates are identifier-free and policy-shaped and would not violate the rules in §1 above. The owner does not have a current need; filing a speculative project-plan item now would consume agent and review bandwidth on something nobody is asking for. The carve-out in Decision §3 leaves the door open.

3. **Do nothing — leave Q6 open.** Rejected. The Progress checklist's discipline depends on open questions being resolved promptly so they do not become a backlog. Wave 2f is the only checklist row blocked on Q6; resolving Q6 with a decisive direction unblocks the rest of the checklist's cadence rule.

## Citations

- **[Microsoft Purview eDiscovery overview](https://learn.microsoft.com/en-us/purview/edisc)**
  Fetch date: 2026-05-16
  > "eDiscovery is the process of identifying and delivering electronic information that can be used as evidence in legal cases."
- **[Get started with the new Microsoft Purview eDiscovery](https://learn.microsoft.com/en-us/purview/ediscovery-get-started)**
  Fetch date: 2026-05-16
  > "eDiscovery cases are containers for the searches, holds, reviews, and exports associated with a single legal matter."
- **[Microsoft Graph eDiscovery resource model — ediscoveryCase](https://learn.microsoft.com/en-us/graph/api/resources/security-ediscoverycase)**
  Fetch date: 2026-05-16
  Defines the case / custodian / search / reviewSet / tag / operation object hierarchy and confirms the case-centric (not policy-centric) state model.
- **[Use the Microsoft Graph eDiscovery API](https://learn.microsoft.com/en-us/graph/api/resources/security-ediscovery-overview)**
  Fetch date: 2026-05-16
  Landing page for the Graph eDiscovery surface; cited to confirm that an API does exist (so the decision is one of fit, not feasibility).
- **[Audit log activities — eDiscovery](https://learn.microsoft.com/en-us/purview/audit-log-activities)**
  Fetch date: 2026-05-16
  Confirms the unified audit log is the evidentiary trail for eDiscovery operations; the reason Git history is not a substitute.
- **[Exchange and Security & Compliance PowerShell module reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/)**
  Fetch date: 2026-05-16
  Houses `New-ComplianceCase`, `New-CaseHoldPolicy`, `New-CaseHoldRule`, `New-ComplianceSearch`, `New-ComplianceSearchAction`. Cited to confirm the second API surface exists and is the same family this repo already consumes for retention / DLP / IRM / Communication Compliance.
- [ADR 0009](0009-portal-role-group-api-ship-order.md) — keeps `eDiscoveryManager` role-group membership in scope under Wave 0 regardless of this decision.
- [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) — identifier-boundary rule applied in §3 alternatives.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries" section cited in §3 alternatives.
