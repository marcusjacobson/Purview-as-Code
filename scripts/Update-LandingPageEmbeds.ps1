#Requires -Version 7.4
<#
.SYNOPSIS
    Refresh (or verify) the offline documentation snapshots embedded in the
    repository landing page, index.html.

.DESCRIPTION
    The landing page (index.html) renders the docs it links to inside a
    slide-in reader panel. When the page is served over HTTP it fetches the
    live file; when opened directly from disk (a file:// URL, where browsers
    block fetch of local files) it falls back to an embedded snapshot of each
    linked doc, held in hidden <script type="text/markdown" data-doc="...">
    blocks between the EMBEDDED-DOCS:START / EMBEDDED-DOCS:END markers.

    Those snapshots are point-in-time copies and can drift from the source
    docs. This script regenerates them so they can't:

      1. It scans index.html (outside the embedded region) for every internal,
         relative Markdown link (href="...md"). That is the single source of
         truth for which docs to embed — add or remove a link and the snapshot
         set follows automatically.
      2. It reads each linked source doc, ordinal-sorts them for a
         deterministic order, and rebuilds the embedded region.
      3. In default mode it writes the file back (honouring -WhatIf / -Confirm).
         In -Check mode it makes no changes and throws if the embedded snapshots
         no longer match the source docs — this is what the CI freshness gate
         in .github/workflows/validate.yml runs.

    Line endings are normalised to LF for both comparison and output so the
    result is identical on Windows and Linux (CI). No network, tenant, or
    Azure calls are made; this is repository tooling only.

    Regenerate locally with:  pwsh ./scripts/Update-LandingPageEmbeds.ps1
    Verify (as CI does) with:  pwsh ./scripts/Update-LandingPageEmbeds.ps1 -Check

.PARAMETER IndexPath
    Path to the landing page to update. Defaults to index.html at the
    repository root (the parent of the scripts/ directory).

.PARAMETER Check
    Verify only. Makes no changes; throws (non-zero exit) if the embedded
    snapshots are stale relative to the source docs. Used by CI.

.EXAMPLE
    pwsh ./scripts/Update-LandingPageEmbeds.ps1
    Regenerates the embedded snapshots in index.html from the linked docs.

.EXAMPLE
    pwsh ./scripts/Update-LandingPageEmbeds.ps1 -Check
    Fails if index.html's embedded snapshots do not match the source docs.

.NOTES
    References:
      about_Functions_CmdletBindingAttribute (SupportsShouldProcess):
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
      System.IO.File.WriteAllText:
        https://learn.microsoft.com/en-us/dotnet/api/system.io.file.writealltext
      System.Text.RegularExpressions.Regex.Replace (MatchEvaluator):
        https://learn.microsoft.com/en-us/dotnet/api/system.text.regularexpressions.regex.replace
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$IndexPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'index.html'),

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$startMarker = '<!-- EMBEDDED-DOCS:START -->'
$endMarker = '<!-- EMBEDDED-DOCS:END -->'

if (-not (Test-Path -LiteralPath $IndexPath)) {
    throw "Landing page not found at: $IndexPath"
}

$repoRoot = Split-Path -Parent $IndexPath

# Normalise CRLF -> LF so comparison and output are platform-independent.
$html = ([System.IO.File]::ReadAllText($IndexPath)) -replace "`r`n", "`n"

$regionPattern = [regex]('(?s)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker))
if (-not $regionPattern.IsMatch($html)) {
    throw "Embedded-docs markers ('$startMarker' ... '$endMarker') not found in: $IndexPath"
}

# Scan the page *outside* the current embedded region for the internal,
# relative Markdown links to embed. Collapsing the region first prevents the
# links inside already-embedded docs from being picked up.
$emptyEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { '' }
$htmlOutsideRegion = $regionPattern.Replace($html, $emptyEvaluator, 1)

$hrefs = [regex]::Matches($htmlOutsideRegion, 'href="([^"]+\.md)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://' } |
    Select-Object -Unique

if (-not $hrefs) {
    throw ('No internal Markdown links (href="*.md") found to embed in: ' + $IndexPath)
}

# Deterministic, culture-independent ordering.
$ordered = [string[]]$hrefs
[Array]::Sort($ordered, [System.StringComparer]::Ordinal)

$blocks = foreach ($href in $ordered) {
    $relative = $href -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $sourcePath = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Linked doc '$href' does not exist (resolved to: $sourcePath). Fix the link in $IndexPath or add the file."
    }
    $content = ([System.IO.File]::ReadAllText($sourcePath)) -replace "`r`n", "`n"
    # Defensive: a literal script-closing tag would break the surrounding
    # <script> block. None exist today; neutralise if one is ever introduced.
    $content = $content -replace '</script>', '<\/script>'
    '  <script type="text/markdown" data-doc="' + $href + '">' + "`n" + $content + "`n" + '  </script>'
}

$newRegion = $startMarker + "`n" + ($blocks -join "`n") + "`n  " + $endMarker
$regionEvaluator = [System.Text.RegularExpressions.MatchEvaluator] { $newRegion }
$newHtml = $regionPattern.Replace($html, $regionEvaluator, 1)

$docList = $ordered -join ', '

if ($Check) {
    if ($newHtml -ceq $html) {
        Write-Information "Embedded docs are current ($($ordered.Count) doc(s): $docList)." -InformationAction Continue
        return
    }
    throw ("index.html embedded doc snapshots are STALE. Regenerate with " +
        "'pwsh ./scripts/Update-LandingPageEmbeds.ps1' and commit the result. " +
        "Docs checked: $docList.")
}

if ($newHtml -ceq $html) {
    Write-Information "No changes; embedded docs already current ($($ordered.Count) doc(s): $docList)." -InformationAction Continue
    return
}

if ($PSCmdlet.ShouldProcess($IndexPath, "Refresh $($ordered.Count) embedded doc snapshot(s)")) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($IndexPath, $newHtml, $utf8NoBom)
    Write-Information "Refreshed embedded docs in $IndexPath ($($ordered.Count) doc(s): $docList)." -InformationAction Continue
}
