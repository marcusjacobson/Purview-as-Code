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
      * Assert-KvUnlockFederatedCredential
          - Returns `$null` when no credential exists (caller creates).
          - Returns the existing credential when every field matches.
          - Throws when the subject shape is wrong
            (Issue #257 acceptance criterion).
          - Throws when more than one credential exists
            (single-subject invariant, Issue #257 acceptance criterion).

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdletbindingattribute-declaration
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-KvUnlockEntraApp.ps1'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fn in @('Get-KvUnlockExpectedShape', 'Assert-KvUnlockFederatedCredential')) {
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
}
