#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Resolve-EnvTokens.ps1 (ADR 0023).

.DESCRIPTION
    Tests the script end-to-end by invoking it with both parameter sets
    (`-InputString`, `-InputObject`) and asserting against the allow-list
    behaviour, unresolved-token behaviour, and recursive substitution
    on nested hashtables / arrays.

    Environment variables are set in BeforeEach and cleared in AfterEach
    so each test is isolated. No Graph or Azure calls are made.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0023-identifier-resolution.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Resolve-EnvTokens.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Resolve-EnvTokens.ps1 at: $script:ScriptPath"
    }

    function Set-AdrTestEnv {
        $env:AZURE_TENANT_ID         = '00000000-0000-0000-0000-000000000001'
        $env:AZURE_SUBSCRIPTION_ID   = '00000000-0000-0000-0000-000000000002'
        $env:PURVIEW_ACCOUNT_NAME    = 'purview-contoso-lab'
        $env:PURVIEW_RG              = 'rg-purview-lab'
        $env:DATABRICKS_METASTORE_ID = '00000000-0000-0000-0000-000000000003'
    }

    function Clear-AdrTestEnv {
        Remove-Item Env:\AZURE_TENANT_ID         -ErrorAction SilentlyContinue
        Remove-Item Env:\AZURE_SUBSCRIPTION_ID   -ErrorAction SilentlyContinue
        Remove-Item Env:\PURVIEW_ACCOUNT_NAME    -ErrorAction SilentlyContinue
        Remove-Item Env:\PURVIEW_RG              -ErrorAction SilentlyContinue
        Remove-Item Env:\DATABRICKS_METASTORE_ID -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-EnvTokens -InputString' {

    BeforeEach { Set-AdrTestEnv }
    AfterEach  { Clear-AdrTestEnv }

    It 'substitutes a single allow-listed token' {
        $result = & $script:ScriptPath -InputString '/subscriptions/${env:AZURE_SUBSCRIPTION_ID}/x'
        $result | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000002/x'
    }

    It 'substitutes multiple allow-listed tokens in one string' {
        $result = & $script:ScriptPath -InputString '/subscriptions/${env:AZURE_SUBSCRIPTION_ID}/resourceGroups/${env:PURVIEW_RG}'
        $result | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000002/resourceGroups/rg-purview-lab'
    }

    It 'substitutes DATABRICKS_METASTORE_ID (added 2026-06-14 under #370 for Deploy-DataSources.ps1)' {
        $result = & $script:ScriptPath -InputString '${env:DATABRICKS_METASTORE_ID}'
        $result | Should -Be '00000000-0000-0000-0000-000000000003'
    }

    It 'returns the input unchanged when no tokens are present' {
        $result = & $script:ScriptPath -InputString '/some/static/path'
        $result | Should -Be '/some/static/path'
    }

    It 'returns an empty string unchanged' {
        $result = & $script:ScriptPath -InputString ''
        $result | Should -Be ''
    }

    It 'throws when a token references a variable not on the allow-list' {
        { & $script:ScriptPath -InputString 'value=${env:AZURE_CLIENT_SECRET}' } |
            Should -Throw -ExpectedMessage '*AZURE_CLIENT_SECRET*allow-list*'
    }

    It 'throws when an allow-listed variable is unset' {
        Remove-Item Env:\AZURE_TENANT_ID -ErrorAction SilentlyContinue
        { & $script:ScriptPath -InputString 'tenant=${env:AZURE_TENANT_ID}' } |
            Should -Throw -ExpectedMessage '*AZURE_TENANT_ID*allow-listed but the environment variable is unset*'
    }

    It 'rejects an obviously secret-shaped variable name even if it were exported' {
        $env:AZURE_CLIENT_SECRET = 'super-secret-value'
        try {
            { & $script:ScriptPath -InputString 'x=${env:AZURE_CLIENT_SECRET}' } |
                Should -Throw -ExpectedMessage '*AZURE_CLIENT_SECRET*allow-list*'
        }
        finally {
            Remove-Item Env:\AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Resolve-EnvTokens -InputObject' {

    BeforeEach { Set-AdrTestEnv }
    AfterEach  { Clear-AdrTestEnv }

    It 'substitutes tokens inside a hashtable value' {
        $hash = @{
            resourceId = '/subscriptions/${env:AZURE_SUBSCRIPTION_ID}/x'
            name       = 'static'
        }
        $result = & $script:ScriptPath -InputObject $hash
        $result.resourceId | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000002/x'
        $result.name       | Should -Be 'static'
    }

    It 'recurses into nested hashtables' {
        $hash = @{
            outer = @{
                inner = @{
                    leaf = 'tenant=${env:AZURE_TENANT_ID}'
                }
            }
        }
        $result = & $script:ScriptPath -InputObject $hash
        $result.outer.inner.leaf | Should -Be 'tenant=00000000-0000-0000-0000-000000000001'
    }

    It 'substitutes tokens inside arrays' {
        $arr = @(
            'first=${env:PURVIEW_ACCOUNT_NAME}',
            'second-static'
        )
        $result = & $script:ScriptPath -InputObject $arr
        $result[0] | Should -Be 'first=purview-contoso-lab'
        $result[1] | Should -Be 'second-static'
    }

    It 'returns $null unchanged' {
        $result = & $script:ScriptPath -InputObject $null
        $result | Should -BeNullOrEmpty
    }

    It 'returns non-string scalars unchanged' {
        $result = & $script:ScriptPath -InputObject 42
        $result | Should -Be 42
    }

    It 'throws when a nested string contains an off-allow-list token' {
        $hash = @{ x = 'oops=${env:SECRET_VAR}' }
        { & $script:ScriptPath -InputObject $hash } |
            Should -Throw -ExpectedMessage '*SECRET_VAR*allow-list*'
    }
}

