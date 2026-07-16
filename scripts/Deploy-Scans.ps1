#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview scans, scan rulesets, and triggers against
    `data-plane/scans/scans.yaml`.

.DESCRIPTION
    Wave 4a-ii-a full-circle reconciler for the scanning data plane. The YAML
    file is the desired state. This script performs:

      1. GET current scan rulesets, scans (per registered data source), and
         the default trigger (per scan) from the scanning data plane.
      2. Diff desired vs. tenant by composite key.
      3. Emit a per-object plan table:
           Create / Update / NoChange / Orphan / Conflict.
      4. Apply only authorized actions (`-WhatIf`, `-PruneMissing`,
         `-Force`) using per-write `$PSCmdlet.ShouldProcess(...)`.
      5. Support deterministic `-ExportCurrentState` to hydrate the YAML.

    Composite keys:
      - Scan ruleset: name (top-level, case-insensitive).
      - Scan:         "{dataSource}/{scanName}" (case-insensitive).
      - Trigger:      "{dataSource}/{scanName}/default" (one default per scan).

    Cross-domain validation:
      - Every scan's `dataSource` must be a registered tenant data source.
      - Scans referencing `scanRulesetType: Custom` must declare the ruleset
        under `scanRulesets:` in the same file.

    References:
      Scans REST:
        https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans
      Scan rulesets REST:
        https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets
      Triggers REST:
        https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers
      Purview API auth:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Desired-state YAML path. Defaults to `data-plane/scans/scans.yaml`.

.PARAMETER PruneMissing
    Remove tenant scans, scan rulesets, and triggers not present in YAML.
    Default `$false`. NEVER passes a name listed in `-SkipNames`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan, emit
                         the categorized report, and exit. No PUT /
                         DELETE writes against the REST surface fire
                         under any circumstance. Equivalent to a forced
                         -WhatIf at the script boundary.
      * `portal-wins` -- (default) skip any scan / scan ruleset /
                         trigger whose tracked fields differ; emit a
                         Skip plan row and a `[ADR0029-SKIP] <name>`
                         marker per skip so an upstream workflow can
                         capture the list for an auto-PR. Create /
                         NoChange / Orphan / Conflict handling are
                         unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         object naming the drifted field(s). The
                         overwrite is gated at the SCRIPT layer by the
                         ADR 0052 typed-confirmation prompt: it names the
                         objects it is about to overwrite, asks EVERY
                         caller -- local operators included -- and aborts
                         with no tenant writes if declined. Suppress with
                         -Force, or -Confirm:$false as CI does. The
                         workflow's 'overwrite portal' input is an
                         ADDITIONAL gate per ADR 0029, not the only one: a
                         clone of this template that has not run kickoff
                         has no CI at all, so the script-layer gate is its
                         only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list. A name matched here becomes
    a Skip plan row instead of an Update / Orphan / Conflict row
    (reason: "explicitly skipped by caller"). NoChange and Create rows
    are unaffected. `-PruneMissing` still respects `-SkipNames`. Names
    not present in the YAML or the tenant are silently ignored. The
    match is case-insensitive against the bare scan ruleset name (e.g.
    `MyCustomRuleset`) or the composite `<dataSource>/<scanName>` key
    used in plan rows for Scan and Trigger kinds (e.g.
    `AzureBlob-SampleData/Scan-DataLakeModernization`). Ignored in
    `-DirectionPolicy audit` mode. Default `@()`.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for. In the
    Export parameter set that guard is `-ExportCurrentState`'s refusal
    to clobber a non-empty managed block in the target YAML. In the
    Apply parameter set it is the ADR 0052 destructive-operation
    confirmation prompt.
    `-Force` does NOT authorize overwriting a foreign-authored tenant
    object, and it does NOT suppress `Conflict` rows -- that meaning was
    split out to `-OverwriteForeignAuthor` by ADR 0053.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER OverwriteForeignAuthor
    Apply parameter set only. Permit `Update` writes against tenant scans
    and scan rulesets whose authorship (`lastModifiedBy` / `updatedBy` /
    `properties.lastModifiedBy` / `systemData.lastModifiedBy`) differs from
    the current deploy principal. Without it, such an object is reported as
    a `Conflict` row and left untouched.
    The `Conflict` row is emitted either way -- this switch authorizes the
    overwrite, it does not hide the finding. A write over a foreign-authored
    object is ALWAYS reported as a `Conflict` row, never laundered into a
    plain `Update`.
    Requires `-DirectionPolicy repo-wins` to have any effect: the direction
    policy and the authorship override are independent axes and both must
    permit the write. Under the default `portal-wins` a drifted object is
    skipped whatever its authorship. Default `$false`.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER ExportCurrentState
    Export live tenant state to YAML and exit. Makes no writes to Purview.

.PARAMETER ParametersFile
    Environment parameters YAML path (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved from repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER AccountName
    Purview account name. When omitted, resolved from `purviewAccountName`
    in `-ParametersFile`.

.EXAMPLE
    ./scripts/Deploy-Scans.ps1 -AccountName purview-contoso-lab -WhatIf

.EXAMPLE
    ./scripts/Deploy-Scans.ps1 -AccountName purview-contoso-lab -ExportCurrentState
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\scans\scans.yaml'),

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

    # ADR 0053: the foreign-author overwrite override is its own switch and
    # lives in the Apply parameter set only. The Export path has no tenant
    # object to be authored by anyone, so there is nothing for it to mean there.
    [Parameter(ParameterSetName = 'Apply')]
    [switch]$OverwriteForeignAuthor,

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

# Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans
$script:ScansApiVersion = '2023-09-01'

# Server-computed fields stripped symmetrically before comparison and before
# export, for the same reason documented in Deploy-DataSources.ps1: ISO-8601
# timestamps round-trip asymmetrically through Invoke-RestMethod's
# ConvertFrom-Json, producing spurious drift rows on unchanged scans.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans/get
$script:ScanComputedFields = @(
    'createdAt',
    'lastModifiedAt',
    'lastRunStatus',
    'scanRulesetVersion'
)
$script:ScanRulesetComputedFields = @(
    'createdAt',
    'lastModifiedAt',
    'version',
    'status'
)
$script:TriggerComputedFields = @(
    'createdAt',
    'lastModifiedAt',
    'scanId'
)
$script:CollectionComputedFields = @(
    'lastModifiedAt',
    'type'
)

function Get-ComparableScanProperty {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Properties,
        [Parameter(Mandatory = $true)][string[]]$ComputedFields
    )

    if ($null -eq $Properties) { return @{} }
    if (-not ($Properties -is [System.Collections.IDictionary])) { return $Properties }

    $out = @{}
    foreach ($key in $Properties.Keys) {
        $name = [string]$key
        if ($ComputedFields -contains $name) { continue }

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

function ConvertTo-DesiredScanHash {
    param([Parameter(Mandatory = $true)][hashtable]$Scan)

    foreach ($req in @('dataSource','name','kind','properties')) {
        if (-not $Scan.ContainsKey($req) -or [string]::IsNullOrWhiteSpace([string]$Scan[$req])) {
            if ($req -eq 'properties' -and $Scan.ContainsKey($req) -and $Scan[$req]) { continue }
            throw "Scan entry is missing required field '$req'."
        }
    }

    $props = [hashtable]$Scan.properties
    # `scanRulesetName` / `scanRulesetType` are required only for the
    # subset of scan kinds that bind a single top-level ruleset (the
    # AzureSqlDatabase / AdlsGen2 / AzureStorage / Dataverse / etc.
    # families). Other kinds carry the ruleset reference elsewhere:
    #   * AzureSynapseWorkspaceMsi -- per-resource-type ruleset under
    #     `properties.resourceTypes.<rt>.scanRulesetName`.
    #   * FabricMsi / DatabricksUnityCatalog -- no ruleset (the source
    #     itself defines the scan surface).
    # Trust the REST surface to reject bad combinations at apply time
    # rather than re-implementing the per-kind requirement matrix here.
    # `properties.collection.referenceName` is always required and is
    # validated unconditionally below.
    foreach ($req in @('collection')) {
        if (-not $props.ContainsKey($req) -or -not $props[$req]) {
            throw "Scan '$($Scan.name)' is missing properties.$req."
        }
    }
    $collection = [hashtable]$props.collection
    if (-not $collection.ContainsKey('referenceName') -or [string]::IsNullOrWhiteSpace([string]$collection.referenceName)) {
        throw "Scan '$($Scan.name)' is missing properties.collection.referenceName."
    }

    $trigger = $null
    if ($Scan.ContainsKey('trigger') -and $Scan.trigger) {
        $trigger = [hashtable]$Scan.trigger
    }

    return @{
        dataSource = [string]$Scan.dataSource
        name       = [string]$Scan.name
        kind       = [string]$Scan.kind
        properties = $props
        trigger    = $trigger
    }
}

function ConvertTo-DesiredScanRulesetHash {
    param([Parameter(Mandatory = $true)][hashtable]$Ruleset)

    foreach ($req in @('name','kind','properties')) {
        if (-not $Ruleset.ContainsKey($req)) {
            throw "Scan ruleset entry is missing required field '$req'."
        }
    }

    return @{
        name       = [string]$Ruleset.name
        kind       = [string]$Ruleset.kind
        properties = [hashtable]$Ruleset.properties
    }
}

function ConvertTo-TenantScanHash {
    param(
        [Parameter(Mandatory = $true)][string]$DataSourceName,
        [Parameter(Mandatory = $true)]$Scan
    )

    $properties = @{}
    if ($Scan.PSObject.Properties.Name -contains 'properties' -and $Scan.properties) {
        $properties = ($Scan.properties | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    }

    return @{
        dataSource = $DataSourceName
        name       = [string]$Scan.name
        kind       = [string]$Scan.kind
        properties = $properties
        trigger    = $null
    }
}

function ConvertTo-TenantScanRulesetHash {
    param([Parameter(Mandatory = $true)]$Ruleset)

    $properties = @{}
    if ($Ruleset.PSObject.Properties.Name -contains 'properties' -and $Ruleset.properties) {
        $properties = ($Ruleset.properties | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    }

    return @{
        name       = [string]$Ruleset.name
        kind       = [string]$Ruleset.kind
        properties = $properties
    }
}

function ConvertTo-TenantTriggerHash {
    param([Parameter(Mandatory = $true)]$Trigger)

    if (-not $Trigger) { return $null }

    $properties = @{}
    if ($Trigger.PSObject.Properties.Name -contains 'properties' -and $Trigger.properties) {
        $properties = ($Trigger.properties | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    }
    return $properties
}

function Compare-ScanHash {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'
    if ($Desired.kind -ne $Tenant.kind) { $diffs.Add('kind') | Out-Null }

    $desiredProps = Get-ComparableScanProperty -Properties $Desired.properties -ComputedFields $script:ScanComputedFields
    $tenantProps  = Get-ComparableScanProperty -Properties $Tenant.properties  -ComputedFields $script:ScanComputedFields
    if ((ConvertTo-ComparableJson -Value $desiredProps) -ne (ConvertTo-ComparableJson -Value $tenantProps)) {
        $diffs.Add('properties') | Out-Null
    }
    return $diffs.ToArray()
}

function Compare-ScanRulesetHash {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'
    if ($Desired.kind -ne $Tenant.kind) { $diffs.Add('kind') | Out-Null }

    $desiredProps = Get-ComparableScanProperty -Properties $Desired.properties -ComputedFields $script:ScanRulesetComputedFields
    $tenantProps  = Get-ComparableScanProperty -Properties $Tenant.properties  -ComputedFields $script:ScanRulesetComputedFields
    if ((ConvertTo-ComparableJson -Value $desiredProps) -ne (ConvertTo-ComparableJson -Value $tenantProps)) {
        $diffs.Add('properties') | Out-Null
    }
    return $diffs.ToArray()
}

function Compare-TriggerHash {
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Desired,
        [Parameter(Mandatory = $true)][AllowNull()]$Tenant
    )

    # Both null = NoChange. One null = drift.
    $desiredNull = ($null -eq $Desired)
    $tenantNull  = ($null -eq $Tenant)
    if ($desiredNull -and $tenantNull) { return @() }
    if ($desiredNull -xor $tenantNull) { return @('presence') }

    $desiredStripped = Get-ComparableScanProperty -Properties $Desired -ComputedFields $script:TriggerComputedFields
    $tenantStripped  = Get-ComparableScanProperty -Properties $Tenant  -ComputedFields $script:TriggerComputedFields
    if ((ConvertTo-ComparableJson -Value $desiredStripped) -ne (ConvertTo-ComparableJson -Value $tenantStripped)) {
        return @('properties')
    }
    return @()
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
    # ADR 0053: a PURE authorship predicate. It knows nothing about any override
    # switch, by design.
    #
    # Before ADR 0053 this function opened with `if ($ForceEnabled) { return
    # $false }`, bound to $Force.IsPresent -- so -Force suppressed the Conflict
    # classification AT SOURCE: the row was never emitted, the scan/ruleset fell
    # through to a plain Update, and the portal-authored object was silently
    # overwritten with no record anywhere in the drift report.
    #
    # Merely renaming that parameter to -OverwriteForeignAuthor would have kept
    # the defect and relabelled it -- the alternative ADR 0053 section Alternatives-5
    # rejects by name ("the switch grants permission, not silence"). The override
    # decision therefore lives in Resolve-ConflictPlanAction, NOT here.
    param(
        [Parameter(Mandatory = $true)]$TenantRaw,
        [Parameter(Mandatory = $true)][string]$DeployIdentity
    )

    if ([string]::IsNullOrWhiteSpace($DeployIdentity)) { return $false }

    $last = Get-LastModifiedByIdentity -Source $TenantRaw
    if ([string]::IsNullOrWhiteSpace($last)) { return $false }

    return ($last -notlike "*$DeployIdentity*")
}

function Resolve-ConflictPlanAction {
    # ADR 0053: the authorship-override decision, isolated and pure.
    #
    # The Conflict row is emitted whenever authorship differs -- with OR without
    # -OverwriteForeignAuthor. The switch decides only whether the WRITE
    # proceeds; it never buys silence. A write over a foreign-authored object is
    # therefore never laundered into a plain `Update` row.
    #
    # Mirrors Deploy-UnifiedCatalog.ps1's Get-ReconciliationPlan (Mechanism B),
    # which had this shape right from the start.
    param(
        [Parameter(Mandatory = $true)][bool]$IsConflict,
        [Parameter(Mandatory = $true)][bool]$OverwriteForeignAuthor,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DriftText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Who
    )

    if (-not $IsConflict) {
        return [pscustomobject]@{
            Action   = 'Update'
            Category = 'Update'
            Conflict = $false
            Reason   = ('Drift in: {0}' -f $DriftText)
        }
    }

    if ($OverwriteForeignAuthor) {
        return [pscustomobject]@{
            Action   = 'Update'
            Category = 'Conflict'
            Conflict = $true
            Reason   = ("Drift in: {0}; lastModifiedBy '{1}' differs from deploy principal. Conflict will be overwritten because -OverwriteForeignAuthor was supplied." -f $DriftText, $Who)
        }
    }

    return [pscustomobject]@{
        Action   = 'Conflict'
        Category = 'Conflict'
        Conflict = $true
        Reason   = ("Drift in: {0}; lastModifiedBy '{1}' differs from deploy principal. Re-run with -OverwriteForeignAuthor to overwrite." -f $DriftText, $Who)
    }
}

function Get-TenantPaginated {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    $next = $Uri
    while ($next) {
        $resp = Invoke-RestMethod -Method GET -Uri $next -Headers $Headers -ErrorAction Stop
        if ($resp.value) {
            foreach ($v in $resp.value) { $items.Add($v) | Out-Null }
        }
        if ($resp.PSObject.Properties.Name -contains 'nextLink' -and $resp.nextLink) {
            $next = [string]$resp.nextLink
        } else {
            $next = $null
        }
    }
    return $items.ToArray()
}

function Get-TenantScanRuleset {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets/list-all
    return Get-TenantPaginated -Uri "$BaseUri/scanrulesets?api-version=$ApiVersion" -Headers $Headers
}

function Get-TenantDataSourceName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/list-all
    $items = Get-TenantPaginated -Uri "$BaseUri/datasources?api-version=$ApiVersion" -Headers $Headers
    return @($items | ForEach-Object { [string]$_.name })
}

function Get-TenantScan {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion,
        [Parameter(Mandatory = $true)][string]$DataSourceName
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans/list-by-data-source
    $encoded = [uri]::EscapeDataString($DataSourceName)
    return Get-TenantPaginated -Uri "$BaseUri/datasources/$encoded/scans?api-version=$ApiVersion" -Headers $Headers
}

function Get-TenantTriggerDefault {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion,
        [Parameter(Mandatory = $true)][string]$DataSourceName,
        [Parameter(Mandatory = $true)][string]$ScanName
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers/get-trigger
    $dsEnc   = [uri]::EscapeDataString($DataSourceName)
    $scanEnc = [uri]::EscapeDataString($ScanName)
    $uri = "$BaseUri/datasources/$dsEnc/scans/$scanEnc/triggers/default?api-version=$ApiVersion"
    try {
        return Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function ConvertTo-ScanExportDoc {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Scans,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Rulesets
    )

    $orderedScans = @($Scans | Sort-Object -Property `
        @{ Expression = { $_.dataSource.ToLowerInvariant() } }, `
        @{ Expression = { $_.name.ToLowerInvariant() } })
    $orderedRulesets = @($Rulesets | Sort-Object -Property { $_.name.ToLowerInvariant() })

    return [ordered]@{
        scanRulesets = @($orderedRulesets | ForEach-Object {
            [ordered]@{
                name       = $_.name
                kind       = $_.kind
                properties = (Get-ComparableScanProperty -Properties $_.properties -ComputedFields $script:ScanRulesetComputedFields)
            }
        })
        scans = @($orderedScans | ForEach-Object {
            $entry = [ordered]@{
                dataSource = $_.dataSource
                name       = $_.name
                kind       = $_.kind
                properties = (Get-ComparableScanProperty -Properties $_.properties -ComputedFields $script:ScanComputedFields)
            }
            if ($_.trigger) {
                $entry['trigger'] = (Get-ComparableScanProperty -Properties $_.trigger -ComputedFields $script:TriggerComputedFields)
            }
            $entry
        })
    }
}

function Invoke-ScansExport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Scans,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Rulesets,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
        $hasBody = $false
        if ($existing) {
            try {
                $existingDoc = $existing | ConvertFrom-Yaml -ErrorAction Stop
                if ($existingDoc) {
                    if (($existingDoc.ContainsKey('scans') -and $existingDoc.scans -and $existingDoc.scans.Count -gt 0) -or
                        ($existingDoc.ContainsKey('scanRulesets') -and $existingDoc.scanRulesets -and $existingDoc.scanRulesets.Count -gt 0)) {
                        $hasBody = $true
                    }
                }
            } catch {
                $hasBody = $false
            }
        }
        if ($hasBody -and -not $ForceOverwrite) {
            Write-Error ("Target YAML '{0}' already declares scans or scanRulesets. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }

    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }

    $doc = ConvertTo-ScanExportDoc -Scans $Scans -Rulesets $Rulesets
    $body = ConvertTo-Yaml $doc
    $nl = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} scan(s) and {1} scan ruleset(s) to '{2}'." -f $Scans.Count, $Rulesets.Count, $Path) -InformationAction Continue
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

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so neither destructive branch (repo-wins
# overwrite, -PruneMissing delete) can be entered unattended from a local
# terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

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

$desiredScans = @()
$desiredRulesets = @()
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

    if (-not $desiredRoot.ContainsKey('scans')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'scans'." -f $Path)
        return
    }
    if (-not $desiredRoot.ContainsKey('scanRulesets')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'scanRulesets' (use [] when none)." -f $Path)
        return
    }

    $desiredScans = @($desiredRoot.scans | ForEach-Object { ConvertTo-DesiredScanHash -Scan ([hashtable]$_) })
    $desiredRulesets = @($desiredRoot.scanRulesets | ForEach-Object { ConvertTo-DesiredScanRulesetHash -Ruleset ([hashtable]$_) })
    Write-Information ("Desired         : {0} scan(s), {1} scan ruleset(s)" -f $desiredScans.Count, $desiredRulesets.Count) -InformationAction Continue
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

# --- Enumerate tenant state ---
try {
    $tenantDataSourceNames = @(Get-TenantDataSourceName -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:ScansApiVersion)
} catch {
    Write-Error ("Failed to list tenant data sources: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
Write-Information ("Tenant DS       : {0} data source(s)" -f $tenantDataSourceNames.Count) -InformationAction Continue

try {
    $tenantRulesetsRaw = @(Get-TenantScanRuleset -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:ScansApiVersion)
} catch {
    Write-Error ("Failed to list tenant scan rulesets: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
# Custom-only: System rulesets are tenant-builtin and must not appear in
# desired-state YAML or in orphan-prune candidates.
$tenantCustomRulesetsRaw = @($tenantRulesetsRaw | Where-Object {
    $kind = if ($_.PSObject.Properties.Name -contains 'kind') { [string]$_.kind } else { '' }
    -not ($kind -like 'System*')
})
Write-Information ("Tenant rulesets : {0} ({1} custom)" -f $tenantRulesetsRaw.Count, $tenantCustomRulesetsRaw.Count) -InformationAction Continue

$tenantScansRaw = New-Object 'System.Collections.Generic.List[object]'
$tenantTriggersByScanKey = @{}
foreach ($dsName in $tenantDataSourceNames) {
    try {
        $scansForDs = @(Get-TenantScan -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:ScansApiVersion -DataSourceName $dsName)
    } catch {
        Write-Error ("Failed to list scans for data source '{0}': {1}" -f $dsName, (Format-PurviewRestError -ErrorRecord $_))
        return
    }
    foreach ($s in $scansForDs) {
        $tenantScansRaw.Add([pscustomobject]@{ DataSourceName = $dsName; Scan = $s }) | Out-Null
        try {
            $trig = Get-TenantTriggerDefault -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:ScansApiVersion -DataSourceName $dsName -ScanName ([string]$s.name)
        } catch {
            Write-Error ("Failed to GET default trigger for '{0}/{1}': {2}" -f $dsName, $s.name, (Format-PurviewRestError -ErrorRecord $_))
            return
        }
        if ($trig) {
            $key = ("{0}/{1}" -f $dsName.ToLowerInvariant(), ([string]$s.name).ToLowerInvariant())
            $tenantTriggersByScanKey[$key] = $trig
        }
    }
}
Write-Information ("Tenant scans    : {0} scan(s) across {1} source(s)" -f $tenantScansRaw.Count, $tenantDataSourceNames.Count) -InformationAction Continue

# --- Export branch ---
if ($mode -eq 'Export') {
    $tenantScanHashes = @($tenantScansRaw | ForEach-Object {
        $h = ConvertTo-TenantScanHash -DataSourceName $_.DataSourceName -Scan $_.Scan
        $key = ("{0}/{1}" -f $_.DataSourceName.ToLowerInvariant(), $h.name.ToLowerInvariant())
        if ($tenantTriggersByScanKey.ContainsKey($key)) {
            $h.trigger = ConvertTo-TenantTriggerHash -Trigger $tenantTriggersByScanKey[$key]
        }
        $h
    })
    $tenantRulesetHashes = @($tenantCustomRulesetsRaw | ForEach-Object { ConvertTo-TenantScanRulesetHash -Ruleset $_ })

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

    if ($PSCmdlet.ShouldProcess($exportTarget, 'Write exported scans state')) {
        Invoke-ScansExport -Path $exportTarget -Scans $tenantScanHashes -Rulesets $tenantRulesetHashes -ForceOverwrite $Force.IsPresent
    } else {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no file written):' -InformationAction Continue
        Write-Information ("  Would write {0} scan(s) and {1} ruleset(s) to '{2}'." -f $tenantScanHashes.Count, $tenantRulesetHashes.Count, $exportTarget) -InformationAction Continue
    }
    return
}

# --- Cross-domain validation (Apply) ---
$tenantDsLower = @{}
foreach ($n in $tenantDataSourceNames) { $tenantDsLower[$n.ToLowerInvariant()] = $true }

$desiredRulesetByName = @{}
foreach ($r in $desiredRulesets) {
    $rKey = $r.name.ToLowerInvariant()
    if ($desiredRulesetByName.ContainsKey($rKey)) {
        Write-Error ("Duplicate scan ruleset name '{0}' in YAML. Names must be unique." -f $r.name)
        return
    }
    $desiredRulesetByName[$rKey] = $r
}

$desiredScanByKey = @{}
foreach ($s in $desiredScans) {
    $key = ("{0}/{1}" -f $s.dataSource.ToLowerInvariant(), $s.name.ToLowerInvariant())
    if ($desiredScanByKey.ContainsKey($key)) {
        Write-Error ("Duplicate scan key '{0}' in YAML. Scan names must be unique per data source." -f $key)
        return
    }
    $desiredScanByKey[$key] = $s

    if (-not $tenantDsLower.ContainsKey($s.dataSource.ToLowerInvariant())) {
        Write-Error ("Scan '{0}' references data source '{1}', which is not currently registered in the tenant. Run Deploy-DataSources.ps1 first." -f $s.name, $s.dataSource)
        return
    }
    $rulesetType = [string]$s.properties.scanRulesetType
    $rulesetName = [string]$s.properties.scanRulesetName
    if ($rulesetType -eq 'Custom' -and -not $desiredRulesetByName.ContainsKey($rulesetName.ToLowerInvariant())) {
        Write-Error ("Scan '{0}' references custom scanRulesetName '{1}', which is not declared under scanRulesets in YAML." -f $s.name, $rulesetName)
        return
    }
}

# --- Build per-resource tenant maps ---
$tenantRulesetByName = @{}
$tenantRulesetRawByName = @{}
foreach ($t in $tenantCustomRulesetsRaw) {
    $h = ConvertTo-TenantScanRulesetHash -Ruleset $t
    $tenantRulesetByName[$h.name.ToLowerInvariant()] = $h
    $tenantRulesetRawByName[$h.name.ToLowerInvariant()] = $t
}

$tenantScanByKey = @{}
$tenantScanRawByKey = @{}
foreach ($entry in $tenantScansRaw) {
    $h = ConvertTo-TenantScanHash -DataSourceName $entry.DataSourceName -Scan $entry.Scan
    $key = ("{0}/{1}" -f $h.dataSource.ToLowerInvariant(), $h.name.ToLowerInvariant())
    if ($tenantTriggersByScanKey.ContainsKey($key)) {
        $h.trigger = ConvertTo-TenantTriggerHash -Trigger $tenantTriggersByScanKey[$key]
    }
    $tenantScanByKey[$key] = $h
    $tenantScanRawByKey[$key] = $entry.Scan
}

# --- Plan ---
$plan = New-Object 'System.Collections.Generic.List[object]'

# Scan rulesets (custom only).
foreach ($r in ($desiredRulesets | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $rKey = $r.name.ToLowerInvariant()
    if ($tenantRulesetByName.ContainsKey($rKey)) {
        $diffs = Compare-ScanRulesetHash -Desired $r -Tenant $tenantRulesetByName[$rKey]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Kind = 'ScanRuleset'; Action = 'NoChange'; Name = $r.name; Desired = $r; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            # ADR 0053: classify authorship first (pure), then let
            # Resolve-ConflictPlanAction decide whether the override authorises
            # the write. The Conflict row is emitted either way.
            $isConflict = Test-ConflictRow -TenantRaw $tenantRulesetRawByName[$rKey] -DeployIdentity $deployIdentity
            $who = if ($isConflict) { [string](Get-LastModifiedByIdentity -Source $tenantRulesetRawByName[$rKey]) } else { '' }
            $decision = Resolve-ConflictPlanAction `
                -IsConflict $isConflict `
                -OverwriteForeignAuthor $OverwriteForeignAuthor.IsPresent `
                -DriftText ($diffs -join ', ') `
                -Who $who
            $plan.Add([pscustomobject]@{ Kind = 'ScanRuleset'; Action = $decision.Action; Name = $r.name; Desired = $r; Reason = $decision.Reason; Conflict = $decision.Conflict }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Kind = 'ScanRuleset'; Action = 'Create'; Name = $r.name; Desired = $r; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}
foreach ($t in ($tenantRulesetByName.Values | Where-Object { -not $desiredRulesetByName.ContainsKey($_.name.ToLowerInvariant()) } | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Kind = 'ScanRuleset'; Action = 'Orphan'; Name = $t.name; Desired = $null; Reason = $reason }) | Out-Null
}

# Scans + triggers.
foreach ($s in ($desiredScans | Sort-Object -Property `
    @{ Expression = { $_.dataSource.ToLowerInvariant() } }, `
    @{ Expression = { $_.name.ToLowerInvariant() } })) {

    $key = ("{0}/{1}" -f $s.dataSource.ToLowerInvariant(), $s.name.ToLowerInvariant())
    $displayName = ("{0}/{1}" -f $s.dataSource, $s.name)

    if ($tenantScanByKey.ContainsKey($key)) {
        $tenantScan = $tenantScanByKey[$key]
        $diffs = Compare-ScanHash -Desired $s -Tenant $tenantScan
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Kind = 'Scan'; Action = 'NoChange'; Name = $displayName; Desired = $s; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            # ADR 0053: classify authorship first (pure), then let
            # Resolve-ConflictPlanAction decide whether the override authorises
            # the write. The Conflict row is emitted either way.
            $isConflict = Test-ConflictRow -TenantRaw $tenantScanRawByKey[$key] -DeployIdentity $deployIdentity
            $who = if ($isConflict) { [string](Get-LastModifiedByIdentity -Source $tenantScanRawByKey[$key]) } else { '' }
            $decision = Resolve-ConflictPlanAction `
                -IsConflict $isConflict `
                -OverwriteForeignAuthor $OverwriteForeignAuthor.IsPresent `
                -DriftText ($diffs -join ', ') `
                -Who $who
            $plan.Add([pscustomobject]@{ Kind = 'Scan'; Action = $decision.Action; Name = $displayName; Desired = $s; Reason = $decision.Reason; Conflict = $decision.Conflict }) | Out-Null
        }

        # Trigger plan (only when scan exists; new scans get their trigger
        # applied immediately after the scan create, planned separately below).
        $trigDiffs = Compare-TriggerHash -Desired $s.trigger -Tenant $tenantScan.trigger
        if ($trigDiffs.Count -eq 0) {
            if ($s.trigger -or $tenantScan.trigger) {
                $plan.Add([pscustomobject]@{ Kind = 'Trigger'; Action = 'NoChange'; Name = $displayName; Desired = $s; Reason = 'Trigger in sync with tenant.' }) | Out-Null
            }
        } elseif ($s.trigger) {
            $plan.Add([pscustomobject]@{ Kind = 'Trigger'; Action = (if ($tenantScan.trigger) { 'Update' } else { 'Create' }); Name = $displayName; Desired = $s; Reason = ('Trigger drift: {0}' -f ($trigDiffs -join ', ')) }) | Out-Null
        } else {
            # Desired says no trigger, but tenant has one -> orphan trigger.
            $reason = if ($PruneMissing.IsPresent) { 'Trigger tenant-only; will be removed (-PruneMissing).' } else { 'Trigger tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Kind = 'Trigger'; Action = 'Orphan'; Name = $displayName; Desired = $s; Reason = $reason }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Kind = 'Scan'; Action = 'Create'; Name = $displayName; Desired = $s; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
        if ($s.trigger) {
            $plan.Add([pscustomobject]@{ Kind = 'Trigger'; Action = 'Create'; Name = $displayName; Desired = $s; Reason = 'Trigger declared for new scan.' }) | Out-Null
        }
    }
}

# Orphan scans (and their triggers).
foreach ($t in ($tenantScanByKey.Values | Where-Object { -not $desiredScanByKey.ContainsKey(("{0}/{1}" -f $_.dataSource.ToLowerInvariant(), $_.name.ToLowerInvariant())) } | Sort-Object -Property `
    @{ Expression = { $_.dataSource.ToLowerInvariant() } }, `
    @{ Expression = { $_.name.ToLowerInvariant() } })) {

    $displayName = ("{0}/{1}" -f $t.dataSource, $t.name)
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Kind = 'Scan'; Action = 'Orphan'; Name = $displayName; Desired = $null; Reason = $reason }) | Out-Null
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

# Direction-policy pass: portal-wins drift-skip on Update / Conflict
# rows, plus `-SkipNames` pre-pass that promotes any matched row
# (Create / Update / NoChange / Orphan / Conflict) to Skip across
# ScanRuleset, Scan, and Trigger kinds. Audit short-circuit does not
# enter this pass. SkipNames match is case-insensitive against the
# bare plan-row Name -- a ruleset name for ScanRuleset rows, the
# composite `<dataSource>/<scanName>` for Scan and Trigger rows.
$script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'

# ADR 0052: every scan object whose tenant fields this run WILL overwrite.
# Constructed OUTSIDE the policy test below so the gate can read .Count on
# it unconditionally -- under `audit` the pass never runs, the list stays
# empty, and the gate correctly stays silent.
$repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

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
                Kind        = [string]$row.Kind
                DisplayName = [string]$row.Name
                Reason      = $decision.Reason
            })
            continue
        }
        if ($row.Action -eq 'Update') {
            $fieldsText = ($row.Reason -replace '^Drift in: ', '')
            if ($DirectionPolicy -eq 'repo-wins') {
                Write-Warning ("repo-wins overwriting tenant on Purview {0} '{1}' fields: {2}" -f $row.Kind, $row.Name, $fieldsText)
            }
            # Every Update row that survived the Skip decision WILL be PUT,
            # whatever policy let it through -- an ADR 0053 Conflict row that
            # -OverwriteForeignAuthor promoted to Update included. Collect it here,
            # OUTSIDE the repo-wins test above: the ADR 0052 gate is keyed on this
            # list -- the plan -- and never on $DirectionPolicy. Populating it only
            # under repo-wins would leave the list empty under portal-wins, the
            # plan-keyed gate would see zero, and the overwrite would proceed
            # unconfirmed. See ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON
            # THE POLICY".
            $repoWinsOverwrites.Add(("{0} '{1}'" -f $row.Kind, $row.Name)) | Out-Null
        }
    }
    # Machine-readable markers per skipped object. Format must match
    # `^\[ADR0029-SKIP\] (.+)$` per the github-actions instructions.
    foreach ($s in $script:Adr0029Skips) {
        Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
    }
}

# ---- ADR 0052: destructive-operation confirmation gate ----
# The last point before the apply loop at which nothing has been PUT or
# DELETEd. Both destructive branches are gated here, once per run, via
# $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
# unconditionally; ShouldProcess only prompts when ConfirmImpact >=
# $ConfirmPreference, which is precisely the comparison that silently
# defeated this gate before issue #85.
#
# Both gates are keyed on the PLAN -- the objects this run will actually
# overwrite or delete -- and never on $DirectionPolicy. Every Kind
# (ScanRuleset / Scan / Trigger) is counted in one prompt: they are written
# in one run, and the operator is entitled to see the whole blast radius
# before answering once.
#
# Suppressed by -Force, by an explicit -Confirm:$false (the CI path), and
# skipped under -WhatIf so a dry run still previews the deletes without
# blocking on input. `-DirectionPolicy audit` sets $WhatIfPreference above,
# so an audit run cannot prompt either.
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
    $overwriteQuery = "This run will OVERWRITE tenant fields on {0} Purview scanning object(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
        $overwriteNames.Count, ($overwriteNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
        throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# Derived from the FINAL plan one line above the gate and read one line
# later, so it cannot diverge from the deletes it speaks for.
$pruneTargets = @($plan | Where-Object { $_.Action -eq 'Orphan' })
if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
    $pruneNames = @($pruneTargets | ForEach-Object { "{0} '{1}'" -f $_.Kind, $_.Name } | Sort-Object -Unique)
    $pruneQuery = "-PruneMissing will DELETE {0} orphan Purview scanning object(s) from the account: {1}. This cannot be undone. Continue?" -f `
        $pruneNames.Count, ($pruneNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# --- Apply ---
$report = New-Object 'System.Collections.Generic.List[object]'

function Invoke-ScanRulesetPut {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)
    $payload = @{ kind = $Desired.kind; properties = $Desired.properties } | ConvertTo-Json -Depth 25 -Compress
    $uri = "$baseUri/scanrulesets/$([uri]::EscapeDataString($Desired.name))?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ErrorAction Stop
}

function Invoke-ScanRulesetDelete {
    param([Parameter(Mandatory = $true)][string]$Name)
    $uri = "$baseUri/scanrulesets/$([uri]::EscapeDataString($Name))?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

function Invoke-ScanPut {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)
    $payload = @{ kind = $Desired.kind; properties = $Desired.properties } | ConvertTo-Json -Depth 25 -Compress
    $dsEnc = [uri]::EscapeDataString($Desired.dataSource)
    $nmEnc = [uri]::EscapeDataString($Desired.name)
    $uri = "$baseUri/datasources/$dsEnc/scans/$nmEnc`?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ErrorAction Stop
}

function Invoke-ScanDelete {
    param(
        [Parameter(Mandatory = $true)][string]$DataSourceName,
        [Parameter(Mandatory = $true)][string]$ScanName
    )
    $dsEnc = [uri]::EscapeDataString($DataSourceName)
    $nmEnc = [uri]::EscapeDataString($ScanName)
    $uri = "$baseUri/datasources/$dsEnc/scans/$nmEnc`?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

function Invoke-TriggerPut {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)
    # Trigger payload uses { properties: {...} }. Reference:
    # https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers/create-trigger
    $payload = @{ properties = $Desired.trigger } | ConvertTo-Json -Depth 25 -Compress
    $dsEnc = [uri]::EscapeDataString($Desired.dataSource)
    $nmEnc = [uri]::EscapeDataString($Desired.name)
    $uri = "$baseUri/datasources/$dsEnc/scans/$nmEnc/triggers/default?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ErrorAction Stop
}

function Invoke-TriggerDelete {
    param(
        [Parameter(Mandatory = $true)][string]$DataSourceName,
        [Parameter(Mandatory = $true)][string]$ScanName
    )
    $dsEnc = [uri]::EscapeDataString($DataSourceName)
    $nmEnc = [uri]::EscapeDataString($ScanName)
    $uri = "$baseUri/datasources/$dsEnc/scans/$nmEnc/triggers/default?api-version=$script:ScansApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

foreach ($row in $plan) {
    $target = "Purview $($row.Kind) '$($row.Name)'"

    switch ($row.Action) {
        'NoChange' {
            $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Skip' {
            # ADR 0029 portal-wins drift skip or -SkipNames pre-pass.
            # Reported but never written; -PruneMissing is bypassed.
            $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Conflict' {
            $report.Add([pscustomobject]@{ Category = 'Conflict'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Create' {
            $opDesc = "PUT $($row.Kind) (Create)"
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    switch ($row.Kind) {
                        'ScanRuleset' { Invoke-ScanRulesetPut -Desired $row.Desired }
                        'Scan'        { Invoke-ScanPut        -Desired $row.Desired }
                        'Trigger'     { Invoke-TriggerPut     -Desired $row.Desired }
                    }
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = $row.Kind; Name = $row.Name; Reason = ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Update' {
            $opDesc = "PUT $($row.Kind) (Update)"
            # ADR 0053: an Update that overwrites a foreign-authored scan or
            # ruleset is reported as a Conflict row, never laundered into a plain
            # Update. The switch grants permission, not silence.
            $updateCategory = if ($row.PSObject.Properties['Conflict'] -and $row.Conflict) { 'Conflict' } else { 'Update' }
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    switch ($row.Kind) {
                        'ScanRuleset' { Invoke-ScanRulesetPut -Desired $row.Desired }
                        'Scan'        { Invoke-ScanPut        -Desired $row.Desired }
                        'Trigger'     { Invoke-TriggerPut     -Desired $row.Desired }
                    }
                    $report.Add([pscustomobject]@{ Category = $updateCategory; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = $row.Kind; Name = $row.Name; Reason = ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = $updateCategory; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Orphan' {
            if (-not $PruneMissing.IsPresent) {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = $row.Kind; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                continue
            }

            $opDesc = "DELETE $($row.Kind)"
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    switch ($row.Kind) {
                        'ScanRuleset' { Invoke-ScanRulesetDelete -Name $row.Name }
                        'Scan' {
                            $parts = $row.Name -split '/', 2
                            Invoke-ScanDelete -DataSourceName $parts[0] -ScanName $parts[1]
                        }
                        'Trigger' {
                            $parts = $row.Name -split '/', 2
                            Invoke-TriggerDelete -DataSourceName $parts[0] -ScanName $parts[1]
                        }
                    }
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = $row.Kind; Name = $row.Name; Reason = 'Deleted (-PruneMissing).' }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = $row.Kind; Name = $row.Name; Reason = ("Delete failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = $row.Kind; Name = $row.Name; Reason = 'Would be deleted (-PruneMissing).' }) | Out-Null
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
