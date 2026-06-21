---
description: "Rules for sample data, examples, and regex patterns anywhere in the repo. Prevents real PII, customer data, or production identifiers from landing in source."
applyTo: "**"
---

# Sample-data rule

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md), specifically the "Non-negotiable security principles" and "Environment and identifier boundaries" sections.

This file covers *content* (names, values, regex test inputs, sample rows). Augment #8 covers *identifiers* (tenant IDs, subscription IDs, object IDs). Both apply.

## Never include in the repo

- Real personally identifiable information (PII): real names, real email addresses, real phone numbers, real government IDs (SSN, NINO, SIN, TFN, national ID, passport number), real credit card numbers, real bank accounts, real health record numbers.
- Real customer, partner, employee, or internal project names.
- Real production resource names beyond the `contoso-lab` resources this repo already targets (see augment #8).
- Real data rows copied from a source system, even redacted, even "just for testing the regex."
- Real hostnames, URLs, or database names from production environments.

This rule applies to:

- `data-plane/**/*.yaml` — especially `classifications/classifications.yaml` regex patterns and their `description:` / `testPayload:` fields; `glossary/glossary.yaml` term descriptions and examples; `data-sources/data-sources.yaml` display names and endpoints.
- `scripts/**/*.ps1` — example values in `.EXAMPLE` blocks and comment headers.
- `docs/**/*.md` and top-level `README.md` — tables, fenced code blocks, and screenshots (screenshots must be captured against synthetic data or redacted).
- `.github/**` — instruction files, PR descriptions, and commit message bodies.

## Always use synthetic substitutes

| Kind | Use | Not |
|---|---|---|
| Person name | `Avery Howell`, `Jordan Kim`, `Sam Rivera` | a real coworker's name |
| Email | `user@contoso.com`, `admin@fabrikam.com` | a real inbox |
| Phone | `+1-555-0100` through `+1-555-0199` (North American fictional range) | a real number |
| US SSN | `000-00-0000` or obviously fake `123-45-6789` | a real SSN |
| Credit card | Brand-published test numbers, e.g. Visa `4111 1111 1111 1111` | a real PAN |
| Employee ID | `EMP-1234`, `E00001` | a real HR ID |
| Customer / account | `Widget Co.`, `ACME-0001` | a real customer |
| Organization name | `contoso`, `fabrikam`, `adatum` | a real tenant |
| DNS domain | `contoso.com`, `example.com`, `example.org` (RFC 2606) | a real domain |
| Hostname / server | `sql-lab-01.contoso.com`, `blob-lab.example.net` | a real host |
| Database / schema | `adventureworks`, `northwind`, `hr_demo` | a production DB |
| Address | `1 Microsoft Way, Redmond, WA 98052` | a real address |
| Tenant / subscription / resource ID in `data-plane/**` YAML | `${env:AZURE_TENANT_ID}`, `${env:AZURE_SUBSCRIPTION_ID}`, `${env:PURVIEW_RG}` tokens | a literal real GUID, even "with one digit changed" |
| Entra principal object ID in `data-plane/**` YAML | Stable `displayName` (e.g. `sg-purview-devops-sql-readers`) resolved at deploy | a literal real `objectId`, even prefixed `00000000-…` then suffixed with real values |

The last two rows above are the deploy-time resolution mechanisms defined by [ADR 0023](../../docs/adr/0023-identifier-resolution.md). They are the **only** acceptable shapes for real Azure topology / Entra principal identifiers in committed `data-plane/**` YAML. See [`data-plane-yaml.instructions.md`](data-plane-yaml.instructions.md) §Identifier resolution in YAML for the full rule.

## Regex rules for classification patterns

Classification rules in `data-plane/classifications/classifications.yaml` include a `pattern` field (ECMA-style regex). When Copilot drafts or reviews one of these:

- **Anchor it.** Use `^` / `$` or `\b` word boundaries. An unanchored pattern matches substrings across cells and produces false positives on the Purview scan.
- **Bound repetition.** Prefer explicit bounds (`{3,5}`) over unbounded (`.*`, `.+`).
- **Forbid catastrophic backtracking shapes.** Reject nested unbounded quantifiers: `(x+)+`, `(x*)*`, `(x+)*`, `(.*a){n}`. These can stall the scan worker.
- **Supply synthetic test inputs.** Any accompanying `testPayload:` or documentation sample must use the synthetic values in the table above, never a real one.
- **Cite Learn.** Comment or PR body must link to [Create a custom classification and classification rule](https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule).

## Glossary and data-source content

- Glossary term `longDescription:` and `examples:` fields must describe the *concept* using synthetic examples. Do not paste real policy text verbatim from an internal wiki.
- Data source `displayName:` and `endpoint:` must use the synthetic resource names from augment #8's table, never a real production hostname.

## When real data is required for a test

If a contributor genuinely needs to validate a regex or scan against real data:

1. Do the test locally against a dataset that stays on the contributor's machine.
2. Record the *result* (pass / fail / counts) in the PR, not the input.
3. Do not commit the dataset, even to a `tests/` folder, even temporarily, even in a squashed commit.

## Reviewer obligations

Reject any PR diff that contains:

- A string matching a plausible email, phone, SSN, credit card, or government ID that is not in the synthetic table above.
- A regex pattern that is unanchored *and* has unbounded repetition.
- A customer, partner, or project name that is not `contoso` / `fabrikam` / `adatum` (or the `contoso-lab` names this repo targets).

When rejecting, cite this file and offer the synthetic substitute from the table.

## Prohibited

- "I changed one digit so it's not real anymore." It is still real. Use a synthetic value.
- Hashing or base64-encoding a real value to "hide" it. It is still the same data. Use a synthetic value.
- Screenshots with real data blurred. Re-capture against synthetic data.
