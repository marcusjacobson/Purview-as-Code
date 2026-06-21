# M365 licensing preflight

Operational guide for [`scripts/Test-M365Licensing.ps1`](../../../scripts/Test-M365Licensing.ps1) — the tenant-license preflight called by every `Deploy-*.ps1` that touches an M365 / Purview surface. Ratified by [ADR 0001 — M365 licensing verification](../../adr/0001-m365-licensing-verification.md).

## Purpose

Verifies that the signed-in Microsoft 365 tenant has the licenses and service plans required by the caller, before any state change. Fails fast with an actionable error when a plan is missing or suspended. Read-only; never mutates tenant state.

## Inputs

| Parameter | Required | Description |
|---|---|---|
| `-RequiredServicePlans` | Yes | One or more Microsoft 365 service-plan names (`servicePlanName`, not GUID). Examples: `MIP_S_Exchange`, `PREMIUM_DLP`, `INSIDER_RISK_MANAGEMENT`. See the [licensing service-plan reference](https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference). |
| `-MinimumAssignedUnits` | No | Minimum number of assigned units required on the first SKU containing each plan. Defaults to `1`. |

## Behaviour

1. Validates that `Microsoft.Graph.Identity.DirectoryManagement` is installed.
2. Checks the active `Get-MgContext` carries `Directory.Read.All` (or `Directory.ReadWrite.All`).
3. Calls [`Get-MgSubscribedSku -All`](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list) and confirms each requested `servicePlanName` is `Success` on at least one assigned SKU with `MinimumAssignedUnits` units.
4. Throws on the first failure with the missing plan name in the message.

Read-only. Safe under `-WhatIf` (no-op for read-only verbs), safe in CI, safe to repeat.

## Prerequisites

- PowerShell 7.4+.
- Microsoft Graph PowerShell SDK module `Microsoft.Graph.Identity.DirectoryManagement`.
- A connected Graph session with `Directory.Read.All` (least privilege per [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)):

  ```pwsh
  Connect-MgGraph -Scopes 'Directory.Read.All' -NoWelcome
  ```

## How callers consume it

Every `Deploy-*.ps1` that targets an M365 plane calls this helper before any state-changing API call. Example (from a label-deploy preflight):

```pwsh
./scripts/Test-M365Licensing.ps1 -RequiredServicePlans 'MIP_S_Exchange','MIP_S_CLP2'
```

A missing plan halts the caller; the caller never reaches the apply step.

## Required roles

| Caller | Role | Source |
|---|---|---|
| Interactive user or workload identity reading SKUs | Graph permission `Directory.Read.All` (delegated or application) | [`subscribedSku` resource — permissions](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list?tabs=http#permissions) |

## References

- [Microsoft 365 licensing service plan reference](https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference)
- [`subscribedSku` resource](https://learn.microsoft.com/en-us/graph/api/resources/subscribedsku)
- [List `subscribedSkus`](https://learn.microsoft.com/en-us/graph/api/subscribedsku-list)
- [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [ADR 0001 — M365 licensing verification](../../adr/0001-m365-licensing-verification.md)
