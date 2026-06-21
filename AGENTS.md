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

Reference: [agents.md convention](https://agents.md/), [Custom instructions in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-instructions).
