#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview data sources against
    `data-plane/data-sources/data-sources.yaml`.

.DESCRIPTION
    Wave 4a-i-b full-circle reconciler for scanning data sources.
    The YAML file is the desired state. This script performs:

      1. GET current data sources from the scanning data plane.
      2. Diff desired vs. tenant by source `name`.
      3. Emit a per-object plan table:
           Create / Update / NoChange / Orphan / Conflict.
      4. Apply only authorized actions (`-WhatIf`, `-PruneMissing`,
         `-Force`) using per-write `$PSCmdlet.ShouldProcess(...)`.
      5. Support deterministic `-ExportCurrentState` to hydrate the YAML.

    Key Vault contract:
      * Credential material never appears in YAML.
      * YAML carries only credential references (vault + secret name).
      * This script may verify referenced secret metadata via
        `az keyvault secret show` (read-only); it never reads or writes
        secret values into Purview payloads.

    References:
      Data Sources REST:
        https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources
      Credentials for source authentication:
        https://learn.microsoft.com/en-us/purview/data-map-data-scan-credentials
      Purview API auth:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Desired-state YAML path. Defaults to
    `data-plane/data-sources/data-sources.yaml`.

.PARAMETER PruneMissing
    Remove tenant data sources not present in YAML. Default `$false`.
    NEVER passes a name listed in `-SkipNames`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan, emit
                         the categorized report, and exit. No PUT /
                         DELETE writes against the REST surface fire
                         under any circumstance. Equivalent to a forced
                         -WhatIf at the script boundary.
      * `portal-wins` -- (default) skip any data source whose tracked
                         fields differ; emit a Skip plan row and a
                         `[ADR0029-SKIP] <name>` marker per skip so an
                         upstream workflow can capture the list for an
                         auto-PR. Create / NoChange / Orphan / Conflict
                         handling are unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         data source naming the drifted field(s). The
                         typed-confirmation gate ('overwrite portal') is
                         a CI-layer concern enforced by the workflow per
                         ADR 0029.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list. A name matched here becomes
    a Skip plan row instead of an Update / Orphan / Conflict row
    (reason: "explicitly skipped by caller"). NoChange and Create rows
    are unaffected. `-PruneMissing` still respects `-SkipNames`. Names
    not present in the YAML or the tenant are silently ignored. The
    match is case-insensitive against the bare `name`. Ignored in
    `-DirectionPolicy audit` mode. Default `@()`.

.PARAMETER Force
    Allow overwriting conflict rows (`lastModifiedBy` differs from deploy
    principal) and allow overwriting a non-empty YAML on export.

.PARAMETER ExportCurrentState
    Export live tenant data sources to YAML and exit. Makes no writes
    to Purview.

.PARAMETER ParametersFile
    Environment parameters YAML path (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved from repo root.

.PARAMETER AccountName
    Purview account name. When omitted, resolved from
    `purviewAccountName` in `-ParametersFile`.

.EXAMPLE
    ./scripts/Deploy-DataSources.ps1 -AccountName purview-contoso-lab -WhatIf

.EXAMPLE
    ./scripts/Deploy-DataSources.ps1 -AccountName purview-contoso-lab -ExportCurrentState
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\data-sources\data-sources.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

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
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [Alias('PurviewAccountName')]
    [string]$AccountName
)

$ErrorActionPreference = 'Stop'

# Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources
$script:DataSourcesApiVersion = '2023-09-01'

# Server-computed fields that the Scanning Data Plane GET returns but the PUT
# body must not (and the desired-state YAML must not) carry. Stripping these
# symmetrically on both sides of Compare-DataSourceHash and before export
# guarantees deterministic round-trips. Without this filter, computed
# timestamps round-trip asymmetrically: YAML preserves the original string
# (e.g. `...6564990Z`), while Invoke-RestMethod's ConvertFrom-Json parses the
# same value into [DateTime] which serialises back without trailing-zero
# subseconds (`...656499Z`), producing a spurious 'properties' drift row.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/get
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json#-datekind
$script:DataSourceComputedFields = @(
    'createdAt',
    'lastModifiedAt',
    'dataSourceCollectionMovingState',
    'parentCollection'
)
$script:CollectionComputedFields = @(
    'lastModifiedAt',
    'type'
)

function Get-ComparableDataSourceProperty {
    param([Parameter(Mandatory = $true)][AllowNull()]$Properties)

    if ($null -eq $Properties) { return @{} }
    if (-not ($Properties -is [System.Collections.IDictionary])) { return $Properties }

    $out = @{}
    foreach ($key in $Properties.Keys) {
        $name = [string]$key
        if ($script:DataSourceComputedFields -contains $name) { continue }

        $value = $Properties[$key]
        if ($name -eq 'collection' -and $value -is [System.Collections.IDictionary]) {
            $stripped = @{}
            foreach ($ck in $value.Keys) {
                if ($script:CollectionComputedFields -contains [string]$ck) { continue }
                $stripped[[string]$ck] = $value[$ck]
            }
            $out[$name] = $stripped
            continue
        }

        $out[$name] = $value
    }
    return $out
}

function ConvertTo-DataSourceHash {
    param([Parameter(Mandatory = $true)][hashtable]$Source)

    if (-not $Source.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$Source.name)) {
        throw "Data source entry is missing required field 'name'."
    }
    if (-not $Source.ContainsKey('kind') -or [string]::IsNullOrWhiteSpace([string]$Source.kind)) {
        throw "Data source '$($Source.name)' is missing required field 'kind'."
    }
    if (-not $Source.ContainsKey('properties') -or -not $Source.properties) {
        throw "Data source '$($Source.name)' is missing required field 'properties'."
    }

    $props = [hashtable]$Source.properties
    if (-not $props.ContainsKey('collection') -or -not $props.collection) {
        throw "Data source '$($Source.name)' is missing properties.collection.referenceName."
    }
    $collection = [hashtable]$props.collection
    if (-not $collection.ContainsKey('referenceName') -or [string]::IsNullOrWhiteSpace([string]$collection.referenceName)) {
        throw "Data source '$($Source.name)' is missing properties.collection.referenceName."
    }

    return @{
        name       = [string]$Source.name
        kind       = [string]$Source.kind
        properties = $props
    }
}

function ConvertTo-TenantDataSourceHash {
    param([Parameter(Mandatory = $true)]$Source)

    $properties = @{}
    if ($Source.PSObject.Properties.Name -contains 'properties' -and $Source.properties) {
        $properties = ($Source.properties | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    }

    return @{
        name       = [string]$Source.name
        kind       = [string]$Source.kind
        properties = $properties
    }
}

function ConvertTo-CanonicalValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $ordered[[string]$key] = ConvertTo-CanonicalValue -Value $Value[$key]
        }
        return $ordered
    }

    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) {
            $list.Add((ConvertTo-CanonicalValue -Value $item)) | Out-Null
        }
        return $list.ToArray()
    }

    return $Value
}

function ConvertTo-ComparableJson {
    param([AllowNull()]$Value)
    $canonical = ConvertTo-CanonicalValue -Value $Value
    return ($canonical | ConvertTo-Json -Depth 25 -Compress)
}

function Compare-DataSourceHash {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'
    if ($Desired.kind -ne $Tenant.kind) { $diffs.Add('kind') | Out-Null }

    # Strip server-computed fields from both sides before comparing so that
    # round-trips through Invoke-RestMethod ConvertFrom-Json (which parses
    # ISO-8601 strings into [DateTime]) cannot produce spurious drift on
    # timestamps the user never set in YAML. See $script:DataSourceComputedFields
    # for the field list and rationale.
    $desiredProps = Get-ComparableDataSourceProperty -Properties $Desired.properties
    $tenantProps  = Get-ComparableDataSourceProperty -Properties $Tenant.properties

    $desiredJson = ConvertTo-ComparableJson -Value $desiredProps
    $tenantJson  = ConvertTo-ComparableJson -Value $tenantProps
    if ($desiredJson -ne $tenantJson) { $diffs.Add('properties') | Out-Null }

    return $diffs.ToArray()
}

function Format-PurviewRestError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    try {
        if ($ErrorRecord.Exception.Response) {
            $resp = $ErrorRecord.Exception.Response
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    return "HTTP response: $body"
                }
            }
            return $message
        }
    } catch {
        return $message
    }
    return $message
}

function Get-TenantDataSource {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $uri = "$BaseUri/datasources?api-version=$ApiVersion"

    while ($uri) {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
        if ($resp.value) {
            foreach ($v in $resp.value) { $items.Add($v) | Out-Null }
        }
        if ($resp.PSObject.Properties.Name -contains 'nextLink' -and $resp.nextLink) {
            $uri = [string]$resp.nextLink
        } else {
            $uri = $null
        }
    }
    return $items.ToArray()
}

function Get-LastModifiedByIdentity {
    param([Parameter(Mandatory = $true)]$Source)

    $candidates = @(
        $Source.lastModifiedBy,
        $Source.modifiedBy,
        $Source.updatedBy,
        $Source.properties.lastModifiedBy,
        $Source.properties.modifiedBy,
        $Source.systemData.lastModifiedBy
    )

    foreach ($c in $candidates) {
        if ($null -ne $c -and -not [string]::IsNullOrWhiteSpace([string]$c)) {
            return [string]$c
        }
    }
    return $null
}

function Test-ConflictRow {
    param(
        [Parameter(Mandatory = $true)]$TenantRaw,
        [Parameter(Mandatory = $true)][string]$DeployIdentity,
        [Parameter(Mandatory = $true)][bool]$ForceEnabled
    )

    if ($ForceEnabled) { return $false }
    if ([string]::IsNullOrWhiteSpace($DeployIdentity)) { return $false }

    $last = Get-LastModifiedByIdentity -Source $TenantRaw
    if ([string]::IsNullOrWhiteSpace($last)) { return $false }

    return ($last -notlike "*$DeployIdentity*")
}

function Get-KeyVaultRef {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)

    $refs = New-Object 'System.Collections.Generic.List[object]'
    if (-not $Desired.properties.ContainsKey('credential') -or -not $Desired.properties.credential) {
        return $refs.ToArray()
    }

    $credential = [hashtable]$Desired.properties.credential
    $vaultName = $null
    $secretName = $null

    if ($credential.ContainsKey('keyVault') -and $credential.keyVault) {
        $kv = [hashtable]$credential.keyVault
        if ($kv.ContainsKey('name')) { $vaultName = [string]$kv.name }
        if ($kv.ContainsKey('vaultName')) { $vaultName = [string]$kv.vaultName }
    }
    if ($credential.ContainsKey('vaultName')) { $vaultName = [string]$credential.vaultName }
    if ($credential.ContainsKey('secretName')) { $secretName = [string]$credential.secretName }

    if ($credential.ContainsKey('properties') -and $credential.properties) {
        $cp = [hashtable]$credential.properties
        if (-not $vaultName -and $cp.ContainsKey('keyVaultName')) { $vaultName = [string]$cp.keyVaultName }
        if (-not $vaultName -and $cp.ContainsKey('vaultName')) { $vaultName = [string]$cp.vaultName }
        if (-not $secretName -and $cp.ContainsKey('secretName')) { $secretName = [string]$cp.secretName }
    }

    if (-not [string]::IsNullOrWhiteSpace($vaultName) -or -not [string]::IsNullOrWhiteSpace($secretName)) {
        if ([string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($secretName)) {
            throw "Data source '$($Desired.name)' has a partial Key Vault credential reference. Both vaultName and secretName are required."
        }
        $refs.Add([pscustomobject]@{ Name = $Desired.name; VaultName = $vaultName; SecretName = $secretName }) | Out-Null
    }

    return $refs.ToArray()
}

function Test-KeyVaultSecretReference {
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$SecretName
    )

    # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/secret#az-keyvault-secret-show
    $null = az keyvault secret show --vault-name $VaultName --name $SecretName --query id -o tsv --only-show-errors 2>$null
    return ($LASTEXITCODE -eq 0)
}

function ConvertTo-DataSourceExportDoc {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$TenantHashes
    )

    # Strip server-computed fields before serialising so the exported YAML
    # round-trips deterministically: re-importing and running -WhatIf must
    # produce only NoChange rows. See $script:DataSourceComputedFields.
    $ordered = @($TenantHashes | Sort-Object -Property { $_.name.ToLowerInvariant() })
    return [ordered]@{
        dataSources = @($ordered | ForEach-Object {
            [ordered]@{
                name       = $_.name
                kind       = $_.kind
                properties = (Get-ComparableDataSourceProperty -Properties $_.properties)
            }
        })
    }
}

function Invoke-DataSourceExport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$TenantSources,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
        $hasBody = $false
        if ($existing) {
            try {
                $existingDoc = $existing | ConvertFrom-Yaml -ErrorAction Stop
                if ($existingDoc -and $existingDoc.ContainsKey('dataSources') -and $existingDoc.dataSources -and $existingDoc.dataSources.Count -gt 0) {
                    $hasBody = $true
                }
            } catch {
                $hasBody = $false
            }
        }
        if ($hasBody -and -not $ForceOverwrite) {
            Write-Error ("Target YAML '{0}' already declares data sources. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }

    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }

    $tenantHashes = @($TenantSources | ForEach-Object { ConvertTo-TenantDataSourceHash -Source $_ })
    $doc = ConvertTo-DataSourceExportDoc -TenantHashes $tenantHashes
    $body = ConvertTo-Yaml $doc
    $nl = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} data source(s) to '{1}'." -f $tenantHashes.Count, $Path) -InformationAction Continue
}

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
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
if (-not $parameters.ContainsKey('purviewAccountName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'purviewAccountName'." -f $ParametersFile)
    return
}
if (-not $AccountName) {
    $AccountName = [string]$parameters.purviewAccountName
}

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $AccountName) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
if ($mode -eq 'Apply') {
    Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
    Write-Information ("SkipNames count : {0}" -f $SkipNames.Count) -InformationAction Continue
}

$desiredEntries = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
    if (-not $desiredRoot) {
        Write-Error ("Desired-state YAML '{0}' parsed as empty." -f $Path)
        return
    }

    if (-not $desiredRoot.ContainsKey('dataSources')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'dataSources'." -f $Path)
        return
    }

    # ADR 0023: resolve ${env:VAR} tokens (AZURE_TENANT_ID,
    # AZURE_SUBSCRIPTION_ID, PURVIEW_ACCOUNT_NAME, PURVIEW_RG) in
    # the desired-state YAML before any comparator or REST work.
    # Tokens guard against committing real Azure topology IDs into
    # source control. Reference:
    # docs/adr/0023-identifier-resolution.md
    $resolveScript = Join-Path $PSScriptRoot 'Resolve-EnvTokens.ps1'
    if (-not (Test-Path -LiteralPath $resolveScript)) {
        Write-Error ("Helper not found: '{0}'. See docs/adr/0023-identifier-resolution.md." -f $resolveScript)
        return
    }
    $desiredRoot = & $resolveScript -InputObject $desiredRoot

    $desiredEntries = @($desiredRoot.dataSources | ForEach-Object { ConvertTo-DataSourceHash -Source ([hashtable]$_) })
    Write-Information ("Desired         : {0} data source(s)" -f $desiredEntries.Count) -InformationAction Continue
}

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
$deployIdentity = [string]$account.user.name
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

$connectScript = Join-Path $scriptRoot 'Connect-Purview.ps1'
if (-not (Test-Path -LiteralPath $connectScript)) {
    Write-Error ("Helper not found: '{0}'." -f $connectScript)
    return
}

$ctx = & $connectScript -AccountName $AccountName
if (-not $ctx -or -not $ctx.DataHeaders -or -not $ctx.Endpoint) {
    Write-Error 'Connect-Purview.ps1 did not return data-plane headers.'
    return
}

$baseUri = "$($ctx.Endpoint)/scan"
Write-Information ("Endpoint        : {0}" -f $baseUri) -InformationAction Continue

try {
    $tenantRaw = @(Get-TenantDataSource -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:DataSourcesApiVersion)
} catch {
    Write-Error ("Failed to list tenant data sources: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
Write-Information ("Tenant          : {0} data source(s)" -f $tenantRaw.Count) -InformationAction Continue

if ($mode -eq 'Export') {
    $exportTarget = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            Write-Error ("Parent directory does not exist: '{0}'." -f $parent)
            return
        }
        Join-Path ((Resolve-Path -LiteralPath $parent).Path) (Split-Path -Leaf $Path)
    }

    if ($PSCmdlet.ShouldProcess($exportTarget, 'Write exported data-source state')) {
        Invoke-DataSourceExport -Path $exportTarget -TenantSources $tenantRaw -ForceOverwrite $Force.IsPresent
    } else {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no file written):' -InformationAction Continue
        Write-Information ("  Would write {0} data source(s) to '{1}'." -f $tenantRaw.Count, $exportTarget) -InformationAction Continue
    }
    return
}

$desiredByName = @{}
foreach ($d in $desiredEntries) {
    $key = $d.name.ToLowerInvariant()
    if ($desiredByName.ContainsKey($key)) {
        Write-Error ("Duplicate data source name '{0}' in YAML. Names must be unique." -f $d.name)
        return
    }
    $desiredByName[$key] = $d
}

$tenantByName = @{}
$tenantRawByName = @{}
foreach ($t in $tenantRaw) {
    $h = ConvertTo-TenantDataSourceHash -Source $t
    $key = $h.name.ToLowerInvariant()
    $tenantByName[$key] = $h
    $tenantRawByName[$key] = $t
}

$plan = New-Object 'System.Collections.Generic.List[object]'

foreach ($d in ($desiredEntries | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $key = $d.name.ToLowerInvariant()
    if ($tenantByName.ContainsKey($key)) {
        $diffs = Compare-DataSourceHash -Desired $d -Tenant $tenantByName[$key]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            $isConflict = Test-ConflictRow -TenantRaw $tenantRawByName[$key] -DeployIdentity $deployIdentity -ForceEnabled $Force.IsPresent
            if ($isConflict) {
                $who = Get-LastModifiedByIdentity -Source $tenantRawByName[$key]
                $plan.Add([pscustomobject]@{ Action = 'Conflict'; Name = $d.name; Desired = $d; Reason = ("Drift in: {0}; lastModifiedBy '{1}' differs from deploy principal." -f ($diffs -join ', '), $who) }) | Out-Null
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) }) | Out-Null
            }
        }
    } else {
        $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}

$orphans = @($tenantByName.Values | Where-Object { -not $desiredByName.ContainsKey($_.name.ToLowerInvariant()) } | Sort-Object -Property { $_.name.ToLowerInvariant() })
foreach ($o in $orphans) {
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $o.name; Desired = $null; Reason = $reason }) | Out-Null
}

# ---- ADR 0029 direction-policy pass ----
# Audit short-circuit: `-DirectionPolicy audit` flips $WhatIfPreference
# so every $PSCmdlet.ShouldProcess(...) below falls into its else
# branch. No PUT / DELETE writes under any circumstance, while the
# categorized plan-with-would-rows is preserved end-to-end.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
if ($DirectionPolicy -eq 'audit') {
    Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
    $WhatIfPreference = $true
}

# Direction-policy pass: portal-wins drift-skip on Update rows, plus
# `-SkipNames` pre-pass that promotes any matched row (Create /
# Update / NoChange / Orphan / Conflict) to Skip. Audit short-circuit
# does not enter this pass.
$script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'
if ($DirectionPolicy -ne 'audit') {
    foreach ($row in $plan) {
        if ($row.Action -notin @('Create','Update','NoChange','Orphan','Conflict')) { continue }
        $hasDrift = ($row.Action -eq 'Update' -or $row.Action -eq 'Conflict')
        $decision = Resolve-DirectionPolicyAction `
            -Policy      $DirectionPolicy `
            -SkipList    $SkipNames `
            -DisplayName ([string]$row.Name) `
            -HasDrift    $hasDrift
        if ($decision.Action -eq 'Skip') {
            $row.Action = 'Skip'
            $row.Reason = $decision.Reason
            $script:Adr0029Skips.Add([pscustomobject]@{
                Kind        = 'DataSource'
                DisplayName = [string]$row.Name
                Reason      = $decision.Reason
            })
            continue
        }
        if ($row.Action -eq 'Update' -and $DirectionPolicy -eq 'repo-wins') {
            $fieldsText = ($row.Reason -replace '^Drift in: ', '')
            Write-Warning ("repo-wins overwriting tenant on Purview data source '{0}' fields: {1}" -f $row.Name, $fieldsText)
        }
    }
    # Machine-readable markers per skipped object. Format must match
    # `^\[ADR0029-SKIP\] (.+)$` per the github-actions instructions.
    foreach ($s in $script:Adr0029Skips) {
        Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
    }
}

$report = New-Object 'System.Collections.Generic.List[object]'

foreach ($row in $plan) {
    $target = "Purview data source '{0}'" -f $row.Name

    switch ($row.Action) {
        'NoChange' {
            $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Skip' {
            # ADR 0029 portal-wins drift skip or -SkipNames pre-pass.
            # Reported but never written; -PruneMissing is bypassed.
            $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Conflict' {
            $report.Add([pscustomobject]@{ Category = 'Conflict'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Create' {
            $opDesc = 'PUT data source (Create)'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $kvRefs = @(Get-KeyVaultRef -Desired $row.Desired)
                    foreach ($r in $kvRefs) {
                        if (-not (Test-KeyVaultSecretReference -VaultName $r.VaultName -SecretName $r.SecretName)) {
                            throw "Key Vault reference not found (read-only check): $($r.VaultName)/$($r.SecretName)"
                        }
                    }

                    $payload = @{ kind = $row.Desired.kind; properties = $row.Desired.properties } | ConvertTo-Json -Depth 25 -Compress
                    $uri = "$baseUri/datasources/$([uri]::EscapeDataString($row.Desired.name))?api-version=$script:DataSourcesApiVersion"
                    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'DataSource'; Name = $row.Name; Reason = ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Update' {
            $opDesc = 'PUT data source (Update)'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $kvRefs = @(Get-KeyVaultRef -Desired $row.Desired)
                    foreach ($r in $kvRefs) {
                        if (-not (Test-KeyVaultSecretReference -VaultName $r.VaultName -SecretName $r.SecretName)) {
                            throw "Key Vault reference not found (read-only check): $($r.VaultName)/$($r.SecretName)"
                        }
                    }

                    $payload = @{ kind = $row.Desired.kind; properties = $row.Desired.properties } | ConvertTo-Json -Depth 25 -Compress
                    $uri = "$baseUri/datasources/$([uri]::EscapeDataString($row.Desired.name))?api-version=$script:DataSourcesApiVersion"
                    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'DataSource'; Name = $row.Name; Reason = ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Orphan' {
            if (-not $PruneMissing.IsPresent) {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'DataSource'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                continue
            }

            $opDesc = 'DELETE data source'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    $uri = "$baseUri/datasources/$([uri]::EscapeDataString($row.Name))?api-version=$script:DataSourcesApiVersion"
                    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'DataSource'; Name = $row.Name; Reason = 'Deleted (-PruneMissing).' }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'DataSource'; Name = $row.Name; Reason = ("Delete failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'DataSource'; Name = $row.Name; Reason = 'Would be deleted (-PruneMissing).' }) | Out-Null
            }
            continue
        }
    }
}

$report

$counts = @{}
foreach ($r in $report) {
    if (-not $counts.ContainsKey($r.Category)) { $counts[$r.Category] = 0 }
    $counts[$r.Category]++
}

$bannerParts = @()
foreach ($k in @('Create','Update','NoChange','Orphan','Conflict','Skip','Removed','Failed')) {
    if ($counts.ContainsKey($k)) { $bannerParts += ("{0} {1}" -f $counts[$k], $k) }
}
if ($bannerParts.Count -gt 0) {
    Write-Information ("Plan: {0}" -f ($bannerParts -join ', ')) -InformationAction Continue
} else {
    Write-Information 'Plan: 0 changes.' -InformationAction Continue
}