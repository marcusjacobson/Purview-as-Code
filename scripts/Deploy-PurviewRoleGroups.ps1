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

    Member resolution (ADR 0023 Category 3, issue #95): each `members:`
    entry is EITHER a raw Entra group object ID string (legacy-but-
    supported, used as-is) OR a mapping `{ displayName: <name> }`,
    resolved to an objectId via `scripts/Get-EntraPrincipalIdByDisplayName.ps1`.
    Resolution is FAIL-CLOSED: a not-found or ambiguous displayName aborts
    the whole run before any tenant write -- it never silently drops the
    member and shrinks the desired set (which is what would let
    `-PruneMissing` mistake "resolution failed" for "revoke everything").
    `-ExportCurrentState` always writes the displayName shape for a
    freshly exported member, never a raw OID, so re-committing an export
    can never re-introduce the disclosure #92 fixed.

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
        `RecipientTypeDetails` is `MailNonUniversalGroup` or
        `MailUniversalSecurityGroup` (the documented Entra-security-group
        values -- issue #57; `'Group'` is not a real value in this enum
        under any auth mode) are considered a group member. The Entra
        objectId is read from `ExternalDirectoryObjectId` when populated,
        otherwise resolved via the same displayName-resolution helper
        used for `members:` entries (ADR 0023 Category 3). User members
        and non-group principals are ignored on read and never written.
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

# Issue #65 F4: role groups that `Get-RoleGroup` returns but that cannot take an
# Entra-group member -- `Add-RoleGroupMember` rejects them with
# `EntityValidation CheckIsUserRole, Role with isUserRole not allowed`.
# `DefaultRoleAssignmentPolicy` is an Exchange RBAC role-assignment *policy*, not a
# bindable role group; it was dropped from role-groups.yaml in #61. This denylist
# keeps `-ExportCurrentState` from ever writing such a role group back into the
# desired set. Kept as an explicit list rather than a Get-RoleGroup property probe
# because the discriminating field is undocumented; add names here if a future
# tenant surfaces additional non-bindable role groups (see #65 F4).
$script:NonBindableRoleGroups = @('DefaultRoleAssignmentPolicy')

function Test-IsNonBindableRoleGroup {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RoleGroupName)
    return ($script:NonBindableRoleGroups -contains $RoleGroupName)
}

# Issue #65 F5: confirm a just-added role-group member is visible, tolerating
# Security & Compliance replication lag. The immediate post-Add read frequently
# misses a member that a moments-later read sees -- proven benign on #61 (every
# such warning cleared on a later -WhatIf). Retries the caller-supplied reader a
# few times with a short backoff and returns whether the member OID became
# visible, so the caller only warns after genuine non-persistence. The reader is
# injected (not hard-coded to Get-RoleGroupMember) purely so this stays
# unit-testable without a live S&C session.
function Wait-RoleGroupMemberVisible {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Reader,
        [Parameter(Mandatory = $true)][string]$Oid,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 2
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $rows = @(& $Reader)
            if (@($rows | Where-Object { $_.ExternalDirectoryObjectId -ieq $Oid }).Count -gt 0) {
                return $true
            }
        }
        catch {
            Write-Verbose ("[verify-add] post-Add read attempt {0}/{1} failed: {2}" -f $attempt, $MaxAttempts, $_.Exception.Message)
        }
        if ($attempt -lt $MaxAttempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    }
    return $false
}

function Test-IsRoleMemberShapeValid {
    <#
    .SYNOPSIS
        Validate a single `members:` list entry against the ADR 0023
        Category 3 dual-shape contract (issue #95): either a raw Entra
        group object ID (GUID) string -- the legacy-but-still-supported
        shape -- or a mapping `{ displayName: <name> }`. Pure shape
        check; no Graph calls.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowNull()]$Value)
    if ($Value -is [string]) {
        return (Test-IsGuid -Value $Value)
    }
    if ($Value -is [hashtable] -or $Value -is [System.Collections.IDictionary]) {
        return ($Value.Contains('displayName') -and -not [string]::IsNullOrWhiteSpace([string]$Value['displayName']))
    }
    return $false
}

function Resolve-DesiredRoleGroupMemberIds {
    <#
    .SYNOPSIS
        Normalize a role group's `members:` list to a flat array of Entra
        group object IDs, per the ADR 0023 Category 3 dual-shape contract
        (issue #95).

    .DESCRIPTION
        A plain string entry is a raw Entra group object ID (legacy-but-
        supported; used as-is, unchanged behaviour). A mapping entry
        `{ displayName: <name> }` is resolved to an objectId now, via the
        caller-supplied -Resolver script block (production callers pass a
        closure over `scripts/Get-EntraPrincipalIdByDisplayName.ps1`).

        FAIL-CLOSED CONTRACT (issue #95's single most important acceptance
        criterion): a resolution failure -- not-found, ambiguous, or a
        transport error -- THROWS. It is never caught-and-`continue`d
        here, because swallowing it would silently shrink the returned
        member list, and an emptied desired set is exactly what
        `-PruneMissing` reads as "revoke every real member of this role
        group". Callers MUST let this throw propagate to a run-aborting
        `Write-Error; return` before any write -- never downgrade it to a
        per-member skip.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function returns an array of resolved objectIds; plural is the accurate return shape.')]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Members,
        [Parameter(Mandatory = $true)][scriptblock]$Resolver
    )
    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in @($Members)) {
        if ($m -is [string]) {
            $trimmed = $m.Trim()
            if ($trimmed) { [void]$result.Add($trimmed) }
            continue
        }
        if ($m -is [hashtable] -or $m -is [System.Collections.IDictionary]) {
            $displayName = [string]$m['displayName']
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                throw "Members entry is missing the required 'displayName' field."
            }
            $resolvedId = & $Resolver $displayName
            if ([string]::IsNullOrWhiteSpace([string]$resolvedId)) {
                throw ("Resolver returned an empty objectId for displayName '{0}'." -f $displayName)
            }
            [void]$result.Add([string]$resolvedId)
            continue
        }
        throw ("Members entry '{0}' is not a valid shape. Expected a raw Entra group object ID (GUID) string or an object with 'displayName'." -f $m)
    }
    return , $result.ToArray()
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

# In-repo -PruneMissing safety guard (issue #13): the empty-desired-set
# refusal, which prevents a prune against a zero-entry desired state from
# classifying every live tenant object as an orphan. Shared with the other
# Deploy-*.ps1 reconcilers that implement -PruneMissing.
Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1') `
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

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# With zero desired entries every live custom Purview role group falls out of
# the orphan match below, so the run would classify the entire set as orphans
# and delete it -- revoking every permission those groups conferred. The
# rationale, the likely causes, and the 2026-07-19 production hit are
# documented in scripts/modules/PruneGuard.psm1.
#
# Placed in the desired-state load region so it fires before the tenant is
# contacted at all -- before `az account show`, before Connect-IPPSSession,
# and before any write phase.
if ($mode -eq 'Apply' -and $PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   $desiredRoleGroups.Count `
        -ObjectTypeNoun 'role group' `
        -SourcePath     $Path `
        -CollectionKey  'roleGroups'
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
            if (-not (Test-IsRoleMemberShapeValid -Value $m)) {
                Write-Error ("Role group '{0}' has a members entry that is neither a valid Entra group object ID (GUID) string (legacy-but-supported) nor an object shaped '{{ displayName: <name> }}' (ADR 0023 Category 3). Value: '{1}'" -f $rg.name, $m)
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

    # Resolve the ADR 0023 Category 3 helper (issue #95) used to turn a
    # displayName-shape `members:` entry -- and, per issue #57, a tenant
    # member row whose `ExternalDirectoryObjectId` is blank -- into an
    # Entra objectId. Checked once, up front, shared by both -Export and
    # -Apply below, so a missing helper fails loudly before any read.
    $resolvePrincipalScript = Join-Path $scriptRoot 'Get-EntraPrincipalIdByDisplayName.ps1'
    if (-not (Test-Path -LiteralPath $resolvePrincipalScript)) {
        Write-Error ("Helper not found: '{0}'." -f $resolvePrincipalScript)
        return
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
            # Issue #65 F4: never write a non-bindable role group into the desired
            # set. `Get-RoleGroup` returns entries like `DefaultRoleAssignmentPolicy`
            # (an Exchange RBAC role-assignment policy) that `Add-RoleGroupMember`
            # rejects; exporting them would re-introduce the #61 bind failure on the
            # next apply. Skip on export so a fresh role-groups.yaml stays applyable.
            if (Test-IsNonBindableRoleGroup -RoleGroupName $rg.Name) {
                Write-Warning ("Skipping non-bindable role group '{0}' on export: it cannot take an Entra-group member (Add-RoleGroupMember rejects it with EntityValidation CheckIsUserRole). See issue #65 F4." -f $rg.Name)
                continue
            }
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
            # ADR 0023 Category 3 (issue #95): a fresh export writes the
            # displayName shape, never a raw OID, so re-committing an
            # export can never re-introduce the #92 disclosure.
            # Get-RoleGroupMember already returns the recipient's display
            # name on `.Name` -- no extra Graph round-trip needed. A
            # member with a blank `.Name` falls back to the legacy
            # raw-OID shape with a warning rather than being dropped.
            $seenOids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $memberEntries = New-Object 'System.Collections.Generic.List[hashtable]'
            # Issue #57: `RecipientTypeDetails -eq 'Group'` is not a real
            # value in Microsoft's documented enum (Get-Recipient /
            # Get-RoleGroupMember) under any auth mode -- this filter has
            # never matched a real Entra security group. The documented
            # values are 'MailNonUniversalGroup' and
            # 'MailUniversalSecurityGroup'.
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-recipient?view=exchange-ps
            foreach ($m in ($members | Where-Object { $_.RecipientTypeDetails -in @('MailNonUniversalGroup', 'MailUniversalSecurityGroup') } | Sort-Object Name)) {
                $memberDisplayName = [string]$m.Name
                $oid = [string]$m.ExternalDirectoryObjectId
                if ([string]::IsNullOrWhiteSpace($oid)) {
                    # Issue #57: `ExternalDirectoryObjectId` is empirically
                    # blank for `MailNonUniversalGroup` rows -- Microsoft's
                    # docs do not document population rules for this
                    # property on Get-RoleGroupMember output, so it cannot
                    # be trusted directly. Resolve the real Entra objectId
                    # via the same displayName-resolution helper every
                    # other reconciler in this repo uses (ADR 0023
                    # Category 3), rather than inventing a new mechanism.
                    if ([string]::IsNullOrWhiteSpace($memberDisplayName)) {
                        Write-Warning ("Role group '{0}': a member had both a blank displayName and a blank ExternalDirectoryObjectId during export; skipping (cannot identify the principal). Reference: docs/adr/0023-identifier-resolution.md." -f $rg.Name)
                        continue
                    }
                    try {
                        $oid = & $resolvePrincipalScript -DisplayName $memberDisplayName -Kind 'Group'
                    }
                    catch {
                        Write-Warning ("Role group '{0}': failed to resolve member '{1}' to an Entra group objectId during export: {2}. Skipping this member." -f $rg.Name, $memberDisplayName, $_.Exception.Message)
                        continue
                    }
                }
                if (-not $seenOids.Add($oid)) { continue }
                if ([string]::IsNullOrWhiteSpace($memberDisplayName)) {
                    Write-Warning ("Role group '{0}': a member's displayName was blank during export; exporting the raw object ID instead (legacy-but-supported shape). Reference: docs/adr/0023-identifier-resolution.md." -f $rg.Name)
                    $memberEntries.Add(@{ Shape = 'oid'; Value = $oid })
                }
                else {
                    $memberEntries.Add(@{ Shape = 'displayName'; Value = $memberDisplayName })
                }
            }
            $userCount = @($members | Where-Object { $_.RecipientTypeDetails -notin @('MailNonUniversalGroup', 'MailUniversalSecurityGroup') }).Count
            $entry = @{
                name        = [string]$rg.Name
                description = "Exported from $TenantDomain on $exportStamp."
                members     = @($memberEntries)
                userCount   = [int]$userCount
                groupCount  = [int]$memberEntries.Count
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
                    foreach ($member in $entry.members) {
                        if ($member.Shape -eq 'displayName') {
                            $escapedName = ([string]$member.Value).Replace('\', '\\').Replace('"', '\"')
                            $newBlock.Add('      - displayName: "' + $escapedName + '"')
                        }
                        else {
                            $newBlock.Add(("      - {0}" -f $member.Value))
                        }
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
    # Issue #61 F6: role groups whose CURRENT membership could not be read
    # (Get-RoleGroupMember threw -- e.g. an orphaned member whose backing
    # principal was deleted). Collected here so one unreadable group no longer
    # aborts the whole reconcile; the aggregate throw after the write phase
    # still exits the run non-zero once every group has been tried.
    $readFailures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rg in $desiredRoleGroups) {
        $rgName = [string]$rg.name
        # Normalize `members:` to a flat objectId array (ADR 0023 Category
        # 3, issue #95): a raw OID string is used as-is; a
        # `{ displayName: }` entry is resolved now via
        # Get-EntraPrincipalIdByDisplayName.ps1, which itself fails closed
        # on not-found/ambiguous. A resolution failure here aborts the
        # WHOLE run (return, before any write) -- it never degrades into
        # an empty $desiredMembers that -PruneMissing would read as
        # "revoke every real member of this role group".
        $desiredMembers = @()
        if ($rg.ContainsKey('members') -and $rg.members) {
            try {
                $desiredMembers = Resolve-DesiredRoleGroupMemberIds -Members @($rg.members) -Resolver {
                    param($displayName)
                    & $resolvePrincipalScript -DisplayName $displayName -Kind 'Group'
                }
            }
            catch {
                Write-Error ("Failed to resolve declared member(s) for role group '{0}': {1}" -f $rgName, $_.Exception.Message)
                return
            }
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
        try {
            $tenantMembers = @(Get-RoleGroupMember -Identity $rgName -ResultSize Unlimited -ErrorAction Stop)
        }
        catch {
            # Issue #61 F6: collect-and-continue on the READ leg, mirroring the
            # Phase 3 bind/revoke catches. A single orphaned/unresolvable member
            # (e.g. a role-group member whose backing principal was deleted --
            # it surfaces with an identity of "<tenantId>\") makes
            # Get-RoleGroupMember throw for that ONE role group; under
            # $ErrorActionPreference='stop' the old `Write-Error; return` aborted
            # the ENTIRE reconcile on the first such group. Report via
            # Write-PruneFailure (Write-Warning + '::error::', never Write-Error,
            # so it does not terminate the loop), record the role group, skip it
            # (no plan row is added, so the write phase never touches it), and
            # keep reading the rest. The aggregate throw after the write phase
            # still fails the run non-zero once every group has been tried.
            $report.Add([pscustomobject]@{
                Category  = 'Failed'
                Kind      = 'RoleGroupMember'
                Name      = ("{0} :: <members>" -f $rgName)
                Reason    = ('Get-RoleGroupMember read failed; role group skipped: {0}' -f $_.Exception.Message)
                RoleGroup = $rgName
            })
            Write-PruneFailure ("Get-RoleGroupMember -Identity '{0}' failed: {1}. Role group skipped (unreadable current membership); verify the name is exactly correct (case-sensitive), the workload SP holds 'View-Only Recipients', and the role group has no orphaned members." -f $rgName, $_.Exception.Message)
            $readFailures.Add($rgName)
            continue
        }

        # Read-phase diagnostic: the '#401' reference this comment
        # previously carried was a dead issue number (never existed in
        # this repo or upstream). The real, confirmed root cause was
        # issue #57 -- the `RecipientTypeDetails -eq 'Group'` filter
        # below never matched any real Entra group, so $tenantGroupOids
        # was always empty, which broke both Revoke detection (empty
        # $desiredSet ∩ empty $tenantSet = no plan row) and Create
        # accounting (everything reported as Create then downgraded to
        # NoChange via MemberAlreadyExistsException). Fixed per issue #57;
        # this raw-row dump remains useful for diagnosing any future
        # classification drift. Visible with -Verbose or
        # ACTIONS_STEP_DEBUG=true in CI.
        Write-Verbose ("[read] '{0}': Get-RoleGroupMember returned {1} raw member(s)." -f $rgName, $tenantMembers.Count)
        foreach ($m in $tenantMembers) {
            Write-Verbose ("[read] '{0}': member Name='{1}' RecipientTypeDetails='{2}' ExternalDirectoryObjectId='{3}'" -f $rgName, $m.Name, $m.RecipientTypeDetails, $m.ExternalDirectoryObjectId)
        }

        # Match domain: only tenant members that are Entra security
        # groups. Anything else (users, on-prem recipients) is ignored on
        # read and never written.
        #
        # Issue #57: `RecipientTypeDetails -eq 'Group'` is not a real
        # value in Microsoft's documented enum (Get-Recipient /
        # Get-RoleGroupMember) under any auth mode -- the documented
        # values are 'MailNonUniversalGroup' and
        # 'MailUniversalSecurityGroup'. This filter has never matched a
        # real Entra group, permanently defeating idempotency. Also,
        # `ExternalDirectoryObjectId` is empirically blank for
        # `MailNonUniversalGroup` rows and its population rules are not
        # documented for Get-RoleGroupMember output, so it cannot be
        # trusted directly: fall back to the same displayName-resolution
        # helper used for desired members above (only when
        # ExternalDirectoryObjectId is genuinely populated do we skip the
        # extra Graph round-trip).
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-recipient?view=exchange-ps
        $tenantGroupMemberRows = @($tenantMembers | Where-Object { $_.RecipientTypeDetails -in @('MailNonUniversalGroup', 'MailUniversalSecurityGroup') })
        $tenantOidSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($gm in $tenantGroupMemberRows) {
            $gmOid = [string]$gm.ExternalDirectoryObjectId
            if ([string]::IsNullOrWhiteSpace($gmOid)) {
                $gmDisplayName = [string]$gm.Name
                if ([string]::IsNullOrWhiteSpace($gmDisplayName)) {
                    Write-Warning ("[read] '{0}': a tenant group member had both a blank ExternalDirectoryObjectId and a blank Name; cannot resolve, skipping." -f $rgName)
                    continue
                }
                try {
                    $gmOid = & $resolvePrincipalScript -DisplayName $gmDisplayName -Kind 'Group'
                }
                catch {
                    Write-Error ("Failed to resolve tenant role-group member '{0}' (role group '{1}') to an Entra group objectId: {2}" -f $gmDisplayName, $rgName, $_.Exception.Message)
                    return
                }
            }
            [void]$tenantOidSet.Add($gmOid)
        }
        $tenantGroupOids = @($tenantOidSet)
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
    $pruneFailures = New-Object 'System.Collections.Generic.List[string]'
    # Issue #61: Add (bind) failures are collected and continued exactly like
    # revoke failures below, rather than aborting the run on the first one. A
    # single non-bindable role group (e.g. an Exchange RBAC role-assignment
    # policy such as `DefaultRoleAssignmentPolicy`, which rejects
    # Add-RoleGroupMember with `EntityValidation CheckIsUserRole`) must not
    # prevent every other declared bind from being attempted. The aggregate
    # throw after the Phase 3 loop names every failed add + revoke, so the run
    # still exits non-zero, but only after every plan row has been tried.
    $addFailures = New-Object 'System.Collections.Generic.List[string]'

    # Issue #13: in-loop revoke failures are reported via Write-PruneFailure
    # (scripts/modules/PruneGuard.psm1), which uses Write-Warning plus an
    # '::error::' workflow command rather than Write-Error. The revoke catch
    # previously did Write-Error + return, which under shell: pwsh's
    # $ErrorActionPreference='stop' terminated the run on the first failed
    # revoke so the rest were never attempted. The aggregate `throw` after the
    # Phase 3 loop -- inside the enclosing try, so the finally still
    # disconnects the IPPS session -- is the terminal outcome, so a failed
    # prune still exits non-zero. Principal object IDs are never named (the
    # '<oid>' redaction the drift report already uses): the reporter names the
    # role group plus the tenant's own error text only. The issue #13 ratio
    # guard (guard 2) is deliberately NOT wired here: role-group membership
    # churn is legitimately high-ratio and this reconciler does not capture a
    # single live-member denominator (owner decision), so only guard 1 and
    # this reporter protect the revoke path.
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
                    # Issue #65 F5: the immediate post-Add read routinely misses the new
                    # member to S&C replication lag (proven benign on #61 -- every such
                    # warning cleared on a later -WhatIf). Wait-RoleGroupMemberVisible
                    # retries a few times with a short backoff, so the warning below now
                    # fires only after genuine non-persistence, not on the first lagging
                    # read.
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
                    $verifyReader = { Get-RoleGroupMember -Identity $rgName -ResultSize Unlimited -ErrorAction Stop }
                    if (Wait-RoleGroupMemberVisible -Reader $verifyReader -Oid $oid) {
                        Write-Verbose ("[verify-add] '{0}': post-Add read confirmed member present." -f $rgName)
                    }
                    else {
                        Write-Warning ("[verify-add] '{0}': Add returned success but post-Add read did NOT see the member after retries. Possible silent non-persistence." -f $rgName)
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
                    # Issue #61: collect-and-continue (same shape as the revoke
                    # catch below) instead of Write-Error + return. Report via
                    # Write-PruneFailure (Write-Warning + '::error::', never
                    # Write-Error, so shell: pwsh's $ErrorActionPreference='stop'
                    # does not terminate the loop), record the role group, and
                    # keep binding the rest. The aggregate throw at the end of
                    # Phase 3 fails the run non-zero once every row is tried.
                    $reportRow.Category = 'Failed'
                    $reportRow.Reason   = ('Add failed: {0}' -f $_.Exception.Message)
                    Write-PruneFailure ("Add-RoleGroupMember -Identity '{0}' failed: {1}" -f $rgName, $_.Exception.Message)
                    $addFailures.Add(("{0} :: <oid>" -f $rgName))
                    continue
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
                    $reportRow.Category = 'Failed'
                    $reportRow.Reason   = ('Revoke failed: {0}' -f $_.Exception.Message)
                    Write-PruneFailure ("Remove-RoleGroupMember -Identity '{0}' failed: {1}" -f $rgName, $_.Exception.Message)
                    $pruneFailures.Add(("{0} :: <oid>" -f $rgName))
                    continue
                }
            }
        }
    }

    # Issue #61: one aggregate throw covering read (F6), add, and revoke
    # failures, so a failed member read, bind, or revoke still exits the run
    # non-zero -- but only after every role group has been tried, never on the
    # first failure.
    if ($readFailures.Count -gt 0 -or $addFailures.Count -gt 0 -or $pruneFailures.Count -gt 0) {
        $parts = @()
        if ($readFailures.Count -gt 0) {
            $parts += ('{0} role-group member read(s) failed: {1}' -f $readFailures.Count, ($readFailures -join ', '))
        }
        if ($addFailures.Count -gt 0) {
            $parts += ('{0} role-group member add(s) failed: {1}' -f $addFailures.Count, ($addFailures -join ', '))
        }
        if ($pruneFailures.Count -gt 0) {
            $parts += ('{0} role-group member revoke(s) failed: {1}' -f $pruneFailures.Count, ($pruneFailures -join ', '))
        }
        throw ("Reconciliation completed with failures: {0}. See errors above." -f ($parts -join '; '))
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
