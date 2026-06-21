# Agent interaction guide

This guide explains how to interact with the Squad delivery framework agents in this repo. All agents share a common selectable-menu model for confirmation gates and handoffs, defined in [`.github/agents/INTERACTION-MENUS.md`](../.github/agents/INTERACTION-MENUS.md).

---

## Why menus?

Every confirmation gate and cross-agent handoff used to require typing a specific phrase (e.g., `file it`, `approve`, `@artifact-resolver`). Those typed phrases still work — they are always valid — but each gate now also presents a selectable menu so you never have to remember the exact phrase. A menu selection carries the same confirmation weight as typing the phrase.

---

## The four interaction patterns

### Pattern A — Confirmation gate

Used before any mutation: filing an issue, applying a label, deleting state.

1. The agent prints the **preview block** (issue draft, PR summary, etc.) unchanged.
2. A menu appears **after** the preview:
   - **[Affirmative — names the concrete effect]** (typed alias shown)
   - **[Revise…]** — reply with your edits; the agent re-shows the preview + menu
   - **[Cancel]** — no changes made

Silence, a follow-up question, or any non-affirmative reply cancels the gate.

### Pattern B — Handoff menu

Used when an agent hands off to the next agent in the lifecycle.

1. The agent prints the **completion block** (issue URL, PR URL, merge confirmation, etc.).
2. A menu appears with the next-agent options and a **[Stop here]** option.
   - Selecting a next agent auto-chains into it in the same session.
   - `[Stop here]` prints the typed `@agent` invocation for you to use later.

### Pattern C — Disambiguation menu

Used when multiple candidates match (e.g., two matching checklist rows, two open branches). Each candidate is numbered with a title and link. Always includes `None of these / cancel`.

### Pattern D — Interview menu

Used for multi-attribute data entry (e.g., picking a checklist row + a commit type, or choosing a content-creation interview). Each question is a separate single-select list, presented one at a time. The recommended default is listed first, labelled `(recommended)`. Free-form questions remain free-text. After the interview, the assembled proposal goes through a Pattern-A gate.

---

## Non-interactive surfaces (cloud agents, CLI)

When a native selectable list is unavailable, the agent prints a numbered text menu. For example, the `@idea-intake` file-it gate (Pattern A) renders as:

```text
[1] File it — create the branch and file the issue  (file it / yes)
[2] Revise… — describe the change in a reply
[3] Cancel  (cancel)
```

Reply with the number, the typed alias, or the full `@agent` invocation.

---

## Typed-phrase aliases — always valid

Every menu option maps to a historical typed phrase. You can type any of these at any time instead of selecting from the menu.

| Agent | Gate / handoff | Typed phrases |
| :--- | :--- | :--- |
| `@idea-intake` | §8 ADR gate (Step 0) | `yes` / `cancel` |
| `@idea-intake` | §6 Dependency gate (Step 0) | `yes` / `cancel` |
| `@idea-intake` | Step 5 — file-it gate | `file it` / `yes` / `cancel` |
| `@idea-intake` | Step 6 — handoff | `@artifact-resolver` |
| `@artifact-resolver` | Scope-creep gate (Step 2) | `split` / `narrow` / `cancel` |
| `@artifact-resolver` | Step 7 — handoff | `@owner-approval` |
| `@owner-approval` | Turn 1 → Turn 2 approval gate | `approve` / `approved` / `yes` / `y` / `confirm` / `cancel` |
| `@owner-approval` | Trigger phrases | `owner approved` / `approve PR` / `lgtm` / `approve and merge` |
| `@owner-approval` | Step 6 — next item | `@idea-intake` |
| `@squad` | Lifecycle handoff (rule 7) | `@idea-intake` / `@artifact-resolver` |
| `@squad` | Content-creation interview | `/add-classification` / `/add-data-source` |

---

## Typical session flow

```text
Lab owner types a request
        ↓
  @idea-intake
  ┌─ Step 0: §8 / §6 gates (Pattern A if blocked)
  ├─ Step 1: classify + interview (Pattern D for checklist row / commit type)
  ├─ Step 5: file-it gate (Pattern A)
  └─ Step 6: handoff menu (Pattern B) ─────────────┐
                                                    ↓
                                        @artifact-resolver
                                        ├─ Step 2: scope-creep gate (Pattern A if hit)
                                        └─ Step 7: handoff menu (Pattern B) ──────────┐
                                                                                      ↓
                                                                          @owner-approval
                                                                          ├─ Turn 1: approval gate (Pattern A)
                                                                          └─ Step 6: next-item menu (Pattern B)
```

---

## References

- [`INTERACTION-MENUS.md`](../.github/agents/INTERACTION-MENUS.md) — single-source contract for all patterns and the gate/handoff inventory.
- [`README.md`](../.github/agents/README.md) — agent index and authoring rules.
- [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes)
