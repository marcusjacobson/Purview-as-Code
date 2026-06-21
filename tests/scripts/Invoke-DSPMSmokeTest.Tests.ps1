#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Invoke-DSPMSmokeTest.ps1
    (v2 §5.4 / Issue #366).

.DESCRIPTION
    AST-extracts the wrapper's assertion helpers and exercises them
    in isolation without invoking the wrapper's top-level orchestration
    (which requires az login + Key Vault + Exchange Online tooling).

    Helpers covered:

      1. `Test-DSPMPostureRowShape` — fails on any Status='Fail' row
         and on an empty row set; passes through Warn rows.
      2. `Test-DSPMExportManifestShape` — fails when manifest.rows[]
         is empty or any row has Status != 'OK'.
      3. `New-DSPMSmokeEvidence` — writes a Markdown table to disk
         containing one row per step.

    Reference: docs/adr/0021-dspm-content-explorer-cadence.md
    Reference: docs/runbooks/dspm-end-to-end-smoke.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-DSPMSmokeTest.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Invoke-DSPMSmokeTest.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @('Test-DSPMPostureRowShape', 'Test-DSPMExportManifestShape', 'New-DSPMSmokeEvidence')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Test-DSPMPostureRowShape' {
    It 'passes when all rows are OK' {
        $rows = @(
            [pscustomobject]@{ Check = 'a'; Status = 'OK'; Detail = 'd' }
            [pscustomobject]@{ Check = 'b'; Status = 'OK'; Detail = 'd' }
        )
        $r = Test-DSPMPostureRowShape -Rows $rows
        $r.Pass | Should -BeTrue
        $r.Reasons.Count | Should -Be 0
    }

    It 'passes when rows contain Warn but no Fail' {
        $rows = @(
            [pscustomobject]@{ Check = 'a'; Status = 'OK';   Detail = 'd' }
            [pscustomobject]@{ Check = 'b'; Status = 'Warn'; Detail = 'gitignore drift' }
        )
        (Test-DSPMPostureRowShape -Rows $rows).Pass | Should -BeTrue
    }

    It 'fails on any Fail row and surfaces the detail' {
        $rows = @(
            [pscustomobject]@{ Check = 'Schema valid'; Status = 'Fail'; Detail = 'broken' }
        )
        $r = Test-DSPMPostureRowShape -Rows $rows
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'Schema valid'
        ($r.Reasons -join ' ') | Should -Match 'broken'
    }

    It 'fails when the row set is empty' {
        $r = Test-DSPMPostureRowShape -Rows @()
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'zero rows|no rows|6'
    }
}

Describe 'Test-DSPMExportManifestShape' {
    It 'passes when every row is OK' {
        $m = [pscustomobject]@{
            rows = @(
                [pscustomobject]@{ Kind = 'Label'; Name = 'A'; Workload = 'Exchange'; Status = 'OK' }
                [pscustomobject]@{ Kind = 'SIT';   Name = 'B'; Workload = 'Teams';    Status = 'OK' }
            )
        }
        (Test-DSPMExportManifestShape -Manifest $m).Pass | Should -BeTrue
    }

    It 'fails when manifest.rows is empty' {
        $m = [pscustomobject]@{ rows = @() }
        $r = Test-DSPMExportManifestShape -Manifest $m
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'zero rows|empty'
    }

    It 'fails and surfaces a non-OK row' {
        $m = [pscustomobject]@{
            rows = @(
                [pscustomobject]@{ Kind = 'Label'; Name = 'A'; Workload = 'Exchange'; Status = 'OK' }
                [pscustomobject]@{ Kind = 'SIT';   Name = 'B'; Workload = 'Teams';    Status = 'Failed' }
            )
        }
        $r = Test-DSPMExportManifestShape -Manifest $m
        $r.Pass | Should -BeFalse
        ($r.Reasons -join ' ') | Should -Match 'B'
        ($r.Reasons -join ' ') | Should -Match 'Failed'
    }
}

Describe 'New-DSPMSmokeEvidence' {
    BeforeAll {
        $script:TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dspm-evidence-{0}" -f [Guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        if ($script:TmpDir -and (Test-Path $script:TmpDir)) {
            Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes a Markdown evidence table with one row per step' {
        $results = @(
            [pscustomobject]@{ Step = 1; Title = 'posture';  Result = 'PASS'; Reason = '12 rows OK.' }
            [pscustomobject]@{ Step = 2; Title = 'export';   Result = 'PASS'; Reason = '44 pairs OK.' }
        )
        $file = Join-Path $script:TmpDir 'dspm-evidence.md'
        $written = New-DSPMSmokeEvidence -Results $results -EvidenceFile $file -ManifestPath '/some/manifest.json'
        $written | Should -Be $file
        Test-Path -LiteralPath $file | Should -BeTrue
        $content = Get-Content -LiteralPath $file -Raw
        $content | Should -Match 'DSPM end-to-end smoke evidence'
        $content | Should -Match '\| 1 \| posture \| PASS \|'
        $content | Should -Match '\| 2 \| export \| PASS \|'
        $content | Should -Match '/some/manifest.json'
    }
}
