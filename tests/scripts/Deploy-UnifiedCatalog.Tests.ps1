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

# ---------------------------------------------------------------------------
# Issue #106 -- Invoke-DirectionPolicyPlan clears `$plan` under `audit` but
# cannot reach `$orphans`: a separate top-level list, populated by six
# `$orphans.Add(...)` call sites before Invoke-DirectionPolicyPlan is ever
# called, that this function is never passed and has no way to touch. Left
# alone, `-DirectionPolicy audit -PruneMissing` reached the delete loop for
# real and deleted tenant objects while the script's own log line claimed
# "no writes would have fired" -- an ADR 0029 violation.
#
# Fix: flip $WhatIfPreference at the call site (the mechanism
# Deploy-Collections.ps1 and 8 further Class A reconcilers already use), so
# every $PSCmdlet.ShouldProcess() call for the rest of the run -- both the
# create/update loop and the -PruneMissing delete loop -- renders a
# "What if:" preview instead of writing.
#
# These tests drive the ACTUAL top-level delete-loop and write-loop AST
# extracted from the committed script -- not a reimplementation -- per the
# "RED-REPLAY PROOF" acceptance criterion on #106. Manually verified against
# the pre-fix script: the delete-loop case fired 2/2 stub deletes and the
# write-loop case fired 1/1 stub create; both go to 0 after the fix, which is
# what the assertions below lock in.
# ---------------------------------------------------------------------------
Describe 'Issue #106 -- $orphans neutralized under -DirectionPolicy audit (ADR 0029)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:Issue106Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | ForEach-Object Message | Out-String) }

        # Only DIRECT top-level statements -- excludes the (already-correct,
        # differently-scoped) audit short-circuit inside the
        # Invoke-DirectionPolicyPlan FUNCTION body, so these lookups cannot
        # accidentally match that one instead of the call-site fix.
        $script:Issue106TopLevel = @($script:Issue106Ast.EndBlock.Statements)

        $script:Issue106InvokeCallAst = $script:Issue106TopLevel | Where-Object {
            $_.Extent.Text -match '^Invoke-DirectionPolicyPlan\b'
        } | Select-Object -First 1

        $script:Issue106AuditFixAst = $script:Issue106TopLevel | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -match "DirectionPolicy -eq 'audit'" -and
            $_.Extent.Text -match '\$WhatIfPreference\s*=\s*\$true'
        } | Select-Object -First 1

        $script:Issue106DeleteLoopAst = $script:Issue106TopLevel | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -match '\$PruneMissing\.IsPresent' -and
            $_.Extent.Text -match '\$orphans\.ToArray\(\)'
        } | Select-Object -First 1

        $script:Issue106WriteLoopAst = $script:Issue106TopLevel | Where-Object {
            $_.Extent.Text -match '\$writeOrder' -and
            $_.Extent.Text -match 'Invoke-UCBusinessDomainCreate'
        } | Select-Object -First 1

        if (-not $script:Issue106InvokeCallAst) { throw 'Could not locate the top-level Invoke-DirectionPolicyPlan call.' }
        if (-not $script:Issue106DeleteLoopAst) { throw 'Could not locate the top-level -PruneMissing delete-loop statement.' }
        if (-not $script:Issue106WriteLoopAst) { throw 'Could not locate the top-level $writeOrder write-loop statement.' }

        # Builds and dot-sources a throwaway function that reproduces the
        # REAL extracted top-level statements, in the same order the script
        # itself executes them: [audit fix, if present] -> [body statement].
        # $script:ReplayDeleteCalls / $script:ReplayCreateCalls record the
        # process-boundary stub calls the function makes.
        function Register-Issue106ReplayFunction {
            param(
                [Parameter(Mandatory)][string]$BodyText
            )
            $auditFixText = if ($script:Issue106AuditFixAst) { $script:Issue106AuditFixAst.Extent.Text } else { '# (no audit short-circuit present)' }
            $functionText = @"
function Invoke-Issue106Replay {
    [CmdletBinding(SupportsShouldProcess = `$true, ConfirmImpact = 'High')]
    param()
$auditFixText
$BodyText
}
"@
            . ([ScriptBlock]::Create($functionText))
        }
    }

    It 'places the audit short-circuit at top level, between Invoke-DirectionPolicyPlan and the delete loop' {
        $script:Issue106AuditFixAst | Should -Not -BeNullOrEmpty -Because 'the #106 fix sets $WhatIfPreference at the call site -- Invoke-DirectionPolicyPlan cannot reach $orphans to neutralize it there'

        $invokeIndex = $script:Issue106TopLevel.IndexOf($script:Issue106InvokeCallAst)
        $fixIndex = $script:Issue106TopLevel.IndexOf($script:Issue106AuditFixAst)
        $deleteIndex = $script:Issue106TopLevel.IndexOf($script:Issue106DeleteLoopAst)

        $invokeIndex | Should -BeGreaterThan -1
        $fixIndex | Should -BeGreaterThan $invokeIndex
        $deleteIndex | Should -BeGreaterThan $fixIndex
    }

    It 'drives the real delete-loop AST under -DirectionPolicy audit -PruneMissing and fires zero deletes' {
        $script:ReplayDeleteCalls = [System.Collections.Generic.List[string]]::new()
        # $Context is required for signature parity with the real
        # Invoke-UC*Delete call sites (each is invoked with -Context by
        # name) but this stub does not need its value.
        function Invoke-UCBusinessDomainDelete { param($Context, $DomainId) $null = $Context; $script:ReplayDeleteCalls.Add("BusinessDomain:$DomainId") }
        function Invoke-UCTermDelete { param($Context, $TermId) $null = $Context; $script:ReplayDeleteCalls.Add("Term:$TermId") }

        . Register-Issue106ReplayFunction -BodyText $script:Issue106DeleteLoopAst.Extent.Text

        # Unqualified reads inside the dot-sourced Invoke-Issue106Replay
        # function walk this scope chain, so these script-scoped
        # assignments ARE consumed at runtime even though PSScriptAnalyzer's
        # static, single-scope analysis cannot see that cross-scope read.
        $script:DirectionPolicy = 'audit'
        $script:PruneMissing = [switch]$true
        $script:context = [pscustomobject]@{ Stub = $true }
        $script:orphans = New-Object 'System.Collections.Generic.List[object]'
        $script:orphans.Add([pscustomobject]@{ Kind = 'BusinessDomain'; Item = [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; name = 'OrphanDomain' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; name = 'OrphanTerm' } }) | Out-Null

        Invoke-Issue106Replay -Confirm:$false

        $script:ReplayDeleteCalls.Count | Should -Be 0 -Because 'audit mode must fire zero deletes even with -PruneMissing and a non-empty $orphans (pre-fix this was 2/2)'
    }

    It 'drives the real write-loop AST under -DirectionPolicy audit and fires zero creates, even with a non-empty $plan (defense in depth)' {
        # In the real run $plan is already emptied by Invoke-DirectionPolicyPlan
        # before this loop is reached, so this case is belt-and-braces: it
        # proves $WhatIfPreference independently protects the write loop too,
        # not only the delete loop.
        $script:ReplayCreateCalls = [System.Collections.Generic.List[string]]::new()
        function Invoke-UCBusinessDomainCreate { param($Context, $Payload) $null = $Context; $script:ReplayCreateCalls.Add("BusinessDomain:$($Payload.name)"); return [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000000'; name = $Payload.name } }
        function ConvertTo-BusinessDomainCreatePayload { param($Desired) return [pscustomobject]@{ name = $Desired.name } }

        . Register-Issue106ReplayFunction -BodyText $script:Issue106WriteLoopAst.Extent.Text

        $script:DirectionPolicy = 'audit'
        $script:context = [pscustomobject]@{ Stub = $true }
        $script:createdDomainIds = @{}
        $script:effectiveDomainByName = @{}
        $script:termIdByKey = @{}
        $script:objectiveIdByName = @{}
        $script:writeOrder = @('BusinessDomain', 'DataProduct', 'Okr', 'OkrKeyResult', 'CriticalDataElement', 'Term')
        $script:plan = New-Object 'System.Collections.Generic.List[object]'
        $script:plan.Add([pscustomobject]@{ Action = 'Create'; Kind = 'BusinessDomain'; Desired = [pscustomobject]@{ name = 'ReplayDomain' }; Tenant = $null; Fields = @(); Conflict = $false }) | Out-Null

        Invoke-Issue106Replay -Confirm:$false

        $script:ReplayCreateCalls.Count | Should -Be 0 -Because 'audit mode must fire zero creates (pre-fix this was 1/1 when $plan was non-empty)'
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
