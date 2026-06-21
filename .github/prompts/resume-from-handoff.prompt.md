---
description: "Resume an in-progress checklist item in a fresh chat session by loading a brief from .copilot-tracking/handoff/, running precondition checks, and handing off to the correct downstream prompt. Pairs with /prepare-handoff."
mode: agent
---

# Resume from context handoff

Use this prompt at the **start of a fresh chat session** when the previous session ended with [`/prepare-handoff`](prepare-handoff.prompt.md) leaving a brief under `.copilot-tracking/handoff/`. This prompt finds the brief, verifies the working tree still matches it, restates the item to the author, and hands off to the right downstream prompt.

This prompt does **not** replace [`@idea-intake`](../agents/idea-intake.agent.md) — that's for new items from clean `main`. See [`.github/instructions/context-handoff.instructions.md`](../instructions/context-handoff.instructions.md).

## Step 1 — Find the brief

```pwsh
Get-ChildItem .copilot-tracking/handoff/*.md -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 5 FullName, LastWriteTime
```

- If no files match: stop. Tell the author "No handoff briefs found under `.copilot-tracking/handoff/`. Did you mean `@idea-intake` (new item) or `/build-item` (resume without a brief)?"
- If exactly one file matches: select it.
- If multiple match: list the top 5 newest with timestamp and the branch portion of the filename. Ask the author to pick one. Do not auto-select; the author may have abandoned briefs.

Read the selected brief end-to-end before doing anything else.

## Step 2 — Precondition checks against the brief

```pwsh
git branch --show-current
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
git status --short
git rev-parse --short HEAD
```

Compare against the brief's header:

- **Branch must match.** If the current branch differs from the brief's branch, stop and tell the author: "This brief is for `<brief branch>`. Current branch is `<current>`. Switch with `git checkout <brief branch>` or pick a different brief."
- **Upstream must match `origin/<branch>`.** If not, ask the author to push the branch.
- **Branch name regex.** Must match `^(feat|fix|chore|docs|refactor|ci|build|test|perf|revert)/(w[0-4]-)?[a-z0-9-]+$`. If not, the brief was generated from a non-conforming branch — stop and surface the inconsistency.
- **HEAD SHA may differ.** If `HEAD` is ahead of the brief's SHA, the previous session committed work that the brief does not describe. Show the author `git log --oneline <brief SHA>..HEAD` and ask whether to (a) regenerate the brief with a fresh `/prepare-handoff`, or (b) proceed with the older brief noting the drift.
- **Working tree may have drifted** since the brief. Show `git diff --stat <brief SHA>..HEAD` plus current `git status --short` and let the author confirm before continuing.

## Step 3 — Restate the item

Quote back to the author, in this exact shape:

```text
Resuming: <full quoted checklist row from brief>
Branch:   <branch> @ <current short SHA> (brief was @ <brief short SHA>)
Working tree: <clean | N files changed>
Next step (per brief): <one sentence>
Open blockers:
  - <blocker 1>
  - <blocker 2>
Resume command (per brief): <command>
```

Wait for the author to reply with one of:

- **`confirmed`** — proceed to Step 4.
- **A correction** — the brief is stale or the next step has changed. Stop. Tell the author: "Run `/prepare-handoff` first to refresh the brief, or proceed manually."
- **`abandon`** — leave the branch as-is and exit.

## Step 4 — Hand off

Based on the brief's resume command:

| Resume command in brief | Action |
|---|---|
| `/build-item` | Tell the author: "Now run `/build-item`. The brief's pointers section lists the files to open first." Do **not** invoke `/build-item` from inside this prompt — let the author start it explicitly so the next session has a clean Step A entry. |
| `@artifact-resolver` | Tell the author: "The build was already complete per the brief. Invoke `@artifact-resolver` to commit, push, and open the PR." |
| `Draft an ADR …` | Tell the author: "The next step is a docs-only design decision. Open `docs/adr/` and draft the ADR; no `/build-item` invocation needed yet." |
| Anything else | Stop. Surface the unrecognized resume command and ask the author for clarification. |

## Step 5 — Self-destruct the brief

A handoff brief is a one-shot artifact. Once Step 4 has handed off to the next prompt, the brief has served its purpose and must not linger in `.copilot-tracking/handoff/` to be picked up by a later `/resume-from-handoff` run by mistake.

After Step 4 completes successfully (the author has been told which downstream prompt to run), delete the brief:

```pwsh
Remove-Item -LiteralPath '<full path to the selected brief>' -Force
```

Then tell the author, in one line: `Brief consumed and deleted: <relative path>`. Nothing else.

Do **not** delete the brief if:

- Step 2 stopped on a precondition failure (branch mismatch, stale SHA the author hasn't acknowledged, etc.).
- Step 3 ended in a `correction` or `abandon` reply — the brief is still useful for the next attempt or as a record.
- The author explicitly says `keep brief` in Step 3. In that case, leave the file in place and tell them so.

**Stop here.** This prompt does not edit other files, does not commit, does not push, and does not start the build loop.

## Hard rules (agent must refuse to violate)

1. **Never auto-select a brief** when multiple are present. The author chooses.
2. **Never edit files** as part of the resume, other than the Step 5 self-destruct of the consumed brief itself.
3. **Never bypass `/build-item`'s precondition checks.** The downstream prompt will run them again; that is fine and intentional.
4. **Never resume on the wrong branch.** If the brief's branch and the current branch disagree, stop. Switching branches blindly may discard uncommitted work.
5. **Always self-destruct a successfully consumed brief** (Step 5), unless Step 2 stopped on an error, the author replied `correction`/`abandon` in Step 3, or the author said `keep brief`. A brief is one-shot; leaving it in place invites stale resumes.
6. **Never delete a brief that did not belong to this run.** Step 5 only removes the single file selected in Step 1. Do not bulk-delete `.copilot-tracking/handoff/`; the author owns that folder.
7. **Never use this prompt to start a new item.** If the brief looks like a kickoff template rather than a mid-build snapshot, stop and tell the author to invoke `@idea-intake` instead.
