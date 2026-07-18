#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Update-LandingPageEmbeds.ps1.

.DESCRIPTION
    Exercises the script against a throwaway landing page and source docs in
    a temporary directory (created in BeforeEach, removed in AfterEach), so no
    real repository files are touched. Covers: embedding linked docs, link
    auto-discovery, deterministic idempotency, -Check drift detection,
    -WhatIf safety, the missing-doc error path, and — the #120 regression —
    that each embedded doc's own relative links are rewritten to resolve from
    the repo root (index.html's actual location), not from the source doc's
    own directory. No tenant, Graph, or Azure calls are made.

    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Update-LandingPageEmbeds.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Update-LandingPageEmbeds.ps1 at: $script:ScriptPath"
    }

    # Dot-source only the script's function-definitions block — not its
    # [CmdletBinding()] param() block (whose $IndexPath default evaluates
    # $PSScriptRoot, which is empty for a dynamically created scriptblock and
    # throws) and not its top-level regeneration logic — so the #120
    # regression tests exercise the real, committed link-rewrite
    # implementation rather than a re-implementation living only in the test
    # file. Dot-sourced directly here (not inside a helper function) so the
    # resulting functions attach to this Describe block's scope and stay
    # visible to its It blocks.
    $script:LandingPageSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    $functionBlockStart = $script:LandingPageSource.IndexOf('function ConvertTo-NormalizedRelativePath')
    $functionBlockEnd = $script:LandingPageSource.IndexOf('$startMarker = ')
    if ($functionBlockStart -lt 0 -or $functionBlockEnd -lt 0) {
        throw "Could not locate the function-definitions block in: $script:ScriptPath"
    }
    $functionSource = $script:LandingPageSource.Substring($functionBlockStart, $functionBlockEnd - $functionBlockStart)
    . ([scriptblock]::Create($functionSource))

    function Initialize-Fixture {
        param([string]$Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'docs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Root 'README.md') -Value "# Project`n`nHello world." -NoNewline
        Set-Content -LiteralPath (Join-Path $Root 'docs/guide.md') -Value "# Guide`n`nStep one." -NoNewline
        $index = @'
<!DOCTYPE html>
<html><body>
  <a href="README.md">Read the README</a>
  <a href="docs/guide.md">Guide</a>
  <a href="https://learn.microsoft.com/x.md">External</a>
  <!-- EMBEDDED-DOCS:START -->
  <!-- EMBEDDED-DOCS:END -->
</body></html>
'@
        $indexPath = Join-Path $Root 'index.html'
        Set-Content -LiteralPath $indexPath -Value $index -NoNewline
        return $indexPath
    }
}

Describe 'Update-LandingPageEmbeds' {

    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("lpembed-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:IndexPath = Initialize-Fixture -Root $script:Root
    }

    AfterEach {
        if ($script:Root -and (Test-Path $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'embeds the content of each linked doc into the region' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        $out = Get-Content -LiteralPath $script:IndexPath -Raw
        $out | Should -Match 'data-doc="README.md"'
        $out | Should -Match 'data-doc="docs/guide.md"'
        $out | Should -Match 'Hello world\.'
        $out | Should -Match 'Step one\.'
    }

    It 'does not embed external (absolute-URL) Markdown links' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        $out = Get-Content -LiteralPath $script:IndexPath -Raw
        $out | Should -Not -Match 'data-doc="https://learn.microsoft.com/x.md"'
    }

    It 'is idempotent: -Check passes immediately after an update' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        { & $script:ScriptPath -IndexPath $script:IndexPath -Check } | Should -Not -Throw
    }

    It 'a second update makes no further change to the file' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        $first = Get-Content -LiteralPath $script:IndexPath -Raw
        & $script:ScriptPath -IndexPath $script:IndexPath
        (Get-Content -LiteralPath $script:IndexPath -Raw) | Should -BeExactly $first
    }

    It '-Check throws when a source doc changed after embedding (drift)' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/guide.md') -Value "# Guide`n`nStep one and two." -NoNewline
        { & $script:ScriptPath -IndexPath $script:IndexPath -Check } |
            Should -Throw -ExpectedMessage '*STALE*'
    }

    It '-Check throws on the un-embedded starting state' {
        { & $script:ScriptPath -IndexPath $script:IndexPath -Check } |
            Should -Throw -ExpectedMessage '*STALE*'
    }

    It '-WhatIf does not modify the file' {
        $before = Get-Content -LiteralPath $script:IndexPath -Raw
        & $script:ScriptPath -IndexPath $script:IndexPath -WhatIf
        (Get-Content -LiteralPath $script:IndexPath -Raw) | Should -BeExactly $before
    }

    It 'throws when a linked doc does not exist' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'docs/guide.md') -Force
        { & $script:ScriptPath -IndexPath $script:IndexPath } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'throws when the markers are absent' {
        Set-Content -LiteralPath $script:IndexPath -Value '<html><body><a href="README.md">x</a></body></html>' -NoNewline
        { & $script:ScriptPath -IndexPath $script:IndexPath } |
            Should -Throw -ExpectedMessage '*markers*'
    }
}

Describe 'ConvertTo-RepoRootRelativeLink (unit — #120 regression)' {

    It 'rewrites a ../-relative link from a doc one level under a subdirectory so it resolves from the repo root' {
        # docs/solutions/foo.md linking '../adr/0057-x.md' means docs/adr/0057-x.md
        # from foo.md's own directory; from index.html at the repo root that must
        # become 'docs/adr/0057-x.md', not the unresolved
        # 'docs/solutions/../adr/0057-x.md'.
        ConvertTo-RepoRootRelativeLink -DocDir 'docs/solutions' -Target '../adr/0057-x.md' |
            Should -BeExactly 'docs/adr/0057-x.md'
    }

    It 'prepends docs/ to a same-directory relative link authored without ../' {
        # docs/architecture.md linking 'adr/0038-x.md' means docs/adr/0038-x.md
        # from architecture.md's own directory (docs/); from the repo root that
        # must become 'docs/adr/0038-x.md'.
        ConvertTo-RepoRootRelativeLink -DocDir 'docs' -Target 'adr/0038-x.md' |
            Should -BeExactly 'docs/adr/0038-x.md'
    }

    It 'collapses a climbing ../ back out of docs/ entirely when the target is outside docs/' {
        # docs/kickoff-guide.md linking '../scripts/Connect-Purview.ps1' means
        # repo-root scripts/Connect-Purview.ps1 from kickoff-guide.md's own
        # directory (docs/); from the repo root that must become
        # 'scripts/Connect-Purview.ps1', not 'docs/scripts/Connect-Purview.ps1'.
        ConvertTo-RepoRootRelativeLink -DocDir 'docs' -Target '../scripts/Connect-Purview.ps1' |
            Should -BeExactly 'scripts/Connect-Purview.ps1'
    }

    It 'leaves a link from a repo-root doc unchanged (no double-prefix)' {
        # README.md lives at the repo root; its links are already
        # repo-root-relative and must not gain a spurious prefix.
        ConvertTo-RepoRootRelativeLink -DocDir '' -Target 'docs/getting-started.md' |
            Should -BeExactly 'docs/getting-started.md'
    }

    It 'preserves an in-page anchor fragment while rewriting the path portion' {
        ConvertTo-RepoRootRelativeLink -DocDir 'docs' -Target '../.github/instructions/powershell.instructions.md#pre-commit-checklist' |
            Should -BeExactly '.github/instructions/powershell.instructions.md#pre-commit-checklist'
    }

    It 'leaves an absolute https:// URL untouched' {
        ConvertTo-RepoRootRelativeLink -DocDir 'docs' -Target 'https://learn.microsoft.com/en-us/purview/' |
            Should -BeExactly 'https://learn.microsoft.com/en-us/purview/'
    }

    It 'leaves a mailto: link untouched' {
        ConvertTo-RepoRootRelativeLink -DocDir 'docs' -Target 'mailto:owner@example.com' |
            Should -BeExactly 'mailto:owner@example.com'
    }

    It 'leaves an anchor-only link untouched' {
        ConvertTo-RepoRootRelativeLink -DocDir 'docs/solutions' -Target '#section-heading' |
            Should -BeExactly '#section-heading'
    }
}

Describe 'Update-LandingPageEmbeds — end-to-end link resolution (#120 regression)' {

    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("lpembed-links-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs/solutions') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'docs/adr') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'scripts') -Force | Out-Null

        # A doc one level under docs/ (mirrors docs/architecture.md, docs/kickoff-guide.md, ...).
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/guide.md') -Value @'
# Guide

See the [ADR](adr/0001-fixture.md) and the [script](../scripts/Fixture.ps1).
'@ -NoNewline

        # A doc two levels under docs/ (mirrors docs/solutions/*.md).
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/solutions/foo.md') -Value @'
# Foo

Back to the [ADR](../adr/0002-fixture.md).
'@ -NoNewline

        Set-Content -LiteralPath (Join-Path $script:Root 'docs/adr/0001-fixture.md') -Value '# ADR 1' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/adr/0002-fixture.md') -Value '# ADR 2' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Root 'scripts/Fixture.ps1') -Value '# fixture' -NoNewline

        $index = @'
<!DOCTYPE html>
<html><body>
  <a href="docs/guide.md">Guide</a>
  <a href="docs/solutions/foo.md">Foo</a>
  <!-- EMBEDDED-DOCS:START -->
  <!-- EMBEDDED-DOCS:END -->
</body></html>
'@
        $script:IndexPath = Join-Path $script:Root 'index.html'
        Set-Content -LiteralPath $script:IndexPath -Value $index -NoNewline
    }

    AfterEach {
        if ($script:Root -and (Test-Path $script:Root)) {
            Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rewrites embedded links so every one resolves from the repo root, not the source doc directory' {
        & $script:ScriptPath -IndexPath $script:IndexPath
        $out = Get-Content -LiteralPath $script:IndexPath -Raw

        # docs/guide.md's own-directory link becomes docs/-prefixed.
        $out | Should -Match '\(docs/adr/0001-fixture\.md\)'
        $out | Should -Not -Match '\(adr/0001-fixture\.md\)'

        # docs/guide.md's ../-relative link resolves back out to the repo-root scripts/.
        $out | Should -Match '\(scripts/Fixture\.ps1\)'
        $out | Should -Not -Match '\(\.\./scripts/Fixture\.ps1\)'

        # docs/solutions/foo.md's ../-relative link collapses to docs/adr/, not
        # the unresolved docs/solutions/../adr/ shape.
        $out | Should -Match '\(docs/adr/0002-fixture\.md\)'
        $out | Should -Not -Match '\(\.\./adr/0002-fixture\.md\)'
        $out | Should -Not -Match '\(docs/solutions/\.\./adr/0002-fixture\.md\)'

        # Every embedded relative link target actually exists on disk from the
        # repo root — the real regression proof, not just a string match.
        $repoRoot = Split-Path -Parent $script:IndexPath
        $regionMatch = [regex]::Match($out, '(?s)<!-- EMBEDDED-DOCS:START -->.*?<!-- EMBEDDED-DOCS:END -->')
        $regionMatch.Success | Should -BeTrue
        $links = [regex]::Matches($regionMatch.Value, '\]\(([^)]+)\)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '^[A-Za-z][A-Za-z0-9+.-]*:' -and $_ -notmatch '^#' }
        $links.Count | Should -BeGreaterThan 0
        foreach ($link in $links) {
            $target = (($link -split '#')[0])
            Join-Path $repoRoot $target | Should -Exist
        }
    }
}
