#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only Microsoft Purview Data Security Posture Management (DSPM)
    signal-source posture verifier driven by
    `data-plane/dspm/dspm-config.yaml`.

.DESCRIPTION
    Wave 3a (issue #74) Phase 1 verifier. DSPM is a portal-rendered
    aggregator consuming signals authored in earlier waves
    (sensitivity labels, custom SITs, DLP, IRM, the unified audit
    log) per
    https://learn.microsoft.com/en-us/purview/dspm-get-started.
    There is no `New-DSPMPolicy` cmdlet surface, so this helper is
    intentionally NOT a `Deploy-*.ps1` reconciler -- it makes zero
    tenant writes.

    Local-only checks (always run):
      1. Schema-validate `data-plane/dspm/dspm-config.yaml` against
         `data-plane/dspm/dspm-config.schema.json` (Draft-07).
      2. Resolve every YAML referenced under `scope.labels.sources`
         and `scope.sits.sources`; flag any missing path.
      3. Confirm `export.artifactDir` is gitignored at repo root
         (warn-only; never commit live tenant data per ADR 0021).

    Optional tenant-side checks (require `-ConnectTenant`):
      4. Connect to Security & Compliance PowerShell via the
         workload-identity access-token path in
         `scripts/Get-PurviewIPPSAccessToken.ps1`
         (Key Vault-signed PS256 JWT per ADR 0011 Decision #3
         supersession).
      5. `Get-AdminAuditLogConfig` -- verify
         `UnifiedAuditLogIngestionEnabled = $true` per
         https://learn.microsoft.com/en-us/purview/audit-log-enable-disable.
      6. `Get-RoleGroup -Identity 'ContentExplorerListViewer'` --
         confirm the role group exists. Member resolution
         (data-plane workload identity assignment) ships in Phase 2.

    Output: a list of PSCustomObjects with columns Check / Status /
    Detail. Suitable for `| Format-Table` or capture to
    `$GITHUB_STEP_SUMMARY`. Statuses: `OK`, `Warn`, `Fail`. Exit code
    is 0 unless any `Fail` row is emitted.

    References (Microsoft Learn):
      DSPM overview:
        https://learn.microsoft.com/en-us/purview/dspm
      Get started with DSPM:
        https://learn.microsoft.com/en-us/purview/dspm-get-started
      Content Explorer:
        https://learn.microsoft.com/en-us/purview/data-classification-content-explorer
      Get-AdminAuditLogConfig:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
      Get-RoleGroup:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
      Connect-IPPSSession (-AccessToken):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0021 (Content Explorer export cadence):
        docs/adr/0021-dspm-content-explorer-cadence.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/dspm/dspm-config.yaml`.

.PARAMETER ConnectTenant
    Run the optional tenant-side checks (Get-AdminAuditLogConfig +
    Get-RoleGroup). Requires an active `az login` session and the
    full data-plane Entra app prerequisites described under .NOTES.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted,
    resolved from `automation.apps.dataPlane.certificateName`.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Test-DSPMPosture.ps1

    Local-only verification: schema + source-YAML resolution +
    artifactDir gitignore check. Makes no tenant calls.

.EXAMPLE
    ./scripts/Test-DSPMPosture.ps1 -ConnectTenant

    Local checks plus tenant-side audit-log and role-group checks.
    Requires `az login` and the data-plane app's `Compliance
    Administrator` role assignment (or equivalent read role on
    role-group / audit-config cmdlets).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).
      * Required only when `-ConnectTenant` is specified.

    Data-plane Entra app prerequisites (one-time per tenant, used
    only when `-ConnectTenant` is specified):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` (or
        equivalent that grants Get-AdminAuditLogConfig and
        Get-RoleGroup read access) assigned at directoryScopeId='/'.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\dspm\dspm-config.yaml'),

    [switch]$ConnectTenant,

    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

function New-PostureReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Factory returns a new in-memory List[object] sink; no system state is changed.')]
    param()
    # Returns a fresh System.Collections.Generic.List[object] sink.
    # Factored out so Pester can exercise Add-PostureRow without
    # touching script-scope state. Mirrors the helper shape in
    # scripts/Test-DSPMforAIPosture.ps1.
    , (New-Object 'System.Collections.Generic.List[object]')
}

function Add-PostureRow {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Report,

        [Parameter(Mandatory = $true)][string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'Warn', 'Fail')]
        [string]$Status,

        [Parameter(Mandatory = $true)][string]$Detail
    )
    $Report.Add([pscustomobject]@{
        Check  = $Check
        Status = $Status
        Detail = $Detail
    })
}

function Resolve-DSPMSourceEntryName {
    <#
    .SYNOPSIS
        Parse a desired-state source YAML (labels or SITs) into a
        sorted-unique list of entry display names.
    .DESCRIPTION
        Mirrors the per-source key vocabulary the exporter walks in
        scripts/Export-ContentExplorerData.ps1 -- labels live under
        `labels` / `sensitivityLabels`; SITs live under
        `classifications` / `sensitiveInformationTypes` / `sits`.
        Returns @() for null/missing input; callers treat that as
        "no entries from this source".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $YamlDoc,

        [Parameter(Mandatory = $true)]
        [ValidateSet('labels', 'sits')]
        [string]$Kind
    )
    if (-not $YamlDoc) { return @() }
    $candidateKeys = if ($Kind -eq 'labels') {
        @('labels', 'sensitivityLabels')
    } else {
        @('classifications', 'sensitiveInformationTypes', 'sits')
    }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $candidateKeys) {
        $rows = $null
        if ($YamlDoc -is [System.Collections.IDictionary]) {
            if ($YamlDoc.Contains($key)) { $rows = $YamlDoc[$key] }
        } else {
            $prop = $YamlDoc.PSObject.Properties[$key]
            if ($prop) { $rows = $prop.Value }
        }
        if (-not $rows) { continue }
        foreach ($row in @($rows)) {
            $name = if ($Kind -eq 'labels') { $row.displayName } else { $row.name }
            if (-not $name) {
                # Fall back to the alternate field shape (Export-ContentExplorerData.ps1
                # tolerates `name` for labels and `displayName` for SITs).
                $name = if ($Kind -eq 'labels') { $row.name } else { $row.displayName }
            }
            if ($name -and -not [string]::IsNullOrWhiteSpace([string]$name)) {
                $names.Add([string]$name)
            }
        }
    }
    @($names | Sort-Object -Unique)
}

function Resolve-DSPMIncludedScope {
    <#
    .SYNOPSIS
        Resolve the effective in-scope name list for a selector
        (`scope.labels` or `scope.sits`) given the upstream-YAML
        name list and the selector's `include` directive.
    .DESCRIPTION
        - include = 'all'  -> returns every name in $UpstreamNames.
        - include = @(...) -> returns the intersection (case-insensitive)
                              with $UpstreamNames, and reports any
                              requested-but-missing names via the
                              $MissingOut [ref] parameter.

        Mirrors the Resolve-IncludedLabel helper in
        scripts/Test-DSPMforAIPosture.ps1 so the contract is
        consistent across the two DSPM verifiers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Include,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$UpstreamNames,

        [Parameter(Mandatory = $false)]
        [ref]$MissingOut
    )
    if ($MissingOut) { $MissingOut.Value = @() }
    if ($Include -is [string] -and $Include -eq 'all') {
        return @($UpstreamNames)
    }
    if ($Include -is [System.Collections.IEnumerable] -and -not ($Include -is [string])) {
        $requested = @($Include | ForEach-Object { [string]$_ })
        $upstreamSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [string[]]$UpstreamNames, [System.StringComparer]::OrdinalIgnoreCase)
        $matched = foreach ($name in $requested) {
            if ($upstreamSet.Contains($name)) { $name }
        }
        $missing = foreach ($name in $requested) {
            if (-not $upstreamSet.Contains($name)) { $name }
        }
        if ($MissingOut) { $MissingOut.Value = @($missing) }
        return @($matched)
    }
    return @()
}

function Get-DSPMScopeCeilingStatus {
    <#
    .SYNOPSIS
        Classify a resolved DSPM scope-entry count against the
        ADR 0021 "Harder" section guard-rail thresholds.
    .DESCRIPTION
        ADR 0021 §"Harder" states:
            "if either set grows past ~25 entries, the run wall-clock
             crosses the 6-hour GitHub Actions job ceiling and the
             script will need a paging-per-workload partition."

        This helper maps a resolved (labels + SITs) entry count to
        one of three statuses:

          * OK   when entries <= 25
          * Warn when entries  > 25 and <= 100
          * Fail when entries  > 100

        The Fail ceiling at 4x Warn keeps a small buffer for one-off
        explorations (e.g., temporarily widening scope.sits to test
        a built-in SIT) while still hard-stopping the catastrophic
        re-introduction of the 327-entry sit-catalog.yaml the v2 §5.4
        drift closure removed (issue #366).

        Any future re-tune of these thresholds requires an amendment
        to ADR 0021, not an inline code change. Cited in
        docs/solutions/governance-foundation/dspm.md.

    .OUTPUTS
        [pscustomobject] with fields Status, Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$EntryCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 4)]
        [int]$WorkloadCount
    )
    $pairCount = $EntryCount * $WorkloadCount
    $detailFmt = "{0} scope entries x {1} workloads = {2} (item, Workload) pairs per run. ADR 0021 'Harder' threshold: 25 entries."
    if ($EntryCount -le 25) {
        return [pscustomobject]@{
            Status = 'OK'
            Detail = ($detailFmt -f $EntryCount, $WorkloadCount, $pairCount)
        }
    }
    if ($EntryCount -le 100) {
        return [pscustomobject]@{
            Status = 'Warn'
            Detail = ($detailFmt -f $EntryCount, $WorkloadCount, $pairCount) + ' Above the 25-entry ADR 0021 ceiling; verify the weekly run still fits the 6-hour Actions job and consider paging-per-workload partition.'
        }
    }
    return [pscustomobject]@{
        Status = 'Fail'
        Detail = ($detailFmt -f $EntryCount, $WorkloadCount, $pairCount) + ' Above 100 entries -- ADR 0021 paging-per-workload partition is required. Refusing to validate this scope.'
    }
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

#endregion

$report = New-PostureReport

function Add-Row {
    param(
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'Warn', 'Fail')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    Add-PostureRow -Report $report -Check $Check -Status $Status -Detail $Detail
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

#region Load + schema-validate desired-state YAML

if (-not (Test-Path -LiteralPath $Path)) {
    Add-Row -Check 'Load YAML' -Status 'Fail' -Detail ("Desired-state YAML not found at '{0}'." -f $Path)
    $report
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desired = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
if (-not $desired) {
    Add-Row -Check 'Load YAML' -Status 'Fail' -Detail ("'{0}' parsed as empty or null." -f $Path)
    $report
    exit 1
}
Add-Row -Check 'Load YAML' -Status 'OK' -Detail ("Loaded '{0}'." -f $Path)

# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\dspm\dspm-config.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Add-Row -Check 'Schema present' -Status 'Fail' -Detail ("Schema file not found at '{0}'." -f $schemaPath)
        $report
        exit 1
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $docJson    = $desired | ConvertTo-Json -Depth 10
    try {
        $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
        Add-Row -Check 'Schema valid' -Status 'OK' -Detail (Resolve-Path -LiteralPath $schemaPath).Path
    }
    catch {
        Add-Row -Check 'Schema valid' -Status 'Fail' -Detail $_.Exception.Message
        $report
        exit 1
    }
}

#endregion

#region Resolve upstream scope sources

$resolvedEntryCount = 0
foreach ($selectorName in @('labels', 'sits')) {
    $sel = $desired.scope.$selectorName
    $upstreamNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($srcRel in @($sel.sources)) {
        $srcAbs = Join-Path $repoRoot $srcRel
        if (Test-Path -LiteralPath $srcAbs) {
            Add-Row -Check ("scope.{0}.source" -f $selectorName) -Status 'OK' -Detail $srcRel
            $srcDoc = Get-Content -LiteralPath $srcAbs -Raw | ConvertFrom-Yaml
            foreach ($n in (Resolve-DSPMSourceEntryName -YamlDoc $srcDoc -Kind $selectorName)) {
                if (-not $upstreamNames.Contains($n)) { $upstreamNames.Add($n) }
            }
        } else {
            Add-Row -Check ("scope.{0}.source" -f $selectorName) -Status 'Fail' -Detail ("Path not found: '{0}'." -f $srcRel)
        }
    }
    $missing = $null
    $included = Resolve-DSPMIncludedScope `
        -Include       $sel.include `
        -UpstreamNames ([string[]]$upstreamNames) `
        -MissingOut    ([ref]$missing)
    if ($missing -and $missing.Count -gt 0) {
        Add-Row -Check ("scope.{0}.include" -f $selectorName) -Status 'Fail' -Detail ("Requested entries not present in upstream sources: {0}" -f ($missing -join ', '))
    } else {
        Add-Row -Check ("scope.{0}.include" -f $selectorName) -Status 'OK' -Detail ("{0} entry(ies) in scope" -f $included.Count)
    }
    $resolvedEntryCount += $included.Count
}

Add-Row -Check 'scope.workloads' -Status 'OK' -Detail (@($desired.scope.workloads) -join ', ')

# Ceiling guard rail per ADR 0021 §"Harder". The v2 §5.4 drift closure
# (issue #366) removed the 327-entry sit-catalog.yaml from
# scope.sits.sources because enumerating it pushed the weekly plan to
# ~1,352 (item, Workload) pairs. This row catches future re-introductions
# of similar scope-explosion patterns before they ship. Thresholds are
# pinned to ADR 0021 'Harder' (25 entries); any re-tune requires an ADR
# amendment, not an inline code change.
$workloadCount = @($desired.scope.workloads).Count
$ceiling = Get-DSPMScopeCeilingStatus -EntryCount $resolvedEntryCount -WorkloadCount $workloadCount
Add-Row -Check 'scope.entries.ceiling' -Status $ceiling.Status -Detail $ceiling.Detail

#endregion

#region artifactDir is gitignored

$artifactDir       = [string]$desired.export.artifactDir
$gitignorePath     = Join-Path $repoRoot '.gitignore'
$gitignoreLines    = if (Test-Path -LiteralPath $gitignorePath) { Get-Content -LiteralPath $gitignorePath } else { @() }
$ignoreCandidates  = @($artifactDir, ('{0}/' -f $artifactDir.TrimEnd('/')))
$gitignored        = $false
foreach ($cand in $ignoreCandidates) {
    if ($gitignoreLines -contains $cand) { $gitignored = $true; break }
}
if ($gitignored) {
    Add-Row -Check 'artifactDir gitignored' -Status 'OK' -Detail $artifactDir
} else {
    Add-Row -Check 'artifactDir gitignored' -Status 'Warn' -Detail ("'{0}' not listed in .gitignore -- exports must never land in source per ADR 0021." -f $artifactDir)
}

#endregion

#region Optional tenant-side checks

if ($ConnectTenant.IsPresent) {

    # Parameters file resolution (mirrors Deploy-IRMPolicies.ps1).
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
        Add-Row -Check 'Parameters file' -Status 'Fail' -Detail ("Not found: '{0}'." -f $ParametersFile)
        $report
        exit 1
    }
    $ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
    $parameters     = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
    if (-not $parameters) {
        Add-Row -Check 'Parameters file' -Status 'Fail' -Detail ("'{0}' parsed as empty or null." -f $ParametersFile)
        $report
        exit 1
    }
    foreach ($key in @('resources', 'automation')) {
        if (-not $parameters.ContainsKey($key)) {
            Add-Row -Check 'Parameters file' -Status 'Fail' -Detail ("Missing top-level key '{0}'." -f $key)
            $report
            exit 1
        }
    }
    if (-not $parameters.resources.ContainsKey('keyVault') -or
        -not $parameters.resources.keyVault.ContainsKey('name')) {
        Add-Row -Check 'Parameters file' -Status 'Fail' -Detail "Missing 'resources.keyVault.name'."
        $report
        exit 1
    }
    if (-not $parameters.automation.ContainsKey('tenantDomain') -or
        -not $parameters.automation.ContainsKey('apps') -or
        -not $parameters.automation.apps.ContainsKey('dataPlane')) {
        Add-Row -Check 'Parameters file' -Status 'Fail' -Detail "Missing 'automation.tenantDomain' or 'automation.apps.dataPlane'."
        $report
        exit 1
    }
    foreach ($key in @('displayName', 'certificateName')) {
        if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
            Add-Row -Check 'Parameters file' -Status 'Fail' -Detail ("Missing 'automation.apps.dataPlane.{0}'." -f $key)
            $report
            exit 1
        }
    }

    if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
    if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
    if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
    if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

    Add-Row -Check 'Parameters file' -Status 'OK' -Detail $ParametersFile

    # ExchangeOnlineManagement v3.8.0-Preview1+ required for
    # Connect-IPPSSession -AccessToken.
    # Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
    $module = 'ExchangeOnlineManagement'
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
    }
    Import-Module $module -ErrorAction Stop

    # Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
    $accountJson = az account show -o json --only-show-errors 2>$null
    if (-not $accountJson) {
        Add-Row -Check 'Azure CLI session' -Status 'Fail' -Detail 'No active az session. Run `az login`.'
        $report
        exit 1
    }
    $account  = ($accountJson -join "`n") | ConvertFrom-Json
    $tenantId = [string]$account.tenantId
    if (-not $tenantId) {
        Add-Row -Check 'Azure CLI session' -Status 'Fail' -Detail 'az account show did not return a tenantId.'
        $report
        exit 1
    }
    Add-Row -Check 'Azure CLI session' -Status 'OK' -Detail ("Subscription '{0}'." -f $account.name)

    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
    $appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $appListJson) {
        Add-Row -Check 'Data-plane app' -Status 'Fail' -Detail ("az ad app list failed for '{0}'." -f $DataPlaneAppDisplayName)
        $report
        exit 1
    }
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
    if ($appList.Count -ne 1) {
        Add-Row -Check 'Data-plane app' -Status 'Fail' -Detail ("Found {0} apps with display name '{1}'; expected exactly 1." -f $appList.Count, $DataPlaneAppDisplayName)
        $report
        exit 1
    }
    $appId = [string]$appList[0].appId
    Add-Row -Check 'Data-plane app' -Status 'OK' -Detail $DataPlaneAppDisplayName

    # Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
    $tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
    if (-not (Test-Path -LiteralPath $tokenScript)) {
        Add-Row -Check 'Token helper' -Status 'Fail' -Detail ("Not found: '{0}'." -f $tokenScript)
        $report
        exit 1
    }
    $tok = & $tokenScript `
        -VaultName       $VaultName `
        -CertificateName $CertificateName `
        -AppId           $appId `
        -TenantId        $tenantId
    if (-not $tok -or -not $tok.AccessToken) {
        Add-Row -Check 'Token helper' -Status 'Fail' -Detail 'Get-PurviewIPPSAccessToken.ps1 returned no token.'
        $report
        exit 1
    }
    Add-Row -Check 'Token helper' -Status 'OK' -Detail ("Token scope {0}." -f $tok.Scope)

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Add-Row -Check 'Connect-IPPSSession' -Status 'OK' -Detail $TenantDomain

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
        $auditCfg = Get-AdminAuditLogConfig -ErrorAction Stop
        if ([bool]$auditCfg.UnifiedAuditLogIngestionEnabled) {
            Add-Row -Check 'Unified audit log enabled' -Status 'OK' -Detail 'UnifiedAuditLogIngestionEnabled=True'
        } else {
            Add-Row -Check 'Unified audit log enabled' -Status 'Fail' -Detail 'UnifiedAuditLogIngestionEnabled=False -- DSPM signals are degraded.'
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
        $rg = Get-RoleGroup -Identity 'ContentExplorerListViewer' -ErrorAction SilentlyContinue
        if ($rg) {
            Add-Row -Check 'ContentExplorerListViewer role group' -Status 'OK' -Detail 'Present (member assignment for the workload identity ships in Phase 2).'
        } else {
            Add-Row -Check 'ContentExplorerListViewer role group' -Status 'Fail' -Detail 'Role group not visible to the data-plane app.'
        }
    }
    finally {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
        }
    }
}

#endregion

$report

if ($report | Where-Object { $_.Status -eq 'Fail' }) {
    exit 1
}
exit 0
