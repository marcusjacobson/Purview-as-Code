# Agent interaction menus — single-source contract

This file is the **single-source-of-truth** for how every agent in `.github/agents/` presents choices, confirmation gates, and handoff prompts to the lab owner. All agents reference this file; no agent defines its own menu format inline.

User-facing guide: [`docs/agent-interaction-guide.md`](../../docs/agent-interaction-guide.md).

---

## Core principles

1. **A menu selection IS the explicit confirmation** — same force and audit weight as typing the gate word it replaces. It is an explicit, recorded user action, not implicit consent.
2. **Preview first, always** — the existing Turn-1 preview / proposal / diff block is printed unchanged, and the menu appears **after** it, never instead of it.
3. **No implicit confirmation** — silence, follow-up questions, or unrelated content never confirm. Only an affirmative selection (or its typed alias) proceeds. Cancel / dismiss leaves all state untouched.
4. **Surface parity** — render the same selectable list on every interactive surface (VS Code Copilot Chat and the GitHub Copilot CLI). One consistent experience.
5. **Typed-phrase aliases always remain valid** — every option maps to its historical typed phrase / `@agent` invocation; typing it yields the identical result (muscle memory + non-interactive fallback).

---

## Mechanism

**Primary (interactive surfaces):** present a native selectable choice list using the host session's prompt affordance. No new tool token is required — do not invent a prompt tool or change any agent `tools:` frontmatter; interactive prompting is a host affordance, not a repo-defined tool.

**Fallback (non-interactive / cloud agent surfaces):** print a numbered text menu where each line is `[n] <label> (<typed alias / invocation>)`, accepting the digit, the alias, or the full invocation. Option content is identical across surfaces; only rendering differs.

**Label character set (all surfaces):** interactive menu / choice **labels** (the bracketed selectable text and its rendered separators) must be **ASCII-only**. Do not use em-dashes (`—`), en-dashes (`–`), ellipsis (`…`), or smart quotes inside a label — some interactive menu hosts render them as literal escapes (e.g. `\u2014`), which is meaningless to the user. Use `:`, `-`, `(` `)`, or `...` instead. This applies to labels only; ordinary prose elsewhere may use normal punctuation.

---

## The four patterns

### Pattern A — Confirmation-gate menu (two-turn mutation gates)

Print the preview block (unchanged). Then present a menu ordered:

1. `[affirmative that names the concrete effect]` (typed alias)
2. `[Revise...]` (describe the change in a reply)
3. `[Cancel]` (type `cancel` or just don't reply)

Affirmative selection → run the mutation exactly as the typed phrase would. Revise → apply edits and re-present preview + menu. Cancel / any non-affirmative → do nothing, state nothing changed, stop. Any sanity re-checks an agent already runs between preview and mutation are preserved.

### Pattern B — Handoff menu (cross-agent next step)

Print the completion / report block. Then present a menu of next-agent action(s) plus a `Stop here` item. Selecting a next step **auto-chains** into that agent in the same session (the selection IS the explicit request; the downstream agent then runs its own Pattern-A gate). Auto-chain only on affirmative selection, never silently. `Stop here` → print the equivalent typed `@agent` invocation for later reference and stop.

### Pattern C — Disambiguation menu (pick one of N)

Present candidates as a selectable list (each item: number + title + URL, or branch + linked issue). Selection adopts that candidate and continues to the agent's Pattern-A gate. Always include `None of these / cancel`.

### Pattern D — Interview menu (one selectable question per attribute)

Ask each enumerated-option question as its own single-select list, one at a time in a documented order; mark the recommended default as the first item labelled `(recommended)`. Genuinely free-form questions stay free-text. After the interview, present the assembled proposal through a Pattern-A gate.

---

## Cloud / non-interactive fallback

On any surface where a native selectable list is unavailable (e.g., a cloud coding agent assigned to an issue), print the numbered text menu format described under Mechanism. Accept digit, alias, or full invocation.

Example rendering for a Pattern-A gate:

```text
[1] File it: create the branch and file the issue  (file it / yes)
[2] Revise...: describe the change in a reply
[3] Cancel  (cancel)
```

---

## Authoring rule for agents

When editing or adding an agent:

- **KEEP** its preview / report block.
- **Replace** any `"Reply with one of: …"` block with `"Present a selectable menu per INTERACTION-MENUS.md (Pattern A/B/C/D), options: …"` plus the agent's specific option set.
- **Keep** the typed-phrase aliases listed alongside each option.
- **Keep labels ASCII-only** — no em-dash / en-dash / ellipsis / smart quotes inside a bracketed label or its separator (see "Label character set" under Mechanism). Use `:`, `-`, `(` `)`, or `...`.
- **Never weaken a gate** — affirmative selection has the same enforcement weight as a typed phrase.

---

## Gate/handoff inventory

Quick-reference of every retrofitted point in this repo. Agents inline the Pattern letter and specific options; this table is the index.

| Agent | Point | Pattern | Typed aliases |
| :--- | :--- | :--- | :--- |
| `idea-intake` | §8 ADR gate redirect (Step 0a) | A | `yes` / `cancel` |
| `idea-intake` | §6 Dependency-gate redirect (Step 0a) | A | `yes` / `cancel` |
| `idea-intake` | Step 1 — checklist row + commit type confirm | D | (free-text for row; type name for commit type) |
| `idea-intake` | Step 5 — file-it gate | A | `file it` / `yes` / `cancel` |
| `idea-intake` | Step 6 — handoff to `@artifact-resolver` | B | `@artifact-resolver` |
| `artifact-resolver` | Step 2 — out-of-scope scope-creep gate | A | `split` / `narrow` / `cancel` |
| `artifact-resolver` | Step 7 — handoff to `@owner-approval` | B | `@owner-approval` |
| `owner-approval` | Turn 1 → Turn 2 approval gate | A | `approve` / `approved` / `yes` / `y` / `confirm` / `cancel` |
| `owner-approval` | Step 6 — post-merge next item | B | `@idea-intake` |
| `squad` | Rule 7 — lifecycle handoff | B | `@idea-intake` / `@artifact-resolver` |
| `squad` | Content-creation interview selection | D | `/add-classification` / `/add-data-source` |
