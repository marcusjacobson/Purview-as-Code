#Requires -Version 7.4
<#
.SYNOPSIS
    Grant (or revoke) a single Entra security group's membership in a single
    Microsoft Purview / Microsoft 365 portal role group, idempotently.

.DESCRIPTION
    Wave 0 imperative primitive that the future declarative reconciler
    (`scripts/Deploy-PurviewRoleGroups.ps1`) composes over. Sibling of:

      * Azure RBAC      -> infra/modules/rbac.bicep (control-plane).
      * Purview catalog -> scripts/Grant-PurviewDataMapRole.ps1 (data-map
                            collection roles, distinct surface).
      * THIS SCRIPT      -> Microsoft Purview / M365 portal role groups
                            (Organization Management, Compliance
                            Administrator, eDiscovery Manager, Insider Risk
                            Management, Information Protection Admins, etc.).

    API choice and ship order are decided by ADR 0009 (which supersedes
    ADR 0008). The script ships as Security & Compliance PowerShell only:

      1. `Connect-IPPSSession -AccessToken` against
         `https://ps.compliance.protection.outlook.com/...` with a Key
         Vault-signed JWT (ADR 0011 Decision #3 supersession). The private
         key never leaves Key Vault.
      2. `Get-RoleGroupMember -Identity <RoleGroup>` to read current state.
      3. Diff the requested -PrincipalId against the member list (matched by
         `ExternalDirectoryObjectId`, the Entra group object ID).
      4. Emit a single drift report row: Create / NoChange / Revoke / NoOp
         (subset of the five categories in
         `.github/instructions/powershell.instructions.md` -- Orphan and
         Conflict do not apply to a single-target imperative grant).
      5. `Add-RoleGroupMember` or `Remove-RoleGroupMember` only when the
         drift category requires a write.
      6. `Disconnect-ExchangeOnline -Confirm:$false` in a finally block.

    Graph extension point. Per ADR 0009 Decision #2 a private function
    documents the future Graph code path and the trigger condition (an
    Exchange / compliance / `purview` provider appearing on
    `rbacApplication`). No behavioural code on that path ships today; the
    function throws so a misconfiguration cannot silently call it.

    Group-only enforcement. Per the comment block in
    `data-plane/purview-role-groups/role-groups.yaml` and security
    instruction rule #4 (least privilege -> assign to groups, not users),
    -PrincipalId is validated as the object ID of an Entra **security
    group**, not a user. The S&C cmdlets accept either, but this primitive
    intentionally narrows the contract.

    References (Microsoft Learn):
      Permissions in the Microsoft Purview portal:
        https://learn.microsoft.com/en-us/purview/purview-permissions
      Roles and role groups in the Microsoft Defender / Purview portals:
        https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/scc-permissions
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      App-only authentication for Exchange / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Get-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
      Add-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
      Remove-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
      Microsoft Graph rbacApplication (today: directory + entitlementManagement only):
        https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication
      ADR 0009 (active):
        docs/adr/0009-portal-role-group-api-ship-order.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER RoleGroup
    Exact Microsoft-published role-group display name. Case-sensitive match
    against the portal and the `Identity` parameter of `Get-RoleGroupMember`.
    Examples: "Organization Management", "Compliance Administrator",
    "eDiscovery Manager", "Insider Risk Management",
    "Information Protection Admins". The set is tenant-mutable (custom role
    groups are allowed) so this script does not pin a ValidateSet; the
    cmdlet will surface an unknown-name error from S&C PowerShell.

.PARAMETER PrincipalId
    Entra (Microsoft Entra ID) **security group** object ID. Validated as a
    GUID. User object IDs and UPNs are intentionally rejected at this
    boundary -- assign to groups, not users, per
    `.github/instructions/security.instructions.md` rule #4. The script
    does not call Graph to verify the OID resolves to a group; that lookup
    belongs to the future Deploy-PurviewRoleGroups.ps1 reconciler when it
    has Graph permissions.

.PARAMETER Revoke
    Remove the principal from the role group instead of adding it.
    Destructive (drops a permission); requires explicit opt-in per the
    drift-report contract.

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted, resolved
    from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved from
    `automation.apps.dataPlane.certificateName` in the parameters file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName` in the parameters
    file.

.PARAMETER TenantDomain
    Tenant primary domain (for example `contoso.onmicrosoft.com`), passed to
    `Connect-IPPSSession -Organization`. When omitted, resolved from
    `automation.tenantDomain` in the parameters file.

.EXAMPLE
    ./scripts/Grant-PurviewRoleGroup.ps1 `
        -RoleGroup 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -WhatIf

    Prints planned behaviour; makes no remote calls. Safe with only an
    `az login` session.

.EXAMPLE
    ./scripts/Grant-PurviewRoleGroup.ps1 `
        -RoleGroup 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000

    Adds the Entra security group to "Compliance Administrator" if it is
    not already a member; otherwise emits a NoChange row.

.EXAMPLE
    ./scripts/Grant-PurviewRoleGroup.ps1 `
        -RoleGroup 'Compliance Administrator' `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -Revoke

    Removes the Entra security group from "Compliance Administrator" if it
    is currently a member; otherwise emits a NoOp row.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get for the
        public cert -- needed to compute the x5t#S256 thumbprint).
      Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide

    Data-plane Entra app prerequisites (one-time per tenant; see
    `scripts/Grant-ExchangeManageAsApp.ps1`):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        (application) granted with admin consent.
      * Entra directory role `Compliance Administrator` (or equivalent)
        assigned at `directoryScopeId = /` on the workload SP.
      * For -Revoke / -Add to write a target role group, the workload SP
        must also be a member of an Exchange role group that holds the
        "Role Management" role (typically `Organization Management`).
        This is the chicken-and-egg prerequisite documented in
        ADR 0009 sibling-repo addendum item #4 -- it must be granted
        manually once via the portal before this script can mutate
        membership of any other role group.
      Reference: https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2

    Output: a single PSCustomObject summary with the previous member
    state, the action taken (Create / NoChange / Revoke / NoOp), and the
    confirmed post-action state. No credential material is printed; the
    Entra app appId and target principalId are not emitted -- they are
    real tenant identifiers under the
    `Environment and identifier boundaries` section of
    `.github/copilot-instructions.md`.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 256)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 \-_/&\.]{0,254}$')]
    [string]$RoleGroup,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$PrincipalId,

    [Parameter()]
    [switch]$Revoke,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain
)

$ErrorActionPreference = 'Stop'

#region Graph extension point (ADR 0009 Decision #2 -- not called today)

function Invoke-GraphRoleGroupMember {
    <#
    .SYNOPSIS
        Future Microsoft Graph code path for portal role-group membership.
        Not called today.

    .DESCRIPTION
        Per ADR 0009 Decision #2, this function documents the trigger
        condition for switching the script to a Graph-primary path. It
        throws today so a misconfiguration cannot silently invoke it. When
        Microsoft publishes an `exchange`, `compliance`, or `purview`
        provider on `rbacApplication`
        (https://learn.microsoft.com/en-us/graph/api/resources/rbacapplication),
        a follow-up ADR supersedes ADR 0009 and this function gets a real
        body that issues role-assignment writes against
        `/security/roleAssignments` or the matching unified RBAC namespace,
        with managed-identity auth per
        `.github/instructions/security.instructions.md` rule #2.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$RoleGroup,
        [Parameter(Mandatory = $true)] [string]$PrincipalId,
        [Parameter()]                  [switch]$Revoke
    )
    $direction = if ($Revoke.IsPresent) { 'remove' } else { 'add' }
    throw [System.NotImplementedException]::new(
        ("Graph code path is the documented forward direction (ADR 0009 Decision #2) but is not enabled today. " +
         "Requested intent: {0} principal '{1}' to/from role group '{2}'. " +
         "rbacApplication exposes only 'directory' and 'entitlementManagement' providers, and Permissions in " +
         "the Microsoft Purview portal documents only portal-UI flows for role-group management. Re-enable " +
         "this path in a successor ADR when Microsoft publishes an Exchange / compliance / purview provider " +
         "on rbacApplication.") -f $direction, $PrincipalId, $RoleGroup)
}

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

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
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'. Reference: ADR 0012 Decision #3 + Connect-IPPSSession docs." -f $ParametersFile)
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

$actionLabel = if ($Revoke.IsPresent) { 'Revoke' } else { 'Create' }
$noopLabel   = if ($Revoke.IsPresent) { 'NoOp' }   else { 'NoChange' }

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("Role group      : {0}" -f $RoleGroup) -InformationAction Continue
Write-Information ("Direction       : {0}" -f $actionLabel) -InformationAction Continue

#endregion

#region Azure context (read-only preamble)

# `az account show` is a local token-cache read; safe in -WhatIf. The real
# tenantId GUID is consumed by the JWT helper but never echoed -- it is a
# real tenant identifier under copilot-instructions.md
# `Environment and identifier boundaries`.
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

#region ExchangeOnlineManagement module

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+. See `.github/instructions/powershell.instructions.md`
# section "Runtime: pwsh 7.4+ only, and the Connect-IPPSSession auth
# constraint".
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

#endregion

#region Connect, probe, (optionally) mutate, verify

# Pre-declare summary fields so they are populated regardless of branch.
$action            = $noopLabel
$previousIsMember  = $null
$currentIsMember   = $null

$shouldProcessTarget = "Security & Compliance PowerShell role group '{0}' (tenant {1})" -f $RoleGroup, $TenantDomain
$shouldProcessAction = if ($Revoke.IsPresent) {
    "Read Get-RoleGroupMember; remove principal {0} only if currently a member" -f $PrincipalId
} else {
    "Read Get-RoleGroupMember; add principal {0} only if not currently a member" -f $PrincipalId
}

if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {

    # --- Resolve Entra app appId via Graph read. -----------------------------
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
        Write-Error ("Entra application '{0}' not found. Run Wave 0 #5b (`./scripts/New-AutomationEntraApp.ps1 -Plane data`) first." -f $DataPlaneAppDisplayName)
        return
    }
    if ($appList.Count -gt 1) {
        Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name; reconcile manually." -f $appList.Count, $DataPlaneAppDisplayName)
        return
    }
    $appId = [string]$appList[0].appId
    # NOTE: $appId deliberately not printed -- real tenant identifier.

    # --- Acquire access token via Key Vault-side JWT signing. ---------------
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
        -TenantId        $tenantId
    if (-not $tok -or -not $tok.AccessToken) {
        Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
        return
    }
    Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        # IPPS (not EXO) is the correct endpoint for portal role-group cmdlets
        # per ADR 0009 Decision #1.
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

        # --- Probe current membership. --------------------------------------
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
        # Exchange `Get-RoleGroupMember` requires the `View-Only Recipients`
        # role or a superset on the workload SP (ADR 0009 reconciler-bootstrap
        # addendum item #3).
        try {
            $members = @(Get-RoleGroupMember -Identity $RoleGroup -ResultSize Unlimited -ErrorAction Stop)
        }
        catch {
            Write-Error ("Get-RoleGroupMember -Identity '{0}' failed: {1}. Verify the role-group display name is exactly correct (case-sensitive) and that the workload SP holds 'View-Only Recipients'." -f $RoleGroup, $_.Exception.Message)
            return
        }

        # Match by ExternalDirectoryObjectId (Entra OID). Some role-group
        # entries may be on-prem Exchange recipients with no Entra OID; those
        # cannot match a GUID input by definition.
        $existing = $members | Where-Object {
            $_.ExternalDirectoryObjectId -and ($_.ExternalDirectoryObjectId -ieq $PrincipalId)
        } | Select-Object -First 1

        $previousIsMember = [bool]$existing
        Write-Information ("Previous membership : {0} ({1} total members in role group)" -f $previousIsMember, $members.Count) -InformationAction Continue

        if ($Revoke.IsPresent) {
            if (-not $previousIsMember) {
                $action          = $noopLabel
                $currentIsMember = $false
            }
            else {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
                Remove-RoleGroupMember -Identity $RoleGroup -Member $PrincipalId -Confirm:$false -ErrorAction Stop | Out-Null
                $action = $actionLabel
                # Re-read to confirm.
                $verify = @(Get-RoleGroupMember -Identity $RoleGroup -ResultSize Unlimited -ErrorAction Stop)
                $currentIsMember = [bool]($verify | Where-Object {
                    $_.ExternalDirectoryObjectId -and ($_.ExternalDirectoryObjectId -ieq $PrincipalId)
                })
                if ($currentIsMember) {
                    Write-Error ("Remove-RoleGroupMember reported success but the principal is still a member of '{0}'. Investigate before retrying." -f $RoleGroup)
                    return
                }
            }
        }
        else {
            if ($previousIsMember) {
                $action          = $noopLabel
                $currentIsMember = $true
            }
            else {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
                Add-RoleGroupMember -Identity $RoleGroup -Member $PrincipalId -Confirm:$false -ErrorAction Stop | Out-Null
                $action = $actionLabel
                # Re-read to confirm.
                $verify = @(Get-RoleGroupMember -Identity $RoleGroup -ResultSize Unlimited -ErrorAction Stop)
                $currentIsMember = [bool]($verify | Where-Object {
                    $_.ExternalDirectoryObjectId -and ($_.ExternalDirectoryObjectId -ieq $PrincipalId)
                })
                if (-not $currentIsMember) {
                    Write-Error ("Add-RoleGroupMember reported success but the principal is not a member of '{0}'. Investigate before retrying." -f $RoleGroup)
                    return
                }
            }
        }
    }
    finally {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        # Connect-IPPSSession opens an EXO-style session; the matching
        # disconnect cmdlet is Disconnect-ExchangeOnline.
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
        }
    }
}
else {
    # -WhatIf path: no remote calls.
    Write-Information '-WhatIf specified. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ("  1. Resolve Entra app '{0}' via 'az ad app list' (Graph read)." -f $DataPlaneAppDisplayName) -InformationAction Continue
    Write-Information ("  2. Acquire access token via Get-PurviewIPPSAccessToken.ps1 (Key Vault-side PS256 sign against key '{0}' in vault '{1}')." -f $CertificateName, $VaultName) -InformationAction Continue
    Write-Information ("  3. Connect-IPPSSession -AccessToken <redacted> -Organization {0}" -f $TenantDomain) -InformationAction Continue
    Write-Information ("  4. Read members of role group '{0}' via Get-RoleGroupMember -ResultSize Unlimited." -f $RoleGroup) -InformationAction Continue
    if ($Revoke.IsPresent) {
        Write-Information ("  5. If principal {0} is a current member, run Remove-RoleGroupMember -Identity '{1}' -Member <principalId>; then re-read to verify." -f $PrincipalId, $RoleGroup) -InformationAction Continue
    } else {
        Write-Information ("  5. If principal {0} is NOT a current member, run Add-RoleGroupMember -Identity '{1}' -Member <principalId>; then re-read to verify." -f $PrincipalId, $RoleGroup) -InformationAction Continue
    }
    Write-Information '  6. Disconnect-ExchangeOnline -Confirm:$false in a finally block.' -InformationAction Continue
}

#endregion

#region Summary

[pscustomobject]@{
    tenantDomain        = $TenantDomain
    dataPlaneApp        = $DataPlaneAppDisplayName
    roleGroup           = $RoleGroup
    direction           = $actionLabel
    previousIsMember    = $previousIsMember
    currentIsMember     = $currentIsMember
    action              = $action
} | Format-List

#endregion
