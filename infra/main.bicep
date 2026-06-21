// Control-plane deployment for the contoso-lab Purview account.
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts

targetScope = 'resourceGroup'

@description('Name of the Purview account. Must be globally unique within the tenant.')
@minLength(3)
@maxLength(63)
param purviewAccountName string

@description('Azure region for the Purview account.')
param location string = resourceGroup().location

@description('Purview SKU. Free is intended only for short-lived evaluations.')
@allowed([
  'Free'
  'Standard'
])
param skuName string = 'Standard'

@description('SKU capacity (vCores). Standard minimum is 1.')
@minValue(1)
param skuCapacity int = 1

@description('Public network access to the Purview account. Defaults to Disabled per the secure-by-design rule in .github/instructions/security.instructions.md. Reference: https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#deploy-private-endpoints-for-microsoft-purview-accounts')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Managed resource group name. Leave empty to let Azure auto-generate.')
param managedResourceGroupName string = ''

@description('Resource tags.')
param tags object = {
  workload: 'purview-as-code'
  environment: 'lab'
  owner: 'contoso-lab'
}

@description('Name of the lab automation Key Vault from `infra/parameters/lab.yaml` (`resources.keyVault.name`). Consumed by `modules/role-definitions.bicep` so the `Purview-Lab-KV-Firewall-Toggler` custom role is assignable only at the vault resource scope. The vault itself is provisioned by `scripts/New-AutomationKeyVault.ps1` (Wave 0 #5a), not from this template; this parameter only resolves an `existing` reference.')
param keyVaultName string

resource purview 'Microsoft.Purview/accounts@2024-04-01-preview' = {
  name: purviewAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    publicNetworkAccess: publicNetworkAccess
    managedResourceGroupName: empty(managedResourceGroupName) ? null : managedResourceGroupName
    managedEventHubState: 'Enabled'
  }
}

// PR D1a / Issue #256 — custom RBAC role for the kv-temp-unlock workflow.
// Wired here so the role is created on the next `az deployment group create`.
// Requires the deploying identity to hold `Microsoft.Authorization/roleDefinitions/write`
// (Owner or User Access Administrator), so `deploy-infra.yml` (Contributor SP)
// cannot apply this change — the lab owner runs it locally. See module header.
module customRoles 'modules/role-definitions.bicep' = {
  name: 'role-definitions'
  params: {
    keyVaultName: keyVaultName
  }
}

output purviewAccountId string = purview.id
output purviewAccountName string = purview.name
output purviewAtlasEndpoint string = 'https://${purview.name}.purview.azure.com'
output systemAssignedPrincipalId string = purview.identity.principalId

@description('Full resource ID of the `Purview-Lab-KV-Firewall-Toggler` custom role definition. Consumed by PR D1b\'s `scripts/New-KvUnlockRbac.ps1`.')
output kvFirewallTogglerRoleId string = customRoles.outputs.kvFirewallTogglerRoleId
