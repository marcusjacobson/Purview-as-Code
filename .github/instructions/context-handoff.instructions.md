---
description: "Rules for preparing and resuming context handoffs when a chat session's context window is full, the topic is shifting, or work needs to pause cleanly. Pairs with /prepare-handoff and /resume-from-handoff."
applyTo: "**"
---

# Context handoff rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Pairs with [`prepare-handoff.prompt.md`](../prompts/prepare-handoff.prompt.md) and [`resume-from-handoff.prompt.md`](../prompts/resume-from-handoff.prompt.md). Applies whenever Copilot is asked to summarize the current chat for handoff to a new chat session, a different machine, or a different contributor.

> "Each session has its own context window. Creating a new session clears the history and starts a fresh context window." — [Manage chat sessions](https://code.visualstudio.com/docs/copilot/chat/chat-sessions).
>
> "If none of the context of a particular conversation is helpful, start a new conversation." — [Best practices for using GitHub Copilot](https://docs.github.com/en/copilot/get-started/best-practices).

A handoff brief is a short Markdown file under `.copilot-tracking/handoff/` that lets a fresh chat session resume mid-item without re-reading the entire prior conversation. It is **local-only** scratch — `.copilot-tracking/` is gitignored — and never lands in the repo or in a PR.

## When to hand off

The agent should suggest `/prepare-handoff`, and the author should accept, when **any** of the following is true. These are objective triggers, not vibes.

1. **Context-window pressure.** The VS Code chat input box's [context-window indicator](https://code.visualstudio.com/docs/copilot/chat/copilot-chat-context#_monitor-context-window-usage) is at or above its warning threshold (typically ≥80% full).
2. **Long tool-call trail.** The current session has accumulated more than ~30 tool calls (reads, searches, terminal commands), making earlier context likely stale or low-signal.
3. **Topic pivot.** Work shifts from one checklist item, file area, or plane to another (for example, from `infra/` Bicep to a `data-plane/` script). Per VS Code guidance, "start a new chat session when you want to change topics".
4. **Persona change.** The author wants to switch from an implementer flow (`/build-item`) to a reviewer flow (`/security-review`) and back, where carrying full implementer context into review adds noise.
5. **End of work session.** The author is stopping for the day mid-`/build-item`, or stopping between iterations, and wants a fast cold-start tomorrow.
6. **Handing to another contributor.** Another person (or another machine — different OS, different VS Code profile) needs to pick up the same item.

If none of these triggers apply, do **not** propose a handoff. A short conversation is its own best summary.

## Lifecycle placement

Handoffs slot **between iterations of `/build-item`** in the agent flow. They never replace the lifecycle agents.

- `@idea-intake` — kicks off a new branch. **Never** preceded by a handoff (there is no in-progress state to capture yet).
- `/build-item` — iterative implement-and-test. Handoff/resume slot **between iterations** of this prompt only.
- `@artifact-resolver` — commits, opens PR. **Never** preceded by a handoff (the PR description itself is the canonical artifact at that point).
- `@owner-approval` — applies `owner-approved`, merges, cleans up. **Never** preceded by a handoff (the PR is already the cross-contributor artifact).

A handoff is a private bridge for one author across one context-window break. The PR description is the public artifact for cross-contributor handoff once the build is done.

## What a brief MUST contain

Both `/prepare-handoff` and any hand-rolled brief must produce, in this order:

1. **Header** — branch name, upstream, `git rev-parse HEAD` (short SHA), generation timestamp (ISO 8601, local TZ).
2. **Checklist item** — the exact bullet from the Progress checklist in [`docs/project-plan.md`](../../docs/project-plan.md), quoted verbatim.
3. **Working-tree state** — output of `git status --short`. If empty, say "clean".
4. **What `/build-item` already validated** — table or bulleted list. One row per command, with the command, the touched path(s), and one of `pass` / `fail` / `not run`. No raw output dumps.
5. **What's left to do** — a concrete, single-paragraph next step. Not a wishlist. If the next step is not yet decided, say "decision needed: <one-sentence question>".
6. **Open decisions / blockers** — bulleted, each with one-sentence context. Includes any unanswered open-question ADR from the Progress checklist of `docs/project-plan.md` that this item touches (Q5/Q6/Q7 currently open).
7. **Exit criteria still pending** — bullets copied from the item's Exit criteria block on the GitHub issue linked from the `docs/project-plan.md` Progress checklist row that have not yet been verified.
8. **Pointers** — relative Markdown links to the files the next session will need first. **Links only**, not file contents.
9. **Resume command** — explicit one-liner, one of:
   - `/build-item` (default, mid-iteration).
   - `@artifact-resolver` (the build is complete; only commit/PR/merge remains).
   - `Draft an ADR under docs/adr/` (the next step is a docs-only design decision, not code).

## What a brief MUST NOT contain

A reviewer rejecting a malformed brief should cite this list.

- **Secrets.** Any value matching the secrets-scan regex from [`pre-commit.instructions.md`](pre-commit.instructions.md): `password|secret|key|token|pat|client[_-]secret|connectionstring`. The literal word "key" inside a sentence is fine; a value that looks like one is not. See [`security.instructions.md`](security.instructions.md).
- **Real identifiers.** Tenant IDs, subscription IDs, object IDs, real UPNs, real customer or partner names. Use the placeholders from the "Environment and identifier boundaries" section of [`copilot-instructions.md`](../copilot-instructions.md) (zero GUID, `contoso`, `user@contoso.com`, etc.).
- **Tool-call transcripts.** A handoff brief is not a chat export. Use [Chat: Export Chat...](https://code.visualstudio.com/docs/copilot/chat/chat-sessions#_export-a-chat-session-as-a-json-file) for that, separately, if needed.
- **Full file contents.** Link to the file at the right line range; never paste the file itself.
- **Speculation about work outside the current item.** A handoff describes one item, not a roadmap.
- **AI boilerplate.** "I hope this helps", "let me know what you think", "as requested".

## Filename and location

```text
.copilot-tracking/handoff/<branch>-<YYYYMMDD-HHmm>.md
```

Where `<branch>` is the current Git branch with `/` replaced by `-` (so `feat/w0-enable-unified-audit-log` becomes `feat-w0-enable-unified-audit-log`). Example:

```text
.copilot-tracking/handoff/feat-w0-enable-unified-audit-log-20260425-1530.md
```

The `.copilot-tracking/` directory is gitignored at the repo root. **Never** check a brief in. If a brief ever appears in `git status`, the gitignore is broken — fix it before doing anything else.

## Use the right VS Code primitive

Before reaching for `/prepare-handoff`, consider whether a built-in VS Code feature is the better tool. They cost less effort and produce no scratch file.

- [`/fork`](https://code.visualstudio.com/docs/copilot/chat/chat-sessions#_fork-a-chat-session) — creates a new chat session that inherits the current one's history. Good for "ask a side question without losing the main thread".
- [Chat: Export Chat...](https://code.visualstudio.com/docs/copilot/chat/chat-sessions#_export-a-chat-session-as-a-json-file) — full JSON dump. Good for archival; not for fast resume.
- [`/savePrompt`](https://code.visualstudio.com/docs/copilot/chat/chat-sessions#_save-a-chat-session-as-a-reusable-prompt) — generalizes a chat into a reusable `.prompt.md`. Good when the *workflow* is reusable; not when only *this run's state* is.
- [Checkpoints](https://code.visualstudio.com/docs/copilot/chat/chat-checkpoints) — roll back to a known-good state. Good for "this iteration went sideways, undo".

Use `/prepare-handoff` only when none of the above fits — typically when the goal is a cold-start brief readable by a different chat session (or a different contributor, or you tomorrow morning).

## Hard rules (agent must refuse to violate)

1. **Never commit a handoff brief.** The whole `.copilot-tracking/` directory is gitignored. If `git status` shows a brief, stop and confirm `.gitignore` is intact.
2. **Never include real secrets or real identifiers** in a brief. Redact to placeholders or omit the line.
3. **Never let `/prepare-handoff` modify the working tree.** It writes one Markdown file under `.copilot-tracking/handoff/`. Nothing else.
4. **Never let `/resume-from-handoff` skip precondition checks.** Branch name regex, upstream tracking, and clean-tree gates from `/build-item` apply on resume too.
5. **Never use a handoff to bypass `@idea-intake`.** A handoff is for *resuming* an item already in progress. A new item starts with `@idea-intake` from clean `main`.
6. **A brief is one-shot.** `/resume-from-handoff` deletes the brief after a successful Step 4 hand-off so it cannot be picked up a second time. The author may opt out for that single run by saying `keep brief`, but the default is self-destruct. Don't treat briefs as a paper trail — the PR description is the durable artifact.

## Reference

- [Manage chat sessions](https://code.visualstudio.com/docs/copilot/chat/chat-sessions) — context window, fork, export, savePrompt, checkpoints.
- [Best practices for using GitHub Copilot — Guide Copilot towards helpful outputs](https://docs.github.com/en/copilot/get-started/best-practices#guide-copilot-towards-helpful-outputs).
- [Use prompt files in VS Code](https://code.visualstudio.com/docs/copilot/customization/prompt-files) — why a one-shot task template is a prompt file, not an instruction or agent.
- [`primitives.instructions.md`](primitives.instructions.md) — primitive-selection rules.
