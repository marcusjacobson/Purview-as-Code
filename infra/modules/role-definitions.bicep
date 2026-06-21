// Custom RBAC role definitions for the lab.
//
// PR D1a / Issue #256. Declares `Purview-Lab-KV-Firewall-Toggler` — the
// minimum-privilege custom role used by the kv-temp-unlock workflow's
// purpose-specific identity (`gh-oidc-purview-kv-unlock`, provisioned by
// PR D1b and consumed by PR D2 / Issue #255). The role grants exactly
// `Microsoft.KeyVault/vaults/write`, scoped to the lab automation Key
// Vault, which is the operation `az keyvault update --public-network-access`
// requires.
//
// Why a custom role: built-in roles that grant `vaults/write` (Owner,
// Contributor, Key Vault Contributor) also grant vault deletion or
// data-plane access. The kv-temp-unlock workflow only needs to flip the
// firewall flag and must not be able to read secrets, rotate keys, delete
// the vault, or change other vault properties beyond what `vaults/write`
// already implies on the vault resource.
//
// Permissions to apply: `Microsoft.Authorization/roleDefinitions/write`
// is part of `Owner` and `User Access Administrator`, NOT `Contributor`.
// The control-plane OIDC app from ADR 0010 has `Contributor` on the RG,
// so this module cannot be applied by `deploy-infra.yml`. The lab owner
// must run `az deployment group create` locally with their own
// subscription-Owner credentials. Reference:
// https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#user-access-administrator
//
// NOT wired to a role assignment from `main.bicep`. The assignment lives
// in `kv-unlock-rbac.bicep` and is deployed only when PR D1b's
// `scripts/New-KvUnlockRbac.ps1` runs with the kv-unlock SP object ID.
//
// References:
//   https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles
//   https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roledefinitions
//   https://learn.microsoft.com/en-us/azure/role-based-access-control/role-definitions

targetScope = 'resourceGroup'

@description('Name of the lab automation Key Vault from `infra/parameters/lab.yaml` (`resources.keyVault.name`). Resolved as an existing resource so the custom role is assignable only at the vault resource scope.')
param keyVaultName string

// Existing-resource reference for the vault so `vault.id` resolves to the
// full vault resource ID for `assignableScopes`. Reference:
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/existing-resource
resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

// Deterministic role-definition name. The resource type contract requires
// `name` to be a GUID; seeding from the subscription ID + role display
// name makes the role idempotent across re-runs (same GUID -> upsert) but
// unique per subscription. Reference:
// https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roledefinitions
var kvFirewallTogglerRoleName = guid(subscription().id, 'Purview-Lab-KV-Firewall-Toggler')

resource kvFirewallTogglerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: kvFirewallTogglerRoleName
  properties: {
    roleName: 'Purview-Lab-KV-Firewall-Toggler'
    description: 'PR D1a / Issue #256 — least-privilege custom role granting only Microsoft.KeyVault/vaults/write, assignable to the lab automation Key Vault. Used by the kv-temp-unlock workflow identity to toggle publicNetworkAccess on/off.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.KeyVault/vaults/write'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      vault.id
    ]
  }
}

@description('Full resource ID of the `Purview-Lab-KV-Firewall-Toggler` custom role definition. Consumed by `infra/modules/kv-unlock-rbac.bicep` (PR D1b) once the kv-unlock SP object ID is known.')
output kvFirewallTogglerRoleId string = kvFirewallTogglerRole.id

@description('Role-definition GUID (the `name` segment of the resource ID). Convenience output for scripts that pass `--role` by ID rather than name.')
output kvFirewallTogglerRoleGuid string = kvFirewallTogglerRole.name
