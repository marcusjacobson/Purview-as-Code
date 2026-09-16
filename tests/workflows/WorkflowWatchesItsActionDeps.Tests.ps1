#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    A workflow with a push path filter must watch the local actions it uses,
    and the repo modules those actions import (issue #317).

.DESCRIPTION
    Found the hard way. #316 changed `.github/actions/open-key-vault-firewall`
    and added `scripts/modules/KeyVaultFirewall.psm1`, both of which eleven
    workflows depend on -- and its merge triggered **no deploy run at all**,
    because not one path filter mentioned either. The change shipped with zero
    live signal, and the pull request had claimed the merge would exercise it.

    The quiet half is worse than the missed verification: a break in a shared
    action would not surface until some unrelated change next triggered one of
    those workflows, and it would then be attributed to that change.

    The rule is transitive on purpose. A workflow references the action; the
    action imports the module; the workflow must watch both. Checking only the
    direct reference would have passed this file on the very commit that
    prompted it.

    Both sides are DISCOVERED, never listed: local actions are found by
    scanning each workflow for `uses: ./.github/actions/<name>`, and module
    dependencies by scanning that action for `scripts/modules/<name>.psm1`. A
    twelfth workflow, or a second shared action, is covered without editing
    this file.

    Reference: https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions#onpushpull_requestpull_request_targetpathspaths-ignore
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'

    # Only workflows that actually filter on paths can miss a dependency this
    # way. A schedule- or dispatch-only workflow has nothing to declare.
    $script:PathFiltered = @(
        Get-ChildItem -LiteralPath $script:WorkflowsDir -Filter '*.yml' -File |
            Where-Object {
                $text = Get-Content -LiteralPath $_.FullName -Raw
                ($text -match '(?m)^\s+paths:') -and ($text -match 'uses: \./\.github/actions/')
            } |
            ForEach-Object { $_.Name }
    )
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'

    function Get-LocalActionReference {
        param([Parameter(Mandatory = $true)][string] $Text)
        return @([regex]::Matches($Text, 'uses:\s*\./\.github/actions/([A-Za-z0-9._-]+)') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique)
    }

    function Get-ActionModuleDependency {
        # Repo modules an action imports, so the transitive dependency is
        # discovered rather than assumed.
        param([Parameter(Mandatory = $true)][string] $ActionName)
        $actionPath = Join-Path $script:RepoRoot '.github' 'actions' $ActionName 'action.yml'
        if (-not (Test-Path -LiteralPath $actionPath)) { return @() }
        $text = Get-Content -LiteralPath $actionPath -Raw
        # Import-Module specifically: this action's header comment NAMES
        # scripts/modules/DirectionPolicy.psm1 while explaining the fan-out
        # trigger paths, and a bare mention is not a dependency. The first
        # draft of this scanner matched prose and demanded two workflows
        # watch a module they never load.
        return @([regex]::Matches($text, 'Import-Module[^\r\n]*scripts/modules/([A-Za-z0-9._-]+\.psm1)') |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object -Unique)
    }
}

Describe 'Path-filtered workflows watch their local action dependencies' {

    It 'finds at least one path-filtered workflow that uses a local action' {
        # Non-vacuity: if the discovery rule ever stops matching, every case
        # below would pass by finding nothing to check.
        $discovered = @(
            Get-ChildItem -LiteralPath $script:WorkflowsDir -Filter '*.yml' -File |
                Where-Object {
                    $text = Get-Content -LiteralPath $_.FullName -Raw
                    ($text -match '(?m)^\s+paths:') -and ($text -match 'uses: \./\.github/actions/')
                }
        )
        $discovered.Count | Should -BeGreaterThan 0
    }

    Context 'in <_>' -ForEach $script:PathFiltered {

        BeforeAll {
            $script:Text = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir $_) -Raw
            $script:Actions = Get-LocalActionReference -Text $script:Text
        }

        It 'references at least one local action' {
            $script:Actions.Count | Should -BeGreaterThan 0
        }

        It 'watches every local action it uses' {
            foreach ($action in $script:Actions) {
                $script:Text | Should -Match ([regex]::Escape(".github/actions/$action/")) `
                    -Because "a change to $action must trigger this workflow, or it ships with no run at all"
            }
        }

        It 'watches every repo module those actions import' {
            foreach ($action in $script:Actions) {
                foreach ($module in (Get-ActionModuleDependency -ActionName $action)) {
                    $script:Text | Should -Match ([regex]::Escape("scripts/modules/$module")) `
                        -Because "$action imports $module, so this workflow depends on it transitively"
                }
            }
        }
    }
}
