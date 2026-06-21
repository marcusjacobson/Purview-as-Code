// Reusable **Azure RBAC** role-assignment module. Creates a single
// `Microsoft.Authorization/roleAssignments` resource scoped to the resource group the module
// is deployed into. Callers target a narrower scope (a specific resource) by invoking the
// module with `scope: <resource>` at the call site, or by declaring role assignments inline
// when the target is not a resource group.
//
// SCOPE — this module handles ONE of the three RBAC planes used in a Purview deployment:
//
//   1. Azure RBAC (ARM)           — THIS MODULE.
//                                   Grants Azure control-plane / data-plane-where-ARM-enforces-it
//                                   permissions (e.g., `Storage Blob Data Reader` on a scan
//                                   target, `Contributor` on the RG for a deploy identity).
//                                   Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/overview
//
//   2. Purview data-plane roles   — NOT this module. Use `scripts/Grant-PurviewDataMapRole.ps1`
//                                   (Wave 0 item #2). Purview catalog roles (`Collection Admin`,
//                                   `Data Curator`, `Data Source Administrator`, `Data Reader`,
//                                   `Policy Author`) are enforced inside Purview's own data plane
//                                   via the `/policystore/metadataroles` REST API. Bicep / ARM
//                                   cannot assign them.
//                                   Reference: https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions
//
//   3. Entra (directory) roles    — NOT this module. Use `scripts/Grant-M365ComplianceRoles.ps1`
//                                   (Wave 0 item #3). Tenant-scoped roles (`Compliance Admin`,
//                                   `Information Protection Admin`, `Compliance Data Admin`,
//                                   `Privileged Role Admin`) are assigned via Microsoft Graph.
//                                   Reference: https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
//
// Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments

targetScope = 'resourceGroup'

@description('Entra ID object ID (not client ID, not app ID) of the principal receiving the role. Service principals, managed identities, users, and groups are supported.')
param principalId string

@description('Entra principal type. Declared explicitly to bypass the Entra ID propagation wait that ARM otherwise performs on service principal and managed identity assignments. Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-template#new-service-principal')
@allowed([
  'ServicePrincipal'
  'ManagedIdentity'
  'User'
  'Group'
])
param principalType string

@description('Fully qualified role definition resource ID, e.g. `/subscriptions/<sub>/providers/Microsoft.Authorization/roleDefinitions/<roleGuid>`. Build this at the call site with `subscriptionResourceId(\'Microsoft.Authorization/roleDefinitions\', \'<guid>\')`. Built-in role GUIDs: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles')
param roleDefinitionId string

@description('Optional free-text description recorded on the role assignment. Has no effect on the permissions granted; used only for operator traceability (e.g. `Purview MSI -> Storage Blob Data Reader for scan`).')
param roleDescription string = ''

@description('Optional extra seed appended to the deterministic assignment name hash. Leave empty for the standard idempotent case. Set only when the same principal legitimately needs two distinct assignments of the same role at the same scope, which is rare.')
param assignmentNameSeed string = ''

// Deterministic GUID derived from scope + principal + role. A redeploy with the same inputs
// produces the same name, so ARM treats the second apply as a no-op. Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-string#guid
var assignmentName = guid(resourceGroup().id, principalId, roleDefinitionId, assignmentNameSeed)

// Reference: https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/roleassignments
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: assignmentName
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: roleDefinitionId
    description: empty(roleDescription) ? null : roleDescription
  }
}

@description('Full resource ID of the role assignment created by this module.')
output roleAssignmentId string = roleAssignment.id

@description('Deterministic name (GUID) of the role assignment. Callers can use this to locate the assignment via `az role assignment show --ids`.')
output roleAssignmentName string = roleAssignment.name
