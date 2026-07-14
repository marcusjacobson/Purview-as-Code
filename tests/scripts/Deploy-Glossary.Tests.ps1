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

# ---------------------------------------------------------------------------
# ADR 0053 -- the foreign-author override is split out of -Force into its own
# switch, -OverwriteForeignAuthor.
#
# Mechanism A script. Two things had to change, and the second is the one the
# first attempt got wrong:
#
#   1. Test-ConflictRow must no longer consult -Force. (Done.)
#   2. Test-ConflictRow must no longer consult ANY override switch. It is a PURE
#      authorship predicate. Merely renaming its -ForceEnabled parameter to
#      -OverwriteForeignAuthor would have preserved the suppress-at-source
#      short-circuit -- the object gets overwritten AND the Conflict row vanishes
#      -- which is precisely the alternative ADR 0053 §Alternatives-5 rejects by
#      name ("the switch grants permission, not silence").
#
# The override decision therefore lives in the pure Resolve-ConflictPlanAction,
# mirroring Mechanism B's Get-ReconciliationPlan. The contract pinned below:
#
#   neither switch            -> Conflict row emitted, NOT overwritten
#   -Force alone              -> Conflict row emitted, NOT overwritten
#   -OverwriteForeignAuthor   -> Conflict row STILL emitted, overwritten
#
# Reference: docs/adr/0053-overwrite-foreign-author-switch.md
# ---------------------------------------------------------------------------
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-Glossary.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Glossary.ps1'
        if (-not (Test-Path $script:Adr0053Path)) {
            throw "Could not locate Deploy-Glossary.ps1 at: $script:Adr0053Path"
        }
        $script:Adr0053Source = Get-Content -Path $script:Adr0053Path -Raw

        $adr0053Tokens = $null
        $adr0053Errors = $null
        $script:Adr0053Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Adr0053Path, [ref]$adr0053Tokens, [ref]$adr0053Errors)
        if ($adr0053Errors.Count -gt 0) {
            throw ($adr0053Errors | ForEach-Object Message | Out-String)
        }

        foreach ($fnName in @('Get-LastModifiedByIdentity', 'Test-ConflictRow', 'Resolve-ConflictPlanAction')) {
            $fnAst = $script:Adr0053Ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fnName
                }, $true)
            if (-not $fnAst) { throw "Function $fnName not found in $script:Adr0053Path" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # A drifted glossary term the PORTAL last touched, versus the deploy principal.
        $script:Adr0053ForeignRaw = [pscustomobject]@{
            name      = 'adr0053-fixture'
            updatedBy = 'portal-admin@contoso.onmicrosoft.com'
        }
        $script:Adr0053DeployIdentity = 'gh-oidc-purview-data-plane'
    }

    Context 'Parameter surface -- Apply set only' {

        It 'declares -OverwriteForeignAuthor in the Apply parameter set' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $apply = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Apply' })
            $apply.Count | Should -Be 1
            $apply[0].Parameters.Name | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'does NOT declare -OverwriteForeignAuthor in the Export parameter set' {
            # The export path writes a local YAML file. No tenant object's
            # authorship is in question there, so the switch must be unbindable.
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            $export = @($cmd.ParameterSets | Where-Object { $_.Name -eq 'Export' })
            $export.Count | Should -Be 1
            $export[0].Parameters.Name | Should -Not -Contain 'OverwriteForeignAuthor'
        }

        It 'keeps -Force bindable in BOTH parameter sets (the Export-path callers do not break)' {
            $cmd = Get-Command -Name $script:Adr0053Path -CommandType ExternalScript
            foreach ($setName in @('Apply', 'Export')) {
                $set = @($cmd.ParameterSets | Where-Object { $_.Name -eq $setName })
                $set[0].Parameters.Name | Should -Contain 'Force'
            }
        }
    }

    Context 'Test-ConflictRow is a PURE authorship predicate' {

        It 'no longer exposes a -ForceEnabled parameter' {
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Not -Contain 'ForceEnabled'
        }

        It 'does NOT expose an -OverwriteForeignAuthor parameter either -- it knows about NO override switch' {
            # This is the assertion the first attempt at ADR 0053 lacked. Renaming
            # -ForceEnabled to -OverwriteForeignAuthor keeps the suppress-at-source
            # short-circuit and ships the alternative the ADR rejects by name.
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Not -Contain 'OverwriteForeignAuthor'
        }

        It 'takes exactly TenantRaw and DeployIdentity (no override input at all)' {
            $declared = @((Get-Command Test-ConflictRow).Parameters.Keys |
                Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
            $declared | Should -Contain 'TenantRaw'
            $declared | Should -Contain 'DeployIdentity'
            $declared.Count | Should -Be 2
        }

        It 'returns TRUE for a foreign-authored object' {
            Test-ConflictRow `
                -TenantRaw $script:Adr0053ForeignRaw `
                -DeployIdentity $script:Adr0053DeployIdentity | Should -BeTrue
        }

        It 'returns FALSE for an object the deploy principal itself last authored' {
            $ownRaw = [pscustomobject]@{
                name      = 'adr0053-fixture'
                updatedBy = $script:Adr0053DeployIdentity
            }
            Test-ConflictRow `
                -TenantRaw $ownRaw `
                -DeployIdentity $script:Adr0053DeployIdentity | Should -BeFalse
        }
    }

    Context 'Resolve-ConflictPlanAction -- the override grants permission, NOT silence' {

        It 'under -Force alone: EMITS the Conflict row and does NOT overwrite' {
            # -Force alone leaves $OverwriteForeignAuthor.IsPresent = $false.
            # The row must be a Conflict, and the plan action must NOT be Update.
            $d = Resolve-ConflictPlanAction `
                -IsConflict $true `
                -OverwriteForeignAuthor $false `
                -DriftText 'description' `
                -Who 'portal-admin@contoso.onmicrosoft.com'

            $d.Category | Should -Be 'Conflict'
            $d.Conflict | Should -BeTrue
            $d.Action   | Should -Be 'Conflict'
            $d.Action   | Should -Not -Be 'Update'
            $d.Reason   | Should -Match 'Re-run with -OverwriteForeignAuthor to overwrite'
        }

        It 'under -OverwriteForeignAuthor: STILL emits the Conflict row, AND overwrites' {
            # The assertion the first attempt was missing entirely. Mechanism B had
            # it; Mechanism A did not, and shipped the rejected alternative.
            $d = Resolve-ConflictPlanAction `
                -IsConflict $true `
                -OverwriteForeignAuthor $true `
                -DriftText 'description' `
                -Who 'portal-admin@contoso.onmicrosoft.com'

            $d.Category | Should -Be 'Conflict'   # <-- the row does NOT vanish
            $d.Conflict | Should -BeTrue
            $d.Action   | Should -Be 'Update'     # <-- and the write DOES proceed
            $d.Reason   | Should -Match 'overwritten because -OverwriteForeignAuthor was supplied'
        }

        It 'never launders a foreign-author overwrite into a plain Update category' {
            foreach ($ofa in @($true, $false)) {
                $d = Resolve-ConflictPlanAction `
                    -IsConflict $true `
                    -OverwriteForeignAuthor $ofa `
                    -DriftText 'description' `
                    -Who 'portal-admin@contoso.onmicrosoft.com'
                $d.Category | Should -Be 'Conflict'
                $d.Conflict | Should -BeTrue
            }
        }

        It 'leaves a non-conflicted drifted object as a plain Update, regardless of the switch' {
            foreach ($ofa in @($true, $false)) {
                $d = Resolve-ConflictPlanAction `
                    -IsConflict $false `
                    -OverwriteForeignAuthor $ofa `
                    -DriftText 'description' `
                    -Who ''
                $d.Category | Should -Be 'Update'
                $d.Action   | Should -Be 'Update'
                $d.Conflict | Should -BeFalse
            }
        }
    }

    Context 'Call-site binding' {

        It 'calls Test-ConflictRow with NO override argument (purity is enforced at the call site too)' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Test-ConflictRow'
                    }, $true))

            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $callText = $call.Extent.Text
                $callText | Should -Not -Match '\$Force'
                $callText | Should -Not -Match '-ForceEnabled'
                $callText | Should -Not -Match '-OverwriteForeignAuthor'
            }
        }

        It 'routes the override through Resolve-ConflictPlanAction, bound from $OverwriteForeignAuthor and never from $Force' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Resolve-ConflictPlanAction'
                    }, $true))

            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $callText = $call.Extent.Text
                $callText | Should -Match '-OverwriteForeignAuthor \$OverwriteForeignAuthor\.IsPresent'
                $callText | Should -Not -Match '\$Force\.IsPresent'
            }
        }

        It 'derives the report category for an Update from the row Conflict flag' {
            # Guards the apply-loop half: a Conflict-flagged Update must report as
            # 'Conflict', not 'Update'. Without this the plan is right and the
            # drift report still lies.
            $script:Adr0053Source | Should -Match "\`$updateCategory = if \(\`$row\.PSObject\.Properties\['Conflict'\] -and \`$row\.Conflict\) \{ 'Conflict' \} else \{ 'Update' \}"
            $script:Adr0053Source | Should -Match 'Category = \$updateCategory|Category \$updateCategory'
        }

        It 'names -OverwriteForeignAuthor (not -Force) in the Conflict row Reason text' {
            $script:Adr0053Source | Should -Match 'Re-run with -OverwriteForeignAuthor to overwrite'
        }

        It 'carries no ambient $ConfirmPreference self-disarm (ADR 0053 section 4)' {
            # AST, not raw text -- a raw-text regex would match a COMMENT quoting
            # the forbidden assignment, which is the read-a-comment-as-code error
            # ADR 0053 exists to record.
            $assignments = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $node.Left.VariablePath.UserPath -eq 'ConfirmPreference'
                    }, $true))
            $assignments.Count | Should -Be 0
        }
    }
}
