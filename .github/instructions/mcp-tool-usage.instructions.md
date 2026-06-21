---
description: "Rules that govern when and how Copilot may invoke Azure MCP tools, Azure CLI commands, Azure PowerShell cmdlets, and agent skills in this repo."
applyTo: "**"
---

# MCP and tool-usage policy

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Applies to every chat turn. Agent-specific tool-scoping rules live in [`agents.instructions.md`](agents.instructions.md).

This repo's target is a live Azure subscription (`contoso-lab`) and a live Microsoft Purview account. The rules below govern when and how Copilot may invoke Azure MCP tools, Azure CLI commands, Azure PowerShell cmdlets, and agent skills while working in this repo.

## Default stance — read-only

Without an explicit write instruction in the current user turn, Copilot may only run tool calls that **read** state. Acceptable without extra confirmation:

- `az ... list`, `az ... show`, `az ... get-*`
- `Get-*` PowerShell cmdlets, `Invoke-RestMethod -Method GET`
- `az deployment group what-if`, `az bicep lint`, `az bicep build`
- `./Deploy-*.ps1 -WhatIf`
- Azure Resource Graph queries, pricing lookups, schema/type lookups, best-practices lookups
- AppLens / diagnostics / advisor queries

## Writes require an explicit in-turn instruction

Copilot may only invoke a write-capable tool (create, update, patch, delete) when the user's **current turn** asks for that specific action. "Continue," "proceed," "looks good," or referencing an earlier turn is not sufficient for a write. Examples of acceptable write triggers:

- "Run `az deployment group create` for the main.bicep change."
- "Apply the Deploy-Collections.ps1 plan."
- "Create the missing role assignment for the managed identity."

## Destructive writes require typed confirmation

A destructive tool call is one that:

- Deletes any Azure resource, role assignment, or Purview object.
- Runs `az deployment group create` where the most recent `what-if` reports a `Delete` action.
- Runs any `Deploy-*.ps1` with `-PruneMissing` or `-Force`.
- Drops, overwrites, or re-parents a collection in Purview.

Before invoking a destructive tool call, Copilot must:

1. Summarize exactly which objects will be removed or overwritten.
2. Ask the user to reply with an unambiguous confirmation token (e.g., `confirm delete`) in the same conversation.
3. Not proceed on implicit approval, "yes" to an unrelated question, or a quoted earlier message.

## Skill allow-list for this repo

The following agent skills are in scope for this repo:

- `azure-prepare`, `azure-validate`, `azure-deploy` — for the control-plane Bicep workflow.
- `azure-rbac` — for role-assignment guidance grounded in [Purview roles](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).
- `azure-compliance` — for periodic security and best-practice review.
- `azure-resource-lookup` — for read-only inventory against the lab subscription.
- `azure-diagnostics` — only when triaging a live failure; read-only.
- `azure-cost` — read-only cost and pricing queries.

Skills **not** in scope for this repo (do not invoke without an explicit user request that names the skill):

- `azure-hosted-copilot-sdk`, `microsoft-foundry` — not applicable; no AI-app workload here.
- `azure-kubernetes`, `azure-compute`, `azure-storage`, `azure-messaging` — not applicable; Purview resource only.
- `azure-enterprise-infra-planner` — too broad for the single-account topology this repo targets.
- `azure-cloud-migrate`, `azure-upgrade` — not applicable; no cross-cloud or SKU migration in scope.

## What Copilot must not do

- Run a write tool call "to be helpful" after a read-only question.
- Chain a write after a read ("I listed the collections, then I cleaned up the stale ones").
- Invoke a Foundry, AKS, or other out-of-scope skill to "enrich" an answer.
- Use the MCP pricing or advisor tools to pull real tenant IDs or subscription IDs into chat output — redact to the zero-GUID placeholder per the "Environment and identifier boundaries" section of [`copilot-instructions.md`](../copilot-instructions.md).

## Rules for the agent

- When in doubt, prefer a read-only tool call and surface the result; let the user decide whether to mutate.
- When proposing a write, paste the exact command and its expected effect before invoking it.
- When a tool returns a secret, token, connection string, or real identifier, redact it before echoing into chat or files.
- Custom agents defined under [`.github/agents/`](../agents/) narrow the tool surface via their `tools:` frontmatter but do not bypass this policy. Writes still require an explicit user instruction in the current turn; destructive writes still require typed confirmation. Authoring rules live in [`agents.instructions.md`](agents.instructions.md).

Reference: [Use MCP servers in VS Code](https://code.visualstudio.com/docs/copilot/chat/mcp-servers), [Azure MCP Server overview](https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/overview).
