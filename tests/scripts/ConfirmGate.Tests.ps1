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
      3. Workflow-text assertions that every CI invocation of the two
         reconcilers with a ShouldProcess-gated write binds -Confirm:$false,
         so raising ConfirmImpact to 'High' cannot hang a job.

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
                        $policyRefs = @($clause.Item1.FindAll({
                                    param($n)
                                    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                                    $n.VariablePath.UserPath -eq 'DirectionPolicy'
                                }, $true))
                        if ($policyRefs.Count -gt 0) {
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
        # ---- Class A (12) : overwrite + prune ----
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
        'Deploy-Scans.ps1'                        = 2
        'Deploy-UnifiedCatalog.ps1'               = 2
        'Deploy-UnifiedCatalogPolicies.ps1'       = 2
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
    # This runs against all 21 reconcilers, including the 17 PR-B has not gated
    # yet, so PR-B inherits a class map that is already proven correct.

    BeforeDiscovery {
        $script:AllReconcilers = @(
            Get-ChildItem -Path (Join-Path $PSScriptRoot '..' '..' 'scripts') -Filter 'Deploy-*.ps1' |
                ForEach-Object { $_.Name }
        )
    }

    It 'covers every Deploy-*.ps1 reconciler (no script may be silently absent)' {
        $onDisk = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter 'Deploy-*.ps1' | ForEach-Object { $_.Name })
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
                -Because 'every one of the 21 reconcilers can delete or revoke tenant state; if this ever fails, the class map needs a Class C'
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

    # The scripts gated SO FAR. PR-A gates four; PR-B appends the remaining 17.
    # Each one's expected gate count is declared in $script:DestructiveBranchCount
    # (see the file-level BeforeAll) -- adding a script here without declaring its
    # class there is a hard failure, by design.
    Context 'on <_>' -ForEach @(
        'Deploy-Labels.ps1',
        'Deploy-FilePlan.ps1',
        'Deploy-DLPPolicies.ps1',
        'Deploy-UnifiedCatalogPolicies.ps1'
    ) {

        BeforeAll {
            $script:ScriptName = $_
            $script:ScriptFile = Join-Path $script:RepoRoot 'scripts' $_
            $script:Text = Get-Content -LiteralPath $script:ScriptFile -Raw
            $script:Ast = Get-ScriptAstOrThrow -Path $script:ScriptFile
            $script:GateCalls = @(Get-GateCallAst -Ast $script:Ast)
            $script:ExpectedGates = $script:DestructiveBranchCount[$_]
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
        # WHAT IT DOES **NOT** CATCH. Two shapes reintroduce policy-keying and
        # pass this assertion -- and every other assertion in this file -- GREEN.
        # Catching them statically needs data-flow analysis, which is out of
        # scope for a Pester guard. So they are named here instead, because AN
        # HONESTLY-LABELLED LIMITED GUARD IS FINE; A LIMITED GUARD SOLD AS
        # COMPLETE IS NOT. PR-B's reviewers must look for these BY EYE.
        #
        #   B1 -- policy laundered through a LOCAL VARIABLE:
        #
        #       $isRepoWins = ($DirectionPolicy -eq 'repo-wins')
        #       if ($isRepoWins -and $overwrites.Count -gt 0) { ...gate... }
        #
        #     The condition never names $DirectionPolicy, so this walk sees a
        #     clean plan predicate.
        #
        #   B2 -- policy laundered through the PLAN LIST ITSELF, by emptying it
        #     upstream. **THIS IS THE ONE THAT MATTERS, AND IT IS THE NATURAL
        #     MISTAKE -- NOT AN ADVERSARIAL ONE.**
        #
        #       if ($DirectionPolicy -ne 'repo-wins') { $repoWinsOverwrites.Clear() }
        #       ...
        #       if ($repoWinsOverwrites.Count -gt 0) { ...gate... }   # pure plan predicate!
        #
        #     The gate condition IS plan-keyed -- genuinely, not cosmetically.
        #     But the LIST is emptied under portal-wins, so the gate stays silent
        #     while the writes proceed. Behaviourally identical to the original
        #     bug, and invisible to every assertion here.
        #
        #     Why it is the NATURAL mistake: the old mental model was "the
        #     overwrite list should only ever populate under repo-wins" -- which
        #     is exactly what `if ($DirectionPolicy -eq 'repo-wins') {
        #     $repoWinsOverwrites.Add(...) }` said in the pre-#83 scripts. An
        #     author who reads "key the gate on the plan" and dutifully fixes the
        #     list's POPULATION instead of the gate's KEYING writes B2 without
        #     ever intending an evasion, and the whole hardened suite stays green.
        #
        # THE RULE THE PROSE CANNOT ENFORCE, stated for the human reader:
        # the overwrite list must be populated from the PLAN and from nothing
        # else -- every object the run will actually overwrite goes in it,
        # whatever policy let it through -- and nothing may remove entries from
        # it between population and the gate. If you find yourself reaching for
        # $DirectionPolicy anywhere near that list, you are writing B2.
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

        # Content checks on the prompt text. These are deliberately anchored to
        # the QUERY ASSIGNMENT and matched CASE-SENSITIVELY (-CMatch), so a
        # lowercase comment cannot satisfy them -- see the header note. They
        # assert what the operator READS; the AST assertions above assert that
        # the gate is WIRED. Both are needed and neither substitutes.
        It 'the overwrite query names the count and the irreversible effect' {
            $script:Text | Should -CMatch '\$overwriteQuery\s*=\s*"This run will OVERWRITE'
        }

        It 'the prune query names the count and the irreversible effect' {
            $script:Text | Should -CMatch '\$pruneQuery\s*=\s*"-PruneMissing will (DELETE|REVOKE)'
        }
    }
}

Describe 'ADR 0052: CI cannot hang -- every workflow invocation binds -Confirm:$false' {

    # This is the regression test for the hang that raising ConfirmImpact to
    # 'High' would otherwise have caused. Deploy-Labels.ps1 wraps its
    # -ExportCurrentState YAML write in $PSCmdlet.ShouldProcess(...), and two
    # workflows invoked that export path without -Confirm:$false. At 'High'
    # those steps would have prompted on a hosted runner and hung the job.
    Context 'in <_>' -ForEach @(
        'deploy-labels.yml',
        'sync-labels-from-tenant.yml',
        'deploy-dlp.yml',
        'sync-dlp-from-tenant.yml'
    ) {
        BeforeAll {
            $script:WfText = Get-Content -LiteralPath (Join-Path $script:RepoRoot '.github' 'workflows' $_) -Raw
        }

        It 'binds -Confirm:$false on every Deploy-Labels/Deploy-DLPPolicies invocation' {
            # An invocation is a pwsh call continued across lines with trailing
            # backticks, or a one-line splat (`... .ps1 @applyArgs`). Walk the
            # continuation lines rather than trying to express them in one regex.
            $lines = $script:WfText -split "\r?\n"
            $blocks = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -notmatch '\./scripts/Deploy-(?:Labels|DLPPolicies)\.ps1') { continue }
                $sb = [System.Text.StringBuilder]::new($lines[$i])
                $j = $i
                while ($j -lt $lines.Count - 1 -and $lines[$j].TrimEnd().EndsWith('`')) {
                    $j++
                    [void]$sb.AppendLine()
                    [void]$sb.Append($lines[$j])
                }
                $blocks.Add($sb.ToString())
            }
            $blocks.Count | Should -BeGreaterThan 0

            foreach ($block in $blocks) {
                # A splatted invocation carries Confirm inside the hashtable
                # built just above it; that is asserted by the next It block.
                if ($block -match '@\w+\s*$') { continue }
                $block | Should -Match '-Confirm:\$false' -Because "invocation '$($block.Trim())' must bind -Confirm:`$false or it hangs at ConfirmImpact='High'"
            }
        }

        It 'binds Confirm = $false in every splatted argument hashtable' {
            $splats = [regex]::Matches($script:WfText, '\$applyArgs\s*=\s*@\{(?<body>[^}]*)\}')
            foreach ($s in $splats) {
                $s.Groups['body'].Value | Should -Match 'Confirm\s*=\s*\$false'
            }
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
