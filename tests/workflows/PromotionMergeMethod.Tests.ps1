#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    A dev -> lab PROMOTION MUST LAND AS A MERGE COMMIT, NOT A SQUASH.

    Squashing a promotion gives `lab` the CONTENT of dev's commits but not
    their ANCESTRY. `git merge-base --is-ancestor origin/dev origin/lab`
    then stays false and `git log origin/lab..origin/dev` reports every
    already-promoted commit as outstanding, permanently.

    Measured on 2026-09-07, immediately after a squashed promotion: git
    reported 12 unpromoted commits where the only real difference outside
    data-plane/** was one regenerated docs-regen timestamp.

    The cost is not cosmetic. With the ancestry broken a promotion can no
    longer be a plain `git merge origin/dev` -- which would conflict only on
    the per-tenant data-plane files, exactly where a deliberate decision is
    wanted. It degrades into abort / verify-by-hand / cherry-pick, performed
    three times that day, and that manual reconstruction is precisely where
    a file gets missed.

    ADR 0057 section 9 already ruled this way for upstream syncs; the
    promotion case was added to it the same day. pr-auto-merge.yml selects
    the merge commit from the `promote/` BRANCH PREFIX rather than from the
    `merge-commit` label, deliberately: a rule that depends on remembering
    to apply a label is a rule that gets forgotten, and this one was.

    Reference: docs/adr/0057-multi-environment-and-branch-model.md section 9
    Reference: https://cli.github.com/manual/gh_pr_merge
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'pr-auto-merge.yml'
    if (-not (Test-Path -LiteralPath $script:WorkflowPath)) {
        throw "pr-auto-merge.yml not found at: $script:WorkflowPath"
    }
    $script:Source = Get-Content -LiteralPath $script:WorkflowPath -Raw

    # The merge-method step only, so assertions cannot be satisfied by the
    # explanatory comment blocks elsewhere in the file.
    $m = [regex]::Match($script:Source, '(?s)- name: Determine merge method.*?(?=\r?\n      - name: )')
    $script:MethodStep = $m.Value
}

Describe 'Promotion PRs land as merge commits (ADR 0057 section 9)' {

    It 'the merge-method step exists and was located (non-vacuity)' {
        $script:MethodStep | Should -Not -BeNullOrEmpty -Because 'every assertion below inspects this step; an empty match would pass them all trivially'
        $script:MethodStep | Should -Match 'GITHUB_OUTPUT' -Because 'the step must still be the one that emits the merge flag'
    }

    It 'a promote/ branch selects --merge' {
        $script:MethodStep | Should -Match 'promote/\*' -Because 'the promotion case must be detected from the branch prefix, so it cannot be forgotten the way a label can'
        # The promote branch and the label must both reach --merge.
        $mergeBranches = @([regex]::Matches($script:MethodStep, 'flag=--merge')).Count
        $mergeBranches | Should -BeGreaterOrEqual 2 -Because 'both the merge-commit label and the promote/ prefix must select a merge commit'
    }

    It 'the branch name reaches the shell through env, not string interpolation' {
        # A branch name is attacker-influenced on a fork PR. Interpolating
        # ${{ ... }} straight into a shell condition is script injection;
        # GitHub's own guidance is to pass it via env and quote the variable.
        $script:MethodStep | Should -Match 'HEAD_REF:\s*\$\{\{\s*github\.event\.pull_request\.head\.ref\s*\}\}' -Because 'the ref must be bound to an env var'
        $script:MethodStep | Should -Match '\[\[\s*"\$HEAD_REF"\s*==\s*promote/\*\s*\]\]' -Because 'the comparison must use the quoted env var, never an inline expression'
        $script:MethodStep | Should -Not -Match '==\s*\$\{\{' -Because 'a ${{ }} expression must never be compared inline in shell'
    }

    It 'squash remains the default for everything else' {
        $script:MethodStep | Should -Match 'flag=--squash' -Because 'feature PRs stay squashed: one tidy commit each, and they carry no downstream mirror'
    }

    It 'rebase is never offered (it rewrites the shared history too)' {
        $script:MethodStep | Should -Not -Match 'flag=--rebase'
    }

    It 'ADR 0057 records the promotion ruling, not just the upstream one' {
        $adr = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'docs' 'adr' '0057-multi-environment-and-branch-model.md') -Raw
        $adr | Should -Match 'promotion PRs land as a \*\*merge commit\*\*' -Because 'the workflow enforces a ruling that must be written down, or the next person reads the automation as arbitrary'
        $adr | Should -Match 'merge-base --is-ancestor' -Because 'the ADR should record the observable symptom, so the reasoning can be re-checked rather than taken on faith'
    }
}
