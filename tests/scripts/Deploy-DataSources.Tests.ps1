#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the round-trip determinism helpers in
    `scripts/Deploy-DataSources.ps1`.

.DESCRIPTION
    Issue #322 — exporting Purview data sources via -ExportCurrentState and
    then re-running -WhatIf against the exported YAML must yield only
    NoChange rows. Two helpers guard this contract:

      * Get-ComparableDataSourceProperty -- strips computed fields
        (createdAt, lastModifiedAt, dataSourceCollectionMovingState,
        parentCollection, collection.lastModifiedAt, collection.type)
        from a data source properties hashtable.
      * Compare-DataSourceHash -- compares desired vs. tenant hashes
        after stripping those fields symmetrically.

    The fix prevents the asymmetric DateTime round-trip that
    Invoke-RestMethod's ConvertFrom-Json performs on ISO-8601
    timestamps (parsing them into [DateTime] and re-serializing
    without trailing-zero subseconds) from surfacing as a spurious
    'properties' drift row.

    The production script is a non-module that performs auth at
    import time, so we AST-extract the helper definitions and
    evaluate them into the test scope. See Deploy-LabelPolicies.Tests.ps1
    for the same pattern.

    Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources/get
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-DataSources.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-DataSources.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @(
            'Get-ComparableDataSourceProperty',
            'ConvertTo-CanonicalValue',
            'ConvertTo-ComparableJson',
            'ConvertTo-TenantDataSourceHash',
            'Compare-DataSourceHash')) {

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

    # The helpers reference script-scoped denylists declared at the
    # top of the production script. We mirror them here verbatim so
    # the AST-extracted functions behave the same way they do in the
    # full script.
    $script:DataSourceComputedFields = @(
        'createdAt',
        'lastModifiedAt',
        'dataSourceCollectionMovingState',
        'parentCollection'
    )
    $script:CollectionComputedFields = @(
        'lastModifiedAt',
        'type'
    )
}

Describe 'Get-ComparableDataSourceProperty' {
    It 'strips top-level server-computed fields' {
        $props = @{
            createdAt                       = '2026-03-21T19:56:52.6564990Z'
            lastModifiedAt                  = '2026-03-21T19:56:52.6564990Z'
            dataSourceCollectionMovingState = 0
            parentCollection                = $null
            location                        = 'westus2'
            collection                      = @{ referenceName = 'finance' }
        }

        $result = Get-ComparableDataSourceProperty -Properties $props

        $result.Keys | Should -Not -Contain 'createdAt'
        $result.Keys | Should -Not -Contain 'lastModifiedAt'
        $result.Keys | Should -Not -Contain 'dataSourceCollectionMovingState'
        $result.Keys | Should -Not -Contain 'parentCollection'
        $result.location | Should -Be 'westus2'
        $result.collection.referenceName | Should -Be 'finance'
    }

    It 'strips computed fields inside the nested collection block' {
        $props = @{
            collection = @{
                referenceName  = 'finance'
                lastModifiedAt = '2026-03-21T19:56:52.6564990Z'
                type           = 'CollectionReference'
            }
        }

        $result = Get-ComparableDataSourceProperty -Properties $props

        $result.collection.Keys | Should -Contain 'referenceName'
        $result.collection.Keys | Should -Not -Contain 'lastModifiedAt'
        $result.collection.Keys | Should -Not -Contain 'type'
    }

    It 'returns an empty hashtable when input is null' {
        $result = Get-ComparableDataSourceProperty -Properties $null
        $result | Should -BeOfType [System.Collections.Hashtable]
        $result.Count | Should -Be 0
    }

    It 'preserves user-settable fields unchanged' {
        $props = @{
            endpoint           = 'https://contoso.blob.core.windows.net/'
            dataUseGovernance  = 'Enabled'
            collection         = @{ referenceName = 'finance' }
        }

        $result = Get-ComparableDataSourceProperty -Properties $props

        $result.endpoint          | Should -Be 'https://contoso.blob.core.windows.net/'
        $result.dataUseGovernance | Should -Be 'Enabled'
    }
}

Describe 'Compare-DataSourceHash (round-trip determinism)' {
    It 'returns no diffs for the Synapse trailing-zero subsecond regression (issue #322)' {
        # Synthetic reproduction of the asymmetric round-trip:
        #   - Desired side comes from YAML, where the timestamp string
        #     preserves its trailing-zero subseconds verbatim.
        #   - Tenant side comes from Invoke-RestMethod ConvertFrom-Json,
        #     which parses the same ISO-8601 string into [DateTime] and
        #     re-serializes it without the trailing zero.
        $desired = @{
            name = 'AzureSynapseAnalytics-Sample'
            kind = 'AzureSynapseWorkspace'
            properties = @{
                collection = @{
                    referenceName  = 'finance'
                    lastModifiedAt = '2026-03-21T19:56:52.6564990Z'
                    type           = 'CollectionReference'
                }
                createdAt                       = '2026-03-21T19:56:52.6564990Z'
                lastModifiedAt                  = '2026-03-21T19:56:52.6564990Z'
                dataSourceCollectionMovingState = 0
                parentCollection                = $null
                location                        = 'westus2'
                dataUseGovernance               = 'Disabled'
            }
        }

        $tenant = @{
            name = 'AzureSynapseAnalytics-Sample'
            kind = 'AzureSynapseWorkspace'
            properties = @{
                collection = @{
                    referenceName  = 'finance'
                    lastModifiedAt = '2026-03-21T19:56:52.656499Z'
                    type           = 'CollectionReference'
                }
                createdAt                       = '2026-03-21T19:56:52.656499Z'
                lastModifiedAt                  = '2026-03-21T19:56:52.656499Z'
                dataSourceCollectionMovingState = 0
                parentCollection                = $null
                location                        = 'westus2'
                dataUseGovernance               = 'Disabled'
            }
        }

        $diffs = Compare-DataSourceHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'returns no diffs when tenant carries computed fields the desired YAML omits' {
        $desired = @{
            name = 'AzureBlob-Sample'
            kind = 'AzureBlob'
            properties = @{
                collection        = @{ referenceName = 'finance' }
                endpoint          = 'https://contoso.blob.core.windows.net/'
                dataUseGovernance = 'Enabled'
            }
        }

        $tenant = @{
            name = 'AzureBlob-Sample'
            kind = 'AzureBlob'
            properties = @{
                collection = @{
                    referenceName  = 'finance'
                    lastModifiedAt = '2026-03-21T19:56:52.6564990Z'
                    type           = 'CollectionReference'
                }
                endpoint                        = 'https://contoso.blob.core.windows.net/'
                dataUseGovernance               = 'Enabled'
                createdAt                       = '2026-03-21T19:56:52.6564990Z'
                lastModifiedAt                  = '2026-03-21T19:56:52.6564990Z'
                dataSourceCollectionMovingState = 0
                parentCollection                = $null
            }
        }

        $diffs = Compare-DataSourceHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'still surfaces genuine drift on a user-settable field' {
        $desired = @{
            name = 'AzureBlob-Sample'
            kind = 'AzureBlob'
            properties = @{
                collection        = @{ referenceName = 'finance' }
                endpoint          = 'https://contoso.blob.core.windows.net/'
                dataUseGovernance = 'Enabled'
            }
        }

        $tenant = @{
            name = 'AzureBlob-Sample'
            kind = 'AzureBlob'
            properties = @{
                collection        = @{ referenceName = 'finance' }
                endpoint          = 'https://contoso.blob.core.windows.net/'
                dataUseGovernance = 'Disabled'
            }
        }

        $diffs = Compare-DataSourceHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'properties'
    }

    It 'surfaces a kind mismatch' {
        $desired = @{
            name = 'X'; kind = 'AzureBlob'
            properties = @{ collection = @{ referenceName = 'finance' } }
        }
        $tenant = @{
            name = 'X'; kind = 'AzureDataLakeStorage'
            properties = @{ collection = @{ referenceName = 'finance' } }
        }

        $diffs = Compare-DataSourceHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'kind'
    }
}


Describe 'ADR 0029 direction-policy integration (issue #617)' {

    BeforeAll {
        # Pure decision-helper module — no tenant connection.
        # Reference: docs/adr/0029-source-of-truth-direction-policy.md
        $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
        Import-Module $script:ModulePath -Force -Scope Local -ErrorAction Stop

        # Mirrors the in-script pass. Conflict rows are treated as
        # drift exactly like Update, so portal-wins skips them and
        # repo-wins lets them through.
        function Invoke-Adr0029PassDS {
            param(
                [Parameter(Mandatory)][hashtable[]]$Plan,
                [Parameter(Mandatory)][ValidateSet('audit','portal-wins','repo-wins')][string]$Policy,
                [Parameter()][string[]]$SkipList = @()
            )
            if ($Policy -eq 'audit') { return $Plan }
            foreach ($row in $Plan) {
                if ($row.Action -notin @('Create','Update','NoChange','Orphan','Conflict')) { continue }
                $hasDrift = ($row.Action -eq 'Update' -or $row.Action -eq 'Conflict')
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
        It 'skips Update rows (shared-property drift)' {
            $plan = @(
                @{ Action='Update'; Name='ds1'; Reason='Drift in: endpoint' }
                @{ Action='NoChange'; Name='ds2'; Reason='In sync with tenant.' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'ds2').Action | Should -Be 'NoChange'
        }

        It 'skips Conflict rows the same way as Update rows' {
            # DataSources-specific: Conflict means tracked-field drift
            # + lastModifiedBy differs from the deploy principal. From
            # the source-of-truth-direction angle it is still drift
            # the portal made, so portal-wins skips it.
            #
            # ADR 0053: the direction policy and the authorship override are
            # independent axes and stay that way. -DirectionPolicy arbitrates
            # WHICH source of truth wins on shared-property drift;
            # -OverwriteForeignAuthor arbitrates WHETHER the deploy principal
            # may write over another principal's work.
            $plan = @(
                @{ Action='Conflict'; Name='ds1'; Reason='Drift in: endpoint; lastModifiedBy ... differs.' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Skip'
        }

        It 'leaves Create / Orphan / NoChange rows untouched' {
            $plan = @(
                @{ Action='Create';   Name='ds1'; Reason='Declared in YAML; absent from tenant.' }
                @{ Action='NoChange'; Name='ds2'; Reason='In sync with tenant.' }
                @{ Action='Orphan';   Name='ds3'; Reason='Tenant-only.' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Create'
            ($out | Where-Object Name -eq 'ds2').Action | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'ds3').Action | Should -Be 'Orphan'
        }
    }

    Context 'repo-wins' {
        It 'keeps Update rows as Update (apply will overwrite)' {
            $plan = @(
                @{ Action='Update'; Name='ds1'; Reason='Drift in: endpoint' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Update'
        }

        It 'keeps Conflict rows as Conflict (apply still falls into the -OverwriteForeignAuthor gate)' {
            # ADR 0053 (was: "the script Force gate"). repo-wins proposes to
            # take the repo's content, but a Conflict row is still gated on
            # -OverwriteForeignAuthor, NOT on -Force.
            $plan = @(
                @{ Action='Conflict'; Name='ds1'; Reason='Drift in: endpoint; lastModifiedBy differs.' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Conflict'
        }
    }

    Context '-SkipNames pre-pass' {
        It 'force-skips a name regardless of policy or drift category' {
            $plan = @(
                @{ Action='Update';   Name='ds1'; Reason='Drift in: endpoint' }
                @{ Action='NoChange'; Name='ds2'; Reason='In sync with tenant.' }
                @{ Action='Orphan';   Name='ds3'; Reason='Tenant-only.' }
                @{ Action='Conflict'; Name='ds4'; Reason='Drift + last-mod conflict.' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'repo-wins' -SkipList @('ds1','ds2','ds3','ds4')
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'ds2').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'ds3').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'ds4').Action | Should -Be 'Skip'
        }

        It 'matches -SkipNames case-insensitively' {
            $plan = @(
                @{ Action='Update'; Name='Fabric-Main'; Reason='Drift in: tenant' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'repo-wins' -SkipList @('fabric-main')
            ($out | Where-Object Name -eq 'Fabric-Main').Action | Should -Be 'Skip'
        }
    }

    Context 'audit short-circuit' {
        It 'returns the plan unmodified (consumer flips $WhatIfPreference)' {
            $plan = @(
                @{ Action='Update'; Name='ds1'; Reason='Drift in: endpoint' }
            )
            $out = Invoke-Adr0029PassDS -Plan $plan -Policy 'audit'
            ($out | Where-Object Name -eq 'ds1').Action | Should -Be 'Update'
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
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-DataSources.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-DataSources.ps1'
        if (-not (Test-Path $script:Adr0053Path)) {
            throw "Could not locate Deploy-DataSources.ps1 at: $script:Adr0053Path"
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

        # A drifted data source the PORTAL last touched, versus the deploy principal.
        $script:Adr0053ForeignRaw = [pscustomobject]@{
            name      = 'adr0053-fixture'
            lastModifiedBy = 'portal-admin@contoso.onmicrosoft.com'
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
                lastModifiedBy = $script:Adr0053DeployIdentity
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

Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:DsSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:DsSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:DsSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the data-source noun' {
        $script:DsSource | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:DsSource | Should -Match ([regex]::Escape("-ObjectTypeNoun 'data source'"))
    }
    It 'keys guard 2 on the live tenant data-source count' {
        $script:DsSource | Should -Match ([regex]::Escape('@($tenantRaw).Count'))
    }
    It 'keeps the default threshold at 0.5 (a majority data-source prune is refused)' {
        $script:DsSource | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:DsSource | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
    }
    It 'gates guard 2 on non-audit so a read-only audit run is not refused' {
        $script:DsSource | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:DsSource.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:DsSource.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Prune sanity-ratio guard executed through the script wiring (issue #13, batch 2)' {

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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-DataSources.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $plan = @(for ($i = 0; $i -lt $Prune; $i++) { [pscustomobject]@{ Action = 'Orphan'; Name = "orphan-$i" } })
            $tenantRaw = @(for ($i = 0; $i -lt $Live; $i++) { [pscustomobject]@{ name = "live-$i" } })
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $plan, $tenantRaw
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'does not fire under -DirectionPolicy audit even above the threshold' { { Invoke-Guard2 -Prune 10 -Live 10 -Direction 'audit' } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-DataSources.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-DataSources.ps1; update the anchor in this test.' }
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
            param([string[]]$Names = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Invoke-RestMethod {
                [CmdletBinding()]
                param([string]$Method, [string]$Uri, $Headers, $Body)
                $n = [uri]::UnescapeDataString((($Uri -replace '.*datasources/', '') -replace '\?.*', ''))
                $attempted.Add($n)
                if ($Fail -contains $n) { throw "TenantBlockerException: $n" }
            }
            function Format-PurviewRestError { param($ErrorRecord) $ErrorRecord.Exception.Message }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($Names | ForEach-Object { [pscustomobject]@{ Action = 'Orphan'; Name = $_ } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $plan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every remaining orphan after one fails (loop no longer aborts)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('a')
        $r.Attempted | Should -Be @('a', 'b', 'c')
    }
    It 'reports each individual failure with the tenant error message' {
        $r = Invoke-PruneRegion -Names @('a', 'b') -Fail @('a', 'b')
        $r.Reported.Count | Should -Be 2
        ($r.Reported -join '; ') | Should -Match 'TenantBlockerException: a'
        ($r.Reported -join '; ') | Should -Match 'TenantBlockerException: b'
    }
    It 'throws one aggregate naming every failure (behaviour change: non-zero exit)' {
        $r = Invoke-PruneRegion -Names @('a', 'b', 'c') -Fail @('b', 'c')
        $r.Thrown | Should -Not -BeNullOrEmpty
        $r.Thrown | Should -Match 'Reconciliation aborted'
        $r.Thrown | Should -Match 'b'
        $r.Thrown | Should -Match 'c'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -Names @('a', 'b')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the prune loop behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the aggregate throw and reporter in the lifted region (mutation check vs pre-batch exit-0)' {
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error'
    }
}
