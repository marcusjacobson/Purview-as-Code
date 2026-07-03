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
    -WhatIf safety, and the missing-doc error path. No tenant, Graph, or Azure
    calls are made.

    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Update-LandingPageEmbeds.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Update-LandingPageEmbeds.ps1 at: $script:ScriptPath"
    }

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
