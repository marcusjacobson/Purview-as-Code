---
description: "Rules for composing and reviewing pull request descriptions in this repo."
applyTo: "**"
---

# Pull request description rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md), especially the "Pre-commit checklist" and "Grounding — Microsoft Learn is the central source of truth" sections.

A pull request description in this repo is an auditable artifact, not a chat log. Every PR must match the template in [`.github/pull_request_template.md`](../pull_request_template.md). When Copilot drafts or reviews a PR description, it must enforce the rules below.

## Required sections

1. **Summary** — one or two sentences. Name the plane (`control`, `data`, `ci`, `docs`) and the user-facing outcome.
2. **Plane and scope** — explicit tick list of which folders the PR touches (`infra/`, `data-plane/collections/`, `scripts/`, `.github/workflows/`, `docs/`, etc.). A PR that touches more than one plane must explain why in this section.
3. **Change detail** — bulleted list of what changed, one bullet per logical change. Each bullet that introduces a resource, cmdlet, `az` command, REST endpoint, or action version **must** end with a Microsoft Learn citation in the form `([page title](https://learn.microsoft.com/...))`.
4. **Validation evidence** — pasted, fenced output from the pre-commit checklist commands that apply:
   - `infra/**` → `az bicep lint`, `az bicep build`, `az deployment group what-if` (all three).
   - `data-plane/**` → `yamllint` plus every `Deploy-*.ps1 -WhatIf` that the change touches.
   - `scripts/**` → `Invoke-ScriptAnalyzer` and at least one `-WhatIf` run of the modified script.
   - `.github/workflows/**` → link to a successful run of the workflow on a feature branch, if available.
5. **Security review** — short statement confirming:
   - No secrets in the diff.
   - Any new identity uses managed identity / OIDC federated credentials (no stored client secrets).
   - Any resource with `publicNetworkAccess: 'Enabled'` is justified here, with a Learn citation.
   - Role assignments are scoped to the narrowest resource that works.
6. **Rollback plan** — one or two sentences. For `data-plane/**` data-plane changes, describe the reverse PR (for example: "revert commit X, then run `Deploy-Collections.ps1 -PruneMissing:$false -WhatIf`").
7. **Breaking / destructive flag** — if the PR deletes anything (collection, term, classification, data source, scan, policy, role assignment), the PR **must** also carry the `destructive` label and have an explicit reviewer approval as defined in the pre-commit checklist.

## Prohibited in PR descriptions

- Bare `what-if` links to ephemeral portal URLs. Paste the text output.
- Secrets, keys, tokens, tenant IDs, subscription IDs, or object IDs of real principals. Use `00000000-0000-0000-0000-000000000000` placeholders.
- Generic phrases like "small change" or "minor cleanup" as the only summary for a state-changing PR.
- AI-authored filler such as "I hope this helps" or "Let me know what you think".

## When Copilot drafts the PR description

- Read the diff. Do not describe changes that are not in the diff.
- Fill every required section. If a section legitimately does not apply (for example, no validation evidence on a `docs/` PR), write `Not applicable — docs-only change` rather than leaving the section blank.
- Cite Microsoft Learn pages that you have actually consulted in this task. Do not fabricate URLs.

## When Copilot reviews a PR

- Flag any PR that is missing a required section or a validation block.
- Flag any state-changing PR whose diff does not add a top-of-file [`CHANGELOG.md`](../../CHANGELOG.md) entry, formatted per its "How this file is maintained" section. Exempt: a PR that only changes `CHANGELOG.md`.
- Flag any bullet that introduces a new Azure resource or REST endpoint without a Learn citation.
- Flag any `what-if` output that shows a delete of a resource without the `destructive` label.
- Flag any diff containing a value that matches the secret regex in the pre-commit checklist.
