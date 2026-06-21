---
description: "Rules for the Squad memory and charter files under .squad/. Enforces Scribe-only ownership of memory files, decision-log immutability, and identifier redaction."
applyTo: ".squad/**/*.md"
---

# Squad memory and charter rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Cross-cutting rules — secrets, identifier redaction, sample data — live in [`security.instructions.md`](security.instructions.md), [`sample-data.instructions.md`](sample-data.instructions.md), and the "Environment and identifier boundaries" section of `copilot-instructions.md`. This file narrows those rules for `.squad/` content and adds the Scribe-ownership and append-only-log discipline that the Scribe charter prescribes.

## Files in scope

| Path | Owner | Mutability |
|---|---|---|
| [`.squad/memory/decisions.md`](../../.squad/memory/decisions.md) | Scribe persona | Append-only. Existing rows are never modified. |
| [`.squad/memory/context.md`](../../.squad/memory/context.md) | Scribe persona | Mutable. Fields may be updated; existing fields may not be deleted (mark `[deprecated]` instead). |
| [`.squad/team.md`](../../.squad/team.md) | Lead / Architect | Mutable. Persona definitions and decision-authority caveats. |
| [`.squad/charters/*-charter.md`](../../.squad/charters/) | Lead / Architect (charter author) | Mutable. Each charter is owned by its persona's authoring lead. |
| [`.squad/README.md`](../../.squad/README.md) | Lead / Architect | Mutable. Top-level overview. |

The Scribe charter ([`scribe-charter.md`](../../.squad/charters/scribe-charter.md)) governs the "Memory file maintenance workflow" in detail. This instruction file restates the rules that must be enforced at edit time.

## Hard rules

1. **Scribe-only memory edits.** Any edit to `.squad/memory/decisions.md` or `.squad/memory/context.md` must come from the Scribe persona (or `@artifact-resolver` adopting the Scribe persona). Other personas may *propose* edits, but the Scribe records them.
2. **Decision log is append-only.** Rows in [`decisions.md`](../../.squad/memory/decisions.md) are immutable once committed. To supersede a decision, append a new row that references the original. Do not edit, reorder, or delete existing rows. A diff that modifies any historical row is a review-blocker.
3. **Context file fields are not deleted.** Fields in [`context.md`](../../.squad/memory/context.md) may be updated. They may not be removed. If a field is no longer relevant, mark it `[deprecated]` and explain the change in the same PR.
4. **Charter changes require a paired decision-log row.** Any edit to a `*-charter.md` file or to `team.md` must be accompanied by an appended row in `decisions.md` recording the rationale. The PR description must link the row.
5. **Open questions live in the table.** New unresolved questions go into the `## Open questions` table in `context.md` with a row that includes `Question`, `Raised by`, `Raised date`, `Status`, and `Reference` columns. They do not live in prose elsewhere in `.squad/`.

## Required content

- Every `.squad/**/*.md` file must use current Microsoft branding per the "Branding and voice" section of [`copilot-instructions.md`](../copilot-instructions.md).
- Cross-references between charter files, `team.md`, and `README.md` must use relative Markdown links so renames propagate cleanly.

## Forbidden content

The same redaction rules that apply to the rest of the repo apply here. Specifically:

- **No secrets.** Tokens, certificates, connection strings, account keys, OIDC client secrets, or anything matching the secrets-scan regex from [`pre-commit.instructions.md`](pre-commit.instructions.md): `password|secret|key|token|pat|client[_-]secret|connectionstring`. The literal product names "Microsoft Entra ID", "Key Vault", and "AccessToken" are acceptable in prose; secret *values* are not.
- **No real identifiers.** Real tenant IDs, subscription IDs, principal object IDs, real UPNs, or real customer / partner / project names. Use the placeholders from the "Environment and identifier boundaries" section of [`copilot-instructions.md`](../copilot-instructions.md). The exception, intentionally narrow, is the `contoso-lab` resource names this repo already targets (see the same section).
- **No sample PII.** Synthetic substitutes from [`sample-data.instructions.md`](sample-data.instructions.md) only.
- **No tool-call transcripts or chat exports.** `.squad/memory/` records *decisions*, not deliberations.

## Pre-commit checklist — `.squad/**` changes

Before committing changes in `.squad/`:

- [ ] If the change touches `decisions.md`, confirm the diff contains only **appended** rows. `git diff -- .squad/memory/decisions.md` must show no `-` lines inside the existing table body.
- [ ] If the change touches `context.md`, confirm no field has been deleted. Run `git diff -- .squad/memory/context.md` and review for `-` lines that remove a field rather than update its value.
- [ ] If the change touches a `*-charter.md` file or `team.md`, confirm an appended row in `decisions.md` records the rationale.
- [ ] Run the secrets-scan regex on the staged diff:

  ```pwsh
  git diff --staged -- .squad | Select-String -Pattern 'password|secret|token|pat|client[_-]secret|connectionstring' -CaseSensitive:$false
  ```

  Matches limited to product-name uses (`Key Vault`, `AccessToken`, `Microsoft Entra ID`) are acceptable; any value-shaped match is a review-blocker.
- [ ] Confirm no real GUIDs in the diff:

  ```pwsh
  git diff --staged -- .squad | Select-String -Pattern '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  ```

  Every match must be the zero GUID (`00000000-0000-0000-0000-000000000000`).
- [ ] Confirm "Last updated" timestamp in `context.md` is bumped if `context.md` was edited.

## When this rule conflicts with another

If another instruction file (for example, [`naming.instructions.md`](naming.instructions.md)) requires a literal value that conflicts with what `.squad/memory/context.md` documents about *current physical lab state*, the conflict is resolved by an ADR under [`docs/adr/`](../../docs/adr/), not by silently editing one of the two sources to match. [ADR 0012](../../docs/adr/0012-environment-parameters-file.md) is the canonical example.

## Reference

- [Scribe charter](../../.squad/charters/scribe-charter.md) — append-only memory workflow.
- [Squad team](../../.squad/team.md) — persona scopes and decision authority.
- [`.squad/README.md`](../../.squad/README.md) — Squad framework overview.
