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

        It 'keeps Conflict rows as Conflict (apply still falls into the script -Force gate)' {
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

