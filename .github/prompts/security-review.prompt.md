---
description: "Read-only security audit of the current repo diff against every security and governance rule in this repo. No file modifications."
mode: agent
---

# Security review (read-only)

Run the checks below against the current diff. Do not modify any files. Produce a findings report grouped by severity.

## Scope selection

Ask the user which diff to review:

1. Unstaged changes (`git diff`).
2. Staged changes (`git diff --staged`).
3. Branch vs `main` (`git diff origin/main...HEAD`).

Default to option 3 if the user doesn't specify.

## Checks

For each check, cite the rule it enforces and the Learn page behind it. Every finding must carry a file path, line number, and the literal matched string (redacted if it looks sensitive).

### Secret and credential checks

- **S1.** `grep -Ei '(password|secret|key|token|pat|client[_-]secret|connectionstring|accountkey|sas)'` on the diff. Any match outside `# Reference:` comments or key names inside Key Vault references is a `Block` finding. Cite [`copilot-instructions.md`](../copilot-instructions.md) principle #1.
- **S2.** Search for literal `Bearer ey` or any JWT-shaped string (`eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.`). Any match is a `Block` finding.
- **S3.** Search for Azure storage connection-string fragments: `DefaultEndpointsProtocol=`, `AccountKey=`, `SharedAccessSignature=`. Any match is a `Block` finding.

### Identifier checks

- **I1.** `grep -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'` on the diff. Every match must either be the zero GUID, a schema example URL from `learn.microsoft.com`, or a well-known role-definition GUID. Anything else is a `Block` finding. Cite [`copilot-instructions.md`](../copilot-instructions.md) "Environment and identifier boundaries".
- **I2.** Search for environment tokens other than `lab`: `\b(dev|stage|staging|qa|test|prod|production)\b` inside `infra/**`, `data-plane/**`, `.github/workflows/**`. Any match that isn't inside a comment or a Learn URL is a `Block` finding.

### Sample-data checks

- **SD1.** Run the regex-safety checks from [`sample-data.instructions.md`](../instructions/sample-data.instructions.md) over any new or modified `pattern:` field in `data-plane/classifications/classifications.yaml`. Unanchored pattern with unbounded repetition is a `Block` finding. Nested unbounded quantifier is a `Block` finding.
- **SD2.** Search for plausibly-real PII in the diff: US SSN shape `\d{3}-\d{2}-\d{4}` excluding `000-00-0000` and `123-45-6789`; credit-card shape `\d{4}[ -]?\d{4}[ -]?\d{4}[ -]?\d{4}` excluding brand test numbers; email addresses whose domain is not `contoso.com`, `fabrikam.com`, `adatum.com`, or `example.(com|org|net)`. Any match is a `Block` finding.

### Bicep / infra checks

- **B1.** Every Azure resource in `infra/**` has a pinned API version (no `@latest`, no unpinned decorator). Missing pin is a `Block` finding.
- **B2.** Any resource with `publicNetworkAccess: 'Enabled'` that wasn't present in the base branch is a `Warn` finding unless the PR description justifies it per [`bicep.instructions.md`](../instructions/bicep.instructions.md).
- **B3.** Any new Purview / Key Vault / storage resource without a `Microsoft.Insights/diagnosticSettings` child or parameter hook is a `Warn` finding.

### PowerShell / scripts checks

- **P1.** Every new or modified `Deploy-*.ps1` declares `[CmdletBinding(SupportsShouldProcess)]` and exposes `-PruneMissing` and `-Force` with default `$false`. Missing any of these is a `Block` finding.
- **P2.** Any `Invoke-RestMethod` call without a literal `api-version=` query parameter is a `Block` finding.
- **P3.** Any `Invoke-Expression` or call operator on a non-literal variable is a `Block` finding.

### Workflow checks

- **W1.** Any new `uses:` line that isn't pinned to a full-length commit SHA (and isn't an official `azure/*`, `actions/*`, or `github/*` major tag) is a `Block` finding.
- **W2.** Any job that lacks a top-level `permissions:` block or declares `contents: write` without justification is a `Warn` finding.
- **W3.** Any step that runs `az deployment group create` or a `Deploy-*.ps1` without a preceding `what-if` / `-WhatIf` step in the same job is a `Block` finding.

### Documentation / PR hygiene checks

- **D1.** Any new `.md` file without a single H1 or with an absolute file-system link is a `Warn` finding. Cite [`markdown.instructions.md`](../instructions/markdown.instructions.md).

## Report format

Produce the findings as a Markdown table:

```markdown
| Severity | Check | File | Line | Evidence (redacted) | Rule citation |
|---|---|---|---|---|---|
| Block | S1 | infra/main.bicepparam | 12 | `accountKey = '****'` | copilot-instructions principle #1 |
```

Group by severity: `Block` first, then `Warn`, then `Note`. Summarize counts at the top.

## Rules for the agent

- Do not modify any file. This prompt is read-only.
- Do not run any Azure write command. `az account show`, `git diff`, and local greps only.
- Redact matched evidence that looks sensitive. Show the first four characters and length, not the full string.
- Do not guess at rule citations. If a finding doesn't map to a rule in this repo, mark it `Note` with the reason.

Reference: [Microsoft Purview security best practices](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices), [Azure security benchmark](https://learn.microsoft.com/en-us/security/benchmark/azure/security-controls-v3-identity-management), [OWASP Top 10](https://owasp.org/www-project-top-ten/).
