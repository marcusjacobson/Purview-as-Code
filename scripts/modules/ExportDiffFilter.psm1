#Requires -Version 7.4
<#
.SYNOPSIS
    Pure helper for the issue #508 cosmetic-only export-diff filter.

.DESCRIPTION
    `Test-ExportDiffMeaningful` decides whether a `git diff -U0` produced
    by a sync-<domain>-from-tenant.yml workflow's `-ExportCurrentState`
    step contains any tracked-field change, or only blank-line / YAML
    comment noise introduced by the `ConvertTo-Yaml` round-trip (which
    strips inline comments and blank lines below the line-splice cut
    point -- a deferred defect class tracked separately from this
    filter). It is intentionally pure -- no `git` calls, no file I/O, no
    module imports beyond `Microsoft.PowerShell.Core` -- so it is
    unit-testable against a synthetic diff string without a repo clone.

    `Get-ExportDiffSummary` is a companion that classifies the same diff
    into added/removed/meaningful line counts, used by
    `Invoke-LocalDlpDriftSync.ps1`'s and
    `Invoke-LocalIrmDriftSync.ps1`'s audit records.

    Consumers:
      * `.github/workflows/sync-dlp-from-tenant.yml`
      * `.github/workflows/sync-auto-label-policies-from-tenant.yml`
      * `.github/workflows/sync-label-policies-from-tenant.yml`
      * `scripts/Invoke-LocalDlpDriftSync.ps1`
      * `scripts/Invoke-LocalIrmDriftSync.ps1`

    Each consumer imports the module via:

        Import-Module (Join-Path $PSScriptRoot 'modules/ExportDiffFilter.psm1') `
            -Force -Scope Local -ErrorAction Stop

    KNOWN LIMITATION (preserved deliberately, not fixed silently): a `#`
    character inside a YAML block scalar (e.g. a `rawAdvancedRule: |`
    body that happens to contain a literal `#`) is treated as a comment
    line and therefore as cosmetic. This mirrors the original inline
    workflow logic exactly; a block-scalar-aware diff classifier is a
    separate, larger change out of scope for this refactor.

    References:
      Issue #508 (cosmetic-only export diff)
      Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions
#>

function Test-ExportDiffMeaningful {
    <#
    .SYNOPSIS
        Returns $true if a unified diff contains any non-cosmetic line.

    .DESCRIPTION
        A line is cosmetic if, after stripping its leading +/- marker,
        it is blank or starts with `#` (ignoring leading whitespace).
        `---`/`+++` file-header lines and any line that is not a +/-
        change line are ignored entirely. An empty or null diff is not
        meaningful.

    .PARAMETER DiffText
        The raw output of `git diff -U0 -- <path>` (or an equivalent
        unified diff), as a single string with embedded newlines.

    .EXAMPLE
        Test-ExportDiffMeaningful -DiffText $diff
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DiffText
    )
    if ([string]::IsNullOrEmpty($DiffText)) {
        return $false
    }
    foreach ($line in ($DiffText -split "`n")) {
        if ($line -notmatch '^[-+]') { continue }
        if ($line -match '^(---|\+\+\+)') { continue }
        $payload = $line.Substring(1)
        if ($payload -match '^\s*$') { continue }
        if ($payload -match '^\s*#') { continue }
        return $true
    }
    return $false
}

function Get-ExportDiffSummary {
    <#
    .SYNOPSIS
        Classifies a unified diff into added/removed/meaningful counts.

    .DESCRIPTION
        Companion to `Test-ExportDiffMeaningful` for callers (the local
        drift-sync script's audit record) that want line-count detail,
        not just a boolean. Uses the identical cosmetic-line rule so the
        two functions never disagree about what counts as meaningful.

    .PARAMETER DiffText
        The raw output of `git diff -U0 -- <path>`.

    .OUTPUTS
        [hashtable] with keys `AddedLines`, `RemovedLines`,
        `MeaningfulLines`, `CosmeticOnly`.

    .EXAMPLE
        Get-ExportDiffSummary -DiffText $diff
        # @{ AddedLines = 3; RemovedLines = 1; MeaningfulLines = 2; CosmeticOnly = $false }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$DiffText
    )
    $summary = @{
        AddedLines      = 0
        RemovedLines    = 0
        MeaningfulLines = 0
        CosmeticOnly    = $true
    }
    if ([string]::IsNullOrEmpty($DiffText)) {
        $summary.CosmeticOnly = $false
        return $summary
    }
    foreach ($line in ($DiffText -split "`n")) {
        if ($line -notmatch '^[-+]') { continue }
        if ($line -match '^(---|\+\+\+)') { continue }
        $payload = $line.Substring(1)
        if ($line.StartsWith('+')) { $summary.AddedLines++ }
        else { $summary.RemovedLines++ }
        if ($payload -match '^\s*$') { continue }
        if ($payload -match '^\s*#') { continue }
        $summary.MeaningfulLines++
    }
    $summary.CosmeticOnly = ($summary.MeaningfulLines -eq 0) -and (($summary.AddedLines + $summary.RemovedLines) -gt 0)
    return $summary
}

Export-ModuleMember -Function 'Test-ExportDiffMeaningful', 'Get-ExportDiffSummary'
