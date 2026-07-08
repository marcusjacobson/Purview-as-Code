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

## 2026-07-08

### Added

- **unified-catalog:** rename `data-plane/unified-catalog/governance-domains.{yaml,schema.json}` to `business-domains.{yaml,schema.json}` to match the `2026-03-20-preview` Unified Catalog API's Business Domain operation group, and add `glossary-terms.{yaml,schema.json}` (Terms operation group) and `data-access-policies.{yaml,schema.json}` (Policies operation group, modeled as a simplified role-assignment projection pending the dedicated grant/revoke-aware reconciler) — schema-only scaffolding per ADR 0047 §Decision item 5/10, item (a); no reconciler logic or live API calls added (#43)

### Documentation

- **docs:** update `docs/solutions/unified-catalog/unified-catalog.md` and ADR 0024 with a non-substantive note reflecting the ADR 0047 rename and the two new concept files (#43)

 to `Find-PurviewAccount.ps1` — when ARM enumeration finds no *confirmed* governance account (an empty result, or a result made up entirely of `RequiresOwnerConfirmation` hits such as a pay-as-you-go metering resource), runs a single tenant-scoped GET against the Unified Catalog preview data-plane `businessdomains` enumerate endpoint (`2026-03-20-preview`) and appends a diagnostic classification (`UnifiedCatalogTenantReachable`, `UnifiedCatalogUnauthorized`, `UnifiedCatalogProbeIndeterminate`, `UnifiedCatalogUnreachable`, `UnifiedCatalogProbeSkipped`) to the returned array; default off, never writes, never prints the token, and its diagnostic label must never be written to `purviewAccountName`; Pester coverage of the classification, shaping, and probe-calling functions, including a regression guard proving the probe still fires when ARM surfaces only a metering resource (#41)
- **instructions:** wire the opt-in Unified Catalog tenant-reachability probe into the ADR 0048 operator flow — `@operator-tenant` Step 1a.3 and the `/discover-purview-account` prompt Step 3 now offer `Find-PurviewAccount.ps1 -ProbeUnifiedCatalog` to corroborate the "tenant-level Unified Catalog" hypothesis in the "not found in ARM" branch, with an explicit never-write-to-`purviewAccountName` rule (#41)

### Documentation

- **docs:** add an ADR 0048 addendum grounding the opt-in Unified Catalog tenant-reachability probe in the Learn-documented `businessdomains` enumerate operation, framed conservatively as a tenant-level reachability signal that neither confirms a specific account's type nor reopens item 5's classic-vs-unified caveat (#41)

## 2026-07-06

### Added

- **prompts:** add the read-only `/discover-purview-account` prompt implementing the ADR 0048 deploy-time discovery-and-confirmation gate — enumerate `Microsoft.Purview/accounts` for the `purviewAccountName` in `infra/parameters/lab.yaml` across every visible subscription via `Find-PurviewAccount.ps1`, present each hit with the verbatim pay-as-you-go-metering warning, handle "not found in ARM" (unified / other-subscription / not-yet-created) as first-class, confirm classic-vs-unified, and report the outcome matrix; stop before `Connect-Purview.ps1` on any unconfirmed / metering-only / unified target instead of reconciling; `/deploy-datamap` gains a matching precondition pointing at the gate (#35)
- **instructions:** turn `@operator-tenant` Step 1 Q8 into a discover-then-confirm gate (new Step 1a) implementing ADR 0048 — run read-only discovery (`Find-PurviewAccount.ps1`, or `az account list` + per-subscription `az resource list`) across every visible subscription, present each hit with the verbatim pay-as-you-go-metering warning, handle "not found in ARM" (unified / other-subscription / not-yet-created) as first-class, record and route on classic-vs-unified, and leave the `purview-contoso-lab` placeholder with an "account unconfirmed — owner action required" note rather than write a guessed name; `tenant-placeholders.yaml` `purviewAccountName` note updated to reference the gate (#37)
- **scripts:** add read-only `Find-PurviewAccount.ps1` discovery helper implementing the ADR 0048 gate — enumerate `Microsoft.Purview/accounts` across every visible subscription (`az account list` → per-subscription `az resource list`), return one structured object per hit (name, resource group, region, sku) with a `RequiresOwnerConfirmation` classification and the pay-as-you-go-metering warning, and emit a first-class "not found in ARM" result rather than an error; Pester coverage of the shaping and `az`-wrapping functions (#36)

### Documentation

- **docs:** add ADR 0048 requiring `@operator-tenant` to run a read-only discovery-and-confirmation gate for the Purview account target — enumerate `Microsoft.Purview/accounts` across every visible subscription, distinguish a governance account from a pay-as-you-go metering decoy, handle the "not found in ARM" (unified / other subscription / not-yet-created) case as first-class, route on classic-vs-unified, and never write a guessed account name — complementing ADR 0047's reconcile-time routing
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
