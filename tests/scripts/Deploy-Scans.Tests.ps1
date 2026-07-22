#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the round-trip determinism helpers in
    `scripts/Deploy-Scans.ps1`.

.DESCRIPTION
    Issue #329 — Wave 4a-ii-a full-circle reconciler for Microsoft Purview
    scans, scan rulesets, and triggers. Exporting via -ExportCurrentState
    and then re-running -WhatIf against the exported YAML must yield only
    NoChange rows. The strip+compare helpers guard this contract.

    The production script is a non-module that performs auth at import
    time, so we AST-extract the helper definitions and evaluate them
    into the test scope. See Deploy-DataSources.Tests.ps1 for the same
    pattern.

    Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans
    Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets
    Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/triggers
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Scans.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-Scans.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fnName in @(
            'Get-ComparableScanProperty',
            'ConvertTo-CanonicalValue',
            'ConvertTo-ComparableJson',
            'ConvertTo-DesiredScanHash',
            'ConvertTo-DesiredScanRulesetHash',
            'Compare-ScanHash',
            'Compare-ScanRulesetHash',
            'Compare-TriggerHash')) {

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
    $script:ScanComputedFields = @(
        'createdAt',
        'lastModifiedAt',
        'lastRunStatus',
        'scanRulesetVersion'
    )
    $script:ScanRulesetComputedFields = @(
        'createdAt',
        'lastModifiedAt',
        'version',
        'status'
    )
    $script:TriggerComputedFields = @(
        'createdAt',
        'lastModifiedAt',
        'scanId'
    )
    $script:CollectionComputedFields = @(
        'lastModifiedAt',
        'type'
    )
}

Describe 'Get-ComparableScanProperty' {
    It 'strips top-level server-computed scan fields' {
        $props = @{
            createdAt          = '2026-05-01T02:00:00.6564990Z'
            lastModifiedAt     = '2026-05-01T02:00:00.6564990Z'
            lastRunStatus      = 'Succeeded'
            scanRulesetVersion = 3
            scanRulesetName    = 'AdlsGen2'
            scanRulesetType    = 'System'
            collection         = @{ referenceName = 'finance' }
        }

        $result = Get-ComparableScanProperty -Properties $props -ComputedFields $script:ScanComputedFields

        $result.Keys | Should -Not -Contain 'createdAt'
        $result.Keys | Should -Not -Contain 'lastModifiedAt'
        $result.Keys | Should -Not -Contain 'lastRunStatus'
        $result.Keys | Should -Not -Contain 'scanRulesetVersion'
        $result.scanRulesetName | Should -Be 'AdlsGen2'
        $result.scanRulesetType | Should -Be 'System'
        $result.collection.referenceName | Should -Be 'finance'
    }

    It 'strips computed fields inside the nested collection block' {
        $props = @{
            collection = @{
                referenceName  = 'finance'
                lastModifiedAt = '2026-05-01T02:00:00.6564990Z'
                type           = 'CollectionReference'
            }
        }

        $result = Get-ComparableScanProperty -Properties $props -ComputedFields $script:ScanComputedFields

        $result.collection.Keys | Should -Contain 'referenceName'
        $result.collection.Keys | Should -Not -Contain 'lastModifiedAt'
        $result.collection.Keys | Should -Not -Contain 'type'
    }

    It 'returns an empty hashtable when input is null' {
        $result = Get-ComparableScanProperty -Properties $null -ComputedFields $script:ScanComputedFields
        $result | Should -BeOfType [System.Collections.Hashtable]
        $result.Count | Should -Be 0
    }

    It 'preserves user-settable fields unchanged' {
        $props = @{
            scanRulesetName = 'AdlsGen2'
            scanRulesetType = 'System'
            collection      = @{ referenceName = 'finance' }
        }

        $result = Get-ComparableScanProperty -Properties $props -ComputedFields $script:ScanComputedFields

        $result.scanRulesetName | Should -Be 'AdlsGen2'
        $result.scanRulesetType | Should -Be 'System'
    }
}

Describe 'Compare-ScanHash (round-trip determinism)' {
    It 'returns no diffs when tenant carries computed fields the desired YAML omits' {
        $desired = @{
            name = 'contosolabsrc01-weekly'
            kind = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName = 'AdlsGen2'
                scanRulesetType = 'System'
                collection      = @{ referenceName = 'finance' }
            }
        }

        $tenant = @{
            name = 'contosolabsrc01-weekly'
            kind = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName    = 'AdlsGen2'
                scanRulesetType    = 'System'
                scanRulesetVersion = 3
                lastRunStatus      = 'Succeeded'
                createdAt          = '2026-05-01T02:00:00.6564990Z'
                lastModifiedAt     = '2026-05-01T02:00:00.6564990Z'
                collection         = @{
                    referenceName  = 'finance'
                    lastModifiedAt = '2026-05-01T02:00:00.656499Z'
                    type           = 'CollectionReference'
                }
            }
        }

        $diffs = Compare-ScanHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'still surfaces genuine drift on a user-settable field' {
        $desired = @{
            name = 'contosolabsrc01-weekly'; kind = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName = 'AdlsGen2'
                scanRulesetType = 'System'
                collection      = @{ referenceName = 'finance' }
            }
        }
        $tenant = @{
            name = 'contosolabsrc01-weekly'; kind = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName = 'AdlsGen2Detailed'
                scanRulesetType = 'System'
                collection      = @{ referenceName = 'finance' }
            }
        }

        $diffs = Compare-ScanHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'properties'
    }

    It 'surfaces a kind mismatch' {
        $desired = @{
            name = 'x'; kind = 'AdlsGen2Msi'
            properties = @{ scanRulesetName = 'AdlsGen2'; scanRulesetType = 'System'; collection = @{ referenceName = 'finance' } }
        }
        $tenant = @{
            name = 'x'; kind = 'AdlsGen2'
            properties = @{ scanRulesetName = 'AdlsGen2'; scanRulesetType = 'System'; collection = @{ referenceName = 'finance' } }
        }

        $diffs = Compare-ScanHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'kind'
    }
}

Describe 'Compare-TriggerHash' {
    It 'returns no diffs when both desired and tenant lack a trigger' {
        $diffs = Compare-TriggerHash -Desired $null -Tenant $null
        $diffs | Should -BeNullOrEmpty
    }

    It 'surfaces presence drift when desired declares a trigger but tenant has none' {
        $desired = @{ recurrence = @{ frequency = 'Week'; interval = 1 } }
        $diffs = Compare-TriggerHash -Desired $desired -Tenant $null
        $diffs | Should -Contain 'presence'
    }

    It 'surfaces presence drift when tenant has a trigger but desired omits it' {
        $tenant = @{ recurrence = @{ frequency = 'Week'; interval = 1 } }
        $diffs = Compare-TriggerHash -Desired $null -Tenant $tenant
        $diffs | Should -Contain 'presence'
    }

    It 'returns no diffs when triggers are equivalent after stripping computed fields' {
        $desired = @{ recurrence = @{ frequency = 'Week'; interval = 1; timezone = 'UTC' } }
        $tenant = @{
            createdAt      = '2026-05-01T02:00:00.6564990Z'
            lastModifiedAt = '2026-05-01T02:00:00.6564990Z'
            scanId         = '00000000-0000-0000-0000-000000000000'
            recurrence     = @{ frequency = 'Week'; interval = 1; timezone = 'UTC' }
        }

        $diffs = Compare-TriggerHash -Desired $desired -Tenant $tenant
        $diffs | Should -BeNullOrEmpty
    }

    It 'surfaces genuine drift on a recurrence field' {
        $desired = @{ recurrence = @{ frequency = 'Week'; interval = 1 } }
        $tenant  = @{ recurrence = @{ frequency = 'Day';  interval = 1 } }

        $diffs = Compare-TriggerHash -Desired $desired -Tenant $tenant
        $diffs | Should -Contain 'properties'
    }
}

Describe 'ConvertTo-DesiredScanHash (validation)' {
    It 'accepts a scan that omits top-level scanRulesetName (per-resource-type ruleset; v2 §5.5 row 3 / #371)' {
        # AzureSynapseWorkspaceMsi carries scanRulesetName under
        # properties.resourceTypes.<rt>; FabricMsi / DatabricksUnityCatalog
        # carry no ruleset at all. The validator must not reject these
        # kinds for missing top-level scanRulesetName -- the REST surface
        # validates per-kind at apply time.
        $scan = @{
            dataSource = 'AzureSynapseAnalytics-RegulatedFinanceReporting'
            name       = 'Scan-RegulatedFinanceReporting'
            kind       = 'AzureSynapseWorkspaceMsi'
            properties = @{
                resourceTypes = @{
                    AzureSynapseServerlessSql = @{
                        scanRulesetName = 'AzureSynapseSQL'
                        scanRulesetType = 'System'
                    }
                }
                collection = @{ referenceName = 'finance' }
            }
        }
        { ConvertTo-DesiredScanHash -Scan $scan } | Should -Not -Throw
    }

    It 'accepts a scan that omits both scanRulesetName and scanRulesetType (Fabric / Databricks)' {
        $scan = @{
            dataSource = 'Fabric-Main'
            name       = 'Scan-Test-Workspace'
            kind       = 'FabricMsi'
            properties = @{
                collection                = @{ referenceName = 'finance' }
                includePersonalWorkspaces = $true
            }
        }
        { ConvertTo-DesiredScanHash -Scan $scan } | Should -Not -Throw
    }

    It 'throws when properties.collection.referenceName is missing' {
        $scan = @{
            dataSource = 'contosolabsrc01'
            name       = 'weekly'
            kind       = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName = 'AdlsGen2'
                scanRulesetType = 'System'
                collection      = @{}
            }
        }
        { ConvertTo-DesiredScanHash -Scan $scan } | Should -Throw -ExpectedMessage '*collection.referenceName*'
    }

    It 'accepts a complete scan and surfaces the optional trigger' {
        $scan = @{
            dataSource = 'contosolabsrc01'
            name       = 'weekly'
            kind       = 'AdlsGen2Msi'
            properties = @{
                scanRulesetName = 'AdlsGen2'
                scanRulesetType = 'System'
                collection      = @{ referenceName = 'finance' }
            }
            trigger = @{ recurrence = @{ frequency = 'Week'; interval = 1 } }
        }
        $h = ConvertTo-DesiredScanHash -Scan $scan
        $h.name | Should -Be 'weekly'
        $h.dataSource | Should -Be 'contosolabsrc01'
        $h.trigger.recurrence.frequency | Should -Be 'Week'
    }
}

Describe 'ADR 0029 direction-policy integration (issue #620)' {

    BeforeAll {
        # Pure decision-helper module -- no tenant connection.
        # Reference: docs/adr/0029-source-of-truth-direction-policy.md
        $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
        Import-Module $script:ModulePath -Force -Scope Local -ErrorAction Stop

        # Mirrors the in-script pass. Conflict rows are treated as
        # drift exactly like Update, so portal-wins skips them and
        # repo-wins lets them through. Scans plan rows carry both a
        # Kind ('ScanRuleset' / 'Scan' / 'Trigger') and an Action,
        # but the ADR 0029 decision is kind-agnostic: it looks only
        # at the row's Name + Action.
        function Invoke-Adr0029PassScans {
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
        It 'skips Update rows on every kind (shared-property drift)' {
            $plan = @(
                @{ Kind='ScanRuleset'; Action='Update';   Name='MyRules';                                         Reason='Drift in: properties' }
                @{ Kind='Scan';        Action='Update';   Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='Drift in: properties' }
                @{ Kind='Trigger';     Action='Update';   Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='Trigger drift: properties' }
                @{ Kind='Scan';        Action='NoChange'; Name='AzureBlob-SampleData/Scan-Other';                 Reason='In sync with tenant.' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object { $_.Kind -eq 'ScanRuleset' -and $_.Name -eq 'MyRules' }).Action | Should -Be 'Skip'
            ($out | Where-Object { $_.Kind -eq 'Scan'        -and $_.Name -eq 'AzureBlob-SampleData/Scan-DataLakeModernization' }).Action | Should -Be 'Skip'
            ($out | Where-Object { $_.Kind -eq 'Trigger'     -and $_.Name -eq 'AzureBlob-SampleData/Scan-DataLakeModernization' }).Action | Should -Be 'Skip'
            ($out | Where-Object { $_.Name -eq 'AzureBlob-SampleData/Scan-Other' }).Action | Should -Be 'NoChange'
        }

        It 'skips Conflict rows the same way as Update rows' {
            # Same Conflict semantics as Deploy-DataSources.Tests.ps1 #617:
            # tracked-field drift + lastModifiedBy mismatch is still drift
            # the portal made, so portal-wins skips it.
            #
            # ADR 0053: the direction policy and the authorship override are
            # independent axes and stay that way. -DirectionPolicy arbitrates
            # WHICH source of truth wins on shared-property drift;
            # -OverwriteForeignAuthor arbitrates WHETHER the deploy principal
            # may write over another principal's work. portal-wins skipping a
            # Conflict row says nothing about either -Force or
            # -OverwriteForeignAuthor.
            $plan = @(
                @{ Kind='Scan'; Action='Conflict'; Name='AzureBlob-SampleData/Scan-Foo'; Reason='Drift in: properties; lastModifiedBy ... differs.' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-Foo').Action | Should -Be 'Skip'
        }

        It 'leaves Create / Orphan / NoChange rows untouched' {
            $plan = @(
                @{ Kind='Scan'; Action='Create';   Name='AzureBlob-SampleData/Scan-New';        Reason='Declared in YAML; absent from tenant.' }
                @{ Kind='Scan'; Action='NoChange'; Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='In sync with tenant.' }
                @{ Kind='Scan'; Action='Orphan';   Name='AzureBlob-SampleData/Scan-Stale';      Reason='Tenant-only; skipped (no -PruneMissing).' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-New').Action        | Should -Be 'Create'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-DataLakeModernization').Action | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-Stale').Action      | Should -Be 'Orphan'
        }
    }

    Context 'repo-wins' {
        It 'keeps Update rows as Update on every kind (apply will overwrite)' {
            $plan = @(
                @{ Kind='ScanRuleset'; Action='Update'; Name='MyRules';                                         Reason='Drift in: properties' }
                @{ Kind='Scan';        Action='Update'; Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='Drift in: properties' }
                @{ Kind='Trigger';     Action='Update'; Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='Trigger drift: properties' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'repo-wins'
            $out | ForEach-Object { $_.Action | Should -Be 'Update' }
        }

        It 'keeps Conflict rows as Conflict (apply still falls into the -OverwriteForeignAuthor gate)' {
            # ADR 0053 (was: "the script -Force gate"). repo-wins proposes to
            # take the repo's content, but a Conflict row is still gated on
            # -OverwriteForeignAuthor, NOT on -Force. The direction policy does
            # not grant authority to overwrite a foreign author.
            $plan = @(
                @{ Kind='Scan'; Action='Conflict'; Name='AzureBlob-SampleData/Scan-Foo'; Reason='Drift in: properties; lastModifiedBy differs.' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-Foo').Action | Should -Be 'Conflict'
        }
    }

    Context '-SkipNames pre-pass' {
        It 'force-skips a composite scan name regardless of policy or drift category' {
            $plan = @(
                @{ Kind='Scan';    Action='Update';   Name='AzureBlob-SampleData/Scan-A'; Reason='Drift in: properties' }
                @{ Kind='Scan';    Action='NoChange'; Name='AzureBlob-SampleData/Scan-B'; Reason='In sync.' }
                @{ Kind='Scan';    Action='Orphan';   Name='AzureBlob-SampleData/Scan-C'; Reason='Tenant-only.' }
                @{ Kind='Trigger'; Action='Conflict'; Name='AzureBlob-SampleData/Scan-D'; Reason='Trigger drift + last-mod conflict.' }
            )
            $skip = @(
                'AzureBlob-SampleData/Scan-A',
                'AzureBlob-SampleData/Scan-B',
                'AzureBlob-SampleData/Scan-C',
                'AzureBlob-SampleData/Scan-D'
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'repo-wins' -SkipList $skip
            $out | ForEach-Object { $_.Action | Should -Be 'Skip' }
        }

        It 'force-skips a bare scan-ruleset name' {
            $plan = @(
                @{ Kind='ScanRuleset'; Action='Update'; Name='MyCustomRuleset'; Reason='Drift in: properties' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'repo-wins' -SkipList @('MyCustomRuleset')
            ($out | Where-Object Name -eq 'MyCustomRuleset').Action | Should -Be 'Skip'
        }

        It 'matches -SkipNames case-insensitively across composite keys' {
            $plan = @(
                @{ Kind='Scan'; Action='Update'; Name='AzureBlob-SampleData/Scan-DataLakeModernization'; Reason='Drift in: properties' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'repo-wins' -SkipList @('azureblob-sampledata/scan-datalakemodernization')
            ($out | Where-Object { $_.Kind -eq 'Scan' }).Action | Should -Be 'Skip'
        }
    }

    Context 'audit short-circuit' {
        It 'returns the plan unmodified (consumer flips $WhatIfPreference)' {
            $plan = @(
                @{ Kind='Scan'; Action='Update'; Name='AzureBlob-SampleData/Scan-A'; Reason='Drift in: properties' }
            )
            $out = Invoke-Adr0029PassScans -Plan $plan -Policy 'audit'
            ($out | Where-Object Name -eq 'AzureBlob-SampleData/Scan-A').Action | Should -Be 'Update'
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
Describe 'ADR 0053 -- -OverwriteForeignAuthor (Deploy-Scans.ps1)' {

    BeforeAll {
        $script:Adr0053Path = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Scans.ps1'
        if (-not (Test-Path $script:Adr0053Path)) {
            throw "Could not locate Deploy-Scans.ps1 at: $script:Adr0053Path"
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

        # A drifted scan the PORTAL last touched, versus the deploy principal.
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

Describe 'Prune failure reporter wiring, guard 2 deliberately absent (issue #13, batch 2)' {

    # Deploy-Scans is REPORTER-ONLY. A scan/trigger teardown legitimately prunes
    # a majority (deleting a data source's whole scan set), so the sanity-ratio
    # guard does not fit and is intentionally NOT wired (owner decision). This
    # Describe pins both the reporter's presence and guard 2's absence.
    # Reference: issue #13

    BeforeAll {
        $script:ScSource = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:ScSource | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:ScSource | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'wires the failure reporter' {
        $script:ScSource | Should -Match 'Write-PruneFailure'
    }
    It 'does NOT wire the sanity-ratio guard (majority prune is legitimate here)' {
        # Anchored on the call site (name + line-continuation), so the
        # explanatory mention of the cmdlet in the script comment does not
        # trip this -- only an actual invocation would.
        $script:ScSource | Should -Not -Match 'Assert-PruneRatioWithinThreshold\s+`'
    }
    It 'does NOT surface -AllowMajorityPrune or -MaxPruneRatio' {
        $script:ScSource | Should -Not -Match '\$AllowMajorityPrune'
        $script:ScSource | Should -Not -Match '\$MaxPruneRatio'
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 2)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-Scans.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-Scans.ps1; update the anchor in this test.' }
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
            function Invoke-ScanRulesetDelete {
                param([string]$Name)
                $attempted.Add($Name)
                if ($Fail -contains $Name) { throw "TenantBlockerException: $Name" }
            }
            function Format-PurviewRestError { param($ErrorRecord) $ErrorRecord.Exception.Message }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($Names | ForEach-Object { [pscustomobject]@{ Kind = 'ScanRuleset'; Action = 'Orphan'; Name = $_ } })
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
    It 'throws one aggregate naming every failure (the fix: exit-0 -> non-zero)' {
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
