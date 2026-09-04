#Requires -Version 7.4
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in `scripts/Deploy-IRMEntityLists.ps1`.

.DESCRIPTION
    Locks in the Microsoft Purview Insider Risk Management entity-list
    reconciler contract:

      1. `ConvertTo-DesiredEntityListHash` normalizes a YAML entity-list
         entry into a comparable hashtable; missing optionals collapse to
         $null; entities are normalized to lowercase sorted order.
      2. `ConvertTo-TenantEntityListHash` normalizes a
         `Get-InsiderRiskEntityList` row into the same shape.
      3. `Compare-EntityList` returns an empty list for in-sync inputs and
         the field names that drift. `displayName`, `description`, and
         `entities` are compared only when the desired side declares them
         (a missing optional in YAML is treated as "don''t manage").
         `type` is NOT compared (immutable after creation per ADR 0039).

    Pattern: AST-extract each helper from the script and dot-source into
    the test scope. We deliberately do NOT dot-source the script itself
    -- that would execute its top-level code and try to
    `Connect-IPPSSession` against the live tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMEntityLists.ps1"
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-IRMEntityLists.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join "; "))
    }

    foreach ($fname in @(
            "ConvertTo-DesiredEntityListHash",
            "ConvertTo-TenantEntityListHash",
            "Compare-EntityList",
            "Invoke-IRMEntityListExport")) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe "ConvertTo-DesiredEntityListHash normalizes YAML entries" {

    It "collapses missing optionals to null" {
        $entry = @{ name = "lab-irm-min"; type = "UserType" }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-min"
        $hash.type        | Should -Be "UserType"
        $hash.displayName | Should -BeNullOrEmpty
        $hash.description | Should -BeNullOrEmpty
        $hash.entities    | Should -BeNullOrEmpty
    }

    It "preserves every declared field" {
        $entry = @{
            name        = "lab-irm-full"
            type        = "GroupType"
            displayName = "Lab IRM Group List"
            description = "Test group entity list"
            entities    = @("group-a@contoso.com", "group-b@contoso.com")
        }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-full"
        $hash.type        | Should -Be "GroupType"
        $hash.displayName | Should -Be "Lab IRM Group List"
        $hash.description | Should -Be "Test group entity list"
        $hash.entities    | Should -Not -BeNullOrEmpty
    }

    It "normalizes entities to lowercase sorted order" {
        $entry = @{
            name     = "lab-irm-ent"
            type     = "UserType"
            entities = @("User-B@contoso.com", "user-a@contoso.com", "USER-C@CONTOSO.COM")
        }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.entities[0] | Should -Be "user-a@contoso.com"
        $hash.entities[1] | Should -Be "user-b@contoso.com"
        $hash.entities[2] | Should -Be "user-c@contoso.com"
    }

    It "treats entities empty array as declared-empty (not null)" {
        $entry = @{ name = "lab-irm-empty-ent"; type = "UserType"; entities = @() }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        # @() is declared-empty (tracked for diff), NOT $null (do-not-manage).
        # Use direct null-check rather than Should -Not -BeNullOrEmpty because
        # Pester treats an empty array as "empty" and the assertion would fail.
        ($null -eq $hash.entities) | Should -BeFalse
        $hash.entities.Count | Should -Be 0
    }

    It "treats absent entities key as null (do-not-manage)" {
        $entry = @{ name = "lab-irm-no-ent"; type = "UserType" }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.entities | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-TenantEntityListHash normalizes Get-InsiderRiskEntityList rows" {

    It "maps all properties correctly" {
        $row = [pscustomobject]@{
            Name        = "IRM-Lab-Priority-Users"
            Type        = "UserType"
            DisplayName = "Lab Priority Users"
            Description = "Priority user group for lab"
            Entities    = @("user-a@contoso.com", "user-b@contoso.com")
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.name        | Should -Be "IRM-Lab-Priority-Users"
        $hash.type        | Should -Be "UserType"
        $hash.displayName | Should -Be "Lab Priority Users"
        $hash.description | Should -Be "Priority user group for lab"
        $hash.entities    | Should -Not -BeNullOrEmpty
    }

    It "handles null optional properties without throwing" {
        $row = [pscustomobject]@{
            Name        = "irm-sparse"
            Type        = "SiteType"
            DisplayName = $null
            Description = $null
            Entities    = $null
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.displayName | Should -BeNullOrEmpty
        $hash.description | Should -BeNullOrEmpty
        $hash.entities.Count | Should -Be 0
    }

    It "normalizes tenant entities to lowercase sorted order" {
        $row = [pscustomobject]@{
            Name     = "irm-sort"
            Type     = "UserType"
            DisplayName = $null; Description = $null
            Entities = @("User-Z@contoso.com", "user-a@contoso.com")
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.entities[0] | Should -Be "user-a@contoso.com"
        $hash.entities[1] | Should -Be "user-z@contoso.com"
    }
}

Describe "Compare-EntityList returns drift field names" {

    It "returns empty list for in-sync inputs" {
        $d = @{ name = "x"; type = "UserType"; displayName = "Foo"; description = "Bar"; entities = @("a@contoso.com") }
        $t = @{ name = "x"; type = "UserType"; displayName = "Foo"; description = "Bar"; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports displayName drift when declared" {
        $d = @{ name = "x"; type = "UserType"; displayName = "want"; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = "have"; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "displayName"
    }

    It "ignores displayName drift when YAML omits it" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = "tenant-only"; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports description drift when declared" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = "want"; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = "have"; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "description"
    }

    It "reports entities drift for content change" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("b@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "entities"
    }

    It "reports entities drift when desired is empty and tenant is non-empty" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @() }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "entities"
    }

    It "ignores entities drift when YAML omits the entities key" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "does NOT report type drift (type is immutable; ADR 0039)" {
        $d = @{ name = "x"; type = "GroupType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType";  displayName = $null; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }
}

Describe "ADR 0029 direction-policy context tests" {

    It "script exposes a -DirectionPolicy parameter" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $params | Should -Contain 'DirectionPolicy'
    }

    It "script exposes a -SkipNames parameter" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $params | Should -Contain 'SkipNames'
    }

    It "script emits [ADR0029-AUDIT] marker in source text" {
        $src = Get-Content -LiteralPath $script:ScriptPath -Raw
        $src | Should -Match '\[ADR0029-AUDIT\]'
    }

    It "script emits [ADR0029-SKIP] marker in source text" {
        $src = Get-Content -LiteralPath $script:ScriptPath -Raw
        $src | Should -Match '\[ADR0029-SKIP\]'
    }
}

Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:ElSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:ElSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:ElSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the IRM entity-list noun' {
        $script:ElSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:ElSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'IRM entity list'"))
    }
    It 'keys guard 2 on the live tenant entity-list count' {
        $script:ElSource | Should -Match ([regex]::Escape('@($tenantLists).Count'))
    }
    It 'surfaces the ratio override and threshold parameters' {
        $script:ElSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:ElSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
    }
    It 'gates guard 2 on non-audit (AUDIT TRAP: script flips WhatIfPreference, does not empty orphans)' {
        $script:ElSource | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:ElSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:ElSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Prune sanity-ratio guard executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'PruneGuard.psm1') -Force -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $start = -1; $end = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*if \(\$PruneMissing\.IsPresent') {
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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-IRMEntityLists.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $plan = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Action = 'Orphan'; Name = "orphan-$i" } })
            $tenantLists = @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ Name = "live-$i" } })
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $plan, $tenantLists
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'does NOT fire under -DirectionPolicy audit even above the threshold (audit trap)' { { Invoke-Guard2 -Prune 10 -Live 10 -Direction 'audit' } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-IRMEntityLists.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-IRMEntityLists.ps1; update the anchor in this test.' }
        $depth = 0; $e = -1
        for ($j = $ifStart; $j -lt $script:RepLines.Count; $j++) {
            $depth += ([regex]::Matches($script:RepLines[$j], '\{')).Count
            $depth -= ([regex]::Matches($script:RepLines[$j], '\}')).Count
            if ($depth -le 0) { $e = $j; break }
        }
        $script:ReporterRegion = ($script:RepLines[$s..$e] -join [Environment]::NewLine)
        $script:ReporterShouldProcessCount = ([regex]::Matches($script:ReporterRegion, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:ReporterRunnable = $script:ReporterRegion -replace '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        function Invoke-PruneRegion {
            param([string[]]$Names = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Remove-InsiderRiskEntityList {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add($Identity)
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($Names | ForEach-Object { [pscustomobject]@{ Action = 'Orphan'; Name = $_ } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $plan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every remaining orphan after one fails (loop no longer aborts)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('a')
        $r.Attempted | Should -Be @('a', 'b', 'c')
    }
    It 'reports each individual failure with the tenant error message' {
        $r = Invoke-PruneRegion -Names @('a', 'b') -Fail @('a', 'b')
        $r.Reported.Count | Should -Be 2
        ($r.Reported -join '; ') | Should -Match 'TenantBlockerException: a'
        ($r.Reported -join '; ') | Should -Match 'TenantBlockerException: b'
    }
    It 'throws one aggregate naming every failure (behaviour change: non-zero exit)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('b', 'c')
        $r.Thrown | Should -Not -BeNullOrEmpty
        $r.Thrown | Should -Match 'Reconciliation aborted'
        $r.Thrown | Should -Match 'b'
        $r.Thrown | Should -Match 'c'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -Names @('a', 'b')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the prune loop behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the aggregate throw and reporter in the lifted region (mutation check vs pre-batch exit-0)' {
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}

Describe 'Desired-state schema-validation serialization depth is not truncated (#90)' {

    BeforeAll {
        $script:ScriptPathForDepth = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-IRMEntityLists.ps1'

        # A synthetic document unrelated to this reconciler's actual schema -- the
        # #90 fix is schema-independent, so this only needs to nest deep enough
        # (12+ levels) to prove -Depth 100 does not truncate while -Depth 10 does.
        $script:DeepDoc = @{
            l1 = @{ l2 = @{ l3 = @{ l4 = @{ l5 = @{ l6 = @{ l7 = @{ l8 = @{
                l9 = @{ l10 = @{ l11 = @{ l12 = @{ l13 = @{ l14 = 'leaf' } } } } }
            } } } } } } } }
        }
    }

    It 'reads the serialization depth from the script itself and confirms it is pinned to 100' {
        # A test that hard-codes its own depth cannot catch this defect -- exactly
        # how the #80 sibling escaped every offline schema test before it (each
        # test serialized at a depth of its own choosing rather than the script's).
        $src = Get-Content -LiteralPath $script:ScriptPathForDepth -Raw
        $m = [regex]::Match($src, '\$docJson\s*=\s*\$desiredRoot\s*\|\s*ConvertTo-Json\s+-Depth\s+(?<d>\d+)')
        $m.Success | Should -BeTrue -Because 'the desired-state validation site must stay greppable for this regression test'
        [int]$m.Groups['d'].Value | Should -Be 100
    }

    It 'serializes a deeply nested document WITHOUT truncating at the pinned depth' {
        # ConvertTo-Json warns and rewrites deeper nodes as strings when it hits the
        # depth cap; the truncated document then fails schema validation with an
        # error pointing at an unrelated shallow field (the #80 failure mode).
        $src = Get-Content -LiteralPath $script:ScriptPathForDepth -Raw
        $depth = [int][regex]::Match($src, '\$docJson\s*=\s*\$desiredRoot\s*\|\s*ConvertTo-Json\s+-Depth\s+(?<d>\d+)').Groups['d'].Value

        $warnings = @()
        $null = $script:DeepDoc | ConvertTo-Json -Depth $depth -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -BeNullOrEmpty -Because 'a truncation warning means the validation site would reject a valid deep document'
    }

    It 'demonstrates the defect: the same document at the old -Depth 10 does NOT survive' {
        # Mutation check -- proves the two assertions above are non-vacuous.
        $warnings = @()
        $null = $script:DeepDoc | ConvertTo-Json -Depth 10 -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -Not -BeNullOrEmpty
    }
}

Describe 'Export parameter set contract — entity lists (#177)' {

    BeforeAll {
        $script:ElSrcPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMEntityLists.ps1"
        $script:ElSrc = Get-Content -LiteralPath $script:ElSrcPath -Raw
        $errs = $null
        $script:ElAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ElSrcPath, [ref]$null, [ref]$errs)
        if ($errs) { throw ("Parse errors: {0}" -f ($errs -join '; ')) }

        function Get-ElParamByName {
            param([string]$Name)
            return $script:ElAst.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
                Select-Object -First 1
        }

        function Get-ElParameterSetNames {
            param([string]$Name)
            $p = Get-ElParamByName -Name $Name
            if (-not $p) { throw "Parameter -$Name not found" }
            $names = @()
            foreach ($attr in $p.Attributes) {
                if ($attr.TypeName.Name -ne 'Parameter') { continue }
                foreach ($na in $attr.NamedArguments) {
                    if ($na.ArgumentName -eq 'ParameterSetName') { $names += $na.Argument.Value }
                }
            }
            return $names
        }
    }

    It 'exposes -ExportCurrentState as a mandatory switch in the Export parameter set' {
        $p = Get-ElParamByName -Name 'ExportCurrentState'
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -Be 'SwitchParameter'
        (Get-ElParameterSetNames -Name 'ExportCurrentState') | Should -Be @('Export')
    }

    It 'declares Apply as the default parameter set so existing callers bind unchanged' {
        $cmdletBinding = $script:ElAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } | Select-Object -First 1
        ($cmdletBinding.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' } |
            Select-Object -First 1).Argument.Value | Should -Be 'Apply'
    }

    It 'keeps every prune and skip parameter OUT of the Export set' -ForEach @(
        @{ ParamName = 'PruneMissing' }
        @{ ParamName = 'AllowMajorityPrune' }
        @{ ParamName = 'MaxPruneRatio' }
        @{ ParamName = 'SkipNames' }
    ) {
        $sets = Get-ElParameterSetNames -Name $ParamName
        $sets | Should -Contain 'Apply'
        $sets | Should -Not -Contain 'Export'
    }

    It 'keeps prune guard 1 inside the Apply-only block and ahead of the first tenant contact' {
        $lines = Get-Content -LiteralPath $script:ElSrcPath
        $applyWrap = ($lines | Select-String -Pattern "^if \(\`$mode -eq 'Apply'\) \{" | Select-Object -First 1).LineNumber
        $guard     = ($lines | Select-String -Pattern 'Assert-PruneDesiredSetNotEmpty' | Select-Object -First 1).LineNumber
        $contact   = ($lines | Select-String -Pattern "^\`$accountJson = az account show" | Select-Object -First 1).LineNumber
        $applyWrap | Should -BeLessThan $guard
        $guard     | Should -BeLessThan $contact
    }

    It 'places the Export short-circuit after the tenant enumerate and before the plan builder' {
        $enumIdx   = $script:ElSrc.IndexOf('Get-InsiderRiskEntityList -ErrorAction Stop')
        $exportIdx = $script:ElSrc.IndexOf("if (`$mode -eq 'Export')")
        $planIdx   = $script:ElSrc.IndexOf('$plan = New-Object')
        $enumIdx   | Should -BeGreaterThan 0
        $exportIdx | Should -BeGreaterThan $enumIdx
        $planIdx   | Should -BeGreaterThan $exportIdx
    }

    It 'adds no new ADR 0052 confirmation gate' {
        ([regex]::Matches($script:ElSrc, 'Assert-DestructiveOperationConfirmed @gateArgs')).Count |
            Should -Be 2 -Because 'ConfirmGate.Tests.ps1 pins this reconciler at exactly 2 gates'
    }
}

Describe 'Invoke-IRMEntityListExport round-trips tenant state into schema-valid YAML (#177)' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:ElSchemaPath = Join-Path $PSScriptRoot ".." ".." "data-plane" "irm" "entity-lists.schema.json"
        $script:ElSchemaText = Get-Content -LiteralPath $script:ElSchemaPath -Raw

        function New-TenantEntityListRow {
            param(
                [string]$Name,
                [string]$Type = 'UserType',
                [string]$DisplayName = $null,
                [string]$Description = $null,
                [string[]]$Entities = @()
            )
            return [pscustomobject]@{
                Name        = $Name
                Type        = $Type
                DisplayName = $DisplayName
                Description = $Description
                Entities    = $Entities
            }
        }

        function Test-ElDocSchemaValid {
            param([hashtable]$Doc)
            ($Doc | ConvertTo-Json -Depth 25) | Test-Json -Schema $script:ElSchemaText -ErrorAction Stop | Out-Null
            foreach ($e in @($Doc.entityLists)) {
                (@{ entityLists = @($e) } | ConvertTo-Json -Depth 25) |
                    Test-Json -Schema $script:ElSchemaText -ErrorAction Stop | Out-Null
            }
            return $true
        }
    }

    It 'always emits name and type, and omits unset optional fields' {
        $out = Join-Path $TestDrive 'el-tracked.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'minimal' -Type 'GroupType')
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $entry = @($doc.entityLists)[0]
        $entry.name | Should -Be 'minimal'
        $entry.type | Should -Be 'GroupType'
        $entry.ContainsKey('displayName') | Should -BeFalse
        $entry.ContainsKey('description') | Should -BeFalse
        $entry.ContainsKey('entities')    | Should -BeTrue -Because 'entities is always emitted; omitting it would flip membership to do-not-manage'
    }

    It 'exports entities lowercased and sorted, matching the comparator' {
        $out = Join-Path $TestDrive 'el-entities.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'members' -Entities @('Zoe@Contoso.com', 'adam@CONTOSO.com', 'Mia@contoso.com'))
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @(@($doc.entityLists)[0].entities) | Should -Be @('adam@contoso.com', 'mia@contoso.com', 'zoe@contoso.com')
    }

    It 'emits entities as a declared-empty array when the tenant list has no members' {
        $out = Join-Path $TestDrive 'el-empty-entities.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'no-members' -Entities @())
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $entry = @($doc.entityLists)[0]
        $entry.ContainsKey('entities') | Should -BeTrue
        @($entry.entities).Count | Should -Be 0
    }

    It 'produces a document that validates against entity-lists.schema.json, per entry and whole' {
        $out = Join-Path $TestDrive 'el-schema.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'users' -Type 'UserType' -DisplayName 'Users' -Description 'd' -Entities @('a@contoso.com'))
            (New-TenantEntityListRow -Name 'groups' -Type 'GroupType' -Entities @('sg-x@contoso.com'))
            (New-TenantEntityListRow -Name 'sites' -Type 'SiteType' -Entities @('https://contoso.sharepoint.com/sites/x'))
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        { Test-ElDocSchemaValid -Doc $doc } | Should -Not -Throw
    }

    It 'round-trips NoChange by construction against its source rows' {
        $rows = @(
            (New-TenantEntityListRow -Name 'rt-users' -Type 'UserType' -DisplayName 'RT Users' -Description 'desc' -Entities @('B@contoso.com', 'a@contoso.com'))
            (New-TenantEntityListRow -Name 'rt-bare' -Type 'SiteType' -Entities @())
        )
        $out = Join-Path $TestDrive 'el-roundtrip.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists $rows

        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        foreach ($entry in @($doc.entityLists)) {
            $desired = ConvertTo-DesiredEntityListHash -Entry ([hashtable]$entry)
            $source  = $rows | Where-Object { $_.Name -eq $entry.name } | Select-Object -First 1
            $tenant  = ConvertTo-TenantEntityListHash -EntityList $source
            $diffs   = Compare-EntityList -Desired $desired -Tenant $tenant
            $diffs.Count | Should -Be 0 -Because "a freshly exported '$($entry.name)' must re-compare clean"
        }
    }

    It 'preserves the existing file comment header' {
        $out = Join-Path $TestDrive 'el-header.yaml'
        Set-Content -LiteralPath $out -Value @('# Curated one.', '#', '# Curated two.', 'entityLists: []') -Encoding utf8
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @((New-TenantEntityListRow -Name 'after'))
        $raw = Get-Content -LiteralPath $out -Raw
        $raw | Should -Match '# Curated one\.'
        $raw | Should -Match '# Curated two\.'
        $raw | Should -Match 'after'
    }

    It 'refuses to clobber a populated file unless -Force is passed' {
        $out = Join-Path $TestDrive 'el-guard.yaml'
        Set-Content -LiteralPath $out -Value @(
            '# header', 'entityLists:', '  - name: pre-existing', '    type: UserType'
        ) -Encoding utf8
        $before = Get-Content -LiteralPath $out -Raw
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @((New-TenantEntityListRow -Name 'replacement')) -ErrorAction SilentlyContinue -ErrorVariable elErr
        $elErr | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $out -Raw) | Should -Be $before
    }

    It 'overwrites a populated file when -Force is passed' {
        $out = Join-Path $TestDrive 'el-force.yaml'
        Set-Content -LiteralPath $out -Value @(
            '# header', 'entityLists:', '  - name: pre-existing', '    type: UserType'
        ) -Encoding utf8
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @((New-TenantEntityListRow -Name 'replacement')) -Force
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.entityLists).Count | Should -Be 1
        @($doc.entityLists)[0].name | Should -Be 'replacement'
    }

    It 'writes LF endings, UTF-8 without BOM, and exactly one trailing newline' {
        $out = Join-Path $TestDrive 'el-encoding.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @((New-TenantEntityListRow -Name 'enc'))
        $bytes = [System.IO.File]::ReadAllBytes($out)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        ($bytes -contains 0x0D) | Should -BeFalse
        $bytes[$bytes.Length - 1] | Should -Be 0x0A
        $bytes[$bytes.Length - 2] | Should -Not -Be 0x0A
    }

    It 'writes an empty entityLists list for an empty tenant, and it stays schema-valid' {
        $out = Join-Path $TestDrive 'el-empty.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @()
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $doc.ContainsKey('entityLists') | Should -BeTrue
        @($doc.entityLists).Count | Should -Be 0
        { Test-ElDocSchemaValid -Doc @{ entityLists = @() } } | Should -Not -Throw
    }

    It 'warns and skips a tenant entity list that reports no Type' {
        # type is schema-required AND feeds the immutable Create splat (ADR 0039),
        # so a row without one cannot be represented or recreated.
        $out = Join-Path $TestDrive 'el-notype.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'valid'),
            (New-TenantEntityListRow -Name 'typeless' -Type $null)
        ) -WarningVariable elWarns -WarningAction SilentlyContinue
        $elWarns | Should -Not -BeNullOrEmpty
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.entityLists).Count | Should -Be 1
        @($doc.entityLists)[0].name | Should -Be 'valid'
    }

    It 'never emits an empty-string or null scalar' {
        $out = Join-Path $TestDrive 'el-nonull.yaml'
        Invoke-IRMEntityListExport -Path $out -TenantEntityLists @(
            (New-TenantEntityListRow -Name 'n1' -DisplayName $null -Description ''),
            (New-TenantEntityListRow -Name 'n2' -DisplayName '' -Description $null)
        )
        $raw = Get-Content -LiteralPath $out -Raw
        $raw | Should -Not -Match "displayName:\s*''"
        $raw | Should -Not -Match "description:\s*''"
        $raw | Should -Not -Match ':\s*null'
    }
}

Describe 'Deploy-IRMEntityLists.ps1 is PARKED (ADR 0064)' {

    # ADR 0064 parked this reconciler: the surface it models does not exist
    # (Get-InsiderRiskEntityList cannot enumerate bare, the ADR 0039 type enum
    # is fictional, and membership is not readable through any documented
    # surface). The script is retained on disk deliberately -- deleting it
    # would force count reversals in four AST-derived contract suites for no
    # behavioural gain -- so the ONLY thing stopping someone from wiring it
    # back up is the marker this suite pins. If these fail, either the park
    # was undone or a new ADR un-parked the surface; check which before
    # "fixing" the test.

    BeforeAll {
        $script:ParkedSrcPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMEntityLists.ps1"
        $script:ParkedSrc = Get-Content -LiteralPath $script:ParkedSrcPath -Raw
    }

    It 'carries the PARKED marker in .SYNOPSIS, so the generated scripts reference shows it' {
        # docs/scripts-reference.md is machine-generated from .SYNOPSIS by
        # docs-regen.yml (ADR 0050); the marker has to live there to surface.
        $synopsis = [regex]::Match($script:ParkedSrc, '(?s)\.SYNOPSIS\s*(.*?)?
?
').Groups[1].Value
        $synopsis | Should -Match 'PARKED \(ADR 0064\)'
    }

    It 'carries the do-not-run warning block in .DESCRIPTION' {
        $script:ParkedSrc | Should -Match 'PARKED -- DO NOT RUN, DO NOT UN-PARK WITHOUT A FOLLOW-UP ADR'
    }

    It 'names the ADR that parked it' {
        $script:ParkedSrc | Should -Match 'docs/adr/0064-irm-entity-lists-are-microsoft-managed\.md'
    }

    It 'records the decisive finding: membership is not readable' {
        # Finding 4. Whoever un-parks this must confront it.
        $script:ParkedSrc | Should -Match '(?s)\.Entities` is EMPTY on every list'
    }

    It 'has no workflow driving it' {
        # ADR 0064 Decision #3 removed deploy-irm-entity-lists.yml. Any workflow
        # invoking a parked reconciler is a defect.
        $workflowDir = Join-Path $PSScriptRoot ".." ".." ".github" "workflows"
        $invokers = @(
            Get-ChildItem -Path $workflowDir -Filter '*.yml' -File |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Deploy-IRMEntityLists\.ps1' }
        )
        $invokers | Should -BeNullOrEmpty -Because 'a parked reconciler must not be reachable from CI'
    }

    It 'keeps the desired-state YAML empty, as ADR 0064 Decision #1 requires' {
        Import-Module powershell-yaml -ErrorAction Stop
        $yamlPath = Join-Path $PSScriptRoot ".." ".." "data-plane" "irm" "entity-lists.yaml"
        $doc = Get-Content -LiteralPath $yamlPath -Raw | ConvertFrom-Yaml
        $doc.ContainsKey('entityLists') | Should -BeTrue
        @($doc.entityLists).Count | Should -Be 0 -Because 'populating this file reconciles Microsoft-managed containers'
    }
}
