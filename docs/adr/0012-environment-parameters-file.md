# 0012 — Environment parameters file as the source of truth for the control plane

- **Status:** Accepted
- **Date:** 2026-04-19
- **Gates:** Wave 0 refactor of the 5.0 and 5a orchestrators; establishes the pattern for Wave 0 #5b, #5c and every future `infra/modules/*.bicep` orchestrator.
- **Deciders:** @contoso

## Context

Wave 0 #5.0 ([PR #30](https://github.com/contoso/Purview-as-Code-Generic/pull/30)) and Wave 0 #5a ([PR #31](https://github.com/contoso/Purview-as-Code-Generic/pull/31)) shipped PowerShell orchestrators that hardcode the lab resource names, resource group, region, and tags directly as parameter defaults:

```powershell
[string]$ResourceGroupName = 'rg-purview-lab',
[string]$Location           = 'eastus',
[string]$VaultName          = 'kv-contoso-lab-01',
```

This couples *what the script does* (orchestrate a Bicep module) to *what this specific lab deploys* (names, subscription scope, tags). Three problems follow:

1. **Drift surface.** The real lab resource group is `rg-purview-lab` but the documented canonical name across naming instructions, Copilot instructions, workflows, prompts, [ADR 0010](0010-automation-identity-subject-model.md), [`docs/project-plan.md`](../project-plan.md), and (added 2026-05-04 by the Squad retrofit) [`.squad/memory/context.md`](../../.squad/memory/context.md) is `rg-purview-lab`. Today the drift can only be reconciled by editing seven files.
2. **No on-ramp to a second environment.** A future `prod` environment would require duplicating every orchestrator or threading `-Environment` through every call site.
3. **Review cost.** A name change (say, `log-contoso-lab` → `log-purview-lab`) must touch the script file, which triggers code review rather than parameter review.

Microsoft Learn's guidance on [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files) is explicit about the pattern: "The parameter file exposes values that may change from a given subscription, environment, and/or region. Leveraging a parameter file will drive consistency in your IaC deployments while also providing flexibility." The Learn-canonical multi-environment convention is to keep one parameters file per environment (for example `main.dev.bicepparam`, `main.prod.bicepparam`).

We cannot yet adopt `.bicepparam` natively because a `.bicepparam` file binds to exactly one Bicep template via its `using` statement, and this repo does not (yet) have an `infra/main.bicep` that composes the individual modules — each module is deployed independently from a PowerShell orchestrator. Building `infra/main.bicep` prematurely would pull deploy sequencing, dependency expression, and subscription-scope vs resource-group-scope decisions into the same PR as the parameter-externalization work, which is too much scope.

We need a format that:

- matches the repo's existing data-plane grain (YAML manifests under a domain folder, consumed by PowerShell reconcilers),
- is consumed identically by every orchestrator (no per-script schema drift),
- resolves the `rg-purview-lab` vs `rg-purview-lab` drift in one file, and
- keeps a clean on-ramp to native `.bicepparam` if and when `infra/main.bicep` lands.

## Decision

We will introduce a **single environment parameters file** at `infra/parameters/<env>.yaml` as the source of truth for every value that varies by environment, subscription, region, or lab identity. The initial and only environment is `lab`, materialized as `infra/parameters/lab.yaml`. The six specific rules:

1. **Folder is `infra/parameters/`.** The folder name carries the "this is *the* parameters source" meaning, mirroring Microsoft Learn's own vocabulary for Bicep parameter files. Filename is `<env>.yaml` only — no redundant `parameters` suffix inside the folder.
2. **Values that belong in the file.**
   - Resource group name, region, and tags (today's drift surface).
   - Deployed resource names (`log-contoso-lab`, `kv-contoso-lab-01`, and every `infra/modules/*.bicep`-created name that follows).
   - Purview account name (consumed by future data-plane orchestrators).
   - Cross-module identifiers (for example, the Log Analytics workspace resource ID that `keyvault.bicep` needs for its diagnostic sink) are **derived**, not stored — the orchestrator composes them from the values above so one edit in the YAML flows through.
3. **Values that do not belong in the file.**
   - Subscription ID and tenant ID. These flow via `az account set` locally and via GitHub Environment variables (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`) in CI, per [ADR 0010](0010-automation-identity-subject-model.md) and the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). Committing a real subscription ID would violate the identifier-redaction rule.
   - Secrets, keys, tokens, certificate thumbprints, connection strings. These live in Key Vault or GitHub Secrets per [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md).
   - ADR-mandated invariants. Values that are security or compliance constants set by an ADR — [ADR 0011](0011-certificate-lifecycle.md) §2's 90-day soft-delete, purge-protection-on, 2048-bit RSA SHA-256 cert, 12-month validity — remain hardwired in the Bicep module or the orchestrator. They are not environment-variable; changing them changes the ADR.
4. **Script contract.** Every `New-*.ps1` and future `Deploy-*.ps1` orchestrator that creates or reconciles an Azure resource gains a `-ParametersFile <path>` parameter, defaulting to `infra/parameters/lab.yaml` relative to the repo root. The resolution order for any single value is: explicit CLI parameter → value in `$ParametersFile` → hard error naming the missing key. Hardcoded defaults for resource names and resource group are removed; the YAML becomes the only source.
5. **Schema and validation.** The YAML is validated at load time by the orchestrator against an inline PowerShell schema (required keys, type checks). A separate JSON Schema file is a future nice-to-have, not a gate — the inline check plus `yamllint` on the file itself is enough for Wave 0.
6. **On-ramp to `.bicepparam`.** When `infra/main.bicep` lands in a future wave, `infra/parameters/lab.bicepparam` is the natural sibling to `infra/parameters/lab.yaml`. Either (a) both coexist — YAML for orchestrator-driven single-module deploys, `.bicepparam` for the composed main template — or (b) the YAML becomes the single canonical source and the `.bicepparam` is generated from it at CI time. That choice is a future ADR, not this one.

## Consequences

What this unblocks or improves:

- The `rg-purview-lab` vs `rg-purview-lab` drift becomes a one-line edit in `infra/parameters/lab.yaml` instead of a six-file meta PR.
- Wave 0 #5b (`New-AutomationEntraApp.ps1`) and Wave 0 #5c (`New-AutomationCertificate.ps1`) adopt the pattern from day one; they never acquire hardcoded defaults to refactor away later.
- A future second environment (hypothetical `prod`) is a new file — `infra/parameters/prod.yaml` — not a branch-wide diff.
- Review surface narrows. A name change no longer touches `.ps1` files.
- Aligns the control-plane idiom with the data-plane idiom: YAML manifest + PowerShell orchestrator.

What becomes harder or constrained:

- Every control-plane orchestrator now has a mandatory external dependency (the YAML file). The former "run the script with no arguments" flow becomes "run the script; it reads `infra/parameters/lab.yaml`". The `-ParametersFile` default preserves the zero-argument invocation but documentation must be updated so that deleting the file is an immediate visible failure, not a silent fall-back to hardcoded names.
- Adds a small amount of YAML-parsing code to every orchestrator. We mitigate this by using the same `powershell-yaml` module already required by the data-plane reconcilers.
- Two parameter formats will coexist for a while: the YAML introduced here, and the `.bicepparam` idiom when `infra/main.bicep` eventually lands. This is acceptable because the YAML file is authoritative and the `.bicepparam` (if adopted) is generated or manually kept in sync under CI review.

Security posture this upholds:

- [`security.instructions.md`](../../.github/instructions/security.instructions.md) principle #1 (no secrets in source): the file carries only non-sensitive naming metadata. The commit-message / pre-commit secret-regex scan continues to apply.
- [`copilot-instructions.md`](../../.github/copilot-instructions.md) "Environment and identifier boundaries": subscription ID and tenant ID stay out of source per rule 3.

Scope deliberately deferred:

- Generation of `.bicepparam` from YAML.
- JSON Schema file for the YAML.
- A `prod` environment file.
- Migration of the data-plane reconcilers (`Deploy-Collections.ps1` et al.) to read their Purview account name from the same file. This is a clean follow-up once the control-plane pattern is shipped and `purviewAccountName:` is populated.

## Alternatives considered

**Alternative A: Native `.bicepparam` files (`infra/parameters/lab.bicepparam`).** Rejected for now — a `.bicepparam` file binds to exactly one Bicep template via its `using` statement. Adopting it today forces `infra/main.bicep` to exist and to compose `law.bicep` + `keyvault.bicep` (and eventually every future module). That is a larger architectural decision than parameter externalization, and it pulls in deploy-sequencing and scope questions we are not ready to answer. The on-ramp clause in the Decision section keeps this open as a future ADR.

**Alternative B: Per-script `params.json` with a `Global` section plus per-script sections, matching the sibling [`Azure-Deployment-Pipelines`](https://github.com/contoso/Azure-Deployment-Pipelines) repo pattern.** Rejected — that pattern bucketizes by *script*, not by *environment*. The `Global` section (subscription, tenant, region, tags) would duplicate across every orchestrator directory, and the pattern has no natural slot for a second environment. The `_description` / `_scripts` / `_note` metadata fields also bloat the file without adding enforcement.

**Alternative C: GitHub Environment variables and `$env:*` locally, with a `.env` file for local dev.** Rejected — weakly typed, scattered (one env var per value), not reviewable as a single diff, and nothing to lint against. We will still use GitHub Environment secrets for the values that actually are secret (subscription ID, tenant ID, OIDC client IDs) per [ADR 0010](0010-automation-identity-subject-model.md); this ADR governs the *naming* layer, not the *secrets* layer.

**Alternative D: Do nothing — keep hardcoded defaults in each orchestrator.** Rejected — the drift surface grows linearly with every new orchestrator, and [Wave 0 #5b](../project-plan.md) and [#5c](../project-plan.md) would land with the same problem.

## Citations

- [Create a parameters file for Bicep deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files) — canonical parameter-files idiom, `<template>.<env>.bicepparam` multi-environment convention, rationale ("The parameter file exposes values that may change from a given subscription, environment, and/or region").
- [Bicep `using` statement](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-using) — binding a `.bicepparam` file to a specific template; the constraint that motivates deferring native `.bicepparam` adoption.
- [Use Azure Key Vault to pass a secret as a parameter during Bicep deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/key-vault-parameter) — canonical Microsoft Learn mechanism for keeping secrets out of parameter files.
- [Azure deployment environments and Cloud Adoption Framework guidance](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/landing-zone/design-area/deployments) — environment-per-file convention at landing-zone scale.
- [ADR 0010 — Automation identity subject model](0010-automation-identity-subject-model.md) — the GitHub Environment that carries `AZURE_SUBSCRIPTION_ID` / `AZURE_TENANT_ID` / `AZURE_CLIENT_ID`; the line between values that belong in this YAML and values that must stay in GitHub Secrets.
- [ADR 0011 — Certificate lifecycle for the automation identity](0011-certificate-lifecycle.md) — examples of ADR-mandated invariants (90-day soft-delete, purge-protection) that are deliberately **not** externalized into this parameters file.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — principles #1 (no secrets in source) and #4 (least privilege), which together define the floor for what can and cannot enter `infra/parameters/<env>.yaml`.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries" section; why subscription ID and tenant ID are excluded from the file.
