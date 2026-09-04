#Requires -Version 7.4
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in `scripts/Deploy-IRMPolicies.ps1`.

.DESCRIPTION
    Locks in the Microsoft Purview Insider Risk Management reconciler contract:

      1. `ConvertTo-DesiredIRMPolicyHash` normalizes a YAML policy entry
         into a comparable hashtable; missing optionals collapse to $null.
      2. `ConvertTo-TenantIRMPolicyHash` normalizes a `Get-InsiderRiskPolicy`
         row into the same shape, mapping `Comment` -> `description` and
         `InsiderRiskScenario` -> `scenario`.
      3. `Compare-IRMPolicy` returns an empty list for in-sync inputs and
         the field names that drift. `description`, `scenario`, and
         `enabled` are compared only when the desired side declares them
         (a missing optional in YAML is treated as "don''t manage").

    Pattern: AST-extract each helper from the script and dot-source into
    the test scope. We deliberately do NOT dot-source the script itself
    -- that would execute its top-level code and try to
    `Connect-IPPSSession` against the live tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicy
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMPolicies.ps1"
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-IRMPolicies.ps1 at: $script:ScriptPath"
    }

    $script:ScriptSource = Get-Content -LiteralPath $script:ScriptPath -Raw

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join "; "))
    }

    foreach ($fname in @(
            "ConvertTo-DesiredIRMPolicyHash",
            "ConvertTo-TenantIRMPolicyHash",
            "Compare-IRMPolicy",
            "Get-IRMSettableFieldDrift",
            "Invoke-IRMPolicyExport")) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe "ConvertTo-DesiredIRMPolicyHash normalizes YAML entries" {

    It "collapses missing optionals to null" {
        $entry = @{ name = "lab-irm-min"; scenario = "DataLeaks" }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-min"
        $hash.scenario    | Should -Be "DataLeaks"
        $hash.description | Should -BeNullOrEmpty
        $hash.enabled     | Should -BeNullOrEmpty
    }

    It "preserves every declared field" {
        $entry = @{
            name = "lab-irm-full"
            scenario = "IntellectualPropertyTheft"
            description = "Lab IRM"
            enabled = $true
        }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-full"
        $hash.scenario    | Should -Be "IntellectualPropertyTheft"
        $hash.description | Should -Be "Lab IRM"
        $hash.enabled     | Should -BeTrue
    }

    It "stringifies non-string description" {
        $entry = @{ name = "lab-irm-num"; scenario = "DataLeaks"; description = 42 }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.description | Should -Be "42"
    }
}

Describe "ConvertTo-TenantIRMPolicyHash normalizes Get-InsiderRiskPolicy rows" {

    It "maps Comment to description and InsiderRiskScenario to scenario" {
        $row = [pscustomobject]@{
            Name = "IRM Lab"
            Comment = "live"
            InsiderRiskScenario = "DataLeaks"
            Enabled = $true
            IsCustom = $false
        }
        $hash = ConvertTo-TenantIRMPolicyHash -Policy $row
        $hash.name        | Should -Be "IRM Lab"
        $hash.description | Should -Be "live"
        $hash.scenario    | Should -Be "DataLeaks"
        $hash.enabled     | Should -BeTrue
        $hash.isCustom    | Should -BeFalse
    }

    It "handles null Comment without throwing" {
        $row = [pscustomobject]@{
            Name = "n"; Comment = $null; InsiderRiskScenario = "DataLeaks"; Enabled = $false; IsCustom = $true
        }
        $hash = ConvertTo-TenantIRMPolicyHash -Policy $row
        $hash.description | Should -BeNullOrEmpty
    }
}

Describe "Compare-IRMPolicy returns drift field names" {

    It "returns empty list for in-sync inputs" {
        $d = @{ name="x"; scenario="DataLeaks"; description="d"; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="d"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports description drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description="want"; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="have"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "description"
    }

    It "ignores description drift when YAML omits it" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="tenant-only"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports scenario drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$null }
        $t = @{ name="x"; scenario="IntellectualPropertyTheft"; description=$null; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "scenario"
    }

    It "reports enabled drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$false }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "enabled"
    }

    It "ignores enabled drift when YAML omits it" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$null }
        $t = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }
}

Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:PolSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:PolSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:PolSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the IRM policy noun' {
        $script:PolSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:PolSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'insider risk management policy'"))
    }
    It 'excludes the system-managed IRM_Tenant_Setting_* policies from the denominator' {
        $script:PolSource | Should -Match ([regex]::Escape("-notlike 'IRM_Tenant_Setting_*'"))
    }
    It 'surfaces the ratio override and threshold parameters' {
        $script:PolSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:PolSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
    }
    It 'gates guard 2 on non-audit (AUDIT TRAP: script flips WhatIfPreference, does not empty orphans)' {
        $script:PolSource | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:PolSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:PolSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-IRMPolicies.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [int]$System = 0, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $plan = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Action = 'Orphan'; Name = "orphan-$i" } })
            $tenantPolicies = @(
                @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ Name = "live-$i" } }) +
                @(for ($i = 0; $i -lt $System; $i++) { [pscustomobject]@{ Name = "IRM_Tenant_Setting_$i" } })
            )
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $plan, $tenantPolicies
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 prunable live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 prunable live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 prunable live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'does NOT fire under -DirectionPolicy audit even above the threshold (audit trap)' { { Invoke-Guard2 -Prune 10 -Live 10 -Direction 'audit' } | Should -Not -Throw }
    It 'fires on 4 of 6 prunable even with 100 system policies present (denominator excludes IRM_Tenant_Setting_*)' {
        # If the denominator counted the system policies, 4/106 would pass; it
        # throws because the system policies are excluded and the ratio is 4/6.
        { Invoke-Guard2 -Prune 4 -Live 6 -System 100 } | Should -Throw
    }
    It 'still passes at 3 of 6 prunable with 100 system policies (ratio is over prunable only)' {
        { Invoke-Guard2 -Prune 3 -Live 6 -System 100 } | Should -Not -Throw
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-IRMPolicies.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-IRMPolicies.ps1; update the anchor in this test.' }
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
            function Remove-InsiderRiskPolicy {
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
        $script:ScriptPathForDepth = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-IRMPolicies.ps1'

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

Describe 'Export parameter set contract (#177)' {

    BeforeAll {
        $script:ExportSrcPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMPolicies.ps1"
        $script:ExportSrc = Get-Content -LiteralPath $script:ExportSrcPath -Raw
        $errs = $null
        $script:ExportAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ExportSrcPath, [ref]$null, [ref]$errs)
        if ($errs) { throw ("Parse errors: {0}" -f ($errs -join '; ')) }

        function Get-ParamByName {
            param([string]$Name)
            return $script:ExportAst.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $Name } |
                Select-Object -First 1
        }

        function Get-ParameterSetNames {
            param([string]$Name)
            $p = Get-ParamByName -Name $Name
            if (-not $p) { throw "Parameter -$Name not found" }
            $names = @()
            foreach ($attr in $p.Attributes) {
                if ($attr.TypeName.Name -ne 'Parameter') { continue }
                foreach ($na in $attr.NamedArguments) {
                    if ($na.ArgumentName -eq 'ParameterSetName') {
                        $names += $na.Argument.Value
                    }
                }
            }
            return $names
        }
    }

    It 'exposes -ExportCurrentState as a mandatory switch in the Export parameter set' {
        $p = Get-ParamByName -Name 'ExportCurrentState'
        $p | Should -Not -BeNullOrEmpty
        $p.StaticType.Name | Should -Be 'SwitchParameter'
        (Get-ParameterSetNames -Name 'ExportCurrentState') | Should -Be @('Export')

        $mandatory = $false
        foreach ($attr in $p.Attributes) {
            if ($attr.TypeName.Name -ne 'Parameter') { continue }
            foreach ($na in $attr.NamedArguments) {
                if ($na.ArgumentName -eq 'Mandatory') { $mandatory = $true }
            }
        }
        $mandatory | Should -BeTrue -Because 'a non-mandatory switch cannot select its own parameter set'
    }

    It 'declares Apply as the default parameter set so existing callers bind unchanged' {
        $cmdletBinding = $script:ExportAst.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } | Select-Object -First 1
        $default = $cmdletBinding.NamedArguments |
            Where-Object { $_.ArgumentName -eq 'DefaultParameterSetName' } | Select-Object -First 1
        $default.Argument.Value | Should -Be 'Apply'
    }

    It 'keeps every prune and skip parameter OUT of the Export set' -ForEach @(
        @{ ParamName = 'PruneMissing' }
        @{ ParamName = 'AllowMajorityPrune' }
        @{ ParamName = 'MaxPruneRatio' }
        @{ ParamName = 'SkipNames' }
    ) {
        $sets = Get-ParameterSetNames -Name $ParamName
        $sets | Should -Contain 'Apply'
        $sets | Should -Not -Contain 'Export' -Because 'an export neither plans nor writes to the tenant, so a prune or skip flag on it would be meaningless'
    }

    It 'computes the mode variable from -ExportCurrentState before the desired-state load region' {
        $modeIdx = $script:ExportSrc.IndexOf('$mode = if ($ExportCurrentState.IsPresent)')
        $regionIdx = $script:ExportSrc.IndexOf('#region Desired-state load')
        $modeIdx | Should -BeGreaterThan 0
        $regionIdx | Should -BeGreaterThan 0
        $modeIdx | Should -BeLessThan $regionIdx
    }

    It 'keeps prune guard 1 inside the Apply-only block and ahead of the first tenant contact' {
        # PruneGuardRollout.Tests.ps1 pins the guard-before-contact ordering by
        # line number; this asserts the same invariant survived the mode wrap.
        $lines = Get-Content -LiteralPath $script:ExportSrcPath
        $applyWrap = ($lines | Select-String -Pattern "^if \(\`$mode -eq 'Apply'\) \{" | Select-Object -First 1).LineNumber
        $guard     = ($lines | Select-String -Pattern 'Assert-PruneDesiredSetNotEmpty' | Select-Object -First 1).LineNumber
        $contact   = ($lines | Select-String -Pattern "^\`$accountJson = az account show" | Select-Object -First 1).LineNumber

        $applyWrap | Should -BeLessThan $guard
        $guard     | Should -BeLessThan $contact
    }

    It 'places the Export short-circuit after the tenant enumerate and before the plan builder' {
        $enumIdx   = $script:ExportSrc.IndexOf('Get-InsiderRiskPolicy -ErrorAction Stop')
        $exportIdx = $script:ExportSrc.IndexOf("if (`$mode -eq 'Export')")
        $planIdx   = $script:ExportSrc.IndexOf('$plan = New-Object')
        $enumIdx   | Should -BeGreaterThan 0
        $exportIdx | Should -BeGreaterThan $enumIdx
        $planIdx   | Should -BeGreaterThan $exportIdx
    }

    It 'adds no new ADR 0052 confirmation gate (export is not a destructive tenant operation)' {
        ([regex]::Matches($script:ExportSrc, 'Assert-DestructiveOperationConfirmed @gateArgs')).Count |
            Should -Be 2 -Because 'ConfirmGate.Tests.ps1 pins this reconciler at exactly 2 gates'
    }
}

Describe 'Invoke-IRMPolicyExport round-trips tenant state into schema-valid YAML (#177)' {

    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:SchemaPath = Join-Path $PSScriptRoot ".." ".." "data-plane" "irm" "policies.schema.json"
        $script:SchemaText = Get-Content -LiteralPath $script:SchemaPath -Raw

        # Repeated-nibble synthetic GUID: the ADR 0055 residue scan fails closed
        # on anything that looks like a real tenant identifier.
        $script:FakeTenantGuid = '22222222-2222-2222-2222-222222222222'

        function New-TenantPolicyRow {
            param(
                [string]$Name,
                [string]$Comment = $null,
                [string]$Scenario = 'LeakOfInformation',
                [bool]$Enabled = $true
            )
            return [pscustomobject]@{
                Name                = $Name
                Comment             = $Comment
                InsiderRiskScenario = $Scenario
                Enabled             = $Enabled
                IsCustom            = $false
            }
        }

        function Test-ExportedDocSchemaValid {
            # Validate the whole document AND each policy individually. Test-Json
            # misattributes anyOf/oneOf errors, so a per-item pass is what actually
            # localizes a failure (the DLP #71 lesson).
            param([hashtable]$Doc)
            ($Doc | ConvertTo-Json -Depth 25) | Test-Json -Schema $script:SchemaText -ErrorAction Stop | Out-Null
            foreach ($p in @($Doc.policies)) {
                (@{ policies = @($p) } | ConvertTo-Json -Depth 25) |
                    Test-Json -Schema $script:SchemaText -ErrorAction Stop | Out-Null
            }
            return $true
        }
    }

    It 'emits only the tracked fields and omits description when the tenant Comment is empty' {
        $out = Join-Path $TestDrive 'export-tracked.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'no-comment-policy' -Comment $null)
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $entry = @($doc.policies)[0]

        $entry.ContainsKey('description') | Should -BeFalse -Because 'an absent Comment must not round-trip as a declared-empty description'
        $entry.ContainsKey('isCustom')    | Should -BeFalse -Because 'the schema sets additionalProperties:false'
        @($entry.Keys | Sort-Object)      | Should -Be @('enabled', 'name', 'scenario')
    }

    It 'emits description when the tenant carries a Comment' {
        $out = Join-Path $TestDrive 'export-comment.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'commented' -Comment 'a real comment')
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.policies)[0].description | Should -Be 'a real comment'
    }

    It 'never writes the system-managed IRM_Tenant_Setting_* policy (ADR 0036)' {
        $out = Join-Path $TestDrive 'export-system.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'keep-me'),
            (New-TenantPolicyRow -Name "IRM_Tenant_Setting_$script:FakeTenantGuid" -Scenario 'TenantSetting')
        )
        $raw = Get-Content -LiteralPath $out -Raw
        $raw | Should -Not -Match 'IRM_Tenant_Setting_' -Because 'its name embeds the real tenant GUID, which the ADR 0055 residue scan fails closed on'
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.policies).Count | Should -Be 1
        @($doc.policies)[0].name | Should -Be 'keep-me'
    }

    It 'produces a document that validates against policies.schema.json, per policy and whole' {
        $out = Join-Path $TestDrive 'export-schema.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'alpha' -Comment 'first' -Scenario 'IntellectualPropertyTheft' -Enabled $true)
            (New-TenantPolicyRow -Name 'beta' -Comment $null -Scenario 'LeakOfInformation' -Enabled $false)
        )
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        { Test-ExportedDocSchemaValid -Doc $doc } | Should -Not -Throw
    }

    It 'round-trips NoChange by construction: exported entries compare clean against their source rows' {
        $rows = @(
            (New-TenantPolicyRow -Name 'rt-one' -Comment 'desc one' -Scenario 'LeakOfInformation' -Enabled $true)
            (New-TenantPolicyRow -Name 'rt-two' -Comment $null -Scenario 'WorkplaceThreat' -Enabled $false)
        )
        $out = Join-Path $TestDrive 'export-roundtrip.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies $rows

        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        foreach ($entry in @($doc.policies)) {
            $desired = ConvertTo-DesiredIRMPolicyHash -Entry ([hashtable]$entry)
            $source  = $rows | Where-Object { $_.Name -eq $entry.name } | Select-Object -First 1
            $tenant  = ConvertTo-TenantIRMPolicyHash -Policy $source
            $diffs   = Compare-IRMPolicy -Desired $desired -Tenant $tenant
            $diffs.Count | Should -Be 0 -Because "a freshly exported '$($entry.name)' must re-compare clean, or export and compare disagree"
        }
    }

    It 'preserves the existing file comment header' {
        $out = Join-Path $TestDrive 'export-header.yaml'
        Set-Content -LiteralPath $out -Value @(
            '# Curated header line one.',
            '#',
            '# Curated header line two.',
            'policies: []'
        ) -Encoding utf8
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @((New-TenantPolicyRow -Name 'after-header'))
        $raw = Get-Content -LiteralPath $out -Raw
        $raw | Should -Match '# Curated header line one\.'
        $raw | Should -Match '# Curated header line two\.'
        $raw | Should -Match 'after-header'
    }

    It 'refuses to clobber a file that already declares policy entries unless -Force is passed' {
        $out = Join-Path $TestDrive 'export-guard.yaml'
        Set-Content -LiteralPath $out -Value @(
            '# header',
            'policies:',
            '  - name: pre-existing',
            '    scenario: LeakOfInformation',
            '    enabled: true'
        ) -Encoding utf8
        $before = Get-Content -LiteralPath $out -Raw

        Invoke-IRMPolicyExport -Path $out -TenantPolicies @((New-TenantPolicyRow -Name 'replacement')) -ErrorAction SilentlyContinue -ErrorVariable expErr
        $expErr | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $out -Raw) | Should -Be $before -Because 'the refusal must leave the operator YAML untouched'
    }

    It 'overwrites a populated file when -Force is passed' {
        $out = Join-Path $TestDrive 'export-force.yaml'
        Set-Content -LiteralPath $out -Value @(
            '# header',
            'policies:',
            '  - name: pre-existing',
            '    scenario: LeakOfInformation',
            '    enabled: true'
        ) -Encoding utf8
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @((New-TenantPolicyRow -Name 'replacement')) -Force
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.policies).Count | Should -Be 1
        @($doc.policies)[0].name | Should -Be 'replacement'
    }

    It 'writes LF endings, UTF-8 without BOM, and exactly one trailing newline' {
        $out = Join-Path $TestDrive 'export-encoding.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @((New-TenantPolicyRow -Name 'enc'))
        $bytes = [System.IO.File]::ReadAllBytes($out)

        # No UTF-8 BOM.
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) |
            Should -BeFalse -Because 'a BOM breaks git show <branch>:<path> parsing (the console YamlDotNet issue)'
        # No CR anywhere.
        ($bytes -contains 0x0D) | Should -BeFalse -Because 'yamllint new-lines expects LF regardless of host OS'
        # Exactly one trailing LF.
        $bytes[$bytes.Length - 1] | Should -Be 0x0A
        $bytes[$bytes.Length - 2] | Should -Not -Be 0x0A
    }

    It 'writes an empty policies list for an empty tenant, and it stays schema-valid' {
        $out = Join-Path $TestDrive 'export-empty.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @()
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $doc.ContainsKey('policies') | Should -BeTrue -Because 'the schema marks policies required'
        @($doc.policies).Count | Should -Be 0
        { Test-ExportedDocSchemaValid -Doc @{ policies = @() } } | Should -Not -Throw
    }

    It 'never emits an empty-string or null scalar' {
        $out = Join-Path $TestDrive 'export-nonull.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'n1' -Comment $null),
            (New-TenantPolicyRow -Name 'n2' -Comment '')
        )
        $raw = Get-Content -LiteralPath $out -Raw
        $raw | Should -Not -Match "description:\s*''"
        $raw | Should -Not -Match ':\s*null'
    }

    It 'warns and skips a tenant policy that reports no InsiderRiskScenario' {
        $out = Join-Path $TestDrive 'export-noscenario.yaml'
        Invoke-IRMPolicyExport -Path $out -TenantPolicies @(
            (New-TenantPolicyRow -Name 'valid'),
            (New-TenantPolicyRow -Name 'scenario-less' -Scenario $null)
        ) -WarningVariable warns -WarningAction SilentlyContinue

        $warns | Should -Not -BeNullOrEmpty
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        @($doc.policies).Count | Should -Be 1
        @($doc.policies)[0].name | Should -Be 'valid'
    }
}

Describe 'Immutable scenario drift plans a Blocked row, never an unsatisfiable Update (#177)' {

    BeforeAll {
        $script:BlockedSrcPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMPolicies.ps1"
        $script:BlockedLines = Get-Content -LiteralPath $script:BlockedSrcPath
        $script:BlockedSrc = $script:BlockedLines -join [Environment]::NewLine

        # ---- Lift the plan-builder region ----
        # Anchored on the $plan declaration through the line before the ADR 0029
        # audit short-circuit comment banner.
        $planStart = -1
        $planEnd = -1
        for ($i = 0; $i -lt $script:BlockedLines.Count; $i++) {
            if ($planStart -lt 0 -and $script:BlockedLines[$i] -match '^\s*\$plan = New-Object') { $planStart = $i; continue }
            if ($planStart -ge 0 -and $script:BlockedLines[$i] -match '^\s*# ---- ADR 0029: audit-mode short-circuit') { $planEnd = $i - 1; break }
        }
        if ($planStart -lt 0 -or $planEnd -lt 0) {
            throw 'Could not locate the plan-builder region in Deploy-IRMPolicies.ps1; update the anchor in this test.'
        }
        $script:PlanRegion = ($script:BlockedLines[$planStart..$planEnd] -join [Environment]::NewLine)

        function Invoke-PlanBuilder {
            # Drives the real plan-builder region against stub inputs.
            param(
                [hashtable[]]$Desired,
                [hashtable]$TenantByName,
                [object[]]$TenantPolicies = @(),
                [switch]$Prune
            )
            $desiredEntries = $Desired
            $tenantByName = $TenantByName
            $tenantPolicies = $TenantPolicies
            $desiredNames = @($desiredEntries | ForEach-Object { $_.name })
            $PruneMissing = [switch]$Prune
            $null = $desiredEntries, $tenantByName, $tenantPolicies, $desiredNames, $PruneMissing
            & ([scriptblock]::Create($script:PlanRegion + [Environment]::NewLine + '$plan'))
        }

        # ---- Lift the ADR 0029 direction-policy pass ----
        $dirStart = -1
        $dirEnd = -1
        for ($i = 0; $i -lt $script:BlockedLines.Count; $i++) {
            if ($dirStart -lt 0 -and $script:BlockedLines[$i] -match '^\s*\$script:Adr0029Skips = New-Object') { $dirStart = $i; continue }
            if ($dirStart -ge 0 -and $script:BlockedLines[$i] -match '^\s*# ---- Issue #13, guard 2') { $dirEnd = $i - 1; break }
        }
        if ($dirStart -lt 0 -or $dirEnd -lt 0) {
            throw 'Could not locate the ADR 0029 direction-policy region in Deploy-IRMPolicies.ps1; update the anchor in this test.'
        }
        $script:DirectionRegion = ($script:BlockedLines[$dirStart..$dirEnd] -join [Environment]::NewLine)

        Import-Module (Join-Path $PSScriptRoot ".." ".." "scripts" "modules" "DirectionPolicy.psm1") -Force -ErrorAction Stop

        function Invoke-DirectionPass {
            # Drives the real ADR 0029 pass and returns both the mutated plan and
            # the overwrite list the ADR 0052 gate keys on.
            param(
                [object[]]$Plan,
                [string]$Direction = 'portal-wins',
                [string[]]$Skip = @()
            )
            $plan = $Plan
            $DirectionPolicy = $Direction
            $SkipNames = $Skip
            $null = $plan, $DirectionPolicy, $SkipNames
            $sb = [scriptblock]::Create(
                $script:DirectionRegion + [Environment]::NewLine +
                '[pscustomobject]@{ Plan = $plan; Overwrites = $repoWinsOverwrites }')
            return (& $sb 6>$null 3>$null)
        }

        $script:DesiredScenarioDrift = @{
            name = 'scenario-drifter'; scenario = 'WorkplaceThreat'; description = $null; enabled = $true
        }
        $script:TenantScenarioDrift = @{
            'scenario-drifter' = @{ name = 'scenario-drifter'; scenario = 'LeakOfInformation'; description = $null; enabled = $true }
        }
    }

    It 'classifies scenario drift as Blocked rather than Update' {
        $plan = @(Invoke-PlanBuilder -Desired @($script:DesiredScenarioDrift) -TenantByName $script:TenantScenarioDrift)
        $row = $plan | Where-Object { $_.Name -eq 'scenario-drifter' }
        $row.Action | Should -Be 'Blocked'
        @($plan | Where-Object { $_.Action -eq 'Update' }).Count | Should -Be 0 -Because 'Set-InsiderRiskPolicy has no InsiderRiskScenario parameter, so an Update row could never converge'
    }

    It 'explains in the Reason that the field is immutable and names both sides' {
        $plan = @(Invoke-PlanBuilder -Desired @($script:DesiredScenarioDrift) -TenantByName $script:TenantScenarioDrift)
        $row = $plan | Where-Object { $_.Name -eq 'scenario-drifter' }
        $row.Reason | Should -Match 'Immutable field drift: scenario'
        $row.Reason | Should -Match 'WorkplaceThreat'
        $row.Reason | Should -Match 'LeakOfInformation'
    }

    It 'still plans a plain Update when only mutable fields drift' {
        $desired = @{ name = 'mutable-drifter'; scenario = 'LeakOfInformation'; description = 'new text'; enabled = $true }
        $tenant  = @{ 'mutable-drifter' = @{ name = 'mutable-drifter'; scenario = 'LeakOfInformation'; description = 'old text'; enabled = $true } }
        $plan = @(Invoke-PlanBuilder -Desired @($desired) -TenantByName $tenant)
        ($plan | Where-Object { $_.Name -eq 'mutable-drifter' }).Action | Should -Be 'Update'
    }

    It 'keeps a Blocked row out of the ADR 0052 overwrite list even under repo-wins' {
        $blocked = [pscustomobject]@{
            Action = 'Blocked'; Name = 'scenario-drifter'; Desired = $script:DesiredScenarioDrift
            Reason = "Immutable field drift: scenario (YAML 'WorkplaceThreat', tenant 'LeakOfInformation')."
        }
        $result = Invoke-DirectionPass -Plan @($blocked) -Direction 'repo-wins'
        @($result.Overwrites).Count | Should -Be 0 -Because 'the gate must not ask the operator to confirm an overwrite that cannot happen'
        ($result.Plan | Where-Object { $_.Name -eq 'scenario-drifter' }).Action | Should -Be 'Blocked'
    }

    It 'lets -SkipNames suppress a Blocked row like any other category (ADR 0029)' {
        $blocked = [pscustomobject]@{
            Action = 'Blocked'; Name = 'scenario-drifter'; Desired = $script:DesiredScenarioDrift
            Reason = 'Immutable field drift: scenario.'
        }
        $result = Invoke-DirectionPass -Plan @($blocked) -Direction 'portal-wins' -Skip @('scenario-drifter')
        ($result.Plan | Where-Object { $_.Name -eq 'scenario-drifter' }).Action | Should -Be 'Skip'
    }

    It 'reports Blocked rows in the apply loop without invoking Set-InsiderRiskPolicy' {
        # The apply loop's Blocked case must be report-only. A stub that throws
        # on call proves no write is attempted.
        $applyStart = -1
        for ($i = 0; $i -lt $script:BlockedLines.Count; $i++) {
            if ($script:BlockedLines[$i] -match "^\s*'Blocked' \{") { $applyStart = $i; break }
        }
        $applyStart | Should -BeGreaterThan 0 -Because 'the apply loop must carry a Blocked case'

        $depth = 0; $applyEnd = -1
        for ($j = $applyStart; $j -lt $script:BlockedLines.Count; $j++) {
            $depth += ([regex]::Matches($script:BlockedLines[$j], '\{')).Count
            $depth -= ([regex]::Matches($script:BlockedLines[$j], '\}')).Count
            if ($depth -le 0) { $applyEnd = $j; break }
        }
        # Strip comment lines before asserting: the case carries prose explaining
        # WHY it makes no ShouldProcess call, and matching that prose would be a
        # test of the comment rather than of the code.
        $codeOnly = (@($script:BlockedLines[$applyStart..$applyEnd] | Where-Object { $_ -notmatch '^\s*#' }) -join [Environment]::NewLine)
        $codeOnly | Should -Not -Match 'Set-InsiderRiskPolicy' -Because 'a Blocked row must never reach a write cmdlet'
        $codeOnly | Should -Not -Match 'ShouldProcess' -Because 'there is no tenant operation to gate'
        $codeOnly | Should -Match "Category = 'Blocked'"
    }

    It 'declares Blocked in the reverse-sync workflow drift categories' {
        # A Blocked row needs a human decision, so sync-irm-from-tenant.yml must
        # count it as drift or the daily audit would pass over it silently.
        $syncPath = Join-Path $PSScriptRoot ".." ".." ".github" "workflows" "sync-irm-from-tenant.yml"
        $sync = Get-Content -LiteralPath $syncPath -Raw
        $sync | Should -Match "\`$driftCategories = @\([^)]*'Blocked'[^)]*\)"
    }
}

Describe 'The tracked desired state is in the exporter''s canonical order (#190)' {
    # Found live, by the export round-trip in issue #190's Leg 0. The dev
    # tenant returned every policy byte-identical to the committed file --
    # and the export still produced a five-line diff, because the committed
    # file listed `pac-lab-irm-data-leaks` first while the exporter emits it
    # last. Nothing had drifted; the file simply was not in the order a
    # re-export produces.
    #
    # That matters because a re-export is not a diagnostic here, it is a
    # PRODUCER. deploy-irm.yml re-exports on a portal-wins run and opens a
    # drift-back PR from the result, and Invoke-LocalIrmDriftSync.ps1 does
    # the same locally. A file that is not in canonical order makes both of
    # them open a PR whose diff is a pure reordering, indistinguishable at a
    # glance from a real portal edit -- exactly the noise that got #170 and
    # #172 merged reflexively on the sibling surface.
    #
    # The audit path never sees this: it compares by name, so it reported
    # all-NoChange on the same tenant in the same minute. Only the export
    # path is order-sensitive, which is why no existing test caught it.

    BeforeAll {
        $script:TrackedYamlPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'irm' 'policies.yaml'
        Import-Module powershell-yaml -ErrorAction Stop
        $script:TrackedNames = @(
            ((Get-Content -LiteralPath $script:TrackedYamlPath -Raw | ConvertFrom-Yaml).policies) |
                ForEach-Object { [string]$_.name })
    }

    It 'the exporter sorts tenant policies by name before writing' {
        # Read the production sort rather than restating it: if this line
        # changes, the ordering assertion below is no longer describing the
        # same contract and must be revisited deliberately.
        $source = Get-Content -LiteralPath $script:ScriptPath -Raw
        $source | Should -Match 'Sort-Object \{ \[string\]\$_\.Name \}' -Because 'the canonical order the tracked file must match is whatever the exporter emits'
    }

    It 'the tracked policies.yaml lists policies in that same order' {
        # A genuinely empty desired-state file is not vacuous SUCCESS for
        # this contract -- it is OUT OF SCOPE for it. This repository ships
        # data-plane/irm/policies.yaml empty by design (ADR 0056: the
        # template carries no tenant-tailored desired state); an operator
        # branch that populates the file is exactly where this assertion
        # earns its keep, so it stays a hard requirement there.
        if ($script:TrackedNames.Count -eq 0) {
            Set-ItResult -Skipped -Because 'the tracked file is empty here (ADR 0056 template default); nothing to order'
            return
        }
        $expected = @($script:TrackedNames | Sort-Object { [string]$_ })
        # Compare-Object with -SyncWindow 0 catches a reordering; without it,
        # two lists holding the same names in a different order compare equal.
        $diff = Compare-Object -ReferenceObject $script:TrackedNames -DifferenceObject $expected -SyncWindow 0
        $diff | Should -BeNullOrEmpty -Because 'a re-export would otherwise open a drift-back PR whose diff is a pure reordering'
    }

    It 'holds for a branch whose desired state carries a lowercase name (the case that actually broke)' {
        # Regression anchor, independent of what the current branch happens
        # to track: an entry sorting after the uppercase-initial names must
        # be written last, not first. This is the dev-branch shape.
        $names = @('pac-lab-irm-data-leaks', 'DSPM for AI - Detect risky AI usage', 'IRM Lab - General data leaks')
        $sorted = @($names | Sort-Object { [string]$_ })
        $sorted[-1] | Should -Be 'pac-lab-irm-data-leaks'
    }
}

Describe 'The create path converges fields the service ignores (#196)' {
    # New-InsiderRiskPolicy accepts -Enabled:$false and creates the policy
    # ENABLED anyway; Set-InsiderRiskPolicy honours the same flag.
    # Reproduced live on BOTH tenants during #190, so it is a cmdlet-level
    # defect rather than a tenant quirk.
    #
    # Why it mattered beyond the one field: under `portal-wins` -- the
    # default -- the resulting drift is converted to `Skipped` rather than
    # corrected, and the re-export then opens a drift-back PR proposing to
    # change the committed YAML to `enabled: true`. A reviewer would see a
    # one-line diff that looks entirely reasonable and merge an unintended
    # tenant state into the source of truth. That is the #170 / #172
    # failure reached from a different direction.

    Context 'Get-IRMSettableFieldDrift' {
        BeforeAll {
            $script:Desired196 = @{ name = 'p'; description = 'd'; scenario = 'LeakOfInformation'; enabled = $false }
        }

        It 'reports enabled when the create ignored it' {
            $asCreated = @{ name = 'p'; description = 'd'; scenario = 'LeakOfInformation'; enabled = $true }
            $drift = @(Get-IRMSettableFieldDrift -Desired $script:Desired196 -Tenant $asCreated)
            $drift | Should -Contain 'enabled'
        }

        It 'excludes scenario, which no Set- can correct' {
            # A post-create scenario difference is not something to converge:
            # InsiderRiskScenario is set-once, so retrying is a write that
            # can never succeed. The caller must report Failed instead.
            $wrongScenario = @{ name = 'p'; description = 'd'; scenario = 'IntellectualPropertyTheft'; enabled = $false }
            @(Get-IRMSettableFieldDrift -Desired $script:Desired196 -Tenant $wrongScenario) | Should -BeNullOrEmpty
            @(Compare-IRMPolicy -Desired $script:Desired196 -Tenant $wrongScenario) | Should -Contain 'scenario' -Because 'the difference is still real -- it is only unfixable in place'
        }

        It 'reports nothing when the create honoured everything' {
            $honoured = @{ name = 'p'; description = 'd'; scenario = 'LeakOfInformation'; enabled = $false }
            @(Get-IRMSettableFieldDrift -Desired $script:Desired196 -Tenant $honoured) | Should -BeNullOrEmpty
        }

        It 'reports description too -- the guard is general, not enabled-specific' {
            $wrongComment = @{ name = 'p'; description = 'something else'; scenario = 'LeakOfInformation'; enabled = $false }
            @(Get-IRMSettableFieldDrift -Desired $script:Desired196 -Tenant $wrongComment) | Should -Contain 'description'
        }
    }

    Context 'the apply loop wires the verification' {
        BeforeAll {
            $script:CreateBranch = [regex]::Match(
                $script:ScriptSource,
                "'Create'\s*\{.*?\n            'Update'", 'Singleline').Value
            $script:CreateBranch | Should -Not -BeNullOrEmpty
        }

        It 'reads the policy back after New-InsiderRiskPolicy' {
            $script:CreateBranch | Should -Match 'New-InsiderRiskPolicy @splat'
            $script:CreateBranch | Should -Match 'Get-InsiderRiskPolicy -Identity \$row\.Desired\.name' -Because 'a create-only bootstrap cannot see a field the service silently declined'
        }

        It 'issues a corrective Set-InsiderRiskPolicy for settable drift' {
            $script:CreateBranch | Should -Match 'Get-IRMSettableFieldDrift'
            $script:CreateBranch | Should -Match 'Set-InsiderRiskPolicy @fixSplat'
        }

        It 'reports Failed, never a retry, when the created scenario is wrong' {
            $script:CreateBranch | Should -Match "set-once on New-InsiderRiskPolicy"
            $script:CreateBranch | Should -Match "Category = 'Failed'"
        }

        It 'reports Failed when the corrective write does not take either' {
            $script:CreateBranch | Should -Match 'did not take on either the create or the follow-up'
        }

        It 'does NOT turn an unverifiable create into a Failed row' {
            # A read-back that fails is not a failed create. It must still
            # report Created, but must not claim the state was verified.
            $script:CreateBranch | Should -Match 'could not read it back to verify'
            $script:CreateBranch | Should -Match 'declared state is unconfirmed'
        }

        It 'emits exactly one report row per create outcome' {
            # The success row is gated on the failure flag so a Failed row
            # and a Created row can never both be emitted for one policy.
            $script:CreateBranch | Should -Match '\$createFailed = \$false'
            $script:CreateBranch | Should -Match 'if \(-not \$createFailed\)'
        }
    }
}
