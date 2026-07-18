#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    ADR 0054's SKIP GATE IS A REPO-WIDE INVARIANT, SO A REPO-WIDE TEST PINS IT.

    Issue #91 rolled the ADR 0054 skip-not-fail gate (piloted on
    drift-detection.yml, DriftDetectionPreflightGate.Tests.ps1) out to the
    remaining 12 tenant-touching workflows. This suite is the "stop workflow
    #14 from reintroducing the bug" regression guard the issue's own
    acceptance criteria require: it reads the SHIPPED YAML under
    .github/workflows/** (same "test the committed artefact" reasoning as
    EnvironmentRouting.Tests.ps1 / DriftDetectionPreflightGate.Tests.ps1) and
    asserts, GENERICALLY -- not by hardcoding "these 13 files" as the only
    truth -- that:

      - every workflow that BOTH (a) uses `azure/login` in some job AND
        (b) carries an automatic trigger (`schedule:` and/or `push:`) MUST
        declare a `preflight` job, and every job that calls `azure/login`
        in that workflow MUST declare `needs: preflight` plus the exact
        `if: needs.preflight.outputs.configured == 'true'` condition;
      - the discovered set of "must be gated" workflows matches the
        expected 13-workflow contract table below exactly (neither more
        nor fewer) -- so a new tenant-touching workflow added later without
        an explicit gating decision fails this suite immediately;
      - the 3 dispatch-only workflows (deploy-infra.yml,
        validate-oidc-auth.yml, kv-temp-unlock.yml) are confirmed to have
        NO automatic trigger today, i.e. they are correctly and
        deliberately exempt from ADR 0054 -- not merely absent from the
        gated list by omission. Because the applicability rule is generic
        (trigger shape + azure/login use, not a filename allow-list), if a
        future contributor adds a `schedule:` or `push:` trigger to one of
        these 3, the FIRST Describe block above starts requiring a
        preflight job on it automatically -- a deliberate decision point,
        not an accidental gate or an accidental exemption.

    The final Describe block is the non-vacuity proof for THIS suite's own
    detection logic: it red-replays the exact assertions above against a
    synthetic schedule-triggered, azure/login-calling workflow fixture that
    carries NO preflight job, and asserts the defect is caught -- then
    proves the positive case (a correctly gated synthetic fixture) also
    passes, so the suite is neither vacuous nor over-strict.

    References:
      ADR 0054 -- tenant-touching workflow skip gate (the contract under test)
      ADR 0057 -- multi-environment and branch model (environment expression reused by the gate)
      Issue #91 -- rollout scope, the "regression guard" acceptance criterion this file satisfies
      DriftDetectionPreflightGate.Tests.ps1 -- the per-workflow pilot guard this file generalizes
      https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability
      https://pester.dev/docs/quick-start
#>

BeforeDiscovery {
    # The 13 tenant-touching workflows ADR 0054 / issue #91 require to carry
    # the gate: the pilot (drift-detection.yml) plus the 12 rolled out here.
    # Adding a 14th tenant-touching workflow means adding a row here -- that
    # is the point: the gated set is reviewed, not silently inferred.
    $script:ExpectedGatedWorkflows = @(
        'drift-detection.yml'
        'code-currency-watch.yml'
        'export-content-explorer.yml'
        'sync-labels-from-tenant.yml'
        'sync-label-policies-from-tenant.yml'
        'sync-auto-label-policies-from-tenant.yml'
        'sync-dlp-from-tenant.yml'
        'sync-irm-from-tenant.yml'
        'deploy-labels.yml'
        'deploy-dlp.yml'
        'deploy-label-policies.yml'
        'deploy-auto-label-policies.yml'
        'deploy-irm.yml'
    )

    # The 3 workflows ADR 0054 / issue #91 deliberately leave ungated:
    # dispatch-only, so an operator invoking them deserves a real error, not
    # a silent skip.
    $script:ExpectedDispatchOnlyWorkflows = @(
        'deploy-infra.yml'
        'validate-oidc-auth.yml'
        'kv-temp-unlock.yml'
    )
}

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # BeforeDiscovery variables are discovery-phase only; re-bind them here
    # so run-phase It bodies that reference $script:ExpectedGatedWorkflows /
    # $script:ExpectedDispatchOnlyWorkflows directly (not via -ForEach) see
    # a populated value rather than $null.
    $script:ExpectedGatedWorkflows = @(
        'drift-detection.yml'
        'code-currency-watch.yml'
        'export-content-explorer.yml'
        'sync-labels-from-tenant.yml'
        'sync-label-policies-from-tenant.yml'
        'sync-auto-label-policies-from-tenant.yml'
        'sync-dlp-from-tenant.yml'
        'sync-irm-from-tenant.yml'
        'deploy-labels.yml'
        'deploy-dlp.yml'
        'deploy-label-policies.yml'
        'deploy-auto-label-policies.yml'
        'deploy-irm.yml'
    )
    $script:ExpectedDispatchOnlyWorkflows = @(
        'deploy-infra.yml'
        'validate-oidc-auth.yml'
        'kv-temp-unlock.yml'
    )

    function Get-TriggerBlock {
        # YAML 1.1 parses the bare key `on` as the BOOLEAN true, so a parsed
        # workflow's trigger block can sit under the key $true rather than
        # the string 'on'. Ported from EnvironmentRouting.Tests.ps1.
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Workflow)
        foreach ($key in $Workflow.Keys) {
            if ($key -is [bool] -and $key) { return $Workflow[$key] }
            if ([string]$key -eq 'on')     { return $Workflow[$key] }
        }
        return $null
    }

    function Test-HasAutomaticTrigger {
        # TRUE when the trigger block carries `schedule:` and/or `push:` --
        # the two ADR 0054 "fires without a human present" trigger shapes.
        # `workflow_dispatch` alone does NOT count: an operator invoking a
        # workflow by hand deserves a real error, not a silent skip.
        param($TriggerBlock)
        if ($null -eq $TriggerBlock) { return $false }
        if ($TriggerBlock -is [System.Collections.IDictionary]) {
            return ($TriggerBlock.Contains('schedule') -or $TriggerBlock.Contains('push'))
        }
        # `on: push` / `on: [push, schedule]` shorthand forms.
        if ($TriggerBlock -is [string]) { return $TriggerBlock -in @('schedule', 'push') }
        if ($TriggerBlock -is [System.Collections.IEnumerable]) {
            foreach ($t in $TriggerBlock) { if ([string]$t -in @('schedule', 'push')) { return $true } }
        }
        return $false
    }

    function Get-AzureLoginJobName {
        # Every job name in the workflow that carries a step whose `uses:`
        # starts with `azure/login` -- the exact "touches the tenant" signal
        # ADR 0054 gates on.
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Workflow)
        $names = [System.Collections.Generic.List[string]]::new()
        if (-not $Workflow.Contains('jobs')) { return $names }
        foreach ($jobName in $Workflow.jobs.Keys) {
            $job = $Workflow.jobs[$jobName]
            if ($job -isnot [System.Collections.IDictionary] -or -not $job.Contains('steps')) { continue }
            foreach ($step in $job['steps']) {
                if ($step -is [System.Collections.IDictionary] -and $step.Contains('uses') -and
                    [string]$step['uses'] -match '^azure/login') {
                    [void]$names.Add([string]$jobName)
                    break
                }
            }
        }
        return $names
    }

    function Test-JobHasPreflightGate {
        # TRUE only when the job declares BOTH needs: preflight AND the
        # exact ADR 0054 if: condition -- needs IS available in a job-level
        # if: (unlike secrets or environment-scoped vars), so this is the
        # only legal place to gate.
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Job)
        if (-not $Job.Contains('needs')) { return $false }
        if (@($Job['needs']) -notcontains 'preflight') { return $false }
        if (-not $Job.Contains('if')) { return $false }
        return ([string]$Job['if'] -eq "needs.preflight.outputs.configured == 'true'")
    }

    function Test-WorkflowRequiresGate {
        # The ADR 0054 applicability rule itself, generic and filename-free:
        # an automatic trigger PLUS at least one azure/login job means this
        # workflow touches the tenant unattended and must be gated.
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Workflow)
        $trigger = Get-TriggerBlock -Workflow $Workflow
        if (-not (Test-HasAutomaticTrigger -TriggerBlock $trigger)) { return $false }
        return (Get-AzureLoginJobName -Workflow $Workflow).Count -gt 0
    }

    function Get-WorkflowDocument {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $script:WorkflowsDir $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Workflow not found: $Name" }
        return (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
    }

    $script:AllWorkflowFiles = @(
        Get-ChildItem -Path $script:WorkflowsDir -Filter '*.yml' -File | Select-Object -ExpandProperty Name
    )
}

Describe 'ADR 0054 skip gate — every azure/login + automatic-trigger workflow is gated (issue #91 rollout)' {

    It 'every workflow named in the expected-gated contract table exists' -ForEach $script:ExpectedGatedWorkflows {
        Test-Path -LiteralPath (Join-Path $script:WorkflowsDir $_) |
            Should -BeTrue -Because "ADR 0054 / issue #91 names $_ as a tenant-touching workflow requiring the gate; if it was renamed, update this table in the same PR"
    }

    It 'discovers exactly the expected set of azure/login + automatic-trigger workflows — no more, no fewer' {
        $discovered = @(
            $script:AllWorkflowFiles | Where-Object {
                $wf = Get-WorkflowDocument -Name $_
                Test-WorkflowRequiresGate -Workflow $wf
            }
        ) | Sort-Object
        $expected = @($script:ExpectedGatedWorkflows) | Sort-Object

        $diff = Compare-Object -ReferenceObject $expected -DifferenceObject $discovered
        $diff | Should -BeNullOrEmpty -Because (
            'a workflow appearing on one side only means either a new tenant-touching workflow was added ' +
            'without an explicit ADR 0054 gating decision, or a previously gated workflow lost its automatic ' +
            "trigger or its azure/login step without updating this contract table. Diff: $($diff | Out-String)")
    }

    Context 'each gated workflow wires the preflight job correctly' {

        It '<_> declares a preflight job and gates every azure/login job via needs + if' -ForEach $script:ExpectedGatedWorkflows {
            $wf = Get-WorkflowDocument -Name $_

            $wf.jobs.Contains('preflight') | Should -BeTrue -Because (
                "$_ has an automatic trigger and calls azure/login; ADR 0054 requires the onboarding signal to be " +
                'evaluated in a dedicated preflight job, not a step-level or job-level if: on the tenant-touching job itself')

            $azureLoginJobs = @(Get-AzureLoginJobName -Workflow $wf)
            $azureLoginJobs.Count | Should -BeGreaterThan 0 -Because "$_ is expected to call azure/login in at least one job"

            foreach ($jobName in $azureLoginJobs) {
                $job = $wf.jobs[$jobName]
                Test-JobHasPreflightGate -Job $job | Should -BeTrue -Because (
                    "$_ job '$jobName' calls azure/login and must declare needs: preflight plus the exact " +
                    "if: needs.preflight.outputs.configured == 'true' (ADR 0054), so an un-onboarded copy skips " +
                    'this job cleanly instead of failing at azure/login')
            }
        }
    }
}

Describe 'ADR 0054 — the 3 dispatch-only workflows are deliberately NOT required to carry the gate (issue #91)' {

    It '<_> exists, calls azure/login, and carries no automatic (schedule/push) trigger' -ForEach $script:ExpectedDispatchOnlyWorkflows {
        Test-Path -LiteralPath (Join-Path $script:WorkflowsDir $_) | Should -BeTrue

        $wf = Get-WorkflowDocument -Name $_
        (Get-AzureLoginJobName -Workflow $wf).Count | Should -BeGreaterThan 0 -Because "$_ is a real Azure-acting workflow, just not automatically triggered"

        $trigger = Get-TriggerBlock -Workflow $wf
        Test-HasAutomaticTrigger -TriggerBlock $trigger | Should -BeFalse -Because (
            "$_ is dispatch-only by design (ADR 0054 / issue #91): an operator invoking it deliberately deserves a " +
            'real error, not a silent skip. Because the gate-applicability rule above is generic (trigger shape + ' +
            'azure/login use, not a filename allow-list), if a future change adds a schedule: or push: trigger to ' +
            'this file, the Describe block above will then REQUIRE a preflight job on it -- a deliberate decision ' +
            'point for whoever makes that change, not an accidental gate or an accidental exemption.')
    }

    It 'the dispatch-only set and the gated set are disjoint (no workflow is both required and exempt)' {
        $overlap = $script:ExpectedGatedWorkflows | Where-Object { $script:ExpectedDispatchOnlyWorkflows -contains $_ }
        $overlap | Should -BeNullOrEmpty
    }
}

Describe 'Non-vacuity — the detection logic itself flags a synthetic ungated workflow (red-replay)' {

    BeforeAll {
        # A minimal, syntactically valid workflow that DOES meet the ADR 0054
        # applicability rule (schedule trigger + an azure/login job) but
        # carries NO preflight job. If the functions under test cannot catch
        # this, every assertion in the Describe blocks above is vacuous.
        $script:SyntheticUngated = @'
name: synthetic-ungated-fixture
on:
  schedule:
    - cron: '0 0 * * *'
jobs:
  touch-tenant:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
'@ | ConvertFrom-Yaml

        # The same shape, but correctly wired with a preflight job -- a
        # positive control proving the suite does not reject everything.
        $script:SyntheticGated = @'
name: synthetic-gated-fixture
on:
  schedule:
    - cron: '0 0 * * *'
jobs:
  preflight:
    runs-on: ubuntu-latest
    outputs:
      configured: ${{ steps.check.outputs.configured }}
    steps:
      - id: check
        run: echo "configured=true" >> $GITHUB_OUTPUT
  touch-tenant:
    needs: preflight
    if: needs.preflight.outputs.configured == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
'@ | ConvertFrom-Yaml

        # A dispatch-only fixture (no schedule/push) that ALSO lacks a
        # preflight job -- proves the applicability rule correctly does NOT
        # demand a gate here, mirroring the 3 real dispatch-only workflows.
        $script:SyntheticDispatchOnly = @'
name: synthetic-dispatch-only-fixture
on:
  workflow_dispatch: {}
jobs:
  touch-tenant:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
'@ | ConvertFrom-Yaml
    }

    It 'flags the synthetic ungated fixture as requiring the gate' {
        Test-WorkflowRequiresGate -Workflow $script:SyntheticUngated | Should -BeTrue
    }

    It 'the synthetic ungated fixture has no preflight job, so it FAILS the wiring assertion (the defect under test)' {
        $script:SyntheticUngated.jobs.Contains('preflight') | Should -BeFalse -Because 'this is the exact regression shape the Describe blocks above must catch, not silently pass'
    }

    It 'the synthetic GATED fixture requires and satisfies the gate (positive control)' {
        Test-WorkflowRequiresGate -Workflow $script:SyntheticGated | Should -BeTrue
        $script:SyntheticGated.jobs.Contains('preflight') | Should -BeTrue

        $job = $script:SyntheticGated.jobs['touch-tenant']
        Test-JobHasPreflightGate -Job $job | Should -BeTrue
    }

    It 'the synthetic dispatch-only fixture does NOT require the gate (mirrors the 3 real exempt workflows)' {
        Test-WorkflowRequiresGate -Workflow $script:SyntheticDispatchOnly | Should -BeFalse
        (Get-AzureLoginJobName -Workflow $script:SyntheticDispatchOnly).Count | Should -BeGreaterThan 0 -Because 'it still calls azure/login -- only the automatic-trigger half of the applicability rule is false'
    }
}
