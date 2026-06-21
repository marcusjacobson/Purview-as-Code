#Requires -Version 7.4
<#
.SYNOPSIS
    Grant (or revoke) a single Entra security group's membership in a single
    Microsoft Entra ID directory role at directory scope, idempotently, via
    Microsoft Graph.

.DESCRIPTION
    Wave 0 imperative primitive that the future declarative reconciler
    (`scripts/Deploy-EntraDirectoryRoles.ps1`) composes over. Sibling of:

      * Azure RBAC                  -> infra/modules/rbac.bicep
                                       (control-plane subscription / RG /
                                       resource scope).
      * Purview data-map roles      -> scripts/Grant-PurviewDataMapRole.ps1
                                       (Purview catalog collection roles).
      * Portal role groups          -> scripts/Grant-PurviewRoleGroup.ps1
                                       (Microsoft 365 / Microsoft Purview
                                       portal role groups via Security &
                                       Compliance PowerShell).
      * THIS SCRIPT                 -> Microsoft Entra directory roles via
                                       Microsoft Graph
                                       /roleManagement/directory/roleAssignments.
                                       Targets the three directory roles
                                       cited as Purview-relevant in
                                       Permissions in the Microsoft Purview
                                       portal: Compliance Administrator,
                                       Compliance Data Administrator, and
                                       Information Protection Administrator.

    The "directory role" here is the Microsoft Entra ID notion documented at
    Permissions in the Microsoft Purview portal -- a different RBAC surface
    than the Microsoft 365 / Microsoft Purview portal role groups owned by
    Grant-PurviewRoleGroup.ps1. Mixing the two breaks least privilege; see
    the section 5 Wave 0 deliverables note in docs/project-plan.md.

    Behaviour:

      1. `az account get-access-token --resource https://graph.microsoft.com`
         to mint a delegated Microsoft Graph token from the local
         contributor's `az login` session. The reconciler PR will
         additionally support certificate-based app-only auth; this
         imperative primitive runs delegated only.
      2. Resolve the role definition. If `-RoleTemplateId` is supplied,
         GET `/v1.0/roleManagement/directory/roleDefinitions/{templateId}`
         directly -- per Microsoft Graph the `id` of a built-in directory
         roleDefinition is immutable and equals its `templateId`, which
         makes templateId-based resolution stable across tenants and
         immune to legacy displayName drift (e.g. `Information Protection
         Administrator` is exposed under the legacy displayName `Azure
         Information Protection Administrator` in some tenants). If
         `-RoleName` is supplied, fall back to
         `?$filter=displayName eq '...'`.
      3. Validate the requested principal is a **role-assignable Entra
         security group** via `GET /v1.0/groups/{id}`. The script rejects
         user OIDs and rejects groups whose `isAssignableToRole` is not
         true. Per Microsoft Learn's "Use Microsoft Entra groups to manage
         role assignments", only groups created with
         `isAssignableToRole = true` may hold a directory role; the API
         silently no-ops otherwise.
      4. Probe existing assignments via
         `GET /v1.0/roleManagement/directory/roleAssignments?$filter=principalId eq '...' and roleDefinitionId eq '...'`
         filtered to `directoryScopeId eq '/'` (directory-wide; AU scoping
         is deliberately not exposed by this primitive -- see the
         "Directory scope only" note below).
      5. Emit a single drift-report row: Create / NoChange / Revoke / NoOp
         (subset of the five categories in
         `.github/instructions/powershell.instructions.md` -- Orphan and
         Conflict do not apply to a single-target imperative grant).
      6. `POST` (create) or `DELETE` (revoke) only when the drift category
         requires a write, then re-read to verify.

    Group-only enforcement. Per security instruction rule #4 (least
    privilege -> assign to groups, not users), -PrincipalId is validated as
    the object ID of an Entra **security group** with
    `isAssignableToRole = true`. The unified RBAC API accepts user object
    IDs, but this primitive intentionally narrows the contract to match
    the equivalent narrowing in Grant-PurviewRoleGroup.ps1.

    Directory scope only. `directoryScopeId` is hardwired to `/`
    (directory-wide) today. Administrative-unit-scoped assignments
    (`/administrativeUnits/{id}`) are deferred to the
    `Deploy-EntraDirectoryRoles.ps1` reconciler PR alongside the
    `data-plane/entra-directory-roles/role-assignments.yaml` schema, which
    will model the scope as a YAML field.

    No -ParametersFile. Unlike the New-*/Deploy-* contract in ADR 0012,
    this Grant-* primitive has no environment-varying values to read: the
    tenant comes from the local `az login` session, and the API surface is
    a single Microsoft Graph endpoint that does not vary by environment.
    The reconciler will not need a parameters file either when it uses
    delegated auth, but will gain one when it switches to the Key
    Vault-side JWT signing path used by Grant-PurviewRoleGroup.ps1.

    References (Microsoft Learn):
      Permissions in the Microsoft Purview portal:
        https://learn.microsoft.com/en-us/purview/purview-permissions
      Microsoft Entra built-in roles:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
      Use Microsoft Entra groups to manage role assignments:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept
      Microsoft Graph rbacApplication resource type (directory provider):
        https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication
      List unifiedRoleDefinitions:
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roledefinitions
      List unifiedRoleAssignments:
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments
      Create unifiedRoleAssignment:
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
      Delete unifiedRoleAssignment:
        https://learn.microsoft.com/en-us/graph/api/unifiedroleassignment-delete
      Get group (isAssignableToRole property):
        https://learn.microsoft.com/en-us/graph/api/group-get
      group resource type (properties):
        https://learn.microsoft.com/en-us/graph/api/resources/group
      az account get-access-token:
        https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER RoleName
    Exact directory-role display name (case-insensitive match against
    `displayName` on `unifiedRoleDefinition`). Examples:
    "Compliance Administrator", "Compliance Data Administrator",
    "Information Protection Administrator". Custom roles are allowed; the
    Graph filter will surface an unknown-name error. Belongs to the
    `ByName` parameter set; mutually exclusive with `-RoleTemplateId`.

    Note: some tenants expose roles under their legacy displayName
    (e.g. `Azure Information Protection Administrator` for templateId
    `7495fdc4-34c4-4d15-a289-98788ce399fd`). Prefer `-RoleTemplateId`
    for those rows.

.PARAMETER RoleTemplateId
    Stable templateId GUID of the directory role (`unifiedRoleDefinition.id`
    for built-in roles). Belongs to the `ByTemplateId` parameter set;
    mutually exclusive with `-RoleName`. Recommended when the tenant
    exposes the role under a legacy displayName.

    Reference:
      https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference

.PARAMETER PrincipalId
    Microsoft Entra **security group** object ID. Validated as a GUID.
    The script verifies via Graph that the OID resolves to a group with
    `isAssignableToRole = true` and rejects any other object kind. User
    OIDs and UPNs are intentionally rejected at this boundary -- assign to
    groups, not users, per
    `.github/instructions/security.instructions.md` rule #4.

.PARAMETER Revoke
    Remove the principal from the directory role instead of adding it.
    Destructive (drops a permission); requires explicit opt-in per the
    drift-report contract.

.EXAMPLE
    ./scripts/Grant-EntraDirectoryRole.ps1 `
        -RoleName 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -WhatIf

    Prints planned behaviour; makes no remote calls. Safe with only an
    `az login` session.

.EXAMPLE
    ./scripts/Grant-EntraDirectoryRole.ps1 `
        -RoleName 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000

    Adds the Entra security group to "Compliance Administrator" (directory
    scope) if it is not already assigned; otherwise emits a NoChange row.

.EXAMPLE
    ./scripts/Grant-EntraDirectoryRole.ps1 `
        -RoleName 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -Revoke

    Removes the Entra security group from "Compliance Administrator" if it
    is currently assigned at directory scope; otherwise emits a NoOp row.

.EXAMPLE
    ./scripts/Grant-EntraDirectoryRole.ps1 `
        -RoleTemplateId '7495fdc4-34c4-4d15-a289-98788ce399fd' `
        -PrincipalId 00000000-0000-0000-0000-000000000000

    Adds the Entra security group to the role with templateId
    `7495fdc4-34c4-4d15-a289-98788ce399fd` (Information Protection
    Administrator). Stable across tenants regardless of displayName
    drift.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session that can mint a delegated Microsoft
        Graph token via `az account get-access-token --resource
        https://graph.microsoft.com`.
      * Microsoft Entra directory role `Privileged Role Administrator`
        (or `Global Administrator`). `Privileged Role Administrator` is
        the documented least-privilege role for assigning directory
        roles.
      Reference:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#privileged-role-administrator

    Output: a single PSCustomObject summary with the previous and current
    assignment state and the action taken (Create / NoChange / Revoke /
    NoOp). No credential material is printed; the access token, tenant
    ID, principal ID, and role-definition ID are not echoed -- they are
    real tenant identifiers under the
    `Environment and identifier boundaries` section of
    `.github/copilot-instructions.md`.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 256)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 \-_/&\.]{0,254}$')]
    [string]$RoleName,

    [Parameter(ParameterSetName = 'ByTemplateId', Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$RoleTemplateId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$PrincipalId,

    [Parameter()]
    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'

# Microsoft Graph v1.0 base. Pinning the version explicitly per the
# powershell.instructions.md "Purview REST API version selection"
# rule (the same GA-over-beta principle applies to Graph). All endpoints
# used below are GA on /v1.0.
# Reference: https://learn.microsoft.com/en-us/graph/use-the-api
$graphBase = 'https://graph.microsoft.com/v1.0'

#region Helpers

function Invoke-EntraGraphRequest {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-RestMethod that injects the bearer
        token, sets Content-Type, and surfaces a redacted error on
        non-2xx. Never logs the Authorization header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('GET', 'POST', 'DELETE')] [string]$Method,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]              [string]$Uri,
        [Parameter()]                                                          [object]$Body,
        [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()]              [string]$AccessToken
    )

    $headers = @{
        Authorization     = "Bearer $AccessToken"
        'Content-Type'    = 'application/json'
        ConsistencyLevel  = 'eventual'
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 6 -Compress)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        $errBody = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errBody = $reader.ReadToEnd()
                }
            }
            catch {
                $errBody = '<unable to read error body>'
            }
        }
        # Strip path/query past the v1.0 segment so the URL surfaces in
        # error output without echoing the principal/role-definition GUIDs
        # in $filter clauses.
        $sanitizedUri = ($Uri -split '\?', 2)[0]
        Write-Error ("Microsoft Graph {0} {1} failed (HTTP {2}): {3}" -f $Method, $sanitizedUri, $status, $errBody)
        throw
    }
}

#endregion

#region Banner

$actionLabel = if ($Revoke.IsPresent) { 'Revoke' } else { 'Create' }
$noopLabel   = if ($Revoke.IsPresent) { 'NoOp' }   else { 'NoChange' }

# Friendly label used in banner / errors / drift summary. Populated
# from whichever parameter set the caller chose.
$roleLabel = if ($PSCmdlet.ParameterSetName -eq 'ByTemplateId') {
    "templateId={0}" -f $RoleTemplateId
} else {
    $RoleName
}

Write-Information ("Role            : {0}" -f $roleLabel) -InformationAction Continue
Write-Information ("Principal kind  : Entra security group (isAssignableToRole=true required)") -InformationAction Continue
Write-Information ("Direction       : {0}" -f $actionLabel)  -InformationAction Continue
Write-Information ("Directory scope : / (directory-wide; AU scope deferred to reconciler)") -InformationAction Continue

#endregion

#region Azure context (read-only preamble)

# `az account show` is a local token-cache read; safe in -WhatIf. The real
# tenantId GUID is consumed by the Graph token request but never echoed
# -- it is a real tenant identifier under copilot-instructions.md
# `Environment and identifier boundaries`.
# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
if (-not $account.tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region ShouldProcess gate

# Pre-declare summary fields so they are populated regardless of branch.
$action             = $noopLabel
$previousIsAssigned = $null
$currentIsAssigned  = $null

$shouldProcessTarget = "Microsoft Entra directory role '{0}' (directory scope)" -f $roleLabel
$shouldProcessAction = if ($Revoke.IsPresent) {
    "Read roleAssignments; remove principal {0} only if currently assigned" -f $PrincipalId
} else {
    "Read roleAssignments; add principal {0} only if not currently assigned" -f $PrincipalId
}

if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {

    # --- Acquire delegated Graph access token. ------------------------------
    # Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
    $tokenJson = az account get-access-token --resource 'https://graph.microsoft.com' -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tokenJson) {
        Write-Error 'az account get-access-token failed for resource https://graph.microsoft.com. Verify your `az login` session has Microsoft Graph access.'
        return
    }
    $tokenObj = ($tokenJson -join "`n") | ConvertFrom-Json
    if (-not $tokenObj.accessToken) {
        Write-Error 'az account get-access-token returned no accessToken field.'
        return
    }
    $accessToken = [string]$tokenObj.accessToken
    Write-Information ("Token acquired  : resource https://graph.microsoft.com (delegated)") -InformationAction Continue

    try {
        # --- Resolve the role definition. ---------------------------------
        # Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roledefinitions
        # Reference: https://learn.microsoft.com/en-us/graph/api/unifiedroledefinition-get
        # For built-in directory roles `unifiedRoleDefinition.id` is
        # immutable and equals `templateId`. The templateId path issues a
        # direct GET on `/roleDefinitions/{id}` which is stable across
        # tenants and immune to legacy displayName drift. The displayName
        # path remains for back-compat with callers that don't yet know
        # the templateId.
        if ($PSCmdlet.ParameterSetName -eq 'ByTemplateId') {
            $tidEscaped = [System.Uri]::EscapeDataString($RoleTemplateId)
            $roleDefUri = ('{0}/roleManagement/directory/roleDefinitions/{1}' -f $graphBase, $tidEscaped)
            try {
                $roleDef = Invoke-EntraGraphRequest -Method GET -Uri $roleDefUri -AccessToken $accessToken
            }
            catch {
                Write-Error ("No directory role definition found with templateId '{0}'. Verify the GUID against the Microsoft Entra built-in roles reference." -f $RoleTemplateId)
                return
            }
            if (-not $roleDef -or -not $roleDef.id) {
                Write-Error ("Graph returned an empty roleDefinition for templateId '{0}'." -f $RoleTemplateId)
                return
            }
            $roleDefinitionId = [string]$roleDef.id
        }
        else {
            # `displayName eq '...'` is documented as supported on
            # `unifiedRoleDefinition`. Encode the value to defend against
            # any control characters in the role name (validation rejects
            # most already, but defense in depth on URI segments is
            # required by powershell.instructions.md "Input validation").
            $roleNameEscaped = [System.Uri]::EscapeDataString($RoleName)
            $roleDefUri = ('{0}/roleManagement/directory/roleDefinitions?$filter=displayName+eq+''{1}''' -f $graphBase, $roleNameEscaped)
            $roleDefResp = Invoke-EntraGraphRequest -Method GET -Uri $roleDefUri -AccessToken $accessToken

            $roleDefs = @($roleDefResp.value)
            if ($roleDefs.Count -eq 0) {
                Write-Error ("No directory role definition found with displayName '{0}'. Some tenants expose this role under a legacy displayName -- prefer -RoleTemplateId. Verify the name against `Get-MgRoleManagementDirectoryRoleDefinition` or the Microsoft Entra portal." -f $RoleName)
                return
            }
            if ($roleDefs.Count -gt 1) {
                Write-Error ("Found {0} directory role definitions with displayName '{1}'. Reconcile manually before re-running this primitive." -f $roleDefs.Count, $RoleName)
                return
            }
            $roleDefinitionId = [string]$roleDefs[0].id
        }
        # NOTE: $roleDefinitionId deliberately not printed -- real tenant identifier.

        # --- Validate the principal is a role-assignable security group. --
        # Reference: https://learn.microsoft.com/en-us/graph/api/group-get
        # Reference: https://learn.microsoft.com/en-us/graph/api/resources/group#properties
        $principalIdEscaped = [System.Uri]::EscapeDataString($PrincipalId)
        $groupUri = ('{0}/groups/{1}?$select=id,displayName,securityEnabled,isAssignableToRole' -f $graphBase, $principalIdEscaped)
        try {
            $group = Invoke-EntraGraphRequest -Method GET -Uri $groupUri -AccessToken $accessToken
        }
        catch {
            Write-Error ("Principal {0} did not resolve to a Microsoft Entra group via Graph /groups/{{id}}. Users and other directory objects are rejected by this primitive (see security.instructions.md rule #4)." -f $PrincipalId)
            return
        }
        if (-not $group.securityEnabled) {
            Write-Error ("Group {0} is not security-enabled. Directory roles require a security group." -f $PrincipalId)
            return
        }
        if (-not $group.isAssignableToRole) {
            Write-Error ("Group {0} has isAssignableToRole=false. Directory-role assignments require a group created with isAssignableToRole=true; this property is immutable after creation." -f $PrincipalId)
            return
        }
        # Group displayName is non-sensitive once we have already validated
        # the OID; safe to log.
        Write-Information ("Group resolved  : '{0}' (security-enabled, role-assignable)" -f $group.displayName) -InformationAction Continue

        # --- Probe existing assignment. ------------------------------------
        # Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments
        # Filter on the conjunction of principalId + roleDefinitionId +
        # directoryScopeId='/'. The unified RBAC API supports composite
        # `and` filters on these fields.
        $roleDefIdEscaped = [System.Uri]::EscapeDataString($roleDefinitionId)
        $assignFilter = ("principalId+eq+'{0}'+and+roleDefinitionId+eq+'{1}'+and+directoryScopeId+eq+'/'" -f $principalIdEscaped, $roleDefIdEscaped)
        $assignUri = ('{0}/roleManagement/directory/roleAssignments?$filter={1}' -f $graphBase, $assignFilter)
        $assignResp = Invoke-EntraGraphRequest -Method GET -Uri $assignUri -AccessToken $accessToken
        $existingAssignments = @($assignResp.value)

        if ($existingAssignments.Count -gt 1) {
            # Defense-in-depth: a duplicate at the same triple should not exist
            # per Graph uniqueness, but if it does the primitive declines to
            # mutate -- the reconciler will surface this as a Conflict row.
            Write-Error ("Found {0} active assignments matching principal+role+directoryScope='/'. Investigate and reconcile before re-running this primitive." -f $existingAssignments.Count)
            return
        }
        $existingAssignment  = $existingAssignments | Select-Object -First 1
        $previousIsAssigned  = [bool]$existingAssignment
        Write-Information ("Previous assigned: {0}" -f $previousIsAssigned) -InformationAction Continue

        if ($Revoke.IsPresent) {
            if (-not $previousIsAssigned) {
                $action            = $noopLabel
                $currentIsAssigned = $false
            }
            else {
                # Reference: https://learn.microsoft.com/en-us/graph/api/unifiedroleassignment-delete
                $deleteUri = ('{0}/roleManagement/directory/roleAssignments/{1}' -f $graphBase, [System.Uri]::EscapeDataString([string]$existingAssignment.id))
                Invoke-EntraGraphRequest -Method DELETE -Uri $deleteUri -AccessToken $accessToken | Out-Null
                $action = $actionLabel
                # Re-read to confirm.
                $verifyResp = Invoke-EntraGraphRequest -Method GET -Uri $assignUri -AccessToken $accessToken
                $currentIsAssigned = [bool](@($verifyResp.value) | Select-Object -First 1)
                if ($currentIsAssigned) {
                    Write-Error ("DELETE roleAssignment reported success but the principal is still assigned to '{0}'. Investigate before retrying." -f $roleLabel)
                    return
                }
            }
        }
        else {
            if ($previousIsAssigned) {
                $action            = $noopLabel
                $currentIsAssigned = $true
            }
            else {
                # Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
                $createUri  = ('{0}/roleManagement/directory/roleAssignments' -f $graphBase)
                $createBody = @{
                    principalId      = $PrincipalId
                    roleDefinitionId = $roleDefinitionId
                    directoryScopeId = '/'
                }
                Invoke-EntraGraphRequest -Method POST -Uri $createUri -Body $createBody -AccessToken $accessToken | Out-Null
                $action = $actionLabel
                # Re-read to confirm.
                $verifyResp = Invoke-EntraGraphRequest -Method GET -Uri $assignUri -AccessToken $accessToken
                $currentIsAssigned = [bool](@($verifyResp.value) | Select-Object -First 1)
                if (-not $currentIsAssigned) {
                    Write-Error ("POST roleAssignment reported success but the principal is not assigned to '{0}'. Investigate before retrying." -f $roleLabel)
                    return
                }
            }
        }
    }
    finally {
        # Drop the access token from the local scope as soon as the
        # operation completes. PowerShell does not zero the underlying
        # string memory, but unbinding it removes it from the script's
        # variable surface so a subsequent error / transcript cannot
        # inadvertently echo it.
        if (Get-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue) {
            Remove-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue
        }
    }
}
else {
    # -WhatIf path: no remote calls.
    Write-Information '-WhatIf specified. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information '  1. Acquire delegated Microsoft Graph token via `az account get-access-token --resource https://graph.microsoft.com`.' -InformationAction Continue
    if ($PSCmdlet.ParameterSetName -eq 'ByTemplateId') {
        Write-Information ("  2. GET {0}/roleManagement/directory/roleDefinitions/{1} (templateId path) to verify the role-definition id." -f $graphBase, $RoleTemplateId) -InformationAction Continue
    }
    else {
        Write-Information ("  2. GET {0}/roleManagement/directory/roleDefinitions?`$filter=displayName eq '{1}' to resolve the role-definition id." -f $graphBase, $RoleName) -InformationAction Continue
    }
    Write-Information ("  3. GET {0}/groups/{{principalId}}?`$select=id,displayName,securityEnabled,isAssignableToRole and validate the principal is a role-assignable security group." -f $graphBase) -InformationAction Continue
    Write-Information ("  4. GET {0}/roleManagement/directory/roleAssignments?`$filter=principalId eq '{1}' and roleDefinitionId eq <resolved> and directoryScopeId eq '/' to read current state." -f $graphBase, $PrincipalId) -InformationAction Continue
    if ($Revoke.IsPresent) {
        Write-Information '  5. If the principal IS currently assigned, DELETE /roleManagement/directory/roleAssignments/{id}; otherwise emit a NoOp row.' -InformationAction Continue
    } else {
        Write-Information '  5. If the principal is NOT currently assigned, POST /roleManagement/directory/roleAssignments with {principalId, roleDefinitionId, directoryScopeId="/"}; otherwise emit a NoChange row.' -InformationAction Continue
    }
    Write-Information '  6. Re-read the same filter to verify the post-action state.' -InformationAction Continue
}

#endregion

#region Summary

[pscustomobject]@{
    roleName            = if ($PSCmdlet.ParameterSetName -eq 'ByName') { $RoleName } else { $null }
    roleTemplateId      = if ($PSCmdlet.ParameterSetName -eq 'ByTemplateId') { $RoleTemplateId } else { $null }
    direction           = $actionLabel
    directoryScope      = '/'
    previousIsAssigned  = $previousIsAssigned
    currentIsAssigned   = $currentIsAssigned
    action              = $action
} | Format-List

#endregion
