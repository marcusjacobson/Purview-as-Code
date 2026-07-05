#Requires -Version 7.4
<#
.SYNOPSIS
    Verify the ADR 0045 no-push-back guard: assert this workspace cannot
    contribute content back to the source template repository.

.DESCRIPTION
    Implements the verification gate from
    docs/adr/0045-template-kickoff-spinoff-model.md. It gathers the
    current 'origin' fetch URL and the 'upstream' push URL from git, then
    evaluates them against the source template URL using the pure
    Get-KickoffGuardStatus helper. It passes when:

      * 'origin' is absent (local mode) or does not resolve to the source
        template repository (spin-off mode); and
      * any retained 'upstream' remote's push URL does not resolve to the
        source template repository (it is disabled with a sentinel).

    Writes a human-readable result and emits the status object. Sets the
    process exit code explicitly (0 on pass, 1 on fail) so it can gate
    automation on the exit code — callers do `Test-KickoffGuard.ps1; if
    ($LASTEXITCODE) { fail }`. Read-only: it never mutates git config, never
    writes files, never pushes.

    The -OriginUrl and -UpstreamPushUrl parameters exist so a caller (or a
    unit test) can supply state directly; when omitted they are read from
    git.

    References:
      ADR 0045 (this script's contract):
        docs/adr/0045-template-kickoff-spinoff-model.md
      git remote get-url (--push):
        https://git-scm.com/docs/git-remote

.PARAMETER SourceUrl
    The source template repository URL to check against. Required: pass
    the URL this workspace originated from (the @operator-kickoff agent
    captures it before origin severance).

.PARAMETER UpstreamRemoteName
    Name of the retained read-only remote to inspect. Defaults to 'upstream'.

.PARAMETER OriginUrl
    Override the detected 'origin' fetch URL (for testing). When omitted it
    is read from git; an absent origin is treated as an empty string.

.PARAMETER UpstreamPushUrl
    Override the detected upstream push URL (for testing). When omitted it
    is read from git.

.EXAMPLE
    ./scripts/Test-KickoffGuard.ps1 -SourceUrl 'https://github.com/contoso/Purview-as-Code-Generic.git'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceUrl,

    [Parameter()]
    [string]$UpstreamRemoteName = 'upstream',

    [Parameter()]
    [string]$OriginUrl,

    [Parameter()]
    [string]$UpstreamPushUrl
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

# Gather the origin fetch URL unless supplied. An absent origin is empty (local mode).
if (-not $PSBoundParameters.ContainsKey('OriginUrl')) {
    $origin = Invoke-Git -GitArgs @('remote', 'get-url', 'origin')
    $OriginUrl = if ($origin.ExitCode -eq 0) { $origin.Output } else { '' }
}

# Gather the upstream push URL unless supplied. An absent upstream is empty.
if (-not $PSBoundParameters.ContainsKey('UpstreamPushUrl')) {
    $upstream = Invoke-Git -GitArgs @('remote', 'get-url', '--push', $UpstreamRemoteName)
    $UpstreamPushUrl = if ($upstream.ExitCode -eq 0) { $upstream.Output } else { '' }
}

$status = Get-KickoffGuardStatus -SourceUrl $SourceUrl -OriginUrl $OriginUrl -UpstreamPushUrl $UpstreamPushUrl

if ($status.Passed) {
    Write-Information "PASS: no-push-back guard verified. This workspace cannot push to $SourceUrl." -InformationAction Continue
    # Emit the status object first so a caller that captures the result
    # (`$s = ./Test-KickoffGuard.ps1`) still receives it, then exit 0. Without
    # the explicit exit the script leaked $LASTEXITCODE from the last internal
    # git call (observed as 2) and broke exit-code gating on a passing guard.
    $status
    exit 0
}
else {
    Write-Information "FAIL: no-push-back guard is NOT satisfied:" -InformationAction Continue
    foreach ($f in $status.Failures) {
        Write-Information "  - $f" -InformationAction Continue
    }
    Write-Error "Kickoff guard verification failed for source '$SourceUrl'." -ErrorAction Continue
    $status
    exit 1
}
