#Requires -Version 7.4
<#
.SYNOPSIS
    Read-only identifier-shaped residual scan. Fails the build when a non-zero
    GUID appears anywhere in the repository that the tenant placeholder manifest
    does not explicitly acquit.

.DESCRIPTION
    The IDENTIFIER-shaped half of the residual scan ratified by
    docs/adr/0055-identifier-shaped-residual-scan.md (which amends ADR 0046).

    ADR 0046 shipped a TOKEN-shaped scan
    (`contoso|onmicrosoft\.com|OWNER-PLACEHOLDER`) and claimed that "any
    remaining match is a genuine missed tenant surface". That claim was unsound.
    A token-shaped scan can only find values that string genericization
    SUBSTITUTED. It is structurally incapable of finding identifier-shaped data,
    because a raw GUID contains no token. Real Entra group object IDs sat in
    ACTIVE desired-state lists in this public template repo, and the ADR 0046
    scan could not see them -- both because the whole `data-plane/` tree was
    blanket-excluded and because the pattern could not have matched a GUID even
    if it had been scanned. This script closes that gap.

    CONTRACT -- FAIL CLOSED. Every GUID-shaped token in every tracked file is
    guilty until acquitted. A GUID is acquitted only if one of four manifest
    rules claims it:

      1. syntheticShapes    -- acquits by SHAPE (zero GUID, the zero-prefixed
                               fixture namespace, repeated-nibble fixtures, two
                               named synthetic literals). This is what replaces a
                               `tests/**` path exclusion: a fixture is acquitted
                               for LOOKING synthetic, not for LIVING in tests/.
      2. catalogKeys        -- acquits by (file, key). A GUID that is the whole
                               value of an allow-listed key in an allow-listed
                               file is a Microsoft catalog identifier (built-in
                               SIT IDs, rule-pack IDs, trainable-classifier IDs).
                               The derived VALUE SET is then citable anywhere.
      3. microsoftConstants -- acquits by exact VALUE, for constants with no
                               enclosing key (Bicep `var`, PowerShell literals,
                               prose): Entra role template IDs, Azure RBAC role
                               definition IDs, Microsoft first-party app IDs.
      4. reviewRequired     -- quarantine. Identifiers of UNRESOLVED provenance,
                               keyed by SHA-256 so the manifest never restates
                               them. Reported as `Review`, not `Finding`, and
                               pinned by a Pester test so the list cannot grow
                               quietly.

    Anything else is a `Finding` and the script exits 1.

    There are deliberately NO path exclusions. A path exclusion is what caused
    the disclosure this script exists to prevent.

    Read-only: parses the manifest, reads tracked files (or a git ref), writes
    rows to the output stream. It never edits a file, never calls git for
    anything but enumeration/read, and never touches a tenant.

    References:
      ADR 0055 (this script's contract):
        docs/adr/0055-identifier-shaped-residual-scan.md
      ADR 0046 (the manifest this amends):
        docs/adr/0046-tenant-placeholder-manifest.md
      ADR 0023 (principals are named by displayName, never a raw object ID):
        docs/adr/0023-identifier-resolution.md
      Microsoft placeholder examples (the zero-GUID convention):
        https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples
      powershell-yaml (ConvertFrom-Yaml):
        https://www.powershellgallery.com/packages/powershell-yaml

.PARAMETER ManifestPath
    Path to the tenant placeholder manifest. Defaults to the repo copy at
    .github/agents/tenant-placeholders.yaml relative to this script. Always read
    from the WORKING TREE, never from -Ref: the point of -Ref is to ask "would
    TODAY's rules have caught YESTERDAY's content?".

.PARAMETER Ref
    Scan the tree at a git ref (commit-ish) instead of the working tree. Used to
    prove the scan catches a historical disclosure -- the regression test that
    decides whether this control is real. Omit to scan the working tree.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER IncludeAllowed
    Also emit `Allow` rows. Off by default -- the 384 acquitted GUIDs are noise
    in CI. Useful locally to audit which rule acquitted what.

.PARAMETER FailOnReview
    Treat `Review` rows (rule 4 quarantine) as failures. Off by default so the
    quarantine does not block CI; on for the follow-up PR that empties it.

.EXAMPLE
    ./scripts/Test-IdentifierResidue.ps1

    Scan the working tree. Exit 0 when clean.

.EXAMPLE
    ./scripts/Test-IdentifierResidue.ps1 -Ref 1a37fbd

    Scan the tree at a historical commit using today's manifest. This is the
    regression proof: the scan MUST fail against the pre-scrub commit.

.EXAMPLE
    ./scripts/Test-IdentifierResidue.ps1 -IncludeAllowed |
        Group-Object Rule | Sort-Object Count -Descending

    Audit the allow-list: which rule is carrying how much of the repo.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath,

    [Parameter()]
    [string]$Ref,

    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [switch]$IncludeAllowed,

    [Parameter()]
    [switch]$FailOnReview
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSBoundParameters.ContainsKey('RepoRoot') -or [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (-not $PSBoundParameters.ContainsKey('ManifestPath') -or [string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $RepoRoot '.github' 'agents' 'tenant-placeholders.yaml'
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Tenant placeholder manifest not found at '$ManifestPath'."
}

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$manifest = (Get-Content -LiteralPath $ManifestPath -Raw) | ConvertFrom-Yaml

# The identifierScan block was introduced at schemaVersion 3 (ADR 0055). Fail
# loudly on an older manifest rather than silently scan with no allow-list --
# which would flag every GUID in the repo and get the scan disabled.
$schemaVersion = if ($manifest.ContainsKey('schemaVersion')) { [int]$manifest.schemaVersion } else { 0 }
if ($schemaVersion -lt 3) {
    throw "Manifest '$ManifestPath' is schemaVersion $schemaVersion; this script requires schemaVersion 3 or later (the identifierScan block, ADR 0055)."
}
if (-not $manifest.ContainsKey('identifierScan')) {
    throw "Manifest '$ManifestPath' declares schemaVersion $schemaVersion but has no 'identifierScan' block."
}
$cfg = $manifest.identifierScan

foreach ($required in @('guidPattern', 'syntheticShapes', 'catalogKeys', 'microsoftConstants')) {
    if (-not $cfg.ContainsKey($required)) {
        throw "Manifest identifierScan block is missing required key '$required'."
    }
}

$guidPattern = [string]$cfg.guidPattern

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------

function Get-IdentifierPreview {
    <#
        .SYNOPSIS
            Mask an identifier for display. CI logs on a public repo are public,
            so a Finding row must locate the leak without republishing it.
            Matches the repo's existing Format-EntraIdentifier convention:
            first 8 hex characters, then an ellipsis.
    #>
    param([Parameter(Mandatory = $true)][string]$Value)
    return ($Value.Substring(0, 8) + '-...')
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Value)
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($Value))
    try {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ScannedFileList {
    <#
        .SYNOPSIS
            Enumerate the files to scan.

        .DESCRIPTION
            Working tree: tracked files PLUS untracked-but-not-ignored files.

            The untracked half matters and was learned the hard way. A first cut
            scanned `git ls-files` only, so a brand-new file was invisible until it
            was staged — a contributor could write a file holding a real object ID,
            run the scan, be told PASS, commit, and only then discover the leak in
            CI. A local PASS that a later commit turns into a FAIL is worse than no
            local run at all, because it is trusted. Untracked-not-ignored is what
            "about to be committed" actually means.

            Gitignored files are excluded on purpose: they never reach the remote,
            and they are where local tenant exports legitimately land (ADR 0021's
            exporter artifact directory).

            At a ref (-Ref), only the committed tree exists and the distinction is
            meaningless.
    #>
    param([string]$Root, [string]$AtRef)
    Push-Location $Root
    try {
        if ([string]::IsNullOrWhiteSpace($AtRef)) {
            $tracked = & git ls-files
            if ($LASTEXITCODE -ne 0) { throw "git ls-files failed (exit $LASTEXITCODE)." }
            $untracked = & git ls-files --others --exclude-standard
            if ($LASTEXITCODE -ne 0) { throw "git ls-files --others failed (exit $LASTEXITCODE)." }
            $out = @($tracked) + @($untracked)
        }
        else {
            $out = & git ls-tree -r --name-only $AtRef
            if ($LASTEXITCODE -ne 0) {
                throw "git ls-tree failed (exit $LASTEXITCODE) for ref '$AtRef'."
            }
        }
        return @($out | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    }
    finally {
        Pop-Location
    }
}

function Get-ScannedFileLine {
    <#
        .SYNOPSIS
            Return the lines of one tracked file, from the working tree or from
            a git ref. Returns $null for binary / unreadable content.
    #>
    param([string]$Root, [string]$AtRef, [string]$RelativePath)

    # Binary formats carry no reviewable identifiers and blow up line splitting.
    $binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip',
        '.pfx', '.cer', '.p12', '.woff', '.woff2', '.ttf', '.eot', '.dll', '.exe')
    if ($binaryExtensions -contains ([System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant())) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($AtRef)) {
        $full = Join-Path $Root $RelativePath
        if (-not (Test-Path -LiteralPath $full)) { return $null }
        $raw = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
    }
    else {
        Push-Location $Root
        try {
            $raw = & git show "${AtRef}:${RelativePath}" 2>$null | Out-String
        }
        finally {
            Pop-Location
        }
    }

    if ($raw.Contains([char]0)) { return $null }        # binary -- caller skips
    if ([string]::IsNullOrEmpty($raw)) { return , @() } # empty  -- caller scans nothing

    # THE UNARY COMMA IS LOAD-BEARING. Read this before "simplifying" it.
    #
    # A SINGLE-LINE file with NO trailing newline splits to a ONE-element array.
    # PowerShell UNROLLS a one-element array as it crosses a function boundary,
    # so the caller receives a bare [string], not a [string[]] -- and `@()` INSIDE
    # the function does not prevent that. The unary comma wraps the array in an
    # outer array, which is then unrolled back to the array the caller wanted.
    #
    # Get it wrong and `$lines.Count` at the call site throws under
    # Set-StrictMode -Version Latest, the scan loop never runs, and THE FILE IS
    # NEVER READ.
    #
    # The blast radius is why this comment is this long. Under CI (`shell: pwsh`,
    # $ErrorActionPreference = 'Stop') the process exits 1: fail-closed, safe.
    # Run BARE LOCALLY it prints a red error and leaves $LASTEXITCODE = 0 -- a
    # planted object ID goes UNREPORTED and the operator is told nothing is
    # wrong. That is a local run that LIES, and it is precisely what ADR 0055
    # Decision 7 exists to condemn: "a local PASS that a later commit turns into
    # a FAIL is worse than no local run, because it is trusted." This scanner
    # shipped that bug inside the fix for its own twin, and the first attempted
    # repair (`return @(...)`) did not work either -- it fixed the array inside
    # the function and lost it again on the way out.
    #
    # Pinned by 'FAILS on a single-line file with no trailing newline', which
    # asserts the EXIT CODE, not merely that an error was raised: the defect was
    # that the error was loud and the exit code was clean.
    return , @($raw -split "`r?`n")
}

#-------------------------------------------------------------------------------
# Build the acquittal rules from the manifest
#-------------------------------------------------------------------------------

# Rule 1 — synthetic shapes (by shape, case-insensitive).
$syntheticShapes = @(
    foreach ($s in $cfg.syntheticShapes) {
        [pscustomobject]@{ Id = [string]$s.id; Pattern = [string]$s.pattern }
    }
)

# Rule 3 — Microsoft constants (by exact value).
$microsoftConstants = @{}
foreach ($c in $cfg.microsoftConstants) {
    $microsoftConstants[([string]$c.value).ToLowerInvariant()] = [string]$c.name
}

# Rule 4 — review-required quarantine (by SHA-256 of the lower-cased value).
$reviewRequired = @{}
if ($cfg.ContainsKey('reviewRequired') -and $null -ne $cfg.reviewRequired) {
    foreach ($r in $cfg.reviewRequired) {
        $reviewRequired[([string]$r.sha256).ToLowerInvariant()] = [string]$r.location
    }
}

# @() guards the single-file case: PowerShell unrolls a one-element array on
# return, and `.Count` on a bare string throws under Set-StrictMode.
$fileList = @(Get-ScannedFileList -Root $RepoRoot -AtRef $Ref)

# Rule 2 — catalog keys. Derive the Microsoft-catalog VALUE SET from the tree
# UNDER SCAN (not the working tree), so a historical scan derives it from the
# catalog files as they existed at that ref. The rule is anchored to
# `<key>: <guid>` as the WHOLE value: a bare YAML sequence item (`- <guid>`)
# carries no key and can never be acquitted here, which is exactly why the
# `members:` disclosure fails the scan.
$catalogValues = @{}
foreach ($entry in $cfg.catalogKeys) {
    $catalogPath = [string]$entry.path
    if ($fileList -notcontains $catalogPath) { continue }   # file absent at this ref
    $keyAlternation = (@($entry.keys | ForEach-Object { [regex]::Escape([string]$_) }) -join '|')
    $catalogLineRegex = "^\s*-?\s*(?<key>$keyAlternation)\s*:\s*['`"]?(?<guid>$guidPattern)['`"]?\s*(#.*)?$"

    $catalogLines = Get-ScannedFileLine -Root $RepoRoot -AtRef $Ref -RelativePath $catalogPath
    if ($null -eq $catalogLines) { continue }
    foreach ($line in $catalogLines) {
        $m = [regex]::Match($line, $catalogLineRegex)
        if ($m.Success) {
            $catalogValues[$m.Groups['guid'].Value.ToLowerInvariant()] = "$catalogPath#$($m.Groups['key'].Value)"
        }
    }
}

#-------------------------------------------------------------------------------
# Scan
#-------------------------------------------------------------------------------

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($relativePath in $fileList) {
    # Never scan the manifest's own microsoftConstants block against itself --
    # the manifest IS the allow-list, and every value in it is acquitted by
    # definition (rule 3 covers them). Scanning it is harmless but confusing; it
    # is left IN scope deliberately so that a stray GUID added to the manifest
    # OUTSIDE the microsoftConstants list is still caught.
    $lines = Get-ScannedFileLine -Root $RepoRoot -AtRef $Ref -RelativePath $relativePath
    if ($null -eq $lines) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line -notmatch $guidPattern) { continue }

        foreach ($match in [regex]::Matches($line, $guidPattern)) {
            $value = $match.Value.ToLowerInvariant()
            $verdict = 'Finding'
            $rule = 'unclaimed'

            # Rule 1 — shape.
            $shapeHit = $syntheticShapes | Where-Object { $value -match $_.Pattern } | Select-Object -First 1
            if ($shapeHit) {
                $verdict = 'Allow'
                $rule = "syntheticShape:$($shapeHit.Id)"
            }
            # Rule 2 — catalog key (derived value set).
            elseif ($catalogValues.ContainsKey($value)) {
                $verdict = 'Allow'
                $rule = "catalogKey:$($catalogValues[$value])"
            }
            # Rule 3 — Microsoft constant.
            elseif ($microsoftConstants.ContainsKey($value)) {
                $verdict = 'Allow'
                $rule = "microsoftConstant:$($microsoftConstants[$value])"
            }
            # Rule 4 — quarantine.
            elseif ($reviewRequired.ContainsKey((Get-Sha256Hex -Value $value))) {
                $verdict = 'Review'
                $rule = "reviewRequired:$($reviewRequired[(Get-Sha256Hex -Value $value)])"
            }

            if ($verdict -eq 'Allow' -and -not $IncludeAllowed) { continue }

            $rows.Add([pscustomobject]@{
                    File       = $relativePath
                    Line       = $i + 1
                    Identifier = Get-IdentifierPreview -Value $value
                    Verdict    = $verdict
                    Rule       = $rule
                })
        }
    }
}

#-------------------------------------------------------------------------------
# Report
#-------------------------------------------------------------------------------

$findings = @($rows | Where-Object Verdict -EQ 'Finding')
$reviews = @($rows | Where-Object Verdict -EQ 'Review')

$scanned = if ([string]::IsNullOrWhiteSpace($Ref)) { 'working tree' } else { "ref $Ref" }
Write-Information "Identifier residual scan (ADR 0055) over ${scanned}: $($fileList.Count) tracked files." -InformationAction Continue

# GitHub Actions workflow-command annotations go to stdout. Write-Information
# with -InformationAction Continue is the house pattern for this (see
# Deploy-Labels.ps1); Write-Host is avoided per PSAvoidUsingWriteHost.
# Reference: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-an-error-message
foreach ($r in $reviews) {
    Write-Information "::warning file=$($r.File),line=$($r.Line)::Identifier of unresolved provenance ($($r.Identifier)). Quarantined by identifierScan.reviewRequired; see ADR 0055." -InformationAction Continue
}

foreach ($f in $findings) {
    Write-Information "::error file=$($f.File),line=$($f.Line)::Unclaimed non-zero identifier ($($f.Identifier)). No identifierScan rule acquits it. If this is a real tenant identifier, remove it (ADR 0023: name principals by displayName). If it is a Microsoft-published constant, add it to identifierScan.microsoftConstants in .github/agents/tenant-placeholders.yaml with a Learn citation. If it is a test fixture, move it into the reserved synthetic namespace 00000000-0000-0000-0000-<counter>." -InformationAction Continue
}

$rows | Sort-Object Verdict, File, Line

if ($findings.Count -gt 0) {
    Write-Information "::error::Identifier residual scan FAILED over ${scanned}: $($findings.Count) unclaimed identifier(s) in $(@($findings | Select-Object -ExpandProperty File -Unique).Count) file(s). See ADR 0055." -InformationAction Continue
    exit 1
}

if ($reviews.Count -gt 0 -and $FailOnReview) {
    Write-Information "::error::Identifier residual scan FAILED over ${scanned}: $($reviews.Count) quarantined identifier(s) and -FailOnReview was supplied." -InformationAction Continue
    exit 1
}

Write-Information "Identifier residual scan PASSED over ${scanned}: 0 unclaimed identifiers, $($reviews.Count) quarantined for review." -InformationAction Continue
