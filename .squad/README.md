# Squad — Personal Lab (contoso-lab) × contoso (solo)

The `.squad/` directory contains the human-readable definitions of the Squad personas that power the AI delivery framework for this personal Microsoft Purview lab. It is the authoritative reference for who does what, how decisions are made, and what the current lab context is.

The Squad model is adapted from [bradygaster/squad](https://github.com/bradygaster/squad) and from the upstream [`MSFT-Consultant-Project-Template`](https://github.com/contoso/MSFT-Consultant-Project-Template). The template targets paid customer engagements with a delivery partner and a separate consultant role; this repo strips that framing and runs as a single-owner lab.

---

## Contents

| Path | Purpose |
|---|---|
| [`team.md`](team.md) | Defines all five Squad personas: roles, responsibilities, decision authority, and interaction rules |
| [`charters/`](charters/) | One charter per persona — detailed scope, deliverables, handoff rules, and authoring instructions |
| [`memory/context.md`](memory/context.md) | Current lab context (maintained by the Scribe) |
| [`memory/decisions.md`](memory/decisions.md) | Decision log (maintained by the Scribe) |

---

## How the Squad model works

The Squad consists of five personas operating as a team under lab-owner oversight:

1. **Lead / Architect** — architecture, ADRs, governance, owner-facing summaries, tiebreaker
2. **Security Specialist** — Microsoft Purview security and compliance configuration design
3. **Automation Engineer** — PowerShell, Microsoft Graph and Purview REST API integration, scheduling, reporting
4. **Tester / Validator** — validation, test scenarios, lab smoke QA, exit-criteria verification
5. **Scribe** — memory and decision log maintenance (no decision authority)

Personas are adopted by the [`@squad` agent](../.github/agents/squad.agent.md) (and by `@artifact-resolver`) during task execution. Each persona loads its charter before producing output.

The upstream template also defines a `Data Engineer` persona for customer-side data-source onboarding. This lab retrofit drops that persona — its responsibilities (data-source registration, scan configuration, classification schema) are absorbed by the Automation Engineer because in a single-owner lab they are not a distinct role. See [`memory/decisions.md`](memory/decisions.md).

---

## Human-in-the-loop checkpoints

The following actions **always** require explicit lab-owner approval before proceeding:

| Checkpoint | Gate mechanism |
|---|---|
| Label taxonomy or policy enforcement changes | `owner-approved` label on PR |
| New ADR or change to existing ADR status | `owner-approved` label on PR |
| Architecture direction change | `owner-approved` label on PR |
| Production-shaped lab change to `contoso.onmicrosoft.com` | `owner-approved` label on PR |
| Any merge to `main` | `owner-approved` label on PR |

The `owner-approved` label is gated to `actor.login == 'contoso'` by [`.github/workflows/pr-owner-gate.yml`](../.github/workflows/pr-owner-gate.yml). Only the lab owner may apply it.

---

## Engaging the Squad

1. **File an idea:** Use `@idea-intake` in GitHub Copilot Chat to classify, draft, and file an issue.
2. **Resolve an issue:** Use `@artifact-resolver` to implement the artifact end-to-end.
3. **Approve a PR:** Use `@owner-approval` or run `gh pr edit <N> --add-label owner-approved`.
4. **Orchestrate personas:** Use `@squad` in chat for interactive multi-persona work.

Reference: [bradygaster/squad](https://github.com/bradygaster/squad), [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes).
