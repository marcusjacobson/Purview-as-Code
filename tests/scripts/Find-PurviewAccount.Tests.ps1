#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Find-PurviewAccount.ps1 (ADR 0048).

.DESCRIPTION
    AST-extracts the internal helper functions and exercises them without a
    live tenant:
      - ConvertTo-PurviewAccountResult: pure shaping + ADR 0048 classification.
      - Get-PurviewVisibleSubscription: az account list wrapper, az stubbed.
      - Get-PurviewAccountResource:    az resource list wrapper, az stubbed.

    Synthetic GUIDs follow the 00000000-0000-0000-0000-0000000000NN pattern.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-list
    Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-list
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Find-PurviewAccount.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Find-PurviewAccount.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @('ConvertTo-PurviewAccountResult', 'Get-PurviewVisibleSubscription', 'Get-PurviewAccountResource')) {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fnName
            }, $true)
        if (-not $fnAst) {
            throw "Function '$fnName' not found in $script:ScriptPath"
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Stub the script-scoped variable the extracted functions reference.
    $script:ZeroGuid = '00000000-0000-0000-0000-000000000000'
}

Describe 'ConvertTo-PurviewAccountResult' {

    It 'redacts SubscriptionId to the zero-GUID by default' {
        $accounts = @(
            [pscustomobject]@{
                name          = 'purview-contoso-lab'
                resourceGroup = 'rg-purview-lab'
                location      = 'eastus'
                sku           = [pscustomobject]@{ name = 'Standard' }
            }
        )

        $result = ConvertTo-PurviewAccountResult `
            -Account $accounts `
            -SubscriptionName 'Contoso Lab' `
            -SubscriptionId '00000000-0000-0000-0000-000000000010'

        $result.Name             | Should -Be 'purview-contoso-lab'
        $result.ResourceGroup    | Should -Be 'rg-purview-lab'
        $result.Location         | Should -Be 'eastus'
        $result.Sku              | Should -Be 'Standard'
        $result.SubscriptionName | Should -Be 'Contoso Lab'
        $result.SubscriptionId   | Should -Be '00000000-0000-0000-0000-000000000000'
        $result.Classification   | Should -Be 'RequiresOwnerConfirmation'
    }

    It 'emits the real SubscriptionId only when -IncludeSubscriptionId is set' {
        $accounts = @(
            [pscustomobject]@{ name = 'purview-contoso-lab'; resourceGroup = 'rg-purview-lab'; location = 'eastus'; sku = [pscustomobject]@{ name = 'Standard' } }
        )

        $result = ConvertTo-PurviewAccountResult `
            -Account $accounts `
            -SubscriptionName 'Contoso Lab' `
            -SubscriptionId '00000000-0000-0000-0000-000000000015' `
            -IncludeSubscriptionId

        $result.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000015'
    }

    It 'notes that a metering resource is not a governance target and cites ADR 0048' {
        $accounts = @(
            [pscustomobject]@{ name = 'payg-billing'; resourceGroup = 'rg-meter'; location = 'westus'; sku = $null }
        )

        $result = ConvertTo-PurviewAccountResult `
            -Account $accounts `
            -SubscriptionName 'Contoso Lab' `
            -SubscriptionId '00000000-0000-0000-0000-000000000011'

        $result.Note | Should -Match 'NOT a governance target'
        $result.Note | Should -Match 'ADR 0048'
        $result.Note | Should -Match 'Classic-vs-unified'
    }

    It 'maps a null sku to $null rather than throwing' {
        $accounts = @(
            [pscustomobject]@{ name = 'no-sku'; resourceGroup = 'rg-x'; location = 'eastus'; sku = $null }
        )

        $result = ConvertTo-PurviewAccountResult `
            -Account $accounts `
            -SubscriptionName 'Contoso Lab' `
            -SubscriptionId '00000000-0000-0000-0000-000000000012'

        $result.Sku | Should -BeNullOrEmpty
    }

    It 'returns one object per account when several are supplied' {
        $accounts = @(
            [pscustomobject]@{ name = 'acct-a'; resourceGroup = 'rg-a'; location = 'eastus'; sku = [pscustomobject]@{ name = 'Standard' } },
            [pscustomobject]@{ name = 'acct-b'; resourceGroup = 'rg-b'; location = 'westus'; sku = [pscustomobject]@{ name = 'Free' } }
        )

        $result = @(ConvertTo-PurviewAccountResult `
                -Account $accounts `
                -SubscriptionName 'Contoso Lab' `
                -SubscriptionId '00000000-0000-0000-0000-000000000013')

        $result.Count | Should -Be 2
        $result[0].Name | Should -Be 'acct-a'
        $result[1].Name | Should -Be 'acct-b'
    }

    It 'emits nothing for an empty account collection' {
        $result = @(ConvertTo-PurviewAccountResult `
                -Account @() `
                -SubscriptionName 'Contoso Lab' `
                -SubscriptionId '00000000-0000-0000-0000-000000000014')

        $result.Count | Should -Be 0
    }
}

Describe 'Get-PurviewVisibleSubscription' {

    BeforeEach {
        $script:AzInvocations = New-Object System.Collections.Generic.List[object]
        $script:AzResponses = New-Object System.Collections.Generic.Queue[string]
    }

    It 'returns the subscriptions parsed from az account list' {
        $script:AzResponses.Enqueue((@(
                    [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000030'; name = 'Contoso Lab'; tenantId = '00000000-0000-0000-0000-000000000031'; state = 'Enabled' }
                ) | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            $global:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = @(Get-PurviewVisibleSubscription)

        $result.Count | Should -Be 1
        $result[0].Id | Should -Be '00000000-0000-0000-0000-000000000030'
        $result[0].Name | Should -Be 'Contoso Lab'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'account list'
    }

    It 'throws with az-login guidance when az exits non-zero' {
        $script:AzResponses.Enqueue('')

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 1
            $global:LASTEXITCODE = 1
            return $script:AzResponses.Dequeue()
        }

        { Get-PurviewVisibleSubscription } |
            Should -Throw -ExpectedMessage '*az login*'
    }
}

Describe 'Get-PurviewAccountResource' {

    BeforeEach {
        $script:AzInvocations = New-Object System.Collections.Generic.List[object]
        $script:AzResponses = New-Object System.Collections.Generic.Queue[string]
    }

    It 'lists Microsoft.Purview/accounts scoped to the requested subscription' {
        $script:AzResponses.Enqueue((@(
                    [pscustomobject]@{ name = 'purview-contoso-lab'; resourceGroup = 'rg-purview-lab'; location = 'eastus'; sku = [pscustomobject]@{ name = 'Standard' } }
                ) | ConvertTo-Json -Depth 5))

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            $global:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = @(Get-PurviewAccountResource -SubscriptionId '00000000-0000-0000-0000-000000000040')

        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'purview-contoso-lab'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'resource list'
        ($script:AzInvocations[0] -join ' ') | Should -Match 'Microsoft.Purview/accounts'
        ($script:AzInvocations[0] -join ' ') | Should -Match '00000000-0000-0000-0000-000000000040'
    }

    It 'returns an empty collection when the subscription has no Purview accounts' {
        $script:AzResponses.Enqueue('[]')

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 0
            $global:LASTEXITCODE = 0
            return $script:AzResponses.Dequeue()
        }

        $result = @(Get-PurviewAccountResource -SubscriptionId '00000000-0000-0000-0000-000000000041')
        $result.Count | Should -Be 0
    }

    It 'throws a redacted, Reader-access, discovery-incomplete error when az exits non-zero' {
        $script:AzResponses.Enqueue('')

        function az {
            $script:AzInvocations.Add(@($args))
            $script:LASTEXITCODE = 1
            $global:LASTEXITCODE = 1
            return $script:AzResponses.Dequeue()
        }

        $err = { Get-PurviewAccountResource -SubscriptionId '00000000-0000-0000-0000-000000000042' } |
            Should -Throw -PassThru

        $err.Exception.Message | Should -Match 'Reader'
        $err.Exception.Message | Should -Match 'discovery is incomplete'
        # The real subscription ID must be redacted to the zero-GUID, not echoed.
        $err.Exception.Message | Should -Match '00000000-0000-0000-0000-000000000000'
        $err.Exception.Message | Should -Not -Match '00000000-0000-0000-0000-000000000042'
    }
}

Describe 'Find-PurviewAccount (Get-PurviewAccountDiscovery orchestration)' {

    BeforeAll {
        # Extract the orchestration function and shadow its az-backed sibling
        # getters with in-scope stubs (per tests.instructions.md). ConvertTo-
        # PurviewAccountResult resolves to the real function dot-sourced in the
        # top-level BeforeAll, so shaping + redaction are exercised for real.
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-PurviewAccountDiscovery'
            }, $true)
        if (-not $fnAst) {
            throw "Function 'Get-PurviewAccountDiscovery' not found in $script:ScriptPath"
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))

        function Get-PurviewVisibleSubscription { $script:StubSubs }

        function Get-PurviewAccountResource {
            [CmdletBinding()]
            param([Parameter(Mandatory = $true)][string]$SubscriptionId)
            $script:StubResourceCalls.Add($SubscriptionId)
            if ($script:StubAccountsBySub.ContainsKey($SubscriptionId)) {
                return @($script:StubAccountsBySub[$SubscriptionId])
            }
            return @()
        }
    }

    BeforeEach {
        $script:StubResourceCalls = New-Object System.Collections.Generic.List[string]
        $script:StubSubs = @(
            [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000050'; Name = 'Contoso Lab'; TenantId = '00000000-0000-0000-0000-000000000051'; State = 'Enabled' },
            [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000052'; Name = 'Contoso Sandbox'; TenantId = '00000000-0000-0000-0000-000000000051'; State = 'Enabled' }
        )
        $script:StubAccountsBySub = @{
            '00000000-0000-0000-0000-000000000050' = [pscustomobject]@{ name = 'purview-contoso-lab'; resourceGroup = 'rg-purview-lab'; location = 'eastus'; sku = [pscustomobject]@{ name = 'Standard' } }
            '00000000-0000-0000-0000-000000000052' = [pscustomobject]@{ name = 'purview-sandbox'; resourceGroup = 'rg-sandbox'; location = 'westus'; sku = $null }
        }
    }

    It 'aggregates one hit per visible subscription and scans each once' {
        $result = @(Get-PurviewAccountDiscovery -InformationAction SilentlyContinue)

        $result.Count | Should -Be 2
        ($result.Name | Sort-Object) | Should -Be @('purview-contoso-lab', 'purview-sandbox')
        $script:StubResourceCalls.Count | Should -Be 2
    }

    It 'filters to a single account with -Name' {
        $result = @(Get-PurviewAccountDiscovery -Name 'purview-sandbox' -InformationAction SilentlyContinue)

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'purview-sandbox'
    }

    It 'scans only the requested subscription with -SubscriptionId' {
        $result = @(Get-PurviewAccountDiscovery -SubscriptionId '00000000-0000-0000-0000-000000000050' -InformationAction SilentlyContinue)

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be 'purview-contoso-lab'
        $script:StubResourceCalls.Count | Should -Be 1
        $script:StubResourceCalls[0] | Should -Be '00000000-0000-0000-0000-000000000050'
    }

    It 'throws when no requested subscription is visible' {
        { Get-PurviewAccountDiscovery -SubscriptionId '00000000-0000-0000-0000-000000000099' -InformationAction SilentlyContinue } |
            Should -Throw -ExpectedMessage '*None of the requested subscription IDs are visible*'
    }

    It 'redacts SubscriptionId to the zero-GUID by default' {
        $result = @(Get-PurviewAccountDiscovery -Name 'purview-contoso-lab' -InformationAction SilentlyContinue)

        $result[0].SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000000'
    }

    It 'emits the real SubscriptionId with -IncludeSubscriptionId' {
        $result = @(Get-PurviewAccountDiscovery -Name 'purview-contoso-lab' -IncludeSubscriptionId -InformationAction SilentlyContinue)

        $result[0].SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000050'
    }

    It 'returns an empty, non-error result when a name matches nothing (not found in ARM)' {
        $result = @(Get-PurviewAccountDiscovery -Name 'does-not-exist' -InformationAction SilentlyContinue)

        $result.Count | Should -Be 0
    }

    It 'returns an empty, non-error result when no subscription has any account' {
        $script:StubAccountsBySub = @{}

        $result = @(Get-PurviewAccountDiscovery -InformationAction SilentlyContinue)

        $result.Count | Should -Be 0
    }
}
