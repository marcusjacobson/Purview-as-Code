#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    A JOB THAT READS A COMMIT-SCOPED GRAPHQL FIELD MUST DECLARE `contents: read`,
    AND THIS IS PROVEN AGAINST THE SHIPPED WORKFLOW, NOT RE-IMPLEMENTED.

    Issue #130. `pr-auto-merge.yml`'s `wait-for-merge` job polled until the PR
    reached MERGED and then read the merge SHA:

        gh pr view "$PR_NUMBER" --repo "$REPO" --json mergeCommit --jq '.mergeCommit.oid'

    `repository.pullRequest.mergeCommit` resolves a *commit* object, which the
    GITHUB_TOKEN cannot read under `pull-requests: read` alone. It failed with
    "Resource not accessible by integration (repository.pullRequest.mergeCommit)",
    and because the step runs under `set -euo pipefail` that abort took the whole
    job down -- AFTER a successful merge. `close-linked-issues` and
    `dispatch-affected-deploys` are both `needs`-gated on it, so both skipped.

    The failure mode is nearly invisible: the PR merges correctly and the only
    symptom is a red check on an already-merged PR. It survived from the day the
    job shipped until #130 -- every merge in that window silently forfeited both
    the linked-issue close (#73/#96) and the deploy dispatch (#95).

    This suite is a STATIC guard on the shipped artefact (same "test the
    committed artefact" reasoning as DriftDetectionPreflightGate.Tests.ps1 and
    EnvironmentRouting.Tests.ps1). It asserts the general rule rather than the
    single line, so a NEW job that reads a commit-scoped field is caught too, and
    it red-replays the defect against a synthetic fixture so the detection logic
    cannot itself go vacuous.

    Deliberately NOT asserted here: that the step tolerates a failed field read.
    That is a resilience change with its own test surface, kept out of #130 --
    see that issue's Out-of-scope section.

    References:
      #130 -- the defect under test
      #95  -- dispatch-affected-deploys, the job that consumes merge_sha
      #73 / #96 -- close-linked-issues, the other job gated on this one
      https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions
      https://docs.github.com/en/actions/concepts/security/github_token
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github/workflows/pr-auto-merge.yml'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    $script:Workflow = (Get-Content -LiteralPath $script:WorkflowPath -Raw) | ConvertFrom-Yaml

    # A commit-scoped read is any GraphQL/CLI access that resolves a commit object off the PR.
    # `mergeCommit` is the one in use today; `potentialMergeCommit` and `headRef...target` carry
    # the identical restriction, so they are matched now rather than after the next outage.
    $script:CommitScopedPattern = 'mergeCommit|potentialMergeCommit|\.target\.oid'

    # Returns the job ids that read a commit-scoped field WITHOUT declaring `contents: read`.
    # An empty result is the passing state. Takes a parsed workflow so the same logic can be
    # replayed against a synthetic fixture -- a detector that only ever sees green source is
    # indistinguishable from a detector that always returns nothing.
    function Get-CommitScopeViolation {
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Workflow)

        $violations = @()
        foreach ($jobId in $Workflow['jobs'].Keys) {
            $job = $Workflow['jobs'][$jobId]

            $runText = ($job['steps'] | ForEach-Object { [string]$_['run'] }) -join "`n"
            if ($runText -notmatch $script:CommitScopedPattern) { continue }

            $contents = if ($job.Contains('permissions') -and $job['permissions'] -is [System.Collections.IDictionary]) {
                [string]$job['permissions']['contents']
            } else { $null }

            if ($contents -notin @('read', 'write')) { $violations += $jobId }
        }
        return @($violations)
    }
}

Describe 'pr-auto-merge.yml -- commit-scoped reads carry contents: read (#130)' {

    It 'still denies by default at workflow scope' {
        $script:Workflow.Contains('permissions') | Should -BeTrue -Because 'each job must declare its own scopes; the fix must not be a workflow-wide grant'
        $script:Workflow['permissions'].Count | Should -Be 0 -Because 'permissions: {} is the deny-by-default baseline this workflow is built on'
    }

    It 'grants wait-for-merge contents: read' {
        $job = $script:Workflow['jobs']['wait-for-merge']
        $job | Should -Not -BeNullOrEmpty
        $job.Contains('permissions') | Should -BeTrue
        [string]$job['permissions']['contents'] | Should -BeExactly 'read' -Because 'reading repository.pullRequest.mergeCommit resolves a commit object, which pull-requests: read cannot see (#130)'
    }

    It 'keeps wait-for-merge least-privilege: no write scope of any kind' {
        $perms = $script:Workflow['jobs']['wait-for-merge']['permissions']
        foreach ($scope in $perms.Keys) {
            [string]$perms[$scope] | Should -Not -BeExactly 'write' -Because 'this job only polls and reads; the #130 fix must not become an over-grant'
        }
    }

    It 'flags no job in the shipped workflow' {
        $violations = Get-CommitScopeViolation -Workflow $script:Workflow
        $violations | Should -BeNullOrEmpty -Because "these jobs read a commit-scoped field without contents: read: $($violations -join ', ')"
    }

    It 'proves the merge SHA is load-bearing, so the field read cannot just be deleted' {
        # If this ever stops being true, the cheaper fix (drop the read) becomes available and
        # this whole permissions requirement should be revisited rather than carried forever.
        $dispatch = $script:Workflow['jobs']['dispatch-affected-deploys']
        $checkoutRefs = $dispatch['steps'] | ForEach-Object {
            if ($_.Contains('with') -and $_['with'] -is [System.Collections.IDictionary]) { [string]$_['with']['ref'] }
        }
        ($checkoutRefs -join "`n") | Should -Match 'wait-for-merge\.outputs\.merge_sha' -Because '#95 checks out the merge SHA to match changed files against each deploy workflow'
    }

    It 'keeps both downstream jobs gated on wait-for-merge' {
        foreach ($jobId in 'close-linked-issues', 'dispatch-affected-deploys') {
            @($script:Workflow['jobs'][$jobId]['needs']) | Should -Contain 'wait-for-merge' -Because 'the #130 blast radius came from these needs edges; if they are gone the guard is testing nothing'
        }
    }
}

Describe 'Non-vacuity -- the detector flags a synthetic violating fixture (red-replay)' {

    BeforeAll {
        # The defect exactly as it shipped: a commit-scoped read under pull-requests: read only.
        $script:BrokenFixture = @'
name: fixture
permissions: {}
jobs:
  wait:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: read
    steps:
      - run: gh pr view 1 --json mergeCommit --jq '.mergeCommit.oid'
'@ | ConvertFrom-Yaml

        # The same fixture, repaired.
        $script:FixedFixture = @'
name: fixture
permissions: {}
jobs:
  wait:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: read
      contents: read
    steps:
      - run: gh pr view 1 --json mergeCommit --jq '.mergeCommit.oid'
'@ | ConvertFrom-Yaml

        # A job that reads nothing commit-scoped is out of the rule's scope entirely and must
        # NOT be required to carry contents: read.
        $script:UnrelatedFixture = @'
name: fixture
permissions: {}
jobs:
  label:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - run: gh pr view 1 --json state --jq '.state'
'@ | ConvertFrom-Yaml
    }

    It 'flags the broken fixture (the defect under test)' {
        Get-CommitScopeViolation -Workflow $script:BrokenFixture | Should -Contain 'wait'
    }

    It 'passes the repaired fixture (positive control)' {
        Get-CommitScopeViolation -Workflow $script:FixedFixture | Should -BeNullOrEmpty
    }

    It 'does not require contents: read of a job that reads no commit-scoped field' {
        Get-CommitScopeViolation -Workflow $script:UnrelatedFixture | Should -BeNullOrEmpty
    }
}
