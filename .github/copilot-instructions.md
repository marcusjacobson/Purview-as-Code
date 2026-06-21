# Copilot instructions — Purview-as-Code (contoso-lab)

These instructions apply to **every** file in this repository. Scoped rules live under [`.github/instructions/`](instructions/) and override / extend the baseline below.

## Trust these instructions

Treat this file as the first and most reliable source for how to work in this repository. Do the following in order:

1. **Read `copilot-instructions.md` and any matching `.github/instructions/*.instructions.md` first.** If it answers the question — build command, folder purpose, security rule, citation requirement — use that answer. Do not re-derive it with search, file reads, or code exploration.
2. **If the instructions are incomplete or ambiguous**, search the codebase (READMEs, `docs/`, existing `infra/` and `data-plane/` files) before proposing a change.
3. **If the codebase is silent or the instructions and codebase disagree with each other**, consult Microsoft Learn per the "Grounding — Microsoft Learn is the central source of truth" section below.
4. **If an instruction is demonstrably wrong** (a command fails, a path has moved, a citation 404s), fix the instruction in the same pull request as the change that surfaced the problem. Cite the Learn page that confirms the corrected form. Do not silently work around it.

Precedence when sources disagree: **Microsoft Learn → this file and scoped instructions → repository code → model training**. Model training never wins.

Minimize exploration. If the "Build, validate, and deploy" or "Project layout" sections below already name the file or command you need, go straight there.

## Build, validate, and deploy — canonical commands

See [`instructions/build-deploy.instructions.md`](instructions/build-deploy.instructions.md). Applies to changes under `infra/`, `data-plane/`, `scripts/`, and `.github/workflows/`.

## Project layout

Two planes, kept deliberately separate. A change almost always lives in exactly one of these folders.

| Folder | Plane | Purpose | Entry point |
|---|---|---|---|
| `infra/` | Control | `Microsoft.Purview/accounts` + dependencies as Bicep | [`infra/main.bicep`](../infra/main.bicep), [`infra/main.bicepparam`](../infra/main.bicepparam) |
| `infra/modules/` | Control | Reusable Bicep modules (private endpoints, RBAC, diagnostics) | one module per resource type |
| `data-plane/collections/` | Data | Desired collection hierarchy | [`collections.yaml`](../data-plane/collections/collections.yaml) |
| `data-plane/glossary/` | Data | Business glossary terms | [`glossary.yaml`](../data-plane/glossary/glossary.yaml) |
| `data-plane/classifications/` | Data | Custom classifications and rules | [`classifications.yaml`](../data-plane/classifications/classifications.yaml) |
| `data-plane/data-sources/` | Data | Registered sources (reference credentials by Key Vault, never inline) | [`data-sources.yaml`](../data-plane/data-sources/data-sources.yaml) |
| `data-plane/scans/` | Data | Scans, scan rulesets, triggers | [`scans.yaml`](../data-plane/scans/scans.yaml) |
| `data-plane/administrative-units/` | Data (Entra) | Microsoft Entra administrative units referenced by AU-scoped Purview role groups (default state: empty list). See [ADR 0002](../docs/adr/0002-administrative-units.md). | [`administrative-units.yaml`](../data-plane/administrative-units/administrative-units.yaml) |
| `scripts/` | Data | Idempotent PowerShell helpers that apply `data-plane/**` via Purview REST (plus [`Deploy-AdministrativeUnits.ps1`](../scripts/Deploy-AdministrativeUnits.ps1) via Microsoft Graph for Entra AUs) | one `Deploy-*.ps1` per domain + [`Connect-Purview.ps1`](../scripts/Connect-Purview.ps1) |
| `.github/workflows/` | CI/CD | [`validate.yml`](workflows/validate.yml), [`deploy-infra.yml`](workflows/deploy-infra.yml), [`deploy-data-plane.yml`](workflows/deploy-data-plane.yml) | path filters bind each workflow to its plane |
| `.github/instructions/` | Meta | Path-scoped Copilot rules (Bicep, PowerShell, YAML, workflows) | one file per domain |
| `.github/prompts/` | Meta | Reusable prompt files invoked with `/` in Copilot Chat. Validation engine: `/build-item`. Operational: `/deploy-infra`, `/deploy-datamap`, `/security-review`. Content interviews: `/add-classification`, `/add-data-source` (invoked by `@squad`). Session lifecycle: `/prepare-handoff`, `/resume-from-handoff`. | one `*.prompt.md` per workflow |
| `.github/agents/` | Meta | Workspace-scoped custom agents (personas with scoped tools and model pinning) per [Custom agents in VS Code](https://code.visualstudio.com/docs/copilot/customization/custom-chat-modes) | one `*.agent.md` per persona; see [`agents/README.md`](agents/README.md) |
| `docs/` | Docs | Getting started + architecture | [`getting-started.md`](../docs/getting-started.md), [`architecture.md`](../docs/architecture.md) |
| `tests/` | Tests | Pester 5.x unit tests for `scripts/**` helpers (no live tenant) | [`tests/Run-Pester.ps1`](../tests/Run-Pester.ps1), [`tests/README.md`](../tests/README.md) |

### Change routing

- **New / changed Azure resource?** → `infra/` only. Validates through [`validate.yml`](workflows/validate.yml); deploys through [`deploy-infra.yml`](workflows/deploy-infra.yml).
- **New / changed catalog content (collection, term, classification, source, scan, policy)?** → `data-plane/` only. Deploys through [`deploy-data-plane.yml`](workflows/deploy-data-plane.yml).
- **New / changed apply logic?** → `scripts/` only (still triggers [`deploy-data-plane.yml`](workflows/deploy-data-plane.yml) because it owns the data plane).
- **New / changed CI behavior?** → `.github/workflows/` only. Security rules in [`github-actions.instructions.md`](instructions/github-actions.instructions.md) apply.
- **Documentation?** → `docs/` or the top-level [`README.md`](../README.md). Never the only change in a PR that also touches `infra/` or `data-plane/` — doc-only PRs stay doc-only so reviewers don't miss state-changing edits.

### Do not

- Do not create top-level folders beyond the ones above without a PR that updates this section and [`docs/architecture.md`](../docs/architecture.md).
- Do not put data-plane YAML under `infra/`, and do not put Bicep under `data-plane/`. The plane-to-workflow path filters depend on this separation.
- Do not introduce a second deploy tool (Terraform, Pulumi, ARM JSON authored by hand) without an ADR in `docs/` and explicit reviewer approval.

### Rules map — where each rule lives

Scoped instruction files under [`.github/instructions/`](instructions/) are grouped below by concern. Copilot loads each one automatically when a file matching its `applyTo:` glob is in context; humans can use this table as the single entry point.

| Concern | File | Scope (`applyTo:`) |
|---|---|---|
| **Cross-cutting** | | |
| Security principles (10 rules) + conflict protocol | [`security.instructions.md`](instructions/security.instructions.md) | `**` |
| MCP / tool-usage policy (read-only default, destructive confirmation, skill allow-list) | [`mcp-tool-usage.instructions.md`](instructions/mcp-tool-usage.instructions.md) | `**` |
| Pre-commit checklist — every PR + destructive + command-fail protocol | [`pre-commit.instructions.md`](instructions/pre-commit.instructions.md) | `**` |
| PR description rules | [`pull-request.instructions.md`](instructions/pull-request.instructions.md) | `**` |
| Commit message convention | [`commit-message.instructions.md`](instructions/commit-message.instructions.md) | `**` |
| Sample-data rule (synthetic PII, anchored regex) | [`sample-data.instructions.md`](instructions/sample-data.instructions.md) | `**` |
| Context handoff rules (when, what to include, what to redact) | [`context-handoff.instructions.md`](instructions/context-handoff.instructions.md) | `**` |
| Markdown writing/formatting rules | [`markdown.instructions.md`](instructions/markdown.instructions.md) | `**/*.md` |
| **Authoring Copilot primitives** | | |
| Primitive selection (instruction / prompt / agent / skill) | [`primitives.instructions.md`](instructions/primitives.instructions.md) | authoring surfaces |
| Custom agent authoring rules | [`agents.instructions.md`](instructions/agents.instructions.md) | `.github/agents/**/*.agent.md` |
| Squad memory and charter rules | [`squad-memory.instructions.md`](instructions/squad-memory.instructions.md) | `.squad/**/*.md` |
| **Naming** | | |
| Azure resource + Purview catalog naming | [`naming.instructions.md`](instructions/naming.instructions.md) | `infra/**`, `data-plane/**`, `scripts/**`, `docs/**` |
| **Build / deploy** | | |
| Canonical validate / control-plane / data-plane commands | [`build-deploy.instructions.md`](instructions/build-deploy.instructions.md) | `infra/**`, `data-plane/**`, `scripts/**`, `.github/workflows/**` |
| **Per-domain (control plane)** | | |
| Bicep / ARM secure-by-design + `infra/**` pre-commit | [`bicep.instructions.md`](instructions/bicep.instructions.md) | `infra/**/*.bicep`, `.bicepparam`, `.json` |
| **Per-domain (data plane)** | | |
| Data-plane YAML rules + `data-plane/**` pre-commit | [`data-plane-yaml.instructions.md`](instructions/data-plane-yaml.instructions.md) | `data-plane/**/*.yaml`, `.yml` |
| PowerShell REST helpers + drift discipline + `scripts/**` pre-commit | [`powershell.instructions.md`](instructions/powershell.instructions.md) | `scripts/**/*.ps1` |
| **Per-domain (CI)** | | |
| GitHub Actions secure-by-design + workflows pre-commit | [`github-actions.instructions.md`](instructions/github-actions.instructions.md) | `.github/workflows/**` |
| **Per-domain (tests)** | | |
| Pester unit-test conventions (no live tenant, AST extraction, synthetic IDs) | [`tests.instructions.md`](instructions/tests.instructions.md) | `tests/**/*.ps1` |

If a rule isn't in one of these files, it lives in this document.

## Pre-commit checklist (required for state-changing PRs)

Cross-cutting bullets (every PR, destructive changes, "If a command fails" protocol) live in [`instructions/pre-commit.instructions.md`](instructions/pre-commit.instructions.md). Per-domain bullets live with the matching scoped rules:

- `infra/**` → [`instructions/bicep.instructions.md`](instructions/bicep.instructions.md#pre-commit-checklist--infra-changes)
- `data-plane/**` → [`instructions/data-plane-yaml.instructions.md`](instructions/data-plane-yaml.instructions.md#pre-commit-checklist--data-plane-changes)
- `scripts/**` → [`instructions/powershell.instructions.md`](instructions/powershell.instructions.md#pre-commit-checklist--scripts-changes)
- `.github/workflows/**` → [`instructions/github-actions.instructions.md`](instructions/github-actions.instructions.md#pre-commit-checklist--githubworkflows-changes)

Paste the output of each command into the PR description in fenced code blocks. Reviewers will not approve without this evidence.

## Non-negotiable security principles

See [`instructions/security.instructions.md`](instructions/security.instructions.md). Applies to every file in the repo. The "What to do when a request conflicts with these principles" protocol lives in the same file.

## Environment and identifier boundaries

This repo targets exactly one deployment environment: **`lab`**, backed by the `contoso-lab` Microsoft Purview account in the tenant `contoso.onmicrosoft.com`. The agent must treat this as a hard scope boundary.

### Environment rules

- Unless a PR *explicitly* adds a new environment (with reviewer approval and its own GitHub Environment, secrets, and federated credentials), every workflow, Bicep parameter file, PowerShell script, and sample command targets `lab`.
- Never emit `environment: prod` (or `dev`, `stage`, `qa`, etc.) into a workflow, Bicep, YAML, or shell snippet. If a multi-environment story is requested, propose it as a design PR first and cite the [Environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment) docs.
- Resource group: `rg-purview-lab`. Region: `eastus`. Do not substitute other resource groups or regions in examples.

### Identifier rules

Real identifiers are reconnaissance-grade data. Treat them the same way you treat secrets.

- **Never paste** into any file, commit message, PR description, or sample output:
  - Real Entra ID tenant IDs
  - Real Azure subscription IDs
  - Real managed identity, service principal, user, or group object IDs
  - Real resource IDs beyond the resource group named above
  - Real user principal names (UPNs) or email addresses
  - Real customer, partner, or internal project names

- **Always use these Microsoft-documented placeholders** in samples, docs, and YAML examples:

  | Identifier kind | Placeholder | Notes |
  |---|---|---|
  | GUID (tenant, subscription, object ID, client ID) | `00000000-0000-0000-0000-000000000000` | Per [Microsoft placeholder examples](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples). |
  | Organization name | `contoso`, `fabrikam`, `adatum` | Microsoft fictitious-company names. |
  | DNS domain | `contoso.com`, `example.com` | `example.com` is reserved by [RFC 2606](https://www.rfc-ietf.org/rfc/rfc2606.txt). |
  | User email / UPN | `user@contoso.com` | |
  | Resource name | `<workload>-<env>-<kind>`, e.g. `purview-lab-account` | Uses placeholders for any field that isn't already the real `contoso-lab` name the repo targets. |
  | Tenant / subscription / resource ID in `data-plane/**` YAML | `${env:VAR}` token resolved at deploy time by [`scripts/Resolve-EnvTokens.ps1`](../scripts/Resolve-EnvTokens.ps1) | Per [ADR 0023](../docs/adr/0023-identifier-resolution.md) §Decision Category 2. Allow-listed variables only: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `PURVIEW_ACCOUNT_NAME`, `PURVIEW_RG`. |
  | Entra principal object ID in `data-plane/**` YAML | Stable `displayName` resolved at deploy time by [`scripts/Get-EntraPrincipalIdByDisplayName.ps1`](../scripts/Get-EntraPrincipalIdByDisplayName.ps1) | Per [ADR 0023](../docs/adr/0023-identifier-resolution.md) §Decision Category 3. Display name must be unique in the tenant. |

### When real IDs are actually needed

- Real values belong in GitHub environment secrets / variables (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `PURVIEW_ACCOUNT_NAME`) and are referenced by name in workflows, not by value in source.
- If a local script run requires a real value, source it from `$env:*` or prompt the user; never hard-code it. See the "No secrets in source" rule in the security principles above.
- For data-plane YAML that needs to emit a real value into a Purview payload, use the resolution mechanisms in [ADR 0023](../docs/adr/0023-identifier-resolution.md): `${env:VAR}` tokens for Azure topology IDs, `displayName` lookup for Entra principals. Never inline the real value into the YAML.

### Reviewer and agent obligations

- Reject any PR diff that contains a 32-character hex or GUID pattern that does not match the zero-GUID placeholder. Grep: `grep -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'` — every match must either be the zero GUID, a schema example, or a role-definition GUID from `learn.microsoft.com`.
- Reject any PR that introduces a second environment without the explicit reviewer approval described in the [pull request description rules](instructions/pull-request.instructions.md).

## Naming convention

See [`instructions/naming.instructions.md`](instructions/naming.instructions.md). Applies to `infra/**`, `data-plane/**`, `scripts/**`, and `docs/**`.

## Branding and voice

Always use exact, current Microsoft product names. Shorthand is not acceptable in committed artifacts.

- ✅ `Microsoft Entra ID` — never `Azure AD` or `AAD`
- ✅ `Microsoft 365` — never `Office 365` or `O365`
- ✅ `Microsoft Purview` — never `Azure Purview`
- ✅ `Microsoft Sentinel` — never `Azure Sentinel`
- ✅ `Microsoft Fabric` — never `Azure Synapse` when referring to Fabric workloads

Use the full product name on first reference in every artifact; subsequent shorthand within the same document (e.g., `Purview`) is acceptable. Squad personas write in first-person plural (`We recommend…`, `Our analysis shows…`) within docs they author.

## Evidence pattern for Microsoft Learn citations

Beyond the inline `// Reference: <url>` and `[link](url)` formats described in the "Grounding" section below, any committed artifact that makes a product-capability, role-gating, configuration-setting, or limit claim should include a `## References` block with at least one entry in this format:

```markdown
## References

- **[Short descriptive title](https://learn.microsoft.com/en-us/...)**
  Fetch date: YYYY-MM-DD
  > "Verbatim quote of ≤30 words that directly supports the claim."
```

When Microsoft Learn does not document a behavior, write the explicit phrase:

> Microsoft Learn does not currently document this behavior as of `<fetch date>`.

Do not substitute non-Microsoft sources to fill the gap.

## Squad and meta-agent integration

This repository uses a Squad-based agent model adapted for a single-owner lab:

1. **Tier 1 — Squad orchestrator**: [`@squad`](agents/squad.agent.md) activates one of five personas (Lead/Architect, Security Specialist, Automation Engineer, Tester/Validator, Scribe).
2. **Tier 2 — Meta-workflow agents**: [`@idea-intake`](agents/idea-intake.agent.md), [`@artifact-resolver`](agents/artifact-resolver.agent.md), [`@owner-approval`](agents/owner-approval.agent.md).
3. **Persona definitions and charters**: live in [`../.squad/team.md`](../.squad/team.md) and [`../.squad/charters/`](../.squad/charters/).

See [`agents/README.md`](agents/README.md) for the full agent index.

**Default flow is agent-led** (see [ADR 0014](../docs/adr/0014-agents-as-default-entry-point.md)):

- All work — Progress-checklist items and cross-cutting work alike — enters through `@idea-intake` → `@artifact-resolver` → `@owner-approval`.
- `@idea-intake` enforces the [`docs/project-plan.md`](../docs/project-plan.md) §6 dependency-matrix and §8 ADR gates inline when the work maps onto a Progress-checklist row.
- `/build-item` is the shared validation engine called by `@artifact-resolver` (and any human-driven build loop).
- `@squad` is reserved for content-creation interviews (Security Specialist drafting a classification, Automation Engineer onboarding a data source) and persona-led discussion. It is not a lifecycle agent.
- All flows finish at the `owner-approved` label, applied by `@owner-approval` and enforced by [`pr-auto-merge.yml`](workflows/pr-auto-merge.yml).

**Hard rules for Squad work:**

- Never modify [`../.squad/memory/context.md`](../.squad/memory/context.md) or [`../.squad/memory/decisions.md`](../.squad/memory/decisions.md) outside the documented Scribe handoff workflow. Scoped enforcement: [`instructions/squad-memory.instructions.md`](instructions/squad-memory.instructions.md).
- Never merge, deploy, or finalize any artifact without an explicit lab-owner approval gate (the `owner-approved` label on the PR, applied by the lab owner identity `contoso`).
- All agent outputs are proposals until the lab owner approves them.

## MCP and tool-usage policy

See [`instructions/mcp-tool-usage.instructions.md`](instructions/mcp-tool-usage.instructions.md). Applies to every chat turn. Custom agent tool-scoping rules live in [`instructions/agents.instructions.md`](instructions/agents.instructions.md).

## Primitive selection guidance

See [`instructions/primitives.instructions.md`](instructions/primitives.instructions.md). Applies when the user asks Copilot to create a prompt, agent, instruction, or skill.

## Grounding — Microsoft Learn is the central source of truth

Microsoft Learn (`learn.microsoft.com`) is the **authoritative reference** for every recommendation, code snippet, resource schema, CLI/PowerShell invocation, API call, and deployment pattern produced in this repository. This rule is non-negotiable and overrides AI model training data when the two disagree.

### Research order (mandatory)

Before producing any code, template, script, workflow, YAML manifest, or architectural recommendation, research must proceed in this order:

1. **Microsoft Learn first.** Search `learn.microsoft.com/en-us/purview/`, `learn.microsoft.com/en-us/azure/`, `learn.microsoft.com/en-us/security/`, `learn.microsoft.com/en-us/rest/api/purview/`, and `learn.microsoft.com/en-us/azure/templates/microsoft.purview/` for the relevant topic. Use the fetch/search tools; do not rely on memory.
2. **Official Microsoft properties second** — only when Learn does not cover the topic. Acceptable fallbacks: `techcommunity.microsoft.com`, `github.com/Azure/...` official samples, `github.com/MicrosoftDocs/...`, Azure Architecture Center (`learn.microsoft.com/en-us/azure/architecture/`).
3. **Non-Microsoft sources last** — Stack Overflow, personal blogs, third-party tutorials, AI training recall. These may only be used to *frame a question*, never to *produce a final answer*. Any snippet derived from such a source must be re-verified against a Learn page before being committed.

### No training-data-only answers for technical content

The following categories of output must be grounded in a currently-reachable Microsoft Learn page (or official Microsoft property, per the fallback rule) and must cite the URL in a comment, commit message, PR description, or nearby prose:

- **Bicep / ARM / Terraform** — resource type, API version, property names, required vs. optional, and allowed values must match [`learn.microsoft.com/en-us/azure/templates/...`](https://learn.microsoft.com/en-us/azure/templates/). Do not invent properties or API versions from training data.
- **Purview REST APIs** — endpoint, path, verb, request/response shape, and API version must match [`learn.microsoft.com/en-us/rest/api/purview/`](https://learn.microsoft.com/en-us/rest/api/purview/).
- **Azure CLI (`az`) / Azure PowerShell (`Az.*`)** — command, subcommand, parameter names, and output shape must match the current Learn reference (`learn.microsoft.com/en-us/cli/azure/...` or `learn.microsoft.com/en-us/powershell/module/...`). Do not use deprecated or hallucinated flags.
- **GitHub Actions for Azure** — action name, version, and input schema must match [`learn.microsoft.com/en-us/azure/developer/github/`](https://learn.microsoft.com/en-us/azure/developer/github/) or the action's official README (`github.com/Azure/*`).
- **YAML manifests** that drive our scripts — field names and allowed values must be traceable to the corresponding REST API or Learn reference.
- **Security / RBAC / network recommendations** — must cite a Learn page under `/purview/`, `/azure/`, or `/security/`.

### Citation format

- In prose (README, docs/, PR descriptions): inline Markdown link, e.g. `[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)`.
- In code (`*.bicep`, `*.ps1`, `*.yml`, `*.yaml`): a comment on or directly above the relevant block, e.g. `// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts`.
- When a block is the direct transcription of a Learn sample, note that explicitly in the comment.

### When Learn is silent or contradicts training data

- **If Learn does not cover the scenario**, say so out loud, cite what Learn *does* say about the nearest adjacent topic, and flag the recommendation as "not in Learn — verify before merging".
- **If Learn contradicts model training**, Learn wins. Do not quietly emit the training-data version.
- **If Learn pages disagree** (e.g., a preview doc and a GA doc), prefer the GA / most recently updated page and cite both.
- **If a web fetch fails**, do not guess. Note the failure, retry with a sibling URL, and surface the gap rather than back-filling from memory.

### Security grounding

Every security-sensitive recommendation in this repo must cite a Microsoft Learn page. Do not invent guidance. When in doubt, link to the relevant page under `learn.microsoft.com/en-us/purview/`, `learn.microsoft.com/en-us/azure/`, or `learn.microsoft.com/en-us/security/`.

### API version pinning

Every Azure resource API version (Bicep) and REST `api-version` (scripts) must be pinned explicitly and traceable to a Learn reference page. The specific rules — GA-over-preview, one version per resource type across the repo, deprecation-triggers-migration — live in [`instructions/bicep.instructions.md`](instructions/bicep.instructions.md) and [`instructions/powershell.instructions.md`](instructions/powershell.instructions.md).

