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
