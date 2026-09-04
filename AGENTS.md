# AGENTS.md

Entry point for AI coding agents (GitHub Copilot, Claude Code, and others) working in this repo. Follows the [`agents.md`](https://agents.md/) convention.

## Where the rules live

This file is intentionally thin — the authoritative rules live under [`.github/`](.github/):

- [`.github/copilot-instructions.md`](.github/copilot-instructions.md) — always-on baseline (trust directive, project layout, Rules map, environment boundaries, Microsoft Learn grounding).
- [`.github/instructions/*.instructions.md`](.github/instructions/) — path-scoped rules, auto-loaded by VS Code when a matching file is in context. See the "Rules map" table in `copilot-instructions.md` for the full index.
- [`.github/prompts/*.prompt.md`](.github/prompts/) — explicit task templates invoked with `/<name>` in Copilot Chat.
- [`.github/agents/*.agent.md`](.github/agents/) — workspace-scoped custom agents (personas with restricted tool lists).

Agents that do not support VS Code's `applyTo:` frontmatter should load [`.github/copilot-instructions.md`](.github/copilot-instructions.md) first, then the Rules map table will point them to the scoped file(s) that govern the files they're editing.

## Two planes — do not cross

| Plane | Folder | Tooling |
|---|---|---|
| **Control** — the `Microsoft.Purview/accounts` resource and its Azure dependencies | [`infra/`](infra/) | Bicep, Azure CLI |
| **Data** — collections, glossary, classifications, data sources, scans, policies | [`data-plane/`](data-plane/), [`scripts/`](scripts/) | YAML + PowerShell calling the Purview REST APIs |

A change almost always lives in one plane. Cross-plane PRs require explicit justification in the PR description per [`.github/instructions/pull-request.instructions.md`](.github/instructions/pull-request.instructions.md).

## Non-negotiables

1. **Microsoft Learn is the source of truth.** Every resource, cmdlet, `az` command, REST endpoint, and action version must cite a current Learn page. Model training recall alone is not sufficient. See the "Grounding" section of `copilot-instructions.md`.
2. **No secrets, no real identifiers.** See [`.github/instructions/security.instructions.md`](.github/instructions/security.instructions.md) and the "Environment and identifier boundaries" section of `copilot-instructions.md`.
3. **Read-only default.** Writes require an explicit user instruction in the current turn; destructive writes require typed confirmation. See [`.github/instructions/mcp-tool-usage.instructions.md`](.github/instructions/mcp-tool-usage.instructions.md).
4. **Pre-commit checklist passes before PR.** See [`.github/instructions/pre-commit.instructions.md`](.github/instructions/pre-commit.instructions.md) plus the per-domain checklist in each scoped file.

## Deployment commands

Canonical validate / control-plane / data-plane commands: [`.github/instructions/build-deploy.instructions.md`](.github/instructions/build-deploy.instructions.md). Do not invent alternatives.

## Cursor Cloud specific instructions

This repo is infrastructure-as-code (Bicep + PowerShell 7 + YAML) — there is **no runnable server or
app**. "Running" the project means executing the CI validation gates and the offline posture verifiers.
The required toolchain is `pwsh` 7.4+, Azure CLI + Bicep CLI, Python 3 + `yamllint`, and the PowerShell
modules `Pester` (5.x), `PSScriptAnalyzer`, and `powershell-yaml`. Any pre-provisioned VM snapshot or
startup script that supplies these is Cursor Cloud environment configuration maintained outside this
repo — no `.cursor/` config is tracked here — so verify the tools are present rather than assume them.

The full local CI mirror is [`.github/workflows/validate.yml`](.github/workflows/validate.yml). Its
gates (currently ten) are the source of truth — re-derive this table from that file if the job set
changes. Every gate runs without a tenant:

| Gate | Local equivalent |
| :--- | :--- |
| `bicep` | `az bicep lint --file infra/main.bicep`, then `az bicep build --file infra/main.bicep --outfile <tempfile>` |
| `yaml` | `yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable}}' data-plane/ examples/` — `examples/` is linted alongside `data-plane/` per [ADR 0056](docs/adr/0056-template-ships-empty-desired-state.md) |
| `powershell` | `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning -EnableExit` |
| `actionlint` | the standalone [`actionlint`](https://github.com/rhysd/actionlint) release binary against `.github/workflows/**` — it is not preinstalled; download the binary first |
| `identifier-residue` | `pwsh ./scripts/Test-IdentifierResidue.ps1` — needs the `powershell-yaml` module; exits 1 on any Finding ([ADR 0055](docs/adr/0055-identifier-shaped-residual-scan.md)) |
| `pester` | `pwsh ./tests/Run-Pester.ps1` |
| `dspm-posture` | `pwsh ./scripts/Test-DSPMPosture.ps1` |
| `dspm-ai-posture` | `pwsh ./scripts/Test-DSPMforAIPosture.ps1` |
| `full-circle-contract-guard` | no standalone script — an inline `pwsh` step in `validate.yml` that fails when a non-exempt `scripts/Deploy-*.ps1` lacks any of the `SupportsShouldProcess`, `PruneMissing`, or `ExportCurrentState` contract tokens |
| `landing-page-embeds` | `pwsh ./scripts/Update-LandingPageEmbeds.ps1 -Check`; repeat with `-IndexPath <page>.html` for any additional landing page present in the copy |

Canonical deploy commands live in
[`.github/instructions/build-deploy.instructions.md`](.github/instructions/build-deploy.instructions.md)
— do not invent alternatives.

- **Pester must be 5.x, never 6.x.** [`tests/Run-Pester.ps1`](tests/Run-Pester.ps1) selects the
  *highest* installed Pester `>= 5.5.0`. Pester 6 changes `Mock` command resolution and breaks the
  mock-based tests in `tests/scripts/Export-ContentExplorerData.Tests.ps1`
  (`CommandNotFoundException: Could not find Command Install-Module`). CI stays on 5.x only because
  `windows-latest` ships Pester 5.x preinstalled. Keep a Pester 5.x present and do **not** leave
  Pester 6 installed, or the runner will pick it up. Pester `5.7.1` is a known-good pin; the Cursor
  Cloud update script that applies it is environment configuration maintained outside this repo.
- **`Deploy-*.ps1` reconcilers and `Invoke-*SmokeTest.ps1` require a live Azure/M365 tenant** (OIDC +
  Key Vault certificate auth via `scripts/Connect-Purview.ps1` / `Connect-IPPSSession`). Even the
  `-WhatIf` / `-ExportCurrentState` read paths open a tenant session, so they cannot run in the
  Cursor Cloud VM (no tenant credentials). Local validation is limited to the gates above; live
  deploy and smoke testing are out of scope.
- The `Test-DSPMPosture.ps1` / `Test-DSPMforAIPosture.ps1` verifiers are the best offline smoke test
  of the data-plane engine — they parse, schema-validate, and cross-reference the real
  `data-plane/**` manifests without any tenant call.

Reference: [agents.md convention](https://agents.md/), [Custom instructions in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-instructions).
