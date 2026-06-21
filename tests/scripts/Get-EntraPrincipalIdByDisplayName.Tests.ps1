#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Get-EntraPrincipalIdByDisplayName.ps1 (ADR 0023).

.DESCRIPTION
    AST-extracts the internal `Resolve-EntraPrincipalId` function and
    exercises its happy-path, zero-match, and multi-match branches by
    stubbing the `az` external command inside the test scope.

    Synthetic GUIDs follow the `00000000-0000-0000-0000-0000000000NN`
    pattern.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/graph/api/group-list
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-EntraPrincipalIdByDisplayName.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Get-EntraPrincipalIdByDisplayName.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $fnAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-EntraPrincipalId'
        }, $true)
    if (-not $fnAst) {
        throw "Function 'Resolve-EntraPrincipalId' not found in $script:ScriptPath"
    }
    . ([ScriptBlock]::Create($fnAst.Extent.Text))
}

Describe 'Resolve-EntraPrincipalId' {

    BeforeEach {
        $script:AzInvocations = New-Object System.Collections.Generic.List[object]
        $script:AzResponses   = New-Object System.Collections.Generic.Queue[string]
    }

    It 'returns the objectId when Graph returns exactly one match' {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = '00000000-0000-0000-0000-000000000010'
                            displayName = 'sg-purview-devops-sql-readers'
                        }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = Resolve-EntraPrincipalId -DisplayName 'sg-purview-devops-sql-readers'

        $result | Should -Be '00000000-0000-0000-0000-000000000010'
        $script:AzInvocations.Count | Should -Be 1
        ($script:AzInvocations[0] -join ' ') | Should -Match 'rest'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'graph.microsoft.com/v1.0/groups'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'sg-purview-devops-sql-readers'
    }

    It 'queries the users collection when -Kind User' {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = '00000000-0000-0000-0000-000000000011'
                            displayName = 'Avery Howell'
                        }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = Resolve-EntraPrincipalId -DisplayName 'Avery Howell' -Kind 'User'

        $result | Should -Be '00000000-0000-0000-0000-000000000011'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'graph.microsoft.com/v1.0/users'
    }

    It 'queries the servicePrincipals collection when -Kind ServicePrincipal' {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = '00000000-0000-0000-0000-000000000012'
                            displayName = 'svc-purview-scanner'
                        }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = Resolve-EntraPrincipalId -DisplayName 'svc-purview-scanner' -Kind 'ServicePrincipal'

        $result | Should -Be '00000000-0000-0000-0000-000000000012'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'graph.microsoft.com/v1.0/servicePrincipals'
    }

    It 'uses the beta endpoint when -ApiVersion beta' {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = '00000000-0000-0000-0000-000000000013'
                            displayName = 'beta-only-group'
                        }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        Resolve-EntraPrincipalId -DisplayName 'beta-only-group' -ApiVersion 'beta' | Out-Null
        ($script:AzInvocations[0] -join ' ') | Should -Match 'graph.microsoft.com/beta/groups'
    }

    It "escapes a single quote in the display name per OData rules" {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id          = '00000000-0000-0000-0000-000000000014'
                            displayName = "O'Brien Team"
                        }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        Resolve-EntraPrincipalId -DisplayName "O'Brien Team" | Out-Null
        ($script:AzInvocations[0] -join ' ') | Should -Match "O''Brien Team"
    }

    It 'throws when Graph returns zero matches' {
        $script:AzResponses.Enqueue(([pscustomobject]@{ value = @() } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        { Resolve-EntraPrincipalId -DisplayName 'does-not-exist' } |
            Should -Throw -ExpectedMessage '*No Group found*does-not-exist*'
    }

    It 'throws when Graph returns more than one match' {
        $script:AzResponses.Enqueue(([pscustomobject]@{
                    value = @(
                        [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000020'; displayName = 'dup-name' },
                        [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000021'; displayName = 'dup-name' }
                    )
                } | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        { Resolve-EntraPrincipalId -DisplayName 'dup-name' } |
            Should -Throw -ExpectedMessage '*Multiple Groups found*dup-name*'
    }

    It 'throws with az-login guidance when az exits non-zero' {
        $script:AzResponses.Enqueue('')

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 1
            return $script:AzResponses.Dequeue()
        }

        { Resolve-EntraPrincipalId -DisplayName 'whatever' } |
            Should -Throw -ExpectedMessage '*az login*Graph permissions*'
    }
}

