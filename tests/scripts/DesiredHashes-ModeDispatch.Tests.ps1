#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester regression for the `$desiredHashes` mode-dispatch gate in
    `scripts/Deploy-LabelPolicies.ps1` (issue #240).

.DESCRIPTION
    PR #238 introduced the `-CompareWithTenant` mode but did not extend
    the `if ($mode -eq 'Apply' -or $mode -eq 'Verify')` gate that
    populates `$desiredHashes`. As a result the `Compare` mode received
    an empty `$desiredHashes`, every tenant policy looked like
    `TenantOnly` drift, and the post-merge verify smoke (run
    25884829535) tripped the conflict guard on a policy that was in
    fact NoChange.

    The fix lifts the gate to also accept `Compare`. This test parses
    the script and asserts the gate's `IfStatementAst` condition
    references all three mode strings. It is intentionally agnostic to
    operator order or boolean operator -- it only requires that all
    three string literals appear in the same `if` condition, so future
    refactors (e.g. `$mode -in @('Apply','Verify','Compare')`) keep
    the test passing as long as the contract holds.

    Pattern: AST parse + structural assertion. We do not dot-source
    the script (it would try to connect to a tenant) and we do not
    Find-and-eval a function definition (the gate lives in script
    top-level code, not inside a function).

    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_language_modes
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-LabelPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-LabelPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        throw ("Deploy-LabelPolicies.ps1 has parse errors: {0}" -f ($errors | ForEach-Object Message | Join-String -Separator '; '))
    }

    # Find the assignment `$desiredHashes = @()` at script scope, then
    # walk to the immediately-following `IfStatementAst`. That `if`
    # carries the mode-dispatch condition the test guards.
    $script:DesiredHashesAssignment = $script:Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$desiredHashes' -and
            $node.Right.Extent.Text -eq '@()'
        }, $true)

    if (-not $script:DesiredHashesAssignment) {
        throw 'Could not locate `$desiredHashes = @()` assignment in Deploy-LabelPolicies.ps1.'
    }

    # The gate lives in the parent block, right after the assignment.
    # Walk the parent's statements to find the next IfStatementAst.
    $parent = $script:DesiredHashesAssignment.Parent
    $found = $false
    $script:GateIf = $null
    foreach ($stmt in $parent.Statements) {
        if ($found -and $stmt -is [System.Management.Automation.Language.IfStatementAst]) {
            $script:GateIf = $stmt
            break
        }
        if ($stmt -eq $script:DesiredHashesAssignment.Parent -or $stmt.Extent.Text -eq $script:DesiredHashesAssignment.Extent.Text) {
            $found = $true
        }
    }

    # Fallback: find the first IfStatementAst whose condition references
    # `$mode` and whose start offset is after the assignment.
    if (-not $script:GateIf) {
        $candidates = $script:Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.StartOffset -gt $script:DesiredHashesAssignment.Extent.EndOffset -and
                $node.Clauses[0].Item1.Extent.Text -match '\$mode'
            }, $true)
        if ($candidates -and $candidates.Count -gt 0) {
            $script:GateIf = $candidates | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        }
    }

    if (-not $script:GateIf) {
        throw 'Could not locate the mode-dispatch `if` statement following `$desiredHashes = @()`.'
    }

    $script:GateConditionText = $script:GateIf.Clauses[0].Item1.Extent.Text
}

Describe '$desiredHashes mode-dispatch gate (issue #240)' {

    It 'references $mode' {
        $script:GateConditionText | Should -Match '\$mode'
    }

    It 'references the Apply mode' {
        $script:GateConditionText | Should -Match "'Apply'"
    }

    It 'references the Verify mode' {
        $script:GateConditionText | Should -Match "'Verify'"
    }

    It 'references the Compare mode (the #240 fix)' {
        # This is the assertion that would have failed against PR #238
        # and that locks in the #240 fix. Compare is the read-only
        # conflict-guard mode invoked by deploy-label-policies.yml;
        # omitting it left the workflow reporting every tenant policy
        # as TenantOnly drift.
        $script:GateConditionText | Should -Match "'Compare'"
    }
}
