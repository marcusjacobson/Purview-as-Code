---
description: "Naming convention for Azure resources and Purview catalog objects in this repo."
applyTo: "infra/**/*.bicep,infra/**/*.bicepparam,data-plane/**/*.yaml,data-plane/**/*.yml,scripts/**/*.ps1,docs/**/*.md"
---

# Naming convention

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). See also [`bicep.instructions.md`](bicep.instructions.md) for Bicep-specific naming, [`data-plane-yaml.instructions.md`](data-plane-yaml.instructions.md) for catalog object rules.

Every Azure resource in `infra/**` and every Purview catalog object in `data-plane/**` follows a single scheme. Copilot must apply this pattern by default and reject diffs that break it.

## Azure resource names

Pattern: `<workload>-<env>-<kind>[-<instance>]`

- `<workload>` — the product / team prefix this repo targets: `contoso`.
- `<env>` — environment token. For this repo: `lab`. Any other value must be introduced per the "Environment and identifier boundaries" section of [`copilot-instructions.md`](../copilot-instructions.md).
- `<kind>` — the CAF resource abbreviation ([Abbreviation recommendations for Azure resources](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations)).
- `<instance>` — optional two-digit suffix (`01`, `02`) only when more than one of the same kind exists in the same scope.

Required properties:

- Lowercase only. No mixed case, no camelCase, no PascalCase.
- Hyphen (`-`) as separator. No underscores, no dots (except where required by the resource type, e.g. storage account globally unique rules).
- ASCII letters and digits only; no Unicode.
- Total length within the per-resource limits in [Resource name rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules). When a resource type disallows hyphens (storage accounts, container registries), drop them but keep the order, e.g. `contosolabst01`.

Canonical examples for this repo:

| Resource | Name |
|---|---|
| Resource group | `rg-purview-lab` |
| Purview account | `purview-contoso-lab` |
| Key Vault | `kv-contoso-lab-01` |
| Log Analytics workspace | `log-contoso-lab` |
| Storage account (sample data source) | `contosolabsrc01` (hyphens dropped per rule) |
| Private endpoint | `pep-purview-contoso-lab-account` |
| Private DNS zone | canonical zone names (e.g. `privatelink.purview.azure.com`) — do not rename |
| User-assigned managed identity | `id-contoso-lab-deploy` |

> **Note on the Purview account name.** `purview-contoso-lab` is a placeholder. The
> example uses the order `purview-<workload>-<env>` rather than the standard
> `<workload>-<env>-<kind>` because a Microsoft Purview account name is awkward to
> change: renaming requires deletion and re-provisioning, which loses lineage and
> historical scan results. Choose your account name deliberately at creation time
> and keep it lowercase, and derive private endpoints, role assignments, and
> downstream object names from it.

## Purview catalog object names

- **Collections** (`data-plane/collections/collections.yaml`): `friendlyName` is human-readable Title Case; `name` (the stable identifier Purview assigns) is lowercase with hyphens. Friendly names may include spaces; identifiers must not.
- **Glossary terms** (`data-plane/glossary/glossary.yaml`): `name` is Title Case with spaces, matching Purview's UI convention. `nickName` (if set) is lowercase with hyphens.
- **Classifications** (`data-plane/classifications/classifications.yaml`): `name` uses Purview's dotted convention — `Custom.<Domain>.<Concept>` (Title Case segments), e.g. `Custom.HR.EmployeeId`.
- **Data sources** (`data-plane/data-sources/data-sources.yaml`): `name` follows the Azure resource convention above (hyphenated, lowercase) because it typically mirrors the underlying resource name.
- **Scans** (`data-plane/scans/scans.yaml`): `name` is `scan-<datasource>-<purpose>`, e.g. `scan-contosolabsrc01-full`.

## Rules for the agent

- When drafting a new resource or catalog object, derive the name from this section. Do not invent.
- When a resource type's documented rules conflict with the pattern (e.g., storage account forbids hyphens), follow the resource type rule and cite it in a comment.
- When an existing name in the repo violates this convention, do not rename it in a PR that also changes behavior — open a dedicated rename PR so the diff is reviewable.
- Never embed environment tokens other than `lab` without the explicit approval described in "Environment and identifier boundaries".

Reference: [Define your naming convention](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming), [Resource name rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules).
