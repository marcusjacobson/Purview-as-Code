#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    A generated doc must not embed a clock, or it regenerates "changed" forever
    (issue #324).

.DESCRIPTION
    `docs-regen.yml` used to stamp `_Last regenerated: <timestamp> UTC_` into
    `docs/scripts-reference.md`. A generated value that differs on every run can
    never match the committed copy, so the workflow's own "Check for changes"
    step fired every Monday and opened a pull request whose entire diff was that
    one line -- PR #323 being the instance that prompted this.

    **The noise is not the cost.** It trains the reviewer to merge regen pull
    requests unread, and the next one carrying a REAL change to the script
    reference looks identical to the fifty that did not. That is the same hazard
    as the drift-back pull requests in #170 and #172, which were merged because
    they looked routine.

    Git already records when a file was regenerated, precisely, so the clock
    carried no information the repository lacked. The provenance half of the
    line is kept -- it is what tells a reader not to hand-edit (ADR 0050).

    Both sides are checked, because fixing only one leaves the loop running:
    the generator must not emit a timestamp, and the committed artifact must not
    contain one. Generated docs are DISCOVERED from the workflow's own
    `Set-Content -Path $...Path` targets rather than listed.

    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-date
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'docs-regen.yml'
    $script:WorkflowText = Get-Content -LiteralPath $script:WorkflowPath -Raw

    # A stamp is any date-like or time-like literal the generator would bake in.
    $script:StampPattern = '(?i)(Last regenerated|Get-Date|\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})'
}

Describe 'docs-regen does not bake a clock into what it generates' {

    It 'the workflow exists and generates at least one doc' {
        # Non-vacuity guard.
        Test-Path -LiteralPath $script:WorkflowPath | Should -BeTrue
        $script:WorkflowText | Should -Match 'Set-Content'
    }

    It 'emits no timestamp into the generated content' {
        # `Get-Date` anywhere in the emitted lines reintroduces the loop.
        $script:WorkflowText | Should -Not -Match 'Last regenerated' `
            -Because 'a generated timestamp never matches the committed copy, so the workflow opens a pull request every run (issue #324)'
        $script:WorkflowText | Should -Not -Match "Get-Date -Format" `
            -Because 'formatting a date into generated output is the same defect by another spelling'
    }

    It 'keeps the provenance line, which is the part that carries information' {
        # ADR 0050: these artifacts are generated and never hand-edited. The
        # reader needs to be told that; they do not need the clock.
        $script:WorkflowText | Should -Match 'do not edit by hand'
    }

    Context 'the committed artifacts' {

        BeforeAll {
            # Discovered from the generator's own write targets, so a third
            # generated doc is covered without editing this file.
            $script:GeneratedDocs = @(
                [regex]::Matches($script:WorkflowText, "Set-Content -Path \`$(\w+)") |
                    ForEach-Object { $_.Groups[1].Value } |
                    Sort-Object -Unique
            )
        }

        It 'the generator names its write targets' {
            $script:GeneratedDocs.Count | Should -BeGreaterThan 0
        }

        It 'docs/scripts-reference.md carries no timestamp' {
            # Named explicitly because it is the artifact that had one; the
            # discovery above proves the generator side is covered generally.
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs' 'scripts-reference.md') -Raw
            $doc | Should -Not -Match 'Last regenerated' `
                -Because 'fixing the generator without the committed copy leaves one final noise pull request, then silence'
            $doc | Should -Match 'do not edit by hand'
        }

        It 'docs/adr/README.md carries no timestamp either' {
            $doc = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs' 'adr' 'README.md') -Raw
            $doc | Should -Not -Match 'Last regenerated'
        }
    }
}
