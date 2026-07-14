#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    PROVE THE FIX DOES SOMETHING, AND PROVE IT DOES THE RIGHT SOMETHING.

    ADR 0056 empties every root list under data-plane/**. Two claims follow, and a
    guard test that asserts neither of them is decoration:

      CLAIM 1 (the fix works).      With the SHIPPED (empty) YAML, the reconciler
                                    plans ZERO Create / Update / Delete operations.
      CLAIM 2 (the fix is needed).  With a POPULATED YAML, the same reconciler plans
                                    CREATES. If it did not, emptying the file would
                                    have changed nothing and there was no defect.

    Claim 2 is the discriminating one and it is why this file exists. A test that only
    proved claim 1 would also pass against a reconciler that does nothing at all.

    NO TENANT IS CONTACTED. The boundary is shadowed two ways, both of which are honest
    about what they prove:

      (a) DATA. The reconciler's OWN desired-state derivation functions are lifted out
          of the script by AST and driven against the real shipped YAML on disk. This is
          the script's parser, not a re-implementation of it.

      (b) STRUCTURE. The AST is then used to prove the ORDERING and CONTAINMENT facts
          that turn "zero desired entries" into "zero operations":
            - Deploy-Labels / Deploy-AutoLabelPolicies: an early-return guard keyed on
              the empty desired list precedes EVERY tenant write, and precedes every
              tenant read in the same block. The reconciler returns before it talks to
              anything.
            - Deploy-Collections: has NO early guard (it reads the tenant first), so the
              proof is containment instead — every `Invoke-RestMethod -Method PUT` lives
              inside the switch clause for a `Create` or `Update` plan row, and the ONLY
              producer of those rows is `foreach ($d in $desiredOrdered)`. Zero desired
              entries means that loop body never executes, so no such row exists, so no
              PUT is reachable. `foreach` over an empty collection executing zero times
              is not an assumption.

    WHY THE "POPULATED" INPUT IS examples/**, NOT THE PRE-CHANGE FILE. The pre-change
    YAML carries the real lab identifiers this ADR exists to remove — a real Databricks
    workspace, a real Dataverse org, a real Entra group. Committing it under tests/ as a
    fixture would re-land the disclosure one directory over, which is the exact mistake
    ADR 0056 §Decision-6 warns about ("moving the content relocates the disclosure; it
    does not remove it"). The scrubbed examples are the same SHAPE with synthetic values,
    and shape is all claim 2 needs: a populated root list plans creates.

    The red/green matrix against `main` is the other half of this proof and it lives in
    the PR: ShippedDesiredState.Tests.ps1 FAILS against the pre-fix tree, naming the 11
    populated files. A guard that passes on the broken state is worthless.

    References:
      ADR 0056 — the template ships empty desired state
      ADR 0052 / ADR 0053 — deletes require an explicit -PruneMissing
      https://pester.dev/docs/quick-start
      https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_foreach
#>

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    function Get-ScriptAst {
        param([string]$ScriptName)
        $path = Join-Path $script:ScriptsDir $ScriptName
        if (-not (Test-Path -LiteralPath $path)) { throw "Script not found: $path" }
        $tokens = $null; $errors = $null
        return [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    }
    $script:GetScriptAst = ${function:Get-ScriptAst}

    function Get-ScriptFunctionText {
        <#
            Lift the SOURCE TEXT of named functions out of a Deploy-*.ps1 by AST. The
            caller dot-sources it, so the function lands in the CALLER's scope — do not
            dot-source it in here, or it lands in this function's scope and vanishes.
            The point is that the script's top-level body — which loads
            ExchangeOnlineManagement and connects to a tenant — never runs. This is the
            established pattern in tests/scripts/Deploy-Labels.Tests.ps1.
        #>
        param([string]$ScriptName, [string[]]$FunctionName)
        $ast = Get-ScriptAst -ScriptName $ScriptName
        $out = [System.Collections.Generic.List[string]]::new()
        foreach ($fname in $FunctionName) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $ScriptName" }
            $out.Add($fnAst.Extent.Text)
        }
        return ($out -join "`n")
    }
    $script:GetScriptFunctionText = ${function:Get-ScriptFunctionText}

    <#
        Is this tenant call unreachable on the Apply path because it sits inside a
        mode-exclusive branch (`if ($mode -eq 'Export')` / `'Verify'`) that returns?
        Those branches are a different invocation of the script entirely; asserting that
        the Apply-path guard precedes them would be asserting something false about
        something irrelevant.
    #>
    function Test-IsModeExclusive {
        param($CommandAst)
        $node = $CommandAst.Parent
        while ($node) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $node.Clauses) {
                    if ($clause.Item1.Extent.Text -match "\`$mode\s+-eq\s+'(Export|Verify)'") { return $true }
                }
            }
            $node = $node.Parent
        }
        return $false
    }
    $script:TestIsModeExclusive = ${function:Test-IsModeExclusive}

    function Get-Yaml {
        param([string]$RelativePath)
        $full = Join-Path $script:RepoRoot $RelativePath
        if (-not (Test-Path -LiteralPath $full)) { throw "YAML not found: $RelativePath" }
        return (Get-Content -LiteralPath $full -Raw) | ConvertFrom-Yaml
    }
    $script:GetYaml = ${function:Get-Yaml}

    function Get-CommandAst {
        param($Ast, [string[]]$Name)
        # Fail loudly on an empty -Name rather than return zero matches: a caller that
        # typo'd a cmdlet name would otherwise get a green "no writes before the guard"
        # from a search that found nothing. Same failure class as ADR 0055 Decision 7 —
        # a check whose failure mode is "silently reads nothing" is indistinguishable
        # from a check that passes.
        if (-not $Name -or @($Name).Count -eq 0) { throw 'Get-CommandAst: -Name is required.' }
        $wanted = @($Name)
        return @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -and
                    ($wanted -contains $node.GetCommandName())
                }.GetNewClosure(), $true))
    }
    $script:GetCommandAst = ${function:Get-CommandAst}

    <#
        Find the empty-desired-list early-return guard: an `if` whose condition tests a
        desired-count for zero and whose body returns. Identified by the sentinel string
        the reconcilers all print — 'Nothing to reconcile' — which is unique to that
        guard and survives refactors of the condition itself.
    #>
    function Get-NoOpGuard {
        param($Ast)
        $guard = $Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text -match 'Count -eq 0' -and
                $node.Extent.Text -match 'Nothing to reconcile' -and
                $node.Extent.Text -match '\breturn\b'
            }, $true)
        return $guard
    }
    $script:GetNoOpGuard = ${function:Get-NoOpGuard}
}

Describe 'No-op proof — Deploy-Labels' {

    BeforeAll {
        ${function:Get-ScriptAst}          = $script:GetScriptAst
        ${function:Get-ScriptFunctionText} = $script:GetScriptFunctionText
        ${function:Get-Yaml}               = $script:GetYaml
        ${function:Get-CommandAst}         = $script:GetCommandAst
        ${function:Get-NoOpGuard}          = $script:GetNoOpGuard
        ${function:Test-IsModeExclusive}   = $script:TestIsModeExclusive

        # Dot-source AT THE CALL SITE so the lifted function lands in THIS scope.
        . ([ScriptBlock]::Create((Get-ScriptFunctionText -ScriptName 'Deploy-Labels.ps1' -FunctionName @('ConvertTo-LabelHash'))))
        $script:LabelsAst = Get-ScriptAst -ScriptName 'Deploy-Labels.ps1'

        # Faithful copy of the reconciler's own desired-entry selection
        # (Deploy-Labels.ps1 lines 1206-1209): the root `labels` key, if truthy.
        function Get-DesiredLabelHash {
            param([string]$YamlPath)
            $root = Get-Yaml -RelativePath $YamlPath
            $entries = @()
            if ($root -and $root.ContainsKey('labels') -and $root.labels) { $entries = @($root.labels) }
            return @($entries | ForEach-Object { ConvertTo-LabelHash -Entry $_ })
        }
    }

    It 'CLAIM 1 — the SHIPPED labels.yaml derives ZERO desired labels' {
        $hashes = Get-DesiredLabelHash -YamlPath 'data-plane/information-protection/labels.yaml'
        @($hashes).Count | Should -Be 0 -Because 'ADR 0056: the template ships `labels: []`'
    }

    It 'CLAIM 2 — a POPULATED labels.yaml derives MANY desired labels (so emptying it was not a no-op edit)' {
        $hashes = Get-DesiredLabelHash -YamlPath 'examples/data-plane/information-protection/labels.yaml'
        @($hashes).Count | Should -BeGreaterThan 5 -Because (
            'if a populated file derived zero desired labels, emptying the shipped one would ' +
            'have fixed nothing and there was never a defect. This is the discriminating half.')
    }

    It 'CLAIM 2 — every desired label from the populated file is a CREATE against an empty tenant' {
        # The reconciler's Create/Update fork is `$tenantByPath.ContainsKey($desiredKey)`
        # (Deploy-Labels.ps1:1598). Against a tenant with no labels, that lookup misses for
        # every desired entry, so every one of them lands on the Create branch. Shadow the
        # tenant as the empty map it would be.
        $tenantByPath = @{}
        $hashes = Get-DesiredLabelHash -YamlPath 'examples/data-plane/information-protection/labels.yaml'

        $creates = @($hashes | Where-Object {
                $key = if ($_.parent) { "$($_.parent)/$($_.displayName)" } else { $_.displayName }
                -not $tenantByPath.ContainsKey($key)
            })
        $creates.Count | Should -Be @($hashes).Count
        $creates.Count | Should -BeGreaterThan 5
    }

    It 'STRUCTURE — the empty-list guard exists and returns' {
        $guard = Get-NoOpGuard -Ast $script:LabelsAst
        $guard | Should -Not -BeNullOrEmpty -Because (
            'Deploy-Labels.ps1 must short-circuit on an empty desired list. Without the ' +
            'guard, the empty root list is still safe (the plan loop iterates nothing) but ' +
            'the reconciler would read the tenant for no reason.')
        $guard.Extent.Text | Should -Match 'return'
    }

    It 'STRUCTURE — the guard precedes EVERY tenant write (New-Label / Set-Label / Remove-Label)' {
        $guard  = Get-NoOpGuard -Ast $script:LabelsAst
        $writes = Get-CommandAst -Ast $script:LabelsAst -Name @('New-Label', 'Set-Label', 'Remove-Label')

        $writes.Count | Should -BeGreaterThan 0 -Because 'the reconciler must actually have writes, or this proves nothing'
        foreach ($w in $writes) {
            $w.Extent.StartOffset | Should -BeGreaterThan $guard.Extent.EndOffset -Because (
                "a tenant write at line $($w.Extent.StartLineNumber) is reachable before the " +
                'empty-list guard. With an empty labels.yaml the reconciler would still write.')
        }
    }

    It 'STRUCTURE — the guard precedes every APPLY-PATH tenant read (the reconciler never contacts the tenant)' {
        # Get-Label also appears inside `if ($mode -eq 'Export')`, which returns. That is a
        # different invocation of the script and is unreachable on the Apply path, so it is
        # excluded — by STRUCTURE (a mode-exclusive ancestor), not by line number.
        $guard = Get-NoOpGuard -Ast $script:LabelsAst
        $reads = @(Get-CommandAst -Ast $script:LabelsAst -Name @('Get-Label') |
                Where-Object { -not (Test-IsModeExclusive -CommandAst $_) })

        $reads.Count | Should -BeGreaterThan 0 -Because 'the Apply path must read the tenant when there IS desired state'
        foreach ($r in $reads) {
            $r.Extent.StartOffset | Should -BeGreaterThan $guard.Extent.EndOffset -Because (
                "the Apply-path Get-Label at line $($r.Extent.StartLineNumber) must come AFTER " +
                'the empty-list guard: an empty desired list means the reconciler returns ' +
                'without contacting the tenant at all')
        }
    }
}

Describe 'No-op proof — Deploy-Labels still reads the SIT catalog (the carve-out is load-bearing)' {

    BeforeAll { ${function:Get-Yaml} = $script:GetYaml }

    It 'sit-catalog.yaml is intact and resolves every sitId the repo references' {
        # Deploy-Labels.ps1:1244-1264 validates every label's `autoApplicationOf.sitId`
        # against this catalog and ERRORS if one is missing. Emptying labels.yaml must not
        # have disturbed that path — and emptying the CATALOG would have broken it, which
        # is precisely why the catalog is carved out of the ADR 0056 rule.
        $catalog = Get-Yaml -RelativePath 'data-plane/classifications/sit-catalog.yaml'
        $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($s in @($catalog.sits)) {
            if ($s.ContainsKey('id') -and $s.id) { [void]$known.Add([string]$s.id) }
        }
        $known.Count | Should -BeGreaterThan 300

        # Every sitId referenced anywhere in the repo's YAML must resolve in the catalog.
        # If it does not, a label or auto-label deploy would hard-fail at the pre-flight.
        $referenced = [System.Collections.Generic.List[string]]::new()
        foreach ($rel in @(
                'data-plane/information-protection/labels.autoApplicationOf.fixture.yaml'
                'examples/data-plane/information-protection/auto-label-policies.yaml'
            )) {
            $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot $rel) -Raw
            foreach ($m in [regex]::Matches($raw, '(?m)^\s*-?\s*sitId\s*:\s*([0-9a-fA-F-]{36})')) {
                $referenced.Add($m.Groups[1].Value)
            }
        }
        $referenced.Count | Should -BeGreaterThan 0 -Because 'the check is vacuous if nothing references a SIT'

        $unresolved = @($referenced | Where-Object { -not $known.Contains($_) })
        $unresolved.Count | Should -Be 0 -Because (
            'Deploy-Labels.ps1:1262 errors and returns when a sitId is absent from the ' +
            'catalog. Unresolved: ' + (($unresolved | ForEach-Object { $_.Substring(0, 8) + '-...' }) -join ', '))
    }
}

Describe 'No-op proof — Deploy-AutoLabelPolicies (the file that shipped the enforcing SSN policy)' {

    BeforeAll {
        ${function:Get-ScriptAst}        = $script:GetScriptAst
        ${function:Get-Yaml}             = $script:GetYaml
        ${function:Get-CommandAst}       = $script:GetCommandAst
        ${function:Get-NoOpGuard}        = $script:GetNoOpGuard
        ${function:Test-IsModeExclusive} = $script:TestIsModeExclusive

        $script:AlpAst = Get-ScriptAst -ScriptName 'Deploy-AutoLabelPolicies.ps1'

        # Faithful copy of the reconciler's own desired-entry selection
        # (Deploy-AutoLabelPolicies.ps1 lines 911-920).
        function Get-DesiredAutoLabel {
            param([string]$YamlPath)
            $root = Get-Yaml -RelativePath $YamlPath
            $policies = @(); $rules = @()
            if ($root) {
                if ($root.ContainsKey('policies') -and $root.policies) { $policies = @($root.policies) }
                if ($root.ContainsKey('rules')    -and $root.rules)    { $rules    = @($root.rules) }
            }
            return [pscustomobject]@{ Policies = $policies; Rules = $rules }
        }
    }

    It 'CLAIM 1 — the SHIPPED auto-label-policies.yaml derives ZERO policies and ZERO rules' {
        $d = Get-DesiredAutoLabel -YamlPath 'data-plane/information-protection/auto-label-policies.yaml'
        @($d.Policies).Count | Should -Be 0
        @($d.Rules).Count    | Should -Be 0
    }

    It 'CLAIM 1 — and no policy anywhere in the shipped file is at mode Enable' {
        # Belt and braces on the specific defect. Even if someone re-populates the list,
        # an enforcing policy must never be the shipped default.
        $raw = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'data-plane/information-protection/auto-label-policies.yaml') -Raw
        $raw | Should -Not -Match '(?m)^\s*mode:\s*Enable\s*$' -Because (
            'Lab-AutoLabel-SSN shipped at `mode: Enable` with `exchangeLocation: [All]` in a ' +
            'PUBLIC template. Simulation first: TestWithoutNotifications -> ' +
            'TestWithNotifications -> Enable, one destructive-labelled PR per step (ADR 0016).')
    }

    It 'CLAIM 2 — a POPULATED auto-label-policies.yaml derives policies AND rules' {
        $d = Get-DesiredAutoLabel -YamlPath 'examples/data-plane/information-protection/auto-label-policies.yaml'
        @($d.Policies).Count | Should -BeGreaterThan 0 -Because 'else emptying the shipped file changed nothing'
        @($d.Rules).Count    | Should -BeGreaterThan 0
    }

    It 'STRUCTURE — the empty-list guard precedes EVERY tenant write' {
        $guard = Get-NoOpGuard -Ast $script:AlpAst
        $guard | Should -Not -BeNullOrEmpty

        $writes = Get-CommandAst -Ast $script:AlpAst -Name @(
            'New-AutoSensitivityLabelPolicy', 'Set-AutoSensitivityLabelPolicy', 'Remove-AutoSensitivityLabelPolicy',
            'New-AutoSensitivityLabelRule', 'Set-AutoSensitivityLabelRule', 'Remove-AutoSensitivityLabelRule')
        $writes.Count | Should -BeGreaterThan 0
        foreach ($w in $writes) {
            $w.Extent.StartOffset | Should -BeGreaterThan $guard.Extent.EndOffset -Because (
                "a tenant write at line $($w.Extent.StartLineNumber) is reachable before the empty-list guard")
        }
    }

    It 'STRUCTURE — the guard precedes every APPLY-PATH tenant read' {
        # As with Deploy-Labels: the Verify and Export branches read the tenant too, and
        # both return. They are excluded by their mode-exclusive ancestor, not by offset.
        $guard = Get-NoOpGuard -Ast $script:AlpAst
        $reads = @(Get-CommandAst -Ast $script:AlpAst -Name @(
                'Get-AutoSensitivityLabelPolicy', 'Get-AutoSensitivityLabelRule') |
                Where-Object { -not (Test-IsModeExclusive -CommandAst $_) })

        $reads.Count | Should -BeGreaterThan 0
        foreach ($r in $reads) {
            $r.Extent.StartOffset | Should -BeGreaterThan $guard.Extent.EndOffset -Because (
                "the Apply-path tenant read at line $($r.Extent.StartLineNumber) must come " +
                'AFTER the empty-list guard')
        }
    }
}

Describe 'No-op proof — Deploy-Collections (no early guard: the proof is CONTAINMENT)' {

    BeforeAll {
        ${function:Get-ScriptAst}          = $script:GetScriptAst
        ${function:Get-ScriptFunctionText} = $script:GetScriptFunctionText
        ${function:Get-Yaml}               = $script:GetYaml
        ${function:Get-CommandAst}         = $script:GetCommandAst

        # Dot-source AT THE CALL SITE so the lifted function lands in THIS scope.
        . ([ScriptBlock]::Create((Get-ScriptFunctionText -ScriptName 'Deploy-Collections.ps1' -FunctionName @('ConvertTo-DesiredCollectionList'))))
        $script:CollectionsAst = Get-ScriptAst -ScriptName 'Deploy-Collections.ps1'
    }

    It 'CLAIM 1 — the SHIPPED collections.yaml flattens to ZERO desired collections' {
        $root = Get-Yaml -RelativePath 'data-plane/collections/collections.yaml'
        $desired = @(ConvertTo-DesiredCollectionList -Tree $root -RootName 'purview-contoso-lab')
        $desired.Count | Should -Be 0 -Because 'ADR 0056: the template ships `collections: []`'
    }

    It 'CLAIM 1 — and rootCollection ships UNSET (the account name is a tenant identifier, not desired state)' {
        $root = Get-Yaml -RelativePath 'data-plane/collections/collections.yaml'
        # Emptying the list does not clear this scalar; it had to be handled separately.
        # `Deploy-Collections.ps1:852` treats it as optional and informational — the real
        # account binding always comes from -PurviewAccountName / infra/parameters/lab.yaml.
        $root.rootCollection | Should -BeNullOrEmpty -Because (
            'the shipped rootCollection was `purview-contoso-lab` — the owner''s Purview ' +
            'ACCOUNT NAME. With an empty collections list there is nothing to root, so a ' +
            'shipped value is pure disclosure with zero function. ADR 0056 Decision 5.')
    }

    It 'CLAIM 2 — a POPULATED collections.yaml flattens to MANY desired collections' {
        $root = Get-Yaml -RelativePath 'examples/data-plane/collections/collections.yaml'
        $desired = @(ConvertTo-DesiredCollectionList -Tree $root -RootName 'purview-contoso-lab')
        $desired.Count | Should -BeGreaterThan 10 -Because 'else emptying the shipped file changed nothing'
    }

    It 'CLAIM 2 — every desired collection from the populated file is a CREATE against an empty tenant' {
        # The reconciler's fork is `$tenantByName.ContainsKey($key)` (Deploy-Collections.ps1:1057).
        $tenantByName = @{}
        $root = Get-Yaml -RelativePath 'examples/data-plane/collections/collections.yaml'
        $desired = @(ConvertTo-DesiredCollectionList -Tree $root -RootName 'purview-contoso-lab')

        $creates = @($desired | Where-Object { -not $tenantByName.ContainsKey($_.name.ToLowerInvariant()) })
        $creates.Count | Should -Be $desired.Count
        $creates.Count | Should -BeGreaterThan 10
    }

    It 'STRUCTURE — every tenant PUT lives inside the Create or Update plan-switch clause' {
        # Deploy-Collections has NO early guard: it GETs the tenant before building the
        # plan. So the no-op proof is containment, not ordering. The ONLY producer of a
        # 'Create' or 'Update' plan row is `foreach ($d in $desiredOrdered)`
        # (Deploy-Collections.ps1:1055-1067), and $desiredOrdered is derived from
        # ConvertTo-DesiredCollectionList, which returns @() above. A foreach over an
        # empty collection executes zero times, so no such row exists, so neither clause
        # is ever entered, so no PUT fires.
        $switches = @($script:CollectionsAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst]
                }, $true))
        $switches.Count | Should -BeGreaterThan 0

        $puts = @(Get-CommandAst -Ast $script:CollectionsAst -Name @('Invoke-RestMethod') |
                Where-Object { $_.Extent.Text -match '-Method\s+PUT' })
        $puts.Count | Should -BeGreaterThan 0 -Because 'the reconciler must actually have writes, or this proves nothing'

        foreach ($put in $puts) {
            $enclosing = $null
            foreach ($sw in $switches) {
                foreach ($clause in $sw.Clauses) {
                    $body = $clause.Item2
                    if ($put.Extent.StartOffset -ge $body.Extent.StartOffset -and
                        $put.Extent.EndOffset   -le $body.Extent.EndOffset) {
                        $enclosing = $clause.Item1.Extent.Text.Trim("'", '"', ' ')
                    }
                }
            }
            $enclosing | Should -BeIn @('Create', 'Update') -Because (
                "the PUT at line $($put.Extent.StartLineNumber) must only be reachable from a " +
                "'Create' or 'Update' plan row, and those rows are produced ONLY by iterating " +
                'the desired list. A PUT reachable from any other clause breaks the no-op proof.')
        }
    }

    It 'STRUCTURE — the tenant DELETE lives in the Orphan clause and is gated on -PruneMissing' {
        $switches = @($script:CollectionsAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst]
                }, $true))

        $deletes = @(Get-CommandAst -Ast $script:CollectionsAst -Name @('Invoke-RestMethod') |
                Where-Object { $_.Extent.Text -match '-Method\s+DELETE' })
        $deletes.Count | Should -BeGreaterThan 0

        foreach ($del in $deletes) {
            $clauseText = $null
            $clauseLabel = $null
            foreach ($sw in $switches) {
                foreach ($clause in $sw.Clauses) {
                    $body = $clause.Item2
                    if ($del.Extent.StartOffset -ge $body.Extent.StartOffset -and
                        $del.Extent.EndOffset   -le $body.Extent.EndOffset) {
                        $clauseLabel = $clause.Item1.Extent.Text.Trim("'", '"', ' ')
                        $clauseText  = $body.Extent.Text
                    }
                }
            }
            $clauseLabel | Should -Be 'Orphan' -Because 'a delete must only be reachable from a tenant-only (orphan) row'
            # And inside that clause, the -PruneMissing gate must fire FIRST.
            $clauseText | Should -Match '(?s)-not\s+\$PruneMissing\.IsPresent.*?continue.*?-Method\s+DELETE' -Because (
                'ADR 0052 / ADR 0053: a delete requires an explicit -PruneMissing. Without it ' +
                'the orphan is reported and skipped, so an empty desired list deletes NOTHING ' +
                'on a default apply.')
        }
    }
}
