#Requires -Version 7.4
#Requires -Modules @{ ModuleName = "Pester"; ModuleVersion = "5.5.0" }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in `scripts/Deploy-IRMEntityLists.ps1`.

.DESCRIPTION
    Locks in the Microsoft Purview Insider Risk Management entity-list
    reconciler contract:

      1. `ConvertTo-DesiredEntityListHash` normalizes a YAML entity-list
         entry into a comparable hashtable; missing optionals collapse to
         $null; entities are normalized to lowercase sorted order.
      2. `ConvertTo-TenantEntityListHash` normalizes a
         `Get-InsiderRiskEntityList` row into the same shape.
      3. `Compare-EntityList` returns an empty list for in-sync inputs and
         the field names that drift. `displayName`, `description`, and
         `entities` are compared only when the desired side declares them
         (a missing optional in YAML is treated as "don''t manage").
         `type` is NOT compared (immutable after creation per ADR 0039).

    Pattern: AST-extract each helper from the script and dot-source into
    the test scope. We deliberately do NOT dot-source the script itself
    -- that would execute its top-level code and try to
    `Connect-IPPSSession` against the live tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
    Reference: https://pester.dev/docs/quick-start
    Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot ".." ".." "scripts" "Deploy-IRMEntityLists.ps1"
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-IRMEntityLists.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join "; "))
    }

    foreach ($fname in @(
            "ConvertTo-DesiredEntityListHash",
            "ConvertTo-TenantEntityListHash",
            "Compare-EntityList")) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe "ConvertTo-DesiredEntityListHash normalizes YAML entries" {

    It "collapses missing optionals to null" {
        $entry = @{ name = "lab-irm-min"; type = "UserType" }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-min"
        $hash.type        | Should -Be "UserType"
        $hash.displayName | Should -BeNullOrEmpty
        $hash.description | Should -BeNullOrEmpty
        $hash.entities    | Should -BeNullOrEmpty
    }

    It "preserves every declared field" {
        $entry = @{
            name        = "lab-irm-full"
            type        = "GroupType"
            displayName = "Lab IRM Group List"
            description = "Test group entity list"
            entities    = @("group-a@contoso.com", "group-b@contoso.com")
        }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.name        | Should -Be "lab-irm-full"
        $hash.type        | Should -Be "GroupType"
        $hash.displayName | Should -Be "Lab IRM Group List"
        $hash.description | Should -Be "Test group entity list"
        $hash.entities    | Should -Not -BeNullOrEmpty
    }

    It "normalizes entities to lowercase sorted order" {
        $entry = @{
            name     = "lab-irm-ent"
            type     = "UserType"
            entities = @("User-B@contoso.com", "user-a@contoso.com", "USER-C@CONTOSO.COM")
        }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.entities[0] | Should -Be "user-a@contoso.com"
        $hash.entities[1] | Should -Be "user-b@contoso.com"
        $hash.entities[2] | Should -Be "user-c@contoso.com"
    }

    It "treats entities empty array as declared-empty (not null)" {
        $entry = @{ name = "lab-irm-empty-ent"; type = "UserType"; entities = @() }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        # @() is declared-empty (tracked for diff), NOT $null (do-not-manage).
        # Use direct null-check rather than Should -Not -BeNullOrEmpty because
        # Pester treats an empty array as "empty" and the assertion would fail.
        ($null -eq $hash.entities) | Should -BeFalse
        $hash.entities.Count | Should -Be 0
    }

    It "treats absent entities key as null (do-not-manage)" {
        $entry = @{ name = "lab-irm-no-ent"; type = "UserType" }
        $hash = ConvertTo-DesiredEntityListHash -Entry $entry
        $hash.entities | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-TenantEntityListHash normalizes Get-InsiderRiskEntityList rows" {

    It "maps all properties correctly" {
        $row = [pscustomobject]@{
            Name        = "IRM-Lab-Priority-Users"
            Type        = "UserType"
            DisplayName = "Lab Priority Users"
            Description = "Priority user group for lab"
            Entities    = @("user-a@contoso.com", "user-b@contoso.com")
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.name        | Should -Be "IRM-Lab-Priority-Users"
        $hash.type        | Should -Be "UserType"
        $hash.displayName | Should -Be "Lab Priority Users"
        $hash.description | Should -Be "Priority user group for lab"
        $hash.entities    | Should -Not -BeNullOrEmpty
    }

    It "handles null optional properties without throwing" {
        $row = [pscustomobject]@{
            Name        = "irm-sparse"
            Type        = "SiteType"
            DisplayName = $null
            Description = $null
            Entities    = $null
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.displayName | Should -BeNullOrEmpty
        $hash.description | Should -BeNullOrEmpty
        $hash.entities.Count | Should -Be 0
    }

    It "normalizes tenant entities to lowercase sorted order" {
        $row = [pscustomobject]@{
            Name     = "irm-sort"
            Type     = "UserType"
            DisplayName = $null; Description = $null
            Entities = @("User-Z@contoso.com", "user-a@contoso.com")
        }
        $hash = ConvertTo-TenantEntityListHash -EntityList $row
        $hash.entities[0] | Should -Be "user-a@contoso.com"
        $hash.entities[1] | Should -Be "user-z@contoso.com"
    }
}

Describe "Compare-EntityList returns drift field names" {

    It "returns empty list for in-sync inputs" {
        $d = @{ name = "x"; type = "UserType"; displayName = "Foo"; description = "Bar"; entities = @("a@contoso.com") }
        $t = @{ name = "x"; type = "UserType"; displayName = "Foo"; description = "Bar"; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports displayName drift when declared" {
        $d = @{ name = "x"; type = "UserType"; displayName = "want"; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = "have"; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "displayName"
    }

    It "ignores displayName drift when YAML omits it" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = "tenant-only"; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "reports description drift when declared" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = "want"; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = "have"; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "description"
    }

    It "reports entities drift for content change" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("b@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "entities"
    }

    It "reports entities drift when desired is empty and tenant is non-empty" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @() }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t) | Should -Contain "entities"
    }

    It "ignores entities drift when YAML omits the entities key" {
        $d = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType"; displayName = $null; description = $null; entities = @("a@contoso.com") }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It "does NOT report type drift (type is immutable; ADR 0039)" {
        $d = @{ name = "x"; type = "GroupType"; displayName = $null; description = $null; entities = $null }
        $t = @{ name = "x"; type = "UserType";  displayName = $null; description = $null; entities = @() }
        @(Compare-EntityList -Desired $d -Tenant $t).Count | Should -Be 0
    }
}

Describe "ADR 0029 direction-policy context tests" {

    It "script exposes a -DirectionPolicy parameter" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $params | Should -Contain 'DirectionPolicy'
    }

    It "script exposes a -SkipNames parameter" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $params = $ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
        $params | Should -Contain 'SkipNames'
    }

    It "script emits [ADR0029-AUDIT] marker in source text" {
        $src = Get-Content -LiteralPath $script:ScriptPath -Raw
        $src | Should -Match '\[ADR0029-AUDIT\]'
    }

    It "script emits [ADR0029-SKIP] marker in source text" {
        $src = Get-Content -LiteralPath $script:ScriptPath -Raw
        $src | Should -Match '\[ADR0029-SKIP\]'
    }
}