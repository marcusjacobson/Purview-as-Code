---
description: "Interview the user for a new Purview custom classification, validate it against sample-data and regex safety rules, then append it to data-plane/classifications/classifications.yaml."
mode: agent
---

# Add a custom classification

Gather the fields below one at a time. Validate each answer before moving on. Do not write to `data-plane/classifications/classifications.yaml` until every field passes validation.

## Fields to collect

1. **Domain.** One Title-Case word (e.g. `HR`, `Finance`, `Operations`). Used for the dotted name.
2. **Concept.** One Title-Case word describing what the rule detects (e.g. `EmployeeId`, `InvoiceNumber`). Used for the dotted name.
3. **Display name.** Short human-readable phrase shown in the Purview portal.
4. **Description.** One or two sentences describing what the rule detects and why. Must not contain real customer, person, or project names — enforce the [`sample-data.instructions.md`](../instructions/sample-data.instructions.md) rule.
5. **Regex pattern.** ECMA-style regex. Validate before accepting:
   - Must be anchored (`^`, `$`, or `\b`).
   - All quantifiers must be bounded (`{n}` or `{n,m}`) or single-level unbounded on a non-overlapping character class. Reject `.*`, `.+` unless scoped.
   - Reject nested unbounded quantifiers: `(x+)+`, `(x*)*`, `(x+)*`, `(.*a){n}`.
   - If the pattern fails any of the above, stop and ask the user to rewrite. Do not silently rewrite for them.
6. **Test payload (synthetic).** A string that the pattern should match. Enforce the sample-data rule: must be drawn from the synthetic table in [`sample-data.instructions.md`](../instructions/sample-data.instructions.md), not from a real source system.
7. **Minimum match threshold.** Integer 1–100. Default 60.

## Derive the name

Name is `Custom.<Domain>.<Concept>` per the "Naming convention" section of [`copilot-instructions.md`](../copilot-instructions.md). Echo it for confirmation before writing.

## Write the YAML

Append to [`data-plane/classifications/classifications.yaml`](../../data-plane/classifications/classifications.yaml). The block must look like:

```yaml
- name: Custom.<Domain>.<Concept>
  displayName: <display name>
  description: <description>
  # Reference: https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule
  rule:
    kind: Regex
    pattern: "<regex>"
    minimumMatchThreshold: <int>
  testPayload: "<synthetic test string>"
```

- Preserve existing YAML indentation and list ordering.
- Do not reformat unrelated entries.
- Run `yamllint` per the pre-commit checklist and surface any errors.

## Confirm before writing

Before the file is modified, paste the full YAML block you're about to append into the chat and ask for a typed `apply` confirmation. Do not write on implicit approval.

## Post-write

- Remind the user to run `./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -WhatIf` and paste the drift report into the PR.
- Remind the user to cite the Learn page in the PR description per the pull-request instructions.

## Rules for the agent

- Do not accept a real-looking SSN, credit card, phone number, or email as the test payload. If the user pastes one, stop and cite [`sample-data.instructions.md`](../instructions/sample-data.instructions.md).
- Do not silently rewrite an unsafe regex. Ask the user to fix it.
- Do not invent a `description` — ask the user.

Reference: [Create a custom classification and classification rule](https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule), [Supported classifications](https://learn.microsoft.com/en-us/purview/supported-classifications).
