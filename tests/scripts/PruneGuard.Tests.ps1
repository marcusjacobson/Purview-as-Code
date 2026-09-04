#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the shared -PruneMissing safety guards:
    scripts/modules/PruneGuard.psm1 and its first consumer,
    scripts/Deploy-Labels.ps1. Issue #13.

.DESCRIPTION
    Three behaviours are pinned here, each of which has already failed in
    production or would have:

      1. GUARD 1 -- empty desired set. A zero-entry desired-state file
         classifies every live tenant object as an orphan. Nearly hit on
         2026-07-19 against the dev tenant from a stale working tree.
      2. GUARD 2 -- sanity ratio. A near-total prune clears guard 1 but is
         still almost always a misconfiguration. The boundary cases
         (at threshold vs over threshold) and the override are the whole
         contract, so all three are asserted explicitly.
      3. REPORTER -- Write-PruneFailure must not terminate the caller
         under $ErrorActionPreference='Stop'. This is the exact condition
         GitHub Actions imposes on every `shell: pwsh` step, and the
         reason the prune loop previously abandoned its remaining orphans
         after the first failure (run 29694478494). The test drives it
         under a real 'Stop' preference rather than asserting on source
         text, because the hazard is a runtime stream behaviour.

    Pattern: behaviour tests against the shared module directly (it is
    pure -- no tenant calls, no connection cmdlets), plus source-text
    assertions on Deploy-Labels.ps1 that the inline implementations were
    genuinely replaced by module calls rather than duplicated.

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #13
    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables
#>

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'

    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'modules' 'PruneGuard.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate PruneGuard.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    $script:LabelsScriptPath = Join-Path $script:RepoRoot 'scripts' 'Deploy-Labels.ps1'
    $script:LabelsSource     = Get-Content -LiteralPath $script:LabelsScriptPath -Raw
}

Describe 'PruneGuard module surface' {

    It 'exports exactly the three guard functions' {
        $exported = (Get-Module -Name 'PruneGuard').ExportedFunctions.Keys | Sort-Object
        $exported | Should -Be @(
            'Assert-PruneDesiredSetNotEmpty',
            'Assert-PruneRatioWithinThreshold',
            'Write-PruneFailure'
        )
    }

    It 'takes a caller-supplied object-type noun rather than hard-coding labels' {
        # The module is consumed by 21 reconcilers over different object
        # types; label vocabulary in the API would block that reuse.
        (Get-Command Assert-PruneDesiredSetNotEmpty).Parameters.Keys |
            Should -Contain 'ObjectTypeNoun'
        (Get-Command Assert-PruneRatioWithinThreshold).Parameters.Keys |
            Should -Contain 'ObjectTypeNoun'
    }
}

Describe 'Assert-PruneDesiredSetNotEmpty (guard 1: empty desired set)' {

    BeforeAll {
        $script:G1 = @{
            ObjectTypeNoun = 'sensitivity label'
            SourcePath     = '/repo/data-plane/information-protection/labels.yaml'
            CollectionKey  = 'labels'
        }
    }

    It 'throws when the desired set is empty' {
        { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 0 } |
            Should -Throw
    }

    It 'names the likely causes in the refusal message' {
        $err = $null
        try { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 0 }
        catch { $err = $_.Exception.Message }

        $err | Should -Match 'Stale or unpulled branch'
        $err | Should -Match 'Wrong -Path'
        $err | Should -Match 'yielded no'
    }

    It 'names the source path and the collection key so a misconfiguration is visible on sight' {
        $err = $null
        try { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 0 }
        catch { $err = $_.Exception.Message }

        $err | Should -Match ([regex]::Escape($script:G1.SourcePath))
        $err | Should -Match 'labels'
    }

    It 'records the 2026-07-19 production hit in the refusal message' {
        $err = $null
        try { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 0 }
        catch { $err = $_.Exception.Message }

        $err | Should -Match '2026-07-19'
    }

    It 'passes when the desired set has one entry' {
        { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 1 } |
            Should -Not -Throw
    }

    It 'passes when the desired set has many entries' {
        { Assert-PruneDesiredSetNotEmpty @script:G1 -DesiredCount 10 } |
            Should -Not -Throw
    }

    It 'has no override parameter -- an empty-set prune is never legitimate' {
        (Get-Command Assert-PruneDesiredSetNotEmpty).Parameters.Keys |
            Should -Not -Contain 'Allow'
    }
}

Describe 'Assert-PruneRatioWithinThreshold (guard 2: sanity ratio)' {

    BeforeAll {
        $script:G2 = @{ ObjectTypeNoun = 'sensitivity label' }
    }

    It 'defaults the threshold to 50 percent' {
        (Get-Command Assert-PruneRatioWithinThreshold).Parameters['MaxPruneRatio'].Attributes |
            Should -Not -BeNullOrEmpty
        # The default itself is asserted behaviourally by the boundary
        # cases below, which pass no -MaxPruneRatio.
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 5 -LiveCount 10 } |
            Should -Not -Throw
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 6 -LiveCount 10 } |
            Should -Throw
    }

    It 'passes below the threshold (4 of 14 live -- the intended dev prune)' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 4 -LiveCount 14 } |
            Should -Not -Throw
    }

    It 'passes exactly at the threshold' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 5 -LiveCount 10 } |
            Should -Not -Throw
    }

    It 'throws above the threshold' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 9 -LiveCount 10 } |
            Should -Throw
    }

    It 'throws on the whole-taxonomy case that guard 1 would not see (14 of 14)' {
        # A non-empty desired set whose entries all fail to match still
        # yields a total prune. Guard 1 passes; guard 2 must not.
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 14 -LiveCount 14 } |
            Should -Throw
    }

    It 'names the counts, the percentage, and the override in the refusal message' {
        $err = $null
        try { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 9 -LiveCount 10 }
        catch { $err = $_.Exception.Message }

        $err | Should -Match '9 of 10'
        $err | Should -Match '90'
        $err | Should -Match '-AllowMajorityPrune'
    }

    It 'permits an over-threshold prune when the override is supplied' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 14 -LiveCount 14 -Allow -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'still warns when the override permits an over-threshold prune' {
        $warnings = @()
        Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 14 -LiveCount 14 -Allow `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -BeGreaterThan 0
        [string]$warnings[0] | Should -Match 'proceeding'
    }

    It 'honours a caller-supplied threshold' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 3 -LiveCount 10 -MaxPruneRatio 0.2 } |
            Should -Throw
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 8 -LiveCount 10 -MaxPruneRatio 0.9 } |
            Should -Not -Throw
    }

    It 'passes trivially when nothing is live (ratio undefined, no hazard)' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 0 -LiveCount 0 } |
            Should -Not -Throw
    }

    It 'passes trivially when nothing is being pruned' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 0 -LiveCount 14 } |
            Should -Not -Throw
    }

    It 'rejects a zero threshold, which would refuse every prune' {
        { Assert-PruneRatioWithinThreshold @script:G2 -PruneCount 1 -LiveCount 10 -MaxPruneRatio 0 } |
            Should -Throw
    }
}

Describe 'Write-PruneFailure (ErrorActionPreference-safe reporter)' {

    It 'does not terminate the caller under $ErrorActionPreference = Stop' {
        # This is the GitHub Actions condition: `shell: pwsh` sets
        # $ErrorActionPreference='stop', which promoted the loop's first
        # Write-Error into a terminating error and abandoned the
        # remaining orphans (run 29694478494).
        $reached = [pscustomobject]@{ Value = $false }
        {
            $ErrorActionPreference = 'Stop'
            Write-PruneFailure -Message 'orphan 1 failed' -WarningAction SilentlyContinue 6>$null
            $reached.Value = $true
        } | Should -Not -Throw
        $reached.Value | Should -BeTrue
    }

    It 'attempts every item in a loop under $ErrorActionPreference = Stop' {
        $attempted = [System.Collections.Generic.List[string]]::new()
        $ErrorActionPreference = 'Stop'
        foreach ($name in @('a', 'b', 'c')) {
            $attempted.Add($name)
            Write-PruneFailure -Message "Remove failed for '$name'" -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        }
        $attempted | Should -Be @('a', 'b', 'c')
    }

    It 'writes the message to the warning stream' {
        $warnings = @()
        Write-PruneFailure -Message 'orphan X failed' `
            -WarningVariable warnings -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        [string]$warnings[0] | Should -Be 'orphan X failed'
    }

    It 'emits a ::error:: workflow command on the information stream' {
        $info = Write-PruneFailure -Message 'orphan Y failed' -WarningAction SilentlyContinue 6>&1
        ($info | ForEach-Object { [string]$_ }) -join "`n" | Should -Match '::error::orphan Y failed'
    }

    It 'does not use Write-Host (PSAvoidUsingWriteHost is Warning-severity and CI runs -EnableExit)' {
        $moduleSource = Get-Content -LiteralPath $script:ModulePath -Raw
        $moduleSource | Should -Not -Match '(?m)^\s*Write-Host'
    }

    It 'does not use Write-Error, which is what defeats the loop' {
        $moduleSource = Get-Content -LiteralPath $script:ModulePath -Raw
        $moduleSource | Should -Not -Match '(?m)^\s*Write-Error'
    }
}

Describe 'Deploy-Labels.ps1 consumes the module rather than duplicating it' {

    It 'imports PruneGuard.psm1 the same way it imports the other in-repo modules' {
        $script:LabelsSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules/PruneGuard\.psm1'\)"
    }

    It 'calls the empty-desired-set guard' {
        $script:LabelsSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }

    It 'calls the sanity-ratio guard' {
        $script:LabelsSource | Should -Match 'Assert-PruneRatioWithinThreshold'
    }

    It 'calls the shared failure reporter' {
        $script:LabelsSource | Should -Match 'Write-PruneFailure'
    }

    It 'no longer carries the inline $reportPruneFailure scriptblock' {
        $script:LabelsSource | Should -Not -Match '\$reportPruneFailure'
    }

    It 'surfaces the ratio override as a script parameter' {
        $script:LabelsSource | Should -Match '\[switch\]\$AllowMajorityPrune'
    }

    It 'keeps the sanity-ratio guard ahead of the ADR 0052 confirmation gate' {
        # Guard 2 must refuse before anything is written, and before the
        # gate that CI suppresses with -Confirm:$false.
        $ratioIdx = $script:LabelsSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:LabelsSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }

    It 'keeps the empty-desired-set guard ahead of the tenant connection' {
        # Anchor on the first Connect-IPPSSession INVOCATION (a line whose
        # continuation backtick starts the splat), not on the many prose
        # mentions of the cmdlet in the comment-based help above it.
        $guardIdx = $script:LabelsSource.IndexOf('Assert-PruneDesiredSetNotEmpty')
        $connect  = [regex]::Match($script:LabelsSource, '(?m)^\s+Connect-IPPSSession\s+`')
        $guardIdx | Should -BeGreaterThan 0
        $connect.Success | Should -BeTrue
        $guardIdx | Should -BeLessThan $connect.Index
    }
}
