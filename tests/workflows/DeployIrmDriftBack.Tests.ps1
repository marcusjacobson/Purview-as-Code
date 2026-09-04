#Requires -Version 7.4
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }
<#
.SYNOPSIS
    Pins the deploy-irm.yml two-pass portal-wins + drift-back PR contract (#177).

.DESCRIPTION
    IRM gained -ExportCurrentState, so deploy-irm.yml grew the same shape
    deploy-dlp.yml carries: an enumerate pass that derives a skip set from
    [ADR0029-SKIP] markers, a re-export, and a drift-back PR job. Several
    properties of that shape are load-bearing and easy to break silently:

      1. The enumerate pass must NOT pass -SkipNames. The ADR 0036 baseline
         names emit skip markers exactly as drifted objects do, so folding
         them in would make every run look like it had drift.
      2. The apply pass must pass the UNION of the baseline and the
         drift-derived set.
      3. The drift-back job must carry no azure/login and no `environment:`,
         or it auto-appears in TenantTouchingWorkflowGate.Tests.ps1's
         discovery and in EnvironmentRouting.Tests.ps1's canonical-expression
         sweep (the sync-dlp-from-tenant.yml fanout-dev precedent).
      4. The PR body must tell the reviewer to CLOSE the PR when the YAML
         side is intended, before it tells them anything else. Getting this
         wrong cost the DLP surface two silent reverts in one day
         (#170 and #172).

    Reference: docs/adr/0029-source-of-truth-direction-policy.md
    Reference: docs/adr/0036-irm-tenant-setting-immovable.md
#>

Describe 'deploy-irm.yml two-pass portal-wins and drift-back PR contract (#177)' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:WorkflowPath = Join-Path $PSScriptRoot ".." ".." ".github" "workflows" "deploy-irm.yml"
        Test-Path -LiteralPath $script:WorkflowPath | Should -BeTrue
        $script:Raw = Get-Content -LiteralPath $script:WorkflowPath -Raw
        $script:Wf = $script:Raw | ConvertFrom-Yaml

        function Get-IrmStep {
            param([string]$JobName, [string]$NamePattern)
            return @($script:Wf.jobs[$JobName].steps | Where-Object { [string]$_.name -like $NamePattern })[0]
        }
    }

    Context 'job topology' {

        It 'declares exactly the expected job set' {
            @($script:Wf.jobs.Keys | Sort-Object) | Should -Be @('apply', 'drift-back-pr', 'preflight')
        }

        It 'the apply job exposes skip_count and direction_policy outputs' {
            $outputs = $script:Wf.jobs['apply'].outputs
            $outputs.Keys | Should -Contain 'skip_count'
            $outputs.Keys | Should -Contain 'direction_policy'
        }

        It 'skip_count falls back to 0 so the drift-back gate is never ambiguous' {
            # The enumerate step does not run under audit / repo-wins, leaving the
            # output unset; without the fallback the `if:` compares against ''.
            [string]$script:Wf.jobs['apply'].outputs['skip_count'] | Should -Match "\|\|\s*'0'"
        }

        It 'the drift-back job runs only on a successful portal-wins run that skipped something' {
            $cond = [string]$script:Wf.jobs['drift-back-pr']['if']
            $cond | Should -Match "needs\.apply\.result\s*==\s*'success'"
            $cond | Should -Match "needs\.apply\.outputs\.direction_policy\s*==\s*'portal-wins'"
            $cond | Should -Match "needs\.apply\.outputs\.skip_count\s*!=\s*'0'"
        }
    }

    Context 'the enumerate pass derives the skip set without the baseline' {

        It 'runs only under portal-wins' {
            $step = Get-IrmStep -JobName 'apply' -NamePattern 'Enumerate skipped objects*'
            $step | Should -Not -BeNullOrEmpty
            [string]$step['if'] | Should -Match "IRM_DIRECTION_POLICY\s*==\s*'portal-wins'"
        }

        It 'invokes the reconciler read-only with portal-wins, never audit' {
            # The audit short-circuit runs BEFORE the ADR 0029 skip pass, so an
            # audit run emits no markers at all.
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Enumerate skipped objects*').run
            $run | Should -Match '-DirectionPolicy portal-wins'
            $run | Should -Match '-WhatIf'
            $run | Should -Not -Match '-DirectionPolicy audit'
        }

        It 'does NOT pass -SkipNames, so its markers stay purely drift-derived' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Enumerate skipped objects*').run
            $run | Should -Not -Match '-SkipNames' -Because 'ADR 0036 baseline names emit skip markers too; including them would make every run report drift'
        }

        It 'parses the exact ADR 0029 marker format, case-sensitively' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Enumerate skipped objects*').run
            $run | Should -Match '\^\\\[ADR0029-SKIP\\\] \(\.\+\)\$'
            $run | Should -Match '-CaseSensitive'
        }

        It 'emits both skip_count and skip_names_json' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Enumerate skipped objects*').run
            $run | Should -Match 'skip_count='
            $run | Should -Match 'skip_names_json='
        }
    }

    Context 'the apply pass unions the baseline with the drift set' {

        It 'reads both the static baseline and the enumerate output' {
            $step = Get-IrmStep -JobName 'apply' -NamePattern 'Apply IRM policies*'
            $step.env.Keys | Should -Contain 'SKIP_NAMES_IRM'
            $step.env.Keys | Should -Contain 'SKIP_NAMES_JSON'
        }

        It 'combines them and deduplicates rather than replacing one with the other' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Apply IRM policies*').run
            $run | Should -Match 'Sort-Object -Unique'
            $run | Should -Match "\@\(\@\(\`$baseline\) \+ \@\(\`$drift\)"
        }

        It 'binds -Confirm:$false, as the CI-hang scan requires of every gated reconciler' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Apply IRM policies*').run
            $run | Should -Match "Confirm\s*=\s*\`$false"
        }
    }

    Context 're-export and artifact hand-off' {

        It 're-exports only when the enumerate pass found something' {
            $step = Get-IrmStep -JobName 'apply' -NamePattern 'Re-export tenant IRM policies*'
            $step | Should -Not -BeNullOrEmpty
            $cond = [string]$step['if']
            $cond | Should -Match "steps\.enumerate\.outputs\.skip_count != '0'"
            $cond | Should -Match "IRM_DIRECTION_POLICY == 'portal-wins'"
        }

        It 're-export passes -ExportCurrentState -Force at the tracked path' {
            $run = [string](Get-IrmStep -JobName 'apply' -NamePattern 'Re-export tenant IRM policies*').run
            $run | Should -Match '-ExportCurrentState'
            $run | Should -Match '-Force'
            $run | Should -Match 'data-plane/irm/policies\.yaml'
        }

        It 'uploads and downloads the artifact under the same run-scoped name' {
            $up = Get-IrmStep -JobName 'apply' -NamePattern 'Upload drift-back YAML*'
            $down = Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Download drift-back YAML*'
            $up.with['name'] | Should -Be 'irm-policies-drift-back-${{ github.run_id }}'
            $down.with['name'] | Should -Be $up.with['name']
            $up.with['if-no-files-found'] | Should -Be 'error'
        }
    }

    Context 'the drift-back job stays invisible to the tenant-touching contract tables' {

        It 'declares no job-level environment' {
            # EnvironmentRouting.Tests.ps1 sweeps EVERY job's environment: and
            # requires the canonical expression; declaring none is the other
            # legal option and the one the fanout-dev precedent uses.
            $script:Wf.jobs['drift-back-pr'].Keys | Should -Not -Contain 'environment'
        }

        It 'calls no azure/login, so it is not discovered as tenant-touching' {
            $uses = @($script:Wf.jobs['drift-back-pr'].steps | ForEach-Object { [string]$_.uses })
            @($uses | Where-Object { $_ -match '^azure/login' }) | Should -BeNullOrEmpty
        }

        It 'requests exactly the permissions the PR action needs, and no more' {
            $perms = $script:Wf.jobs['drift-back-pr'].permissions
            @($perms.Keys | Sort-Object) | Should -Be @('contents', 'pull-requests')
            $perms['contents'] | Should -Be 'write'
            $perms['pull-requests'] | Should -Be 'write'
        }

        It 'pins the create-pull-request action by commit SHA' {
            $step = Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Open or update drift-back PR*'
            [string]$step.uses | Should -Match '^peter-evans/create-pull-request@[0-9a-f]{40}$'
        }
    }

    Context 'branch and base routing' {

        It 'scopes the drift-back branch to the environment via the canonical expression' {
            $step = Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Open or update drift-back PR*'
            [string]$step.with['branch'] |
                Should -Be "auto/irm-portal-wins-drift-`${{ inputs.environment || (github.ref_name == 'dev' && 'dev' || 'lab') }}"
        }

        It 'targets the branch the run came from' {
            $step = Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Open or update drift-back PR*'
            [string]$step.with['base'] | Should -Be '${{ github.ref_name }}'
        }

        It 'uses a branch name distinct from the scheduled reverse-sync leg' {
            # The two mechanisms must never contend for one PR.
            $branch = [string](Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Open or update drift-back PR*').with['branch']
            $branch | Should -Match '^auto/irm-portal-wins-drift-'
            $branch | Should -Not -Match 'drift-sync'
        }
    }

    Context 'the PR body leads with the close-not-merge rule' {

        BeforeAll {
            $script:Body = [string](Get-IrmStep -JobName 'drift-back-pr' -NamePattern 'Open or update drift-back PR*').with['body']
        }

        It 'tells the reviewer to CLOSE the PR when the YAML side is intended' {
            $script:Body | Should -Match 'CLOSE this PR'
            $script:Body | Should -Match 'silently reverts'
        }

        It 'puts the close-when-YAML-is-intended case before the merge case' {
            # Order is the whole point: the DLP body buried this and both #170
            # and #172 were merged reflexively.
            $closeIdx = $script:Body.IndexOf('CLOSE this PR')
            $mergeIdx = $script:Body.IndexOf('merge this PR')
            $closeIdx | Should -BeGreaterThan 0
            $mergeIdx | Should -BeGreaterThan $closeIdx
        }

        It 'prescribes the tenant-write-first ordering for the repo-wins case' {
            $script:Body | Should -Match 'locally first'
            $script:Body | Should -Match 'codify PR second'
        }

        It 'does not repeat the DLP body''s stale reference to a main branch' {
            # ADR 0057: the operator repo has no main branch.
            $script:Body | Should -Not -Match 'push run on `main`'
        }

        It 'warns that the residue scan cannot see non-GUID identities' {
            $script:Body | Should -Match 'GUID-shaped only'
        }

        It 'names the IRM-specific review points' {
            $script:Body | Should -Match 'IRM_Tenant_Setting_'
            $script:Body | Should -Match 'Blocked'
        }
    }
}
