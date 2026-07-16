#Requires -Version 7.4
<#
.SYNOPSIS
    Create (idempotently) a Microsoft Purview adaptive policy scope via the
    Security & Compliance PowerShell cmdlet `New-AdaptiveScope`.

.DESCRIPTION
    One-shot imperative primitive (candidate #3 hybrid per issue #548) that
    provisions a lab-tenant adaptive scope so the existing
    `scripts/Deploy-DLPPolicies.ps1` reconciler can resolve it by name at
    apply time via `Get-AdaptiveScope`. Created to unblock umbrella #520
    exit criterion 6 (live-tenant exercise of the new `adaptiveScopes.*`
    buckets).

    Authentication mirrors `scripts/Deploy-AutoLabelPolicies.ps1`:

      1. Read `infra/parameters/lab.yaml` (or the file passed via
         `-ParametersFile`) for vault name, certificate name, data-plane
         Entra app display name, and tenant domain. Per ADR 0012 these
         are the only environment-varying values; no secrets live in the
         parameters file.
      2. Resolve the data-plane Entra app ID via `az ad app list`.
      3. Call `scripts/Get-PurviewIPPSAccessToken.ps1` which selects
         between the local-cert (`$env:PURVIEW_LOCAL_CERT_THUMBPRINT`)
         and Key Vault signing transports per ADR 0028.
      4. `Connect-IPPSSession -AccessToken ...` with -ShowBanner:$false.
      5. `Get-AdaptiveScope -Identity $Name` to detect the idempotent
         path. If the scope already exists and its `LocationType` matches
         the requested value, emit `NoChange` and exit without writing.
         If `LocationType` differs the script refuses to proceed -- the
         `LocationType` of an existing adaptive scope cannot be changed
         in place per Microsoft Learn; the operator must delete and
         recreate.
      6. If the scope does not exist, `New-AdaptiveScope` with the
         provided `-LocationType` and `-FilterConditions` hashtable.
         Gated by `$PSCmdlet.ShouldProcess` so `-WhatIf` produces a plan
         row without writing.

    Scope (deliberately narrow per candidate #3 hybrid):

      - Single scope per invocation. Re-invoke for additional scopes.
      - No declarative YAML round-trip. Reconciler shape and
        `FilterConditions` schema are tracked separately by issue #550
        (the `scripts/Deploy-AdaptiveScopes.ps1` reconciler). See
        ADR 0034 for the YAML / cmdlet boundary decisions.
      - The `-FilterConditions` hashtable is passed through opaquely.
        ADR 0034 Decision 1 ratifies the JSON-string boundary the
        reconciler will use; this one-shot helper accepts a hashtable
        for ergonomic interactive use and is decoupled from that
        boundary.
      - No `-PruneMissing`, no `-Force`, no `-ExportCurrentState`. Those
        belong to `Deploy-*.ps1` reconcilers; this is an imperative
        primitive.

    References:
      docs/adr/0034-adaptive-scope-schema.md -- YAML / cmdlet boundary
        for the reconciler shape (issue #550); explains why the
        cmdlet's `-FilterConditions` schema diverges from the
        Microsoft Learn-published examples.

    References (Microsoft Learn):
      New-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
      Get-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
      Microsoft Purview adaptive policy scopes:
        https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes
      Connect-IPPSSession -AccessToken:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      App-only authentication for unattended scripts in Exchange Online /
      Security & Compliance PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      az ad app list:
        https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
      az account show:
        https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER Name
    Name of the adaptive scope. Must start with the `lab-as-` prefix per
    issue #548 (clear lab ownership in the tenant-wide M365 admin
    surface). Validated to 8-64 characters and kebab-case alphanumerics
    plus hyphen. The name is the authoritative identifier the
    `Deploy-DLPPolicies.ps1` reconciler resolves to a GUID at apply
    time via `Get-AdaptiveScope`, so changing the name is a rename;
    re-running with a new name creates a new scope.

.PARAMETER LocationType
    Location type the scope filters. One of `User`, `Group`, `Site` per
    [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope).
    Immutable once set; if the scope already exists with a different
    `LocationType` the script refuses to proceed.

.PARAMETER FilterConditions
    Hashtable describing the scope membership filter. Passed through to
    `New-AdaptiveScope -FilterConditions` unchanged. The cmdlet
    validates the shape per `LocationType`; see Microsoft Learn for the
    documented shape. Pass-through is intentional per candidate #3
    hybrid in issue #548; a declarative schema is deferred.

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
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.EXAMPLE
    ./scripts/New-AdaptiveScope.ps1 `
        -Name          'lab-as-test-mailbox-01' `
        -LocationType  'User' `
        -FilterConditions @{
            Conditions = @(
                @{ Property = 'UserPrincipalName'; Operator = 'Equals'; Value = 'user@contoso.com' }
            )
        } `
        -WhatIf

    Prints planned behaviour with synthetic identifiers; makes no remote
    writes.

.EXAMPLE
    ./scripts/New-AdaptiveScope.ps1 `
        -Name          'lab-as-test-mailbox-01' `
        -LocationType  'User' `
        -FilterConditions @{
            Conditions = @(
                @{ Property = 'UserPrincipalName'; Operator = 'Equals'; Value = 'user@contoso.com' }
            )
        }

    Creates the scope if missing, emits `NoChange` if it already exists
    with the same `LocationType`, refuses to proceed if `LocationType`
    differs. Returns a PSCustomObject summary with the scope GUID
    (which the operator can paste into `data-plane/dlp/policies.yaml`
    under `adaptiveScopes.*` as the `guid` field if the reconciler's
    name-based lookup is bypassed).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport for
        the Key Vault path, and is also used for tenant + app
        resolution).
      * Either `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` set to a valid local
        signing cert (ADR 0028 transport A) **or** `Key Vault Crypto
        User` + `Key Vault Certificate User` on the lab Key Vault (ADR
        0011 transport B).

    Data-plane Entra app prerequisites (one-time per tenant, same as
    every other IPPS script in this repo):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` (or
        `Compliance Data Administrator`) assigned at directoryScopeId='/'.

    Output: a single PSCustomObject with Name / LocationType / Action
    (`NoChange` | `Create` | `WhatIf-Create`) / Guid. The access token
    is never echoed; the scope GUID is logged in redacted form via
    `Format-AdaptiveScopeIdentifier` and returned in full only via the
    structured PSObject (consumed programmatically).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(8, 64)]
    [ValidatePattern('^lab-as-[a-z0-9]([a-z0-9-]{0,55}[a-z0-9])?$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidateSet('User', 'Group', 'Site')]
    [string]$LocationType,

    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [hashtable]$FilterConditions,

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

#region Helpers (pure -- AST-extracted for Pester)

function Format-AdaptiveScopeIdentifier {
    # Redact a GUID-like string for transcript-safe logging. Real GUIDs
    # only leave the script via the structured PSObject return value
    # (consumed programmatically), never via Write-Information /
    # Write-Error / Write-Warning. Mirrors `Format-EntraIdentifier` in
    # `scripts/New-RoleAssignableEntraGroup.ps1`. See
    # `.github/instructions/security.instructions.md` and the
    # "Environment and identifier boundaries" section of
    # `.github/copilot-instructions.md`.
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<none>' }
    if ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return ($Value.Substring(0, 8) + '-...')
    }
    return $Value
}

function Resolve-AdaptiveScopeAction {
    # Pure decision function. Given the result of `Get-AdaptiveScope
    # -Identity <Name>` (or $null when absent) and the desired
    # `LocationType`, return one of:
    #   * 'Create'           -- scope absent; caller should call New-AdaptiveScope.
    #   * 'NoChange'         -- scope present with matching LocationType; caller skips.
    # Throws on LocationType conflict (the scope exists but with a
    # different LocationType; per Microsoft Learn the LocationType is
    # immutable so an in-place change is not safe).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Existing,
        [Parameter(Mandatory = $true)][ValidateSet('User','Group','Site')][string]$DesiredLocationType,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Name
    )

    if ($null -eq $Existing) { return 'Create' }

    $existingLocationType = $null
    if ($Existing -is [hashtable] -or $Existing -is [System.Collections.IDictionary]) {
        if ($Existing.Contains('LocationType')) { $existingLocationType = [string]$Existing['LocationType'] }
    } else {
        $prop = $Existing.PSObject.Properties.Match('LocationType')
        if ($prop.Count -gt 0) { $existingLocationType = [string]$prop[0].Value }
    }

    if ([string]::IsNullOrWhiteSpace($existingLocationType)) {
        throw ("Adaptive scope '{0}' was returned by Get-AdaptiveScope but has no readable LocationType property; refusing to proceed." -f $Name)
    }
    if ($existingLocationType -ne $DesiredLocationType) {
        throw ("Adaptive scope '{0}' exists with LocationType '{1}' but '{2}' was requested. LocationType is immutable per Microsoft Learn; delete the scope manually and re-run, or pick a new -Name. Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope" -f $Name, $existingLocationType, $DesiredLocationType)
    }
    return 'NoChange'
}

function Get-AdaptiveScopeIdValue {
    # Pure extractor. The Get-AdaptiveScope readback object exposes its
    # GUID under one of several property names depending on cmdlet
    # version (Guid / Identity / ExchangeObjectId). Mirrors the
    # equivalent shape in `scripts/Deploy-DLPPolicies.ps1`
    # Resolve-AdaptiveScopeMap. Returns the empty string when no GUID
    # can be read (loud-error is the caller's responsibility).
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Scope)
    if ($null -eq $Scope) { return '' }
    foreach ($p in @('Guid','Identity','ExchangeObjectId')) {
        $val = $null
        if ($Scope -is [hashtable] -or $Scope -is [System.Collections.IDictionary]) {
            if ($Scope.Contains($p)) { $val = [string]$Scope[$p] }
        } else {
            $match = $Scope.PSObject.Properties.Match($p)
            if ($match.Count -gt 0) { $val = [string]$match[0].Value }
        }
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val }
    }
    return ''
}

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

# Reference: https://github.com/cloudbase/powershell-yaml
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Error "PowerShell module 'powershell-yaml' is required to parse the parameters file. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    return
}
Import-Module powershell-yaml -ErrorAction Stop

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

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("Scope name      : {0}" -f $Name) -InformationAction Continue
Write-Information ("LocationType    : {0}" -f $LocationType) -InformationAction Continue

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

#endregion

#region Resolve Entra app + acquire token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error ("az ad app list failed with exit code {0}." -f $LASTEXITCODE)
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
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$appId = [string]$appList[0].appId

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

#endregion

#region Connect-IPPSSession, read, optionally write, disconnect

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
Import-Module ExchangeOnlineManagement -ErrorAction Stop

$summary = $null
try {
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
    $existing = $null
    try {
        $existing = Get-AdaptiveScope -Identity $Name -ErrorAction Stop
    } catch {
        # The cmdlet throws when the identity is not found rather than
        # returning $null. Treat any read error as "absent" and let the
        # write path surface the real cause if it persists.
        Write-Verbose ('Get-AdaptiveScope returned an error for ''{0}'' (treated as absent): {1}' -f $Name, $_.Exception.Message)
        $existing = $null
    }

    $action = Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType $LocationType -Name $Name

    if ($action -eq 'NoChange') {
        $existingId = Get-AdaptiveScopeIdValue -Scope $existing
        Write-Information ("Adaptive scope '{0}' already present (LocationType={1}, guid={2}). NoChange." -f $Name, $LocationType, (Format-AdaptiveScopeIdentifier -Value $existingId)) -InformationAction Continue
        $summary = [pscustomobject]@{
            Name         = $Name
            LocationType = $LocationType
            Action       = 'NoChange'
            Guid         = $existingId
        }
    }
    elseif ($action -eq 'Create') {
        $target = ("adaptive scope '{0}'" -f $Name)
        $cmdletAction = ("New-AdaptiveScope -LocationType {0}" -f $LocationType)
        if ($PSCmdlet.ShouldProcess($target, $cmdletAction)) {
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
            $created = New-AdaptiveScope `
                -Name             $Name `
                -LocationType     $LocationType `
                -FilterConditions $FilterConditions `
                -ErrorAction      Stop
            $createdId = Get-AdaptiveScopeIdValue -Scope $created
            Write-Information ("Adaptive scope '{0}' created (LocationType={1}, guid={2})." -f $Name, $LocationType, (Format-AdaptiveScopeIdentifier -Value $createdId)) -InformationAction Continue
            $summary = [pscustomobject]@{
                Name         = $Name
                LocationType = $LocationType
                Action       = 'Create'
                Guid         = $createdId
            }
        } else {
            # -WhatIf path (ShouldProcess returned $false). Emit a plan
            # row so the operator sees what an apply would do.
            Write-Information ("WhatIf: would call New-AdaptiveScope -Name '{0}' -LocationType {1}." -f $Name, $LocationType) -InformationAction Continue
            $summary = [pscustomobject]@{
                Name         = $Name
                LocationType = $LocationType
                Action       = 'WhatIf-Create'
                Guid         = ''
            }
        }
    }
    else {
        throw ("Resolve-AdaptiveScopeAction returned unexpected action '{0}' for scope '{1}'." -f $action, $Name)
    }
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

#endregion

# Single PSCustomObject result for programmatic consumption.
$summary
