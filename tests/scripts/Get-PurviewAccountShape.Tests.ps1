#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Get-PurviewAccountShape.ps1 (ADR 0047 item d).

.DESCRIPTION
    AST-extracts the internal helper functions and exercises the pure account-
    shape classification logic without a live tenant or Azure CLI side effects.

    Synthetic GUIDs follow the 00000000-0000-0000-0000-0000000000NN pattern.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-PurviewAccountShape.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Get-PurviewAccountShape.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @(
            'Get-PurviewProbeResult',
            'Get-PurviewAccountShapeClassification'
        )) {
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

    $script:SourceText = Get-Content -LiteralPath $script:ScriptPath -Raw
}

Describe 'Get-PurviewAccountShapeClassification' {

    It 'classifies classic success and unified unreachable as Classic' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $true `
            -ClassicStatusCode 200 `
            -ClassicTransportError $false `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $false `
            -UnifiedStatusCode $null `
            -UnifiedTransportError $true

        $result.Shape | Should -Be 'Classic'
        $result.ClassicProbeResult | Should -Be 'ClassicReachable'
        $result.UnifiedProbeResult | Should -Be 'UnifiedUnreachable'
    }

    It 'classifies unified success and classic unreachable as Unified' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $false `
            -ClassicStatusCode $null `
            -ClassicTransportError $true `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $true `
            -UnifiedStatusCode 200 `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Unified'
        $result.ClassicProbeResult | Should -Be 'ClassicUnreachable'
        $result.UnifiedProbeResult | Should -Be 'UnifiedReachable'
    }

    It 'classifies both successes as Ambiguous' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $true `
            -ClassicStatusCode 200 `
            -ClassicTransportError $false `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $true `
            -UnifiedStatusCode 200 `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Ambiguous'
        $result.Note | Should -Match 'must not be treated as an error'
    }

    It 'classifies both failures as Indeterminate and never coerces to Classic' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $false `
            -ClassicStatusCode $null `
            -ClassicTransportError $true `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $false `
            -UnifiedStatusCode 404 `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Indeterminate'
        $result.ClassicProbeResult | Should -Be 'ClassicUnreachable'
        $result.UnifiedProbeResult | Should -Be 'UnifiedUnreachable'
        $result.Note | Should -Match 'Never silently assume Classic or Unified'
    }

    It 'treats classic 401 as Indeterminate, not a false negative' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $false `
            -ClassicStatusCode 401 `
            -ClassicTransportError $false `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $false `
            -UnifiedStatusCode 404 `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Indeterminate'
        $result.ClassicProbeResult | Should -Be 'ClassicUnauthorized'
    }

    It 'treats unified 403 as Indeterminate, not a false negative' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $true `
            -ClassicSucceeded $false `
            -ClassicStatusCode $null `
            -ClassicTransportError $true `
            -UnifiedTokenAcquired $true `
            -UnifiedSucceeded $false `
            -UnifiedStatusCode 403 `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Indeterminate'
        $result.UnifiedProbeResult | Should -Be 'UnifiedUnauthorized'
    }

    It 'treats skipped token acquisition as Indeterminate' {
        $result = Get-PurviewAccountShapeClassification `
            -ClassicTokenAcquired $false `
            -ClassicSucceeded $false `
            -ClassicStatusCode $null `
            -ClassicTransportError $false `
            -UnifiedTokenAcquired $false `
            -UnifiedSucceeded $false `
            -UnifiedStatusCode $null `
            -UnifiedTransportError $false

        $result.Shape | Should -Be 'Indeterminate'
        $result.ClassicProbeResult | Should -Be 'ClassicProbeSkipped'
        $result.UnifiedProbeResult | Should -Be 'UnifiedProbeSkipped'
    }
}

Describe 'Get-PurviewAccountShape source surface' {

    It 'defines the required functions in source' {
        foreach ($fnName in @(
                'Invoke-PurviewClassicCatalogProbe',
                'Invoke-PurviewUnifiedCatalogProbe',
                'Get-PurviewProbeResult',
                'Get-PurviewAccountShapeClassification'
            )) {
            $fnAst = $script:Ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fnName
                }, $true)
            $fnAst | Should -Not -BeNullOrEmpty
        }
    }

    It 'defines the required parameters in the top-level param block' {
        $paramNames = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        $paramNames | Should -Contain 'AccountName'
        $paramNames | Should -Contain 'ParametersFile'
        $paramNames | Should -Contain 'SubscriptionId'
    }

    It 'pins the unified probe to the tenant-scoped host and preview api-version' {
        $script:SourceText | Should -Match 'https://api\.purview-service\.microsoft\.com'
        $script:SourceText | Should -Match '2026-03-20-preview'
        $script:SourceText | Should -Match 'api-version justification'
    }
}
