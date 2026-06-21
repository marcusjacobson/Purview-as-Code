# 0030 — Label-policies tracked-field expansion: amend ADR 0015 in place, ship one PR per field, no per-field ADR

- **Status:** Accepted
- **Date:** 2026-05-31
- **Gates:** Resolves the design question raised by the umbrella issue [#471](../../issues/471). Unblocks per-field implementation PRs filed as children of [#471](../../issues/471). Does not appear in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs — [#471](../../issues/471) is cross-cutting hardening of an existing reconciler, not a wave-blocking question.
- **Deciders:** @contoso

## Context

[ADR 0015](0015-label-policy-shape.md) intentionally shipped [`scripts/Deploy-LabelPolicies.ps1`](../../scripts/Deploy-LabelPolicies.ps1) with a **minimum-viable tracked-field surface**:

- Scalar fields: `mode` only (`$script:TrackedScalarFields = @('mode')`).
- Structured fields: `exchangeLocation` (set), `labels` (GUID set), `advancedSettings` (allowlisted map with three keys).
- `$script:AdvancedSettingsAllowlist = @('RequireDowngradeJustification', 'MandatoryLabelling', 'HideBarByDefault')`.

That shape deferred — by name — five YAML / cmdlet surfaces the portal **Edit policy** wizard exposes:

- `defaultLabel:` (ADR 0015 §"Default-label assignment — none")
- `ModernGroupLocation` (ADR 0015 §"Policy count and surface mix")
- `PurviewLocation` (ADR 0015 §"Policy count and surface mix")
- additional `advancedSettings:` keys beyond the three allowlisted (ADR 0015 §"Advanced settings — three keys only")
- group `scope:` (ADR 0015 §"Scope — Option A")

[#471](../../issues/471) (`feat(scripts): expand Deploy-LabelPolicies.ps1 tracked-field surface to cover the full portal Edit policy wizard`) catalogued the gap: the [`@artifact-resolver`](../../.github/agents/artifact-resolver.agent.md) Phase 3 acceptance run for [#464](../../issues/464) (ADR 0029 portal-wins / repo-wins direction policy) made a manual portal edit to **Default label for documents** (`Public` → `General`) on the *Lab Confidential + HC* policy, and the reconciler did not flag drift. The direction-policy contract still worked — for the four fields it tracks. The **drift surface** is a strict subset of the **operator-visible portal-edit surface**.

[#471](../../issues/471) lists seven wizard steps that flip from "deferred" to "in scope" as of v2:

1. Admin units
2. Users and groups (scope)
3. Documents → default label
4. Emails → default label
5. Meetings → default label
6. Sites and Groups
7. Fabric and Power BI

…plus two surfaces that stay deferred for cause (Engage preview; Name / description). The umbrella issue's own acceptance criteria asks for "one ADR (or amend ADR 0015 if appropriate) per logical wizard step that flips from 'deferred' to 'tracked'". That phrasing leaves the meta-strategy ambiguous, and the [`@idea-intake`](../../.github/agents/idea-intake.agent.md) interview for [#486](../../issues/486) refused to start the first per-field PR until the meta-strategy itself is pinned. This ADR is that pin.

Three candidate shapes were on the table:

- **(a) one ADR per tracked field** — every field gets its own `docs/adr/003N-*.md`. Total cost: seven new ADRs over the lifetime of [#471](../../issues/471). Audit trail per field is maximally explicit.
- **(b) progressive amendment of ADR 0015 in place** — each tracked field lands as an "Updated: YYYY-MM-DD" note on the relevant section of 0015 (the section that originally deferred it), citing the implementation PR. Total cost: zero new ADRs; 0015 grows in place.
- **(c) hybrid** — one umbrella ADR (this one) records the *strategy*; individual fields amend 0015 in place if the original deferral rationale still holds, OR ship as their own ADR if the field needs a new design decision (e.g. a preview-vs-GA cmdlet trade-off, or a security-blast-radius decision that 0015 did not anticipate).

A repo-wide audit of how prior multi-PR rollouts handled the same shape question (2026-05-31):

| Precedent | Shape used | Why |
|---|---|---|
| [ADR 0026](0026-glossary-custom-classifications-reconciler.md) (glossary + classifications) | one ADR, two reconcilers, no per-reconciler ADR | both reconcilers obey the same data-plane drift contract; the per-script differences were mechanical not architectural |
| [ADR 0029](0029-source-of-truth-direction-policy.md) (direction-policy cross-domain rollout) | one ADR pinning the contract; per-domain rollout tracked via [`.github/instructions/github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) + [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md), no per-domain ADR | the per-domain work is contract-compliant retrofitting; architecture decision is the *contract*, not the retrofitting |
| Per-field `advancedSettings:` keys added since 0015 | none added yet; the allowlist is still the original three | the prior pattern is "add one per follow-up issue with a Learn citation justifying each", per ADR 0015 §"Advanced settings — three keys only" — already an amend-in-place pattern, just for one specific schema slot |

Shape (a) produces seven ADRs whose decision content is each "we now track field X because Microsoft Learn page Y documents the cmdlet shape and ADR 0015's original blast-radius concern is bounded as follows." That is a **per-field implementation note**, not a per-field architecture decision. ADRs in this repo (see ADR 0001 onward) record *architecture decisions* — the contract, the surface choice, the trade-off vocabulary — not per-implementation field additions. Shape (a) would inflate the ADR ledger from 30 to 37 without proportional decision content, and would obscure the existence of ADR 0015's original framing by spreading its rebuttal across seven files.

Shape (b) keeps 0015 as the single source of truth for label-policy shape decisions. The original deferral context stays adjacent to the eventual reversal, so a future reader of 0015 immediately sees both "we deferred this on date X because Y" and "we reversed the deferral on date Z because the lab matured to W." The cost is that ADR 0015 grows in length — currently ~150 lines; after seven amendments it could reach ~400. Length is acceptable when the content is genuinely co-located decision history; it is not acceptable when it conceals architectural divergence. Per the seven-field audit below, every deferral is a "blast-radius-was-bigger-than-the-lab-could-absorb-at-the-time" decision, not a "we don't think we should ever track this" decision. The reversals are predictable, not divergent.

Shape (c) — hybrid — is the option that survives any reasonable future. It is also the option [#471](../../issues/471)'s acceptance criteria text most naturally maps onto ("one ADR **or amend ADR 0015 if appropriate**"). The cost is the meta-decision of *which* fields warrant their own ADR. This ADR resolves that meta-decision once: **default to amend-in-place; new ADR only when a field introduces a design question ADR 0015 did not anticipate.**

## Decision

We will:

1. **Default amend-in-place.** Each of the seven tracked-field PRs amends [ADR 0015](0015-label-policy-shape.md) in the same diff that ships the schema / reconciler / Pester changes. The amendment is an "Updated: YYYY-MM-DD" note on the ADR 0015 section that originally deferred the field, citing (a) the implementing PR, (b) the Microsoft Learn page(s) consulted, and (c) the GA-vs-preview cmdlet shape used. No new ADR file is created for these.

2. **New ADR only when a design question ADR 0015 did not anticipate is in scope.** The exact triggers that mandate a new ADR (instead of an amendment) are:
   - **Preview-only cmdlet on the only documented surface.** Adopting a preview surface as part of a tracked field is a design decision that ADR 0015 explicitly did not make (0015's blast-radius reasoning was all GA). Wave 0's `.github/instructions/powershell.instructions.md` "GA-over-preview" rule already gates this; a new ADR records the exception. Currently affects: **Admin units** (preview cmdlet shape per [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)).
   - **Cross-plane or cross-product impact ADR 0015 did not contemplate.** A tracked field whose authoring surface crosses out of the Information Protection plane into Fabric, Power BI, Teams, or Engage moves the architecture decision beyond 0015's scope. Currently affects: **Fabric and Power BI** (impacts the [Fabric / Power BI compliance information surface](https://learn.microsoft.com/en-us/fabric/governance/microsoft-purview-fabric)).
   - **Security blast radius ADR 0015 explicitly deferred for cause.** ADR 0015 §"Default-label assignment — none" called the `defaultLabel:` decision out as the "highest-impact end-user change available in this surface." Reversing that deferral is a security decision worth its own record. Currently affects: **Documents → default label** (`defaultLabel:` schema field).

   The remaining four fields (Users and groups, Emails default, Meetings default, Sites and Groups) amend 0015 in place — each maps directly onto a deferral that 0015 already framed, with the same blast-radius vocabulary.

3. **Field-by-field implementation order is fixed by smallest-blast-radius-first.** The order is *not* the order [#471](../../issues/471) listed (which followed the portal wizard top-to-bottom). It is:

   1. **Emails → default label** — amend-in-place. Smallest end-user surprise (Outlook only, opens with label pre-selected, user can change before send). One advanced-setting key (`OutlookDefaultLabel` per [Outlook-specific options for default label and mandatory labeling](https://learn.microsoft.com/en-us/purview/sensitivity-labels-aip#outlook-specific-options-for-default-label-and-mandatory-labeling)). Pure additive `advancedSettings:` allowlist extension; no new schema fields.
   2. **Meetings → default label** — amend-in-place. Same shape as #1 but for the meetings surface. Adds one more advanced-setting key. Pure additive allowlist extension.
   3. **Users and groups (scope)** — amend-in-place. ADR 0015 already named the schema slot (`scope:`); the deferral was "we have no second identity to scope against, so the field is `null`." With v2 onboarding a backing Entra group surface ([`data-plane/purview-role-groups/`](../../data-plane/purview-role-groups/)), the lab now does have stable group identities. The field can flip from `null` to a single group display-name resolved via [`scripts/Get-EntraPrincipalIdByDisplayName.ps1`](../../scripts/Get-EntraPrincipalIdByDisplayName.ps1) per [ADR 0023](0023-identifier-resolution.md).
   4. **Sites and Groups (`ModernGroupLocation`)** — amend-in-place. ADR 0015 §"Policy count and surface mix" named this as deferred Option B. Adds a new `modernGroupLocation:` schema field (list of group object IDs, with the zero-GUID placeholder per ADR 0023 Category 3).
   5. **Documents → default label** (`defaultLabel:`) — **new ADR**. ADR 0015 §"Default-label assignment — none" deferred this specifically and called it out as the loudest possible end-user change. The new ADR (next number after this one is allocated; tentatively `0031-default-label-for-documents.md`) records (a) which label to default to in the lab (recommended: `Public` per the current label hierarchy), (b) the `RequireDowngradeJustification` interaction, and (c) the rollback ceremony when an inadvertent default needs to be unset.
   6. **Admin units** — **new ADR**. Preview cmdlet shape. The new ADR records the preview-shape exception per Decision §2 above.
   7. **Fabric and Power BI** — **new ADR**. Cross-product impact. The new ADR records the [`-PowerBIComplianceInformation`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy) surface, the [Fabric governance integration](https://learn.microsoft.com/en-us/fabric/governance/microsoft-purview-fabric) implications, and any Fabric-side prerequisites.

4. **Per-field PR shape contract.** Each tracked-field PR ships with **all** of the following, in one PR, scoped to one field:
   - **Schema:** additive extension to [`data-plane/information-protection/label-policies.schema.json`](../../data-plane/information-protection/label-policies.schema.json). No breaking changes; existing YAML without the new field stays valid.
   - **Reconciler:** the new field added to `$script:TrackedScalarFields` (or `$script:AdvancedSettingsAllowlist`, or a new structured-field branch) in [`scripts/Deploy-LabelPolicies.ps1`](../../scripts/Deploy-LabelPolicies.ps1); diff coverage in `ConvertTo-PolicyHash` / `ConvertTo-TenantPolicyHash` / `Compare-PolicyHash`.
   - **Pester:** new `Describe` block in [`tests/scripts/Deploy-LabelPolicies.Tests.ps1`](../../tests/scripts/Deploy-LabelPolicies.Tests.ps1) following the AST-extract-and-stub pattern, covering at minimum: no-drift, repo-side-only drift, tenant-side-only drift, mixed drift, schema-validation error on malformed input.
   - **Workflow:** no change. [`.github/workflows/deploy-label-policies.yml`](../../.github/workflows/deploy-label-policies.yml) already obeys the ADR 0029 direction-policy contract; the new tracked field flows through it automatically.
   - **YAML:** [`data-plane/information-protection/label-policies.yaml`](../../data-plane/information-protection/label-policies.yaml) populated with the desired value for both shipped policies. May be `null` / empty for the deferred case if the lab's chosen position is "schema supports it; we don't use it yet."
   - **ADR amendment OR new ADR:** per Decision §2 above. If amending 0015 in place, the diff includes the dated update note in the same PR. If a new ADR, the new ADR file is the *only* doc artifact and ADR 0015 gets a one-line "See also" pointer at the end of the relevant section.
   - **Acceptance scenarios:** portal-side mirror of the 5 ADR 0029 scenarios from [#464](../../issues/464) Phase 3 — `audit` no-drift, `portal-wins` with a deliberate portal edit on the new field, `repo-wins` overwrite, post-merge clean re-run, drift-back PR shape (if applicable to the field).

5. **No batching.** One field per PR. Even if two adjacent fields look mechanically similar (e.g. the three default-label fields all touch the same `advancedSettings:` allowlist), each ships in its own PR with its own acceptance evidence. This obeys [`docs/project-plan.md`](../project-plan.md) §"Delivery cadence — one feature at a time" and gives each direction-policy acceptance run a clean attribution.

## Consequences

**Easier:**

- **[#471](../../issues/471) becomes implementable.** Each child issue (seven of them) has a fixed scope, a fixed PR shape, and a fixed "does this need its own ADR" verdict. [`@idea-intake`](../../.github/agents/idea-intake.agent.md) for each child does not have to re-derive the meta-decision.
- **ADR ledger stays calibrated.** Three new ADRs over the lifetime of [#471](../../issues/471) (Documents default, Admin units, Fabric/Power BI), not seven. Each new ADR carries a real architectural decision; the other four field expansions are recorded as dated updates to ADR 0015's existing deferral sections.
- **ADR 0015 stays the single source of truth for label-policy shape.** A reader looking up "why does `Deploy-LabelPolicies.ps1` track only X fields?" finds the question and the answer in one file, with the full deferral history.
- **Direction-policy contract (ADR 0029) gains test coverage as the tracked-field surface expands.** Each tracked-field PR ships its own portal-wins / repo-wins acceptance run, so the rollout naturally grows the acceptance corpus.
- **Implementation order is decision-driven, not wizard-order-driven.** Smallest blast radius first means the first few PRs prove the per-field shape contract works before the high-impact Documents-default PR has to also prove a new architectural pattern.

**Harder:**

- **ADR 0015 grows.** Four amendment notes over time means ADR 0015 expands from ~150 lines to ~250 lines once [#471](../../issues/471) closes. The Update-note pattern (see ADR 0022 for prior art) handles this readably, but reviewers reading 0015 from the top get more text to traverse.
- **The "does this warrant a new ADR" judgment is non-mechanical.** The triggers in Decision §2 are stated explicitly, but the meta-call still requires reviewer judgment when an edge case appears. Mitigation: the [`@idea-intake`](../../.github/agents/idea-intake.agent.md) Step 0 for each child issue restates the trigger list and the verdict before [`@artifact-resolver`](../../.github/agents/artifact-resolver.agent.md) begins.
- **Per-field PR size is non-trivial.** Schema + reconciler + Pester + ADR (amendment or new) + YAML + acceptance evidence. Comparable in line count to [PR #484](../../pull/484) (sublabel resolution + 9 Pester cases) but with more files touched. Mitigation: the per-field PRs are still single-feature, so reviewer cognitive load is bounded even if the diff spans more files than #484.
- **No combined refactor opportunity.** A combined "expand all seven fields in one branch" approach could have factored out a shared `Compare-AdvancedSettingsMap` helper. Per-PR cadence means each PR pays the helper-extraction cost individually or duplicates the inline logic. ADR-acknowledged trade-off; per-PR clarity wins.

**Security principles (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege).** Smallest-blast-radius-first ordering means the high-impact `defaultLabel:` PR ships only after the contract is exercised four times on lower-impact fields; the lab's "blast radius math" stays bounded at every step.
- **#9 (idempotent and reversible).** Each tracked-field PR ships its own `-WhatIf` evidence and round-trip Pester coverage; per-PR cadence means a faulty field can be reverted in isolation without disturbing the others. Same property the direction-policy contract relies on.
- **#10 (OWASP-aware).** Each new tracked field is a new operator-visible knob; per-PR review keeps the security-specialist persona's attention focused on one field's blast-radius story at a time, instead of spread across seven.

**Project-plan items:**

- Does not directly tick any [`docs/project-plan.md`](../project-plan.md) §5 row. [#471](../../issues/471) is cross-cutting hardening of an existing reconciler, not a §5.2 Label-policies row (that row is the Phase-1 drift-closure work, already separately scoped at [#358](../../issues/358)).
- Unblocks: the seven per-field child issues to be filed against [#471](../../issues/471). [`@idea-intake`](../../.github/agents/idea-intake.agent.md) for each cites this ADR's Decision §3 ordering and Decision §2 verdict.
- Does not affect: [#67](../../issues/67) (auto-labeling — its own ADR-0015-like deferral set), Wave 2+ on any other §5 row.

## Alternatives considered

- **(a) One ADR per tracked field.** Rejected per Context — inflates the ledger with per-implementation notes that do not contain per-implementation *decisions*, and dilutes ADR 0015's original framing.
- **(b) Pure amend-in-place for every field.** Rejected per Decision §2 — three of the seven fields introduce design questions ADR 0015 did not anticipate (preview cmdlet adoption, cross-product impact, the explicitly-deferred-for-cause `defaultLabel:` decision); flattening them into 0015 amendments would conceal real architectural divergence.
- **One omnibus PR that ships all seven fields at once.** Rejected per Decision §5. The combine-argument wins (one auth call, one workflow run, one Pester sweep) are dwarfed by the loss of per-field acceptance attribution, per-field reversibility, and per-field reviewer focus — exactly the same calculation ADR 0026 made for the glossary-vs-classifications "two reconcilers, not one" decision.
- **Defer the meta-decision; let each [`@idea-intake`](../../.github/agents/idea-intake.agent.md) child interview re-derive it.** Rejected because [#486](../../issues/486)'s [`@idea-intake`](../../.github/agents/idea-intake.agent.md) interview already proved the meta-decision is itself an architectural call that blocks per-field work. Re-deriving it seven times costs more reviewer time than ratifying it once here.
- **Use [`.github/instructions/`](../../.github/instructions/) instead of an ADR**, mirroring how ADR 0029 pinned the direction-policy *contract* in instructions and let the rollout proceed without per-domain ADRs. Rejected because the meta-decision being recorded here is about *which artifact records each field-expansion decision*. That is itself an ADR-shaped question (architecture decision about the documentation artifact), not an instruction-shaped one (a binding rule for how scripts behave).

## Citations

- [ADR 0015 — Sensitivity label policy shape (locations, scope, advanced settings)](0015-label-policy-shape.md)
- [ADR 0023 — Identifier resolution (env tokens; Entra principal display-name lookup)](0023-identifier-resolution.md)
- [ADR 0026 — Glossary and custom-classifications reconcilers: two scripts, one Data Map api-version pin](0026-glossary-custom-classifications-reconciler.md)
- [ADR 0029 — Source-of-truth direction policy for data-plane reconcilers](0029-source-of-truth-direction-policy.md)
- [`docs/project-plan.md`](../project-plan.md) §"Delivery cadence — one feature at a time"
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — GA-over-preview rule, drift-report contract
- [Publish sensitivity labels by creating a label policy](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#publish-sensitivity-labels-by-creating-a-label-policy)
- [`Set-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy)
- [`Get-LabelPolicy` reference](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy)
- [Custom configurations for sensitivity labels (advanced settings)](https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings)
- [Outlook-specific options for default label and mandatory labeling](https://learn.microsoft.com/en-us/purview/sensitivity-labels-aip#outlook-specific-options-for-default-label-and-mandatory-labeling)
- [Microsoft Purview integration with Microsoft Fabric (governance)](https://learn.microsoft.com/en-us/fabric/governance/microsoft-purview-fabric)
- [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)
