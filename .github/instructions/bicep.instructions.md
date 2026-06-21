---
description: "Secure-by-design rules for Bicep and ARM templates that define Microsoft.Purview resources and their dependencies."
applyTo: "infra/**/*.bicep,infra/**/*.bicepparam,infra/**/*.json"
---

# Bicep / IaC secure-by-design rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). All rules there still apply, including the **Microsoft Learn is the central source of truth** rule.

## Grounding — Bicep / ARM must be verified against Microsoft Learn

Before adding or modifying any resource, module, parameter, or property:

- Consult the authoritative resource schema at [`learn.microsoft.com/en-us/azure/templates/<namespace>/<type>`](https://learn.microsoft.com/en-us/azure/templates/) for the **exact** resource type, current API version, property names, allowed values, and required/optional flags. Do not rely on AI training recall — property shapes, API versions, and allowed enums change.
- For Microsoft.Purview specifically: [Microsoft.Purview/accounts](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts), [Microsoft.Purview/accounts/privateEndpointConnections](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts/privateendpointconnections).
- For general Bicep authoring: [Best practices for Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices), [Bicep file structure and syntax](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/file), [Parameters in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameters).
- Prefer Azure Verified Modules when one exists: [aka.ms/avm](https://aka.ms/avm). Pin the version.
- Every resource block in `infra/**` must carry an inline `// Reference: https://learn.microsoft.com/...` comment pointing to the schema page (or the AVM module) used to author it.
- If the feature is not documented on Learn, do not silently emit it. Add a `// TODO: not-on-Learn` comment, cite the closest adjacent Learn page, and flag for human review.

## Parameters and secrets

- Never declare a parameter that holds a secret value without the `@secure()` decorator. Source: [Bicep best practices — outputs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices#outputs), [Use parameters in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameters).
- Never set a default value for a `@secure()` parameter.
- Never emit a secret, key, connection string, or token via `output`. Callers must fetch with `existing` + `listKeys()` at call time. Source: [Bicep best practices — outputs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices#outputs).
- Retrieve secrets via `getSecret()` from a referenced Key Vault parameter file — never inline. Source: [Use Key Vault in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/key-vault-parameter).

## Identity

- Every resource that can have a managed identity must declare one. Prefer `SystemAssigned` unless cross-resource reuse is required, then `UserAssigned`.
- Purview account (`Microsoft.Purview/accounts`) in this repo uses `identity.type: 'SystemAssigned'`.

## Network surface

- Default `publicNetworkAccess` to `'Disabled'` for any resource that supports it **except** where the lab explicitly opts into `'Enabled'` via a parameter with a documented reason. Source: [Block public access using Microsoft Purview firewall](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#block-public-access-using-microsoft-purview-firewall).
- When `publicNetworkAccess` is `'Disabled'`, the template must also create (or reference) the matching private endpoint(s) and private DNS zone group. Required Purview private endpoint sub-resources: `account`, `portal`, `ingestion` (as applicable to the scenario). Source: [Use private endpoints for your Microsoft Purview account](https://learn.microsoft.com/en-us/purview/catalog-private-link).
- Never author an NSG rule with `sourceAddressPrefix: '*'` on port `22`, `3389`, `1433`, `5432`, `3306`, or any management port. Restrict to `VirtualNetwork` service tag, a specific subnet, or a bastion source.
- Storage, Key Vault, SQL, Event Hubs attached to Purview must have `publicNetworkAccess: 'Disabled'` and a private endpoint in the non-public scenario.

## RBAC

- Role assignments in Bicep must reference a role definition by GUID with a descriptive variable name, not a hardcoded name — GUIDs are stable across renames.
- Scope role assignments to the narrowest resource possible (resource → resource group → subscription). Do not emit subscription-scope assignments in this repo.
- Use `principalType` explicitly (`ServicePrincipal`, `User`, `Group`, `ManagedIdentity`).

## API versions and defaults

- Use a recent stable API version for each resource; avoid `preview` API versions unless the feature requires it. Source: [Bicep best practices — resource definitions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices#resource-definitions).
- Default SKUs must be safe / low-cost for lab, but callers must be able to parameterize for production.
- `@allowed` lists are OK for discrete enums (e.g., `Enabled` / `Disabled`); avoid them for evolving SKU lists.

## Diagnostics

- Any new Purview, Storage, Key Vault, SQL, Event Hub, or networking resource should have a `Microsoft.Insights/diagnosticSettings` child that forwards `AuditEvent` / `allLogs` to a Log Analytics workspace parameter (may be optional but template should expose the hook). Source: [Monitor Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-azure-monitor).

## Resource locks

- Production-shaped parameter files should document (or emit) a `Microsoft.Authorization/locks` `CanNotDelete` lock on the Purview account. Source: [Prevent accidental deletion of Microsoft Purview accounts](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#prevent-accidental-deletion-of-microsoft-purview-accounts).

## What-if is mandatory

- Any CI pipeline that invokes `az deployment group create` must first run `az deployment group what-if` in the same job and surface the output in the run log.

## API version selection and deprecation

Every `Microsoft.*` resource declared in `infra/**` must pin an explicit API version. The rules below are non-negotiable.

### Choose the newest GA version that supports the feature

- Use GA (no `-preview` / `-beta` suffix) whenever the feature the resource needs is GA.
- Only use a preview version when Learn shows that the required property is preview-only. Add a comment immediately above the resource:

  ```bicep
  // API version justification: <property> is preview-only as of <date>.
  // Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts
  resource purview 'Microsoft.Purview/accounts@2024-04-01-preview' = { ... }
  ```

- Never use `api-version=latest` or an unpinned resource decorator. The ARM evaluator does not resolve `latest` deterministically and [Bicep does not accept it](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/resource-declaration).

### One version per resource type across the repo

- A workspace-wide grep for the resource type (`grep -R "Microsoft.Purview/accounts@" infra/`) must return a single API version string. Cross-module drift is a review-blocker.
- When bumping a version, update every occurrence in the same PR and note the justification in the PR body.

### Deprecation triggers migration

- When a Learn reference page for an API version this repo pins shows a "retired" banner or a "retirement on YYYY-MM-DD" notice, the next PR that touches a file using that version must either:
  1. Migrate to the current GA version (and update every other file per the rule above), or
  2. Open a follow-up issue titled `API version retirement: <resource>@<version>` and link it from the PR body.
- Do not silently keep deploying a retired API version because it still works.

Reference: [Azure REST API versioning](https://learn.microsoft.com/en-us/azure/architecture/best-practices/api-design#versioning-a-restful-web-api), [Azure service retirements](https://learn.microsoft.com/en-us/azure/advisor/advisor-workbook-service-retirement).

## Pre-commit checklist — `infra/**` changes

Run before opening a PR that touches `infra/**`. Paste the output of each command into the PR description. See [`pre-commit.instructions.md`](pre-commit.instructions.md) for the cross-cutting checklist that applies to every PR.

- [ ] `az bicep lint --file infra/main.bicep` exits 0
- [ ] `az bicep build --file infra/main.bicep --outfile infra/main.json` exits 0
- [ ] `az deployment group what-if -g <rg> -f infra/main.bicep -p infra/main.bicepparam` run against the target environment; output pasted into the PR description
- [ ] No resource is added or modified with `publicNetworkAccess: 'Enabled'` unless the PR description documents why, per the "Network surface" section above
