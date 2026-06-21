#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only Microsoft Purview Sensitive Information Type (SIT) hit-volume
    and confidence analyzer. Consumes the JSON artifacts produced by
    `scripts/Export-ContentExplorerData.ps1` and emits a per-SIT report
    that the lab owner can use to retire or retune custom SITs.

.DESCRIPTION
    Wave 3 (issue #76) optional analysis helper. Standalone -- not part of
    the DSPM reconciler chain, not a `Deploy-*.ps1`, issues zero tenant
    calls. The input is a Content Explorer export run directory created
    by `Export-ContentExplorerData.ps1`; the output is a paired
    `sit-confidence-report.md` + `sit-confidence-report.csv` written to
    `verify-sit-confidence-output/<timestamp>/`.

    Microsoft Purview's `Get-ContentExplorerData` does NOT return a
    per-record confidence score; it returns the content items that
    matched a given SIT or sensitivity label per Workload. The
    "confidence" angle this helper exposes is therefore signal-volume
    -- how many records each SIT actually matched, and across how many
    Workloads -- which is the practical input the lab owner needs to
    decide whether a custom SIT is worth keeping, retuning, or
    retiring.

    Outputs (per row, one row per SIT seen in the run):
      * Name              -- SIT display name from the manifest.
      * Id                -- SIT GUID resolved from the sit-catalog.
      * Type              -- `Custom`, `Entity`, `Credential`, etc.
      * IsCustom          -- $true only for `Custom` SITs (lab-published).
      * Hits              -- record count summed across all workloads.
      * WorkloadsWithHits -- count of workloads where Hits > 0.
      * WorkloadsScanned  -- count of workloads attempted in the run.
      * Signal            -- `None` / `Isolated` / `Broad` (see below).
      * Recommendation    -- `Retain` / `Review` / `Retire` / `Reference`.

    Signal classification (single workload):
      None     Hits == 0
      Isolated Hits > 0 in exactly one Workload
      Broad    Hits > 0 in more than one Workload

    Recommendation logic:
      Reference  SIT.Type != Custom -- Microsoft built-in, not actionable
                 from this repo (read-only per
                 https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions ).
      Retire     IsCustom AND Hits == 0 across every scanned Workload.
      Review     IsCustom AND 0 < Hits < `-MinHits`, OR Signal == Isolated.
      Retain     IsCustom AND Hits >= `-MinHits` AND Signal == Broad.

    `-WhatIf` returns the resolved report plan as objects on the
    pipeline and writes no files. Use this to dry-run threshold
    changes before persisting a report.

    References (Microsoft Learn):
      Content Explorer overview:
        https://learn.microsoft.com/en-us/purview/data-classification-content-explorer
      Get-ContentExplorerData:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata
      Sensitive information type entity definitions:
        https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions
      Sensitive information types learn page:
        https://learn.microsoft.com/en-us/purview/sit-learn-about-sensitive-information-types
      Custom sensitive information types:
        https://learn.microsoft.com/en-us/purview/sit-get-started-with-custom-sensitive-information-types
      about_Functions_CmdletBindingAttribute (SupportsShouldProcess):
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      ADR 0021 (DSPM Content Explorer cadence + retention):
        docs/adr/0021-dspm-content-explorer-cadence.md

.PARAMETER ExportRoot
    Root directory containing one or more `Export-ContentExplorerData.ps1`
    run subdirectories. The script picks the lexicographically newest
    subdirectory unless `-RunDirectory` is supplied. Defaults to
    `<repoRoot>/verify-dspm-export-output`.

.PARAMETER RunDirectory
    Explicit run directory to analyze. Must contain a `manifest.json`
    written by the exporter. When supplied, `-ExportRoot` is ignored.

.PARAMETER SitCatalogPath
    Path to the desired-state SIT catalog YAML. Defaults to
    `<repoRoot>/data-plane/classifications/sit-catalog.yaml`. The
    catalog supplies the `id`/`type` columns the report cross-references
    against the manifest's SIT names.

.PARAMETER OutputRoot
    Override the parent directory for the timestamped report folder.
    Defaults to `<repoRoot>/verify-sit-confidence-output`. The folder
    is gitignored at repo root; do not commit raw output.

.PARAMETER MinHits
    Inclusive lower bound used by the Recommendation column to separate
    `Review` from `Retain`. Default 5. Must be >= 1.

.PARAMETER CustomOnly
    Filter the emitted report to `IsCustom == $true` rows. Built-in
    SITs are still loaded for cross-reference but suppressed from
    output.

.EXAMPLE
    ./scripts/Invoke-SITConfidenceAnalysis.ps1 -WhatIf

    Resolve the newest export run, build the report in memory, emit
    the rows on the pipeline, write no files.

.EXAMPLE
    ./scripts/Invoke-SITConfidenceAnalysis.ps1 -CustomOnly

    Analyze the newest export run, suppress Microsoft built-ins from
    the written report, persist markdown + CSV under
    `verify-sit-confidence-output/<timestamp>/`.

.EXAMPLE
    ./scripts/Invoke-SITConfidenceAnalysis.ps1 `
        -RunDirectory ./verify-dspm-export-output/2026-05-17-1200 `
        -MinHits 10

    Analyze a specific run and tighten the Retain threshold.

.NOTES
    File Name      : Invoke-SITConfidenceAnalysis.ps1
    Author         : Marcus Jacobson
    Version History: 1.0.0 -- initial release (Wave 3 / issue #76)

    Caller role requirements: none. This script is local-only and reads
    files written by the exporter. It issues no Azure, Microsoft Graph,
    or Microsoft Purview calls.

    See also:
      docs/runbooks/sit-confidence-analysis.md
      scripts/Export-ContentExplorerData.ps1
      data-plane/classifications/sit-catalog.yaml
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ExportRoot,

    [ValidateNotNullOrEmpty()]
    [string]$RunDirectory,

    [ValidateNotNullOrEmpty()]
    [string]$SitCatalogPath,

    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot,

    [ValidateRange(1, 1000000)]
    [int]$MinHits = 5,

    [switch]$CustomOnly
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

#region Helper functions (AST-extractable; testable in isolation)

function Resolve-RunDirectory {
    <#
    .SYNOPSIS
        Pick the run directory to analyze.

    .DESCRIPTION
        If $RunDirectoryPath is supplied, return it (after Resolve-Path).
        Otherwise pick the lexicographically newest immediate child of
        $ExportRootPath that contains a `manifest.json`. Throws when no
        candidate exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$RunDirectoryPath,
        [string]$ExportRootPath
    )

    if ($RunDirectoryPath) {
        if (-not (Test-Path -LiteralPath $RunDirectoryPath)) {
            throw ("RunDirectory not found at '{0}'." -f $RunDirectoryPath)
        }
        $resolved = (Resolve-Path -LiteralPath $RunDirectoryPath).Path
        $manifest = Join-Path $resolved 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw ("RunDirectory '{0}' has no manifest.json." -f $resolved)
        }
        return $resolved
    }

    if (-not $ExportRootPath) {
        throw 'Either -RunDirectory or -ExportRoot must resolve to a valid path.'
    }
    if (-not (Test-Path -LiteralPath $ExportRootPath)) {
        throw ("ExportRoot not found at '{0}'." -f $ExportRootPath)
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $ExportRootPath -Directory -ErrorAction Stop |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object Name -Descending
    )
    if ($candidates.Count -eq 0) {
        throw ("No run subdirectory under '{0}' contains a manifest.json." -f $ExportRootPath)
    }
    return $candidates[0].FullName
}

function Get-PairFileRecordCount {
    <#
    .SYNOPSIS
        Count Content Explorer records in one (Kind, Name, Workload)
        JSON file written by Export-ContentExplorerData.ps1.

    .DESCRIPTION
        The exporter writes the captured pages as a JSON array. Each
        page may be an array of records, a single record, or an object
        wrapping records. This function flattens conservatively and
        returns the number of non-null leaf records. Robustness over
        exactness: a missing/empty file returns 0 (with a verbose
        message) rather than throwing, so a single malformed pair does
        not abort an entire run.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose ("Pair file missing: {0}" -f $Path)
        return 0
    }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return 0
    }

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json
        $doc = $raw | ConvertFrom-Json -Depth 64
    }
    catch {
        Write-Verbose ("Pair file '{0}' not valid JSON: {1}" -f $Path, $_.Exception.Message)
        return 0
    }

    if ($null -eq $doc) { return 0 }

    $count = 0
    foreach ($page in @($doc)) {
        if ($null -eq $page) { continue }
        # Array-of-records page.
        if ($page -is [System.Collections.IEnumerable] -and -not ($page -is [string])) {
            foreach ($r in $page) {
                if ($null -ne $r) { $count++ }
            }
            continue
        }
        # Single-record page or wrapper.
        $count++
    }
    return $count
}

function Get-SitIndex {
    <#
    .SYNOPSIS
        Build a name-keyed hashtable of SIT catalog rows.

    .DESCRIPTION
        Accepts the parsed YAML document (hashtable) and returns a
        hashtable keyed by SIT name with value:
            @{ Id = <guid>; Type = <string>; Publisher = <string> }
        Empty or malformed inputs return an empty hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object]$YamlDoc
    )

    $index = @{}
    if ($null -eq $YamlDoc) { return $index }
    if (-not ($YamlDoc -is [System.Collections.IDictionary])) { return $index }
    if (-not $YamlDoc.Contains('sits')) { return $index }

    foreach ($sit in @($YamlDoc['sits'])) {
        if ($null -eq $sit) { continue }
        if (-not ($sit -is [System.Collections.IDictionary])) { continue }
        $name = [string]$sit['name']
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $index[$name] = @{
            Id        = [string]$sit['id']
            Type      = [string]$sit['type']
            Publisher = [string]$sit['publisher']
        }
    }
    return $index
}

function Get-Recommendation {
    <#
    .SYNOPSIS
        Compute (Signal, Recommendation) for one aggregated SIT row.

    .DESCRIPTION
        Pure function -- no I/O. Lab-owner-visible Recommendation logic
        lives here so it can be unit-tested without touching disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [bool]$IsCustom,

        [Parameter(Mandatory)]
        [int]$Hits,

        [Parameter(Mandatory)]
        [int]$WorkloadsWithHits,

        [Parameter(Mandatory)]
        [int]$MinHits
    )

    $signal =
        if     ($Hits -le 0)            { 'None' }
        elseif ($WorkloadsWithHits -le 1) { 'Isolated' }
        else                              { 'Broad' }

    $recommendation =
        if     (-not $IsCustom)            { 'Reference' }
        elseif ($signal -eq 'None')        { 'Retire' }
        elseif ($Hits -lt $MinHits)        { 'Review' }
        elseif ($signal -eq 'Isolated')    { 'Review' }
        else                                { 'Retain' }

    return @{ Signal = $signal; Recommendation = $recommendation }
}

function ConvertTo-ReportRow {
    <#
    .SYNOPSIS
        Aggregate per-workload manifest rows into one report row per SIT.

    .DESCRIPTION
        Accepts:
          $ManifestRows -- the array from manifest.json `.rows`.
          $PairCounts   -- hashtable: file name -> integer record count.
          $SitIndex     -- output of Get-SitIndex.
          $MinHits      -- threshold for Get-Recommendation.

        Emits one PSCustomObject per distinct SIT name observed.
        Manifest rows with Kind != 'SIT' are silently skipped (this
        analyzer is scoped to SITs only; label aggregation is out of
        scope per issue #76).
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)] $ManifestRows,
        [Parameter(Mandatory)] [hashtable]$PairCounts,
        [Parameter(Mandatory)] [hashtable]$SitIndex,
        [Parameter(Mandatory)] [int]$MinHits
    )

    $byName = @{}
    foreach ($row in @($ManifestRows)) {
        if ($null -eq $row) { continue }
        $kind = [string]$row.Kind
        if ($kind -ne 'SIT') { continue }
        $name = [string]$row.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (-not $byName.ContainsKey($name)) {
            $byName[$name] = @{
                Name              = $name
                Hits              = 0
                WorkloadsScanned  = 0
                WorkloadsWithHits = 0
                Workloads         = New-Object 'System.Collections.Generic.List[string]'
            }
        }
        $bucket = $byName[$name]
        $bucket.WorkloadsScanned++
        $workload = [string]$row.Workload
        if ($workload) { [void]$bucket.Workloads.Add($workload) }

        $status = [string]$row.Status
        if ($status -ne 'OK') { continue }

        $file = [string]$row.File
        $count = 0
        if ($file -and $PairCounts.ContainsKey($file)) {
            $count = [int]$PairCounts[$file]
        }
        if ($count -gt 0) {
            $bucket.Hits += $count
            $bucket.WorkloadsWithHits++
        }
    }

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in ($byName.Keys | Sort-Object)) {
        $b = $byName[$name]
        $meta = if ($SitIndex.ContainsKey($name)) { $SitIndex[$name] } else { @{ Id = ''; Type = 'Unknown'; Publisher = '' } }
        $isCustom = [string]$meta.Type -eq 'Custom'
        $verdict = Get-Recommendation `
            -IsCustom $isCustom `
            -Hits $b.Hits `
            -WorkloadsWithHits $b.WorkloadsWithHits `
            -MinHits $MinHits
        $out.Add([pscustomobject][ordered]@{
            Name              = $name
            Id                = [string]$meta.Id
            Type              = [string]$meta.Type
            IsCustom          = $isCustom
            Hits              = [int]$b.Hits
            WorkloadsWithHits = [int]$b.WorkloadsWithHits
            WorkloadsScanned  = [int]$b.WorkloadsScanned
            Workloads         = ($b.Workloads | Sort-Object -Unique) -join ','
            Signal            = [string]$verdict.Signal
            Recommendation    = [string]$verdict.Recommendation
        })
    }
    return $out.ToArray()
}

function Format-ReportMarkdown {
    <#
    .SYNOPSIS
        Render report rows as a Markdown document.

    .DESCRIPTION
        Pure -- no I/O. Returns a single string. The header captures
        the run directory, MinHits threshold, totals, and a per-
        Recommendation summary. The body is a Markdown table.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [string]$RunDirectory,
        [Parameter(Mandatory)] [int]$MinHits,
        [Parameter(Mandatory)] [datetime]$GeneratedAt
    )

    $rowsArr = @($Rows)
    $total   = $rowsArr.Count
    $custom  = @($rowsArr | Where-Object IsCustom).Count
    $retire  = @($rowsArr | Where-Object Recommendation -EQ 'Retire').Count
    $review  = @($rowsArr | Where-Object Recommendation -EQ 'Review').Count
    $retain  = @($rowsArr | Where-Object Recommendation -EQ 'Retain').Count
    $refer   = @($rowsArr | Where-Object Recommendation -EQ 'Reference').Count

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# SIT confidence analysis')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(('- Generated: {0}' -f $GeneratedAt.ToString('o')))
    [void]$sb.AppendLine(('- Run directory: `{0}`' -f $RunDirectory))
    [void]$sb.AppendLine(('- MinHits threshold: {0}' -f $MinHits))
    [void]$sb.AppendLine(('- Rows: {0} total, {1} custom' -f $total, $custom))
    [void]$sb.AppendLine(('- Recommendations: Retain {0}, Review {1}, Retire {2}, Reference {3}' -f $retain, $review, $retire, $refer))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Type | IsCustom | Hits | WorkloadsWithHits | WorkloadsScanned | Signal | Recommendation |')
    [void]$sb.AppendLine('|---|---|---|---:|---:|---:|---|---|')
    foreach ($r in $rowsArr) {
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
            $r.Name, $r.Type, $r.IsCustom, $r.Hits, $r.WorkloadsWithHits, $r.WorkloadsScanned, $r.Signal, $r.Recommendation))
    }
    return $sb.ToString()
}

#endregion

#region Resolve paths

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

if (-not $ExportRoot)    { $ExportRoot    = Join-Path $repoRoot 'verify-dspm-export-output' }
if (-not $SitCatalogPath){ $SitCatalogPath= Join-Path $repoRoot 'data-plane/classifications/sit-catalog.yaml' }
if (-not $OutputRoot)    { $OutputRoot    = Join-Path $repoRoot 'verify-sit-confidence-output' }

$runDir = Resolve-RunDirectory -RunDirectoryPath $RunDirectory -ExportRootPath $ExportRoot
Write-Information ("Analyzing run directory: {0}" -f $runDir) -InformationAction Continue

if (-not (Test-Path -LiteralPath $SitCatalogPath)) {
    throw ("SIT catalog not found at '{0}'." -f $SitCatalogPath)
}

#endregion

#region Load manifest + catalog + pair counts

$manifestPath = Join-Path $runDir 'manifest.json'
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/convertfrom-json
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 64
if ($null -eq $manifest -or -not $manifest.rows) {
    throw ("manifest.json at '{0}' parsed empty or missing 'rows'." -f $manifestPath)
}

$catalogDoc = Get-Content -LiteralPath $SitCatalogPath -Raw | ConvertFrom-Yaml
$sitIndex   = Get-SitIndex -YamlDoc $catalogDoc
Write-Information ("Catalog loaded: {0} SIT entries." -f $sitIndex.Count) -InformationAction Continue

$pairCounts = @{}
foreach ($row in @($manifest.rows)) {
    if ([string]$row.Kind -ne 'SIT') { continue }
    if ([string]$row.Status -ne 'OK') { continue }
    $file = [string]$row.File
    if (-not $file) { continue }
    if ($pairCounts.ContainsKey($file)) { continue }
    $pairCounts[$file] = Get-PairFileRecordCount -Path (Join-Path $runDir $file)
}
Write-Information ("Pair files counted: {0}." -f $pairCounts.Count) -InformationAction Continue

#endregion

#region Build report

$rows = ConvertTo-ReportRow `
    -ManifestRows $manifest.rows `
    -PairCounts $pairCounts `
    -SitIndex $sitIndex `
    -MinHits $MinHits

if ($CustomOnly) {
    $rows = @($rows | Where-Object IsCustom)
}

#endregion

#region -WhatIf short-circuit

if ($WhatIfPreference) {
    Write-Information ("Plan: {0} report rows (MinHits={1}, CustomOnly={2})." -f $rows.Count, $MinHits, [bool]$CustomOnly) -InformationAction Continue
    return $rows
}

#endregion

#region Persist report

$generatedAt = Get-Date
$stamp       = $generatedAt.ToString('yyyy-MM-dd-HHmm')
$reportDir   = Join-Path $OutputRoot $stamp
if (-not (Test-Path -LiteralPath $reportDir)) {
    if ($PSCmdlet.ShouldProcess($reportDir, 'Create report directory')) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
}

$mdPath  = Join-Path $reportDir 'sit-confidence-report.md'
$csvPath = Join-Path $reportDir 'sit-confidence-report.csv'

if ($PSCmdlet.ShouldProcess($mdPath, 'Write Markdown report')) {
    Format-ReportMarkdown -Rows $rows -RunDirectory $runDir -MinHits $MinHits -GeneratedAt $generatedAt |
        Out-File -LiteralPath $mdPath -Encoding utf8
}
if ($PSCmdlet.ShouldProcess($csvPath, 'Write CSV report')) {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-csv
    $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
}

Write-Information ("Wrote {0} rows to '{1}'." -f $rows.Count, $reportDir) -InformationAction Continue
return $rows

#endregion
