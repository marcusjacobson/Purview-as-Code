#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Invoke-DSPMforAISmokeTest.ps1
    (v2 §5.4 / Issue #368).

.DESCRIPTION
    AST-extracts the wrapper's assertion helpers and exercises them
    in isolation without invoking the wrapper's top-level orchestration
    (which requires az login + Key Vault + Exchange Online tooling).

    Helpers covered:

      1. `Test-DSPMforAIPostureRowShape` — fails on any Status='Fail'
         row and on an empty row set; passes through Warn rows
         (because the YAML's roleGroups: [] default produces a Warn
         row by design).
      2. `New-DSPMforAISmokeEvidence` — writes a Markdown table to
         disk containing one row per step.

    Reference: docs/adr/0022-dspm-for-ai-authoring-surface.md
    Reference: docs/runbooks/dspm-for-ai-end-to-end-smoke.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-DSPMforAISmokeTest.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Invoke-DSPMforAISmokeTest.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @('Test-DSPMforAIPostureRowShape', 'New-DSPMforAISmokeEvidence')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Test-DSPMforAIPostureRowShape' {
    It 'passes when all rows are OK' {
        $rows = @(
            [pscustomobject]@{ Check = 'a'; Status = 'OK'; Detail = 'd' }
            [pscustomobject]@{ Check = 'b'; Status = 'OK'; Detail = 'd' }
        )
        (Test-DSPMforAIPostureRowShape -Rows $rows).Pass | Should -BeTrue
    }

    It 'passes when rows contain Warn but no Fail' {
        $rows = @(
            [pscustomobject]@{ Check = 'a'; Status = 'OK';   Detail = 'd' }
            [pscustomobject]@{ Check = 'b'; Status = 'Warn'; Detail = 'roleGroups: []' }
        )
        (Test-DSPMforAIPostureRowShape -Rows $rows).Pass | Should -BeTrue
    }

    It 'fails on any Fail row and surfaces the detail' {
        $rows = @(
            [pscustomobject]@{ Check = 'Schema valid'; Status = 'Fail'; Detail = 'broken' }
        )
        $r = Test-DSPMforAIPostureRowShape -Rows $rows
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'Schema valid'
        ($r.Reasons -join ' ') | Should -Match 'broken'
    }

    It 'fails when the row set is empty' {
        $r = Test-DSPMforAIPostureRowShape -Rows @()
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'no rows|6'
    }
}

Describe 'New-DSPMforAISmokeEvidence' {
    BeforeAll {
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dspm-ai-evidence-{0}" -f [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
            Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a Markdown evidence table with one row per step' {
        $results = @(
            [pscustomobject]@{ Step = 1; Title = 'posture'; Result = 'PASS'; Reason = '7 rows; no Fail.' }
        )
        $file = Join-Path $script:TmpDir 'dspm-ai-evidence.md'
        $written = New-DSPMforAISmokeEvidence -Results $results -EvidenceFile $file
        $written | Should -Be $file
        Test-Path -LiteralPath $file | Should -BeTrue
        $content = Get-Content -LiteralPath $file -Raw
        $content | Should -Match 'DSPM for AI watch-list re-verification evidence'
        $content | Should -Match '\| 1 \| posture \| PASS \|'
    }
}
