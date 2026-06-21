---
description: "Writing and formatting rules for Markdown files in this repository."
applyTo: "**/*.md"
---

# Markdown / docs writing rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). See also [`sample-data.instructions.md`](sample-data.instructions.md) for rules on synthetic examples and [`pull-request.instructions.md`](pull-request.instructions.md) for PR description formatting.

Applies to every `.md` file in the repo: `README.md`, `docs/**`, `.github/**/*.md`, and any ad-hoc notes. Follows [CommonMark](https://spec.commonmark.org/current/) + [GitHub Flavored Markdown](https://github.github.com/gfm/) and aligns with the [Microsoft Writing Style Guide](https://learn.microsoft.com/en-us/style-guide/welcome/) where technical content references Microsoft products.

## Voice and tone

- Direct, technical, imperative. Assume the reader is a competent engineer.
- Describe systems in present tense ("The script registers data sources.") not future ("The script will register…").
- No filler: drop phrases like "please note", "as you can see", "in conclusion", "this document will explain".
- Do not refer to the AI agent in prose. If attribution is needed, use `Co-authored-by:` in the commit.

## Structure

- Exactly one H1 per file, matching the document's primary subject.
- Do not skip heading levels (H1 → H2 → H3, never H1 → H3).
- Use sentence case for headings, not title case: `## Project layout`, not `## Project Layout`.
- Keep lines reasonably short (around 100–120 characters). Hard-wrap long paragraphs when it aids diff review; leave long URLs intact.

## Links

- Prefer **relative links** for anything inside the repo: `[docs/getting-started.md](../../docs/getting-started.md)`. Never link to this repo by its `https://github.com/...` URL.
- External links use full HTTPS URLs.
- Microsoft Learn is the preferred source for Azure / Purview references. When citing Learn, use the human-readable page title as the link text:
  - Good: `[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)`
  - Bad: `[click here](https://learn.microsoft.com/...)`
- Do not invent URLs. If a reference is uncertain, omit it or flag `<!-- TODO: verify Learn URL -->`.

## Code blocks

- Always declare a language on fenced code blocks: ` ```bicep `, ` ```pwsh `, ` ```yaml `, ` ```text `, ` ```json `.
- Use `pwsh` (not `powershell`) for PowerShell 7+ snippets that are the canonical shell in this repo.
- Inline code for file names, command names, parameter names, identifiers: `` `infra/main.bicep` ``, `` `-WhatIf` ``, `` `publicNetworkAccess` ``.
- Do not paste the output of a command unless it is an illustrative example; for PR validation evidence, use the PR description, not `docs/`.

## Tables

- Use GFM pipe tables with a header row and a separator row.
- Keep tables navigable: left-align text columns (` :--- `), right-align numeric columns (` ---: `). Center only when it materially aids readability.

## Lists

- Use `-` for unordered lists (consistent across the repo). Don't mix `*` / `+` / `-`.
- Use numbered lists for ordered procedures; do not manually renumber after insertion (let rendering handle it, but keep the source readable).
- Task lists (`- [ ]`) are reserved for PR templates, checklists, and issue templates.

## Emojis

Emojis are allowed when they add genuine visual context to a status, warning, or category marker — and they must remain rare. Examples of acceptable use:

- ⚠️ callouts in a hazard list
- ✅ / ❌ markers in a compatibility matrix

Do not use emojis:

- in H1–H3 headings
- in commit messages (see [`commit-message.instructions.md`](commit-message.instructions.md))
- as decoration (🎉, 🚀, 🔥, ✨, 👉) in prose
- more than one per bullet or paragraph

When in doubt, leave the emoji out. Prose should stand on its own.

## Microsoft Learn citations

Every new technical claim about an Azure or Microsoft Purview resource, API, CLI command, or behavior must cite a Microsoft Learn page. See `.github/copilot-instructions.md` → "Grounding — Microsoft Learn is the central source of truth" for the precedence rules.

- Inline: `[Microsoft.Purview/accounts](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts)`
- Reference-style is acceptable when the same link is used multiple times.
- If Learn is silent on a topic, say so explicitly: `Not documented on Microsoft Learn at the time of writing; verify before acting on this recommendation.`

## Prohibited

- Secrets, real tenant/subscription/object IDs, customer names, internal DNS names. Use synthetic placeholders (`contoso.com`, `00000000-0000-0000-0000-000000000000`, `purview-lab`).
- Screenshots containing portal UI with real principals, resource IDs, or production data.
- Phrases that date the content ("the latest version", "as of today"). State a concrete version or date.
- HTML in Markdown, except `<details>` / `<summary>` blocks where progressive disclosure genuinely helps.
- Trailing whitespace; final newline at end of file is required.

## When Copilot writes or edits Markdown

1. Match the surrounding file's heading level, list style, and link style.
2. When adding a new external reference, confirm the URL resolves and prefer Microsoft Learn over blogs.
3. Do not restructure an existing document in a drive-by change. If a refactor is needed, open a dedicated `docs:` PR.
4. Never emit a table of contents unless the existing file already maintains one.
