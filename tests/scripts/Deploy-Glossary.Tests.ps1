#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the round-trip determinism helpers in
    `scripts/Deploy-Glossary.ps1`.

.DESCRIPTION
    Issue #628 — Phase 1+2 reconciler per ADR 0026. Exporting via
    -ExportCurrentState and then re-running -WhatIf against the
    exported YAML must yield only NoChange rows. The strip+compare
    helpers guard this contract.

    The production script is a non-module that performs auth at
    import time, so we AST-extract the helper definitions and
    evaluate them into the test scope. See Deploy-DataSources.Tests.ps1
    for the same pattern.

    Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Glossary.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-Glossary.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @(
            'Get-ComparableTermProperty',
            'ConvertTo-CanonicalValue',
            'ConvertTo-ComparableJson',
            'ConvertTo-DesiredTermHash',
            'ConvertTo-TenantTermHash',
            'Compare-TermHash')) {

        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fnName
            }, $true)

        if (-not $fnAst) {
            throw "Function $fnName not found in $script:ScriptPath"
        }

        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Mirror the script-scoped denylists so AST-extracted functions behave
    # the same way they do in the production script.
    $script:TermComputedFields = @(
        'guid',
        'qualifiedName',
        'anchor',
        'createTime',
        'createdBy',
        'updateTime',
        'updatedBy',
        'lastModifiedTS',
        'version',
        'classifications',
        'attributes',
        'additionalAttributes'
    )
    $script:TermDeferredFields = @('experts', 'stewards')
}

Describe 'Get-ComparableTermProperty' {
    It 'strips server-computed identity and timestamp fields' {
        $term = @{
            guid           = '00000000-0000-0000-0000-000000000000'
            qualifiedName  = 'Customer@Glossary'
            createTime     = 1700000000000
            createdBy      = 'ServiceAdmin'
            updateTime     = 1700000001000
            updatedBy      = 'ServiceAdmin'
            lastModifiedTS = '1'
            version        = 2
            anchor         = @{ glossaryGuid = '11111111-1111-1111-1111-111111111111' }
            name           = 'Customer'
            shortDescription = 'A person who buys.'
        }
        $result = Get-ComparableTermProperty -Term $term
        $result.Keys | Should -Not -Contain 'guid'
        $result.Keys | Should -Not -Contain 'qualifiedName'
        $result.Keys | Should -Not -Contain 'createTime'
        $result.Keys | Should -Not -Contain 'createdBy'
        $result.Keys | Should -Not -Contain 'updateTime'
        $result.Keys | Should -Not -Contain 'updatedBy'
        $result.Keys | Should -Not -Contain 'anchor'
        $result.Keys | Should -Not -Contain 'version'
        $result.name             | Should -Be 'Customer'
        $result.shortDescription | Should -Be 'A person who buys.'
    }

    It 'strips Phase 3+4 deferred fields (experts, stewards)' {
        # Issue #628 out-of-scope: ADR 0023 Category 3 wiring lands later.
        $term = @{
            name     = 'Customer'
            experts  = @(@{ id = 'objectId-1'; info = 'Alice' })
            stewards = @(@{ id = 'objectId-2'; info = 'Bob' })
        }
        $result = Get-ComparableTermProperty -Term $term
        $result.Keys | Should -Not -Contain 'experts'
        $result.Keys | Should -Not -Contain 'stewards'
        $result.name | Should -Be 'Customer'
    }

    It 'returns an empty hashtable when input is null' {
        $result = Get-ComparableTermProperty -Term $null
        $result | Should -BeOfType [System.Collections.Hashtable]
        $result.Count | Should -Be 0
    }

    It 'preserves user-settable fields unchanged' {
        $term = @{
            name             = 'PII'
            shortDescription = 'Personally Identifiable Information.'
            longDescription  = 'Any data that can be used to identify a specific individual.'
            status           = 'Approved'
        }
        $result = Get-ComparableTermProperty -Term $term
        $result.name             | Should -Be 'PII'
        $result.shortDescription | Should -Be 'Personally Identifiable Information.'
        $result.longDescription  | Should -Match 'identify a specific individual'
        $result.status           | Should -Be 'Approved'
    }
}

Describe 'Compare-TermHash (round-trip determinism)' {
    It 'returns no diffs when tenant carries computed identity fields the desired YAML omits' {
        $desired = @{
            name             = 'Customer'
            shortDescription = 'A person or organization that purchases goods or services.'
            longDescription  = 'Any external party with an active or prior commercial relationship.'
            status           = 'Approved'
        }
        $tenant = @{
            guid             = '00000000-0000-0000-0000-000000000000'
            qualifiedName    = 'Customer@Glossary'
            anchor           = @{ glossaryGuid = '11111111-1111-1111-1111-111111111111' }
            createTime       = 1700000000000
            createdBy        = 'ServiceAdmin'
            updateTime       = 1700000001000
            updatedBy        = 'ServiceAdmin'
            name             = 'Customer'
            shortDescription = 'A person or organization that purchases goods or services.'
            longDescription  = 'Any external party with an active or prior commercial relationship.'
            status           = 'Approved'
        }
        $diffs = Compare-TermHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'returns no diffs when tenant carries Phase 3+4 deferred experts/stewards the desired YAML omits' {
        $desired = @{
            name             = 'Customer'
            shortDescription = 'A person who buys.'
            status           = 'Approved'
        }
        $tenant = @{
            name             = 'Customer'
            shortDescription = 'A person who buys.'
            status           = 'Approved'
            experts          = @(@{ id = 'objectId-1'; info = 'Alice' })
            stewards         = @(@{ id = 'objectId-2'; info = 'Bob' })
        }
        $diffs = Compare-TermHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'surfaces genuine drift on shortDescription' {
        $desired = @{ name = 'Customer'; shortDescription = 'New text.'; status = 'Approved' }
        $tenant  = @{ name = 'Customer'; shortDescription = 'Old text.'; status = 'Approved' }
        $diffs = Compare-TermHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'shortDescription'
    }

    It 'surfaces genuine drift on status' {
        $desired = @{ name = 'PII'; shortDescription = 'Same.'; status = 'Approved' }
        $tenant  = @{ name = 'PII'; shortDescription = 'Same.'; status = 'Draft' }
        $diffs = Compare-TermHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'status'
    }

    It 'treats absent longDescription on desired equivalently to empty string on tenant' {
        # The YAML scaffold for `RevenueRecognition` omits longDescription
        # entirely. Atlas returns the field as an empty string. Both must
        # compare equal so a freshly-imported YAML reports NoChange.
        $desired = @{ name = 'RevenueRecognition'; shortDescription = 'Policy.'; status = 'Draft' }
        $tenant  = @{ name = 'RevenueRecognition'; shortDescription = 'Policy.'; status = 'Draft'; longDescription = '' }
        $diffs = Compare-TermHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DesiredTermHash (validation)' {
    It 'accepts the YAML scaffold shape verbatim' {
        $term = @{
            name             = 'Customer'
            shortDescription = 'A person or organization that purchases goods or services.'
            longDescription  = "Any external party with an active or prior commercial relationship.`n"
            status           = 'Approved'
            expert           = @()
            steward          = @()
        }
        $h = ConvertTo-DesiredTermHash -Term $term
        $h.name             | Should -Be 'Customer'
        $h.shortDescription | Should -Match 'purchases goods or services'
        $h.status           | Should -Be 'Approved'
    }

    It 'throws when name is missing' {
        $term = @{ shortDescription = 'Orphaned term'; status = 'Draft' }
        { ConvertTo-DesiredTermHash -Term $term } | Should -Throw -ExpectedMessage "*missing required field 'name'*"
    }

    It 'accepts a term with only name + shortDescription (minimal valid shape)' {
        $term = @{ name = 'Minimal'; shortDescription = 'A bare term.' }
        $h = ConvertTo-DesiredTermHash -Term $term
        $h.name             | Should -Be 'Minimal'
        $h.shortDescription | Should -Be 'A bare term.'
    }
}

Describe 'ADR 0029 direction-policy pass (Glossary terms)' {
    # Tests for the direction-policy decision matrix applied to the
    # glossary term plan rows. Mirrors the Collections pattern in
    # Deploy-Collections.Tests.ps1.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md

    BeforeAll {
        $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
        Import-Module $script:ModulePath -Force -Scope Local -ErrorAction Stop

        # Reusable: apply the same direction-policy pass logic the
        # Deploy-Glossary.ps1 #region ADR 0029 implements for Term rows.
        function Invoke-GlossaryAdr0029Pass {
            param(
                [Parameter(Mandatory)][hashtable[]]$Plan,
                [Parameter(Mandatory)][ValidateSet('audit','portal-wins','repo-wins')][string]$Policy,
                [Parameter()][string[]]$SkipList = @()
            )
            if ($Policy -eq 'audit') { return $Plan }
            foreach ($row in $Plan) {
                if ($row.Kind -ne 'Term') { continue }
                if ($row.Action -notin @('Create','Update','NoChange','Orphan','Conflict')) { continue }
                $hasDrift = ($row.Action -eq 'Update')
                $decision = Resolve-DirectionPolicyAction `
                    -Policy      $Policy `
                    -SkipList    $SkipList `
                    -DisplayName ([string]$row.Name) `
                    -HasDrift    $hasDrift
                if ($decision.Action -eq 'Skip') {
                    $row.Action = 'Skip'
                    $row.Reason = $decision.Reason
                }
            }
            return $Plan
        }
    }

    Context 'portal-wins (default)' {

        It 'skips Update rows (shared-property drift on term fields)' {
            $plan = @(
                @{ Kind='Term'; Action='Update'; Name='Customer'; Reason='Drift in: shortDescription' }
                @{ Kind='Term'; Action='NoChange'; Name='PII'; Reason='In sync with tenant.' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'Customer').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'PII').Action      | Should -Be 'NoChange'
        }

        It 'leaves Create / Orphan / NoChange term rows untouched' {
            $plan = @(
                @{ Kind='Term'; Action='Create';   Name='NewTerm'; Reason='Declared in YAML; absent from tenant.' }
                @{ Kind='Term'; Action='NoChange'; Name='PII';     Reason='In sync with tenant.' }
                @{ Kind='Term'; Action='Orphan';   Name='OldTerm'; Reason='Tenant-only.' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'NewTerm').Action | Should -Be 'Create'
            ($out | Where-Object Name -eq 'PII').Action     | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'OldTerm').Action | Should -Be 'Orphan'
        }

        It 'does not touch Glossary container rows (Kind=Glossary)' {
            $plan = @(
                @{ Kind='Glossary'; Action='NoChange'; Name='Glossary'; Reason='Container exists.' }
                @{ Kind='Term';     Action='Update';   Name='Customer'; Reason='Drift in: status' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Kind -eq 'Glossary').Action | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'Customer').Action | Should -Be 'Skip'
        }
    }

    Context 'repo-wins' {

        It 'keeps Update rows as Update (apply will overwrite term fields)' {
            $plan = @(
                @{ Kind='Term'; Action='Update'; Name='Customer'; Reason='Drift in: shortDescription' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'Customer').Action | Should -Be 'Update'
        }
    }

    Context '-SkipNames pre-pass' {

        It 'force-skips a term name regardless of policy or drift category' {
            $plan = @(
                @{ Kind='Term'; Action='Update'; Name='Customer'; Reason='Drift in: longDescription' }
                @{ Kind='Term'; Action='Orphan'; Name='OldTerm';  Reason='Tenant-only.' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'repo-wins' -SkipList @('Customer','OldTerm')
            ($out | Where-Object Name -eq 'Customer').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'OldTerm').Action  | Should -Be 'Skip'
        }

        It 'matches -SkipNames case-insensitively' {
            $plan = @(
                @{ Kind='Term'; Action='Update'; Name='revenuerecognition'; Reason='Drift in: status' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'repo-wins' -SkipList @('RevenueRecognition')
            ($out | Where-Object Name -eq 'revenuerecognition').Action | Should -Be 'Skip'
        }
    }

    Context 'audit short-circuit' {

        It 'returns the plan unmodified (consumer flips $WhatIfPreference)' {
            $plan = @(
                @{ Kind='Term'; Action='Update'; Name='Customer'; Reason='Drift in: status' }
            )
            $out = Invoke-GlossaryAdr0029Pass -Plan $plan -Policy 'audit'
            ($out | Where-Object Name -eq 'Customer').Action | Should -Be 'Update'
        }
    }
}