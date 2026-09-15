#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    A SKIPPED TENANT-TOUCHING RUN MUST NOT LOOK LIKE A VERIFIED ONE.

    Lab's scheduled `sync-labels-from-tenant` reported `success` on five
    consecutive days while doing nothing: its tenant-touching job is skipped
    every run by the ADR 0054 / ADR 0060 preflight, and the workflow then
    concludes green having checked nothing. Four labels of drift sat
    undetected behind those green ticks -- three of them referenced by name
    from lab's own label-policies.yaml, so a `-PruneMissing` run would have
    deleted them (issues #243, #245).

    The gate itself is correct and deliberate: ADR 0060 added
    `CI_DATA_PLANE_ENABLED` precisely so a governance-locked environment can
    silence its scheduled tenant calls, and it is expected to stay `false`
    on lab indefinitely. The gate is not the bug. The UNQUALIFIED GREEN TICK
    is: nothing distinguished "the tenant matches the repo" from "we never
    looked", and the second is indistinguishable from the first at a glance.

    This is the same shape as #231, where `upstream-delta-watch` failed every
    scheduled run for eight-plus weeks while the ledger silently went stale.
    The lesson recorded there: a check whose failure mode is "silently reads
    nothing" is indistinguishable from a check that passes. This is that
    shape one branch over -- a check whose SKIP mode is indistinguishable
    from a pass.

    WHAT THIS ENFORCES, and what it deliberately does not. GitHub gives a
    normal job no "neutral" conclusion, so a skipped run still concludes
    `success` in the run list and no workflow change can alter that. What it
    CAN do is make the run page state plainly what happened. So every
    preflight that can skip a tenant-touching job must:

      1. announce the skip as `::warning::`, not `::notice::` -- a warning
         raises an annotation on the run; a notice is easy to miss; and
      2. write a job summary saying the tenant was NOT contacted, so the run
         page cannot be read as a verification.

    Discovery is the same shape as the reconciler contract guard: any
    workflow carrying the `configured=false` preflight output is in scope
    automatically, so a future gated workflow is covered without editing
    this file.

    References:
      ADR 0054 (onboarding signal), ADR 0060 (CI_DATA_PLANE_ENABLED gate)
      https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowDir = Join-Path $script:RepoRoot '.github' 'workflows'

    # In scope: every workflow whose preflight can gate a tenant-touching
    # job off, identified by the output it writes. Same discovery-by-shape
    # approach the Deploy-*.ps1 contract guard uses.
    $script:Gated = @(Get-ChildItem -Path $script:WorkflowDir -Filter '*.yml' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'configured=false' })

    $script:SkipAnnouncementPattern = '::(notice|warning)::[^"]*skipping the tenant-touching job|::(notice|warning)::[^"]*skipping this scheduled tenant-touching run'
}

Describe 'A skipped tenant-touching run announces itself as unverified (#245)' {

    It 'discovery finds the gated workflows (non-vacuity)' {
        $script:Gated.Count | Should -BeGreaterThan 0 -Because 'if the preflight output string changes, every assertion below would pass by finding nothing'
        # 13 at the time of writing; asserted as a floor so adding a gated
        # workflow does not fail this, but silently losing most of them does.
        $script:Gated.Count | Should -BeGreaterOrEqual 10 -Because 'the gate is on the five deploy, five sync, and the drift/export/currency watch workflows'
    }

    It 'no gated workflow announces a tenant-touching skip with ::notice:: (it must be ::warning::)' {
        $offenders = @()
        foreach ($wf in $script:Gated) {
            $src = Get-Content -LiteralPath $wf.FullName -Raw
            $notices = @([regex]::Matches($src, '::notice::[^"]*skipping (the tenant-touching job|this scheduled tenant-touching run)'))
            if ($notices.Count -gt 0) { $offenders += ('{0} ({1})' -f $wf.Name, $notices.Count) }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            'a notice is easy to miss, so the run reads as a clean pass. These announce a skipped ' +
            'tenant-touching job at notice level: ' + ($offenders -join '; '))
    }

    It 'every gated workflow writes a NOT VERIFIED job summary on the skip path' {
        $offenders = @()
        foreach ($wf in $script:Gated) {
            $src = Get-Content -LiteralPath $wf.FullName -Raw
            $skips = @([regex]::Matches($src, 'configured=false')).Count
            $summaries = @([regex]::Matches($src, 'GITHUB_STEP_SUMMARY[^\r\n]*NOT VERIFIED')).Count
            if ($summaries -lt $skips) {
                $offenders += ('{0} ({1} skip path(s), {2} summary line(s))' -f $wf.Name, $skips, $summaries)
            }
        }
        $offenders | Should -BeNullOrEmpty -Because (
            'GitHub gives a normal job no neutral conclusion, so the run page summary is the only ' +
            'place a skipped run can say it verified nothing. Missing on: ' + ($offenders -join '; '))
    }

    It 'the skip summary does not claim the run verified anything (the overclaim this issue is about)' {
        # Caught in review of this very change: the first draft wrote
        # "Verified against the tenant" from the PREFLIGHT, which only decides
        # the job will run -- the job can still fail. Announcing verification
        # before verifying is the same defect in the opposite direction.
        foreach ($wf in $script:Gated) {
            $src = Get-Content -LiteralPath $wf.FullName -Raw
            $src | Should -Not -Match 'GITHUB_STEP_SUMMARY[^\r\n]*Verified against the tenant' -Because (
                "$($wf.Name): the preflight cannot know the tenant matched -- it only knows the job was allowed to start")
        }
    }
}
