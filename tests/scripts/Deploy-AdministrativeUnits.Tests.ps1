#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-AdministrativeUnits.ps1.

.DESCRIPTION
    Locks in the Wave 0 / v2 §5.1 reconciler contract for the Microsoft
    Entra administrative-units (AU) data-plane reconciler ratified by
    docs/adr/0002-administrative-units.md:

      1. CmdletBinding declares SupportsShouldProcess with
         ConfirmImpact = 'High' so -WhatIf is honored end-to-end AND the
         ADR 0052 destructive-confirmation gate can actually prompt.
      2. The drift-report contract from
         .github/instructions/powershell.instructions.md is implemented
         with the five canonical categories: Create, Update, NoChange,
         Orphan, Conflict.
      3. -PruneMissing and -Force switches exist and are off by default
         (no destructive action without an explicit opt-in).
      4. The script targets the Microsoft Graph v1.0 administrativeUnits
         surface, not a Purview-account endpoint (per ADR 0002 #1).
      5. Comment-based help cites Microsoft Learn for every Graph verb
         the script invokes.
      6. The default -Path resolves to the in-repo desired-state YAML.

    Pattern: AST-parse the script and assert structural properties.
    The script's reconcile logic lives at script scope (no extractable
    helper functions) and the two helpers it does define (Get-GraphToken,
    Get-SignedInPrincipalId) shell out to `az` -- both would fail in a
    unit-test sandbox. We therefore do not dot-source the script and do
    not invoke its functions. Per tests/README.md "No script execution".

    Reference: https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit
    Reference: https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits
    Reference: https://learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits
    Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-update
    Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete
    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-AdministrativeUnits.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-AdministrativeUnits.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
}

Describe 'Deploy-AdministrativeUnits.ps1 — CmdletBinding contract' {

    It 'declares [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = ''High'')]' {
        $paramBlock = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.ParamBlockAst]
            }, $true)
        $paramBlock | Should -Not -BeNullOrEmpty

        $cmdletBinding = $paramBlock.Attributes |
            Where-Object { $_.TypeName.FullName -eq 'CmdletBinding' } |
            Select-Object -First 1
        $cmdletBinding | Should -Not -BeNullOrEmpty -Because 'the script must declare CmdletBinding'

        $cbArgs = @{}
        foreach ($named in $cmdletBinding.NamedArguments) {
            $cbArgs[$named.ArgumentName] = $named.Argument.Extent.Text
        }
        $cbArgs.Keys | Should -Contain 'SupportsShouldProcess' -Because '-WhatIf must be honored end-to-end'
        $cbArgs['SupportsShouldProcess'] | Should -Match '\$true'
        $cbArgs.Keys | Should -Contain 'ConfirmImpact'
        # 'High', NOT 'Medium'. This assertion previously pinned 'Medium' --
        # it was pinning the issue #85 DEFECT. PowerShell raises a
        # ShouldProcess confirmation only when ConfirmImpact >=
        # $ConfirmPreference, and $ConfirmPreference defaults to 'High', so at
        # 'Medium' every ShouldProcess call returned $true WITHOUT PROMPTING
        # and the mandated confirmation was dead code. Raised by issue #83
        # (ADR 0052 rollout). Case-sensitive so a lowercase 'high' cannot pass.
        # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
        $cbArgs['ConfirmImpact'] | Should -CMatch "'High'" `
            -Because 'ConfirmImpact = Medium is the issue #85 defect: it silently disables every confirmation prompt in the script'
    }
}

Describe 'Deploy-AdministrativeUnits.ps1 — parameter surface' {

    BeforeAll {
        $script:ParamBlock = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.ParamBlockAst]
            }, $true)
        $script:ParamNames = $script:ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath }
    }

    It 'exposes -Path with a non-null default' {
        $script:ParamNames | Should -Contain 'Path'
        $pathParam = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Path' } |
            Select-Object -First 1
        $pathParam.DefaultValue | Should -Not -BeNullOrEmpty
        # Default must point at the in-repo YAML location.
        $pathParam.DefaultValue.Extent.Text |
            Should -Match 'administrative-units[\\/]administrative-units\.yaml'
    }

    It 'exposes -PruneMissing as a [switch] (default $false)' {
        $script:ParamNames | Should -Contain 'PruneMissing'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'PruneMissing' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }

    It 'exposes -Force as a [switch] (default $false)' {
        $script:ParamNames | Should -Contain 'Force'
        $p = $script:ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'Force' } |
            Select-Object -First 1
        $p.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }
}

Describe 'Deploy-AdministrativeUnits.ps1 — drift-report categories' {

    It 'emits each of the five canonical categories as a string literal' {
        $stringLiterals = $script:Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value }

        foreach ($category in @('Create', 'Update', 'NoChange', 'Orphan', 'Conflict')) {
            $stringLiterals |
                Should -Contain $category -Because "drift category '$category' is part of the contract in .github/instructions/powershell.instructions.md"
        }
    }

    It 'guards orphan deletion behind -PruneMissing' {
        $script:ScriptText | Should -Match '-not \$PruneMissing'
    }

    It 'guards conflict overwrite behind -Force' {
        $script:ScriptText | Should -Match '-not \$Force'
    }
}

Describe 'Deploy-AdministrativeUnits.ps1 — Microsoft Graph surface' {

    It 'targets the v1.0 administrativeUnits endpoint (not a Purview-account URL)' {
        $script:ScriptText | Should -Match 'graph\.microsoft\.com/v1\.0'
        $script:ScriptText | Should -Match 'directory/administrativeUnits'
        $script:ScriptText | Should -Not -Match 'purview\.azure\.com'
    }

    It 'invokes GET, POST, PATCH, and DELETE against Invoke-RestMethod' {
        foreach ($verb in @('Get', 'Post', 'Patch', 'Delete')) {
            $script:ScriptText |
                Should -Match ("Invoke-RestMethod\s+-Method\s+{0}\b" -f $verb)
        }
    }

    It 'acquires its access token against the Microsoft Graph resource' {
        $script:ScriptText | Should -Match 'az account get-access-token --resource ''https://graph\.microsoft\.com'''
    }
}

Describe 'Deploy-AdministrativeUnits.ps1 — Microsoft Learn citations' {

    It 'cites the Graph administrativeUnit resource type' {
        $script:ScriptText |
            Should -Match 'learn\.microsoft\.com/en-us/graph/api/resources/administrativeunit'
    }

    It 'cites every Graph verb the script invokes' {
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/directory-list-administrativeunits'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/directory-post-administrativeunits'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/administrativeunit-update'
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/graph/api/administrativeunit-delete'
    }

    It 'cites ADR 0002 (the ratifying decision)' {
        $script:ScriptText | Should -Match 'docs/adr/0002-administrative-units\.md'
    }
}


# ---------------------------------------------------------------------------
# ADR 0053 -- Deploy-AdministrativeUnits.ps1 is the counter-example that makes
# the rule legible.
#
# Its .PARAMETER Force block used to promise "Overwrite AUs whose
# `lastModifiedBy` is not the current principal" -- a capability it does not and
# cannot implement: Microsoft Graph exposes no per-administrative-unit
# authorship field, nothing in the script ever emits a Conflict row, and the
# 'Conflict' apply case is therefore unreachable.
#
# ADR 0053 does NOT give this script -OverwriteForeignAuthor. It only makes the
# help honest. These tests pin both halves.
#
# Reference: docs/adr/0053-overwrite-foreign-author-switch.md
# ---------------------------------------------------------------------------
Describe 'ADR 0053 -- Deploy-AdministrativeUnits.ps1 documents no capability it lacks' {

    BeforeAll {
        $script:Adr0053AuPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-AdministrativeUnits.ps1'
        $script:Adr0053AuSource = Get-Content -Path $script:Adr0053AuPath -Raw
    }

    It 'no longer promises the foreign-author overwrite in its .PARAMETER Force help' {
        $script:Adr0053AuSource |
            Should -Not -Match 'Overwrite AUs whose .lastModifiedBy. is not the current principal'
    }

    It 'states explicitly that -Force does NOT carry the authorship meaning' {
        $script:Adr0053AuSource | Should -Match 'does NOT mean'
        $script:Adr0053AuSource | Should -Match 'docs/adr/0053-overwrite-foreign-author-switch\.md'
    }

    It 'does NOT acquire -OverwriteForeignAuthor (Graph exposes no per-AU authorship to diff)' {
        # Guards the other direction: the switch must land on exactly the six
        # Atlas/REST reconcilers, not be sprayed across every Deploy-*.ps1.
        $cmd = Get-Command -Name $script:Adr0053AuPath -CommandType ExternalScript
        $cmd.Parameters.Keys | Should -Not -Contain 'OverwriteForeignAuthor'
    }
}

# ---------------------------------------------------------------------------
# Issue #13, part C batch 3: guard 2 (prune sanity ratio) and the failure
# reporter. This script's apply phase is a mixed Create/Update/Delete switch
# that had NO try/catch: under $ErrorActionPreference = 'Stop', the first
# failed orphan delete terminated the run and the remaining orphans were
# never attempted. The regions below are lifted from the REAL script source
# (not transcribed) and executed against stubs, so the tests cannot keep
# passing after the script regresses.
# ---------------------------------------------------------------------------
Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 3)' {

    BeforeAll {
        $script:AuSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:AuSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:AuSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the administrative-unit noun' {
        $script:AuSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:AuSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'administrative unit'"))
    }
    It 'keys guard 2 on the live tenant AU count' {
        $script:AuSource | Should -Match ([regex]::Escape('@($current).Count'))
    }
    It 'surfaces the ratio override and threshold parameters' {
        $script:AuSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:AuSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:AuSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:AuSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Prune sanity-ratio guard executed through the script wiring (issue #13, batch 3)' {

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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-AdministrativeUnits.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow)
            $PruneMissing = [switch]$true
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $orphans = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Category = 'Orphan'; Name = "orphan-$i" } })
            $current = @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ displayName = "live-$i"; id = "live-$i" } })
            $null = $PruneMissing, $MaxPruneRatio, $AllowMajorityPrune, $orphans, $current
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'honours a caller-supplied -MaxPruneRatio' { { Invoke-Guard2 -Prune 6 -Live 10 -Max 0.7 } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 3)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-AdministrativeUnits.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-AdministrativeUnits.ps1; update the anchor in this test.' }
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
            # Stub shadows the real cmdlet inside the lifted region. Deletes are
            # identified by the trailing URI segment, which the harness sets to
            # the AU's display name (id == displayName in the stub tenant).
            function Invoke-RestMethod {
                param($Method, $Uri, $Headers, $Body)
                $null = $Headers, $Body
                if ($Method -ne 'Delete') { throw "Unexpected non-Delete call in orphan-only run: $Method $Uri" }
                $name = ($Uri -split '/')[-1]
                $attempted.Add($name)
                if ($Fail -contains $name) { throw "TenantBlockerException: $name" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $graphBase = 'https://graph.unit.test/v1.0'
            $headers = @{}
            $desired = @()
            $current = @($Names | ForEach-Object { [pscustomobject]@{ displayName = $_; id = $_ } })
            $report = @($Names | ForEach-Object { [pscustomobject]@{ Category = 'Orphan'; Kind = 'AdministrativeUnit'; Name = $_; Reason = 'test' } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $graphBase, $headers, $desired, $current, $report, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every orphan after a failure (no first-failure abort)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('a')
        $r.Attempted | Should -Be @('a', 'b', 'c')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -Names @('a', 'b') -Fail @('b')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException: b'
    }
    It 'throws one aggregate naming every failure (non-zero exit preserved)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('a', 'c')
        $r.Thrown | Should -Match 'a, c'
        $r.Thrown | Should -Match '2 orphan administrative unit'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -Names @('a', 'b')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the delete behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries try/catch, the reporter, and the aggregate throw in the lifted region (mutation check vs pre-batch first-failure abort)' {
        # Non-vacuous: the lift anchors on the $pruneFailures declaration,
        # which the pre-change file lacked entirely (no try/catch around the
        # delete, no collection, no aggregate throw).
        $script:ReporterRegion | Should -Match 'try \{'
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}
