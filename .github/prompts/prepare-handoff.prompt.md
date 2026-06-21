---
description: "Capture the current chat's progress on an in-progress checklist item into a short brief under .copilot-tracking/handoff/ so a fresh chat session can resume cleanly. Pairs with /resume-from-handoff."
mode: agent
---

# Prepare context handoff

Use this prompt **between iterations of [`/build-item`](build-item.prompt.md)** when the chat session needs to end before the build is complete — typically because the context window is full, the topic is shifting, or the work is pausing for the day. Produces one Markdown brief under `.copilot-tracking/handoff/` that a future chat session can load with [`/resume-from-handoff`](resume-from-handoff.prompt.md).

This prompt is **not** for finished items (use [`@artifact-resolver`](../agents/artifact-resolver.agent.md) and then [`@owner-approval`](../agents/owner-approval.agent.md)) and **not** for starting new ones (use [`@idea-intake`](../agents/idea-intake.agent.md)). See [`.github/instructions/context-handoff.instructions.md`](../instructions/context-handoff.instructions.md) for the full ruleset.

## Inputs the agent must confirm with the user

Before doing anything else, ask for and echo back:

1. **Trigger.** Which of the handoff triggers from [`context-handoff.instructions.md` §When to hand off](../instructions/context-handoff.instructions.md#when-to-hand-off) applies? If none does, say so and ask the author whether to proceed anyway or abandon the prompt.
2. **Resume target.** Which prompt or agent should the resume call hand off to: `/build-item` (default), `@artifact-resolver` (the build is done; commit/push/PR remains), or `Draft an ADR` (the next step is a design decision, not code)?

Wait for confirmation before continuing.

## Step 1 — Precondition checks

```pwsh
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
git status --short
git rev-parse --short HEAD
```

- Current branch must match `^(feat|fix|chore|docs|refactor|ci|build|test|perf|revert)/(w[0-4]-)?[a-z0-9-]+$`. If it does not, stop and tell the author this is not an in-progress item branch — there is nothing to hand off.
- Upstream must be `origin/<same branch>`. If not, ask the author to push the branch first (`@idea-intake` Step 6 should already have done this).
- Working tree may be clean or dirty. Either is fine. If clean, the brief should call out "no in-flight edits — handoff is for context only".

Confirm the `.copilot-tracking/handoff/` directory is gitignored:

```pwsh
git check-ignore -v .copilot-tracking/handoff/test.md
```

The output must reference the `.copilot-tracking/` line in `.gitignore`. If it does not, **stop**. Surface the gitignore problem to the author and refuse to write the brief — `.gitignore` must be fixed first (this prompt cannot ship a brief that risks landing in source).

## Step 2 — Gather the brief contents

Do not run new tool calls just to populate the brief; use what is already in chat history. The exception is the small set of `git` commands above, which are cheap and authoritative. If a required field cannot be filled from existing context, write `unknown — populate before resume` rather than fabricating.

Required fields, per [`context-handoff.instructions.md` §What a brief MUST contain](../instructions/context-handoff.instructions.md#what-a-brief-must-contain):

1. **Header** — branch, upstream, short SHA, ISO 8601 local timestamp.
2. **Checklist item** — quoted verbatim from [`docs/project-plan.md`](../../docs/project-plan.md) Progress checklist. If you cannot find it, ask the author.
3. **Working-tree state** — `git status --short` output, or "clean".
4. **What `/build-item` already validated** — short table: `command | path | result`. No raw output.
5. **What's left to do** — one paragraph, concrete next step.
6. **Open decisions / blockers** — bulleted, including any open-question ADR from the Progress checklist (none in the template — populate as you adopt).
7. **Exit criteria still pending** — bullets from the GitHub issue's Exit criteria block linked from the `docs/project-plan.md` Progress checklist row.
8. **Pointers** — relative Markdown links to the files the next session will read first.
9. **Resume command** — explicit one-liner, one of: `/build-item`, `@artifact-resolver`, or `Draft an ADR`.

## Step 3 — Apply redaction

Before writing the file, redact:

- Any value matching `password|secret|key|token|pat|client[_-]secret|connectionstring` that looks like a real value (not a comment word).
- Any 32-character hex / GUID that is not the zero placeholder, not a Microsoft-published role-definition ID, and not a Bicep schema example.
- Any real UPN, tenant name, subscription name, or customer name. Replace with the placeholders from the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../copilot-instructions.md).

If redaction would gut a field beyond usefulness, write `redacted — see <secure source>` and stop.

## Step 4 — Write the file

Path:

```text
.copilot-tracking/handoff/<branch-with-dashes>-<YYYYMMDD-HHmm>.md
```

`<branch-with-dashes>` is the current branch with `/` replaced by `-`. Timestamp is local time, not UTC, to match the author's working hours.

If the directory does not exist, create it. The directory is gitignored, so creating it is safe.

If a brief with the same exact filename already exists (same minute on the same branch), stop and ask the author whether to overwrite or pick a fresh timestamp.

## Step 5 — Verify and announce

Re-read the file you just wrote. Confirm:

- All nine sections from Step 2 are present.
- No real secrets, no real GUIDs, no real UPNs.
- No file contents pasted inline (links only).

Then post a short status to chat:

```text
Handoff brief written: .copilot-tracking/handoff/<filename>.md
Branch: <branch> @ <short SHA>
Resume with: /resume-from-handoff
```

**Stop here.** Do not begin a new build iteration, do not commit, do not push, do not open a PR.

## Hard rules (agent must refuse to violate)

1. **Never commit the brief.** It lives under `.copilot-tracking/`, which is gitignored. If the brief ever shows in `git status`, stop and fix `.gitignore` first.
2. **Never write the brief if `.copilot-tracking/` is not gitignored.** Step 1's `git check-ignore` is the gate.
3. **Never include real secrets or real identifiers.** Redact or omit. See Step 3.
4. **Never run new validation commands** (`Deploy-*.ps1 -WhatIf`, `az deployment group what-if`, `Invoke-ScriptAnalyzer`, etc.) just to populate the brief. The brief reflects what already happened.
5. **Never modify files outside `.copilot-tracking/handoff/`.** This prompt is a writer of one Markdown file. It is not a builder, committer, or pusher.
6. **Never use this prompt as a substitute for a PR description.** When the build is done, hand off to `@artifact-resolver`. The PR description is the canonical cross-contributor artifact; the handoff brief is a private, single-author bridge.
