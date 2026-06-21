---
description: "Commit message convention for this repository. Enforced whenever Copilot drafts a commit message."
applyTo: "**"
---

# Commit message convention

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). See also [`pull-request.instructions.md`](pull-request.instructions.md) for PR description rules and [`pre-commit.instructions.md`](pre-commit.instructions.md) for the pre-commit checklist.

All commits in this repository use [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/). Copilot must follow the rules below whenever it proposes a commit message.

## Format

```text
<type>(<scope>): <short subject>

<body — optional, wrap at 72 columns>

<footer — optional, one entry per line>
```

### Required elements

- **`<type>`** — one of: `feat`, `fix`, `refactor`, `docs`, `chore`, `ci`, `build`, `test`, `perf`, `revert`.
- **`<scope>`** — required. Must be one of the repo-specific scopes below.
- **`<short subject>`** — imperative mood, lower-case, no trailing period, ≤ 72 characters.

### Allowed scopes (this repo)

| Scope | When to use |
|---|---|
| `infra` | Any change under `infra/` (Bicep, modules, `.bicepparam`). |
| `collections` | `data-plane/collections/**` |
| `glossary` | `data-plane/glossary/**` |
| `classifications` | `data-plane/classifications/**` |
| `data-sources` | `data-plane/data-sources/**` |
| `scans` | `data-plane/scans/**` |
| `role-groups` | `data-plane/purview-role-groups/**` |
| `scripts` | `scripts/**` (PowerShell helpers). |
| `ci` | `.github/workflows/**` |
| `instructions` | `.github/copilot-instructions.md`, `.github/instructions/**`, `.github/pull_request_template.md` |
| `docs` | `docs/**`, top-level `README.md`, `.md` files outside the above. |
| `repo` | Cross-cutting meta changes (`.gitignore`, `.editorconfig`, repo config). Use sparingly. |

A commit that touches multiple scopes should either be split, or — if the changes are logically inseparable — use the most specific scope that matches and call out the spread in the body. Do not combine scopes with slashes (`infra/scripts`).

### Subject examples

```text
feat(infra): add private endpoint module for Purview account
fix(scripts): handle 409 on collection upsert as idempotent success
docs(instructions): add commit message convention
chore(ci): pin azure/login to v2.3.1 commit SHA
refactor(data-sources): normalize credential reference to key-vault shape
```

### Body rules

- Wrap at 72 columns.
- Describe the *why* (motivation, trade-off, Learn citation). The *what* is in the diff.
- Cite Microsoft Learn pages introduced or relied on by this change, e.g. `See: https://learn.microsoft.com/en-us/...`.

### Footer rules

- `BREAKING CHANGE: <description>` — required when the commit introduces a destructive or backward-incompatible change (deleting a collection, renaming a scope, removing a script parameter). Must match the `destructive` label on the PR.
- `Refs: #<issue>` / `Closes: #<issue>` — one per line.
- `Co-authored-by: Name <email>` — one per line, only for actual contributors.

## Prohibited

- Emojis in the subject line.
- Square-bracket prefixes (`[infra]`, `[WIP]`). Use `chore` or `wip` only as a `type` / a draft PR.
- Passive voice (`was updated`, `has been fixed`). Use imperative (`update`, `fix`).
- Personal opinions ("finally", "hopefully"), hedging ("maybe", "might"), or AI boilerplate ("this commit", "as requested").
- Secrets, tokens, keys, tenant IDs, subscription IDs, object IDs, or real customer identifiers in any part of the message.
- Referring to the agent or model ("Copilot suggested", "AI-generated"). Attribute via `Co-authored-by:` if needed.

## When Copilot generates a commit message

1. Inspect the diff. Pick the single most specific scope that covers the change.
2. Write one subject line under 72 characters in the imperative mood.
3. Add a body only if the *why* is not obvious from the subject or diff.
4. Add `BREAKING CHANGE:` when the diff removes or renames anything that another file, script, or pipeline depends on.
5. Never invent issue numbers, Learn URLs, or co-authors.
