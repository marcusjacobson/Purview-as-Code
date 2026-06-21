# 0001 — Microsoft 365 licensing: require E5 and verify at deploy time

- **Status:** Accepted
- **Date:** 2026-04-18
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q1, unblocks Wave 1 and Wave 2
- **Deciders:** @contoso

## Context

The project plan assumes **Microsoft 365 E5 or E5 Compliance** across the `contoso.onmicrosoft.com` tenant. Almost every downstream solution depends on a specific service plan that ships in one of those SKUs:

- Sensitivity labels and auto-labeling (Wave 1) depend on `MIP_S_Exchange` and `MIP_S_CLP1` / `MIP_S_CLP2`.
- DLP (Wave 2b) depends on `PREMIUM_DLP` / `DLP_ANALYTICS`.
- Insider Risk Management (Wave 2d) depends on `INSIDER_RISK_MANAGEMENT`.
- Communication Compliance (Wave 2e) depends on `COMMUNICATIONS_COMPLIANCE`.
- Records Management (Wave 2c) depends on `RECORDS_MANAGEMENT`.
- Audit (Standard) is included with any Microsoft 365 SKU; Audit (Premium) retention (Wave 2a) depends on `M365_ADVANCED_AUDITING`.

If a license gets removed or a service plan is disabled mid-lifecycle, a `Deploy-*.ps1` run will fail partway through with an opaque cmdlet error (for example, `Connect-IPPSSession` will succeed but `New-AutoSensitivityLabelPolicy` will return a 403 that does not mention licensing). That is a poor operator experience and a poor audit trail.

The reference repo (`Azure-Deployment-Pipelines/Purview/*`) documents E5 as a prerequisite in prose READMEs but does not verify it programmatically. We can do better.

## Decision

1. **The `contoso.onmicrosoft.com` tenant runs Microsoft 365 E5.** This is the only supported licensing posture for this repo. Any downgrade is a breaking change and requires a new ADR superseding this one.
2. **Every data-plane deploy script calls a shared preflight**, [`scripts/Test-M365Licensing.ps1`](../../scripts/Test-M365Licensing.ps1), before it performs any state change. The preflight calls Microsoft Graph `GET /subscribedSkus`, checks that the caller-supplied list of required service plans is present and in `servicePlanProvisioningStatus = Success`, and fails fast with a descriptive error if any are missing.
3. **The preflight is Graph-based, not PowerShell-module-version-based.** `Get-MgSubscribedSku` from `Microsoft.Graph.Identity.DirectoryManagement` is the authoritative source. We do not infer licensing from cmdlet availability or from `(Get-Module).Version`.
4. **The preflight is read-only and non-destructive.** It never mutates tenant state. It is safe to run in CI, in `-WhatIf`, and repeatedly.
5. **Each `Deploy-*.ps1` declares its own required service plans** as a constant at the top of the file, with a comment citing the Learn page for that plan. Callers do not pass service plans from outside the script — that keeps the contract auditable.

## Consequences

**Easier.**

- Operators get a single, human-readable failure message when a license is missing, instead of a cryptic REST 403.
- Adding a new solution script is a standard pattern: declare the required plans, call the preflight, proceed.
- Compliance audit: `Test-M365Licensing.ps1` output is pasted into the PR description as the "preflight passed" evidence per the cadence in [`docs/archive/project-plan-v1.md`](../archive/project-plan-v1.md#delivery-cadence--one-item-at-a-time) (historical) and [`docs/project-plan.md`](../project-plan.md#delivery-cadence--one-feature-at-a-time) (current).

**Harder.**

- The preflight adds a Microsoft Graph dependency (`Microsoft.Graph.Identity.DirectoryManagement`) and a `Directory.Read.All` Graph permission on the automation identity. This is a least-privilege read — no write scope added — and is consistent with principle #4 of [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md).

**Unblocks.**

- §8 Q1 in [`docs/project-plan.md`](../project-plan.md).
- Wave 1 item `Deploy-Labels.ps1` can now start.

## Alternatives considered

- **Prose-only prerequisite in the README (status quo, what the reference repo does).** Rejected: no programmatic enforcement, poor operator experience on drift.
- **Check the M365 admin portal manually before each deploy.** Rejected: not automatable, not auditable, not idempotent.
- **Infer licensing from cmdlet success/failure.** Rejected: `Connect-IPPSSession` succeeds on any Exchange license; service-plan-specific failures surface too late.
- **Require E5 Compliance add-on instead of full E5.** Rejected here: the lab already has E5. E5 Compliance would work, but the preflight pattern is identical — the only difference is the SKU part number set accepted.

## Citations

- [List subscribedSkus — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list)
- [Product names and service plan identifiers for licensing](https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference)
- [Microsoft 365, Office 365, Enterprise Mobility + Security, and Windows 11 Subscriptions Licensing — Compliance](https://learn.microsoft.com/en-us/office365/servicedescriptions/microsoft-365-service-descriptions/microsoft-365-tenantlevel-services-licensing-guidance/microsoft-365-security-compliance-licensing-guidance)
- [Get-MgSubscribedSku (Microsoft.Graph.Identity.DirectoryManagement)](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.identity.directorymanagement/get-mgsubscribedsku)
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — Non-negotiable security principles (rule #4, least privilege)
