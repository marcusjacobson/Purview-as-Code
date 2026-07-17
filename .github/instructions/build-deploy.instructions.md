---
description: "Canonical build, validate, and deploy commands for the control plane (Bicep) and data plane (Purview REST) of this repo."
applyTo: "infra/**,data-plane/**,scripts/**,.github/workflows/**"
---

# Build, validate, and deploy — canonical commands

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Domain-specific rules live in [`bicep.instructions.md`](bicep.instructions.md), [`powershell.instructions.md`](powershell.instructions.md), [`data-plane-yaml.instructions.md`](data-plane-yaml.instructions.md), and [`github-actions.instructions.md`](github-actions.instructions.md).

These are the verified commands for this repo. The agent should **run these rather than invent alternatives**, and must update this section (and the Learn citation) if any command changes.

## Prerequisites (local)

- PowerShell 7.4+ (`pwsh`)
- Azure CLI 2.60+ (`az --version`)
- Bicep CLI (installed via `az bicep install`; verify with `az bicep version`)
- Python 3.12+ (for `yamllint` only)
- Logged in: `az login` (or an active OIDC session in GitHub Actions)
- `PSScriptAnalyzer` and `powershell-yaml` PowerShell modules (installed on first run)

## Validate (must pass before every commit to `infra/`, `data-plane/`, `scripts/`, or `.github/workflows/`)

```pwsh
# 1. Bicep
az bicep lint  --file infra/main.bicep
az bicep build --file infra/main.bicep --outfile infra/main.json

# 2. YAML
pip install --quiet yamllint
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable}}" data-plane/

# 3. PowerShell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning -EnableExit
```

All three must exit 0. Treat any warning as a failure.

## Control-plane deploy (Azure Resource Manager)

Always run `what-if` first and include its output in the pull-request description.

```pwsh
$rg = 'rg-purview-lab'
az group create -n $rg -l eastus                                          # idempotent
az deployment group what-if      -g $rg -f infra/main.bicep -p infra/main.bicepparam
az deployment group create       -g $rg -f infra/main.bicep -p infra/main.bicepparam
```

The shipped `infra/main.bicepparam` is the `lab` parameter file. For a non-`lab` environment, substitute its `infra/main.<environment>.bicepparam` (created by copying the lab file, [ADR 0057](../../docs/adr/0057-multi-environment-and-branch-model.md)) — `deploy-infra.yml` performs the same selection and fails fast when the file is missing.

On a unified-only tenant ([ADR 0047](../../docs/adr/0047-unified-catalog-preview-api-coexistence.md)/[ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md): no classic account; never target a PAYG metering resource), append `--parameters deployPurviewAccount=false` to both the `what-if` and the `create` — same canonical commands, classic `Microsoft.Purview/accounts` resource skipped, `role-definitions` module still deployed ([conditional deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment)). Do not deploy `infra/modules/role-definitions.bicep` standalone as a workaround.

Reference: [Deploy Bicep files with Azure CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli), [What-if operation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if).

## Data-plane deploy (Purview REST APIs)

Every script supports `-WhatIf`. Always dry-run first. Runs in the order below — later stages assume earlier stages succeeded.

```pwsh
$acct = 'purview-contoso-lab'

./scripts/Deploy-Collections.ps1     -AccountName $acct -WhatIf
./scripts/Deploy-Glossary.ps1        -AccountName $acct -WhatIf
./scripts/Deploy-Classifications.ps1 -AccountName $acct -WhatIf
./scripts/Deploy-DataSources.ps1     -AccountName $acct -WhatIf
./scripts/Deploy-Scans.ps1           -AccountName $acct -WhatIf

# Re-run without -WhatIf once the plan has been reviewed.
```

Reference: [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).

## CI entry points

- [`validate.yml`](../workflows/validate.yml) — runs on every PR and push to `main`.
- [`deploy-infra.yml`](../workflows/deploy-infra.yml) — control plane; triggered by changes under `infra/**`.
- **The per-solution `deploy-<solution>.yml` workflows** — data plane, **one workflow per surface** ([ADR 0051](../../docs/adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)). Each is triggered by changes to the `data-plane/**` path and the single `scripts/Deploy-*.ps1` reconciler it owns. Five exist today: [`deploy-labels.yml`](../workflows/deploy-labels.yml), [`deploy-label-policies.yml`](../workflows/deploy-label-policies.yml), [`deploy-auto-label-policies.yml`](../workflows/deploy-auto-label-policies.yml), [`deploy-dlp.yml`](../workflows/deploy-dlp.yml), [`deploy-irm.yml`](../workflows/deploy-irm.yml).
  - **Surfaces with no per-solution workflow have no CI apply path at all.** Do not tell an operator that merging their YAML applies it. The apply path is running the surface's `scripts/Deploy-*.ps1` reconciler locally. Backfill is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

## Rules for the agent

- **Trust these commands.** Do not invent alternatives (`bicep build` instead of `az bicep build`, `Install-Module -Force -AllowPrerelease`, etc.).
- **Run validate before proposing changes.** If a command fails, capture the error verbatim in the PR description rather than guessing a fix.
- **Never skip `what-if` / `-WhatIf`.** No exceptions.
- If one of these commands no longer works, update this section in the same PR and cite the Learn page that confirms the new form.
