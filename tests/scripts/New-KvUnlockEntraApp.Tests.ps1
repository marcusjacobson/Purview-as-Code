#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-KvUnlockEntraApp.ps1 (PR D1b, Issue #257).

.DESCRIPTION
    AST-extracts the two pure helper functions from the orchestrator and
    exercises them with synthetic hashtables / federated-credential
    objects. No live tenant, no `az` calls -- per
    `.github/instructions/tests.instructions.md`. Identifiers follow the
    `00000000-0000-0000-0000-0000000000NN` synthetic GUID pattern.

    Functions under test:
      * Get-KvUnlockExpectedShape
          - Errors loudly when `automation.apps.kvUnlock.displayName` is
            absent (Issue #257 acceptance criterion).
          - Errors loudly when `automation.apps.kvUnlock.githubEnvironment`
            is absent.
          - Returns the expected federated-credential shape using the
            documented subject format
            `repo:<org>/<repo>:environment:<env>`.
          - ADR 0058: computes the immutable (ID-embedded) candidate
            `repo:<org>@<ownerId>/<repo>@<repoId>:environment:<env>` when
            the numeric IDs are supplied, prefers it only when asked, and
            exposes a shape-only fallback pattern only when the IDs are
            NOT available.
      * Assert-KvUnlockFederatedCredential
          - Returns `$null` when no credential exists (caller creates).
          - Returns the existing credential when every field matches.
          - ADR 0058: accepts either subject format; accepts a
            pattern-matching immutable subject (with a warning) only when
            the numeric IDs were unresolved; still throws on any other
            subject.
          - Throws when the subject shape is wrong
            (Issue #257 acceptance criterion).
          - Throws when more than one credential exists
            (single-subject invariant, Issue #257 acceptance criterion).
      * Test-ImmutableSubjectDefault
          - ADR 0058: pins GitHub's 2026-07-15 default-format cutoff.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdletbindingattribute-declaration
    Reference: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-KvUnlockEntraApp.ps1'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fn in @('Get-KvUnlockExpectedShape', 'Assert-KvUnlockFederatedCredential', 'Test-ImmutableSubjectDefault')) {
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

    # Canonical valid parameters hashtable that mirrors infra/parameters/lab.yaml.
    $script:ValidParameters = @{
        environment = 'lab'
        automation  = @{
            githubOrg   = 'contoso'
            githubRepo  = 'Purview-as-Code-Generic'
            apps        = @{
                kvUnlock = @{
                    displayName       = 'gh-oidc-purview-kv-unlock'
                    githubEnvironment = 'kv-unlock'
                }
            }
        }
    }

    $script:ExpectedSubject = 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock'
    # ADR 0058 immutable (ID-embedded) candidate for the same repo, built
    # with the synthetic numeric IDs from GitHub's own documentation
    # examples (123456 / 456789) -- never real IDs.
    $script:ExpectedImmutableSubject = 'repo:contoso@123456/Purview-as-Code-Generic@456789:environment:kv-unlock'
}

Describe 'Get-KvUnlockExpectedShape' {

    It 'returns the documented federated-credential shape from a valid parameters block' {
        $shape = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters
        $shape.DisplayName | Should -Be 'gh-oidc-purview-kv-unlock'
        $shape.FcName      | Should -Be 'gh-env-kv-unlock'
        $shape.Subject     | Should -Be $script:ExpectedSubject
        $shape.Issuer      | Should -Be 'https://token.actions.githubusercontent.com'
        $shape.Audiences   | Should -Be @('api://AzureADTokenExchange')
    }

    It 'honors the DisplayName override' {
        $shape = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters -DisplayNameOverride 'gh-oidc-other'
        $shape.DisplayName | Should -Be 'gh-oidc-other'
    }

    It 'throws when automation.apps.kvUnlock.displayName is missing' {
        $broken = @{
            automation = @{
                githubOrg  = 'contoso'
                githubRepo = 'Purview-as-Code-Generic'
                apps       = @{
                    kvUnlock = @{
                        # displayName intentionally omitted
                        githubEnvironment = 'kv-unlock'
                    }
                }
            }
        }
        { Get-KvUnlockExpectedShape -Parameters $broken } |
            Should -Throw -ExpectedMessage '*automation.apps.kvUnlock.displayName*'
    }

    It 'throws when automation.apps.kvUnlock.githubEnvironment is missing' {
        $broken = @{
            automation = @{
                githubOrg  = 'contoso'
                githubRepo = 'Purview-as-Code-Generic'
                apps       = @{
                    kvUnlock = @{
                        displayName = 'gh-oidc-purview-kv-unlock'
                    }
                }
            }
        }
        { Get-KvUnlockExpectedShape -Parameters $broken } |
            Should -Throw -ExpectedMessage '*automation.apps.kvUnlock.githubEnvironment*'
    }

    It 'throws when the automation.apps.kvUnlock block itself is absent' {
        $broken = @{
            automation = @{
                githubOrg  = 'contoso'
                githubRepo = 'Purview-as-Code-Generic'
                apps       = @{}
            }
        }
        { Get-KvUnlockExpectedShape -Parameters $broken } |
            Should -Throw -ExpectedMessage '*automation.apps.kvUnlock*'
    }

    It 'throws when the top-level automation block is absent' {
        { Get-KvUnlockExpectedShape -Parameters @{} } |
            Should -Throw -ExpectedMessage "*'automation'*"
    }

    Context 'ADR 0058 immutable (ID-embedded) subject candidates' {

        It 'keeps the classic subject preferred and exposes the fallback pattern when no IDs are supplied' {
            $shape = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters
            $shape.Subject          | Should -Be $script:ExpectedSubject
            $shape.SubjectClassic   | Should -Be $script:ExpectedSubject
            $shape.SubjectImmutable | Should -BeNullOrEmpty
            @($shape.Subjects)      | Should -Be @($script:ExpectedSubject)
            $shape.SubjectPattern   | Should -Not -BeNullOrEmpty
            $script:ExpectedImmutableSubject | Should -Match $shape.SubjectPattern
            'repo:other-org@1/other-repo@2:environment:kv-unlock' | Should -Not -Match $shape.SubjectPattern
        }

        It 'computes both candidates and keeps classic preferred when IDs are supplied without the preference switch' {
            $shape = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters -OwnerId '123456' -RepoId '456789'
            $shape.Subject          | Should -Be $script:ExpectedSubject
            $shape.SubjectImmutable | Should -Be $script:ExpectedImmutableSubject
            @($shape.Subjects)      | Should -Contain $script:ExpectedSubject
            @($shape.Subjects)      | Should -Contain $script:ExpectedImmutableSubject
            $shape.SubjectPattern   | Should -BeNullOrEmpty
        }

        It 'prefers the immutable subject when asked (repository mints ID-embedded claims)' {
            $shape = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters -OwnerId '123456' -RepoId '456789' -PreferImmutableSubject
            $shape.Subject | Should -Be $script:ExpectedImmutableSubject
        }

        It 'throws when the immutable preference is requested without resolved IDs' {
            { Get-KvUnlockExpectedShape -Parameters $script:ValidParameters -PreferImmutableSubject } |
                Should -Throw -ExpectedMessage '*OwnerId*'
        }
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

Describe 'Assert-KvUnlockFederatedCredential' {

    BeforeAll {
        $script:Expected = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters

        $script:GoodFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000001'
            name      = 'gh-env-kv-unlock'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock'
            audiences = @('api://AzureADTokenExchange')
        }
    }

    It 'returns $null when the FC list is empty' {
        $result = Assert-KvUnlockFederatedCredential `
            -FcList @() `
            -Expected $script:Expected `
            -DisplayName 'gh-oidc-purview-kv-unlock'
        $result | Should -BeNullOrEmpty
    }

    It 'returns the matching FC when exactly one credential matches' {
        $result = Assert-KvUnlockFederatedCredential `
            -FcList @($script:GoodFc) `
            -Expected $script:Expected `
            -DisplayName 'gh-oidc-purview-kv-unlock'
        $result.id | Should -Be '00000000-0000-0000-0000-000000000001'
    }

    It 'throws when the FC subject is bound to the wrong GitHub environment' {
        $wrongEnvFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000002'
            name      = 'gh-env-kv-unlock'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:lab'
            audiences = @('api://AzureADTokenExchange')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($wrongEnvFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*subject*'
    }

    It 'throws when the FC subject is bound to the wrong repo' {
        $wrongRepoFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000003'
            name      = 'gh-env-kv-unlock'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:other-org/other-repo:environment:kv-unlock'
            audiences = @('api://AzureADTokenExchange')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($wrongRepoFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*subject*'
    }

    It 'throws when the FC issuer is not the GitHub Actions OIDC issuer' {
        $wrongIssuerFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000004'
            name      = 'gh-env-kv-unlock'
            issuer    = 'https://example.com/oidc'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock'
            audiences = @('api://AzureADTokenExchange')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($wrongIssuerFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*issuer*'
    }

    It 'throws when the FC audience list does not match the expected audience' {
        $wrongAudFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000005'
            name      = 'gh-env-kv-unlock'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock'
            audiences = @('api://OtherAudience')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($wrongAudFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*audiences*'
    }

    It 'throws when the FC count is greater than one (single-subject invariant)' {
        $secondFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000006'
            name      = 'gh-env-other'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:other'
            audiences = @('api://AzureADTokenExchange')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($script:GoodFc, $secondFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*federated credentials*'
    }

    It 'throws when two FCs share the same subject (still a single-subject invariant violation)' {
        $dupFc = [pscustomobject]@{
            id        = '00000000-0000-0000-0000-000000000007'
            name      = 'gh-env-kv-unlock-duplicate'
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = 'repo:contoso/Purview-as-Code-Generic:environment:kv-unlock'
            audiences = @('api://AzureADTokenExchange')
        }
        { Assert-KvUnlockFederatedCredential `
                -FcList @($script:GoodFc, $dupFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*federated credentials*'
    }

    Context 'ADR 0058 immutable (ID-embedded) subject acceptance' {

        BeforeAll {
            # Expected shape as computed when the numeric IDs resolved.
            $script:ExpectedWithIds = Get-KvUnlockExpectedShape -Parameters $script:ValidParameters -OwnerId '123456' -RepoId '456789' -PreferImmutableSubject

            $script:ImmutableFc = [pscustomobject]@{
                id        = '00000000-0000-0000-0000-000000000010'
                name      = 'gh-env-kv-unlock'
                issuer    = 'https://token.actions.githubusercontent.com'
                subject   = 'repo:contoso@123456/Purview-as-Code-Generic@456789:environment:kv-unlock'
                audiences = @('api://AzureADTokenExchange')
            }
        }

        It 'accepts an immutable-format credential when the IDs resolved' {
            $result = Assert-KvUnlockFederatedCredential `
                -FcList @($script:ImmutableFc) `
                -Expected $script:ExpectedWithIds `
                -DisplayName 'gh-oidc-purview-kv-unlock'
            $result.id | Should -Be '00000000-0000-0000-0000-000000000010'
        }

        It 'still accepts a classic credential when the immutable format is preferred (transition acceptance)' {
            $result = Assert-KvUnlockFederatedCredential `
                -FcList @($script:GoodFc) `
                -Expected $script:ExpectedWithIds `
                -DisplayName 'gh-oidc-purview-kv-unlock'
            $result.id | Should -Be '00000000-0000-0000-0000-000000000001'
        }

        It 'throws when an immutable-format credential carries different numeric IDs than resolved' {
            $wrongIdsFc = [pscustomobject]@{
                id        = '00000000-0000-0000-0000-000000000011'
                name      = 'gh-env-kv-unlock'
                issuer    = 'https://token.actions.githubusercontent.com'
                subject   = 'repo:contoso@999999/Purview-as-Code-Generic@888888:environment:kv-unlock'
                audiences = @('api://AzureADTokenExchange')
            }
            { Assert-KvUnlockFederatedCredential `
                    -FcList @($wrongIdsFc) `
                    -Expected $script:ExpectedWithIds `
                    -DisplayName 'gh-oidc-purview-kv-unlock' } |
                Should -Throw -ExpectedMessage '*subject*'
        }

        It 'accepts a pattern-matching immutable credential with a warning when the IDs were unresolved' {
            $warnings = $null
            $result = Assert-KvUnlockFederatedCredential `
                -FcList @($script:ImmutableFc) `
                -Expected $script:Expected `
                -DisplayName 'gh-oidc-purview-kv-unlock' `
                -WarningVariable warnings -WarningAction SilentlyContinue
            $result.id | Should -Be '00000000-0000-0000-0000-000000000010'
            @($warnings).Count | Should -BeGreaterThan 0
            [string]$warnings[0] | Should -Match 'could not be resolved'
        }

        It 'rejects an immutable-format credential for the wrong repo even when the IDs were unresolved' {
            $wrongRepoImmutableFc = [pscustomobject]@{
                id        = '00000000-0000-0000-0000-000000000012'
                name      = 'gh-env-kv-unlock'
                issuer    = 'https://token.actions.githubusercontent.com'
                subject   = 'repo:other-org@123456/other-repo@456789:environment:kv-unlock'
                audiences = @('api://AzureADTokenExchange')
            }
            { Assert-KvUnlockFederatedCredential `
                    -FcList @($wrongRepoImmutableFc) `
                    -Expected $script:Expected `
                    -DisplayName 'gh-oidc-purview-kv-unlock' `
                    -WarningAction SilentlyContinue } |
                Should -Throw -ExpectedMessage '*subject*'
        }
    }
}
