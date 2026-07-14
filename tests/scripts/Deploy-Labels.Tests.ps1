#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for issue #215 - autoApplicationOf translation
    via Set-Label -Conditions sink in scripts/Deploy-Labels.ps1.

.DESCRIPTION
    Locks in the issue #215 acceptance criteria:

      1. ConvertTo-TenantLabelHash parses $Label.Conditions JSON and
         lifts autoapplytype -> mode and policytip -> policyTip plus
         the SIT array with mincount / minconfidence.
      2. Compare-LabelHash produces autoApplicationOf.mode and
         autoApplicationOf.policyTip diffs when those fields differ.
      3. Compare-LabelHash does NOT diff policyTip when desired YAML
         omits it (the #157 "omit means preserve" convention).
      4. Merge-LabelConditionsJson preserves server-managed Settings
         keys (name, rulepackage, groupname, confidencelevel,
         maxcount, maxconfidence) verbatim.
      5. Merge-LabelConditionsJson overwrites the four schema-owned
         keys (mincount, minconfidence, autoapplytype, policytip).
      6. Merge-LabelConditionsJson returns $null when the tenant
         label has no existing Conditions (deferred Create-path).

    Pattern: AST-extract the three target functions and evaluate them
    into the test scope so the top-level script body (which loads
    ExchangeOnlineManagement and connects to a tenant) never runs.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    Reference: https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Labels.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-Labels.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fname in @('ConvertTo-LabelHash', 'ConvertTo-TenantLabelHash', 'ConvertTo-LabelCmdletArgument', 'Compare-LabelHash', 'Merge-LabelConditionsJson', 'Resolve-AutoApplyRemovalPlan', 'Get-NeedsPortalActionSummary')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Import the in-repo ADR 0029 direction-policy module so the
    # `Describe 'Apply-path direction policy branches'` and
    # `Describe 'SkipNames behavior'` blocks can call
    # `Resolve-DirectionPolicyAction` directly. Extracted to a shared
    # module in #473 so the helper no longer lives inside Deploy-Labels.ps1.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
        -Force -ErrorAction Stop

    # Stub script-scoped dependencies read by ConvertTo-TenantLabelHash
    # and Compare-LabelHash (only the names referenced; values that match
    # the production constants so equality logic is honest).
    $script:TrackedScalarFields    = @('tooltip','comment')
    $script:RedactedIdentityPattern = '(?i)@(contoso|fabrikam|adatum)\.com$|@example\.(com|org)$'

    # A minimal fake Get-Label result carrying just enough scalar fields
    # for ConvertTo-TenantLabelHash to run; auto-apply lives entirely in
    # Conditions so the other fields can be empty.
    $script:MakeFakeLabel = {
        param([string]$Conditions)
        [pscustomobject]@{
            DisplayName            = 'Confidential\Internal'
            Guid                   = '00000000-0000-0000-0000-000000000000'
            ParentId               = $null
            Tooltip                = ''
            Comment                = ''
            ContentType            = ''
            ApplyContentMarkingHeaderEnabled = $false
            ApplyContentMarkingFooterEnabled = $false
            ApplyWaterMarkingEnabled         = $false
            EncryptionEnabled                = $false
            Conditions             = $Conditions
        }
    }
}

Describe 'ConvertTo-TenantLabelHash autoApplicationOf parser (issue #215)' {

    It 'parses mode, policyTip, and SIT array from Conditions JSON' {
        $cond = '{"And":[{"Or":[{"Key":"CCSI","Value":"50842eb7-edc8-4019-85dd-5a5c1f2bb085","Properties":null,"Settings":[{"Key":"mincount","Value":"1"},{"Key":"minconfidence","Value":"85"},{"Key":"groupname","Value":"Default"},{"Key":"rulepackage","Value":"00000000-0000-0000-0000-000000000000"},{"Key":"name","Value":"Credit Card Number"},{"Key":"policytip","Value":"Confidential content"},{"Key":"confidencelevel","Value":"High"},{"Key":"autoapplytype","Value":"Recommend"}]}]}]}'
        $label = & $script:MakeFakeLabel $cond
        $hash = ConvertTo-TenantLabelHash -Label $label
        $hash.autoApplicationOf | Should -Not -BeNullOrEmpty
        $hash.autoApplicationOf.mode | Should -Be 'Recommend'
        $hash.autoApplicationOf.policyTip | Should -Be 'Confidential content'
        $hash.autoApplicationOf.sensitiveInformationTypes.Count | Should -Be 1
        $hash.autoApplicationOf.sensitiveInformationTypes[0].sitId | Should -Be '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
        $hash.autoApplicationOf.sensitiveInformationTypes[0].minCount | Should -Be 1
        $hash.autoApplicationOf.sensitiveInformationTypes[0].minConfidence | Should -Be 85
    }

    It 'returns null autoApplicationOf when Conditions is empty' {
        $label = & $script:MakeFakeLabel ''
        $hash = ConvertTo-TenantLabelHash -Label $label
        $hash.autoApplicationOf | Should -BeNullOrEmpty
    }

    It 'returns null autoApplicationOf when Conditions JSON is malformed' {
        $label = & $script:MakeFakeLabel 'not valid json'
        $hash = ConvertTo-TenantLabelHash -Label $label
        $hash.autoApplicationOf | Should -BeNullOrEmpty
    }

    It 'parses Automatic mode' {
        $cond = '{"And":[{"Or":[{"Key":"CCSI","Value":"abc-123","Settings":[{"Key":"mincount","Value":"5"},{"Key":"minconfidence","Value":"75"},{"Key":"autoapplytype","Value":"Automatic"}]}]}]}'
        $label = & $script:MakeFakeLabel $cond
        $hash = ConvertTo-TenantLabelHash -Label $label
        $hash.autoApplicationOf.mode | Should -Be 'Automatic'
        $hash.autoApplicationOf.policyTip | Should -BeNullOrEmpty
        $hash.autoApplicationOf.sensitiveInformationTypes[0].minCount | Should -Be 5
    }
}

Describe 'Compare-LabelHash autoApplicationOf diff (issue #215)' {

    BeforeAll {
        $script:MakeHash = {
            param($mode, $policyTip, $sits)
            $base = @{
                displayName = 'Test'; tooltip = ''; comment = ''
                contentType = @(); encryption = $null
                marking_header = $null; marking_footer = $null; marking_watermark = $null
                autoApplicationOf = $null
            }
            if ($mode -or $sits) {
                $base.autoApplicationOf = @{
                    mode      = $mode
                    policyTip = $policyTip
                    sensitiveInformationTypes = @($sits)
                }
            }
            return $base
        }
        $script:Sit = [pscustomobject]@{ sitId = 'abc'; minCount = 1; minConfidence = 75 }
    }

    It 'produces autoApplicationOf.mode diff when mode differs' {
        $d = & $script:MakeHash 'Automatic' 'Tip text' @($script:Sit)
        $t = & $script:MakeHash 'Recommend' 'Tip text' @($script:Sit)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'autoApplicationOf.mode'
        $diffs | Should -Not -Contain 'autoApplicationOf.policyTip'
        $diffs | Should -Not -Contain 'autoApplicationOf.sensitiveInformationTypes'
    }

    It 'produces autoApplicationOf.policyTip diff when policyTip differs' {
        $d = & $script:MakeHash 'Recommend' 'New tip' @($script:Sit)
        $t = & $script:MakeHash 'Recommend' 'Old tip' @($script:Sit)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'autoApplicationOf.policyTip'
        $diffs | Should -Not -Contain 'autoApplicationOf.mode'
    }

    It 'omits policyTip from diff when desired YAML omits it (#157 convention)' {
        $d = & $script:MakeHash 'Recommend' $null @($script:Sit)
        $t = & $script:MakeHash 'Recommend' 'Tenant tip' @($script:Sit)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        $diffs | Should -Not -Contain 'autoApplicationOf.policyTip'
    }

    It 'produces no autoApplicationOf diffs when everything matches' {
        $d = & $script:MakeHash 'Recommend' 'Same tip' @($script:Sit)
        $t = & $script:MakeHash 'Recommend' 'Same tip' @($script:Sit)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        ($diffs | Where-Object { $_ -like 'autoApplicationOf*' }).Count | Should -Be 0
    }
}

Describe 'Merge-LabelConditionsJson (issue #215)' {

    BeforeAll {
        $script:CurrentConditions = '{"And":[{"Or":[{"Key":"CCSI","Value":"50842eb7-edc8-4019-85dd-5a5c1f2bb085","Properties":null,"Settings":[{"Key":"mincount","Value":"1"},{"Key":"maxconfidence","Value":"100"},{"Key":"groupname","Value":"Default"},{"Key":"rulepackage","Value":"00000000-0000-0000-0000-000000000000"},{"Key":"name","Value":"Credit Card Number"},{"Key":"minconfidence","Value":"85"},{"Key":"policytip","Value":"Old tip"},{"Key":"maxcount","Value":"75"},{"Key":"confidencelevel","Value":"High"},{"Key":"autoapplytype","Value":"Recommend"}]}]}]}'
    }

    It 'preserves all server-managed Settings keys and overwrites schema-owned keys' {
        $desired = @{
            mode      = 'Automatic'
            policyTip = 'New tip'
            sensitiveInformationTypes = @(
                [pscustomobject]@{ sitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; minCount = 3; minConfidence = 90 }
            )
        }
        $result = Merge-LabelConditionsJson `
            -CurrentConditions $script:CurrentConditions `
            -DesiredAutoApply  $desired `
            -LabelDisplayName  'Confidential\Internal'
        $result | Should -Not -BeNullOrEmpty
        $parsed = $result | ConvertFrom-Json -Depth 20
        $settings = $parsed.And[0].Or[0].Settings
        $kvp = @{}
        foreach ($s in $settings) { $kvp[[string]$s.Key] = [string]$s.Value }

        # Schema-owned: overwritten.
        $kvp['autoapplytype'] | Should -Be 'Automatic'
        $kvp['policytip'] | Should -Be 'New tip'
        $kvp['mincount'] | Should -Be '3'
        $kvp['minconfidence'] | Should -Be '90'

        # Server-managed: preserved verbatim.
        $kvp['name'] | Should -Be 'Credit Card Number'
        $kvp['rulepackage'] | Should -Be '00000000-0000-0000-0000-000000000000'
        $kvp['groupname'] | Should -Be 'Default'
        $kvp['confidencelevel'] | Should -Be 'High'
        $kvp['maxcount'] | Should -Be '75'
        $kvp['maxconfidence'] | Should -Be '100'
    }

    It 'drops policytip key when desired omits policyTip' {
        $desired = @{
            mode      = 'Recommend'
            policyTip = $null
            sensitiveInformationTypes = @(
                [pscustomobject]@{ sitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; minCount = 1; minConfidence = 85 }
            )
        }
        $result = Merge-LabelConditionsJson `
            -CurrentConditions $script:CurrentConditions `
            -DesiredAutoApply  $desired `
            -LabelDisplayName  'Test'
        $parsed = $result | ConvertFrom-Json -Depth 20
        $settings = $parsed.And[0].Or[0].Settings
        ($settings | Where-Object { $_.Key -eq 'policytip' }) | Should -BeNullOrEmpty
    }

    It 'returns $null when tenant Conditions is empty' {
        $desired = @{
            mode      = 'Recommend'
            policyTip = 'Tip'
            sensitiveInformationTypes = @(
                [pscustomobject]@{ sitId = 'abc'; minCount = 1; minConfidence = 75 }
            )
        }
        $result = Merge-LabelConditionsJson `
            -CurrentConditions '' `
            -DesiredAutoApply  $desired `
            -LabelDisplayName  'Test' `
            -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
    }

    It 'skips desired SITs not present in tenant Conditions (no name source)' {
        $desired = @{
            mode      = 'Recommend'
            policyTip = 'Tip'
            sensitiveInformationTypes = @(
                [pscustomobject]@{ sitId = '50842eb7-edc8-4019-85dd-5a5c1f2bb085'; minCount = 1; minConfidence = 85 },
                [pscustomobject]@{ sitId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; minCount = 1; minConfidence = 75 }
            )
        }
        $result = Merge-LabelConditionsJson `
            -CurrentConditions $script:CurrentConditions `
            -DesiredAutoApply  $desired `
            -LabelDisplayName  'Test' `
            -WarningAction SilentlyContinue
        $parsed = $result | ConvertFrom-Json -Depth 20
        $parsed.And[0].Or.Count | Should -Be 1
        $parsed.And[0].Or[0].Value | Should -Be '50842eb7-edc8-4019-85dd-5a5c1f2bb085'
    }
}

Describe 'EncryptionPromptUser propagation (issue #420)' {

    BeforeAll {
        $script:MakeYamlEntry = {
            param([string]$ProtectionType)
            @{
                displayName = 'Confidential\Test'
                tooltip     = 'tip'
                contentType = @('Email','File')
                encryption  = @{
                    enabled                            = $true
                    protectionType                     = $ProtectionType
                    contentExpiredOnDateInDaysOrNever  = 'Never'
                    offlineAccessDays                  = 0
                    doNotForward                       = $true
                    encryptOnly                        = $false
                    rightsDefinitions                  = @()
                }
            }
        }

        $script:MakeFakeTenantLabelWithEncryption = {
            param([bool]$PromptUser)
            [pscustomobject]@{
                DisplayName                      = 'Confidential\Test'
                Guid                             = '00000000-0000-0000-0000-000000000000'
                ParentId                         = $null
                Tooltip                          = ''
                Comment                          = ''
                ContentType                      = 'Email,File'
                ApplyContentMarkingHeaderEnabled = $false
                ApplyContentMarkingFooterEnabled = $false
                ApplyWaterMarkingEnabled         = $false
                EncryptionEnabled                = $true
                EncryptionProtectionType         = 'UserDefined'
                EncryptionContentExpiredOnDateInDaysOrNever = 'Never'
                EncryptionOfflineAccessDays      = 0
                EncryptionDoNotForward           = $true
                EncryptionEncryptOnly            = $false
                EncryptionPromptUser             = $PromptUser
                EncryptionRightsDefinitions      = $null
                Conditions                       = ''
            }
        }
    }

    It 'ConvertTo-LabelHash derives promptUser=true from UserDefined' {
        $entry = & $script:MakeYamlEntry 'UserDefined'
        $h = ConvertTo-LabelHash -Entry $entry
        $h.encryption.promptUser | Should -BeTrue
    }

    It 'ConvertTo-LabelHash derives promptUser=false from Template' {
        $entry = & $script:MakeYamlEntry 'Template'
        $h = ConvertTo-LabelHash -Entry $entry
        $h.encryption.promptUser | Should -BeFalse
    }

    It 'ConvertTo-LabelHash derives promptUser=false from RemoveProtection' {
        $entry = & $script:MakeYamlEntry 'RemoveProtection'
        $h = ConvertTo-LabelHash -Entry $entry
        $h.encryption.promptUser | Should -BeFalse
    }

    It 'ConvertTo-TenantLabelHash reads EncryptionPromptUser from the tenant Label' {
        $label = & $script:MakeFakeTenantLabelWithEncryption $true
        $h = ConvertTo-TenantLabelHash -Label $label
        $h.encryption.promptUser | Should -BeTrue

        $label2 = & $script:MakeFakeTenantLabelWithEncryption $false
        $h2 = ConvertTo-TenantLabelHash -Label $label2
        $h2.encryption.promptUser | Should -BeFalse
    }

    It 'Compare-LabelHash reports encryption.promptUser drift' {
        $d = ConvertTo-LabelHash -Entry (& $script:MakeYamlEntry 'UserDefined')
        $t = ConvertTo-TenantLabelHash -Label (& $script:MakeFakeTenantLabelWithEncryption $false)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        $diffs | Should -Contain 'encryption.promptUser'
    }

    It 'Compare-LabelHash produces no promptUser diff when both sides agree' {
        $d = ConvertTo-LabelHash -Entry (& $script:MakeYamlEntry 'UserDefined')
        $t = ConvertTo-TenantLabelHash -Label (& $script:MakeFakeTenantLabelWithEncryption $true)
        $diffs = Compare-LabelHash -Desired $d -Tenant $t
        $diffs | Should -Not -Contain 'encryption.promptUser'
    }

    It 'ConvertTo-LabelCmdletArgument emits EncryptionPromptUser=$true for UserDefined' {
        $h = ConvertTo-LabelHash -Entry (& $script:MakeYamlEntry 'UserDefined')
        $splat = ConvertTo-LabelCmdletArgument -Desired $h
        $splat.ContainsKey('EncryptionPromptUser') | Should -BeTrue
        $splat['EncryptionPromptUser'] | Should -BeTrue
    }

    It 'ConvertTo-LabelCmdletArgument emits EncryptionPromptUser=$false for Template' {
        $h = ConvertTo-LabelHash -Entry (& $script:MakeYamlEntry 'Template')
        $splat = ConvertTo-LabelCmdletArgument -Desired $h
        $splat.ContainsKey('EncryptionPromptUser') | Should -BeTrue
        $splat['EncryptionPromptUser'] | Should -BeFalse
    }

    It 'ConvertTo-LabelCmdletArgument emits EncryptionPromptUser=$false for RemoveProtection' {
        $h = ConvertTo-LabelHash -Entry (& $script:MakeYamlEntry 'RemoveProtection')
        $splat = ConvertTo-LabelCmdletArgument -Desired $h
        $splat.ContainsKey('EncryptionPromptUser') | Should -BeTrue
        $splat['EncryptionPromptUser'] | Should -BeFalse
    }
}


Describe 'Resolve-AutoApplyRemovalPlan (issue #429, ADR 0027)' {

    BeforeAll {
        $script:HashWithAutoApply = @{
            displayName              = 'Confidential\Internal'
            tooltip                  = ''
            comment                  = ''
            contentType              = @()
            encryption               = $null
            marking_header           = $null
            marking_footer           = $null
            marking_watermark        = $null
            autoApplicationOf        = @{
                mode      = 'Recommend'
                policyTip = 'Tip'
                sensitiveInformationTypes = @(
                    [pscustomobject]@{ sitId = 'abc'; minCount = 1; minConfidence = 75 }
                )
            }
        }
        $script:HashWithoutAutoApply = @{
            displayName       = 'Confidential\Internal'
            tooltip           = ''
            comment           = ''
            contentType       = @()
            encryption        = $null
            marking_header    = $null
            marking_footer    = $null
            marking_watermark = $null
            autoApplicationOf = $null
        }
    }

    It 'flags the removal direction (desired null, tenant set) as NeedsPortalRemoval' {
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('autoApplicationOf') `
            -Desired $script:HashWithoutAutoApply `
            -Tenant  $script:HashWithAutoApply
        $result.NeedsPortalRemoval | Should -BeTrue
        $result.ApplyableDiffs | Should -BeNullOrEmpty
    }

    It 'leaves the add direction (desired set, tenant null) on the Update plan' {
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('autoApplicationOf') `
            -Desired $script:HashWithAutoApply `
            -Tenant  $script:HashWithoutAutoApply
        $result.NeedsPortalRemoval | Should -BeFalse
        $result.ApplyableDiffs | Should -Contain 'autoApplicationOf'
    }

    It 'does not strip autoApplicationOf when both sides have a block (sub-field diff)' {
        # When both desired and tenant carry an autoApplicationOf block,
        # Compare-LabelHash emits the dotted sub-field names (e.g.
        # autoApplicationOf.mode), never the bare field. The bare field is
        # only emitted on presence asymmetry. This test guards the contract.
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('autoApplicationOf.mode') `
            -Desired $script:HashWithAutoApply `
            -Tenant  $script:HashWithAutoApply
        $result.NeedsPortalRemoval | Should -BeFalse
        $result.ApplyableDiffs | Should -Contain 'autoApplicationOf.mode'
    }

    It 'preserves co-occurring tooltip / encryption diffs on the same label' {
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('tooltip', 'autoApplicationOf', 'encryption.promptUser') `
            -Desired $script:HashWithoutAutoApply `
            -Tenant  $script:HashWithAutoApply
        $result.NeedsPortalRemoval | Should -BeTrue
        $result.ApplyableDiffs | Should -Contain 'tooltip'
        $result.ApplyableDiffs | Should -Contain 'encryption.promptUser'
        $result.ApplyableDiffs | Should -Not -Contain 'autoApplicationOf'
    }

    It 'does nothing when the bare autoApplicationOf field is not in the diff list' {
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('tooltip', 'encryption.promptUser') `
            -Desired $script:HashWithoutAutoApply `
            -Tenant  $script:HashWithAutoApply
        $result.NeedsPortalRemoval | Should -BeFalse
        $result.ApplyableDiffs | Should -Contain 'tooltip'
        $result.ApplyableDiffs | Should -Contain 'encryption.promptUser'
    }

    It 'returns an empty ApplyableDiffs array (not $null) when the only diff is the removal' {
        $result = Resolve-AutoApplyRemovalPlan `
            -Diffs   @('autoApplicationOf') `
            -Desired $script:HashWithoutAutoApply `
            -Tenant  $script:HashWithAutoApply
        # The planner reads `$applyableDiffs.Count -gt 0`; the stored value
        # must be a real (possibly empty) array so the property access is
        # well-defined, never $null.
        $null -eq $result.ApplyableDiffs | Should -BeFalse
        @($result.ApplyableDiffs).Count | Should -Be 0
    }
}

Describe 'Get-NeedsPortalActionSummary (issue #512, closes #429)' {

    BeforeAll {
        $script:NeedsPortalRow = [pscustomobject]@{
            Category = 'NeedsPortalAction'
            Kind     = 'Label'
            Name     = 'Confidential\Internal'
            Reason   = 'Tenant carries an autoApplicationOf (Conditions) block ...'
            Field    = 'autoApplicationOf'
        }
        $script:UpdateRow = [pscustomobject]@{
            Category = 'Update'; Kind = 'Label'; Name = 'Confidential\Partner'
            Reason = 'Tracked field differs from tenant.'; Field = 'tooltip'
        }
        $script:NoChangeRow = [pscustomobject]@{
            Category = 'NoChange'; Kind = 'Label'; Name = 'Public'
            Reason = ''; Field = ''
        }
    }

    It 'returns $null when no NeedsPortalAction rows exist' {
        $result = Get-NeedsPortalActionSummary -Report @($script:UpdateRow, $script:NoChangeRow)
        $result | Should -BeNullOrEmpty
    }

    It 'returns $null on an empty report' {
        $result = Get-NeedsPortalActionSummary -Report @()
        $result | Should -BeNullOrEmpty
    }

    It 'emits a console block naming each affected label exactly once (de-duped)' {
        $report = @(
            $script:NeedsPortalRow,
            $script:NeedsPortalRow,  # duplicate, must collapse via Sort -Unique
            $script:UpdateRow
        )
        $result = Get-NeedsPortalActionSummary -Report $report
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match 'MANUAL PORTAL ACTIONS REQUIRED -- 1 label'
        $result | Should -Match 'Confidential\\Internal'
        $result | Should -Match '#512'
        $result | Should -Match 'ADR 0027|0027-autoapplication-removal'
        $result | Should -Match 'docs/runbooks/labels-manual-portal-actions.md'
    }

    It 'emits a markdown block with the GitHub-rendered warning header when -Markdown is set' {
        $result = Get-NeedsPortalActionSummary -Report @($script:NeedsPortalRow) -Markdown
        $result | Should -Not -BeNullOrEmpty
        $result | Should -Match '## :warning: Manual portal actions required'
        $result | Should -Match '\[#512\]'
        $result | Should -Match '\[ADR 0027\]'
        $result | Should -Match 'labels-manual-portal-actions\.md'
        # Confirms the markdown block uses bullet-list syntax for the
        # affected labels, not console hyphens.
        $result | Should -Match '- `Confidential\\Internal`'
    }

    It 'omits Update / NoChange / Create rows from the affected-labels list' {
        $report = @(
            $script:UpdateRow,
            $script:NoChangeRow,
            $script:NeedsPortalRow
        )
        $result = Get-NeedsPortalActionSummary -Report $report
        $result | Should -Match 'Confidential\\Internal'
        $result | Should -Not -Match 'Confidential\\Partner'
        $result | Should -Not -Match '\bPublic\b'
    }
}

Describe 'Get-Label PendingDeletion filter (issue #441 / #450)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'filters PendingDeletion rows from the Apply read path' {
        # Phase 1 read in the Apply branch. Without the filter a
        # just-pruned label resurfaces as a NoOp orphan on -WhatIf and
        # inflates the B-strict conflict-guard orphan count.
        $script:ScriptText | Should -Match '\$tenantLabels\s*=\s*@\(\s*Get-Label\s+-IncludeDetailedLabelActions:\$true\s+-ErrorAction\s+Stop\s*\|\s*Where-Object\s*\{\s*\$_\.Mode\s+-ne\s+''PendingDeletion''\s*\}\s*\)'
    }

    It 'filters PendingDeletion rows from the -ExportCurrentState read path' {
        # Without the filter the drift-back exporter
        # (sync-labels-from-tenant.yml) would re-import a soft-deleted
        # label into committed YAML on its next scheduled run.
        $script:ScriptText | Should -Match '\$allLabels\s*=\s*@\(\s*Get-Label\s+-IncludeDetailedLabelActions:\$true\s+-ErrorAction\s+Stop\s*\|\s*Where-Object\s*\{\s*\$_\.Mode\s+-ne\s+''PendingDeletion''\s*\}\s*\)'
    }

    It 'has no unfiltered Get-Label -IncludeDetailedLabelActions read sites' {
        # Future-proofing: every read of detailed-label data must apply
        # the filter. If a contributor adds a third call site without
        # the filter, this test fails.
        $callSites = [regex]::Matches(
            $script:ScriptText,
            'Get-Label\s+-IncludeDetailedLabelActions:\$true\s+-ErrorAction\s+Stop')
        $callSites.Count | Should -Be 2
        foreach ($m in $callSites) {
            $tail = $script:ScriptText.Substring(
                $m.Index + $m.Length,
                [Math]::Min(120, $script:ScriptText.Length - ($m.Index + $m.Length)))
            $tail | Should -Match 'Where-Object\s*\{\s*\$_\.Mode\s+-ne\s+''PendingDeletion''\s*\}'
        }
    }

    It 'strips PendingDeletion rows from a Get-Label pipeline (behavioral)' {
        # Independent proof that the filter expression itself does what
        # the source-text tests claim it does, without relying on the
        # ExchangeOnlineManagement cmdlet.
        $fakeLabels = @(
            [pscustomobject]@{ DisplayName = 'Confidential'; Mode = 'Enable' }
            [pscustomobject]@{ DisplayName = 'Public';       Mode = 'Enable' }
            [pscustomobject]@{ DisplayName = 'Smoke-Parent'; Mode = 'PendingDeletion' }
        )
        $filtered = @($fakeLabels | Where-Object { $_.Mode -ne 'PendingDeletion' })
        $filtered.Count | Should -Be 2
        ($filtered.DisplayName -contains 'Smoke-Parent') | Should -BeFalse
    }
}

Describe 'DirectionPolicy parameter (ADR 0029)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'declares a -DirectionPolicy parameter with the audit/portal-wins/repo-wins ValidateSet' {
        # Source-text assertion: the ValidateSet attribute and parameter
        # declaration must remain stable so the workflow contract in
        # sub-issue C can pass the value through unchanged.
        $script:ScriptText | Should -Match '\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'defaults -DirectionPolicy to portal-wins per ADR 0029' {
        # Independent assertion on the default value so a future contributor
        # who reorders the attribute decorators still sees a focused failure
        # when the default changes.
        $script:ScriptText | Should -Match '\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'attaches -DirectionPolicy to both Apply and Export parameter sets' {
        # Required so -ExportCurrentState callers can opt into audit mode
        # (read-only verify of the export path) without separate parameter
        # ceremonies. The parameter declaration carries two consecutive
        # Parameter attributes (one per set) before the ValidateSet.
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy'
    }

    It 'declares -SkipNames on the Apply parameter set only' {
        # The workflow uses -SkipNames to pass a pre-computed skip list to
        # the apply path; the export path has no use for it. Single Parameter
        # attribute (Apply only), [string[]] type, default empty array.
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'has a single audit-mode short-circuit that empties the plan before Phase 2' {
        # Source-text guard: the audit short-circuit must run after the
        # Blocked-rows fail-fast and before "Phase 2: Refresh session
        # before any writes". Audit mode keeps the categorized report
        # intact for the end-of-script emission but empties $plan and
        # $orphans so the write loop is a no-op without disrupting the
        # script's normal control flow (early-return-from-try-block
        # confused PowerShell's post-finally output handling).
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''.*?\$plan\.Clear\(\)\s*\r?\n\s*\$orphans\s*=\s*@\(\)\s*\r?\n\s*\}'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'portal-wins'
    }

    It 'returns Update when policy is portal-wins and no drift is present' {
        # NoChange / Create entries do not call this helper, but the
        # contract is well-defined for the no-drift case so future callers
        # do not need to guard.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'Internal' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'emits a Write-Warning on each repo-wins overwrite via the policy pass' {
        # Source-text assertion: the per-label warning is the audit signal
        # that lets a reviewer of the run log see which tenant fields were
        # overwritten and on which labels.
        $script:ScriptText | Should -Match 'Write-Warning \("Overwriting tenant on label '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped label for workflow consumption' {
        # The sub-issue C workflow parses these markers (one per line) to
        # build the auto-PR skip list. The marker shape is part of the
        # script-to-workflow contract and must not drift.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }
}

Describe 'SkipNames behavior (ADR 0029)' {

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('Internal') `
            -DisplayName 'Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is false' {
        # Module-level helper is unconditional on the skip list. The
        # call site in scripts/Deploy-Labels.ps1 only consults the helper
        # for rows whose Action is 'Update', so a NoChange row carrying a
        # SkipNames-matched name is reported as NoChange, not Skip.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('Internal') `
            -DisplayName 'Internal' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        # Defends against casing mismatches between a workflow-supplied
        # skip list (which may parse from a comma-joined string) and the
        # YAML displayName.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('INTERNAL') `
            -DisplayName 'Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        # `Where-Object { $_ -ieq $DisplayName }` is an equality, not a
        # contains/regex match. A label named 'Confidential / Internal'
        # is not skipped by `-SkipNames Internal`.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('Internal') `
            -DisplayName 'Confidential / Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames' {
        # The script ignores skip-list entries that match no label, so a
        # stale workflow-supplied list does not abort the run. The helper
        # itself never observes unknown names (the policy pass walks the
        # plan, not the skip list), so this is a documented invariant we
        # exercise at the call-site shape.
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchLabel') `
                -DisplayName 'Internal' `
                -HasDrift    $true } | Should -Not -Throw
    }

    It 'handles an empty SkipList without error' {
        # @() is the default. Defensive test against future refactors that
        # might $null the default.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'Internal' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }
}
