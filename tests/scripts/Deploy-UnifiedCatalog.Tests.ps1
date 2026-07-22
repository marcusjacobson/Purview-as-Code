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

# ---------------------------------------------------------------------------
# Issue #13 (part C prerequisite) -- -PruneMissing prune delete-order safety.
#
# Unified Catalog is a containment hierarchy and a parent delete cascades its
# children server-side (Business Domain -> Data Products / Objectives / Critical
# Data Elements / Terms; Objective -> Key Results). `$orphans` is assembled
# parent-first, so the pre-fix flat pass could delete a parent and then issue an
# explicit DELETE for an already-cascaded child, taking the resulting 404 as a
# real failure.
#
# The fix, mirroring Deploy-Labels.ps1's depth-descending orphan sort (#154):
#   1. sort orphans deepest-child-first so parents are deleted LAST, and
#   2. tolerate a post-cascade 404 as already-gone (Test-UCDeleteAlreadyGone),
#      while still surfacing every non-404 error.
#
# These tests drive the REAL top-level delete-loop AST extracted from the
# committed script -- not a reimplementation -- against stubbed Invoke-UC*Delete
# cmdlets, per the RED-REPLAY spirit of the #106 tests above.
# ---------------------------------------------------------------------------
Describe 'Issue #13 -- prune delete order + 404 tolerance (Deploy-UnifiedCatalog.ps1)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:Issue13Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | ForEach-Object Message | Out-String) }

        # Dot-source the real 404-tolerance helper the loop depends on.
        $helperAst = $script:Issue13Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-UCDeleteAlreadyGone'
            }, $true)
        if (-not $helperAst) { throw 'Function Test-UCDeleteAlreadyGone not found in the script.' }
        . ([ScriptBlock]::Create($helperAst.Extent.Text))

        # Lift the real top-level -PruneMissing delete loop (the SAME statement
        # the #106 tests bind, matched on $PruneMissing.IsPresent + $orphans.ToArray()).
        $script:Issue13DeleteLoopAst = @($script:Issue13Ast.EndBlock.Statements) | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -match '\$PruneMissing\.IsPresent' -and
            $_.Extent.Text -match '\$orphans\.ToArray\(\)'
        } | Select-Object -First 1
        if (-not $script:Issue13DeleteLoopAst) { throw 'Could not locate the top-level -PruneMissing delete-loop statement.' }
        $script:Issue13DeleteLoopBody = $script:Issue13DeleteLoopAst.Extent.Text

        # Dot-sourcing the CALL to this builder runs its body -- and the inner
        # function definition -- in the CALLER (It) scope, so Invoke-Issue13Replay
        # lands where the per-It stubs live. Mirrors Register-Issue106ReplayFunction.
        function Register-Issue13ReplayFunction {
            param([Parameter(Mandatory)][string]$BodyText)
            $functionText = @"
function Invoke-Issue13Replay {
    [CmdletBinding(SupportsShouldProcess = `$true, ConfirmImpact = 'High')]
    param()
$BodyText
}
"@
            . ([ScriptBlock]::Create($functionText))
        }

        # Builds an exception shaped like PS7's HttpResponseException: a live
        # .Response.StatusCode the helper reads. Used to fake a cascade 404 (and
        # a non-404 that must still fail).
        function Get-Issue13HttpError {
            param([Parameter(Mandatory)][int]$StatusCode, [string]$Message = 'stub http error')
            $ex = [System.Exception]::new($Message)
            $ex | Add-Member -NotePropertyName 'Response' -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode }) -Force
            return $ex
        }

        # Records every stub delete as "Kind:id", in the order fired.
        # Also stubs Write-PruneFailure: the part-C reporter (batch 6) calls it
        # in the non-404 delete catch, so the lifted -PruneMissing block now
        # references it. Records reported failures for the batch-6 tests below.
        function Register-Issue13DeleteStub {
            function Invoke-UCBusinessDomainDelete { param($Context, $DomainId) $null = $Context; $script:Issue13Deletes.Add("BusinessDomain:$DomainId") }
            function Invoke-UCDataProductDelete { param($Context, $DataProductId) $null = $Context; $script:Issue13Deletes.Add("DataProduct:$DataProductId") }
            function Invoke-UCObjectiveDelete { param($Context, $ObjectiveId) $null = $Context; $script:Issue13Deletes.Add("Okr:$ObjectiveId") }
            function Invoke-UCKeyResultDelete { param($Context, $ObjectiveId, $KeyResultId) $null = $Context; $null = $ObjectiveId; $script:Issue13Deletes.Add("OkrKeyResult:$KeyResultId") }
            function Invoke-UCCriticalDataElementDelete { param($Context, $CriticalDataElementId) $null = $Context; $script:Issue13Deletes.Add("CriticalDataElement:$CriticalDataElementId") }
            function Invoke-UCTermDelete { param($Context, $TermId) $null = $Context; $script:Issue13Deletes.Add("Term:$TermId") }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $script:Issue13Reported.Add($Message) }
        }
    }

    It 'unit: Test-UCDeleteAlreadyGone tolerates only a 404' {
        Test-UCDeleteAlreadyGone -ErrorRecord ([System.Management.Automation.ErrorRecord]::new((Get-Issue13HttpError -StatusCode 404), 'id', 'NotSpecified', $null)) | Should -BeTrue
        Test-UCDeleteAlreadyGone -ErrorRecord ([System.Management.Automation.ErrorRecord]::new((Get-Issue13HttpError -StatusCode 500), 'id', 'NotSpecified', $null)) | Should -BeFalse
        Test-UCDeleteAlreadyGone -ErrorRecord ([System.Management.Automation.ErrorRecord]::new([System.Exception]::new('no response'), 'id', 'NotSpecified', $null)) | Should -BeFalse
    }

    It 'deletes orphans deepest-child-first, parents last, for a mixed cross-kind set' {
        $script:Issue13Deletes = [System.Collections.Generic.List[string]]::new()
        . Register-Issue13DeleteStub
        . Register-Issue13ReplayFunction -BodyText $script:Issue13DeleteLoopBody

        $script:PruneMissing = [switch]$true
        $script:context = [pscustomobject]@{ Stub = $true }
        # Added parent-first -- the exact order $orphans is assembled in the real
        # script (Business Domains first). A correct fix must re-order this.
        $script:orphans = New-Object 'System.Collections.Generic.List[object]'
        $script:orphans.Add([pscustomobject]@{ Kind = 'BusinessDomain'; Item = [pscustomobject]@{ id = 'bd-1'; name = 'Finance' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'DataProduct'; Item = [pscustomobject]@{ id = 'dp-1'; name = 'Ledger' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'Okr'; Item = [pscustomobject]@{ id = 'okr-1'; definition = 'Improve quality' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'OkrKeyResult'; Item = [pscustomobject]@{ id = 'kr-1'; definition = '95% coverage'; __objectiveId = 'okr-1'; __objectiveName = 'Improve quality' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'CriticalDataElement'; Item = [pscustomobject]@{ id = 'cde-1'; name = 'SSN' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-1'; name = 'Revenue' } }) | Out-Null

        Invoke-Issue13Replay -Confirm:$false

        $order = @($script:Issue13Deletes)
        $order.Count | Should -Be 6 -Because 'every orphan is deleted exactly once'

        $kinds = @($order | ForEach-Object { ($_ -split ':')[0] })

        # (a) deepest first: the Key Result (depth 2) is deleted before any other.
        $kinds[0] | Should -Be 'OkrKeyResult'
        # ...and before its own parent Objective.
        [array]::IndexOf($kinds, 'OkrKeyResult') | Should -BeLessThan ([array]::IndexOf($kinds, 'Okr'))

        # (b) parents last: the Business Domain (top-level) is deleted last, after
        #     every one of its direct children.
        $kinds[-1] | Should -Be 'BusinessDomain'
        $bdIndex = [array]::IndexOf($kinds, 'BusinessDomain')
        foreach ($child in @('DataProduct', 'Okr', 'CriticalDataElement', 'Term')) {
            [array]::IndexOf($kinds, $child) | Should -BeLessThan $bdIndex -Because "$child is contained by the Business Domain and must be deleted before it"
        }

        # Mutation check: the pre-fix flat pass deleted in $orphans' assembled
        # order, i.e. Business Domain FIRST. Assert the fix did not preserve that.
        $kinds[0] | Should -Not -Be 'BusinessDomain' -Because 'the pre-fix flat order deleted the parent Business Domain first -- the ordering fix must not reproduce it'
    }

    It 'treats a post-cascade 404 on a child as already-gone and keeps pruning the rest' {
        $script:Issue13Deletes = [System.Collections.Generic.List[string]]::new()
        . Register-Issue13DeleteStub
        # The Term's parent domain already cascaded it away -> explicit DELETE 404s.
        function Invoke-UCTermDelete { param($Context, $TermId) $null = $Context; $null = $TermId; throw (Get-Issue13HttpError -StatusCode 404 -Message 'Term already removed by cascade') }
        . Register-Issue13ReplayFunction -BodyText $script:Issue13DeleteLoopBody

        $script:PruneMissing = [switch]$true
        $script:context = [pscustomobject]@{ Stub = $true }
        $script:orphans = New-Object 'System.Collections.Generic.List[object]'
        $script:orphans.Add([pscustomobject]@{ Kind = 'BusinessDomain'; Item = [pscustomobject]@{ id = 'bd-1'; name = 'Finance' } }) | Out-Null
        $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-1'; name = 'Revenue' } }) | Out-Null

        { Invoke-Issue13Replay -Confirm:$false } | Should -Not -Throw -Because 'a 404 from an already-cascaded child is idempotent-delete success, not a prune failure'

        # The Business Domain (deleted after the tolerated 404) still ran.
        @($script:Issue13Deletes) | Should -Contain 'BusinessDomain:bd-1'
    }

    It 'still fails on a non-404 delete error (now via the batch-6 aggregate throw)' {
        $script:Issue13Deletes = [System.Collections.Generic.List[string]]::new()
        $script:Issue13Reported = [System.Collections.Generic.List[string]]::new()
        . Register-Issue13DeleteStub
        function Invoke-UCTermDelete { param($Context, $TermId) $null = $Context; $null = $TermId; throw (Get-Issue13HttpError -StatusCode 500 -Message 'server error') }
        . Register-Issue13ReplayFunction -BodyText $script:Issue13DeleteLoopBody

        $script:PruneMissing = [switch]$true
        $script:context = [pscustomobject]@{ Stub = $true }
        $script:orphans = New-Object 'System.Collections.Generic.List[object]'
        $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-1'; name = 'Revenue' } }) | Out-Null

        # Behaviour change (part C batch 6): the non-404 error is no longer
        # rethrown inline; it is reported via Write-PruneFailure and collected,
        # and the aggregate throw at the end of the -PruneMissing block fails the
        # run non-zero. Still fails -- a non-404 error must not be swallowed.
        { Invoke-Issue13Replay -Confirm:$false } | Should -Throw -Because 'a non-404 error is a real prune failure and must not be swallowed'
        @($script:Issue13Reported).Count | Should -Be 1 -Because 'the failure is reported through Write-PruneFailure before the aggregate throw'
    }
}

# ---------------------------------------------------------------------------
# Issue #13 part C batch 6: the prune failure REPORTER (attempt-every-orphan,
# aggregate throw) and guard 2 (per-kind prune sanity ratio). The reporter
# region is the SAME lifted -PruneMissing delete loop the delete-order tests
# above bind; these cases drive its new collect-and-continue path.
# ---------------------------------------------------------------------------
Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 6) -- Deploy-UnifiedCatalog.ps1' {

    BeforeAll {
        $script:B6Source = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:B6Source | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:B6Source | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the per-kind Unified Catalog nouns' {
        $script:B6Source | Should -Match 'Assert-PruneRatioWithinThreshold'
        foreach ($noun in @('Unified Catalog business domain', 'Unified Catalog data product', 'Unified Catalog objective', 'Unified Catalog key result', 'Unified Catalog critical data element', 'Unified Catalog term')) {
            $script:B6Source | Should -Match ([regex]::Escape("Noun = '$noun'"))
        }
    }
    It 'keys the key-result tier on the flat tenant key-result list (no single tenant collection)' {
        $script:B6Source | Should -Match ([regex]::Escape('@($keyResultTenant).Count'))
    }
    It 'gates guard 2 on non-audit (AUDIT TRAP: audit flips WhatIfPreference but leaves $orphans populated)' {
        $script:B6Source | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'surfaces the ratio override and threshold parameters on the Apply parameter set' {
        $script:B6Source | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:B6Source | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters['AllowMajorityPrune'].ParameterSets.Keys | Should -Not -Contain 'Export'
        $cmd.Parameters['MaxPruneRatio'].ParameterSets.Keys | Should -Not -Contain 'Export'
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:B6Source.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:B6Source.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Per-kind prune sanity-ratio guard executed through the script wiring (issue #13, batch 6)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'PruneGuard.psm1') -Force -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $start = -1; $end = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*if \(\$PruneMissing\.IsPresent -and \$DirectionPolicy -ne ''audit''\)') {
                $depth = 0; $e = -1
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $depth += ([regex]::Matches($lines[$j], '\{')).Count
                    $depth -= ([regex]::Matches($lines[$j], '\}')).Count
                    if ($depth -le 0) { $e = $j; break }
                }
                $cand = ($lines[$i..$e] -join [Environment]::NewLine)
                if ($cand -match 'Assert-PruneRatioWithinThreshold') { $start = $i; $end = $e; break }
            }
        }
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-UnifiedCatalog.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            # $OrphanKinds: one entry per orphan, its Kind. Live* set the per-kind
            # denominators. Only the tested kind needs a non-trivial denominator.
            param([hashtable]$OrphanCounts = @{}, [hashtable]$Live = @{}, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $orphans = New-Object 'System.Collections.Generic.List[object]'
            foreach ($k in $OrphanCounts.Keys) {
                for ($i = 0; $i -lt $OrphanCounts[$k]; $i++) { $orphans.Add([pscustomobject]@{ Kind = $k; Item = [pscustomobject]@{ id = "$k-$i" } }) | Out-Null }
            }
            $mk = { param($n) @(for ($i = 0; $i -lt $n; $i++) { [pscustomobject]@{ id = $i } }) }
            $tenantState = [pscustomobject]@{
                Domains              = & $mk ([int]($Live['BusinessDomain']))
                DataProducts         = & $mk ([int]($Live['DataProduct']))
                Objectives           = & $mk ([int]($Live['Okr']))
                CriticalDataElements = & $mk ([int]($Live['CriticalDataElement']))
                Terms                = & $mk ([int]($Live['Term']))
            }
            $keyResultTenant = & $mk ([int]($Live['OkrKeyResult']))
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $orphans, $tenantState, $keyResultTenant
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes when every kind sits at or below the threshold' {
        { Invoke-Guard2 -OrphanCounts @{ Term = 2; BusinessDomain = 1 } -Live @{ Term = 10; BusinessDomain = 4 } } | Should -Not -Throw
    }
    It 'throws when ONE kind exceeds the threshold even though the blended ratio would pass (the per-kind point)' {
        # 4 of 4 terms pruned but 0 of 16 domains: blended 4/20 = 20%, term kind 100%.
        { Invoke-Guard2 -OrphanCounts @{ Term = 4 } -Live @{ Term = 4; BusinessDomain = 16 } } | Should -Throw
    }
    It 'throws when the key-result kind exceeds the threshold (flat-list denominator)' {
        { Invoke-Guard2 -OrphanCounts @{ OkrKeyResult = 6 } -Live @{ OkrKeyResult = 10; BusinessDomain = 10 } -Max 0.5 } | Should -Throw
    }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' {
        { Invoke-Guard2 -OrphanCounts @{ Term = 4 } -Live @{ Term = 4 } -Allow } | Should -Not -Throw
    }
    It 'does NOT fire under -DirectionPolicy audit even above the threshold (audit trap)' {
        { Invoke-Guard2 -OrphanCounts @{ Term = 4 } -Live @{ Term = 4 } -Direction 'audit' } | Should -Not -Throw
    }
    It 'honours a caller-supplied -MaxPruneRatio' {
        { Invoke-Guard2 -OrphanCounts @{ Term = 6 } -Live @{ Term = 10 } -Max 0.7 } | Should -Not -Throw
    }
}

Describe 'Prune failure reporting executed through the delete loop (issue #13, batch 6)' {

    BeforeAll {
        # Reuse the delete-loop lift from the delete-order Describe by rebuilding
        # the same AST slice here (self-contained BeforeAll).
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | ForEach-Object Message | Out-String) }
        $helperAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-UCDeleteAlreadyGone' }, $true)
        . ([ScriptBlock]::Create($helperAst.Extent.Text))
        $loopAst = @($ast.EndBlock.Statements) | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Extent.Text -match '\$PruneMissing\.IsPresent' -and $_.Extent.Text -match '\$orphans\.ToArray\(\)'
        } | Select-Object -First 1
        $script:B6LoopBody = $loopAst.Extent.Text
        $script:B6LoopHasReporter = $script:B6LoopBody -match 'Write-PruneFailure' -and $script:B6LoopBody -match '\$pruneFailures' -and $script:B6LoopBody -match 'throw'

        function Get-B6HttpError { param([int]$StatusCode, [string]$Message = 'stub') $ex = [System.Exception]::new($Message); $ex | Add-Member -NotePropertyName 'Response' -NotePropertyValue ([pscustomobject]@{ StatusCode = $StatusCode }) -Force; return $ex }

        function Invoke-B6Prune {
            param([string[]]$FailTerms = @())
            $script:B6Deletes = [System.Collections.Generic.List[string]]::new()
            $script:B6Reported = [System.Collections.Generic.List[string]]::new()
            function Invoke-UCBusinessDomainDelete { param($Context, $DomainId) $null = $Context; $script:B6Deletes.Add("BusinessDomain:$DomainId") }
            function Invoke-UCDataProductDelete { param($Context, $DataProductId) $null = $Context; $script:B6Deletes.Add("DataProduct:$DataProductId") }
            function Invoke-UCObjectiveDelete { param($Context, $ObjectiveId) $null = $Context; $script:B6Deletes.Add("Okr:$ObjectiveId") }
            function Invoke-UCKeyResultDelete { param($Context, $ObjectiveId, $KeyResultId) $null = $Context, $ObjectiveId; $script:B6Deletes.Add("OkrKeyResult:$KeyResultId") }
            function Invoke-UCCriticalDataElementDelete { param($Context, $CriticalDataElementId) $null = $Context; $script:B6Deletes.Add("CriticalDataElement:$CriticalDataElementId") }
            function Invoke-UCTermDelete { param($Context, $TermId) $null = $Context; $script:B6Deletes.Add("Term:$TermId"); if ($FailTerms -contains [string]$TermId) { throw (Get-B6HttpError -StatusCode 500 -Message "server error on $TermId") } }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $script:B6Reported.Add($Message) }
            $fnText = @"
function Invoke-B6Replay {
    [CmdletBinding(SupportsShouldProcess = `$true, ConfirmImpact = 'High')]
    param()
$script:B6LoopBody
}
"@
            . ([ScriptBlock]::Create($fnText))
            $script:PruneMissing = [switch]$true
            $script:context = [pscustomobject]@{ Stub = $true }
            $script:orphans = New-Object 'System.Collections.Generic.List[object]'
            # Three sibling terms under one domain (all depth 2, so sort keeps them
            # together and the loop attempts each independently).
            $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-1'; name = 'T1' } }) | Out-Null
            $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-2'; name = 'T2' } }) | Out-Null
            $script:orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = [pscustomobject]@{ id = 'term-3'; name = 'T3' } }) | Out-Null
            $thrown = $null
            try { Invoke-B6Replay -Confirm:$false 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = @($script:B6Deletes); Reported = @($script:B6Reported); Thrown = $thrown }
        }
    }

    It 'attempts every orphan after a non-404 failure (no first-failure abort)' {
        $r = Invoke-B6Prune -FailTerms @('term-1')
        @($r.Attempted) | Should -Be @('Term:term-1', 'Term:term-2', 'Term:term-3')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-B6Prune -FailTerms @('term-2')
        @($r.Reported).Count | Should -Be 1
        $r.Reported[0] | Should -Match 'server error on term-2'
    }
    It 'throws one aggregate naming every failed object (non-zero exit preserved)' {
        $r = Invoke-B6Prune -FailTerms @('term-1', 'term-3')
        $r.Thrown | Should -Match "Term 'T1'"
        $r.Thrown | Should -Match "Term 'T3'"
        $r.Thrown | Should -Match '2 orphan Unified Catalog object'
    }
    It 'throws nothing when every delete succeeds' {
        $r = Invoke-B6Prune
        $r.Thrown   | Should -BeNullOrEmpty
        @($r.Reported).Count | Should -Be 0
    }
    It 'carries the reporter and the aggregate throw in the lifted -PruneMissing block (mutation check)' {
        $script:B6LoopHasReporter | Should -BeTrue
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
