#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Invoke-RecordsSmokeTest.ps1 (issue #596).

.DESCRIPTION
    AST-extracts the wrapper's helper functions and locks in their
    pure, deterministic contracts. Zero live-tenant interaction: the
    wrapper's top-level orchestration (which would otherwise call
    Deploy-FilePlan.ps1 against contoso.onmicrosoft.com) is never executed
    because we parse and dot-source individual function bodies only,
    not the whole script.

    Covered helpers:
      * Get-RecordsSmokeSeed          -- copy-paste regression against
                                         ADR 0035's 29-name seed list.
      * Get-RecordsSmokeYamlTail      -- per-phase YAML body shape.
      * Set-RecordsYamlFile           -- in-place splice, UTF-8 no-BOM.
      * Assert-CleanRecordsTree       -- pass-through on clean, throws
                                         on dirty (via mocked git).
      * Read-DestructiveConfirmation  -- y/yes/confirm vs anything else
                                         (via mocked Read-Host).
      * Test-StepExpectation          -- pure assertion matrix.
      * New-StepRecord                -- factory shape.
      * Get-EvidenceFilePath          -- filename shape + scope guard.
      * Format-RecordsSmokeEvidence   -- markdown structure.

    References:
      * https://pester.dev/docs/quick-start
      * about_Functions_CmdletBindingAttribute:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-RecordsSmokeTest.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Invoke-RecordsSmokeTest.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $names = @(
        'Get-RecordsSmokeSeed',
        'Get-RecordsSmokeYamlTail',
        'Set-RecordsYamlFile',
        'Reset-RecordsYamlFile',
        'Assert-CleanRecordsTree',
        'Read-DestructiveConfirmation',
        'Test-StepExpectation',
        'New-StepRecord',
        'Get-EvidenceFilePath',
        'Format-RecordsSmokeEvidence'
    )
    foreach ($fname in $names) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Get-RecordsSmokeSeed -- ADR 0035 copy-paste regression' {

    It 'returns exactly 29 unique names' {
        $seeds = Get-RecordsSmokeSeed
        $seeds.Count | Should -Be 29
        ($seeds | Sort-Object -Unique).Count | Should -Be 29
    }

    It 'includes the three documented authority seeds' {
        $seeds = Get-RecordsSmokeSeed
        $seeds | Should -Contain 'Business'
        $seeds | Should -Contain 'Legal'
        $seeds | Should -Contain 'Regulatory'
    }

    It 'includes Sarbanes-Oxley Act of 2002 (citation seed with awkward characters)' {
        Get-RecordsSmokeSeed | Should -Contain 'Sarbanes-Oxley Act of 2002'
    }

    It 'includes Procurement exactly once (collapsed across category + department kinds)' {
        @(Get-RecordsSmokeSeed | Where-Object { $_ -eq 'Procurement' }).Count | Should -Be 1
    }

    It 'includes Legal exactly once (collapsed across authority + department kinds)' {
        @(Get-RecordsSmokeSeed | Where-Object { $_ -eq 'Legal' }).Count | Should -Be 1
    }
}

Describe 'Get-RecordsSmokeYamlTail -- per-phase YAML body shape' {

    It 'Empty phase yields fully empty desired state' {
        $y = Get-RecordsSmokeYamlTail -Phase Empty -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $y | Should -Match 'categories:\s*\[\]'
        $y | Should -Match 'retentionLabels:\s*\[\]'
        $y | Should -Not -Match 'lab-fp-cat-smoke-001'
        $y | Should -Not -Match 'lab-fp-label-smoke-001'
    }

    It 'CategoryOnly phase declares the category but leaves retentionLabels empty' {
        $y = Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $y | Should -Match '(?ms)categories:\s*\n\s*-\s*name:\s*lab-fp-cat-smoke-001'
        $y | Should -Match 'retentionLabels:\s*\[\]'
        $y | Should -Not -Match 'lab-fp-label-smoke-001'
    }

    It 'CategoryAndLabel phase emits retentionDuration: 30 and isRecordLabel: false' {
        $y = Get-RecordsSmokeYamlTail -Phase CategoryAndLabel -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $y | Should -Match 'isRecordLabel:\s*false'
        $y | Should -Match 'retentionDuration:\s*30'
        $y | Should -Match 'category:\s*lab-fp-cat-smoke-001'
    }

    It 'CategoryAndLabelEdited phase bumps retentionDuration to 60' {
        $y = Get-RecordsSmokeYamlTail -Phase CategoryAndLabelEdited -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $y | Should -Match 'retentionDuration:\s*60'
        $y | Should -Not -Match 'retentionDuration:\s*30'
        $y | Should -Match 'isRecordLabel:\s*false'
    }

    It 'CategoryAndLabelImmutable phase flips isRecordLabel to true (DriftWarn smoke only)' {
        $y = Get-RecordsSmokeYamlTail -Phase CategoryAndLabelImmutable -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $y | Should -Match 'isRecordLabel:\s*true'
        $y | Should -Not -Match 'isRecordLabel:\s*false'
    }

    It 'rejects category names outside the lab-fp- prefix' {
        { Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName 'production-real-thing' -LabelName 'lab-fp-label-smoke-001' } |
            Should -Throw
    }

    It 'rejects label names outside the lab-fp- prefix' {
        { Get-RecordsSmokeYamlTail -Phase CategoryAndLabel -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'real-retention-policy' } |
            Should -Throw
    }
}

Describe 'Set-RecordsYamlFile -- in-place splice' {

    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("irst-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:YamlPath = Join-Path $script:TempRoot 'file-plan.yaml'
        @"
# Header line 1
# Header line 2 (long comment block)
# Header line 3

filePlanProperties:
  authorities: []
  categories: []
  citations: []
  departments: []
  referenceIds: []
  subCategories: []

retentionLabels: []
"@ | Set-Content -LiteralPath $script:YamlPath -Encoding utf8
    }
    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item -Recurse -Force $script:TempRoot }
    }

    It 'preserves everything before filePlanProperties:' {
        Set-RecordsYamlFile -YamlPath $script:YamlPath `
            -Tail (Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001')
        $content = Get-Content -LiteralPath $script:YamlPath -Raw
        $content | Should -Match '# Header line 1'
        $content | Should -Match '# Header line 3'
    }

    It 'replaces only the desired-state tail' {
        Set-RecordsYamlFile -YamlPath $script:YamlPath `
            -Tail (Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001')
        $content = Get-Content -LiteralPath $script:YamlPath -Raw
        $content | Should -Match 'lab-fp-cat-smoke-001'
        $content | Should -Match 'retentionLabels:\s*\[\]'
    }

    It 'writes UTF-8 without BOM' {
        Set-RecordsYamlFile -YamlPath $script:YamlPath `
            -Tail (Get-RecordsSmokeYamlTail -Phase Empty -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001')
        $bytes = [System.IO.File]::ReadAllBytes($script:YamlPath)
        # UTF-8 BOM is EF BB BF
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $hasBom | Should -BeFalse
    }

    It 'throws when no filePlanProperties: anchor is found' {
        'just a comment' | Set-Content -LiteralPath $script:YamlPath -Encoding utf8
        { Set-RecordsYamlFile -YamlPath $script:YamlPath -Tail 'retentionLabels: []' } |
            Should -Throw -ExpectedMessage '*filePlanProperties*'
    }

    It 'throws when YAML file is missing' {
        { Set-RecordsYamlFile -YamlPath (Join-Path $script:TempRoot 'nope.yaml') -Tail 'retentionLabels: []' } |
            Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'Read-DestructiveConfirmation -- y/yes/confirm vs everything else' {

    It 'returns $true for "y"' {
        Mock -CommandName Read-Host -MockWith { 'y' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeTrue
    }

    It 'returns $true for "yes" (case-insensitive)' {
        Mock -CommandName Read-Host -MockWith { 'Yes' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeTrue
    }

    It 'returns $true for "confirm"' {
        Mock -CommandName Read-Host -MockWith { 'CONFIRM' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeTrue
    }

    It 'returns $false for empty input' {
        Mock -CommandName Read-Host -MockWith { '' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeFalse
    }

    It 'returns $false for "n"' {
        Mock -CommandName Read-Host -MockWith { 'n' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeFalse
    }

    It 'returns $false for any unrelated text (no surprise affirmatives)' {
        Mock -CommandName Read-Host -MockWith { 'absolutely' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeFalse
    }

    It 'returns $false for whitespace-only input' {
        Mock -CommandName Read-Host -MockWith { '   ' }
        Read-DestructiveConfirmation -Prompt 'proceed?' | Should -BeFalse
    }
}

Describe 'Test-StepExpectation -- pure assertion' {

    It 'PASS when CategoryCounts match' {
        $rows = @(
            [pscustomobject]@{ Category = 'Skipped'; Kind = 'Category'; Name = 'A'; Reason = '' },
            [pscustomobject]@{ Category = 'Skipped'; Kind = 'Category'; Name = 'B'; Reason = '' }
        )
        $v = Test-StepExpectation -PlanRows $rows -Expected @{ CategoryCounts = @{ Skipped = 2 } }
        $v.Result | Should -Be 'PASS'
    }

    It 'FAIL when CategoryCounts mismatch with helpful diagnostic' {
        $rows = @( [pscustomobject]@{ Category = 'Create'; Kind = 'Label'; Name = 'X'; Reason = '' } )
        $v = Test-StepExpectation -PlanRows $rows -Expected @{ CategoryCounts = @{ Create = 0 } }
        $v.Result | Should -Be 'FAIL'
        $v.Reason | Should -Match 'Create.*expected=0.*actual=1'
    }

    It 'PASS when ContainsRow matches an exact triple' {
        $rows = @(
            [pscustomobject]@{ Category = 'Create'; Kind = 'Category'; Name = 'lab-fp-cat-smoke-001'; Reason = '' }
        )
        $v = Test-StepExpectation -PlanRows $rows -Expected @{ ContainsRow = @( @{ Category = 'Create'; Kind = 'Category'; Name = 'lab-fp-cat-smoke-001' } ) }
        $v.Result | Should -Be 'PASS'
    }

    It 'FAIL when ContainsRow misses (wrong name)' {
        $rows = @(
            [pscustomobject]@{ Category = 'Create'; Kind = 'Category'; Name = 'typo-name'; Reason = '' }
        )
        $v = Test-StepExpectation -PlanRows $rows -Expected @{ ContainsRow = @( @{ Category = 'Create'; Kind = 'Category'; Name = 'lab-fp-cat-smoke-001' } ) }
        $v.Result | Should -Be 'FAIL'
        $v.Reason | Should -Match 'Missing row.*lab-fp-cat-smoke-001'
    }

    It 'ignores non-plan-row pipeline noise' {
        $rows = @(
            'some informational string',
            [pscustomobject]@{ Category = 'NoChange'; Kind = 'Label'; Name = 'Z'; Reason = '' }
        )
        $v = Test-StepExpectation -PlanRows $rows -Expected @{ CategoryCounts = @{ NoChange = 1 } }
        $v.Result | Should -Be 'PASS'
    }

    It 'handles a null PlanRows input as zero rows' {
        $v = Test-StepExpectation -PlanRows $null -Expected @{ CategoryCounts = @{ Create = 0 } }
        $v.Result | Should -Be 'PASS'
    }
}

Describe 'New-StepRecord -- factory shape' {

    It 'returns the expected fields' {
        $r = New-StepRecord -Step '2a' -Title 't' -Result 'PASS'
        $r.PSObject.Properties.Name | Should -Contain 'Step'
        $r.PSObject.Properties.Name | Should -Contain 'Title'
        $r.PSObject.Properties.Name | Should -Contain 'Result'
        $r.PSObject.Properties.Name | Should -Contain 'Reason'
        $r.PSObject.Properties.Name | Should -Contain 'PlanRows'
        $r.PSObject.Properties.Name | Should -Contain 'PlanRowCount'
        $r.PSObject.Properties.Name | Should -Contain 'Command'
    }

    It 'rejects an unknown Result value' {
        { New-StepRecord -Step 'X' -Title 't' -Result 'MAYBE' } | Should -Throw
    }

    It 'folds plan rows into a typed array and counts them' {
        $rows = @(
            [pscustomobject]@{ Category = 'Create'; Kind = 'Label'; Name = 'A'; Reason = '' },
            [pscustomobject]@{ Category = 'NoChange'; Kind = 'Category'; Name = 'B'; Reason = '' }
        )
        $r = New-StepRecord -Step '1' -Title 't' -Result 'PASS' -PlanRows $rows
        $r.PlanRowCount | Should -Be 2
        @($r.PlanRows).Count | Should -Be 2
    }
}

Describe 'Get-EvidenceFilePath -- timestamped path with scope guard' {

    It 'produces a records-<UTC>.md filename inside the supplied directory' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) '.copilot-tracking\smoke'
        $ts  = [datetime]::SpecifyKind([datetime]'2026-06-07T19:07:00', [System.DateTimeKind]::Utc)
        $p = Get-EvidenceFilePath -EvidenceDirectory $dir -Timestamp $ts
        $p | Should -Match 'records-20260607-190700Z\.md$'
        $p | Should -Match '\.copilot-tracking'
    }

    It 'refuses to write outside .copilot-tracking/' {
        { Get-EvidenceFilePath -EvidenceDirectory '/tmp/elsewhere' } |
            Should -Throw -ExpectedMessage '*outside .copilot-tracking*'
    }
}

Describe 'Format-RecordsSmokeEvidence -- markdown structure' {

    It 'produces a result-summary table with one row per step' {
        $steps = @(
            (New-StepRecord -Step '1' -Title 'Baseline' -Result 'PASS'),
            (New-StepRecord -Step '2' -Title 'Create' -Result 'FAIL' -Reason 'missing row')
        )
        $md = Format-RecordsSmokeEvidence -Steps $steps `
            -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001' `
            -Timestamp ([datetime]'2026-06-07T19:07:00Z')
        $md | Should -Match '## Result summary'
        $md | Should -Match '\|\s*1\s*\|\s*Baseline\s*\|\s*PASS'
        $md | Should -Match '\|\s*2\s*\|\s*Create\s*\|\s*FAIL'
    }

    It 'emits the FAIL reason in the per-step detail block' {
        $steps = @( New-StepRecord -Step '2' -Title 'Create' -Result 'FAIL' -Reason 'missing row: Category=Create Kind=Category Name=lab-fp-cat-smoke-001' )
        $md = Format-RecordsSmokeEvidence -Steps $steps `
            -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $md | Should -Match 'Reason: missing row'
    }

    It 'emits a plan-rows sub-table when the step carried plan rows' {
        $rows = @( [pscustomobject]@{ Category = 'Create'; Kind = 'Category'; Name = 'lab-fp-cat-smoke-001'; Reason = 'new' } )
        $steps = @( New-StepRecord -Step '2b' -Title 'Create' -Result 'PASS' -PlanRows $rows -Command 'Deploy-FilePlan.ps1' )
        $md = Format-RecordsSmokeEvidence -Steps $steps `
            -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $md | Should -Match 'Plan rows:'
        $md | Should -Match '\|\s*Create\s*\|\s*Category\s*\|\s*lab-fp-cat-smoke-001\s*\|'
    }

    It 'includes the wrapper + runbook back-links' {
        $md = Format-RecordsSmokeEvidence -Steps @() `
            -CategoryName 'lab-fp-cat-smoke-001' -LabelName 'lab-fp-label-smoke-001'
        $md | Should -Match 'docs/runbooks/records-end-to-end-smoke\.md'
        $md | Should -Match 'scripts/Invoke-RecordsSmokeTest\.ps1'
    }
}

Describe 'Assert-CleanRecordsTree -- git status integration' {

    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("acrt-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        # init a real empty repo so git status returns clean
        Push-Location $script:TempRoot
        $null = git init -q 2>&1
        $null = git config user.email 'test@example.com' 2>&1
        $null = git config user.name 'test' 2>&1
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'data-plane/records') -Force | Out-Null
        'content' | Set-Content (Join-Path $script:TempRoot 'data-plane/records/file-plan.yaml')
        $null = git add -A 2>&1
        $null = git commit -q -m 'init' 2>&1
        Pop-Location
    }
    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item -Recurse -Force $script:TempRoot }
    }

    It 'returns silently when working tree is clean' {
        { Assert-CleanRecordsTree -RepoRoot $script:TempRoot } | Should -Not -Throw
    }

    It 'throws when a tracked file under data-plane/records is modified' {
        'dirty' | Set-Content (Join-Path $script:TempRoot 'data-plane/records/file-plan.yaml')
        { Assert-CleanRecordsTree -RepoRoot $script:TempRoot } |
            Should -Throw -ExpectedMessage '*uncommitted edits*'
    }
}