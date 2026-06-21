# 0022 — Microsoft Purview DSPM for AI authoring surface: no programmatic API; ship a read-only posture verifier

- **Status:** Accepted
- **Date:** 2026-05-17
- **Gates:** Adds open-question row Q11 in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs. Governs the desired-state shape of Wave 3b / [#75](../../issues/75) (`data-plane/dspm-ai/` policies + deploy script). Does not gate any other item.
- **Deciders:** @contoso

## Context

Wave 3b ([#75](../../issues/75)) is the DSPM-for-AI counterpart to the Wave 3a DSPM item that landed under [ADR 0021](0021-dspm-content-explorer-cadence.md). Both items follow the same posture-management shape — the lab does not author the dashboard, it authors the signal sources the dashboard consumes and the evidence trail that demonstrates the lab is exercising those signals over time.

The Wave 3b acceptance criteria as filed assumed a `Deploy-DSPMforAI.ps1` reconciler symmetrical to `Deploy-DSPM.ps1`: idempotent, `-WhatIf`-safe, `-PruneMissing`-aware, reading a `data-plane/dspm-ai/dspm-ai-config.yaml` desired-state file. That shape requires a programmatic authoring surface — a documented cmdlet, REST endpoint, or Microsoft Graph resource — that the reconciler can drive in `Create`, `Update`, and `Remove` modes against the live tenant `contoso.onmicrosoft.com`.

A repo-wide search of Microsoft Learn for that surface produced the following (all verified 2026-05-17):

- **[DSPM for AI overview](https://learn.microsoft.com/en-us/purview/dspm-for-ai)** — HTTP 200, 75 KB body; zero occurrences of `PowerShell`, `cmdlet`, `graph.microsoft`, `REST API`, or `programmat`. The page documents an "Activate Microsoft Purview for AI" experience that is portal-driven and creates instances of already-shipped surfaces (default DLP, IRM, Communication Compliance, and audit policies). The activation is described as a one-click portal action.
- **[Considerations for deploying Microsoft Purview AI controls](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations)** — HTTP 200, 70 KB body; zero occurrences of `PowerShell`, `cmdlet`, `graph.microsoft`, `REST API`, or `programmat`. The page enumerates licensing, role, and scoping considerations; all configuration guidance is portal-only.
- **[Permissions for Microsoft Purview AI features](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions)** — HTTP 200, 57 KB body; zero occurrences of `PowerShell`, `cmdlet`, `graph.microsoft`, `REST API`, or `programmat`. Role assignment is documented for the Microsoft Purview portal role-group surface, which is already covered by [`Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) per [ADR 0009](0009-portal-role-group-api-ship-order.md).
- **[Get started with Microsoft Purview AI (older entry point)](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview)** — HTTP 200, 68 KB body; zero occurrences of `PowerShell`, `cmdlet`, `graph.microsoft`, `REST API`, or `programmat`. Same activation pattern; portal-only.
- **Speculative cmdlet probes** — `New-AIPolicy` (Exchange PowerShell) returns HTTP 404. No cmdlet named `*DSPMforAI*`, `*AICompliance*`, or `*CopilotPolicy*` is indexed on Microsoft Learn as of 2026-05-17.
- **Speculative Graph probes** — `/graph/api/resources/security-aiinteraction` returns HTTP 404. The Graph `security` namespace overview ([learn.microsoft.com/en-us/graph/api/resources/security-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview), already cited in [ADR 0019](0019-cc-graph-pivot.md) §Context) contains zero occurrences of `dspm`, `aiInteraction`, or `copilotPolicy`.

Net: **Microsoft Learn currently documents no programmatic authoring API for DSPM for AI.** The only surface Learn points at is the "Activate Microsoft Purview for AI" one-click portal action, which itself fans out into already-shipped surfaces (DLP, IRM, Communication Compliance, audit) that this repo already covers in their respective waves.

This finding mirrors — and partly cascades from — [ADR 0019](0019-cc-graph-pivot.md), which ratified `policies: []` for Communication Compliance for the same reason: Learn documents no authoring API. The "Activate Microsoft Purview for AI" path materializes a default Communication Compliance policy among other artifacts; that default policy inherits the same authoring-surface gap.

## Decision

**We will not ship a `Deploy-DSPMforAI.ps1` reconciler in Wave 3b.** Instead, the wave ships a read-only posture verifier symmetrical in spirit to (but narrower in scope than) the Wave 3a apply script. Specifically:

1. **Ship [`data-plane/dspm-ai/dspm-ai-config.yaml`](../../data-plane/dspm-ai/dspm-ai-config.yaml)** as a scope-and-cadence descriptor only. The file declares (a) which sensitivity labels are in scope for DSPM-for-AI signal reporting, (b) which workloads (Microsoft 365 Copilot, Copilot for Security, Copilot Studio agents the lab actually uses) are in scope, and (c) the posture-check cadence. The file deliberately omits a `policies:` field; there is no documented surface to drive policy authoring against. The header comment in the file states this, citing this ADR.

2. **Ship [`scripts/Test-DSPMforAIPosture.ps1`](../../scripts/Test-DSPMforAIPosture.ps1)** as a **read-only** verifier (not `Deploy-*.ps1`). The script performs zero tenant writes. Its job is to assert that the prerequisites the "Activate Microsoft Purview for AI" portal action depends on are live: unified audit log enabled (already covered by [`Enable-UnifiedAuditLog.ps1`](../../scripts/Enable-UnifiedAuditLog.ps1) and Wave 0), the role groups documented in [Permissions for Microsoft Purview AI features](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions) exist (already managed by [`Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1)), and the sensitivity labels listed in `dspm-ai-config.yaml` are published.

3. **Zero tenant writes from Wave 3b.** Every authoring step that the DSPM-for-AI dashboard depends on (audit, role groups, labels, label policies, DLP defaults, IRM defaults) has already shipped in its own wave under its own reconciler. Wave 3b does not duplicate any of that — it only verifies that the prerequisites are intact and the scope file is internally consistent.

4. **Add open-question row Q11 to [`docs/project-plan.md`](../project-plan.md) §8** as the standing watch-list for this question. The row stays unticked until any watch-list trigger below fires, at which point it is closed and superseded by a new ADR that scopes the reconciler.

5. **Re-open triggers (the watch list).** This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:
   - A `dspmForAi`, `aiInteraction`, `copilotPolicy`, or similarly-named resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0).
   - Either [DSPM for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai) or [Considerations for deploying Microsoft Purview AI controls](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations) gains a programmatic-authoring section (Graph, REST, or named PowerShell cmdlet).
   - A Microsoft-published reference repo (under `github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a DSPM-for-AI policy authoring sample.
   - The cascade from [ADR 0019](0019-cc-graph-pivot.md) reverses (i.e., Communication Compliance gains a documented authoring surface), since the AI default-policy fan-out includes a CC instance.

6. **No undocumented surface.** We will not consume the Microsoft Purview portal's internal REST traffic by reverse-engineering the browser dev-tools network tab. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and would break on any backend revision without warning. This restriction is identical to the one in [ADR 0019](0019-cc-graph-pivot.md) §6.

## Consequences

**Easier:**

- **Wave 3b unblocks.** [#75](../../issues/75) ships within its current sprint by descoping the unbuildable reconciler and shipping the verifier the surface actually supports.
- **No moving target.** With Q11 ratified, future PRs in `data-plane/dspm-ai/` are limited to the watch-list triggers above. The lab is not committed to revisiting this every quarter.
- **Symmetry with the rest of the repo.** Read-only verifiers already exist for the audit log, sensitivity labels, and label policies; Wave 3b adds one more entry in that shape rather than inventing a new pattern.
- **The repo stays inside its grounding rule.** Every cited Microsoft Learn URL in this ADR was fetched and verified on 2026-05-17 before the ADR was committed.

**Harder:**

- **No Git-tracked desired state for DSPM-for-AI policies.** The "Activate Microsoft Purview for AI" action is performed in the portal once; its output (default DLP / IRM / CC policy instances) is governed by those products' own reconcilers if and when they gain authoring surfaces. The activation itself is not represented in this repo.
- **Wave 3b's Progress-checklist row is technically complete on the verifier shape, but its long-term value is read-only assurance rather than declarative apply.** This is a deliberate scope shift and is captured here so it does not surface later as a surprise.
- **A future operator that needs DSPM-for-AI policies in code will have to either re-open this ADR after a watch trigger fires, or write a new ADR arguing for a portal-internal REST consumer despite the rule in §6.** This ADR neither commits to nor pre-rejects the latter; it only requires that path be argued in its own ADR.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Trivially satisfied — the verifier authenticates with the existing workload identity; no new credential is introduced.
- **#4 (least privilege).** Upheld. The verifier requires the role-group membership documented in [Permissions for Microsoft Purview AI features](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions) for read-only checks, no Authoring role.
- **#9 (idempotent, reversible, auditable).** Upheld. A read-only verifier is the most idempotent and most auditable shape available for a surface without a documented write API.

## Alternatives considered

1. **Ship `Deploy-DSPMforAI.ps1` against an undocumented authoring surface (Microsoft Purview portal internal REST).** Rejected. Same reasoning as [ADR 0019](0019-cc-graph-pivot.md) §6: violates the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and breaks on any backend revision without warning.

2. **Pivot to Microsoft Graph.** Rejected. The Graph `security` namespace overview returns zero occurrences of any DSPM-for-AI resource as of 2026-05-17 (verified by fetch). Adopting a Graph endpoint we cannot cite on Learn would violate the grounding rule.

3. **Pivot to a speculative Exchange PowerShell cmdlet (e.g., `New-AIPolicy`).** Rejected. The reference URL returns HTTP 404 on Learn — the cmdlet is not documented and we have no evidence the service exposes it.

4. **Treat DSPM for AI as out of scope for this repository (mirror [ADR 0018](0018-ediscovery-scope.md)'s eDiscovery decision).** Rejected. eDiscovery is *case-shaped* and genuinely does not fit a policy-as-code model. DSPM for AI *is* posture-shaped (standing org-wide signal reporting, rare to change, identifier-light) and *would* fit policy-as-code the day a documented authoring surface exists. Descoping the entire wave would discard the verifier shape and would foreclose a future re-enable. Deferral is the lower-regret choice.

5. **Do nothing — leave [#75](../../issues/75) open with no ADR.** Rejected. The Open-question ADRs sub-section in the Progress checklist exists precisely so that questions get decisive answers and the cadence does not stall. "Decisive answer" includes "the answer is *defer the reconciler, ship the verifier*, and here is what would re-open the question".

## Citations

- **[Microsoft Purview Data Security Posture Management (DSPM) for AI](https://learn.microsoft.com/en-us/purview/dspm-for-ai)**
  Fetch date: 2026-05-17
  > "Activate Microsoft Purview for AI. ... Use the recommended one-click policies to create default policies that protect your organization's data from AI risks."
  Cited to confirm the activation surface is portal-only and creates instances of already-shipped policy products. Body contains zero occurrences of `PowerShell`, `cmdlet`, `graph.microsoft`, `REST API`, or `programmat`.
- **[Considerations for deploying Microsoft Purview AI controls](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations)**
  Fetch date: 2026-05-17
  Cited to confirm zero programmatic-authoring mentions across the configuration-guidance page.
- **[Permissions for Microsoft Purview AI features](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions)**
  Fetch date: 2026-05-17
  Cited to confirm role assignment is documented for the Microsoft Purview portal role-group surface — already managed by [`Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) per [ADR 0009](0009-portal-role-group-api-ship-order.md).
- **[Get started with Microsoft Purview AI (older entry point)](https://learn.microsoft.com/en-us/purview/ai-microsoft-purview)**
  Fetch date: 2026-05-17
  Cited to confirm the older entry-point page also documents only portal activation; surfaces the same set of fan-out products.
- **[Microsoft Graph security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)**
  Fetch date: 2026-05-17 (originally cited 2026-05-16 in [ADR 0019](0019-cc-graph-pivot.md))
  Cited to confirm no DSPM-for-AI resource is documented in the Graph `security` namespace.
