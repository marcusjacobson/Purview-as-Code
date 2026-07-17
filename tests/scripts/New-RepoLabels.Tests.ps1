#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-RepoLabels.ps1 (spin-off label seeding).

.DESCRIPTION
    AST-extracts the pure `Get-RequiredLabel` function from the seeder and
    checks two things:

      1. Shape: every entry has a name, a valid 6-hex color, and a
         description; names are unique.
      2. COVERAGE (the non-vacuous assertion): every label token the
         committed workflows actually reference is present in the seeder's
         set. This is the property that matters -- a fresh spin-off has
         the automation dormant unless the seeder creates every label the
         automation gates on. The test reads the SHIPPED workflow files
         (same reasoning as tests/workflows/EnvironmentRouting.Tests.ps1:
         when the hazard is in the committed artefact, the test reads the
         committed artefact) and fails if a workflow references a label
         the seeder would not create.

    No `gh` calls, no network -- only the pure function and static file
    reads.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'New-RepoLabels.ps1'
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $fnAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-RequiredLabel'
        }, $true)
    if (-not $fnAst) {
        throw "Function 'Get-RequiredLabel' not found in $($script:ScriptPath)."
    }
    . ([ScriptBlock]::Create($fnAst.Extent.Text))

    $script:Required = @(Get-RequiredLabel)
    $script:RequiredNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($l in $script:Required) { [void]$script:RequiredNames.Add($l.Name) }

    # Extract every label token the committed workflows reference. Covers
    # the ways a label name appears in this repo's workflows:
    #   * gh label create '<name>' / "<name>" / <name>
    #   * --label '<name>' / "<name>" / <name>   (also comma-joined lists)
    #   * --add-label '<name>' / "<name>"
    #   * grep -c/-q "<name>" for the bash owner/needs-review gates
    #   * PowerShell drift-step hashtable keys: '<name>' = @{ color = ... }
    # This is a best-effort superset extractor; anything it captures that
    # is a real label MUST be seeded. `squad:*` in particular has an
    # unambiguous shape and is the set most likely to grow.
    $script:ReferencedLabels = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)

    # A referenced label is only trusted when it is label-SHAPED --
    # contains a `-` or `:`. This keeps every real label the workflows
    # reference (all are hyphenated: needs-review, owner-approved,
    # code-currency, drift-detected, surface-watch, watch-list; or
    # colon-shaped: squad:*) while dropping plain-word false positives
    # from comment prose the patterns would otherwise catch -- e.g.
    # "# gh label create exits non-zero..." or "grep -q "when"...". The
    # only plain-word label, `destructive`, is applied manually (never via
    # --label in a workflow) and is asserted explicitly in the "nothing
    # self-seeds" test instead.
    $labelShaped = "[A-Za-z0-9][A-Za-z0-9_]*[:-][A-Za-z0-9:_-]*"
    $patterns = @(
        "gh label create\s+['`"]?($labelShaped)['`"]?"
        "--label\s+['`"]?($labelShaped)['`"]?"
        "--add-label\s+['`"]?($labelShaped)['`"]?"
        "grep -[a-z]*\s+['`"]($labelShaped)['`"]"
    )

    Get-ChildItem -Path $script:WorkflowsDir -Filter '*.yml' -File | ForEach-Object {
        $text = Get-Content -Raw -LiteralPath $_.FullName
        foreach ($pat in $patterns) {
            foreach ($m in [regex]::Matches($text, $pat)) {
                $val = $m.Groups[1].Value
                # A `--label "a,b,c"` list -- split on commas.
                foreach ($part in ($val -split ',')) {
                    $p = $part.Trim()
                    if ($p) { [void]$script:ReferencedLabels.Add($p) }
                }
            }
        }
        # Every squad:* token anywhere in the file (routing lists, hashtable
        # keys, grep bodies) -- the persona set most likely to grow.
        foreach ($m in [regex]::Matches($text, 'squad:[a-z-]+')) {
            [void]$script:ReferencedLabels.Add($m.Value)
        }
    }
}

Describe 'Get-RequiredLabel shape' {

    It 'returns at least the 12 known automation labels' {
        $script:Required.Count | Should -BeGreaterOrEqual 12
    }

    It 'gives every label a non-empty name and description' {
        foreach ($l in $script:Required) {
            $l.Name        | Should -Not -BeNullOrEmpty
            $l.Description  | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives every label a valid 6-hex color (no leading #)' {
        foreach ($l in $script:Required) {
            $l.Color | Should -Match '^[0-9a-fA-F]{6}$'
        }
    }

    It 'has no duplicate label names' {
        $names = $script:Required | ForEach-Object { $_.Name }
        ($names | Sort-Object -Unique).Count | Should -Be $names.Count
    }

    It 'seeds the labels that NOTHING self-seeds at run time' {
        # owner-approved / destructive / surface-watch have no run-time
        # `gh label create` fallback anywhere -- the seeder is the ONLY
        # thing that creates them, so a spin-off that skips it has the
        # merge gate and destructive gate permanently dormant.
        foreach ($critical in @('owner-approved', 'destructive', 'surface-watch')) {
            $script:RequiredNames.Contains($critical) |
                Should -BeTrue -Because "the seeder is the only creator of '$critical'"
        }
    }
}

Describe 'Get-RequiredLabel coverage of the committed workflows' {

    It 'discovered a non-trivial set of referenced labels (extractor is not silently empty)' {
        # Green-by-absence guard: if the extractor matched nothing, the
        # coverage assertion below would pass vacuously.
        $script:ReferencedLabels.Count | Should -BeGreaterThan 5
    }

    It 'seeds every label the workflows reference' {
        $missing = @($script:ReferencedLabels | Where-Object { -not $script:RequiredNames.Contains($_) })
        $missing | Should -BeNullOrEmpty -Because "New-RepoLabels.ps1 must seed every label the automation gates on; missing: $($missing -join ', ')"
    }

    It 'seeds all five squad personas that issue-triage routes on' {
        foreach ($persona in @('squad:lead-architect', 'squad:security-specialist', 'squad:automation-engineer', 'squad:tester-validator', 'squad:scribe')) {
            $script:RequiredNames.Contains($persona) | Should -BeTrue -Because "issue-triage.yml routes on '$persona'"
        }
    }
}
