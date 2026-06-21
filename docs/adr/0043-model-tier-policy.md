# 0043 — Model-tier policy: prioritized model arrays across lifecycle and persona agents

- **Status:** Accepted
- **Date:** 2026-06-19
- **Gates:** Slice 3 of the [agentic process modernization plan](../governance/agentic-process-modernization-plan.md) (tracking issue [#680](../../issues/680); slice issue [#687](../../issues/687)). Establishes [`docs/governance/model-policy.md`](../governance/model-policy.md) as the canonical tier-to-array mapping and converts the `model:` field on all four [`.github/agents/`](../../.github/agents/) `*.agent.md` files from a single pinned model to a prioritized array.
- **Deciders:** @contoso

## Context

Every workspace agent in [`.github/agents/`](../../.github/agents/) currently hard-pins a single model: `model: GPT-5 (copilot)`. The models offered in the VS Code Chat model picker change over time, and a single hard-pinned model fails the agent when that one model is briefly unavailable, deprecated, or renamed.

The VS Code custom-agent header schema accepts more than a single string for `model`. Per [Use custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional):

> "The AI model to use when running the prompt. Specify a single model name (string) or a prioritized list of models (array). When you specify an array, the system tries each model in order until an available one is found."

Qualified model names use the format `Model Name (vendor)` — for example `GPT-5 (copilot)` or `Claude Sonnet 4.5 (copilot)`. The repo's agent-authoring rules already permit this: [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) requires the `model` field and states it may "Pin a model **or prioritized list**".

The [agentic process modernization plan](../governance/agentic-process-modernization-plan.md) §"Model-tier policy" defines three tiers (`fast`, `balanced`, `reasoning`), each a vendor-mixed prioritized array, and a recurring review cadence. This ADR ratifies that design and records the concrete decision; the live arrays live in the canonical policy doc, not here.

## Decision

We will standardize three model tiers and express each agent's `model:` field as a prioritized, vendor-mixed array drawn from those tiers.

1. **Three tiers.** `fast` (high-volume, deterministic, low-ambiguity work), `balanced` (default implement-and-validate work), and `reasoning` (deep analysis). Each tier is a prioritized array of qualified `Model Name (vendor)` entries.

2. **Canonical mapping lives in the policy doc.** [`docs/governance/model-policy.md`](../governance/model-policy.md) is the single source of truth for the concrete tier-to-array mapping and the per-agent tier assignment. This ADR records the decision and the rules; the policy doc holds the live arrays so they can be updated on the review cadence without amending an immutable ADR.

3. **Per-agent tier assignment.** `idea-intake` → `balanced`, `artifact-resolver` → `balanced`, `squad` → `balanced`, `owner-approval` → `fast`. The merge-gate agent (`owner-approval`) does deterministic, low-ambiguity label-and-cleanup work, so it takes the `fast` tier; the three implement-and-classify agents take `balanced`.

4. **Rules that make this durable.**
   - **Arrays, not single names.** Every lifecycle and persona agent uses a prioritized array so a transient model outage degrades gracefully instead of breaking the agent.
   - **Mix vendors.** Each array spans more than one model vendor so no single vendor's availability is a single point of failure.
   - **Behavior is the contract, not the model.** Tool lists and instruction bodies define what an agent may do. Changing a tier never widens an agent's tool surface.
   - **Recurring review.** The tier-to-array mapping is reviewed on a fixed cadence (quarterly) as its own `@idea-intake` item that re-checks each array against the models actually offered in the VS Code model picker and updates the policy doc.

5. **Vendor selection.** The modernization plan illustratively named "Microsoft MAI, OpenAI GPT, and Anthropic Claude". The VS Code model picker exposes OpenAI, Anthropic, and Gemini (Google) as built-in third-party providers (plus Azure for bring-your-own-key), per [Manage language models in VS Code](https://code.visualstudio.com/docs/copilot/customization/language-models). The policy therefore mixes OpenAI, Anthropic, and Google Gemini to satisfy the vendor-diversity intent. Because illustrative identifiers are not authoritative, the quarterly review reconciles the exact names against the live picker.

## Consequences

### Positive

- A transient single-model or single-vendor outage degrades gracefully: VS Code falls through to the next available entry instead of breaking the agent.
- The current `GPT-5 (copilot)` pin is preserved as the primary entry of the `balanced` tier, so the three balanced agents keep their existing behavior and merely gain fallbacks.
- Tool lists and instruction bodies are untouched — the behavior contract is unchanged.

### Neutral

- Model identifiers drift as the picker changes. The quarterly review owns reconciliation; VS Code's try-each-until-available behavior makes a stale entry non-fatal (it is skipped).
- The policy doc, not this ADR, is where future array edits land. The ADR stays immutable.

### Risk

- None beyond normal PR review. No tool surface is widened, no live Purview object is touched, no OIDC credential is changed.

## Alternatives considered

1. **Keep a single pinned model (status quo).** Rejected: a single model is a single point of failure — when it is briefly unavailable, the agent has no fallback.
2. **Single-vendor prioritized array (e.g., only the GPT family).** Rejected: it survives one model outage but not a vendor-wide outage; the modernization plan requires vendor diversity.
3. **Omit the `model` field and rely on the picker default.** Rejected: it violates the [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) required-frontmatter rule and makes shared-agent behavior depend on each contributor's picker selection.

## References

- **[Use custom agents in VS Code — header schema](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_header-optional)**
  Fetch date: 2026-06-19
  > "The AI model to use when running the prompt. Specify a single model name (string) or a prioritized list of models (array). When you specify an array, the system tries each model in order until an available one is found."
- **[Manage language models in VS Code](https://code.visualstudio.com/docs/copilot/customization/language-models)**
  Fetch date: 2026-06-19
  > "the provider you want is already listed (Azure, Anthropic, Gemini, OpenAI, and others)."
- [`agents.instructions.md`](../../.github/instructions/agents.instructions.md) — required `model` frontmatter field ("Pin a model or prioritized list").
- [`docs/governance/agentic-process-modernization-plan.md`](../governance/agentic-process-modernization-plan.md) — Slice 3 source.
- [Issue #687](../../issues/687) — Slice 3 work item.
