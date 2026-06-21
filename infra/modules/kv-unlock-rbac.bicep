// kv-temp-unlock workflow role assignment.
//
// PR D1a / Issue #256 — Bicep only, not wired from `main.bicep`. Assigns
// the `Purview-Lab-KV-Firewall-Toggler` custom role (declared in
// `role-definitions.bicep`) to the OIDC service principal that backs the
// kv-temp-unlock workflow (`gh-oidc-purview-kv-unlock`, provisioned by
// PR D1b and consumed by PR D2 / Issue #255).
//
// PR D1b's `scripts/New-KvUnlockRbac.ps1` will deploy this module
// directly once it has resolved the SP object ID. It is not referenced
// from `main.bicep` because the SP does not exist at the time the
// control-plane Bicep is applied.
//
// Permissions to apply: `Microsoft.Authorization/roleAssignments/write`
// is in `Owner` and `User Access Administrator`, NOT `Contributor`. PR
// D1b's helper script will surface this requirement so the lab owner
// runs it with the right identity.
//
// References:
//   https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
//   https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
//   https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide

targetScope = 'resourceGroup'

@description('Service principal object ID (NOT app/client ID, NOT app object ID) of the kv-temp-unlock OIDC app `gh-oidc-purview-kv-unlock`. Resolved at runtime by PR D1b\'s `scripts/New-KvUnlockRbac.ps1` via `az ad app list --display-name` then `az ad sp show --id <appId>`.')
param kvUnlockSpObjectId string

@description('Name of the lab automation Key Vault from `infra/parameters/lab.yaml` (`resources.keyVault.name`). Resolved as an existing resource so the role assignment scopes to the vault resource, not the parent RG.')
param keyVaultName string

@description('Full resource ID of the `Purview-Lab-KV-Firewall-Toggler` custom role definition emitted by `infra/modules/role-definitions.bicep` (`kvFirewallTogglerRoleId` output). PR D1b\'s helper script resolves this dynamically via `az role definition list --custom-role-only true --name Purview-Lab-KV-Firewall-Toggler`.')
param kvFirewallTogglerRoleId string

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

// Deterministic name (idempotent across re-runs). Mirrors the pattern in
// `infra/modules/automation-rbac.bicep` for the data-plane Crypto User
// assignment. Reference:
// https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
resource kvUnlockRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, kvUnlockSpObjectId, kvFirewallTogglerRoleId)
  scope: vault
  properties: {
    principalId: kvUnlockSpObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: kvFirewallTogglerRoleId
    description: 'PR D1a/D1b/D2 — kv-temp-unlock workflow OIDC SP gets least-privilege firewall-toggle access on the lab automation Key Vault.'
  }
}

@description('Role-assignment resource ID for the kv-unlock SP -> Purview-Lab-KV-Firewall-Toggler grant on the vault.')
output kvUnlockRoleAssignmentId string = kvUnlockRoleAssignment.id
