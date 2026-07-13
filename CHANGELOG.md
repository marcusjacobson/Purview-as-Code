# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this repository follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
Entries are grouped by merge date in reverse chronological order. A `#NNN` reference points to the pull request (or issue) that introduced the change; GitHub renders it as a link.

## How this file is maintained

Every state-changing pull request adds its own entry here **as part of that PR** — never in a follow-up PR, never by a direct commit to `main`. `@artifact-resolver` does this during implementation; a human author does it before opening the PR. The merge-time gate is enforced by `@owner-approval` and by [`pre-commit.instructions.md`](.github/instructions/pre-commit.instructions.md) and [`pull-request.instructions.md`](.github/instructions/pull-request.instructions.md).

To add an entry:

1. **Date heading.** Find or create a `## YYYY-MM-DD` heading for the merge date (in the lab's same-day cadence, today's date). Newest date first — a new date heading goes directly below this section, above all older dates.
2. **Category.** Under that date, find or create the matching `### <Category>` subsection, mapping the PR's Conventional-Commit type: `feat` → Added, `fix` → Fixed, `refactor` / `chore` → Changed, `perf` → Performance, `revert` → Reverted, `docs` → Documentation, `test` → Tests, `ci` → CI/CD, `build` → Build; a deletion uses Removed. Keep categories in the order Added, Changed, Fixed, Removed, Performance, Reverted, Documentation, Tests, CI/CD, Build.
3. **Bullet.** Add `- **<scope>:** <subject> (#NNN)` at the top of that category, where `<scope>` is the commit scope, `<subject>` is the Conventional-Commit subject without its `type(scope):` prefix, and `#NNN` is the originating issue number. Historical entries reference the squash-merge PR instead; either renders as a link on GitHub.
4. **Exemption.** A PR whose only change is this file (a manual changelog fix) does not add an entry for itself.

## 2026-07-13

### Changed

- **repo:** remove the phantom `Purview-as-Code-Generic` sibling folder from `Purview-as-Code.code-workspace`, so the multi-root workspace declares only `{ "path": "." }` — the second entry pointed at a directory that exists on no clone, shipped broken to every "Use this template" consumer (ADR 0045), and was silently auto-removed by VS Code / Cursor on open, re-dirtying the working tree and tripping the clean-tree precondition of the agent-led lifecycle on every item; the dangling `"powershell.cwd": "Purview-as-Code-Generic"` setting is deleted with it (owner ruling on the issue's open question), since PowerShell already defaults to the sole remaining workspace folder and hardcoding a folder *name* in a template reproduces the same defect class for any consumer who renames the repo folder, leaving `"settings": {}` — the shape VS Code itself emits (#71)

### Fixed

- **ci:** close linked issues explicitly from `pr-auto-merge.yml`, completing the fix that the `issues: write` scope alone could not deliver. Verification on PR #76 proved the scope fix **insufficient**: `main` already carried `issues: write` at both label and merge time, the PR's trailer was `Refs #75` (so the body's `Closes #75` link was the sole mechanism under test, unconfounded), and `closingIssuesReferences` resolved correctly to `[{number: 75}]` — yet issue #75 received **no `ClosedEvent` of any kind**, identical to #64/#66/#68/#70/#72. The real root cause is broader than permissions: events produced by a `GITHUB_TOKEN`-attributed merge are suppressed outright ("events triggered by the `GITHUB_TOKEN` [...] will not create a new workflow run"), and in this repo that one rule has **three** confirmed faces — the implicit linked-issue close never fires; a `pull_request: closed` workflow never runs (`pr-stacked-retarget.yml` has fired only on the single human merge, #58, and on **none** of the 11 `GITHUB_TOKEN` merges); and a `push: [main]` workflow never runs (`validate.yml`'s push lane has exactly one run in its history, the same human merge). The close therefore **cannot** be hung off `pull_request: closed` or `push: main` — neither trigger ever fires for these merges — so the new `close-linked-issues` job hangs off the one non-suppressed trigger that already exists, the *human* `owner-approved` `labeled` event: it waits (bounded, 20 min) for `gh pr merge --auto` to actually land, reads GitHub's own authoritative `closingIssuesReferences` list, and closes each still-open issue with `gh issue close --reason completed`, citing the merging PR and its squash SHA. Idempotent (already-closed issues skip), fail-soft (an un-closable issue warns and continues rather than failing the run), and incapable of closing anything outside `closingIssuesReferences`. Also tightens the workflow to deny-by-default `permissions: {}` with per-job least privilege, which makes PR #74's `issues: write` load-bearing rather than dead — it now sits only on the job that closes issues, while the merge job holds no issue scope at all (#73)
- **agents:** route a confirmed **unified** Purview account to [`/deploy-unified`](.github/prompts/deploy-unified.prompt.md) instead of dead-ending it — `operator-tenant.agent.md` §1a.4 still told owners that classic `Deploy-*.ps1` onboarding was "blocked pending the ADR 0047 unified reconcilers", a statement that was true before those reconcilers shipped (`Deploy-UnifiedCatalog.ps1`, `Deploy-UnifiedCatalogPolicies.ps1`, `Get-PurviewAccountShape.ps1`, `/deploy-unified`) and is now simply stale; the true half is kept (classic `Deploy-*.ps1` / `/deploy-datamap` export-first onboarding still does not apply to a unified account) and the §1a.5 outcome matrix changes **only** in its "Also record" cell — the ADR 0048 placeholder rule ("leave the placeholder; do not write a classic name") and Hard rules 9/10 are untouched, because a tenant-level Unified Catalog has no ARM account name to write regardless of which reconcilers exist. Also refreshes the stale "once the ADR 0047 reconcile-time account-shape probe ships" parenthetical (it shipped as `Get-PurviewAccountShape.ps1`, and *corroborates* rather than replaces owner confirmation), adds the ADR 0048 discovery precondition to `/deploy-unified` — closing a one-way dangling contract where `/discover-purview-account` already declared itself a `/deploy-unified` precondition but was never pointed back to, and layering the ARM-plane "is this a real, non-decoy, owner-confirmed target?" gate ahead of the retained data-plane "which data plane does it speak?" shape gate — and indexes `/deploy-unified` in the `copilot-instructions.md` prompt list, where it was missing entirely (#75)
- **ci:** add the missing `issues: write` scope to the `permissions:` block in `pr-auto-merge.yml`. A top-level `permissions:` block is exhaustive — every scope not listed is set to `none` — so declaring only `pull-requests: write` and `contents: write` left `issues` at `none`, and the merging identity (`secrets.GITHUB_TOKEN`, via `gh pr merge --squash --auto`) had no permission to close the linked issue. Five consecutive PRs (#64/#66/#68/#70/#72) left their linked issue open with **no** `ClosedEvent` on the timeline at all, while `closingIssuesReferences` resolved correctly on every one — so the link was never the defect, the merging identity's scope was. This adds the missing scope; it is **not** yet confirmed to fix auto-close, because `GITHUB_TOKEN`-raised events are independently known not to trigger downstream automation regardless of scope. Verification is pending on the next merged PR, and issue #73 stays open until a real `ClosedEvent` is observed (#73)
- **docs-regen:** make the ADR-index generator authoritative per ADR 0050 — repair the status regex (`docs-regen.yml:86`), whose lazy quantifier terminated on the first whitespace character and collapsed `Superseded by [ADR NNNN](…)` to a bare `Superseded` (ADRs 0008 and 0037), so it now captures the full status up to an inline HTML comment or end of line; repair the title-strip regex (`docs-regen.yml:80`), which matched the em dash only and leaked the ADR number into the `Title` column for ADR 0039 (`-`) and ADR 0042 (`--`), so it now tolerates em dash, en dash, `--`, and `-`; anchor the table replacement on the table header row so prose between the `## Current ADRs` heading and the table survives regeneration; migrate the curated index prose for ADR 0044 (`watch-list.yml`, fired trigger #1) and ADR 0045 (the KickoffGuard ratification list, plus the `Tracks #4` the curated row silently dropped) into those two ADRs' own `Gates:` lines so the first clean regeneration is lossless; rewrite `docs/adr/README.md` process step 4, which told authors to hand-edit the table and contradicted both ADR 0050 and `.github/skills/docs-maintenance/SKILL.md`; add the "do not hand-edit" NOTE callout above the table; and land the first generator-clean regeneration of the 46-row ADR index (which fixes the hand-curated ADR 0049 row's factually wrong "`sync-*-from-tenant` pair" — its source `Gates:` line already correctly enumerates all three workflows) together with the regenerated `docs/scripts-reference.md`, picking up 7 missing scripts and the stale `Deploy-UnifiedCatalog` placeholder synopsis (#69)

### Documentation

- **adr:** add ADR 0051 — the per-solution workflow (`deploy-<solution>.yml`) is the unit of data-plane apply, and the monolithic `deploy-data-plane.yml` is retired; each per-solution workflow owns exactly one data-plane surface, with `push:` path triggers, a small `workflow_dispatch` input surface, `permissions: {}` deny-by-default with least-privilege per-job splits, a concurrency group, and (where the surface supports export) two-pass deterministic skip enumeration and automated drift-back PRs. Records the evidence that the monolith is **structurally invalid and has never once executed**: it declares **32** `workflow_dispatch` inputs against GitHub's documented **25**-property cap, has done so since the original scaffold commit (`e30b51f`, 2026-06-21), and its Actions history is **90 runs, 0 successes, 0 jobs scheduled** — the runs are even attributed to `push` despite the file declaring no `push:` trigger, the signature of an `on:` block that never parses. Deletion is therefore a zero-regression change. Also records the five-workflow precedent (PRs #58–#61, #70), the rationale already written into `deploy-irm.yml` lines 12–17 (quoted verbatim), the fact that the monolith is a **stale subset rather than an umbrella** (`deploy-label-policies.yml` and `deploy-auto-label-policies.yml` cover surfaces it never had), and the three-way `skip_names_irm` byte-lockstep tax it levies while dead. Corrects the intake's "hard limit of 10" — that is the `repository_dispatch` `client_payload` cap, not the `workflow_dispatch` `inputs` cap of 25; the conclusion is unchanged, since 32 exceeds both the current 25 and the historical 10. Consequences: 12 of ~14 surfaces have **no** automated apply path (they never did — the monolith only made it *look* like they had one), so the documented path for those is the local `scripts/Deploy-*.ps1` reconciler until backfilled; supersedes the relevant passages of **11** ADRs (0003, 0010, 0011, 0021, 0026, 0035, 0036, 0037, 0038, 0046, 0049) while leaving them otherwise standing and unedited — the 12th `grep` hit, `docs/adr/README.md`, is a **generated** index under ADR 0050 and cannot be superseded; and a `deploy-all.yml` orchestrator is explicitly deferred as greenfield `workflow_call` work. Rejects collapsing the inputs to fit the cap (valid but always-red, and **worse than absent because it looks like it should work**) and reducing the file to an orchestrator (no coherent contract to orchestrate at 3 of ~14 surfaces). Gates the follow-up that deletes the workflow and sweeps the operator docs (#78)
- **adr:** add ADR 0050 — the `docs/adr/README.md` "Current ADRs" table is machine-generated by `docs-regen.yml` and is never hand-edited; each ADR's three header lines (`# NNNN — Title` H1, `- **Status:**`, `- **Gates:**`) are the generator's only inputs and therefore the single source of truth for that ADR's row, and must be correct on merge; records the 2026-07-13 evidence (0 of 45 committed rows generator-clean; curated titles are unreproducible editorial rewrites; the curated ADR 0049 row is factually wrong about its own source), ratifies `.github/skills/docs-maintenance/SKILL.md`, and gates the follow-up item that fixes the two generator defects (status truncation at `docs-regen.yml:86`, title number leak at `docs-regen.yml:80`), migrates the ADR 0044 / 0045 curated prose into their `Gates:` lines, and corrects `docs/adr/README.md` process step 4 (#67)
- **adr:** ratify ADRs 0044, 0045, and 0046 to `Accepted` (each one's decision has shipped), resolve the duplicate 0045 number by moving the misfiled tracking plan out of the ADR namespace to `docs/plans/adr-0045-implementation-plan.md` (re-pathing its four sibling-ADR links), and backfill the `docs/adr/README.md` index with the missing rows for 0044, 0045, 0046, and 0049 — 0049's authored `Proposed` status is left untouched pending a separate owner ruling (#63)

## 2026-07-12

### Fixed

- **scripts:** redact the real Entra tenant-scoped GUID from the `IRM_Tenant_Setting_<tenant-guid>` policy name across all IRM artifacts (skip-baseline defaults, YAML header, smoke-test baseline, ADR 0036, runbook, solution guide) — a tenant-scoped GUID is a real tenant identifier prohibited by the "Environment and identifier boundaries" rule, which supersedes ADR 0036 §Security #1 — and drop the now-redundant system-managed skip entry, since `Deploy-IRMPolicies.ps1` already classifies any `IRM_Tenant_Setting_*` policy as `NoChange` via a name-prefix wildcard (skip baseline shrinks 5→4 operator-authored names) (#60)
- **scripts:** make `Deploy-AutoLabelPolicies.ps1` round-trip exportable state — `-ExportCurrentState` now builds rules first and skips any whose resolved `contentContainsSensitiveInformation` is empty (EDM / trainable classifier / document fingerprint), then skips parent policies left with zero surviving rules, reporting both as skipped orphans instead of emitting entries that fail the CCSI `minItems:1` floor on the next deploy (ADR 0016 §12) (#57)
- **policies:** remove the `minItems: 1` floor on `exchangeLocation` in `auto-label-policies.schema.json`, and relax the reconciler's forward-apply input guard to require the key present but allow an empty array, so a SharePoint/OneDrive-only policy's `exchangeLocation: []` round-trips; empty-location writes are gated (Create omits `-ExchangeLocation`, Update skips it) so desired `[]` == tenant `[]` → NoChange (ADR 0016 §12) (#57)

### Documentation

- **docs:** document the IRM reverse drift-detection workflow (`sync-irm-from-tenant.yml`) and its Tier-3 issue-based (not PR-based) semantics in the Insider Risk Management solution guide and the IRM end-to-end smoke runbook (#59)
- **docs:** point the DLP solution guide and end-to-end smoke runbook at the new `deploy-dlp.yml` / `sync-dlp-from-tenant.yml` workflows and drop the "no dedicated forward workflow" gap (#70)
- **docs:** add ADR 0016 §12 (export-scope exclusion + NoChange-only location semantics), a round-trip/scope section in the auto-label-policies solution guide, and export-scope notes in the YAML header (#57)

### CI/CD

- **ci:** add IRM isolated forward companion `deploy-irm.yml` — a Tier-3 (export-incapable) single-apply-pass forward workflow for the Insider Risk Management surface that runs `Deploy-IRMPolicies.ps1` with the ADR 0029 direction-policy contract (dispatch inputs, repo-wins typed-confirm gate, `audit` mode, push-uses-defaults, `concurrency`, KV firewall window); forward twin of `sync-irm-from-tenant.yml`, mirroring the `deploy-dlp.yml` precedent, with no two-pass enumerate (static ADR 0036 skip baseline), no drift-back PR (reverse is issue-based), and no verify-published step; adds a Tier-3 carve-out to the ADR 0029 companion-workflow contract in `.github/instructions/github-actions.instructions.md` (#59)
- **ci:** add IRM reverse drift-detection companion `sync-irm-from-tenant.yml` — a Tier-3, issue-based (not PR-based) reverse leg for the Insider Risk Management surface that runs `Deploy-IRMPolicies.ps1 -DirectionPolicy audit` (read-only, ADR 0029), detects drift from the reconciler's returned object rows (`.Category`/`.Name`/`.Reason`, no stdout scraping), post-filters the ADR 0036 skip baseline, and opens a GitHub issue with self-provisioned labels; closes the reverse-leg gap for IRM per the companion-workflow rule in `.github/instructions/github-actions.instructions.md` (#59)
- **ci:** add DLP companion workflows `sync-dlp-from-tenant.yml` (scheduled reverse drift-back, `-ExportCurrentState`) and `deploy-dlp.yml` (isolated forward apply with the ADR 0029 enumerate/apply/drift-back direction-policy contract), closing the Tier-1 loop for the Data Loss Prevention surface per the companion-workflow rule in `.github/instructions/github-actions.instructions.md` (#70)

## 2026-07-11

### Fixed

- **scripts:** guard the `None` "no default label" sentinel in `Resolve-DesiredAdvancedSettingLabel` (Deploy-LabelPolicies.ps1) so `OutlookDefaultLabel`/`DefaultLabel`/`teamworkdefaultlabelid` set to any casing of `none` normalize to the lowercase tenant sentinel instead of Blocking as an unresolved label reference; adds Pester coverage (#55)
- **policies:** remove the `minItems: 1` floor on `exchangeLocation` in `label-policies.schema.json` so a group-scoped-only label policy's `exchangeLocation: []` (emitted by `-ExportCurrentState`) passes forward-deploy schema validation (#55)
- **infra:** grant the data-plane automation SP `Key Vault Contributor` at vault scope so the single-login data-plane firewall-toggle workflows can run `az keyvault update --public-network-access Enabled` (management-plane `Microsoft.KeyVault/vaults/write`); the prior `Key Vault Crypto User`-only grant did not cover it (ADR 0049) (#53)

### Documentation

- **docs:** add ADR 0049, update the automation-identity guide's 5d RBAC section, and add `drift-detection.yml` to the "Allow GitHub Actions to create and approve pull requests" rationale in the CI repo-settings runbook (#53)

## 2026-07-09

### Added

- **prompts:** add `/deploy-unified` prompt for the Unified Catalog track — account-shape gate via `Get-PurviewAccountShape.ps1`, first-run export-first check, then a concepts pass and a grant/revoke-aware policies pass, each its own `-WhatIf` -> confirm -> apply cycle (ADR 0047 item e) (#51)
- **scripts:** add `Get-PurviewAccountShape.ps1` for read-only classic-vs-unified account-shape detection, plus Pester coverage and Unified Catalog guide updates (ADR 0047 item d) (#49)
- **scripts:** add `Deploy-UnifiedCatalogPolicies.ps1` with grant/revoke-aware gating for Unified Catalog data-access policies, plus tests and guide updates (#47)

### Documentation

- **prompts:** update `/discover-purview-account` Step 4/5 to route a confirmed unified account to `/deploy-unified` instead of stopping, and to mention the shipped `Get-PurviewAccountShape.ps1` probe as corroboration for the owner-confirmed classic-vs-unified determination (#51)

## 2026-07-08

### Added

- **unified-catalog:** promote `Deploy-UnifiedCatalog.ps1` to a live full-circle reconciler for business domains, data products, OKRs, critical data elements, and glossary terms (#45)
- **unified-catalog:** rename `data-plane/unified-catalog/governance-domains.{yaml,schema.json}` to `business-domains.{yaml,schema.json}` to match the `2026-03-20-preview` Unified Catalog API's Business Domain operation group, and add `glossary-terms.{yaml,schema.json}` (Terms operation group) and `data-access-policies.{yaml,schema.json}` (Policies operation group, modeled as a simplified role-assignment projection pending the dedicated grant/revoke-aware reconciler) — schema-only scaffolding per ADR 0047 §Decision item 5/10, item (a); no reconciler logic or live API calls added (#43)
- **scripts:** add an opt-in, read-only `-ProbeUnifiedCatalog` switch to `Find-PurviewAccount.ps1` — when ARM enumeration finds no *confirmed* governance account (an empty result, or a result made up entirely of `RequiresOwnerConfirmation` hits such as a pay-as-you-go metering resource), runs a single tenant-scoped GET against the Unified Catalog preview data-plane `businessdomains` enumerate endpoint (`2026-03-20-preview`) and appends a diagnostic classification (`UnifiedCatalogTenantReachable`, `UnifiedCatalogUnauthorized`, `UnifiedCatalogProbeIndeterminate`, `UnifiedCatalogUnreachable`, `UnifiedCatalogProbeSkipped`) to the returned array; default off, never writes, never prints the token, and its diagnostic label must never be written to `purviewAccountName`; Pester coverage of the classification, shaping, and probe-calling functions, including a regression guard proving the probe still fires when ARM surfaces only a metering resource (#41)
- **instructions:** wire the opt-in Unified Catalog tenant-reachability probe into the ADR 0048 operator flow — `@operator-tenant` Step 1a.3 and the `/discover-purview-account` prompt Step 3 now offer `Find-PurviewAccount.ps1 -ProbeUnifiedCatalog` to corroborate the "tenant-level Unified Catalog" hypothesis in the "not found in ARM" branch, with an explicit never-write-to-`purviewAccountName` rule (#41)

### Documentation

- **docs:** update `docs/solutions/unified-catalog/unified-catalog.md` and ADR 0024 with a non-substantive note reflecting the ADR 0047 rename and the two new concept files (#43)
- **docs:** add an ADR 0048 addendum grounding the opt-in Unified Catalog tenant-reachability probe in the Learn-documented `businessdomains` enumerate operation, framed conservatively as a tenant-level reachability signal that neither confirms a specific account's type nor reopens item 5's classic-vs-unified caveat (#41)

## 2026-07-06

### Added

- **prompts:** add the read-only `/discover-purview-account` prompt implementing the ADR 0048 deploy-time discovery-and-confirmation gate — enumerate `Microsoft.Purview/accounts` for the `purviewAccountName` in `infra/parameters/lab.yaml` across every visible subscription via `Find-PurviewAccount.ps1`, present each hit with the verbatim pay-as-you-go-metering warning, handle "not found in ARM" (unified / other-subscription / not-yet-created) as first-class, confirm classic-vs-unified, and report the outcome matrix; stop before `Connect-Purview.ps1` on any unconfirmed / metering-only / unified target instead of reconciling; `/deploy-datamap` gains a matching precondition pointing at the gate (#35)
- **instructions:** turn `@operator-tenant` Step 1 Q8 into a discover-then-confirm gate (new Step 1a) implementing ADR 0048 — run read-only discovery (`Find-PurviewAccount.ps1`, or `az account list` + per-subscription `az resource list`) across every visible subscription, present each hit with the verbatim pay-as-you-go-metering warning, handle "not found in ARM" (unified / other-subscription / not-yet-created) as first-class, record and route on classic-vs-unified, and leave the `purview-contoso-lab` placeholder with an "account unconfirmed — owner action required" note rather than write a guessed name; `tenant-placeholders.yaml` `purviewAccountName` note updated to reference the gate (#37)
- **scripts:** add read-only `Find-PurviewAccount.ps1` discovery helper implementing the ADR 0048 gate — enumerate `Microsoft.Purview/accounts` across every visible subscription (`az account list` → per-subscription `az resource list`), return one structured object per hit (name, resource group, region, sku) with a `RequiresOwnerConfirmation` classification and the pay-as-you-go-metering warning, and emit a first-class "not found in ARM" result rather than an error; Pester coverage of the shaping and `az`-wrapping functions (#36)

### Documentation

- **docs:** add ADR 0048 requiring `@operator-tenant` to run a read-only discovery-and-confirmation gate for the Purview account target — enumerate `Microsoft.Purview/accounts` across every visible subscription, distinguish a governance account from a pay-as-you-go metering decoy, handle the "not found in ARM" (unified / other subscription / not-yet-created) case as first-class, route on classic-vs-unified, and never write a guessed account name — complementing ADR 0047's reconcile-time routing (#34)
- **docs:** record the Microsoft Purview Unified Catalog preview-REST-API coexistence decision in ADR 0047, superseding ADR 0037 after its watch-list trigger #1 fired (#32)

## 2026-07-05

### Changed

- **instructions:** single-source the `@operator-tenant` Step 6 placeholder scans from `tenant-placeholders.yaml` — promote `residualScan` / `functionalWorkflowScan` to structured fields (`schemaVersion` 2), add the `Get-TenantResidualScanCommand.ps1` generator and a manifest-based fallback in the agent body, and drop the removed owner-login clause from the functional scan (#29)

### Fixed

- **scripts:** `Test-KickoffGuard.ps1` exits `0` on a passing guard instead of leaking a non-zero `$LASTEXITCODE` from the last internal `git` call, restoring exit-code gating; add Pester coverage of the exit-code contract (#27)
- **instructions:** operational deploy/add prompts (`deploy-infra`, `deploy-datamap`, `add-classification`, `add-data-source`, `build-item`) read the resource group, region, Purview account, and tenant domain from `infra/parameters/lab.yaml` instead of embedding tenant literals that break on a tailored copy (#27)
- **instructions:** `tenant-placeholders.yaml` closes two scan-only tenant surfaces — the `.github/CODEOWNERS` header slug (`ownerSlug`) and the `.github/copilot-instructions.md` Squad owner-identity line (`githubOrg`) — and `@operator-tenant` Step 5 is synced (#27)

### Documentation

- **docs:** rewrite `getting-started.md` §4 to lead with the export-first onboarding bootstrap (`-ExportCurrentState -Force`, per domain) before reconciling with `-WhatIf`/apply, so a first run against a pre-existing account no longer surfaces every live object as `Orphan` drift; cross-link the `/deploy-datamap` prompt (now with a first-run precondition) and name export-first onboarding as `@operator-tenant`'s post-tailoring next step (#30)
- **docs:** add a "Teardown / re-run" section to the kickoff guide — rebuilding requires manual GitHub-UI repo deletion because the automation token lacks the `delete_repo` scope by design (#27)
- **docs:** record the prompt-decoupling and closed-tenant-surface decisions in ADR 0046 (#27)

### Tests

- **scripts:** add drift-guard Pester coverage for `Get-TenantResidualScanCommand.ps1`, asserting the generated residual / functional scans stay faithful to `tenant-placeholders.yaml` (#29)

### CI/CD

- **ci:** make the `idea-intake-autoadd.yml` needs-review owner gate data-driven via the `OWNER_APPROVAL_LOGIN` repository variable (two-job least-privilege split; warns and skips on unset instead of failing), removing the hardcoded owner login (#29)

## 2026-07-04

### Added

- **instructions:** add tenant placeholder manifest (`.github/agents/tenant-placeholders.yaml`) — ordered longest-match-first tokens, the authoritative tenant-surface edit list, the intentional-sample allowlist, and de-template markers — for deterministic, corruption-safe template tailoring (#24)

### Changed

- **instructions:** wire `@operator-tenant` to the placeholder manifest — ordered replacement, intentional-sample-scoped residual scan, diff-scoped secrets scan, targeted functional-workflow scan, and a de-template step; add custom-domain, missing-origin, and harness-portability notes (#24)
- **instructions:** fix `@operator-kickoff` `isTemplate` false-positive (a template clone no longer reads as the canonical template), flag local-workspace mode as a CI/CD dead-end, and reconcile `origin` removal with `@operator-tenant`'s org/repo defaults (#24)
- **instructions:** ban em-dashes / ellipsis / smart quotes in interactive menu labels (INTERACTION-MENUS.md + agents.instructions.md) and convert existing agent menu labels to ASCII (#24)

### Fixed

- **docs:** correct getting-started OIDC identity setup to the per-plane app trio (`gh-oidc-purview-control-plane` / `-data-plane` / `-kv-unlock`) with `:environment:<env>` federated-credential subjects — the previous single-app `gh-Purview-as-Code-Generic` with a `:ref:refs/heads/main` subject would fail `azure/login` (#24)

### Documentation

- **docs:** add ADR 0046 — tenant placeholder manifest for template tailoring (#24)

## 2026-07-03

### Added

- **scripts:** add `Update-LandingPageEmbeds.ps1` to refresh (and `-Check`) the offline documentation snapshots embedded in `index.html` (#22)
- **scripts:** resolve the `@operator-kickoff` source template URL via the GitHub template relationship (with `origin` fallback), so the no-push-back guard works after "Use this template" and never targets the consumer's own repo (#18)
- **scripts:** add the `@operator-kickoff` kickoff agent and the no-push-back guard (`scripts/modules/KickoffGuard.psm1`, `Set-KickoffGuard.ps1`, `Test-KickoffGuard.ps1`) that severs a template copy from the source repository, with Pester coverage (#7)

### Changed

- **repo:** add `tests/**` to the `@artifact-resolver` authorized file scope (#16)
- **repo:** mark the source repository as a GitHub template so consumers use "Use this template" for spin-off copies (#9)
- **docs:** add ADR 0045 — template kickoff and spin-off consumption model with a no-push-back guard (#4)

### Fixed

- **ci:** make the pr-auto-merge owner gate data-driven via the `OWNER_APPROVAL_LOGIN` repository variable, removing the hardcoded owner login (#6)

### Documentation

- **docs:** add a browser-openable HTML landing page (`index.html`) with a slide-in side panel that renders the linked Markdown docs in-page (#22)
- **docs:** add an opinionated kickoff guide (`docs/kickoff-guide.md`) and feature it as the "start here" entry point in the README (#20)
- **docs:** rewrite the README quick-start and tenant-onboarding guide to lead with the `@operator-kickoff` decouple step before tenant intake (#8)
- **docs:** add ADR 0045 implementation tracking plan sequencing the follow-on tasks #6–#9 (#10)

### Tests

- **scripts:** add Pester coverage for `Update-LandingPageEmbeds.ps1` (embedding, drift detection, `-WhatIf` safety, idempotency) (#22)

### CI/CD

- **ci:** add a `validate.yml` gate that fails when `index.html`'s embedded doc snapshots drift from their source docs (#22)

## 2026-06-21

### Added

- **repo:** initial generic Purview-as-Code template baseline — every tenant-specific identifier replaced with Microsoft's documented placeholders (`contoso`, `contoso.onmicrosoft.com`, zero-GUID), and the `@operator-tenant` Tenant Intake agent added for per-tenant tailoring.

### Changed

- **docs:** reset `docs/project-plan.md` to a generic, empty roadmap template (the §3/§5/§6/§8 framework is preserved so the Squad agents still resolve their gates).

### Fixed

- **scripts:** restore the UTF-8 BOM on 15 PowerShell files that lost it during the genericization token-rewrite, fixing the `PSUseBOMForUnicodeEncodedFile` PSScriptAnalyzer failure (#1).

### Removed

- **docs:** remove lab-only build-up and test working docs — the archived v1 plan, the wave-0 smoke-test log, the repo-consistency-housekeeping and role-group-backing audits, and the agentic-process-modernization plan (references repointed to surviving canonical docs).

### Documentation

- **docs:** add a README quick-start and a detailed [`docs/tenant-onboarding.md`](docs/tenant-onboarding.md) guide for the clone → `@operator-tenant` → secrets/OIDC → deploy flow (#1).
