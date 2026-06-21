# Lab context

> **Maintained by:** Scribe persona
> **Last updated:** 2026-06-18
> **Update workflow:** Scribe updates this file after every session that changes lab context. See [`../charters/scribe-charter.md`](../charters/scribe-charter.md).

---

## Lab profile

- **Lab name:** Personal Lab (contoso-lab)
- **Domain:** [`contoso.onmicrosoft.com`](https://contoso.onmicrosoft.com)
- **Tenant type:** Single tenant — Microsoft 365 + Azure
- **Owner:** contoso (solo)
- **Purpose:** Personal Microsoft Purview learning + Purview-as-Code reference implementation. Not a customer engagement.

---

## Microsoft solution scope

- **Primary solution:** Microsoft Purview (governance + compliance, both M365 portal surface and Azure data-map surface)
- **In-scope workloads:**
  - Information Protection (sensitivity labels, label policies, auto-labeling)
  - Audit (Standard + Premium retention)
  - Data Loss Prevention
  - Data Lifecycle Management + Records Management
  - Insider Risk Management
  - Communication Compliance
  - Microsoft Purview Data Map (Azure data sources)
  - DSPM and DSPM for AI
- **Out of scope:** customer-facing deliverables, executive assessments, demo runbooks for clients

---

## Azure target

- **Subscription:** lab subscription owned by contoso
- **Resource group:** `rg-purview-lab` (canonical name across instructions, prompts, workflows, and `infra/parameters/lab.yaml` — drift with the previously documented `rg-purview-lab` name was reconciled in the #109 follow-up to the Wave 0 phase-0 smoke test; ADRs 0010 and 0012 retain the divergence rationale and are intentionally not edited)
- **Region:** `eastus` (default)
- **Purview account:** existing account in `rg-purview-lab`
- **Key Vault:** `kv-contoso-lab-01` (RBAC, soft-delete, purge protection enabled)
- **Log Analytics workspace:** lab LAW receiving Key Vault `AuditEvent` diagnostic logs

---

## Identity model

- **Control-plane automation app:** `gh-oidc-purview-control-plane` — Contributor at `rg-purview-lab`
- **Data-plane automation app:** `gh-oidc-purview-data-plane` — Key Vault Crypto User at `kv-contoso-lab-01`; certificate-based app-only auth into Security & Compliance PowerShell via `Connect-IPPSSession -AccessToken`
- **Federated credential subjects:** `repo:contoso/Purview-as-Code-Generic:environment:lab` (per [ADR 0010](../../docs/adr/0010-automation-identity-subject-model.md))
- **Human owner:** contoso (GitHub login). All `owner-approved` actions are gated to this login.

---

## Compliance and policy drivers

This is a **personal lab**, not a regulated environment. There are no external compliance drivers. Policy choices in this lab are intended to model production-shaped patterns suitable for customer reference, not to satisfy real regulations.

---

## Tech stack

- **Infrastructure as code:** Bicep (`infra/main.bicep` + modules under `infra/modules/`)
- **Data-plane configuration:** YAML manifests under `data-plane/`
- **Automation:** PowerShell 7+ scripts under `scripts/`, calling Microsoft Graph and Purview REST APIs
- **CI/CD:** GitHub Actions, OIDC federated credentials, no stored client secrets
- **Lab smoke validation:** every reconciler script supports `-WhatIf` simulation and an end-to-end add/verify/revoke cycle against `contoso.onmicrosoft.com`

---

## Current phase

- **Phase:** v2 — per-feature governance review of the live `contoso.onmicrosoft.com` tenant (in progress, started 2026-05-25). v1 shipped the foundation through Waves 0–4b; every v1 row is ticked and archived at [`docs/archive/project-plan-v1.md`](../../docs/archive/project-plan-v1.md).
- **Next phase trigger:** each Microsoft Purview feature in [`docs/project-plan.md`](../../docs/project-plan.md) §5 reviewed, drift closed, hardened as-code, and ticked — one feature at a time, no batching.
- **Cadence:** agent-led default flow per [ADR 0014](../../docs/adr/0014-agents-as-default-entry-point.md). All work — Progress-checklist items and cross-cutting work alike — enters through `@idea-intake` → `/build-item` → `@artifact-resolver` → `@owner-approval`. `@idea-intake` Step 0 enforces the [`docs/project-plan.md`](../../docs/project-plan.md) §6 dependency-matrix and §8 ADR gates inline when the work maps onto a Progress-checklist row. `@squad` is reserved for content-creation interviews and persona-led discussion. All flows finish at the `owner-approved` label.

---

## Open questions

| # | Question | Raised by | Raised date | Status | Reference |
|---|---|---|---|---|---|
| Q5 | Content Explorer export cadence for DSPM | project-plan §8 | 2026-04-25 | Open | [#84](https://github.com/contoso/Purview-as-Code-Generic/issues/84) |
| Q6 | eDiscovery-as-code in or out of scope | project-plan §8 | 2026-04-25 | Open | [#77](https://github.com/contoso/Purview-as-Code-Generic/issues/77) |
| Q7 | Unified Catalog folder placement confirmed | project-plan §8 | 2026-04-25 | Open | [#78](https://github.com/contoso/Purview-as-Code-Generic/issues/78) |
