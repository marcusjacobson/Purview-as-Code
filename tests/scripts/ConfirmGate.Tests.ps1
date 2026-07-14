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

    Context 'on <_>' -ForEach @(
        'Deploy-Labels.ps1',
        'Deploy-FilePlan.ps1',
        'Deploy-DLPPolicies.ps1',
        'Deploy-UnifiedCatalogPolicies.ps1'
    ) {

        BeforeAll {
            $script:ScriptFile = Join-Path $script:RepoRoot 'scripts' $_
            $script:Text = Get-Content -LiteralPath $script:ScriptFile -Raw
            $script:Ast = Get-ScriptAstOrThrow -Path $script:ScriptFile
            $script:GateCalls = @(Get-GateCallAst -Ast $script:Ast)
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

        It 'wires exactly 2 destructive gates as real command calls' {
            # Every one of these four scripts has exactly two destructive
            # branches: the overwrite and the prune. Not 1 (a branch is
            # unguarded), not 0 (the gate was deleted -- which the old
            # query-string regexes did not notice).
            $script:GateCalls.Count | Should -Be 2 `
                -Because 'both the overwrite branch and the -PruneMissing branch must call Assert-DestructiveOperationConfirmed'
        }

        It 'binds -Query on both gates, one per destructive branch' {
            $queries = @($script:GateCalls | ForEach-Object { Get-BoundQueryVariableName -GateCall $_ }) | Sort-Object
            $queries | Should -Be @('overwriteQuery', 'pruneQuery') `
                -Because 'each gate must name the objects it is about to destroy; an operator who cannot see what they are destroying is not really being asked'
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
            $script:GateCalls.Count | Should -Be 2 -Because 'an assertion about "each gate" is vacuous if there are no gates'

            foreach ($gate in $script:GateCalls) {
                $throws = @(Get-GateDeclineThrow -GateCall $gate)
                $throws.Count | Should -BeGreaterThan 0 `
                    -Because "the gate at line $($gate.Extent.StartLineNumber) must abort the run on decline, not fall through into a half-applied state"
                ($throws | ForEach-Object { $_.Extent.Text }) -join ' ' |
                    Should -Match 'No tenant writes were made'
            }
        }

        # ================== THE PLAN-KEYING INVARIANT (V4) ==================
        #
        # THE permanent guard. PR-B replicates this gate into 17 more scripts,
        # so this is the assertion standing between the repo and a reintroduced
        # policy-keyed gate. It has to catch the CLASS, not one SPELLING.
        #
        # The regex version pinned the literal
        #     if ($DirectionPolicy -eq 'repo-wins' -and
        # and was GREEN against all of these, every one of which reintroduces
        # policy-keying:
        #     if ($overwrites.Count -gt 0 -and $DirectionPolicy -eq 'repo-wins')  # reordered
        #     if ($DirectionPolicy -eq "repo-wins" -and $overwrites.Count -gt 0)  # double-quoted
        #     if ($DirectionPolicy -ne 'portal-wins' -and $overwrites.Count -gt 0) # negated
        #
        # A guard that pins a spelling is a guard the next author routes around
        # without ever knowing it was there.
        #
        # The AST rule is about STRUCTURE and admits no spelling: walk from each
        # real gate call up through every `if` that guards it (any depth, via the
        # BODY), and assert none of those conditions so much as MENTIONS the
        # $DirectionPolicy variable. Operator, quoting, operand order, negation
        # and nesting are all irrelevant -- a VariableExpressionAst is a
        # VariableExpressionAst.
        #
        # Measured on all four scripts: every gate-guarding condition is a pure
        # plan predicate ($repoWinsOverwrites.Count -gt 0, $prunePlan.Count -gt 0,
        # $PruneMissing.IsPresent), so the strict "no mention at any depth" form
        # is achievable and is what ships.
        It 'keys every gate on the PLAN -- no gate-guarding condition mentions $DirectionPolicy' {
            # NON-VACUITY GUARD (see the note on the decline-throw assertion).
            # Get-PolicyKeyedGuard walks outward FROM each gate call, so with
            # zero gates it returns zero offenders and this would pass green on a
            # script that has no gate at all. State the population first.
            $script:GateCalls.Count | Should -Be 2 -Because 'a "no gate is policy-keyed" claim is vacuous if there are no gates'

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
