#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only Microsoft Purview Content Explorer exporter driven by
    `data-plane/dspm/dspm-config.yaml`.

.DESCRIPTION
    Wave 3a (issue #74) Phase 1 exporter. Iterates the union of
    (published sensitivity labels) and (custom Sensitive Information
    Types) across the workloads declared in
    `data-plane/dspm/dspm-config.yaml`, calling
    `Get-ContentExplorerData` once per (item, Workload) pair. One
    JSON document is written per pair; a `manifest.json` records
    invocation context, scope hash, throttle settings, per-row
    status, and any retries.

    The exporter is intentionally NOT a `Deploy-*.ps1` reconciler --
    Content Explorer is a read API. No tenant writes are issued.

    Cadence + retention + throttling all come from ADR 0021. The
    artifact directory is gitignored; exports must never land in
    source.

    Local-only safety:
      * `-WhatIf` (default off) emits the resolved (item, Workload)
        plan as a PSCustomObject stream and writes no files. Use
        this to dry-run scope changes.

    Live mode:
      * Acquires a workload-identity access token via
        `scripts/Get-PurviewIPPSAccessToken.ps1`
        (Key Vault-signed PS256 JWT per ADR 0011 Decision #3
        supersession), opens an Security & Compliance PowerShell
        session via `Connect-IPPSSession -AccessToken`, and pages
        `Get-ContentExplorerData` with `Start-Sleep` between calls
        and exponential-backoff retries on transient HTTP 429.
      * Partial failure exits non-zero; the manifest captures every
        attempt so reviewers can see which (item, Workload) rows
        failed.

    References (Microsoft Learn):
      Content Explorer overview:
        https://learn.microsoft.com/en-us/purview/data-classification-content-explorer
      Get-ContentExplorerData:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata
      Connect-IPPSSession (-AccessToken):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Disconnect-ExchangeOnline:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0021 (cadence + scope + retention):
        docs/adr/0021-dspm-content-explorer-cadence.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to
    `data-plane/dspm/dspm-config.yaml`.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

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

.PARAMETER OutputRoot
    Optional override for the artifact root directory. Defaults to
    `<repoRoot>/<export.artifactDir>` from the desired-state YAML.

.PARAMETER PageSize
    Page size passed to `Get-ContentExplorerData -PageSize`. Allowed
    range per the cmdlet reference is 1-100; default 100.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Export-ContentExplorerData.ps1 -WhatIf

    Resolves the scope and prints the (item, Workload) plan only.
    Makes no tenant calls. Writes no files.

.EXAMPLE
    ./scripts/Export-ContentExplorerData.ps1

    Live mode. Connects to Security & Compliance PowerShell, pages
    Get-ContentExplorerData for every (item, Workload) pair, writes
    one JSON per pair plus a manifest into
    `verify-dspm-export-output/<YYYY-MM-DD-HHmm>/`.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Membership in the `ContentExplorerListViewer` role group is
        required to receive non-empty Get-ContentExplorerData results;
        the assignment ships in Phase 2 (separate issue). Until then
        the cmdlet returns 401/403 and the exporter exits non-zero.

    Phase 2 scope (deferred):
      * `.github/workflows/export-content-explorer.yml` -- cron
        `0 7 * * 1` + workflow_dispatch + 90-day artifact retention
        per ADR 0021 Decision 1 / 5.
      * Adding the data-plane workload identity to the
        `ContentExplorerListViewer` role group.
      * Live JSON-shape contract test in tests/.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\dspm\dspm-config.yaml'),

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

    [string]$OutputRoot,

    [ValidateRange(1, 100)]
    [int]$PageSize = 100,

    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

#endregion

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

#region Load + schema-validate desired-state YAML

if (-not (Test-Path -LiteralPath $Path)) {
    throw ("Desired-state YAML not found at '{0}'." -f $Path)
}
$Path    = (Resolve-Path -LiteralPath $Path).Path
$desired = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
if (-not $desired) {
    throw ("'{0}' parsed as empty or null." -f $Path)
}

# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\dspm\dspm-config.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        throw ("Schema file not found at '{0}'." -f $schemaPath)
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $docJson    = $desired | ConvertTo-Json -Depth 10
    $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
}

$workloads       = @($desired.scope.workloads)
$artifactDir     = [string]$desired.export.artifactDir
$throttleSeconds = [double]$desired.export.throttleSeconds
$maxRetries      = [int]$desired.export.maxRetries

#endregion

#region Resolve scope from upstream YAMLs

function Get-RowField {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Field
    )
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) {
        if ($Row.Contains($Field)) { return $Row[$Field] } else { return $null }
    }
    $prop = $Row.PSObject.Properties[$Field]
    if ($prop) { return $prop.Value } else { return $null }
}

function Test-DocHasKey {
    param(
        [Parameter(Mandatory = $true)]$Doc,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if ($Doc -is [System.Collections.IDictionary]) { return $Doc.Contains($Key) }
    return [bool]($Doc.PSObject.Properties[$Key])
}

function Resolve-LabelScope {
    param([Parameter(Mandatory = $true)]$Selector)
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($srcRel in @($Selector.sources)) {
        $srcAbs = Join-Path $repoRoot $srcRel
        if (-not (Test-Path -LiteralPath $srcAbs)) { continue }
        $doc = Get-Content -LiteralPath $srcAbs -Raw | ConvertFrom-Yaml
        if (-not $doc) { continue }
        foreach ($candidateKey in @('labels', 'sensitivityLabels')) {
            if (Test-DocHasKey -Doc $doc -Key $candidateKey) {
                foreach ($row in @($doc[$candidateKey])) {
                    $display = Get-RowField -Row $row -Field 'displayName'
                    if ($display) { $items.Add([string]$display); continue }
                    $name = Get-RowField -Row $row -Field 'name'
                    if ($name) { $items.Add([string]$name) }
                }
            }
        }
    }
    $items | Sort-Object -Unique
}

function Resolve-SitScope {
    param([Parameter(Mandatory = $true)]$Selector)
    $items = New-Object 'System.Collections.Generic.List[string]'
    foreach ($srcRel in @($Selector.sources)) {
        $srcAbs = Join-Path $repoRoot $srcRel
        if (-not (Test-Path -LiteralPath $srcAbs)) { continue }
        $doc = Get-Content -LiteralPath $srcAbs -Raw | ConvertFrom-Yaml
        if (-not $doc) { continue }
        foreach ($candidateKey in @('classifications', 'sensitiveInformationTypes', 'sits')) {
            if (Test-DocHasKey -Doc $doc -Key $candidateKey) {
                foreach ($row in @($doc[$candidateKey])) {
                    $name = Get-RowField -Row $row -Field 'name'
                    if ($name) { $items.Add([string]$name); continue }
                    $display = Get-RowField -Row $row -Field 'displayName'
                    if ($display) { $items.Add([string]$display) }
                }
            }
        }
    }
    $items | Sort-Object -Unique
}

$labelInclude = $desired.scope.labels.include
$sitInclude   = $desired.scope.sits.include

$labels = if ($labelInclude -is [string] -and $labelInclude -eq 'all') {
    Resolve-LabelScope -Selector $desired.scope.labels
} else {
    @($labelInclude)
}

$sits = if ($sitInclude -is [string] -and $sitInclude -eq 'all') {
    Resolve-SitScope -Selector $desired.scope.sits
} else {
    @($sitInclude)
}

$plan = New-Object 'System.Collections.Generic.List[object]'
foreach ($wl in $workloads) {
    foreach ($l in $labels) {
        $plan.Add([pscustomobject]@{ Kind = 'Label'; Name = $l; Workload = $wl })
    }
    foreach ($s in $sits) {
        $plan.Add([pscustomobject]@{ Kind = 'SIT';   Name = $s; Workload = $wl })
    }
}

#endregion

#region -WhatIf short-circuit

if ($WhatIfPreference) {
    Write-Information ("Plan: {0} (item, Workload) pairs ({1} labels, {2} SITs, {3} workloads)." -f $plan.Count, $labels.Count, $sits.Count, $workloads.Count) -InformationAction Continue
    return $plan
}

if ($plan.Count -eq 0) {
    Write-Warning 'Resolved plan is empty -- nothing to export. Confirm upstream YAMLs contain entries.'
    return
}

#endregion

#region Parameters file resolution (live mode)

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    throw ("Parameters file not found at '{0}'." -f $ParametersFile)
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
$parameters     = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    throw ("'{0}' parsed as empty or null." -f $ParametersFile)
}
foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        throw ("Parameters file '{0}' missing top-level key '{1}'." -f $ParametersFile, $key)
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    throw ("Parameters file '{0}' missing 'resources.keyVault.name'." -f $ParametersFile)
}
if (-not $parameters.automation.ContainsKey('tenantDomain') -or
    -not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    throw ("Parameters file '{0}' missing 'automation.tenantDomain' or 'automation.apps.dataPlane'." -f $ParametersFile)
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        throw ("Parameters file '{0}' missing 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key)
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

#endregion

#region Output directory

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $repoRoot $artifactDir
}
$timestamp = (Get-Date).ToString('yyyy-MM-dd-HHmm')
$runDir    = Join-Path $OutputRoot $timestamp
if (-not (Test-Path -LiteralPath $runDir)) {
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
}

#endregion

#region Module dependencies (live mode)

# ExchangeOnlineManagement v3.8.0-Preview1+ required for
# Connect-IPPSSession -AccessToken.
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

#endregion

#region Acquire token + connect

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    throw 'No active az session. Run `az login` first.'
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    throw 'az account show did not return a tenantId.'
}

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0 -or -not $appListJson) {
    throw ("az ad app list failed for display name '{0}'." -f $DataPlaneAppDisplayName)
}
$appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
if ($appList.Count -ne 1) {
    throw ("Found {0} apps with display name '{1}'; expected exactly 1." -f $appList.Count, $DataPlaneAppDisplayName)
}
$appId = [string]$appList[0].appId

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) {
    throw ("Token helper not found at '{0}'." -f $tokenScript)
}
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId
if (-not $tok -or -not $tok.AccessToken) {
    throw 'Get-PurviewIPPSAccessToken.ps1 returned no token.'
}

$manifestRows = New-Object 'System.Collections.Generic.List[object]'
$anyFailure   = $false

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null

    foreach ($row in $plan) {
        $rowStart = Get-Date
        $itemSlug = ($row.Name -replace '[^A-Za-z0-9\-_.]+', '_')
        $kindTag  = if ($row.Kind -eq 'Label') { 'Tag' } else { 'TagName' }
        $outFile  = Join-Path $runDir ("{0}__{1}__{2}.json" -f $row.Kind, $itemSlug, $row.Workload)

        $attempt   = 0
        $succeeded = $false
        $pages     = New-Object 'System.Collections.Generic.List[object]'
        $cookie    = $null
        $lastError = $null

        do {
            try {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata
                $params = @{
                    Workload    = $row.Workload
                    PageSize    = $PageSize
                    ErrorAction = 'Stop'
                }
                $params[$kindTag] = $row.Name
                if ($cookie) { $params['PageCookie'] = $cookie }

                if (-not $PSCmdlet.ShouldProcess(
                        ('{0}={1} Workload={2}' -f $kindTag, $row.Name, $row.Workload),
                        'Get-ContentExplorerData')) {
                    break
                }
                $page = Get-ContentExplorerData @params
                if ($null -ne $page) {
                    $pages.Add($page)
                    $cookie = $page.PageCookie
                } else {
                    $cookie = $null
                }
                $succeeded = $true
            }
            catch {
                $lastError = $_.Exception.Message
                $isThrottle = $lastError -match '(?i)429|throttl|too many requests'
                if ($isThrottle -and $attempt -lt $maxRetries) {
                    $attempt++
                    $delay = [math]::Pow(2, $attempt)
                    Write-Warning ("Throttled on '{0}/{1}'; retry {2}/{3} after {4}s." -f $row.Name, $row.Workload, $attempt, $maxRetries, $delay)
                    Start-Sleep -Seconds $delay
                    continue
                }
                break
            }

            if ($cookie) { Start-Sleep -Seconds $throttleSeconds }
        } while ($cookie)

        if ($succeeded) {
            $pages | ConvertTo-Json -Depth 12 | Out-File -LiteralPath $outFile -Encoding utf8
            $manifestRows.Add([pscustomobject]@{
                Kind     = $row.Kind
                Name     = $row.Name
                Workload = $row.Workload
                Status   = 'OK'
                Retries  = $attempt
                Pages    = $pages.Count
                File     = (Split-Path -Leaf $outFile)
                Started  = $rowStart.ToString('o')
                DurationSeconds = [int]((Get-Date) - $rowStart).TotalSeconds
            })
        } else {
            $anyFailure = $true
            $manifestRows.Add([pscustomobject]@{
                Kind     = $row.Kind
                Name     = $row.Name
                Workload = $row.Workload
                Status   = 'Fail'
                Retries  = $attempt
                Pages    = 0
                Error    = $lastError
                Started  = $rowStart.ToString('o')
                DurationSeconds = [int]((Get-Date) - $rowStart).TotalSeconds
            })
        }

        Start-Sleep -Seconds $throttleSeconds
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

$manifest = [pscustomobject]@{
    timestamp         = $timestamp
    tenantDomain      = $TenantDomain
    desiredStatePath  = $Path
    parametersFile    = $ParametersFile
    workloads         = $workloads
    pageSize          = $PageSize
    throttleSeconds   = $throttleSeconds
    maxRetries        = $maxRetries
    rowCount          = $manifestRows.Count
    failureCount      = (@($manifestRows | Where-Object { $_.Status -eq 'Fail' })).Count
    rows              = $manifestRows
}
$manifest | ConvertTo-Json -Depth 12 | Out-File -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding utf8

Write-Information ("Wrote {0} files (+ manifest.json) to '{1}'." -f $manifestRows.Count, $runDir) -InformationAction Continue

if ($anyFailure) { exit 1 }
exit 0
