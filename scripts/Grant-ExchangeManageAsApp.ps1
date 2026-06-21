#Requires -Version 7.4
<#
.SYNOPSIS
    Idempotently grant a workload identity the Microsoft 365 surface needed for
    app-only Connect-IPPSSession (Security & Compliance PowerShell).

.DESCRIPTION
    Wave 0 prerequisite for any data-plane script that talks to the Microsoft
    Purview compliance APIs (Unified Audit Log, eDiscovery, retention,
    sensitivity labels). Two grants must be in place before
    [Get-PurviewIPPSAccessToken.ps1](Get-PurviewIPPSAccessToken.ps1) can return a
    usable token:

      1. **API permission**: `Office 365 Exchange Online > Exchange.ManageAsApp`
         (application). Adds the app role to the Entra app's
         `requiredResourceAccess` and admin-consents it on the service
         principal. Token's `roles` claim picks this up.
         Reference: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2#step-1-register-the-application-in-microsoft-entra-id

      2. **Entra directory role**: `Compliance Administrator`
         (`17315797-102d-40b4-93e0-432062caca18`) assigned to the service
         principal at directory scope `/`. This is the documented least-
         privilege role for Security & Compliance PowerShell — Exchange
         Administrator is *not* sufficient.
         Reference: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2#supported-roles
         Reference: https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#compliance-administrator

    The script is idempotent and `-WhatIf` aware:

      * Each grant is independently probed; only missing pieces are mutated.
      * `-WhatIf` emits a drift report with no mutations.
      * Re-runs on a fully-configured app produce all `NoChange` rows.

    Caller role requirement: Privileged Role Administrator (or Global
    Administrator) on the Entra tenant — required to admin-consent an
    application permission and to assign a directory role. Reference:
    https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#privileged-role-administrator

    What this script does NOT do:

      * Does not create the Entra app (use
        [New-AutomationEntraApp.ps1](New-AutomationEntraApp.ps1)).
      * Does not assign Information Protection Administrator or Compliance
        Data Administrator (those belong to the broader Wave 0 #3
        `Grant-M365ComplianceRoles.ps1`).
      * Does not grant Microsoft Purview *catalog* roles (use
        [Grant-PurviewDataMapRole.ps1](Grant-PurviewDataMapRole.ps1)).

    References:
      Add app role permission (CLI):
        https://learn.microsoft.com/en-us/cli/azure/ad/app/permission#az-ad-app-permission-add
      Admin-consent appRoleAssignments (Microsoft Graph):
        https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments
      Directory role assignment (Microsoft Graph):
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
      ShouldProcess pattern:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER AppId
    Application (client) ID of the Entra app whose service principal will be
    granted the API permission and directory role.

.PARAMETER Revoke
    Remove the grants instead of adding them. Destructive; required opt-in per
    .github/instructions/powershell.instructions.md.

.EXAMPLE
    ./scripts/Grant-ExchangeManageAsApp.ps1 `
        -AppId 00000000-0000-0000-0000-000000000000 -WhatIf

    Drift report only. Shows what would change without mutating directory state.

.EXAMPLE
    ./scripts/Grant-ExchangeManageAsApp.ps1 `
        -AppId 00000000-0000-0000-0000-000000000000

    Apply both grants idempotently.

.NOTES
    File Name : Grant-ExchangeManageAsApp.ps1
    Wave 0 partial (precondition for the Wave 0 audit-log item; full
    Wave 0 #3 `Grant-M365ComplianceRoles.ps1` covers the broader role-group
    surface and is still pending.)
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AppId,

    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants. All GUIDs below are Microsoft-published and stable.
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2#modify-the-app-manifest-to-assign-api-permissions
# Reference: https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#compliance-administrator
# ---------------------------------------------------------------------------
$script:ExchangeOnlineAppId  = '00000002-0000-0ff1-ce00-000000000000'  # Office 365 Exchange Online (commercial cloud)
$script:ExchangeManageAsApp  = 'dc50a0fb-09a3-484d-be87-e023b12c6440'  # app role: Exchange.ManageAsApp
$script:ComplianceAdminRoleTemplateId = '17315797-102d-40b4-93e0-432062caca18'

# ---------------------------------------------------------------------------
# Microsoft Graph token via Azure CLI (works locally + with OIDC in CI).
# Reference: https://learn.microsoft.com/en-us/graph/auth-v2-service
# ---------------------------------------------------------------------------
function Get-GraphToken {
    $raw = az account get-access-token --resource 'https://graph.microsoft.com' --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire Microsoft Graph token. Run 'az login' or configure OIDC."
    }
    return ($raw | ConvertFrom-Json).accessToken
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory = $true)] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter()] $Body,
        [Parameter()] [hashtable] $ExtraHeaders
    )
    $headers = @{
        Authorization = "Bearer $script:GraphToken"
        'Content-Type' = 'application/json'
    }
    if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }

    $params = @{
        Method  = $Method
        Uri     = "https://graph.microsoft.com/v1.0$Path"
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }
    return Invoke-RestMethod @params
}

# ---------------------------------------------------------------------------
# Entry: resolve script principal SP + Exchange Online SP.
# ---------------------------------------------------------------------------
$script:GraphToken = Get-GraphToken

Write-Verbose "Resolving service principal for app $AppId."
$appSp = Invoke-Graph -Method GET -Path "/servicePrincipals?`$filter=appId eq '$AppId'&`$select=id,displayName"
if (-not $appSp.value -or $appSp.value.Count -ne 1) {
    throw "No service principal found for AppId $AppId. Run New-AutomationEntraApp.ps1 first."
}
$appSpId = $appSp.value[0].id
$appName = $appSp.value[0].displayName
Write-Verbose "App service principal: $appName ($appSpId)."

Write-Verbose "Resolving Office 365 Exchange Online service principal."
$exoSp = Invoke-Graph -Method GET -Path "/servicePrincipals?`$filter=appId eq '$script:ExchangeOnlineAppId'&`$select=id"
if (-not $exoSp.value -or $exoSp.value.Count -ne 1) {
    throw "Office 365 Exchange Online service principal not found in tenant. Provision it with: az ad sp create --id $script:ExchangeOnlineAppId"
}
$exoSpId = $exoSp.value[0].id

# ---------------------------------------------------------------------------
# Drift report rows.
# ---------------------------------------------------------------------------
$report = [System.Collections.Generic.List[object]]::new()

# ---- Grant 1: Exchange.ManageAsApp app role assignment --------------------
# Reference: https://learn.microsoft.com/en-us/graph/api/serviceprincipal-post-approleassignments
$existingRoleAssignments = Invoke-Graph -Method GET `
    -Path "/servicePrincipals/$appSpId/appRoleAssignments?`$select=id,appRoleId,resourceId"
$existingExoRole = $existingRoleAssignments.value | Where-Object {
    $_.appRoleId -eq $script:ExchangeManageAsApp -and $_.resourceId -eq $exoSpId
}

if ($Revoke) {
    if ($existingExoRole) {
        $report.Add([pscustomobject]@{ Grant = 'Exchange.ManageAsApp'; Action = 'Revoke' }) | Out-Null
        if ($PSCmdlet.ShouldProcess("$appName ($appSpId)", "Revoke Exchange.ManageAsApp")) {
            Invoke-Graph -Method DELETE -Path "/servicePrincipals/$appSpId/appRoleAssignments/$($existingExoRole.id)" | Out-Null
        }
    }
    else {
        $report.Add([pscustomobject]@{ Grant = 'Exchange.ManageAsApp'; Action = 'NoChange' }) | Out-Null
    }
}
else {
    if ($existingExoRole) {
        $report.Add([pscustomobject]@{ Grant = 'Exchange.ManageAsApp'; Action = 'NoChange' }) | Out-Null
    }
    else {
        $report.Add([pscustomobject]@{ Grant = 'Exchange.ManageAsApp'; Action = 'Create' }) | Out-Null
        if ($PSCmdlet.ShouldProcess("$appName ($appSpId)", "Grant Exchange.ManageAsApp")) {
            $body = @{
                principalId = $appSpId
                resourceId  = $exoSpId
                appRoleId   = $script:ExchangeManageAsApp
            }
            try {
                Invoke-Graph -Method POST -Path "/servicePrincipals/$appSpId/appRoleAssignments" -Body $body | Out-Null
            }
            catch {
                # 400 / "Permission being assigned was already assigned" race window — accept as idempotent.
                if ($_.Exception.Response.StatusCode.value__ -eq 400 -and $_.ErrorDetails.Message -match 'already assigned') {
                    Write-Verbose "Permission already assigned (idempotent)."
                }
                else { throw }
            }
        }
    }
}

# ---- Grant 2: Compliance Administrator directory role ---------------------
# Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
$existingRoleScope = Invoke-Graph -Method GET `
    -Path "/roleManagement/directory/roleAssignments?`$filter=principalId eq '$appSpId' and roleDefinitionId eq '$script:ComplianceAdminRoleTemplateId'"
$existingCompAdmin = $existingRoleScope.value | Select-Object -First 1

if ($Revoke) {
    if ($existingCompAdmin) {
        $report.Add([pscustomobject]@{ Grant = 'Compliance Administrator'; Action = 'Revoke' }) | Out-Null
        if ($PSCmdlet.ShouldProcess("$appName ($appSpId)", "Revoke Compliance Administrator")) {
            Invoke-Graph -Method DELETE -Path "/roleManagement/directory/roleAssignments/$($existingCompAdmin.id)" | Out-Null
        }
    }
    else {
        $report.Add([pscustomobject]@{ Grant = 'Compliance Administrator'; Action = 'NoChange' }) | Out-Null
    }
}
else {
    if ($existingCompAdmin) {
        $report.Add([pscustomobject]@{ Grant = 'Compliance Administrator'; Action = 'NoChange' }) | Out-Null
    }
    else {
        $report.Add([pscustomobject]@{ Grant = 'Compliance Administrator'; Action = 'Create' }) | Out-Null
        if ($PSCmdlet.ShouldProcess("$appName ($appSpId)", "Assign Compliance Administrator at /")) {
            $body = @{
                principalId      = $appSpId
                roleDefinitionId = $script:ComplianceAdminRoleTemplateId
                directoryScopeId = '/'
            }
            try {
                Invoke-Graph -Method POST -Path "/roleManagement/directory/roleAssignments" -Body $body | Out-Null
            }
            catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 409) {
                    Write-Verbose "Role assignment already exists (idempotent)."
                }
                else { throw }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Output the drift report. Drift contract:
#   .github/instructions/powershell.instructions.md
# ---------------------------------------------------------------------------
$report | Format-Table -AutoSize | Out-Host
$report
