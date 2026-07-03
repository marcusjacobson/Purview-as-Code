# Custom agents (`.github/agents/`)

This folder holds workspace-scoped [custom agents](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes) for this repo. VS Code auto-discovers `*.agent.md` files here and surfaces them in the Copilot Chat agents dropdown.

## What belongs here

Custom agents are *personas with persistent behavior and scoped tools* — distinct from prompt files (task templates) and instructions (passive rules). Use an agent when:

- The role needs a restricted tool list (e.g., a reviewer that cannot write files).
- The role needs a specific model pinned (e.g., planning agent on a reasoning model).
- The role needs handoffs to other agents in a multi-step workflow.

For one-off scripted flows (deploy, add-classification, security-review), stay in [`../prompts/`](../prompts/).

## Authoring rules

Every new agent must conform to [`../instructions/agents.instructions.md`](../instructions/agents.instructions.md). In short:

- File name: `<role>-<scope>.agent.md`, lowercase hyphen-separated.
- Frontmatter must include `description`, `tools` (explicit allow-list), and `model`.
- Tools list must follow least privilege — no write tools without a documented justification in the body.
- Body must cite Microsoft Learn for any Azure or Purview operation it prescribes.
- Every confirmation gate and agent handoff must use the selectable-menu patterns defined in [`INTERACTION-MENUS.md`](INTERACTION-MENUS.md). Never define inline gate wording that diverges from that contract.

## Discoverability

Workspace agents live in `.github/agents/` per [Custom agent file locations](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes#_custom-agent-file-locations). Do not move them elsewhere — VS Code will stop finding them.

## Current agents

The Squad delivery framework agents (retrofitted from [bradygaster/squad](https://github.com/bradygaster/squad), adapted for this single-owner lab). Per [ADR 0014](../../docs/adr/0014-agents-as-default-entry-point.md), the three meta-workflow agents are the **default** entry point for all repo work; `@squad` is reserved for content-creation interviews and persona-led discussion.

### Tier 1 — Squad orchestrator (content creation)

| Agent | Purpose |
|---|---|
| [`squad`](squad.agent.md) | Persona orchestrator. Activates Lead/Architect, Security Specialist, Automation Engineer, Tester/Validator, or Scribe. Owns content-creation interviews (`/add-classification`, `/add-data-source`). Not a lifecycle agent. |

### Tier 2 — Meta-workflow agents (default lifecycle)

| Agent | Purpose |
|---|---|
| [`idea-intake`](idea-intake.agent.md) | Default front door. Classifies an idea, enforces the project-plan §6 / §8 gates inline when applicable, drafts a GitHub issue, creates and pushes the branch, pauses for confirmation before filing. |
| [`artifact-resolver`](artifact-resolver.agent.md) | Resolves one confirmed issue end-to-end: runs `/build-item` validation, stages scoped paths, runs secrets-scan, commits with Conventional Commits, pushes, opens a PR with `needs-review`. Never merges, never deploys live. |
| [`owner-approval`](owner-approval.agent.md) | Two-turn flow: apply `owner-approved`, wait for `pr-auto-merge.yml` to squash-merge, run local cleanup (`git branch -D`), confirm checklist tick, prompt for next item. Refuses on any reply except exact confirmation words. |

### Repository initialization (one-time, template only)

| Agent | Purpose |
|---|---|
| [`operator-kickoff`](operator-kickoff.agent.md) | **Kickoff.** Runs first on a fresh copy of the template. Lets the owner choose a local-only workspace or a spin-off GitHub repository, installs the [ADR 0045](../../docs/adr/0045-template-kickoff-spinoff-model.md) no-push-back guard so the copy can never contribute content back to the source template repository, verifies it, then hands off to `@operator-tenant`. Never deploys, never pushes. |
| [`operator-tenant`](operator-tenant.agent.md) | **Tenant Intake.** Runs once per copy, after `@operator-kickoff`. Interviews the owner for tenant values, writes `infra/parameters` and the identity-boundary statements, validates, and prints the GitHub-Secrets / OIDC checklist. Never stores a secret or real identifier, never deploys. |

Persona definitions and charters live under [`../../.squad/`](../../.squad/). The Squad framework conventions are documented in [`../../.squad/README.md`](../../.squad/README.md) and [`../../.squad/team.md`](../../.squad/team.md).

The selectable-menu contract for every agent confirmation gate and handoff is defined in [`INTERACTION-MENUS.md`](INTERACTION-MENUS.md). The lab-owner-facing guide is [`../../docs/agent-interaction-guide.md`](../../docs/agent-interaction-guide.md).

Reference: [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes).
