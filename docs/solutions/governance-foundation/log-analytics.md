# Log Analytics workspace

Operational guide for the lab Log Analytics workspace that backs the Key Vault `AuditEvent` diagnostic sink and any future Purview diagnostic forwarding.

| Artifact | Path |
|---|---|
| Bicep module | [`infra/modules/law.bicep`](../../../infra/modules/law.bicep) |
| Orchestrator script | [`scripts/New-LogAnalyticsWorkspace.ps1`](../../../scripts/New-LogAnalyticsWorkspace.ps1) |
| Parameters | [`infra/parameters/lab.yaml`](../../../infra/parameters/lab.yaml) — keys under `resources.logAnalytics.*` |

## Purpose

Provision the [Log Analytics workspace](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview) that receives Key Vault `AuditEvent` logs per [ADR 0011 §2](../../adr/0011-certificate-lifecycle.md). Downstream consumers (Key Vault diagnostics, optional Purview diagnostics) reference its resource ID.

## Inputs

All values default to the parameters file; each is independently overridable on the command line.

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-ParametersFile` | n/a — defaults to `infra/parameters/lab.yaml` |
| `-ResourceGroupName` | `resourceGroupName:` |
| `-WorkspaceName` | `resources.logAnalytics.name:` |
| `-Location` | `location:` |
| `-RetentionInDays` | `resources.logAnalytics.retentionInDays:` |
| `-SkuName` | `resources.logAnalytics.skuName:` |

The orchestrator is a thin wrapper around [`az deployment group create`](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli) against `law.bicep`. The four-switch reconciler contract (`-PruneMissing` / `-Force` / `-ExportCurrentState`) does **not** apply — this script manages a single Azure resource, not a YAML-driven catalog.

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | Runs [`az deployment group what-if`](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if) against the Bicep module and prints the result. Never calls `az deployment group create`. |
| (default) | Probes the workspace with `az resource show`. If shape matches, reports `NoChange` and exits. Otherwise calls `az deployment group create`. Re-run is a no-op once shape converges. |

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Interactive contributor or control-plane OIDC service principal | `Contributor` (or any role with `Microsoft.OperationalInsights/workspaces/write`) | Target resource group |

Reference: [Azure built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles).

## References

- [Microsoft.OperationalInsights/workspaces](https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces) — resource schema and pinned API version (see the module).
- [Log Analytics workspace overview](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview)
- [`az deployment group what-if`](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)
- [ADR 0011 — Certificate lifecycle (decision §2)](../../adr/0011-certificate-lifecycle.md) — establishes the diagnostic-sink requirement for Key Vault.
- [ADR 0012 — Environment parameters file](../../adr/0012-environment-parameters-file.md)
