#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 ADAPTIVE POLICY SCOPES
    against `data-plane/adaptive-scopes/scopes.yaml` (desired state).

.DESCRIPTION
    Declarative reconciler for adaptive policy scopes. Sibling of
    `scripts/Deploy-AutoLabelPolicies.ps1` -- same auth path, same drift
    vocabulary (Create / Update / NoChange / Orphan / Blocked / Skip),
    same ADR 0029 `-DirectionPolicy` contract. Where the auto-label
    reconciler owns label automation, this script owns the dynamic
    membership sets (`Get-/New-/Set-/Remove-AdaptiveScope`) that
    retention, DLP, IRM, and sensitivity policies bind to. The lab's
    existing `scripts/Deploy-DLPPolicies.ps1` already resolves these
    scopes by NAME via `Get-AdaptiveScope` at apply time -- this script
    is the source of truth for the scopes themselves.

    See `docs/adr/0034-adaptive-scope-schema.md` for the YAML / cmdlet
    boundary decisions. In particular Decision 1 (FilterConditions
    pass-through as a JSON string -- the cmdlet rejects hashtable
    input at depth 1) and Decision 4 (server-side NRE blocker on first
    apply is documented separately; this script's read paths
    (-WhatIf, -ExportCurrentState) work today).

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET each scope via `Get-AdaptiveScope`.
      2. Match desired vs. tenant by `name` (immutable identity).
      3. Diff each desired scope's tracked fields:
           name (identity, not diffed), locationType (IMMUTABLE per
           Microsoft Learn -- mismatch -> Blocked, never Update),
           filterConditions (JSON string, byte-for-byte equality).
      4. Emit a categorized report (Create / Update / NoChange /
         Orphan / Blocked / Skip).
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing / -DirectionPolicy / -SkipNames).

    Single-phase reconciliation (no rule sub-loop, no label-GUID
    resolution, no simulation start step):
      Phase 1 (read)  -- `Get-AdaptiveScope`, build per-object plan.
      Phase 2 (reset) -- Disconnect + reload ExchangeOnlineManagement +
                         Reconnect (only if writes are planned).
      Phase 3 (write) -- `*-AdaptiveScope` calls against the refreshed
                         session.

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md`):

        ./scripts/Deploy-AdaptiveScopes.ps1 -ExportCurrentState

    Hydrates the YAML from the live tenant. Refuses to overwrite a
    non-empty `scopes:` block unless -Force is also specified.

    `comment` field (ADR 0034): the schema permits an optional
    documentation-only `comment:` field on each scope entry. The
    cmdlet has no `-Comment` parameter (verified via
    `(Get-Command New-AdaptiveScope).Parameters`), so the reconciler
    silently ignores the field for diff and export -- it lives in YAML
    only.

    `LocationType` immutability: a desired scope with a `locationType`
    that differs from the tenant readback is reported as `Blocked`,
    not `Update`. The operator must rename the desired scope (which
    triggers Create + Orphan) or delete the tenant scope and re-apply.
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope

    `filterConditions` pass-through (ADR 0034 Decision 1+3): the
    reconciler treats the JSON string as opaque. It does not parse,
    canonicalize, or normalize. `Test-Json -Json $body` validates
    well-formedness client-side; the cmdlet enforces attribute-name
    and value rules at write time. There is no
    `ConvertTo-NormalizedFilterConditionsJson` helper -- byte-for-byte
    equality is the diff contract, and `-ExportCurrentState`
    establishes the tenant-canonical form in YAML.

    References (Microsoft Learn):
      Adaptive policy scopes overview:
        https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes
      New-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
      Get-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
      Set-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-adaptivescope
      Remove-AdaptiveScope:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-adaptivescope
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0029 (source-of-truth direction policy):
        docs/adr/0029-source-of-truth-direction-policy.md
      ADR 0034 (adaptive-scope schema / cmdlet boundary):
        docs/adr/0034-adaptive-scope-schema.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/adaptive-scopes/scopes.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant scopes that are not declared in the YAML.
    Default $false. Destructive; gated by `$PSCmdlet.ShouldProcess` per
    scope.

.PARAMETER Force
    With `-ExportCurrentState`: allow overwriting a `scopes:` block that
    already contains entries. Without it the script refuses, to avoid
    clobbering hand-curated YAML.

.PARAMETER ExportCurrentState
    Read every adaptive scope visible to the connected app, write to the
    YAML's `scopes:` block, and exit. Makes no writes to the tenant.
    The tenant `FilterConditions` property is preserved byte-for-byte
    (string pass-through) per ADR 0034 Decision 1.

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

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. No write fires.
      * `portal-wins` -- (default) skip any shared scope whose tracked
                         fields differ; emit `[ADR0029-SKIP] <name>`.
      * `repo-wins`   -- apply the full plan; emit a per-object
                         Write-Warning naming the drifted field(s).
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipSchemaValidation
    Bypass the JSON-Schema check against
    `data-plane/adaptive-scopes/scopes.schema.json`. Intended for
    emergency recovery; never set in CI.

.EXAMPLE
    ./scripts/Deploy-AdaptiveScopes.ps1 -WhatIf

    Connect read-only and emit the per-object Create / Update /
    NoChange / Orphan / Blocked plan table for what an Apply would do;
    make no remote writes.

.EXAMPLE
    ./scripts/Deploy-AdaptiveScopes.ps1 -ExportCurrentState -Force

    Replace the `scopes:` block in
    `data-plane/adaptive-scopes/scopes.yaml` with every scope visible
    to the connected app. -Force is required when the YAML already has
    a non-empty scopes block.

.EXAMPLE
    ./scripts/Deploy-AdaptiveScopes.ps1 -DirectionPolicy audit

    Read-only audit pass. Builds the plan, emits the report, prints
    `[ADR0029-AUDIT]`, exits without any New-/Set-/Remove call.

.NOTES
    Caller role requirements:
      * Active `az login` session (for tenant + app resolution and as
        the JWT signing transport on the Key Vault path).
      * Either `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` (ADR 0028 transport
        A) or Key Vault `Crypto User` + `Certificate User` on the lab
        Key Vault (ADR 0011 transport B).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        with admin consent.
      * Entra directory role `Compliance Administrator` (or
        `Compliance Data Administrator`) assigned at
        `directoryScopeId='/'`.

    First-apply caveat (ADR 0034 Decision 4): the first
    `New-AdaptiveScope` write currently fails with a server-side NRE
    against this lab tenant. The read paths (`-WhatIf`,
    `-ExportCurrentState`) work today; live apply is gated on
    resolving the NRE separately.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\adaptive-scopes\scopes.yaml'),

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
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers (pure -- AST-extracted for Pester)

function ConvertTo-DesiredAdaptiveScopeHash {
    <#
    .SYNOPSIS
        Normalize a YAML scope entry into a comparable hashtable.

    .DESCRIPTION
        Pure transform. Input is a hashtable (from ConvertFrom-Yaml) or
        an ordered dictionary; output is a hashtable with exactly three
        tracked keys (name, locationType, filterConditions). The
        optional `comment` field is intentionally dropped -- per ADR
        0034 it is YAML-only documentation; the cmdlet has no -Comment
        parameter, so including it in the diff hash would cause every
        scope with a comment to drift forever.

        Throws on missing required fields or invalid shape. The schema
        check upstream catches these at the boundary, but the helper
        repeats them so it is safe to call from a Pester test on a
        synthetic hashtable that bypassed the schema gate.

    .OUTPUTS
        [hashtable] with keys `name` (string), `locationType` (string),
        `filterConditions` (string, JSON document).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Entry
    )
    if ($null -eq $Entry) {
        throw 'ConvertTo-DesiredAdaptiveScopeHash: $Entry is $null.'
    }
    $hasName = $false; $hasLoc = $false; $hasFc = $false
    $name = $null; $loc = $null; $fc = $null
    if ($Entry -is [hashtable] -or $Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('name'))             { $hasName = $true; $name = [string]$Entry['name'] }
        if ($Entry.Contains('locationType'))     { $hasLoc  = $true; $loc  = [string]$Entry['locationType'] }
        if ($Entry.Contains('filterConditions')) { $hasFc   = $true; $fc   = [string]$Entry['filterConditions'] }
    }
    else {
        foreach ($p in $Entry.PSObject.Properties) {
            switch ($p.Name) {
                'name'             { $hasName = $true; $name = [string]$p.Value }
                'locationType'     { $hasLoc  = $true; $loc  = [string]$p.Value }
                'filterConditions' { $hasFc   = $true; $fc   = [string]$p.Value }
            }
        }
    }
    if (-not $hasName -or [string]::IsNullOrWhiteSpace($name)) {
        throw 'ConvertTo-DesiredAdaptiveScopeHash: required field "name" is missing or empty.'
    }
    if (-not $hasLoc -or [string]::IsNullOrWhiteSpace($loc)) {
        throw ("ConvertTo-DesiredAdaptiveScopeHash: scope '{0}' missing required field 'locationType'." -f $name)
    }
    if (@('User','Group','Site') -notcontains $loc) {
        throw ("ConvertTo-DesiredAdaptiveScopeHash: scope '{0}' has invalid locationType '{1}' (expected User|Group|Site)." -f $name, $loc)
    }
    if (-not $hasFc -or [string]::IsNullOrWhiteSpace($fc)) {
        throw ("ConvertTo-DesiredAdaptiveScopeHash: scope '{0}' missing required field 'filterConditions'." -f $name)
    }
    # ADR 0034 Decision 1: filterConditions is an opaque JSON string.
    # Validate well-formedness only; do NOT canonicalize.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    try {
        $null = Test-Json -Json $fc -ErrorAction Stop
    } catch {
        throw ("ConvertTo-DesiredAdaptiveScopeHash: scope '{0}' has filterConditions that is not well-formed JSON: {1}" -f $name, $_.Exception.Message)
    }
    return @{
        name             = $name
        locationType     = $loc
        filterConditions = $fc
    }
}

function ConvertTo-TenantAdaptiveScopeHash {
    <#
    .SYNOPSIS
        Normalize a Get-AdaptiveScope row into the same shape as
        ConvertTo-DesiredAdaptiveScopeHash so the two can be compared.

    .DESCRIPTION
        Pure transform. Defensive about FilterConditions shape: the
        readback may be a string (canonical case) or a typed object
        (older cmdlet versions). Strings are preserved byte-for-byte
        (ADR 0034 Decision 1 pass-through); objects are converted via
        ConvertTo-Json -Compress so the diff has something stable to
        compare. Either way the result is a string.

    .OUTPUTS
        [hashtable] with keys `name`, `locationType`, `filterConditions`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Scope
    )
    if ($null -eq $Scope) {
        throw 'ConvertTo-TenantAdaptiveScopeHash: $Scope is $null.'
    }
    $name = $null; $loc = $null; $rawFc = $null
    if ($Scope -is [hashtable] -or $Scope -is [System.Collections.IDictionary]) {
        if ($Scope.Contains('Name'))             { $name  = [string]$Scope['Name'] }
        if ($Scope.Contains('LocationType'))     { $loc   = [string]$Scope['LocationType'] }
        if ($Scope.Contains('FilterConditions')) { $rawFc =          $Scope['FilterConditions'] }
    }
    else {
        $pName = $Scope.PSObject.Properties.Match('Name')
        $pLoc  = $Scope.PSObject.Properties.Match('LocationType')
        $pFc   = $Scope.PSObject.Properties.Match('FilterConditions')
        if ($pName.Count -gt 0) { $name  = [string]$pName[0].Value }
        if ($pLoc.Count  -gt 0) { $loc   = [string]$pLoc[0].Value }
        if ($pFc.Count   -gt 0) { $rawFc =          $pFc[0].Value }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'ConvertTo-TenantAdaptiveScopeHash: tenant scope has no readable Name property.'
    }
    if ([string]::IsNullOrWhiteSpace($loc)) {
        throw ("ConvertTo-TenantAdaptiveScopeHash: tenant scope '{0}' has no readable LocationType property." -f $name)
    }
    $fcString = ''
    if ($null -ne $rawFc) {
        if ($rawFc -is [string]) {
            $fcString = $rawFc
        } else {
            # Older cmdlet versions return a typed object; serialize
            # compactly so the diff has a stable shape. The operator's
            # next -ExportCurrentState run will overwrite the YAML with
            # the tenant's authoritative shape regardless.
            $fcString = $rawFc | ConvertTo-Json -Depth 100 -Compress
        }
    }
    return @{
        name             = $name
        locationType     = $loc
        filterConditions = $fcString
    }
}

function Compare-AdaptiveScope {
    <#
    .SYNOPSIS
        Decide the reconciler action for a (Desired, Tenant) pair.

    .DESCRIPTION
        Pure decision function. Accepts either side as $null. Returns a
        hashtable @{ Action; Fields } where Action is one of:
          * Create   -- desired present, tenant absent.
          * Orphan   -- desired absent, tenant present.
          * NoChange -- both present, all tracked fields identical.
          * Update   -- both present, only `filterConditions` differs.
          * Blocked  -- both present, `locationType` differs. The
                       LocationType of an adaptive scope is immutable
                       per Microsoft Learn; the operator must rename
                       the desired scope or delete the tenant scope.
                       Reference:
                       https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope

        `Fields` is the list of tracked field names that drifted
        (`filterConditions` for Update; `locationType` for Blocked;
        empty for Create / Orphan / NoChange).

        Throws if both sides are $null (caller bug; the outer plan must
        not invoke this helper for a (None, None) pair).

    .OUTPUTS
        [hashtable] @{ Action = 'Create'|'Update'|'NoChange'|'Orphan'|'Blocked';
                       Fields = [string[]] }
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][hashtable]$Desired,
        [Parameter()][AllowNull()][hashtable]$Tenant
    )
    if ($null -eq $Desired -and $null -eq $Tenant) {
        throw 'Compare-AdaptiveScope: both Desired and Tenant are $null.'
    }
    if ($null -eq $Tenant)  { return @{ Action = 'Create'; Fields = @() } }
    if ($null -eq $Desired) { return @{ Action = 'Orphan'; Fields = @() } }
    if ($Desired.locationType -ne $Tenant.locationType) {
        return @{ Action = 'Blocked'; Fields = @('locationType') }
    }
    # ADR 0034 Decision 1: byte-for-byte string equality on the JSON
    # blob is the diff contract. The reconciler does not parse or
    # canonicalize. Drift is resolved by re-running -ExportCurrentState.
    if ([string]$Desired.filterConditions -cne [string]$Tenant.filterConditions) {
        return @{ Action = 'Update'; Fields = @('filterConditions') }
    }
    return @{ Action = 'NoChange'; Fields = @() }
}

function Get-AdaptiveScopeSplat {
    <#
    .SYNOPSIS
        Build the splat hashtable for New-/Set-AdaptiveScope.

    .DESCRIPTION
        Pure transform. For `Operation='Create'` returns a hashtable
        suitable for `New-AdaptiveScope @splat` with keys `Name`,
        `LocationType`, `FilterConditions`. For `Operation='Update'`
        returns a hashtable suitable for `Set-AdaptiveScope @splat`
        with keys `Identity` and `FilterConditions` -- the only
        mutable tracked field (Name is identity; LocationType is
        immutable).

        The `FilterConditions` value is passed through unchanged per
        ADR 0034 Decision 1 (JSON string at the cmdlet boundary). The
        cmdlet schema-validates the body server-side; the client only
        validates well-formedness via Test-Json upstream.

    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][ValidateSet('Create','Update')][string]$Operation
    )
    foreach ($k in @('name','locationType','filterConditions')) {
        if (-not $Desired.ContainsKey($k)) {
            throw ("Get-AdaptiveScopeSplat: desired hash is missing required key '{0}'." -f $k)
        }
    }
    if ($Operation -eq 'Create') {
        return @{
            Name             = [string]$Desired.name
            LocationType     = [string]$Desired.locationType
            FilterConditions = [string]$Desired.filterConditions
        }
    }
    # Update path: identity by Name, only FilterConditions is mutable.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-adaptivescope
    return @{
        Identity         = [string]$Desired.name
        FilterConditions = [string]$Desired.filterConditions
    }
}

function Format-AdaptiveScopeIdentifier {
    # Redact a GUID-like string for transcript-safe logging. Mirrors
    # the equivalent helper in scripts/New-AdaptiveScope.ps1.
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '<none>' }
    if ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return ($Value.Substring(0, 8) + '-...')
    }
    return $Value
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
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

# In-repo ADR 0029 direction-policy decision helper. Shared with every
# Deploy-*.ps1 reconciler in this repo per issue #463.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so neither destructive branch (repo-wins
# overwrite, -PruneMissing delete) can be entered unattended from a local
# terminal.
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

#region Desired-state load

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

# Schema validation (JSON Schema Draft-07). ADR 0034.
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\adaptive-scopes\scopes.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Write-Error ("Schema file not found at '{0}'. Pass -SkipSchemaValidation to bypass." -f $schemaPath)
        return
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $jsonDoc    = $desiredRoot | ConvertTo-Json -Depth 100
    try {
        $jsonDoc | Test-Json -Schema $schemaText -ErrorAction Stop | Out-Null
        Write-Information ("Schema OK       : {0}" -f (Split-Path -Leaf $schemaPath)) -InformationAction Continue
    } catch {
        Write-Error ("Schema validation failed for '{0}' against '{1}': {2}" -f $Path, $schemaPath, $_.Exception.Message)
        return
    }
}

$desiredEntries = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('scopes') -and $desiredRoot.scopes) {
    $desiredEntries = @($desiredRoot.scopes)
}

$desiredHashes = @()
if ($mode -eq 'Apply') {
    foreach ($e in $desiredEntries) {
        # Helper repeats the required-field checks so a YAML that
        # somehow slipped past the schema gate still fails loudly here.
        $desiredHashes += ConvertTo-DesiredAdaptiveScopeHash -Entry $e
    }
    $seenNames = @{}
    foreach ($h in $desiredHashes) {
        if ($seenNames.ContainsKey($h.name)) {
            Write-Error ("Adaptive scope name '{0}' is declared more than once in '{1}'." -f $h.name, $Path)
            return
        }
        $seenNames[$h.name] = $true
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

#region -WhatIf short-circuit (Export only -- Apply runs the read phase)

# -WhatIf on the Apply path deliberately does NOT short-circuit -- each
# write is gated by $PSCmdlet.ShouldProcess in Phase 3, so the read
# phase still produces a per-object plan table for destructive-change
# PR previews. Mirrors Deploy-Labels.ps1 / Deploy-AutoLabelPolicies.ps1.
# Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ("  Connect, run Get-AdaptiveScope, write every visible scope to {0}." -f $Path) -InformationAction Continue
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

#region Connect, reconcile, disconnect

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredEntries.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("'{0}' already declares {1} scope(s). Refusing to overwrite without -Force." -f $Path, $desiredEntries.Count)
            return
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
        $allScopes = @(Get-AdaptiveScope -ErrorAction Stop)
        Write-Information ("Discovered {0} adaptive scope(s) visible to the connected app." -f $allScopes.Count) -InformationAction Continue

        $scopeExport = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
        foreach ($s in $allScopes | Sort-Object Name) {
            $h = ConvertTo-TenantAdaptiveScopeHash -Scope $s
            $entry = [ordered]@{
                name             = $h.name
                locationType     = $h.locationType
                # ADR 0034 Decision 1: pass the tenant's canonical JSON
                # string through unchanged so subsequent applies are
                # round-trip stable.
                filterConditions = $h.filterConditions
            }
            $scopeExport.Add($entry)
        }

        Write-Information ("Exporting {0} scope(s)." -f $scopeExport.Count) -InformationAction Continue

        # Preserve YAML header comments by line-splicing at `scopes:`.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*scopes\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'scopes:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = if ($cutIndex -gt 0) { $originalLines[0..($cutIndex - 1)] } else { @() }

        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        $bodyDoc = [ordered]@{
            scopes = @($scopeExport)
        }
        if ($scopeExport.Count -eq 0) { $bodyDoc.scopes = @() }

        # Reference: https://www.powershellgallery.com/packages/powershell-yaml
        $body = $bodyDoc | ConvertTo-Yaml -Options WithIndentedSequences
        foreach ($line in ($body -split "`n")) { $newBlock.Add($line.TrimEnd()) }
        while ($newBlock.Count -gt 0 -and [string]::IsNullOrEmpty($newBlock[$newBlock.Count - 1])) {
            $newBlock.RemoveAt($newBlock.Count - 1)
        }

        $finalLines = @($headerLines) + @($newBlock)
        $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
        $shouldProcessAction = "Replace 'scopes:' block with {0} scope entry/entries" -f $scopeExport.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            $content = ($finalLines -join "`n") + "`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
            Write-Information ("Wrote {0} scope entry/entries to '{1}'." -f $scopeExport.Count, $Path) -InformationAction Continue
        }
        return

        #endregion
    }

    #region Apply mode: read + categorize + ADR 0029 + write

    if ($desiredHashes.Count -eq 0 -and -not $PruneMissing.IsPresent) {
        Write-Information 'No adaptive scopes declared in YAML. Nothing to reconcile (use -PruneMissing to remove tenant-only scopes).' -InformationAction Continue
        return @()
    }

    # ---- Phase 1: Read + categorize ----
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
    $tenantScopes = @(Get-AdaptiveScope -ErrorAction Stop)
    Write-Information ("Read {0} adaptive scope(s) from tenant." -f $tenantScopes.Count) -InformationAction Continue

    $tenantByName = @{}
    foreach ($s in $tenantScopes) { $tenantByName[[string]$s.Name] = $s }

    $desiredByName = @{}
    foreach ($d in $desiredHashes) { $desiredByName[$d.name] = $d }

    $plan         = New-Object 'System.Collections.Generic.List[object]'
    $blockedRows  = New-Object 'System.Collections.Generic.List[object]'
    $orphanScopes = New-Object 'System.Collections.Generic.List[object]'

    # Per-desired pass: Create / Update / NoChange / Blocked.
    foreach ($d in $desiredHashes) {
        $tenantHash = $null
        $tenantObj  = $null
        if ($tenantByName.ContainsKey($d.name)) {
            $tenantObj  = $tenantByName[$d.name]
            $tenantHash = ConvertTo-TenantAdaptiveScopeHash -Scope $tenantObj
        }
        $decision = Compare-AdaptiveScope -Desired $d -Tenant $tenantHash
        switch ($decision.Action) {
            'Create' {
                $report.Add([pscustomobject]@{
                    Category = 'Create'
                    Kind     = 'AdaptiveScope'
                    Name     = $d.name
                    Reason   = 'Declared in YAML; not present in tenant.'
                    Field    = ''
                })
                $plan.Add([pscustomobject]@{
                    Action  = 'Create'
                    Desired = $d
                    Tenant  = $null
                })
            }
            'NoChange' {
                $report.Add([pscustomobject]@{
                    Category = 'NoChange'
                    Kind     = 'AdaptiveScope'
                    Name     = $d.name
                    Reason   = 'Declared in YAML and present in tenant; tracked fields identical.'
                    Field    = ''
                })
            }
            'Update' {
                foreach ($f in $decision.Fields) {
                    $report.Add([pscustomobject]@{
                        Category = 'Update'
                        Kind     = 'AdaptiveScope'
                        Name     = $d.name
                        Reason   = 'Tracked field differs from tenant.'
                        Field    = $f
                    })
                }
                $plan.Add([pscustomobject]@{
                    Action  = 'Update'
                    Desired = $d
                    Tenant  = $tenantObj
                    Fields  = @($decision.Fields)
                })
            }
            'Blocked' {
                $reason = ("LocationType conflict: YAML='{0}' vs tenant='{1}'. LocationType is immutable per Microsoft Learn; rename the desired scope (Create+Orphan) or delete the tenant scope and re-apply. Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope" -f $d.locationType, $tenantHash.locationType)
                $blockedRows.Add([pscustomobject]@{
                    Category = 'Blocked'
                    Kind     = 'AdaptiveScope'
                    Name     = $d.name
                    Reason   = $reason
                    Field    = 'locationType'
                })
                $report.Add([pscustomobject]@{
                    Category = 'Blocked'
                    Kind     = 'AdaptiveScope'
                    Name     = $d.name
                    Reason   = $reason
                    Field    = 'locationType'
                })
            }
            default {
                throw ("Compare-AdaptiveScope returned unexpected action '{0}' for scope '{1}'." -f $decision.Action, $d.name)
            }
        }
    }

    # Orphans: tenant scopes not declared in YAML.
    foreach ($s in $tenantScopes) {
        $tenantName = [string]$s.Name
        if (-not $desiredByName.ContainsKey($tenantName)) {
            $orphanScopes.Add($s)
            $cat = if ($PruneMissing.IsPresent) { 'Orphan' } else { 'NoOp' }
            $reason = if ($PruneMissing.IsPresent) {
                'Tenant scope not in YAML; will Remove-AdaptiveScope under -PruneMissing.'
            } else {
                'Tenant scope not in YAML; skipped (use -PruneMissing to remove).'
            }
            $report.Add([pscustomobject]@{
                Category = $cat
                Kind     = 'AdaptiveScope'
                Name     = $tenantName
                Reason   = $reason
                Field    = ''
            })
        }
    }

    # ---- ADR 0029: direction-policy pass ----
    # Walk the Update entries in the plan and consult the shared
    # Resolve-DirectionPolicyAction (imported module) to decide Skip
    # vs. Update under the configured policy and SkipNames list. Create
    # entries are unaffected (no shared-property drift to arbitrate).
    # Blocked entries are immune (LocationType conflict cannot be
    # papered over by a direction policy).
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md

    # ADR 0052: every adaptive scope whose tenant fields this run WILL
    # overwrite. Constructed OUTSIDE the policy test below so the gate can
    # read .Count on it unconditionally -- under `audit` the pass never runs,
    # the list stays empty, and the gate correctly stays silent.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'
        $keptPlan      = @()
        foreach ($p in $plan) {
            if ($p.Action -ne 'Update') {
                $keptPlan += $p
                continue
            }
            $displayName = [string]$p.Desired.name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'AdaptiveScope'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = @($p.Fields)
                })
                continue
            }
            $fieldsText = @($p.Fields) -join ','
            Write-Warning ("repo-wins overwriting tenant on adaptive scope '{0}' fields: {1}" -f $displayName, $fieldsText)
            # Every Update entry that survived Resolve-DirectionPolicyAction's
            # Skip decision WILL be Set-, whatever policy let it through. The
            # ADR 0052 gate is keyed on this list -- the plan -- and never on
            # $DirectionPolicy. See ConfirmGate.psm1 "KEY THE GATE ON THE PLAN,
            # NOT ON THE POLICY".
            $repoWinsOverwrites.Add($displayName) | Out-Null
            $keptPlan += $p
        }

        if ($skipDecisions.Count -gt 0) {
            $plan.Clear()
            foreach ($k in $keptPlan) { $plan.Add($k) }

            # Drop existing Update report rows for skipped objects so
            # the plan summary shows the Skip row (and only the Skip
            # row) per skipped object.
            $skipKeyed = @{}
            foreach ($s in $skipDecisions) {
                $skipKeyed[("{0}|{1}" -f $s.Kind, $s.DisplayName)] = $true
            }
            $kept = @($report | Where-Object {
                -not ($_.Category -eq 'Update' -and $skipKeyed.ContainsKey(("{0}|{1}" -f $_.Kind, [string]$_.Name)))
            })
            $report.Clear()
            foreach ($r in $kept) { $report.Add($r) }
            foreach ($s in $skipDecisions) {
                $report.Add([pscustomobject]@{
                    Category = 'Skip'
                    Kind     = $s.Kind
                    Name     = $s.DisplayName
                    Reason   = $s.Reason
                    Field    = (@($s.Fields) -join ',')
                })
                # Machine-readable marker for the workflow's auto-PR
                # step. Format must match the exact regex
                # `^\[ADR0029-SKIP\] (.+)$` per the github-actions
                # instructions rule.
                Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
            }
        }
    }

    # Plan summary (pre-write).
    $planRows = $report |
        Group-Object Category, Kind, Name |
        ForEach-Object {
            $first = $_.Group[0]
            $fields = @($_.Group | Where-Object { $_.Field } | ForEach-Object { $_.Field }) -join ','
            [pscustomobject]@{
                Category = $first.Category
                Kind     = $first.Kind
                Name     = $first.Name
                Fields   = $fields
            }
        } |
        Sort-Object Category, Kind, Name

    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $planRows |
        Format-Table Category, Kind, Name, Fields -Wrap |
        Out-String |
        Write-Information -InformationAction Continue

    if ($blockedRows.Count -gt 0) {
        foreach ($b in $blockedRows) {
            Write-Error ("Adaptive scope '{0}' is Blocked: {1}" -f $b.Name, $b.Reason)
        }
        throw ("Reconciliation aborted: {0} scope(s) blocked. See plan summary above." -f $blockedRows.Count)
    }

    # ---- ADR 0029: audit-mode short-circuit ----
    # Mirrors Deploy-AutoLabelPolicies.ps1: keep the categorized report
    # for end-of-script emission but empty the plan and orphan list so
    # Phase 2 (session refresh) and Phase 3 (write) become no-ops
    # without breaking post-finally output handling.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit -- no writes would have fired. Plan above is read-only.' -InformationAction Continue
        $plan.Clear()
        $orphanScopes.Clear()
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before Phase 2/3 at which nothing has been written.
    # Both destructive branches are gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
    # unconditionally; ShouldProcess only prompts when ConfirmImpact >=
    # $ConfirmPreference, which is precisely the comparison that silently
    # defeated this gate before issue #85.
    #
    # Both gates are keyed on the PLAN -- the objects this run will actually
    # overwrite or delete -- and never on $DirectionPolicy. The gate sits
    # AFTER the audit short-circuit above, so an audit run (which empties both
    # the plan and the orphan list) presents an empty plan to both gates and
    # cannot prompt. The $yesToAll / $noToAll pair is shared, so a run that
    # trips both gates prompts once.
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

    if ($repoWinsOverwrites.Count -gt 0) {
        $overwriteNames = @($repoWinsOverwrites | Sort-Object -Unique)
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} adaptive scope(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
            $overwriteNames.Count, ($overwriteNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
            throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Derived from $orphanScopes -- the delete loop's own source -- one line
    # above the gate and read one line later, so it cannot diverge from the
    # deletes it speaks for.
    $pruneTargets = @($orphanScopes | ForEach-Object { [string]$_.Name })
    if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
        $pruneNames = @($pruneTargets | Sort-Object -Unique)
        $pruneQuery = "-PruneMissing will DELETE {0} orphan adaptive scope(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
            $pruneNames.Count, ($pruneNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # ---- Phase 2: Refresh session before any writes ----
    $writeCount = $plan.Count
    if ($PruneMissing.IsPresent) { $writeCount += $orphanScopes.Count }

    if ($writeCount -gt 0 -and -not $WhatIfPreference) {
        Write-Information ("Read phase complete. Refreshing S&C session before {0} write operation(s)." -f $writeCount) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose ("Pre-write Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
        }
        Remove-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $env:TEMP -Directory -Filter 'tmpEXO_*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Import-Module ExchangeOnlineManagement -Force -ErrorAction Stop

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Write-Information 'Reconnected to Security & Compliance PowerShell for write phase.' -InformationAction Continue
    }

    # ---- Phase 3: Write ----
    foreach ($entry in $plan) {
        $d = $entry.Desired
        $shouldProcessTarget = "Adaptive scope '{0}'" -f $d.name
        switch ($entry.Action) {

            'Create' {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
                $splat = Get-AdaptiveScopeSplat -Desired $d -Operation 'Create'
                $shouldProcessAction = "New-AdaptiveScope -LocationType {0}" -f $d.locationType
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    try {
                        New-AdaptiveScope @splat -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Created adaptive scope '{0}' (LocationType={1})." -f $d.name, $d.locationType) -InformationAction Continue
                    } catch {
                        if ($_.Exception.Message -match 'already exists') {
                            Write-Information ("Adaptive scope '{0}' already exists server-side; treating as no-op." -f $d.name) -InformationAction Continue
                            continue
                        }
                        Write-Error ("New-AdaptiveScope '{0}' failed: {1}" -f $d.name, $_.Exception.Message)
                        return
                    }
                }
            }

            'Update' {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-adaptivescope
                # Only `filterConditions` can be updated. `Name` is
                # identity (renames are Create+Orphan); `LocationType`
                # is immutable (Blocked at the diff stage).
                $splat = Get-AdaptiveScopeSplat -Desired $d -Operation 'Update'
                $shouldProcessAction = 'Set-AdaptiveScope -FilterConditions (JSON string)'
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    try {
                        Set-AdaptiveScope @splat -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Updated adaptive scope '{0}' FilterConditions." -f $d.name) -InformationAction Continue
                    } catch {
                        Write-Error ("Set-AdaptiveScope '{0}' (FilterConditions) failed: {1}" -f $d.name, $_.Exception.Message)
                        return
                    }
                }
            }
        }
    }

    if ($PruneMissing.IsPresent) {
        foreach ($s in $orphanScopes) {
            $tenantName = [string]$s.Name
            $shouldProcessTarget = "Adaptive scope '{0}'" -f $tenantName
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, 'Remove-AdaptiveScope')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-adaptivescope
                    Remove-AdaptiveScope -Identity $tenantName -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Removed orphan adaptive scope '{0}'." -f $tenantName) -InformationAction Continue
                } catch {
                    Write-Error ("Remove-AdaptiveScope '{0}' failed: {1}" -f $tenantName, $_.Exception.Message)
                    return
                }
            }
        }
    }

    #endregion
}
finally {
    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
    }
}

# Emit the structured drift report on the pipeline so callers can pipe
# to Format-Table / Out-File / ConvertTo-Json / >> $GITHUB_STEP_SUMMARY
# per `.github/instructions/powershell.instructions.md` ("Drift report
# format").
$report

#endregion
