---
name: docs-maintenance
description: >
  Solution-guide authoring and freshness conventions for the Purview-as-Code lab repository.
  Packages the docs/solutions/** page template, the feature-to-doc mapping, the Microsoft Learn
  evidence pattern, the identifier-redaction rules, and the "I changed code — which guide do I
  touch?" checklist. Single-sources from markdown.instructions.md and copilot-instructions.md.
  Load it when authoring, reviewing, or refreshing a solution guide under docs/solutions/.
---

# Docs Maintenance Skill

This skill packages the conventions for keeping the operational solution guides under
[`docs/solutions/`](../../../docs/solutions/) current with the reconcilers and desired-state YAML
they document. It is the on-demand companion to the always-on
[`.github/instructions/markdown.instructions.md`](../../instructions/markdown.instructions.md) and
the evidence-pattern rules in
[`.github/copilot-instructions.md`](../../copilot-instructions.md), and the human-readable side of
the [`docs-freshness.yml`](../../workflows/docs-freshness.yml) CI check.

**Primitive:** Skill (per
[`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md)).
Loaded on demand by description match — not an always-on instruction, not a task prompt.

**Canonical sources** (this skill restates and links; it never diverges):

- [`.github/instructions/markdown.instructions.md`](../../instructions/markdown.instructions.md) —
  writing, heading, link, code-block, and table rules.
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — §"Evidence pattern for
  Microsoft Learn citations", §"Environment and identifier boundaries", §"Branding and voice".
- [`docs/solutions/.solution-map.yml`](../../../docs/solutions/.solution-map.yml) — the
  authoritative feature-to-code-to-doc map.

When a canonical source changes, update this skill to match — never the reverse.

---

## When a solution guide is required

Every Microsoft Purview feature governed as code in this repo has exactly one guide under
`docs/solutions/`. The mapping is enumerated in
[`docs/solutions/.solution-map.yml`](../../../docs/solutions/.solution-map.yml). A new reconciler
(`scripts/Deploy-*.ps1`) or a new `data-plane/<solution>/` folder must ship with:

1. A guide page under the correct `docs/solutions/<area>/` folder
   (`governance-foundation`, `information-protection`, `compliance`, `data-map`, or
   `unified-catalog`).
2. A new row in `docs/solutions/.solution-map.yml` listing the code paths and the guide path.
3. A link from the area `README.md` index and the top-level
   [`docs/solutions/README.md`](../../../docs/solutions/README.md) feature map.

---

## The solution-guide page template

Mirror an existing page —
[`docs/solutions/data-map/collections.md`](../../../docs/solutions/data-map/collections.md) is the
reference. Sections, in order:

1. **H1 title** — one per file, sentence case, naming the feature
   (e.g. `# Information Protection — sensitivity labels`).
2. **Intro paragraph** — link the reconciler script, the desired-state YAML, and the Microsoft
   Learn entry point in the first two sentences.
3. **`## Purpose`** — what the reconciler reconciles, the REST or Security & Compliance PowerShell
   surface it drives, and the drift decisions it emits
   (Create / Update / NoChange / Orphan / Conflict).
4. **`## Default state`** — the *shape* of the shipped YAML. Describe structure, never paste real
   tenant identifiers, principals, or PII.
5. **`## Authentication`** — how the script authenticates (Azure CLI token for Purview REST;
   Key Vault-signed token + `Connect-IPPSSession` for Security & Compliance PowerShell; OIDC in
   CI). Cite [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
6. **`## Inputs`** — a parameter table built from the script's actual `param()` block, including the
   full-circle switches (`-WhatIf`, `-PruneMissing`, `-Force`, `-ExportCurrentState`) and the
   direction-policy parameters (`-DirectionPolicy`, `-SkipNames`) where present.
7. **`## Manage <feature> with this repo`** — numbered end-to-end steps that cover add / change /
   remove: hydrate (`-ExportCurrentState`) → edit YAML → preview (`-WhatIf`) → apply → verify (smoke
   runbook link). Use concrete `pwsh` commands with the account-name placeholder
   `purview-contoso-lab`.

   For the **apply** step, name the surface's own per-solution `deploy-<solution>.yml` workflow
   ([ADR 0051](../../../docs/adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)). If the
   surface has **no** per-solution workflow, say so plainly — "no automated apply path yet" — name
   the local `scripts/Deploy-*.ps1` reconciler as the interim path, and link the backfill tracker
   [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80). **Never** paper over the gap
   by silently omitting the apply step: a doc that hides a missing apply path is worse than one that
   names it.
8. **`## References`** — the evidence block (see below).

Area `README.md` index pages mirror
[`docs/solutions/governance-foundation/README.md`](../../../docs/solutions/governance-foundation/README.md):
intro, a `Page | Purpose | Primary artifacts` table, a "How this section relates to the rest of the
repo" subsection, and a "Conventions" subsection.

---

## Microsoft Learn evidence block

Any guide that makes a product-capability, role-gating, configuration, or limit claim ends with a
`## References` block in exactly this shape, one entry per Learn page actually consulted:

```markdown
## References

- **[Short descriptive title](https://learn.microsoft.com/en-us/...)**
  Fetch date: YYYY-MM-DD
  > "Verbatim quote of <=30 words that directly supports a claim on the page."
```

Followed by bullet links to the ADRs the guide relies on. Rules:

- Do **not** fabricate URLs. Cite only pages you fetched, or that already appear in the repo
  sources you read (the reconciler header, the YAML header, the runbook, the project plan).
- When Microsoft Learn does not document a behavior, write the explicit phrase
  `Microsoft Learn does not currently document this behavior as of <fetch date>.` Do not substitute
  a non-Microsoft source.
- Use the full product name on first reference (`Microsoft Purview`, `Microsoft 365`,
  `Microsoft Entra ID`); never `Azure Purview`, `Azure AD`, or `O365`.

---

## Identifier and sample-data redaction

Per §"Environment and identifier boundaries" of
[`copilot-instructions.md`](../../copilot-instructions.md) and
[`sample-data.instructions.md`](../../instructions/sample-data.instructions.md):

| Kind | Use |
|---|---|
| GUID (tenant, subscription, object, client ID) | `00000000-0000-0000-0000-000000000000` |
| Organization | `contoso`, `fabrikam`, `adatum` |
| User / UPN | `user@contoso.com` |
| Account / resource group / region | `purview-contoso-lab` / `rg-purview-lab` / `eastus` |
| Classification regex test input | synthetic only — e.g. Visa test PAN `4111 1111 1111 1111` |

Never "change one digit" of a real value, never base64/hash a real value to hide it, never blur a
real value in a screenshot. Re-capture against synthetic data.

---

## Freshness checklist — "I changed code, which guide do I touch?"

When a pull request changes any of the following, update the mapped guide in the **same PR**:

- A `scripts/Deploy-*.ps1` parameter surface, drift-report wording, or default behavior → update
  the **Inputs** and **Manage** sections of the mapped guide.
- A `data-plane/<solution>/*.yaml` schema or default state → update the **Default state** section.
- A new ADR that changes how a feature is governed → add it to the guide's **References** bullets.
- A renamed or retired reconciler / YAML / runbook → fix every link, and update
  `docs/solutions/.solution-map.yml`.

The [`docs-freshness.yml`](../../workflows/docs-freshness.yml) check emits an advisory `::warning::`
on the PR when code changed without its guide. It never blocks merge — it is a reminder. The
mechanical indexes ([`docs/adr/README.md`](../../../docs/adr/README.md),
[`docs/scripts-reference.md`](../../../docs/scripts-reference.md)) are regenerated separately by
[`docs-regen.yml`](../../workflows/docs-regen.yml); do not hand-edit those two files.

---

## Usage

Load this skill when:

- Authoring a new `docs/solutions/**` guide for a feature.
- Reviewing a PR that touches `docs/solutions/**`, a reconciler, or a `data-plane/**` schema.
- Responding to a `docs-freshness` advisory warning on a pull request.
- Adding a new reconciler / solution folder (so the guide, the map row, and the index land together).

Do not load this skill:

- For the mechanical auto-generated files (`docs/adr/README.md`, `docs/scripts-reference.md`) —
  those are owned by `docs-regen.yml`.
- For ADR authoring — use the [`adr-author`](../adr-author/SKILL.md) skill.
- When editing the canonical [`markdown.instructions.md`](../../instructions/markdown.instructions.md)
  file itself.

---

## References

- **[Customize AI in VS Code — Skills](https://code.visualstudio.com/docs/copilot/customization/overview)**
  Fetch date: 2026-06-20
  > "Skills are reusable capabilities that agents can load on demand to help with specific tasks."
- **[Microsoft Writing Style Guide](https://learn.microsoft.com/en-us/style-guide/welcome/)**
  Fetch date: 2026-06-20
  > "Use the clearest, most specific word for the situation. Write the way people speak."
- [`.github/instructions/markdown.instructions.md`](../../instructions/markdown.instructions.md) — canonical writing rules.
- [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md) — why this is a skill.
- [`docs/solutions/.solution-map.yml`](../../../docs/solutions/.solution-map.yml) — feature-to-doc map.
- [`.github/workflows/docs-freshness.yml`](../../workflows/docs-freshness.yml) — the advisory CI check this skill backs.
