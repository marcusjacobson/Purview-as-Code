# Purview-as-Code — generic template

> **This is a tenant-neutral template.** Every tenant-specific value is a placeholder using
> Microsoft's documented fictitious identifiers (`contoso`, `contoso.onmicrosoft.com`). It will
> **not** deploy against a real tenant until you tailor it. To tailor a fresh clone, run the
> **Tenant Intake** agent — open Copilot Chat and invoke [`@operator-tenant`](.github/agents/operator-tenant.agent.md),
> or edit [`infra/parameters/lab.yaml`](infra/parameters/lab.yaml) by hand and follow
> [Getting started](docs/getting-started.md). Placeholders to replace: GitHub org/repo, tenant
> domain, resource group, Purview account name, Key Vault, Log Analytics, OIDC app display names,
> CODEOWNERS handles, and the content-explorer wrapper-group object ID.

Declarative, version-controlled configuration of a Microsoft Purview environment for a single tenant. Both the Azure resource (control plane) and the catalog contents (data plane) are expressed as code and deployed by GitHub Actions.

> **Target account (placeholder):** `contoso-lab` Microsoft Purview account (tenant `contoso.onmicrosoft.com`).

## Why two planes?

Microsoft Purview does not expose a single "Purview-as-Code" product. A complete IaC repo must manage two independent planes, each with its own API surface and auth model:

| Plane | What it manages | API | Auth | This repo |
|---|---|---|---|---|
| **Control plane** | The `Microsoft.Purview/accounts` resource, networking, managed identity, SKU | Azure Resource Manager | Azure RBAC (Contributor on RG) | [`infra/`](infra/) — Bicep |
| **Data plane** | Sensitivity labels, DLP, data lifecycle and records management, insider risk, communication compliance, DSPM, plus Data Map collections, glossary, classifications, data sources, and scans | Microsoft Purview data-plane APIs (REST and Security & Compliance PowerShell) | App-only automation identity (certificate in Key Vault, OIDC from GitHub Actions) with least-privilege Microsoft Purview roles | [`data-plane/`](data-plane/) + [`scripts/`](scripts/) — YAML rendered by PowerShell |

References:

- [Microsoft.Purview/accounts resource (Bicep/ARM/Terraform)](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts)
- [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane)
- [Purview Data Plane REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/)
- [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions)
- [Azure Verified Module — Purview Account](https://aka.ms/avm)

## Repository layout

```text
.
├── .github/
│   ├── workflows/  # CI (validate) and CD (deploy-infra, deploy-data-plane)
│   ├── instructions/  # Path-scoped Copilot rules (Bicep, PowerShell, YAML, ...)
│   ├── prompts/  # Reusable /-invoked task templates
│   └── agents/  # Workspace-scoped Squad agents (personas)
├── infra/  # Bicep: Purview account + dependencies (control plane)
│   ├── main.bicep
│   ├── main.bicepparam
│   ├── modules/
│   └── parameters/
├── data-plane/  # Desired-state governance content — one folder per Purview solution
│   ├── information-protection/  # Sensitivity labels + label / auto-label policies
│   ├── classifications/  # Sensitive information type (SIT) catalog
│   ├── audit/
│   ├── dlp/
│   ├── data-lifecycle/
│   ├── records/
│   ├── irm/  # Insider Risk Management
│   ├── communication-compliance/
│   ├── dspm/
│   ├── dspm-ai/
│   ├── adaptive-scopes/
│   ├── collections/  # Data Map collection hierarchy
│   ├── glossary/
│   ├── data-sources/
│   ├── scans/
│   ├── unified-catalog/
│   ├── purview-role-groups/
│   ├── entra-directory-roles/
│   └── administrative-units/
├── scripts/  # PowerShell 7+ reconcilers, smoke tests, provisioning helpers
│   ├── Connect-Purview.ps1
│   ├── Deploy-*.ps1  # Idempotent reconciler per data-plane solution
│   ├── Invoke-*SmokeTest.ps1  # End-to-end lab smoke tests
│   ├── New-*.ps1  # One-time identity / Key Vault / certificate provisioning
│   └── modules/
├── docs/
│   ├── getting-started.md
│   ├── architecture.md
│   ├── project-plan.md  # v2 roadmap + progress checklist
│   ├── adr/  # Architecture decision records
│   ├── governance/
│   ├── runbooks/
│   ├── solutions/
│   └── archive/  # Archived v1 plan
├── tests/  # Pester 5.x unit tests for scripts/ (no live tenant)
├── AGENTS.md
└── README.md
```

## Quick start

1. **Prerequisites** — see [`docs/getting-started.md`](docs/getting-started.md).
2. **Create the deployment service principal** and grant it the required Purview data plane roles (one-time) — see [Authenticate for APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).
3. **Configure GitHub secrets/variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `PURVIEW_ACCOUNT_NAME`.
4. **Provision control plane**: push to `main`, the `deploy-infra` workflow runs `az deployment group create` against [`infra/main.bicep`](infra/main.bicep).
5. **Deploy data plane**: `deploy-data-plane` workflow renders YAML under [`data-plane/`](data-plane/) into REST API calls.

## Design principles

- **Idempotent** — every apply script GETs current state, diffs, then PUT/PATCHes.
- **Declarative YAML** — human-reviewable; pull request = change review.
- **Least privilege** — OIDC federated credentials from GitHub → Entra; no long-lived secrets.
- **Separation of concerns** — control-plane PRs never change catalog content and vice versa.

## Status

**Roadmap.** This template ships with an empty feature roadmap. See [`docs/project-plan.md`](docs/project-plan.md) to plan and track which Microsoft Purview features you adopt into as-code governance, and [`docs/getting-started.md`](docs/getting-started.md) to set up the tenant connection.

Scheduled watch loops (drift, surface, and the planned code- and feature-currency loops) file their findings as review issues into a discoverable queue — see [`.github/copilot-automations/README.md`](.github/copilot-automations/README.md).
