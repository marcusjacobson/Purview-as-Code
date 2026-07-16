<#
.SYNOPSIS
    Reconcile `data-plane/entra-directory-roles/role-assignments.yaml`
    against the live Microsoft Entra directory-role assignments in the
    target tenant via Microsoft Graph unified RBAC.

.DESCRIPTION
    Desired-state reconciler for the three Purview-relevant Microsoft
    Entra ID directory roles cited in
    https://learn.microsoft.com/en-us/purview/purview-permissions:

      * Compliance Administrator
      * Compliance Data Administrator
      * Information Protection Administrator

    Roles outside that allowlist are out of scope for Purview-as-Code and
    are rejected by this reconciler if they appear in the YAML. Other
    directory-role surfaces (groups, S&C role groups, Microsoft Purview
    Data Map roles) live in their own siblings under `data-plane/**`.

    Reconciliation is two-phase (ADR 0052), because this reconciler manages
    a PERMISSIONS surface: Phase 1 computes the complete plan across every
    row in `directoryRoles:` with zero tenant writes; Phase 3 applies that
    same plan. There is no reconnect step in between -- unlike
    `Deploy-PurviewRoleGroups.ps1`, whose own Phase 2 rebinds a degrading
    IPPS session, this script authenticates via a single Graph REST access
    token acquired once (see .NOTES), which does not degrade under read
    volume.

      Phase 1 (read + plan; no tenant writes), for every row:
      1. Resolve the role definition. If the row supplies a `templateId:`
         GUID (recommended), use it directly as the
         `unifiedRoleDefinition.id` -- per Microsoft Graph, the `id` of a
         built-in directory roleDefinition is immutable and equals its
         `templateId`, which makes templateId-based resolution stable
         across tenants and immune to legacy displayName drift (e.g.
         `Information Protection Administrator` is exposed under the
         legacy displayName `Azure Information Protection Administrator`
         in some tenants). If the row omits `templateId:`, fall back to
         the legacy `displayName` filter against
         `/v1.0/roleManagement/directory/roleDefinitions`.
      2. Validate every declared member as a Microsoft Entra group with
         `securityEnabled=true` and `isAssignableToRole=true` per
         `.github/instructions/security.instructions.md` rule #4.
      3. Read the current assignments at the requested `directoryScopeId`
         filtered by `roleDefinitionId` from
         `/v1.0/roleManagement/directory/roleAssignments`.
      4. Compute drift (Create / NoChange / Revoke / NoOp) per (role,
         scope, principal) triple. Emit the informational NoChange / NoOp
         report rows immediately; accumulate the Create / Revoke rows into
         a per-row plan entry (role, scope, resolved role-definition id,
         validated Create object IDs, and the Revoke object IDs together
         with their tenant assignment IDs, which Phase 3's DELETE needs).

      ADR 0052 gate: when `-PruneMissing` is supplied and the accumulated
      plan carries at least one Revoke across any row, the operator is
      asked to confirm once before Phase 3 runs. Declining throws and
      leaves the tenant untouched -- for every row, not only the ones not
      yet reached. See
      `docs/adr/0052-destructive-confirmation-gate-at-script-layer.md`.

      Phase 3 (write), iterating the SAME plan Phase 1 built:
      5. Apply Create rows always; apply Revoke rows only with
         `-PruneMissing`. Both are additionally gated per-write by
         `ShouldProcess`.

    `-ExportCurrentState` reads every in-scope role's current assignments
    at directory scope `/` and rewrites the `directoryRoles:` block of
    the YAML, preserving the header comments via line splicing. AU-scoped
    assignments are not exported until ADR 0002 ships AU support;
    encountering one is a hard error.

    Authentication uses the data-plane Entra app's Key Vault-resident
    certificate per ADR 0010 / ADR 0011: this script delegates to
    `scripts/Get-PurviewIPPSAccessToken.ps1` with
    `-Scope https://graph.microsoft.com/.default` to mint a Graph
    access token. The local-PFX `-CertificateThumbprint` path is
    superseded by ADR 0011 Decision #3 (the cert is non-exportable in Key Vault).

    Supports both `-WhatIf` (no remote calls; planned-behaviour banner)
    and `-Confirm`. ConfirmImpact is `High` (ADR 0052): a `-PruneMissing`
    run whose plan carries at least one Revoke prompts once via
    `Assert-DestructiveOperationConfirmed` unless `-Force` or an explicit
    `-Confirm:$false` is supplied.

    References (Microsoft Learn):
      Permissions in the Microsoft Purview portal:
        https://learn.microsoft.com/en-us/purview/purview-permissions
      Microsoft Entra built-in roles:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
      Use Microsoft Entra groups to manage role assignments:
        https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept
      rbacApplication resource (unified RBAC):
        https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication
      List unifiedRoleDefinitions (id == templateId for built-ins):
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roledefinitions
      Get unifiedRoleDefinition by id:
        https://learn.microsoft.com/en-us/graph/api/unifiedroledefinition-get
      List unifiedRoleAssignments:
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments
      Create unifiedRoleAssignment:
        https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
      Delete unifiedRoleAssignment:
        https://learn.microsoft.com/en-us/graph/api/unifiedroleassignment-delete
      Get group:
        https://learn.microsoft.com/en-us/graph/api/group-get
      ADR 0002 (Administrative Units):  ../docs/adr/0002-administrative-units.md
      ADR 0010 (Automation Identity):    ../docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 (Certificate Lifecycle):  ../docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (Environment Parameters): ../docs/adr/0012-environment-parameters-file.md
      ADR 0052 (Destructive confirmation gate): ../docs/adr/0052-destructive-confirmation-gate-at-script-layer.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to
    `data-plane/entra-directory-roles/role-assignments.yaml` resolved
    relative to the repo root.

.PARAMETER PruneMissing
    Allow revocation of tenant assignments that are not declared in the
    YAML. Without this switch, orphan assignments are reported as `NoOp`
    rows and skipped. Destructive; defaults to `$false`.

.PARAMETER Force
    Two independent meanings, one per parameter set (ADR 0052 section 6 /
    ADR 0053 section 2): with `-ExportCurrentState`, permit overwriting a
    `directoryRoles:` block that already declares one or more entries; on
    the Apply path, suppress the ADR 0052 `-PruneMissing` revoke
    confirmation prompt. The two never overlap. `-Force` does not make
    Apply mode silently overwrite tenant state in any other way -- it
    still only ever creates or revokes assignments explicitly declared or
    implied by the YAML.

.PARAMETER ExportCurrentState
    Read live assignments for the three in-scope directory roles at
    scope `/` and rewrite the `directoryRoles:` block of the YAML.
    Refuses to overwrite a non-empty list without `-Force`. Mutually
    exclusive with `-PruneMissing`.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved
    from `automation.apps.dataPlane.certificateName`.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain. Used only for error/log context; the Graph
    token endpoint is keyed off the tenant ID resolved from
    `az account show`. When omitted, resolved from
    `automation.tenantDomain`.

.EXAMPLE
    ./scripts/Deploy-EntraDirectoryRoles.ps1 -WhatIf

    Print the planned-behaviour banner; make no remote calls.

.EXAMPLE
    ./scripts/Deploy-EntraDirectoryRoles.ps1

    Add Entra-group assignments declared in the YAML that are missing
    from the tenant. Orphan assignments are reported and skipped (no
    `-PruneMissing`).

.EXAMPLE
    ./scripts/Deploy-EntraDirectoryRoles.ps1 -PruneMissing

    Add missing assignments AND revoke tenant assignments not in the
    YAML.

.EXAMPLE
    ./scripts/Deploy-EntraDirectoryRoles.ps1 -ExportCurrentState

    Hydrate `data-plane/entra-directory-roles/role-assignments.yaml`
    from the live tenant. Refuses to clobber a non-empty
    `directoryRoles:` list without `-Force`.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * Microsoft Graph application permission
        `RoleManagement.ReadWrite.Directory` granted with admin consent.
        Reference:
          https://learn.microsoft.com/en-us/graph/permissions-reference#rolemanagementreadwritedirectory
      * Entra directory role `Privileged Role Administrator` assigned to
        the workload service principal (least-privilege role for
        directly assigning directory roles). Reference:
          https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#privileged-role-administrator

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason / RoleName. Suitable for capture to
    `$GITHUB_STEP_SUMMARY` or a file. No credential material is printed;
    real tenant identifiers (appId, tenantId, role-definition IDs, group
    OIDs) are not echoed at INFO level.
#>
#Requires -Version 7.4
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until issue #105, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting (the issue #85 defect). Do not lower it back
# to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\entra-directory-roles\role-assignments.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain
)

$ErrorActionPreference = 'Stop'

#region Constants

# Microsoft Graph v1.0 base. Pinning the version explicitly per the
# powershell.instructions.md "Purview REST API version selection" rule
# (the same GA-over-beta principle applies to Graph). All endpoints used
# below are GA on /v1.0.
# Reference: https://learn.microsoft.com/en-us/graph/use-the-api
$graphBase = 'https://graph.microsoft.com/v1.0'

# Allowlist of directory roles managed by this reconciler -- canonical
# Microsoft-published displayName -> stable templateId GUID. Mirrors
# `data-plane/entra-directory-roles/role-assignments.yaml` header. Any
# other role name (or any templateId not in this map) in the YAML is
# rejected at validation.
#
# templateIds are sourced from the Microsoft Entra built-in roles
# reference. They are tenant-stable and immune to legacy displayName
# drift (e.g. `Information Protection Administrator` is exposed under
# the legacy displayName `Azure Information Protection Administrator`
# in tenants that pre-date the rename).
#
# Reference: https://learn.microsoft.com/en-us/purview/purview-permissions
# Reference: https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference
$inScopeRoles = [ordered]@{
    'Compliance Administrator'             = '17315797-102d-40b4-93e0-432062caca18'
    'Compliance Data Administrator'        = 'e6d1a23a-da11-4be4-9570-befc86d067a7'
    'Information Protection Administrator' = '7495fdc4-34c4-4d15-a289-98788ce399fd'
}
# Reverse lookup so the YAML can declare either `name:` (canonical) or
# `templateId:` (preferred); validation enforces the pair when both
# appear.
$inScopeTemplateIds = @{}
foreach ($kvp in $inScopeRoles.GetEnumerator()) {
    $inScopeTemplateIds[$kvp.Value] = $kvp.Key
}

#endregion

#region Helpers

function Test-IsGuid {
    param([Parameter(Mandatory = $true)][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return [System.Guid]::TryParse($Value, [ref]([guid]::Empty))
}

function Test-IsScopeShape {
    <#
    .SYNOPSIS
        Validate a directoryScopeId against the two shapes this
        reconciler supports: `/` (directory-wide) or
        `/administrativeUnits/{guid}`. Other shapes are rejected per
        ADR 0002.
    #>
    param([Parameter(Mandatory = $true)][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -eq '/') { return $true }
    if ($Value -match '^/administrativeUnits/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$') {
        return $true
    }
    return $false
}

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
        Authorization    = "Bearer $AccessToken"
        'Content-Type'   = 'application/json'
        ConsistencyLevel = 'eventual'
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
        # error output without echoing principal/role-definition GUIDs
        # in $filter clauses.
        $sanitizedUri = ($Uri -split '\?', 2)[0]
        Write-Error ("Microsoft Graph {0} {1} failed (HTTP {2}): {3}" -f $Method, $sanitizedUri, $status, $errBody)
        throw
    }
}

function Resolve-RoleDefinitionId {
    <#
    .SYNOPSIS
        Return the `unifiedRoleDefinition.id` for a directory role.
        Prefers `-TemplateId` (no Graph call required for built-in
        roles since `id == templateId`); falls back to a `displayName`
        filter when only `-RoleName` is supplied.

    .NOTES
        Reference (id == templateId for built-ins):
          https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roledefinitions
        Reference (GET by id):
          https://learn.microsoft.com/en-us/graph/api/unifiedroledefinition-get
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName',       Mandatory = $true)] [string]$RoleName,
        [Parameter(ParameterSetName = 'ByTemplateId', Mandatory = $true)] [string]$TemplateId,
        [Parameter(Mandatory = $true)] [string]$AccessToken
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByTemplateId') {
        # For built-in directory roles the unifiedRoleDefinition.id is
        # immutable and equals templateId. Verify the role exists
        # via GET /roleDefinitions/{id} so a typo in the YAML is caught
        # before we try to write an assignment.
        $escaped = [System.Uri]::EscapeDataString($TemplateId)
        $uri = ('{0}/roleManagement/directory/roleDefinitions/{1}' -f $graphBase, $escaped)
        try {
            $def = Invoke-EntraGraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
        }
        catch {
            throw ("No directory role definition found with templateId '{0}': {1}" -f $TemplateId, $_.Exception.Message)
        }
        if (-not $def -or -not $def.id) {
            throw ("Graph returned an empty roleDefinition for templateId '{0}'." -f $TemplateId)
        }
        return [string]$def.id
    }

    # Legacy displayName lookup. Vulnerable to legacy-name drift -- prefer
    # the templateId path in YAML rows.
    $escaped = [System.Uri]::EscapeDataString($RoleName)
    $uri = ('{0}/roleManagement/directory/roleDefinitions?$filter=displayName+eq+''{1}''' -f $graphBase, $escaped)
    $resp = Invoke-EntraGraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
    $defs = @($resp.value)
    if ($defs.Count -eq 0) {
        throw ("No directory role definition found with displayName '{0}'. Consider declaring the row with 'templateId:' instead -- some tenants expose this role under a legacy displayName." -f $RoleName)
    }
    if ($defs.Count -gt 1) {
        throw ("Found {0} directory role definitions with displayName '{1}'. Reconcile manually." -f $defs.Count, $RoleName)
    }
    return [string]$defs[0].id
}

function Test-IsRoleAssignableGroup {
    <#
    .SYNOPSIS
        GET /groups/{id}; return $true only if the principal exists, is
        security-enabled, and has isAssignableToRole=true. Returns $false
        with a Write-Warning otherwise (rejection surfaces in the report
        as a Conflict-style row).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )
    # Reference: https://learn.microsoft.com/en-us/graph/api/group-get
    $escaped = [System.Uri]::EscapeDataString($PrincipalId)
    $uri = ('{0}/groups/{1}?$select=id,displayName,securityEnabled,isAssignableToRole' -f $graphBase, $escaped)
    try {
        $group = Invoke-EntraGraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
    }
    catch {
        return $false
    }
    if (-not $group.securityEnabled) { return $false }
    if (-not $group.isAssignableToRole) { return $false }
    return $true
}

function Get-AssignmentsForRoleScope {
    <#
    .SYNOPSIS
        GET roleAssignments filtered by roleDefinitionId+directoryScopeId.
        Returns the array of unifiedRoleAssignment objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RoleDefinitionId,
        [Parameter(Mandatory = $true)][string]$DirectoryScopeId,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )
    # Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments
    $escRoleId = [System.Uri]::EscapeDataString($RoleDefinitionId)
    $escScope  = [System.Uri]::EscapeDataString($DirectoryScopeId)
    $filter = ("roleDefinitionId+eq+'{0}'+and+directoryScopeId+eq+'{1}'" -f $escRoleId, $escScope)
    $uri = ('{0}/roleManagement/directory/roleAssignments?$filter={1}' -f $graphBase, $filter)
    $resp = Invoke-EntraGraphRequest -Method GET -Uri $uri -AccessToken $AccessToken
    return @($resp.value)
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the -PruneMissing revoke branch cannot be
# entered unattended from a local terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

# When -ParametersFile is omitted, the PURVIEW_PARAMETERS_FILE environment
# variable (set per-environment by the CI workflows) selects the parameters
# file. See docs/adr/0057-multi-environment-and-branch-model.md.
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'. Reference: docs/adr/0010-automation-identity-subject-model.md." -f $ParametersFile)
    return
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key)
        return
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }

Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue

#endregion

#region Desired-state load and validation

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

$desiredEntries = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('directoryRoles') -and $desiredRoot.directoryRoles) {
    $desiredEntries = @($desiredRoot.directoryRoles)
}

if ($mode -eq 'Apply') {
    foreach ($row in $desiredEntries) {
        if (-not $row.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$row.name)) {
            Write-Error ("Directory-role entry in '{0}' is missing the required 'name' field." -f $Path)
            return
        }
        $rowName = [string]$row.name
        if (-not $inScopeRoles.Contains($rowName)) {
            Write-Error ("Role '{0}' is not in the Purview-as-Code allowlist. Permitted: {1}. Reference: data-plane/entra-directory-roles/role-assignments.yaml header." -f $rowName, (($inScopeRoles.Keys) -join ', '))
            return
        }
        if ($row.ContainsKey('templateId') -and -not [string]::IsNullOrWhiteSpace([string]$row.templateId)) {
            $rowTemplateId = [string]$row.templateId
            if (-not (Test-IsGuid -Value $rowTemplateId)) {
                Write-Error ("Role '{0}' has 'templateId' '{1}' which is not a GUID." -f $rowName, $rowTemplateId)
                return
            }
            $expectedTemplateId = [string]$inScopeRoles[$rowName]
            if ($rowTemplateId -ne $expectedTemplateId) {
                Write-Error ("Role '{0}' declares templateId '{1}' but the canonical templateId for that name is '{2}'. The pair must match the in-scope allowlist." -f $rowName, $rowTemplateId, $expectedTemplateId)
                return
            }
        }
        $rowScope = '/'
        if ($row.ContainsKey('scope') -and -not [string]::IsNullOrWhiteSpace([string]$row.scope)) {
            $rowScope = [string]$row.scope
        }
        if (-not (Test-IsScopeShape -Value $rowScope)) {
            Write-Error ("Role '{0}' has unsupported scope '{1}'. Permitted shapes: '/' or '/administrativeUnits/{{guid}}' (ADR 0002)." -f $rowName, $rowScope)
            return
        }
        $members = @()
        if ($row.ContainsKey('members') -and $row.members) { $members = @($row.members) }
        foreach ($m in $members) {
            if (-not (Test-IsGuid -Value ([string]$m))) {
                Write-Error ("Role '{0}' member '{1}' is not a valid Entra group object ID. Per role-assignments.yaml header, only role-assignable Entra group OIDs are accepted." -f $rowName, $m)
                return
            }
        }
    }
}

#endregion

#region Azure context (read-only preamble)

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region -WhatIf short-circuit (no remote calls)

if ($WhatIfPreference -and $mode -eq 'Apply') {
    Write-Information '-WhatIf specified. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  1. Resolve Entra app via `az ad app list` (Graph read).') -InformationAction Continue
    Write-Information ('  2. Acquire access token via Get-PurviewIPPSAccessToken.ps1 (Key Vault PS256 sign, scope=https://graph.microsoft.com/.default).') -InformationAction Continue
    Write-Information ('  3. For each of the {0} desired-state row(s) in {1}:' -f $desiredEntries.Count, (Split-Path -Leaf $Path)) -InformationAction Continue
    Write-Information ('       - Resolve role definition: GET roleDefinitions/{templateId} when row supplies templateId; otherwise GET roleDefinitions?$filter=displayName eq <name>') -InformationAction Continue
    Write-Information ('       - For each declared member: GET /groups/{id} and validate isAssignableToRole=true') -InformationAction Continue
    Write-Information ('       - GET roleAssignments?$filter=roleDefinitionId eq <id> and directoryScopeId eq <scope>') -InformationAction Continue
    Write-Information ('       - Diff against YAML members; emit Create/NoChange/Revoke/NoOp report rows') -InformationAction Continue
    Write-Information ('  4. POST new assignments (Create); DELETE orphans only with -PruneMissing.') -InformationAction Continue
    Write-Information ('-PruneMissing : {0}' -f $PruneMissing.IsPresent) -InformationAction Continue
    return
}
if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Acquire token; for each in-scope role, list assignments at scope ''/''; rewrite directoryRoles: block of {0}.' -f $Path) -InformationAction Continue
    return
}

#endregion

#region Resolve Entra app + acquire Graph token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app list failed with exit code $LASTEXITCODE."
    return
}
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) {
    Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName)
    return
}
if ($appList.Count -gt 1) {
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name; reconcile manually." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$appId = [string]$appList[0].appId
# NOTE: $appId deliberately not echoed at INFO -- real tenant identifier.

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) {
    Write-Error ("Helper not found: '{0}'." -f $tokenScript)
    return
}
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId `
    -Scope           'https://graph.microsoft.com/.default'
if (-not $tok -or -not $tok.AccessToken) {
    Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
    return
}
$accessToken = [string]$tok.AccessToken
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion

#region Reconcile

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredEntries.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("'{0}' already declares {1} directoryRoles entry/entries. Refusing to overwrite without -Force." -f $Path, $desiredEntries.Count)
            return
        }

        $exportEntries = New-Object 'System.Collections.Generic.List[hashtable]'
        $exportStamp   = [DateTime]::UtcNow.ToString('yyyy-MM-dd')

        foreach ($kvp in $inScopeRoles.GetEnumerator()) {
            $roleName       = [string]$kvp.Key
            $roleTemplateId = [string]$kvp.Value
            try {
                # Resolve via templateId (id == templateId for built-in
                # roles). Stable across tenants and immune to legacy
                # displayName drift.
                $roleDefId = Resolve-RoleDefinitionId -TemplateId $roleTemplateId -AccessToken $accessToken
            }
            catch {
                Write-Warning ("Role '{0}' (templateId {1}) did not resolve during export: {2}. Skipping." -f $roleName, $roleTemplateId, $_.Exception.Message)
                continue
            }
            $assigns = Get-AssignmentsForRoleScope -RoleDefinitionId $roleDefId -DirectoryScopeId '/' -AccessToken $accessToken

            # Filter to principals that are role-assignable Entra groups.
            # Per security.instructions.md rule #4 the reconciler manages
            # only group-based assignments; user/app-based assignments
            # are reported via a comment so reviewers can spot them.
            $groupOids = New-Object 'System.Collections.Generic.List[string]'
            $userOrAppCount = 0
            foreach ($a in $assigns) {
                $principalOid = [string]$a.principalId
                if (-not $principalOid) { continue }
                if (Test-IsRoleAssignableGroup -PrincipalId $principalOid -AccessToken $accessToken) {
                    [void]$groupOids.Add($principalOid)
                }
                else {
                    $userOrAppCount++
                }
            }

            $entry = @{
                name        = $roleName
                templateId  = $roleTemplateId
                description = "Exported from $TenantDomain on $exportStamp."
                scope       = '/'
                members     = @($groupOids | Sort-Object -Unique)
                otherCount  = [int]$userOrAppCount
            }
            $exportEntries.Add($entry)
        }

        # Preserve YAML header comments by line-splicing.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*directoryRoles\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'directoryRoles:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = if ($cutIndex -eq 0) { @() } else { $originalLines[0..($cutIndex - 1)] }

        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        $populated = @($exportEntries | Where-Object { $_.members.Count -gt 0 -or $_.otherCount -gt 0 }).Count
        if ($populated -eq 0) {
            $newBlock.Add('directoryRoles: []')
        }
        else {
            $newBlock.Add('directoryRoles:')
            foreach ($entry in $exportEntries) {
                $newBlock.Add(("  - name: {0}" -f $entry.name))
                if ($entry.templateId) {
                    $newBlock.Add(("    templateId: {0}" -f $entry.templateId))
                }
                $newBlock.Add(("    description: {0}" -f $entry.description))
                $newBlock.Add(("    scope: {0}" -f $entry.scope))
                if ($entry.otherCount -gt 0) {
                    $newBlock.Add(("    # Tenant has {0} non-group principal(s) assigned at this scope (users or service principals); not managed by this reconciler." -f $entry.otherCount))
                }
                if ($entry.members.Count -eq 0) {
                    $newBlock.Add('    members: []')
                }
                else {
                    $newBlock.Add('    members:')
                    foreach ($oid in $entry.members) {
                        $newBlock.Add(("      - {0}" -f $oid))
                    }
                }
            }
        }

        $finalLines = @($headerLines) + @($newBlock)
        $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
        $shouldProcessAction = "Replace 'directoryRoles:' block with {0} entry/entries" -f $exportEntries.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            $finalLines | Set-Content -LiteralPath $Path -Encoding utf8
            Write-Information ("Wrote {0} role entry/entries to '{1}'. Review the diff in a pull request before applying." -f $exportEntries.Count, $Path) -InformationAction Continue
        }

        return

        #endregion
    }

    #region Apply mode: two-phase reconciliation (issue #105)
    # This reconciler manages Microsoft Entra directory-role assignments --
    # a PERMISSIONS surface -- so the ADR 0052 confirmation gate must see
    # the FULL revoke plan, across every row, before any tenant write.
    #
    # The original shape was single-pass and INTERLEAVED: read a row's
    # current assignments, POST its creates, DELETE its revokes, then move
    # to the next row. Under that shape row 2's revoke plan did not exist
    # until row 1's writes had already landed, so no gate site could ever
    # make "No tenant writes were made" TRUE on decline -- the only choices
    # were "lie" or "restructure" (issue #105).
    #
    # Fixed by splitting into two phases, mirroring
    # `Deploy-PurviewRoleGroups.ps1` (Phase 1 -> ADR 0052 gate -> Phase 3):
    #   1. Read phase: for every row, resolve the role definition, validate
    #      members, read current assignments, diff, and accumulate a
    #      per-row plan entry. Zero remote writes.
    #   3. Write phase: iterate the SAME plan the read phase built, applying
    #      Create rows always and Revoke rows only with -PruneMissing.
    #
    # No reconnect step in between (no Phase 2), unlike the RoleGroups
    # reconciler: that script's Phase 2 rebinds an Exchange Online /
    # Security & Compliance PowerShell session that degrades under a
    # high-volume read loop. This script authenticates via a single Graph
    # REST access token acquired once above ($accessToken, via
    # Get-PurviewIPPSAccessToken.ps1), which has no analogous session to
    # degrade -- so a reconnect step here would be inventing a fix for a
    # problem this script does not have.

    if ($desiredEntries.Count -eq 0) {
        Write-Information 'No directory roles declared in YAML. Nothing to reconcile.' -InformationAction Continue
        return @()
    }

    # Cache role-definition ids and group-assignability lookups so the
    # script issues each Graph read at most once per (role, principal).
    $roleDefIdCache  = @{}
    $groupCheckCache = @{}

    # ---- Phase 1: Read + categorize (no remote writes) ----
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $desiredEntries) {
        $rowName  = [string]$row.name
        $rowScope = if ($row.ContainsKey('scope') -and -not [string]::IsNullOrWhiteSpace([string]$row.scope)) {
            [string]$row.scope
        } else { '/' }
        $rowTemplateId = if ($row.ContainsKey('templateId') -and -not [string]::IsNullOrWhiteSpace([string]$row.templateId)) {
            [string]$row.templateId
        } else { $null }
        $desiredMembers = @()
        if ($row.ContainsKey('members') -and $row.members) {
            $desiredMembers = @($row.members | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        }

        # Resolve role-definition id (cached). Cache key includes the
        # template id when supplied so a typo'd name + correct templateId
        # row resolves independently of a name-only row.
        $cacheKey = if ($rowTemplateId) { "tid:$rowTemplateId" } else { "name:$rowName" }
        if (-not $roleDefIdCache.ContainsKey($cacheKey)) {
            try {
                if ($rowTemplateId) {
                    $roleDefIdCache[$cacheKey] = Resolve-RoleDefinitionId -TemplateId $rowTemplateId -AccessToken $accessToken
                }
                else {
                    $roleDefIdCache[$cacheKey] = Resolve-RoleDefinitionId -RoleName $rowName -AccessToken $accessToken
                }
            }
            catch {
                # A Phase 1 failure on ANY row aborts the WHOLE run before
                # any write for ANY row -- not just this one. Phase 3 has
                # not started, so this is still a zero-write abort.
                Write-Error ("Failed to resolve role '{0}': {1}" -f $rowName, $_.Exception.Message)
                return
            }
        }
        $roleDefId = [string]$roleDefIdCache[$cacheKey]

        # Validate every desired member is a role-assignable group.
        $validatedMembers = New-Object 'System.Collections.Generic.List[string]'
        foreach ($oid in $desiredMembers) {
            if (-not $groupCheckCache.ContainsKey($oid)) {
                $groupCheckCache[$oid] = Test-IsRoleAssignableGroup -PrincipalId $oid -AccessToken $accessToken
            }
            if (-not $groupCheckCache[$oid]) {
                $report.Add([pscustomobject]@{
                    Category = 'Conflict'
                    Kind     = 'DirectoryRoleAssignment'
                    Name     = ("{0} @ {1} :: <oid>" -f $rowName, $rowScope)
                    Reason   = 'Declared member is not a security-enabled, role-assignable Entra group; skipped.'
                    RoleName = $rowName
                })
                continue
            }
            [void]$validatedMembers.Add($oid)
        }

        # Read current assignments at this (roleDefinitionId, scope).
        try {
            $currentAssigns = Get-AssignmentsForRoleScope -RoleDefinitionId $roleDefId -DirectoryScopeId $rowScope -AccessToken $accessToken
        }
        catch {
            # Same abort-the-whole-run contract as role resolution, above:
            # Phase 3 has not started, so no write has fired for any row.
            Write-Error ("Failed to read assignments for role '{0}' at scope '{1}': {2}" -f $rowName, $rowScope, $_.Exception.Message)
            return
        }

        # Build map: principalId -> assignment id. Phase 3's DELETE
        # addresses a roleAssignment by its own id, not by principal, so
        # this map -- not just the oid list -- must travel with the plan.
        $tenantMap = @{}
        foreach ($a in $currentAssigns) {
            $principalOid = [string]$a.principalId
            if ($principalOid -and -not $tenantMap.ContainsKey($principalOid)) {
                $tenantMap[$principalOid] = [string]$a.id
            }
        }

        $desiredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($oid in $validatedMembers) { [void]$desiredSet.Add($oid) }
        $tenantSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($principalOid in $tenantMap.Keys) { [void]$tenantSet.Add($principalOid) }

        $toCreate = @($validatedMembers | Where-Object { -not $tenantSet.Contains($_) })
        $toRevoke = @($tenantMap.Keys     | Where-Object { -not $desiredSet.Contains($_) })
        $noChange = @($validatedMembers | Where-Object {     $tenantSet.Contains($_) })

        foreach ($oid in $noChange) {
            $report.Add([pscustomobject]@{
                Category = 'NoChange'
                Kind     = 'DirectoryRoleAssignment'
                Name     = ("{0} @ {1} :: <oid>" -f $rowName, $rowScope)
                Reason   = 'Declared in YAML and present in tenant.'
                RoleName = $rowName
            })
        }

        if (-not $PruneMissing.IsPresent) {
            foreach ($oid in $toRevoke) {
                $report.Add([pscustomobject]@{
                    Category = 'NoOp'
                    Kind     = 'DirectoryRoleAssignment'
                    Name     = ("{0} @ {1} :: <oid>" -f $rowName, $rowScope)
                    Reason   = 'Tenant assignment not in YAML; skipped (use -PruneMissing to revoke).'
                    RoleName = $rowName
                })
            }
        }

        # Accumulate this row into the plan Phase 3 will iterate. A row
        # with neither a Create nor an in-scope Revoke has nothing left for
        # Phase 3 to do and is omitted -- mirrors
        # Deploy-PurviewRoleGroups.ps1's identical Phase 1 condition.
        if ($toCreate.Count -gt 0 -or ($PruneMissing.IsPresent -and $toRevoke.Count -gt 0)) {
            $plan.Add([pscustomobject]@{
                RowName   = $rowName
                RowScope  = $rowScope
                RoleDefId = $roleDefId
                ToCreate  = @($toCreate)
                ToRevoke  = @($toRevoke)
                TenantMap = $tenantMap
            })
        }
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before Phase 3 at which nothing has been written. This
    # script is Class B: it declares no -DirectionPolicy, so it has no
    # repo-wins overwrite branch and exactly ONE destructive branch -- the
    # -PruneMissing revoke. That branch is gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue
    # prompts unconditionally; ShouldProcess only prompts when
    # ConfirmImpact >= $ConfirmPreference, which is precisely the
    # comparison that silently defeated this gate before issue #85.
    #
    # The gate is keyed on the PLAN -- $revokes is the flattened union of
    # the very ToRevoke collections the Phase 3 revoke loop iterates -- and
    # never on a policy. Phase 3 guards that loop with
    # `if (-not $PruneMissing.IsPresent) { continue }`, so the gate's
    # `$PruneMissing.IsPresent -and $revokes.Count -gt 0` condition is
    # exactly the reachability condition of the writes it speaks for.
    # (A $plan entry can carry a non-empty ToRevoke without -PruneMissing,
    # because Phase 1 admits an entry on ToCreate alone -- hence the
    # -PruneMissing conjunct here is a PLAN predicate, not a policy one.)
    #
    # $revokes is built directly from $plan -- the same collection Phase 3
    # reads immediately below -- with no separate shadow list and no
    # lifetime between construction and read. There is therefore no window
    # in which policy (or anything else) could desynchronize the gate's
    # count from the writes it is about to authorize: shrinking $revokes
    # would require shrinking $plan itself, which would shrink the actual
    # Phase 3 revoke loop identically. That is the same structural immunity
    # ADR 0052's reference implementations rely on for their prune gates
    # (issue #103); this script has no overwrite gate to which the B2
    # data-laundering hazard could even apply.
    #
    # REVOKE, not DELETE: DELETE /roleManagement/directory/roleAssignments/{id}
    # drops a permission grant; it does not delete the underlying Entra
    # group or the role definition. Matches
    # Deploy-PurviewRoleGroups.ps1's own "REVOKE, not DELETE" framing.
    #
    # This `throw` sits inside the enclosing try/finally. There is no
    # `catch`, so a decline propagates out of the script (after the
    # `finally` drops the access token) rather than being swallowed and
    # falling through into Phase 3.
    #
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path),
    # and skipped under -WhatIf so a dry run still previews the revokes
    # without blocking on input. (The Apply-mode -WhatIf short-circuit
    # above returns before Phase 1 ever runs, so in practice this gate is
    # unreached under -WhatIf today -- -IsWhatIf is still bound correctly
    # below so the gate remains safe if that short-circuit is ever
    # narrowed to cover fewer cases.)
    # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    $yesToAll = $false
    $noToAll = $false
    $confirmBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')
    $confirmValue = if ($confirmBound) { [bool]$PSCmdlet.MyInvocation.BoundParameters['Confirm'] } else { $false }
    $gateArgs = @{
        Cmdlet       = $PSCmdlet
        Caption      = 'Destructive operation (ADR 0052)'
        YesToAll     = ([ref]$yesToAll)
        NoToAll      = ([ref]$noToAll)
        Force        = $Force.IsPresent
        IsWhatIf     = [bool]$WhatIfPreference
        ConfirmBound = $confirmBound
        ConfirmValue = $confirmValue
    }

    # One entry per assignment the Phase 3 revoke loop would drop. The
    # principal's Entra object ID is deliberately NOT interpolated into the
    # prompt -- the operator is shown the role and scope plus a count,
    # matching the '<oid>' redaction the drift report already uses.
    $revokes = @(foreach ($p in $plan) {
            foreach ($oid in $p.ToRevoke) { ("{0} @ {1}" -f $p.RowName, $p.RowScope) }
        })
    if ($PruneMissing.IsPresent -and $revokes.Count -gt 0) {
        $revokeSummary = @($revokes | Group-Object | Sort-Object Name |
                ForEach-Object { '{0} ({1} assignment(s))' -f $_.Name, $_.Count })
        $pruneQuery = "-PruneMissing will REVOKE {0} Microsoft Entra directory-role assignment(s) from the tenant: {1}. Each revoked assignment drops the permissions that directory role confers. This cannot be undone. Continue?" -f `
            $revokes.Count, ($revokeSummary -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing revoke confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # ---- Phase 3: Write, over the SAME plan Phase 1 built ----
    foreach ($entry in $plan) {
        $rowName   = $entry.RowName
        $rowScope  = $entry.RowScope
        $roleDefId = $entry.RoleDefId
        $tenantMap = $entry.TenantMap

        # Create rows.
        foreach ($oid in $entry.ToCreate) {
            $reportRow = [pscustomobject]@{
                Category = 'Create'
                Kind     = 'DirectoryRoleAssignment'
                Name     = ("{0} @ {1} :: <oid>" -f $rowName, $rowScope)
                Reason   = 'Declared in YAML; not present in tenant.'
                RoleName = $rowName
            }
            $report.Add($reportRow)

            $shouldProcessTarget = "Directory role '{0}' at scope '{1}' member <oid>" -f $rowName, $rowScope
            $shouldProcessAction = 'POST /roleManagement/directory/roleAssignments'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/rbacapplication-post-roleassignments
                $createUri  = ('{0}/roleManagement/directory/roleAssignments' -f $graphBase)
                $createBody = @{
                    principalId      = $oid
                    roleDefinitionId = $roleDefId
                    directoryScopeId = $rowScope
                }
                try {
                    Invoke-EntraGraphRequest -Method POST -Uri $createUri -Body $createBody -AccessToken $accessToken | Out-Null
                    Write-Information ("Created assignment for role '{0}' at scope '{1}'." -f $rowName, $rowScope) -InformationAction Continue
                }
                catch {
                    if ($_.Exception.Message -match 'A conflicting object with one or more of the specified property values is present') {
                        $reportRow.Category = 'NoChange'
                        $reportRow.Reason   = 'Tenant read returned stale state; server confirmed assignment already present (idempotent).'
                        Write-Information ("Role '{0}' already has the desired member at '{1}'; treating as no-op." -f $rowName, $rowScope) -InformationAction Continue
                        continue
                    }
                    Write-Error ("POST roleAssignments failed for role '{0}' at scope '{1}': {2}" -f $rowName, $rowScope, $_.Exception.Message)
                    return
                }
            }
        }

        if (-not $PruneMissing.IsPresent) { continue }

        # Revoke rows.
        foreach ($oid in $entry.ToRevoke) {
            $assignmentId = [string]$tenantMap[$oid]
            $reportRow = [pscustomobject]@{
                Category = 'Revoke'
                Kind     = 'DirectoryRoleAssignment'
                Name     = ("{0} @ {1} :: <oid>" -f $rowName, $rowScope)
                Reason   = 'Tenant assignment not in YAML; revoking under -PruneMissing.'
                RoleName = $rowName
            }
            $report.Add($reportRow)

            $shouldProcessTarget = "Directory role '{0}' at scope '{1}' member <oid>" -f $rowName, $rowScope
            $shouldProcessAction = 'DELETE /roleManagement/directory/roleAssignments/{id} (destructive: drops a permission)'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/unifiedroleassignment-delete
                $deleteUri = ('{0}/roleManagement/directory/roleAssignments/{1}' -f $graphBase, [System.Uri]::EscapeDataString($assignmentId))
                try {
                    Invoke-EntraGraphRequest -Method DELETE -Uri $deleteUri -AccessToken $accessToken | Out-Null
                    Write-Information ("Revoked assignment for role '{0}' at scope '{1}'." -f $rowName, $rowScope) -InformationAction Continue
                }
                catch {
                    if ($_.Exception.Message -match 'Resource.*does not exist|ResourceNotFound') {
                        $reportRow.Category = 'NoChange'
                        $reportRow.Reason   = 'Tenant read returned stale state; server confirmed assignment already absent (idempotent).'
                        Write-Information ("Role '{0}' did not have the assignment at '{1}'; treating as no-op." -f $rowName, $rowScope) -InformationAction Continue
                        continue
                    }
                    Write-Error ("DELETE roleAssignments failed for role '{0}' at scope '{1}': {2}" -f $rowName, $rowScope, $_.Exception.Message)
                    return
                }
            }
        }
    }

    #endregion
}
finally {
    # Drop the access token from the local scope as soon as the run
    # completes. PowerShell does not zero the underlying string memory,
    # but unbinding it removes it from the script's variable surface so
    # a subsequent error / transcript cannot inadvertently echo it.
    if (Get-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue) {
        Remove-Variable -Name accessToken -Scope 0 -ErrorAction SilentlyContinue
    }
}

#endregion

#region Emit report

$report
Write-Information ("Reconciliation complete. {0} report row(s) emitted." -f $report.Count) -InformationAction Continue

#endregion
