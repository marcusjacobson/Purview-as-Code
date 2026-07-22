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
            "Compare-EntityList")) {
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
