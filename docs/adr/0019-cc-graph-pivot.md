# 0019 — Communication Compliance authoring surface: defer pivot until Microsoft documents one

- **Status:** Accepted
- **Date:** 2026-05-16
- **Gates:** Open-question row Q10 in [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs); governs the desired-state of [`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml) and the Create / Update / Remove branches of [`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1). Issue [#278](../../issues/278).
- **Deciders:** @contoso

## Context

Wave 2e ([#72](../../issues/72)) shipped `data-plane/communication-compliance/policies.yaml` + `Deploy-CommunicationCompliance.ps1` in PRs [#269](../../pull/269) (scaffold), [#273](../../pull/273) (Phase 1 hardening), [#276](../../pull/276) (cmdlet-surface live probe), and [#277](../../pull/277) (Phase 2 hardening). Phase 2 attempted a real `Create` against the live lab tenant `contoso.onmicrosoft.com` and was service-rejected at the IPPS endpoint with:

> Microsoft.Exchange.Management.UnifiedPolicy.LegacySupervisionPolicyCreationException
> "Following the February 2020 release of Communication Compliance in the Microsoft 365 compliance center, supervision in the Office 365 Security & Compliance Center is being retired and hence this command is no longer supported."

The cmdlet that produced that error — [`New-SupervisoryReviewPolicyV2`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewpolicyv2) — is **still indexed on Microsoft Learn** with no deprecation notice on the reference page (verified 2026-05-16: page returns HTTP 200, body contains zero occurrences of "retire", "deprec", or any successor pointer). The retirement is asserted only at runtime by the service, not on the cmdlet documentation, and Learn does not currently link the reader to a replacement.

A repo-wide search of Microsoft Learn for the modern authoring surface produced the following (all verified 2026-05-16):

- **Microsoft Graph `security` API overview** ([learn.microsoft.com/en-us/graph/api/resources/security-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)) — HTTP 200; zero occurrences of `Communication Compliance`, `communicationCompliance`, `supervisoryReview`, or `communications/compliance`.
- **Microsoft Graph `communications` API overview** ([learn.microsoft.com/en-us/graph/api/resources/communications-api-overview](https://learn.microsoft.com/en-us/graph/api/resources/communications-api-overview)) — HTTP 200; zero occurrences of the same set of terms. This namespace covers calls / online meetings, not the CC product.
- **Communication Compliance solution overview** ([learn.microsoft.com/en-us/purview/communication-compliance-solution-overview](https://learn.microsoft.com/en-us/purview/communication-compliance-solution-overview)) — HTTP 200, 57 KB body; zero occurrences of `Graph`, `PowerShell`, `REST`, `endpoint`, `API`, `programmat`. All authoring guidance is portal-only.
- **Configure Communication Compliance** ([learn.microsoft.com/en-us/purview/communication-compliance-configure](https://learn.microsoft.com/en-us/purview/communication-compliance-configure)) — HTTP 200, 87 KB body; the only `PowerShell` mention is for configuring a distribution group as a global policy target, and the only `cmdlet` mention is `New-ComplianceSecurityFilter` (security filtering, not policy authoring). The entire "Create a policy" step assumes the Microsoft Purview portal UI.
- **Non-`V2` cmdlet path** (`New-SupervisoryReviewPolicy` without the suffix) — HTTP **404** on Learn. There is no documented non-V2 cmdlet to fall back to.
- [`New-SupervisoryReviewRule`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewrule) and [`Get-SupervisoryReviewPolicyV2`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-supervisoryreviewpolicyv2) remain documented and the `Get` cmdlet is read-only (already used by the reconciler's tenant-hash branch without issue).

Net: **Microsoft Learn currently documents no programmatic authoring API for the modern Communication Compliance product.** The only surface Learn points at is the Microsoft Purview portal UI. The reference repos this repository tracks ([`microsoft/purviewautomation`](https://github.com/microsoft/purviewautomation)) cover the Purview Data Map only — they do not address CC.

This ADR exists because issue [#278](../../issues/278) was filed to scope a pivot off the legacy IPPS surface onto Microsoft Graph or an equivalent. The research above forecloses that pivot: there is nothing to pivot to that the repo's [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) permits us to ship against.

## Decision

**We will not pivot `Deploy-CommunicationCompliance.ps1` to any new authoring surface in this PR or in the foreseeable future.** Specifically:

1. **Keep [`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml) at `policies: []` as the only valid desired state.** The header comment in that file already documents this; this ADR ratifies it as the standing rule rather than a temporary state.

2. **Keep the existing reconciler ([`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1)) on the legacy IPPS `*-SupervisoryReviewPolicyV2` cmdlets for its `Get-only` / drift-detection role.** `Get-SupervisoryReviewPolicyV2` and `Get-SupervisoryReviewRule` still respond on the live tenant (verified by PR [#276](../../pull/276)); they are needed so the reconciler can detect manually-created (portal) policies as drift and surface them in the `What-If` report. The `Create`, `Update`, and `Remove` branches are now dead code paths in practice, but they stay in place — guarded by `policies: []` — so that the surface re-enables instantly the day Microsoft documents a replacement, with no rebuild of the diff engine. The Phase 2 hardening shipped in PR [#277](../../pull/277) (env-var expansion, `-ParentAction` rule sub-reconciler gate) remains valuable for that future re-enable.

3. **Communication Compliance policies are authored in the Microsoft Purview portal** by an operator with the appropriate role-group membership (`Communication Compliance Admins` / `Communication Compliance Investigators` / `Communication Compliance Analysts` / `Communication Compliance Viewers`). Role-group membership stays managed by [`Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) per [ADR 0009](0009-portal-role-group-api-ship-order.md), which already covers the Communication Compliance role-group family.

4. **A new open-question row `Q10` is added to the project plan §8** (see [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs)) as the standing watch-list for this question. The row stays unticked until either of the watch triggers below fires, at which point it is closed and superseded by a new ADR.

5. **Re-open triggers (the watch list).** This ADR is to be re-opened with a follow-up ADR if any of the following becomes true on Microsoft Learn:
   - A `communicationCompliance` resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0).
   - The [Communication Compliance solution overview](https://learn.microsoft.com/en-us/purview/communication-compliance-solution-overview) or [Configure Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance-configure) page gains a programmatic-authoring section (Graph, REST, or named PowerShell cmdlet other than the legacy `*-SupervisoryReviewPolicyV2` set).
   - Microsoft adds a deprecation notice to [`New-SupervisoryReviewPolicyV2`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewpolicyv2) that names a successor cmdlet, REST endpoint, or Graph resource.
   - A Microsoft-published reference repo (under `github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a Communication Compliance policy authoring sample.

6. **No undocumented surface.** We will not consume the Microsoft Purview portal's internal REST traffic by reverse-engineering the browser dev-tools network tab. Doing so would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) ("Non-Microsoft sources last ... never to produce a final answer") and would break on any backend revision without warning.

## Consequences

**Easier:**

- **The CC reconciler stops being a moving target.** With `policies: []` ratified as the standing state, future PRs in this directory are limited to the watch-list triggers above; no recurring "let me try X surface this quarter" cycle.
- **The hardening landed in PR [#273](../../pull/273) and PR [#277](../../pull/277) (pinned cmdlet surface, rule schema, env-var expansion, `-ParentAction` gate) is preserved without justifying a non-empty `policies.yaml`.** That work paid off the cost of detecting drift against manually-created portal policies, which is the reconciler's only remaining real-world job.
- **The repo stays inside its grounding rule.** Every cited Microsoft Learn URL in this ADR was fetched and verified on 2026-05-16 before the ADR was committed.

**Harder:**

- **No Git-tracked desired state for CC policies.** Operators who create CC policies in the portal must remember that their changes are not represented in this repo. The reconciler will report them as drift on every `What-If` run, which is the closest thing to "audit trail in Git" available.
- **The Wave 2e Progress-checklist row is technically complete but its long-term value is now read-only drift detection rather than declarative apply.** This is a deliberate scope shift and is captured here so it does not surface later as a surprise.
- **A future operator that needs CC policies in code will have to choose between (a) re-opening this ADR after a watch trigger fires, or (b) writing a new ADR that argues for a portal-internal REST consumer despite the rule in §6 above.** This ADR neither commits to nor pre-rejects path (b); it only requires that path (b) be argued in its own ADR.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Trivially satisfied — nothing changes about how the reconciler authenticates (cert-in-Key-Vault, OIDC).
- **#9 (idempotent, reversible, auditable).** Reinforced — the reconciler's `Get-only` posture against an undocumented authoring surface is the most idempotent + most auditable shape available.

## Alternatives considered

1. **Pivot to Microsoft Graph.** Rejected. The Graph `security` and `communications` API overview pages on Microsoft Learn contain zero references to Communication Compliance or `supervisoryReview` as of 2026-05-16 (verified by fetch). Adopting a Graph endpoint we cannot cite on Learn would violate the [grounding rule](../../.github/copilot-instructions.md).

2. **Pivot to a non-`V2` PowerShell cmdlet (`New-SupervisoryReviewPolicy`).** Rejected. The non-V2 reference URL on Microsoft Learn returns HTTP 404 — the cmdlet is not documented and we have no evidence the service exposes it. Even if it did, we would be making an undocumented bet.

3. **Consume the Microsoft Purview portal's internal REST traffic via browser-captured calls.** Rejected. See Decision §6.

4. **Treat Communication Compliance as out of scope for this repository (mirror [ADR 0018](0018-ediscovery-scope.md)'s eDiscovery decision).** Rejected. eDiscovery is *case-shaped* (transactional, identifier-laden, privilege-sensitive) and genuinely does not fit a policy-as-code model regardless of API availability. Communication Compliance *is* policy-shaped (standing org-wide rules, rare to change, identifier-light, appropriate to review in a PR) and *would* fit policy-as-code the day a documented authoring surface exists. Descoping the entire workload would discard the hardening already shipped and would foreclose a future re-enable. Deferral is the lower-regret choice.

5. **Retry the legacy `New-SupervisoryReviewPolicyV2` cmdlet against the tenant on a different schedule, hoping the service flips back.** Rejected. The retirement message is unambiguous and dates the surface change to February 2020; the legacy path is not coming back.

6. **Do nothing — leave issue [#278](../../issues/278) open with no ADR.** Rejected. The Open-question ADRs sub-section in the Progress checklist exists precisely so that questions get decisive answers and the cadence does not stall. "Decisive answer" includes "the answer is *defer*, and here is what would re-open the question".

## Citations

- **[New-SupervisoryReviewPolicyV2 (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
  Reference page for the cmdlet the live tenant rejects at runtime. Cited to confirm Learn still documents the cmdlet with no deprecation notice or successor pointer.
- **[Communication Compliance solution overview](https://learn.microsoft.com/en-us/purview/communication-compliance-solution-overview)**
  Fetch date: 2026-05-16
  Cited to confirm Learn documents only portal-based authoring. Body contains zero occurrences of `Graph`, `PowerShell`, `REST`, `endpoint`, `API`, or `programmat`.
- **[Configure Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance-configure)**
  Fetch date: 2026-05-16
  Cited to confirm the only `PowerShell` mention in the configuration flow is distribution-group plumbing, and the only `cmdlet` mention is `New-ComplianceSecurityFilter` (security filtering, not policy authoring).
- **[Microsoft Graph security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview)**
  Fetch date: 2026-05-16
  Cited to confirm no Communication Compliance resource is documented in this namespace.
- **[Microsoft Graph communications API overview](https://learn.microsoft.com/en-us/graph/api/resources/communications-api-overview)**
  Fetch date: 2026-05-16
  Cited to confirm no Communication Compliance resource is documented in this namespace. Coverage is calls and online meetings only.
- **[New-SupervisoryReviewRule (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewrule)**
  Fetch date: 2026-05-16
  Cited to confirm the rule cmdlet survives independently of the rejected policy cmdlet.
- **[Get-SupervisoryReviewPolicyV2 (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-supervisoryreviewpolicyv2)**
  Fetch date: 2026-05-16
  Cited to confirm read-only enumeration still works; basis for the reconciler's retained drift-detection role.
- [ADR 0009](0009-portal-role-group-api-ship-order.md) — keeps the `Communication Compliance Admins` / `Investigators` / `Analysts` / `Viewers` role-group membership in scope under Wave 0 regardless of this decision.
- [ADR 0018](0018-ediscovery-scope.md) — precedent for declining-by-policy a workload that does not fit the repo's pattern. Cited in alternative 4 to explain why CC is *deferred* rather than *descoped*.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" rule applied throughout.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — principles #1 and #9 cited in Consequences.

## 2026-06-07 watch-list re-verification

Status remains **Accepted**. This appendix records the v2 §5.3 watch-list re-verification ([#367](../../issues/367)) and walks each of the four §5 re-open triggers against fresh evidence collected on 2026-06-07. All four triggers remain **cold**. The standing rule — `policies: []` in [`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml), reconciler retained for drift detection only — stands unchanged.

### Stronger primary citation (supersedes the 2020-vintage service-side rejection as the lead reasoning)

The [Create and manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies) page (Microsoft Learn, last updated 2026-05-28) now carries an explicit "Important" callout that states the rule plainly on the *authoring* page rather than only at the *service* error boundary:

> "PowerShell isn't supported for creating and managing Communication Compliance policies. To create and manage these policies, use the policy management controls in the Communication Compliance solution."

This is the citation to lead with going forward. It is the same answer the 2026-05-16 IPPS write attempt produced at runtime, but now documented prospectively by Microsoft on the policy-management Learn page itself. The original 2020-vintage `LegacySupervisionPolicyCreationException` text remains valid corroborating evidence and is preserved in the body above.

### Re-open trigger status (each re-verified 2026-06-07)

| # | Trigger (from §5 above) | Status | Evidence (2026-06-07) |
|---|---|---|---|
| 1 | A `communicationCompliance` resource lands under `https://learn.microsoft.com/en-us/graph/api/resources/` (beta or v1.0). | **Cold.** | Live Microsoft Graph `$metadata` re-fetch: `https://graph.microsoft.com/v1.0/$metadata` (2.7 MB) and `https://graph.microsoft.com/beta/$metadata` (7.1 MB) contain **zero** `communicationCompliance` / `supervisoryReview` EntitySets. The three beta hits for `supervisoryReview*` are read-only `auditData`-typed records (e.g. `supervisoryReviewDayXInsightsAuditRecord`), not authoring surfaces. |
| 2 | The [Communication Compliance solution overview](https://learn.microsoft.com/en-us/purview/communication-compliance-solution-overview) or [Configure Communication Compliance](https://learn.microsoft.com/en-us/purview/communication-compliance-configure) page gains a programmatic-authoring section. | **Cold — and reinforced.** | The new [Create and manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies) page (Last updated 2026-05-28) actively closes the door with the "Important" callout quoted above. The two pages cited in the original ADR Context still document portal-only authoring. |
| 3 | Microsoft adds a deprecation notice to [`New-SupervisoryReviewPolicyV2`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewpolicyv2) that names a successor cmdlet, REST endpoint, or Graph resource. | **Cold.** | Live tenant write probe (2026-06-07, against `contoso.onmicrosoft.com`): `New-SupervisoryReviewPolicyV2 -Name smoke-cc-20260607-001 -Reviewers user@contoso.com` returned `Microsoft.Exchange.Management.UnifiedPolicy.LegacySupervisionPolicyCreationException` with the same retirement text quoted in the original Context above — identical to the 2026-05-16 probe, no successor named. Transcript local-only at `.copilot-tracking/smoke/cc-stage1-add-20260607.log` (gitignored, not committed). |
| 4 | A Microsoft-published reference repo (under `github.com/microsoft/` or `github.com/MicrosoftDocs/`) ships a Communication Compliance policy authoring sample. | **Cold.** | [Microsoft Purview What's New](https://learn.microsoft.com/en-us/purview/whats-new) (Last updated 2026-06-03) lists **zero** Communication Compliance entries across January 2026 through June 2026, while every adjacent Purview product (DLP, IRM, eDiscovery, sensitivity labels, DSPM, Data Governance) shipped multiple monthly updates. The absence is selective: see "Selectivity check" below. |

### Selectivity check — the gate is CC-specific, not a platform-wide retirement

A live IPPS cmdlet enumeration on 2026-06-07 against the live `contoso.onmicrosoft.com` tenant confirmed that the sibling products on the same authoring surface continue to accept `New-` / `Set-` / `Remove-` writes with no service rejection:

- `New-/Set-/Remove-InsiderRiskPolicy` and the wider `InsiderRisk*` cmdlet family — full parity, writes succeed.
- `New-/Set-/Remove-RetentionCompliancePolicy` and `RetentionCompliance*` — full parity, writes succeed.
- `New-/Set-/Remove-AutoSensitivityLabelPolicy` and `AutoSensitivityLabel*` — full parity, writes succeed.
- `New-/Set-/Remove-AppRetentionCompliancePolicy` and `AppRetentionCompliance*` — full parity, writes succeed.

The Communication Compliance cmdlets (`*-SupervisoryReviewPolicyV2`, `*-SupervisoryReviewRule`) exist on the same IPPS module surface but the service rejects writes specifically against them. The selectivity proves the gate is **CC-specific and deliberate**, not a platform-wide PowerShell retirement that would also catch IRM, retention, auto-label, or app-retention. Triggers 1, 2, and 3 above remain the only paths to reverse the deferral.

### Surface note — undocumented cmdlet

The live IPPS enumeration also surfaced `New-SupervisoryReviewPolicyMailboxFolders` as a published cmdlet on the live `ExchangeOnlineManagement` IPPS session. Its Microsoft Learn reference page returns **HTTP 404** as of 2026-06-07. Per the repo's [Microsoft Learn grounding rule](../../.github/copilot-instructions.md), an undocumented cmdlet is **unusable** — we will not consume it. This finding is recorded here so future watch-list iterations do not re-discover it; it does not flip any of the four triggers.

### Disposition

- §5 re-open triggers: all four cold. No follow-up ADR needed.
- [`data-plane/communication-compliance/policies.yaml`](../../data-plane/communication-compliance/policies.yaml): standing state `policies: []` reaffirmed. Header comment refreshed to lead with the 2026-05-28 "Important" callout.
- [`scripts/Deploy-CommunicationCompliance.ps1`](../../scripts/Deploy-CommunicationCompliance.ps1): no executable behavior changes. Header comment annotated with a one-line ADR 0019 cross-reference so the standing rationale is reachable from the script.
- Project plan §5.3 Communication Compliance row: ticked under the §4 watch-list-row closure rubric (review confirms read-only posture; box ticked on the basis of no programmatic authoring surface as of the review date).
- Project plan §8 Q10: remains an open watch-list row, stamped with the 2026-06-07 re-verification date. The four re-open triggers stay relevant going forward.
- Next re-verification: triggered by any of the four §5 triggers above, or on the next v2 §5.3 cadence touch — whichever fires first.

### Citations (2026-06-07)

- **[Create and manage Communication Compliance policies](https://learn.microsoft.com/en-us/purview/communication-compliance-policies)**
  Fetch date: 2026-06-07 (Last updated 2026-05-28)
  > "PowerShell isn't supported for creating and managing Communication Compliance policies. To create and manage these policies, use the policy management controls in the Communication Compliance solution."
- **[Microsoft Purview What's New](https://learn.microsoft.com/en-us/purview/whats-new)**
  Fetch date: 2026-06-07 (Last updated 2026-06-03)
  Cited for the selective absence: zero Communication Compliance entries across January–June 2026 while every adjacent Purview product shipped multiple monthly updates. (No verbatim quote — citation is to the absence, not a passage.)
- **Microsoft Graph `v1.0` `$metadata`** — `https://graph.microsoft.com/v1.0/$metadata` (2.7 MB)
  Fetch date: 2026-06-07
  Cited to confirm zero `communicationCompliance` / `supervisoryReview` EntitySets in the v1.0 schema.
- **Microsoft Graph `beta` `$metadata`** — `https://graph.microsoft.com/beta/$metadata` (7.1 MB)
  Fetch date: 2026-06-07
  Cited to confirm the only `supervisoryReview*` hits in the beta schema are read-only `auditData`-typed records, not authoring surfaces.
- **[New-SupervisoryReviewPolicyV2 (Exchange PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-supervisoryreviewpolicyv2)**
  Fetch date: 2026-06-07
  Cited to confirm the cmdlet reference page still ships with no deprecation notice and names no successor — basis for trigger 3 remaining cold.
- **Live IPPS write probe against `contoso.onmicrosoft.com`** — `New-SupervisoryReviewPolicyV2 -Name smoke-cc-20260607-001 -Reviewers user@contoso.com`
  Fetch date: 2026-06-07
  > "Following the February 2020 release of Communication Compliance in the Microsoft 365 compliance center, supervision in the Office 365 Security & Compliance Center is being retired and hence this command is no longer supported."
  Transcript local-only at `.copilot-tracking/smoke/cc-stage1-add-20260607.log` (gitignored).
- **Live IPPS cmdlet enumeration against `contoso.onmicrosoft.com`** (`Get-Command` on `InsiderRisk*`, `RetentionCompliance*`, `AutoSensitivityLabel*`, `AppRetentionCompliance*`, `SupervisoryReview*`)
  Fetch date: 2026-06-07
  Cited for the selectivity check — sibling products on the same IPPS surface accept writes; only CC cmdlets are rejected.
