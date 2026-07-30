#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the helper functions in
    `scripts/Deploy-DLPPolicies.ps1`.

.DESCRIPTION
    Locks in the Wave 2b (issue #70) reconciler contract:

      1. `ConvertTo-DesiredDlpPolicyHash` / `ConvertTo-DesiredDlpRuleHash`
         normalize a YAML entry into a comparable hashtable; missing
         optionals collapse to @() / $null / empty buckets.
      2. `ConvertTo-TenantDlpPolicyHash` / `ConvertTo-TenantDlpRuleHash`
         normalize Get-Dlp* results into the same shape.
      3. `Compare-DlpPolicy` / `Compare-DlpRule` return an empty list
         for in-sync inputs and surface the exact field names that
         drift. Only fields the YAML actually declares are compared.
         `mode` is required and always compared. Array comparisons
         (locations, notifyUser, sensitiveInfoTypes) are order-
         insensitive.
      4. `Get-DlpPolicySplat` and `Get-DlpRuleSplat` build splats for
         `New-` (-Name / -Name + -Policy) or `Set-` (-Identity).
         Location buckets only set when desired; SIT entries carry
         GUID + optional minCount / maxCount / confidencelevel; rules
         that reference an unknown sensitivity label throw.

    Pattern: AST-extract each function definition and dot-source it
    into the test scope. We do NOT dot-source the script itself --
    that would execute its top-level code and try to install
    `ExchangeOnlineManagement` / `Connect-IPPSSession` / acquire a
    Key Vault-signed JWT. The Pester suite is unit-only per
    `tests/Run-Pester.ps1`.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-DLPPolicies.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-DLPPolicies.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @(
            'ConvertFrom-AdvancedRuleWire',
            'ConvertTo-NormalizedAdvancedRule',
            'ConvertTo-ExportedAdvancedRule',
            'ConvertTo-AdvancedRuleWire',
            'ConvertTo-NormalizedAdvancedRuleJson',
            'ConvertTo-SensitivityLabelNameMap',
            'Test-DlpRuleIsNotesOnly',
            'ConvertFrom-GenericLocationsWire',
            'ConvertTo-NormalizedGenericLocations',
            'ConvertTo-GenericLocationsWire',
            'ConvertTo-NormalizedGenericLocationsJson',
            'ConvertTo-AdaptiveScopeRef',
            'ConvertTo-NormalizedAdaptiveScopes',
            'ConvertTo-NormalizedAdaptiveScopesJson',
            'ConvertTo-NormalizedEndpointDlpRestrictions',
            'ConvertTo-NormalizedEndpointDlpRestrictionsJson',
            'ConvertTo-NormalizedAlertProperties',
            'ConvertTo-NormalizedAlertPropertiesJson',
            'ConvertTo-NormalizedRestrictAccess',
            'ConvertTo-NormalizedRestrictAccessJson',
            'ConvertTo-NormalizedPolicyTemplateInfo',
            'ConvertTo-DesiredDlpPolicyHash',
            'ConvertTo-DesiredDlpRuleHash',
            'ConvertTo-TenantDlpPolicyHash',
            'ConvertTo-TenantDlpRuleHash',
            'Compare-DlpPolicy',
            'Compare-DlpRule',
            'Get-DlpPolicySplat',
            'Get-DlpRuleSplat',
            'Invoke-DlpExport')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'ConvertTo-DesiredDlpPolicyHash normalizes YAML policy entries' {

    It 'preserves all fields when fully populated' {
        $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name        = 'DLP-CC'
            description = 'lab credit-card test'
            mode        = 'TestWithoutNotifications'
            priority    = 5
            locations   = @{
                exchange   = 'All'
                sharePoint = @('https://contoso.sharepoint.com/sites/finance')
            }
            rules       = @(@{ name = 'r1'; sensitiveInfoTypes = @(@{ guid = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085' }) })
        }
        $h.name                                 | Should -Be 'DLP-CC'
        $h.description                          | Should -Be 'lab credit-card test'
        $h.mode                                 | Should -Be 'TestWithoutNotifications'
        $h.priority                             | Should -Be 5
        $h.locations.exchange                   | Should -Be @('All')
        $h.locations.sharePoint                 | Should -Be @('https://contoso.sharepoint.com/sites/finance')
        $h.locations.oneDrive                   | Should -BeNullOrEmpty
        $h.rules.Count                          | Should -Be 1
        $h.rules[0].name                        | Should -Be 'r1'
        $h.rules[0].sensitiveInfoTypes.Count    | Should -Be 1
    }

    It 'collapses missing optionals to defaults' {
        $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name = 'DLP-Min'
            mode = 'Disable'
        }
        $h.description                  | Should -BeNullOrEmpty
        $h.priority                     | Should -BeNullOrEmpty
        $h.locations.exchange.Count     | Should -Be 0
        $h.locations.endpoint.Count     | Should -Be 0
        $h.rules.Count                  | Should -Be 0
    }
}

Describe 'ConvertTo-DesiredDlpRuleHash normalizes YAML rule entries' {

    It 'lowercases SIT GUIDs and preserves match thresholds' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{
            name               = 'r-cc'
            priority           = 0
            sensitiveInfoTypes = @(
                @{ guid = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085'; minCount = 1; maxCount = 9; confidenceLevel = 'High' }
            )
        }
        $r.sensitiveInfoTypes[0].guid            | Should -Be '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
        $r.sensitiveInfoTypes[0].minCount        | Should -Be 1
        $r.sensitiveInfoTypes[0].maxCount        | Should -Be 9
        $r.sensitiveInfoTypes[0].confidenceLevel | Should -Be 'High'
    }

    It 'sorts sensitivityLabels by displayName' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{
            name              = 'r-lbl'
            sensitivityLabels = @(@{ displayName = 'Confidential' }, @{ displayName = 'Public' }, @{ displayName = 'Internal' })
        }
        $r.sensitivityLabels.displayName | Should -Be @('Confidential','Internal','Public')
    }

    It 'collapses missing collections to empty arrays' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r-empty' }
        $r.sensitiveInfoTypes.Count     | Should -Be 0
        $r.sensitivityLabels.Count      | Should -Be 0
        $r.notifyUser.Count             | Should -Be 0
        $r.generateIncidentReport.Count | Should -Be 0
        $r.generateAlert.Count          | Should -Be 0
        $r.priority                     | Should -BeNullOrEmpty
        $r.blockAccess                  | Should -BeNullOrEmpty
    }
}

Describe 'Compare-DlpPolicy detects drift in declared fields only' {

    It 'returns empty list when desired and tenant agree' {
        $d = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name = 'P1'; mode = 'Enable'; priority = 10
            locations = @{ exchange = @('user@contoso.com') }
        }
        $t = @{
            name        = 'P1'
            description = $null
            mode        = 'Enable'
            priority    = 10
            locations   = @{ exchange = @('user@contoso.com'); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @() }
            rules       = @()
        }
        (Compare-DlpPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It 'flags `mode` drift even when YAML declares only mode' {
        $d = ConvertTo-DesiredDlpPolicyHash -Entry @{ name = 'P1'; mode = 'Enable' }
        $t = @{ name = 'P1'; description = $null; mode = 'Disable'; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @() }; rules = @() }
        (Compare-DlpPolicy -Desired $d -Tenant $t) | Should -Be @('mode')
    }

    It 'ignores tenant-only description / priority when YAML omits them' {
        $d = ConvertTo-DesiredDlpPolicyHash -Entry @{ name = 'P1'; mode = 'Enable' }
        $t = @{ name = 'P1'; description = 'extra'; mode = 'Enable'; priority = 99
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @() }; rules = @() }
        (Compare-DlpPolicy -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It 'flags location-bucket drift with order-insensitive compare' {
        $d = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name = 'P1'; mode = 'Enable'
            locations = @{ sharePoint = @('https://a','https://b') }
        }
        $t = @{ name = 'P1'; description = $null; mode = 'Enable'; priority = $null
                locations = @{ exchange = @(); sharePoint = @('https://b','https://a','https://c'); oneDrive = @(); teams = @(); endpoint = @() }; rules = @() }
        (Compare-DlpPolicy -Desired $d -Tenant $t) | Should -Be @('locations.sharePoint')
    }
}

Describe 'Compare-DlpRule detects drift in declared fields only' {

    It 'returns empty list when desired and tenant agree' {
        $d = ConvertTo-DesiredDlpRuleHash -Entry @{
            name               = 'r'
            priority           = 0
            sensitiveInfoTypes = @(@{ guid = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085'; minCount = 1 })
            blockAccess        = $false
        }
        $t = @{
            name                   = 'r'
            priority               = 0
            sensitiveInfoTypes     = @([pscustomobject]@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; minCount = 1; maxCount = $null; confidenceLevel = $null })
            sensitivityLabels      = @()
            blockAccess            = $false
            notifyUser             = @()
            generateIncidentReport = @()
            generateAlert          = @()
        }
        (Compare-DlpRule -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It 'is order-insensitive across two SIT entries that differ only by ordering' {
        $g1 = '11111111-1111-1111-1111-111111111111'
        $g2 = '22222222-2222-2222-2222-222222222222'
        $d = ConvertTo-DesiredDlpRuleHash -Entry @{
            name = 'r'
            sensitiveInfoTypes = @(@{ guid = $g1 }, @{ guid = $g2 })
        }
        $t = @{
            name                   = 'r'
            priority               = $null
            sensitiveInfoTypes     = @(
                [pscustomobject]@{ guid = $g2; minCount = $null; maxCount = $null; confidenceLevel = $null },
                [pscustomobject]@{ guid = $g1; minCount = $null; maxCount = $null; confidenceLevel = $null }
            )
            sensitivityLabels      = @()
            blockAccess            = $null
            notifyUser             = @()
            generateIncidentReport = @()
            generateAlert          = @()
        }
        (Compare-DlpRule -Desired $d -Tenant $t).Count | Should -Be 0
    }

    It 'flags sensitiveInfoTypes drift when match thresholds differ' {
        $g = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085'
        $d = ConvertTo-DesiredDlpRuleHash -Entry @{
            name = 'r'; sensitiveInfoTypes = @(@{ guid = $g; minCount = 10 })
        }
        $t = @{
            name                   = 'r'
            priority               = $null
            sensitiveInfoTypes     = @([pscustomobject]@{ guid = $g.ToLowerInvariant(); minCount = 1; maxCount = $null; confidenceLevel = $null })
            sensitivityLabels      = @()
            blockAccess            = $null
            notifyUser             = @()
            generateIncidentReport = @()
            generateAlert          = @()
        }
        (Compare-DlpRule -Desired $d -Tenant $t) | Should -Be @('sensitiveInfoTypes')
    }
}

Describe 'Get-DlpPolicySplat builds correct argument sets' {

    It 'uses -Name and -Mode for New' {
        $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name = 'P1'; mode = 'TestWithoutNotifications'
            locations = @{ exchange = 'All'; sharePoint = @('https://x') }
        }
        $splat = Get-DlpPolicySplat -Hash $h
        $splat.Name                          | Should -Be 'P1'
        $splat.Mode                          | Should -Be 'TestWithoutNotifications'
        $splat.ExchangeLocation              | Should -Be @('All')
        $splat.SharePointLocation            | Should -Be @('https://x')
        $splat.ContainsKey('Identity')       | Should -BeFalse
        $splat.ContainsKey('OneDriveLocation') | Should -BeFalse
    }

    It 'uses -Identity for Set' {
        $h = ConvertTo-DesiredDlpPolicyHash -Entry @{ name = 'P1'; mode = 'Enable' }
        $splat = Get-DlpPolicySplat -Hash $h -ForSet
        $splat.Identity                | Should -Be 'P1'
        $splat.ContainsKey('Name')     | Should -BeFalse
        $splat.Mode                    | Should -Be 'Enable'
    }

    # #564: Set-DlpCompliancePolicy does not accept the declarative
    # per-workload location parameters (-ExchangeLocation, -TeamsLocation, etc.) —
    # it exposes -Add*Location / -Remove*Location deltas instead. The
    # reconciler is declarative-only, so -ForSet must omit every
    # location-shaped parameter. To change a policy's location set, the
    # operator deletes from YAML, prunes, re-adds, and re-applies.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy
    Context '-ForSet omits all location-shaped parameters (#564)' {
        BeforeAll {
            # Build one fat hash carrying every location, generic-location,
            # and adaptive-scope bucket the schema supports. The New splat
            # carries all 29 location/scope parameters; the Set splat must
            # carry none of them.
            $script:LocationLikeParams = @(
                # 6 primary per-workload location parameters
                'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation',
                'TeamsLocation', 'EndpointDlpLocation', 'PowerBIDlpLocation',
                # 12 exception / on-premises / server / third-party variants
                'ExchangeOnPremisesLocation', 'OneDriveLocationException',
                'SharePointLocationException', 'SharePointOnPremisesLocationException',
                'SharePointServerLocation', 'TeamsLocationException',
                'EndpointDlpLocationException', 'OnPremisesScannerDlpLocation',
                'OnPremisesScannerDlpLocationException', 'PowerBIDlpLocationException',
                'ThirdPartyAppDlpLocation', 'ThirdPartyAppDlpLocationException',
                # generic -Locations (genericLocations bucket per ADR 0032)
                'Locations',
                # 10 per-workload adaptive-scope parameters per #520
                'EndpointDlpAdaptiveScopes', 'EndpointDlpAdaptiveScopesException',
                'ExchangeAdaptiveScopes', 'ExchangeAdaptiveScopesException',
                'OneDriveAdaptiveScopes', 'OneDriveAdaptiveScopesException',
                'SharePointAdaptiveScopes', 'SharePointAdaptiveScopesException',
                'TeamsAdaptiveScopes', 'TeamsAdaptiveScopesException'
            )

            $script:FatHash = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-AllLocations'
                mode = 'Enable'
                locations = @{
                    exchange                      = 'All'
                    sharePoint                    = @('https://x')
                    oneDrive                      = @('https://od')
                    teams                         = 'All'
                    endpoint                      = 'All'
                    powerBI                       = 'All'
                    exchangeOnPremises            = 'All'
                    oneDriveException             = @('https://od-ex')
                    sharePointException           = @('https://sp-ex')
                    sharePointOnPremisesException = 'All'
                    sharePointServer              = 'All'
                    teamsException                = 'All'
                    endpointException             = 'All'
                    onPremisesScanner             = 'All'
                    onPremisesScannerException    = 'All'
                    powerBIException              = 'All'
                    thirdPartyApp                 = 'All'
                    thirdPartyAppException        = 'All'
                }
                genericLocations = @(@{
                    workload   = 'Applications'
                    location   = 'Copilot.M365'
                    inclusions = @(@{ type = 'Tenant'; identity = 'All' })
                })
                adaptiveScopes = @{
                    endpoint            = @(@{ name = 'Finance' })
                    endpointException   = @(@{ name = 'Finance' })
                    exchange            = @(@{ name = 'Finance' })
                    exchangeException   = @(@{ name = 'Finance' })
                    oneDrive            = @(@{ name = 'Finance' })
                    oneDriveException   = @(@{ name = 'Finance' })
                    sharePoint          = @(@{ name = 'Finance' })
                    sharePointException = @(@{ name = 'Finance' })
                    teams               = @(@{ name = 'Finance' })
                    teamsException      = @(@{ name = 'Finance' })
                }
            }
        }

        It 'baseline -- New splat carries every location-shaped parameter' {
            # Confirms the fixture really declares all 29 params on the New
            # path; if this fails, the negative test below is trivially true
            # and not actually exercising the fix.
            $newSplat = Get-DlpPolicySplat -Hash $script:FatHash
            foreach ($p in $script:LocationLikeParams) {
                $newSplat.ContainsKey($p) | Should -BeTrue -Because ('New splat should carry -' + $p)
            }
        }

        It '-ForSet splat does NOT carry any of the 29 location-shaped parameters' {
            $setSplat = Get-DlpPolicySplat -Hash $script:FatHash -ForSet
            foreach ($p in $script:LocationLikeParams) {
                $setSplat.ContainsKey($p) | Should -BeFalse -Because ('Set splat must not carry -' + $p + ' (Set-DlpCompliancePolicy uses -Add* / -Remove* deltas)')
            }
        }

        It '-ForSet splat still carries the non-location-shaped parameters' {
            # Identity, Mode, EnforcementPlanes are valid on Set- and must
            # still flow through. Comment is in the fixture via -Identity
            # only; description is unset here.
            $setSplat = Get-DlpPolicySplat -Hash $script:FatHash -ForSet
            $setSplat.Identity          | Should -Be 'P-AllLocations'
            $setSplat.Mode              | Should -Be 'Enable'
            $setSplat.ContainsKey('Name') | Should -BeFalse
        }
    }
}

Describe 'Get-DlpRuleSplat builds correct argument sets' {

    It 'uses -Name + -Policy for New' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{
            name = 'r1'
            sensitiveInfoTypes = @(@{ guid = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085'; minCount = 1; confidenceLevel = 'Medium' })
            blockAccess = $true
        }
        $splat = Get-DlpRuleSplat -Hash $r -PolicyName 'P1'
        $splat.Name        | Should -Be 'r1'
        $splat.Policy      | Should -Be 'P1'
        $splat.BlockAccess | Should -BeTrue
        $splat.ContentContainsSensitiveInformation[0].Name            | Should -Be '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
        $splat.ContentContainsSensitiveInformation[0].minCount        | Should -Be 1
        $splat.ContentContainsSensitiveInformation[0].confidencelevel | Should -Be 'Medium'
    }

    It 'uses -Identity (Policy\Rule) for Set' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r1'; sensitiveInfoTypes = @(@{ guid = '50842EB7-EDC8-4019-85DD-5A5C1F2BB085' }) }
        $splat = Get-DlpRuleSplat -Hash $r -PolicyName 'P1' -ForSet
        $splat.Identity            | Should -Be 'P1\r1'
        $splat.ContainsKey('Name') | Should -BeFalse
        $splat.ContainsKey('Policy') | Should -BeFalse
    }

    It 'resolves sensitivityLabels through the label map and emits the grouped structure' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{
            name              = 'r-lbl'
            sensitivityLabels = @(@{ displayName = 'Confidential' })
        }
        $map = @{ 'Confidential' = 'ffffffff-ffff-ffff-ffff-ffffffffffff' }
        $splat = Get-DlpRuleSplat -Hash $r -PolicyName 'P1' -LabelGuidMap $map
        $splat.ContentContainsSensitiveInformation.operator                                    | Should -Be 'And'
        $splat.ContentContainsSensitiveInformation.groups[0].labels[0].name                    | Should -Be 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $splat.ContentContainsSensitiveInformation.groups[0].labels[0].type                    | Should -Be 'Sensitivity'
    }

    It 'throws when a referenced sensitivity label is not in the map' {
        $r = ConvertTo-DesiredDlpRuleHash -Entry @{
            name              = 'r-lbl'
            sensitivityLabels = @(@{ displayName = 'Confidential' })
        }
        { Get-DlpRuleSplat -Hash $r -PolicyName 'P1' -LabelGuidMap @{} } | Should -Throw -ExpectedMessage "*Confidential*"
    }
}

Describe 'Schema and reconciler accept the post-export tenant shape (PR for #362)' {

    BeforeAll {
        $script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema     = Get-Content -LiteralPath $script:SchemaPath -Raw
        Import-Module powershell-yaml -ErrorAction Stop
    }

    It 'exporter omits restrictAccess when the tenant items normalize to empty (issue #71 -- never emits schema-invalid restrictAccess: [])' {
        # A tenant rule whose only RestrictAccess entry has no `setting` is dropped
        # by ConvertTo-NormalizedRestrictAccess, so a naive exporter would write
        # `restrictAccess: []` -- which the schema (restrictAccess minItems: 1)
        # rejects and no round-trip can satisfy. Observed live on the lab Copilot
        # "Protect sensitive M365 Copilot interactions" rule. The export must omit
        # the key entirely and stay schema-valid.
        $policy = [pscustomobject]@{ Name = 'P-71'; Mode = 'Enable'; Priority = 0; TeamsLocation = @('All') }
        $rule = [pscustomobject]@{
            ParentPolicyName = 'P-71'
            Name             = 'R-71'
            Priority         = 0
            IsAdvancedRule   = $false
            RestrictAccess   = @(@{ notASetting = 'value' })
        }
        $out = Join-Path $TestDrive 'export-71.yaml'
        Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
        $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
        $doc.policies[0].rules[0].ContainsKey('restrictAccess') | Should -BeFalse
        { ($doc | ConvertTo-Json -Depth 25) | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'validates a policy that declares the powerBI location bucket (Fabric DLP)' {
        $doc = '{"policies":[{"name":"x","mode":"Enable","locations":{"powerBI":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}]}]}]}'
        { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'powerBI bucket round-trips through ConvertTo-DesiredDlpPolicyHash and Get-DlpPolicySplat' {
        $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
            name      = 'P-Fabric'
            mode      = 'Enable'
            locations = @{ powerBI = 'All' }
        }
        $h.locations['powerBI'] | Should -Be @('All')

        $splat = Get-DlpPolicySplat -Hash $h
        $splat.PowerBIDlpLocation         | Should -Be @('All')
        $splat.ContainsKey('ExchangeLocation') | Should -BeFalse
    }

    It 'accepts maxCount=-1 (Microsoft unbounded sentinel) without a schema error' {
        $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085","minCount":1,"maxCount":-1}]}]}]}'
        { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'accepts a notes-only rule (no sensitiveInfoTypes, no sensitivityLabels) for AdvancedRule pass-through' {
        $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","blockAccess":false,"notes":"AdvancedRule body not yet modeled"}]}]}'
        { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'still rejects a rule with no predicate and no notes marker' {
        $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","blockAccess":false}]}]}'
        { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
    }

    It 'accepts a policy with no locations and no rules (notes-only pass-through; e.g. Microsoft 365 Copilot)' {
        $doc = '{"policies":[{"name":"x","mode":"Enable","notes":"Generic Locations parameter not yet modeled"}]}'
        { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'AdvancedRule round-trip (PR A2 of #514, ADR 0031)' {

    BeforeAll {
        # Representative HIPAA Enhanced default-rule body captured during #362
        # (PR #516 probe), trimmed to two groups for test brevity. Both
        # branches (sensitiveInfoTypes, trainableClassifiers) and a
        # non-default outerOperator are exercised.
        $script:HipaaWire = @'
{
  "Version": "1.0",
  "Condition": {
    "Operator": "And",
    "SubConditions": [
      {
        "ConditionName": "ContentContainsSensitiveInformation",
        "Value": [
          {
            "Operator": "And",
            "Groups": [
              {
                "Name": "PII Identifiers",
                "Operator": "Or",
                "Sensitivetypes": [
                  { "Name": "U.S. Social Security Number (SSN)", "Id": "a44669fe-0d48-453d-a9b1-2cc83f2cba77", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "Medium", "Minconfidence": 75, "Maxconfidence": 100 }
                ]
              },
              {
                "Name": "Trainable Classifiers",
                "Operator": "Or",
                "Sensitivetypes": [
                  { "Name": "dcbada08-65bf-4561-b140-25d8fee4d143", "Id": "dcbada08-65bf-4561-b140-25d8fee4d143", "Classifiertype": "MLModel" }
                ]
              }
            ]
          }
        ]
      }
    ]
  }
}
'@
    }

    Context 'ConvertFrom-AdvancedRuleWire parses Microsoft wire JSON' {

        It 'returns Recognized=$true and the expected outerOperator + group shape for HIPAA-style input' {
            # #80: the parse result is now a condition TREE. The HIPAA body is the
            # single-content-predicate case, so it lands as one condition under an
            # `And` root -- the exact shape ConvertTo-ExportedAdvancedRule renders
            # back as the legacy { outerOperator, groups } sugar.
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:HipaaWire
            $r.Recognized | Should -BeTrue
            $r.Reason     | Should -BeNullOrEmpty
            $content = $r.Normalized.conditions[0]
            $r.Normalized.operator                     | Should -Be 'And'
            $content.type                              | Should -Be 'ContentContainsSensitiveInformation'
            $content.outerOperator                     | Should -Be 'And'
            @($content.groups).Count                       | Should -Be 2
            $content.groups[0].name                        | Should -Be 'PII Identifiers'
            $content.groups[0].operator                    | Should -Be 'Or'
            @($content.groups[0].sensitiveInfoTypes).Count | Should -Be 1
            $content.groups[0].sensitiveInfoTypes[0].guid  | Should -Be 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'
            $content.groups[0].sensitiveInfoTypes[0].name  | Should -Be 'U.S. Social Security Number (SSN)'
            $content.groups[0].sensitiveInfoTypes[0].maxCount      | Should -Be -1
            $content.groups[0].sensitiveInfoTypes[0].minConfidence | Should -Be 75
        }

        It 'routes Classifiertype=MLModel entries into trainableClassifiers, not sensitiveInfoTypes' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:HipaaWire
            $groups = $r.Normalized.conditions[0].groups
            # Group 1 (Trainable Classifiers) carries no SITs, one classifier.
            $groups[1].sensitiveInfoTypes   | Should -BeNullOrEmpty
            @($groups[1].trainableClassifiers).Count | Should -Be 1
            $groups[1].trainableClassifiers[0].guid  | Should -Be 'dcbada08-65bf-4561-b140-25d8fee4d143'
        }

        It 'returns Recognized=$false with a reason when SubCondition.ConditionName is unsupported' {
            $bad = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"DocumentMatchesPatternsAttachedItem","Value":[]}]}}'
            $r   = ConvertFrom-AdvancedRuleWire -Wire $bad
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'DocumentMatchesPatternsAttachedItem'
        }

        It 'returns Recognized=$false when Version is not 1.0' {
            $bad = '{"Version":"2.0","Condition":{"Operator":"And","SubConditions":[]}}'
            $r   = ConvertFrom-AdvancedRuleWire -Wire $bad
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match "Version"
        }
    }

    Context 'ConvertTo-AdvancedRuleWire reconstructs the wire shape for -AdvancedRule' {

        It 'wraps the YAML shape in Version + Condition.SubConditions[0].ConditionName constants' {
            $h = ConvertTo-NormalizedAdvancedRule -Source @{
                outerOperator = 'And'
                groups = @(@{
                    name = 'g1'; operator = 'Or'
                    sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'; minCount = 1; maxCount = -1 })
                })
            }
            $wire = ConvertTo-AdvancedRuleWire -AdvancedRule $h | ConvertFrom-Json
            $wire.Version                                                  | Should -Be '1.0'
            $wire.Condition.Operator                                       | Should -Be 'And'
            $wire.Condition.SubConditions[0].ConditionName                 | Should -Be 'ContentContainsSensitiveInformation'
            $wire.Condition.SubConditions[0].Value[0].Operator             | Should -Be 'And'
            $wire.Condition.SubConditions[0].Value[0].Groups[0].Name       | Should -Be 'g1'
            $wire.Condition.SubConditions[0].Value[0].Groups[0].Operator   | Should -Be 'Or'
            $wire.Condition.SubConditions[0].Value[0].Groups[0].Sensitivetypes[0].Id       | Should -Be 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'
            $wire.Condition.SubConditions[0].Value[0].Groups[0].Sensitivetypes[0].Mincount | Should -Be 1
            $wire.Condition.SubConditions[0].Value[0].Groups[0].Sensitivetypes[0].Maxcount | Should -Be -1
        }

        It 'emits Classifiertype=MLModel on trainable-classifier entries' {
            $h = ConvertTo-NormalizedAdvancedRule -Source @{
                outerOperator = 'Or'
                groups = @(@{
                    name = 'tc'; operator = 'Or'
                    trainableClassifiers = @(@{ guid = 'dcbada08-65bf-4561-b140-25d8fee4d143' })
                })
            }
            $wire = ConvertTo-AdvancedRuleWire -AdvancedRule $h | ConvertFrom-Json
            $st   = $wire.Condition.SubConditions[0].Value[0].Groups[0].Sensitivetypes[0]
            $st.Id            | Should -Be 'dcbada08-65bf-4561-b140-25d8fee4d143'
            $st.Classifiertype | Should -Be 'MLModel'
        }
    }

    Context 'Round-trip: wire -> YAML -> wire produces equivalent JSON' {

        It 'is byte-equal under canonical key-sorting' {
            $r1 = ConvertFrom-AdvancedRuleWire -Wire $script:HipaaWire
            $w  = ConvertTo-AdvancedRuleWire   -AdvancedRule $r1.Normalized
            $r2 = ConvertFrom-AdvancedRuleWire -Wire $w
            $j1 = ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r1.Normalized
            $j2 = ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r2.Normalized
            $j2 | Should -Be $j1
        }
    }

    Context 'ConvertTo-DesiredDlpRuleHash + Get-DlpRuleSplat wire advancedRule into -AdvancedRule' {

        It 'surfaces advancedRule on the desired hash when the YAML entry declares it' {
            $r = ConvertTo-DesiredDlpRuleHash -Entry @{
                name = 'r-adv'
                advancedRule = @{
                    outerOperator = 'And'
                    groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77' }) })
                }
            }
            # #80: the desired hash normalizes the authored sugar into the tree.
            $r.advancedRule                                  | Should -Not -BeNullOrEmpty
            $r.advancedRule.operator                         | Should -Be 'And'
            $r.advancedRule.conditions[0].outerOperator      | Should -Be 'And'
            $r.advancedRule.conditions[0].groups[0].sensitiveInfoTypes[0].guid | Should -Be 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'
        }

        It 'emits -AdvancedRule (string JSON) and not -ContentContainsSensitiveInformation on the splat' {
            $r = ConvertTo-DesiredDlpRuleHash -Entry @{
                name = 'r-adv'
                advancedRule = @{
                    outerOperator = 'And'
                    groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77' }) })
                }
            }
            $splat = Get-DlpRuleSplat -Hash $r -PolicyName 'P-Adv'
            $splat.ContainsKey('AdvancedRule')                       | Should -BeTrue
            $splat.ContainsKey('ContentContainsSensitiveInformation') | Should -BeFalse
            ($splat.AdvancedRule | ConvertFrom-Json).Version          | Should -Be '1.0'
        }
    }

    Context 'Compare-DlpRule detects advancedRule drift' {

        It 'returns empty diffs when desired and tenant advancedRule are structurally equal' {
            $entry = @{
                outerOperator = 'And'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'; minCount = 1 }) })
            }
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; advancedRule = $entry }
            $tenant  = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @();
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @();
                advancedRule = ConvertTo-NormalizedAdvancedRule -Source $entry
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant).Count | Should -Be 0
        }

        It 'flags advancedRule when desired changes a per-SIT confidenceLevel' {
            $base = @{
                outerOperator = 'And'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'; confidenceLevel = 'High' }) })
            }
            $drift = @{
                outerOperator = 'And'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77'; confidenceLevel = 'Medium' }) })
            }
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; advancedRule = $drift }
            $tenant  = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @();
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @();
                advancedRule = ConvertTo-NormalizedAdvancedRule -Source $base
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'advancedRule'
        }

        It 'flags advancedRule when only one side has it' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name = 'r'
                advancedRule = @{
                    outerOperator = 'And'
                    groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = 'a44669fe-0d48-453d-a9b1-2cc83f2cba77' }) })
                }
            }
            $tenant  = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @();
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @();
                advancedRule = $null
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'advancedRule'
        }
    }

    Context 'Schema rejects mutual-exclusion violations (ADR 0031)' {

        It 'rejects a rule that declares both advancedRule and sensitiveInfoTypes' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}],"advancedRule":{"outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitiveInfoTypes":[{"guid":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'rejects a rule that declares both advancedRule and sensitivityLabels' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","sensitivityLabels":[{"displayName":"Confidential"}],"advancedRule":{"outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitiveInfoTypes":[{"guid":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }
    }
}

Describe 'rawAdvancedRule captured-evidence pass-through (#79, ADR 0031)' {

    BeforeAll {
        $script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema     = Get-Content -LiteralPath $script:SchemaPath -Raw
        Import-Module powershell-yaml -ErrorAction Stop

        # Wire bodies that ConvertFrom-AdvancedRuleWire REJECTS.
        #
        # UPDATED BY #80. These originally mirrored the two degradation modes seen
        # across the 10 tenant rules -- a second SubCondition and
        # Condition.Operator='Or' -- both of which #80 now MODELS, so neither is a
        # parse failure any more. The #79 contract under test here is not "those two
        # shapes fail" but "whatever the parser cannot model is captured verbatim as
        # evidence instead of being discarded", so the fixtures are re-pointed at
        # shapes that remain unmodelled after #80:
        #   * an unsupported predicate name (RecipientDomainIs)
        #   * a sensitivity label the tenant cannot resolve to a display name, which
        #     must degrade rather than write a raw label GUID into the repo (ADR 0023)
        $script:UnparseableUnknownPredicate = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"Operator":"Or","Groups":[{"Name":"g","Operator":"Or","Sensitivetypes":[{"Name":"U.S. Social Security Number (SSN)","Id":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}]}]}]},{"ConditionName":"RecipientDomainIs","Value":["contoso.com"]}]}}'
        $script:UnparseableUnresolvedLabel  = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"Operator":"And","Groups":[{"Name":"g","Operator":"Or","Labels":[{"Name":"00000000-0000-0000-0000-000000000821","Id":"00000000-0000-0000-0000-000000000821","Type":"Sensitivity"}]}]}]}]}}'

        # A body the parser DOES accept, for the negative case.
        $script:ParseableWire = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"ContentContainsSensitiveInformation","Value":[{"Operator":"And","Groups":[{"Name":"g","Operator":"Or","Sensitivetypes":[{"Name":"Credit Card Number","Id":"50842eb7-edc8-4019-85dd-5a5c1f2bb085","Mincount":1,"Maxcount":-1}]}]}]}]}}'
    }

    Context 'Invoke-DlpExport captures the wire body on parse failure' {

        It 'writes rawAdvancedRule verbatim alongside notes when the body does not parse' {
            $policy = [pscustomobject]@{ Name = 'P-79'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName = 'P-79'
                Name             = 'R-79'
                Priority         = 0
                IsAdvancedRule   = $true
                AdvancedRule     = $script:UnparseableUnknownPredicate
            }
            $out = Join-Path $TestDrive 'export-79-a.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
            $r = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml).policies[0].rules[0]

            $r.ContainsKey('rawAdvancedRule') | Should -BeTrue
            # Verbatim: the captured string must be byte-identical to the tenant body,
            # otherwise it is not usable as evidence for modelling the shape.
            $r.rawAdvancedRule               | Should -BeExactly $script:UnparseableUnknownPredicate
            $r.notes                         | Should -Match "Unsupported SubCondition.ConditionName='RecipientDomainIs'"
            $r.ContainsKey('advancedRule')   | Should -BeFalse
        }

        It 'captures the unresolvable-sensitivity-label degradation mode too (never writes a raw label GUID)' {
            # The export path resolves Labels[].Id -> display name via Get-Label (#80).
            # With no label map -- Get-Label unavailable, or a label present on the
            # rule but absent from the tenant -- the ONLY safe outcome is to degrade
            # to evidence. Writing the GUID would be an ADR 0023 violation and an
            # ADR 0055 residue finding.
            $policy = [pscustomobject]@{ Name = 'P-79b'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName = 'P-79b'
                Name             = 'R-79b'
                Priority         = 0
                IsAdvancedRule   = $true
                AdvancedRule     = $script:UnparseableUnresolvedLabel
            }
            $out = Join-Path $TestDrive 'export-79-b.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
            $r = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml).policies[0].rules[0]

            $r.rawAdvancedRule             | Should -BeExactly $script:UnparseableUnresolvedLabel
            $r.notes                       | Should -Match 'display name'
            $r.ContainsKey('advancedRule') | Should -BeFalse
            # The degradation note itself must stay GUID-free.
            $r.notes | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        }

        It 'resolves the label by display name when the map HAS it (the #80 success path)' {
            $policy = [pscustomobject]@{ Name = 'P-79b2'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName = 'P-79b2'
                Name             = 'R-79b2'
                Priority         = 0
                IsAdvancedRule   = $true
                AdvancedRule     = $script:UnparseableUnresolvedLabel
            }
            $out = Join-Path $TestDrive 'export-79-b2.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule) `
                -LabelNameMap @{ '00000000-0000-0000-0000-000000000821' = 'Internal' }
            $body = Get-Content -LiteralPath $out -Raw
            $r = ($body | ConvertFrom-Yaml).policies[0].rules[0]

            $r.ContainsKey('rawAdvancedRule') | Should -BeFalse
            $r.advancedRule.groups[0].sensitivityLabels[0].displayName | Should -Be 'Internal'
            # The exported FILE must carry no label GUID at all.
            $body | Should -Not -Match '00000000-0000-0000-0000-000000000821'
        }

        It 'does NOT write rawAdvancedRule when the body parses cleanly' {
            $policy = [pscustomobject]@{ Name = 'P-79c'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName = 'P-79c'
                Name             = 'R-79c'
                Priority         = 0
                IsAdvancedRule   = $true
                AdvancedRule     = $script:ParseableWire
            }
            $out = Join-Path $TestDrive 'export-79-c.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
            $r = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml).policies[0].rules[0]

            $r.ContainsKey('rawAdvancedRule') | Should -BeFalse
            $r.ContainsKey('advancedRule')    | Should -BeTrue
        }

        It 'captures the wire even when the rule ALSO carries ContentContainsSensitiveInformation (#79 constraint 4)' {
            # The emit is deliberately NOT gated on $sits.Count. AdvancedRule and
            # ContentContainsSensitiveInformation are separate tenant properties, so a
            # rule can populate both; gating would silently drop this case and hand #80
            # an incomplete sample. This is the hole that option 1 closes.
            $policy = [pscustomobject]@{ Name = 'P-79d'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName                     = 'P-79d'
                Name                                 = 'R-79d'
                Priority                             = 0
                IsAdvancedRule                       = $true
                AdvancedRule                         = $script:UnparseableUnknownPredicate
                ContentContainsSensitiveInformation  = @(@{ id = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $out = Join-Path $TestDrive 'export-79-d.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
            $r = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml).policies[0].rules[0]

            $r.rawAdvancedRule                  | Should -BeExactly $script:UnparseableUnknownPredicate
            @($r.sensitiveInfoTypes).Count      | Should -Be 1
            # NOTE: `notes:` is NOT emitted on this path -- its write is still gated on
            # $sits.Count -eq 0. That residual is pre-existing and out of scope for #79
            # (which captures the wire, the evidence #80 needs); it is left unasserted
            # here deliberately so a later fix does not have to fight this test.
        }

        It 'stays schema-valid for every captured-evidence shape it emits' {
            $policy = [pscustomobject]@{ Name = 'P-79e'; Mode = 'Enable'; Priority = 0; ExchangeLocation = @('All') }
            $rule   = [pscustomobject]@{
                ParentPolicyName = 'P-79e'
                Name             = 'R-79e'
                Priority         = 0
                IsAdvancedRule   = $true
                AdvancedRule     = $script:UnparseableUnknownPredicate
            }
            $out = Join-Path $TestDrive 'export-79-e.yaml'
            Invoke-DlpExport -Path $out -TenantPolicies @($policy) -TenantRules @($rule)
            $doc = Get-Content -LiteralPath $out -Raw | ConvertFrom-Yaml
            { ($doc | ConvertTo-Json -Depth 25) | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }
    }

    Context 'Schema contract for rawAdvancedRule' {

        It 'accepts notes + rawAdvancedRule together (the normal degradation shape)' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","notes":"body not yet modeled","rawAdvancedRule":"{\"Version\":\"1.0\"}"}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'rejects advancedRule + rawAdvancedRule (parse cannot both succeed and fail)' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","rawAdvancedRule":"{\"Version\":\"1.0\"}","advancedRule":{"outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitiveInfoTypes":[{"guid":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'PERMITS rawAdvancedRule + sensitiveInfoTypes -- by design, not by oversight' {
            # Mirrors the exporter emit decision above. If this ever starts throwing,
            # the schema and the exporter have diverged and the #79 constraint-4 case
            # will silently fail schema validation on a real export.
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"a44669fe-0d48-453d-a9b1-2cc83f2cba77"}],"rawAdvancedRule":"{\"Version\":\"1.0\"}"}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'does NOT let rawAdvancedRule alone satisfy the predicate requirement' {
            # It is evidence, never a predicate. Without notes (or a real predicate)
            # the rule must still be rejected.
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","blockAccess":false,"rawAdvancedRule":"{\"Version\":\"1.0\"}"}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'rejects an empty rawAdvancedRule string' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","notes":"n","rawAdvancedRule":""}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'Applier-skip boundary: rawAdvancedRule never reaches the write path' {

        It 'ConvertTo-DesiredDlpRuleHash drops rawAdvancedRule entirely' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name            = 'r'
                notes           = 'body not yet modeled'
                rawAdvancedRule = '{"Version":"1.0"}'
            }
            $h.ContainsKey('rawAdvancedRule') | Should -BeFalse
        }

        It 'Get-DlpRuleSplat NEVER emits -AdvancedRule from a rawAdvancedRule, even when injected directly' {
            # Belt and braces: bypass ConvertTo-DesiredDlpRuleHash and hand the splat
            # builder a hash that carries the field, proving the boundary holds even if
            # a future change starts threading the field through the desired-state hash.
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; notes = 'n' }
            $h['rawAdvancedRule'] = '{"Version":"1.0","Condition":{"Operator":"Or"}}'
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P'

            $splat.ContainsKey('rawAdvancedRule') | Should -BeFalse
            $splat.ContainsKey('AdvancedRule')    | Should -BeFalse
        }

        It 'Compare-DlpRule reports no drift for rawAdvancedRule' {
            # Compare-DlpRule is an explicit field allowlist, so an unlisted field is
            # ignored by construction. Pinned here so a future refactor to a generic
            # key-walk cannot silently turn captured evidence into perpetual drift.
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; notes = 'n' }
            $desired['rawAdvancedRule'] = '{"Version":"1.0"}'
            $tenant  = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @();
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @();
                advancedRule = $null
            }
            @(Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'rawAdvancedRule'
        }

        It 'a notes + rawAdvancedRule rule still satisfies the notes-only skip predicate' {
            # The apply-path guard is inline (not a function), so it is out of reach of
            # this suite's AST-extraction harness. This asserts the exact predicate that
            # guard evaluates against the normalized desired hash, so a change to the
            # hash shape that would break the skip is caught here.
            $dr = ConvertTo-DesiredDlpRuleHash -Entry @{
                name            = 'r'
                notes           = 'body not yet modeled'
                rawAdvancedRule = '{"Version":"1.0"}'
            }
            $isNotesOnly = (-not [string]::IsNullOrEmpty([string]$dr.notes)) -and
                           @($dr.sensitiveInfoTypes).Count -eq 0 -and
                           @($dr.sensitivityLabels).Count  -eq 0 -and
                           (-not $dr.advancedRule)
            $isNotesOnly | Should -BeTrue
        }
    }
}

Describe 'genericLocations / enforcementPlanes / policyTemplateInfo round-trip (PR for #515, ADR 0032)' {

    BeforeAll {
        # Representative Microsoft 365 Copilot policy wire shape captured
        # during #362 (PR #516 probe). Workload=Applications,
        # Location=Copilot.M365, single Tenant=All inclusion.
        $script:CopilotLocationsWire = @'
[{"Workload":"Applications","Location":"Copilot.M365","LocationDisplayName":null,"LocationSource":"Unknown","LocationType":"Unknown","Inclusions":[{"Type":"Tenant","Identity":"All","DisplayName":"All","Name":"All"}]}]
'@
    }

    Context 'ConvertFrom-GenericLocationsWire parses Microsoft wire JSON' {

        It 'returns Recognized=$true and the expected workload + location for Copilot-style input' {
            $r = ConvertFrom-GenericLocationsWire -Wire $script:CopilotLocationsWire
            $r.Recognized                              | Should -BeTrue
            $r.Reason                                  | Should -BeNullOrEmpty
            @($r.Normalized).Count                     | Should -Be 1
            $r.Normalized[0].workload                  | Should -Be 'Applications'
            $r.Normalized[0].location                  | Should -Be 'Copilot.M365'
            $r.Normalized[0].locationSource            | Should -Be 'Unknown'
            $r.Normalized[0].locationType              | Should -Be 'Unknown'
            @($r.Normalized[0].inclusions).Count       | Should -Be 1
            $r.Normalized[0].inclusions[0].type        | Should -Be 'Tenant'
            $r.Normalized[0].inclusions[0].identity    | Should -Be 'All'
        }

        It 'preserves locationDisplayName=null as a key (round-trip fidelity)' {
            $r = ConvertFrom-GenericLocationsWire -Wire $script:CopilotLocationsWire
            $r.Normalized[0].Contains('locationDisplayName') | Should -BeTrue
            $r.Normalized[0]['locationDisplayName']          | Should -BeNullOrEmpty
        }

        It 'returns Recognized=$false with a reason when an entry is missing required Workload' {
            $bad = '[{"Location":"Copilot.M365"}]'
            $r   = ConvertFrom-GenericLocationsWire -Wire $bad
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'Workload'
        }

        It 'returns Recognized=$false on empty array' {
            $r = ConvertFrom-GenericLocationsWire -Wire '[]'
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'zero entries'
        }
    }

    Context 'ConvertTo-GenericLocationsWire emits cmdlet-compatible JSON' {

        It 'reconstructs PascalCase keys (Workload, Location, Inclusions) from lowerCamelCase YAML' {
            $h = ConvertTo-NormalizedGenericLocations -Source @(@{
                workload  = 'Applications'
                location  = 'Copilot.M365'
                inclusions = @(@{ type = 'Tenant'; identity = 'All' })
            })
            $wire = ConvertTo-GenericLocationsWire -GenericLocations $h | ConvertFrom-Json
            $wire[0].Workload                            | Should -Be 'Applications'
            $wire[0].Location                            | Should -Be 'Copilot.M365'
            @($wire[0].Inclusions).Count                 | Should -Be 1
            $wire[0].Inclusions[0].Type                  | Should -Be 'Tenant'
            $wire[0].Inclusions[0].Identity              | Should -Be 'All'
        }

        It 'omits inclusions / exclusions when not declared' {
            $h = ConvertTo-NormalizedGenericLocations -Source @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            $wire = ConvertTo-GenericLocationsWire -GenericLocations $h | ConvertFrom-Json
            $wire[0].PSObject.Properties.Match('Inclusions').Count | Should -Be 0
            $wire[0].PSObject.Properties.Match('Exclusions').Count | Should -Be 0
        }

        It 'emits a JSON ARRAY when the policy declares exactly one location scope (#92)' {
            # Regression guard. The emitter used to pipe into ConvertTo-Json, which
            # enumerates the array, so a single scope serialized as a bare JSON object and
            # New-DlpCompliancePolicy rejected the create: "the type requires a JSON array
            # (e.g. [1,2,3])".
            #
            # Assert on the raw STRING and on the parsed type. Do NOT assert via $wire[0]
            # or @(...).Count -- indexing a PSCustomObject returns the object itself in
            # PowerShell 7, so both pass against the broken object shape and prove nothing.
            # The sibling tests in this Context are index-based and stayed green
            # throughout the outage; that is exactly how this shipped.
            $h    = ConvertTo-NormalizedGenericLocations -Source @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            $json = ConvertTo-GenericLocationsWire -GenericLocations $h

            $json.TrimStart()                                                | Should -Match '^\['
            ((ConvertFrom-Json -InputObject $json -NoEnumerate) -is [array]) | Should -BeTrue
        }

        It 'emits a JSON array for multiple location scopes (#92)' {
            $h = ConvertTo-NormalizedGenericLocations -Source @(
                @{ workload = 'Applications'; location = 'Copilot.M365' },
                @{ workload = 'Applications'; location = 'Copilot.Fabric' }
            )
            $json = ConvertTo-GenericLocationsWire -GenericLocations $h

            $json.TrimStart()                                                | Should -Match '^\['
            ((ConvertFrom-Json -InputObject $json -NoEnumerate) -is [array]) | Should -BeTrue
            @(ConvertFrom-Json -InputObject $json).Count                     | Should -Be 2
        }
    }

    Context 'Round-trip: wire -> YAML -> wire produces equivalent JSON' {

        It 'is byte-equal under canonical key-sorting' {
            $r1 = ConvertFrom-GenericLocationsWire -Wire $script:CopilotLocationsWire
            $w  = ConvertTo-GenericLocationsWire   -GenericLocations $r1.Normalized
            $r2 = ConvertFrom-GenericLocationsWire -Wire $w
            $j1 = ConvertTo-NormalizedGenericLocationsJson -GenericLocations $r1.Normalized
            $j2 = ConvertTo-NormalizedGenericLocationsJson -GenericLocations $r2.Normalized
            $j2 | Should -Be $j1
        }
    }

    Context 'ConvertTo-DesiredDlpPolicyHash + Get-DlpPolicySplat wire genericLocations into -Locations' {

        It 'surfaces genericLocations on the desired hash when the YAML entry declares it' {
            $p = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'
                mode = 'TestWithoutNotifications'
                genericLocations = @(@{
                    workload = 'Applications'
                    location = 'Copilot.M365'
                    inclusions = @(@{ type = 'Tenant'; identity = 'All' })
                })
            }
            @($p.genericLocations).Count           | Should -Be 1
            $p.genericLocations[0].workload        | Should -Be 'Applications'
            $p.genericLocations[0].location        | Should -Be 'Copilot.M365'
        }

        It 'emits -Locations (string JSON) on the splat when genericLocations is declared' {
            $p = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'
                mode = 'TestWithoutNotifications'
                genericLocations = @(@{
                    workload = 'Applications'
                    location = 'Copilot.M365'
                    inclusions = @(@{ type = 'Tenant'; identity = 'All' })
                })
            }
            $splat = Get-DlpPolicySplat -Hash $p
            $splat.ContainsKey('Locations')                       | Should -BeTrue
            ($splat.Locations | ConvertFrom-Json)[0].Workload     | Should -Be 'Applications'
        }
    }

    Context 'enforcementPlanes wires through to the splat' {

        It 'emits -EnforcementPlanes on the splat when declared' {
            $p = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'
                mode = 'TestWithoutNotifications'
                enforcementPlanes = 'CopilotExperiences'
                genericLocations  = @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            }
            $splat = Get-DlpPolicySplat -Hash $p
            $splat.EnforcementPlanes | Should -Be 'CopilotExperiences'
        }

        It 'omits -EnforcementPlanes on the splat when not declared' {
            $p = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-OnDisk'
                mode = 'Enable'
                locations = @{ exchange = 'All' }
            }
            $splat = Get-DlpPolicySplat -Hash $p
            $splat.ContainsKey('EnforcementPlanes') | Should -BeFalse
        }
    }

    Context 'policyTemplateInfo defensive exporter-write / applier-skip (ADR 0032)' {

        It 'schema accepts a policyTemplateInfo block (opaque pass-through)' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","locations":{"exchange":"All"},"policyTemplateInfo":{"Id":"DlpPolicyTemplatesCustom","CategoryId":"DlpPolicyCategoryCustom"}}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'Get-DlpPolicySplat NEVER emits -PolicyTemplateInfo even when declared' {
            $p = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'
                mode = 'TestWithoutNotifications'
                policyTemplateInfo = @{ Id = 'DlpPolicyTemplatesCustom' }
                genericLocations   = @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            }
            $splat = Get-DlpPolicySplat -Hash $p
            $splat.ContainsKey('PolicyTemplateInfo') | Should -BeFalse
        }
    }

    Context 'Compare-DlpPolicy detects genericLocations / enforcementPlanes drift; skips policyTemplateInfo' {

        It 'returns empty diffs when desired and tenant genericLocations are structurally equal' {
            $entry = @(@{
                workload = 'Applications'
                location = 'Copilot.M365'
                inclusions = @(@{ type = 'Tenant'; identity = 'All' })
            })
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'; genericLocations = $entry
            }
            $tenant  = @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = ConvertTo-NormalizedGenericLocations -Source $entry
                enforcementPlanes = $null; policyTemplateInfo = $null
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant).Count | Should -Be 0
        }

        It 'flags genericLocations when desired changes the location identifier' {
            $base = @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            $drift = @(@{ workload = 'Applications'; location = 'Copilot.Future' })
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'; genericLocations = $drift
            }
            $tenant  = @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = ConvertTo-NormalizedGenericLocations -Source $base
                enforcementPlanes = $null; policyTemplateInfo = $null
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant) | Should -Contain 'genericLocations'
        }

        It 'flags enforcementPlanes when desired declares a different value than tenant' {
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                enforcementPlanes = 'CopilotExperiences'
                genericLocations  = @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            }
            $tenant  = @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = $desired.genericLocations
                enforcementPlanes = 'SomeOtherPlane'; policyTemplateInfo = $null
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant) | Should -Contain 'enforcementPlanes'
        }

        It 'NEVER flags policyTemplateInfo drift (ADR 0032 defensive pattern)' {
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                policyTemplateInfo = @{ Id = 'DlpPolicyTemplatesCustom' }
                genericLocations   = @(@{ workload = 'Applications'; location = 'Copilot.M365' })
            }
            $tenant  = @{
                name = 'P-Copilot'; mode = 'TestWithoutNotifications'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = $desired.genericLocations
                enforcementPlanes = $null
                policyTemplateInfo = @{ Id = 'DlpPolicyTemplatesSomethingDifferent' }
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant) | Should -Not -Contain 'policyTemplateInfo'
        }
    }
}

Describe 'DLP per-workload exception / on-premises / third-party location buckets (#519)' {

    # Test data must be available at Pester discovery time, not at runtime,
    # so this lives outside BeforeAll (which only runs in the Run phase).
    # Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:BucketMap519 = @(
            @{ Bucket = 'exchangeOnPremises';             Param = 'ExchangeOnPremisesLocation' }
            @{ Bucket = 'oneDriveException';              Param = 'OneDriveLocationException' }
            @{ Bucket = 'sharePointException';            Param = 'SharePointLocationException' }
            @{ Bucket = 'sharePointOnPremisesException';  Param = 'SharePointOnPremisesLocationException' }
            @{ Bucket = 'sharePointServer';               Param = 'SharePointServerLocation' }
            @{ Bucket = 'teamsException';                 Param = 'TeamsLocationException' }
            @{ Bucket = 'endpointException';              Param = 'EndpointDlpLocationException' }
            @{ Bucket = 'onPremisesScanner';              Param = 'OnPremisesScannerDlpLocation' }
            @{ Bucket = 'onPremisesScannerException';     Param = 'OnPremisesScannerDlpLocationException' }
            @{ Bucket = 'powerBIException';               Param = 'PowerBIDlpLocationException' }
            @{ Bucket = 'thirdPartyApp';                  Param = 'ThirdPartyAppDlpLocation' }
            @{ Bucket = 'thirdPartyAppException';         Param = 'ThirdPartyAppDlpLocationException' }
        )
    }

    BeforeAll {
        $script:SchemaPath519 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema519     = Get-Content -LiteralPath $script:SchemaPath519 -Raw
    }

    Context 'Schema validation per bucket' {
        It 'schema accepts a policy declaring locations.<Bucket> = "All"' -ForEach $BucketMap519 {
            $doc = '{"policies":[{"name":"x","mode":"Enable","locations":{"' + $Bucket + '":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema519 -ErrorAction Stop } | Should -Not -Throw
        }
    }

    Context 'Splat emission per bucket' {
        It '<Bucket> round-trips through ConvertTo-DesiredDlpPolicyHash and Get-DlpPolicySplat as -<Param>' -ForEach $BucketMap519 {
            $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name      = ('P-' + $Bucket)
                mode      = 'Enable'
                locations = @{ $Bucket = 'All' }
            }
            $h.locations[$Bucket] | Should -Be @('All')

            $splat = Get-DlpPolicySplat -Hash $h
            $splat[$Param] | Should -Be @('All')
            $splat.ContainsKey('ExchangeLocation') | Should -BeFalse
        }
    }

    Context 'Aggregated round-trip across all 12 new buckets' {
        It 'all 12 new buckets coexist on a single policy and emit 12 distinct cmdlet params' {
            $entry = @{ name = 'P-AllVariants'; mode = 'Enable'; locations = @{} }
            foreach ($p in $script:BucketMap519) { $entry.locations[$p.Bucket] = 'All' }

            $h = ConvertTo-DesiredDlpPolicyHash -Entry $entry
            $splat = Get-DlpPolicySplat -Hash $h

            foreach ($p in $script:BucketMap519) {
                $splat.ContainsKey($p.Param) | Should -BeTrue -Because ('expected splat to carry -' + $p.Param)
                $splat[$p.Param] | Should -Be @('All')
            }
            $splat.ContainsKey('ExchangeLocation') | Should -BeFalse
        }
    }
}

Describe 'DLP per-workload adaptive-scope parameters (#520)' {

    # Bucket -> cmdlet parameter map exposed at discovery time so -ForEach
    # blocks expand into one It per bucket. See pester.dev/docs/usage/data-driven-tests.
    BeforeDiscovery {
        $script:BucketMap520 = @(
            @{ Bucket = 'endpoint';             Param = 'EndpointDlpAdaptiveScopes' }
            @{ Bucket = 'endpointException';    Param = 'EndpointDlpAdaptiveScopesException' }
            @{ Bucket = 'exchange';             Param = 'ExchangeAdaptiveScopes' }
            @{ Bucket = 'exchangeException';    Param = 'ExchangeAdaptiveScopesException' }
            @{ Bucket = 'oneDrive';             Param = 'OneDriveAdaptiveScopes' }
            @{ Bucket = 'oneDriveException';    Param = 'OneDriveAdaptiveScopesException' }
            @{ Bucket = 'sharePoint';           Param = 'SharePointAdaptiveScopes' }
            @{ Bucket = 'sharePointException';  Param = 'SharePointAdaptiveScopesException' }
            @{ Bucket = 'teams';                Param = 'TeamsAdaptiveScopes' }
            @{ Bucket = 'teamsException';       Param = 'TeamsAdaptiveScopesException' }
        )
    }

    BeforeAll {
        $script:SchemaPath520 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema520     = Get-Content -LiteralPath $script:SchemaPath520 -Raw
    }

    Context 'Schema validation per adaptive-scope bucket' {
        It 'schema accepts a policy declaring adaptiveScopes.<Bucket>' -ForEach $BucketMap520 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"adaptiveScopes":{"' + $Bucket + '":[{"name":"Finance"}]},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema520 -ErrorAction Stop } | Should -Not -Throw
        }
    }

    Context 'Splat emission per adaptive-scope bucket' {
        It '<Bucket> round-trips through ConvertTo-DesiredDlpPolicyHash and Get-DlpPolicySplat as -<Param>' -ForEach $BucketMap520 {
            $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name           = ('P-' + $Bucket)
                mode           = 'Enable'
                locations      = @{ sharePoint = 'All' }
                adaptiveScopes = @{ $Bucket = @(@{ name = 'Finance' }) }
            }
            $h.adaptiveScopes[$Bucket].Count | Should -Be 1
            $h.adaptiveScopes[$Bucket][0].name | Should -Be 'Finance'

            $splat = Get-DlpPolicySplat -Hash $h
            $splat[$Param] | Should -Be @('Finance')
        }
    }

    Context 'ConvertTo-AdaptiveScopeRef name resolution' {
        It 'returns the entry unchanged when an explicit guid is declared' {
            $r = ConvertTo-AdaptiveScopeRef -Entry @{ name = 'Finance'; guid = '00000000-0000-0000-0000-000000000001' }
            $r.name | Should -Be 'Finance'
            $r.guid | Should -Be '00000000-0000-0000-0000-000000000001'
        }

        It 'resolves a name via the scope map when guid is missing' {
            $map = @{ 'Finance' = '00000000-0000-0000-0000-000000000001' }
            $r = ConvertTo-AdaptiveScopeRef -Entry @{ name = 'Finance' } -ScopeMap $map
            $r.guid | Should -Be '00000000-0000-0000-0000-000000000001'
        }

        It 'throws when neither guid nor a tenant-resolvable name is available' {
            $map = @{ 'OtherScope' = '00000000-0000-0000-0000-000000000002' }
            { ConvertTo-AdaptiveScopeRef -Entry @{ name = 'Finance' } -ScopeMap $map -ContextName 'P-Missing' } |
                Should -Throw -ExpectedMessage "*Adaptive scope 'Finance'*was not found*"
        }

        It 'skips validation when ScopeMap is empty (unit-test path)' {
            { ConvertTo-AdaptiveScopeRef -Entry @{ name = 'Finance' } } | Should -Not -Throw
        }
    }

    Context 'Get-DlpPolicySplat throws on unresolved adaptive scope when a non-empty ScopeMap is provided' {
        It 'throws when the YAML references an adaptive scope not in the tenant map' {
            $h = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name           = 'P-Missing'
                mode           = 'Enable'
                locations      = @{ sharePoint = 'All' }
                adaptiveScopes = @{ sharePoint = @(@{ name = 'NotInTenant' }) }
            }
            $map = @{ 'OtherScope' = '00000000-0000-0000-0000-000000000099' }
            { Get-DlpPolicySplat -Hash $h -AdaptiveScopeMap $map } |
                Should -Throw -ExpectedMessage "*Adaptive scope 'NotInTenant'*"
        }
    }

    Context 'Compare-DlpPolicy detects adaptiveScopes drift per bucket' {
        It 'reports no drift when desired and tenant adaptive scopes are identical' {
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name           = 'P-NoDrift'
                mode           = 'Enable'
                adaptiveScopes = @{ sharePoint = @(@{ name = 'Finance' }) }
            }
            $tenant = @{
                name = 'P-NoDrift'; mode = 'Enable'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = @(); enforcementPlanes = $null; policyTemplateInfo = $null
                adaptiveScopes = $desired.adaptiveScopes
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant) | Should -Not -Contain 'adaptiveScopes.sharePoint'
        }

        It 'flags adaptiveScopes.<Bucket> drift when desired declares a scope and tenant has none' -ForEach $BucketMap520 {
            $desired = ConvertTo-DesiredDlpPolicyHash -Entry @{
                name           = 'P-DriftAdd'
                mode           = 'Enable'
                adaptiveScopes = @{ $Bucket = @(@{ name = 'Finance' }) }
            }
            $tenant = @{
                name = 'P-DriftAdd'; mode = 'Enable'
                description = $null; priority = $null
                locations = @{ exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @() }
                genericLocations = @(); enforcementPlanes = $null; policyTemplateInfo = $null
                adaptiveScopes = @{
                    endpoint = @(); endpointException = @(); exchange = @(); exchangeException = @()
                    oneDrive = @(); oneDriveException = @(); sharePoint = @(); sharePointException = @()
                    teams = @(); teamsException = @()
                }
                rules = @()
            }
            (Compare-DlpPolicy -Desired $desired -Tenant $tenant) | Should -Contain ("adaptiveScopes.{0}" -f $Bucket)
        }
    }

    Context 'Aggregated round-trip across all 10 adaptive-scope buckets' {
        It 'all 10 buckets coexist on a single policy and emit 10 distinct cmdlet params' {
            $entry = @{
                name = 'P-AllScopes'; mode = 'Enable'
                locations = @{ sharePoint = 'All' }
                adaptiveScopes = @{}
            }
            foreach ($p in $script:BucketMap520) { $entry.adaptiveScopes[$p.Bucket] = @(@{ name = 'Finance' }) }

            $h = ConvertTo-DesiredDlpPolicyHash -Entry $entry
            $splat = Get-DlpPolicySplat -Hash $h

            foreach ($p in $script:BucketMap520) {
                $splat.ContainsKey($p.Param) | Should -BeTrue -Because ('expected splat to carry -' + $p.Param)
                $splat[$p.Param] | Should -Be @('Finance')
            }
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 1: mechanical defaults (#521 slice B / #529)' {

    # Field map exposed at discovery time so -ForEach blocks expand at
    # discovery, not runtime. Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:FieldMap529 = @(
            @{ Field = 'enforcePortalAccess';                  Param = 'EnforcePortalAccess';                  Sample = $true;  Other = $false; JsonSample = 'true' }
            @{ Field = 'notifyEmailExchangeIncludeAttachment'; Param = 'NotifyEmailExchangeIncludeAttachment'; Sample = $true;  Other = $false; JsonSample = 'true' }
            @{ Field = 'reportSeverityLevel';                  Param = 'ReportSeverityLevel';                  Sample = 'Low'; Other = 'High'; JsonSample = '"Low"' }
        )
    }

    BeforeAll {
        $script:SchemaPath529 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema529     = Get-Content -LiteralPath $script:SchemaPath529 -Raw
    }

    Context 'Schema validation per field' {
        It 'schema accepts a rule declaring <Field>' -ForEach $FieldMap529 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":' + $JsonSample + '}]}]}'
            { $doc | Test-Json -Schema $script:Schema529 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects reportSeverityLevel outside the Low/Medium/High enum' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"reportSeverityLevel":"NotAValue"}]}]}'
            { $doc | Test-Json -Schema $script:Schema529 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects non-boolean enforcePortalAccess' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"enforcePortalAccess":"yes"}]}]}'
            { $doc | Test-Json -Schema $script:Schema529 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'Desired-state normalization per field' {
        It '<Field> round-trips through ConvertTo-DesiredDlpRuleHash' -ForEach $FieldMap529 {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $h[$Field] | Should -Be $Sample
        }

        It '<Field> is $null when the desired entry omits it' -ForEach $FieldMap529 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h[$Field] | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission per field' {
        It '<Field> emits -<Param> when desired declares it' -ForEach $FieldMap529 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeTrue -Because ('expected splat to carry -' + $Param)
            $splat[$Param] | Should -Be $Sample
        }

        It '<Field> is omitted from the splat when desired does not declare it' -ForEach $FieldMap529 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection per field' {
        It '<Field>: no drift when desired and tenant match' -ForEach $FieldMap529 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
            }
            $tenant[$Field] = $Sample
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }

        It '<Field>: drift flagged when desired and tenant differ' -ForEach $FieldMap529 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
            }
            $tenant[$Field] = $Other
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain $Field
        }

        It '<Field>: NOT flagged when desired omits it (tracked only when declared)' -ForEach $FieldMap529 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $true
                notifyEmailExchangeIncludeAttachment = $true
                reportSeverityLevel                  = 'High'
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }
    }

    Context 'Aggregated round-trip across all 3 Batch 1 fields' {
        It 'all 3 fields coexist on a single rule and emit 3 distinct cmdlet params' {
            $entry = @{
                name               = 'r-all'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            foreach ($f in $script:FieldMap529) { $entry[$f.Field] = $f.Sample }

            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-AllBatch1'

            foreach ($f in $script:FieldMap529) {
                $splat.ContainsKey($f.Param) | Should -BeTrue -Because ('expected splat to carry -' + $f.Param)
                $splat[$f.Param] | Should -Be $f.Sample
            }
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 2: operator-meaningful scalars (#521 slice C / #532)' {

    # Field map exposed at discovery time so -ForEach blocks expand at
    # discovery, not runtime. Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:FieldMap532 = @(
            @{ Field = 'comment';     Param = 'Comment';     Sample = 'Detects PII shared externally'; Other = 'Different rule comment';   JsonSample = '"Detects PII shared externally"' }
            @{ Field = 'accessScope'; Param = 'AccessScope'; Sample = 'NotInOrganization';            Other = 'InOrganization';            JsonSample = '"NotInOrganization"' }
        )
    }

    BeforeAll {
        $script:SchemaPath532 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema532     = Get-Content -LiteralPath $script:SchemaPath532 -Raw
    }

    Context 'Schema validation per field' {
        It 'schema accepts a rule declaring <Field>' -ForEach $FieldMap532 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":' + $JsonSample + '}]}]}'
            { $doc | Test-Json -Schema $script:Schema532 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects accessScope outside InOrganization/NotInOrganization/PerUser' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"accessScope":"NotAScope"}]}]}'
            { $doc | Test-Json -Schema $script:Schema532 -ErrorAction Stop } | Should -Throw
        }

        It 'schema accepts each of the 3 documented accessScope enum values' {
            foreach ($v in @('InOrganization','NotInOrganization','PerUser')) {
                $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"accessScope":"' + $v + '"}]}]}'
                { $doc | Test-Json -Schema $script:Schema532 -ErrorAction Stop } | Should -Not -Throw -Because ("accessScope=$v should be accepted")
            }
        }
    }

    Context 'Desired-state normalization per field' {
        It '<Field> round-trips through ConvertTo-DesiredDlpRuleHash' -ForEach $FieldMap532 {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $h[$Field] | Should -Be $Sample
        }

        It '<Field> is $null when the desired entry omits it' -ForEach $FieldMap532 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h[$Field] | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission per field' {
        It '<Field> emits -<Param> when desired declares it' -ForEach $FieldMap532 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeTrue -Because ('expected splat to carry -' + $Param)
            $splat[$Param] | Should -Be $Sample
        }

        It '<Field> is omitted from the splat when desired does not declare it' -ForEach $FieldMap532 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection per field' {
        It '<Field>: no drift when desired and tenant match' -ForEach $FieldMap532 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = $null
                accessScope                          = $null
            }
            $tenant[$Field] = $Sample
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }

        It '<Field>: drift flagged when desired and tenant differ' -ForEach $FieldMap532 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = $null
                accessScope                          = $null
            }
            $tenant[$Field] = $Other
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain $Field
        }

        It '<Field>: NOT flagged when desired omits it (tracked only when declared)' -ForEach $FieldMap532 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = 'Some tenant-side comment'
                accessScope                          = 'PerUser'
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }
    }

    Context 'Aggregated round-trip across all 2 Batch 2 fields' {
        It 'both fields coexist on a single rule and emit 2 distinct cmdlet params' {
            $entry = @{
                name               = 'r-all'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            foreach ($f in $script:FieldMap532) { $entry[$f.Field] = $f.Sample }

            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-AllBatch2'

            foreach ($f in $script:FieldMap532) {
                $splat.ContainsKey($f.Param) | Should -BeTrue -Because ('expected splat to carry -' + $f.Param)
                $splat[$f.Param] | Should -Be $f.Sample
            }
        }
    }
}

Describe 'ConvertTo-NormalizedPolicyTemplateInfo deterministic projection (#524)' {

    Context 'Hashtable input -- the Microsoft Copilot policy shape' {
        It 'projects only the dictionary key/value pairs (no Get-Member noise)' {
            $h = @{ Id = 'DlpPolicyTemplatesCustom'; CategoryId = 'DlpPolicyCategoryCustom' }
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $h

            # Must NOT include Get-Member projection of [Hashtable]:
            #   Count, IsFixedSize, IsReadOnly, IsSynchronized, Keys,
            #   SyncRoot, Values.
            $r.Keys | Should -Be @('CategoryId','Id') -Because 'keys sorted by ordinal'
            $r.Count | Should -Be 2
            $r['Id'] | Should -Be 'DlpPolicyTemplatesCustom'
            $r['CategoryId'] | Should -Be 'DlpPolicyCategoryCustom'
        }

        It 'produces byte-equal projections for two hashtables with the same data in different insertion order (the #524 bug)' {
            $a = @{}
            $a['Id'] = 'DlpPolicyTemplatesCustom'
            $a['CategoryId'] = 'DlpPolicyCategoryCustom'

            $b = @{}
            $b['CategoryId'] = 'DlpPolicyCategoryCustom'
            $b['Id'] = 'DlpPolicyTemplatesCustom'

            $ra = ConvertTo-NormalizedPolicyTemplateInfo -Source $a
            $rb = ConvertTo-NormalizedPolicyTemplateInfo -Source $b

            # Same keys in same order
            @($ra.Keys) | Should -Be @($rb.Keys)
            # Same YAML projection
            ($ra | ConvertTo-Json -Depth 5 -Compress) | Should -Be ($rb | ConvertTo-Json -Depth 5 -Compress)
        }

        It 'sorts keys deterministically by string ordinal' {
            $h = @{ Zebra = 'z'; Apple = 'a'; Mango = 'm' }
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $h
            @($r.Keys) | Should -Be @('Apple','Mango','Zebra')
        }

        It 'drops null values' {
            $h = @{ Id = 'something'; Nothing = $null }
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $h
            $r.Keys | Should -Not -Contain 'Nothing'
            $r.Keys | Should -Contain 'Id'
        }

        It 'returns $null when the input has no non-null entries' {
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source @{}
            $r | Should -BeNullOrEmpty
        }

        It 'returns $null when the input is $null' {
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $null
            $r | Should -BeNullOrEmpty
        }
    }

    Context 'PSCustomObject input -- the legacy / deserialized shape' {
        It 'projects properties sorted by name' {
            $o = [pscustomobject]@{ Id = 'something'; CategoryId = 'other' }
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $o
            @($r.Keys) | Should -Be @('CategoryId','Id')
            $r['Id'] | Should -Be 'something'
        }

        It 'defensively skips IDictionary-shape noise properties' {
            # If a PSCustomObject defensively wraps a [Hashtable]-like shape,
            # don't surface Count/IsFixedSize/IsReadOnly/IsSynchronized/Keys/
            # Values/SyncRoot in the projection.
            $o = [pscustomobject]@{
                Id           = 'real-data'
                Count        = 99
                IsFixedSize  = $false
                Keys         = @('K1','K2')
                Values       = @('V1','V2')
            }
            $r = ConvertTo-NormalizedPolicyTemplateInfo -Source $o
            $r.Keys | Should -Not -Contain 'Count'
            $r.Keys | Should -Not -Contain 'IsFixedSize'
            $r.Keys | Should -Not -Contain 'Keys'
            $r.Keys | Should -Not -Contain 'Values'
            $r.Keys | Should -Contain 'Id'
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 3a: operator-facing notify content (#521 slice D / #536)' {

    # Field map exposed at discovery time so -ForEach blocks expand at
    # discovery, not runtime. Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:FieldMap536 = @(
            @{ Field = 'notifyEmailCustomText';        Param = 'NotifyEmailCustomText';        Sample = 'You shared content that contains sensitive data.';     Other = 'Different email body';          JsonSample = '"You shared content that contains sensitive data."' }
            @{ Field = 'notifyPolicyTipCustomText';    Param = 'NotifyPolicyTipCustomText';    Sample = 'This item contains sensitive content.';                  Other = 'Different policy tip text';     JsonSample = '"This item contains sensitive content."' }
            @{ Field = 'notifyPolicyTipDisplayOption'; Param = 'NotifyPolicyTipDisplayOption'; Sample = 'Tip';                                                    Other = 'NotificationOnly';              JsonSample = '"Tip"' }
        )
    }

    BeforeAll {
        $script:SchemaPath536 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema536     = Get-Content -LiteralPath $script:SchemaPath536 -Raw
    }

    Context 'Schema validation per field' {
        It 'schema accepts a rule declaring <Field>' -ForEach $FieldMap536 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":' + $JsonSample + '}]}]}'
            { $doc | Test-Json -Schema $script:Schema536 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts notifyPolicyTipDisplayOption values beyond the originally-assumed set (live tenant returns Dialog; issue #71)' {
            # The enum was relaxed to a non-empty string to match its sibling
            # notify-* fields: the live service returns values (e.g. Dialog) outside
            # the originally-pinned [Tip, NotifyOnly, NotificationOnly], and the
            # cmdlet validates the allowed set server-side at apply time.
            foreach ($v in @('Tip','NotifyOnly','NotificationOnly','Dialog')) {
                $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"notifyPolicyTipDisplayOption":"' + $v + '"}]}]}'
                { $doc | Test-Json -Schema $script:Schema536 -ErrorAction Stop } | Should -Not -Throw -Because ("notifyPolicyTipDisplayOption=$v should be accepted")
            }
        }

        It 'schema still rejects an EMPTY notifyPolicyTipDisplayOption (minLength: 1 -- relaxed, not unconstrained)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"notifyPolicyTipDisplayOption":""}]}]}'
            { $doc | Test-Json -Schema $script:Schema536 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'Desired-state normalization per field' {
        It '<Field> round-trips through ConvertTo-DesiredDlpRuleHash' -ForEach $FieldMap536 {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $h[$Field] | Should -Be $Sample
        }

        It '<Field> is $null when the desired entry omits it' -ForEach $FieldMap536 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h[$Field] | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission per field' {
        It '<Field> emits -<Param> when desired declares it' -ForEach $FieldMap536 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeTrue -Because ('expected splat to carry -' + $Param)
            $splat[$Param] | Should -Be $Sample
        }

        It '<Field> is omitted from the splat when desired does not declare it' -ForEach $FieldMap536 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection per field' {
        It '<Field>: no drift when desired and tenant match' -ForEach $FieldMap536 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = $null
                accessScope                          = $null
                notifyEmailCustomText                = $null
                notifyPolicyTipCustomText            = $null
                notifyPolicyTipDisplayOption         = $null
            }
            $tenant[$Field] = $Sample
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }

        It '<Field>: drift flagged when desired and tenant differ' -ForEach $FieldMap536 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = $null
                accessScope                          = $null
                notifyEmailCustomText                = $null
                notifyPolicyTipCustomText            = $null
                notifyPolicyTipDisplayOption         = $null
            }
            $tenant[$Field] = $Other
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain $Field
        }

        It '<Field>: NOT flagged when desired omits it (tracked only when declared)' -ForEach $FieldMap536 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenant  = @{
                name                                 = 'r'
                priority                             = $null
                sensitiveInfoTypes                   = $desired.sensitiveInfoTypes
                sensitivityLabels                    = @()
                advancedRule                         = $null
                blockAccess                          = $null
                notifyUser                           = @()
                generateIncidentReport               = @()
                generateAlert                        = @()
                enforcePortalAccess                  = $null
                notifyEmailExchangeIncludeAttachment = $null
                reportSeverityLevel                  = $null
                comment                              = $null
                accessScope                          = $null
                notifyEmailCustomText                = 'Some tenant-side email body'
                notifyPolicyTipCustomText            = 'Some tenant-side policy tip'
                notifyPolicyTipDisplayOption         = 'NotifyOnly'
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }
    }

    Context 'Aggregated round-trip across all 3 Batch 3a fields' {
        It 'all 3 fields coexist on a single rule and emit 3 distinct cmdlet params' {
            $entry = @{
                name               = 'r-all'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            foreach ($f in $script:FieldMap536) { $entry[$f.Field] = $f.Sample }

            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-AllBatch3a'

            foreach ($f in $script:FieldMap536) {
                $splat.ContainsKey($f.Param) | Should -BeTrue -Because ('expected splat to carry -' + $f.Param)
                $splat[$f.Param] | Should -Be $f.Sample
            }
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 3b: notify recipient/override/remediation (#521 slice E / #538)' {

    # Field map exposed at discovery time so -ForEach blocks expand at
    # discovery, not runtime. Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:FieldMap538 = @(
            @{ Field = 'notifyUserType';                        Param = 'NotifyUserType';                        Sample = 'NotSet'; Other = 'Owner';      JsonSample = '"NotSet"' }
            @{ Field = 'notifyOverrideRequirements';            Param = 'NotifyOverrideRequirements';            Sample = 'None';   Other = 'WithJustification'; JsonSample = '"None"' }
            @{ Field = 'notifyEmailOnedriveRemediationActions'; Param = 'NotifyEmailOnedriveRemediationActions'; Sample = 'NotSet'; Other = 'Remove';     JsonSample = '"NotSet"' }
        )
    }

    BeforeAll {
        $script:SchemaPath538 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema538     = Get-Content -LiteralPath $script:SchemaPath538 -Raw
    }

    Context 'Schema validation per field' {
        It 'schema accepts a rule declaring <Field>' -ForEach $FieldMap538 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":' + $JsonSample + '}]}]}'
            { $doc | Test-Json -Schema $script:Schema538 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects empty string for <Field> (minLength: 1)' -ForEach $FieldMap538 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":""}]}]}'
            { $doc | Test-Json -Schema $script:Schema538 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'Desired-state normalization per field' {
        It '<Field> round-trips through ConvertTo-DesiredDlpRuleHash' -ForEach $FieldMap538 {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $h[$Field] | Should -Be $Sample
        }

        It '<Field> is $null when the desired entry omits it' -ForEach $FieldMap538 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h[$Field] | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission per field' {
        It '<Field> emits -<Param> when desired declares it' -ForEach $FieldMap538 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeTrue -Because ('expected splat to carry -' + $Param)
            $splat[$Param] | Should -Be $Sample
        }

        It '<Field> is omitted from the splat when desired does not declare it' -ForEach $FieldMap538 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection per field' {
        It '<Field>: no drift when desired and tenant match' -ForEach $FieldMap538 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
            }
            $tenant[$Field] = $Sample
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }

        It '<Field>: drift flagged when desired and tenant differ' -ForEach $FieldMap538 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
            }
            $tenant[$Field] = $Other
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain $Field
        }

        It '<Field>: NOT flagged when desired omits it (tracked only when declared)' -ForEach $FieldMap538 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = 'Owner'
                notifyOverrideRequirements            = 'WithJustification'
                notifyEmailOnedriveRemediationActions = 'Remove'
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }
    }

    Context 'Aggregated round-trip across all 3 Batch 3b fields' {
        It 'all 3 fields coexist on a single rule and emit 3 distinct cmdlet params' {
            $entry = @{
                name               = 'r-all'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            foreach ($f in $script:FieldMap538) { $entry[$f.Field] = $f.Sample }

            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-AllBatch3b'

            foreach ($f in $script:FieldMap538) {
                $splat.ContainsKey($f.Param) | Should -BeTrue -Because ('expected splat to carry -' + $f.Param)
                $splat[$f.Param] | Should -Be $f.Sample
            }
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 3c: notify override / incident-report (#521 slice F / #540)' {

    # Field map exposed at discovery time so -ForEach blocks expand at
    # discovery, not runtime. Reference: https://pester.dev/docs/usage/data-driven-tests
    BeforeDiscovery {
        $script:FieldMap540 = @(
            @{ Field = 'notifyAllowOverride';   Param = 'NotifyAllowOverride';   Sample = 'WithJustification'; Other = 'WithFalsePositive'; JsonSample = '"WithJustification"' }
            @{ Field = 'incidentReportContent'; Param = 'IncidentReportContent'; Sample = 'Title, DocumentAuthor, Service'; Other = 'Title, Service'; JsonSample = '"Title, DocumentAuthor, Service"' }
        )
    }

    BeforeAll {
        $script:SchemaPath540 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema540     = Get-Content -LiteralPath $script:SchemaPath540 -Raw
    }

    Context 'Schema validation per field' {
        It 'schema accepts a rule declaring <Field>' -ForEach $FieldMap540 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":' + $JsonSample + '}]}]}'
            { $doc | Test-Json -Schema $script:Schema540 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects empty string for <Field> (minLength: 1)' -ForEach $FieldMap540 {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"' + $Field + '":""}]}]}'
            { $doc | Test-Json -Schema $script:Schema540 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'Desired-state normalization per field' {
        It '<Field> round-trips through ConvertTo-DesiredDlpRuleHash' -ForEach $FieldMap540 {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $h[$Field] | Should -Be $Sample
        }

        It '<Field> is $null when the desired entry omits it' -ForEach $FieldMap540 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h[$Field] | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission per field' {
        It '<Field> emits -<Param> when desired declares it' -ForEach $FieldMap540 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeTrue -Because ('expected splat to carry -' + $Param)
            $splat[$Param] | Should -Be $Sample
        }

        It '<Field> is omitted from the splat when desired does not declare it' -ForEach $FieldMap540 {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey($Param) | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection per field' {
        It '<Field>: no drift when desired and tenant match' -ForEach $FieldMap540 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
            }
            $tenant[$Field] = $Sample
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }

        It '<Field>: drift flagged when desired and tenant differ' -ForEach $FieldMap540 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                $Field             = $Sample
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
            }
            $tenant[$Field] = $Other
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain $Field
        }

        It '<Field>: NOT flagged when desired omits it (tracked only when declared)' -ForEach $FieldMap540 {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = 'WithFalsePositive'
                incidentReportContent                 = 'Title, Service'
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain $Field
        }
    }

    Context 'Aggregated round-trip across all 2 Batch 3c fields' {
        It 'both fields coexist on a single rule and emit 2 distinct cmdlet params' {
            $entry = @{
                name               = 'r-all'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            foreach ($f in $script:FieldMap540) { $entry[$f.Field] = $f.Sample }

            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-AllBatch3c'

            foreach ($f in $script:FieldMap540) {
                $splat.ContainsKey($f.Param) | Should -BeTrue -Because ('expected splat to carry -' + $f.Param)
                $splat[$f.Param] | Should -Be $f.Sample
            }
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 4/1: endpointDlpRestrictions (#521 slice G / #542)' {

    BeforeAll {
        $script:SchemaPath542 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema542     = Get-Content -LiteralPath $script:SchemaPath542 -Raw

        # Sample restriction items mirror the lab tenant shape:
        # ArrayList[Hashtable] with keys {setting, value, appgroup, defaultmessage}.
        $script:SampleEdr542 = @(
            @{ setting = 'CloudEgress';    value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
            @{ setting = 'CopyPaste';      value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
            @{ setting = 'Print';          value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
        )
    }

    Context 'Schema validation' {
        It 'schema accepts a rule declaring endpointDlpRestrictions with multiple items' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"endpoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"endpointDlpRestrictions":[{"setting":"CloudEgress","value":"Audit","appgroup":"none","defaultmessage":"none"},{"setting":"CopyPaste","value":"Audit","appgroup":"none","defaultmessage":"none"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema542 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts a single-item endpointDlpRestrictions array' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"endpoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"endpointDlpRestrictions":[{"setting":"CloudEgress"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema542 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects an empty endpointDlpRestrictions array (minItems: 1)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"endpoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"endpointDlpRestrictions":[]}]}]}'
            { $doc | Test-Json -Schema $script:Schema542 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects an item missing the required setting key' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"endpoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"endpointDlpRestrictions":[{"value":"Audit"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema542 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects an item carrying an unknown key (additionalProperties: false)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"endpoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"endpointDlpRestrictions":[{"setting":"CloudEgress","bogusKey":"x"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema542 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'ConvertTo-NormalizedEndpointDlpRestrictions' {
        It 'sorts items by setting (ordinal)' {
            $unsorted = @(
                @{ setting = 'Print';       value = 'Audit' }
                @{ setting = 'CloudEgress'; value = 'Audit' }
                @{ setting = 'CopyPaste';   value = 'Audit' }
            )
            $sorted = ConvertTo-NormalizedEndpointDlpRestrictions -Source $unsorted
            @($sorted).Count | Should -Be 3
            @($sorted)[0].setting | Should -Be 'CloudEgress'
            @($sorted)[1].setting | Should -Be 'CopyPaste'
            @($sorted)[2].setting | Should -Be 'Print'
        }

        It 'drops items without a setting key' {
            $mixed = @(
                @{ value = 'Audit' }
                @{ setting = 'Print'; value = 'Audit' }
            )
            $out = ConvertTo-NormalizedEndpointDlpRestrictions -Source $mixed
            @($out).Count | Should -Be 1
            @($out)[0].setting | Should -Be 'Print'
        }

        It 'returns @() for $null input' {
            (ConvertTo-NormalizedEndpointDlpRestrictions -Source $null).Count | Should -Be 0
        }
    }

    Context 'ConvertTo-NormalizedEndpointDlpRestrictionsJson' {
        It 'produces identical JSON for two inputs that differ only by item order' {
            $a = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(
                @{ setting = 'CloudEgress'; value = 'Audit' }
                @{ setting = 'Print';       value = 'Audit' }
            )
            $b = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(
                @{ setting = 'Print';       value = 'Audit' }
                @{ setting = 'CloudEgress'; value = 'Audit' }
            )
            $jsonA = ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $a
            $jsonB = ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $b
            $jsonA | Should -Be $jsonB
        }

        It 'produces different JSON when a value changes' {
            $a = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(@{ setting = 'CloudEgress'; value = 'Audit' })
            $b = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(@{ setting = 'CloudEgress'; value = 'Block' })
            (ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $a) | Should -Not -Be (ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $b)
        }

        It 'returns [] for empty input' {
            (ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions @()) | Should -Be '[]'
        }
    }

    Context 'Desired-state normalization via ConvertTo-DesiredDlpRuleHash' {
        It 'round-trips endpointDlpRestrictions through ConvertTo-DesiredDlpRuleHash (sorted)' {
            $entry = @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = @(
                    @{ setting = 'Print';       value = 'Audit' }
                    @{ setting = 'CloudEgress'; value = 'Audit' }
                )
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            @($h.endpointDlpRestrictions).Count | Should -Be 2
            @($h.endpointDlpRestrictions)[0].setting | Should -Be 'CloudEgress'
            @($h.endpointDlpRestrictions)[1].setting | Should -Be 'Print'
        }

        It 'endpointDlpRestrictions is empty @() when the desired entry omits it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            @($h.endpointDlpRestrictions).Count | Should -Be 0
        }
    }

    Context 'Splat emission via Get-DlpRuleSplat' {
        It 'emits -EndpointDlpRestrictions as a hashtable[] when desired declares it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = $script:SampleEdr542
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('EndpointDlpRestrictions') | Should -BeTrue
            @($splat.EndpointDlpRestrictions).Count | Should -Be 3
            @($splat.EndpointDlpRestrictions)[0] | Should -BeOfType [hashtable]
            @($splat.EndpointDlpRestrictions)[0].setting | Should -Be 'CloudEgress'
        }

        It 'omits -EndpointDlpRestrictions when desired does not declare it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('EndpointDlpRestrictions') | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection for endpointDlpRestrictions' {
        It 'no drift when desired and tenant match' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = $script:SampleEdr542
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = $desired.endpointDlpRestrictions
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'endpointDlpRestrictions'
        }

        It 'no drift when desired and tenant items differ only by order' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = @(
                    @{ setting = 'Print';       value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
                    @{ setting = 'CloudEgress'; value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
                )
            }
            $tenantNormalized = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(
                @{ setting = 'CloudEgress'; value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
                @{ setting = 'Print';       value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
            )
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = $tenantNormalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'endpointDlpRestrictions'
        }

        It 'drift flagged when a value changes (Audit -> Block)' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = @(
                    @{ setting = 'CloudEgress'; value = 'Audit'; appgroup = 'none'; defaultmessage = 'none' }
                )
            }
            $tenantNormalized = ConvertTo-NormalizedEndpointDlpRestrictions -Source @(
                @{ setting = 'CloudEgress'; value = 'Block'; appgroup = 'none'; defaultmessage = 'none' }
            )
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = $tenantNormalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'endpointDlpRestrictions'
        }

        It 'drift flagged when desired declares the field and tenant has none' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name                    = 'r'
                sensitiveInfoTypes      = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                endpointDlpRestrictions = $script:SampleEdr542
            }
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'endpointDlpRestrictions'
        }

        It 'NOT flagged when desired omits the field (tracked only when declared)' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenantNormalized = ConvertTo-NormalizedEndpointDlpRestrictions -Source $script:SampleEdr542
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = $tenantNormalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'endpointDlpRestrictions'
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 4/2: alertProperties (#521 slice H / #544)' {

    BeforeAll {
        $script:SchemaPath544 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema544     = Get-Content -LiteralPath $script:SchemaPath544 -Raw

        # Lab-tenant sample shape (single key {AggregationType: None}).
        $script:SampleAp544 = @{ AggregationType = 'None' }
    }

    Context 'Schema validation' {
        It 'schema accepts a single-key alertProperties (AggregationType: None)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"alertProperties":{"AggregationType":"None"}}]}]}'
            { $doc | Test-Json -Schema $script:Schema544 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts a multi-key alertProperties (open shape)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"alertProperties":{"AggregationType":"None","Threshold":"5"}}]}]}'
            { $doc | Test-Json -Schema $script:Schema544 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts an unknown key (additionalProperties open)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"alertProperties":{"NewKeyMicrosoftMightAdd":"someValue"}}]}]}'
            { $doc | Test-Json -Schema $script:Schema544 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects an empty alertProperties object (minProperties: 1)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"alertProperties":{}}]}]}'
            { $doc | Test-Json -Schema $script:Schema544 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects a non-string value (additionalProperties.type: string)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"alertProperties":{"AggregationType":5}}]}]}'
            { $doc | Test-Json -Schema $script:Schema544 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'ConvertTo-NormalizedAlertProperties' {
        It 'returns a pscustomobject with keys sorted ordinal' {
            $unsorted = @{ Zebra = 'z'; Apple = 'a'; Mango = 'm' }
            $sorted = ConvertTo-NormalizedAlertProperties -Source $unsorted
            @($sorted.PSObject.Properties.Name) | Should -Be @('Apple','Mango','Zebra')
        }

        It 'coerces non-string values to string' {
            $h = @{ Threshold = 5; Aggregation = 'None' }
            $out = ConvertTo-NormalizedAlertProperties -Source $h
            $out.Threshold | Should -BeOfType [string]
            $out.Threshold | Should -Be '5'
        }

        It 'returns $null for $null input' {
            (ConvertTo-NormalizedAlertProperties -Source $null) | Should -BeNullOrEmpty
        }

        It 'returns $null for empty hashtable' {
            (ConvertTo-NormalizedAlertProperties -Source @{}) | Should -BeNullOrEmpty
        }

        It 'skips keys whose value is $null' {
            $out = ConvertTo-NormalizedAlertProperties -Source @{ Keep = 'yes'; Drop = $null }
            @($out.PSObject.Properties.Name) | Should -Be @('Keep')
        }
    }

    Context 'ConvertTo-NormalizedAlertPropertiesJson' {
        It 'produces identical JSON for two inputs that differ only by key order' {
            $a = ConvertTo-NormalizedAlertProperties -Source @{ K1 = 'v1'; K2 = 'v2' }
            $b = ConvertTo-NormalizedAlertProperties -Source @{ K2 = 'v2'; K1 = 'v1' }
            (ConvertTo-NormalizedAlertPropertiesJson -Properties $a) | Should -Be (ConvertTo-NormalizedAlertPropertiesJson -Properties $b)
        }

        It 'produces different JSON when a value changes' {
            $a = ConvertTo-NormalizedAlertProperties -Source @{ AggregationType = 'None' }
            $b = ConvertTo-NormalizedAlertProperties -Source @{ AggregationType = 'SimpleAggregation' }
            (ConvertTo-NormalizedAlertPropertiesJson -Properties $a) | Should -Not -Be (ConvertTo-NormalizedAlertPropertiesJson -Properties $b)
        }

        It 'returns {} for $null input' {
            (ConvertTo-NormalizedAlertPropertiesJson -Properties $null) | Should -Be '{}'
        }
    }

    Context 'Desired-state normalization via ConvertTo-DesiredDlpRuleHash' {
        It 'round-trips alertProperties through ConvertTo-DesiredDlpRuleHash (sorted keys)' {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = @{ Zebra = 'z'; Apple = 'a' }
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            @($h.alertProperties.PSObject.Properties.Name) | Should -Be @('Apple','Zebra')
        }

        It 'alertProperties is $null when the desired entry omits it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $h.alertProperties | Should -BeNullOrEmpty
        }
    }

    Context 'Splat emission via Get-DlpRuleSplat' {
        It 'emits -AlertProperties as a hashtable when desired declares it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = $script:SampleAp544
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('AlertProperties') | Should -BeTrue
            $splat.AlertProperties | Should -BeOfType [hashtable]
            $splat.AlertProperties.AggregationType | Should -Be 'None'
        }

        It 'omits -AlertProperties when desired does not declare it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('AlertProperties') | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection for alertProperties' {
        It 'no drift when desired and tenant match' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = $script:SampleAp544
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $desired.alertProperties
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'alertProperties'
        }

        It 'no drift when desired and tenant differ only by key order' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = @{ B = '2'; A = '1' }
            }
            $tenantAp = ConvertTo-NormalizedAlertProperties -Source @{ A = '1'; B = '2' }
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $tenantAp
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'alertProperties'
        }

        It 'drift flagged when a value changes' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = @{ AggregationType = 'None' }
            }
            $tenantAp = ConvertTo-NormalizedAlertProperties -Source @{ AggregationType = 'SimpleAggregation' }
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $tenantAp
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'alertProperties'
        }

        It 'drift flagged when tenant has an extra key' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                alertProperties    = @{ AggregationType = 'None' }
            }
            $tenantAp = ConvertTo-NormalizedAlertProperties -Source @{ AggregationType = 'None'; Threshold = '5' }
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $tenantAp
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'alertProperties'
        }

        It 'NOT flagged when desired omits the field (tracked only when declared)' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenantAp = ConvertTo-NormalizedAlertProperties -Source $script:SampleAp544
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $tenantAp
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'alertProperties'
        }
    }
}

Describe 'DLP rule tracked-field expansion -- Batch 4/3: restrictAccess (#521 slice I / #546)' {

    BeforeAll {
        $script:SchemaPath546 = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema546     = Get-Content -LiteralPath $script:SchemaPath546 -Raw

        # Lab-tenant sample shape: ArrayList[Hashtable] of {setting, value}.
        $script:SampleRa546 = @(
            @{ setting = 'UploadText'; value = 'Block' }
        )
    }

    Context 'Schema validation' {
        It 'schema accepts a single-item restrictAccess (lab-tenant shape)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[{"setting":"UploadText","value":"Block"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts a multi-item restrictAccess' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[{"setting":"UploadText","value":"Block"},{"setting":"ShareItems","value":"Audit"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema accepts an item with only setting (value optional)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[{"setting":"UploadText"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Not -Throw
        }

        It 'schema rejects an empty restrictAccess array (minItems: 1)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects an item missing the required setting key' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[{"value":"Block"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Throw
        }

        It 'schema rejects an item carrying an unknown key (additionalProperties: false)' {
            $doc = '{"policies":[{"name":"p","mode":"Enable","locations":{"sharePoint":"All"},"rules":[{"name":"r","sensitiveInfoTypes":[{"guid":"50842eb7-edc8-4019-85dd-5a5c1f2bb085"}],"restrictAccess":[{"setting":"UploadText","bogusKey":"x"}]}]}]}'
            { $doc | Test-Json -Schema $script:Schema546 -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'ConvertTo-NormalizedRestrictAccess' {
        It 'sorts items by setting (ordinal)' {
            $unsorted = @(
                @{ setting = 'Zebra';      value = 'Block' }
                @{ setting = 'Apple';      value = 'Audit' }
                @{ setting = 'UploadText'; value = 'Block' }
            )
            $sorted = ConvertTo-NormalizedRestrictAccess -Source $unsorted
            @($sorted).Count | Should -Be 3
            @($sorted)[0].setting | Should -Be 'Apple'
            @($sorted)[1].setting | Should -Be 'UploadText'
            @($sorted)[2].setting | Should -Be 'Zebra'
        }

        It 'drops items without a setting key' {
            $mixed = @(
                @{ value = 'Block' }
                @{ setting = 'UploadText'; value = 'Block' }
            )
            $out = ConvertTo-NormalizedRestrictAccess -Source $mixed
            @($out).Count | Should -Be 1
            @($out)[0].setting | Should -Be 'UploadText'
        }

        It 'returns @() for $null input' {
            (ConvertTo-NormalizedRestrictAccess -Source $null).Count | Should -Be 0
        }
    }

    Context 'ConvertTo-NormalizedRestrictAccessJson' {
        It 'produces identical JSON for two inputs that differ only by item order' {
            $a = ConvertTo-NormalizedRestrictAccess -Source @(
                @{ setting = 'UploadText'; value = 'Block' }
                @{ setting = 'ShareItems'; value = 'Audit' }
            )
            $b = ConvertTo-NormalizedRestrictAccess -Source @(
                @{ setting = 'ShareItems'; value = 'Audit' }
                @{ setting = 'UploadText'; value = 'Block' }
            )
            (ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $a) | Should -Be (ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $b)
        }

        It 'produces different JSON when a value changes' {
            $a = ConvertTo-NormalizedRestrictAccess -Source @(@{ setting = 'UploadText'; value = 'Block' })
            $b = ConvertTo-NormalizedRestrictAccess -Source @(@{ setting = 'UploadText'; value = 'Audit' })
            (ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $a) | Should -Not -Be (ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $b)
        }

        It 'returns [] for empty input' {
            (ConvertTo-NormalizedRestrictAccessJson -RestrictAccess @()) | Should -Be '[]'
        }
    }

    Context 'Desired-state normalization via ConvertTo-DesiredDlpRuleHash' {
        It 'round-trips restrictAccess through ConvertTo-DesiredDlpRuleHash (sorted)' {
            $entry = @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = @(
                    @{ setting = 'UploadText'; value = 'Block' }
                    @{ setting = 'ShareItems'; value = 'Audit' }
                )
            }
            $h = ConvertTo-DesiredDlpRuleHash -Entry $entry
            @($h.restrictAccess).Count | Should -Be 2
            @($h.restrictAccess)[0].setting | Should -Be 'ShareItems'
            @($h.restrictAccess)[1].setting | Should -Be 'UploadText'
        }

        It 'restrictAccess is empty @() when the desired entry omits it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            @($h.restrictAccess).Count | Should -Be 0
        }
    }

    Context 'Splat emission via Get-DlpRuleSplat' {
        It 'emits -RestrictAccess as a hashtable[] when desired declares it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = $script:SampleRa546
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('RestrictAccess') | Should -BeTrue
            @($splat.RestrictAccess).Count | Should -Be 1
            @($splat.RestrictAccess)[0] | Should -BeOfType [hashtable]
            @($splat.RestrictAccess)[0].setting | Should -Be 'UploadText'
            @($splat.RestrictAccess)[0].value | Should -Be 'Block'
        }

        It 'omits -RestrictAccess when desired does not declare it' {
            $h = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $splat = Get-DlpRuleSplat -Hash $h -PolicyName 'P-Test'
            $splat.ContainsKey('RestrictAccess') | Should -BeFalse
        }
    }

    Context 'Compare-DlpRule drift detection for restrictAccess' {
        It 'no drift when desired and tenant match' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = $script:SampleRa546
            }
            $tenant  = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $null
                restrictAccess                        = $desired.restrictAccess
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'restrictAccess'
        }

        It 'no drift when desired and tenant items differ only by order' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = @(
                    @{ setting = 'UploadText'; value = 'Block' }
                    @{ setting = 'ShareItems'; value = 'Audit' }
                )
            }
            $tenantRa = ConvertTo-NormalizedRestrictAccess -Source @(
                @{ setting = 'ShareItems'; value = 'Audit' }
                @{ setting = 'UploadText'; value = 'Block' }
            )
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $null
                restrictAccess                        = $tenantRa
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'restrictAccess'
        }

        It 'drift flagged when a value changes (Block -> Audit)' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = @(@{ setting = 'UploadText'; value = 'Block' })
            }
            $tenantRa = ConvertTo-NormalizedRestrictAccess -Source @(@{ setting = 'UploadText'; value = 'Audit' })
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $null
                restrictAccess                        = $tenantRa
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'restrictAccess'
        }

        It 'drift flagged when desired declares the field and tenant has none' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
                restrictAccess     = $script:SampleRa546
            }
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $null
                restrictAccess                        = @()
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'restrictAccess'
        }

        It 'NOT flagged when desired omits the field (tracked only when declared)' {
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name               = 'r'
                sensitiveInfoTypes = @(@{ guid = '50842eb7-edc8-4019-85dd-5a5c1f2bb085' })
            }
            $tenantRa = ConvertTo-NormalizedRestrictAccess -Source $script:SampleRa546
            $tenant = @{
                name                                  = 'r'
                priority                              = $null
                sensitiveInfoTypes                    = $desired.sensitiveInfoTypes
                sensitivityLabels                     = @()
                advancedRule                          = $null
                blockAccess                           = $null
                notifyUser                            = @()
                generateIncidentReport                = @()
                generateAlert                         = @()
                enforcePortalAccess                   = $null
                notifyEmailExchangeIncludeAttachment  = $null
                reportSeverityLevel                   = $null
                comment                               = $null
                accessScope                           = $null
                notifyEmailCustomText                 = $null
                notifyPolicyTipCustomText             = $null
                notifyPolicyTipDisplayOption          = $null
                notifyUserType                        = $null
                notifyOverrideRequirements            = $null
                notifyEmailOnedriveRemediationActions = $null
                notifyAllowOverride                   = $null
                incidentReportContent                 = $null
                endpointDlpRestrictions               = @()
                alertProperties                       = $null
                restrictAccess                        = $tenantRa
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Not -Contain 'restrictAccess'
        }
    }
}

# ---------------------------------------------------------------------------
# ADR 0029 direction-policy contract (#556).
# Mirrors tests/scripts/Deploy-AutoLabelPolicies.Tests.ps1 and
# tests/scripts/Deploy-Labels.Tests.ps1: source-text assertions for
# script-level requirements + direct helper invocations from the
# shared scripts/modules/DirectionPolicy.psm1 module.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
# ---------------------------------------------------------------------------

Describe 'DirectionPolicy parameter (ADR 0029) -- DLP' {

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
        # Mirrors the AutoLabelPolicies precedent: -ExportCurrentState
        # callers can opt into audit mode without separate parameter
        # ceremonies.
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy'
    }

    It 'declares -SkipNames on the Apply parameter set only' {
        # The workflow uses -SkipNames to pass a pre-computed skip
        # list to the apply path; the export path has no use for it.
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }

    It 'imports the shared DirectionPolicy.psm1 module rather than re-inlining the resolver' {
        # ADR 0029 + #556 AC: do NOT re-inline Resolve-DirectionPolicyAction.
        $script:ScriptText | Should -Match 'Import-Module\s+\(Join-Path\s+\$PSScriptRoot\s+''modules/DirectionPolicy\.psm1''\)'
        $script:ScriptText | Should -Not -Match 'function\s+Resolve-DirectionPolicyAction'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029) -- DLP' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

        # Import the shared module so the behavior-level It blocks can
        # call Resolve-DirectionPolicyAction directly (mirrors the
        # sibling test suites).
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
            -Force -ErrorAction Stop
    }

    It 'has an audit-mode short-circuit that emits [ADR0029-AUDIT] and sets $WhatIfPreference = $true' {
        # Audit mode flips $WhatIfPreference so every $PSCmdlet.ShouldProcess(...)
        # call below the short-circuit falls into its existing "Would..."
        # else branch. The AUDIT marker is the operator-visible signal.
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''[^}]*\$WhatIfPreference\s*=\s*\$true\s*\r?\n\s*\}'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'portal-wins'
    }

    It 'returns Update when policy is portal-wins and no drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'emits one Write-Warning per drifted DLP policy on repo-wins' {
        # Source-text assertion: warning fires once per Update entry
        # in the policy direction-policy pass with the comma-joined
        # drifted-field set. Wording must include "DLP policy" so a
        # run-log grep can disambiguate from sibling reconcilers.
        $script:ScriptText | Should -Match 'Write-Warning \("Overwriting tenant on DLP policy '''
    }

    It 'emits one Write-Warning per drifted DLP rule on repo-wins' {
        # DLP policies and rules are planned separately; warnings
        # must use kind-specific wording for the same reason.
        $script:ScriptText | Should -Match 'Write-Warning \("Overwriting tenant on DLP rule '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped object for workflow consumption' {
        # The Phase 2 workflow (deploy-dlp.yml, separate item) will
        # parse these markers (one per line) to build the auto-PR
        # skip list. Format must match `^\[ADR0029-SKIP\] (.+)$` per
        # github-actions.instructions.md.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }
}

Describe 'SkipNames behavior (ADR 0029) -- DLP' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
            -Force -ErrorAction Stop
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-dlp-confidential') `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is false' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('lab-dlp-confidential') `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('LAB-DLP-CONFIDENTIAL') `
            -DisplayName 'lab-dlp-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        # A rule named 'lab-dlp-confidential-rule' is not skipped by
        # `-SkipNames lab-dlp-confidential`.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-dlp-confidential') `
            -DisplayName 'lab-dlp-confidential-rule' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames' {
        # The script ignores skip-list entries that match no object,
        # so a stale workflow-supplied list does not abort the run.
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchPolicy') `
                -DisplayName 'lab-dlp-confidential' `
                -HasDrift    $true } | Should -Not -Throw
    }

    It 'handles an empty SkipList without error' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-dlp-confidential' `
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
        $script:B4Source | Should -Match ([regex]::Escape("-ObjectTypeNoun 'DLP rule'"))
        $script:B4Source | Should -Match ([regex]::Escape("-ObjectTypeNoun 'DLP policy'"))
    }
    It 'keys each tier on its own live denominator' {
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
    It 'gates guard 2 on non-audit (AUDIT TRAP: script flips WhatIfPreference, does not empty orphan plans)' {
        $script:B4Source | Should -Match ([regex]::Escape("-and `$DirectionPolicy -ne 'audit'"))
    }
    It 'places guard 2 before the ADR 0052 confirmation gates' {
        $ratioIdx = $script:B4Source.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:B4Source.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-DLPPolicies.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$RuleOrphans, [int]$LiveRules, [int]$PolicyOrphans, [int]$LivePolicies, [double]$Max = 0.5, [switch]$Allow, [string]$Direction = 'portal-wins')
            $PruneMissing = [switch]$true
            $DirectionPolicy = $Direction
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $ruleOrphanPlan = @(for ($i = 0; $i -lt $RuleOrphans; $i++) { [pscustomobject]@{ Key = "orphan-rule-$i" } })
            $policyPlan = @(
                @(for ($i = 0; $i -lt $PolicyOrphans; $i++) { [pscustomobject]@{ Name = "orphan-policy-$i"; Action = 'Orphan' } }) +
                @([pscustomobject]@{ Name = 'kept-policy'; Action = 'NoChange' })
            )
            $tenantRules    = @(for ($i = 0; $i -lt $LiveRules; $i++) { [pscustomobject]@{ Name = "live-rule-$i" } })
            $tenantPolicies = @(for ($i = 0; $i -lt $LivePolicies; $i++) { [pscustomobject]@{ Name = "live-policy-$i" } })
            $null = $PruneMissing, $DirectionPolicy, $MaxPruneRatio, $AllowMajorityPrune, $ruleOrphanPlan, $policyPlan, $tenantRules, $tenantPolicies
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes when both tiers sit at or below the threshold' {
        { Invoke-Guard2 -RuleOrphans 2 -LiveRules 10 -PolicyOrphans 1 -LivePolicies 4 } | Should -Not -Throw
    }
    It 'throws when the RULE tier exceeds the threshold even though the blended ratio would pass (the per-tier point)' {
        # 4 of 4 rules pruned but 0 of 16 policies: blended 20%, rules tier 100%.
        { Invoke-Guard2 -RuleOrphans 4 -LiveRules 4 -PolicyOrphans 0 -LivePolicies 16 } | Should -Throw
    }
    It 'throws when the POLICY tier exceeds the threshold' {
        { Invoke-Guard2 -RuleOrphans 0 -LiveRules 16 -PolicyOrphans 4 -LivePolicies 4 } | Should -Throw
    }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' {
        { Invoke-Guard2 -RuleOrphans 4 -LiveRules 4 -PolicyOrphans 4 -LivePolicies 4 -Allow } | Should -Not -Throw
    }
    It 'does NOT fire under -DirectionPolicy audit even above the threshold (audit trap)' {
        { Invoke-Guard2 -RuleOrphans 4 -LiveRules 4 -PolicyOrphans 4 -LivePolicies 4 -Direction 'audit' } | Should -Not -Throw
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 4)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-DLPPolicies.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-DLPPolicies.ps1; update the anchor in this test.' }
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
            param([string[]]$RuleKeys = @(), [string[]]$PolicyNames = @(), [string[]]$Fail = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Remove-DlpComplianceRule {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add("rule:$Identity")
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Remove-DlpCompliancePolicy {
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity)
                $attempted.Add("policy:$Identity")
                if ($Fail -contains $Identity) { throw "TenantBlockerException: $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $ruleOrphanPlan = @($RuleKeys | ForEach-Object { [pscustomobject]@{ Key = $_; Reason = 'test' } })
            $policyPlan = @($PolicyNames | ForEach-Object { [pscustomobject]@{ Name = $_; Action = 'Orphan'; Reason = 'test' } })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $ruleOrphanPlan, $policyPlan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every orphan in both tiers after a failure, rules before policies' {
        $r = Invoke-PruneRegion -RuleKeys @('r1', 'r2') -PolicyNames @('p1') -Fail @('r1')
        $r.Attempted | Should -Be @('rule:r1', 'rule:r2', 'policy:p1')
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -RuleKeys @('r1') -PolicyNames @('p1') -Fail @('p1')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException: p1'
    }
    It 'throws one aggregate naming every failure across both tiers (exit-0 defect fixed)' {
        $r = Invoke-PruneRegion -RuleKeys @('r1', 'r2') -PolicyNames @('p1') -Fail @('r2', 'p1')
        $r.Thrown | Should -Match "rule 'r2'"
        $r.Thrown | Should -Match "policy 'p1'"
        $r.Thrown | Should -Match '2 orphan DLP object'
    }
    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -RuleKeys @('r1') -PolicyNames @('p1')
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

Describe 'AdvancedRule widened predicate vocabulary (#80, ADR 0031 amendment)' {

    BeforeAll {
        $script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json'
        $script:Schema     = Get-Content -LiteralPath $script:SchemaPath -Raw

        # Synthetic identifiers only (ADR 0055 rule 1 reserved namespace).
        $script:SitA   = '00000000-0000-0000-0000-000000000801'
        $script:SitB   = '00000000-0000-0000-0000-000000000802'
        $script:LblInt = '00000000-0000-0000-0000-000000000811'
        $script:LblCnf = '00000000-0000-0000-0000-000000000812'
        $script:LabelNames = @{
            $script:LblInt = 'Internal'
            $script:LblCnf = 'Confidential'
        }
        $script:LabelGuids = @{
            'Internal'     = $script:LblInt
            'Confidential' = $script:LblCnf
        }

        # Shape of the lab "Protect sensitive M365 Copilot interactions" rule:
        # Condition.Operator=And over [HasActivity, nested Or [content]].
        $script:NestedWire = @"
{
  "Version": "1.0",
  "Condition": {
    "Operator": "And",
    "SubConditions": [
      { "ConditionName": "HasActivity", "Value": "UploadText" },
      {
        "Operator": "Or",
        "SubConditions": [
          {
            "ConditionName": "ContentContainsSensitiveInformation",
            "Value": [
              {
                "Groups": [
                  {
                    "Name": "Default",
                    "Operator": "Or",
                    "Sensitivetypes": [
                      { "Name": "Synthetic SIT A", "Id": "$($script:SitA)", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "Medium", "Minconfidence": 75, "Maxconfidence": 100 }
                    ]
                  }
                ],
                "Operator": "And"
              }
            ]
          }
        ]
      }
    ]
  }
}
"@

        # Shape of the lab "DSPM for AI" rule: Condition.Operator=Or over
        # [content-with-labels, FromScope].
        $script:LabelWire = @"
{
  "Version": "1.0",
  "Condition": {
    "Operator": "Or",
    "SubConditions": [
      {
        "ConditionName": "ContentContainsSensitiveInformation",
        "Value": [
          {
            "Groups": [
              {
                "Name": "Default",
                "Operator": "Or",
                "Labels": [
                  { "Name": "$($script:LblInt)", "Id": "$($script:LblInt)", "Type": "Sensitivity" },
                  { "Name": "Confidential", "Id": "$($script:LblCnf)", "Type": "Sensitivity" }
                ]
              }
            ],
            "Operator": "And"
          }
        ]
      },
      { "ConditionName": "FromScope", "Value": "NotInOrganization" }
    ]
  }
}
"@
    }

    Context 'ConvertFrom-AdvancedRuleWire models the full observed vocabulary' {

        It 'captures Condition.Operator=Or, which the pre-#80 parser asserted away' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $r.Recognized              | Should -BeTrue
            $r.Normalized.operator     | Should -Be 'Or'
            @($r.Normalized.conditions).Count | Should -Be 2
        }

        It 'keeps Condition.Operator distinct from the deeper Value[].Operator (outerOperator)' {
            # The captured body has Condition.Operator=Or and Value[0].Operator=And.
            # Conflating them is the exact defect that made `Or` rules unmodelable.
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $r.Normalized.operator                    | Should -Be 'Or'
            $r.Normalized.conditions[0].outerOperator | Should -Be 'And'
        }

        It 'walks nested SubConditions into a nested condition group' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:NestedWire
            $r.Recognized                                  | Should -BeTrue
            $r.Normalized.operator                         | Should -Be 'And'
            $r.Normalized.conditions[0].type               | Should -Be 'HasActivity'
            $r.Normalized.conditions[0].value              | Should -Be 'UploadText'
            $r.Normalized.conditions[1].operator           | Should -Be 'Or'
            $r.Normalized.conditions[1].conditions[0].type | Should -Be 'ContentContainsSensitiveInformation'
            $r.Normalized.conditions[1].conditions[0].groups[0].sensitiveInfoTypes[0].guid | Should -Be $script:SitA
        }

        It 'models each scalar predicate type observed on the tenants' -ForEach @(
            @{ CName = 'AccessScope';      CValue = 'NotInOrganization' }
            @{ CName = 'FromScope';        CValue = 'NotInOrganization' }
            @{ CName = 'HasActivity';      CValue = 'UploadText' }
            @{ CName = 'DocumentSizeOver'; CValue = '1 B' }
        ) {
            $wire = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"' + $CName + '","Value":"' + $CValue + '"}]}}'
            $r = ConvertFrom-AdvancedRuleWire -Wire $wire
            $r.Recognized                     | Should -BeTrue
            $r.Normalized.conditions[0].type  | Should -Be $CName
            $r.Normalized.conditions[0].value | Should -Be $CValue
        }

        It 'still refuses a predicate outside the modeled vocabulary (degrades to evidence, never widens silently)' {
            $wire = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"DocumentIsPasswordProtected","Value":"true"}]}}'
            $r = ConvertFrom-AdvancedRuleWire -Wire $wire
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'DocumentIsPasswordProtected'
        }

        It 'refuses a scalar predicate whose Value is an array rather than a scalar' {
            $wire = '{"Version":"1.0","Condition":{"Operator":"And","SubConditions":[{"ConditionName":"HasActivity","Value":["UploadText","Print"]}]}}'
            $r = ConvertFrom-AdvancedRuleWire -Wire $wire
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'non-scalar'
        }
    }

    Context 'Sensitivity labels are modeled by display name (ADR 0023)' {

        It 'resolves Labels[].Id to a display name and never surfaces the GUID' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $r.Recognized | Should -BeTrue
            $labels = $r.Normalized.conditions[0].groups[0].sensitivityLabels
            @($labels).Count          | Should -Be 2
            $labels[0].displayName    | Should -Be 'Internal'
            $labels[1].displayName    | Should -Be 'Confidential'
            # Wire Name was the raw GUID on the first entry; the model must not carry it.
            ($r.Normalized | ConvertTo-Json -Depth 20) | Should -Not -Match $script:LblInt
        }

        It 'FAILS the parse when a label cannot be resolved, rather than writing a raw tenant GUID' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap @{}
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'display name'
        }

        It 'never quotes a GUID in the failure reason (the reason is written into policies.yaml as notes:)' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap @{}
            $r.Reason | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        }

        It 'refuses a label whose Type is not Sensitivity' {
            $wire = $script:LabelWire -replace '"Type": "Sensitivity"', '"Type": "Retention"'
            $r = ConvertFrom-AdvancedRuleWire -Wire $wire -LabelNameMap $script:LabelNames
            $r.Recognized | Should -BeFalse
            $r.Reason     | Should -Match 'Type='
        }

        It 'resolves display names back to this tenant''s own GUIDs on the write path' {
            $r    = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $wire = ConvertTo-AdvancedRuleWire -AdvancedRule $r.Normalized -LabelGuidMap $script:LabelGuids | ConvertFrom-Json
            $emitted = $wire.Condition.SubConditions[0].Value[0].Groups[0].Labels
            @($emitted).Count   | Should -Be 2
            $emitted[0].Id      | Should -Be $script:LblInt
            # Name carries the GUID, NOT the display name. The service resolves this entry
            # by Name and rejects a human-readable display name -- "The label name
            # '<x>' ... does not exist" -- because a label's Name is not its DisplayName
            # (#93). This assertion previously pinned 'Internal' and so pinned the bug.
            $emitted[0].Name    | Should -Be $script:LblInt
            $emitted[0].Type    | Should -Be 'Sensitivity'
        }

        It 'throws when a referenced label display name is absent from the tenant map' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            { ConvertTo-AdvancedRuleWire -AdvancedRule $r.Normalized -LabelGuidMap @{} } |
                Should -Throw -ExpectedMessage '*was not found via Get-Label*'
        }

        It 'omits Sensitivetypes entirely on a labels-only group (an empty array is a different document)' {
            $r    = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $wire = ConvertTo-AdvancedRuleWire -AdvancedRule $r.Normalized -LabelGuidMap $script:LabelGuids | ConvertFrom-Json
            $group = $wire.Condition.SubConditions[0].Value[0].Groups[0]
            $group.PSObject.Properties.Name | Should -Not -Contain 'Sensitivetypes'
        }
    }

    Context 'Round-trip and anti-phantom-drift' {

        It 'wire -> YAML -> wire is stable under the canonical hash for the nested tree' {
            $r1 = ConvertFrom-AdvancedRuleWire -Wire $script:NestedWire
            $w  = ConvertTo-AdvancedRuleWire   -AdvancedRule $r1.Normalized
            $r2 = ConvertFrom-AdvancedRuleWire -Wire $w
            $r2.Recognized | Should -BeTrue
            (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r2.Normalized) |
                Should -Be (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r1.Normalized)
        }

        It 'wire -> YAML -> wire is stable for the label-bearing Or-rooted tree' {
            $r1 = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $w  = ConvertTo-AdvancedRuleWire   -AdvancedRule $r1.Normalized -LabelGuidMap $script:LabelGuids
            $r2 = ConvertFrom-AdvancedRuleWire -Wire $w -LabelNameMap $script:LabelNames
            $r2.Recognized | Should -BeTrue
            (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r2.Normalized) |
                Should -Be (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r1.Normalized)
        }

        It 'canonicalises every widened field: a tenant tree and the identical desired tree diff to nothing' {
            # The phantom-drift guard. A field the comparator does not canonicalise
            # produces an advancedRule diff on EVERY reconcile that no apply can settle.
            $tenantParse = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{
                name         = 'r'
                advancedRule = $tenantParse.Normalized
            }
            $tenant = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @()
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @()
                advancedRule = $tenantParse.Normalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant).Count | Should -Be 0
        }

        It 'flags drift when only the root operator changes (And vs Or)' {
            $tenantParse = ConvertFrom-AdvancedRuleWire -Wire $script:LabelWire -LabelNameMap $script:LabelNames
            $drifted = ConvertTo-NormalizedAdvancedRule -Source $tenantParse.Normalized
            $drifted['operator'] = 'And'
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; advancedRule = $drifted }
            $tenant = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @()
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @()
                advancedRule = $tenantParse.Normalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'advancedRule'
        }

        It 'flags drift when only a scalar predicate value changes' {
            $base = ConvertFrom-AdvancedRuleWire -Wire $script:NestedWire
            $drift = ConvertFrom-AdvancedRuleWire -Wire ($script:NestedWire -replace 'UploadText', 'Print')
            $desired = ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; advancedRule = $drift.Normalized }
            $tenant = @{
                name = 'r'; sensitiveInfoTypes = @(); sensitivityLabels = @()
                notifyUser = @(); generateIncidentReport = @(); generateAlert = @()
                advancedRule = $base.Normalized
            }
            (Compare-DlpRule -Desired $desired -Tenant $tenant) | Should -Contain 'advancedRule'
        }
    }

    Context 'Legacy { outerOperator, groups } sugar stays first-class' {

        It 'up-converts the legacy shape to the equivalent single-condition tree' {
            $n = ConvertTo-NormalizedAdvancedRule -Source @{
                outerOperator = 'And'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = $script:SitA }) })
            }
            $n.operator                    | Should -Be 'And'
            @($n.conditions).Count         | Should -Be 1
            $n.conditions[0].type          | Should -Be 'ContentContainsSensitiveInformation'
            $n.conditions[0].outerOperator | Should -Be 'And'
        }

        It 'compares equal to the tree form of the same predicate (no forced migration)' {
            $sugar = ConvertTo-NormalizedAdvancedRule -Source @{
                outerOperator = 'Or'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = $script:SitA }) })
            }
            $tree = ConvertTo-NormalizedAdvancedRule -Source @{
                operator = 'And'
                conditions = @(@{
                        type = 'ContentContainsSensitiveInformation'
                        outerOperator = 'Or'
                        groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = $script:SitA }) })
                    })
            }
            (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $sugar) |
                Should -Be (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $tree)
        }

        It 'exports back as sugar when the tree allows it (zero YAML churn on already-clean rules)' {
            $n = ConvertTo-NormalizedAdvancedRule -Source @{
                outerOperator = 'And'
                groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = $script:SitA }) })
            }
            $e = ConvertTo-ExportedAdvancedRule -AdvancedRule $n
            $e.Contains('outerOperator') | Should -BeTrue
            $e.Contains('conditions')    | Should -BeFalse
            $e.outerOperator             | Should -Be 'And'
        }

        It 'exports as a tree when the predicate cannot be expressed as sugar' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:NestedWire
            $e = ConvertTo-ExportedAdvancedRule -AdvancedRule $r.Normalized
            $e.Contains('conditions')    | Should -BeTrue
            $e.Contains('outerOperator') | Should -BeFalse
        }

        It 'export rendering is semantics-preserving in both directions' {
            $r = ConvertFrom-AdvancedRuleWire -Wire $script:NestedWire
            $e = ConvertTo-ExportedAdvancedRule -AdvancedRule $r.Normalized
            (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule (ConvertTo-NormalizedAdvancedRule -Source $e)) |
                Should -Be (ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $r.Normalized)
        }
    }

    Context 'ConvertTo-SensitivityLabelNameMap inverts the Get-Label map' {

        It 'maps GUID -> displayName with lower-cased keys' {
            $inv = ConvertTo-SensitivityLabelNameMap -LabelGuidMap @{ 'Internal' = $script:LblInt.ToUpperInvariant() }
            $inv[$script:LblInt] | Should -Be 'Internal'
        }

        It 'returns an empty map for an empty input (Get-Label unavailable)' {
            (ConvertTo-SensitivityLabelNameMap -LabelGuidMap @{}).Count | Should -Be 0
        }
    }

    Context 'Hollow-policy create guard shares one notes-only definition' {

        It 'treats a notes-only rule as unmodeled' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r'; notes = 'not modeled' }) |
                Should -BeTrue
        }

        It 'treats a rule with sensitiveInfoTypes as modeled even when it also carries notes' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{
                    name = 'r'; notes = 'x'; sensitiveInfoTypes = @(@{ guid = $script:SitA })
                }) | Should -BeFalse
        }

        It 'treats a rule with an advancedRule as modeled' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{
                    name = 'r'; notes = 'x'
                    advancedRule = @{ outerOperator = 'And'; groups = @(@{ name = 'g'; operator = 'Or'; sensitiveInfoTypes = @(@{ guid = $script:SitB }) }) }
                }) | Should -BeFalse
        }

        It 'treats a rule with sensitivityLabels as modeled' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{
                    name = 'r'; notes = 'x'; sensitivityLabels = @(@{ displayName = 'Internal' })
                }) | Should -BeFalse
        }

        It 'treats a rule with no notes marker as NOT a notes-only pass-through' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{ name = 'r' }) | Should -BeFalse
        }

        It 'a rawAdvancedRule evidence rule is still notes-only (the shape the guard must catch)' {
            Test-DlpRuleIsNotesOnly -Rule (ConvertTo-DesiredDlpRuleHash -Entry @{
                    name = 'r'; notes = 'wire shape not yet modeled'
                    rawAdvancedRule = '{"Version":"1.0"}'
                }) | Should -BeTrue
        }
    }

    Context 'Schema accepts the widened shape and still rejects nonsense' {

        It 'accepts the tree form with a nested group and a scalar predicate' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"And","conditions":[{"type":"HasActivity","value":"UploadText"},{"operator":"Or","conditions":[{"type":"ContentContainsSensitiveInformation","outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitiveInfoTypes":[{"guid":"' + $script:SitA + '"}]}]}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'accepts a content group that carries sensitivityLabels by display name' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"Or","conditions":[{"type":"ContentContainsSensitiveInformation","outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitivityLabels":[{"displayName":"Internal"}]}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'still accepts the legacy flat form unchanged (no forced migration)' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitiveInfoTypes":[{"guid":"' + $script:SitA + '"}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Not -Throw
        }

        It 'rejects a scalar predicate type outside the modeled enum' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"And","conditions":[{"type":"DocumentIsPasswordProtected","value":"true"}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'rejects a tree that mixes the two authored forms' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"And","outerOperator":"And","conditions":[{"type":"HasActivity","value":"UploadText"}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'rejects a sensitivity label referenced by raw GUID key instead of displayName' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"And","conditions":[{"type":"ContentContainsSensitiveInformation","outerOperator":"And","groups":[{"name":"g","operator":"Or","sensitivityLabels":[{"guid":"' + $script:LblInt + '"}]}]}]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }

        It 'rejects an empty conditions list' {
            $doc = '{"policies":[{"name":"x","mode":"Enable","rules":[{"name":"r","advancedRule":{"operator":"And","conditions":[]}}]}]}'
            { $doc | Test-Json -Schema $script:Schema -ErrorAction Stop } | Should -Throw
        }
    }
}

Describe 'Desired-state schema validation serializes deeply enough for the modelled shape (#80)' {

    BeforeAll {
        $script:ScriptPathForDepth = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-DLPPolicies.ps1'
        $script:SchemaForDepth     = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'data-plane' 'dlp' 'policies.schema.json') -Raw

        # The DEEPEST shape the model can express, as a desired-state document:
        # policies > [] > rules > [] > advancedRule > conditions > [] >
        # conditions > [] > groups > [] > sensitiveInfoTypes > [] > guid.
        # This is the real lab "Protect sensitive M365 Copilot interactions" shape
        # (a nested condition group wrapping a content predicate).
        $script:DeepestDoc = @{
            policies = @(
                @{
                    name  = 'P-deep'
                    mode  = 'Enable'
                    rules = @(
                        @{
                            name         = 'R-deep'
                            advancedRule = @{
                                operator   = 'And'
                                conditions = @(
                                    @{ type = 'HasActivity'; value = 'UploadText' }
                                    @{
                                        operator   = 'Or'
                                        conditions = @(
                                            @{
                                                type          = 'ContentContainsSensitiveInformation'
                                                outerOperator = 'And'
                                                groups        = @(
                                                    @{
                                                        name               = 'Default'
                                                        operator           = 'Or'
                                                        sensitiveInfoTypes = @(
                                                            @{ guid = '00000000-0000-0000-0000-000000000801'; minCount = 1; maxCount = -1 }
                                                        )
                                                    }
                                                )
                                            }
                                        )
                                    }
                                )
                            }
                        }
                    )
                }
            )
        }
    }

    It 'reads the serialization depth from the script itself, not from a copy in this test' {
        # A test that hard-codes its own depth cannot catch this defect -- which is
        # exactly how it escaped: every schema test here serialized at a generous
        # depth of its own choosing while the script shipped -Depth 10.
        $src = Get-Content -LiteralPath $script:ScriptPathForDepth -Raw
        $m = [regex]::Match($src, '\$docJson\s*=\s*\$desiredRoot\s*\|\s*ConvertTo-Json\s+-Depth\s+(?<d>\d+)')
        $m.Success | Should -BeTrue -Because 'the desired-state validation site must stay greppable for this regression test'
        $script:ValidationDepth = [int]$m.Groups['d'].Value
        $script:ValidationDepth | Should -BeGreaterThan 0
    }

    It 'serializes the deepest modelled shape WITHOUT truncating at that depth' {
        # ConvertTo-Json warns and rewrites deeper nodes as strings when it hits the
        # depth cap; the resulting document then fails schema validation with an
        # error pointing at an unrelated shallow field. Found live on dev, where a
        # valid file was rejected for `locations/powerBI`.
        $src = Get-Content -LiteralPath $script:ScriptPathForDepth -Raw
        $depth = [int][regex]::Match($src, '\$docJson\s*=\s*\$desiredRoot\s*\|\s*ConvertTo-Json\s+-Depth\s+(?<d>\d+)').Groups['d'].Value

        $warnings = @()
        $null = $script:DeepestDoc | ConvertTo-Json -Depth $depth -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -BeNullOrEmpty -Because 'a truncation warning means the validation site would reject a valid document'
    }

    It 'validates the deepest modelled shape against the schema at that depth' {
        $src = Get-Content -LiteralPath $script:ScriptPathForDepth -Raw
        $depth = [int][regex]::Match($src, '\$docJson\s*=\s*\$desiredRoot\s*\|\s*ConvertTo-Json\s+-Depth\s+(?<d>\d+)').Groups['d'].Value

        $json = $script:DeepestDoc | ConvertTo-Json -Depth $depth
        { $json | Test-Json -Schema $script:SchemaForDepth -ErrorAction Stop } | Should -Not -Throw
    }

    It 'demonstrates the defect: the same document at the old -Depth 10 does NOT survive' {
        # Mutation check -- proves the three assertions above are non-vacuous.
        $warnings = @()
        $null = $script:DeepestDoc | ConvertTo-Json -Depth 10 -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings | Should -Not -BeNullOrEmpty
    }
}

Describe 'Prune-ratio guard call avoids the PS 7.6 List[object] @() array-wrap crash (#110)' {
    <#
        Found live at first -PruneMissing contact against a real tenant: PowerShell 7.6.x
        throws "Argument types do not match" when @() directly wraps a
        System.Collections.Generic.List[object] VARIABLE REFERENCE (as opposed to a pipeline
        result), independent of element count -- reproduced crashing at 0, 1, and 2 elements
        alike. $ruleOrphanPlan is exactly this shape (built via New-Object + .Add()). The fix
        drops the unnecessary @() wrap in favor of List<T>'s own .Count property, which carries
        none of the pipeline single-result-unwrapping hazard @(...) normally guards against --
        that hazard is a property of PIPELINE output, not of a pre-built List<T>.

        This suite does not try to reproduce the PS-7.6-specific crash directly (that would make
        the test fragile across different PowerShell versions in CI); instead it (a) source-reads
        the fixed call site to pin the exact pattern, and (b) proves the guard's actual behavior
        -- refuse an oversized prune, allow a sane one -- survives unchanged at 0/1/many elements,
        so the fix could not have silently defanged the ratio guard it touches.
    #>

    BeforeAll {
        $script:ScriptPathForPruneCount = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-DLPPolicies.ps1'
        Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'PruneGuard.psm1') -Force
    }

    It 'the ruleOrphanPlan prune-count argument reads .Count directly, not @(...).Count' {
        $src = Get-Content -LiteralPath $script:ScriptPathForPruneCount -Raw
        $src | Should -Not -Match '@\(\$ruleOrphanPlan\)\.Count' -Because 'wrapping a List[object] variable in @() crashes on PowerShell 7.6.x (issue #110)'
        $src | Should -Match '-PruneCount\s+\$ruleOrphanPlan\.Count'
    }

    It 'passing a real List[object].Count through the guard at 0, 1, and many elements does not throw' {
        foreach ($n in 0, 1, 5) {
            $list = New-Object 'System.Collections.Generic.List[object]'
            for ($i = 0; $i -lt $n; $i++) { $list.Add([pscustomobject]@{ Action = 'Orphan' }) }
            { Assert-PruneRatioWithinThreshold -PruneCount $list.Count -LiveCount 100 -ObjectTypeNoun 'DLP rule' -MaxPruneRatio 0.75 -Allow:$false } |
                Should -Not -Throw -Because "a List[object] with $n elements must not crash the guard call (issue #110)"
        }
    }

    It 'the guard still refuses a genuinely oversized prune (non-vacuous: the fix did not defang it)' {
        $list = New-Object 'System.Collections.Generic.List[object]'
        1..90 | ForEach-Object { $list.Add([pscustomobject]@{ Action = 'Orphan' }) }
        { Assert-PruneRatioWithinThreshold -PruneCount $list.Count -LiveCount 100 -ObjectTypeNoun 'DLP rule' -MaxPruneRatio 0.75 -Allow:$false } |
            Should -Throw -Because '90 of 100 (90%) exceeds the 75% threshold and must still be refused'
    }
}
