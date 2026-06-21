// Lab Log Analytics workspace module.
//
// Created as a standalone atomic item (Wave 0 #5.0 per docs/project-plan.md).
// The workspace is a prerequisite for the automation Key Vault's `AuditEvent`
// diagnostic sink required by ADR 0011 decision §2 — see
// docs/adr/0011-certificate-lifecycle.md. The `Microsoft.Insights/diagnosticSettings`
// resource consumed by 5a needs this workspace's resource ID at deployment time,
// so the workspace must exist before the Key Vault does.
//
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces
// Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview

targetScope = 'resourceGroup'

@description('Log Analytics workspace name. Per .github/instructions/naming.instructions.md the canonical name for this lab is `log-contoso-lab`. 4-63 chars, alphanumeric plus hyphen, must start and end alphanumeric. Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces#microsoftoperationalinsightsworkspaces')
@minLength(4)
@maxLength(63)
param workspaceName string

@description('Azure region for the workspace. Defaults to the parent resource group location.')
param location string = resourceGroup().location

@description('Workspace pricing SKU. PerGB2018 is the current pay-as-you-go tier and the default for new workspaces. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs')
@allowed([
  'PerGB2018'
  'CapacityReservation'
  'LACluster'
])
param skuName string = 'PerGB2018'

@description('Data retention in days. Allowed range per pricing plan is 30-730 for PerGB2018; 30 is the free interactive retention band. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/data-retention-configure')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Daily ingestion cap in GB. `-1` means no cap and is the safe default for a lab that ingests only Key Vault AuditEvent and a handful of future diag sinks. Set a positive integer to cap. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/daily-cap')
param dailyQuotaGb int = -1

@description('Public network access for data ingestion. Lab default is `Enabled` because the KV diagnostic-settings pipeline needs an ingestion endpoint reachable from the GitHub-hosted runner. Flip to `Disabled` when a private endpoint is wired in (tracked as a follow-on; ADR 0011 §2 "Private endpoint recommended as follow-on"). Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/private-link-security')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccessForIngestion string = 'Enabled'

@description('Public network access for query. Same rationale as ingestion. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/private-link-security')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccessForQuery string = 'Enabled'

@description('Resource tags. Inherit the workload-wide tag shape used by infra/main.bicep so cost rollups stay consistent.')
param tags object = {
  workload: 'purview-as-code'
  environment: 'lab'
  owner: 'contoso-lab'
}

// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: skuName
    }
    retentionInDays: retentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
    publicNetworkAccessForIngestion: publicNetworkAccessForIngestion
    publicNetworkAccessForQuery: publicNetworkAccessForQuery
    features: {
      // Use resource-scope RBAC so the `Log Analytics Reader` role on a specific
      // resource grants query rights only to that resource's logs. Avoids granting
      // workspace-wide read to identities that only need KV diag access.
      // Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/manage-access#access-control-mode
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

@description('Full resource ID of the workspace. Downstream items (notably 5a `scripts/New-AutomationKeyVault.ps1`) consume this value as the `workspaceId` on a `Microsoft.Insights/diagnosticSettings` resource. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings')
output workspaceId string = workspace.id

@description('Workspace name.')
output workspaceName string = workspace.name

@description('Workspace customer ID (a GUID that identifies the workspace in the Log Analytics query URL and in agent enrollments). Distinct from the ARM resource ID. Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview#workspace-id')
output customerId string = workspace.properties.customerId
