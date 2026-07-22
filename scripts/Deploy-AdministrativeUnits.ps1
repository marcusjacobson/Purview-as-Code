<#
.SYNOPSIS
    Reconcile Microsoft Entra administrative units with data-plane/administrative-units/administrative-units.yaml.

.DESCRIPTION
    Idempotent deploy for the Entra administrative-units plane referenced by
    ADR 0002. Follows the drift-report contract in
    .github/instructions/powershell.instructions.md:

      1. GET existing AUs from Microsoft Graph.
      2. Diff against desired state in the YAML file.
      3. Emit a categorized drift report: Create, Update, NoChange, Orphan, Conflict.
      4. Act only on categories the caller has authorized via -WhatIf / -PruneMissing / -Force.

    Member reconciliation is intentionally out of scope for this script. The
    YAML carries `members: []` only; if a future ADR adds membership
    management, it lands in a separate script or a dedicated switch here and
    supersedes ADR 0002.

    References:
      https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit
      https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits
      https://learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits
      https://learn.microsoft.com/en-us/graph/api/administrativeunit-update
      https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete
      https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER Path
    Path to the desired-state YAML file. Defaults to the in-repo location.

.PARAMETER PruneMissing
    Delete AUs that exist in the tenant but are not declared in the YAML.
    Default: $false. Must be explicit per the drift-report contract.

    Two issue #13 guards stand in front of this switch, both implemented
    in `scripts/modules/PruneGuard.psm1`:

      * The desired-state set must be non-empty. A prune against
        `administrativeUnits: []` would classify the entire live set as
        orphaned.
      * The prune must not exceed `-MaxPruneRatio` of the live
        administrative units without `-AllowMajorityPrune`.

    Both refuse before the tenant is written to.

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would delete more than `-MaxPruneRatio` of
    the live administrative units is refused before any write. Supply it
    when a large prune is genuinely intended (a deliberate
    consolidation); the ratio is then reported as a warning and the run
    proceeds. Has no effect on the empty-desired-set guard, which cannot
    be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the live administrative units `-PruneMissing` may
    delete without `-AllowMajorityPrune`, as a fraction in (0, 1].
    Default 0.5. A prune exactly at the threshold passes; only a
    strictly larger share is refused. Set to 1 to disable the ratio
    guard for a single run.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for (ADR 0052 section 6).
    Default: $false. Must be explicit per the drift-report contract.

    `-Force` does NOT mean "overwrite AUs whose `lastModifiedBy` is not the
    current principal." That is what this help block used to promise, and it
    was never true: Microsoft Graph exposes no per-administrative-unit
    authorship field, nothing in this script ever emits a `Conflict` row, and
    the `'Conflict'` apply case below is therefore unreachable. ADR 0053 gives
    the authorship override its own switch (`-OverwriteForeignAuthor`) and
    scopes it to the six Atlas / Data Map REST reconcilers that can actually
    diff an authorship field. This script is not one of them and does not get
    that switch. The dead `'Conflict'` handler is retained, unarmed, and is
    tracked as a follow-up.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.EXAMPLE
    ./scripts/Deploy-AdministrativeUnits.ps1 -WhatIf
    Runs the drift report without making any change.

.EXAMPLE
    ./scripts/Deploy-AdministrativeUnits.ps1
    Creates and updates AUs to match the YAML; leaves orphans untouched.

.EXAMPLE
    ./scripts/Deploy-AdministrativeUnits.ps1 -PruneMissing
    Same as above, plus deletes tenant AUs not in the YAML.

.NOTES
    Owner ADR: docs/adr/0002-administrative-units.md
    Graph permissions required (delegated): AdministrativeUnit.ReadWrite.All, plus
    the caller must hold an Entra role that can create AUs (Privileged Role
    Administrator or Global Administrator). Reference:
      https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units#license-requirements
#>
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\administrative-units\administrative-units.yaml'),

    [switch]$PruneMissing,

    [switch]$AllowMajorityPrune,

    [ValidateRange(0.0000001, 1.0)]
    [double]$MaxPruneRatio = 0.5,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

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
        throw "Failed to acquire Microsoft Graph token. Run 'az login' or configure OIDC."
    }
    return ($raw | ConvertFrom-Json).accessToken
}

function Get-SignedInPrincipalId {
    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/signed-in-user
    $raw = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) {
        # Fall back to the client ID of the workload identity (GitHub Actions OIDC).
        $raw = az account show --query 'user.name' -o tsv
    }
    return $raw.Trim()
}

# ---------------------------------------------------------------------------
# Load desired state.
#
# Deliberately ordered BEFORE the Graph token acquisition below (issue #13):
# the empty-desired-set guard needs the parsed count, and the guard must refuse
# a destructive run before the tenant is contacted at all. Nothing in this
# block depends on $token / $headers, so the move is behaviour-preserving.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) {
    throw "Desired-state YAML not found at $Path."
}
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
$desired = @()
if ($desiredRoot -and $desiredRoot.administrativeUnits) {
    $desired = @($desiredRoot.administrativeUnits)
}

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# With zero desired entries every live administrative unit falls out of the
# orphan match below, so the run would classify the entire set as orphans and
# delete it. The rationale, the likely causes, and the 2026-07-19 production
# hit are documented in scripts/modules/PruneGuard.psm1.
#
# This script has no Export mode, so the prune switch alone selects the
# destructive branch. Placed above the Graph token acquisition so it fires
# before the tenant is contacted at all.
if ($PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   $desired.Count `
        -ObjectTypeNoun 'administrative unit' `
        -SourcePath     $Path `
        -CollectionKey  'administrativeUnits'
}

$graphBase = 'https://graph.microsoft.com/v1.0'
$token     = Get-GraphToken
$headers   = @{
    Authorization   = "Bearer $token"
    'Content-Type'  = 'application/json'
}
$currentPrincipal = Get-SignedInPrincipalId

# ---------------------------------------------------------------------------
# Fetch current state.
# Reference: https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits
# ---------------------------------------------------------------------------
$uri = "$graphBase/directory/administrativeUnits?`$select=id,displayName,description,visibility"
$currentResponse = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
$current = @($currentResponse.value)

# ---------------------------------------------------------------------------
# Drift calculation.
# Categories per .github/instructions/powershell.instructions.md:
#   Create, Update, NoChange, Orphan, Conflict
# ---------------------------------------------------------------------------
$report = New-Object 'System.Collections.Generic.List[object]'

foreach ($d in $desired) {
    $match = $current | Where-Object { $_.displayName -eq $d.displayName } | Select-Object -First 1
    if (-not $match) {
        $report.Add([pscustomobject]@{
            Category = 'Create'
            Kind     = 'AdministrativeUnit'
            Name     = $d.displayName
            Reason   = 'Declared in YAML; not present in tenant.'
        })
        continue
    }

    $desiredDescription = if ($null -eq $d.description) { '' } else { ([string]$d.description).TrimEnd() }
    $currentDescription = if ($null -eq $match.description) { '' } else { ([string]$match.description).TrimEnd() }
    $desiredVisibility  = if ($null -eq $d.visibility) { 'Public' } else { [string]$d.visibility }
    $currentVisibility  = if ($null -eq $match.visibility) { 'Public' } else { [string]$match.visibility }

    $differs = ($desiredDescription -ne $currentDescription) -or ($desiredVisibility -ne $currentVisibility)
    if ($differs) {
        $report.Add([pscustomobject]@{
            Category = 'Update'
            Kind     = 'AdministrativeUnit'
            Name     = $d.displayName
            Reason   = 'description or visibility differs from YAML.'
        })
    }
    else {
        $report.Add([pscustomobject]@{
            Category = 'NoChange'
            Kind     = 'AdministrativeUnit'
            Name     = $d.displayName
            Reason   = 'Tenant state matches YAML.'
        })
    }
}

$desiredNames = @($desired | ForEach-Object { $_.displayName })
foreach ($c in $current) {
    if ($desiredNames -notcontains $c.displayName) {
        $report.Add([pscustomobject]@{
            Category = 'Orphan'
            Kind     = 'AdministrativeUnit'
            Name     = $c.displayName
            Reason   = 'Present in tenant; not declared in YAML. Delete only with -PruneMissing.'
        })
    }
}

# Emit the drift report. Write-Information so callers can capture to files / step summaries.
$report | Sort-Object Category, Name | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

# ---- Issue #13, guard 2: prune sanity ratio ----
# Guard 1 (desired-state load region) catches only the total wipe. This
# catches the near-total one: an administrative-units.yaml that lost most of
# its entries to a bad merge, or a -Path pointing at a smaller environment's
# file, both of which leave a non-zero desired count and so clear guard 1.
#
# Keyed on the ORPHAN rows this run would actually delete against the live
# tenant AU count. Fires before the ADR 0052 gate and before the write loop:
# the last point at which nothing has been written. This script is Class B
# with no -DirectionPolicy, so there is no audit mode to gate on; -WhatIf
# still previews the plan because the guard only refuses when a prune is
# actually requested and oversized.
# Reference: scripts/modules/PruneGuard.psm1
$orphans = @($report | Where-Object { $_.Category -eq 'Orphan' })
if ($PruneMissing.IsPresent) {
    Assert-PruneRatioWithinThreshold `
        -PruneCount     $orphans.Count `
        -LiveCount      @($current).Count `
        -ObjectTypeNoun 'administrative unit' `
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
    $pruneQuery = "-PruneMissing will DELETE {0} orphan administrative unit(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
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
            $desiredItem = $desired | Where-Object { $_.displayName -eq $row.Name } | Select-Object -First 1
            $body = @{
                displayName = $desiredItem.displayName
                description = if ($null -ne $desiredItem.description) { [string]$desiredItem.description } else { $null }
                visibility  = if ($null -ne $desiredItem.visibility)  { [string]$desiredItem.visibility }  else { 'Public' }
            } | ConvertTo-Json -Depth 5
            if ($PSCmdlet.ShouldProcess("Administrative unit '$($row.Name)'", 'Create')) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits
                $created = Invoke-RestMethod -Method Post -Uri "$graphBase/directory/administrativeUnits" -Headers $headers -Body $body
                Write-Information "Created AU '$($created.displayName)' (id=$($created.id))." -InformationAction Continue
            }
        }
        'Update' {
            $desiredItem = $desired | Where-Object { $_.displayName -eq $row.Name } | Select-Object -First 1
            $match       = $current  | Where-Object { $_.displayName -eq $row.Name } | Select-Object -First 1
            $body = @{
                description = if ($null -ne $desiredItem.description) { [string]$desiredItem.description } else { '' }
                visibility  = if ($null -ne $desiredItem.visibility)  { [string]$desiredItem.visibility }  else { 'Public' }
            } | ConvertTo-Json -Depth 5
            if ($PSCmdlet.ShouldProcess("Administrative unit '$($row.Name)'", 'Update')) {
                # Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-update
                Invoke-RestMethod -Method Patch -Uri "$graphBase/directory/administrativeUnits/$($match.id)" -Headers $headers -Body $body | Out-Null
                Write-Information "Updated AU '$($row.Name)'." -InformationAction Continue
            }
        }
        'Orphan' {
            if (-not $PruneMissing) {
                Write-Information "Skipping orphan AU '$($row.Name)' (use -PruneMissing to delete)." -InformationAction Continue
                continue
            }
            $match = $current | Where-Object { $_.displayName -eq $row.Name } | Select-Object -First 1
            if ($PSCmdlet.ShouldProcess("Administrative unit '$($row.Name)'", 'Delete')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete
                    Invoke-RestMethod -Method Delete -Uri "$graphBase/directory/administrativeUnits/$($match.id)" -Headers $headers | Out-Null
                    Write-Information "Deleted orphan AU '$($row.Name)'." -InformationAction Continue
                } catch {
                    Write-PruneFailure ("Delete of orphan AU '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
                    $pruneFailures.Add([string]$row.Name)
                    continue
                }
            }
        }
        'Conflict' {
            if (-not $Force) {
                Write-Information "Skipping conflict AU '$($row.Name)' (use -Force to overwrite)." -InformationAction Continue
            }
        }
        default {
            # NoChange - nothing to do.
        }
    }
}

if ($pruneFailures.Count -gt 0) {
    throw ("Reconciliation aborted: {0} orphan administrative unit(s) could not be deleted: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
}

# Suppress PSReviewUnusedParameter warnings for principal variable reserved for future Conflict detection.
$null = $currentPrincipal

# Return the report for pipeline capture.
return $report
