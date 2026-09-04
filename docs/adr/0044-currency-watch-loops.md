# 0044 — Code- and feature-currency watch loops

- **Status:** Accepted <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-06-20
- **Gates:** Cross-cutting; no [`project-plan.md`](../project-plan.md) §5 / §8 row. Establishes [`watch-list.yml`](watch-list.yml) and the currency watch loops; its trigger #1 has fired (cited by [ADR 0047](0047-unified-catalog-preview-api-coexistence.md)).
- **Deciders:** contoso

## Context

Two recurring maintenance questions have no automated answer in this repo:

1. **Are our commands still current?** Every reconciler under `scripts/**` pins a PowerShell cmdlet /
   module surface and an explicit REST `api-version`, and every `infra/**` resource pins an API version.
   The [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) and
   [`bicep.instructions.md`](../../.github/instructions/bicep.instructions.md) "deprecation triggers
   migration" rules *require* migrating off a retired version — but nothing *detects* the retirement.
   Today this is found by hand, if at all.
2. **What's new in Microsoft Purview that we should adopt as-code?** Microsoft ships new Purview features
   and, occasionally, new programmatic (PowerShell / REST / Graph) surfaces for features that were
   portal-only. The 2026-06-15 §5.7 surface-completeness check was a one-time, lab-owner-led manual
   survey ([#376](../../issues/376)); there is no recurring loop that proactively flags net-new features
   or newly-available as-code surfaces.

The existing scheduled loops do not close these gaps. [`drift-detection.yml`](../../.github/workflows/drift-detection.yml)
(Slice 7) compares repo desired-state against live tenant *state*. [`surface-watch.yml`](../../.github/workflows/surface-watch.yml)
(Slice 8) verifies that the §3 inventory's Microsoft Learn URLs still return HTTP 200 with an unchanged
title — its net-new "additions" report array is built but never populated, so it cannot discover features
that are not already listed, nor judge whether a feature is "now as-code".

The lab owner asked to research options for a **cloud agent** that periodically scans the code to (1) flag
PowerShell / REST commands that changed or can be improved, and (2) perform a recurring "what's new"
review for Purview features to consider or newly available as-code. GitHub now ships a first-class
**Copilot cloud agent** (formerly "coding agent") that can be run on a schedule via **automations**, which
makes a reasoning-driven loop a real option alongside the repo's existing deterministic GitHub Actions
loops. This repo is **private**, which matters because Copilot automations are unavailable in public
repositories.

The non-negotiable **augment, never replace** invariant applies: any new loop runs read-only, produces a GitHub issue upstream of
`@idea-intake`, and never deploys, never mutates the data plane, and adds no lifecycle stage.

## Decision

We will close both gaps with **two complementary, read-only, issue-only watch loops**, each enumerated as a
new numbered slice in the agentic-process-modernization plan and each later built as its own
`@idea-intake` item. We choose a **hybrid** of the two cloud-agent primitives — matching each gap to the
mechanism that fits its determinism:

1. **Code-currency watch loop → a scheduled GitHub Actions workflow** (the deterministic Option A,
   the proven surface-watch / drift-detection pattern). The check — "does the pinned `api-version` /
   cmdlet's Microsoft Learn page show retirement, or a newer GA version?" — is a deterministic
   string-and-version diff that benefits from zero model cost, full auditability, and no nondeterminism.
   It opens one deduplicated issue routed to `@idea-intake`. Enumerated as **Slice 12**.

2. **Feature-currency ("what's new") watch loop → a scheduled GitHub Copilot cloud-agent automation**
   (Option B). Judging whether a newly documented Purview feature *now has an as-code surface* and *is in
   scope* is open-ended reasoning that the deterministic surface-watch diff structurally cannot do. The
   automation reads the [What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new)
   page on a schedule, cross-references the §3 inventory and §7 out-of-scope list, and opens an issue
   summarizing net-new features and any newly-available programmatic surface. To preserve the "loops
   produce issues only" invariant, the automation's **tool list is restricted to issue creation** — no
   pull request, no deploy, no data-plane call. Enumerated as **Slice 13**.

The "what's new" loop ships as a **new** loop, **not** as an extension of `surface-watch.yml`. Bolting LLM
reasoning into surface-watch would violate Slice 8's deterministic read-only contract and its regression
guard; the two are complementary in the same way drift-detection and surface-watch are. surface-watch is
left unchanged.

**Where suggestions go.** Each loop's only output is a GitHub issue. Following the established
`drift-detected` / `surface-watch` convention, the issue carries a stable per-loop marker label —
`code-currency` (Slice 12) and `feature-currency` (Slice 13) — plus the `squad:*` routing labels and
`needs-review`, and is deduplicated against the open issue bearing its marker label before a second one is
filed. The open marker-labeled issues form a **review queue** surfaced through a pointer in the
top-level [`README.md`](../../README.md), so suggestions are
discoverable rather than buried in the issue backlog.

This ADR **decides and enumerates only**. Implementing either loop is a separate future `@idea-intake`
item, per the plan's own out-of-scope rule.

## Consequences

What becomes easier:

- The `powershell.instructions.md` / `bicep.instructions.md` "deprecation triggers migration" rule gains
  an automated trigger instead of relying on a human noticing a retirement.
- Net-new Purview features and newly-as-code surfaces surface on a cadence instead of via one-off manual
  surveys, feeding the unchanged `@idea-intake` → `/build-item` → `@artifact-resolver` → `@owner-approval`
  lifecycle.
- The two loops slot cleanly beside Slices 7–10 with no new lifecycle stage.
- Loop suggestions are discoverable: the per-loop marker-label review queue plus the `README.md` pointer
  give the reviewer one place to find pending code- and feature-currency issues instead of scanning the
  whole backlog.

What becomes harder:

- The repo gains a second LLM-driven surface (the Slice 13 automation) whose prompt and tool scope must be
  maintained and reviewed. Its model-tier is `reasoning` per [ADR 0043](0043-model-tier-policy.md).
- Slice 13 depends on the repository staying **private or internal** (Copilot automations are unavailable
  in public repos). If the repo is ever made public, Slice 13 must fall back to a deterministic
  surface-watch extension; this constraint is recorded in the slice's regression guard.

Security:

- Upholds the read-only default in [`mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md)
  and security principle #9 (idempotent, reversible, auditable) in
  [`security.instructions.md`](../../.github/instructions/security.instructions.md): both loops only ever
  open an issue.
- Slice 12 is secure-by-default per [`github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md):
  least-privilege `permissions:` (`contents: read`, `issues: write`), third-party actions pinned to a
  commit SHA, no secrets, no Azure auth (it fetches public Learn pages only).
- Slice 13's issue-only tool scope is the security control that keeps a reasoning agent inside the
  "loops produce issues only" invariant.

Unblocked / changed checklist items: none on `project-plan.md` §5 (this is cross-cutting). Adds Slices 12
and 13 to the agentic-process-modernization plan.

## Alternatives considered

**Alternative A — deterministic GitHub Actions for *both* gaps.** Reject for gap 2. A deterministic crawl
can detect a new Learn URL, but it cannot judge whether a feature "is now as-code" or "is in scope" — the
exact reasoning the §5.7 manual survey performed. It would either miss net-new as-code surfaces or emit
noisy false positives, recreating the unused `surface-watch.yml` additions path.

**Alternative B — a Copilot cloud-agent automation for *both* gaps.** Reject for gap 1. Spending model
budget and accepting nondeterminism on a check that is a simple, auditable string-and-version diff is the
wrong trade; the deterministic GitHub Actions loop is cheaper, faster, fully reproducible, and matches the
established Slice 7 / Slice 8 pattern.

**Alternative C — extend `surface-watch.yml` to populate its `$additionsReport`.** Reject as the *primary*
mechanism. It can cheaply detect new top-level Purview Learn pages and is worth keeping as a complementary
deterministic signal, but it still cannot make the "now as-code / in scope" judgment that gap 2 needs, and
adding it to surface-watch breaks Slice 8's deterministic contract.

**Alternative D — do nothing / keep the status quo.** Reject. Command currency has zero coverage today, so
a silent cmdlet or `api-version` retirement is found only by a runtime failure; and feature currency relies
on one-off manual surveys that do not scale across the §3 inventory.

## Errata — 2026-07-17 (public-repo premise correction)

This is a dated errata note, not an amending ADR: nothing in the original decision above was wrong, and
nothing below changes it. Only a stated fact — the repo's visibility — has since changed, and this repo's
own contingency plan for exactly that change (Context, line 97-99; Alternative C, line 128-131) has already
been executed. Per this repo's ADR-immutability convention, the correction is recorded here rather than
silently edited into the Context section above.

1. **The premise is stale.** Line 35 states: *"This repo is **private**, which matters because Copilot
   automations are unavailable in public repos."* `gh repo view` confirms `visibility: PUBLIC`. The repo's
   visibility changed from private to public at some point after this ADR was accepted (2026-06-20) — no
   exact toggle date is recorded in the repository's version-controlled history, since a GitHub visibility
   change is not itself a commit or an event this repo's Git history captures. [ADR 0055](0055-identifier-shaped-residual-scan.md)
   (dated 2026-07-13) already treats the repo as having been public "for weeks" by that date, so the change
   predates this errata by a comfortable margin; the outer bound is 2026-07-16, when this staleness was
   discovered during a documentation-currency audit ([#119](https://github.com/marcusjacobson/Purview-as-Code/issues/119)).

2. **The ADR's own fallback has been executed.** Lines 97-99 anticipated this exact scenario: *"If the repo
   is ever made public, Slice 13 must fall back to a deterministic surface-watch extension."* Lines 128-131
   (Alternative C) named the mechanism and explicitly kept it as the complementary fallback: extend
   `surface-watch.yml` to populate its `$additionsReport`. That fallback is
   [#114](https://github.com/marcusjacobson/Purview-as-Code/issues/114) / [PR #133](https://github.com/marcusjacobson/Purview-as-Code/pull/133),
   now merged. Concretely: `surface-watch.yml` previously declared `$additionsReport = @()` and rendered it
   under "### New features on Learn (not in §3)", but no code path ever populated it — the fetch/parse loop
   only walked the §3 table's own rows, so it could detect removals and title drift but could never
   discover a Learn page not already listed in §3. The fix resolves the current Learn entry-point URL for a
   curated feature-name list against Microsoft Learn's machine-readable `/purview/` TOC
   (`https://learn.microsoft.com/en-us/purview/toc.json`) and diffs each resolved URL against §3, so a
   genuinely new Learn page for an in-scope Purview feature now surfaces as a real addition instead of dead
   code. `surface-watch.yml` itself is otherwise unchanged — this did not touch Slice 8's deterministic
   removal/title-change contract.

3. **Slice 13's real-world configuration status is unverified, and is not resolvable from this repository.**
   Whether `feature-currency-watch` (the Copilot cloud-agent automation this ADR enumerated as Slice 13) was
   ever actually turned on in this repo's GitHub Copilot-automations UI is **unknown**. The lab owner does
   not know either — it may be a newer Copilot-automations capability that was never configured for this
   repo. This is not a code question and there is no gate or check that can answer it: a Copilot automation
   is a UI-level setting external to Git, not a version-controlled artifact, so nothing in this repo's
   history, workflows, or scripts can confirm or deny whether it is enabled, disabled, or was ever set up.
   Confirming its status requires checking GitHub's Copilot-automations settings for this repository
   directly. This errata makes no claim that Slice 13 is "likely disabled" or "likely fine" — only that its
   status is unknown and open.

4. **Nothing in the original decision is retracted.** The reasoning in Context and Decision above — why
   command currency (Slice 12) is a deterministic GitHub Actions loop and feature currency (Slice 13) is a
   reasoning-driven Copilot automation, and why the two are not interchangeable — is unaffected by the
   visibility change. The only thing that was wrong was the standing assumption that the repo would stay
   private; the ADR itself already priced that risk in and named its own mitigation.

## Citations

- **[What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new)**
  Fetch date: 2026-06-20
  > "Microsoft Purview helps you stay on top of the ever-changing data governance, data security, and risk and compliance areas."
- **[About GitHub Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent)**
  Fetch date: 2026-06-20
  > "Copilot can research a repository, create an implementation plan, and make code changes on a branch."
- **[About Copilot automations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations)**
  Fetch date: 2026-06-20
  > "Automations let you run Copilot cloud agent automatically, on a schedule or in response to events in a repository."
- **[About Copilot automations — Availability and permissions](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations)**
  Fetch date: 2026-06-20
  > "The repository must be private or internal. Automations are not available in public repositories."
- [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/) — `api-version` currency source for the code-currency loop.
- [Az PowerShell module reference](https://learn.microsoft.com/en-us/powershell/module/?view=azps-latest) and [Azure service retirements](https://learn.microsoft.com/en-us/azure/service-retirement/) — cmdlet / version deprecation sources.
- [Schedule events for GitHub Actions workflows](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#schedule) and [Security hardening for GitHub Actions](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions) — Slice 12 trigger and secure-by-default rules.
- [ADR 0014](0014-agents-as-default-entry-point.md) — the unchanged lifecycle both loops feed.
- [ADR 0055](0055-identifier-shaped-residual-scan.md) — records the repo as public "for weeks" as of its
  2026-07-13 date, the closest version-controlled evidence for how long the visibility change had already
  been in effect (Errata, point 1).
- [#119](https://github.com/marcusjacobson/Purview-as-Code/issues/119) — the doc-currency issue that
  identified this ADR's stale private-repo premise.
- [#114](https://github.com/marcusjacobson/Purview-as-Code/issues/114) / [PR #133](https://github.com/marcusjacobson/Purview-as-Code/pull/133) —
  implements this ADR's own anticipated public-repo fallback (Errata, point 2).
