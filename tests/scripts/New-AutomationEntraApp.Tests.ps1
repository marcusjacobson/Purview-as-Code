#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-AutomationEntraApp.ps1 (ADR 0058 helpers).

.DESCRIPTION
    AST-extracts the pure helper functions from the orchestrator and
    exercises them with synthetic values. No live tenant, no `az` calls,
    no GitHub API calls -- per `.github/instructions/tests.instructions.md`.
    The network-facing Resolve-GitHubRepoIdentity helper is deliberately
    NOT driven here (it is a thin gh/api.github.com wrapper); the format
    decision and candidate computation it feeds are.

    Functions under test:
      * Get-AutomationExpectedSubject
          - Classic candidate `repo:<org>/<repo>:environment:<env>` is
            always computed and is the default preference (ADR 0010
            decision #2 unchanged for pre-cutoff repositories).
          - ADR 0058: immutable candidate
            `repo:<org>@<ownerId>/<repo>@<repoId>:environment:<env>` is
            computed when the numeric IDs are supplied, preferred only
            when asked, and the shape-only fallback pattern exists only
            when the IDs are NOT available.
      * Test-ImmutableSubjectDefault
          - ADR 0058: pins GitHub's 2026-07-15 default-format cutoff.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
    Reference: https://docs.github.com/en/actions/reference/security/oidc
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-AutomationEntraApp.ps1'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fn in @('Get-AutomationExpectedSubject', 'Test-ImmutableSubjectDefault')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fn
            }, $true)
        if (-not $fnAst) {
            throw "Function '$fn' not found in $($script:ScriptPath)."
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Synthetic identifiers only. The numeric IDs are GitHub's own
    # documentation examples (123456 / 456789) -- never real IDs.
    $script:Org = 'contoso'
    $script:Repo = 'Purview-as-Code-Generic'
    $script:Environment = 'lab'
    $script:Classic = 'repo:contoso/Purview-as-Code-Generic:environment:lab'
    $script:Immutable = 'repo:contoso@123456/Purview-as-Code-Generic@456789:environment:lab'
}

Describe 'Get-AutomationExpectedSubject' {

    It 'returns the classic ADR 0010 subject as default preference with no IDs' {
        $shape = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment
        $shape.Subject          | Should -Be $script:Classic
        $shape.SubjectClassic   | Should -Be $script:Classic
        $shape.SubjectImmutable | Should -BeNullOrEmpty
        @($shape.Subjects)      | Should -Be @($script:Classic)
    }

    It 'exposes the shape-only fallback pattern only when the IDs are unresolved' {
        $noIds = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment
        $noIds.SubjectPattern | Should -Not -BeNullOrEmpty
        $script:Immutable | Should -Match $noIds.SubjectPattern
        'repo:other-org@1/other-repo@2:environment:lab' | Should -Not -Match $noIds.SubjectPattern

        $withIds = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment -OwnerId '123456' -RepoId '456789'
        $withIds.SubjectPattern | Should -BeNullOrEmpty
    }

    It 'computes both candidates when the IDs are supplied, classic still preferred' {
        $shape = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment -OwnerId '123456' -RepoId '456789'
        $shape.Subject          | Should -Be $script:Classic
        $shape.SubjectImmutable | Should -Be $script:Immutable
        @($shape.Subjects)      | Should -Contain $script:Classic
        @($shape.Subjects)      | Should -Contain $script:Immutable
    }

    It 'prefers the immutable subject when asked (repository mints ID-embedded claims)' {
        $shape = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment -OwnerId '123456' -RepoId '456789' -PreferImmutableSubject
        $shape.Subject | Should -Be $script:Immutable
    }

    It 'throws when the immutable preference is requested without resolved IDs' {
        { Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment $script:Environment -PreferImmutableSubject } |
            Should -Throw -ExpectedMessage '*OwnerId*'
    }

    It 'environment-scopes both candidates (kv-unlock-style environments included)' {
        $shape = Get-AutomationExpectedSubject -Org $script:Org -Repo $script:Repo -Environment 'kv-unlock-dev' -OwnerId '123456' -RepoId '456789'
        $shape.SubjectClassic   | Should -Be 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock-dev'
        $shape.SubjectImmutable | Should -Be 'repo:contoso@123456/Purview-as-Code-Generic@456789:environment:kv-unlock-dev'
    }
}

Describe 'Test-ImmutableSubjectDefault' {

    It 'is false for a repository created before the 2026-07-15 cutoff' {
        Test-ImmutableSubjectDefault -CreatedAt ([datetime]::SpecifyKind([datetime]'2026-07-14T23:59:59', [System.DateTimeKind]::Utc)) |
            Should -BeFalse
    }

    It 'is true on the cutoff instant and after' {
        Test-ImmutableSubjectDefault -CreatedAt ([datetime]::SpecifyKind([datetime]'2026-07-15T00:00:00', [System.DateTimeKind]::Utc)) |
            Should -BeTrue
        Test-ImmutableSubjectDefault -CreatedAt ([datetime]::SpecifyKind([datetime]'2026-08-01T12:00:00', [System.DateTimeKind]::Utc)) |
            Should -BeTrue
    }
}
