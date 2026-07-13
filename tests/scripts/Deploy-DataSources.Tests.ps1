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
# This is a Mechanism A script: before ADR 0053, Test-ConflictRow opened with
# `if ($ForceEnabled) { return $false }` and was called with
# `-ForceEnabled $Force.IsPresent`, so a -Force run SUPPRESSED the Conflict
# classification entirely and silently overwrote the portal-authored object as
# a plain Update. These tests pin the corrected contract:
#
#   * -Force alone            => Conflict row IS emitted, object NOT overwritten.
#   * -OverwriteForeignAuthor => overwrite permitted, Conflict row still emitted.
#   * the switch lives in the Apply parameter set only.
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

        foreach ($fnName in @('Get-LastModifiedByIdentity', 'Test-ConflictRow')) {
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

    Context 'Test-ConflictRow consults -OverwriteForeignAuthor, never -Force' {

        It 'no longer exposes a -ForceEnabled parameter' {
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Not -Contain 'ForceEnabled'
        }

        It 'exposes -OverwriteForeignAuthor instead' {
            (Get-Command Test-ConflictRow).Parameters.Keys | Should -Contain 'OverwriteForeignAuthor'
        }

        It 'EMITS the Conflict row for a foreign-authored object when the override is absent (-Force alone)' {
            # The load-bearing assertion. -Force alone leaves
            # $OverwriteForeignAuthor.IsPresent = $false, so the classifier must
            # still return $true and the plan builder must emit a Conflict row
            # rather than an Update. Pre-ADR-0053 this returned $false under
            # -Force and the object was silently overwritten.
            Test-ConflictRow `
                -TenantRaw $script:Adr0053ForeignRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $false | Should -BeTrue
        }

        It 'permits the overwrite only when -OverwriteForeignAuthor is supplied' {
            Test-ConflictRow `
                -TenantRaw $script:Adr0053ForeignRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $true | Should -BeFalse
        }

        It 'does not flag an object the deploy principal itself last authored' {
            $ownRaw = [pscustomobject]@{
                name      = 'adr0053-fixture'
                lastModifiedBy = $script:Adr0053DeployIdentity
            }
            Test-ConflictRow `
                -TenantRaw $ownRaw `
                -DeployIdentity $script:Adr0053DeployIdentity `
                -OverwriteForeignAuthor $false | Should -BeFalse
        }
    }

    Context 'Call-site binding' {

        It 'binds every Test-ConflictRow call from $OverwriteForeignAuthor and never from $Force' {
            $calls = @($script:Adr0053Ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -eq 'Test-ConflictRow'
                    }, $true))

            $calls.Count | Should -BeGreaterThan 0
            foreach ($call in $calls) {
                $callText = $call.Extent.Text
                $callText | Should -Match '-OverwriteForeignAuthor\s+\$OverwriteForeignAuthor\.IsPresent'
                $callText | Should -Not -Match '\$Force'
                $callText | Should -Not -Match '-ForceEnabled'
            }
        }

        It 'names -OverwriteForeignAuthor (not -Force) in the Conflict row Reason text' {
            $script:Adr0053Source | Should -Match 'Re-run with -OverwriteForeignAuthor to overwrite'
        }

        It 'carries no ambient $ConfirmPreference self-disarm (ADR 0053 section 4)' {
            # AST, not raw text -- see the note in the Mechanism B test files.
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
