#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only Microsoft Purview Data Security Posture Management
    (DSPM) for AI posture verifier driven by
    `data-plane/dspm-ai/dspm-ai-config.yaml`.

.DESCRIPTION
    Wave 3b (issue #75) Phase 2 verifier. Per ADR 0022 Microsoft Learn
    documents no programmatic authoring API for DSPM for AI -- the
    "Activate Microsoft Purview for AI" path is a one-click portal
    action that fans out to already-shipped surfaces (DLP, IRM,
    Communication Compliance, audit). This helper is intentionally
    NOT a `Deploy-*.ps1` reconciler -- it makes zero tenant writes.

    Local-only checks (always run):
      1. Schema-validate `data-plane/dspm-ai/dspm-ai-config.yaml`
         against `data-plane/dspm-ai/dspm-ai-config.schema.json`
         (Draft-07).
      2. Resolve every YAML referenced under `scope.labels.sources`;
         flag any missing path.
      3. Report `scope.workloads` and `scope.roleGroups`.

    Optional tenant-side checks (require `-ConnectTenant`):
      4. Connect to Security & Compliance PowerShell via the
         workload-identity access-token path in
         `scripts/Get-PurviewIPPSAccessToken.ps1` (Key Vault-signed
         PS256 JWT per ADR 0011 Decision #3 supersession).
      5. `Get-AdminAuditLogConfig` -- verify
         `UnifiedAuditLogIngestionEnabled = $true` per
         https://learn.microsoft.com/en-us/purview/audit-log-enable-disable.
      6. `Get-RoleGroup -Identity <name>` for every entry in
         `scope.roleGroups` -- confirm each AI role group exists.
         Operators populate this list from
         https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions.
      7. `Get-Label -Identity <name>` for every label resolved by the
         scope -- confirm each is published. `include: all` expands
         to the displayName list parsed from the source YAML.

    Output: a list of PSCustomObjects with columns Check / Status /
    Detail. Statuses: `OK`, `Warn`, `Fail`. Exit code is 0 unless any
    `Fail` row is emitted.

    References (Microsoft Learn):
      DSPM for AI overview:
        https://learn.microsoft.com/en-us/purview/dspm-for-ai
      Considerations for deploying Microsoft Purview AI controls:
        https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations
      Permissions for Microsoft Purview AI features:
        https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions
      Get-AdminAuditLogConfig:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
      Get-RoleGroup:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
      Get-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
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
      ADR 0022 (DSPM for AI authoring surface):
        docs/adr/0022-dspm-for-ai-authoring-surface.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/dspm-ai/dspm-ai-config.yaml`.

.PARAMETER ConnectTenant
    Run the optional tenant-side checks. Requires an active `az login`
    session and the data-plane Entra app prerequisites described
    under .NOTES.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml`.

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
    ./scripts/Test-DSPMforAIPosture.ps1

    Local-only verification: schema + source-YAML resolution.
    Makes no tenant calls.

.EXAMPLE
    ./scripts/Test-DSPMforAIPosture.ps1 -ConnectTenant

    Local checks plus tenant-side audit-log, role-group, and
    label-published checks. Requires `az login` and the data-plane
    app's read role on Get-AdminAuditLogConfig / Get-RoleGroup /
    Get-Label.

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
        equivalent that grants Get-AdminAuditLogConfig, Get-RoleGroup,
        and Get-Label read access) assigned at directoryScopeId='/'.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\dspm-ai\dspm-ai-config.yaml'),

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
    # touching script-scope state.
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

function Get-LabelDisplayName {
    <#
    .SYNOPSIS
        Parse a labels.yaml document into a sorted-unique array of
        label displayNames.
    .DESCRIPTION
        Used by both the verifier orchestrator and its Pester tests.
        Accepts a hashtable already produced by ConvertFrom-Yaml.
        Returns @() for null/empty input -- callers treat that as
        "no labels in scope" (check passes vacuously).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $YamlDoc
    )
    if (-not $YamlDoc) { return @() }
    $labels = $YamlDoc.labels
    if (-not $labels) { return @() }
    $names = foreach ($entry in @($labels)) {
        if ($null -ne $entry.displayName -and -not [string]::IsNullOrWhiteSpace([string]$entry.displayName)) {
            [string]$entry.displayName
        }
    }
    @($names | Sort-Object -Unique)
}

function Resolve-IncludedLabel {
    <#
    .SYNOPSIS
        Resolve the effective in-scope label name list given an
        `include` selector and the upstream-YAML displayName list.
    .DESCRIPTION
        - include = 'all'  -> returns every name from $UpstreamNames.
        - include = @(...) -> returns the intersection with $UpstreamNames
                              and reports the missing entries via
                              $MissingOut (out parameter shaped as a
                              [ref] to an array).
    #>
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
        $upstreamSet = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$UpstreamNames, [System.StringComparer]::OrdinalIgnoreCase)
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

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

#region Load + schema-validate desired-state YAML

if (-not (Test-Path -LiteralPath $Path)) {
    Add-PostureRow -Report $report -Check 'Load YAML' -Status 'Fail' -Detail ("Desired-state YAML not found at '{0}'." -f $Path)
    $report
    exit 1
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desired = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
if (-not $desired) {
    Add-PostureRow -Report $report -Check 'Load YAML' -Status 'Fail' -Detail ("'{0}' parsed as empty or null." -f $Path)
    $report
    exit 1
}
Add-PostureRow -Report $report -Check 'Load YAML' -Status 'OK' -Detail ("Loaded '{0}'." -f $Path)

# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\dspm-ai\dspm-ai-config.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Add-PostureRow -Report $report -Check 'Schema present' -Status 'Fail' -Detail ("Schema file not found at '{0}'." -f $schemaPath)
        $report
        exit 1
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $docJson    = $desired | ConvertTo-Json -Depth 10
    try {
        $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
        Add-PostureRow -Report $report -Check 'Schema valid' -Status 'OK' -Detail (Resolve-Path -LiteralPath $schemaPath).Path
    }
    catch {
        Add-PostureRow -Report $report -Check 'Schema valid' -Status 'Fail' -Detail $_.Exception.Message
        $report
        exit 1
    }
}

#endregion

#region Resolve scope

$labelSources    = @($desired.scope.labels.sources)
$resolvedSources = New-Object 'System.Collections.Generic.List[string]'
foreach ($srcRel in $labelSources) {
    $srcAbs = Join-Path $repoRoot $srcRel
    if (Test-Path -LiteralPath $srcAbs) {
        Add-PostureRow -Report $report -Check 'scope.labels.source' -Status 'OK' -Detail $srcRel
        $resolvedSources.Add((Resolve-Path -LiteralPath $srcAbs).Path)
    } else {
        Add-PostureRow -Report $report -Check 'scope.labels.source' -Status 'Fail' -Detail ("Path not found: '{0}'." -f $srcRel)
    }
}

# Expand `include` into a concrete name list parsed from the source
# YAMLs. Tenant-side Get-Label calls iterate this list when
# -ConnectTenant is set.
$upstreamNames = New-Object 'System.Collections.Generic.List[string]'
foreach ($srcAbs in $resolvedSources) {
    $srcDoc = Get-Content -LiteralPath $srcAbs -Raw | ConvertFrom-Yaml
    foreach ($n in (Get-LabelDisplayName -YamlDoc $srcDoc)) {
        if (-not $upstreamNames.Contains($n)) { $upstreamNames.Add($n) }
    }
}

$missingFromSources = $null
$inScopeLabels = Resolve-IncludedLabel `
    -Include       $desired.scope.labels.include `
    -UpstreamNames ([string[]]$upstreamNames) `
    -MissingOut    ([ref]$missingFromSources)

if ($missingFromSources -and $missingFromSources.Count -gt 0) {
    Add-PostureRow -Report $report -Check 'scope.labels.include' -Status 'Fail' -Detail ("Requested labels not present in upstream sources: {0}" -f ($missingFromSources -join ', '))
} else {
    $detail = if ($inScopeLabels.Count -gt 0) {
        "{0} label(s) in scope" -f $inScopeLabels.Count
    } else {
        'No labels in scope (sources empty).'
    }
    Add-PostureRow -Report $report -Check 'scope.labels.include' -Status 'OK' -Detail $detail
}

Add-PostureRow -Report $report -Check 'scope.workloads' -Status 'OK' -Detail (@($desired.scope.workloads) -join ', ')

$roleGroupNames = @($desired.scope.roleGroups)
if ($roleGroupNames.Count -eq 0) {
    Add-PostureRow -Report $report -Check 'scope.roleGroups' -Status 'Warn' -Detail 'No role groups configured. Populate from https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions once Deploy-PurviewRoleGroups.ps1 provisions the AI role groups your tenant uses.'
} else {
    Add-PostureRow -Report $report -Check 'scope.roleGroups' -Status 'OK' -Detail ($roleGroupNames -join ', ')
}

Add-PostureRow -Report $report -Check 'posture.cadence' -Status 'OK' -Detail ([string]$desired.posture.cadence)

#endregion

#region Optional tenant-side checks

if ($ConnectTenant.IsPresent) {

    if (-not $ParametersFile) {
        $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
    if (-not (Test-Path -LiteralPath $ParametersFile)) {
        Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail ("Not found: '{0}'." -f $ParametersFile)
        $report
        exit 1
    }
    $ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
    $parameters     = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
    if (-not $parameters) {
        Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail ("'{0}' parsed as empty or null." -f $ParametersFile)
        $report
        exit 1
    }
    foreach ($key in @('resources', 'automation')) {
        if (-not $parameters.ContainsKey($key)) {
            Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail ("Missing top-level key '{0}'." -f $key)
            $report
            exit 1
        }
    }
    if (-not $parameters.resources.ContainsKey('keyVault') -or
        -not $parameters.resources.keyVault.ContainsKey('name')) {
        Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail "Missing 'resources.keyVault.name'."
        $report
        exit 1
    }
    if (-not $parameters.automation.ContainsKey('tenantDomain') -or
        -not $parameters.automation.ContainsKey('apps') -or
        -not $parameters.automation.apps.ContainsKey('dataPlane')) {
        Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail "Missing 'automation.tenantDomain' or 'automation.apps.dataPlane'."
        $report
        exit 1
    }
    foreach ($key in @('displayName', 'certificateName')) {
        if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
            Add-PostureRow -Report $report -Check 'Parameters file' -Status 'Fail' -Detail ("Missing 'automation.apps.dataPlane.{0}'." -f $key)
            $report
            exit 1
        }
    }

    if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
    if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
    if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
    if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

    Add-PostureRow -Report $report -Check 'Parameters file' -Status 'OK' -Detail $ParametersFile

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
        Add-PostureRow -Report $report -Check 'Azure CLI session' -Status 'Fail' -Detail 'No active az session. Run `az login`.'
        $report
        exit 1
    }
    $account  = ($accountJson -join "`n") | ConvertFrom-Json
    $tenantId = [string]$account.tenantId
    if (-not $tenantId) {
        Add-PostureRow -Report $report -Check 'Azure CLI session' -Status 'Fail' -Detail 'az account show did not return a tenantId.'
        $report
        exit 1
    }
    Add-PostureRow -Report $report -Check 'Azure CLI session' -Status 'OK' -Detail ("Subscription '{0}'." -f $account.name)

    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
    $appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $appListJson) {
        Add-PostureRow -Report $report -Check 'Data-plane app' -Status 'Fail' -Detail ("az ad app list failed for '{0}'." -f $DataPlaneAppDisplayName)
        $report
        exit 1
    }
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
    if ($appList.Count -ne 1) {
        Add-PostureRow -Report $report -Check 'Data-plane app' -Status 'Fail' -Detail ("Found {0} apps with display name '{1}'; expected exactly 1." -f $appList.Count, $DataPlaneAppDisplayName)
        $report
        exit 1
    }
    $appId = [string]$appList[0].appId
    Add-PostureRow -Report $report -Check 'Data-plane app' -Status 'OK' -Detail $DataPlaneAppDisplayName

    # Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
    $tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
    if (-not (Test-Path -LiteralPath $tokenScript)) {
        Add-PostureRow -Report $report -Check 'Token helper' -Status 'Fail' -Detail ("Not found: '{0}'." -f $tokenScript)
        $report
        exit 1
    }
    $tok = & $tokenScript `
        -VaultName       $VaultName `
        -CertificateName $CertificateName `
        -AppId           $appId `
        -TenantId        $tenantId
    if (-not $tok -or -not $tok.AccessToken) {
        Add-PostureRow -Report $report -Check 'Token helper' -Status 'Fail' -Detail 'Get-PurviewIPPSAccessToken.ps1 returned no token.'
        $report
        exit 1
    }
    Add-PostureRow -Report $report -Check 'Token helper' -Status 'OK' -Detail ("Token scope {0}." -f $tok.Scope)

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Add-PostureRow -Report $report -Check 'Connect-IPPSSession' -Status 'OK' -Detail $TenantDomain

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
        $auditCfg = Get-AdminAuditLogConfig -ErrorAction Stop
        if ([bool]$auditCfg.UnifiedAuditLogIngestionEnabled) {
            Add-PostureRow -Report $report -Check 'Unified audit log enabled' -Status 'OK' -Detail 'UnifiedAuditLogIngestionEnabled=True'
        } else {
            Add-PostureRow -Report $report -Check 'Unified audit log enabled' -Status 'Fail' -Detail 'UnifiedAuditLogIngestionEnabled=False -- DSPM-for-AI signals are degraded.'
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroup
        foreach ($rgName in $roleGroupNames) {
            $rg = Get-RoleGroup -Identity $rgName -ErrorAction SilentlyContinue
            if ($rg) {
                Add-PostureRow -Report $report -Check ("Role group '{0}'" -f $rgName) -Status 'OK' -Detail 'Present.'
            } else {
                Add-PostureRow -Report $report -Check ("Role group '{0}'" -f $rgName) -Status 'Fail' -Detail 'Role group not visible to the data-plane app.'
            }
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
        foreach ($labelName in $inScopeLabels) {
            $lbl = Get-Label -Identity $labelName -ErrorAction SilentlyContinue
            if (-not $lbl) {
                Add-PostureRow -Report $report -Check ("Label '{0}'" -f $labelName) -Status 'Fail' -Detail 'Label not found in tenant.'
                continue
            }
            $disabled = $false
            try { $disabled = [bool]$lbl.Disabled } catch { $disabled = $false }
            if ($disabled) {
                Add-PostureRow -Report $report -Check ("Label '{0}'" -f $labelName) -Status 'Fail' -Detail 'Label exists but is Disabled.'
            } else {
                Add-PostureRow -Report $report -Check ("Label '{0}'" -f $labelName) -Status 'OK' -Detail 'Present and enabled.'
            }
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
