---
name: adr-author
description: >
  ADR authoring structure and rules for the Purview-as-Code lab repository. Packages the
  required sections (Context, Decision, Consequences, Alternatives, Citations), citation
  requirements, status lifecycle, and the no-real-identifiers rule. Single-sources from
  docs/adr/0000-template.md and copilot-instructions.md environment boundaries.
---

# ADR Author Skill

This skill packages the non-negotiable ADR (Architecture Decision Record) authoring structure and rules for the Purview-as-Code (`contoso-lab`) repository. It is the on-demand loadable companion that gives agents consistent guidance when drafting, reviewing, or superseding ADRs under `docs/adr/`.

**Primitive:** Skill (per [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md)). **Not** an instruction (skills are loaded on demand, instructions are always-on) and not a prompt (skills provide knowledge, prompts provide task sequences).

**Canonical sources:** This skill single-sources from:
- [`docs/adr/0000-template.md`](../../../docs/adr/0000-template.md) — ADR structure template.
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — §"Environment and identifier boundaries" (zero-GUID placeholders, no real identifiers).

When the canonical sources change, this skill must be updated to reflect them — never the reverse.

---

## ADR file structure

Every ADR under `docs/adr/` must follow the structure in [`docs/adr/0000-template.md`](../../../docs/adr/0000-template.md).

### Header (required)

```markdown
# NNNN — <decision title>

- **Status:** Proposed <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** YYYY-MM-DD
- **Gates:** <!-- Which project-plan.md checklist item(s) this unblocks -->
- **Deciders:** <!-- GitHub handles -->
```

**Status lifecycle:**
- `Proposed` — draft in PR, not yet merged.
- `Accepted` — merged to `main`.
- `Superseded by NNNN` — a later ADR replaces this one. The superseding ADR number is named.
- `Deprecated` — no longer applicable, but not replaced by a specific ADR.

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) header block.

### Section 1: Context (required)

**What to include:**
- Why does this decision need to be made? What constraints apply?
- Link to the [`docs/project-plan.md`](../../../docs/project-plan.md) section, the Learn docs, and any reference-repo pattern that motivated the question.
- Do not paste secrets, tenant IDs, subscription IDs, or real identifiers. Use the placeholders defined in the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../copilot-instructions.md).

**What to exclude:**
- Speculation about future work not yet enumerated on the Progress checklist.
- Real customer, partner, or employee names.
- Real PII or production identifiers.

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) §"Context".

### Section 2: Decision (required)

State the decision in one or two short paragraphs. Use the phrase "we will ...".

If the decision has sub-parts, enumerate them. Example:

```markdown
## Decision

We will do X by implementing Y. Specifically:

1. Sub-decision A.
2. Sub-decision B.
3. Sub-decision C.
```

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) §"Decision".

### Section 3: Consequences (required)

**What to include:**
- What becomes easier because of this decision? What becomes harder?
- Which checklist items in [`docs/project-plan.md`](../../../docs/project-plan.md) are now unblocked?
- Which items (if any) are now blocked or changed?
- Which security principle in [`.github/instructions/security.instructions.md`](../../instructions/security.instructions.md) does this uphold or relax (with justification)?

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) §"Consequences".

### Section 4: Alternatives considered (required)

List the two or three realistic alternatives and why each was rejected. At least one alternative must be "do nothing / keep the status quo".

Example:

```markdown
## Alternatives considered

**Alternative A: [name].** Reject. [One-sentence reason.]

**Alternative B: Do nothing.** Reject. [One-sentence reason why the status quo is unacceptable.]
```

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) §"Alternatives considered".

### Section 5: Citations (required)

At least one Microsoft Learn URL. Additional citations: reference-repo pattern files, RFCs, internal docs.

Format:

```markdown
## Citations

- [Learn page title](https://learn.microsoft.com/en-us/...)
```

When a claim references a Microsoft product capability, role, or configuration setting, prefer the evidence pattern from [`.github/copilot-instructions.md`](../../copilot-instructions.md) §"Evidence pattern for Microsoft Learn citations":

```markdown
- **[Short descriptive title](https://learn.microsoft.com/en-us/...)**
  Fetch date: YYYY-MM-DD
  > "Verbatim quote of ≤30 words that directly supports the claim."
```

**Source:** [docs/adr/0000-template.md](../../../docs/adr/0000-template.md) §"Citations".

---

## ADR numbering

ADRs are numbered sequentially starting at `0001`. The next free number is determined by reading the highest existing `NNNN-*` file in `docs/adr/` (excluding `0000-template.md`).

The filename format is `NNNN-kebab-case-title.md`, where `NNNN` is the zero-padded four-digit number and `kebab-case-title` matches the decision title in the header (lowercased, spaces replaced with hyphens).

Example: the 43rd ADR with title "Model tier policy" becomes `0043-model-tier-policy.md`.

**Source:** observed pattern in existing ADR filenames (`docs/adr/0002-administrative-units.md` through `docs/adr/0043-model-tier-policy.md`).

---

## No real identifiers rule

Do not paste into any ADR:

- Real Entra ID tenant IDs, Azure subscription IDs, object IDs, or resource IDs beyond the `contoso-lab` resources this repo already targets.
- Real user principal names (UPNs), email addresses, or customer/partner/employee names.
- Real PII (SSN, credit card, phone, government ID, bank account, health record number).
- Real production resource names, hostnames, URLs, or database names.

**Always use these placeholders:**

| Kind | Placeholder |
|---|---|
| GUID (tenant, subscription, object ID, client ID) | `00000000-0000-0000-0000-000000000000` |
| Organization name | `contoso`, `fabrikam`, `adatum` |
| DNS domain | `contoso.com`, `example.com` |
| User email / UPN | `user@contoso.com` |

Full placeholder table: [copilot-instructions.md](../../copilot-instructions.md) §"Environment and identifier boundaries".

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Environment and identifier boundaries", [sample-data.instructions.md](../../instructions/sample-data.instructions.md).

---

## ADR lifecycle

1. **Draft.** Author the ADR on a feature branch with status `Proposed`.
2. **Review.** Open a PR. The PR must pass the pre-commit checklist per [`.github/instructions/pre-commit.instructions.md`](../../instructions/pre-commit.instructions.md) (no secrets, Learn citations present, markdownlint clean).
3. **Merge.** After the lab owner approval (`owner-approved` label), merge the PR. The ADR status becomes `Accepted`.
4. **Supersede or deprecate.** If a later ADR replaces this one, update the status to `Superseded by NNNN` in the same PR that lands the superseding ADR.

**Source:** observed pattern in existing ADRs (e.g., ADR 0011 §1 superseded by ADR 0028 addendum).

---

## When to write an ADR

Write an ADR when:

- A [`docs/project-plan.md`](../../../docs/project-plan.md) checklist item is gated by an open question in §8 (if any are listed).
- A design decision affects multiple waves or multiple planes (control + data).
- A decision constrains future work or changes a security principle.
- A decision resolves a recurring question that contributors ask.

Do not write an ADR for:

- Single-file edits (typo fixes, instruction updates).
- Ephemeral trial-and-error work on a spike branch.
- Decisions already documented in an existing ADR.

**Source:** inferred from existing ADR set (decisions that span waves, gates, or personas).

---

## Usage

Load this skill on demand when:
- Authoring a new ADR.
- Reviewing a PR that contains an ADR.
- Superseding or deprecating an existing ADR.
- Resolving a [`docs/project-plan.md`](../../../docs/project-plan.md) §8 open-question gate.

Do not load this skill:
- For general coding questions.
- When the task is to edit the canonical [`docs/adr/0000-template.md`](../../../docs/adr/0000-template.md) itself.
- For runtime debugging or error diagnosis.

---

## References

- **[Customize AI in VS Code — Skills](https://code.visualstudio.com/docs/copilot/customization/overview)**
  Fetch date: 2026-06-19
  > "Skills are reusable capabilities that agents can load on demand to help with specific tasks."
- [`docs/adr/0000-template.md`](../../../docs/adr/0000-template.md) — canonical ADR structure template.
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — §"Environment and identifier boundaries".
- [`.github/instructions/sample-data.instructions.md`](../../instructions/sample-data.instructions.md) — synthetic-data rule.
- [`.github/instructions/pre-commit.instructions.md`](../../instructions/pre-commit.instructions.md) — per-PR checklist.
- [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md) — why this is a skill.
- [ADR 0013](../../../docs/adr/0013-squad-agents-vs-prompt-pipeline.md) — example of a well-formed ADR.
