<#
.SYNOPSIS
    Provision and reconcile Microsoft Entra security groups that back each
    Microsoft Purview / Microsoft 365 portal role group declared in
    data-plane/purview-role-groups/role-groups.yaml.

.DESCRIPTION
    Implements the naming and lifecycle contract ratified by
    docs/adr/0025-role-group-entra-backing-naming.md:

      1. Read every roleGroups[].name from the desired-state YAML.
      2. For each entry, derive the backing-group display name
         'sg-purview-<slug>' where <slug> is the kebab-case form of the
         role-group name (dash before each interior capital letter, then
         ToLower()).
      3. GET existing Entra groups whose displayName starts with
         'sg-purview-' from Microsoft Graph v1.0.
      4. Diff desired against current and emit a categorized drift report
         per .github/instructions/powershell.instructions.md:
            Create   -- desired; not in tenant.
            NoChange -- present and matches.
            Update   -- present; description drift.
            Orphan   -- present in tenant; not declared in YAML.
            Conflict -- present but mailEnabled/securityEnabled/groupTypes mismatch.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing / -Force).

    Membership of the backing groups is intentionally out of scope.
    Member reconciliation against the portal role group itself is handled
    by scripts/Deploy-PurviewRoleGroups.ps1 once the OIDs land in
    role-groups.yaml (Phase 2 PR, follow-up to issue #383).

    References:
      https://learn.microsoft.com/en-us/graph/api/group-list
      https://learn.microsoft.com/en-us/graph/api/group-post-groups
      https://learn.microsoft.com/en-us/graph/api/group-update
      https://learn.microsoft.com/en-us/graph/api/group-delete
      https://learn.microsoft.com/en-us/graph/api/resources/group
      https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions
      https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions
      https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location.

.PARAMETER OwnerObjectId
    Entra object ID of the human or workload-identity co-owner added to
    each backing group on Create. The automation identity that runs this
    script is added as the second owner by the Graph create call's
    implicit ownership behaviour. Required for -Apply runs (Create); not
    required for -WhatIf.

.PARAMETER PruneMissing
    Delete backing groups that exist in the tenant but are not declared
    in the YAML. Default: $false. Must be explicit per the drift-report
    contract. Destructive; subject to the destructive-change rule in
    .github/instructions/pre-commit.instructions.md.

    Two issue #13 guards stand in front of this switch, both implemented
    in `scripts/modules/PruneGuard.psm1`:

      * The desired-state set must be non-empty. A prune against
        `roleGroups: []` would classify every live sg-purview-* group
        as orphaned and revoke every permission they confer.
      * The prune must not exceed `-MaxPruneRatio` of the live
        sg-purview-* groups without `-AllowMajorityPrune`.

    Both refuse before the tenant is written to.

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would delete more than `-MaxPruneRatio` of
    the live sg-purview-* backing groups is refused before any write.
    Supply it when a large prune is genuinely intended (a deliberate
    consolidation); the ratio is then reported as a warning and the run
    proceeds. Has no effect on the empty-desired-set guard, which cannot
    be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the live sg-purview-* backing groups
    `-PruneMissing` may delete without `-AllowMajorityPrune`, as a
    fraction in (0, 1]. Default 0.5. A prune exactly at the threshold
    passes; only a strictly larger share is refused. Set to 1 to disable
    the ratio guard for a single run.

.PARAMETER Force
    Overwrite a tenant group whose securityEnabled / mailEnabled /
    groupTypes do not match the contract (Conflict rows). Default:
    $false. Must be explicit per the drift-report contract.

.PARAMETER ExportCurrentState
    Query Microsoft Graph for every Entra security group whose
    `displayName` starts with `sg-purview-` and emit a structured
    inventory (`RoleGroupName`, `DisplayName`, `ObjectId`,
    `Description`, `Status`) joined against the desired-state YAML. No
    write is performed. Satisfies the full-circle reconciler contract
    (issue #292, ratified by ADR 0025) so the Phase 2 OID-rebind PR can
    pipe the inventory to a sidecar mapping file. Mutually exclusive
    with -OwnerObjectId / -PruneMissing / -Force.

.EXAMPLE
    ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -WhatIf
    Runs the drift report without making any change.

.EXAMPLE
    ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -OwnerObjectId 00000000-0000-0000-0000-000000000000
    Creates and updates backing groups to match the YAML; leaves orphans
    untouched.

.EXAMPLE
    ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -OwnerObjectId 00000000-0000-0000-0000-000000000000 -PruneMissing
    Same as above, plus deletes tenant sg-purview-* groups not in the
    YAML.

.EXAMPLE
    ./scripts/Deploy-RoleGroupBackingEntraGroups.ps1 -ExportCurrentState
    Emits the live sg-purview-* inventory joined against role-groups.yaml.
    Used by the Phase 2 OID-rebind PR; never mutates tenant or repo state.

.NOTES
    Owner ADR: docs/adr/0025-role-group-entra-backing-naming.md
    Microsoft Graph permissions required (application or delegated):
      Group.ReadWrite.All
    Reference: https://learn.microsoft.com/en-us/graph/permissions-reference#group-permissions
#>
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(DefaultParameterSetName = 'Apply', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\purview-role-groups\role-groups.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$OwnerObjectId,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$AllowMajorityPrune,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0.0000001, 1.0)]
    [double]$MaxPruneRatio = 0.5,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants from docs/adr/0025-role-group-entra-backing-naming.md.
# ---------------------------------------------------------------------------
$script:NamePrefix       = 'sg-purview-'
$script:DescriptionShape = "Backs the Microsoft Purview portal role group '{0}'. Managed by scripts/Deploy-RoleGroupBackingEntraGroups.ps1. See docs/adr/0025-role-group-entra-backing-naming.md."

# ---------------------------------------------------------------------------
# Module dependency: powershell-yaml
# Reference: https://www.powershellgallery.com/packages/powershell-yaml
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information "Installing powershell-yaml module to CurrentUser scope." -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the -PruneMissing delete branch cannot be
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

# ---------------------------------------------------------------------------
# Acquire a Microsoft Graph access token via Azure CLI.
# Works with OIDC federated login in GitHub Actions and with `az login` locally.
# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
# ---------------------------------------------------------------------------
function Get-GraphToken {
    $raw = az account get-access-token --resource 'https://graph.microsoft.com' --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire Microsoft Graph token. Run 'az login' or configure OIDC federated credentials."
    }
    return ($raw | ConvertFrom-Json).accessToken
}

# ---------------------------------------------------------------------------
# Derive the backing-group display name from a role-group name.
# Contract (ADR 0025): kebab-case conversion that preserves acronyms.
# Insert '-' before any uppercase letter preceded by a lower-case/digit, or
# before any uppercase letter that begins a word inside a run of capitals
# (uppercase preceded by uppercase AND followed by lower-case). Then lower
# the whole thing and prefix with 'sg-purview-'.
#   ComplianceAdministrator                -> sg-purview-compliance-administrator
#   CommunicationComplianceAdministrators  -> sg-purview-communication-compliance-administrators
#   eDiscoveryManager                      -> sg-purview-e-discovery-manager
#   DataSecurityAIAdmins                   -> sg-purview-data-security-ai-admins
#   IRMContributors                        -> sg-purview-irm-contributors
# ---------------------------------------------------------------------------
function ConvertTo-BackingGroupSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RoleGroupName
    )
    $slug = [regex]::Replace($RoleGroupName, '(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', '-').ToLowerInvariant()
    return ($script:NamePrefix + $slug)
}

# ---------------------------------------------------------------------------
# Load desired state.
#
# Deliberately ordered BEFORE the Graph token acquisition below (issue #13):
# the empty-desired-set guard needs the projected count, and the guard must
# refuse a destructive run before the tenant is contacted at all. Nothing in
# this block depends on $token / $headers, and ConvertTo-BackingGroupSlug is
# defined above, so the move is behaviour-preserving.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) {
    throw "Desired-state YAML not found at $Path."
}
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
$roleGroups = @()
if ($desiredRoot -and $desiredRoot.roleGroups) {
    $roleGroups = @($desiredRoot.roleGroups)
}

$desired = foreach ($rg in $roleGroups) {
    if (-not $rg.name) { continue }
    [pscustomobject]@{
        RoleGroupName = [string]$rg.name
        DisplayName   = (ConvertTo-BackingGroupSlug -RoleGroupName ([string]$rg.name))
        Description   = ($script:DescriptionShape -f [string]$rg.name)
    }
}

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# The orphan match below compares live sg-purview-* groups against $desired --
# the PROJECTION of roleGroups, which drops nameless entries -- so $desired is
# the set the guard must key on, not the raw $roleGroups. It is an unrolled
# pipeline result, hence the @() before .Count.
#
# With zero desired entries every live backing security group falls out of that
# match and the run would delete all of them, revoking every permission they
# conferred. The rationale, the likely causes, and the 2026-07-19 production hit
# are documented in scripts/modules/PruneGuard.psm1.
#
# -ExportCurrentState returns before the prune branch is ever reached, so it is
# excluded here rather than refused. Placed above the Graph token acquisition so
# the guard fires before the tenant is contacted at all.
if ($PruneMissing.IsPresent -and -not $ExportCurrentState.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   @($desired).Count `
        -ObjectTypeNoun 'backing Entra security group' `
        -SourcePath     $Path `
        -CollectionKey  'roleGroups'
}

$graphBase = 'https://graph.microsoft.com/v1.0'
$token     = Get-GraphToken
$headers   = @{
    Authorization   = "Bearer $token"
    'Content-Type'  = 'application/json'
}

# ---------------------------------------------------------------------------
# Fetch current state.
# Filter to displayName startswith 'sg-purview-' so we only see groups this
# script owns.
# Reference: https://learn.microsoft.com/en-us/graph/api/group-list
# Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter
# ---------------------------------------------------------------------------
$filter = "startswith(displayName,'$script:NamePrefix')"
$select = 'id,displayName,description,mailEnabled,securityEnabled,groupTypes,mailNickname'
$uri = "$graphBase/groups?`$select=$select&`$filter=$([uri]::EscapeDataString($filter))"
$current = @()
$next = $uri
while ($next) {
    $response = Invoke-RestMethod -Method Get -Uri $next -Headers $headers
    $current += @($response.value)
    $next = $response.'@odata.nextLink'
}

# ---------------------------------------------------------------------------
# Drift calculation.
# Categories per .github/instructions/powershell.instructions.md.
# ---------------------------------------------------------------------------

if ($ExportCurrentState.IsPresent) {
    # -------------------------------------------------------------------
    # ExportCurrentState: emit the live sg-purview-* inventory joined
    # against the desired-state YAML. No tenant or repo writes. Satisfies
    # the full-circle reconciler contract (issue #292) so the Phase 2
    # OID-rebind PR can consume a deterministic mapping.
    # Reference: https://learn.microsoft.com/en-us/graph/api/group-list
    # -------------------------------------------------------------------
    if ($WhatIfPreference) {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls beyond list):' -InformationAction Continue
        Write-Information ('  GET {0}/groups?$filter=startswith(displayName,''{1}'') and join against {2}.' -f $graphBase, $script:NamePrefix, $Path) -InformationAction Continue
        return
    }
    $desiredByName = @{}
    foreach ($d in $desired) { $desiredByName[$d.DisplayName] = $d.RoleGroupName }
    $inventory = foreach ($c in $current) {
        $isTracked = $desiredByName.ContainsKey($c.displayName)
        [pscustomobject]@{
            RoleGroupName = if ($isTracked) { $desiredByName[$c.displayName] } else { $null }
            DisplayName   = $c.displayName
            ObjectId      = $c.id
            Description   = $c.description
            Status        = if ($isTracked) { 'Tracked' } else { 'Orphan' }
        }
    }
    $trackedCount = @($inventory | Where-Object Status -EQ 'Tracked').Count
    $orphanCount  = @($inventory | Where-Object Status -EQ 'Orphan').Count
    Write-Information ("Exported {0} sg-purview-* group(s) from tenant ({1} tracked, {2} orphan)." -f $inventory.Count, $trackedCount, $orphanCount) -InformationAction Continue
    return $inventory
}

$report = New-Object 'System.Collections.Generic.List[object]'

foreach ($d in $desired) {
    $match = $current | Where-Object { $_.displayName -eq $d.DisplayName } | Select-Object -First 1
    if (-not $match) {
        $report.Add([pscustomobject]@{
            Category      = 'Create'
            Kind          = 'EntraSecurityGroup'
            Name          = $d.DisplayName
            RoleGroupName = $d.RoleGroupName
            ObjectId      = $null
            Reason        = 'Declared in YAML; not present in tenant.'
        })
        continue
    }

    $shapeMatches = ($match.securityEnabled -eq $true) -and
                    ($match.mailEnabled -eq $false) -and
                    ((-not $match.groupTypes) -or ($match.groupTypes.Count -eq 0))
    if (-not $shapeMatches) {
        $report.Add([pscustomobject]@{
            Category      = 'Conflict'
            Kind          = 'EntraSecurityGroup'
            Name          = $d.DisplayName
            RoleGroupName = $d.RoleGroupName
            ObjectId      = $match.id
            Reason        = "Tenant group is not a pure security group (securityEnabled=$($match.securityEnabled), mailEnabled=$($match.mailEnabled), groupTypes=$($match.groupTypes -join ',')). Overwrite only with -Force."
        })
        continue
    }

    $currentDescription = if ($null -eq $match.description) { '' } else { ([string]$match.description).TrimEnd() }
    $desiredDescription = $d.Description.TrimEnd()
    if ($currentDescription -ne $desiredDescription) {
        $report.Add([pscustomobject]@{
            Category      = 'Update'
            Kind          = 'EntraSecurityGroup'
            Name          = $d.DisplayName
            RoleGroupName = $d.RoleGroupName
            ObjectId      = $match.id
            Reason        = 'description differs from ADR 0025 contract.'
        })
    }
    else {
        $report.Add([pscustomobject]@{
            Category      = 'NoChange'
            Kind          = 'EntraSecurityGroup'
            Name          = $d.DisplayName
            RoleGroupName = $d.RoleGroupName
            ObjectId      = $match.id
            Reason        = 'Tenant state matches YAML + ADR 0025.'
        })
    }
}

$desiredNames = @($desired | ForEach-Object { $_.DisplayName })
foreach ($c in $current) {
    if ($desiredNames -notcontains $c.displayName) {
        $report.Add([pscustomobject]@{
            Category      = 'Orphan'
            Kind          = 'EntraSecurityGroup'
            Name          = $c.displayName
            RoleGroupName = $null
            ObjectId      = $c.id
            Reason        = "Present in tenant; not declared in YAML. Delete only with -PruneMissing."
        })
    }
}

# Emit the drift report.
$report | Sort-Object Category, Name | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

# ---- Issue #13, guard 2: prune sanity ratio ----
# Guard 1 (desired-state load region) catches only the total wipe. This
# catches the near-total one: a role-groups.yaml that lost most of its
# entries to a bad merge, or a -Path pointing at a smaller environment's
# file, both of which leave a non-zero desired count and so clear guard 1.
# The stakes here are the ADR 0052 gate's own warning: deleting a backing
# group revokes every permission it conferred, tenant-wide.
#
# Keyed on the ORPHAN rows this run would actually delete against the live
# sg-purview-* group count. Fires before the ADR 0052 gate and before the
# write loop: the last point at which nothing has been written. This script
# is Class B with no -DirectionPolicy, so there is no audit mode to gate on;
# -ExportCurrentState returned above and never reaches this guard.
# Reference: scripts/modules/PruneGuard.psm1
$orphans = @($report | Where-Object { $_.Category -eq 'Orphan' })
if ($PruneMissing.IsPresent) {
    Assert-PruneRatioWithinThreshold `
        -PruneCount     $orphans.Count `
        -LiveCount      @($current).Count `
        -ObjectTypeNoun 'backing Entra security group' `
        -MaxPruneRatio  $MaxPruneRatio `
        -Allow:$AllowMajorityPrune
}

# ---- ADR 0052: destructive-operation confirmation gate ----
# The last point before the write loop at which nothing has been written.
# This script is Class B: it declares no -DirectionPolicy, so it has no
# repo-wins overwrite branch and exactly ONE destructive branch -- the
# -PruneMissing delete. That branch is gated here, once per run, via
# $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
# unconditionally; ShouldProcess only prompts when ConfirmImpact >=
# $ConfirmPreference, which is precisely the comparison that silently
# defeated this gate before issue #85.
#
# The gate is keyed on the PLAN -- the orphan rows the delete loop below
# actually iterates -- and never on a policy. $orphans is derived from
# $report here and read one line later, so it cannot diverge from the
# writes it speaks for.
#
# The query says DELETE, not REVOKE, deliberately: the Orphan branch below
# issues DELETE /groups/{id}, destroying the Entra security-group OBJECT.
# That is strictly worse than revoking a permission -- the group's Purview
# role-group membership, and every other grant it carried anywhere in the
# tenant, goes with it, and the object cannot be restored with the same
# object ID. The operator is told so.
#
# Suppressed by -Force, by an explicit -Confirm:$false (the CI path), and
# skipped under -WhatIf so a dry run still previews the deletes without
# blocking on input.
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

if ($PruneMissing.IsPresent -and $orphans.Count -gt 0) {
    $orphanNames = @($orphans | ForEach-Object { [string]$_.Name })
    $pruneQuery = "-PruneMissing will DELETE {0} orphan Entra security group(s) that back Purview role groups: {1}. Deleting the group revokes every permission it conferred, and this cannot be undone. Continue?" -f `
        $orphanNames.Count, (($orphanNames | Sort-Object) -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# ---------------------------------------------------------------------------
# Act on the report.
# ---------------------------------------------------------------------------
$pruneFailures = New-Object 'System.Collections.Generic.List[string]'

# Issue #13: in-loop prune failures are reported via Write-PruneFailure
# (scripts/modules/PruneGuard.psm1), which uses Write-Warning plus an
# '::error::' workflow command rather than Write-Error. This script runs with
# $ErrorActionPreference = 'Stop', so an unhandled delete failure would
# terminate the loop on the first orphan and the rest would never be
# attempted. The aggregate `throw` below remains the terminal outcome, so a
# failed prune still exits non-zero.

foreach ($row in $report) {
    switch ($row.Category) {
        'Create' {
            if (-not $OwnerObjectId -and -not $WhatIfPreference) {
                throw "Create action requires -OwnerObjectId for the lab-owner co-owner. See docs/adr/0025-role-group-entra-backing-naming.md."
            }
            $desiredItem = $desired | Where-Object { $_.DisplayName -eq $row.Name } | Select-Object -First 1
            $bodyHash = @{
                displayName     = $desiredItem.DisplayName
                description     = $desiredItem.Description
                mailEnabled     = $false
                mailNickname    = $desiredItem.DisplayName
                securityEnabled = $true
            }
            if ($OwnerObjectId) {
                $bodyHash['owners@odata.bind'] = @("https://graph.microsoft.com/v1.0/directoryObjects/$OwnerObjectId")
            }
            $body = $bodyHash | ConvertTo-Json -Depth 5
            if ($PSCmdlet.ShouldProcess("Entra security group '$($row.Name)'", 'Create')) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/group-post-groups
                $created = Invoke-RestMethod -Method Post -Uri "$graphBase/groups" -Headers $headers -Body $body
                Write-Information "Created Entra security group '$($created.displayName)' (id=$($created.id)) backing role group '$($desiredItem.RoleGroupName)'." -InformationAction Continue
            }
        }
        'Update' {
            $desiredItem = $desired | Where-Object { $_.DisplayName -eq $row.Name } | Select-Object -First 1
            $body = @{
                description = $desiredItem.Description
            } | ConvertTo-Json -Depth 5
            if ($PSCmdlet.ShouldProcess("Entra security group '$($row.Name)'", 'Update description')) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/group-update
                Invoke-RestMethod -Method Patch -Uri "$graphBase/groups/$($row.ObjectId)" -Headers $headers -Body $body | Out-Null
                Write-Information "Updated Entra security group '$($row.Name)' description." -InformationAction Continue
            }
        }
        'Orphan' {
            if (-not $PruneMissing) {
                Write-Information "Skipping orphan Entra security group '$($row.Name)' (use -PruneMissing to delete)." -InformationAction Continue
                continue
            }
            if ($PSCmdlet.ShouldProcess("Entra security group '$($row.Name)'", 'Delete')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/graph/api/group-delete
                    Invoke-RestMethod -Method Delete -Uri "$graphBase/groups/$($row.ObjectId)" -Headers $headers | Out-Null
                    Write-Information "Deleted orphan Entra security group '$($row.Name)'." -InformationAction Continue
                } catch {
                    Write-PruneFailure ("Delete of orphan Entra security group '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
                    $pruneFailures.Add([string]$row.Name)
                    continue
                }
            }
        }
        'Conflict' {
            if (-not $Force) {
                Write-Information "Skipping conflict Entra security group '$($row.Name)' (use -Force to overwrite shape; review ADR 0025 first)." -InformationAction Continue
                continue
            }
            # Conflict overwrite is intentionally not auto-implemented: changing
            # securityEnabled/mailEnabled on an existing group requires delete +
            # recreate per Microsoft Graph. Force only logs intent so the lab
            # owner can intervene manually.
            Write-Information "Conflict overwrite for '$($row.Name)' is manual: delete the group in Entra and re-run without -Force. ADR 0025." -InformationAction Continue
        }
        default {
            # NoChange - nothing to do.
        }
    }
}

if ($pruneFailures.Count -gt 0) {
    throw ("Reconciliation aborted: {0} orphan backing Entra security group(s) could not be deleted: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
}

# Return the report for pipeline capture.
return $report
