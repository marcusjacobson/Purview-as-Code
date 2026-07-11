// Lab automation RBAC orchestrator.
//
// Wave 0 #5d per docs/project-plan.md. Declarative role assignments for the
// two OIDC apps from ADR 0010 — but only for grants whose target resources
// already exist at Bicep deploy time:
//
//   1. Control-plane SP -> `Contributor` at the parent resource group.
//      Required by ADR 0010 §5 (each app gets its own least-privilege set).
//      Without this grant, `azure/login@v2` succeeds but `az account show`
//      fails with `No subscriptions found for ***`, which is the exact
//      Wave 0 #15 smoke failure observed on 2026-04-25.
//
//   2. Data-plane SP -> `Key Vault Crypto User` scoped to the lab Key Vault.
//      Required by ADR 0011 §3-supersession-addendum (2026-04-24): the
//      Connect-IPPSSession path now signs an RFC 7523 JWT assertion against
//      the cert's underlying RSA key via `az keyvault key sign`, which is
//      the `keys/sign` data-plane operation that this role grants.
//
//   3. Data-plane SP -> `Key Vault Contributor` scoped to the lab Key Vault.
//      Required by ADR 0049 (2026-07-11): every data-plane workflow that
//      reads the automation cert must briefly open the vault firewall with
//      `az keyvault update --public-network-access Enabled`, a management-
//      plane `Microsoft.KeyVault/vaults/write` operation. `Key Vault Crypto
//      User` is data-plane-only and does NOT include `vaults/write`, so the
//      toggle fails. `Key Vault Contributor` is the narrowest built-in that
//      includes `Microsoft.KeyVault/vaults/write`; it is management-plane
//      only (empty dataActions -> cannot read secrets/keys/certs) and does
//      not include `Microsoft.Authorization/*/write` (cannot assign RBAC).
//      The vault uses the RBAC permission model, so the access-policy
//      self-grant escalation Learn warns about does not apply.
//
// Explicitly OUT of scope:
//   * `Key Vault Certificate User` and `Key Vault Certificates Officer` for
//     the data-plane SP. Both are already granted by Wave 0 #5c
//     (`scripts/New-AutomationCertificate.ps1`). 5c keeps ownership of
//     cert-scoped grants because the certificate object only exists at the
//     time that script runs; Bicep cannot resolve `{vault}/certificates/{name}`
//     ahead of time.
//   * Any grant for `validate.yml` — that workflow never calls Azure
//     (ADR 0010 decision §1).
//
// References:
//   https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
//   https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
//   https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
//   https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments

targetScope = 'resourceGroup'

@description('Service principal object ID (NOT app/client ID, NOT app object ID) of the control-plane OIDC app `gh-oidc-purview-control-plane` from ADR 0010. Resolved at runtime by `scripts/New-AutomationRbac.ps1` via `az ad app list --display-name` then `az ad sp show --id <appId>`.')
param controlPlaneSpObjectId string

@description('Service principal object ID of the data-plane OIDC app `gh-oidc-purview-data-plane` from ADR 0010. Resolved the same way as `controlPlaneSpObjectId`.')
param dataPlaneSpObjectId string

@description('Name of the lab automation Key Vault from `infra/parameters/lab.yaml` (`resources.keyVault.name`). Resolved as an existing resource so the Crypto User assignment scopes to the vault, not the resource group.')
param keyVaultName string

// Built-in role definition GUIDs. Verified against
// https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
// and pinned here so the source-of-truth is reviewable in the diff. Do NOT
// substitute role *names* — `az role assignment create` accepts names but
// Bicep `roleAssignments` requires the role definition resource ID.
var contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
var keyVaultCryptoUserRoleId = '12338af0-0e69-4776-bea7-57ae8d297424'
// Key Vault Contributor. Management-plane role (empty dataActions) that
// includes `Microsoft.KeyVault/vaults/write` for the firewall toggle.
// Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-contributor
var keyVaultContributorRoleId = 'f25e0fa2-a7c8-4377-a976-54943a77a395'

// Existing-resource reference for the vault. Required because the Crypto User
// assignment is scoped to the vault, not the parent RG. Reference:
// https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/existing-resource
resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  name: keyVaultName
}

// 1. Control-plane SP -> Contributor at this RG.
//    Delegates to the reusable rbac.bicep module because the module's
//    targetScope = 'resourceGroup' matches this assignment's scope exactly.
//    Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles#contributor
module controlPlaneContributor 'rbac.bicep' = {
  name: 'rbac-cp-contributor'
  params: {
    principalId: controlPlaneSpObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
    roleDescription: 'Wave 0 #5d / ADR 0010 §5 — control-plane OIDC app deploys infra via deploy-infra.yml'
  }
}

// 2. Data-plane SP -> Key Vault Crypto User scoped to the vault resource.
//    Declared inline (not via rbac.bicep) because that module is RG-scoped
//    and Bicep rejects calling a `targetScope = 'resourceGroup'` module with
//    `scope: <child resource>` (BCP134). The deterministic-name pattern is
//    copied from rbac.bicep so the assignment is idempotent across re-runs.
//    Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide#azure-built-in-roles-for-key-vault-data-plane-operations
//    Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-crypto-user
//    Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
resource dataPlaneCryptoUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, dataPlaneSpObjectId, keyVaultCryptoUserRoleId)
  scope: vault
  properties: {
    principalId: dataPlaneSpObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCryptoUserRoleId)
    description: 'Wave 0 #5d / ADR 0011 §3-supersession-addendum — keys/sign for Connect-IPPSSession JWT assertion via az keyvault key sign'
  }
}

// 3. Data-plane SP -> Key Vault Contributor scoped to the vault resource.
//    Management-plane grant so the single-login data-plane workflows can
//    toggle the vault firewall (`Microsoft.KeyVault/vaults/write`) before
//    reading the automation cert and re-lock afterward. Declared inline for
//    the same BCP134 reason as the Crypto User grant above, with the same
//    deterministic-name pattern for idempotency.
//    Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-contributor
//    Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-update
//    Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
resource dataPlaneKeyVaultContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, dataPlaneSpObjectId, keyVaultContributorRoleId)
  scope: vault
  properties: {
    principalId: dataPlaneSpObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultContributorRoleId)
    description: 'ADR 0049 — vaults/write for the single-login data-plane workflow firewall toggle (management-plane only; cannot read secrets/keys/certs)'
  }
}

@description('Role-assignment ID for the control-plane SP Contributor grant on the resource group.')
output controlPlaneContributorAssignmentId string = controlPlaneContributor.outputs.roleAssignmentId

@description('Role-assignment ID for the data-plane SP Key Vault Crypto User grant on the vault.')
output dataPlaneCryptoUserAssignmentId string = dataPlaneCryptoUserAssignment.id

@description('Role-assignment ID for the data-plane SP Key Vault Contributor grant on the vault (ADR 0049 — firewall toggle).')
output dataPlaneKeyVaultContributorAssignmentId string = dataPlaneKeyVaultContributorAssignment.id