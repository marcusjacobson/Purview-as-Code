#Requires -Version 7.4
<#
.SYNOPSIS
    Install the ADR 0045 no-push-back guard on a consumer's copy of the
    Purview-as-Code template, so it cannot contribute content back to the
    source template repository.

.DESCRIPTION
    Applies the git-level layers of the four-layer guard defined in
    docs/adr/0045-template-kickoff-spinoff-model.md:

      2. Disables the push URL of a retained 'upstream' remote (if present)
         by setting it to a non-resolvable sentinel, so 'git push upstream'
         fails fast while 'git fetch upstream' still works for pulling
         template updates.
      3. Installs a best-effort 'pre-push' hook that aborts any push whose
         destination resolves to the source template repository.

    Layer 1 (origin severance) and the mode choice (local workspace vs.
    spin-off repository) are performed by the @operator-kickoff agent
    before this script runs; this script hardens whatever remote state the
    agent has produced. Layer 4 (agent-level refusal) lives in the agent.

    The source template URL is detected from the current 'origin' when
    -SourceUrl is not supplied, so nothing is hardcoded. Run
    scripts/Test-KickoffGuard.ps1 afterward to verify.

    This script mutates git config and writes a hook file; it supports
    -WhatIf / -Confirm. It never deletes history and never pushes.

    References:
      ADR 0045 (this script's contract):
        docs/adr/0045-template-kickoff-spinoff-model.md
      git remote set-url --push (disable a push URL):
        https://git-scm.com/docs/git-remote
      githooks (pre-push):
        https://git-scm.com/docs/githooks
      about_Functions_CmdletBindingAttribute (SupportsShouldProcess):
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute

.PARAMETER SourceUrl
    The source template repository URL to guard against. When omitted, it is
    resolved from -TemplateRepositoryUrl (preferred) then the current 'origin'
    fetch URL (the git-clone path).

.PARAMETER TemplateRepositoryUrl
    The GitHub template relationship URL (from 'gh repo view --json
    templateRepository'). For a repo created via "Use this template" this is the
    true source, since 'origin' is the consumer's own repo. Preferred over origin.

.PARAMETER UpstreamRemoteName
    Name of a retained read-only remote whose push URL should be disabled.
    Defaults to 'upstream'. Ignored if no such remote exists.

.PARAMETER DisableSentinel
    Non-resolvable value written as the upstream push URL. Defaults to
    'DISABLE'.

.PARAMETER RepoRoot
    Repository working-tree root. Defaults to 'git rev-parse --show-toplevel'.

.EXAMPLE
    ./scripts/Set-KickoffGuard.ps1 -WhatIf

.EXAMPLE
    ./scripts/Set-KickoffGuard.ps1 -SourceUrl 'https://github.com/contoso/Purview-as-Code-Generic.git'
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [string]$SourceUrl,

    [Parameter()]
    [string]$TemplateRepositoryUrl,

    [Parameter()]
    [string]$UpstreamRemoteName = 'upstream',

    [Parameter()]
    [string]$DisableSentinel = 'DISABLE',

    [Parameter()]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'modules/KickoffGuard.psm1') -Force -Scope Local -ErrorAction Stop

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArgs)
    $output = & git @GitArgs 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = ($output | Out-String).Trim()
    }
}

# Resolve the repository root.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $top = Invoke-Git -GitArgs @('rev-parse', '--show-toplevel')
    if ($top.ExitCode -ne 0) {
        throw "Not inside a git working tree. Run this from a clone of the template, or pass -RepoRoot."
    }
    $RepoRoot = $top.Output
}

# Resolve the source template URL. Precedence: explicit -SourceUrl, then the GitHub template
# relationship (-TemplateRepositoryUrl), then 'origin' (the git-clone path). A repo created via
# "Use this template" has origin = the consumer's own repo, so origin is NOT the source there --
# pass -SourceUrl or -TemplateRepositoryUrl in that case.
if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
    $originResult = Invoke-Git -GitArgs @('remote', 'get-url', 'origin')
    $originUrl = if ($originResult.ExitCode -eq 0) { $originResult.Output } else { '' }
    $SourceUrl = Resolve-KickoffSourceUrl -OriginUrl $originUrl -TemplateRepositoryUrl $TemplateRepositoryUrl

    if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
        throw "Could not resolve the source template URL: no -SourceUrl, no -TemplateRepositoryUrl, and 'origin' is not set. Pass -SourceUrl explicitly with the URL this workspace originated from."
    }

    if ([string]::IsNullOrWhiteSpace($TemplateRepositoryUrl)) {
        Write-Warning "Resolved the source template URL from 'origin' ($SourceUrl). If this repository was created via 'Use this template', 'origin' is your own repo, not the source -- re-run with -SourceUrl (or -TemplateRepositoryUrl) set to the true source."
    }
    else {
        Write-Verbose "Resolved the source template URL from the template relationship: $SourceUrl"
    }
}

$normalizedSource = Get-NormalizedRepoUrl -Url $SourceUrl
if ([string]::IsNullOrWhiteSpace($normalizedSource)) {
    throw "The source URL '$SourceUrl' normalized to an empty value; refusing to install a guard that matches nothing."
}

Write-Information "Source template repository to guard against: $SourceUrl" -InformationAction Continue

# --- Layer 2: disable the upstream push URL (if an upstream remote exists) ---
$remotes = Invoke-Git -GitArgs @('remote')
$remoteList = @()
if ($remotes.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($remotes.Output)) {
    $remoteList = $remotes.Output -split '\r?\n'
}

if ($remoteList -contains $UpstreamRemoteName) {
    $target = "push URL of remote '$UpstreamRemoteName'"
    if ($PSCmdlet.ShouldProcess($target, "set to sentinel '$DisableSentinel'")) {
        $set = Invoke-Git -GitArgs @('remote', 'set-url', '--push', $UpstreamRemoteName, $DisableSentinel)
        if ($set.ExitCode -ne 0) {
            throw "Failed to disable the '$UpstreamRemoteName' push URL: $($set.Output)"
        }
        Write-Information "Disabled push URL of '$UpstreamRemoteName' (set to '$DisableSentinel'); fetch still works." -InformationAction Continue
    }
}
else {
    Write-Information "No '$UpstreamRemoteName' remote present; skipping push-URL disablement (nothing to harden)." -InformationAction Continue
}

# --- Layer 3: install the best-effort pre-push hook ---
$hooksDirResult = Invoke-Git -GitArgs @('rev-parse', '--git-path', 'hooks')
if ($hooksDirResult.ExitCode -ne 0) {
    throw "Could not resolve the git hooks directory: $($hooksDirResult.Output)"
}
$hooksDir = $hooksDirResult.Output
if (-not [System.IO.Path]::IsPathRooted($hooksDir)) {
    $hooksDir = Join-Path $RepoRoot $hooksDir
}
$hookPath = Join-Path $hooksDir 'pre-push'
$hookContent = Get-KickoffPrePushHookContent -SourceUrl $SourceUrl

if ($PSCmdlet.ShouldProcess($hookPath, 'install pre-push guard hook')) {
    if (-not (Test-Path $hooksDir)) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }
    # Write LF-only so the hook runs under bash on every platform.
    $lfContent = $hookContent -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($hookPath, $lfContent, [System.Text.UTF8Encoding]::new($false))

    # Mark executable where the platform tracks the bit (no-op on Windows;
    # Git for Windows honours the shebang regardless).
    if (-not $IsWindows) {
        & chmod +x $hookPath 2>$null
    }
    Write-Information "Installed pre-push guard hook: $hookPath" -InformationAction Continue
}

Write-Information '' -InformationAction Continue
Write-Information "Guard applied. Verify with: ./scripts/Test-KickoffGuard.ps1 -SourceUrl '$SourceUrl'" -InformationAction Continue
