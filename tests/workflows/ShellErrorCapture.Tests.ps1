#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    A FAILED COMMAND'S OUTPUT MUST NEVER BECOME A VALUE.

    Issue #137. `gh` writes the HTTP RESPONSE BODY to stdout even on an error, and the exit code
    is the only reliable signal that the call failed. Three sites discarded stderr and never
    checked that code, so a failed call was captured as data:

      - pr-owner-gate.yml  comment lookup   -> a 403 body became $EXISTING_ID, and the script
                                               PATCHed .../issues/comments/{"message":"Resource
                                               not accessible by integration"...}
      - pr-owner-gate.yml  check-run rollup -> `|| echo ""` looked like a guard but the body was
                                               already on stdout; a body matching neither grep
                                               fell through to checks_state=passing, reporting
                                               "all checks are passing" because the call FAILED
      - pr-auto-merge.yml  issue state      -> `|| echo UNKNOWN` produced "<body>\nUNKNOWN", which
                                               matches neither CLOSED nor UNKNOWN, so the UNKNOWN
                                               guard was skipped and the close path ran anyway

    The same root shape sank #124 on the PowerShell side: Write-Information under `pwsh -File`
    goes to STDOUT, so a progress notice landed ahead of the JSON and ConvertFrom-Json read 'I'.

    This suite asserts the RULE rather than the three instances, so the next command substitution
    that swallows a failure is caught when it is written:

      1. no `2>/dev/null` inside a command substitution in any gh-driven workflow;
      2. every gh read in the advisory workflow is guarded, not just the ones that swallow
         stderr -- a bare `VAR=$(gh ...)` aborts its whole step under `bash -e`;
      3. the comment id is shape-validated before it can reach a URL;
      4. the fallbacks are the SAFE ones (never `passing`);
      5. the advisory workflow serialises per PR, so its sticky comment is actually sticky.

    The PowerShell half of the same defect class -- #124, Write-Information reaching stdout under
    `pwsh -File` -- is asserted in tests/scripts/Get-UpstreamDelta.Tests.ps1 instead, because its
    subject is operator-tooling and absent from the template. This file ports; that one does not.

    Deliberately NOT asserted: validate-oidc-auth.yml's `az ... 2>/dev/null || true`. The Azure
    CLI writes errors to stderr, so that variable goes empty rather than corrupt, and its
    `${PRE_DA:-Allow}` default feeds Key Vault firewall RESTORE posture -- a security-behavior
    change that does not belong in a CI-hygiene sweep. See #137's "assessed and not changed".

    References:
      #137 -- the defect under test
      #124 -- the PowerShell-side instance of the same shape
      https://cli.github.com/manual/gh_api
      https://docs.github.com/en/actions/using-jobs/using-concurrency
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # Every `$( ... 2>/dev/null ... )` in a file's text. A redirect OUTSIDE a substitution is
    # fine -- it only silences a diagnostic. Inside one it silences the diagnostic while the
    # error body is still captured, which is the whole defect.
    function script:Get-SwallowedCapture {
        param([Parameter(Mandatory)][string]$Text)

        $hits = [System.Collections.Generic.List[string]]::new()
        # Substitutions here never nest, so a non-greedy span to the first ')' is sufficient and
        # avoids pretending to parse shell.
        foreach ($m in [regex]::Matches($Text, '\$\((?:[^()]|\([^()]*\))*?\)', 'Singleline')) {
            if ($m.Value -match '2>\s*/dev/null') { $hits.Add($m.Value) }
        }
        return @($hits)
    }
}

Describe 'No gh-driven workflow captures a failed command as data (#137)' {

    # Only the workflows that actually shell out to gh: they are the ones where a failure lands
    # on stdout as a JSON body rather than as nothing.
    It '<_> has no 2>/dev/null inside a command substitution' -ForEach @(
        'pr-owner-gate.yml'
        'pr-auto-merge.yml'
    ) {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' '.github/workflows' $_) -Raw
        $hits = Get-SwallowedCapture -Text $text
        $hits | Should -BeNullOrEmpty -Because "each of these captures a failed gh call as a value: $($hits -join ' | ')"
    }

    It 'pr-owner-gate.yml guards EVERY gh call, not just the ones that swallow stderr' {
        # The first cut of this fix guarded the rollup call and left the two `VAR=$(gh ...)` reads
        # above it bare. Steps run under `bash -e`, so a bare substitution aborts the whole step
        # on any failure -- on PR #138 a 503 on the head-SHA read killed the step before the
        # guarded code was ever reached. Guarding one call in a step and not the one above it
        # guards nothing, so the rule is per-call, not per-site.
        #
        # Scoped to this workflow deliberately. pr-auto-merge.yml has nine bare `$(gh ...)` reads
        # and they are RIGHT to fail hard: they are merge gates, and failing closed when the PR
        # state cannot be read is the safe outcome. This job only posts an advisory comment, so
        # its correct failure mode is to say nothing, never to red-check a healthy PR.
        $text = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir 'pr-owner-gate.yml') -Raw
        $bare = @([regex]::Matches($text, '(?m)^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(gh ') | ForEach-Object { $_.Value.Trim() })
        $bare | Should -BeNullOrEmpty -Because "each of these aborts its step under bash -e on a transient API failure: $($bare -join ' | ')"
    }

    It 'pr-owner-gate.yml shape-validates the comment id before building a URL' {
        $text = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir 'pr-owner-gate.yml') -Raw
        # Belt and braces: even if a future edit reintroduces a leak, a non-numeric value must not
        # reach .../issues/comments/<id>.
        $text | Should -Match "\*\[!0-9\]\*\)\s*EXISTING_ID=" -Because 'a comment id is all digits; anything else is an error blob'
    }

    It 'pr-owner-gate.yml degrades to running, never to passing, when the rollup cannot be read' {
        $text = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir 'pr-owner-gate.yml') -Raw
        $failureBranch = [regex]::Match($text, 'Could not read check runs.+?checks_state=(\w+)', 'Singleline')
        $failureBranch.Success | Should -BeTrue -Because 'the failure path must warn and set a state explicitly'
        $failureBranch.Groups[1].Value | Should -BeExactly 'running' -Because 'an unreadable rollup must never be reported to the owner as "all checks passing"'
    }

    It 'pr-auto-merge.yml only reaches its close path with a state it actually read' {
        $text = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir 'pr-auto-merge.yml') -Raw
        $text | Should -Match 'if ! ISSUE_STATE=\$\(gh issue view' -Because 'the UNKNOWN sentinel is only reachable if the failure is detected'
        $text | Should -Match 'ISSUE_STATE="UNKNOWN"'
    }

    It 'pr-owner-gate.yml serialises runs per PR so its sticky comment is actually sticky' {
        $wf = (Get-Content -LiteralPath (Join-Path $script:WorkflowsDir 'pr-owner-gate.yml') -Raw) | ConvertFrom-Yaml
        $wf.Contains('concurrency') | Should -BeTrue -Because 'opened and labeled fire together; both runs looked up, both found nothing, both created'
        [string]$wf['concurrency']['group'] | Should -Match 'pull_request\.number' -Because 'the group must be per PR, not global, or unrelated PRs cancel each other'
    }
}

# The #124 assertions that used to live here now sit in
# tests/scripts/Get-UpstreamDelta.Tests.ps1. They read scripts/Get-UpstreamDelta.ps1, which is
# operator-tooling and correctly absent from the public template -- so this file, which IS ported,
# could not pass there: `Cannot find path ... Get-UpstreamDelta.ps1`. A test may only assert about
# files that exist wherever the test itself ships. Its subject's suppression decides its home.

Describe 'Non-vacuity -- the detector flags the defect as it shipped (red-replay)' {

    It 'flags a substitution that discards stderr' {
        $broken = 'EXISTING_ID=$(gh api "repos/o/r/issues/1/comments" --jq ".[].id" 2>/dev/null | head -1)'
        Get-SwallowedCapture -Text $broken | Should -Not -BeNullOrEmpty
    }

    It 'flags the sentinel form too, which only looked like a guard' {
        $broken = 'CHECKS=$(gh api "repos/o/r/commits/x/check-runs" --jq ".[]" 2>/dev/null || echo "")'
        Get-SwallowedCapture -Text $broken | Should -Not -BeNullOrEmpty
    }

    It 'passes the repaired form (positive control)' {
        $fixed = 'if CHECKS=$(gh api "repos/o/r/commits/x/check-runs" --jq ".[]" 2>&1); then echo ok; fi'
        Get-SwallowedCapture -Text $fixed | Should -BeNullOrEmpty
    }

    It 'does not flag a redirect outside a substitution' {
        # Silencing a diagnostic on a command whose exit code IS checked is legitimate; the rule
        # is about capturing a failure as a value, not about stderr in general.
        $fine = 'grep -q needs-review labels.txt 2>/dev/null && echo yes'
        Get-SwallowedCapture -Text $fine | Should -BeNullOrEmpty
    }
}

Describe 'A non-zero exit that is a VALID OUTCOME must not abort its step (#154)' {

    # Third instance of one shape in this workflow pair, after #130 and #137: a step running
    # under `bash -e` where a command's non-zero exit is an expected result rather than an error,
    # so the failure kills the step before the code written to handle that result can run.
    #
    #   close-linked-issues:  ALL_ISSUES=$(... | grep -E '^[0-9]+$' | sort -un)
    #
    # grep exits 1 on no-match. The step declares `set -uo pipefail`, and GitHub invokes it as
    # `bash -e {0}`, so -e and pipefail combine: grep's status propagates through the pipeline,
    # the assignment fails, and the `-z "$ALL_ISSUES"` guard three lines below -- written for
    # exactly the no-linked-issues case -- is unreachable. Observed on PR #150, a docs-regen PR
    # that has no `Closes #N` by construction and would therefore have failed every week.
    #
    # NOTE for anyone reproducing this by hand: BOTH settings are required. Without pipefail the
    # pipeline reports `sort`'s status (0) and grep's failure is masked, which makes the defect
    # look nonexistent. That false negative cost a wrong "diagnosis cleared" once already.
    BeforeAll {
        $script:AutoMergeText = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' '.github/workflows/pr-auto-merge.yml') -Raw
    }

    It 'neutralises the no-match exit on the linked-issue collection' {
        $line = [regex]::Match($script:AutoMergeText, '(?m)^\s*ALL_ISSUES=.*$').Value
        $line | Should -Not -BeNullOrEmpty -Because 'the linked-issue collection must still exist'
        $line | Should -Match '\|\|\s*true\s*\)' -Because 'grep exits 1 on no-match, and under bash -e + pipefail that aborts the step before the empty-set guard can run (#154)'
    }

    It 'still has the empty-set guard the fix exists to make reachable' {
        # Neutralising the exit is only half of it: the guard must survive too, or an empty
        # result would fall through into the close loop instead of exiting cleanly.
        $script:AutoMergeText | Should -Match 'if \[ -z "\$ALL_ISSUES" \]; then' -Because 'the whole point is to reach this'
        $script:AutoMergeText | Should -Match 'has no linked closing issues'
    }

    It 'keeps pipefail on the step, so the guard is load-bearing rather than incidental' {
        # If pipefail were ever dropped the defect would vanish by accident, and the `|| true`
        # would look like cargo cult to the next reader. Pin the combination that makes it needed.
        $script:AutoMergeText | Should -Match 'set -uo pipefail'
    }
}
