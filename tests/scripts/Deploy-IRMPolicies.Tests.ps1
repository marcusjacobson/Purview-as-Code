#Requires -Version 7.4
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in `scripts/Deploy-IRMPolicies.ps1`.

.DESCRIPTION
    Locks in the Microsoft Purview Insider Risk Management reconciler contract:

      1. `ConvertTo-DesiredIRMPolicyHash` normalizes a YAML policy entry
         into a comparable hashtable; missing optionals collapse to $null.
      2. `ConvertTo-TenantIRMPolicyHash` normalizes a `Get-InsiderRiskPolicy`
         row into the same shape, mapping `Comment` -> `description` and
         `InsiderRiskScenario` -> `scenario`.
      3. `Compare-IRMPolicy` returns an empty list for in-sync inputs and
         the field names that drift. `description`, `scenario`, and
         `enabled` are compared only when the desired side declares them
         (a missing optional in YAML is treated as "don''t manage").

    Pattern: AST-extract each helper from the script and dot-source into
    the test scope. We deliberately do NOT dot-source the script itself
    -- that would execute its top-level code and try to
    `Connect-IPPSSession` against the live tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicy
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMPolicies.ps1"
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-IRMPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join "; "))
    }

    foreach ($fname in @(
            "ConvertTo-DesiredIRMPolicyHash",
            "ConvertTo-TenantIRMPolicyHash",
            "Compare-IRMPolicy")) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe "ConvertTo-DesiredIRMPolicyHash normalizes YAML entries" {

    It "collapses missing optionals to null" {
        $entry = @{ name = "lab-irm-min"; scenario = "DataLeaks" }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-min"
        $hash.scenario    | Should -Be "DataLeaks"
        $hash.description | Should -BeNullOrEmpty
        $hash.enabled     | Should -BeNullOrEmpty
    }

    It "preserves every declared field" {
        $entry = @{
            name = "lab-irm-full"
            scenario = "IntellectualPropertyTheft"
            description = "Lab IRM"
            enabled = $true
        }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-full"
        $hash.scenario    | Should -Be "IntellectualPropertyTheft"
        $hash.description | Should -Be "Lab IRM"
        $hash.enabled     | Should -BeTrue
    }

    It "stringifies non-string description" {
        $entry = @{ name = "lab-irm-num"; scenario = "DataLeaks"; description = 42 }
        $hash = ConvertTo-DesiredIRMPolicyHash -Entry $entry
        $hash.description | Should -Be "42"
    }
}

Describe "ConvertTo-TenantIRMPolicyHash normalizes Get-InsiderRiskPolicy rows" {

    It "maps Comment to description and InsiderRiskScenario to scenario" {
        $row = [pscustomobject]@{
            Name = "IRM Lab"
            Comment = "live"
            InsiderRiskScenario = "DataLeaks"
            Enabled = $true
            IsCustom = $false
        }
        $hash = ConvertTo-TenantIRMPolicyHash -Policy $row
        $hash.name        | Should -Be "IRM Lab"
        $hash.description | Should -Be "live"
        $hash.scenario    | Should -Be "DataLeaks"
        $hash.enabled     | Should -BeTrue
        $hash.isCustom    | Should -BeFalse
    }

    It "handles null Comment without throwing" {
        $row = [pscustomobject]@{
            Name = "n"; Comment = $null; InsiderRiskScenario = "DataLeaks"; Enabled = $false; IsCustom = $true
        }
        $hash = ConvertTo-TenantIRMPolicyHash -Policy $row
        $hash.description | Should -BeNullOrEmpty
    }
}

Describe "Compare-IRMPolicy returns drift field names" {

    It "returns empty list for in-sync inputs" {
        $d = @{ name="x"; scenario="DataLeaks"; description="d"; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="d"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports description drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description="want"; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="have"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "description"
    }

    It "ignores description drift when YAML omits it" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description="tenant-only"; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports scenario drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$null }
        $t = @{ name="x"; scenario="IntellectualPropertyTheft"; description=$null; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "scenario"
    }

    It "reports enabled drift when declared" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        $t = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$false }
        @(Compare-IRMPolicy -Desired $d -Tenant $t) | Should -Contain "enabled"
    }

    It "ignores enabled drift when YAML omits it" {
        $d = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$null }
        $t = @{ name="x"; scenario="DataLeaks"; description=$null; enabled=$true }
        @(Compare-IRMPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }
}