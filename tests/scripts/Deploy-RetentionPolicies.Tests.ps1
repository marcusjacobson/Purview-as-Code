#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in `scripts/Deploy-RetentionPolicies.ps1`.

.DESCRIPTION
    Locks in the Microsoft 365 Data Lifecycle Management reconciler contract:

      1. `ConvertTo-DesiredRetentionPolicyHash` normalizes a YAML policy entry
         into a comparable hashtable; missing optionals collapse to defaults
         (`enabled` => $true, `restrictiveRetention` => $false, missing
         location buckets => @()).
      2. `ConvertTo-DesiredRetentionRuleHash` normalizes a rule entry, preserving
         `retentionDuration` as either `Unlimited` (string) or an integer day
         count per the cmdlet contract.
      3. `ConvertTo-TenantRetentionPolicyHash` normalizes a
         `Get-RetentionCompliancePolicy` row into the same shape, extracting
         per-bucket location names (handling `All` sentinel) and mapping
         `Comment` -> `description`.
      4. `ConvertTo-TenantRetentionRuleHash` normalizes a
         `Get-RetentionComplianceRule` row; `RetentionDuration` parses to
         [int] when numeric, otherwise stays as a string (e.g. `Unlimited`).
      5. `Compare-RetentionPolicy` returns an empty list for in-sync inputs
         and the field names that drift. `enabled` and `restrictiveRetention`
         are always compared; `description` and per-bucket `locations` are
         only compared when declared on the desired side. Location array
         comparisons are order-insensitive.
      6. `Compare-RetentionRule` always compares `retentionDuration` and
         `retentionAction`; other rule fields are compared only when declared.
      7. `Get-RetentionPolicySplat` builds a splat for `New-` (-Name) or
         `Set-` (-Identity), always carries `Enabled`, only emits
         `RestrictiveRetention` when true, and only emits location params
         that the YAML actually declared.
      8. `Get-RetentionRuleSplat` builds a splat for `New-` (-Name + -Policy)
         or `Set-` (-Identity = "PolicyName\RuleName"), always carries
         `RetentionDuration` and `RetentionComplianceAction`, and omits
         unset optionals.

    Pattern: AST-extract each helper from the script and dot-source into the
    test scope. The two script-scope variables the helpers depend on
    (`$script:LocationBuckets`, `$script:LocationBucketNames`) are AST-
    extracted the same way. We deliberately do NOT dot-source the script
    itself -- that would execute its top-level code and try to
    `Connect-IPPSSession` against the live tenant.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-RetentionPolicies.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-RetentionPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    # Seed the two script-scope vars the helpers depend on. Find their
    # assignment statements in the AST and dot-source them.
    $assignAsts = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in @('$script:LocationBuckets', '$script:LocationBucketNames')
        }, $true)
    foreach ($a in $assignAsts) {
        . ([ScriptBlock]::Create($a.Extent.Text))
    }
    if (-not $script:LocationBucketNames -or $script:LocationBucketNames.Count -eq 0) {
        throw 'Failed to seed $script:LocationBucketNames from script AST.'
    }

    foreach ($fname in @(
            'ConvertTo-DesiredRetentionPolicyHash',
            'ConvertTo-DesiredRetentionRuleHash',
            'ConvertTo-TenantRetentionPolicyHash',
            'ConvertTo-TenantRetentionRuleHash',
            'Compare-RetentionPolicy',
            'Compare-RetentionRule',
            'Get-RetentionPolicySplat',
            'Get-RetentionRuleSplat',
            'Resolve-TenantRulePolicyName',
            'Get-RetentionLocationIdentity',
            'Invoke-RetentionExport')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'ConvertTo-DesiredRetentionPolicyHash normalizes YAML entries' {

    It 'collapses missing optionals to defaults (enabled=true, restrictiveRetention=false)' {
        $entry = @{ name = 'lab-rp-min'; rules = @() }
        $hash = ConvertTo-DesiredRetentionPolicyHash -Entry $entry
        $hash.name                 | Should -Be 'lab-rp-min'
        $hash.description          | Should -BeNullOrEmpty
        $hash.enabled              | Should -BeTrue
        $hash.restrictiveRetention | Should -BeFalse
        $hash.rules.Count          | Should -Be 0
        foreach ($b in $script:LocationBucketNames) {
            @($hash.locations[$b]).Count | Should -Be 0
        }
    }

    It 'preserves every declared field' {
        $entry = @{
            name = 'lab-rp-full'
            description = 'lab full'
            enabled = $false
            restrictiveRetention = $true
            locations = @{ exchange = @('user@contoso.com'); sharePoint = 'All' }
            rules = @(@{ name = 'lab-rule-1'; retentionDuration = 365; retentionAction = 'Keep' })
        }
        $hash = ConvertTo-DesiredRetentionPolicyHash -Entry $entry
        $hash.description          | Should -Be 'lab full'
        $hash.enabled              | Should -BeFalse
        $hash.restrictiveRetention | Should -BeTrue
        $hash.locations['exchange']   | Should -Be @('user@contoso.com')
        $hash.locations['sharePoint'] | Should -Be @('All')
        $hash.rules.Count          | Should -Be 1
        $hash.rules[0].name        | Should -Be 'lab-rule-1'
    }

    It 'sorts and de-duplicates location arrays for stable comparison' {
        $entry = @{
            name = 'lab-rp-sort'
            locations = @{ exchange = @('b@contoso.com', 'a@contoso.com', 'a@contoso.com') }
            rules = @()
        }
        $hash = ConvertTo-DesiredRetentionPolicyHash -Entry $entry
        $hash.locations['exchange'] | Should -Be @('a@contoso.com', 'b@contoso.com')
    }

    It 'recognizes the `All` sentinel verbatim and does not split it' {
        $entry = @{ name = 'lab-rp-all'; locations = @{ exchange = 'All' }; rules = @() }
        $hash = ConvertTo-DesiredRetentionPolicyHash -Entry $entry
        $hash.locations['exchange'] | Should -Be @('All')
    }

    It 'seeds every known location bucket even when the YAML omits them' {
        $entry = @{ name = 'lab-rp-buckets'; rules = @() }
        $hash = ConvertTo-DesiredRetentionPolicyHash -Entry $entry
        foreach ($b in $script:LocationBucketNames) {
            $hash.locations.ContainsKey($b) | Should -BeTrue
        }
    }
}

Describe 'ConvertTo-DesiredRetentionRuleHash normalizes rule entries' {

    It 'preserves Unlimited as a string sentinel' {
        $r = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 'Unlimited'; retentionAction = 'Keep' }
        $r.retentionDuration | Should -Be 'Unlimited'
    }

    It 'preserves integer day counts as [int]' {
        $r = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 2555; retentionAction = 'KeepAndDelete' }
        $r.retentionDuration | Should -Be 2555
        $r.retentionDuration | Should -BeOfType ([int])
    }

    It 'collapses optional fields to $null when absent' {
        $r = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 30; retentionAction = 'Delete' }
        $r.description          | Should -BeNullOrEmpty
        $r.expirationDateOption | Should -BeNullOrEmpty
        $r.contentMatchQuery    | Should -BeNullOrEmpty
    }

    It 'preserves all optional fields when declared' {
        $r = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 30; retentionAction = 'Delete'
            description = 'lab d'; expirationDateOption = 'CreationAgeInDays'
            contentMatchQuery = 'Subject:lab'
        }
        $r.description          | Should -Be 'lab d'
        $r.expirationDateOption | Should -Be 'CreationAgeInDays'
        $r.contentMatchQuery    | Should -Be 'Subject:lab'
    }
}

Describe 'ConvertTo-TenantRetentionPolicyHash normalizes Get-RetentionCompliancePolicy rows' {

    It 'maps tracked scalars and Comment -> description' {
        $tenant = [pscustomobject]@{
            Name = 'lab-rp'; Comment = 'lab c'; Enabled = $true; RestrictiveRetention = $false
            ExchangeLocation = @([pscustomobject]@{ Name = 'user@contoso.com' })
        }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.name        | Should -Be 'lab-rp'
        $h.description | Should -Be 'lab c'
        $h.enabled     | Should -BeTrue
        $h.locations['exchange'] | Should -Be @('user@contoso.com')
    }

    It 'collapses null Comment to $null' {
        $tenant = [pscustomobject]@{ Name = 'lab-rp'; Comment = $null; Enabled = $true }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.description | Should -BeNullOrEmpty
    }

    It 'collapses the `All` single-item case to the verbatim sentinel' {
        $tenant = [pscustomobject]@{ Name = 'lab-rp'; Enabled = $true
            SharePointLocation = @('All') }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.locations['sharePoint'] | Should -Be @('All')
    }

    It 'extracts the .Name property from location entries (Exchange shape)' {
        $tenant = [pscustomobject]@{ Name = 'lab-rp'; Enabled = $true
            ExchangeLocation = @(
                [pscustomobject]@{ Name = 'b@contoso.com' },
                [pscustomobject]@{ Name = 'a@contoso.com' }) }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.locations['exchange'] | Should -Be @('a@contoso.com', 'b@contoso.com')
    }

    It 'extracts the .Address fallback when .Name is absent' {
        $tenant = [pscustomobject]@{ Name = 'lab-rp'; Enabled = $true
            ExchangeLocation = @([pscustomobject]@{ Address = 'user@contoso.com' }) }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.locations['exchange'] | Should -Be @('user@contoso.com')
    }
}

Describe 'ConvertTo-TenantRetentionRuleHash normalizes Get-RetentionComplianceRule rows' {

    It 'parses numeric RetentionDuration to [int]' {
        $r = ConvertTo-TenantRetentionRuleHash -Rule ([pscustomobject]@{
            Name = 'lab-rule'; RetentionDuration = '365'; RetentionComplianceAction = 'Keep'
            Policy = 'lab-rp' })
        $r.retentionDuration | Should -Be 365
        $r.retentionDuration | Should -BeOfType ([int])
    }

    It 'preserves Unlimited as a string' {
        $r = ConvertTo-TenantRetentionRuleHash -Rule ([pscustomobject]@{
            Name = 'lab-rule'; RetentionDuration = 'Unlimited'; RetentionComplianceAction = 'Keep'
            Policy = 'lab-rp' })
        $r.retentionDuration | Should -Be 'Unlimited'
    }

    It 'maps Comment -> description and preserves policyName' {
        $r = ConvertTo-TenantRetentionRuleHash -Rule ([pscustomobject]@{
            Name = 'lab-rule'; Comment = 'lab desc'; RetentionDuration = '30'
            RetentionComplianceAction = 'Delete'; Policy = 'lab-rp' })
        $r.description | Should -Be 'lab desc'
        $r.policyName  | Should -Be 'lab-rp'
    }

    It 'collapses null Comment / ExpirationDateOption / ContentMatchQuery to $null' {
        $r = ConvertTo-TenantRetentionRuleHash -Rule ([pscustomobject]@{
            Name = 'lab-rule'; RetentionDuration = '30'; RetentionComplianceAction = 'Delete'
            Policy = 'lab-rp' })
        $r.description          | Should -BeNullOrEmpty
        $r.expirationDateOption | Should -BeNullOrEmpty
        $r.contentMatchQuery    | Should -BeNullOrEmpty
    }
}

Describe 'Compare-RetentionPolicy detects drift and honours YAML-declared fields only' {

    BeforeEach {
        $script:DesiredP = ConvertTo-DesiredRetentionPolicyHash -Entry @{
            name = 'lab-rp'; enabled = $true; restrictiveRetention = $false
            locations = @{ exchange = @('user@contoso.com') }; rules = @() }
        $script:TenantP = @{
            name = 'lab-rp'; description = $null; enabled = $true; restrictiveRetention = $false
            locations = @{ exchange = @('user@contoso.com') }; rules = @() }
        foreach ($b in $script:LocationBucketNames) {
            if (-not $script:TenantP.locations.ContainsKey($b)) { $script:TenantP.locations[$b] = @() }
        }
    }

    It 'returns zero diffs when desired and tenant match' {
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP).Count | Should -Be 0
    }

    It 'reports enabled when the tenant flag differs' {
        $script:TenantP.enabled = $false
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP) | Should -Contain 'enabled'
    }

    It 'reports restrictiveRetention when the tenant flag differs' {
        $script:TenantP.restrictiveRetention = $true
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP) | Should -Contain 'restrictiveRetention'
    }

    It 'reports locations.<bucket> when a declared bucket differs' {
        $script:TenantP.locations['exchange'] = @('other@contoso.com')
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP) | Should -Contain 'locations.exchange'
    }

    It 'does not report locations drift for buckets the YAML omits' {
        $script:TenantP.locations['sharePoint'] = @('All')
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP) | Should -Not -Contain 'locations.sharePoint'
    }

    It 'does not report description as drift when YAML omits it' {
        $script:TenantP.description = 'something'
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP) | Should -Not -Contain 'description'
    }

    It 'is order-insensitive on location arrays' {
        $script:DesiredP.locations['exchange'] = @('a@contoso.com', 'b@contoso.com')
        $script:TenantP.locations['exchange']  = @('b@contoso.com', 'a@contoso.com')
        (Compare-RetentionPolicy -Desired $script:DesiredP -Tenant $script:TenantP).Count | Should -Be 0
    }
}

Describe 'Compare-RetentionRule detects rule-level drift' {

    BeforeEach {
        $script:DesiredR = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 365; retentionAction = 'Keep' }
        $script:TenantR = @{
            name = 'lab-rule'; description = $null; retentionDuration = 365; retentionAction = 'Keep'
            expirationDateOption = $null; contentMatchQuery = $null }
    }

    It 'returns zero diffs when desired and tenant match' {
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR).Count | Should -Be 0
    }

    It 'reports retentionDuration when the integer value differs' {
        $script:TenantR.retentionDuration = 30
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR) | Should -Contain 'retentionDuration'
    }

    It 'reports retentionDuration when one side is Unlimited and the other is numeric' {
        $script:DesiredR.retentionDuration = 'Unlimited'
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR) | Should -Contain 'retentionDuration'
    }

    It 'reports retentionAction when the tenant differs' {
        $script:TenantR.retentionAction = 'KeepAndDelete'
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR) | Should -Contain 'retentionAction'
    }

    It 'does not report contentMatchQuery as drift when YAML omits it' {
        $script:TenantR.contentMatchQuery = 'Subject:something'
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR) | Should -Not -Contain 'contentMatchQuery'
    }

    It 'reports contentMatchQuery when YAML declares a different value' {
        $script:DesiredR.contentMatchQuery = 'Subject:repo'
        $script:TenantR.contentMatchQuery  = 'Subject:portal'
        (Compare-RetentionRule -Desired $script:DesiredR -Tenant $script:TenantR) | Should -Contain 'contentMatchQuery'
    }
}

Describe 'Get-RetentionPolicySplat builds splat tables for New- and Set-' {

    BeforeEach {
        $script:Hash = ConvertTo-DesiredRetentionPolicyHash -Entry @{
            name = 'lab-rp'; description = 'lab d'; enabled = $true
            locations = @{ exchange = @('user@contoso.com') }; rules = @() }
    }

    It 'uses -Name for New- (no -Identity)' {
        $s = Get-RetentionPolicySplat -Hash $script:Hash
        $s.Name | Should -Be 'lab-rp'
        $s.ContainsKey('Identity') | Should -BeFalse
    }

    It 'uses -Identity for -ForSet (no -Name)' {
        $s = Get-RetentionPolicySplat -Hash $script:Hash -ForSet
        $s.Identity | Should -Be 'lab-rp'
        $s.ContainsKey('Name') | Should -BeFalse
    }

    It 'always carries Enabled' {
        $s = Get-RetentionPolicySplat -Hash $script:Hash
        $s.ContainsKey('Enabled') | Should -BeTrue
        $s.Enabled | Should -BeTrue
    }

    It 'omits RestrictiveRetention unless true' {
        $script:Hash.restrictiveRetention = $false
        (Get-RetentionPolicySplat -Hash $script:Hash).ContainsKey('RestrictiveRetention') | Should -BeFalse
        $script:Hash.restrictiveRetention = $true
        (Get-RetentionPolicySplat -Hash $script:Hash).RestrictiveRetention | Should -BeTrue
    }

    It 'emits Comment only when description is declared' {
        $s1 = Get-RetentionPolicySplat -Hash $script:Hash
        $s1.Comment | Should -Be 'lab d'
        $script:Hash.description = $null
        (Get-RetentionPolicySplat -Hash $script:Hash).ContainsKey('Comment') | Should -BeFalse
    }

    It 'only emits location params the YAML declared' {
        $s = Get-RetentionPolicySplat -Hash $script:Hash
        $s.ContainsKey('ExchangeLocation')   | Should -BeTrue
        $s.ContainsKey('SharePointLocation') | Should -BeFalse
    }
}

Describe 'Get-RetentionRuleSplat builds splat tables for New- and Set-' {

    BeforeEach {
        $script:RuleHash = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 365; retentionAction = 'Keep'
            description = 'lab desc' }
    }

    It 'uses -Name + -Policy for New- (no -Identity)' {
        $s = Get-RetentionRuleSplat -Hash $script:RuleHash -PolicyName 'lab-rp'
        $s.Name   | Should -Be 'lab-rule'
        $s.Policy | Should -Be 'lab-rp'
        $s.ContainsKey('Identity') | Should -BeFalse
    }

    It 'uses -Identity = "PolicyName\RuleName" for -ForSet (no -Name / -Policy)' {
        $s = Get-RetentionRuleSplat -Hash $script:RuleHash -PolicyName 'lab-rp' -ForSet
        $s.Identity | Should -Be 'lab-rp\lab-rule'
        $s.ContainsKey('Name')   | Should -BeFalse
        $s.ContainsKey('Policy') | Should -BeFalse
    }

    It 'always carries RetentionDuration and RetentionComplianceAction' {
        $s = Get-RetentionRuleSplat -Hash $script:RuleHash -PolicyName 'lab-rp'
        $s.RetentionDuration         | Should -Be 365
        $s.RetentionComplianceAction | Should -Be 'Keep'
    }

    It 'emits Comment / ExpirationDateOption / ContentMatchQuery only when declared' {
        $minimal = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 30; retentionAction = 'Delete' }
        $s = Get-RetentionRuleSplat -Hash $minimal -PolicyName 'lab-rp'
        $s.ContainsKey('Comment')              | Should -BeFalse
        $s.ContainsKey('ExpirationDateOption') | Should -BeFalse
        $s.ContainsKey('ContentMatchQuery')    | Should -BeFalse

        $full = ConvertTo-DesiredRetentionRuleHash -Entry @{
            name = 'lab-rule'; retentionDuration = 30; retentionAction = 'Delete'
            description = 'd'; expirationDateOption = 'CreationAgeInDays'
            contentMatchQuery = 'Subject:lab' }
        $s2 = Get-RetentionRuleSplat -Hash $full -PolicyName 'lab-rp'
        $s2.Comment              | Should -Be 'd'
        $s2.ExpirationDateOption | Should -Be 'CreationAgeInDays'
        $s2.ContentMatchQuery    | Should -Be 'Subject:lab'
    }
}

Describe 'Resolve-TenantRulePolicyName translates rule.Policy to friendly Name' {

    BeforeEach {
        $script:GuidA = '00000000-0000-0000-0000-000000000001'
        $script:DnA   = 'CN=lab-rp\0ADEL:00000000-0000-0000-0000-000000000001,CN=Deleted Objects,DC=labtenant,DC=onmicrosoft,DC=com'
        $script:TenantPolicies = @(
            [pscustomobject]@{
                Name              = 'lab-rp'
                Identity          = 'lab-rp'
                Guid              = $script:GuidA
                DistinguishedName = $script:DnA
                ExchangeObjectId  = $script:GuidA
                ImmutableId       = $script:GuidA
            },
            [pscustomobject]@{
                Name              = 'lab-rp-other'
                Identity          = 'lab-rp-other'
                Guid              = '00000000-0000-0000-0000-000000000002'
                DistinguishedName = $null
            }
        )
    }

    It 'returns the friendly Name when rule.Policy already matches Name' {
        Resolve-TenantRulePolicyName -RulePolicy 'lab-rp' -TenantPolicies $script:TenantPolicies | Should -Be 'lab-rp'
    }

    It 'translates a Guid-shaped rule.Policy to the friendly Name (the bug)' {
        Resolve-TenantRulePolicyName -RulePolicy $script:GuidA -TenantPolicies $script:TenantPolicies | Should -Be 'lab-rp'
    }

    It 'translates a DistinguishedName-shaped rule.Policy to the friendly Name' {
        Resolve-TenantRulePolicyName -RulePolicy $script:DnA -TenantPolicies $script:TenantPolicies | Should -Be 'lab-rp'
    }

    It 'translates an Identity-shaped rule.Policy to the friendly Name' {
        Resolve-TenantRulePolicyName -RulePolicy 'lab-rp-other' -TenantPolicies $script:TenantPolicies | Should -Be 'lab-rp-other'
    }

    It 'returns the input verbatim when no tenant policy matches (defensive)' {
        Resolve-TenantRulePolicyName -RulePolicy 'unknown-policy-id' -TenantPolicies $script:TenantPolicies | Should -Be 'unknown-policy-id'
    }

    It 'returns the input verbatim when the tenant policy snapshot is empty' {
        Resolve-TenantRulePolicyName -RulePolicy 'whatever' -TenantPolicies @() | Should -Be 'whatever'
    }

    It 'returns the input verbatim when the tenant policy snapshot is $null' {
        Resolve-TenantRulePolicyName -RulePolicy 'whatever' -TenantPolicies $null | Should -Be 'whatever'
    }
}

Describe 'Rule-key composition uses the resolved friendly Name (regression for #573)' {

    It 'builds the same rule key whether rule.Policy is the Name or the Guid' {
        $tenantPolicies = @([pscustomobject]@{
            Name = 'lab-rp-smoke-001'
            Guid = '11111111-1111-1111-1111-111111111111'
        })

        $ruleViaName = [pscustomobject]@{
            Name                       = 'lab-rule-smoke-001'
            Policy                     = 'lab-rp-smoke-001'
            RetentionDuration          = '30'
            RetentionComplianceAction  = 'Keep'
        }
        $ruleViaGuid = [pscustomobject]@{
            Name                       = 'lab-rule-smoke-001'
            Policy                     = '11111111-1111-1111-1111-111111111111'
            RetentionDuration          = '30'
            RetentionComplianceAction  = 'Keep'
        }

        $resolvedName = Resolve-TenantRulePolicyName -RulePolicy ([string]$ruleViaName.Policy) -TenantPolicies $tenantPolicies
        $resolvedGuid = Resolve-TenantRulePolicyName -RulePolicy ([string]$ruleViaGuid.Policy) -TenantPolicies $tenantPolicies

        $keyFromName = '{0}\{1}' -f $resolvedName, $ruleViaName.Name
        $keyFromGuid = '{0}\{1}' -f $resolvedGuid, $ruleViaGuid.Name

        $keyFromName | Should -Be 'lab-rp-smoke-001\lab-rule-smoke-001'
        $keyFromGuid | Should -Be 'lab-rp-smoke-001\lab-rule-smoke-001'
        $keyFromGuid | Should -Be $keyFromName
    }
}

Describe 'Get-RetentionLocationIdentity prefers SMTP / UPN over DisplayName' {

    It 'returns PrimarySmtpAddress when present (regression for #575)' {
        $item = [pscustomobject]@{
            Name                = 'Demo US User'
            PrimarySmtpAddress  = 'demo-us-user@contoso.com'
            DisplayName         = 'Demo US User'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'demo-us-user@contoso.com'
    }

    It 'falls back to WindowsLiveID when PrimarySmtpAddress is absent' {
        $item = [pscustomobject]@{
            Name           = 'Demo US User'
            WindowsLiveID  = 'demo-us-user@contoso.com'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'demo-us-user@contoso.com'
    }

    It 'falls back to UserPrincipalName when SMTP-shaped fields are absent' {
        $item = [pscustomobject]@{
            Name               = 'Demo US User'
            UserPrincipalName  = 'demo-us-user@contoso.com'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'demo-us-user@contoso.com'
    }

    It 'falls back to Address when no SMTP / UPN field is present' {
        $item = [pscustomobject]@{
            Name    = 'Demo US User'
            Address = 'demo-us-user@contoso.com'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'demo-us-user@contoso.com'
    }

    It 'falls back to Url for SharePoint-shaped entries' {
        $item = [pscustomobject]@{
            Name = 'Marketing site'
            Url  = 'https://contoso.sharepoint.com/sites/marketing'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'https://contoso.sharepoint.com/sites/marketing'
    }

    It 'falls back to Name when no SMTP / URL field exists' {
        $item = [pscustomobject]@{ Name = 'Demo US User' }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'Demo US User'
    }

    It 'returns a plain string input unchanged' {
        Get-RetentionLocationIdentity -Item 'demo-us-user@contoso.com' | Should -Be 'demo-us-user@contoso.com'
    }

    It 'returns the All sentinel unchanged' {
        Get-RetentionLocationIdentity -Item 'All' | Should -Be 'All'
    }

    It 'returns $null for a null input' {
        Get-RetentionLocationIdentity -Item $null | Should -BeNullOrEmpty
    }

    It 'treats empty-string SMTP / URL fields as absent and skips to the next field' {
        $item = [pscustomobject]@{
            Name                = 'Demo US User'
            PrimarySmtpAddress  = ''
            WindowsLiveID       = $null
            UserPrincipalName   = 'demo-us-user@contoso.com'
        }
        Get-RetentionLocationIdentity -Item $item | Should -Be 'demo-us-user@contoso.com'
    }
}

Describe 'ConvertTo-TenantRetentionPolicyHash uses SMTP, not DisplayName, for ExchangeLocation (regression for #575)' {

    It 'extracts the SMTP from a recipient-shaped ExchangeLocation entry' {
        $tenant = [pscustomobject]@{
            Name = 'lab-rp'
            Enabled = $true
            ExchangeLocation = @([pscustomobject]@{
                Name                = 'Demo US User'
                PrimarySmtpAddress  = 'demo-us-user@contoso.com'
                DisplayName         = 'Demo US User'
            })
        }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.locations['exchange'] | Should -Be @('demo-us-user@contoso.com')
        $h.locations['exchange'] | Should -Not -Contain 'Demo US User'
    }

    It 'reports zero drift when YAML SMTP matches tenant DisplayName + SMTP shape' {
        $desired = ConvertTo-DesiredRetentionPolicyHash -Entry @{
            name = 'lab-rp'; enabled = $true
            locations = @{ exchange = @('demo-us-user@contoso.com') }; rules = @() }
        $tenant = ConvertTo-TenantRetentionPolicyHash -Policy ([pscustomobject]@{
            Name = 'lab-rp'; Enabled = $true
            ExchangeLocation = @([pscustomobject]@{
                Name                = 'Demo US User'
                PrimarySmtpAddress  = 'demo-us-user@contoso.com'
            })
        })
        (Compare-RetentionPolicy -Desired $desired -Tenant $tenant).Count | Should -Be 0
    }

    It 'still preserves the All sentinel verbatim (no regression on existing behaviour)' {
        $tenant = [pscustomobject]@{
            Name = 'lab-rp'
            Enabled = $true
            SharePointLocation = @('All')
        }
        $h = ConvertTo-TenantRetentionPolicyHash -Policy $tenant
        $h.locations['sharePoint'] | Should -Be @('All')
    }
}

Describe 'Invoke-RetentionExport round-trip (regression for #577)' {

    BeforeAll {
        Import-Module powershell-yaml -Force -ErrorAction Stop
        $script:ExportDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dlm-export-test-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ExportDir -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:ExportDir) {
            Remove-Item -LiteralPath $script:ExportDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'emits a rules: block under each policy even when rule.Policy is a GUID (the bug)' {
        $path = Join-Path $script:ExportDir 'guid-policy.yaml'
        New-Item -Path $path -ItemType File -Force | Out-Null

        $guid = '11111111-1111-1111-1111-111111111111'
        $tenantPolicies = @([pscustomobject]@{
            Name             = 'lab-rp-smoke-001'
            Identity         = 'lab-rp-smoke-001'
            Guid             = $guid
            Enabled          = $true
            Comment          = 'Test policy'
            ExchangeLocation = @([pscustomobject]@{
                Name                = 'Demo US User'
                PrimarySmtpAddress  = 'demo@contoso.com'
            })
        })
        $tenantRules = @([pscustomobject]@{
            Name                       = 'lab-rule-smoke-001'
            Policy                     = $guid
            Comment                    = 'Keep 30 days'
            RetentionDuration          = '30'
            RetentionComplianceAction  = 'Keep'
        })

        Invoke-RetentionExport -Path $path -TenantPolicies $tenantPolicies -TenantRules $tenantRules -Force

        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $doc.policies.Count | Should -Be 1
        $policy = $doc.policies[0]
        $policy.name | Should -Be 'lab-rp-smoke-001'
        $policy.ContainsKey('rules') | Should -BeTrue -Because 'export must emit the rules block (regression for #577)'
        @($policy.rules).Count | Should -Be 1
        $rule = $policy.rules[0]
        $rule.name              | Should -Be 'lab-rule-smoke-001'
        $rule.retentionDuration | Should -Be 30
        $rule.retentionAction   | Should -Be 'Keep'
    }

    It 'emits the rules: block when rule.Policy is the friendly Name (no regression)' {
        $path = Join-Path $script:ExportDir 'name-policy.yaml'
        New-Item -Path $path -ItemType File -Force | Out-Null

        $tenantPolicies = @([pscustomobject]@{
            Name             = 'lab-rp-smoke-001'
            Enabled          = $true
            ExchangeLocation = @([pscustomobject]@{ Name = 'demo@contoso.com' })
        })
        $tenantRules = @([pscustomobject]@{
            Name                       = 'lab-rule-smoke-001'
            Policy                     = 'lab-rp-smoke-001'
            RetentionDuration          = '60'
            RetentionComplianceAction  = 'Keep'
        })

        Invoke-RetentionExport -Path $path -TenantPolicies $tenantPolicies -TenantRules $tenantRules -Force

        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $rule = $doc.policies[0].rules[0]
        $rule.name              | Should -Be 'lab-rule-smoke-001'
        $rule.retentionDuration | Should -Be 60
    }

    It 'extracts the SMTP from a recipient-shaped ExchangeLocation entry on export' {
        $path = Join-Path $script:ExportDir 'smtp-location.yaml'
        New-Item -Path $path -ItemType File -Force | Out-Null

        $tenantPolicies = @([pscustomobject]@{
            Name             = 'lab-rp-smoke-001'
            Enabled          = $true
            ExchangeLocation = @([pscustomobject]@{
                Name                = 'Demo US User'
                PrimarySmtpAddress  = 'demo@contoso.com'
            })
        })

        Invoke-RetentionExport -Path $path -TenantPolicies $tenantPolicies -TenantRules @() -Force

        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $doc.policies[0].locations.exchange | Should -Be @('demo@contoso.com')
    }

    It 'preserves the All sentinel on export' {
        $path = Join-Path $script:ExportDir 'all-sentinel.yaml'
        New-Item -Path $path -ItemType File -Force | Out-Null

        $tenantPolicies = @([pscustomobject]@{
            Name               = 'lab-rp-smoke-001'
            Enabled            = $true
            SharePointLocation = @('All')
        })

        Invoke-RetentionExport -Path $path -TenantPolicies $tenantPolicies -TenantRules @() -Force

        $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Yaml
        $doc.policies[0].locations.sharePoint | Should -Be 'All'
    }
}

# ---------------------------------------------------------------------------
# ADR 0029 source-of-truth direction-policy contract on the DLM reconciler.
# These tests are source-text (regex) assertions on parameter declarations
# plus behavior tests against the shared
# scripts/modules/DirectionPolicy.psm1 module. Issue: #571. Precedent:
# tests/scripts/Deploy-Labels.Tests.ps1 and
# tests/scripts/Deploy-DLPPolicies.Tests.ps1.
# ---------------------------------------------------------------------------

Describe 'DirectionPolicy parameter (ADR 0029) -- DLM' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'declares a -DirectionPolicy parameter with the audit/portal-wins/repo-wins ValidateSet' {
        $script:ScriptText | Should -Match '\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'defaults -DirectionPolicy to portal-wins per ADR 0029' {
        $script:ScriptText | Should -Match '\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'attaches -DirectionPolicy to both Apply and Export parameter sets' {
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy'
    }

    It 'declares -SkipNames on the Apply parameter set only' {
        # The workflow uses -SkipNames to pass a pre-computed skip
        # list to the script; Export does not need it.
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }

    It 'imports the shared DirectionPolicy.psm1 module rather than re-inlining the resolver' {
        $script:ScriptText | Should -Match 'Import-Module\s+\(Join-Path\s+\$PSScriptRoot\s+''modules/DirectionPolicy\.psm1''\)'
        $script:ScriptText | Should -Not -Match 'function\s+Resolve-DirectionPolicyAction'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029) -- DLM' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
            -Force -ErrorAction Stop
    }

    It 'has an audit-mode short-circuit that emits [ADR0029-AUDIT] and sets $WhatIfPreference = $true' {
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''[^}]*\$WhatIfPreference\s*=\s*\$true\s*\r?\n\s*\}'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'portal-wins'
    }

    It 'returns Update when policy is portal-wins and no drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'emits one Write-Warning per drifted retention policy on repo-wins' {
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on retention policy '''
    }

    It 'emits one Write-Warning per drifted retention rule on repo-wins' {
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on retention rule '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped object for workflow consumption' {
        # Format must match `^\[ADR0029-SKIP\] (.+)$` per
        # github-actions.instructions.md.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }
}

Describe 'SkipNames behavior (ADR 0029) -- DLM' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
            -Force -ErrorAction Stop
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-rp-smoke-001') `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is false' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('lab-rp-smoke-001') `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('LAB-RP-SMOKE-001') `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-rp-smoke') `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames' {
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchPolicy') `
                -DisplayName 'lab-rp-smoke-001' `
                -HasDrift    $true } | Should -Not -Throw
    }

    It 'handles an empty SkipList without error' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-rp-smoke-001' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }
}

# ---------------------------------------------------------------------------
# Issue #13, part C batch 4: guard 2 (PER-TIER prune sanity ratio) and the
# failure reporter. The prune catches previously added a 'Failed' report row
# and moved on -- a failed prune exited 0. The regions below are lifted from
# the REAL script source (not transcribed) and executed against stubs, so the
# tests cannot keep passing after the script regresses.
# ---------------------------------------------------------------------------
Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 4)' {

    BeforeAll {
        $script:B4Source = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:B4Source | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:B4Source | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard once PER TIER with tier-specific nouns' {
        ([regex]::Matches($script:B4Source, 'Assert-PruneRatioWithinThreshold\s+`')).Count | Should -Be 2
        $script:B4Source | Should -Match ([regex]::Escape("-ObjectTypeNoun 'retention rule'"))
        $script:B4Source | Should -Match ([regex]::Escape("-ObjectTypeNoun 'retention policy'"))
    }
    It 'keys the rule tier on the SAME $pruneTargets the ADR 0052 prompt reads (full blast radius, incl. orphan-parent cascade)' {
        $script:B4Source | Should -Match ([regex]::Escape('@($pruneTargets | Where-Object { $_ -like "rule ''*" }).Count'))
        $script:B4Source | Should -Match ([regex]::Escape('@($tenantRules).Count'))
        $script:B4Source | Should -Match ([regex]::Escape('@($tenantPolicies).Count'))
    }
    It 'surfaces the ratio override and threshold parameters on the Apply parameter set' {
        $script:B4Source | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:B4Source | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters['AllowMajorityPrune'].ParameterSets.Keys | Should -Not -Contain 'Export'
        $cmd.Parameters['MaxPruneRatio'].ParameterSets.Keys | Should -Not -Contain 'Export'
    }
    It 'gates guard 2 on non-audit (AUDIT TRAP: script flips WhatIfPreference, does not empty prune targets)' {
        $script:B4Source | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'places guard 2 before the ADR 0052 prune confirmation gate' {
        $ratioIdx = $script:B4Source.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:B4Source.IndexOf('-PruneMissing will DELETE')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Per-tier prune sanity-ratio guard executed through the script wiring (issue #13, batch 4)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'PruneGuard.psm1') -Force -ErrorAction Stop
        $lines = @(Get-Content -LiteralPath $script:ScriptPath)
        $start = -1; $end = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*if \(\$PruneMissing\.IsPresent') {
                $depth = 0; $e = -1
                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $depth += ([regex]::Matches($lines[$j], '\{')).Count
                    $depth -= ([regex]::Matches($lines[$j], '\}')).Count
                    if ($depth -le 0) { $e = $j; break }
                }
                $cand = ($lines[$i..$e] -join [Environment]::NewLine)
                if ($cand -match 'Assert-PruneRatioWithinThreshold') { $start = $i; $end = $e; break }
            }
        }
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-RetentionPolicies.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$RulePrunes, [int]$LiveRules, [int]$PolicyOrphans, [int]$LivePolicies, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $pruneTargets = @(
                @(for ($i = 0; $i -lt $RulePrunes; $i++) { "rule 'P\r$i'" }) +
                @(for ($i = 0; $i -lt $PolicyOrphans; $i++) { "policy 'orphan-$i'" })
            )
            $policyPlan = @(
                @(for ($i = 0; $i -lt $PolicyOrphans; $i++) { [pscustomobject]@{ Name = "orphan-$i"; Action = 'Orphan' } }) +
                @([pscustomobject]@{ Name = 'kept'; Action = 'NoChange' })
            )
            $tenantRules    = @(for ($i = 0; $i -lt $LiveRules; $i++) { [pscustomobject]@{ Name = "live-rule-$i" } })
            $tenantPolicies = @(for ($i = 0; $i -lt $LivePolicies; $i++) { [pscustomobject]@{ Name = "live-policy-$i" } })
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $pruneTargets, $policyPlan, $tenantRules, $tenantPolicies
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes when both tiers sit at or below the threshold' {
        { Invoke-Guard2 -RulePrunes 2 -LiveRules 10 -PolicyOrphans 1 -LivePolicies 4 } | Should -Not -Throw
    }
    It 'throws when the RULE blast radius exceeds the threshold even though the blended ratio would pass (the per-tier point)' {
        { Invoke-Guard2 -RulePrunes 4 -LiveRules 4 -PolicyOrphans 0 -LivePolicies 16 } | Should -Throw
    }
    It 'throws when the POLICY tier exceeds the threshold' {
        { Invoke-Guard2 -RulePrunes 0 -LiveRules 16 -PolicyOrphans 4 -LivePolicies 4 } | Should -Throw
    }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' {
        { Invoke-Guard2 -RulePrunes 4 -LiveRules 4 -PolicyOrphans 4 -LivePolicies 4 -Allow } | Should -Not -Throw
    }
    It 'does NOT fire under -DirectionPolicy audit even above the threshold (audit trap)' {
        { Invoke-Guard2 -RulePrunes 4 -LiveRules 4 -PolicyOrphans 4 -LivePolicies 4 -Direction 'audit' } | Should -Not -Throw
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 4)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-RetentionPolicies.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-RetentionPolicies.ps1; update the anchor in this test.' }
        $depth = 0; $e = -1
        for ($j = $ifStart; $j -lt $script:RepLines.Count; $j++) {
            $depth += ([regex]::Matches($script:RepLines[$j], '\{')).Count
            $depth -= ([regex]::Matches($script:RepLines[$j], '\}')).Count
            if ($depth -le 0) { $e = $j; break }
        }
        $script:ReporterRegion = ($script:RepLines[$s..$e] -join [Environment]::NewLine)
        $script:ReporterShouldProcessCount = ([regex]::Matches($script:ReporterRegion, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:ReporterRunnable = $script:ReporterRegion -replace '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        function Invoke-PruneRegion {
            # Scenario shape: orphan rules under the still-desired policy
            # 'KeptPolicy', plus orphan policies each carrying one child rule
            # that is removed with the parent.
            param([string[]]$OrphanRuleNames = @(), [string[]]$OrphanPolicyNames = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Remove-RetentionComplianceRule {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add("rule:$Identity")
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Remove-RetentionCompliancePolicy {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add("policy:$Identity")
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $desiredPolicyNames = @('KeptPolicy')
            $desiredRuleKeys = @('KeptPolicy\KeptRule')
            $tenantRuleByKey = [ordered]@{}
            $tenantRuleByKey['KeptPolicy\KeptRule'] = [pscustomobject]@{ policyName = 'KeptPolicy' }
            foreach ($n in $OrphanRuleNames) {
                $tenantRuleByKey[('KeptPolicy\{0}' -f $n)] = [pscustomobject]@{ policyName = 'KeptPolicy' }
            }
            $tenantRules = @($OrphanPolicyNames | ForEach-Object { [pscustomobject]@{ Policy = $_; Name = 'ChildRule' } })
            $policyPlan = @($OrphanPolicyNames | ForEach-Object { [pscustomobject]@{ Name = $_; Action = 'Orphan'; Reason = 'test' } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $desiredPolicyNames, $desiredRuleKeys, $tenantRuleByKey, $tenantRules, $policyPlan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every prune population after a failure: orphan rules, cascade child rules, then the orphan parent' {
        $r = Invoke-PruneRegion -OrphanRuleNames @('r1', 'r2') -OrphanPolicyNames @('P2') -Fail @('KeptPolicy\r1')
        $r.Attempted | Should -Be @('rule:KeptPolicy\r1', 'rule:KeptPolicy\r2', 'rule:P2\ChildRule', 'policy:P2')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -OrphanRuleNames @('r1') -OrphanPolicyNames @('P2') -Fail @('P2')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException: P2'
    }
    It 'throws one aggregate naming every failure across all three populations (exit-0 defect fixed)' {
        $r = Invoke-PruneRegion -OrphanRuleNames @('r1') -OrphanPolicyNames @('P2') -Fail @('KeptPolicy\r1', 'P2\ChildRule', 'P2')
        $r.Thrown | Should -Match ([regex]::Escape("rule 'KeptPolicy\r1'"))
        $r.Thrown | Should -Match ([regex]::Escape("rule 'P2\ChildRule'"))
        $r.Thrown | Should -Match ([regex]::Escape("policy 'P2'"))
        $r.Thrown | Should -Match '3 orphan retention object'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -OrphanRuleNames @('r1') -OrphanPolicyNames @('P2')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the deletes behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the reporter and the aggregate throw in the lifted region (mutation check vs pre-batch exit-0)' {
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}
