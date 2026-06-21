---
name: learn-grounding
description: >
  Microsoft Learn citation and grounding discipline for the Purview-as-Code lab repository.
  Packages the research order (Learn first, official Microsoft second, non-Microsoft last),
  citation format rules, no-training-data-only-answers policy, and the evidence pattern for
  product-capability claims. Single-sources from copilot-instructions.md.
---

# Learn Grounding Skill

This skill packages the non-negotiable Microsoft Learn grounding discipline for the Purview-as-Code (`contoso-lab`) repository. It is the on-demand loadable companion to the always-on [`.github/copilot-instructions.md`](../../copilot-instructions.md), designed to give agents consistent citation and research rules when authoring or reviewing any technical content.

**Primitive:** Skill (per [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md)). **Not** an instruction (skills are loaded on demand, instructions are always-on) and not a prompt (skills provide knowledge, prompts provide task sequences).

**Canonical source:** This skill single-sources from:
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — §"Grounding — Microsoft Learn is the central source of truth" and §"Evidence pattern for Microsoft Learn citations".

When the canonical instruction file changes, this skill must be updated to reflect it — never the reverse.

---

## Microsoft Learn is the authoritative reference

Microsoft Learn (`learn.microsoft.com`) is the **authoritative reference** for every recommendation, code snippet, resource schema, CLI/PowerShell invocation, API call, and deployment pattern produced in this repository. This rule is non-negotiable and overrides AI model training data when the two disagree.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Grounding — Microsoft Learn is the central source of truth".

---

## Research order (mandatory)

Before producing any code, template, script, workflow, YAML manifest, or architectural recommendation, research must proceed **in this order**:

1. **Microsoft Learn first.** Search `learn.microsoft.com/en-us/purview/`, `learn.microsoft.com/en-us/azure/`, `learn.microsoft.com/en-us/security/`, `learn.microsoft.com/en-us/rest/api/purview/`, and `learn.microsoft.com/en-us/azure/templates/microsoft.purview/` for the relevant topic. Use the fetch/search tools; do not rely on memory.
2. **Official Microsoft properties second** — only when Learn does not cover the topic. Acceptable fallbacks: `techcommunity.microsoft.com`, `github.com/Azure/...` official samples, `github.com/MicrosoftDocs/...`, Azure Architecture Center (`learn.microsoft.com/en-us/azure/architecture/`).
3. **Non-Microsoft sources last** — Stack Overflow, personal blogs, third-party tutorials, AI training recall. These may only be used to *frame a question*, never to *produce a final answer*. Any snippet derived from such a source must be re-verified against a Learn page before being committed.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Research order (mandatory)".

---

## No training-data-only answers for technical content

The following categories of output must be grounded in a currently-reachable Microsoft Learn page (or official Microsoft property, per the fallback rule) and must cite the URL in a comment, commit message, PR description, or nearby prose:

- **Bicep / ARM / Terraform** — resource type, API version, property names, required vs. optional, and allowed values must match [`learn.microsoft.com/en-us/azure/templates/`](https://learn.microsoft.com/en-us/azure/templates/). Do not invent properties or API versions from training data.
- **Purview REST APIs** — endpoint, path, verb, request/response shape, and API version must match [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/).
- **Azure CLI (`az`) / Azure PowerShell (`Az.*`)** — command, subcommand, parameter names, and output shape must match the current Learn reference (`learn.microsoft.com/en-us/cli/azure/` or `learn.microsoft.com/en-us/powershell/module/`). Do not use deprecated or hallucinated flags.
- **GitHub Actions for Azure** — action name, version, and input schema must match [`learn.microsoft.com/en-us/azure/developer/github/`](https://learn.microsoft.com/en-us/azure/developer/github/) or the action's official README (`github.com/Azure/*`).
- **YAML manifests** that drive our scripts — field names and allowed values must be traceable to the corresponding REST API or Learn reference.
- **Security / RBAC / network recommendations** — must cite a Learn page under `/purview/`, `/azure/`, or `/security/`.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"No training-data-only answers for technical content".

---

## Citation format

### In prose (README, docs/, PR descriptions)
Inline Markdown link, e.g.:
```markdown
[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)
```

### In code (*.bicep, *.ps1, *.yml, *.yaml)
A comment on or directly above the relevant block, e.g.:
```bicep
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts
```

When a block is the direct transcription of a Learn sample, note that explicitly in the comment.

### For product-capability claims (evidence pattern)
Any committed artifact that makes a product-capability, role-gating, configuration-setting, or limit claim should include a `## References` block with at least one entry in this format:

```markdown
## References

- **[Short descriptive title](https://learn.microsoft.com/en-us/...)**
  Fetch date: YYYY-MM-DD
  > "Verbatim quote of ≤30 words that directly supports the claim."
```

When Microsoft Learn does not document a behavior, write the explicit phrase:

> Microsoft Learn does not currently document this behavior as of `<fetch date>`.

Do not substitute non-Microsoft sources to fill the gap.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Citation format" and §"Evidence pattern for Microsoft Learn citations".

---

## When Learn is silent or contradicts training data

- **If Learn does not cover the scenario**, say so out loud, cite what Learn *does* say about the nearest adjacent topic, and flag the recommendation as "not in Learn — verify before merging".
- **If Learn contradicts model training**, Learn wins. Do not quietly emit the training-data version.
- **If Learn pages disagree** (e.g., a preview doc and a GA doc), prefer the GA / most recently updated page and cite both.
- **If a web fetch fails**, do not guess. Note the failure, retry with a sibling URL, and surface the gap rather than back-filling from memory.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"When Learn is silent or contradicts training data".

---

## Security grounding

Every security-sensitive recommendation in this repo must cite a Microsoft Learn page. Do not invent guidance. When in doubt, link to the relevant page under `learn.microsoft.com/en-us/purview/`, `learn.microsoft.com/en-us/azure/`, or `learn.microsoft.com/en-us/security/`.

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Security grounding".

---

## API version pinning

Every Azure resource API version (Bicep) and REST `api-version` (scripts) must be pinned explicitly and traceable to a Learn reference page. The specific rules — GA-over-preview, one version per resource type across the repo, deprecation-triggers-migration — live in [`.github/instructions/bicep.instructions.md`](../../instructions/bicep.instructions.md) and [`.github/instructions/powershell.instructions.md`](../../instructions/powershell.instructions.md).

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"API version pinning".

---

## Usage

Load this skill on demand when:
- Authoring any Bicep, PowerShell, YAML manifest, GitHub Actions workflow, or ADR.
- Reviewing a PR that introduces a new Azure resource, REST endpoint, CLI/PowerShell cmdlet, or action version.
- Drafting a PR description or commit message that cites a product capability.
- Resolving a "Learn citation missing" review comment.

Do not load this skill:
- For general coding questions where the language feature is well-known (e.g., PowerShell parameter validation).
- When the task is to edit the canonical [copilot-instructions.md](../../copilot-instructions.md) file itself.
- For runtime debugging or error diagnosis unrelated to citation.

---

## References

- **[Customize AI in VS Code — Skills](https://code.visualstudio.com/docs/copilot/customization/overview)**
  Fetch date: 2026-06-19
  > "Skills are reusable capabilities that agents can load on demand to help with specific tasks."
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — canonical source for this skill.
- [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md) — why this is a skill.
- [`.github/instructions/bicep.instructions.md`](../../instructions/bicep.instructions.md) — API version pinning for Bicep.
- [`.github/instructions/powershell.instructions.md`](../../instructions/powershell.instructions.md) — API version pinning for scripts.
- [`.github/instructions/security.instructions.md`](../../instructions/security.instructions.md) — security grounding requirement.
