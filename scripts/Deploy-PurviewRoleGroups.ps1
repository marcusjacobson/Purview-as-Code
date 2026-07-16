#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 portal role-group membership
    against `data-plane/purview-role-groups/role-groups.yaml` (desired state).

.DESCRIPTION
    Wave 0 declarative reconciler. The YAML is the central source of truth for
    portal role-group membership in this repo: any add/remove of an Entra
    security-group object ID in the file flows through this script, which
    converges the live tenant to match. Sibling of:

      * `scripts/Grant-PurviewRoleGroup.ps1` -- single-target imperative
        primitive. Same API surface, same drift vocabulary, same matching
        rule (`ExternalDirectoryObjectId` -ieq Entra group OID). The
        reconciler does **not** subprocess-invoke the primitive per row;
        it inlines the same `Get/Add/Remove-RoleGroupMember` cmdlets and
        re-uses one Security & Compliance PowerShell session for the whole
        run. Per-row subprocess invocation would force a cold
        `Connect-IPPSSession` + `Disconnect-ExchangeOnline` cycle per
        action, explicitly anti-pattern in
        `.github/instructions/powershell.instructions.md`
        (section: "Session re-use across cmdlet calls").

      * `scripts/Get-PurviewIPPSAccessToken.ps1` -- Key Vault-side JWT
        signing helper that supplies the access token; same auth path as
        the Grant- primitive (ADR 0011 Decision #3 supersession).

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET each desired role group's current membership via
         `Get-RoleGroupMember -Identity <RoleGroup> -ResultSize Unlimited`.
      2. Diff Entra group OIDs between desired and current state.
      3. Emit a categorized report:
            Create   -- in YAML members; not in tenant role-group.
            NoChange -- in both.
            Revoke   -- in tenant role-group; not in YAML members. Written
                        only with -PruneMissing.
            NoOp     -- skipped Revoke row (no -PruneMissing) or skipped
                        no-op write.
         "Update" does not apply because membership is binary. "Conflict"
         does not apply because role-group members do not carry a
         `lastModifiedBy` we can inspect.
      4. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    Scope rules (mirrors the YAML header comment in
    `data-plane/purview-role-groups/role-groups.yaml`):

      * Role groups NOT listed in the YAML are left untouched. The
        reconciler does not attempt to enumerate every tenant role group.
      * Within a listed role group, only members whose
        `ExternalDirectoryObjectId` matches an Entra group OID are
        considered. User members, on-prem recipients (no Entra OID), and
        non-group principals are ignored on read and never written.
        Enforces security instruction rule #4 (least privilege -- assign
        to groups, not users).
      * `-PruneMissing` is required to revoke Entra-group members that are
        present in the tenant but not in the YAML. Without it the row is
        reported and skipped.

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md` "First-run-against-
    an-existing-tenant contract"):

        ./scripts/Deploy-PurviewRoleGroups.ps1 -ExportCurrentState

    Hydrates the YAML from the live tenant (every role group with >=1
    Entra-group member). The script refuses to overwrite a non-empty
    `roleGroups:` list unless -Force is also specified. Existing YAML
    header comments are preserved by line-splicing -- only the
    `roleGroups:` block is rewritten.

    References (Microsoft Learn):
      Permissions in the Microsoft Purview portal:
        https://learn.microsoft.com/en-us/purview/purview-permissions
      Roles and role groups (Defender / Purview):
        https://learn.microsoft.com/en-us/microsoft-365/security/office-365-security/scc-permissions
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Get-RoleGroup:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
      Get-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
      Add-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
      Remove-RoleGroupMember:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0009 (active): docs/adr/0009-portal-role-group-api-ship-order.md
      ADR 0011 Decision #3 supersession: docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract): docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML file. Defaults to the in-repo location
    `data-plane/purview-role-groups/role-groups.yaml`.

.PARAMETER PruneMissing
    Allow revocation of Entra-group members that exist in a listed role
    group but are not declared in its YAML `members` list. Default $false.

.PARAMETER Force
    With -ExportCurrentState: allow overwriting a `roleGroups:` block that
    already contains entries. Without it the script refuses, to avoid
    clobbering hand-curated YAML. Reserved for the export path; ignored on
    the apply path because membership reconciliation does not have a
    "conflict" category (see .DESCRIPTION).

.PARAMETER ExportCurrentState
    Read every role group visible to the connected app, write those with
    >=1 Entra-group member to the YAML's `roleGroups:` block, and exit.
    Makes no writes to the tenant.

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
    from `automation.apps.dataPlane.certificateName` in the parameters
    file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.PARAMETER Interactive
    Bypass app-only authentication (Key Vault + cert JWT) and connect
    to Security & Compliance PowerShell as the calling user via
    `Connect-IPPSSession -UserPrincipalName`. Intended for local-dev
    runs from a workstation that cannot reach the Key Vault (PNA=
    Disabled, no private-link path). Opens a browser MFA flow. CI must
    not use this switch; any workflow running this reconciler always
    runs app-only. NOTE: no per-solution workflow owns Purview role
    groups today (ADR 0051; backfill tracked in issue #80), so the
    documented apply path for this surface is a LOCAL run of this
    script.

.PARAMETER UserPrincipalName
    UPN to pre-populate in the interactive sign-in dialog. Used only
    when `-Interactive` is supplied. When omitted with `-Interactive`,
    the UPN is read from `az account show --query user.name -o tsv`.

.EXAMPLE
    ./scripts/Deploy-PurviewRoleGroups.ps1 -WhatIf

    Run the read phase end-to-end (Connect, Get-RoleGroupMember, diff,
    emit Create/NoChange/Revoke/NoOp report) but skip every write.
    Writes are guarded by SupportsShouldProcess; the read phase is
    intentionally exercised so the drift report is produced.

.EXAMPLE
    ./scripts/Deploy-PurviewRoleGroups.ps1 -WhatIf -Interactive

    Same as above but authenticates as the calling user via browser
    MFA. Requires no Key Vault access. Suitable for local-dev drift
    review when the workstation is outside the KV's approved network.

.EXAMPLE
    ./scripts/Deploy-PurviewRoleGroups.ps1

    Add Entra-group members declared in the YAML that are missing from the
    tenant. Orphan members are reported and skipped (no -PruneMissing).

.EXAMPLE
    ./scripts/Deploy-PurviewRoleGroups.ps1 -PruneMissing

    Add missing members AND revoke tenant members not in the YAML.

.EXAMPLE
    ./scripts/Deploy-PurviewRoleGroups.ps1 -ExportCurrentState

    Hydrate `data-plane/purview-role-groups/role-groups.yaml` from the
    live tenant. Refuses to clobber a non-empty `roleGroups:` list.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant; see
    `scripts/Grant-ExchangeManageAsApp.ps1`):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` (or equivalent)
        assigned at directoryScopeId='/' on the workload SP.
      * Membership in an Exchange role group that holds the "Role
        Management" role (typically `Organization Management`) -- the
        chicken-and-egg prerequisite documented in ADR 0009. This must be
        granted manually once via the portal before this reconciler can
        mutate membership of any other role group.

    Output: a list of PSCustomObjects with columns Category / Kind / Name
    / Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or a file.
    No credential material is printed; tenant-real identifiers (appId,
    tenantId, member OIDs) are not echoed at INFO level.
#>
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\purview-role-groups\role-groups.yaml'),

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
    [string]$TenantDomain,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Interactive,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$')]
    [string]$UserPrincipalName
)

$ErrorActionPreference = 'Stop'

#region Helper -- GUID test for Entra OID matching

function Test-IsGuid {
    param([Parameter(Mandatory = $true)][AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return [System.Guid]::TryParse($Value, [ref]([guid]::Empty))
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA). See
# `.github/instructions/powershell.instructions.md`.
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

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
$authMode = if ($Interactive.IsPresent) { 'Interactive (user, browser MFA)' } else { 'App-only (Key Vault cert)' }

Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("Auth            : {0}" -f $authMode) -InformationAction Continue
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
if (-not $Interactive.IsPresent) {
    Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
    Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
    Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
}
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue

#endregion

#region Desired-state load (Apply mode)

# Always parse the file so Export mode can inspect the existing
# `roleGroups:` block and refuse to clobber non-empty content without
# -Force. For Apply mode, this is the desired state.
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

$desiredRoleGroups = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('roleGroups') -and $desiredRoot.roleGroups) {
    $desiredRoleGroups = @($desiredRoot.roleGroups)
}

# Validate desired state: every member must be a parseable GUID. User
# UPNs and individual-object IDs are rejected at this boundary per
# security rule #4.
if ($mode -eq 'Apply') {
    foreach ($rg in $desiredRoleGroups) {
        if (-not $rg.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$rg.name)) {
            Write-Error ("Role-group entry in '{0}' is missing the required 'name' field." -f $Path)
            return
        }
        $members = @()
        if ($rg.ContainsKey('members') -and $rg.members) { $members = @($rg.members) }
        foreach ($m in $members) {
            if (-not (Test-IsGuid -Value ([string]$m))) {
                Write-Error ("Role group '{0}' member '{1}' is not a valid Entra group object ID. Per role-groups.yaml header, only Entra security-group OIDs are accepted." -f $rg.name, $m)
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

#region Resolve Entra app + acquire token

# -WhatIf no longer short-circuits before Connect. The read phase
# (Get-RoleGroupMember, categorize) is required to produce a drift
# report; writes (Add/Remove) remain guarded by SupportsShouldProcess
# and become no-ops under -WhatIf via Phase 3 below. Per drift-report
# contract in `.github/instructions/powershell.instructions.md`.

$tok = $null
if (-not $Interactive.IsPresent) {
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
        Write-Error ("Entra application '{0}' not found. Run Wave 0 #5b first." -f $DataPlaneAppDisplayName)
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
        -TenantId        $tenantId
    if (-not $tok -or -not $tok.AccessToken) {
        Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
        return
    }
    Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue
}
else {
    # Interactive mode: resolve the UPN from `az account show` when the
    # caller did not pass one. Connect-IPPSSession -UserPrincipalName
    # uses MSAL to open a browser sign-in with MFA.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    if (-not $UserPrincipalName) {
        $UserPrincipalName = (az account show --query user.name -o tsv 2>$null)
        if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
            Write-Error 'Interactive mode requires a UPN. Pass -UserPrincipalName or run `az login` first.'
            return
        }
    }
    Write-Information ("Interactive UPN : {0} (browser MFA will be triggered)" -f $UserPrincipalName) -InformationAction Continue
}

#endregion

#region Connect, reconcile, disconnect (single session for the whole run)

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    if ($Interactive.IsPresent) {
        Connect-IPPSSession `
            -UserPrincipalName $UserPrincipalName `
            -ShowBanner:$false `
            -ErrorAction       Stop | Out-Null
        Write-Information ("Connected to Security & Compliance PowerShell as user '{0}'." -f $UserPrincipalName) -InformationAction Continue
    }
    else {
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue
    }

    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredRoleGroups.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("'{0}' already declares {1} role group(s) in 'roleGroups:'. Refusing to overwrite without -Force. Edit the file by hand or pass -Force to clobber." -f $Path, $desiredRoleGroups.Count)
            return
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
        $allRoleGroups = @(Get-RoleGroup -ResultSize Unlimited -ErrorAction Stop)
        Write-Information ("Discovered {0} role group(s) visible to the connected app." -f $allRoleGroups.Count) -InformationAction Continue

        # Inventory mode: emit every role group the connected app can
        # see, with `members:` populated only by Entra-group OIDs (per
        # `.github/instructions/security.instructions.md` rule #4 — the
        # reconciler manages group-based assignments only). Per-entry
        # comments record current user/group counts so reviewers can spot
        # role groups that should be re-modelled around an Entra group.
        $exportEntries = New-Object 'System.Collections.Generic.List[hashtable]'
        $exportStamp   = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        foreach ($rg in $allRoleGroups | Sort-Object Name) {
            try {
                $members = @(Get-RoleGroupMember -Identity $rg.Name -ResultSize Unlimited -ErrorAction Stop)
            }
            catch {
                Write-Warning ("Get-RoleGroupMember -Identity '{0}' failed during export: {1}. Recording entry with empty members." -f $rg.Name, $_.Exception.Message)
                $entry = @{
                    name        = [string]$rg.Name
                    description = "Exported from $TenantDomain on $exportStamp."
                    members     = @()
                    userCount   = 0
                    groupCount  = 0
                    note        = "Get-RoleGroupMember failed during export; counts unavailable."
                }
                $exportEntries.Add($entry)
                continue
            }
            $groupOids = @($members |
                Where-Object { $_.RecipientTypeDetails -eq 'Group' -and $_.ExternalDirectoryObjectId } |
                Select-Object -ExpandProperty ExternalDirectoryObjectId -Unique |
                Sort-Object)
            $userCount = @($members | Where-Object { $_.RecipientTypeDetails -ne 'Group' }).Count
            $entry = @{
                name        = [string]$rg.Name
                description = "Exported from $TenantDomain on $exportStamp."
                members     = @($groupOids)
                userCount   = [int]$userCount
                groupCount  = [int]$groupOids.Count
                note        = $null
            }
            $exportEntries.Add($entry)
        }

        $populated = @($exportEntries | Where-Object { $_.groupCount -gt 0 }).Count
        Write-Information ("Exporting {0} role group(s) total ({1} with >=1 Entra-group member managed by this reconciler)." -f $exportEntries.Count, $populated) -InformationAction Continue

        # Preserve YAML header comments by line-splicing: keep every line
        # up to (but not including) the first occurrence of a top-level
        # `roleGroups:` key, then append the freshly serialized block.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*roleGroups\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'roleGroups:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = $originalLines[0..($cutIndex - 1)]

        # Build the new roleGroups block with stable ordering.
        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        if ($exportEntries.Count -eq 0) {
            $newBlock.Add('roleGroups: []')
        }
        else {
            $newBlock.Add('roleGroups:')
            foreach ($entry in $exportEntries) {
                $newBlock.Add(("  - name: {0}" -f $entry.name))
                $newBlock.Add(("    description: {0}" -f $entry.description))
                if ($entry.note) {
                    $newBlock.Add(("    # {0}" -f $entry.note))
                }
                else {
                    $newBlock.Add(("    # Current tenant assignments: {0} user(s), {1} group(s). Users are not managed by this reconciler." -f $entry.userCount, $entry.groupCount))
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
        $shouldProcessAction = "Replace 'roleGroups:' block with {0} entry/entries" -f $exportEntries.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            $finalLines | Set-Content -LiteralPath $Path -Encoding utf8
            Write-Information ("Wrote {0} role-group entry/entries to '{1}'. Review the diff in a pull request before applying." -f $exportEntries.Count, $Path) -InformationAction Continue
        }

        return

        #endregion
    }

    #region Apply mode: two-phase reconciliation
    # The Security & Compliance PowerShell REST proxy auto-disconnects
    # long-lived app-only (-AccessToken) sessions after a high-volume
    # read loop. When that happens the EXO module emits its
    # "Disconnected successfully !" banner mid-run and the local
    # cmdlet stubs lapse into a degraded state where subsequent
    # Add-/Remove-RoleGroupMember calls fail with a *local* parser
    # error ("A positional parameter cannot be found that accepts
    # argument '<RoleGroup>'"), not a server error. To avoid this we
    # split Apply into two phases with an explicit reconnect in
    # between:
    #   1. Read phase: enumerate desired vs. tenant state for every
    #      role group, build a per-RG plan, emit NoChange / NoOp
    #      report rows (no remote writes).
    #   2. Reconnect: Disconnect-ExchangeOnline + fresh
    #      Connect-IPPSSession to rebind clean cmdlet stubs.
    #   3. Write phase: execute Add / Remove calls against the
    #      refreshed session and emit Create / Revoke report rows.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline

    if ($desiredRoleGroups.Count -eq 0) {
        Write-Information 'No role groups declared in YAML. Nothing to reconcile.' -InformationAction Continue
        return @()
    }

    # ---- Phase 1: Read + categorize ----
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rg in $desiredRoleGroups) {
        $rgName = [string]$rg.name
        $desiredMembers = @()
        if ($rg.ContainsKey('members') -and $rg.members) {
            $desiredMembers = @($rg.members | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
        try {
            $tenantMembers = @(Get-RoleGroupMember -Identity $rgName -ResultSize Unlimited -ErrorAction Stop)
        }
        catch {
            Write-Error ("Get-RoleGroupMember -Identity '{0}' failed: {1}. Verify the role-group name is exactly correct (case-sensitive) and the workload SP holds 'View-Only Recipients'." -f $rgName, $_.Exception.Message)
            return
        }

        # Read-phase diagnostic (issue #401): when the app-only IPPS session
        # returns membership with stripped RecipientTypeDetails or null
        # ExternalDirectoryObjectId, the filter below silently drops every
        # row and the empty $tenantGroupOids breaks both Revoke detection
        # (empty $desiredSet ∩ empty $tenantSet = no plan row) and Create
        # accounting (everything reported as Create then downgraded to
        # NoChange via MemberAlreadyExistsException). Visible with -Verbose
        # or ACTIONS_STEP_DEBUG=true in CI.
        Write-Verbose ("[read] '{0}': Get-RoleGroupMember returned {1} raw member(s)." -f $rgName, $tenantMembers.Count)
        foreach ($m in $tenantMembers) {
            Write-Verbose ("[read] '{0}': member Name='{1}' RecipientTypeDetails='{2}' ExternalDirectoryObjectId='{3}'" -f $rgName, $m.Name, $m.RecipientTypeDetails, $m.ExternalDirectoryObjectId)
        }

        # Match domain: only tenant members that are Entra security
        # groups with a non-null ExternalDirectoryObjectId. Anything else
        # (users, on-prem recipients) is ignored on read and never
        # written.
        $tenantGroupOids = @($tenantMembers |
            Where-Object { $_.RecipientTypeDetails -eq 'Group' -and $_.ExternalDirectoryObjectId } |
            Select-Object -ExpandProperty ExternalDirectoryObjectId -Unique)
        Write-Verbose ("[read] '{0}': after filter, {1} Entra group OID(s) remain." -f $rgName, $tenantGroupOids.Count)

        $desiredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($oid in $desiredMembers) { [void]$desiredSet.Add($oid) }
        $tenantSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($oid in $tenantGroupOids) { [void]$tenantSet.Add($oid) }

        # Categorize.
        $toCreate = @($desiredMembers | Where-Object { -not $tenantSet.Contains($_) })
        $toRevoke = @($tenantGroupOids | Where-Object { -not $desiredSet.Contains($_) })
        $noChange = @($desiredMembers | Where-Object { $tenantSet.Contains($_) })

        foreach ($oid in $noChange) {
            $report.Add([pscustomobject]@{
                Category  = 'NoChange'
                Kind      = 'RoleGroupMember'
                Name      = ("{0} :: <oid>" -f $rgName)
                Reason    = 'Declared in YAML and present in tenant.'
                RoleGroup = $rgName
            })
        }

        if (-not $PruneMissing.IsPresent) {
            foreach ($oid in $toRevoke) {
                $report.Add([pscustomobject]@{
                    Category  = 'NoOp'
                    Kind      = 'RoleGroupMember'
                    Name      = ("{0} :: <oid>" -f $rgName)
                    Reason    = 'Tenant member not in YAML; skipped (use -PruneMissing to revoke).'
                    RoleGroup = $rgName
                })
            }
        }

        Write-Verbose ("[plan] '{0}': desired={1} tenantOids={2} toCreate={3} toRevoke={4} noChange={5} PruneMissing={6}" -f $rgName, $desiredMembers.Count, $tenantGroupOids.Count, $toCreate.Count, $toRevoke.Count, $noChange.Count, $PruneMissing.IsPresent)

        if ($toCreate.Count -gt 0 -or ($PruneMissing.IsPresent -and $toRevoke.Count -gt 0)) {
            $plan.Add([pscustomobject]@{
                RoleGroup = $rgName
                ToCreate  = @($toCreate)
                ToRevoke  = @($toRevoke)
            })
        }
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before Phase 2/3 at which nothing has been written.
    # This script is Class B: it declares no -DirectionPolicy, so it has no
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
    # REVOKE, not DELETE: Remove-RoleGroupMember drops a member's
    # permission; it does not destroy the Entra group or the role group.
    #
    # This `throw` sits inside the enclosing try/finally. There is no
    # `catch`, so a decline propagates out of the script (after the
    # `finally` disconnects the S&C session) rather than being swallowed
    # and falling through into the write phase.
    #
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path),
    # and skipped under -WhatIf so a dry run still previews the revokes
    # without blocking on input.
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

    # One entry per membership the Phase 3 revoke loop would drop. The
    # member's Entra object ID is deliberately NOT interpolated into the
    # prompt -- the operator is shown the role group and the member count,
    # matching the '<oid>' redaction the drift report already uses.
    $revokes = @(foreach ($p in $plan) {
            foreach ($oid in $p.ToRevoke) { [string]$p.RoleGroup }
        })
    if ($PruneMissing.IsPresent -and $revokes.Count -gt 0) {
        $revokeSummary = @($revokes | Group-Object | Sort-Object Name |
                ForEach-Object { '{0} ({1} member(s))' -f $_.Name, $_.Count })
        $pruneQuery = "-PruneMissing will REVOKE {0} Purview role-group membership(s) from the tenant: {1}. Each revoked member loses the permissions that role group confers. This cannot be undone. Continue?" -f `
            $revokes.Count, ($revokeSummary -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing revoke confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # ---- Phase 2: Refresh session before any writes ----
    $writeCount = 0
    foreach ($p in $plan) {
        $writeCount += $p.ToCreate.Count
        if ($PruneMissing.IsPresent) { $writeCount += $p.ToRevoke.Count }
    }

    if ($writeCount -gt 0) {
        Write-Information ("Read phase complete. Refreshing S&C session before {0} write operation(s)." -f $writeCount) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        # NOTE: a Disconnect+Connect alone is not enough. The
        # ExchangeOnlineManagement module loads its cmdlet stubs from
        # a temporary auto-generated module (tmpEXO_*) in $env:TEMP.
        # After a high-volume read loop the stubs degrade: the next
        # Add-/Remove-RoleGroupMember call rejects both `-Identity`
        # (named) and the positional form with a *local* parser
        # error. Fully unloading the EXO module, removing the temp
        # module artifacts, and re-importing forces fresh stubs to
        # be generated for the new connection.
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Verbose ("Pre-write Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
        }
        Remove-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue
        # Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
        Get-ChildItem -Path $env:TEMP -Directory -Filter 'tmpEXO_*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Import-Module ExchangeOnlineManagement -Force -ErrorAction Stop

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        if ($Interactive.IsPresent) {
            Connect-IPPSSession `
                -UserPrincipalName $UserPrincipalName `
                -ShowBanner:$false `
                -ErrorAction       Stop | Out-Null
        }
        else {
            Connect-IPPSSession `
                -AccessToken  $tok.AccessToken `
                -Organization $TenantDomain `
                -ShowBanner:$false `
                -ErrorAction  Stop | Out-Null
        }
        Write-Information 'Reconnected to Security & Compliance PowerShell for write phase.' -InformationAction Continue
    }

    # ---- Phase 3: Write ----
    foreach ($entry in $plan) {
        $rgName = $entry.RoleGroup

        foreach ($oid in $entry.ToCreate) {
            $reportRow = [pscustomobject]@{
                Category  = 'Create'
                Kind      = 'RoleGroupMember'
                Name      = ("{0} :: <oid>" -f $rgName)
                Reason    = 'Declared in YAML; not present in tenant.'
                RoleGroup = $rgName
            }
            $report.Add($reportRow)

            $shouldProcessTarget = "Role group '{0}' member <oid>" -f $rgName
            $shouldProcessAction = 'Add-RoleGroupMember'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
                try {
                    Add-RoleGroupMember -Identity $rgName -Member $oid -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Added member to role group '{0}'." -f $rgName) -InformationAction Continue
                    # Post-write verification (issue #401): re-read role-group membership
                    # to confirm the Add actually persisted server-side. Diagnoses the
                    # silent non-persistence hypothesis where Exchange / S&C returns 2xx
                    # but the row never lands.
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
                    try {
                        $verify = @(Get-RoleGroupMember -Identity $rgName -ResultSize Unlimited -ErrorAction Stop |
                            Where-Object { $_.ExternalDirectoryObjectId -ieq $oid })
                        if ($verify.Count -gt 0) {
                            Write-Verbose ("[verify-add] '{0}': post-Add read confirmed member present." -f $rgName)
                        }
                        else {
                            Write-Warning ("[verify-add] '{0}': Add returned success but post-Add read did NOT see the member. Possible silent non-persistence or replication lag." -f $rgName)
                        }
                    }
                    catch {
                        Write-Verbose ("[verify-add] '{0}': post-Add read failed: {1}" -f $rgName, $_.Exception.Message)
                    }
                }
                catch {
                    # Idempotent: server confirms member already present. Downgrade report row to NoChange and continue.
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
                    if ($_.Exception.Message -match 'MemberAlreadyExistsException' -or
                        $_.Exception.Message -match 'is already a member of the group') {
                        $reportRow.Category = 'NoChange'
                        $reportRow.Reason   = 'Tenant read returned stale state; server confirmed member already present (idempotent).'
                        Write-Information ("Role group '{0}' already contains the desired member; treating as no-op." -f $rgName) -InformationAction Continue
                        continue
                    }
                    Write-Error ("Add-RoleGroupMember -Identity '{0}' failed: {1}" -f $rgName, $_.Exception.Message)
                    return
                }
            }
        }

        if (-not $PruneMissing.IsPresent) { continue }

        foreach ($oid in $entry.ToRevoke) {
            $reportRow = [pscustomobject]@{
                Category  = 'Revoke'
                Kind      = 'RoleGroupMember'
                Name      = ("{0} :: <oid>" -f $rgName)
                Reason    = 'Tenant member not in YAML; revoking under -PruneMissing.'
                RoleGroup = $rgName
            }
            $report.Add($reportRow)
            $shouldProcessTarget = "Role group '{0}' member <oid>" -f $rgName
            $shouldProcessAction = 'Remove-RoleGroupMember (destructive: drops a permission)'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
                try {
                    Remove-RoleGroupMember -Identity $rgName -Member $oid -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Revoked member from role group '{0}'." -f $rgName) -InformationAction Continue
                }
                catch {
                    # Idempotent: server confirms member already absent. Downgrade report row to NoChange and continue.
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
                    if ($_.Exception.Message -match 'MemberNotFoundException' -or
                        $_.Exception.Message -match 'is not a member of the group') {
                        $reportRow.Category = 'NoChange'
                        $reportRow.Reason   = 'Tenant read returned stale state; server confirmed member already absent (idempotent).'
                        Write-Information ("Role group '{0}' did not contain the member; treating as no-op." -f $rgName) -InformationAction Continue
                        continue
                    }
                    Write-Error ("Remove-RoleGroupMember -Identity '{0}' failed: {1}" -f $rgName, $_.Exception.Message)
                    return
                }
            }
        }
    }

    #endregion
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
    }
}

#endregion

#region Drift report emission

$report | Sort-Object RoleGroup, Category, Name | Format-Table Category, Kind, RoleGroup, Reason -AutoSize | Out-String | Write-Information -InformationAction Continue

# Return the report for pipeline capture (-OutVariable / | Export-Csv / etc.).
return $report

#endregion
