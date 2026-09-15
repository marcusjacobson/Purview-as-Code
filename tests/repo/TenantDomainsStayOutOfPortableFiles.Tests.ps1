#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    A real tenant domain must not appear in any file that ports upstream
    (issue #329).

.DESCRIPTION
    `Test-IdentifierResidue.ps1` is the repository's disclosure gate, and its
    contract is explicit: *"every GUID-shaped token in every tracked file is
    guilty until acquitted"*. A tenant domain is not GUID-shaped, so that gate
    is structurally blind to it — as is the placeholder manifest, which acquits
    by exact value.

    That blind spot was not theoretical. The 2026-09-15 upstream scope ruling
    found **ten** real tenant identifiers across **five** files that were owed
    to the public template — including, with some irony, a test whose subject is
    identity redaction. The template was clean of all of them, so the port would
    have been a first disclosure, and every automated gate in the repository
    would have passed it.

    This guard closes that class:

      - the domains are **discovered** from `infra/parameters/*.yaml`, the
        authoritative source, never restated here;
      - "portable" is decided with the **same glob translation the upstream scan
        uses** (`Convert-ScopeGlobToRegex`, AST-extracted from
        `scripts/Get-UpstreamDelta.ps1`), so this guard and the scan cannot
        disagree about what ports;
      - a file listed in `upstream-scope.yaml` as an operator surface may carry
        them freely — that is what those entries are for.

    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    Import-Module powershell-yaml -ErrorAction SilentlyContinue

    # --- the domains, discovered ------------------------------------------
    $script:TenantDomains = @(
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'infra' 'parameters') -Filter '*.yaml' -File |
            ForEach-Object {
                $doc = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Yaml
                if ($doc -and $doc['automation'] -and $doc['automation']['tenantDomain']) {
                    [string]$doc['automation']['tenantDomain']
                }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    # --- what is allowed to carry them, from the scope manifest ------------
    # Reuse the scan's own glob translation rather than writing a second one:
    # two implementations of "does this path port" would eventually disagree,
    # and the disagreement would be silent.
    $scanPath = Join-Path $script:RepoRoot 'scripts' 'Get-UpstreamDelta.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scanPath, [ref]$null, [ref]$null)
    $fn = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Convert-ScopeGlobToRegex'
        }, $true)
    if (-not $fn) { throw "Convert-ScopeGlobToRegex not found in $scanPath" }
    . ([ScriptBlock]::Create($fn.Extent.Text))

    $scope = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github' 'agents' 'upstream-scope.yaml') -Raw |
        ConvertFrom-Yaml
    $script:OperatorRegexes = @(
        $scope['operatorSurfaces'] |
            ForEach-Object { [string]$_['path'] } |
            Where-Object { $_ } |
            ForEach-Object { Convert-ScopeGlobToRegex -Glob $_ }
    )

    function Test-PortsUpstream {
        param([Parameter(Mandatory = $true)][string] $Path)
        foreach ($rx in $script:OperatorRegexes) {
            if ($Path -match $rx) { return $false }
        }
        return $true
    }

    # --- the sweep ---------------------------------------------------------
    Push-Location $script:RepoRoot
    try { $script:Tracked = @(git ls-files) } finally { Pop-Location }

    $script:Offenders = @()
    if ($script:TenantDomains.Count -gt 0) {
        $pattern = ($script:TenantDomains | ForEach-Object { [regex]::Escape($_) }) -join '|'
        foreach ($rel in $script:Tracked) {
            if (-not (Test-PortsUpstream -Path $rel)) { continue }
            $full = Join-Path $script:RepoRoot $rel
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $content = Get-Content -LiteralPath $full -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content) { continue }
            if ($content -match $pattern) { $script:Offenders += $rel }
        }
    }
}

Describe 'Real tenant domains never reach a file that ports upstream' {

    It 'discovers the tenant domains from the parameters files' {
        # Non-vacuity. With no domains discovered the sweep below would pass by
        # searching for nothing -- which is exactly how the residue scan misses
        # this class, so the same mistake is not repeated here.
        $script:TenantDomains.Count | Should -BeGreaterThan 0
        foreach ($d in $script:TenantDomains) { $d | Should -Match '\.' }
    }

    It 'resolves which files port using the upstream scan own glob rules' {
        $script:OperatorRegexes.Count | Should -BeGreaterThan 0
    }

    It 'sees a meaningful number of tracked files' {
        $script:Tracked.Count | Should -BeGreaterThan 100
    }

    It 'finds no tenant domain in any portable file' {
        # On 2026-09-15 this listed docs/runbooks/irm-sync-loop-e2e.md,
        # tests/data-plane/LabelsIdentityRedaction.Tests.ps1,
        # tests/scripts/Deploy-Labels.Tests.ps1 and both local drift-sync tests.
        # All five were owed upstream, and every other gate passed them.
        $script:Offenders | Should -BeNullOrEmpty -Because (
            "these files port to the public template and carry a real tenant domain: {0}" -f ($script:Offenders -join ', ')
        )
    }
}
