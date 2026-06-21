#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-KvUnlockRbac.ps1 (PR D1b, Issue #257).

.DESCRIPTION
    AST-extracts the two pure-modulo-az helper functions from the
    orchestrator and exercises them by stubbing `az` and the
    `$LASTEXITCODE` automatic variable inside a child script scope.
    Synthetic GUIDs follow the `00000000-0000-0000-0000-0000000000NN`
    pattern.

    Functions under test:
      * Resolve-KvUnlockSp
          - Throws (and names `New-KvUnlockEntraApp.ps1`) when the app
            display name has zero matches.
          - Throws when the app display name has more than one match.
          - Returns the SP object ID on the happy path.
      * Resolve-KvFirewallTogglerRole
          - Throws (and prints the `infra/main.bicep` fail-closed
            command) when the custom role does not exist.
          - Throws when more than one custom role of that name exists.
          - Returns the role resource ID on the happy path.

    The az stub is registered as a function inside the test scope; the
    extracted helpers resolve the `az` token to that function before
    falling back to the real CLI binary, so the tests never reach the
    network.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-arrays
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-KvUnlockRbac.ps1'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fn in @('Resolve-KvUnlockSp', 'Resolve-KvFirewallTogglerRole')) {
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
}

Describe 'Resolve-KvFirewallTogglerRole' {

    BeforeEach {
        $script:AzInvocations = New-Object System.Collections.Generic.List[object]
        $script:AzResponses   = New-Object System.Collections.Generic.Queue[string]
    }

    It 'returns the role resource ID when az returns exactly one match' {
        $script:AzResponses.Enqueue((@(
                    [pscustomobject]@{
                        id   = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000002'
                        name = '00000000-0000-0000-0000-000000000002'
                        roleName = 'Purview-Lab-KV-Firewall-Toggler'
                    }
                ) | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = Resolve-KvFirewallTogglerRole
        $result | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000002'
        $script:AzInvocations.Count | Should -Be 1
        ($script:AzInvocations[0] -join ' ') | Should -Match 'role definition list'
        ($script:AzInvocations[0] -join ' ') | Should -Match '--custom-role-only true'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'Purview-Lab-KV-Firewall-Toggler'
    }

    It 'throws with the infra/main.bicep fail-closed guidance when az returns an empty list' {
        $script:AzResponses.Enqueue('[]')

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        { Resolve-KvFirewallTogglerRole } |
            Should -Throw -ExpectedMessage '*infra/main.bicep*'
    }

    It 'throws when az returns more than one custom role of that name' {
        $script:AzResponses.Enqueue((@(
                    [pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000003'; name = '00000000-0000-0000-0000-000000000003' },
                    [pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000001/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000004'; name = '00000000-0000-0000-0000-000000000004' }
                ) | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        { Resolve-KvFirewallTogglerRole } |
            Should -Throw -ExpectedMessage '*Found 2 custom roles*'
    }
}

Describe 'Resolve-KvUnlockSp' {

    BeforeEach {
        $script:AzInvocations = New-Object System.Collections.Generic.List[object]
    }

    It 'throws and names New-KvUnlockEntraApp.ps1 when the app list is empty' {
        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return '[]'
        }

        { Resolve-KvUnlockSp -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*New-KvUnlockEntraApp.ps1*'
    }

    It 'throws when more than one app shares the kv-unlock display name' {
        $duplicates = (@(
                [pscustomobject]@{ appId = '00000000-0000-0000-0000-000000000010'; displayName = 'gh-oidc-purview-kv-unlock' },
                [pscustomobject]@{ appId = '00000000-0000-0000-0000-000000000011'; displayName = 'gh-oidc-purview-kv-unlock' }
            ) | ConvertTo-Json -Depth 5)

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            return $duplicates
        }

        { Resolve-KvUnlockSp -DisplayName 'gh-oidc-purview-kv-unlock' } |
            Should -Throw -ExpectedMessage '*Found 2 Entra applications*'
    }

    It 'returns the SP object ID when one app and one SP resolve cleanly' {
        $appListJson = (@(
                [pscustomobject]@{ appId = '00000000-0000-0000-0000-000000000020'; displayName = 'gh-oidc-purview-kv-unlock' }
            ) | ConvertTo-Json -Depth 5)
        $spJson = ([pscustomobject]@{
                id          = '00000000-0000-0000-0000-000000000021'
                appId       = '00000000-0000-0000-0000-000000000020'
                displayName = 'gh-oidc-purview-kv-unlock'
            } | ConvertTo-Json -Depth 5)

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match '^ad app list') { return $appListJson }
            if ($joined -match '^ad sp show')  { return $spJson }
            throw "Unexpected az invocation in test: $joined"
        }

        $objectId = Resolve-KvUnlockSp -DisplayName 'gh-oidc-purview-kv-unlock'
        $objectId | Should -Be '00000000-0000-0000-0000-000000000021'
        $script:AzInvocations.Count | Should -Be 2
        ($script:AzInvocations[0] -join ' ') | Should -Match 'ad app list .*--display-name gh-oidc-purview-kv-unlock'
        ($script:AzInvocations[1] -join ' ') | Should -Match 'ad sp show .*--id 00000000-0000-0000-0000-000000000020'
    }

    It 'post-filters the app list on exact displayName even when az returns near-matches' {
        $appListJson = (@(
                [pscustomobject]@{ appId = '00000000-0000-0000-0000-000000000030'; displayName = 'gh-oidc-purview-kv-unlock-old' },
                [pscustomobject]@{ appId = '00000000-0000-0000-0000-000000000031'; displayName = 'gh-oidc-purview-kv-unlock' }
            ) | ConvertTo-Json -Depth 5)
        $spJson = ([pscustomobject]@{
                id          = '00000000-0000-0000-0000-000000000032'
                appId       = '00000000-0000-0000-0000-000000000031'
                displayName = 'gh-oidc-purview-kv-unlock'
            } | ConvertTo-Json -Depth 5)

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            $joined = $args -join ' '
            if ($joined -match '^ad app list') { return $appListJson }
            if ($joined -match '^ad sp show')  { return $spJson }
            throw "Unexpected az invocation in test: $joined"
        }

        $objectId = Resolve-KvUnlockSp -DisplayName 'gh-oidc-purview-kv-unlock'
        $objectId | Should -Be '00000000-0000-0000-0000-000000000032'
    }
}
