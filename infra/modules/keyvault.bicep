// Lab automation Key Vault module.
//
// Wave 0 #5a per docs/project-plan.md. Key Vault that holds the data-plane
// automation certificate defined by ADR 0011 decision §1 and consumed by the
// Security & Compliance PowerShell app-only auth path (Connect-IPPSSession
// -CertificateThumbprint) per ADR 0011 decision §3.
//
// Scope of this module:
//   * Create the vault with the required settings from ADR 0011 decision §2:
//       - enableRbacAuthorization: true
//       - enableSoftDelete: true + softDeleteRetentionInDays: 90
//       - enablePurgeProtection: true
//       - Diagnostic settings on, `AuditEvent` category streamed to the
//         Log Analytics workspace created by Wave 0 #5.0.
//
// Explicitly out of scope for 5a:
//   * Creating the certificate itself (that's 5c).
//   * Assigning `Key Vault Certificate User` / `Key Vault Certificates Officer`
//     to the data-plane Entra app (that's 5c; the app ID doesn't exist until
//     5b has run).
//   * Private endpoint wiring (tracked as a follow-on; ADR 0011 §2 "Private
//     endpoint recommended as follow-on").
//
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults
// Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
// Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview
// Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/logging
// Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings

targetScope = 'resourceGroup'

@description('Key Vault name. Per .github/instructions/naming.instructions.md the canonical name for this lab is `kv-contoso-lab-01`. 3-24 chars, alphanumeric plus hyphen, must start with a letter, cannot end with hyphen, cannot contain consecutive hyphens. Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/about-keys-secrets-certificates#vault-name-and-object-name')
@minLength(3)
@maxLength(24)
param vaultName string

@description('Azure region for the vault. Defaults to the parent resource group location.')
param location string = resourceGroup().location

@description('Microsoft Entra tenant ID that owns the vault. Defaults to the deploying subscription\'s tenant so local runs and OIDC runs both resolve correctly without a parameter override.')
param tenantId string = subscription().tenantId

@description('SKU. `standard` is appropriate for the single automation certificate; `premium` only exists for HSM-backed keys and is out of scope for ADR 0011 (self-signed in software per Decision §1). Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/overview#key-vault-soft-delete-and-purge-protection-plans-and-pricing')
@allowed([
  'standard'
  'premium'
])
param skuName string = 'standard'

@description('Soft-delete retention in days. ADR 0011 decision §2 pins this at 90. Allowed range 7-90; 90 is the maximum recovery window. Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Public network access for the control plane. Lab default is `Enabled` because the GitHub-hosted runner that calls `az keyvault certificate download` during each data-plane deploy must reach the vault. Flip to `Disabled` when a private endpoint + runner reachable through it are in place (tracked as an ADR 0011 §2 follow-on). Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/private-link-service')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Full resource ID of the Log Analytics workspace that receives `AuditEvent` logs, required by ADR 0011 decision §2 and produced by Wave 0 #5.0 (`infra/modules/law.bicep`). Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings')
param logAnalyticsWorkspaceId string

@description('Resource tags. Inherit the workload-wide tag shape used by infra/main.bicep and 5.0.')
param tags object = {
  workload: 'purview-as-code'
  environment: 'lab'
  owner: 'contoso-lab'
}

// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults
resource vault 'Microsoft.KeyVault/vaults@2026-02-01' = {
  name: vaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: skuName
    }

    // ADR 0011 decision §2: RBAC auth mode only. No access policies.
    // Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
    enableRbacAuthorization: true

    // ADR 0011 decision §2: soft-delete is mandatory and set to the 90-day
    // maximum so a mis-rotation has the full recovery window. Soft-delete is
    // permanently on for every vault since Feb 2025 (parameter kept for
    // clarity; the API rejects `false`).
    // Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays

    // ADR 0011 decision §2: purge-protection is required so a compromised
    // operator cannot hard-delete the vault inside the soft-delete window.
    // Once `true` this property cannot be disabled — that is by design.
    // Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview#purge-protection
    enablePurgeProtection: true

    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }

    // The auto-rotation workflow (ADR 0011 decision §4) generates new certs
    // via Graph `application:addKey`; it does not call the legacy template
    // deployment path, so `enabledForTemplateDeployment` stays false.
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
  }
}

// Diagnostic settings: stream `AuditEvent` to the Wave 0 #5.0 workspace.
// Required by ADR 0011 decision §2 ("Diagnostic settings on, AuditEvent
// category streamed to a Log Analytics workspace") and supports the four-layer
// out-of-band detection stack (ADR 0011 decision §6, layer 4 — KV AuditEvent
// retrospective KQL).
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.insights/diagnosticsettings
// Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/logging
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'kv-auditevent-to-law'
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        // Data-plane Key Vault operations (secret reads, certificate
        // reads, firewall writes via management API). Required for the
        // unlock-window audit query in docs/runbooks/kv-temp-unlock.md.
        // Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/logging
        // Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs-categories#microsoftkeyvaultvaults
        category: 'AuditEvent'
        enabled: true
      }
      {
        // Azure Policy compliance evaluation results scoped to this
        // vault. Lets us detect policy drift inside the unlock window.
        // Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/resource-logs-categories#microsoftkeyvaultvaults
        category: 'AzurePolicyEvaluationDetails'
        enabled: true
      }
    ]
    metrics: [
      {
        // All platform metrics (ServiceApiHit, ServiceApiLatency, etc.)
        // for capacity and anomaly review during an unlock window.
        // Reference: https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/metrics-supported#microsoftkeyvaultvaults
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

@description('Full resource ID of the vault. Consumed by Wave 0 #5c (`scripts/New-AutomationCertificate.ps1`) when it assigns `Key Vault Certificates Officer` at vault scope. Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide#azure-built-in-roles-for-key-vault-data-plane-operations')
output vaultId string = vault.id

@description('Vault name.')
output vaultName string = vault.name

@description('Vault DNS name (the FQDN that `Connect-IPPSSession -CertificateThumbprint` effectively pulls the cert from via `az keyvault certificate download` in the calling workflow). Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/about-keys-secrets-certificates#objects-identifiers-and-versioning')
output vaultUri string = vault.properties.vaultUri
