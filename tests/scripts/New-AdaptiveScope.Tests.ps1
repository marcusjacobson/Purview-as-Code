#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/New-AdaptiveScope.ps1 (Issue #548).

.DESCRIPTION
    AST-extracts the three pure helper functions from the script and
    exercises them with synthetic inputs. Then asserts a small set of
    parameter-shape and source-text contracts on the script itself.

    Pattern: AST + text assertions. Per
    `.github/instructions/tests.instructions.md` "No live tenant,
    no live subscription" -- the script connects to Security &
    Compliance PowerShell, so we never invoke its body.

    Functions under test:
      * Format-AdaptiveScopeIdentifier
          - Redacts a GUID-shaped string to first-8-chars + ellipsis.
          - Passes non-GUID input through unchanged.
          - Returns the `<none>` placeholder for null / empty / whitespace.
      * Resolve-AdaptiveScopeAction
          - Returns 'Create' when Existing is $null.
          - Returns 'NoChange' when Existing.LocationType matches.
          - Throws on LocationType mismatch (immutable per Microsoft Learn).
          - Throws when Existing has no readable LocationType.
      * Get-AdaptiveScopeIdValue
          - Returns the empty string for $null input.
          - Reads Guid / Identity / ExchangeObjectId in priority order.
          - Returns the empty string when none of the GUID properties are present.

    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-AdaptiveScope.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate New-AdaptiveScope.ps1 at: $script:ScriptPath"
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

    foreach ($fn in @('Format-AdaptiveScopeIdentifier','Resolve-AdaptiveScopeAction','Get-AdaptiveScopeIdValue')) {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fn
            }, $true)
        if (-not $fnAst) {
            throw "Function '$fn' not found in $($script:ScriptPath)."
        }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'New-AdaptiveScope.ps1 -- parameter contract' {

    It 'declares Name as a mandatory string with a lab-as- prefix pattern' {
        $script:Parameters.ContainsKey('Name') | Should -BeTrue
        $script:Parameters['Name'].StaticType.FullName | Should -Be 'System.String'
        $pattern = $script:Parameters['Name'].Attributes |
            Where-Object { $_.TypeName.Name -eq 'ValidatePattern' } |
            Select-Object -First 1
        $pattern | Should -Not -BeNullOrEmpty
        $pattern.PositionalArguments[0].Value | Should -Match '\^lab-as-'
    }

    It 'declares LocationType as a mandatory ValidateSet(User,Group,Site) string' {
        $script:Parameters.ContainsKey('LocationType') | Should -BeTrue
        $script:Parameters['LocationType'].StaticType.FullName | Should -Be 'System.String'
        $set = $script:Parameters['LocationType'].Attributes |
            Where-Object { $_.TypeName.Name -eq 'ValidateSet' } |
            Select-Object -First 1
        $set | Should -Not -BeNullOrEmpty
        $values = @($set.PositionalArguments | ForEach-Object { $_.Value })
        $values | Should -Be @('User','Group','Site')
    }

    It 'declares FilterConditions as a mandatory hashtable' {
        $script:Parameters.ContainsKey('FilterConditions') | Should -BeTrue
        $script:Parameters['FilterConditions'].StaticType.FullName | Should -Be 'System.Collections.Hashtable'
    }

    It 'declares a -ParametersFile parameter (ADR 0012 contract)' {
        $script:Parameters.ContainsKey('ParametersFile') | Should -BeTrue
        $script:Parameters['ParametersFile'].StaticType.FullName | Should -Be 'System.String'
    }

    It 'declares CmdletBinding(SupportsShouldProcess = $true)' {
        $cb = $script:Ast.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' } |
            Select-Object -First 1
        $cb | Should -Not -BeNullOrEmpty
        $supports = $cb.NamedArguments | Where-Object { $_.ArgumentName -eq 'SupportsShouldProcess' }
        $supports | Should -Not -BeNullOrEmpty
    }

    It 'gates the write call behind $PSCmdlet.ShouldProcess' {
        $script:ScriptText | Should -Match 'PSCmdlet\.ShouldProcess'
    }

    It 'requires PowerShell 7.4 via #Requires directive' {
        $script:ScriptText | Should -Match '#Requires\s+-Version\s+7\.4'
    }
}

Describe 'New-AdaptiveScope.ps1 -- IPPS auth pattern (mirrors Deploy-AutoLabelPolicies.ps1)' {

    It 'calls Get-PurviewIPPSAccessToken.ps1 to acquire the access token' {
        $script:ScriptText | Should -Match 'Get-PurviewIPPSAccessToken\.ps1'
    }

    It 'uses Connect-IPPSSession -AccessToken (never -Credential, never -CertificateThumbprint)' {
        $script:ScriptText | Should -Match 'Connect-IPPSSession\s+`?\s*\n?\s*-AccessToken'
        $script:ScriptText | Should -Not -Match 'Connect-IPPSSession\s+-Credential'
        $script:ScriptText | Should -Not -Match 'Connect-IPPSSession\s+-CertificateThumbprint'
    }

    It 'wraps the write path in try/finally with Disconnect-ExchangeOnline' {
        $script:ScriptText | Should -Match 'Disconnect-ExchangeOnline\s+-Confirm:\$false'
    }

    It 'guards Get-AdaptiveScope before calling New-AdaptiveScope (idempotency)' {
        $script:ScriptText | Should -Match 'Get-AdaptiveScope\s+-Identity\s+\$Name'
        $script:ScriptText | Should -Match 'New-AdaptiveScope\s+`?\s*\n?\s*-Name'
    }

    It 'cites the New-AdaptiveScope Microsoft Learn reference' {
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/powershell/module/exchange/new-adaptivescope'
    }

    It 'cites the Microsoft Purview adaptive scopes Learn reference' {
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/purview/purview-adaptive-scopes'
    }

    It 'cites the Connect-IPPSSession -AccessToken Learn reference' {
        $script:ScriptText | Should -Match 'learn\.microsoft\.com/en-us/powershell/module/exchangepowershell/connect-ippssession'
    }
}

Describe 'Format-AdaptiveScopeIdentifier' {

    It 'redacts a GUID-shaped value to the first 8 chars plus ellipsis' {
        Format-AdaptiveScopeIdentifier -Value '00000000-0000-0000-0000-000000000001' | Should -Be '00000000-...'
    }

    It 'redacts a mixed-case GUID-shaped value' {
        Format-AdaptiveScopeIdentifier -Value 'AbCdEf01-1234-5678-9ABC-DEF012345678' | Should -Be 'AbCdEf01-...'
    }

    It 'returns <none> placeholder for $null' {
        Format-AdaptiveScopeIdentifier -Value $null | Should -Be '<none>'
    }

    It 'returns <none> placeholder for the empty string' {
        Format-AdaptiveScopeIdentifier -Value '' | Should -Be '<none>'
    }

    It 'returns <none> placeholder for whitespace' {
        Format-AdaptiveScopeIdentifier -Value '   ' | Should -Be '<none>'
    }

    It 'passes a non-GUID display name through unchanged' {
        Format-AdaptiveScopeIdentifier -Value 'lab-as-test-mailbox-01' | Should -Be 'lab-as-test-mailbox-01'
    }

    It 'does not redact a value that is too short to be a GUID' {
        Format-AdaptiveScopeIdentifier -Value '00000000-0000' | Should -Be '00000000-0000'
    }
}

Describe 'Resolve-AdaptiveScopeAction' {

    It "returns 'Create' when no existing scope is found" {
        $action = Resolve-AdaptiveScopeAction -Existing $null -DesiredLocationType 'User' -Name 'lab-as-test-01'
        $action | Should -Be 'Create'
    }

    It "returns 'NoChange' when LocationType matches (pscustomobject existing)" {
        $existing = [pscustomobject]@{ Name = 'lab-as-test-01'; LocationType = 'User' }
        $action = Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType 'User' -Name 'lab-as-test-01'
        $action | Should -Be 'NoChange'
    }

    It "returns 'NoChange' when LocationType matches (hashtable existing)" {
        $existing = @{ Name = 'lab-as-test-01'; LocationType = 'Group' }
        $action = Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType 'Group' -Name 'lab-as-test-01'
        $action | Should -Be 'NoChange'
    }

    It 'throws on LocationType mismatch with a clear remediation message' {
        $existing = [pscustomobject]@{ Name = 'lab-as-test-01'; LocationType = 'User' }
        { Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType 'Group' -Name 'lab-as-test-01' } |
            Should -Throw -ExpectedMessage "*LocationType 'User' but 'Group' was requested*"
    }

    It 'mismatch error cites the New-AdaptiveScope Learn page' {
        $existing = [pscustomobject]@{ Name = 'lab-as-test-01'; LocationType = 'Site' }
        { Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType 'User' -Name 'lab-as-test-01' } |
            Should -Throw -ExpectedMessage "*new-adaptivescope*"
    }

    It 'throws when Existing has no readable LocationType property' {
        $existing = [pscustomobject]@{ Name = 'lab-as-test-01' }
        { Resolve-AdaptiveScopeAction -Existing $existing -DesiredLocationType 'User' -Name 'lab-as-test-01' } |
            Should -Throw -ExpectedMessage "*no readable LocationType*"
    }

    It 'rejects an invalid DesiredLocationType at the parameter boundary' {
        { Resolve-AdaptiveScopeAction -Existing $null -DesiredLocationType 'Mailbox' -Name 'lab-as-test-01' } |
            Should -Throw
    }
}

Describe 'Get-AdaptiveScopeIdValue' {

    It 'returns the empty string for $null input' {
        Get-AdaptiveScopeIdValue -Scope $null | Should -Be ''
    }

    It 'reads the Guid property when present (pscustomobject)' {
        $scope = [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; Identity = 'ignored'; ExchangeObjectId = 'ignored' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be '00000000-0000-0000-0000-000000000001'
    }

    It 'reads the Guid property when present (hashtable)' {
        $scope = @{ Guid = '00000000-0000-0000-0000-000000000002' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be '00000000-0000-0000-0000-000000000002'
    }

    It 'falls back to Identity when Guid is absent' {
        $scope = [pscustomobject]@{ Identity = '00000000-0000-0000-0000-000000000003' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be '00000000-0000-0000-0000-000000000003'
    }

    It 'falls back to ExchangeObjectId when Guid and Identity are absent' {
        $scope = [pscustomobject]@{ ExchangeObjectId = '00000000-0000-0000-0000-000000000004' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be '00000000-0000-0000-0000-000000000004'
    }

    It 'returns the empty string when none of the GUID properties carry a value' {
        $scope = [pscustomobject]@{ Name = 'lab-as-test-01' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be ''
    }

    It 'returns the empty string when GUID properties are present but empty' {
        $scope = [pscustomobject]@{ Guid = ''; Identity = $null; ExchangeObjectId = '   ' }
        Get-AdaptiveScopeIdValue -Scope $scope | Should -Be ''
    }
}
