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

## 2026-07-03

### Added

- **scripts:** add the `@operator-kickoff` kickoff agent and the no-push-back guard (`scripts/modules/KickoffGuard.psm1`, `Set-KickoffGuard.ps1`, `Test-KickoffGuard.ps1`) that severs a template copy from the source repository, with Pester coverage (#7)

### Changed

- **repo:** add `tests/**` to the `@artifact-resolver` authorized file scope (#16)
- **repo:** mark the source repository as a GitHub template so consumers use "Use this template" for spin-off copies (#9)
- **docs:** add ADR 0045 — template kickoff and spin-off consumption model with a no-push-back guard (#4)

### Fixed

- **ci:** make the pr-auto-merge owner gate data-driven via the `OWNER_APPROVAL_LOGIN` repository variable, removing the hardcoded owner login (#6)

### Documentation

- **docs:** rewrite the README quick-start and tenant-onboarding guide to lead with the `@operator-kickoff` decouple step before tenant intake (#8)
- **docs:** add ADR 0045 implementation tracking plan sequencing the follow-on tasks #6–#9 (#10)

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
