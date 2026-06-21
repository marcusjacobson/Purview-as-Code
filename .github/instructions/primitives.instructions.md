---
description: "Guidance for selecting the correct Copilot customization primitive (instruction, prompt file, custom agent, or skill) before authoring."
applyTo: ".github/instructions/**/*.md,.github/prompts/**/*.md,.github/agents/**/*.md,.github/copilot-instructions.md,AGENTS.md"
---

# Primitive selection guidance

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). See also [`agents.instructions.md`](agents.instructions.md) for the agent-authoring rules.

When the user asks Copilot to create a "prompt", "agent", "instruction", "skill", or "workflow", Copilot must first confirm the user has picked the primitive that actually fits the problem. The four primitives are not interchangeable. If the request is suboptimal, say so with a citation, propose the better primitive, and ask whether to proceed.

## Decision matrix

| Primitive | Use when | File | Invocation |
|---|---|---|---|
| **Instruction** (`*.instructions.md` in `.github/instructions/`) | You want rules that apply automatically whenever a matching file is in context. Examples: "every Bicep file must pin an API version", "every PowerShell script must support `-WhatIf`". | `*.instructions.md` with `applyTo:` glob | Loaded in the background — no explicit invocation. |
| **Prompt file** (`.github/prompts/`) | You want a saved *task template* — a fixed sequence of steps to run on demand, then end. Examples: `/deploy-infra`, `/security-review`, `/add-classification`. | `*.prompt.md` | User types `/<name>` in chat. |
| **Custom agent** (`.github/agents/`) | You want a *persistent persona* with a restricted tool list, pinned model, or handoffs to other agents. The whole chat runs *in* the agent. Example: a reviewer persona that has read-only tools. | `*.agent.md` | User selects from the agents dropdown or is handed off. |
| **Agent skill** (`.agents/skills/` or similar) | You want a reusable, portable capability bundled with scripts and resources. Skills are loaded on demand by their description match. Example: `azure-deploy`, `azure-rbac`. | `SKILL.md` + supporting files | Agent reads the skill when it matches the task. |

## Checks Copilot must run before authoring

Before creating any new primitive, verify each of the questions below. If the answer points to a different primitive, stop and tell the user.

1. **Does the behavior need to be automatic, or explicit?**
   - Automatic (applied whenever a file matches) → **instruction**.
   - Explicit (run on demand) → **prompt** or **agent**.
2. **Is it a one-shot sequence, or a persistent persona?**
   - One-shot → **prompt file**.
   - Persistent persona with scoped tools or a pinned model → **agent**.
3. **Does it need a restricted tool list or handoffs to other roles?**
   - Yes → **agent** (only agents can scope `tools:` and define `handoffs:`).
   - No → **prompt file** is simpler.
4. **Does it bundle scripts or resources that other agents could reuse?**
   - Yes → **skill**.
   - No → **prompt file** or **agent**.
5. **Does an existing primitive already cover this?**
   - If the behavior overlaps with an existing instruction / prompt / agent, extend the existing file instead of creating a new one. Duplicate primitives drift.

## Common misroutes — push back on these

When the user asks for one of the patterns below, respond with the correction cited here.

- **"Make me a prompt that always applies to Bicep files."** That's an instruction, not a prompt. Prompts are explicit-invocation only. Cite [Custom instructions](https://code.visualstudio.com/docs/copilot/customization/custom-instructions).
- **"Make me an agent that runs this one sequence and exits."** That's a prompt file. Agents define a persona, not a task. Cite [Custom agents — Agents, prompt files, or skills?](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes).
- **"Make me an agent with all tools enabled."** Rejected under [`agents.instructions.md`](agents.instructions.md) — agents must declare a least-privilege `tools:` list. Propose the minimum surface the persona actually needs.
- **"Make me a prompt that restricts which tools Copilot can use."** Prompt files cannot scope tools the way agents can. If tool restriction is the goal, it's an agent.
- **"Rename `.github/prompts/` to `.github/agents/`."** They're distinct primitives per [Custom agents — Custom agent file locations](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_custom-agent-file-locations). Keep them separate.
- **"Add a new instruction file for this one-off task."** Instructions are always-on for matching files. A one-off is a prompt file.
- **"Create a reviewer agent that edits code."** A reviewer role must be read-only per [`agents.instructions.md`](agents.instructions.md). Propose a planner or implementer agent if editing is actually required, and ask the user which role they meant.
- **"Create a speculative agent / prompt / skill for a role we don't have yet."** Rejected per the "only make changes that are directly requested or clearly necessary" discipline. Wait until a real recurring use case emerges.
- **"Make me an agent for handing off context between chat sessions."** That's a one-shot task, not a persona — a prompt file. The repo already provides [`prepare-handoff.prompt.md`](../prompts/prepare-handoff.prompt.md) and [`resume-from-handoff.prompt.md`](../prompts/resume-from-handoff.prompt.md), governed by [`context-handoff.instructions.md`](context-handoff.instructions.md). Cite [Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files): "Use prompt files for lightweight, single-task prompts."

## How Copilot should respond when the request is suboptimal

1. Name the primitive the user asked for.
2. Name the primitive that actually fits, with one sentence on why.
3. Cite the Learn page that justifies the swap.
4. Ask whether to proceed with the corrected primitive, keep the original, or cancel. Do not silently substitute.

Reference: [Customize AI in VS Code — customization scenarios](https://code.visualstudio.com/docs/copilot/customization/overview), [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes), [Prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files), [Custom instructions in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-instructions).
