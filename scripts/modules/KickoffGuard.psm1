#Requires -Version 7.4
<#
.SYNOPSIS
    Pure helpers for the ADR 0045 no-push-back guard.

.DESCRIPTION
    These functions contain the guard's decision logic with no side
    effects -- no git invocation, no file I/O, no module imports beyond
    Microsoft.PowerShell.Core. That is what makes them unit-testable
    against synthetic URLs without a real repository (tests/scripts/
    KickoffGuard.Tests.ps1).

    The consuming scripts do the actual git / filesystem I/O and import
    this module:

        Import-Module (Join-Path $PSScriptRoot 'modules/KickoffGuard.psm1') `
            -Force -Scope Local -ErrorAction Stop

    Consumers:
      * scripts/Set-KickoffGuard.ps1   -- installs the guard.
      * scripts/Test-KickoffGuard.ps1  -- verifies the guard.

    Exported functions:
      * Get-NormalizedRepoUrl        -- canonicalize a git URL for comparison.
      * Test-IsSameRepoUrl           -- compare two git URLs by canonical form.
      * Get-KickoffGuardStatus       -- pass/fail evaluation of the guard state.
      * Get-KickoffPrePushHookContent -- render the best-effort pre-push hook.

    References:
      ADR 0045 (this module's contract):
        docs/adr/0045-template-kickoff-spinoff-model.md
      git-remote (push-URL semantics used by the guard):
        https://git-scm.com/docs/git-remote
      githooks (pre-push backstop, layer 3):
        https://git-scm.com/docs/githooks
      PowerShell modules:
        https://learn.microsoft.com/en-us/powershell/scripting/developer/module/writing-a-windows-powershell-module
#>

Set-StrictMode -Version Latest

function Get-NormalizedRepoUrl {
    <#
    .SYNOPSIS
        Canonicalize a git remote URL so HTTPS and SCP/SSH forms of the
        same repository compare equal.
    .DESCRIPTION
        Lowercases, converts SCP-like syntax (user@host:owner/repo) to
        host/owner/repo, strips the URL scheme, strips any userinfo, and
        strips a trailing '.git' and trailing slashes. A blank or sentinel
        value (for example 'DISABLE') normalizes to itself lowercased and
        will not match a real repository URL.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }

    $u = $Url.Trim().ToLowerInvariant()

    # SCP-like syntax has no scheme: [user@]host:path -> host/path
    if ($u -notmatch '://' -and $u -match '^[^/]+@[^:/]+:') {
        $u = $u -replace '^[^@]+@', ''
        $u = $u -replace '^([^:/]+):', '$1/'
    }

    $u = $u -replace '^[a-z][a-z0-9+.\-]*://', ''  # strip scheme
    $u = $u -replace '^[^/@]+@', ''                # strip userinfo
    $u = $u -replace '\.git$', ''                  # strip trailing .git
    $u = $u -replace '/+$', ''                     # strip trailing slashes

    return $u
}

function Test-IsSameRepoUrl {
    <#
    .SYNOPSIS
        True when two git URLs resolve to the same repository. A blank
        input on either side is never a match.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UrlA,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UrlB
    )

    $a = Get-NormalizedRepoUrl -Url $UrlA
    $b = Get-NormalizedRepoUrl -Url $UrlB
    if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { return $false }

    return ($a -eq $b)
}

function Get-KickoffGuardStatus {
    <#
    .SYNOPSIS
        Evaluate whether a workspace is severed from the source template
        repository. Returns an object with Passed (bool) and Failures
        (string[]).
    .DESCRIPTION
        A workspace is compliant when:
          * 'origin' does not resolve to the source template repository
            (it is either absent -- local mode -- or points at the
            consumer's own repository -- spin-off mode); and
          * any retained 'upstream' remote's push URL does not resolve to
            the source template repository (it is disabled with a sentinel
            such as 'DISABLE').
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SourceUrl,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$OriginUrl = '',

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UpstreamPushUrl = ''
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
        $failures.Add("Source template URL is unknown; cannot verify the guard. Pass -SourceUrl with the URL the clone originated from.")
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($OriginUrl) -and (Test-IsSameRepoUrl -UrlA $OriginUrl -UrlB $SourceUrl)) {
            $failures.Add("origin still resolves to the source template repository ($OriginUrl). Remove it (local mode) or repoint it at your own repository (spin-off mode).")
        }

        if (-not [string]::IsNullOrWhiteSpace($UpstreamPushUrl) -and (Test-IsSameRepoUrl -UrlA $UpstreamPushUrl -UrlB $SourceUrl)) {
            $failures.Add("the 'upstream' push URL still targets the source template repository. Disable it: git remote set-url --push upstream DISABLE.")
        }
    }

    return [pscustomobject]@{
        Passed   = ($failures.Count -eq 0)
        Failures = $failures.ToArray()
    }
}

function Get-KickoffPrePushHookContent {
    <#
    .SYNOPSIS
        Render the best-effort pre-push hook (layer 3 of the guard) that
        aborts any push whose destination resolves to the source template
        repository.
    .DESCRIPTION
        Returns a bash script. It embeds the canonicalized source URL and
        re-canonicalizes each push destination before comparing, so HTTPS
        and SSH forms are both blocked. It is deliberately non-strict (no
        'set -e') so an unexpected condition never blocks an unrelated
        push -- it blocks only on a positive match. It is bypassable with
        'git push --no-verify', which is why it backstops rather than
        replaces origin severance and push-URL disablement.
        Reference: https://git-scm.com/docs/githooks
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceUrl
    )

    $normalized = Get-NormalizedRepoUrl -Url $SourceUrl
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Cannot build a pre-push hook: the source URL '$SourceUrl' normalized to an empty value."
    }

    $template = @'
#!/usr/bin/env bash
# Managed by scripts/Set-KickoffGuard.ps1 (ADR 0045). Best-effort backstop that
# blocks any push whose destination resolves to the source template repository.
# Layer 3 of the no-push-back guard; origin severance and upstream push-URL
# disablement are the primary layers. Bypassable with --no-verify.
# Reference: https://git-scm.com/docs/githooks
source_url="__SOURCE_URL__"
remote_url="${2:-}"

norm() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^[^@]+@([^:/]+):#\1/#' \
    | sed -E 's#^[a-z][a-z0-9+.-]*://##' \
    | sed -E 's#^[^/@]+@##' \
    | sed -E 's#\.git$##' \
    | sed -E 's#/+$##'
}

if [ "$(norm "$remote_url")" = "$source_url" ]; then
  echo "pre-push blocked: this workspace was severed from its source template" >&2
  echo "  repository ($source_url) per ADR 0045. Pushing content back to the" >&2
  echo "  source template is not permitted." >&2
  exit 1
fi
exit 0
'@

    return $template.Replace('__SOURCE_URL__', $normalized)
}

Export-ModuleMember -Function `
    'Get-NormalizedRepoUrl', `
    'Test-IsSameRepoUrl', `
    'Get-KickoffGuardStatus', `
    'Get-KickoffPrePushHookContent'
