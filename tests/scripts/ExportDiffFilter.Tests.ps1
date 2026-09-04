#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/modules/ExportDiffFilter.psm1, the
    shared issue #508 cosmetic-only export-diff filter.

.DESCRIPTION
    Two layers:

      1. BEHAVIOUR -- Test-ExportDiffMeaningful / Get-ExportDiffSummary
         against synthetic diff strings, including a red-replay of the
         pre-refactor inline logic to prove the extraction changed
         nothing (Non-vacuity pattern used across this repo's workflow
         suites).
      2. WORKFLOW PARITY -- the three sync-<domain>-from-tenant.yml
         workflows that carry this filter step import the module and
         call Test-ExportDiffMeaningful, rather than each re-implementing
         the regex inline; their run blocks are identical modulo the
         `$path =` line (mirrors CIDataPlaneEnabledGate.Tests.ps1's
         "one reference, assert the rest match" technique).

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #508
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'modules' 'ExportDiffFilter.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate ExportDiffFilter.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Pre-refactor inline logic, verbatim from the shipped workflow
    # (sync-dlp-from-tenant.yml "Filter cosmetic-only export diff (issue
    # #508)" step, minus the `$diff = git diff ...` line and the
    # `-not $diff` early return, which the caller already handles).
    # Kept here as a fixture, not sourced from the workflow, so this test
    # cannot silently start comparing the module against itself.
    function Test-LegacyDiffMeaningful {
        param([string]$DiffText)
        $meaningful = $false
        foreach ($line in ($DiffText -split "`n")) {
            if ($line -notmatch '^[-+]') { continue }
            if ($line -match '^(---|\+\+\+)') { continue }
            $payload = $line.Substring(1)
            if ($payload -match '^\s*$') { continue }
            if ($payload -match '^\s*#') { continue }
            $meaningful = $true
            break
        }
        return $meaningful
    }

    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:FilterWorkflows = @{
        'sync-dlp-from-tenant.yml'                 = 'data-plane/dlp/policies.yaml'
        'sync-auto-label-policies-from-tenant.yml' = 'data-plane/information-protection/auto-label-policies.yaml'
        'sync-label-policies-from-tenant.yml'      = 'data-plane/information-protection/label-policies.yaml'
    }

    Import-Module 'powershell-yaml' -ErrorAction Stop
    function Get-FilterRun {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $script:WorkflowsDir $Name
        $wf = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
        foreach ($jobKey in $wf['jobs'].Keys) {
            foreach ($step in $wf['jobs'][$jobKey]['steps']) {
                # The step name is unquoted YAML containing "#508)"; the
                # parser reads the space before # as a comment start and
                # truncates the value to "...(issue" -- true of all three
                # workflows identically, so match by prefix.
                if ([string]$step['name'] -like 'Filter cosmetic-only export diff*') {
                    return [string]$step['run']
                }
            }
        }
        throw "Step 'Filter cosmetic-only export diff*' not found in $Name"
    }
}

Describe 'Test-ExportDiffMeaningful' {
    It 'returns $false for a null diff' {
        Test-ExportDiffMeaningful -DiffText $null | Should -BeFalse
    }

    It 'returns $false for an empty diff' {
        Test-ExportDiffMeaningful -DiffText '' | Should -BeFalse
    }

    It 'returns $false for blank-line-only changes' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+
+
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }

    It 'returns $false for comment-only changes' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+# a comment
+  # an indented comment
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }

    It 'returns $false for mixed blank and comment lines' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+
+# comment
-# old comment
-
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }

    It 'returns $true when a real field changes alongside cosmetic lines' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+# comment
+
+    mode: Enable
-    mode: TestWithoutNotifications
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeTrue
    }

    It 'ignores --- and +++ file-header lines' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }

    It 'treats an indented comment line as cosmetic' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+      # indented comment inside a nested block
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }

    It 'treats a # inside a block scalar as cosmetic (known limitation, preserved deliberately)' {
        # Only the block-scalar content line changes; a real diff would
        # also touch the "rawAdvancedRule: |" declaration line, but that
        # line does not itself start with #, so it would correctly be
        # flagged meaningful. This isolates the limitation: an unchanged
        # block scalar whose *content* line happens to start with #.
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+          # this is data, not a YAML comment, but the filter cannot tell
'@
        Test-ExportDiffMeaningful -DiffText $diff | Should -BeFalse
    }
}

Describe 'Get-ExportDiffSummary' {
    It 'reports CosmeticOnly=$false and zero counts for an empty diff' {
        $summary = Get-ExportDiffSummary -DiffText ''
        $summary.CosmeticOnly | Should -BeFalse
        $summary.MeaningfulLines | Should -Be 0
        $summary.AddedLines | Should -Be 0
        $summary.RemovedLines | Should -Be 0
    }

    It 'counts added/removed lines and flags CosmeticOnly for comment-only changes' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+# comment
-# old comment
'@
        $summary = Get-ExportDiffSummary -DiffText $diff
        $summary.AddedLines | Should -Be 1
        $summary.RemovedLines | Should -Be 1
        $summary.MeaningfulLines | Should -Be 0
        $summary.CosmeticOnly | Should -BeTrue
    }

    It 'counts meaningful lines and clears CosmeticOnly when a real field changes' {
        $diff = @'
--- a/x.yaml
+++ b/x.yaml
+    mode: Enable
-    mode: TestWithoutNotifications
'@
        $summary = Get-ExportDiffSummary -DiffText $diff
        $summary.MeaningfulLines | Should -Be 2
        $summary.CosmeticOnly | Should -BeFalse
    }
}

Describe 'Non-vacuity -- the module agrees with the pre-refactor inline logic (red-replay)' {
    It 'agrees on a fixture table of representative diffs' {
        $fixtures = @(
            '',
            "--- a/x.yaml`n+++ b/x.yaml`n+`n+",
            "--- a/x.yaml`n+++ b/x.yaml`n+# comment",
            "--- a/x.yaml`n+++ b/x.yaml`n+    mode: Enable`n-    mode: TestWithoutNotifications",
            "--- a/x.yaml`n+++ b/x.yaml`n+# comment`n+    mode: Enable"
        )
        foreach ($fixture in $fixtures) {
            $legacy = Test-LegacyDiffMeaningful -DiffText $fixture
            $module = Test-ExportDiffMeaningful -DiffText $fixture
            $module | Should -Be $legacy -Because "module and pre-refactor logic must agree on: $fixture"
        }
    }
}

Describe 'Workflow parity -- the three sync workflows share the module, not inline duplicates' {
    It 'imports ExportDiffFilter.psm1 and calls Test-ExportDiffMeaningful, with no leftover inline regex' {
        foreach ($name in $script:FilterWorkflows.Keys) {
            $run = Get-FilterRun -Name $name
            $run | Should -Match 'ExportDiffFilter\.psm1' -Because "$name must import the shared module"
            $run | Should -Match 'Test-ExportDiffMeaningful' -Because "$name must call the shared function"
            $run | Should -Not -Match "'\^\\s\*#'" -Because "$name must not re-implement the cosmetic-comment regex inline"
            $run | Should -Not -Match "'\^\\s\*\$'" -Because "$name must not re-implement the cosmetic-blank regex inline"
        }
    }

    It 'has an identical filter step across all three workflows, modulo the $path line' {
        $names = @($script:FilterWorkflows.Keys)
        $normalized = @{}
        foreach ($name in $names) {
            $run = Get-FilterRun -Name $name
            $lines = $run -split "`n" | Where-Object { $_ -notmatch "^\s*\`$path\s*=" }
            $normalized[$name] = ($lines -join "`n")
        }
        $reference = $normalized[$names[0]]
        foreach ($name in $names) {
            $normalized[$name] | Should -Be $reference -Because "$name's filter step must be identical to $($names[0]) apart from the `$path assignment"
        }
    }

    It 'each workflow still sets $path to its own tracked file' {
        foreach ($name in $script:FilterWorkflows.Keys) {
            $run = Get-FilterRun -Name $name
            $expectedLine = "`$path = '$($script:FilterWorkflows[$name])'"
            $pattern = [regex]::Escape($expectedLine)
            $run | Should -Match $pattern -Because "$name must set `$path to $($script:FilterWorkflows[$name])"
        }
    }
}
