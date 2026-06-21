// Parameters for the contoso-lab Purview account.
using './main.bicep'

param purviewAccountName = 'purview-contoso-lab'
param location = 'eastus'
param skuName = 'Standard'
param skuCapacity = 1
// Reason for publicNetworkAccess = 'Enabled' in lab: no private endpoint yet.
// Flip to 'Disabled' when infra/modules/private-endpoint.bicep is wired in.
// Reference: https://learn.microsoft.com/en-us/purview/catalog-private-link
param publicNetworkAccess = 'Enabled'
param tags = {
  workload: 'purview-as-code'
  environment: 'lab'
  owner: 'contoso-lab'
  tenant: 'contoso.onmicrosoft.com'
}
// PR D1a / Issue #256 — name of the lab automation Key Vault. Must match
// `resources.keyVault.name` in `infra/parameters/lab.yaml` and the value
// `scripts/New-AutomationKeyVault.ps1` provisions. Consumed by
// `modules/role-definitions.bicep` as an `existing` reference so the
// `Purview-Lab-KV-Firewall-Toggler` custom role's `assignableScopes` is
// the vault resource ID, not the parent RG.
param keyVaultName = 'kv-contoso-lab-01'
