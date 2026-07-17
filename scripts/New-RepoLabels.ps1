#Requires -Version 7.4
<#
.SYNOPSIS
    Seed the GitHub labels this repository's automation depends on (idempotent).

.DESCRIPTION
    GitHub's "Use this template" does NOT copy labels, so every spin-off
    repository starts with the label-driven automation dormant:

      * pr-auto-merge.yml (and the @owner-approval agent) gate the merge
        on the `owner-approved` label -- observed live downstream as
        "'owner-approved' not found" at merge time.
      * pr-owner-gate.yml and @idea-intake key on `needs-review`.
      * The pre-commit checklist requires `destructive` on destructive PRs.
      * issue-triage.yml routes on the five `squad:*` labels.
      * The watch loops file issues under `code-currency`, `surface-watch`,
        and `watch-list`; drift issues carry `drift-detected`.

    Some workflows self-seed their own labels at run time (issue-triage,
    idea-intake-autoadd, code-currency-watch, watch-list-review, the
    sync-*-from-tenant drift steps); this script is the one-shot
    kickoff-time superset so no label is missing the FIRST time each
    automation fires -- including `owner-approved`, `destructive`, and
    `surface-watch`, which nothing self-seeds today.

    Creates ONLY missing labels. It never rewrites an existing label's
    color or description, so operator customizations survive re-runs
    (same create-only-missing idiom as the sync-*-from-tenant steps).

    References:
      Template repos do not copy labels:
        https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template
      gh label create / list:
        https://cli.github.com/manual/gh_label_create
        https://cli.github.com/manual/gh_label_list

.PARAMETER Repo
    Target repository as `owner/name`. When omitted, gh resolves the
    repository from the current directory's git remotes.

.EXAMPLE
    ./scripts/New-RepoLabels.ps1 -WhatIf

    Lists which labels would be created, without creating anything.

.EXAMPLE
    ./scripts/New-RepoLabels.ps1

    Seeds every missing label in the current repository. Re-running is a
    no-op once all labels exist.

.NOTES
    Requires an authenticated GitHub CLI (`gh auth login`) with push
    access to the target repository (label creation needs write access).
    Imperative primitive, not a reconciler -- the four-switch
    `Deploy-*.ps1` contract does not apply.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$')]
    [string]$Repo
)

$ErrorActionPreference = 'Stop'

#region Helpers (AST-extractable for unit tests)

# The full label set the automation depends on. Colors and descriptions
# match the run-time self-seeding steps where one exists
# (idea-intake-autoadd.yml, issue-triage.yml, code-currency-watch.yml,
# watch-list-review.yml, sync-*-from-tenant.yml) so double-seeding stays
# consistent; labels nothing self-seeds (`owner-approved`, `destructive`,
# `surface-watch`) are declared here for the first time. Pure function;
# tests AST-extract it and compare it against the label tokens the
# workflows actually reference.
function Get-RequiredLabel {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{ Name = 'needs-review'; Color = 'fbca04'; Description = 'Awaiting lab-owner review before merge' }
        [pscustomobject]@{ Name = 'owner-approved'; Color = '0e8a16'; Description = 'Lab owner approved; pr-auto-merge enables auto-merge' }
        [pscustomobject]@{ Name = 'merge-commit'; Color = 'c5def5'; Description = 'pr-auto-merge lands the PR as a merge commit, not squash (shared-history / upstream sync)' }
        [pscustomobject]@{ Name = 'destructive'; Color = 'd93f0b'; Description = 'PR deletes or prunes existing state; rollback plan + qualified review required' }
        [pscustomobject]@{ Name = 'drift-detected'; Color = 'b60205'; Description = 'Drift detected between desired-state YAML and the live tenant' }
        [pscustomobject]@{ Name = 'code-currency'; Color = '1d76db'; Description = 'Code-currency watch loop finding (Slice 12)' }
        [pscustomobject]@{ Name = 'surface-watch'; Color = '006b75'; Description = 'Surface-watch loop finding (new Learn surface inventory drift)' }
        [pscustomobject]@{ Name = 'watch-list'; Color = '5319e7'; Description = 'Watch-list re-open-trigger review loop finding (#725)' }
        [pscustomobject]@{ Name = 'squad:lead-architect'; Color = '0075ca'; Description = 'Routed to Lead Architect persona' }
        [pscustomobject]@{ Name = 'squad:security-specialist'; Color = 'e4e669'; Description = 'Routed to Security Specialist persona' }
        [pscustomobject]@{ Name = 'squad:automation-engineer'; Color = '0052cc'; Description = 'Routed to Automation Engineer persona' }
        [pscustomobject]@{ Name = 'squad:tester-validator'; Color = '5319e7'; Description = 'Routed to Tester/Validator persona' }
        [pscustomobject]@{ Name = 'squad:scribe'; Color = 'bfd4f2'; Description = 'Routed to Scribe persona' }
    )
}

#endregion

#region Preflight

$ghCmd = Get-Command -Name 'gh' -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Write-Error 'The GitHub CLI (gh) is required. Install it (https://cli.github.com/) and run `gh auth login` before invoking this script.'
    return
}

$repoArgs = @()
if ($Repo) { $repoArgs = @('--repo', $Repo) }

# Reference: https://cli.github.com/manual/gh_label_list
$existingJson = gh label list --limit 200 --json name --jq '.[].name' @repoArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error 'gh label list failed. Verify gh is authenticated (`gh auth status`) and the target repository is reachable.'
    return
}
$existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($existingJson)) {
    if ($name) { [void]$existingSet.Add([string]$name) }
}

#endregion

#region Seed

$created = 0
$skipped = 0
foreach ($label in Get-RequiredLabel) {
    if ($existingSet.Contains($label.Name)) {
        Write-Information ("  = Label '{0}' already exists; skipping (color/description left untouched)." -f $label.Name) -InformationAction Continue
        $skipped++
        continue
    }
    if ($PSCmdlet.ShouldProcess("label '$($label.Name)'", 'Create GitHub label')) {
        # Reference: https://cli.github.com/manual/gh_label_create
        gh label create $label.Name --color $label.Color --description $label.Description @repoArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error ("gh label create failed for '{0}' with exit code {1}. Fix the failure and re-run; the script is idempotent." -f $label.Name, $LASTEXITCODE)
            return
        }
        Write-Information ("  + Created label '{0}'." -f $label.Name) -InformationAction Continue
        $created++
    }
}

Write-Information '' -InformationAction Continue
Write-Information ("Done. Created: {0}. Already present: {1}. Total required: {2}." -f $created, $skipped, @(Get-RequiredLabel).Count) -InformationAction Continue

#endregion
