---
name: code-review
description: >
  Code review hard rules for the Purview-as-Code lab repository. Packages the
  secrets-scan regex, zero-GUID / synthetic-identifier placeholders, and the
  Microsoft Learn citation requirement as on-demand loadable knowledge for
  consistent, secure review across all agents and models. Single-sources from
  the existing `.instructions.md` files — restates and links, never diverges.
---

# Code Review Skill

This skill packages the non-negotiable code-review hard rules enforced across every pull request in the Purview-as-Code (`contoso-lab`) repository. It is the on-demand loadable companion to the always-on instruction files, designed to give agents consistent security and quality gates regardless of which model is active that day.

**Primitive:** Skill (per [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md)). **Not** an instruction (skills are loaded on demand, instructions are always-on) and not a prompt (skills provide knowledge, prompts provide task sequences).

**Canonical sources:** This skill single-sources from:
- [`.github/instructions/security.instructions.md`](../../instructions/security.instructions.md) — 10 non-negotiable security principles.
- [`.github/instructions/sample-data.instructions.md`](../../instructions/sample-data.instructions.md) — synthetic-data rule (no real PII, customer names, or production identifiers).
- [`.github/instructions/pre-commit.instructions.md`](../../instructions/pre-commit.instructions.md) — secrets-scan regex and per-PR checklist.
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — zero-GUID placeholder rule (§"Environment and identifier boundaries"), Microsoft Learn grounding (§"Grounding — Microsoft Learn is the central source of truth"), and the evidence pattern (§"Evidence pattern for Microsoft Learn citations").

When the canonical instruction files change, this skill must be updated to reflect them — never the reverse.

---

## Hard rule 1 — No secrets in diff

**Source:** [security.instructions.md](../../instructions/security.instructions.md) principle #1, [pre-commit.instructions.md](../../instructions/pre-commit.instructions.md) §"Every PR".

Every pull request must pass this check before it can be opened:

```pwsh
git diff --staged | Select-String -Pattern 'password|secret|key|token|pat|client[_-]secret|connectionstring' -CaseSensitive:$false
```

**Regex (case-insensitive):** `password|secret|key|token|pat|client[_-]secret|connectionstring`

If the grep returns **any** match, the PR is **blocked**. Policy-word matches in prose (e.g., "no stored **secret**s") are acceptable and must be documented in the PR description under the secrets-scan evidence block. Real-looking values that match (base64-encoded blobs, connection-string shapes, `clientSecret` fields in JSON) block the commit unconditionally.

**What to do when a secret is detected:**
1. State the conflict explicitly — cite the matched line and this rule.
2. Refuse the commit.
3. Offer the secure alternative:
   - Secrets belong in **Azure Key Vault** or **GitHub Actions secrets**, referenced by name.
   - Credentials must follow the identity-preference ladder: managed identity > service principal (OIDC federated credential only) > key-based auth stored in Key Vault (per [security.instructions.md](../../instructions/security.instructions.md) principle #2).

**Learn citation:** [Microsoft Purview credential management](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management).

---

## Hard rule 2 — Zero-GUID placeholders and synthetic identifiers

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Environment and identifier boundaries", [sample-data.instructions.md](../../instructions/sample-data.instructions.md).

Real identifiers are reconnaissance-grade data. Never commit:
- Real Entra ID tenant IDs, Azure subscription IDs, object IDs, or resource IDs beyond the `contoso-lab` resources this repo already targets.
- Real user principal names (UPNs), email addresses, or customer/partner/employee names.
- Real PII (SSN, credit card, phone, government ID, bank account, health record number).
- Real production resource names, hostnames, URLs, or database names.

**Always use these placeholders:**

| Kind | Placeholder | Notes |
|---|---|---|
| GUID (tenant, subscription, object ID, client ID) | `00000000-0000-0000-0000-000000000000` | Per [Microsoft placeholder examples](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples). |
| Organization name | `contoso`, `fabrikam`, `adatum` | Microsoft fictitious-company names. |
| DNS domain | `contoso.com`, `example.com` | `example.com` is reserved by [RFC 2606](https://www.rfc-ietf.org/rfc/rfc2606.txt). |
| User email / UPN | `user@contoso.com` | |
| Person name | `Avery Howell`, `Jordan Kim`, `Sam Rivera` | |
| Phone | `+1-555-0100` through `+1-555-0199` | North American fictional range. |
| US SSN | `000-00-0000` or obviously fake `123-45-6789` | |
| Credit card | Brand-published test numbers, e.g. Visa `4111 1111 1111 1111` | |

Full synthetic-data table: [sample-data.instructions.md](../../instructions/sample-data.instructions.md) §"Always use synthetic substitutes".

**Rejection protocol:** Reject any PR diff that contains a 32-character hex or GUID pattern that does not match the zero-GUID placeholder. Grep: `grep -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'`. Every match must either be the zero GUID, a schema example, or a role-definition GUID from `learn.microsoft.com`.

**What to do when rejecting:** Cite [sample-data.instructions.md](../../instructions/sample-data.instructions.md) and offer the synthetic substitute from the table above.

---

## Hard rule 3 — Microsoft Learn citation requirement

**Source:** [copilot-instructions.md](../../copilot-instructions.md) §"Grounding — Microsoft Learn is the central source of truth" and §"Evidence pattern for Microsoft Learn citations".

Microsoft Learn (`learn.microsoft.com`) is the **authoritative reference** for every recommendation, code snippet, resource schema, CLI/PowerShell invocation, API call, and deployment pattern produced in this repository. Model training recall alone is not sufficient.

**Every new capability** introduced in a PR must cite a Learn page:
- **Bicep / ARM** — resource type, API version, property names: [`learn.microsoft.com/en-us/azure/templates/`](https://learn.microsoft.com/en-us/azure/templates/).
- **Purview REST APIs** — endpoint, path, verb, request/response shape: [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/).
- **Azure CLI / PowerShell** — command, subcommand, parameter names: [`learn.microsoft.com/en-us/cli/azure/`](https://learn.microsoft.com/en-us/cli/azure/) or [`learn.microsoft.com/en-us/powershell/module/`](https://learn.microsoft.com/en-us/powershell/module/).
- **GitHub Actions** — action name, version, input schema: [`learn.microsoft.com/en-us/azure/developer/github/`](https://learn.microsoft.com/en-us/azure/developer/github/) or the action's official README.
- **Security / RBAC / network recommendations** — [`learn.microsoft.com/en-us/purview/`](https://learn.microsoft.com/en-us/purview/), [`learn.microsoft.com/en-us/azure/`](https://learn.microsoft.com/en-us/azure/), or [`learn.microsoft.com/en-us/security/`](https://learn.microsoft.com/en-us/security/).

**Citation format:**
- In prose (README, docs/, PR descriptions): inline Markdown link, e.g. `[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)`.
- In code (`*.bicep`, `*.ps1`, `*.yml`, `*.yaml`): a comment on or directly above the relevant block, e.g. `// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts`.
- For product-capability, role-gating, configuration-setting, or limit claims, include a `## References` block with at least one entry in this format:

  ```markdown
  ## References

  - **[Short descriptive title](https://learn.microsoft.com/en-us/...)**
    Fetch date: YYYY-MM-DD
    > "Verbatim quote of ≤30 words that directly supports the claim."
  ```

**When Learn is silent:** If Learn does not cover the scenario, say so out loud, cite what Learn *does* say about the nearest adjacent topic, and flag the recommendation as "not in Learn — verify before merging".

**Rejection protocol:** Flag any PR that is missing a required Learn citation for a new Azure resource, REST endpoint, CLI/PowerShell cmdlet, or action. Require the author to add the citation before approval.

**Learn citation cadence:** Every cited URL should be re-verified on a fixed cadence (proposed: quarterly, aligned with the model-policy review). Broken links or deprecated pages block merge.

---

## Hard rule 4 — Destructive changes require explicit approval

**Source:** [pre-commit.instructions.md](../../instructions/pre-commit.instructions.md) §"Destructive changes".

Any PR that deletes a resource, collection, term, classification, data source, scan, policy, role assignment, or Purview object must:

1. Carry the `destructive` label.
2. Document a **rollback plan** in the PR description.
3. Receive explicit approval from at least one reviewer with:
   - `Collection Admin` (for data-plane deletes), or
   - `Contributor` on the resource group (for control-plane deletes).

**When `az deployment group what-if` reports a `Delete` action**, the PR must be labeled `destructive` before opening.

**When a reconciler script is run with `-PruneMissing` or `-Force`**, the PR must be labeled `destructive` and the What-If output showing which objects will be pruned/forced must be pasted into the PR description.

**Rejection protocol:** Reject any PR that shows a deletion in its diff or What-If output without the `destructive` label and a rollback plan.

---

## Usage

Load this skill on demand when:
- Reviewing a pull request.
- Drafting a PR description for `@artifact-resolver`.
- Running `/build-item` validation against staged changes.
- Authoring content that will appear in a commit message, PR body, or instruction file.

Do not load this skill:
- For general coding questions (use the default agent).
- For runtime debugging or error diagnosis (use logs, traces, and the error message itself).
- When the task is to edit or create a new instruction file (the canonical sources take precedence).

---

## References

- **[Microsoft Purview credential management](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management)**
  Fetch date: 2026-06-19
  > "Credentials should be managed by integration runtime configuration or stored in services like Azure Key Vault."
- **[Microsoft placeholder examples](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples)**
  Fetch date: 2026-06-19
  > "Use 00000000-0000-0000-0000-000000000000 for GUID placeholders."
- **[Customize AI in VS Code — Skills](https://code.visualstudio.com/docs/copilot/customization/overview)**
  Fetch date: 2026-06-19
  > "Skills are reusable capabilities that agents can load on demand to help with specific tasks."
- [`.github/instructions/security.instructions.md`](../../instructions/security.instructions.md) — 10 non-negotiable security principles.
- [`.github/instructions/sample-data.instructions.md`](../../instructions/sample-data.instructions.md) — synthetic-data rule.
- [`.github/instructions/pre-commit.instructions.md`](../../instructions/pre-commit.instructions.md) — per-PR checklist.
- [`.github/copilot-instructions.md`](../../copilot-instructions.md) — environment boundaries, grounding, evidence pattern.
- [`.github/instructions/primitives.instructions.md`](../../instructions/primitives.instructions.md) — primitive-selection rules (why this is a skill, not an instruction or prompt).
