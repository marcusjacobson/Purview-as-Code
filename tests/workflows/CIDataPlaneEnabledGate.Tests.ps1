#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    ADR 0060 — vars.CI_DATA_PLANE_ENABLED lets a governance-locked tenant's
    owner silence a *scheduled* tenant-touching workflow's daily/weekly
    failure instead of it going unexplained-red forever (issue #9). It is a
    manual-run bypass, not a hard disable: a workflow_dispatch run always
    attempts the tenant call regardless of the variable, so the owner can
    test after requesting a policy exemption.

    This gate rides the same ADR 0054 preflight `Check onboarding signal`
    step already gating every tenant-touching schedule-triggered workflow
    (see TenantTouchingWorkflowGate.Tests.ps1 for the wiring contract: a
    dedicated `preflight` job, `needs: preflight` + `if:
    needs.preflight.outputs.configured == 'true'` on the tenant-touching
    job). This suite pins the CHECK STEP'S OWN LOGIC by extracting and
    REPLAYING it from the shipped workflow files, the same "test the
    committed artefact" reasoning as KeyVaultOpenVerify.Tests.ps1.

    Two shapes exist:
      * "Variant A" (6 workflows) also gates on vars.KEY_VAULT_NAME being
        non-empty (ADR 0054's original KV-onboarding check). All six carry
        a byte-identical check step, so this suite pins one representative
        (sync-labels-from-tenant.yml) and asserts the other five are
        identical to it.
      * "Variant B" (export-content-explorer.yml) never opens the Key
        Vault firewall itself (the script resolves it from the parameters
        file), so its check step omits the KEY_VAULT_NAME branch.

    Reference: docs/adr/0054-tenant-touching-workflow-skip-gate.md
    Reference: docs/adr/0060-governance-locked-kv-local-cert-apply.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # The 6 "variant A" workflows: schedule-triggered, azure/login-calling,
    # and their preflight step also gates on KEY_VAULT_NAME.
    $script:VariantAWorkflows = @(
        'drift-detection.yml',
        'sync-auto-label-policies-from-tenant.yml',
        'sync-dlp-from-tenant.yml',
        'sync-irm-from-tenant.yml',
        'sync-label-policies-from-tenant.yml',
        'sync-labels-from-tenant.yml'
    )

    # Pull the "Check onboarding signal" step's `run:` block out of the
    # SHIPPED workflow (searched by step name, not job structure, so job
    # renames don't silently blind this test).
    function Get-CheckRun {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $script:WorkflowsDir $Name
        $wf = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
        foreach ($jobKey in $wf['jobs'].Keys) {
            foreach ($step in $wf['jobs'][$jobKey]['steps']) {
                if ($step['name'] -eq 'Check onboarding signal') {
                    return [string]$step['run']
                }
            }
        }
        throw "Step 'Check onboarding signal' not found in $Name"
    }

    # Replay the extracted pwsh block in a real child pwsh process (the
    # block is `shell: pwsh` in the workflow, not bash), with the four
    # environment variables the step reads set to the scenario's values.
    # Reads back GITHUB_OUTPUT and returns the emitted `configured` value.
    function Invoke-CheckBlock {
        param(
            [Parameter(Mandatory)][string]$RunScript,
            [string]$AzureClientId = 'fake-client-id',
            [string]$KeyVaultName = 'kv-test',
            [Parameter(Mandatory)][string]$EventName,
            [string]$CiDataPlaneEnabled = ''
        )
        $tmpDir = [System.IO.Path]::GetTempPath()
        $scriptPath = Join-Path $tmpDir ("cidpgate-" + [System.IO.Path]::GetRandomFileName() + '.ps1')
        $outputPath = Join-Path $tmpDir ("cidpgate-out-" + [System.IO.Path]::GetRandomFileName())
        [System.IO.File]::WriteAllText($scriptPath, $RunScript, (New-Object System.Text.UTF8Encoding $false))
        New-Item -ItemType File -Path $outputPath -Force | Out-Null
        try {
            $env:AZURE_CLIENT_ID = $AzureClientId
            $env:KEY_VAULT_NAME = $KeyVaultName
            $env:EVENT_NAME = $EventName
            $env:CI_DATA_PLANE_ENABLED = $CiDataPlaneEnabled
            $env:GITHUB_OUTPUT = $outputPath
            & pwsh -NoProfile -NonInteractive -File $scriptPath 2>&1 | Out-Null
            $content = Get-Content -LiteralPath $outputPath -Raw -ErrorAction SilentlyContinue
        }
        finally {
            Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $outputPath -ErrorAction SilentlyContinue
            Remove-Item Env:AZURE_CLIENT_ID, Env:KEY_VAULT_NAME, Env:EVENT_NAME, Env:CI_DATA_PLANE_ENABLED, Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        }
        $m = [regex]::Match([string]$content, 'configured=(?<v>true|false)')
        if (-not $m.Success) {
            throw "GITHUB_OUTPUT did not contain a 'configured=' line. Raw content: '$content'"
        }
        return $m.Groups['v'].Value
    }
}

Describe 'ADR 0060 — variant-A check step is byte-identical across all 6 workflows' {

    It 'the other 5 match the sync-labels-from-tenant.yml reference verbatim' {
        $reference = Get-CheckRun -Name 'sync-labels-from-tenant.yml'
        foreach ($name in ($script:VariantAWorkflows | Where-Object { $_ -ne 'sync-labels-from-tenant.yml' })) {
            (Get-CheckRun -Name $name) | Should -Be $reference -Because "$name must carry the identical preflight check as the reference, or the two can silently diverge"
        }
    }
}

Describe 'ADR 0060 — CI_DATA_PLANE_ENABLED gate contract (variant A: KEY_VAULT_NAME-checking workflows)' {

    BeforeAll {
        $script:RunScript = Get-CheckRun -Name 'sync-labels-from-tenant.yml'
    }

    It 'unchanged: empty AZURE_CLIENT_ID -> configured=false (onboarding gate, ADR 0054)' {
        Invoke-CheckBlock -RunScript $script:RunScript -AzureClientId '' -EventName 'schedule' |
            Should -Be 'false'
    }

    It 'unchanged: empty KEY_VAULT_NAME -> configured=false (onboarding gate, ADR 0054)' {
        Invoke-CheckBlock -RunScript $script:RunScript -KeyVaultName '' -EventName 'schedule' |
            Should -Be 'false'
    }

    It 'new: schedule trigger + CI_DATA_PLANE_ENABLED=false -> configured=false (governance skip, ADR 0060)' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'schedule' -CiDataPlaneEnabled 'false' |
            Should -Be 'false'
    }

    It 'new: schedule trigger + CI_DATA_PLANE_ENABLED=true -> configured=true' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'schedule' -CiDataPlaneEnabled 'true' |
            Should -Be 'true'
    }

    It 'new: schedule trigger + CI_DATA_PLANE_ENABLED unset -> configured=true (default-on; unconfigured environments are unaffected)' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'schedule' -CiDataPlaneEnabled '' |
            Should -Be 'true'
    }

    It 'new: workflow_dispatch trigger + CI_DATA_PLANE_ENABLED=false -> configured=true (manual runs always attempt the tenant call)' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'workflow_dispatch' -CiDataPlaneEnabled 'false' |
            Should -Be 'true'
    }
}

Describe 'ADR 0060 — CI_DATA_PLANE_ENABLED gate contract (variant B: export-content-explorer.yml, no KEY_VAULT_NAME check)' {

    BeforeAll {
        $script:RunScript = Get-CheckRun -Name 'export-content-explorer.yml'
    }

    It 'unchanged: empty AZURE_CLIENT_ID -> configured=false (onboarding gate, ADR 0054)' {
        Invoke-CheckBlock -RunScript $script:RunScript -AzureClientId '' -EventName 'schedule' |
            Should -Be 'false'
    }

    It 'new: schedule trigger + CI_DATA_PLANE_ENABLED=false -> configured=false (governance skip, ADR 0060)' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'schedule' -CiDataPlaneEnabled 'false' |
            Should -Be 'false'
    }

    It 'new: schedule trigger + CI_DATA_PLANE_ENABLED=true -> configured=true' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'schedule' -CiDataPlaneEnabled 'true' |
            Should -Be 'true'
    }

    It 'new: workflow_dispatch trigger + CI_DATA_PLANE_ENABLED=false -> configured=true (manual runs always attempt the tenant call)' {
        Invoke-CheckBlock -RunScript $script:RunScript -EventName 'workflow_dispatch' -CiDataPlaneEnabled 'false' |
            Should -Be 'true'
    }
}
