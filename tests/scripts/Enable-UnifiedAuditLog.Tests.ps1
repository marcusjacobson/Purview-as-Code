#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Enable-UnifiedAuditLog.ps1.

.DESCRIPTION
    Pins the -Interactive local-dev contract added in issue #356 Phase 3
    so a future refactor cannot silently regress the workstation-friendly
    auth path. The same KV-PNA-disabled drift that blocked role-groups
    (issue #355) blocks UAL re-verification when the data-plane app cert
    cannot be reached from the workstation; -Interactive provides a
    browser-MFA fallback that skips the Key Vault entirely.

    Pattern: AST + text assertions. Per tests/README.md "No script
    execution" -- the script shells out to az / Key Vault and connects
    to Exchange Online PowerShell, so we never invoke its body.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
    Reference: https://learn.microsoft.com/en-us/purview/audit-log-enable-disable
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Enable-UnifiedAuditLog.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Enable-UnifiedAuditLog.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    $paramBlock = $script:Ast.ParamBlock
    $script:Parameters = @{}
    foreach ($p in $paramBlock.Parameters) {
        $script:Parameters[$p.Name.VariablePath.UserPath] = $p
    }
}

Describe 'Enable-UnifiedAuditLog.ps1 -- local-dev interactive mode (issue #356 Phase 3)' {

    It 'declares an -Interactive switch parameter' {
        $script:Parameters.ContainsKey('Interactive') | Should -BeTrue
        $script:Parameters['Interactive'].StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }

    It 'declares a -UserPrincipalName parameter with email validation' {
        $script:Parameters.ContainsKey('UserPrincipalName') | Should -BeTrue
        $script:Parameters['UserPrincipalName'].StaticType.FullName | Should -Be 'System.String'
        $validate = $script:Parameters['UserPrincipalName'].Attributes |
            Where-Object { $_.TypeName.Name -eq 'ValidatePattern' } |
            Select-Object -First 1
        $validate | Should -Not -BeNullOrEmpty
        $validate.PositionalArguments[0].Value | Should -Match '@'
    }

    It 'guards the app-only token acquisition behind -not $Interactive.IsPresent' {
        # The KV + cert + Get-PurviewIPPSAccessToken.ps1 path must be
        # skipped under -Interactive so a local-dev run never reaches
        # the vault. AST check: locate the `if` whose condition is
        # `-not $Interactive.IsPresent` and whose body contains the
        # token-helper literal.
        $ifGuards = $script:Ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
            $cond = $node.Clauses[0].Item1.Extent.Text
            return ($cond -match '-not\s+\$Interactive\.IsPresent')
        }, $true)
        $ifGuards.Count | Should -BeGreaterOrEqual 1
        $guardsTokenHelper = $false
        foreach ($g in $ifGuards) {
            if ($g.Clauses[0].Item2.Extent.Text -match 'Get-PurviewIPPSAccessToken\.ps1') {
                $guardsTokenHelper = $true
                break
            }
        }
        $guardsTokenHelper | Should -BeTrue -Because 'the KV-side token helper must be skipped under -Interactive'
    }

    It 'branches Connect-ExchangeOnline to -UserPrincipalName when Interactive' {
        $matches = [regex]::Matches($script:ScriptText, 'Connect-ExchangeOnline\s+(?:`\s*\n\s*)?-UserPrincipalName')
        $matches.Count | Should -BeGreaterOrEqual 1
    }

    It 'preserves the app-only -AccessToken connect path for CI' {
        # CI must keep working unchanged. The app-only Connect-ExchangeOnline
        # -AccessToken path is the canonical ADR 0011 Decision #3 contract.
        $matches = [regex]::Matches($script:ScriptText, 'Connect-ExchangeOnline\s+`\s*\n\s*-AccessToken')
        $matches.Count | Should -BeGreaterOrEqual 1
    }

    It 'falls back to `az account show --query user.name` when UPN is omitted' {
        # Convenience: in interactive mode a missing UPN is read from
        # the active Azure CLI session, not prompted for.
        $script:ScriptText | Should -Match 'az account show --query user\.name'
    }
}
