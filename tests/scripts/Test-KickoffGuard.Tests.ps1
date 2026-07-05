#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for the CLI exit-code contract of scripts/Test-KickoffGuard.ps1
    (ADR 0045).

.DESCRIPTION
    The script gates automation on its process exit code ("A non-zero exit is
    a stop" — .github/agents/operator-kickoff.agent.md). These tests assert the
    contract directly: exit 0 when the guard passes, exit 1 when it fails.

    The script is invoked in a CHILD pwsh process so its `exit` statements set a
    real process exit code without terminating the Pester runspace. The
    -OriginUrl and -UpstreamPushUrl parameters are bound so the script never
    shells out to git — the run is deterministic and uses only synthetic,
    fictitious URLs (no live git, no real identifier).

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0045-template-kickoff-spinoff-model.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Test-KickoffGuard.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Test-KickoffGuard.ps1 at: $script:ScriptPath"
    }

    # Path to the pwsh hosting this test run; used to spawn the child process.
    $script:PwshExe = (Get-Process -Id $PID).Path

    # Synthetic source template repo (fictitious org) and a distinct consumer repo.
    $script:SourceUrl   = 'https://github.com/contoso/purview-as-code-generic.git'
    $script:ConsumerUrl = 'https://github.com/fabrikam/my-purview.git'

    # Run the script in a child process with bound remotes (no git shell-out)
    # and return the process exit code.
    function Invoke-GuardScript {
        param(
            [Parameter(Mandatory)][string]$SourceUrl,
            [string]$OriginUrl = '',
            [string]$UpstreamPushUrl = ''
        )
        & $script:PwshExe -NoProfile -NonInteractive -File $script:ScriptPath `
            -SourceUrl $SourceUrl -OriginUrl $OriginUrl -UpstreamPushUrl $UpstreamPushUrl *> $null
        return $LASTEXITCODE
    }
}

Describe 'Test-KickoffGuard.ps1 exit-code contract' {

    It 'exits 0 when the guard passes (local mode: no origin, no upstream)' {
        Invoke-GuardScript -SourceUrl $script:SourceUrl -OriginUrl '' -UpstreamPushUrl '' |
            Should -Be 0
    }

    It 'exits 0 when the guard passes (spin-off mode: origin points at the consumer repo)' {
        Invoke-GuardScript -SourceUrl $script:SourceUrl -OriginUrl $script:ConsumerUrl -UpstreamPushUrl '' |
            Should -Be 0
    }

    It 'exits 1 when origin still resolves to the source template' {
        Invoke-GuardScript -SourceUrl $script:SourceUrl -OriginUrl $script:SourceUrl -UpstreamPushUrl '' |
            Should -Be 1
    }

    It 'exits 1 when the upstream push URL still targets the source template' {
        Invoke-GuardScript -SourceUrl $script:SourceUrl -OriginUrl $script:ConsumerUrl -UpstreamPushUrl $script:SourceUrl |
            Should -Be 1
    }
}
