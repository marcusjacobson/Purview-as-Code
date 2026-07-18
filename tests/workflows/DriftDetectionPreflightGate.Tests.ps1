#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    THE ADR 0054 SKIP GATE IS PROVEN AGAINST THE SHIPPED WORKFLOW, NOT
    RE-IMPLEMENTED, SO A TEST READS THE REAL YAML.

    Issue #91 / ADR 0054 pilots a skip-not-fail gate on ONE tenant-touching
    workflow (drift-detection.yml) before the pattern rolls out to the
    remaining 12. The gate's whole point is that an un-onboarded template
    copy SKIPS the tenant-touching job instead of failing at azure/login --
    that behavior was proven empirically on a throwaway fork (two run URLs,
    skipped vs failed-past-preflight, in the PR that lands this file).

    This suite is the STATIC half of that proof: it reads the SHIPPED
    drift-detection.yml (same "test the committed artefact" reasoning as
    EnvironmentRouting.Tests.ps1 / SurfaceWatchAdditions.Tests.ps1) and
    asserts the wiring the empirical proof depends on can never silently
    regress:

      - the `preflight` job exists, binds the SAME canonical ADR 0057
        environment expression as `detect-drift`, maps `secrets` only
        through `env:` (never through `if:`, which cannot see secrets --
        see ADR 0054's context-availability research), and emits a
        `configured` output;
      - `detect-drift` declares `needs: preflight` and the exact
        `if: needs.preflight.outputs.configured == 'true'` condition;
      - the misplaced `KEY_VAULT_NAME` throw guard that used to live in the
        "Temporarily allow Key Vault public access" step is gone -- the
        signal is checked once, in preflight, not twice.

    This is a per-workflow regression guard for the PILOT only. The
    repo-wide static test asserting EVERY azure/login workflow with an
    automatic trigger carries this gate is rollout scope for the follow-up
    PR that closes #91 (see ADR 0054 "Ship shape").

    References:
      ADR 0054 -- tenant-touching workflow skip gate (the contract under test)
      ADR 0057 -- multi-environment and branch model (the environment expression reused here)
      https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability
      https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    $script:WorkflowPath = Join-Path $script:WorkflowsDir 'drift-detection.yml'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # The contract expression, byte for byte -- kept in lockstep with
    # ADR 0057 / EnvironmentRouting.Tests.ps1.
    $script:CanonicalEnvExpr = '${{ inputs.environment || (github.ref_name == ''dev'' && ''dev'' || ''lab'') }}'

    $script:RawYaml = Get-Content -LiteralPath $script:WorkflowPath -Raw
    $script:Workflow = $script:RawYaml | ConvertFrom-Yaml

    function Get-JobRunText {
        param(
            [Parameter(Mandatory)][System.Collections.IDictionary]$Job,
            [Parameter(Mandatory)][string]$StepName
        )
        foreach ($step in $Job['steps']) {
            if ($step['name'] -eq $StepName) { return [string]$step['run'] }
        }
        return $null
    }
}

Describe 'drift-detection.yml preflight gate is wired correctly (ADR 0054 pilot, #91)' {

    It 'defines both a preflight job and a detect-drift job' {
        $script:Workflow.jobs.Contains('preflight')    | Should -BeTrue -Because 'ADR 0054 evaluates the onboarding signal in a dedicated job, not a step-level or job-level if: on the tenant-touching job'
        $script:Workflow.jobs.Contains('detect-drift') | Should -BeTrue -Because 'the existing tenant-touching job must be preserved, only gated'
    }

    Context 'preflight job' {

        BeforeAll {
            $script:Preflight = $script:Workflow.jobs['preflight']
        }

        It 'binds the SAME canonical ADR 0057 environment expression as detect-drift' {
            $script:Preflight.Contains('environment') | Should -BeTrue -Because 'the secret preflight tests must be scoped to the exact environment detect-drift would use'
            [string]$script:Preflight['environment'] | Should -BeExactly $script:CanonicalEnvExpr -Because 'a hardcoded "lab" would test the wrong environment on a dev dispatch (ADR 0057)'
        }

        It 'declares an outputs.configured mapped from a step output' {
            $script:Preflight.Contains('outputs') | Should -BeTrue
            [string]$script:Preflight['outputs']['configured'] | Should -Match 'steps\.check\.outputs\.configured' -Because 'detect-drift reads needs.preflight.outputs.configured'
        }

        It 'maps secrets.AZURE_CLIENT_ID and vars.KEY_VAULT_NAME through env:, never through if:' {
            $script:Preflight.Contains('env') | Should -BeTrue -Because 'secrets are only legal in jobs.<job_id>.env, run, or with -- never in any if: (ADR 0054 context-availability research)'
            [string]$script:Preflight['env']['AZURE_CLIENT_ID'] | Should -Match 'secrets\.AZURE_CLIENT_ID'
            [string]$script:Preflight['env']['KEY_VAULT_NAME']  | Should -Match 'vars\.KEY_VAULT_NAME'
            if ($script:Preflight.Contains('if')) {
                [string]$script:Preflight['if'] | Should -Not -Match 'secrets\.' -Because 'secrets is not an available context in jobs.<job_id>.if'
            }
        }

        It 'declares least-privilege permissions (contents: read only, no id-token)' {
            $script:Preflight.Contains('permissions') | Should -BeTrue -Because 'preflight never calls azure/login and does not need id-token: write'
            $script:Preflight['permissions'].Contains('id-token') | Should -BeFalse -Because 'least privilege: preflight only reads a secret value, it never mints an OIDC token'
        }

        It 'tests both signals in its check step and emits configured=true only when both are present' {
            $runText = Get-JobRunText -Job $script:Preflight -StepName 'Check onboarding signal'
            $runText | Should -Not -BeNullOrEmpty -Because 'the onboarding-signal check step must exist and be named for discoverability'
            $runText | Should -Match 'AZURE_CLIENT_ID'
            $runText | Should -Match 'KEY_VAULT_NAME'
            $runText | Should -Match 'configured=false'
            $runText | Should -Match 'configured=true'
        }
    }

    Context 'detect-drift job' {

        BeforeAll {
            $script:DetectDrift = $script:Workflow.jobs['detect-drift']
        }

        It 'declares needs: preflight' {
            @($script:DetectDrift['needs']) | Should -Contain 'preflight' -Because 'ADR 0054: needs IS available in a job-level if:, unlike secrets or environment-scoped vars'
        }

        It 'declares if: needs.preflight.outputs.configured == ''true''' {
            $script:DetectDrift.Contains('if') | Should -BeTrue
            [string]$script:DetectDrift['if'] | Should -BeExactly "needs.preflight.outputs.configured == 'true'"
        }

        It 'still binds the canonical ADR 0057 environment expression (unchanged by this PR)' {
            [string]$script:DetectDrift['environment'] | Should -BeExactly $script:CanonicalEnvExpr -Because 'ADR 0054 adds a gating job in FRONT of the existing routing logic; it must not alter how the target environment is selected'
        }

        It 'no longer throws on a missing KEY_VAULT_NAME in the Key Vault open step (folded into preflight)' {
            $runText = Get-JobRunText -Job $script:DetectDrift -StepName 'Temporarily allow Key Vault public access'
            $runText | Should -Not -BeNullOrEmpty
            $runText | Should -Not -Match 'throw' -Because 'the misplaced throw guard (previously step 5, unreachable behind the azure/login failure) is removed -- the same signal is now checked once, in preflight, with the correct skip verb'
        }
    }
}
