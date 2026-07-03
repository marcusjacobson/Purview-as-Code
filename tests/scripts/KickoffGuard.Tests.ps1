#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/modules/KickoffGuard.psm1 (ADR 0045).

.DESCRIPTION
    Exercises the pure no-push-back guard helpers against synthetic git
    URLs: URL canonicalization across HTTPS / SSH / SCP forms, same-repo
    comparison, the pass/fail guard evaluation, and pre-push hook
    rendering. No git is invoked and no real repository or identifier is
    used.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0045-template-kickoff-spinoff-model.md
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'KickoffGuard.psm1'
    if (-not (Test-Path $script:ModulePath)) {
        throw "Could not locate KickoffGuard.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Synthetic source template repo used across the suite (fictitious org).
    $script:SourceHttps = 'https://github.com/contoso/purview-as-code-generic.git'
    $script:SourceScp   = 'git@github.com:contoso/purview-as-code-generic.git'
    $script:SourceSsh   = 'ssh://git@github.com/contoso/purview-as-code-generic.git'
    $script:ConsumerUrl = 'https://github.com/fabrikam/my-purview.git'
}

AfterAll {
    Remove-Module KickoffGuard -Force -ErrorAction SilentlyContinue
}

Describe 'Get-NormalizedRepoUrl' {

    It 'strips scheme and trailing .git' {
        Get-NormalizedRepoUrl -Url $script:SourceHttps |
            Should -Be 'github.com/contoso/purview-as-code-generic'
    }

    It 'canonicalizes the SCP form to match the HTTPS form' {
        Get-NormalizedRepoUrl -Url $script:SourceScp |
            Should -Be (Get-NormalizedRepoUrl -Url $script:SourceHttps)
    }

    It 'canonicalizes the ssh:// form to match the HTTPS form' {
        Get-NormalizedRepoUrl -Url $script:SourceSsh |
            Should -Be (Get-NormalizedRepoUrl -Url $script:SourceHttps)
    }

    It 'strips userinfo from an HTTPS URL' {
        Get-NormalizedRepoUrl -Url 'https://user:token@github.com/contoso/purview-as-code-generic.git' |
            Should -Be 'github.com/contoso/purview-as-code-generic'
    }

    It 'strips trailing slashes' {
        Get-NormalizedRepoUrl -Url 'https://github.com/contoso/purview-as-code-generic/' |
            Should -Be 'github.com/contoso/purview-as-code-generic'
    }

    It 'returns empty for a blank input' {
        Get-NormalizedRepoUrl -Url '   ' | Should -Be ''
    }

    It 'lowercases a sentinel and does not fabricate a host path' {
        Get-NormalizedRepoUrl -Url 'DISABLE' | Should -Be 'disable'
    }
}

Describe 'Test-IsSameRepoUrl' {

    It 'matches HTTPS and SCP forms of the same repository' {
        Test-IsSameRepoUrl -UrlA $script:SourceHttps -UrlB $script:SourceScp | Should -BeTrue
    }

    It 'does not match two different repositories' {
        Test-IsSameRepoUrl -UrlA $script:SourceHttps -UrlB $script:ConsumerUrl | Should -BeFalse
    }

    It 'never matches when one side is blank' {
        Test-IsSameRepoUrl -UrlA '' -UrlB $script:SourceHttps | Should -BeFalse
    }

    It 'does not treat the DISABLE sentinel as the source repository' {
        Test-IsSameRepoUrl -UrlA 'DISABLE' -UrlB $script:SourceHttps | Should -BeFalse
    }
}

Describe 'Get-KickoffGuardStatus' {

    It 'passes in local mode (no origin, no upstream)' {
        $r = Get-KickoffGuardStatus -SourceUrl $script:SourceHttps -OriginUrl '' -UpstreamPushUrl ''
        $r.Passed | Should -BeTrue
        $r.Failures | Should -BeNullOrEmpty
    }

    It 'passes in spin-off mode (origin points at the consumer repo)' {
        $r = Get-KickoffGuardStatus -SourceUrl $script:SourceHttps -OriginUrl $script:ConsumerUrl -UpstreamPushUrl ''
        $r.Passed | Should -BeTrue
    }

    It 'fails when origin still points at the source template' {
        $r = Get-KickoffGuardStatus -SourceUrl $script:SourceHttps -OriginUrl $script:SourceScp -UpstreamPushUrl ''
        $r.Passed | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'origin still resolves to the source template'
    }

    It 'fails when the upstream push URL still targets the source template' {
        $r = Get-KickoffGuardStatus -SourceUrl $script:SourceHttps -OriginUrl '' -UpstreamPushUrl $script:SourceHttps
        $r.Passed | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match "upstream' push URL still targets"
    }

    It 'passes when the upstream push URL is disabled with a sentinel' {
        $r = Get-KickoffGuardStatus -SourceUrl $script:SourceHttps -OriginUrl $script:ConsumerUrl -UpstreamPushUrl 'DISABLE'
        $r.Passed | Should -BeTrue
    }

    It 'fails when the source URL is unknown' {
        $r = Get-KickoffGuardStatus -SourceUrl '' -OriginUrl $script:ConsumerUrl -UpstreamPushUrl ''
        $r.Passed | Should -BeFalse
        ($r.Failures -join ' ') | Should -Match 'Source template URL is unknown'
    }
}

Describe 'Get-KickoffPrePushHookContent' {

    It 'embeds the canonicalized source URL and blocks on a match' {
        $hook = Get-KickoffPrePushHookContent -SourceUrl $script:SourceHttps
        $hook | Should -Match 'source_url="github.com/contoso/purview-as-code-generic"'
        $hook | Should -Match 'exit 1'
        $hook | Should -Match '#!/usr/bin/env bash'
    }

    It 'throws when the source URL normalizes to empty' {
        { Get-KickoffPrePushHookContent -SourceUrl '   ' } |
            Should -Throw -ExpectedMessage '*normalized to an empty value*'
    }
}
