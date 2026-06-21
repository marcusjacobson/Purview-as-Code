# `infra/parameters/` — environment parameters files

This folder holds the **source of truth** for every value that varies by environment, subscription, region, or lab identity. Each file is named `<env>.yaml` and is consumed by every control-plane orchestrator (`scripts/New-*.ps1` and the `scripts/Deploy-*.ps1` reconcilers) via a mandatory `-ParametersFile` switch whose default is `infra/parameters/lab.yaml`.

The naming and scope rules are fixed in [ADR 0012 — Environment parameters file as the source of truth for the control plane](../../docs/adr/0012-environment-parameters-file.md). This README summarizes the file layout and the consumer contract; the authoritative rules live in the ADR.

## Files

| File | Environment | Notes |
|---|---|---|
| [`lab.yaml`](lab.yaml) | `lab` | The only live environment today. Backs the `contoso-lab` subscription / `rg-purview-lab` resource group. |

Adding a second environment (hypothetical `prod`) means dropping a `prod.yaml` in this folder and invoking orchestrators with `-ParametersFile infra/parameters/prod.yaml`. No code change is required.

## What belongs in the file

Per [ADR 0012 Decision §2](../../docs/adr/0012-environment-parameters-file.md):

- Resource group name, region, and tags.
- Resource names for every Azure resource managed from `infra/modules/*.bicep` (for example `log-contoso-lab`, `kv-contoso-lab-01`).
- Purview account name (consumed by future data-plane orchestrators).
- Environment-variable knobs whose correct value depends on the environment (for example Log Analytics retention in days; Key Vault `publicNetworkAccess`).

## What does **not** belong in the file

Per [ADR 0012 Decision §3](../../docs/adr/0012-environment-parameters-file.md):

- **Subscription ID and tenant ID.** These flow via `az account set` locally and GitHub Environment secrets (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`) in CI per [ADR 0010](../../docs/adr/0010-automation-identity-subject-model.md) and the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). Committing a real subscription ID would violate the identifier-redaction rule.
- **Secrets, keys, tokens, certificate thumbprints, connection strings.** These live in Key Vault or GitHub Secrets per [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) principle #1.
- **ADR-mandated invariants.** Values that are security or compliance constants set by an ADR — [ADR 0011](../../docs/adr/0011-certificate-lifecycle.md) §2's 90-day soft-delete, purge-protection-on, 2048-bit RSA SHA-256 cert, 12-month validity — remain hardwired in the Bicep module or the orchestrator. They are not environment-variable; changing them changes the ADR.

## Consumer contract

Every orchestrator that creates or reconciles an Azure resource implements this contract:

- Accepts `-ParametersFile <path>` (default `infra/parameters/lab.yaml` relative to the repo root).
- Loads the YAML via `powershell-yaml`'s `ConvertFrom-Yaml`.
- Validates that the required top-level keys and per-resource keys it consumes are present; hard-errors with a named-key message if any are missing.
- Value resolution for any single value is: explicit CLI parameter (for example `-ResourceGroupName foo`) → value read from `-ParametersFile` → hard error.
- Does **not** ship hardcoded defaults for resource names, resource groups, regions, or tags. The YAML is the only source.

Reference:

- [Create a parameters file for Bicep deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files) — Microsoft Learn canonical parameter-files pattern and multi-environment convention.
- [Bicep `using` statement](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-using) — why native `.bicepparam` adoption is deferred until `infra/main.bicep` lands.
- [ADR 0012](../../docs/adr/0012-environment-parameters-file.md) — the accepted decision governing this folder.
