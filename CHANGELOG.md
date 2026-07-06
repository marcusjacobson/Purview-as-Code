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

## 2026-07-06

### Documentation

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
