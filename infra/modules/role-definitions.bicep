// Custom RBAC role definitions for the lab.
//
// PR D1a / Issue #256. Declares the Key Vault firewall-toggler custom role
// (default name `Purview-Lab-KV-Firewall-Toggler`, overridable per
// environment via `kvFirewallTogglerRoleName` per ADR 0057) — the
// minimum-privilege custom role used by the kv-temp-unlock workflow's
// purpose-specific identity (`gh-oidc-purview-kv-unlock`, provisioned by
// PR D1b and consumed by PR D2 / Issue #255). The role grants exactly
// `Microsoft.KeyVault/vaults/read` + `Microsoft.KeyVault/vaults/write`,
// scoped to the lab automation Key Vault: `read` is what the workflow's
// `az keyvault show` state guards ("Pre-unlock state guard", "Assert
// final vault state is locked") require, and `write` is what
// `az keyvault update --public-network-access` requires. A write-only
// grant fails the workflow at the pre-unlock guard with
// AuthorizationFailed on `vaults/read` after a successful azure/login —
// caught on the first live tenant run; keep this action list in lockstep
// with the role documented in docs/runbooks/kv-temp-unlock.md.
//
// Why a custom role: built-in roles that grant `vaults/write` (Owner,
// Contributor, Key Vault Contributor) also grant vault deletion or
// data-plane access. The kv-temp-unlock workflow only needs to read the
// vault's management-plane properties and flip the firewall flag; it must
// not be able to read secrets, rotate keys, delete the vault, or change
// other vault properties beyond what `vaults/read` + `vaults/write`
// already imply on the vault resource (both are management-plane actions,
// not dataActions -- neither exposes secret, key, or certificate
// material).
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

// The default preserves the role name that existing single-environment
// deployments already carry. Because the role-definition GUID below is
// seeded from this name, overriding it mints a NEW role definition rather
// than renaming the old one — migration procedure in
// docs/adr/0057-multi-environment-and-branch-model.md.
@description('Display name of the least-privilege Key Vault firewall-toggler custom role. Override per environment (for example `Purview-Dev-KV-Firewall-Toggler`); renaming creates a new role definition (see ADR 0057).')
param kvFirewallTogglerRoleName string = 'Purview-Lab-KV-Firewall-Toggler'

// Existing-resource reference for the vault so `vault.id` resolves to the
// full vault resource ID for `assignableScopes`. Reference:
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/existing-resource
resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

// Deterministic role-definition name. The resource type contract requires
// `name` to be a GUID; seeding from the subscription ID + role display
// name makes the role idempotent across re-runs (same GUID -> upsert) but
// unique per subscription — and means a changed `kvFirewallTogglerRoleName`
// yields a different GUID, i.e. a new role definition. Reference:
// https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roledefinitions
var kvFirewallTogglerRoleDefinitionName = guid(subscription().id, kvFirewallTogglerRoleName)

resource kvFirewallTogglerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: kvFirewallTogglerRoleDefinitionName
  properties: {
    roleName: kvFirewallTogglerRoleName
    description: 'PR D1a / Issue #256 — least-privilege custom role granting only Microsoft.KeyVault/vaults/read + Microsoft.KeyVault/vaults/write, assignable to the automation Key Vault. Used by the kv-temp-unlock workflow identity to verify (az keyvault show) and toggle (az keyvault update) publicNetworkAccess.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.KeyVault/vaults/read'
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

@description('Full resource ID of the Key Vault firewall-toggler custom role definition. Consumed by `infra/modules/kv-unlock-rbac.bicep` (PR D1b) once the kv-unlock SP object ID is known.')
output kvFirewallTogglerRoleId string = kvFirewallTogglerRole.id

@description('Role-definition GUID (the `name` segment of the resource ID). Convenience output for scripts that pass `--role` by ID rather than name.')
output kvFirewallTogglerRoleGuid string = kvFirewallTogglerRole.name
