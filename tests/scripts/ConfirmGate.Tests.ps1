#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the ADR 0052 destructive-operation confirmation
    gate: scripts/modules/ConfirmGate.psm1 and its three reference
    consumers.

.DESCRIPTION
    Locks in the fix for issue #85. The defect being regression-tested:

      Every Deploy-*.ps1 declared ConfirmImpact = 'Medium'. PowerShell only
      raises a ShouldProcess confirmation when ConfirmImpact >=
      $ConfirmPreference, and $ConfirmPreference defaults to 'High'. Because
      Medium < High, EVERY $PSCmdlet.ShouldProcess(...) call returned $true
      without ever prompting. The mandated delete-confirmation prompt was
      dead code.

    The fix is a change of METHOD, not merely of constant: the destructive
    branches are gated with ShouldContinue (which performs no
    ConfirmImpact / $ConfirmPreference comparison and therefore prompts
    unconditionally) rather than ShouldProcess. The most important test in
    this file is 'ignores $ConfirmPreference entirely' -- if that ever goes
    red, the defect is back.

    Pattern (matches tests/scripts/Deploy-FilePlan.Tests.ps1):

      1. Behaviour tests against the shared scripts/modules/ConfirmGate.psm1
         module directly, driving it with a stub $Cmdlet that records
         ShouldContinue calls. We do NOT dot-source the consumer scripts --
         that would execute their top-level code and try to
         Connect-IPPSSession against the live tenant.
      2. Source-text regex assertions on the three reference consumers
         (ConfirmImpact level, module import, gate invocation).
      3. A DERIVED workflow scan: the gated set comes from the AST, every
         run: block in every .github/workflows/*.yml is parsed as PowerShell,
         and every invocation of every gated script -- including the
         drift-detection glob loop, which dispatches all twenty via
         `& $script.FullName` -- must bind -Confirm:$false or -WhatIf, so
         raising ConfirmImpact to 'High' cannot hang a job. -Force is NOT
         accepted: it silences the gate but not ShouldProcess.

    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    Reference: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.cmdlet.shouldcontinue
#>

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'

    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'modules' 'ConfirmGate.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate ConfirmGate.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Stub $PSCmdlet. Records every ShouldContinue call and returns a canned
    # answer, so the prompt-emission path is testable under a non-interactive
    # Pester run (a real PSCmdlet cannot raise a prompt there).
    #   -Answer      : what ShouldContinue returns.
    #   -SetYesToAll : simulate the operator choosing "Yes to All".
    #   -SetNoToAll  : simulate the operator choosing "No to All".
    function Get-StubCmdlet {
        param(
            [bool]$Answer = $true,
            [switch]$SetYesToAll,
            [switch]$SetNoToAll
        )
        $stub = [pscustomobject]@{
            Calls       = [System.Collections.Generic.List[object]]::new()
            Answer      = $Answer
            SetYesToAll = [bool]$SetYesToAll
            SetNoToAll  = [bool]$SetNoToAll
        }
        # Signature mirrors the four-argument overload:
        #   bool ShouldContinue(string query, string caption, ref bool yesToAll, ref bool noToAll)
        $stub | Add-Member -MemberType ScriptMethod -Name 'ShouldContinue' -Value {
            param($query, $caption, [ref]$yesToAll, [ref]$noToAll)
            $this.Calls.Add([pscustomobject]@{ Query = $query; Caption = $caption })
            if ($this.SetYesToAll) { $yesToAll.Value = $true }
            if ($this.SetNoToAll) { $noToAll.Value = $true }
            return $this.Answer
        }
        return $stub
    }

    # ---------------------------------------------------------------------
    # AST helpers for the reference-implementation contract.
    #
    # These exist because SOURCE-TEXT ASSERTIONS ON THESE SCRIPTS ARE VACUOUS.
    # The scripts' comments deliberately quote the anti-patterns they forbid
    # ("KEY THE GATE ON THE PLAN, NOT ON THE POLICY", "ConfirmGate.psm1",
    # "if ($DirectionPolicy -eq 'repo-wins' -and ...)"), so a regex over the
    # file cannot distinguish the rule from a violation of it, nor an import
    # from a mention of one. Prose cannot forge an AST node; that is the point.
    # ---------------------------------------------------------------------

    function Get-ScriptAstOrThrow {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            throw ("Parse errors in {0}:`n{1}" -f $Path, (($errors | ForEach-Object { $_.Message }) -join "`n"))
        }
        return $ast
    }

    # The ConfirmImpact the RUNTIME sees: the named argument on the real
    # [CmdletBinding()] attribute, not a mention of it in a comment.
    function Get-ConfirmImpact {
        param([Parameter(Mandatory)]$Ast)
        $binding = $Ast.ParamBlock.Attributes |
            Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        if (-not $binding) { return $null }
        $named = $binding.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' } | Select-Object -First 1
        if (-not $named) { return $null }
        return [string]$named.Argument.Value
    }

    # Real invocations of the gate, as commands. A comment naming the function
    # is not a CommandAst; neither is a string literal containing its name.
    function Get-GateCallAst {
        param([Parameter(Mandatory)]$Ast)
        @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Assert-DestructiveOperationConfirmed'
                }, $true))
    }

    # A real `Import-Module ... ConfirmGate.psm1`. The path is matched against
    # the extents of the command's own ELEMENTS, which are expression nodes --
    # a comment can never be inside one.
    function Get-ConfirmGateImportAst {
        param([Parameter(Mandatory)]$Ast)
        @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Import-Module'
                }, $true) | Where-Object {
                @($_.CommandElements | Where-Object { $_.Extent.Text -match 'ConfirmGate\.psm1' }).Count -gt 0
            })
    }

    # The variable name bound to the gate's -Query parameter, e.g. 'overwriteQuery'.
    function Get-BoundQueryVariableName {
        param([Parameter(Mandatory)]$GateCall)
        $elements = @($GateCall.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -eq 'Query') {
                # `-Query $overwriteQuery` -- the argument is either attached to
                # the parameter node or is the next element.
                $arg = if ($null -ne $el.Argument) { $el.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
                if ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    return [string]$arg.VariablePath.UserPath
                }
                return $null
            }
        }
        return $null
    }

    # Walk from a gate call up to the `if` whose CONDITION it sits in -- that is
    # the `if (-not (Assert-DestructiveOperationConfirmed ...))` decline branch --
    # and return the throw statements in that if's BODY. Proves the decline
    # ABORTS rather than falling through into a half-applied state, and proves it
    # against the WIRING, not against a `throw '...'` literal sitting anywhere in
    # the file.
    function Get-GateDeclineThrow {
        param([Parameter(Mandatory)]$GateCall)
        $node = $GateCall
        while ($null -ne $node.Parent) {
            $parent = $node.Parent
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $parent.Clauses) {
                    $inCondition = @($clause.Item1.FindAll({
                                param($n) [object]::ReferenceEquals($n, $GateCall)
                            }, $true)).Count -gt 0
                    if ($inCondition) {
                        return @($clause.Item2.FindAll({
                                    param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
                                }, $true))
                    }
                }
            }
            $node = $parent
        }
        return @()
    }

    # THE V4 GUARD, and the one PR-B leans on.
    #
    # For every real gate call, walk up through EVERY `if` that guards it -- at
    # any nesting depth, entered via the BODY -- and flag any whose condition
    # mentions the $DirectionPolicy variable at all.
    #
    # Structural, so it admits no spelling. Reordered operands, double quotes,
    # `-ne 'portal-wins'` instead of `-eq 'repo-wins'`, or hiding the policy test
    # in an outer `if` are all caught identically: a VariableExpressionAst named
    # DirectionPolicy anywhere in a gate-guarding condition is the finding.
    #
    # Returns the offending condition texts (empty array = compliant).
    function Get-PolicyKeyedGuard {
        param([Parameter(Mandatory)]$Ast)
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($gate in (Get-GateCallAst -Ast $Ast)) {
            $node = $gate
            while ($null -ne $node.Parent) {
                $parent = $node.Parent
                if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $parent.Clauses) {
                        # Only conditions guarding the BODY the gate lives in.
                        # The `if (-not (gate))` decline branch holds the gate in
                        # its CONDITION, not its body, and is correctly ignored.
                        if (-not [object]::ReferenceEquals($clause.Item2, $node)) { continue }
                        # Scope-stripped (Get-AstVariableName), so a `$script:DirectionPolicy`
                        # or `$local:DirectionPolicy` spelling cannot slip past a UserPath
                        # equality test. See the Get-AstVariableName note in the B2 helpers.
                        if (Test-AstNamesVariable -Ast $clause.Item1 -Name 'DirectionPolicy') {
                            $offenders.Add(($clause.Item1.Extent.Text -replace '\s+', ' '))
                        }
                    }
                }
                $node = $parent
            }
        }
        @($offenders | Select-Object -Unique)
    }

    # How many destructive branches each reconciler has -- therefore how many
    # gate calls it MUST wire. This is the class map from #83, made executable.
    #
    #   Class A (2) -- prune-delete AND repo-wins overwrite.
    #   Class B (1) -- prune-delete only; declares no -DirectionPolicy at all.
    #   Class C (0) -- does not exist. Every one of the 21 reconcilers can
    #                  delete or revoke tenant state.
    #
    # WHY A TABLE AND NOT `Should -BeGreaterThan 0`. All four scripts gated in
    # PR-A are Class A, so a flat `Should -Be 2` is correct today -- and it is a
    # LANDMINE for PR-B. The moment PR-B adds a Class B script to the -ForEach
    # list, `Should -Be 2` false-fails, and the obvious "fix" is to relax it to
    # `-BeGreaterThan 0`. That relaxation re-opens the exact hole this assertion
    # closes: a Class A script silently shipping only ONE of its two gates would
    # sail through. Defusing it now, before PR-B has a reason to reach for the
    # relaxation.
    #
    # PR-B: add the script to $script:GatedScripts below; its expected count is
    # already declared here. A script gated without an entry here FAILS -- you
    # must state its class, not infer it.
    $script:DestructiveBranchCount = @{
        # ---- Class A (17) : overwrite + prune ----
        'Deploy-AdaptiveScopes.ps1'               = 2
        'Deploy-AutoLabelPolicies.ps1'            = 2
        'Deploy-Collections.ps1'                  = 2
        'Deploy-DataSources.ps1'                  = 2
        'Deploy-DLPPolicies.ps1'                  = 2
        'Deploy-FilePlan.ps1'                     = 2
        'Deploy-Glossary.ps1'                     = 2
        'Deploy-IRMEntityLists.ps1'               = 2
        'Deploy-IRMPolicies.ps1'                  = 2
        'Deploy-LabelPolicies.ps1'                = 2
        'Deploy-Labels.ps1'                       = 2
        'Deploy-RetentionPolicies.ps1'            = 2
        'Deploy-SITRulePackages.ps1'              = 2
        'Deploy-Scans.ps1'                        = 2
        'Deploy-UnifiedCatalog.ps1'               = 2
        'Deploy-UnifiedCatalogPolicies.ps1'       = 2
        # Not a Deploy-*.ps1 -- the 22nd reconciler, found by #108 once the
        # population was widened from the filename glob to the -PruneMissing
        # predicate. Declares BOTH -DirectionPolicy (repo-wins overwrite) AND
        # -PruneMissing (orphan-delete), so it is Class A like its 15 siblings.
        'Set-AuditRetentionPolicy.ps1'            = 2
        # ---- Class B (6) : prune only, no -DirectionPolicy ----
        'Deploy-AdministrativeUnits.ps1'          = 1
        'Deploy-Classifications.ps1'              = 1
        'Deploy-CommunicationCompliance.ps1'      = 1
        'Deploy-EntraDirectoryRoles.ps1'          = 1
        'Deploy-PurviewRoleGroups.ps1'            = 1
        'Deploy-RoleGroupBackingEntraGroups.ps1'  = 1
    }

    # The gate's two SUPPRESSORS, as bound at the call site.
    #
    # A gate can be perfectly wired -- 2 calls, -Query bound, decline throws,
    # ConfirmImpact High -- and still be INCAPABLE OF EVER PROMPTING, if -Force
    # is hard-bound to a constant:
    #
    #     $gateArgs = @{ ... ; Force = $true ; ... }     # the gate can never fire
    #
    # That is not hypothetical: it is the SHAPE of the ambient self-disarm
    # (`if ($Force) { $ConfirmPreference = 'None' }`) that ADR 0053 section 4 had
    # to strip out of Deploy-UnifiedCatalog and Deploy-UnifiedCatalogPolicies.
    # This repo has already shipped a gate that looked correct and could not fire.
    #
    # So: each suppressor must trace back to the OPERATOR'S OWN switch --
    # -Force must carry a $Force VariableExpressionAst, -IsWhatIf must carry a
    # $WhatIfPreference one. A constant, or any expression that never names the
    # operator's variable, is the finding.
    #
    # Returns @{ Force = <bool>; IsWhatIf = <bool> } -- $true when correctly bound.
    function Test-GateSuppressorBinding {
        param(
            [Parameter(Mandatory)]$Ast,
            [Parameter(Mandatory)]$GateCall
        )

        # Collect the value expressions bound to -Force / -IsWhatIf, whether the
        # caller splats a hashtable or binds the parameters directly.
        $valueFor = @{ Force = $null; IsWhatIf = $null }

        # (a) direct binding at the call site: `-Force:$Force`
        $elements = @($GateCall.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $el = $elements[$i]
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($el.ParameterName -notin @('Force', 'IsWhatIf')) { continue }
            $arg = if ($null -ne $el.Argument) { $el.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
            if ($null -ne $arg) { $valueFor[$el.ParameterName] = $arg }
        }

        # (b) splatted binding: `@gateArgs`, whose hashtable is assigned upstream.
        $splat = @($elements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            }) | Select-Object -First 1
        if ($splat) {
            $splatName = [string]$splat.VariablePath.UserPath
            $assign = @($Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.Left.VariablePath.UserPath -eq $splatName
                    }, $true)) | Select-Object -Last 1
            if ($assign) {
                $hash = @($assign.Right.FindAll({
                            param($n) $n -is [System.Management.Automation.Language.HashtableAst]
                        }, $true)) | Select-Object -First 1
                if ($hash) {
                    foreach ($pair in $hash.KeyValuePairs) {
                        $keyName = if ($pair.Item1 -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            [string]$pair.Item1.Value
                        }
                        else { ($pair.Item1.Extent.Text -replace "['`"]", '') }
                        if ($keyName -in @('Force', 'IsWhatIf') -and $null -eq $valueFor[$keyName]) {
                            $valueFor[$keyName] = $pair.Item2
                        }
                    }
                }
            }
        }

        # The value must NAME the operator's own variable. `$true` parses as a
        # VariableExpressionAst too -- but one whose name is 'true', not 'Force',
        # so a name check (not a mere "is it a variable" check) is what closes it.
        $expected = @{ Force = 'Force'; IsWhatIf = 'WhatIfPreference' }
        $result = @{}
        foreach ($param in 'Force', 'IsWhatIf') {
            $value = $valueFor[$param]
            if ($null -eq $value) { $result[$param] = $false; continue }
            $result[$param] = @($value.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.VariablePath.UserPath -eq $expected[$param]
                    }, $true)).Count -gt 0
        }
        return $result
    }

    # =====================================================================
    #  THE B2 GUARD (issue #103). Rules (a), (b) and (c).
    # =====================================================================
    #
    # PR #102's plan-keying guard (Get-PolicyKeyedGuard, above) proves no gate's
    # CONDITION mentions $DirectionPolicy. B2 is the shape that satisfies that
    # and is still fatal: leave the condition honestly plan-keyed, and launder
    # the policy through the LIST the condition counts.
    #
    #     if ($DirectionPolicy -ne 'repo-wins') { $repoWinsOverwrites.Clear() }
    #     ...
    #     if ($repoWinsOverwrites.Count -gt 0) { ...gate... }   # genuinely plan-keyed
    #
    # The gate goes silent; the writes proceed.
    #
    # THE STRUCTURAL INSIGHT THAT MAKES THIS TRACTABLE:
    # B2 is possible only where a gate's list DIVERGES from the write loop's
    # source. The OVERWRITE gate keys on a hand-maintained SHADOW list of display
    # strings, separate from the $plan that drives the Set-* writes -- empty the
    # shadow and the writes still fire. That is the entire B2 exposure. The PRUNE
    # gate keys on the delete loop's own source (or on a list derived from the
    # plan one line above the gate), so emptying it cancels the deletes too.
    # Rule (c) pins that immunity so PR-B cannot quietly break it.
    #
    # ---- THE CARVE-OUT, STATED ONCE, USED BY (b) AND (c) ----
    #
    #   `audit` is the sanctioned NON-WRITING mode.
    #   `portal-wins` and `repo-wins` BOTH write.
    #
    # So a condition may separate the writing modes from `audit` and may do
    # NOTHING ELSE. The carve-out is anchored to the scripts' own
    # [ValidateSet('audit','portal-wins','repo-wins')] and re-derived on every
    # run: add a FOURTH policy value and the guard fails loudly, demanding an
    # owner ruling rather than silently widening. This is the ADR 0056
    # "carve-out with a stated reason, mechanically re-verified" idiom.

    # The policy values the script itself declares. Derived, never hardcoded --
    # a hardcoded set would keep passing after someone adds a fourth value.
    function Get-DirectionPolicyValueSet {
        param([Parameter(Mandatory)]$Ast)
        $param = @($Ast.ParamBlock.Parameters | Where-Object {
                (Get-AstVariableName -VariableAst $_.Name) -eq 'DirectionPolicy'
            }) | Select-Object -First 1
        if (-not $param) { return $null }
        $vs = @($param.Attributes | Where-Object {
                $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'ValidateSet'
            }) | Select-Object -First 1
        if (-not $vs) { return $null }
        return @($vs.PositionalArguments | ForEach-Object { [string]$_.Value })
    }

    # THE VARIABLE'S NAME WITH ITS SCOPE QUALIFIER STRIPPED -- and a warning.
    #
    # Deploy-UnifiedCatalogPolicies.ps1 uses `$script:RepoWinsOverwrites`, whose
    # VariablePath.UserPath is 'script:RepoWinsOverwrites'. A guard that matches on
    # UserPath resolves nothing for UCP, finds ZERO .Add() sites, iterates an empty
    # collection, and passes GREEN while asserting nothing -- the exact
    # green-by-absence vacuity this suite exists to kill.
    #
    # The obvious remedy -- `VariablePath.UnqualifiedPath` -- IS A TRAP. That
    # property is INTERNAL to System.Management.Automation.VariablePath and is not
    # on its public surface, so from PowerShell it silently evaluates to an EMPTY
    # STRING for every variable in existence. A guard keyed on it matches NOTHING
    # AT ALL: no $DirectionPolicy reference is ever found, no list ever resolves,
    # every rule iterates an empty set, and the whole guard reports zero findings
    # against every mutant while looking perfectly plausible in review. It is a
    # worse vacuity than the one it was meant to fix, and it was caught here only
    # because the non-vacuity assertions below refuse to accept an unresolved list.
    #
    #   VariablePath public surface: DriveName, IsDriveQualified, IsGlobal,
    #   IsLocal, IsPrivate, IsScript, IsUnqualified, IsUnscopedVariable,
    #   IsVariable, UserPath. That is the whole list. UnqualifiedPath is not on it.
    #
    # So strip the qualifier ourselves. 'script:RepoWinsOverwrites' ->
    # 'RepoWinsOverwrites'; 'repoWinsOverwrites' -> 'repoWinsOverwrites'.
    # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.variablepath
    function Get-AstVariableName {
        param([Parameter(Mandatory)]$VariableAst)
        $userPath = [string]$VariableAst.VariablePath.UserPath
        if ($userPath -match ':') { return ($userPath -split ':')[-1] }
        return $userPath
    }

    function Test-AstNamesVariable {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        return @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_) -eq $Name }).Count -gt 0
    }

    # THE GATE'S LIST IS DERIVED FROM THE GATE. Never hardcoded: hardcoding
    # 'repoWinsOverwrites' means the guard silently stops applying the moment
    # PR-B names a list something else in one of 17 scripts.
    #
    # Walk from the gate call up to the innermost `if` that guards it via its
    # BODY and whose condition counts something; the counted variable IS the
    # gate's list. `if (-not (Assert-...))` holds the gate in its CONDITION, not
    # its body, and is correctly skipped by the body-identity check.
    #
    # Exactly one counted variable, or $null. Two (`$a.Count -gt 0 -or
    # $b.Count -gt 0`) is ambiguous and resolves to $null -- which the caller
    # treats as a FINDING. Fail closed.
    function Get-GateListVariableName {
        param([Parameter(Mandatory)]$GateCall)
        $node = $GateCall
        while ($null -ne $node.Parent) {
            $parent = $node.Parent
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $parent.Clauses) {
                    if (-not [object]::ReferenceEquals($clause.Item2, $node)) { continue }
                    $counted = @($clause.Item1.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
                                $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                                $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                [string]$n.Member.Value -eq 'Count' -and
                                $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst]
                            }, $true) | ForEach-Object { Get-AstVariableName -VariableAst $_.Expression } | Select-Object -Unique)
                    if ($counted.Count -eq 1) { return $counted[0] }
                    if ($counted.Count -gt 1) { return $null }   # ambiguous: fail closed
                }
            }
            $node = $parent
        }
        return $null
    }

    # Every method invoked ON the list, and every assignment TO it, anywhere in
    # the script -- function bodies included.
    #
    # WHOLE-SCRIPT, NOT "BETWEEN CONSTRUCTION AND GATE". A lexical line range is
    # not a lifetime: UCP constructs and populates its list inside a function and
    # gates it 350 lines later at top level, and a function DEFINED after the gate
    # can be CALLED before it. Nothing in any of the four scripts reads the
    # overwrite list after its gate, so the whole-script rule has zero false
    # positives today -- and it cannot be defeated by moving a .Clear() into a
    # helper.
    function Get-ListMethodCall {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                    $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_.Expression) -eq $Name })
    }

    function Get-ListAssignment {
        param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
        @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_.Left) -eq $Name })
    }

    # An empty-collection construction: `@()`, `New-Object ...List[string]`,
    # `[List[string]]::new()`. These CREATE the list; they do not populate it, so
    # they are not population sites and cannot carry policy. Anything else on the
    # right of the construction IS a population site and gets policy-checked --
    # which is what admits the eventual structural fix
    # (`$ow = @($plan | Where-Object Action -eq 'Update')`) while still refusing
    # `@($plan | Where-Object { $DirectionPolicy -eq 'repo-wins' })`.
    function Test-EmptyCollectionExpression {
        param($Expr)
        if ($null -eq $Expr) { return $false }
        $inner = $Expr
        while ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1) {
            $inner = $inner.PipelineElements[0]
        }
        if ($inner -is [System.Management.Automation.Language.CommandExpressionAst]) { $inner = $inner.Expression }
        if ($inner -is [System.Management.Automation.Language.ArrayExpressionAst]) {
            return ($inner.SubExpression.Statements.Count -eq 0)          # @()
        }
        if ($inner -is [System.Management.Automation.Language.ArrayLiteralAst]) {
            return ($inner.Elements.Count -eq 0)
        }
        if ($inner -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $inner.Static -and [string]$inner.Member.Value -eq 'new') {
            return (@($inner.Arguments).Count -eq 0)                      # [List[string]]::new()
        }
        # `New-Object 'System.Collections.Generic.List[string]'` -- a CommandAst
        # whose only argument is the type. An -ArgumentList seed makes it a
        # population site.
        if ($inner -is [System.Management.Automation.Language.CommandAst] -and
            $inner.GetCommandName() -eq 'New-Object') {
            $ctorArgs = @($inner.CommandElements | Select-Object -Skip 1)
            $hasSeed = @($ctorArgs | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -like 'Arg*'
                }).Count -gt 0
            return (-not $hasSeed -and $ctorArgs.Count -le 1)
        }
        return $false
    }

    # A GUARD CLAUSE: `if (<cond>) { ...; continue }` -- an `if` all of whose
    # clauses terminate control flow and which has no `else`. Everything AFTER it
    # in the same statement block is reached only when <cond> is FALSE, so it gates
    # its later siblings exactly as surely as if it wrapped them.
    function Test-TerminatingGuardClause {
        param([Parameter(Mandatory)]$Statement)
        if ($Statement -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
        if ($null -ne $Statement.ElseClause) { return $false }   # the else path falls through
        foreach ($clause in $Statement.Clauses) {
            $last = @($clause.Item2.Statements) | Select-Object -Last 1
            if ($null -eq $last) { return $false }
            $terminates = $last -is [System.Management.Automation.Language.ContinueStatementAst] -or
            $last -is [System.Management.Automation.Language.BreakStatementAst] -or
            $last -is [System.Management.Automation.Language.ReturnStatementAst] -or
            $last -is [System.Management.Automation.Language.ThrowStatementAst]
            if (-not $terminates) { return $false }
        }
        return $true
    }

    # Every construct that GATES $Node -- i.e. that $Node is reached only when its
    # controlling expression holds -- from $Node up to the script root, filtered to
    # those that mention $DirectionPolicy.
    #
    # Four shapes, and MISSING ANY ONE OF THEM IS A FAIL-OPEN HOLE:
    #
    #  1. `if` BODY -- positive. The obvious one.
    #  2. `else` / `elseif` body -- the NEGATION of the earlier clause conditions.
    #  3. A preceding GUARD CLAUSE in the same block -- also a negation:
    #
    #         foreach ($p in $plan) {
    #             if ($DirectionPolicy -ne 'repo-wins') { continue }   # <-- a SIBLING
    #             $repoWinsOverwrites.Add($displayName)
    #         }
    #
    #     The policy test is NOT an ancestor of the .Add(), so a walk that only
    #     looked at enclosing `if` bodies would never see it -- and this is the
    #     idiom these scripts already use everywhere for their PLAN guards, which
    #     makes it the likeliest way for PR-B to write B2. It is also, read as a
    #     negation, exactly how Deploy-UnifiedCatalogPolicies legitimately
    #     implements audit mode (`if ($DirectionPolicy -eq 'audit') { ...; return }`
    #     before the population loop), so the same machinery that closes the hole
    #     is what proves UCP's early-return shape is sound.
    #  4. Any OTHER construct (foreach / while / for / do / switch) whose
    #     CONTROLLING EXPRESSION mentions the policy is recorded as uncomputable and
    #     the caller fails CLOSED:
    #
    #         foreach ($p in ($plan | Where-Object { $DirectionPolicy -eq 'repo-wins' })) { $ow.Add(...) }
    #         switch ($DirectionPolicy) { 'repo-wins' { $ow.Add(...) } }
    function Get-PolicyGatingCondition {
        param([Parameter(Mandatory)]$Node)
        $found = [System.Collections.Generic.List[object]]::new()
        $node = $Node
        while ($null -ne $node.Parent) {
            $parent = $node.Parent
            if ($parent -is [System.Management.Automation.Language.StatementBlockAst]) {
                # Shape 3: preceding terminating guard clauses in this block.
                foreach ($stmt in @($parent.Statements)) {
                    if ([object]::ReferenceEquals($stmt, $node)) { break }   # only what PRECEDES us
                    if (-not (Test-TerminatingGuardClause -Statement $stmt)) { continue }
                    foreach ($clause in $stmt.Clauses) {
                        if (Test-AstNamesVariable -Ast $clause.Item1 -Name 'DirectionPolicy') {
                            $found.Add([pscustomobject]@{ Condition = $clause.Item1; Negated = $true; Construct = 'guard clause' })
                        }
                    }
                }
            }
            if ($parent -is [System.Management.Automation.Language.IfStatementAst]) {
                $clauses = @($parent.Clauses)
                for ($i = 0; $i -lt $clauses.Count; $i++) {
                    if ([object]::ReferenceEquals($clauses[$i].Item2, $node)) {
                        # this clause's own condition, positive ...
                        if (Test-AstNamesVariable -Ast $clauses[$i].Item1 -Name 'DirectionPolicy') {
                            $found.Add([pscustomobject]@{ Condition = $clauses[$i].Item1; Negated = $false; Construct = 'if' })
                        }
                        # ... and the negation of every EARLIER clause (elseif).
                        for ($j = 0; $j -lt $i; $j++) {
                            if (Test-AstNamesVariable -Ast $clauses[$j].Item1 -Name 'DirectionPolicy') {
                                $found.Add([pscustomobject]@{ Condition = $clauses[$j].Item1; Negated = $true; Construct = 'elseif' })
                            }
                        }
                    }
                }
                if ($null -ne $parent.ElseClause -and [object]::ReferenceEquals($parent.ElseClause, $node)) {
                    foreach ($clause in $clauses) {
                        if (Test-AstNamesVariable -Ast $clause.Item1 -Name 'DirectionPolicy') {
                            $found.Add([pscustomobject]@{ Condition = $clause.Item1; Negated = $true; Construct = 'else' })
                        }
                    }
                }
            }
            elseif ($parent -is [System.Management.Automation.Language.LoopStatementAst] -or
                $parent -is [System.Management.Automation.Language.SwitchStatementAst]) {
                $ctrl = $parent.Condition
                if ($null -ne $ctrl -and (Test-AstNamesVariable -Ast $ctrl -Name 'DirectionPolicy')) {
                    $found.Add([pscustomobject]@{ Condition = $null; Negated = $false; Construct = $parent.GetType().Name; Uncomputable = $ctrl.Extent.Text })
                }
            }
            $node = $parent
        }
        return @($found)
    }

    # The MAXIMAL sub-expressions of $Expr that name $DirectionPolicy and NO other
    # variable. Maximal, not minimal: `-not ($DirectionPolicy -eq 'audit')` means
    # {portal-wins, repo-wins} and must be evaluated WHOLE. Taking the minimal
    # sub-expression would see `-eq 'audit'`, compute {audit}, and false-fail.
    function Get-MaximalPolicyOnlyExpression {
        param([Parameter(Mandatory)]$Expr)
        $candidates = @($Expr.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ExpressionAst]
                }, $true) | Where-Object {
                $vars = @($_.FindAll({
                            param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst]
                        }, $true) | ForEach-Object { Get-AstVariableName -VariableAst $_ })
                (@($vars | Where-Object { $_ -eq 'DirectionPolicy' }).Count -gt 0) -and
                (@($vars | Where-Object { $_ -ne 'DirectionPolicy' }).Count -eq 0)
            })
        $maximal = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $candidates) {
            $covered = $false
            $up = $c.Parent
            while ($null -ne $up -and -not $covered) {
                foreach ($d in $candidates) {
                    if ([object]::ReferenceEquals($up, $d)) { $covered = $true; break }
                }
                $up = $up.Parent
            }
            if (-not $covered) { $maximal.Add($c) }
        }
        return @($maximal)
    }

    # The TRUTH SET of a policy-only expression over the script's own ValidateSet
    # values: which policies make it true.
    #
    # Returns $null for "cannot compute" -- a command call, a method invocation, a
    # scriptblock, or a parse failure. The caller FAILS CLOSED on $null. A
    # blacklist of known-bad spellings would fail OPEN on a novel one, and this
    # repo has been burned by fail-open guards.
    #
    # The expression is evaluated, not pattern-matched, so it admits no spelling:
    # -eq / -ne / -in / -notin / -not / -and / -or / reordered operands / double
    # quotes all compute correctly. The rejection of CommandAst and
    # InvokeMemberExpressionAst above is what makes evaluating source text from the
    # script under test safe: what remains is operators over $DirectionPolicy and
    # string literals, with no side effects and nothing to call.
    function Get-PolicyTruthSet {
        param([Parameter(Mandatory)]$Expr, [Parameter(Mandatory)][string[]]$PolicyValues)
        $unsafe = @($Expr.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -or
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -or
                    $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                    $n -is [System.Management.Automation.Language.SubExpressionAst]
                }, $true))
        if ($unsafe.Count -gt 0) { return $null }
        try {
            $probe = [scriptblock]::Create('param([string]$DirectionPolicy) [bool](' + $Expr.Extent.Text + ')')
        }
        catch { return $null }
        $set = [System.Collections.Generic.List[string]]::new()
        foreach ($value in $PolicyValues) {
            try {
                if (& $probe -DirectionPolicy $value) { $set.Add($value) }
            }
            catch { return $null }
        }
        return @($set)
    }

    # A gating condition's EFFECTIVE truth set, honouring else/elseif negation and
    # the coverage requirement.
    #
    # COVERAGE. Every $DirectionPolicy reference in the condition must sit inside
    # one of the maximal policy-only sub-expressions. Otherwise the policy is
    # entangled with another variable -- `if ($DirectionPolicy -ne 'audit' -and
    # $x -eq $DirectionPolicy)` -- and evaluating only the computable half would
    # fail OPEN on the other. Uncovered reference => $null => FINDING.
    function Get-GatingConditionTruthSet {
        param([Parameter(Mandatory)]$Gate, [Parameter(Mandatory)][string[]]$PolicyValues)
        if ($null -eq $Gate.Condition) { return $null }        # loop / switch: uncomputable
        $maximal = @(Get-MaximalPolicyOnlyExpression -Expr $Gate.Condition)
        if ($maximal.Count -eq 0) { return $null }

        # A BARE $DirectionPolicy that is not the whole condition is the policy being
        # CONSUMED by an enclosing expression that also names other variables --
        # `$DirectionPolicy -ne 'audit' -and $mode -eq $DirectionPolicy`. It is
        # trivially "policy-only" and evaluates truthy for every policy value, so it
        # would DISSOLVE harmlessly into the intersection below and the entanglement
        # with $mode would go unnoticed. That is a fail-OPEN hole, and it is exactly
        # the shape B1 uses. Fail closed instead. (A bare $DirectionPolicy that IS
        # the whole condition -- `if ($DirectionPolicy)` -- is a real, if useless,
        # truthiness test: truth set {all three}, which the whitelist rejects below.)
        foreach ($m in $maximal) {
            if ($m -is [System.Management.Automation.Language.VariableExpressionAst] -and
                -not ($m.Extent.StartOffset -eq $Gate.Condition.Extent.StartOffset -and
                    $m.Extent.EndOffset -eq $Gate.Condition.Extent.EndOffset)) {
                return $null
            }
        }

        $refs = @($Gate.Condition.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_) -eq 'DirectionPolicy' })
        foreach ($ref in $refs) {
            $covered = $false
            $up = $ref
            while ($null -ne $up -and -not $covered) {
                foreach ($m in $maximal) { if ([object]::ReferenceEquals($up, $m)) { $covered = $true; break } }
                $up = $up.Parent
            }
            if (-not $covered) { return $null }                # entangled: fail closed
        }

        if ($Gate.Negated) {
            # An else/elseif negation is only sound over the WHOLE condition. If the
            # condition also tests something else, the else branch's policy
            # constraint is not the complement of the policy conjunct. Fail closed.
            $whole = $maximal | Where-Object { [object]::ReferenceEquals($_.Extent, $Gate.Condition.Extent) -or $_.Extent.Text -eq $Gate.Condition.Extent.Text }
            if (-not $whole) { return $null }
            $set = Get-PolicyTruthSet -Expr $maximal[0] -PolicyValues $PolicyValues
            if ($null -eq $set) { return $null }
            return @($PolicyValues | Where-Object { $_ -notin $set })
        }

        # Positive: EVERY maximal policy-only sub-expression must hold. Intersect.
        $acc = @($PolicyValues)
        foreach ($m in $maximal) {
            $set = Get-PolicyTruthSet -Expr $m -PolicyValues $PolicyValues
            if ($null -eq $set) { return $null }
            $acc = @($acc | Where-Object { $_ -in $set })
        }
        return @($acc)
    }

    # Methods that CANNOT reduce the list. Whitelist, not blacklist: a blacklist of
    # Clear|Remove* fails OPEN on HashSet.ExceptWith, on a novel collection type, or
    # on whatever the next author reaches for. Adding a name here is an owner
    # decision that requires stating why it cannot shrink the list.
    $script:ListSafeMethod = @(
        'Add', 'AddRange', 'Insert', 'InsertRange',          # population
        'Contains', 'IndexOf', 'ToArray', 'ToString', 'GetEnumerator', 'CopyTo',
        'GetType', 'Sort', 'Reverse', 'TrimExcess', 'AsReadOnly',
        'Exists', 'Find', 'FindAll', 'ForEach', 'Where'      # read-only
    )
    $script:ListPopulationMethod = @('Add', 'AddRange', 'Insert', 'InsertRange')

    # Rule (a) + Rule (b), and -- with -AllowAuditEmptying -- rule (c).
    #
    # Returns a list of findings. Empty list = compliant. Also returns, via the
    # -PopulationSites ref, the count of sites that put items INTO the list, so the
    # caller can assert NON-VACUITY: every rule here iterates the list's population,
    # and a foreach over nothing passes green while asserting nothing.
    function Get-ListIntegrityFinding {
        param(
            [Parameter(Mandatory)]$Ast,
            [Parameter(Mandatory)][string]$ListName,
            [Parameter(Mandatory)][string[]]$PolicyValues,
            [Parameter(Mandatory)][ref]$PopulationSiteCount,
            [switch]$AllowAuditEmptying
        )
        $findings = [System.Collections.Generic.List[object]]::new()
        $writingPolicies = @($PolicyValues | Where-Object { $_ -ne 'audit' } | Sort-Object)
        $populationSites = [System.Collections.Generic.List[object]]::new()

        # ---- (a) APPEND-ONLY: no method may shrink the list ----
        foreach ($call in (Get-ListMethodCall -Ast $Ast -Name $ListName)) {
            $method = [string]$call.Member.Value
            if ($method -notin $script:ListSafeMethod) {
                $findings.Add([pscustomobject]@{
                        Rule = 'a'; Line = $call.Extent.StartLineNumber
                        Text = ($call.Extent.Text -replace '\s+', ' ')
                        Why  = "`$$ListName.$method() is not in the append-only whitelist. If it cannot REDUCE the list, add it to `$script:ListSafeMethod with a one-line reason. Shrinking the gate's list silences the gate while the writes proceed -- that is B2."
                    })
            }
            if ($method -in $script:ListPopulationMethod) { $populationSites.Add($call) }
        }

        # ---- (a) APPEND-ONLY: exactly ONE construction; no reassignment ----
        $assignments = @(Get-ListAssignment -Ast $Ast -Name $ListName)
        $constructions = @($assignments | Where-Object { $_.Operator -eq 'Equals' })
        foreach ($assign in $assignments) {
            if ($assign.Operator -eq 'PlusEquals') { $populationSites.Add($assign); continue }   # append
            if ($assign.Operator -ne 'Equals') {
                $findings.Add([pscustomobject]@{
                        Rule = 'a'; Line = $assign.Extent.StartLineNumber
                        Text = ($assign.Extent.Text -replace '\s+', ' ')
                        Why  = "operator '$($assign.Operator)' on `$$ListName is neither a construction nor an append."
                    })
                continue
            }
            if (-not (Test-EmptyCollectionExpression -Expr $assign.Right)) { $populationSites.Add($assign) }
            if ([object]::ReferenceEquals($assign, $constructions[0])) { continue }   # the construction

            # A SECOND `=` assignment is a reassignment. Under rule (c) exactly one
            # shape is carved out: emptying the prune list inside the ADR 0029
            # audit short-circuit, whose reason is RE-VERIFIED here against source
            # rather than asserted by a comment.
            $acquitted = $false
            if ($AllowAuditEmptying -and (Test-EmptyCollectionExpression -Expr $assign.Right)) {
                $gates = @(Get-PolicyGatingCondition -Node $assign)
                $auditOnly = $false
                foreach ($g in $gates) {
                    $ts = Get-GatingConditionTruthSet -Gate $g -PolicyValues $PolicyValues
                    if ($null -ne $ts -and (@($ts) -join ',') -eq 'audit') { $auditOnly = $true }
                }
                # ... and the SAME statement block must also empty the write plan.
                # If someone deletes `$plan.Clear()`, audit mode starts applying
                # creates and updates, and this carve-out goes RED.
                $block = $assign.Parent
                while ($null -ne $block -and $block -isnot [System.Management.Automation.Language.StatementBlockAst]) { $block = $block.Parent }
                $emptiesWritePlan = $false
                if ($null -ne $block) {
                    $emptiesWritePlan = @($block.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                                $n.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                [string]$n.Member.Value -eq 'Clear'
                            }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_.Expression) -ne $ListName }).Count -gt 0
                }
                if ($auditOnly -and $emptiesWritePlan) { $acquitted = $true }
                if ($auditOnly -and -not $emptiesWritePlan) {
                    $findings.Add([pscustomobject]@{
                            Rule = 'c'; Line = $assign.Extent.StartLineNumber
                            Text = ($assign.Extent.Text -replace '\s+', ' ')
                            Why  = ("`$$ListName is emptied under 'audit', but the same block does NOT empty the write plan. " +
                                'The carve-out for this statement is granted ONLY on the grounds that the block is a total ' +
                                "no-write short-circuit (`$plan.Clear() beside it). Without that, audit mode applies creates " +
                                'and updates while the gate stays silent. Restore the write-plan clear, or remove this emptying.')
                        })
                    continue
                }
            }
            if ($acquitted) { continue }

            $findings.Add([pscustomobject]@{
                    Rule = 'a'; Line = $assign.Extent.StartLineNumber
                    Text = ($assign.Extent.Text -replace '\s+', ' ')
                    Why  = "`$$ListName is REASSIGNED here. The gate's list is append-only between construction and the gate: reassigning it empties it as surely as .Clear(), and the gate then sits silent while the writes proceed."
                })
        }
        if ($constructions.Count -eq 0) {
            $findings.Add([pscustomobject]@{
                    Rule = 'a'; Line = 0; Text = "`$$ListName"
                    Why  = "the gate counts `$$ListName but nothing in this script constructs it. Either the gate reads a list built elsewhere (which this guard cannot follow) or the name is wrong. Fail closed."
                })
        }

        # ---- (a) no HANDOFF to a locally-defined function ----
        # A .NET list is a REFERENCE type, so `Reset-It $repoWinsOverwrites` where
        # `function Reset-It { param($L) $L.Clear() }` empties the gate's list under
        # a name no whole-script scan for `$repoWinsOverwrites` will ever see. Only
        # functions THIS SCRIPT defines are flagged: an external cmdlet taking the
        # list on the pipeline (`$repoWinsOverwrites | Sort-Object`) is a read, and
        # the four gated scripts hand their gate lists to nothing at all.
        $localFunctions = @($Ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true) | ForEach-Object { $_.Name })
        foreach ($cmd in @($Ast.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.CommandAst]
                    }, $true))) {
            $cmdName = $cmd.GetCommandName()
            if ([string]::IsNullOrEmpty($cmdName) -or $cmdName -notin $localFunctions) { continue }
            $handed = @($cmd.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    (Get-AstVariableName -VariableAst $_) -eq $ListName
                })
            if ($handed.Count -gt 0) {
                $findings.Add([pscustomobject]@{
                        Rule = 'a'; Line = $cmd.Extent.StartLineNumber
                        Text = ($cmd.Extent.Text -replace '\s+', ' ')
                        Why  = "`$$ListName is handed to '$cmdName', a function defined in this script. A .NET list is a reference type, so the callee can .Clear() it under a parameter name this guard cannot follow. Pass a COPY (`@(`$$ListName)`), or return the additions and .Add() them here."
                    })
            }
        }

        # ---- (a) no BARE ALIAS: `$x = $list` hands .Clear() a second name ----
        foreach ($assign in @($Ast.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
                    }, $true))) {
            if ($assign.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $leftName = Get-AstVariableName -VariableAst $assign.Left
            if ($leftName -eq $ListName) { continue }
            $rhs = $assign.Right
            while ($rhs -is [System.Management.Automation.Language.PipelineAst] -and $rhs.PipelineElements.Count -eq 1) { $rhs = $rhs.PipelineElements[0] }
            if ($rhs -is [System.Management.Automation.Language.CommandExpressionAst]) { $rhs = $rhs.Expression }
            if ($rhs -is [System.Management.Automation.Language.VariableExpressionAst] -and
                (Get-AstVariableName -VariableAst $rhs) -eq $ListName) {
                $findings.Add([pscustomobject]@{
                        Rule = 'a'; Line = $assign.Extent.StartLineNumber
                        Text = ($assign.Extent.Text -replace '\s+', ' ')
                        Why  = "`$$ListName is ALIASED here. A .NET list is a reference type, so `$$leftName.Clear() empties the gate's list under a name this guard does not track. Pipe a COPY (`@(`$$ListName | ...)`) instead."
                    })
            }
        }

        # ---- (b) POPULATION MAY NOT DISCRIMINATE BETWEEN TWO WRITING POLICIES ----
        foreach ($site in $populationSites) {
            # (b1) the value going IN may not be selected by policy.
            $value = if ($site -is [System.Management.Automation.Language.AssignmentStatementAst]) { $site.Right } else { $site }
            $valueRefs = if ($site -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                @(if (Test-AstNamesVariable -Ast $value -Name 'DirectionPolicy') { $value })
            }
            else {
                @($site.Arguments | Where-Object { Test-AstNamesVariable -Ast $_ -Name 'DirectionPolicy' })
            }
            if (@($valueRefs).Count -gt 0) {
                $findings.Add([pscustomobject]@{
                        Rule = 'b'; Line = $site.Extent.StartLineNumber
                        Text = ($site.Extent.Text -replace '\s+', ' ')
                        Why  = "the expression that populates `$$ListName names `$DirectionPolicy. The list must hold every object the run WILL touch, whatever policy let it through; filtering it by policy is B2."
                    })
            }

            # (b2) every policy-mentioning gate on the path to this site must have a
            #      truth set of EXACTLY the writing policies.
            foreach ($g in (Get-PolicyGatingCondition -Node $site)) {
                $ts = Get-GatingConditionTruthSet -Gate $g -PolicyValues $PolicyValues
                if ($null -eq $ts) {
                    $shown = if ($null -ne $g.Condition) { ($g.Condition.Extent.Text -replace '\s+', ' ') } else { ($g.Uncomputable -replace '\s+', ' ') }
                    $findings.Add([pscustomobject]@{
                            Rule = 'b'; Line = $site.Extent.StartLineNumber
                            Text = ($site.Extent.Text -replace '\s+', ' ')
                            Why  = "the population of `$$ListName is gated by a $($g.Construct) whose `$DirectionPolicy test has no computable truth set: `"$shown`". FAIL CLOSED -- a whitelist that cannot read a condition must not assume it is safe."
                        })
                    continue
                }
                $sorted = @($ts | Sort-Object)
                if (($sorted -join ',') -ne ($writingPolicies -join ',')) {
                    $shown = ($g.Condition.Extent.Text -replace '\s+', ' ')
                    $findings.Add([pscustomobject]@{
                            Rule = 'b'; Line = $site.Extent.StartLineNumber
                            Text = ($site.Extent.Text -replace '\s+', ' ')
                            Why  = ("the population of `$$ListName is gated on `"$shown`", whose truth set is {$($sorted -join ', ')}. " +
                                "The ONLY permitted policy test is one whose truth set is exactly the WRITING policies {$($writingPolicies -join ', ')} -- " +
                                'i.e. it may separate them from `audit`, the sanctioned non-writing mode, and do nothing else. ' +
                                'A test that admits only one writing policy leaves the other writing silently past a gate that never fires.')
                        })
                }
            }
        }

        $PopulationSiteCount.Value = $populationSites.Count
        return @($findings)
    }

    # Default gate arguments: no suppressor set, so the gate prompts.
    function Get-GateArgTable {
        param(
            [Parameter(Mandatory)]$Stub,
            [Parameter(Mandatory)][ref]$YesToAll,
            [Parameter(Mandatory)][ref]$NoToAll
        )
        @{
            Cmdlet   = $Stub
            Caption  = 'Destructive operation (ADR 0052)'
            Query    = '-PruneMissing will DELETE 3 orphan object(s). This cannot be undone. Continue?'
            YesToAll = $YesToAll
            NoToAll  = $NoToAll
        }
    }

    # =====================================================================
    #  THE GATED SET, AT RUN TIME -- and the #83 completion criterion.
    # =====================================================================

    # THE POPULATION: EVERY DESTRUCTIVE-CAPABLE SCRIPT ON DISK, DERIVED FROM A
    # PREDICATE, NOT A FILENAME GLOB (issue #108).
    #
    # Every `Deploy-*.ps1` filename glob in this file used to DEFINE "every
    # reconciler". `Set-AuditRetentionPolicy.ps1` declares -PruneMissing, calls
    # Remove-UnifiedAuditLogRetentionPolicy, shipped ConfirmImpact = 'Medium' --
    # the live issue #85 defect -- and was invisible to every count in #83
    # because its name is Set-*, not Deploy-*. The glob was the bug; the real
    # invariant is the destructive capability itself, not the filename.
    #
    # A script belongs to this population iff it declares [switch]$PruneMissing
    # -- the delete branch every reconciler in this repo can reach. Verified
    # against the WHOLE scripts/ directory as of #108, not assumed from the
    # `Deploy-*.ps1` set alone: Set-AuditRetentionPolicy.ps1 is the ONLY
    # non-Deploy-*.ps1 script under scripts/ that declares -PruneMissing.
    #
    # This is the population used to determine "should this be gated" (the
    # completion criterion below, and the destructive-branch class map's own
    # self-check). It is deliberately NARROWER than "every *.ps1 in scripts/"
    # -- see Get-GatedReconciler immediately below, which widens only the
    # ENUMERATION its "has a real gate call" predicate walks, and is used to
    # determine "IS this gated" instead.
    function Get-DestructiveCapableScriptFile {
        @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' |
                Where-Object {
                    $ast = Get-ScriptAstOrThrow -Path $_.FullName
                    @($ast.ParamBlock.Parameters | Where-Object { (Get-AstVariableName -VariableAst $_.Name) -eq 'PruneMissing' }).Count -gt 0
                })
    }

    # Which reconcilers are gated, derived from the SOURCE at run time.
    #
    # The canonical derivation: a script is gated iff it contains at least one real
    # Assert-DestructiveOperationConfirmed CommandAst. That predicate was always
    # filename-agnostic -- but the `Get-ChildItem -Filter 'Deploy-*.ps1'` feeding it
    # was NOT, so a gated Set-AuditRetentionPolicy.ps1 would have been invisible here
    # regardless of the AST check ever finding its gate call. Issue #108 widens the
    # enumeration to every *.ps1 in scripts/; the "has a gate call" filter is
    # unchanged and remains the sole determinant of membership, so this cannot pick
    # up a non-reconciler utility script by accident.
    #
    # The AST-contract Describe below drives its -ForEach from a SECOND copy of this
    # predicate (it has to -- -ForEach is evaluated during DISCOVERY, which runs in a
    # different SessionState where these helpers do not exist yet). The final
    # Describe in this file asserts the two derivations agree, so the copy cannot
    # silently drift.
    function Get-GatedReconciler {
        @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter '*.ps1' |
                Where-Object { @(Get-GateCallAst -Ast (Get-ScriptAstOrThrow -Path $_.FullName)).Count -gt 0 } |
                ForEach-Object { $_.Name } | Sort-Object)
    }

    # THE ONE DECLARED EXCEPTION to the #83 completion criterion, in the ADR 0056
    # "carve-out with a stated reason, mechanically re-verified" idiom.
    #
    # #105 LANDED: Deploy-EntraDirectoryRoles.ps1 was the sole declared exception
    # (interleaved single-pass reconcile loop; POSTed creates before the revoke plan
    # existed, so no gate site could ever make "No tenant writes were made" TRUE on
    # decline). It has been restructured to the same two-phase (plan-then-apply)
    # shape as `Deploy-PurviewRoleGroups.ps1` and now carries its own ADR 0052 gate,
    # so the carve-out below is EMPTY -- the staleness guard two Describes down would
    # have gone RED the moment a gate call appeared here if the entry had not been
    # removed. Nothing else has ever needed one. Keep the table so a future author
    # who genuinely cannot gate a new destructive-capable script has somewhere to
    # state why, with the same mechanical re-verification.
    $script:UngatedByDesign = @{}

    # Every script the AST contract ACTUALLY examined, recorded at RUN time by each
    # Context's BeforeAll. Read by the coverage assertion in the final Describe.
    #
    # This is the batch's own non-vacuity guard, and it is not ceremonial: the
    # -ForEach list that drives the contract was a HARDCODED four-script literal
    # until this change, so the contract ran green while five gated scripts were
    # never examined at all. An accumulator that is compared against the canonical
    # gated set is the only thing that can prove that is no longer true.
    $script:ContractExamined = [System.Collections.Generic.List[string]]::new()

    # =====================================================================
    #  THE CI-HANG SCANNER (batch 3). Derived, not curated.
    # =====================================================================
    #
    # THE DEFECT THIS REPLACES. The CI-hang Describe below used to drive its
    # -ForEach from a HARDCODED list of FOUR workflows, checking invocations of
    # TWO scripts (Deploy-Labels, Deploy-DLPPolicies). Twenty scripts are now
    # gated. Every CI invocation of the other EIGHTEEN was unexamined. That is the
    # same green-by-absence hole batch 1.5 closed for the gate contract, left wide
    # open for the hang contract -- and it is worse here, because the failure mode
    # is not "a gate is missing" but "the runner blocks forever on a prompt nobody
    # can answer".
    #
    # WHY IT MATTERS AT ALL. The gate uses $PSCmdlet.ShouldContinue(), which
    # performs no ConfirmImpact / $ConfirmPreference comparison and therefore
    # prompts UNCONDITIONALLY. Separately, raising ConfirmImpact to 'High' means
    # every $PSCmdlet.ShouldProcess(...) in these scripts now prompts too, because
    # $ConfirmPreference defaults to 'High'. So ANY CI invocation that reaches
    # either one, without a suppressor, is a hung job.
    #
    # ---- THE SUPPRESSOR SET, AND WHY -Force IS NOT IN IT ----
    #
    # This is the one place this guard deliberately contradicts the rollout brief,
    # which listed the suppressors as `-Confirm:$false`, `-Force`, or `-WhatIf`.
    # -Force IS NOT A SUPPRESSOR of the CI hang, and the difference is load-bearing:
    #
    #   * -Confirm:$false  -- sets $ConfirmPreference = 'None' for the invocation.
    #                         Suppresses ShouldProcess AND the gate. SAFE.
    #   * -WhatIf          -- ShouldProcess returns $false with a "What if:" line and
    #                         no prompt; ConfirmGate short-circuits on -IsWhatIf
    #                         BEFORE ShouldContinue. SAFE. (This is what makes the
    #                         drift-detection glob loop safe -- see below.)
    #   * -Force           -- a CUSTOM switch on these scripts. It suppresses the
    #                         GATE (ConfirmGate honours -Force) and does NOTHING to
    #                         $PSCmdlet.ShouldProcess, which consults only
    #                         $ConfirmPreference. ADR 0053 section 4 deliberately
    #                         REMOVED the `if ($Force) { $ConfirmPreference = 'None' }`
    #                         ambient self-disarm that used to paper over this.
    #
    # Verified by experiment, not reasoned from the docs. A probe script at
    # ConfirmImpact='High' invoked as `pwsh -c "& ./probe.ps1 -Force"` with stdin
    # closed does not proceed -- ShouldProcess THROWS ("PowerShell is in
    # NonInteractive mode. Read and Prompt functionality is not available."). The
    # same probe with -Confirm:$false or -WhatIf runs clean.
    #
    # No CI invocation in this repo currently relies on -Force alone, so excluding
    # it changes no verdict TODAY. It is excluded so that the first author who
    # reaches for `-Force` instead of `-Confirm:$false` -- the natural mistake,
    # since -Force is what silences the gate when you run the script by hand --
    # gets a RED test instead of a hung weekly job.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

    # Every `run:` block in a workflow, with its file and line. Pure text, walked
    # by indentation.
    #
    # NO powershell-yaml DEPENDENCY, and that is deliberate. validate.yml's `pester`
    # job runs ./tests/Run-Pester.ps1 on a bare windows-latest runner and installs
    # NOTHING but Pester -- the `Install-Module powershell-yaml` step exists only on
    # OTHER jobs. A guard that needed ConvertFrom-Yaml would throw in the one job
    # that actually runs it.
    function Get-WorkflowRunBlock {
        param([Parameter(Mandatory)][string]$Path)
        $lines = Get-Content -LiteralPath $Path
        $blocks = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^(\s*)run:(.*)$') { continue }
            $indent = $Matches[1].Length
            $rest = $Matches[2].Trim()
            $startLine = $i + 1
            if ($rest -match '^[|>][-+]?\d*$') {
                # Block scalar: every following line indented deeper than `run:`.
                $body = [System.Collections.Generic.List[string]]::new()
                $j = $i + 1
                while ($j -lt $lines.Count) {
                    $l = $lines[$j]
                    if ($l.Trim().Length -eq 0) { $body.Add(''); $j++; continue }
                    if ((($l -replace '^(\s*).*$', '$1').Length) -le $indent) { break }
                    $body.Add($l); $j++
                }
                $nonBlank = @($body | Where-Object { $_.Trim().Length -gt 0 })
                $min = if ($nonBlank.Count) {
                    ($nonBlank | ForEach-Object { ($_ -replace '^(\s*).*$', '$1').Length } | Measure-Object -Minimum).Minimum
                }
                else { 0 }
                $text = ($body | ForEach-Object { if ($_.Length -ge $min) { $_.Substring($min) } else { '' } }) -join "`n"
                $blocks.Add([pscustomobject]@{ File = (Split-Path $Path -Leaf); Line = $startLine; Text = $text })
                $i = $j - 1
            }
            elseif ($rest.Length -gt 0) {
                $blocks.Add([pscustomobject]@{ File = (Split-Path $Path -Leaf); Line = $startLine; Text = $rest })
            }
        }
        return $blocks
    }

    # Which suppressors an invocation binds. AST, never regex: a `run:` block is
    # PowerShell, and the same "prose cannot forge an AST node" rule that governs
    # the gate contract governs here. It is what lets validate.yml's
    #
    #     $exempt = @('Deploy-Classifications.ps1', 'Deploy-IRMPolicies.ps1', ...)
    #
    # be recognised for what it is -- StringConstantExpressionAsts consumed by
    # Get-Content, NOT invocations -- and correctly left unflagged. A regex for
    # `Deploy-\w+\.ps1` flags all eight and the guard becomes a nuisance that the
    # next author silences.
    function Get-InvocationSuppressor {
        param([Parameter(Mandatory)]$CommandAst, [Parameter(Mandatory)]$BlockAst)
        $found = [System.Collections.Generic.List[string]]::new()
        $elements = @($CommandAst.CommandElements)

        # (a) directly bound: -Confirm:$false / -WhatIf
        foreach ($el in $elements) {
            if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $name = $el.ParameterName
            $arg = $el.Argument
            # `$false` parses as a VariableExpressionAst whose UserPath is 'false'.
            $argIsFalse = $arg -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $arg.VariablePath.UserPath -eq 'false'
            $argIsTrue = $arg -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $arg.VariablePath.UserPath -eq 'true'
            if ($name -eq 'Confirm' -and $argIsFalse) { $found.Add('-Confirm:$false') }
            if ($name -eq 'WhatIf' -and ($null -eq $arg -or $argIsTrue)) { $found.Add('-WhatIf') }
        }

        # (b) splatted: `./scripts/Deploy-X.ps1 @applyArgs`, hashtable built above.
        #
        # ONLY the hashtable LITERAL counts, never a later `$applyArgs['Confirm'] = $false`
        # index-assignment. Fail closed: an index-assignment can sit inside an `if`,
        # and a CONDITIONALLY-bound suppressor is no suppressor at all. The repo's
        # own splats put Confirm in the literal and use index-assignment only for
        # SkipNames / PruneMissing, so this costs nothing and refuses the unsound shape.
        $splat = @($elements | Where-Object {
                $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            }) | Select-Object -First 1
        if ($splat) {
            $splatName = [string]$splat.VariablePath.UserPath
            $assign = @($BlockAst.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.Left.VariablePath.UserPath -eq $splatName
                    }, $true)) | Select-Object -First 1
            if ($assign) {
                $hash = @($assign.Right.FindAll({
                            param($n) $n -is [System.Management.Automation.Language.HashtableAst]
                        }, $true)) | Select-Object -First 1
                if ($hash) {
                    foreach ($pair in $hash.KeyValuePairs) {
                        $key = ($pair.Item1.Extent.Text -replace "['`"]", '')
                        $val = $pair.Item2.Extent.Text.Trim()
                        if ($key -eq 'Confirm' -and $val -eq '$false') { $found.Add("SPLAT @$splatName Confirm = `$false") }
                        if ($key -eq 'WhatIf' -and $val -eq '$true') { $found.Add("SPLAT @$splatName WhatIf = `$true") }
                    }
                }
            }
        }
        return @($found)
    }

    # Every invocation of a gated script inside one `run:` block.
    #
    # TWO SHAPES, and missing either one is a fail-open hole:
    #
    #  1. DIRECT -- the command name is a literal path ending in a gated script's
    #     file name. Backtick line-continuations need no special handling at all:
    #     the PowerShell parser joins them, which is exactly why the old regex-based
    #     version had to hand-roll a continuation walker.
    #
    #  2. GLOB DISPATCH -- .github/workflows/drift-detection.yml:113:
    #
    #         $reconcilers = Get-ChildItem scripts/Deploy-*.ps1 | Where-Object {
    #             (Get-Content $_.FullName -Raw) -match 'SupportsShouldProcess' }
    #         foreach ($script in $reconcilers) { & $script.FullName -WhatIf }
    #
    #     This invokes ALL TWENTY gated scripts, weekly, on a hosted runner. The
    #     command name is `$script.FullName` -- an expression, not a literal -- so a
    #     scanner looking only for literal script paths finds ZERO invocations here
    #     and passes green while asserting nothing about the single widest-reaching
    #     CI invocation in the repo. It is the exact shape most likely to be silently
    #     skipped, so it gets its own non-vacuity floor in the Describe below.
    #
    #     It is SAFE -- it binds -WhatIf -- but it must be PROVEN safe, not assumed.
    #
    #     Detection is deliberately fail-CLOSED and coarse: any `&`/`.` dispatch on a
    #     non-literal command name, in a block that also enumerates Deploy-*.ps1, is
    #     charged with invoking EVERY gated script. A dispatch this guard cannot
    #     resolve is treated as reaching all of them rather than none of them.
    function Get-CiInvocationSite {
        param(
            [Parameter(Mandatory)]$Block,
            [Parameter(Mandatory)][string[]]$GatedScripts,
            [Parameter(Mandatory)][ref]$ParseFailure
        )
        $sites = [System.Collections.Generic.List[object]]::new()
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Block.Text, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) {
            # A candidate block that will not parse must NOT be silently skipped --
            # that is how a scanner goes green by reading nothing. Recorded, and
            # asserted on as a hard failure.
            $ParseFailure.Value.Add([pscustomobject]@{
                    File = $Block.File; Line = $Block.Line
                    Why  = $errors[0].Message
                })
            return $sites
        }

        $commands = @($ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst]
                }, $true))

        $enumeratesReconcilers = @($commands | Where-Object {
                $_.GetCommandName() -eq 'Get-ChildItem' -and
                @($_.CommandElements | Where-Object { $_.Extent.Text -match 'Deploy-\*\.ps1' }).Count -gt 0
            }).Count -gt 0

        foreach ($cmd in $commands) {
            $first = $cmd.CommandElements[0]
            $nameText = $first.Extent.Text
            $targets = $null
            $kind = $null

            $hit = @($GatedScripts | Where-Object { $nameText -match ([regex]::Escape($_) + '$') })
            if ($hit.Count -gt 0) {
                $targets = $hit; $kind = 'direct'
            }
            elseif ($enumeratesReconcilers -and
                $cmd.InvocationOperator -in @('Ampersand', 'Dot') -and
                $first -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $targets = $GatedScripts; $kind = 'glob-dispatch'
            }
            if (-not $targets) { continue }

            $sites.Add([pscustomobject]@{
                    File        = $Block.File
                    Line        = $Block.Line
                    Kind        = $kind
                    Targets     = @($targets)
                    Command     = ($cmd.Extent.Text -replace '\s+', ' ')
                    Suppressors = @(Get-InvocationSuppressor -CommandAst $cmd -BlockAst $ast)
                })
        }
        return $sites
    }

    # The whole scan, over every workflow. Returns the counts the Describe asserts
    # on -- a scanner that finds nothing must be able to SAY it found nothing.
    function Get-CiHangScan {
        param([Parameter(Mandatory)][string[]]$GatedScripts)
        $wfDir = Join-Path $script:RepoRoot '.github' 'workflows'
        $allBlocks = [System.Collections.Generic.List[object]]::new()
        foreach ($wf in (Get-ChildItem -Path $wfDir -Filter '*.yml' -File)) {
            foreach ($b in (Get-WorkflowRunBlock -Path $wf.FullName)) { $allBlocks.Add($b) }
        }

        # CANDIDATE = any run block whose raw text so much as mentions 'Deploy-'.
        # A deliberate textual SUPERSET: it can only over-include, never miss an
        # invocation (every gated script's name, and the Deploy-*.ps1 glob, contain
        # it). The AST pass below is what does the real discrimination -- this only
        # keeps us from PowerShell-parsing the repo's bash blocks.
        $candidates = @($allBlocks | Where-Object { $_.Text -match 'Deploy-' })

        $parseFailures = [System.Collections.Generic.List[object]]::new()
        $sites = [System.Collections.Generic.List[object]]::new()
        foreach ($b in $candidates) {
            foreach ($s in (Get-CiInvocationSite -Block $b -GatedScripts $GatedScripts -ParseFailure ([ref]$parseFailures))) {
                $sites.Add($s)
            }
        }
        return [pscustomobject]@{
            TotalBlocks     = $allBlocks.Count
            CandidateBlocks = $candidates.Count
            ParseFailures   = @($parseFailures)
            Sites           = @($sites)
        }
    }
}

Describe 'ConfirmGate: ShouldContinue prompt emission (ADR 0052)' {

    It 'prompts via ShouldContinue when no suppressor is set' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 1
    }

    It 'returns $false when the operator declines' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeFalse
        $stub.Calls.Count | Should -Be 1
    }

    It 'passes the object names and count through to the operator in the query text' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $null = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'Destructive operation (ADR 0052)' `
            -Query "-PruneMissing will DELETE 2 orphan sensitivity label(s) from the tenant: Alpha, Beta. This cannot be undone. Continue?" `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $stub.Calls[0].Query | Should -Match 'Alpha, Beta'
        $stub.Calls[0].Query | Should -Match 'cannot be undone'
    }

    # THE regression test for issue #85. ShouldContinue must NOT consult
    # $ConfirmPreference. If this goes red, the Medium-vs-High defect is back.
    It 'ignores $ConfirmPreference entirely -- prompts even when $ConfirmPreference = None' {
        $ConfirmPreference = 'None'
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: -Force suppression (ADR 0052)' {

    It '-Force returns $true WITHOUT prompting' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false   # would decline if ever asked
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -Force
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }
}

Describe 'ConfirmGate: -WhatIf short-circuits BEFORE the prompt (ADR 0052)' {

    # -WhatIf must return $true so the caller still WALKS the destructive
    # branch and the per-write ShouldProcess calls inside it render their
    # "What if:" preview. Returning $false here would hide the very deletes
    # -WhatIf exists to preview.
    It '-WhatIf returns $true WITHOUT prompting (dry run never blocks on input)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -IsWhatIf
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It '-WhatIf takes precedence over -Force (neither prompts; both proceed)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -IsWhatIf -Force
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }
}

Describe 'ConfirmGate: -Confirm:$false is the unattended CI path (ADR 0052)' {

    It '-Confirm:$false returns $true WITHOUT prompting (CI runs unattended)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $true -ConfirmValue $false
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It 'an explicit -Confirm:$true still prompts' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $true -ConfirmValue $true
        $stub.Calls.Count | Should -Be 1
    }

    It 'an UNBOUND -Confirm still prompts (absence of -Confirm is not consent)' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs -ConfirmBound $false -ConfirmValue $false
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: one prompt per run, not one per object (ADR 0052)' {

    It 'honours a pre-set yesToAll without prompting again' {
        $yes = $true; $no = $false
        $stub = Get-StubCmdlet -Answer $false
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeTrue
        $stub.Calls.Count | Should -Be 0
    }

    It 'honours a pre-set noToAll without prompting again' {
        $yes = $false; $no = $true
        $stub = Get-StubCmdlet -Answer $true
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $result = Assert-DestructiveOperationConfirmed @gateArgs
        $result | Should -BeFalse
        $stub.Calls.Count | Should -Be 0
    }

    It 'writes the operator''s "Yes to All" answer back through the [ref] pair' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true -SetYesToAll
        $gateArgs = Get-GateArgTable -Stub $stub -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $null = Assert-DestructiveOperationConfirmed @gateArgs
        $yes | Should -BeTrue
    }

    # The shared-ref contract: a run that trips BOTH the repo-wins overwrite
    # gate AND the -PruneMissing delete gate prompts ONCE.
    It 'a second gate in the same run does not re-prompt after "Yes to All"' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $true -SetYesToAll

        $gate1 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'overwrite gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $gate2 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'prune gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)

        $gate1 | Should -BeTrue
        $gate2 | Should -BeTrue
        $stub.Calls.Count | Should -Be 1   # ONE prompt across BOTH gates
    }

    It 'a second gate in the same run does not re-prompt after "No to All"' {
        $yes = $false; $no = $false
        $stub = Get-StubCmdlet -Answer $false -SetNoToAll

        $gate1 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'overwrite gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)
        $gate2 = Assert-DestructiveOperationConfirmed -Cmdlet $stub -Caption 'c' -Query 'prune gate' `
            -YesToAll ([ref]$yes) -NoToAll ([ref]$no)

        $gate1 | Should -BeFalse
        $gate2 | Should -BeFalse
        $stub.Calls.Count | Should -Be 1
    }
}

Describe 'ConfirmGate: contract check on -Cmdlet' {

    It 'throws when -Cmdlet exposes no ShouldContinue method' {
        $yes = $false; $no = $false
        { Assert-DestructiveOperationConfirmed -Cmdlet ([pscustomobject]@{ Nope = $true }) `
                -Caption 'c' -Query 'q' -YesToAll ([ref]$yes) -NoToAll ([ref]$no) } |
            Should -Throw '*must expose a ShouldContinue method*'
    }
}

Describe 'The destructive-branch class map is DERIVED FROM THE SOURCE, not asserted' {

    # $script:DestructiveBranchCount drives how many gates each reconciler must
    # wire. A hand-maintained table is only as good as the hand -- and a table
    # that silently misclassifies a Class A script as Class B would EXPECT one
    # gate, get one gate, and pass green while the overwrite branch shipped
    # unguarded. The table would then be laundering the very defect it exists to
    # prevent.
    #
    # So the table is checked against the scripts themselves. The class is a
    # FACT ABOUT THE SOURCE, derivable with no judgment:
    #
    #   Class A (2 gates) -- declares -DirectionPolicy  => has an overwrite branch
    #                        AND -PruneMissing          => has a prune branch
    #   Class B (1 gate)  -- no -DirectionPolicy        => prune branch only
    #
    # This ran against all 21 Deploy-*.ps1 reconcilers through #83. #108 widens the
    # population from that filename glob to the destructive-capability predicate
    # (every script under scripts/ declaring -PruneMissing), which is what makes
    # Set-AuditRetentionPolicy.ps1 -- the 22nd reconciler, and Set-*, not Deploy-* --
    # visible to this class map's own self-check for the first time. See
    # Get-DestructiveCapableScriptFile in the file-level BeforeAll.

    BeforeDiscovery {
        # Self-contained: -ForEach is evaluated during DISCOVERY, which runs in a
        # SessionState that cannot see Get-DestructiveCapableScriptFile (defined in
        # the file-level BeforeAll, which has not executed yet). Mirrors that
        # function's predicate by hand rather than a 'Deploy-*.ps1' filename glob.
        $script:AllReconcilers = @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..' '..' 'scripts') -Filter '*.ps1' |
                Where-Object {
                    $tokens = $null
                    $errors = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
                    @($ast.ParamBlock.Parameters | Where-Object {
                                $_.Name -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                (([string]$_.Name.VariablePath.UserPath) -replace '^.*:', '') -eq 'PruneMissing'
                            }).Count -gt 0
                } |
                ForEach-Object { $_.Name }
        )
    }

    It 'covers every destructive-capable reconciler (no script may be silently absent)' {
        $onDisk = @(Get-DestructiveCapableScriptFile | ForEach-Object { $_.Name })
        $declared = @($script:DestructiveBranchCount.Keys)
        ($onDisk | Sort-Object) | Should -Be ($declared | Sort-Object) `
            -Because 'a reconciler missing from the class map is a reconciler whose gate count nobody has decided'
    }

    Context '<_>' -ForEach $script:AllReconcilers {

        BeforeAll {
            $script:RecAst = Get-ScriptAstOrThrow -Path (Join-Path $script:RepoRoot 'scripts' $_)
            $params = @($script:RecAst.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
            $script:HasDirectionPolicy = $params -contains 'DirectionPolicy'
            $script:HasPruneMissing = $params -contains 'PruneMissing'
            $script:DeclaredCount = $script:DestructiveBranchCount[$_]
        }

        It 'has a -PruneMissing branch (Class C -- no destructive branch -- is empty)' {
            $script:HasPruneMissing | Should -BeTrue `
                -Because 'every one of the 22 reconcilers can delete or revoke tenant state; if this ever fails, the class map needs a Class C'
        }

        It 'its declared gate count matches the class derivable from its parameters' {
            $derived = if ($script:HasDirectionPolicy) { 2 } else { 1 }
            $script:DeclaredCount | Should -Be $derived -Because (
                "$_ declares -DirectionPolicy = $($script:HasDirectionPolicy), so it has $derived destructive branch(es) " +
                "(overwrite + prune, or prune alone). The class map says $($script:DeclaredCount). " +
                'A Class A script misclassified as Class B would expect one gate, get one gate, and ship its overwrite branch UNGUARDED.'
            )
        }
    }
}

Describe 'ADR 0052 reference implementations: AST contract (not source text)' {

    # WHY THIS DESCRIBE IS AST-BASED, AND WHY THAT IS NOT PEDANTRY.
    #
    # Every assertion here was originally a source-text regex, and the regexes
    # were VACUOUS. Two independent instances, both caught, both worth recording
    # because the failure mode is the exact one this whole PR exists to remove:
    #
    #   1. `Should -Match 'This run will OVERWRITE'` is case-INSENSITIVE, and it
    #      passed against pre-fix Deploy-Labels.ps1 -- a script with NO plan-keyed
    #      gate at all -- by matching the lowercase COMMENT on line 1804.
    #
    #   2. `Should -Match 'ConfirmGate\.psm1'` (the "imports the module" check)
    #      passed with the real `Import-Module` line DELETED, because THIS PR
    #      added explanatory comments that mention `ConfirmGate.psm1` by name.
    #      The PR's own prose made its own guard vacuous.
    #
    # A file is not its text. `Should -Match` cannot tell code from a comment,
    # and this repo's comments deliberately quote the anti-pattern they forbid.
    #
    # PROSE CANNOT FORGE AN AST NODE. A comment never becomes a CommandAst; a
    # string literal never becomes an IfStatementAst condition. So every claim
    # below is made against parsed nodes, and each is proven to distinguish the
    # real script from a mutant (see the mutation matrix in PR #102).
    #
    # WHAT THIS DESCRIBE DOES NOT PROVE -- read before relying on it.
    #
    # These assertions prove the gate is WIRED (it exists, it is reached, it is
    # keyed on a plan predicate, it aborts on decline, its suppressors trace to
    # the operator's own switches). They are SYNTACTIC. They do NOT prove the
    # gate is REACHED WITH A CORRECT PLAN: policy can still be laundered through
    # a local variable, or through upstream mutation of the plan list itself,
    # and this suite will stay green. Both shapes are named, with code, in the
    # boundary note above the plan-keying assertion below -- B1 and B2. B2 is
    # the NATURAL mistake, not an adversarial one, and it is what a PR-B reviewer
    # should be looking for by eye.
    #
    # A guard is only as trustworthy as its stated boundary. This one's boundary
    # is stated.

    # ========== THE GATED SET IS DERIVED, NOT CURATED (PR-B batch 1.5) ==========
    #
    # This list was a HARDCODED four-script literal -- PR-A's four -- and that made
    # the whole Describe VACUOUS for everything PR-B added. Batch 1 gated five Class B
    # reconcilers; nine scripts carried gate calls; the contract examined FOUR. Pester
    # reported 149/149 GREEN with batch 1's five scripts entirely unexamined: gate
    # wiring, query text, decline-throw, plan-keying and rules (a)/(b)/(c) never ran
    # against a single one of them.
    #
    # That is GREEN BY ABSENCE -- the exact vacuity this file exists to kill, shipped
    # by the file itself. A curated list of scripts-under-guard is a guard with an
    # opt-out, and the opt-out is silent.
    #
    # So the list is DERIVED: every script under scripts/ carrying at least one real
    # Assert-DestructiveOperationConfirmed CommandAst. AST, not text -- a comment or a
    # string mentioning the function name is not a gate (see the header note: prose
    # cannot forge an AST node). This makes the guard SELF-CLOSING: gating a script
    # automatically subjects it to the full contract, and no future author can gate a
    # script and silently escape review. Batch 2 adds eleven more; they arrive
    # pre-guarded.
    #
    # #108: the ENUMERATION this predicate walked used to be filtered to
    # 'Deploy-*.ps1' before the "has a gate call" check ever ran, so a gated
    # Set-AuditRetentionPolicy.ps1 would have been invisible to the full AST
    # contract below -- wiring, ConfirmImpact, import, query text, decline-throw,
    # plan-keying, the B2 rules -- NONE of it would have run against it, exactly the
    # "gated but unexamined" hole batch 1.5 closed for the four PR-A scripts. The
    # "has a gate call" predicate itself was always filename-agnostic and needed no
    # change; only the glob feeding it did.
    #
    # Each script's expected gate count is declared in $script:DestructiveBranchCount
    # (file-level BeforeAll) -- a script gated without a declared class is a hard
    # failure, by design.
    BeforeDiscovery {
        # Pester evaluates -ForEach during DISCOVERY, which runs in a DIFFERENT
        # SessionState from the run pass: the file-level BeforeAll has not executed,
        # so Get-ScriptAstOrThrow / Get-GateCallAst do not exist here, and a variable
        # set here does NOT survive into Run (verified, not assumed). Hence this
        # deliberately self-contained second copy of the "is it gated?" predicate.
        #
        # A second copy is a divergence risk, and it is closed mechanically, not by
        # discipline: the final Describe in this file re-derives the gated set at RUN
        # time with the canonical helper and asserts it equals the set of scripts the
        # Contexts below actually examined. Let the copies drift and that goes RED.
        $script:GatedScripts = @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..' '..' 'scripts') -Filter '*.ps1' |
                Where-Object {
                    $tokens = $null
                    $errors = $null
                    $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
                    @($ast.FindAll({
                                param($n)
                                $n -is [System.Management.Automation.Language.CommandAst] -and
                                $n.GetCommandName() -eq 'Assert-DestructiveOperationConfirmed'
                            }, $true)).Count -gt 0
                } | ForEach-Object { $_.Name } | Sort-Object
        )
    }

    Context 'on <_>' -ForEach $script:GatedScripts {

        BeforeAll {
            $script:ScriptName = $_
            $script:ScriptFile = Join-Path $script:RepoRoot 'scripts' $_
            $script:Text = Get-Content -LiteralPath $script:ScriptFile -Raw
            $script:Ast = Get-ScriptAstOrThrow -Path $script:ScriptFile
            $script:GateCalls = @(Get-GateCallAst -Ast $script:Ast)
            $script:ExpectedGates = $script:DestructiveBranchCount[$_]

            # Record what the contract actually examined, for the coverage assertion
            # in the final Describe. See $script:ContractExamined.
            $script:ContractExamined.Add($_)
        }

        It 'has a declared destructive-branch class (Class A = 2 gates, Class B = 1)' {
            # Fails loudly if PR-B gates a script without declaring how many
            # destructive branches it has. The count assertions below are only
            # meaningful because this one refuses to let the expectation default.
            $script:ExpectedGates | Should -BeIn @(1, 2) `
                -Because "'$($script:ScriptName)' must have an entry in `$script:DestructiveBranchCount -- state the class, do not infer it"
        }

        It 'declares ConfirmImpact = ''High'' in the real CmdletBinding attribute' {
            # AST, not regex: these scripts carry comments that discuss
            # ConfirmImpact = 'High' / 'Medium' in prose, so a text match proves
            # nothing about the attribute the runtime actually sees.
            Get-ConfirmImpact -Ast $script:Ast | Should -BeExactly 'High' `
                -Because 'ShouldProcess prompts only when ConfirmImpact >= $ConfirmPreference (default High); Medium is the issue #85 defect'
        }

        It 'imports ConfirmGate.psm1 via a real Import-Module command (not a mention in a comment)' {
            # V1: the regex version of this assertion passed with the real
            # Import-Module line deleted, satisfied by this PR's own comments.
            @(Get-ConfirmGateImportAst -Ast $script:Ast).Count | Should -BeGreaterThan 0 `
                -Because 'the gate must be the shared module, not re-inlined -- and a comment naming the module is not an import'
        }

        It 'wires exactly one gate per destructive branch, as real command calls' {
            # Class-aware: 2 for Class A (overwrite + prune), 1 for Class B
            # (prune only). NOT `-BeGreaterThan 0` -- that would let a Class A
            # script ship with only ONE of its two branches gated.
            $script:GateCalls.Count | Should -Be $script:ExpectedGates `
                -Because "$($script:ScriptName) has $($script:ExpectedGates) destructive branch(es); every one must call Assert-DestructiveOperationConfirmed"
        }

        It 'binds -Query on every gate, one per destructive branch' {
            $expected = if ($script:ExpectedGates -eq 2) { @('overwriteQuery', 'pruneQuery') } else { @('pruneQuery') }
            $queries = @($script:GateCalls | ForEach-Object { Get-BoundQueryVariableName -GateCall $_ }) | Sort-Object
            $queries | Should -Be $expected `
                -Because 'each gate must name the objects it is about to destroy; an operator who cannot see what they are destroying is not really being asked'
        }

        # ---- B3: a wired gate that can never fire is not a gate ----
        #
        # Everything else in this Describe proves the gate is WIRED. None of it
        # proves the gate CAN FIRE. A gate with `Force = $true` hard-bound in its
        # argument table passes every other assertion here and prompts exactly
        # never.
        #
        # That is not a contrived mutant. It is the shape of the ambient
        # self-disarm ADR 0053 section 4 had to delete from Deploy-UnifiedCatalog
        # and Deploy-UnifiedCatalogPolicies -- the one reconciler already at
        # ConfirmImpact = 'High' was neutering itself. This repo has shipped a
        # gate that looked correct and could not fire; it is not a hypothetical.
        It 'binds each gate''s suppressors to the OPERATOR''s switches, not to constants' {
            $script:GateCalls.Count | Should -Be $script:ExpectedGates `
                -Because 'an assertion about "each gate" is vacuous if there are no gates'

            foreach ($gate in $script:GateCalls) {
                $bound = Test-GateSuppressorBinding -Ast $script:Ast -GateCall $gate
                $line = $gate.Extent.StartLineNumber

                $bound['Force'] | Should -BeTrue `
                    -Because "the gate at line $line must bind -Force to the operator's `$Force switch. Bound to a constant (`Force = `$true`) the gate is wired, passes every other assertion in this file, and CAN NEVER PROMPT -- the ADR 0053 section 4 self-disarm shape."

                $bound['IsWhatIf'] | Should -BeTrue `
                    -Because "the gate at line $line must bind -IsWhatIf to `$WhatIfPreference. Hard-bound to `$true it never prompts; hard-bound to `$false a dry run blocks on input."
            }
        }

        # ---- THE OTHER HALF OF THE SUPPRESSOR CONTRACT: $Force must be REAL ----
        #
        # Test-GateSuppressorBinding (above) proves the gate BINDS something named
        # $Force. It does not prove that name refers to the operator's switch. Delete
        # `[switch]$Force` from a gated script's param block and the ENTIRE suite --
        # every assertion in this file -- stays GREEN. That hole was proved by
        # experiment, not theorised.
        #
        # Runtime is fail-SAFE in that state ($Force resolves to $null, the gate sees
        # $false, and it PROMPTS rather than disarming), so it is not a P0. But an
        # undeclared -Force means the operator has no way to run unattended and will
        # reach for something worse, and batch 2 gates Deploy-IRMEntityLists.ps1 and
        # Deploy-IRMPolicies.ps1, which BOTH currently lack -Force entirely.
        #
        # THREE SHAPES, and the last two are fail-DANGEROUS -- they disarm every gate
        # in the script while passing every other assertion in this file:
        #
        #   1. no `$Force` param at all          -- gate always prompts (fail-safe, but broken)
        #   2. `[switch]$Force = $true`          -- a DEFAULT-ON switch. The gate binds
        #                                           $Force, $Force is $true, the gate
        #                                           NEVER PROMPTS. One token, total disarm.
        #   3. `$Force = $true` before the gate  -- reassignment. Same total disarm, and
        #                                           it is the ADR 0053 section 4
        #                                           self-disarm shape wearing a new hat.
        #
        # Shapes 2 and 3 are not in the brief for this batch; they were found by
        # attacking shape 1's fix and asking what ELSE satisfies it. All three are
        # closed here, from the ParamBlock AST.
        It 'declares -Force as a real, un-defaulted [switch] the operator controls' {
            $forceParam = @($script:Ast.ParamBlock.Parameters | Where-Object {
                    (Get-AstVariableName -VariableAst $_.Name) -eq 'Force'
                }) | Select-Object -First 1

            $forceParam | Should -Not -BeNullOrEmpty -Because (
                "$($script:ScriptName) wires a gate that binds `-Force:`$Force, but its param block DECLARES no `$Force. " +
                'The gate then binds an unresolved variable: it can never be suppressed, so every unattended run prompts and hangs. ' +
                'Test-GateSuppressorBinding proves the gate BINDS something named $Force; only this proves the script DEFINES it.'
            )

            # [switch], not [bool] and not untyped. StaticType, so the fully-qualified
            # spelling ([System.Management.Automation.SwitchParameter]) passes too.
            $forceParam.StaticType.FullName | Should -BeExactly 'System.Management.Automation.SwitchParameter' `
                -Because "-Force must be a [switch]: a [bool]`$Force would force every caller -- and every CI workflow -- to pass a value, and an untyped `$Force accepts a string."

            # A DEFAULT-ON switch disarms every gate in the script. `[switch]$Force = $true`
            # passes the suppressor-binding assertion above (the gate does bind $Force)
            # and prompts exactly never. A switch's correct default is absent.
            $forceParam.DefaultValue | Should -BeNullOrEmpty -Because (
                "`[switch]`$Force in $($script:ScriptName) must carry NO default. A default of `$true means the gate is suppressed on every run, " +
                'including runs where nobody passed -Force -- wired, green against every other assertion in this file, and incapable of prompting.'
            )

            # Reassignment is the same disarm from a different direction.
            $reassigned = @($script:Ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst]
                    }, $true) | Where-Object { (Get-AstVariableName -VariableAst $_.Left) -eq 'Force' })

            $reassigned.Count | Should -Be 0 -Because (
                "nothing may ASSIGN to `$Force in $($script:ScriptName): `$Force = `$true` before the gate suppresses it just as completely as a " +
                '$true default, and it is the ADR 0053 section 4 ambient self-disarm in a new spelling. $Force is the OPERATOR''s input and is read-only ' +
                'to the script. Assignment(s): ' + (($reassigned | ForEach-Object { "line $($_.Extent.StartLineNumber): '$($_.Extent.Text -replace '\s+', ' ')'" }) -join '; ')
            )
        }

        It 'aborts with ZERO tenant writes when the operator declines (each gate''s decline branch throws)' {
            # V3: the regex version asserted only that a `throw '...'` LITERAL
            # existed somewhere in the file. It stayed green with both gate calls
            # deleted. This walks from each real gate CommandAst to the `if`
            # whose CONDITION it sits in, and asserts that if's BODY throws.
            #
            # NON-VACUITY GUARD. Without this line the foreach below iterates an
            # empty set when a script has NO gates, and the It passes green while
            # asserting nothing at all -- the same "green by absence" defect this
            # Describe exists to kill. Every gate-iterating It states its
            # population first.
            $script:GateCalls.Count | Should -Be $script:ExpectedGates -Because 'an assertion about "each gate" is vacuous if there are no gates'

            foreach ($gate in $script:GateCalls) {
                $throws = @(Get-GateDeclineThrow -GateCall $gate)
                $throws.Count | Should -BeGreaterThan 0 `
                    -Because "the gate at line $($gate.Extent.StartLineNumber) must abort the run on decline, not fall through into a half-applied state"
                ($throws | ForEach-Object { $_.Extent.Text }) -join ' ' |
                    Should -Match 'No tenant writes were made'
            }
        }

        # ============ THE PLAN-KEYING GUARD (V4) -- AND ITS BOUNDARY ============
        #
        # READ THIS BEFORE TRUSTING THIS ASSERTION. It is a PARTIAL guard, and
        # knowing exactly where it stops is the difference between a safety net
        # and a false sense of one.
        #
        # WHAT IT CATCHES -- policy-keying expressed IN A GATE-GUARDING CONDITION.
        # Structural, so it admits no spelling. Walk from each real gate call up
        # through every `if` that guards it (any depth, entered via the BODY) and
        # assert no such condition so much as MENTIONS the $DirectionPolicy
        # variable. All of these die:
        #
        #     if ($DirectionPolicy -eq 'repo-wins' -and $ow.Count -gt 0)   # the original
        #     if ($ow.Count -gt 0 -and $DirectionPolicy -eq 'repo-wins')   # reordered
        #     if ($DirectionPolicy -eq "repo-wins" -and $ow.Count -gt 0)   # double-quoted
        #     if ($DirectionPolicy -ne 'portal-wins' -and $ow.Count -gt 0) # negated
        #     if ($DirectionPolicy -eq 'repo-wins') { if ($ow.Count -gt 0) # outer nesting
        #
        # Operand order, quoting, negation, nesting depth: all irrelevant. A
        # VariableExpressionAst is a VariableExpressionAst.
        #
        # ---- B2: CAUGHT as of issue #103. B1: STILL UNCAUGHT. ----
        #
        #   B2 -- policy laundered through the PLAN LIST ITSELF rather than
        #     through the gate's condition:
        #
        #       if ($DirectionPolicy -ne 'repo-wins') { $repoWinsOverwrites.Clear() }
        #       ...
        #       if ($repoWinsOverwrites.Count -gt 0) { ...gate... }   # pure plan predicate!
        #
        #     The gate condition IS plan-keyed -- genuinely, not cosmetically --
        #     so THIS assertion passes. But the list is emptied under
        #     portal-wins, so the gate stays silent while the writes proceed.
        #     Behaviourally identical to the original bug.
        #
        #     It is the NATURAL mistake, not an adversarial one: seven ungated
        #     Class A reconcilers already carry a live `$DirectionPolicy -eq
        #     'repo-wins'` test that today wraps only a Write-Warning. An author
        #     rolling the gate out by pattern-matching the local idiom drops the
        #     `.Add()` INSIDE that existing `if` and writes B2 by following the
        #     surrounding code.
        #
        #     ==> CLOSED by the three assertions below this one (issue #103):
        #         (a) the overwrite gate's list is APPEND-ONLY -- nothing may
        #             .Clear() it, reassign it, alias it, or call any method on
        #             it that is not on the cannot-shrink whitelist. ABSOLUTE:
        #             an UNCONDITIONAL .Clear() is exactly as silent as a
        #             policy-keyed one, so there is no policy carve-out.
        #         (b) its POPULATION may not discriminate between two WRITING
        #             policies. Whitelist, not blacklist: the only permitted
        #             policy test is one whose truth set is exactly
        #             {portal-wins, repo-wins}. `-ne 'audit'` passes;
        #             `-eq 'repo-wins'` and `-ne 'portal-wins'` are findings, and
        #             so is any test whose truth set cannot be COMPUTED.
        #         (c) the PRUNE gate's list is append-only too -- see below.
        #
        #   WHY THE PRUNE GATE NEEDS NO B2 GUARD OF ITS OWN, and what rule (c)
        #   pins. B2 is possible only where a gate's list DIVERGES from the write
        #   loop's source. The OVERWRITE gate keys on a hand-maintained SHADOW
        #   list of display strings, separate from the $plan that drives the
        #   Set-* writes: empty the shadow and the writes still fire. That is the
        #   entire B2 exposure. The PRUNE gate is immune BY CONSTRUCTION in all
        #   four gated scripts, by one of two mechanisms:
        #
        #     * Deploy-Labels: $orphans IS the delete loop's source
        #       (`$sortedOrphans = $orphans | Sort-Object ...`). Empty it and the
        #       DELETES vanish with the gate. That is why `$orphans = @()` in the
        #       audit short-circuit is correct and not a defect.
        #     * Deploy-FilePlan / Deploy-DLPPolicies / Deploy-UnifiedCatalogPolicies:
        #       the prune list is built FROM THE PLAN one line above the gate and
        #       read one line later. Zero lifetime; no window for policy to act.
        #
        #   That immunity is a PRECONDITION of scoping (a)/(b) to the overwrite
        #   list, and PR-B must not be able to quietly break it. Rule (c) asserts
        #   the prune list is append-only as well, with ONE declared exception --
        #   Deploy-Labels' `$orphans = @()` -- whose reason is re-verified against
        #   source on every run: the exception holds only while the SAME block is
        #   gated on `audit` alone AND also empties the write plan
        #   (`$plan.Clear()`). Delete that line and rule (c) goes RED. A carve-out
        #   without a mechanically-asserted reason is the erosion this suite
        #   exists to prevent.
        #
        #   B1 -- policy laundered through a LOCAL VARIABLE. **STILL UNCAUGHT.**
        #     This is the one remaining hole, and it is named here rather than
        #     papered over.
        #
        #       $isRepoWins = ($DirectionPolicy -eq 'repo-wins')
        #       if ($isRepoWins -and $overwrites.Count -gt 0) { ...gate... }   # gate
        #       if ($isRepoWins) { $repoWinsOverwrites.Add($displayName) }     # list
        #
        #     Neither condition NAMES $DirectionPolicy, so the plan-keying walk sees
        #     a clean plan predicate and rule (b) sees no policy gate. Catching it
        #     needs data-flow analysis -- following a boolean through an assignment
        #     -- which is out of scope for a Pester guard.
        #
        #     The same boundary covers anything else that reaches the list through a
        #     binding this guard cannot follow: a splatted hashtable
        #     (`$a = @{ L = $repoWinsOverwrites }; Reset-It @a`), or stashing the
        #     list in another structure and clearing it from there. What rule (a)
        #     DOES close are the two shapes that are a single AST node -- the bare
        #     alias (`$x = $repoWinsOverwrites`) and the direct handoff to a
        #     locally-defined function (`Reset-It $repoWinsOverwrites`) -- which it
        #     REFUSES outright rather than trying to follow.
        #
        #     AN HONESTLY-LABELLED LIMITED GUARD IS FINE; A LIMITED GUARD SOLD AS
        #     COMPLETE IS NOT. B1 is what PR-B's reviewers must look for BY EYE:
        #     **if you see $DirectionPolicy assigned into a local, look hard at what
        #     that local then gates.**
        #
        #     The durable fix is structural, not a test: derive the overwrite list
        #     FROM THE PLAN (`@($plan | Where-Object Action -eq 'Update')`) so it
        #     cannot diverge from the writes at all -- exactly the property that
        #     already makes the prune gate immune, and the reason B2 is possible on
        #     one gate and impossible on the other. That is an ADR-sized change
        #     across 15 scripts; recorded on #83, not done here. Rules (a)/(b) are
        #     the right move NOW precisely because that refactor is not, and they
        #     stay correct even after it lands (the guard's own probe suite pins the
        #     plan-derived shape as GREEN).
        It 'keys every gate on the PLAN -- no gate-guarding condition mentions $DirectionPolicy' {
            # NON-VACUITY GUARD (see the note on the decline-throw assertion).
            # Get-PolicyKeyedGuard walks outward FROM each gate call, so with
            # zero gates it returns zero offenders and this would pass green on a
            # script that has no gate at all. State the population first.
            $script:GateCalls.Count | Should -Be $script:ExpectedGates -Because 'a "no gate is policy-keyed" claim is vacuous if there are no gates'

            $offenders = @(Get-PolicyKeyedGuard -Ast $script:Ast)

            $offenders.Count | Should -Be 0 -Because (
                'the gate must be keyed on the plan (the set of objects that will actually be destroyed), never on $DirectionPolicy. ' +
                'The policy is a PROXY for "will this overwrite?" and a fallible one: Deploy-UnifiedCatalogPolicies passed -HasDrift $false, ' +
                'so portal-wins never skipped, the policy conjunct was false, THE GATE NEVER FIRED, and a permissions surface was overwritten ' +
                'with no confirmation. Offending condition(s): ' + (($offenders | ForEach-Object { "`"$_`"" }) -join '; ')
            )
        }

        # ================= B2: THE GATE'S LIST (issue #103) =================
        #
        # Everything above proves the gate is WIRED and its CONDITION is honest.
        # These three prove the LIST that condition counts is honest too.

        It 'anchors the audit carve-out: -DirectionPolicy declares EXACTLY audit/portal-wins/repo-wins' {
            # Rules (b) and (c) both rest on ONE stated carve-out: `audit` is the
            # sanctioned NON-WRITING mode; portal-wins and repo-wins BOTH write.
            # That is the whole reason `-ne 'audit'` may gate the list's population
            # and `-eq 'repo-wins'` may not. The carve-out is derived from the
            # script's own ValidateSet and re-verified here on every run, so adding
            # a FOURTH policy value fails LOUDLY and demands an owner ruling instead
            # of silently widening the whitelist.
            if ($script:ExpectedGates -eq 1) {
                Set-ItResult -Skipped -Because 'Class B: declares no -DirectionPolicy, so it has no overwrite branch and no policy carve-out'
                return
            }
            $values = @(Get-DirectionPolicyValueSet -Ast $script:Ast)
            ($values | Sort-Object) -join ',' | Should -BeExactly 'audit,portal-wins,repo-wins' `
                -Because 'the whitelist in rules (b)/(c) is "exactly the WRITING policies". If the policy vocabulary changes, an owner must decide which of the new values write BEFORE the guard can be trusted again.'
        }

        It 'rule (a): the OVERWRITE gate''s list is APPEND-ONLY -- never cleared, reassigned or aliased' {
            if ($script:ExpectedGates -eq 1) {
                Set-ItResult -Skipped -Because 'Class B: prune only, no overwrite gate and no overwrite list'
                return
            }

            # ---- NON-VACUITY, and it is stronger than $GateCalls.Count. ----
            # This rule iterates "everything that touches the overwrite list". If the
            # LIST fails to resolve -- the $script:RepoWinsOverwrites / UserPath trap --
            # every foreach below iterates nothing and the It passes GREEN while
            # asserting nothing. State the population FIRST: the gate exists, the list
            # RESOLVED to a name, and it has at least one site that puts items in it.
            $overwriteGate = @($script:GateCalls | Where-Object { (Get-BoundQueryVariableName -GateCall $_) -eq 'overwriteQuery' })
            $overwriteGate.Count | Should -Be 1 -Because 'a claim about "the overwrite gate''s list" is vacuous if there is no overwrite gate'

            $listName = Get-GateListVariableName -GateCall $overwriteGate[0]
            $listName | Should -Not -BeNullOrEmpty -Because (
                'the overwrite list must be DERIVED from the gate: gate call -> guarding `if` -> the `.Count` member -> its variable. ' +
                'If it does not resolve, the gate counts something this guard cannot follow (a local `$n = $ow.Count`, or two lists OR-ed together) ' +
                'and every assertion in this It would iterate an empty set and pass green. Fail closed.'
            )

            $population = 0
            $findings = @(Get-ListIntegrityFinding -Ast $script:Ast -ListName $listName `
                    -PolicyValues (Get-DirectionPolicyValueSet -Ast $script:Ast) -PopulationSiteCount ([ref]$population))

            $population | Should -BeGreaterThan 0 -Because (
                "nothing in $($script:ScriptName) puts anything INTO `$$listName. Either the guard failed to resolve the list " +
                '(green by absence -- exactly what this assertion exists to prevent) or the gate counts a list that is never populated, ' +
                'which means the gate can never fire.'
            )

            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -Be 0 -Because (
                "the overwrite gate's list is a hand-maintained SHADOW of the write plan, not the plan itself. Shrink it and the gate goes SILENT while " +
                "the Set-* writes proceed -- that is B2, and it is behaviourally identical to the #83 bug the gate exists to fix. So `$$listName is " +
                'APPEND-ONLY between construction and gate. ABSOLUTE: no policy carve-out -- an UNCONDITIONAL .Clear() is exactly as silent as a ' +
                'policy-keyed one. Finding(s): ' + (($findings | Where-Object { $_.Rule -eq 'a' } | ForEach-Object { "line $($_.Line): '$($_.Text)' -- $($_.Why)" }) -join ' | ')
            )
        }

        It 'rule (b): the overwrite list''s POPULATION may not discriminate between two WRITING policies' {
            if ($script:ExpectedGates -eq 1) {
                Set-ItResult -Skipped -Because 'Class B: prune only, no overwrite gate and no overwrite list'
                return
            }

            $overwriteGate = @($script:GateCalls | Where-Object { (Get-BoundQueryVariableName -GateCall $_) -eq 'overwriteQuery' })
            $overwriteGate.Count | Should -Be 1 -Because 'a claim about "the overwrite list''s population" is vacuous if there is no overwrite gate'

            $listName = Get-GateListVariableName -GateCall $overwriteGate[0]
            $listName | Should -Not -BeNullOrEmpty -Because 'the list must resolve, or the population loop below iterates nothing and passes green'

            $population = 0
            $findings = @(Get-ListIntegrityFinding -Ast $script:Ast -ListName $listName `
                    -PolicyValues (Get-DirectionPolicyValueSet -Ast $script:Ast) -PopulationSiteCount ([ref]$population))

            $population | Should -BeGreaterThan 0 -Because 'a rule about "every .Add() to the list" is vacuous if the guard found no .Add()'

            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -Be 0 -Because (
                '`audit` is the sanctioned NON-WRITING mode; `portal-wins` and `repo-wins` BOTH write. A policy test guarding the list''s population may ' +
                'therefore separate the writing modes from `audit` and do NOTHING ELSE -- truth set exactly {portal-wins, repo-wins}. ' +
                'For example `if ($DirectionPolicy -eq ''repo-wins'')` has truth set {repo-wins}: under portal-wins the list stays empty, the plan-keyed ' +
                'gate sees zero, the gate NEVER FIRES, and the overwrite proceeds unconfirmed. That is B2, and seven ungated reconcilers already carry ' +
                'that exact `if` around a Write-Warning, waiting for PR-B to drop an .Add() into it. Finding(s) below name the ACTUAL condition: ' +
                (($findings | Where-Object { $_.Rule -eq 'b' } | ForEach-Object { "line $($_.Line): '$($_.Text)' -- $($_.Why)" }) -join ' | ')
            )
        }

        It 'rule (c): the PRUNE gate''s list is append-only too -- pinning the immunity (a)/(b) rely on' {
            # Rules (a)/(b) can ignore the prune gate ONLY because the prune list IS
            # the delete loop's source (Labels) or is derived from the plan at the
            # gate with zero lifetime (FilePlan / DLP / UCP): shrink it and the
            # DELETES vanish with the gate. PR-B must not be able to quietly break
            # that. One carve-out, and its reason is re-verified against source.
            $pruneGate = @($script:GateCalls | Where-Object { (Get-BoundQueryVariableName -GateCall $_) -eq 'pruneQuery' })
            $pruneGate.Count | Should -Be 1 -Because 'a claim about "the prune gate''s list" is vacuous if there is no prune gate'

            $listName = Get-GateListVariableName -GateCall $pruneGate[0]
            $listName | Should -Not -BeNullOrEmpty -Because 'the prune list must resolve from the gate, or this assertion iterates nothing and passes green'

            # NOTE: no population-count assertion here, and that is deliberate, not an
            # oversight. Three of the four prune lists are built by a PIPELINE
            # (`@($plan | Where-Object Action -eq 'Orphan')`) and have zero .Add()
            # sites -- which is precisely WHY they are immune. Demanding a population
            # site here would false-fail the safe shape.
            # A Class B script declares no -DirectionPolicy at all, so it has no
            # policy vocabulary and no policy gating condition can exist in it. The
            # append-only half of rule (c) still applies, and the audit carve-out is
            # simply unreachable there -- which is correct: with no policy, there is
            # no audit short-circuit to carve out for.
            # THE @($null).Count TRAP -- and it made this whole rule CRASH on Class B.
            #
            # Get-DirectionPolicyValueSet returns $null for a Class B script (no
            # -DirectionPolicy param). `@($null)` is an array of ONE ELEMENT whose
            # value is $null, so its .Count is 1, NOT 0. The Class-B fallback on the
            # next line was therefore DEAD CODE, $null was passed straight through to
            # a [Parameter(Mandatory)][string[]] parameter, and rule (c) died with
            #   ParameterBindingValidationException: Cannot bind argument to parameter
            #   'PolicyValues' because it is an empty string.
            # on every Class B script -- which nobody noticed, because the -ForEach
            # list was hardcoded to four Class A scripts and rule (c) never once ran
            # against a Class B one. The vacuity was hiding the crash.
            #
            # Filter the pipeline instead of counting the wrapper: `$null | Where-Object { $_ }`
            # emits nothing, so an ungated-by-policy script yields a genuinely EMPTY
            # array and the fallback fires. Same trap, same shape, one level up: a
            # $script: variable set in BeforeDiscovery reads back as $null during Run,
            # and @($null).Count would have said 1 there too.
            $policyValues = @(Get-DirectionPolicyValueSet -Ast $script:Ast | Where-Object { $_ })
            if ($policyValues.Count -eq 0) { $policyValues = @('audit') }

            $population = 0
            $findings = @(Get-ListIntegrityFinding -Ast $script:Ast -ListName $listName `
                    -PolicyValues $policyValues `
                    -PopulationSiteCount ([ref]$population) -AllowAuditEmptying)

            $findings.Count | Should -Be 0 -Because (
                "the prune gate's list `$$listName is append-only, with EXACTLY ONE carve-out: emptying it inside the ADR 0029 audit short-circuit. " +
                'That carve-out is granted only on the grounds that the same block is a total no-write short-circuit -- it also empties the ' +
                'write plan (`$plan.Clear()`) -- and this assertion RE-VERIFIES that reason against source rather than trusting a comment. ' +
                'Delete the `$plan.Clear()` line and this goes RED, since audit mode would then apply creates and updates. Finding(s): ' +
                (($findings | ForEach-Object { "line $($_.Line): '$($_.Text)' -- $($_.Why)" }) -join ' | ')
            )
        }

        # Content checks on the prompt text. These are deliberately anchored to
        # the QUERY ASSIGNMENT and matched CASE-SENSITIVELY (-CMatch), so a
        # lowercase comment cannot satisfy them -- see the header note. They
        # assert what the operator READS; the AST assertions above assert that
        # the gate is WIRED. Both are needed and neither substitutes.
        It 'the overwrite query names the count and the irreversible effect' {
            # Class B has no overwrite branch -- correctly, so it has no $overwriteQuery
            # to assert on. Every other Class-A-only It in this Context carries this
            # guard; this one did not, because the -ForEach list was hardcoded to four
            # Class A scripts and no Class B script ever reached it.
            if ($script:ExpectedGates -eq 1) {
                Set-ItResult -Skipped -Because 'Class B: prune only, so there is no overwrite branch and no $overwriteQuery'
                return
            }
            $script:Text | Should -CMatch '\$overwriteQuery\s*=\s*"This run will OVERWRITE'
        }

        It 'the prune query names the count and the irreversible effect' {
            $script:Text | Should -CMatch '\$pruneQuery\s*=\s*"-PruneMissing will (DELETE|REVOKE)'
        }
    }
}

Describe 'ADR 0052: CI cannot hang -- every workflow invocation of a GATED script binds a suppressor' {

    # See the extended note on the CI-hang scanner in the file-level BeforeAll for
    # WHY this is derived and why -Force is NOT a suppressor.
    #
    # In one line: the previous version of this Describe drove a -ForEach from a
    # hardcoded list of FOUR workflows and checked invocations of TWO scripts.
    # Twenty are gated. Eighteen were unexamined. This one derives the gated set
    # from the AST, scans EVERY run: block in EVERY workflow, and states its
    # population before asserting anything about it.

    BeforeAll {
        $script:CiGated = @(Get-GatedReconciler)
        $script:CiScan = Get-CiHangScan -GatedScripts $script:CiGated
        $script:CiSites = @($script:CiScan.Sites)
    }

    # ---------------- NON-VACUITY. Assert the population FIRST. ----------------
    #
    # A scanner that matches nothing passes green and asserts nothing. Every count
    # this guard depends on is named and floored, so the guard cannot quietly
    # degrade into a no-op the way its predecessor did.

    It 'found the gated scripts to scan for (a scan for nothing proves nothing)' {
        $script:CiGated.Count | Should -BeGreaterThan 0 -Because 'the gated set is derived from the AST; zero means the derivation broke and every assertion below is vacuous'
        # The gated set is derived twice in this file (here and in the AST-contract
        # BeforeDiscovery). The completion Describe pins that they agree.
        $script:CiGated.Count | Should -Be 23 -Because (
            'all twenty-three destructive-capable reconcilers are gated -- #108 widened the population from a ' +
            'Deploy-*.ps1 filename glob to every script declaring -PruneMissing, adding Set-AuditRetentionPolicy.ps1 as the ' +
            '22nd; #105 then closed the last declared exception, Deploy-EntraDirectoryRoles.ps1, by restructuring it to a ' +
            'two-phase (plan-then-apply) shape so its ADR 0052 gate can see the full revoke plan before any tenant write; ' +
            'issue #48 added Deploy-SITRulePackages.ps1 (custom SIT rule packages, ADR 0061) as the 23rd. ' +
            "Found: $($script:CiGated.Count) -- [$($script:CiGated -join ', ')]."
        )
    }

    It 'read the workflows and found run: blocks to examine' {
        $script:CiScan.TotalBlocks | Should -BeGreaterThan 0 -Because 'the run:-block extractor returned nothing -- it is broken, and a broken extractor makes this whole Describe green by absence'
        $script:CiScan.CandidateBlocks | Should -BeGreaterThan 0 -Because 'no run: block anywhere in .github/workflows mentions a reconciler. Either the extractor is broken or the workflows stopped calling the scripts.'
    }

    It 'parsed every candidate run: block (an unparseable block is a hole, not a pass)' {
        @($script:CiScan.ParseFailures).Count | Should -Be 0 -Because (
            'a run: block that mentions a reconciler but does not parse as PowerShell is a block this scanner CANNOT see into. ' +
            'Skipping it would be green-by-absence. Failure(s): ' +
            (($script:CiScan.ParseFailures | ForEach-Object { "$($_.File):$($_.Line) -- $($_.Why)" }) -join ' | ')
        )
    }

    It 'found CI invocation sites to check' {
        $script:CiSites.Count | Should -BeGreaterThan 0 -Because (
            'the scanner found ZERO invocations of ZERO gated scripts across every workflow. That is not a pass -- the repo demonstrably ' +
            'invokes these reconcilers from CI. It means the AST matcher is broken and every suppressor assertion below iterates an empty set.'
        )
    }

    # ---- THE GLOB-DISPATCH FLOOR. The shape most likely to be silently skipped. ----
    #
    # drift-detection.yml runs EVERY gated reconciler, weekly, on a hosted runner,
    # via `& $script.FullName -WhatIf` over a Get-ChildItem glob. The command name
    # is an expression, so a scanner that only matches literal script paths finds
    # nothing here -- and passes. This floor is what makes "the scanner handles the
    # glob loop" a tested claim rather than a comment.
    It 'MATCHES the drift-detection glob-loop shape (& $script.FullName over a Deploy-*.ps1 glob)' {
        $glob = @($script:CiSites | Where-Object { $_.Kind -eq 'glob-dispatch' })

        $glob.Count | Should -BeGreaterThan 0 -Because (
            'the scanner recognised NO glob-dispatch invocation. .github/workflows/drift-detection.yml enumerates scripts/Deploy-*.ps1 and ' +
            'runs each one with `& $script.FullName -WhatIf` -- the single widest-reaching CI invocation in the repo, hitting all twenty gated ' +
            'scripts weekly. A scanner that cannot see it reports zero findings there and passes green while asserting nothing. If that workflow ' +
            'was deliberately removed, delete this assertion CONSCIOUSLY -- do not let it rot into a no-op.'
        )

        foreach ($g in $glob) {
            # It must be charged with ALL of them, not one of them.
            @($g.Targets).Count | Should -Be $script:CiGated.Count -Because (
                "the glob dispatch at $($g.File):$($g.Line) invokes whatever the glob matched, which this guard cannot resolve statically. " +
                'It must therefore be charged with EVERY gated script (fail closed), not with none of them.'
            )
        }
    }

    # ---------------- THE CONTRACT ITSELF ----------------

    It 'binds -Confirm:$false or -WhatIf on EVERY invocation of EVERY gated script' {
        $script:CiSites.Count | Should -BeGreaterThan 0 -Because 'an assertion about "every invocation" is vacuous if there are no invocations'

        $naked = @($script:CiSites | Where-Object { @($_.Suppressors).Count -eq 0 })

        $naked.Count | Should -Be 0 -Because (
            'every gated reconciler prompts UNCONDITIONALLY at its ADR 0052 gate (ShouldContinue ignores $ConfirmPreference) and prompts at ' +
            "every `$PSCmdlet.ShouldProcess(...) too, now that ConfirmImpact is 'High'. A CI invocation that binds neither -Confirm:`$false nor " +
            '-WhatIf therefore HANGS the runner the moment it reaches a destructive branch, with nobody able to answer. ' +
            "NOTE: -Force is NOT accepted here -- it silences the gate but not ShouldProcess (ADR 0053 section 4 removed the ambient self-disarm), " +
            'so an invocation carrying only -Force still hangs. Unsuppressed invocation(s): ' +
            (($naked | ForEach-Object { "$($_.File):$($_.Line) [$($_.Kind)] '$($_.Command)'" }) -join ' | ')
        )
    }

    # ---- FALSE-POSITIVE FLOOR. A guard that cries wolf gets deleted. ----
    #
    # validate.yml:188-197 holds eight gated script names as STRING LITERALS in an
    # $exempt array, consumed by Get-Content + regex. They are not invocations, and
    # flagging them would make this guard a nuisance that the next author silences
    # by weakening it. Probes, not a hardcoded allow-list for validate.yml, so the
    # claim is about the SCANNER and not about one file.
    Context 'the scanner distinguishes an invocation from a mention (probes)' {

        BeforeAll {
            $script:Probe = {
                param([string]$Text)
                $failures = [System.Collections.Generic.List[object]]::new()
                $block = [pscustomobject]@{ File = 'probe.yml'; Line = 1; Text = $Text }
                @(Get-CiInvocationSite -Block $block -GatedScripts @('Deploy-Labels.ps1') -ParseFailure ([ref]$failures))
            }
        }

        It 'does NOT flag a script name used as a string literal (the validate.yml $exempt shape)' {
            $sites = & $script:Probe @"
`$exempt = @(
    'Deploy-Labels.ps1',
    'Deploy-Classifications.ps1'
)
Get-ChildItem -Path scripts -Filter 'Deploy-*.ps1' | ForEach-Object {
    if (`$exempt -contains `$_.Name) { return }
}
"@
            @($sites).Count | Should -Be 0 -Because 'a StringConstantExpressionAst inside an array literal is a MENTION, not a CommandAst. Flagging it would be a false positive on validate.yml.'
        }

        It 'DOES flag a direct invocation that binds no suppressor' {
            $sites = & $script:Probe './scripts/Deploy-Labels.ps1 -DirectionPolicy repo-wins'
            @($sites).Count | Should -Be 1
            @($sites[0].Suppressors).Count | Should -Be 0
        }

        It 'accepts -Confirm:$false, and -WhatIf, as suppressors' {
            @((& $script:Probe './scripts/Deploy-Labels.ps1 -Confirm:$false')[0].Suppressors).Count | Should -BeGreaterThan 0
            @((& $script:Probe './scripts/Deploy-Labels.ps1 -WhatIf')[0].Suppressors).Count | Should -BeGreaterThan 0
        }

        It 'REJECTS -Force as a suppressor (it silences the gate, not ShouldProcess)' {
            # The one place this guard contradicts the rollout brief. See the
            # BeforeAll note: verified against a live ConfirmImpact='High' probe --
            # `-Force` alone THROWS in a non-interactive host rather than proceeding.
            @((& $script:Probe './scripts/Deploy-Labels.ps1 -Force')[0].Suppressors).Count | Should -Be 0 `
                -Because '-Force is a custom switch. It suppresses ConfirmGate and does nothing whatever to $PSCmdlet.ShouldProcess, which consults only $ConfirmPreference.'
        }

        It 'REJECTS an explicit -Confirm:$true' {
            @((& $script:Probe './scripts/Deploy-Labels.ps1 -Confirm:$true')[0].Suppressors).Count | Should -Be 0
        }

        It 'reads Confirm = $false out of a splatted hashtable' {
            $sites = & $script:Probe @"
`$applyArgs = @{
    DirectionPolicy = 'portal-wins'
    Confirm         = `$false
}
./scripts/Deploy-Labels.ps1 @applyArgs
"@
            @($sites).Count | Should -Be 1
            @($sites[0].Suppressors).Count | Should -BeGreaterThan 0
        }

        It 'does NOT accept a splat whose hashtable omits Confirm' {
            $sites = & $script:Probe @"
`$applyArgs = @{ DirectionPolicy = 'repo-wins' }
./scripts/Deploy-Labels.ps1 @applyArgs
"@
            @($sites).Count | Should -Be 1
            @($sites[0].Suppressors).Count | Should -Be 0
        }

        It 'matches the glob-dispatch shape and charges it with every gated script' {
            $sites = & $script:Probe @"
`$reconcilers = Get-ChildItem -Path scripts/Deploy-*.ps1 | Where-Object {
    (Get-Content `$_.FullName -Raw) -match 'SupportsShouldProcess'
}
foreach (`$s in `$reconcilers) {
    `$output = & `$s.FullName -WhatIf 2>&1 | Out-String
}
"@
            @($sites).Count | Should -Be 1
            $sites[0].Kind | Should -BeExactly 'glob-dispatch'
            @($sites[0].Suppressors) | Should -Contain '-WhatIf'
        }

        It 'flags a glob dispatch that binds NO suppressor' {
            $sites = & $script:Probe @"
`$reconcilers = Get-ChildItem -Path scripts/Deploy-*.ps1
foreach (`$s in `$reconcilers) { & `$s.FullName -DirectionPolicy repo-wins }
"@
            @($sites).Count | Should -Be 1
            @($sites[0].Suppressors).Count | Should -Be 0 -Because 'the weekly glob loop is exactly where an unsuppressed invocation would hang for six hours before the job timed out'
        }
    }
}

Describe 'ADR 0052 gate keying: key on the PLAN, never on the POLICY (#83)' {

    # THE DISCRIMINATING TEST for the #83 design correction.
    #
    # The ADR 0052 reference implementations originally keyed the overwrite gate
    # on a CONJUNCTION:
    #
    #     if ($DirectionPolicy -eq 'repo-wins' -and $overwrites.Count -gt 0)
    #
    # That policy conjunct is either redundant or dangerous, and never useful:
    #
    #   * REDUNDANT wherever portal-wins genuinely skips drifted objects -- the
    #     overwrite list can then only populate under repo-wins anyway.
    #   * DANGEROUS wherever it does not. Deploy-UnifiedCatalogPolicies.ps1
    #     passed a hardcoded `-HasDrift $false` into Resolve-DirectionPolicyAction,
    #     which only skips when `$HasDrift -and $Policy -eq 'portal-wins'`. So
    #     portal-wins never skipped: the overwrite list populated, the policy
    #     conjunct evaluated FALSE, THE GATE NEVER FIRED, and a PERMISSIONS
    #     surface was overwritten with no confirmation.
    #
    # The discriminating input is therefore: portal-wins AND a non-empty
    # overwrite plan. Policy-keying does not fire on it. Plan-keying does.
    #
    # NOTE ON NON-VACUITY, stated honestly. That input state was REACHABLE on
    # pre-fix 1d4f855 through Deploy-UnifiedCatalogPolicies' real plan pipeline
    # -- that is the historical RED replay in the PR body. The F4 fix in this
    # same change closes that reachability, and an audit of all 12 Class A
    # call sites found UCP was the only script whose HasDrift was wrong. So
    # after this PR, no CURRENT pipeline can reach the divergent state, and this
    # test is a LATENT guard, not an active one: it fires the moment anyone
    # reintroduces policy-keying, or lands a HasDrift bug like F4 again. That is
    # worth having -- it is the same reason ADR 0052 chose ShouldContinue over
    # ShouldProcess, and ADR 0053 made Test-ConflictRow pure: THE GUARD MUST NOT
    # DEPEND ON A NEGOTIABLE PROXY. It is not sold as catching a live bug.

    BeforeAll {
        # The two candidate keying rules, isolated. Everything else is held equal.
        function Test-GateFires_PolicyKeyed {
            param([string]$DirectionPolicy, [string[]]$Overwrites)
            return (($DirectionPolicy -eq 'repo-wins') -and ($Overwrites.Count -gt 0))
        }
        # $DirectionPolicy is deliberately UNUSED here, and PSSA is right that it
        # is: THAT IS THE ENTIRE INVARIANT. Plan-keying does not consult the
        # policy. The parameter is kept so both keyings share one signature and
        # Measure-GatePrompt can call them interchangeably -- if it were removed,
        # the two rules could not be compared against identical inputs.
        function Test-GateFires_PlanKeyed {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DirectionPolicy',
                Justification = 'Deliberately unconsulted: plan-keying ignores the direction policy. That is the invariant under test.')]
            param([string]$DirectionPolicy, [string[]]$Overwrites)
            return ($Overwrites.Count -gt 0)
        }

        # Drive the REAL gate and count the prompts it actually raises.
        function Measure-GatePrompt {
            param([scriptblock]$Keying, [string]$DirectionPolicy, [string[]]$Overwrites)
            $stub = Get-StubCmdlet -Answer $true
            $yes = $false
            $no = $false
            if (& $Keying -DirectionPolicy $DirectionPolicy -Overwrites $Overwrites) {
                Assert-DestructiveOperationConfirmed `
                    -Cmdlet $stub `
                    -Caption 'Destructive operation (ADR 0052)' `
                    -Query ("This run will OVERWRITE {0} object(s): {1}. Continue?" -f $Overwrites.Count, ($Overwrites -join ', ')) `
                    -YesToAll ([ref]$yes) -NoToAll ([ref]$no) | Out-Null
            }
            return $stub.Calls.Count
        }
    }

    Context 'the discriminating case: portal-wins with a NON-EMPTY overwrite plan' {

        # If this ever passes under BOTH keyings, the correction is theatre and
        # the rollout is unsafe. It must be RED against policy-keying.
        It 'PLAN-keyed  -> the gate FIRES (the objects are being overwritten, so ask)' {
            $prompts = Measure-GatePrompt `
                -Keying ${function:Test-GateFires_PlanKeyed} `
                -DirectionPolicy 'portal-wins' `
                -Overwrites @('Finance / Governance Domain Owner', 'HR / Governance Domain Reader')

            $prompts | Should -Be 1 -Because 'the plan says two objects WILL be overwritten; the policy that let them through is irrelevant'
        }

        It 'POLICY-keyed -> the gate stays SILENT (this is the defect; pinned so it stays dead)' {
            $prompts = Measure-GatePrompt `
                -Keying ${function:Test-GateFires_PolicyKeyed} `
                -DirectionPolicy 'portal-wins' `
                -Overwrites @('Finance / Governance Domain Owner', 'HR / Governance Domain Reader')

            $prompts | Should -Be 0 -Because 'this is exactly the vacuous pass the plan-keying rule exists to prevent -- a guard that can pass vacuously is worse than no guard, because it is believed'
        }
    }

    Context 'the two keyings agree everywhere else (so the difference is the defect, not a behaviour change)' {

        It 'repo-wins + non-empty plan -> BOTH fire' {
            $ow = @('Finance / Governance Domain Owner')
            (Measure-GatePrompt -Keying ${function:Test-GateFires_PlanKeyed} -DirectionPolicy 'repo-wins' -Overwrites $ow) | Should -Be 1
            (Measure-GatePrompt -Keying ${function:Test-GateFires_PolicyKeyed} -DirectionPolicy 'repo-wins' -Overwrites $ow) | Should -Be 1
        }

        It 'empty overwrite plan -> NEITHER fires, under either policy' -ForEach @('portal-wins', 'repo-wins') {
            (Measure-GatePrompt -Keying ${function:Test-GateFires_PlanKeyed} -DirectionPolicy $_ -Overwrites @()) | Should -Be 0
            (Measure-GatePrompt -Keying ${function:Test-GateFires_PolicyKeyed} -DirectionPolicy $_ -Overwrites @()) | Should -Be 0
        }
    }

    Context 'the invariant, stated positively' {

        # Plan-keying's defining property: the gate fires IFF the plan is
        # non-empty. The policy is not an input. Table-driven so a future
        # reader can see there is no policy value that suppresses the prompt.
        It 'fires on a non-empty overwrite plan under <_> -- the policy is NOT an input to the decision' -ForEach @('portal-wins', 'repo-wins') {
            $prompts = Measure-GatePrompt `
                -Keying ${function:Test-GateFires_PlanKeyed} `
                -DirectionPolicy $_ `
                -Overwrites @('Some / Object')

            $prompts | Should -Be 1
        }
    }
}

Describe 'The B2 guard is NOT VACUOUS: it goes RED on every B2 shape (#103)' {

    # THE RED REPLAY, MADE PERMANENT.
    #
    # The four gated scripts are CLEAN, so every assertion above passes with zero
    # findings -- and a guard that only ever reports zero is indistinguishable from
    # a guard that cannot report anything at all. Sixteen guards in this repo would
    # have passed while protecting nothing; the one thing that separates a real
    # guard from theatre is watching it go RED against the broken state.
    #
    # A red replay done once, by hand, in a terminal, protects nothing tomorrow.
    # These run the SAME analyzer functions the per-script assertions run, against
    # synthetic ASTs carrying each B2 shape, on every CI run. If someone weakens
    # Get-ListIntegrityFinding into a no-op, THESE go red -- not the per-script
    # assertions, which would happily keep reporting zero.
    #
    # The last Context is the other direction: the CORRECT shapes must stay GREEN,
    # or the guard is just noise a future author will delete.

    BeforeAll {
        # A miniature reconciler in the shape of the four real ones: construct the
        # overwrite list; populate it under the sanctioned `-ne 'audit'` test; gate
        # on its .Count. The two slots are where each mutant is injected.
        function Get-ProbeAst {
            param(
                [string]$Construction = '$repoWinsOverwrites = New-Object ''System.Collections.Generic.List[string]''',
                [string]$Population = 'if ($DirectionPolicy -ne ''audit'') { $repoWinsOverwrites.Add($row.Name) }',
                [string]$Mutation = ''
            )
            $src = @"
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]`$DirectionPolicy = 'portal-wins',
    [switch]`$PruneMissing,
    [switch]`$Force
)
$Construction
foreach (`$row in `$plan) {
    $Population
}
$Mutation
if (`$repoWinsOverwrites.Count -gt 0) {
    `$overwriteQuery = "This run will OVERWRITE {0} object(s)." -f `$repoWinsOverwrites.Count
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query `$overwriteQuery)) {
        throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
    }
}
"@
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) {
                throw ('probe source does not parse: ' + (($errors | ForEach-Object { $_.Message }) -join '; '))
            }
            return $ast
        }

        # Runs the REAL analyzer, resolving the list the REAL way (from the gate).
        function Get-ProbeFinding {
            param([Parameter(Mandatory)]$Ast)
            $gate = @(Get-GateCallAst -Ast $Ast) | Select-Object -First 1
            if (-not $gate) { throw 'probe has no gate call -- the probe itself is broken' }
            $listName = Get-GateListVariableName -GateCall $gate
            if (-not $listName) { throw 'probe gate list did not resolve -- the probe itself is broken' }
            $population = 0
            return @(Get-ListIntegrityFinding -Ast $Ast -ListName $listName `
                    -PolicyValues (Get-DirectionPolicyValueSet -Ast $Ast) -PopulationSiteCount ([ref]$population))
        }
    }

    Context 'rule (a) -- the overwrite list is APPEND-ONLY' {

        It 'mutant (i): .Clear() under a policy test -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation 'if ($DirectionPolicy -ne ''repo-wins'') { $repoWinsOverwrites.Clear() }')
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }

        It 'mutant (ii): reassignment to @() under a policy test -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation 'if ($DirectionPolicy -ne ''repo-wins'') { $repoWinsOverwrites = @() }')
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }

        # THE MUTANT THE ORIGINALLY-AGREED DESIGN LET THROUGH. Rule (a) was first
        # specified as "no shrink under a POLICY-KEYED condition" -- which passes an
        # unconditional .Clear() straight through, and an unconditional .Clear() is
        # exactly as silent and exactly as fatal. Hence: absolute, no carve-out.
        It 'mutant (iv): an UNCONDITIONAL .Clear() before the gate -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation '$repoWinsOverwrites.Clear()')
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }

        It 'mutant (a4): .RemoveAt() -> RED (the whitelist admits no shrinking method)' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation '$repoWinsOverwrites.RemoveAt(0)')
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }

        # A .NET list is a REFERENCE type. `$alias.Clear()` empties the gate's list
        # under a name a whole-script scan for `$repoWinsOverwrites` never sees.
        It 'mutant (a5): a bare ALIAS, then .Clear() on the alias -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation "`$alias = `$repoWinsOverwrites`n`$alias.Clear()")
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }

        # The same reference-aliasing hole, hidden behind a PARAMETER instead of an
        # assignment. Rule (a) refuses the handoff rather than trying to follow it.
        It 'mutant (a6): the list handed to a locally-defined function that clears it -> RED' {
            $mutation = "function Reset-It { param(`$L) `$L.Clear() }`nif (`$DirectionPolicy -ne 'repo-wins') { Reset-It `$repoWinsOverwrites }"
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Mutation $mutation)
            @($findings | Where-Object { $_.Rule -eq 'a' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'rule (b) -- the population may not discriminate between two WRITING policies' {

        # B2's population form, and the one PR-B will write by accident: seven
        # ungated reconcilers already carry this exact `if` around a Write-Warning.
        It 'mutant (iii): .Add() wrapped in if ($DirectionPolicy -eq ''repo-wins'') -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if ($DirectionPolicy -eq ''repo-wins'') { $repoWinsOverwrites.Add($row.Name) }')
            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        # Truth set {audit, repo-wins}: EXCLUDES portal-wins, which writes. A
        # blacklist of "-eq 'repo-wins'" fails OPEN here. The whitelist does not.
        It 'mutant (v): .Add() under -ne ''portal-wins'' -> RED (whitelist fails CLOSED where a blacklist fails OPEN)' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if ($DirectionPolicy -ne ''portal-wins'') { $repoWinsOverwrites.Add($row.Name) }')
            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        # The policy is not in an `if` at all -- it is in the loop's SOURCE. A walk
        # that only inspected `if` conditions would never see it.
        It 'mutant (b3): policy laundered through the foreach SOURCE -> RED (uncomputable, fails closed)' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Population 'foreach ($x in ($plan | Where-Object { $DirectionPolicy -eq ''repo-wins'' })) { $repoWinsOverwrites.Add($x) }')
            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        It 'mutant (b4): policy laundered through a switch -> RED' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Population 'switch ($DirectionPolicy) { ''repo-wins'' { $repoWinsOverwrites.Add($row.Name) } }')
            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        # The policy is entangled with another variable, so no sub-expression has a
        # computable truth set. Evaluating only the readable half would fail OPEN.
        It 'mutant (b5): policy compared to another VARIABLE -> RED (uncomputable, fails closed)' {
            $findings = Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if ($DirectionPolicy -ne ''audit'' -and $mode -eq $DirectionPolicy) { $repoWinsOverwrites.Add($row.Name) }')
            @($findings | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        # The list is never .Add()-ed to; it is CONSTRUCTED from a policy-filtered
        # pipeline. One assignment, so rule (a) is satisfied -- rule (b) is what
        # catches it, by policy-checking the construction's own right-hand side.
        It 'mutant (b6): the list CONSTRUCTED from a policy-filtered pipeline -> RED' {
            $src = Get-ProbeAst `
                -Construction '$repoWinsOverwrites = @($plan | Where-Object { $DirectionPolicy -eq ''repo-wins'' } | ForEach-Object { $_.Name })' `
                -Population '$null = $row'
            @(Get-ProbeFinding -Ast $src | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }

        # THE MOST LIKELY WAY PR-B ACTUALLY WRITES B2. The policy test is a SIBLING
        # of the .Add(), not an ancestor of it -- and the guard-clause idiom
        # (`if (...) { continue }`) is the one these scripts already use for every
        # plan filter, so it is the shape an author reaches for without thinking. A
        # walk that only inspected ENCLOSING `if` bodies would sail straight past
        # it. This is the mutant that justifies Test-TerminatingGuardClause.
        It 'mutant (b7): policy laundered through a `continue` GUARD CLAUSE -> RED' {
            $population = "if (`$DirectionPolicy -ne 'repo-wins') { continue }`n    `$repoWinsOverwrites.Add(`$row.Name)"
            @(Get-ProbeFinding -Ast (Get-ProbeAst -Population $population) | Where-Object { $_.Rule -eq 'b' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'the correct shapes stay GREEN (a guard that cries wolf gets deleted)' {

        It 'the reference shape -- .Add() under -ne ''audit'' -> zero findings' {
            @(Get-ProbeFinding -Ast (Get-ProbeAst)).Count | Should -Be 0
        }

        # Semantically identical to `-ne 'audit'`. A guard that isolated the SMALLEST
        # policy sub-expression would see `-eq 'audit'`, compute {audit}, and
        # false-fail this. The truth set is computed over the MAXIMAL policy-only
        # sub-expression precisely so that it does not.
        It 'the negated spelling -- -not ($DirectionPolicy -eq ''audit'') -> zero findings' {
            @(Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if (-not ($DirectionPolicy -eq ''audit'')) { $repoWinsOverwrites.Add($row.Name) }')).Count | Should -Be 0
        }

        It 'an else branch -- if ($DirectionPolicy -eq ''audit'') {} else { .Add() } -> zero findings' {
            @(Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if ($DirectionPolicy -eq ''audit'') { $null = $row } else { $repoWinsOverwrites.Add($row.Name) }')).Count | Should -Be 0
        }

        # A PLAN condition around the .Add() is not a policy condition and must not
        # be flagged: Deploy-FilePlan.ps1 uses exactly this shape.
        It 'a PLAN-keyed condition inside the policy gate -> zero findings' {
            @(Get-ProbeFinding -Ast (Get-ProbeAst -Population 'if ($DirectionPolicy -ne ''audit'') { if ($row.Action -eq ''Update'') { $repoWinsOverwrites.Add($row.Name) } }')).Count | Should -Be 0
        }

        # Deploy-UnifiedCatalogPolicies' REAL shape: audit mode is an early `return`
        # guard clause before the population loop, so the .Add() sits under NO
        # enclosing policy `if` at all. Read as a negation, that guard clause is
        # `-ne 'audit'` -- truth set {portal-wins, repo-wins} -- and must be GREEN.
        # The same machinery that catches mutant (b7) is what proves this sound;
        # if it false-failed here, the guard would be unusable on UCP.
        It 'a policy guard clause that EXCLUDES audit (UCP''s early-return shape) -> zero findings' {
            $construction = "if (`$DirectionPolicy -eq 'audit') { `$plan.Clear(); return }`n" +
            "`$repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'"
            @(Get-ProbeFinding -Ast (Get-ProbeAst -Construction $construction -Population '$repoWinsOverwrites.Add($row.Name)')).Count | Should -Be 0
        }

        # The structural fix #103 recommends as a follow-up: derive the overwrite
        # list FROM THE PLAN. The guard must not stand in its way.
        It 'the structural fix -- list constructed from the plan, no policy -> zero findings' {
            $src = Get-ProbeAst `
                -Construction '$repoWinsOverwrites = @($plan | Where-Object { $_.Action -eq ''Update'' } | ForEach-Object { $_.Name })' `
                -Population '$null = $row'
            @(Get-ProbeFinding -Ast $src).Count | Should -Be 0
        }
    }
}

Describe 'ADR 0052 rollout completion (#83/#108): every reconciler gated, or declared' {

    # MUST RUN AFTER the AST-contract Describe: the coverage assertion below reads
    # $script:ContractExamined, which that Describe's Contexts fill in as they run.
    # Pester executes Describes in file order, so this stays last.

    BeforeAll {
        # Widened from a 'Deploy-*.ps1' filename glob to the destructive-capability
        # predicate (issue #108). See Get-DestructiveCapableScriptFile above -- this
        # is what turns "every Deploy-* reconciler is gated" into "every reconciler
        # that can delete or revoke tenant state is gated", closing the exact hole
        # the boundary note below used to name.
        $script:AllReconcilersOnDisk = @(Get-DestructiveCapableScriptFile | ForEach-Object { $_.Name } | Sort-Object)
        $script:GatedNow = @(Get-GatedReconciler)
        $script:ExemptNames = @($script:UngatedByDesign.Keys | Sort-Object)
    }

    # ---- THE BATCH'S OWN NON-VACUITY GUARD ----
    #
    # Everything in this batch rests on one claim: the AST contract now examines every
    # gated script. That claim is easy to assert and easy to get wrong -- the -ForEach
    # list is derived by a SECOND copy of the gate predicate, living in a
    # BeforeDiscovery block that cannot see the canonical helper. If the copies ever
    # diverge, the contract quietly shrinks back to a blind guard and every assertion
    # in it goes back to passing by absence.
    #
    # So do not assert the claim -- MEASURE it. $script:ContractExamined is what the
    # Contexts ACTUALLY ran against; Get-GatedReconciler is the canonical gated set.
    # They must be equal.
    It 'the AST contract examined EVERY gated script (the -ForEach list is derived, not curated)' {
        $examined = @($script:ContractExamined | Sort-Object)

        $examined.Count | Should -BeGreaterThan 0 -Because (
            'the AST-contract Describe examined NOTHING. Either its BeforeDiscovery derivation returned an empty list ' +
            '(in which case every assertion in it is vacuous) or this Describe ran without it. Fail closed.'
        )

        ($examined -join ', ') | Should -BeExactly ($script:GatedNow -join ', ') -Because (
            'the set of scripts the AST contract examined must equal the set of scripts that actually carry a gate. ' +
            'A gated script missing from the contract is a gated script whose wiring, query text, decline-throw, plan-keying and ' +
            'list-integrity rules NOBODY CHECKED -- which is exactly the state this file shipped in until PR-B batch 1.5: nine gated ' +
            'scripts, four examined, 149/149 green. ' +
            "Contract examined: [$($examined -join ', ')]. Actually gated: [$($script:GatedNow -join ', ')]."
        )
    }

    # ---- THE STALENESS GUARD ON THE CARVE-OUT. This must be GREEN. ----
    #
    # An exception nobody is forced to remove is how a "temporary" gap becomes
    # permanent. #105 gated Deploy-EntraDirectoryRoles.ps1 and, in the same PR,
    # deleted its entry from $script:UngatedByDesign -- had it gated the script
    # without deleting the entry, this assertion would have gone RED immediately,
    # which is precisely the bookkeeping enforcement this guard exists for. The
    # table is empty now; the next author who genuinely cannot gate a new
    # destructive-capable script states why here, and this guard keeps them honest.
    # NOTE ON SHAPE: a single It iterating the table, NOT `-ForEach $script:UngatedByDesign.Keys`.
    # -ForEach is evaluated during DISCOVERY, and $script:UngatedByDesign is defined in
    # the file-level BeforeAll, which runs during RUN -- so at discovery it is $null and
    # the It would silently expand to nothing. That is the same cross-phase trap as the
    # @($null).Count bug in rule (c), and it is worth naming twice: in this file, a
    # variable that is $null at the moment you use it does not fail loudly, it EXPANDS
    # TO NOTHING and passes green. An EMPTY table needs no assertions and is the desired
    # end state (#105 landed, nothing left to excuse), so there is no non-vacuity floor
    # here -- the completion criterion below is what refuses to let the table hide work.
    It 'the carve-out has not gone STALE: every declared-ungated script still carries ZERO gate calls' {
        foreach ($name in @($script:UngatedByDesign.Keys)) {
            $path = Join-Path $script:RepoRoot 'scripts' $name

            Test-Path -LiteralPath $path | Should -BeTrue -Because (
                "the carve-out names '$name', but no such script exists. A carve-out for a script that is not there excuses nothing, " +
                'and it hides whatever the script was renamed to. Update $script:UngatedByDesign.'
            )

            @(Get-GateCallAst -Ast (Get-ScriptAstOrThrow -Path $path)).Count | Should -Be 0 -Because (
                "'$name' is carved OUT of the #83 completion criterion on the stated grounds that it CANNOT yet be gated " +
                "($($script:UngatedByDesign[$name])). It now HAS a gate, so that reason is false and the carve-out is STALE -- " +
                'it is now suppressing real coverage. DELETE the entry from $script:UngatedByDesign: the completion criterion will ' +
                'then count this script, and the AST contract will examine it like every other gated reconciler.'
            )
        }
    }

    # ---- THE COMPLETION CRITERION. NOW GREEN -- KEEP IT THAT WAY. ----
    #
    # This assertion was EXPECTED RED through batches 1 and 2, by design: it was the
    # rollout's remaining work stated executably. Batch 2 gated the last eleven Class A
    # reconcilers and it turned GREEN. It is now a RATCHET, not a to-do list.
    #
    # #108 RE-OPENED IT ON PURPOSE. $script:AllReconcilersOnDisk was a `Deploy-*.ps1`
    # filename GLOB, so this criterion only ever proved "every DEPLOY-* reconciler is
    # gated" -- and `Set-AuditRetentionPolicy.ps1` (declares -PruneMissing, calls
    # Remove-UnifiedAuditLogRetentionPolicy, shipped ConfirmImpact = 'Medium' -- the
    # live issue #85 defect -- with NO gate and NO workflow behind it) was invisible to
    # it, and to every other count in #83, because its name is Set-*, not Deploy-*. The
    # glob was the bug: it silently narrowed "every reconciler" to "every reconciler
    # whose author remembered to name it Deploy-*". #108 widens the population (see
    # Get-DestructiveCapableScriptFile above) to a destructive-capability predicate --
    # every script under scripts/ that declares [switch]$PruneMissing -- which is
    # filename-agnostic by construction and picked this one up immediately: with the
    # population widened and the script still ungated, this assertion went RED, naming
    # Set-AuditRetentionPolicy.ps1 as the missing script. It is GREEN again now that
    # #108 has gated it.
    #
    # ⚠️ BOUNDARY -- READ BEFORE TRUSTING THE WORD "COMPLETE".
    # This criterion proves "every script that declares -PruneMissing is gated", NOT
    # "every script capable of a destructive tenant write is gated". A future
    # reconciler that reached a destructive branch through some OTHER shape -- no
    # -PruneMissing switch at all, e.g. an unconditional Remove-* on every run, or a
    # delete branch gated by a differently-named switch -- would be invisible to this
    # predicate exactly as Set-AuditRetentionPolicy.ps1 was invisible to the Deploy-*
    # glob. The predicate that defines the population is still where the next gap
    # would hide; #108 moved it to firmer ground, it did not retire it as a risk.
    #
    # It goes red again if anyone adds a script under scripts/ that declares
    # -PruneMissing without gating it. The fix is to GATE IT -- or to declare it in
    # $script:UngatedByDesign with a stated, mechanically-verifiable reason, which the
    # staleness guard above then refuses to let rot.
    It 'every destructive-capable script is gated, or declared ungated (the #83/#108 completion criterion)' {
        $accountedFor = @(($script:GatedNow + $script:ExemptNames) | Sort-Object -Unique)
        $missing = @($script:AllReconcilersOnDisk | Where-Object { $_ -notin $accountedFor })

        ($accountedFor -join ', ') | Should -BeExactly ($script:AllReconcilersOnDisk -join ', ') -Because (
            "#83 is complete when every reconciler that can delete or revoke tenant state asks first. $($script:GatedNow.Count) of " +
            "$($script:AllReconcilersOnDisk.Count) are gated; $($script:ExemptNames.Count) is declared ungated-by-design " +
            "($($script:ExemptNames -join ', ')). STILL UNGATED ($($missing.Count)): $($missing -join ', '). " +
            'Each of these can DELETE or OVERWRITE tenant state today with no confirmation prompt -- the issue #85 defect, still live. ' +
            'Gate them (PR-B batch 2), or declare them in $script:UngatedByDesign with a stated, mechanically-verifiable reason.'
        )
    }
}
