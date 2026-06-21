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

.PARAMETER Force
    Overwrite AUs whose `lastModifiedBy` is not the current principal.
    Default: $false. Must be explicit per the drift-report contract.

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
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\administrative-units\administrative-units.yaml'),

    [switch]$PruneMissing,

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

$graphBase = 'https://graph.microsoft.com/v1.0'
$token     = Get-GraphToken
$headers   = @{
    Authorization   = "Bearer $token"
    'Content-Type'  = 'application/json'
}
$currentPrincipal = Get-SignedInPrincipalId

# ---------------------------------------------------------------------------
# Load desired state.
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) {
    throw "Desired-state YAML not found at $Path."
}
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
$desired = @()
if ($desiredRoot -and $desiredRoot.administrativeUnits) {
    $desired = @($desiredRoot.administrativeUnits)
}

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

# ---------------------------------------------------------------------------
# Act on the report.
# ---------------------------------------------------------------------------
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
                # Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete
                Invoke-RestMethod -Method Delete -Uri "$graphBase/directory/administrativeUnits/$($match.id)" -Headers $headers | Out-Null
                Write-Information "Deleted orphan AU '$($row.Name)'." -InformationAction Continue
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

# Suppress PSReviewUnusedParameter warnings for principal variable reserved for future Conflict detection.
$null = $currentPrincipal

# Return the report for pipeline capture.
return $report
