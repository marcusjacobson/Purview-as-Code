<#
.SYNOPSIS
    Preflight: verifies that the signed-in Microsoft 365 tenant has the licenses
    and service plans required by a caller script.

.DESCRIPTION
    Called by every data-plane Deploy-*.ps1 before any state change. Reads
    tenant SKUs from Microsoft Graph (GET /subscribedSkus) and confirms that
    each service plan passed in -RequiredServicePlans is present AND in
    provisioning status 'Success' on at least one assigned SKU. Fails fast
    with an actionable error when a plan is missing or suspended.

    Read-only. Never mutates tenant state. Safe to run in CI, under -WhatIf,
    and repeatedly.

    Decision context: docs/adr/0001-m365-licensing-verification.md

.PARAMETER RequiredServicePlans
    One or more Microsoft 365 service plan names (servicePlanName, not GUID).
    Example values: 'MIP_S_Exchange', 'PREMIUM_DLP', 'INSIDER_RISK_MANAGEMENT'.
    Reference: https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference

.PARAMETER MinimumAssignedUnits
    Optional. Minimum number of assigned units required on the first SKU that
    contains each plan. Defaults to 1. Does not inspect per-user assignment.

.EXAMPLE
    PS> ./Test-M365Licensing.ps1 -RequiredServicePlans 'MIP_S_Exchange','MIP_S_CLP2'
    Verifies sensitivity-label service plans before running Deploy-Labels.ps1.

.EXAMPLE
    PS> ./Test-M365Licensing.ps1 -RequiredServicePlans 'INSIDER_RISK_MANAGEMENT' -Verbose

.NOTES
    Requires:
      - PowerShell 7.4+
      - Microsoft.Graph.Identity.DirectoryManagement (any 2.x)
      - Graph delegated OR app-only scope: Directory.Read.All (least privilege)
    Reference: https://learn.microsoft.com/en-us/graph/api/subscribedsku-list
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]] $RequiredServicePlans,

    [Parameter()]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $MinimumAssignedUnits = 1
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# --- Module check -----------------------------------------------------------
# Reference: https://learn.microsoft.com/en-us/powershell/microsoftgraph/installation
$module = 'Microsoft.Graph.Identity.DirectoryManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    throw "Required module '$module' is not installed. Install with: Install-Module $module -Scope CurrentUser"
}
Import-Module $module -ErrorAction Stop -Verbose:$false

# --- Graph connection check -------------------------------------------------
# Reference: https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands
$context = Get-MgContext -ErrorAction SilentlyContinue
if (-not $context) {
    throw "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'Directory.Read.All' -NoWelcome"
}
if ($context.Scopes -notcontains 'Directory.Read.All' -and $context.Scopes -notcontains 'Directory.ReadWrite.All') {
    throw "Current Graph context lacks 'Directory.Read.All'. Reconnect with: Connect-MgGraph -Scopes 'Directory.Read.All'"
}
Write-Verbose "Graph tenant: $($context.TenantId)"

# --- Fetch SKUs -------------------------------------------------------------
# Reference: https://learn.microsoft.com/en-us/graph/api/subscribedsku-list
$skus = Get-MgSubscribedSku -All -ErrorAction Stop
if (-not $skus) {
    throw "No subscribed SKUs returned from Microsoft Graph. Check tenant licensing."
}
Write-Verbose ("Tenant has {0} subscribed SKU(s)." -f $skus.Count)

# --- Index service plans: planName -> list of (skuPartNumber, status, unitsEnabled) ---
$planIndex = @{}
foreach ($sku in $skus) {
    foreach ($plan in $sku.ServicePlans) {
        if (-not $planIndex.ContainsKey($plan.ServicePlanName)) {
            $planIndex[$plan.ServicePlanName] = [System.Collections.Generic.List[pscustomobject]]::new()
        }
        $planIndex[$plan.ServicePlanName].Add([pscustomobject]@{
            SkuPartNumber            = $sku.SkuPartNumber
            ProvisioningStatus       = $plan.ProvisioningStatus
            AssignedUnits            = $sku.PrepaidUnits.Enabled
        }) | Out-Null
    }
}

# --- Evaluate required plans ------------------------------------------------
$missing = [System.Collections.Generic.List[string]]::new()
$suspended = [System.Collections.Generic.List[string]]::new()
$underprovisioned = [System.Collections.Generic.List[string]]::new()

foreach ($required in $RequiredServicePlans) {
    if (-not $planIndex.ContainsKey($required)) {
        $missing.Add($required) | Out-Null
        continue
    }

    $entries = $planIndex[$required]
    $successful = @($entries | Where-Object { $_.ProvisioningStatus -eq 'Success' })
    if ($successful.Count -eq 0) {
        $statuses = ($entries | ForEach-Object { "$($_.SkuPartNumber)=$($_.ProvisioningStatus)" }) -join ', '
        $suspended.Add("$required ($statuses)") | Out-Null
        continue
    }

    $topSku = $successful | Sort-Object AssignedUnits -Descending | Select-Object -First 1
    if ($topSku.AssignedUnits -lt $MinimumAssignedUnits) {
        $underprovisioned.Add("$required (SKU $($topSku.SkuPartNumber) has $($topSku.AssignedUnits) units, need $MinimumAssignedUnits)") | Out-Null
        continue
    }

    Write-Verbose ("OK: {0} via {1} ({2} units)" -f $required, $topSku.SkuPartNumber, $topSku.AssignedUnits)
}

# --- Report -----------------------------------------------------------------
if ($missing.Count -or $suspended.Count -or $underprovisioned.Count) {
    $lines = @('Licensing preflight FAILED for tenant ' + $context.TenantId + ':')
    if ($missing.Count)          { $lines += '  Missing service plans   : '        + ($missing -join ', ') }
    if ($suspended.Count)        { $lines += '  Non-Success provisioning: '        + ($suspended -join '; ') }
    if ($underprovisioned.Count) { $lines += '  Under-provisioned plans : '        + ($underprovisioned -join '; ') }
    $lines += 'Reference: https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference'
    throw ($lines -join [Environment]::NewLine)
}

Write-Information ("Licensing preflight OK: {0} service plan(s) verified." -f $RequiredServicePlans.Count) -InformationAction Continue
