#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester tests for the issue #13 batch-2 prune guards in
    `scripts/Deploy-CommunicationCompliance.ps1`: the sanity-ratio guard
    (`Assert-PruneRatioWithinThreshold`, guard 2) and the collect-then-throw
    failure reporter (`Write-PruneFailure` + aggregate throw).

.DESCRIPTION
    This reconciler is Class B -- it declares no `-DirectionPolicy`, so it has
    no audit mode to gate guard 2 against, and its prune loop lives inside a
    `try/finally` that disconnects the Security & Compliance session. The
    behaviour is proven by lifting the real guard-2 and prune regions from the
    script and executing them against the shared module / stubbed cmdlets, the
    same technique the sibling reconciler test files use.

    Batch 2 makes a deliberate BEHAVIOUR CHANGE: a failed prune, which used to
    add a `Failed` report row and exit 0, now throws an aggregate after
    attempting every orphan and exits non-zero. The reporter execution tests
    lift the REAL region so they cannot keep passing against the pre-change
    shape.

    Reference: issue #13
    Reference: scripts/modules/PruneGuard.psm1
    Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-CommunicationCompliance.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-CommunicationCompliance.ps1 at: $script:ScriptPath"
    }
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors | ForEach-Object Message | Join-String -Separator '; '))
    }
}

Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:CcSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:CcSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:CcSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the communication-compliance noun' {
        $script:CcSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:CcSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'communication compliance policy'"))
    }
    It 'keys guard 2 on the live tenant policy count' {
        $script:CcSource | Should -Match ([regex]::Escape('@($tenantPolicies).Count'))
    }
    It 'surfaces the ratio override and threshold parameters' {
        $script:CcSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:CcSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:CcSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:CcSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
    It 'wires the failure reporter' {
        $script:CcSource | Should -Match 'Write-PruneFailure'
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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-CommunicationCompliance.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow)
            $PruneMissing = [switch]$true
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $plan = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Action = 'Orphan'; Name = "orphan-$i" } })
            $tenantPolicies = @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ Name = "live-$i" } })
            $null = $PruneMissing, $MaxPruneRatio, $AllowMajorityPrune, $plan, $tenantPolicies
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-CommunicationCompliance.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-CommunicationCompliance.ps1; update the anchor in this test.' }
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
            function Remove-SupervisoryReviewPolicyV2 {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add($Identity)
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($Names | ForEach-Object { [pscustomobject]@{ Action = 'Orphan'; Name = $_; Reason = 'orphan'; Desired = $null } })
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
        $script:ScriptPathForDepth = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-CommunicationCompliance.ps1'

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
