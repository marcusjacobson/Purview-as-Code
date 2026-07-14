#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-UnifiedCatalog.ps1.

.DESCRIPTION
    The production script performs top-level work at import time, so the tests
    AST-extract the pure helper functions we want to exercise.
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

    if ($errors.Count -gt 0) {
        throw ($errors | ForEach-Object Message | Out-String)
    }

    foreach ($fnName in @(
            'Get-DesiredItem',
            'ConvertTo-JsonComparable',
            'ConvertTo-StringArrayNormalized',
            'ConvertTo-StatusFromDesired',
            'ConvertTo-StatusToDesired',
            'ConvertTo-BusinessDomainTypeFromDesired',
            'ConvertTo-CdeDataTypeFromDesired',
            'Resolve-DesiredNumericValue',
            'ConvertTo-ReportRow',
            'ConvertTo-BusinessDomainComparableDesired',
            'ConvertTo-BusinessDomainComparableTenant',
            'Compare-ComparableFieldSet',
            'Get-EntityDisplayName',
            'Test-IsConflict',
            'Get-ReconciliationPlan',
            'Invoke-DirectionPolicyPlan'
        )) {
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

    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop

    $script:RepoUcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'data-plane' 'unified-catalog')).Path
    $script:CurrentPrincipalIds = @('current-principal')
    $script:SkipNameList = @()
}

Describe 'Get-DesiredItem (schema validation)' {
    It 'accepts an empty items list against the business-domains schema' {
        $yaml = Join-Path $TestDrive 'gov-empty.yaml'
        Set-Content -LiteralPath $yaml -Value "items: []`n"
        $schema = Join-Path $script:RepoUcRoot 'business-domains.schema.json'

        $result = @(Get-DesiredItem -YamlPath $yaml -SchemaPath $schema)
        $result.Count | Should -Be 0
    }

    It 'accepts a well-formed business domain' {
        $yaml = Join-Path $TestDrive 'gov-one.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - name: Finance
    type: BusinessUnit
    status: Draft
"@
        $schema = Join-Path $script:RepoUcRoot 'business-domains.schema.json'

        $result = @(Get-DesiredItem -YamlPath $yaml -SchemaPath $schema)
        $result.Count | Should -Be 1
        $result[0].name | Should -Be 'Finance'
    }

    It 'rejects a malformed enum value' {
        $yaml = Join-Path $TestDrive 'gov-bad.yaml'
        Set-Content -LiteralPath $yaml -Value @"
items:
  - name: Finance
    type: Bogus
"@
        $schema = Join-Path $script:RepoUcRoot 'business-domains.schema.json'

        { Get-DesiredItem -YamlPath $yaml -SchemaPath $schema } | Should -Throw
    }
}

Describe 'Desired-state normalization helpers' {
    It 'maps BusinessUnit to the preview API enum' {
        $item = [pscustomobject]@{ name = 'Finance'; type = 'BusinessUnit'; status = 'Draft' }
        $result = ConvertTo-BusinessDomainComparableDesired -Item $item
        $result.type | Should -Be 'LineOfBusiness'
    }

    It 'maps Identifier to a supported preview CDE data type' {
        ConvertTo-CdeDataTypeFromDesired -Type 'Identifier' | Should -Be 'TEXT'
    }

    It 'parses numeric key-result values and rejects text ranges' {
        Resolve-DesiredNumericValue -Value '42.5' | Should -Be 42.5
        Resolve-DesiredNumericValue -Value '<= 2 per quarter' | Should -BeNullOrEmpty
    }

    It 'normalizes duplicate string arrays' {
        @(ConvertTo-StringArrayNormalized -Values @('Finance', 'finance', 'Finance'))[0] | Should -Be 'finance' -Because 'Sort-Object is case-insensitive on strings'
    }

    It 'preserves a single normalized value as an array' {
        $result = ConvertTo-StringArrayNormalized -Values 'Creator'
        $result -is [System.Array] | Should -BeTrue
        $result | Should -Be @('Creator')
    }
}

Describe 'Get-ReconciliationPlan' {
    BeforeEach {
        $script:CurrentPrincipalIds = @('current-principal')
    }

    It 'returns Create rows when an item is only in desired state' {
        $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Draft' })
        $plan = Get-ReconciliationPlan `
            -Kind 'BusinessDomain' `
            -DesiredItems $desired `
            -TenantItems @() `
            -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
            -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
            -DesiredKeySelector { param($item) [string]$item.name } `
            -TenantKeySelector { param($item) [string]$item.name }

        $plan.Report[0].Category | Should -Be 'Create'
        $plan.Plan[0].Action | Should -Be 'Create'
    }

    It 'returns NoChange rows when comparable state matches' {
        $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Draft' })
        $tenant = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'LineOfBusiness'; status = 'Draft'; systemData = [pscustomobject]@{ lastModifiedBy = 'current-principal' } })
        $plan = Get-ReconciliationPlan `
            -Kind 'BusinessDomain' `
            -DesiredItems $desired `
            -TenantItems $tenant `
            -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
            -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
            -DesiredKeySelector { param($item) [string]$item.name } `
            -TenantKeySelector { param($item) [string]$item.name }

        $plan.Report[0].Category | Should -Be 'NoChange'
        $plan.Plan.Count | Should -Be 0
    }

    It 'returns Update rows when comparable state differs and the current principal owns the tenant object' {
        $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Published' })
        $tenant = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'LineOfBusiness'; status = 'Draft'; systemData = [pscustomobject]@{ lastModifiedBy = 'current-principal' } })
        $plan = Get-ReconciliationPlan `
            -Kind 'BusinessDomain' `
            -DesiredItems $desired `
            -TenantItems $tenant `
            -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
            -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
            -DesiredKeySelector { param($item) [string]$item.name } `
            -TenantKeySelector { param($item) [string]$item.name }

        $plan.Report[0].Category | Should -Be 'Update'
        $plan.Plan[0].Action | Should -Be 'Update'
        $plan.Plan[0].Fields | Should -Contain 'status'
    }

    It 'returns Conflict rows when a different principal last modified the tenant object' {
        $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Published' })
        $tenant = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'LineOfBusiness'; status = 'Draft'; systemData = [pscustomobject]@{ lastModifiedBy = 'other-principal' } })
        $plan = Get-ReconciliationPlan `
            -Kind 'BusinessDomain' `
            -DesiredItems $desired `
            -TenantItems $tenant `
            -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
            -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
            -DesiredKeySelector { param($item) [string]$item.name } `
            -TenantKeySelector { param($item) [string]$item.name }

        $plan.Report[0].Category | Should -Be 'Conflict'
        $plan.Plan.Count | Should -Be 0
        # ADR 0053: the Reason must name -OverwriteForeignAuthor, not -Force.
        # -Force no longer authorizes an authorship overwrite, so telling the
        # operator to "re-run with -Force" would send them to a switch that
        # does not do it.
        $plan.Report[0].Reason | Should -Match '-OverwriteForeignAuthor'
        $plan.Report[0].Reason | Should -Not -Match '-Force'
    }
}

Describe 'Invoke-DirectionPolicyPlan' {
    BeforeEach {
        $script:SkipNameList = @()
    }

    It 'converts Update rows to Skip rows under portal-wins' {
        $DirectionPolicy = 'portal-wins'
        $plan = New-Object 'System.Collections.Generic.List[object]'
        $report = New-Object 'System.Collections.Generic.List[object]'
        $plan.Add([pscustomobject]@{ Action = 'Update'; Kind = 'BusinessDomain'; Name = 'Finance'; Fields = @('status'); Conflict = $false }) | Out-Null
        $report.Add((ConvertTo-ReportRow -Category 'Update' -Kind 'BusinessDomain' -Name 'Finance' -Fields @('status'))) | Out-Null

        Invoke-DirectionPolicyPlan -Plan $plan -Report $report

        $plan.Count | Should -Be 0
        ($report | Where-Object Category -eq 'Skip').Count | Should -Be 1
    }

    It 'keeps Update rows under repo-wins' {
        $DirectionPolicy = 'repo-wins'
        $plan = New-Object 'System.Collections.Generic.List[object]'
        $report = New-Object 'System.Collections.Generic.List[object]'
        $plan.Add([pscustomobject]@{ Action = 'Update'; Kind = 'BusinessDomain'; Name = 'Finance'; Fields = @('status'); Conflict = $false }) | Out-Null
        $report.Add((ConvertTo-ReportRow -Category 'Update' -Kind 'BusinessDomain' -Name 'Finance' -Fields @('status'))) | Out-Null

        Invoke-DirectionPolicyPlan -Plan $plan -Report $report

        $plan.Count | Should -Be 1
        ($report | Where-Object Category -eq 'Skip').Count | Should -Be 0
    }

    It 'clears the plan under audit mode' {
        $DirectionPolicy = 'audit'
        $plan = New-Object 'System.Collections.Generic.List[object]'
        $report = New-Object 'System.Collections.Generic.List[object]'
        $plan.Add([pscustomobject]@{ Action = 'Update'; Kind = 'BusinessDomain'; Name = 'Finance'; Fields = @('status'); Conflict = $false }) | Out-Null
        $report.Add((ConvertTo-ReportRow -Category 'Update' -Kind 'BusinessDomain' -Name 'Finance' -Fields @('status'))) | Out-Null

        Invoke-DirectionPolicyPlan -Plan $plan -Report $report

        $plan.Count | Should -Be 0
    }
}

Describe 'Source surface contract' {
    It 'keeps the required reconciler switches and ADR markers in source' {
        $raw = Get-Content -LiteralPath $script:ScriptPath -Raw
        $raw | Should -Match 'SupportsShouldProcess = \$true'
        $raw | Should -Match '\[switch\]\$PruneMissing'
        $raw | Should -Match '\[switch\]\$ExportCurrentState'
        $raw | Should -Match '\[string\]\$DirectionPolicy = ''portal-wins'''
        $raw | Should -Match '\[string\[\]\]\$SkipNames = @\(\)'
        $raw | Should -Match '\[ADR0029-AUDIT\]'
        $raw | Should -Match '\[ADR0029-SKIP\]'
        $raw | Should -Match 'api-version justification:'
        $raw | Should -Match 'Connect-Purview\.ps1'
        $raw | Should -Match 'Get-EntraPrincipalIdByDisplayName\.ps1'
    }
}

Describe 'Repository unified-catalog YAMLs' {
    It 'validates every shipped unified-catalog YAML against its schema' {
        $pairs = @(
            @{ Yaml = 'business-domains.yaml'; Schema = 'business-domains.schema.json' },
            @{ Yaml = 'data-products.yaml'; Schema = 'data-products.schema.json' },
            @{ Yaml = 'critical-data-elements.yaml'; Schema = 'critical-data-elements.schema.json' },
            @{ Yaml = 'health-controls.yaml'; Schema = 'health-controls.schema.json' },
            @{ Yaml = 'okrs.yaml'; Schema = 'okrs.schema.json' },
            @{ Yaml = 'glossary-terms.yaml'; Schema = 'glossary-terms.schema.json' },
            @{ Yaml = 'data-access-policies.yaml'; Schema = 'data-access-policies.schema.json' }
        )

        foreach ($pair in $pairs) {
            $yamlPath = Join-Path $script:RepoUcRoot $pair.Yaml
            $schemaPath = Join-Path $script:RepoUcRoot $pair.Schema
            $result = @(Get-DesiredItem -YamlPath $yamlPath -SchemaPath $schemaPath)
            $result.Count | Should -Be 0 -Because "$($pair.Yaml) ships as items: []"
        }
    }
}

# ---------------------------------------------------------------------------
# ADR 0053 -- the foreign-author override is split out of -Force into its own
# switch, -OverwriteForeignAuthor.
#
# This is a Mechanism B script: Test-IsConflict is pure and the Conflict row was
# always emitted, but the plan builder took -AllowConflictOverwrite:$Force.IsPresent
# at the call site, so -Force authorised the overwrite. The fix rebinds the call
# sites to $OverwriteForeignAuthor.IsPresent and updates the Reason strings.
#
# It also carried an ambient `if ($Force.IsPresent) { $ConfirmPreference = 'None' }`
# self-disarm, which ADR 0052 line 89 forbids. It is deleted.
#
# Reference: docs/adr/0053-overwrite-foreign-author-switch.md
# ---------------------------------------------------------------------------
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-UnifiedCatalog.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-UnifiedCatalog.ps1'
        $script:Adr0053Source = Get-Content -Path $script:Adr0053Path -Raw

        $adr0053Tokens = $null
        $adr0053Errors = $null
        $script:Adr0053Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Adr0053Path, [ref]$adr0053Tokens, [ref]$adr0053Errors)
        if ($adr0053Errors.Count -gt 0) {
            throw ($adr0053Errors | ForEach-Object Message | Out-String)
        }

        $script:CurrentPrincipalIds = @('current-principal')
    }

    Context 'Parameter surface -- Apply set only' {

        It 'declares -OverwriteForeignAuthor in the Apply parameter set' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $apply = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Apply' })
            $apply.Count | Should -Be 1
            $apply[0].Parameters.Name | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'does NOT declare -OverwriteForeignAuthor in the Export parameter set' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $export = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Export' })
            $export.Count | Should -Be 1
            $export[0].Parameters.Name | Should -Not -Contain 'OverwriteForeignAuthor'
        }

        It 'keeps -Force bindable in BOTH parameter sets (the Export-path callers do not break)' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            foreach ($setName in @('Apply', 'Export')) {
                $set = @($cmd.ParameterSets | Where-Object { $_.Name -eq $setName })
                $set[0].Parameters.Name | Should -Contain 'Force'
            }
        }
    }

    Context 'Call-site binding' {

        It 'binds every Get-ReconciliationPlan call from $OverwriteForeignAuthor and never from $Force' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Get-ReconciliationPlan'
                    }, $true))

            # Six concept plans: BusinessDomain, DataProduct, Okr, OkrKeyResult,
            # CriticalDataElement, Term.
            $calls.Count | Should -Be 6
            foreach ($call in $calls) {
                $callText = $call.Extent.Text
                $callText | Should -Match '-AllowConflictOverwrite:\$OverwriteForeignAuthor\.IsPresent'
                $callText | Should -Not -Match '-AllowConflictOverwrite:\$Force'
            }
        }

        It 'has zero -AllowConflictOverwrite bindings sourced from $Force anywhere in the file' {
            $script:Adr0053Source | Should -Not -Match '-AllowConflictOverwrite:\$Force'
        }
    }

    Context 'Ambient self-disarm deleted (ADR 0053 section 4)' {

        It 'no longer assigns $ConfirmPreference = None under -Force' {
            # Asserted over the AST, NOT the raw source text. A raw-text regex
            # here would match the explanatory COMMENT in the script that quotes
            # the forbidden assignment -- which is precisely the read-a-comment-
            # as-code error ADR 0053 records ADR 0052 making. Guard on the
            # AssignmentStatementAst nodes, which prose cannot forge.
            $assignments = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'ConfirmPreference'
                    }, $true))
            $assignments.Count | Should -Be 0
        }
    }

    Context 'Under -Force alone, a foreign-authored drifted object is reported and NOT overwritten' {

        It 'emits a Conflict row and produces no plan entry when -AllowConflictOverwrite is absent' {
            # -Force alone now leaves $OverwriteForeignAuthor.IsPresent = $false,
            # which is what the call site passes here.
            $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Published' })
            $tenant = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'LineOfBusiness'; status = 'Draft'; systemData = [pscustomobject]@{ lastModifiedBy = 'other-principal' } })
            $plan = Get-ReconciliationPlan `
                -Kind 'BusinessDomain' `
                -DesiredItems $desired `
                -TenantItems $tenant `
                -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
                -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
                -DesiredKeySelector { param($item) [string]$item.name } `
                -TenantKeySelector { param($item) [string]$item.name } `
                -AllowConflictOverwrite:$false

            $plan.Report[0].Category | Should -Be 'Conflict'
            $plan.Plan.Count | Should -Be 0
            $plan.Report[0].Reason | Should -Match '-OverwriteForeignAuthor'
            $plan.Report[0].Reason | Should -Not -Match '-Force'
        }

        It 'still emits the Conflict row when the overwrite IS authorised -- the switch grants permission, not silence' {
            $desired = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'BusinessUnit'; status = 'Published' })
            $tenant = @([pscustomobject]@{ name = 'Finance'; description = 'A'; type = 'LineOfBusiness'; status = 'Draft'; systemData = [pscustomobject]@{ lastModifiedBy = 'other-principal' } })
            $plan = Get-ReconciliationPlan `
                -Kind 'BusinessDomain' `
                -DesiredItems $desired `
                -TenantItems $tenant `
                -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } `
                -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } `
                -DesiredKeySelector { param($item) [string]$item.name } `
                -TenantKeySelector { param($item) [string]$item.name } `
                -AllowConflictOverwrite:$true

            $plan.Report[0].Category | Should -Be 'Conflict'
            $plan.Report[0].Reason | Should -Match 'overwritten because -OverwriteForeignAuthor was supplied'
            $plan.Plan[0].Action | Should -Be 'Update'
        }
    }
}
