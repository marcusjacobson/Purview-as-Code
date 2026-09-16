#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pins issue #274: every workflow that opens a pull request carrying
    re-exported TENANT state must validate that export before opening it.

.DESCRIPTION
    A pull request opened with the default GITHUB_TOKEN runs NO workflows --
    GitHub does not raise `pull_request` or `push` events for that token. So
    a drift-back PR gets no yamllint and, far more seriously, no ADR 0055
    identifier-residual scan, on content that is by construction a fresh
    `-ExportCurrentState` dump of live tenant state. The gate only ran after
    the merge, by which point a real tenant GUID would already be committed.

    Established by controlled comparison rather than inference: PR #257 on
    `auto/irm-drift-sync-lab`, opened with an operator's own token via
    `gh api`, got a `validate` run with 10 green jobs; PRs #260 and #262 on
    `auto/irm-portal-wins-drift-dev`, opened by the bot, each got a run with
    ZERO jobs, finalised `failure` when the PR closed.

    Three properties are load-bearing:

      1. Every producer runs `.github/actions/validate-driftback-export`
         BEFORE its create-pull-request step. After would be useless -- the
         point is that a bad export never becomes a PR.
      2. Every producer passes a pluggable token, so adding a
         `DRIFT_PR_TOKEN` secret later upgrades all of them at once with no
         edit. With no secret set the expression yields `github.token`, i.e.
         exactly today's behaviour.
      3. The composite action's yamllint invocation stays byte-identical to
         validate.yml's. Two copies of a linter invocation drift; this is the
         same lockstep guard the repo already applies to SKIP_NAMES_IRM
         across deploy-irm.yml and sync-irm-from-tenant.yml.

    The producer list is DISCOVERED, not hard-coded, so a tenth workflow that
    starts exporting tenant state is covered without editing this file.

    Reference: docs/adr/0055-identifier-shaped-residual-scan.md
    Reference: docs/adr/0029-source-of-truth-direction-policy.md
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:ActionPath   = Join-Path $script:RepoRoot '.github' 'actions' 'validate-driftback-export' 'action.yml'
    $script:ValidatePath = Join-Path $script:WorkflowsDir 'validate.yml'

    # docs-regen.yml opens PRs the same way but carries NO tenant data -- it
    # regenerates derived docs (ADR 0050). The residue risk this guard exists
    # for does not apply, so it is exempt by name and the exemption is asserted
    # below rather than left implicit.
    $script:ExemptProducers = @('docs-regen.yml')

    # DISCOVERY: any workflow that both opens a pull request and touches
    # data-plane/ in that PR is a tenant-state producer.
    $script:Producers = @(
        Get-ChildItem -LiteralPath $script:WorkflowsDir -Filter '*.yml' |
            Where-Object {
                $t = Get-Content -LiteralPath $_.FullName -Raw
                ($t -match 'uses:\s*peter-evans/create-pull-request@') -and
                ($t -match 'add-paths:\s*data-plane/')
            } |
            Where-Object { $_.Name -notin $script:ExemptProducers } |
            Sort-Object Name
    )
}

Describe 'Drift-back exports are validated before a pull request is opened (#274)' {

    It 'discovers the tenant-state producers, and finds a plausible number of them' {
        # Non-vacuity: a discovery that silently found nothing would make every
        # -ForEach assertion below pass by running zero times.
        $script:Producers.Count | Should -BeGreaterOrEqual 9 -Because 'five deploy-*.yml drift-back jobs and four sync-*-from-tenant.yml producers export tenant state'
    }

    It 'the composite action exists and is a composite action' {
        Test-Path -LiteralPath $script:ActionPath | Should -BeTrue
        (Get-Content -LiteralPath $script:ActionPath -Raw) | Should -Match 'using:\s*composite'
    }

    It 'exempts docs-regen.yml deliberately, and only because it carries no tenant data' {
        # If this ever starts writing data-plane/ the discovery above picks it
        # up and this exemption becomes wrong -- so assert the premise, not just
        # the exemption.
        $docsRegen = Join-Path $script:WorkflowsDir 'docs-regen.yml'
        Test-Path -LiteralPath $docsRegen | Should -BeTrue
        (Get-Content -LiteralPath $docsRegen -Raw) | Should -Not -Match 'add-paths:\s*data-plane/'
    }

    Context 'in <_>' -ForEach @( (Get-ChildItem -LiteralPath (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path '.github' 'workflows') -Filter '*.yml' |
                Where-Object {
                    $t = Get-Content -LiteralPath $_.FullName -Raw
                    ($t -match 'uses:\s*peter-evans/create-pull-request@') -and ($t -match 'add-paths:\s*data-plane/')
                } | Where-Object { $_.Name -ne 'docs-regen.yml' } | Sort-Object Name | ForEach-Object { $_.Name }) ) {

        BeforeAll {
            $script:Path = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path '.github' 'workflows' $_
            $script:Text = Get-Content -LiteralPath $script:Path -Raw
        }

        It 'runs the validate-driftback-export action' {
            $script:Text | Should -Match 'uses:\s*\./\.github/actions/validate-driftback-export'
        }

        It 'runs it BEFORE create-pull-request, not after' {
            # Ordering is the whole point: validating afterwards would leave a
            # bad export sitting in an open pull request that nothing checks.
            $validateAt = $script:Text.IndexOf('./.github/actions/validate-driftback-export')
            $cprAt      = $script:Text.IndexOf('uses: peter-evans/create-pull-request@')
            $validateAt | Should -BeGreaterThan 0
            $cprAt      | Should -BeGreaterThan 0
            $validateAt | Should -BeLessThan $cprAt
        }

        It 'passes a pluggable PR-author token that falls back to github.token' {
            $script:Text | Should -Match 'token:\s*\$\{\{\s*secrets\.DRIFT_PR_TOKEN\s*\|\|\s*github\.token\s*\}\}'
        }

        It 'still checks out the repository before the validation runs' {
            # The action runs ./scripts/Test-IdentifierResidue.ps1 and lints
            # data-plane/, so the working tree has to be there.
            $checkoutAt = $script:Text.IndexOf('uses: actions/checkout@')
            $validateAt = $script:Text.IndexOf('./.github/actions/validate-driftback-export')
            $checkoutAt | Should -BeGreaterThan 0
            $checkoutAt | Should -BeLessThan $validateAt
        }
    }
}

Describe 'The composite action stays in lockstep with validate.yml (#274)' {

    BeforeAll {
        $script:ActionText   = Get-Content -LiteralPath $script:ActionPath -Raw
        $script:ValidateText = Get-Content -LiteralPath $script:ValidatePath -Raw

        function Get-YamllintLine {
            param([Parameter(Mandatory)][string]$Text)
            $m = [regex]::Match($Text, '(?m)^\s*(yamllint\s+-d\s+.+)$')
            if (-not $m.Success) { throw 'No yamllint invocation found.' }
            return $m.Groups[1].Value.Trim()
        }
    }

    It 'runs a yamllint invocation byte-identical to validate.yml''s' {
        # Two copies of a linter invocation drift, and the drift is silent:
        # the export would be linted under different rules than the repo.
        $fromAction   = Get-YamllintLine -Text $script:ActionText
        $fromValidate = Get-YamllintLine -Text $script:ValidateText
        $fromAction | Should -BeExactly $fromValidate
    }

    It 'lints examples/ alongside data-plane/, as ADR 0056 requires' {
        Get-YamllintLine -Text $script:ActionText | Should -Match 'data-plane/ examples/$'
    }

    It 'runs the residue scan with -FailOnReview, matching validate.yml' {
        # Without -FailOnReview a Review row (an identifier of unresolved
        # provenance) passes silently in report mode -- which on an export of
        # live tenant state is exactly the case this guard exists for.
        $script:ActionText   | Should -Match 'Test-IdentifierResidue\.ps1 -FailOnReview'
        $script:ValidateText | Should -Match 'Test-IdentifierResidue\.ps1 -FailOnReview'
    }

    It 'surfaces the scan''s exit code rather than swallowing it' {
        $script:ActionText | Should -Match 'exit \$LASTEXITCODE'
    }

    It 'short-circuits when the export changed nothing, on the same condition the pull request uses' {
        # The reverse-sync workflows run daily whether or not the tenant
        # drifted, and create-pull-request no-ops on an unchanged tree. Gating
        # on `git status --porcelain -- data-plane/` keeps a quiet run cheap
        # without ever skipping a run that has something to check.
        $script:ActionText | Should -Match 'git status --porcelain -- data-plane/'
        $script:ActionText | Should -Match "changed=true"
        $script:ActionText | Should -Match "changed=false"
    }

    It 'gates EVERY gate step on that condition, so none can run unguarded or be skipped by accident' {
        # A gate step without the `if:` would run on every quiet day; a gate
        # step someone forgets to add it to would silently stop protecting the
        # export. Count them rather than trusting the eye.
        $gateSteps = @([regex]::Matches($script:ActionText, "(?m)^\s{4}- (name: (Install yamllint|Run yamllint|Install powershell-yaml|Test-IdentifierResidue)|if: steps\.changed)"))
        $guards    = @([regex]::Matches($script:ActionText, "if: steps\.changed\.outputs\.changed == 'true'"))
        # setup-python + yamllint install + yamllint + module install + scan.
        $guards.Count | Should -Be 5
    }

    It 'the lockstep check has teeth: a changed invocation is detected (red-replay)' {
        # Otherwise "the two strings are equal" is a claim two empty strings
        # would also satisfy.
        $mutated = $script:ActionText -replace 'line-length: disable', 'line-length: enable'
        $fromMutated = [regex]::Match($mutated, '(?m)^\s*(yamllint\s+-d\s+.+)$').Groups[1].Value.Trim()
        $fromValidate = [regex]::Match($script:ValidateText, '(?m)^\s*(yamllint\s+-d\s+.+)$').Groups[1].Value.Trim()
        $fromMutated | Should -Not -BeExactly $fromValidate
    }
}

Describe 'A failed validation must actually BLOCK the pull request (#274)' {

    # Run 4 (#277) proved the gate RUNS on a real export -- yamllint and the
    # ADR 0055 residue scan both executed in the drift-back job, and the scan
    # was separately proved to exit 1 with a line-accurate annotation on a
    # poisoned data-plane file. What neither proved is the link between those
    # two facts: that a non-zero exit actually stops the pull request.
    #
    # It does, by GitHub Actions' default semantics -- a failed step fails the
    # job, and a later step with no `if:` does not run. But that is a property
    # of what the workflows DO NOT say, and nothing was checking it. One
    # `continue-on-error: true` added for an unrelated reason would leave the
    # gate running, green, and completely inert: it would report the problem
    # and open the pull request anyway.

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:ProducerFiles = @(
            Get-ChildItem -LiteralPath (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path '.github' 'workflows') -Filter '*.yml' |
                Where-Object {
                    $t = Get-Content -LiteralPath $_.FullName -Raw
                    ($t -match 'uses:\s*peter-evans/create-pull-request@') -and ($t -match 'add-paths:\s*data-plane/')
                } | Where-Object { $_.Name -ne 'docs-regen.yml' } | Sort-Object Name)
    }

    It 'no producer lets the export validation fail softly, and none lets the PR step survive it' {
        $offenders = @()
        foreach ($f in $script:ProducerFiles) {
            $wf = (Get-Content -LiteralPath $f.FullName -Raw) | ConvertFrom-Yaml
            foreach ($jobName in $wf['jobs'].Keys) {
                $steps = @($wf['jobs'][$jobName]['steps'])
                if (-not ($steps | Where-Object { "$($_['uses'])" -like '*peter-evans/create-pull-request@*' })) { continue }

                $validate = @($steps | Where-Object { "$($_['uses'])" -like '*validate-driftback-export*' })[0]
                $pr       = @($steps | Where-Object { "$($_['uses'])" -like '*peter-evans/create-pull-request@*' })[0]

                # continue-on-error on the gate: it reports and proceeds anyway.
                if ($validate['continue-on-error']) { $offenders += "$($f.Name): validation carries continue-on-error" }
                # continue-on-error on the PR step does not un-block it, but an
                # `if:` does -- any condition at all can re-enable a step after
                # a failed one (if: always(), if: success() || ..., etc.).
                if ($pr['if']) { $offenders += "$($f.Name): create-pull-request carries an if: ($($pr['if']))" }
                if ($pr['continue-on-error']) { $offenders += "$($f.Name): create-pull-request carries continue-on-error" }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'the composite action does not swallow the scan''s exit code' {
        $action = (Get-Content -LiteralPath $script:ActionPath -Raw) | ConvertFrom-Yaml
        foreach ($step in @($action['runs']['steps'])) {
            $step['continue-on-error'] | Should -Not -BeTrue -Because "step '$($step['name'])' would let the gate pass while failing"
        }
    }

    It 'the guard has teeth: it flags a producer whose PR step could survive a failure (red-replay)' {
        # Without this, "no offenders" is a claim an empty producer list would
        # also satisfy, and the condition itself is never exercised.
        $synthetic = @{
            'jobs' = @{
                'drift-back-pr' = @{
                    'steps' = @(
                        @{ 'uses' = './.github/actions/validate-driftback-export'; 'continue-on-error' = $true }
                        @{ 'uses' = 'peter-evans/create-pull-request@abc'; 'if' = 'always()' }
                    )
                }
            }
        }
        $offenders = @()
        $steps = @($synthetic['jobs']['drift-back-pr']['steps'])
        $validate = @($steps | Where-Object { "$($_['uses'])" -like '*validate-driftback-export*' })[0]
        $pr       = @($steps | Where-Object { "$($_['uses'])" -like '*peter-evans/create-pull-request@*' })[0]
        if ($validate['continue-on-error']) { $offenders += 'validation carries continue-on-error' }
        if ($pr['if']) { $offenders += 'create-pull-request carries an if:' }
        $offenders.Count | Should -Be 2
    }
}
