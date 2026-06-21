# Model-tier policy

> **Status:** Canonical. This document is the authoritative tier-to-array mapping referenced by [ADR 0043](../adr/0043-model-tier-policy.md). The ADR records the decision and rules; this file holds the live arrays so they can be updated on the review cadence without amending an immutable ADR.
> **Governed by:** [ADR 0043 — Model-tier policy](../adr/0043-model-tier-policy.md). Source: [agentic process modernization plan](agentic-process-modernization-plan.md) §"Model-tier policy".
> **Maintained by:** Lead / Architect persona, reviewed quarterly (see "Review cadence").

## Why tiers

Every workspace agent in [`.github/agents/`](../../.github/agents/) declares a `model:` field. The VS Code custom-agent header schema accepts a single model name or a prioritized array; with an array, VS Code tries each entry in order until an available one is found, per [Use custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional). A single hard-pinned model is a single point of failure: when that model is briefly unavailable, deprecated, or renamed, the agent breaks. Tiers express each agent's model preference as a vendor-mixed prioritized array so a transient outage degrades gracefully.

## Tiers

Each tier is a prioritized array of qualified `Model Name (vendor)` entries. VS Code tries them in order and uses the first available one.

| Tier | Use for | Prioritized `model:` array |
|---|---|---|
| `fast` | High-volume, deterministic, low-ambiguity work: label routing, merge-gate cleanup, ADR-index and script-reference regeneration, surface-diff loops. | `GPT-4.1 (copilot)` → `Claude Sonnet 4.5 (copilot)` → `Gemini 2.5 Flash (copilot)` |
| `balanced` | Default implement-and-validate work: `@idea-intake` classification, `@artifact-resolver` implementation, `@squad` orchestration, `/build-item` iteration. | `GPT-5 (copilot)` → `Claude Sonnet 4.5 (copilot)` → `Gemini 2.5 Pro (copilot)` |
| `reasoning` | Deep analysis: ADR authoring, `/security-review`, architectural design, the model-policy review itself. | `GPT-5.2 (copilot)` → `Claude Sonnet 4.6 (copilot)` → `Gemini 2.5 Pro (copilot)` |

## Agent-to-tier mapping

| Agent | Tier | Rationale |
|---|---|---|
| [`idea-intake`](../../.github/agents/idea-intake.agent.md) | `balanced` | Classifies input and drafts issues — default implement-and-classify work. |
| [`artifact-resolver`](../../.github/agents/artifact-resolver.agent.md) | `balanced` | Implements and validates one issue end-to-end — default implement-and-validate work. |
| [`squad`](../../.github/agents/squad.agent.md) | `balanced` | Persona orchestration and content-creation interviews — default work; individual personas may invoke deeper analysis on demand. |
| [`owner-approval`](../../.github/agents/owner-approval.agent.md) | `fast` | Deterministic, low-ambiguity merge-gate: apply a label, wait for auto-merge, clean up the local branch. |

## Rules

- **Arrays, not single names.** Every lifecycle and persona agent uses a prioritized array so a transient model outage degrades gracefully instead of breaking the agent.
- **Mix vendors.** Each array spans more than one vendor so no single vendor's availability is a single point of failure.
- **Behavior is the contract, not the model.** Tool lists and instruction bodies define what an agent may do. Changing a tier never widens an agent's tool surface.
- **Qualified names.** Use the `Model Name (vendor)` format, for example `GPT-5 (copilot)`, per the VS Code header schema.

## Vendor selection

The VS Code model picker exposes OpenAI, Anthropic, and Gemini (Google) as built-in third-party providers, plus Azure for bring-your-own-key, per [Manage language models in VS Code](https://code.visualstudio.com/docs/copilot/customization/language-models). The arrays above mix OpenAI, Anthropic, and Google Gemini. The exact identifiers are illustrative of the current picker as of the fetch date below and are reconciled by the quarterly review — VS Code skips any entry that is not currently available.

## Review cadence

The tier-to-array mapping is reviewed quarterly as its own `@idea-intake` item. The review:

1. Re-checks each array against the models actually offered in the VS Code model picker.
2. Updates the arrays in this file (and only this file) when a name is added, removed, or renamed.
3. Leaves the agent files unchanged unless an agent's tier assignment itself changes.

## References

- **[Use custom agents in VS Code — header schema](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional)**
  Fetch date: 2026-06-19
  > "Specify a single model name (string) or a prioritized list of models (array). When you specify an array, the system tries each model in order until an available one is found."
- **[Manage language models in VS Code](https://code.visualstudio.com/docs/copilot/customization/language-models)**
  Fetch date: 2026-06-19
  > "the provider you want is already listed (Azure, Anthropic, Gemini, OpenAI, and others)."
- [ADR 0043 — Model-tier policy](../adr/0043-model-tier-policy.md)
- [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) — required `model` frontmatter field.
