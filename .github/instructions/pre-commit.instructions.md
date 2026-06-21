---
description: "Pre-commit checklist bullets that apply to every state-changing PR, regardless of plane. Domain-specific bullets live in the matching scoped file."
applyTo: "**"
---

# Pre-commit checklist — cross-cutting rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Domain-specific checklist items live in [`bicep.instructions.md`](bicep.instructions.md), [`data-plane-yaml.instructions.md`](data-plane-yaml.instructions.md), [`powershell.instructions.md`](powershell.instructions.md), [`github-actions.instructions.md`](github-actions.instructions.md), and [`pull-request.instructions.md`](pull-request.instructions.md).

Any pull request that touches `infra/`, `data-plane/`, `scripts/`, or `.github/workflows/` must complete the applicable checklist below **before** the PR is opened. Paste the output of each command into the PR description in fenced code blocks. Reviewers will not approve without this evidence.

## Every PR

- [ ] Instructions consulted: confirm the change is covered by [`.github/copilot-instructions.md`](../copilot-instructions.md) and the relevant scoped instructions under [`.github/instructions/`](.). If not, update the instructions in the same PR.
- [ ] Learn citations added: every new resource, cmdlet, `az` command, REST endpoint, or action version has an inline `// Reference: https://learn.microsoft.com/...` (or prose equivalent). See the "Grounding — Microsoft Learn is the central source of truth" section of `copilot-instructions.md`.
- [ ] No secrets in diff: run `git diff --staged | grep -Ei 'password|secret|key|token|pat|client[_-]secret|connectionstring'`; if the grep returns anything, the PR is blocked.
- [ ] Changelog updated: the PR adds a top-of-file entry to [`CHANGELOG.md`](../../CHANGELOG.md) for this change, formatted per its "How this file is maintained" section (newest date first, category mapped from the Conventional-Commit type, scope-prefixed, ending with the `#NNN` issue/PR reference). Exempt: a PR that only changes `CHANGELOG.md`.

## Destructive changes

- [ ] PR is labeled `destructive`
- [ ] Rollback plan documented in the PR description
- [ ] At least one reviewer with `Collection Admin` (for data-plane deletes) or `Contributor` on the resource group (for control-plane deletes) has approved

## If a command fails

Do not paper over it. Paste the failing command and its output into the PR description, describe the investigation, and either fix the root cause in the same PR or stop and escalate. Never silence warnings or disable validation.
