#Requires -Version 7.4
<#
.SYNOPSIS
    Wave 4b-ii placeholder reconciler for Microsoft Purview Unified Catalog.

.DESCRIPTION
    Loads the five per-concept YAMLs from `data-plane/unified-catalog/`,
    validates each against its co-located Draft-07 JSON schema using
    `Test-Json -SchemaFile`, and emits a per-concept plan table computed
    against an EMPTY tenant baseline. With an empty baseline, every desired
    item plans as `Create`; when desired is also empty, the row is
    `NoChange`.

    The script makes NO live REST or Microsoft Graph calls. Surface
    selection (Purview REST vs. Microsoft Graph vs. PowerShell module) is
    deferred to the follow-up authoring-surface ADR opened during Wave 4b
    research per docs/adr/0024-unified-catalog-folder-placement.md.
    Until that ADR ships, the script supports `-WhatIf` only:

      - Apply mode without `-WhatIf`  -> throws "not implemented -
        pending authoring-surface ADR".
      - `-ExportCurrentState`         -> throws the same message; no
        live tenant read path is defined.
      - `-PruneMissing`               -> declared for full-circle
        reconciler contract-guard parity and accepted as a no-op (there
        is no tenant baseline to prune against).

    Parameter shape mirrors `Deploy-Scans.ps1` and `Deploy-Policies.ps1`
    and honours the ADR 0012 `-ParametersFile` contract.

    References:
      Microsoft Purview Unified Catalog (concept):
        https://learn.microsoft.com/en-us/purview/unified-catalog
      Test-Json -SchemaFile (PowerShell 7.4):
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      JSON Schema Draft-07:
        https://json-schema.org/specification-links#draft-7
      ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0024 (Unified Catalog folder placement; authoring-surface deferred):
        docs/adr/0024-unified-catalog-folder-placement.md

.PARAMETER Path
    Folder containing the five per-concept YAMLs and schemas. Defaults to
    `data-plane/unified-catalog/` resolved from repo root.

.PARAMETER PruneMissing
    Declared for full-circle reconciler contract-guard parity. No-op in
    this placeholder iteration because there is no live tenant baseline.

.PARAMETER Force
    Reserved for the live apply iteration. No-op today.

.PARAMETER ExportCurrentState
    Reserved for the live apply iteration. Throws today because there is
    no documented Unified Catalog REST surface to read from.

.PARAMETER ParametersFile
    Environment parameters YAML path (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved from repo root.

.PARAMETER AccountName
    Purview account name. When omitted, resolved from `purviewAccountName`
    in `-ParametersFile`. Captured for downstream parity even though this
    iteration makes no Purview calls.

.EXAMPLE
    ./scripts/Deploy-UnifiedCatalog.ps1 -AccountName purview-contoso-lab -WhatIf

    Validates every YAML against its schema and prints the placeholder
    plan table. No live writes.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\unified-catalog'),

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
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [Alias('PurviewAccountName')]
    [string]$AccountName
)

$ErrorActionPreference = 'Stop'

# Per-concept manifest. Each entry pairs a YAML file with its co-located
# Draft-07 schema and the singular noun used in plan-table output. Keep this
# in sync with `data-plane/unified-catalog/`; adding a sixth concept is a
# separate PR that updates this table and ships the matching schema.
$script:UnifiedCatalogConcepts = @(
    @{ Concept = 'GovernanceDomain'    ; Yaml = 'governance-domains.yaml'    ; Schema = 'governance-domains.schema.json' },
    @{ Concept = 'DataProduct'         ; Yaml = 'data-products.yaml'         ; Schema = 'data-products.schema.json' },
    @{ Concept = 'CriticalDataElement' ; Yaml = 'critical-data-elements.yaml'; Schema = 'critical-data-elements.schema.json' },
    @{ Concept = 'HealthControl'       ; Yaml = 'health-controls.yaml'       ; Schema = 'health-controls.schema.json' },
    @{ Concept = 'Okr'                 ; Yaml = 'okrs.yaml'                  ; Schema = 'okrs.schema.json' }
)

function Get-DesiredItem {
    <#
    .SYNOPSIS
        Load a Unified Catalog YAML and validate it against its Draft-07 schema.
    .DESCRIPTION
        Reads the YAML at $YamlPath, validates the round-tripped JSON against
        $SchemaPath via Test-Json -SchemaFile, and returns the `items` array.
        Returns an empty array when items is `[]`. Throws on missing files,
        empty parse output, missing top-level `items` key, or schema failure.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$YamlPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw ("Desired-state YAML not found: '{0}'." -f $YamlPath)
    }
    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        throw ("Schema file not found: '{0}'." -f $SchemaPath)
    }

    $raw = Get-Content -LiteralPath $YamlPath -Raw
    $doc = $raw | ConvertFrom-Yaml
    if ($null -eq $doc) {
        throw ("YAML '{0}' parsed as empty." -f $YamlPath)
    }
    if (-not ($doc -is [System.Collections.IDictionary])) {
        throw ("YAML '{0}' did not parse as a mapping at the document root." -f $YamlPath)
    }
    if (-not $doc.ContainsKey('items')) {
        throw ("YAML '{0}' is missing required top-level key 'items' (use [] when none)." -f $YamlPath)
    }

    # Test-Json validates JSON text, not a hashtable. Round-trip through
    # ConvertTo-Json -Depth 25 so nested arrays/objects survive.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    $json = $doc | ConvertTo-Json -Depth 25
    $null = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop

    return @($doc.items)
}

function Get-ConceptPlan {
    <#
    .SYNOPSIS
        Compute the placeholder plan rows for a single Unified Catalog concept.
    .DESCRIPTION
        The live tenant baseline is intentionally empty: the authoring-surface
        ADR has not yet selected the REST/Graph endpoint to GET from, so until
        then every desired row is treated as Create and an empty desired set
        is a single whole-file NoChange row. -PruneMissing has no effect
        because there is no tenant set to diff against.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Concept,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Desired
    )

    if ($Desired.Count -eq 0) {
        return @([pscustomobject]@{
            Concept = $Concept
            Name    = '(none)'
            Action  = 'NoChange'
        })
    }

    return @($Desired | ForEach-Object {
        [pscustomobject]@{
            Concept = $Concept
            Name    = [string]$_.name
            Action  = 'Create'
        }
    })
}

# ---- Module bootstrap (powershell-yaml) ----
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

# ---- Resolve parameters file (ADR 0012) ----
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

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Unified Catalog folder not found: '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $AccountName) -InformationAction Continue
Write-Information ("YAML folder     : {0}" -f $Path) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
# -PruneMissing and -Force are declared for full-circle reconciler
# contract-guard parity and reserved for the live-apply iteration. Echo
# their state so that an operator can confirm the placeholder is honoring
# the same parameter surface the live reconcilers will use.
Write-Information ("PruneMissing    : {0} (reserved; no-op until authoring-surface ADR ships)" -f $PruneMissing.IsPresent) -InformationAction Continue
Write-Information ("Force           : {0} (reserved; no-op until authoring-surface ADR ships)" -f $Force.IsPresent) -InformationAction Continue

# ---- Authoring-surface gate (ADR 0024 follow-up still open) ----
$pendingAdrMessage = (
    'Deploy-UnifiedCatalog.ps1 is a -WhatIf-only placeholder. Live apply ' +
    '(create/update/delete against Microsoft Purview Unified Catalog) and ' +
    '-ExportCurrentState are pending the follow-up authoring-surface ADR ' +
    'opened during Wave 4b research. See ' +
    'docs/adr/0024-unified-catalog-folder-placement.md.'
)
if ($mode -eq 'Export') {
    throw $pendingAdrMessage
}
if (-not $WhatIfPreference) {
    throw $pendingAdrMessage
}

# ---- Validate + plan each concept ----
$allRows = New-Object 'System.Collections.Generic.List[object]'
foreach ($concept in $script:UnifiedCatalogConcepts) {
    $yamlPath   = Join-Path $Path $concept.Yaml
    $schemaPath = Join-Path $Path $concept.Schema
    Write-Information ("Validating {0,-19} : {1}" -f $concept.Concept, $concept.Yaml) -InformationAction Continue
    # Wrap in @() so an empty items: [] does not collapse to $null on
    # single-value assignment and break the [object[]] binding below.
    $desired = @(Get-DesiredItem -YamlPath $yamlPath -SchemaPath $schemaPath)
    $rows = Get-ConceptPlan -Concept $concept.Concept -Desired $desired
    foreach ($r in $rows) { $allRows.Add($r) | Out-Null }
}

Write-Information '' -InformationAction Continue
Write-Information 'Plan (placeholder; empty tenant baseline; live apply pending authoring-surface ADR):' -InformationAction Continue
$allRows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Information $_ -InformationAction Continue }
