#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in
    `scripts/Set-AuditRetentionPolicy.ps1`.

.DESCRIPTION
    Locks in the Wave 2a (issue #69) reconciler contract:

      1. `ConvertTo-DesiredPolicyHash` normalizes a YAML entry into a
         comparable hashtable; missing optionals collapse to @() / $null.
      2. `ConvertTo-TenantPolicyHash` normalizes a
         `Get-UnifiedAuditLogRetentionPolicy` result into the same shape.
      3. `Compare-AuditPolicy` returns an empty list for in-sync inputs
         and surfaces the exact field names that drift; only fields the
         YAML actually declares are compared (a missing description /
         priority / array in YAML is not a diff against a tenant that
         has them set). Array comparisons are order-insensitive.
         `retentionDuration` is always compared.
      4. `Get-AuditPolicySplat` builds a splat for `New-` (-Name) or
         `Set-` (-Identity), omits unset optionals, and always carries
         `RetentionDuration`.

    Pattern: AST-extract each function definition and dot-source it
    into the test scope. We deliberately do NOT dot-source the script
    itself -- that would execute its top-level code and try to install
    `ExchangeOnlineManagement` / `Connect-IPPSSession` / acquire a
    Key Vault-signed JWT. The Pester suite is unit-only per
    `tests/Run-Pester.ps1`.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-unifiedauditlogretentionpolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-unifiedauditlogretentionpolicy
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Set-AuditRetentionPolicy.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Set-AuditRetentionPolicy.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @(
            'ConvertTo-DesiredPolicyHash',
            'ConvertTo-TenantPolicyHash',
            'Compare-AuditPolicy',
            'Get-AuditPolicySplat')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'ConvertTo-DesiredPolicyHash normalizes YAML entries' {

    It 'preserves all fields when fully populated' {
        $h = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Default'
            description       = 'lab default'
            recordTypes       = @('AzureActiveDirectory', 'ExchangeAdmin')
            operations        = @('FileAccessed')
            userIds           = @('user@contoso.com')
            retentionDuration = 'OneYear'
            priority          = 100
        }
        $h.name              | Should -Be 'AR-Default'
        $h.description       | Should -Be 'lab default'
        $h.retentionDuration | Should -Be 'OneYear'
        $h.priority          | Should -Be 100
        $h.recordTypes.Count | Should -Be 2
        $h.operations.Count  | Should -Be 1
        $h.userIds.Count     | Should -Be 1
    }

    It 'collapses missing description and priority to $null' {
        $h = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Lean'
            recordTypes       = @('AzureActiveDirectory')
            retentionDuration = 'OneYear'
        }
        $h.description | Should -BeNullOrEmpty
        $h.priority    | Should -BeNullOrEmpty
        $h.operations  | Should -BeNullOrEmpty
        $h.userIds     | Should -BeNullOrEmpty
    }

    It 'sorts recordTypes / operations / userIds for stable comparison' {
        $h = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Sort'
            recordTypes       = @('ExchangeAdmin', 'AzureActiveDirectory')
            operations        = @('FileDeleted', 'FileAccessed')
            userIds           = @('z@contoso.com', 'a@contoso.com')
            retentionDuration = 'OneYear'
        }
        ($h.recordTypes -join ',') | Should -Be 'AzureActiveDirectory,ExchangeAdmin'
        ($h.operations  -join ',') | Should -Be 'FileAccessed,FileDeleted'
        ($h.userIds     -join ',') | Should -Be 'a@contoso.com,z@contoso.com'
    }
}

Describe 'ConvertTo-TenantPolicyHash normalizes Get-UnifiedAuditLogRetentionPolicy output' {

    It 'maps every tracked field from a tenant PSObject' {
        $policy = [pscustomobject]@{
            Name              = 'AR-Default'
            Description       = 'lab default'
            RecordTypes       = @('ExchangeAdmin', 'AzureActiveDirectory')
            Operations        = @('FileAccessed')
            UserIds           = @('user@contoso.com')
            RetentionDuration = 'ThreeYears'
            Priority          = 50
        }
        $h = ConvertTo-TenantPolicyHash -Policy $policy
        $h.name              | Should -Be 'AR-Default'
        $h.description       | Should -Be 'lab default'
        $h.retentionDuration | Should -Be 'ThreeYears'
        $h.priority          | Should -Be 50
        ($h.recordTypes -join ',') | Should -Be 'AzureActiveDirectory,ExchangeAdmin'
        $h.operations.Count | Should -Be 1
        $h.userIds.Count    | Should -Be 1
    }

    It 'treats empty / null tenant collections as empty arrays' {
        $policy = [pscustomobject]@{
            Name              = 'AR-Empty'
            Description       = $null
            RecordTypes       = $null
            Operations        = @()
            UserIds           = @('')
            RetentionDuration = 'OneYear'
            Priority          = $null
        }
        $h = ConvertTo-TenantPolicyHash -Policy $policy
        $h.description       | Should -BeNullOrEmpty
        $h.priority          | Should -BeNullOrEmpty
        $h.recordTypes.Count | Should -Be 0
        $h.operations.Count  | Should -Be 0
        # Empty-string entries are filtered (Where-Object { $_ }).
        $h.userIds.Count     | Should -Be 0
    }
}

Describe 'Compare-AuditPolicy detects drift and respects YAML declaration scope' {

    BeforeEach {
        $script:desired = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Default'
            description       = 'lab default'
            recordTypes       = @('AzureActiveDirectory', 'ExchangeAdmin')
            operations        = @('FileAccessed')
            userIds           = @('user@contoso.com')
            retentionDuration = 'OneYear'
            priority          = 100
        }
        $script:tenant = ConvertTo-TenantPolicyHash -Policy ([pscustomobject]@{
                Name              = 'AR-Default'
                Description       = 'lab default'
                RecordTypes       = @('ExchangeAdmin', 'AzureActiveDirectory')
                Operations        = @('FileAccessed')
                UserIds           = @('user@contoso.com')
                RetentionDuration = 'OneYear'
                Priority          = 100
            })
    }

    It 'returns zero diffs when desired and tenant match' {
        (Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant).Count | Should -Be 0
    }

    It 'is order-insensitive on recordTypes / operations / userIds' {
        $tenantShuffled = ConvertTo-TenantPolicyHash -Policy ([pscustomobject]@{
                Name              = 'AR-Default'
                Description       = 'lab default'
                RecordTypes       = @('ExchangeAdmin', 'AzureActiveDirectory')
                Operations        = @('FileAccessed')
                UserIds           = @('user@contoso.com')
                RetentionDuration = 'OneYear'
                Priority          = 100
            })
        (Compare-AuditPolicy -Desired $script:desired -Tenant $tenantShuffled).Count | Should -Be 0
    }

    It 'reports recordTypes when the tenant set differs' {
        $script:tenant.recordTypes = @('ExchangeAdmin')
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'recordTypes'
    }

    It 'reports operations when the tenant set differs' {
        $script:tenant.operations = @('FileDeleted')
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'operations'
    }

    It 'reports userIds when the tenant set differs' {
        $script:tenant.userIds = @('other@contoso.com')
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'userIds'
    }

    It 'reports retentionDuration on any difference' {
        $script:tenant.retentionDuration = 'ThreeYears'
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'retentionDuration'
    }

    It 'reports description when the tenant value differs' {
        $script:tenant.description = 'stale description'
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'description'
    }

    It 'reports priority when the tenant value differs' {
        $script:tenant.priority = 999
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'priority'
    }

    It 'does not report description as drift when YAML omits it' {
        $lean = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Default'
            recordTypes       = @('AzureActiveDirectory', 'ExchangeAdmin')
            operations        = @('FileAccessed')
            userIds           = @('user@contoso.com')
            retentionDuration = 'OneYear'
        }
        $rich = ConvertTo-TenantPolicyHash -Policy ([pscustomobject]@{
                Name              = 'AR-Default'
                Description       = 'something the tenant has but YAML never declared'
                RecordTypes       = @('AzureActiveDirectory', 'ExchangeAdmin')
                Operations        = @('FileAccessed')
                UserIds           = @('user@contoso.com')
                RetentionDuration = 'OneYear'
                Priority          = 555
            })
        (Compare-AuditPolicy -Desired $lean -Tenant $rich).Count | Should -Be 0
    }

    It 'does not report array drift when the YAML declares an empty / missing array' {
        $lean = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Default'
            recordTypes       = @('AzureActiveDirectory')
            retentionDuration = 'OneYear'
        }
        $rich = ConvertTo-TenantPolicyHash -Policy ([pscustomobject]@{
                Name              = 'AR-Default'
                Description       = $null
                RecordTypes       = @('AzureActiveDirectory')
                Operations        = @('FileAccessed', 'FileDeleted')
                UserIds           = @('user@contoso.com')
                RetentionDuration = 'OneYear'
                Priority          = $null
            })
        (Compare-AuditPolicy -Desired $lean -Tenant $rich).Count | Should -Be 0
    }

    It 'reports multiple fields when several drift simultaneously' {
        $script:tenant.recordTypes       = @('ExchangeAdmin')
        $script:tenant.retentionDuration = 'ThreeYears'
        $script:tenant.priority          = 200
        $diffs = Compare-AuditPolicy -Desired $script:desired -Tenant $script:tenant
        $diffs | Should -Contain 'recordTypes'
        $diffs | Should -Contain 'retentionDuration'
        $diffs | Should -Contain 'priority'
        $diffs.Count | Should -Be 3
    }
}

Describe 'Get-AuditPolicySplat builds splat tables for New- and Set-' {

    BeforeAll {
        $script:hash = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Default'
            description       = 'lab default'
            recordTypes       = @('AzureActiveDirectory', 'ExchangeAdmin')
            operations        = @('FileAccessed')
            userIds           = @('user@contoso.com')
            retentionDuration = 'OneYear'
            priority          = 100
        }
    }

    It 'uses -Name for New- (no -Identity)' {
        $s = Get-AuditPolicySplat -Hash $script:hash
        $s.ContainsKey('Name')     | Should -BeTrue
        $s.ContainsKey('Identity') | Should -BeFalse
        $s.Name                    | Should -Be 'AR-Default'
    }

    It 'uses -Identity for -ForSet (no -Name)' {
        $s = Get-AuditPolicySplat -Hash $script:hash -ForSet
        $s.ContainsKey('Identity') | Should -BeTrue
        $s.ContainsKey('Name')     | Should -BeFalse
        $s.Identity                | Should -Be 'AR-Default'
    }

    It 'always carries RetentionDuration' {
        (Get-AuditPolicySplat -Hash $script:hash).RetentionDuration         | Should -Be 'OneYear'
        (Get-AuditPolicySplat -Hash $script:hash -ForSet).RetentionDuration | Should -Be 'OneYear'
    }

    It 'omits Description / Priority when the hash has $null for them' {
        $lean = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Lean'
            recordTypes       = @('AzureActiveDirectory')
            retentionDuration = 'OneYear'
        }
        $s = Get-AuditPolicySplat -Hash $lean
        $s.ContainsKey('Description') | Should -BeFalse
        $s.ContainsKey('Priority')    | Should -BeFalse
    }

    It 'omits empty optional arrays' {
        $lean = ConvertTo-DesiredPolicyHash -Entry @{
            name              = 'AR-Lean'
            recordTypes       = @('AzureActiveDirectory')
            retentionDuration = 'OneYear'
        }
        $s = Get-AuditPolicySplat -Hash $lean
        $s.ContainsKey('Operations') | Should -BeFalse
        $s.ContainsKey('UserIds')    | Should -BeFalse
        $s.ContainsKey('RecordTypes') | Should -BeTrue
    }
}

Describe 'ADR 0029 direction-policy pass (Audit Retention)' {
    # Tests for the direction-policy decision matrix applied to the
    # audit retention policy plan rows. Mirrors the Glossary pattern in
    # Deploy-Glossary.Tests.ps1.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md

    BeforeAll {
        $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
        Import-Module $script:ModulePath -Force -Scope Local -ErrorAction Stop

        # Reusable: apply the same direction-policy pass logic the
        # Set-AuditRetentionPolicy.ps1 ADR 0029 block implements for
        # Policy rows.
        function Invoke-AuditRetentionAdr0029Pass {
            param(
                [Parameter(Mandatory)][hashtable[]]$Plan,
                [Parameter(Mandatory)][ValidateSet('audit','portal-wins','repo-wins')][string]$Policy,
                [Parameter()][string[]]$SkipList = @()
            )
            if ($Policy -eq 'audit') { return $Plan }
            foreach ($row in $Plan) {
                if ($row.Action -ne 'Update') { continue }
                $decision = Resolve-DirectionPolicyAction `
                    -Policy      $Policy `
                    -SkipList    $SkipList `
                    -DisplayName ([string]$row.Name) `
                    -HasDrift    $true
                if ($decision.Action -eq 'Skip') {
                    $row.Action = 'Skip'
                    $row.Reason = $decision.Reason
                }
            }
            return $Plan
        }
    }

    Context 'portal-wins (default)' {

        It 'skips Update rows (shared-property drift on policy fields)' {
            $plan = @(
                @{ Action='Update';   Name='AR-E5';     Reason='Drift in: retentionDuration' }
                @{ Action='NoChange'; Name='AR-Default'; Reason='In sync with tenant.' }
            )
            $out = Invoke-AuditRetentionAdr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'AR-E5').Action     | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'AR-Default').Action | Should -Be 'NoChange'
        }

        It 'leaves Create / Orphan / NoChange rows untouched' {
            $plan = @(
                @{ Action='Create';   Name='AR-New';  Reason='Declared in YAML; absent from tenant.' }
                @{ Action='NoChange'; Name='AR-OK';   Reason='In sync with tenant.' }
                @{ Action='Orphan';   Name='AR-Old';  Reason='Tenant-only.' }
            )
            $out = Invoke-AuditRetentionAdr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'AR-New').Action | Should -Be 'Create'
            ($out | Where-Object Name -eq 'AR-OK').Action  | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'AR-Old').Action | Should -Be 'Orphan'
        }
    }

    Context 'repo-wins' {

        It 'keeps Update rows as Update (apply will overwrite policy fields)' {
            $plan = @(
                @{ Action='Update'; Name='AR-E5'; Reason='Drift in: retentionDuration' }
            )
            $out = Invoke-AuditRetentionAdr0029Pass -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'AR-E5').Action | Should -Be 'Update'
        }
    }

    Context 'audit short-circuit' {

        It 'returns the plan unmodified (consumer sets $WhatIfPreference = $true)' {
            $plan = @(
                @{ Action='Update'; Name='AR-E5'; Reason='Drift in: recordTypes' }
            )
            $out = Invoke-AuditRetentionAdr0029Pass -Plan $plan -Policy 'audit'
            ($out | Where-Object Name -eq 'AR-E5').Action | Should -Be 'Update'
        }
    }
}
