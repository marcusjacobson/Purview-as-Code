#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for `scripts/Deploy-UnifiedCatalog.ps1`.

.DESCRIPTION
    Issue #340 — Wave 4b-ii placeholder reconciler. Tests cover:

      - Schema validation positive path (each shipped YAML validates).
      - Schema validation negative path (malformed fixtures rejected).
      - Plan emission against an empty tenant baseline.

    The production script performs top-level work at import time
    (parameter resolution, az CLI hand-off in later iterations), so we
    AST-extract the helper functions and evaluate them into the test
    scope. See `Deploy-Policies.Tests.ps1` for the same pattern.

    References:
      https://learn.microsoft.com/en-us/purview/unified-catalog
      https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-UnifiedCatalog.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-UnifiedCatalog.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @('Get-DesiredItem', 'Get-ConceptPlan')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fnName
            }, $true)
        if (-not $fnAst) {
            throw "Function $fnName not found in $script:ScriptPath"
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # AST-extracted Get-DesiredItem calls ConvertFrom-Yaml; ensure the module
    # is available in the test session without invoking the production
    # bootstrap path.
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop

    $script:RepoUcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'data-plane' 'unified-catalog')).Path
}

Describe 'Get-DesiredItem (schema validation)' {
    It 'accepts an empty items list against the governance-domains schema' {
        $yaml = Join-Path $TestDrive 'gov-empty.yaml'
        Set-Content -LiteralPath $yaml -Value "items: []`n"
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        $result = @(Get-DesiredItem -YamlPath $yaml -SchemaPath $schema)
        $result.Count | Should -Be 0
    }

    It 'accepts a well-formed governance domain' {
        $yaml = Join-Path $TestDrive 'gov-one.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - name: Finance
    type: BusinessUnit
    status: Draft
"@
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        $result = @(Get-DesiredItem -YamlPath $yaml -SchemaPath $schema)
        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'Finance'
    }

    It 'rejects a malformed entry that violates the enum constraint' {
        $yaml = Join-Path $TestDrive 'gov-bad.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - name: Finance
    type: Bogus
"@
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } | Should -Throw
    }

    It 'rejects an entry missing the required name property' {
        $yaml = Join-Path $TestDrive 'gov-no-name.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - type: BusinessUnit
"@
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } | Should -Throw
    }

    It 'throws when the YAML file is missing' {
        $yaml = Join-Path $TestDrive 'does-not-exist.yaml'
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } |
            Should -Throw -ExpectedMessage "*not found*"
    }

    It 'throws when the schema file is missing' {
        $yaml = Join-Path $TestDrive 'gov-no-schema.yaml'
        Set-Content -LiteralPath $yaml -Value "items: []`n"
        $schema = Join-Path $TestDrive 'absent.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } |
            Should -Throw -ExpectedMessage "*not found*"
    }

    It 'throws when the YAML is missing the top-level items key' {
        $yaml = Join-Path $TestDrive 'gov-no-items.yaml'
        Set-Content -LiteralPath $yaml -Value "other: []`n"
        $schema = Join-Path $script:RepoUcRoot 'governance-domains.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } | Should -Throw
    }
}

Describe 'Get-ConceptPlan (empty-baseline plan emission)' {
    It 'returns a single NoChange row when desired is empty' {
        $plan = @(Get-ConceptPlan -Concept 'GovernanceDomain' -Desired @())
        $plan.Count | Should -Be 1
        $plan[0].Concept | Should -Be 'GovernanceDomain'
        $plan[0].Action | Should -Be 'NoChange'
        $plan[0].Name | Should -Be '(none)'
    }

    It 'returns one Create row per desired item, preserving order' {
        $desired = @(
            [pscustomobject]@{ name = 'Finance' }
            [pscustomobject]@{ name = 'Sales' }
        )
        $plan = @(Get-ConceptPlan -Concept 'GovernanceDomain' -Desired $desired)
        $plan.Count | Should -Be 2
        @($plan | ForEach-Object Action) | Should -Be @('Create', 'Create')
        @($plan | ForEach-Object Name)   | Should -Be @('Finance', 'Sales')
    }

    It 'preserves the concept label on every row' {
        $desired = @([pscustomobject]@{ name = 'Customer Tax ID' })
        $plan = @(Get-ConceptPlan -Concept 'CriticalDataElement' -Desired $desired)
        $plan[0].Concept | Should -Be 'CriticalDataElement'
        $plan[0].Name    | Should -Be 'Customer Tax ID'
    }
}

Describe 'Repository unified-catalog YAMLs (smoke against shipped schemas)' {
    It 'validates every committed unified-catalog YAML against its schema' {
        $pairs = @(
            @{ Yaml = 'governance-domains.yaml'    ; Schema = 'governance-domains.schema.json' },
            @{ Yaml = 'data-products.yaml'         ; Schema = 'data-products.schema.json' },
            @{ Yaml = 'critical-data-elements.yaml'; Schema = 'critical-data-elements.schema.json' },
            @{ Yaml = 'health-controls.yaml'       ; Schema = 'health-controls.schema.json' },
            @{ Yaml = 'okrs.yaml'                  ; Schema = 'okrs.schema.json' }
        )
        foreach ($p in $pairs) {
            $yamlPath   = Join-Path $script:RepoUcRoot $p.Yaml
            $schemaPath = Join-Path $script:RepoUcRoot $p.Schema
            $result = @(Get-DesiredItem -YamlPath $yamlPath -SchemaPath $schemaPath)
            $result.Count | Should -Be 0 -Because "$($p.Yaml) is expected to ship as items: []"
        }
    }
}
