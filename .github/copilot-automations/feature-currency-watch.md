# Feature-currency watch — automation prompt

This is the canonical prompt for the **feature-currency-watch** GitHub Copilot cloud-agent
automation (Slice 13, decided by [ADR 0044](../../docs/adr/0044-currency-watch-loops.md)). It is the
version-controlled source of truth — paste it verbatim into the automation's prompt field in the
GitHub UI per [`README.md`](README.md). When this file changes, re-paste it into the UI in the same
pull request.

The automation performs the recurring Microsoft Purview "what's new" review for the Purview-as-Code
lab. It is **read-only and issue-only**: its only permitted write is opening or commenting on a
single GitHub issue.

## Task

On each scheduled run:

1. Fetch [What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new) and
   read the entries published since the previous run (use the page's dated sections).
2. Read [`docs/project-plan.md`](../../docs/project-plan.md) section 3 (feature inventory) and
   section 7 (out of scope).
3. Identify two kinds of delta:
   - **Net-new features** — a Microsoft Purview feature on the What's new page that is **not** listed
     in section 3 and **not** already dispositioned in section 7.
   - **Newly as-code** — a feature currently tracked as portal-only that now documents a
     programmatic authoring surface (PowerShell, REST, or Microsoft Graph). Confirm the as-code claim
     against a Microsoft Learn page before reporting it.
4. For each delta, capture the Microsoft Learn link and a summary of 30 words or fewer.

## Output — open exactly one issue

- **Dedupe first.** Search open issues labeled `feature-currency`. If one is open, add a comment with
  the new findings instead of opening a second issue. If none is open and there are findings, open
  one. If there are no findings and no open issue, do nothing (stay silent).
- **Title:** `Feature-currency watch — Purview what's-new review`.
- **Body:** a `## Net-new features` section and a `## Newly as-code` section. Each item lists its
  Microsoft Learn link and the summary. If a section has nothing, write `None this run.` End with a
  reviewer checklist:
  - `- [ ] For each net-new feature, decide: add a project-plan section 5 row, add a section 7
    out-of-scope entry, or draft an ADR.`
  - `- [ ] For each newly-as-code item, decide whether to open a reconciler / automation item.`
- **Labels:** `feature-currency`, `squad:automation-engineer`, `squad:scribe`, `needs-review`.
- **Routing:** state in the body that the issue is an input to `@idea-intake` and flows through the
  unchanged `@idea-intake` → `/build-item` → `@artifact-resolver` → `@owner-approval` lifecycle.

## Hard rules

- **Issue-only.** Do not open a pull request, edit any file, or deploy. The only write you may perform
  is opening or commenting on one issue. This preserves the "loops produce issues only" invariant.
- **Ground every claim in Microsoft Learn.** If Learn does not document an as-code surface for a
  feature, say so explicitly rather than inferring one.
- **No secrets, no real identifiers.** Use the placeholders defined in the repo's
  `.github/copilot-instructions.md` (zero GUID, `contoso`, `user@contoso.com`).
- **Stay scoped.** Report deltas only; do not propose implementations, and do not act on the findings
  beyond opening the issue.

## References

- [ADR 0044 — Code- and feature-currency watch loops](../../docs/adr/0044-currency-watch-loops.md)
- [What's new in Microsoft Purview](https://learn.microsoft.com/en-us/purview/whats-new)
