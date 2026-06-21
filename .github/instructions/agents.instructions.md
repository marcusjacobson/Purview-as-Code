---
description: "Secure-by-design rules for custom agents defined under .github/agents/. Enforces least-privilege tool lists, required frontmatter, Learn grounding, and naming."
applyTo: ".github/agents/**/*.agent.md"
---

# Custom agent authoring rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Cross-cutting rules live in [`security.instructions.md`](security.instructions.md), [`mcp-tool-usage.instructions.md`](mcp-tool-usage.instructions.md), and [`primitives.instructions.md`](primitives.instructions.md) — this file narrows those rules for agent authors.

Every file in `.github/agents/**/*.agent.md` is a workspace-scoped custom agent per [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes). These agents run in the author's live Copilot session against the live `contoso-lab` Purview account, so the "as code" discipline the rest of this repo uses applies here too.

## Required frontmatter

Every agent file must declare these YAML frontmatter fields:

| Field | Required | Rule |
|---|---|---|
| `description` | yes | One sentence describing the persona and its scope. Shown in the chat input placeholder. |
| `tools` | yes | Explicit list of tools the agent may invoke. Never omit. An omitted `tools` list gives the agent every tool, which violates MCP/tool-usage policy. |
| `model` | yes | Pin a model or prioritized list. Do not rely on the picker default for a shared agent — behavior shifts when a teammate's picker changes. |

Optional fields from the [VS Code schema](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional) (`name`, `argument-hint`, `handoffs`, `user-invocable`, `disable-model-invocation`, `agents`, `hooks`) may be used when the role genuinely needs them. Do not include a field just to fill space.

## Tools list — least privilege is mandatory

- Read-only agents (reviewers, auditors, planners) must limit `tools` to read/search/fetch tools. No `edit`, `new`, `runCommands`, `runTasks`, `runNotebooks`, or MCP write tools.
- Write-capable agents must list each write tool explicitly and the body must document why each is needed.
- Agents that trigger Azure state changes must still defer to the [MCP and tool-usage policy](../copilot-instructions.md) — writes require an explicit user instruction in the current turn, destructive writes require typed confirmation. The agent's `tools` list narrows the surface; it does not bypass the policy.
- MCP wildcard grants (`<server>/*`) are a review-blocker unless justified in the body.

### Default deny list (never in `tools` without justification)

`edit`, `new`, `runCommands`, `runTasks`, MCP server `*` wildcards, any tool that deletes, prunes, or force-overwrites.

## Handoffs

- `handoffs[].agent` must reference an agent that exists in this folder. Dangling handoffs are a review-blocker.
- `handoffs[].send: true` is prohibited for any handoff whose target agent has write tools. The user must confirm before auto-submit into a write-capable persona.

## Body content

- Body must be Markdown, CommonMark + GFM, per [`markdown.instructions.md`](markdown.instructions.md).
- Every Azure, Purview, PowerShell, or REST operation the body prescribes must carry an inline Microsoft Learn citation.
- Body must not include:
  - Secrets, tokens, keys, connection strings.
  - Real tenant / subscription / object IDs — use the zero-GUID placeholder per the "Environment and identifier boundaries" section.
  - Real customer, person, or production resource names — use the synthetic substitutes from [`sample-data.instructions.md`](sample-data.instructions.md).
- Body may reference other instruction files and prompt files via relative Markdown links so rules stay single-sourced.

## Naming

- File name: `<role>-<scope>.agent.md`, lowercase, hyphen-separated, per the "Naming convention" section of [`copilot-instructions.md`](../copilot-instructions.md).
- `<role>`: what the persona does — `reviewer`, `planner`, `operator`, `auditor`.
- `<scope>`: what it operates on — `datamap`, `infra`, `security`, `purview`.
- Examples: `reviewer-security.agent.md`, `operator-datamap.agent.md`, `planner-infra.agent.md`.

## Prohibited

- Authoring an agent with no `tools` field to "just use everything."
- Duplicating the behavior of an existing prompt file under `.github/prompts/` as an agent. Pick one primitive.
- Speculative agents with no current user. Remove them on review.
- `.chatmode.md` files. That extension is deprecated; use `*.agent.md`.
- Agents that shell out to delete, prune, or force-overwrite without `destructive` PR labeling and typed confirmation per the [MCP and tool-usage policy](../copilot-instructions.md).

## When drafting a new agent

1. Confirm the role can't be a prompt file or an instruction file — agents are for persistent personas with scoped tools and model preferences.
2. Start from the least-privilege tool set and add only what the role genuinely needs.
3. Cite every Learn page the body relies on.
4. Add the agent to the "Current agents" list in [`../agents/README.md`](../agents/README.md) in the same PR.
5. Validate by opening the file in VS Code — the Chat Customizations editor surfaces parse errors.

Reference: [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes), [Customize AI in VS Code](https://code.visualstudio.com/docs/copilot/customization/overview).
