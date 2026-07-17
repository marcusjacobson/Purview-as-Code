// Control-plane deployment for the contoso-lab Purview account.
//
// The classic `Microsoft.Purview/accounts` resource is conditional
// (`deployPurviewAccount`, default true) so operators on the tenant-level
// Unified Catalog experience (ADR 0047 / ADR 0048 — no classic account,
// and a PAYG metering resource must never be targeted) can run the
// canonical `az deployment group create -f infra/main.bicep` to get the
// role-definitions module without creating an unwanted classic account.
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts
// Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment

targetScope = 'resourceGroup'

@description('Name of the Purview account. Must be globally unique within the tenant. When `deployPurviewAccount` is false (unified-only tenants per ADR 0048), the shipped placeholder stays in place and the value is unused.')
@minLength(3)
@maxLength(63)
param purviewAccountName string

@description('Deploy the classic `Microsoft.Purview/accounts` resource. Set false for tenants on the tenant-level Unified Catalog experience (ADR 0047/0048): no classic account exists there, a pay-as-you-go metering resource must never be targeted, and this template must still deploy the role-definitions module via the canonical command. Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment')
param deployPurviewAccount bool = true

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

@description('Name of the lab automation Key Vault from `infra/parameters/lab.yaml` (`resources.keyVault.name`). Consumed by `modules/role-definitions.bicep` so the Key Vault firewall-toggler custom role is assignable only at the vault resource scope. The vault itself is provisioned by `scripts/New-AutomationKeyVault.ps1` (Wave 0 #5a), not from this template; this parameter only resolves an `existing` reference.')
param keyVaultName string

@description('Display name for the Key Vault firewall-toggler custom role declared in `modules/role-definitions.bicep`. The default preserves the name existing single-environment deployments carry; per-environment `.bicepparam` files may override it. The role-definition GUID is seeded from this name, so overriding creates a NEW role definition — migration procedure in docs/adr/0057-multi-environment-and-branch-model.md.')
param kvFirewallTogglerRoleName string = 'Purview-Lab-KV-Firewall-Toggler'

// Conditional per the header note above: unified-only tenants (ADR
// 0047/0048) deploy this template with deployPurviewAccount=false.
// Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment
resource purview 'Microsoft.Purview/accounts@2024-04-01-preview' = if (deployPurviewAccount) {
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
    kvFirewallTogglerRoleName: kvFirewallTogglerRoleName
  }
}

// Outputs are empty-string when the account is not deployed
// (deployPurviewAccount=false) -- the ternary guard is the documented
// pattern for referencing a conditional resource from an output.
// Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/conditional-resource-deployment#reference-deployed-resource
output purviewAccountId string = deployPurviewAccount ? purview.id : ''
output purviewAccountName string = deployPurviewAccount ? purview.name : ''
output purviewAtlasEndpoint string = deployPurviewAccount ? 'https://${purview.name}.purview.azure.com' : ''
// `purview!` (non-null assertion) is required for the runtime property
// access: the ternary already guards evaluation, but the type checker
// cannot see that (BCP318). Reference:
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/operator-null-forgiving
output systemAssignedPrincipalId string = deployPurviewAccount ? purview!.identity.principalId : ''

@description('Full resource ID of the Key Vault firewall-toggler custom role definition. Consumed by PR D1b\'s `scripts/New-KvUnlockRbac.ps1`.')
output kvFirewallTogglerRoleId string = customRoles.outputs.kvFirewallTogglerRoleId
