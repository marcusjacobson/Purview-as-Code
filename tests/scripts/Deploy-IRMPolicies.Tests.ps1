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
            "Compare-IRMPolicy")) {
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
