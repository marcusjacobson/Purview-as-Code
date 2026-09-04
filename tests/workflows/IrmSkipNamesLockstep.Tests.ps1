# Regression test for a defect fixed alongside this test: sync-irm-from-tenant.yml's
# SKIP_NAMES_IRM env line had no `||` fallback, so the daily `schedule` trigger (where
# `inputs.*` is unset) ran the post-filter against an empty skip set and reported the
# four ADR 0036 baseline policies as false drift every day. deploy-irm.yml already
# carried the correct fallback pattern for its own SKIP_NAMES_IRM env line. Both
# workflows' header comments claim a "TWO-way byte-lockstep" between their
# skip_names_irm input defaults and, in deploy-irm.yml's case, its own env fallback.
# This test pins all three literals so the lockstep claim stays true and the empty-set
# regression cannot silently return.

Describe 'IRM skip_names baseline stays in byte-lockstep across both workflows (fix for the empty-skip-set schedule regression)' {

    BeforeAll {
        $script:WorkflowsDir = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'

        function Get-WorkflowRawText {
            param([Parameter(Mandatory)][string]$Name)
            $path = Join-Path $script:WorkflowsDir $Name
            if (-not (Test-Path -LiteralPath $path)) { throw "Workflow not found: $Name" }
            return Get-Content -LiteralPath $path -Raw
        }

        $script:ExpectedBaseline = 'IRM Lab — Data leaks by priority users,IRM Lab — Data theft by departing users,IRM Lab — General data leaks,IRM Lab — Risky AI usage'
        $script:DeployText = Get-WorkflowRawText -Name 'deploy-irm.yml'
        $script:SyncText   = Get-WorkflowRawText -Name 'sync-irm-from-tenant.yml'
    }

    It 'deploy-irm.yml declares the skip_names_irm workflow_dispatch input default as the expected baseline' {
        $script:DeployText | Should -Match ([regex]::Escape("default: '$script:ExpectedBaseline'"))
    }

    It 'deploy-irm.yml SKIP_NAMES_IRM env carries a || fallback to the expected baseline' {
        $pattern = "SKIP_NAMES_IRM:\s*\`$\{\{\s*github\.event\.inputs\.skip_names_irm\s*\|\|\s*'" + [regex]::Escape($script:ExpectedBaseline) + "'\s*\}\}"
        $script:DeployText | Should -Match $pattern
    }

    It 'sync-irm-from-tenant.yml declares the skip_names_irm workflow_dispatch input default as the expected baseline' {
        $script:SyncText | Should -Match ([regex]::Escape("default: '$script:ExpectedBaseline'"))
    }

    It 'sync-irm-from-tenant.yml SKIP_NAMES_IRM env carries a || fallback to the expected baseline — the regression this test guards' {
        $pattern = "SKIP_NAMES_IRM:\s*\`$\{\{\s*inputs\.skip_names_irm\s*\|\|\s*'" + [regex]::Escape($script:ExpectedBaseline) + "'\s*\}\}"
        $script:SyncText | Should -Match $pattern -Because 'on the schedule trigger inputs.* is unset; without a || fallback the post-filter runs empty and every ADR 0036 baseline policy reports as drift daily'
    }

    It 'neither workflow''s SKIP_NAMES_IRM env line is a bare input reference with no fallback' {
        # The exact defect: the env value was `${{ inputs.skip_names_irm }}` with
        # nothing after it. Match the env line, then assert it is not immediately
        # followed by the closing `}}` (i.e. it must contain a `||`).
        foreach ($pair in @(
                @{ Name = 'deploy-irm.yml'; Text = $script:DeployText; Expr = 'github\.event\.inputs\.skip_names_irm' }
                @{ Name = 'sync-irm-from-tenant.yml'; Text = $script:SyncText; Expr = 'inputs\.skip_names_irm' }
            )) {
            $bareFallbackless = "SKIP_NAMES_IRM:\s*\`$\{\{\s*$($pair.Expr)\s*\}\}"
            $pair.Text | Should -Not -Match $bareFallbackless -Because "$($pair.Name)'s SKIP_NAMES_IRM must not regress to a fallback-less input reference"
        }
    }
}
