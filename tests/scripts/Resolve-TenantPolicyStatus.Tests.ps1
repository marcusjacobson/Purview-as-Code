#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the `Resolve-TenantPolicyStatus` helper in
    `scripts/Deploy-LabelPolicies.ps1`.

.DESCRIPTION
    Locks in the empty-`Status` -> `Published` normalization landed in
    PR #201 (issue #200): `Get-LabelPolicy.Status` is empty for some
    long-lived published policies (notably the built-in
    `Global sensitivity label policy`) even when the policy is actively
    deployed. The verify path treats empty `Status` paired with a known
    runtime `Mode` (e.g. `Enforce`) as `Published`.

    Pattern: AST-extract the function definition only and evaluate it
    into the test scope. See `tests/.github/instructions/tests.instructions.md`.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-LabelPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-LabelPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $fnAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Resolve-TenantPolicyStatus'
        }, $true)

    if (-not $fnAst) {
        throw "Resolve-TenantPolicyStatus not found in $script:ScriptPath"
    }

    . ([ScriptBlock]::Create($fnAst.Extent.Text))

    # Match the production map exactly so the default-parameter path
    # is also exercised when callers omit -RuntimeModeMap.
    $script:RuntimePolicyModeMap = @{ 'Enforce' = 'Enable' }
}

Describe 'Resolve-TenantPolicyStatus (issue #200, PR #201)' {

    It 'returns the populated Status string verbatim' {
        $result = Resolve-TenantPolicyStatus -Status 'Published' -Mode 'Enforce'
        $result | Should -Be 'Published'
    }

    It 'passes through a non-Published populated Status verbatim (e.g. Pending)' {
        # A reconciled policy can sit at Status=Pending for a few
        # seconds after Apply; verify must report that as-is so the
        # caller can flag a Fail row.
        $result = Resolve-TenantPolicyStatus -Status 'Pending' -Mode 'Enforce'
        $result | Should -Be 'Pending'
    }

    It 'normalizes empty Status + runtime Mode=Enforce to Published (the #200 fix)' {
        $result = Resolve-TenantPolicyStatus -Status '' -Mode 'Enforce'
        $result | Should -Be 'Published'
    }

    It 'normalizes $null Status + runtime Mode=Enforce to Published' {
        $result = Resolve-TenantPolicyStatus -Status $null -Mode 'Enforce'
        $result | Should -Be 'Published'
    }

    It 'returns <empty> when Status is empty and Mode is not in the runtime map' {
        $result = Resolve-TenantPolicyStatus -Status '' -Mode 'Disabled'
        $result | Should -Be '<empty>'
    }

    It 'returns <empty> when both Status and Mode are empty' {
        $result = Resolve-TenantPolicyStatus -Status '' -Mode ''
        $result | Should -Be '<empty>'
    }

    It 'honors a caller-supplied RuntimeModeMap override' {
        # Future-proofing: if Microsoft adds a new runtime state, the
        # production script can ship a one-line map update and the
        # helper still works.
        $custom = @{ 'SomeFutureRuntime' = 'Enable' }
        $result = Resolve-TenantPolicyStatus -Status '' -Mode 'SomeFutureRuntime' -RuntimeModeMap $custom
        $result | Should -Be 'Published'
    }

    It 'returns <empty> when an empty RuntimeModeMap is supplied and Status is empty' {
        $result = Resolve-TenantPolicyStatus -Status '' -Mode 'Enforce' -RuntimeModeMap @{}
        $result | Should -Be '<empty>'
    }
}

