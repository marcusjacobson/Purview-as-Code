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

Describe 'The redacted export emits rightsDefinitions in a canonical order (#225 follow-up to #194)' {
    # Found by diffing merged dev against PR #229 -- an actual
    # -RedactIdentities export of the live dev tenant. #238 had just
    # redacted dev's 12 real identities, and the sync was declared fixed;
    # the export still produced a 12-line diff, because the committed file
    # and the exporter disagreed on the ORDER of the two rights entries in
    # each of six labels. Nothing had drifted.
    #
    # Root cause: the redaction collapses every Identity to the same
    # literal, so the export's `Sort-Object Identity` had become an
    # ALL-TIES key. Sort-Object is not stable without -Stable, and the
    # tenant's return order is not a contract either, so emission order was
    # undefined. Fixed by giving the sort a real total order (Identity,
    # Rights) rather than reaching for -Stable, which has no precedent
    # here -- the same resolution #194 took on the IRM surface.
    #
    # This matters because a re-export is a PRODUCER on this surface:
    # sync-labels-from-tenant.yml runs daily and opens a drift-back PR from
    # the result, so a reordering-only diff is indistinguishable at a glance
    # from a real portal edit -- the noise that got #170 and #172 merged
    # reflexively on the sibling surface.
    #
    # The compare path is order-blind (Compare-LabelHash sorts before
    # comparing), which is why the audit reported clean and no existing
    # test caught this. Only the export path is order-sensitive.

    BeforeAll {
        $script:TrackedLabelsPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'information-protection' 'labels.yaml'
        Import-Module powershell-yaml -ErrorAction Stop
        $script:TrackedLabels = @((Get-Content -LiteralPath $script:TrackedLabelsPath -Raw | ConvertFrom-Yaml).labels)

        # Anchor to the EXPORT path's sort statement, not the whole file:
        # lines ~408 and ~589 also sort by Identity on the compare path,
        # where identities are real and distinct and a single key IS a
        # total order. A whole-file regex would match those and assert
        # nothing about the line that actually broke.
        $script:ExportSortLine = (((Get-Content -LiteralPath $script:ScriptPath -Raw) -split "`r?`n") |
            Where-Object { $_ -match '\$rightsDefs\s*=\s*@\(\$redacted\s*\|\s*Sort-Object' })
    }

    It 'the exporter sorts redacted rights definitions on a total order, not an all-ties key' {
        # Read the production sort rather than restating it: if this line
        # changes, the ordering assertion below is no longer describing the
        # same contract and must be revisited deliberately.
        $script:ExportSortLine | Should -Not -BeNullOrEmpty -Because 'the export sort statement must exist for the rest of this Describe to test anything real'
        $script:ExportSortLine | Should -Match 'Sort-Object Identity, Rights' -Because 'after redaction Identity alone is an all-ties key, so it cannot define the canonical order the tracked file must match'
    }

    It 'every tracked label lists its rightsDefinitions in that same order' {
        $checked = 0
        foreach ($label in $script:TrackedLabels) {
            $rights = @($label.encryption.rightsDefinitions)
            if ($rights.Count -lt 2) { continue }
            $checked++
            $actual = @($rights | ForEach-Object { '{0}|{1}' -f $_.Identity, $_.Rights })
            $expected = @($rights | Sort-Object Identity, Rights | ForEach-Object { '{0}|{1}' -f $_.Identity, $_.Rights })
            # -SyncWindow 0 catches a reordering; without it two lists holding
            # the same entries in a different order compare equal.
            $diff = Compare-Object -ReferenceObject $actual -DifferenceObject $expected -SyncWindow 0
            $diff | Should -BeNullOrEmpty -Because ("label '{0}' lists its rights entries out of canonical order, so a re-export would open a drift-back PR whose diff is a pure reordering" -f $label.displayName)
        }
        $checked | Should -BeGreaterThan 0 -Because 'a file with no multi-entry rightsDefinitions would satisfy this vacuously'
    }

    It 'the secondary key is what orders a fully-redacted pair (red-replay of the exact defect)' {
        # Data-independent regression anchor, using the two real Rights
        # strings from dev. Independent of what this branch happens to track.
        $owner = 'DOCEDIT,EDIT,EDITRIGHTSDATA,EXPORT,EXTRACT,FORWARD,OBJMODEL,OWNER,PRINT,REPLY,REPLYALL,VIEW,VIEWRIGHTSDATA'
        $coauthor = 'DOCEDIT,EDIT,EXTRACT,FORWARD,OBJMODEL,PRINT,REPLY,REPLYALL,VIEW,VIEWRIGHTSDATA'
        $tenantOrder = @(
            [pscustomobject]@{ Identity = 'user@contoso.com'; Rights = $coauthor }
            [pscustomobject]@{ Identity = 'user@contoso.com'; Rights = $owner }
        )

        # RED: the pre-fix single-key sort has nothing to order by, so it
        # simply echoes whatever order the tenant returned. This is the
        # defect -- proved here rather than asserted about.
        (@($tenantOrder | Sort-Object Identity))[0].Rights | Should -Be $coauthor -Because 'an all-ties key leaves emission order at the mercy of the tenant, which is not a contract'

        # GREEN: the two-key sort produces the same output from either input
        # order, which is what makes a re-export reproduce the tracked file.
        (@($tenantOrder | Sort-Object Identity, Rights))[0].Rights | Should -Be $owner
        $reversed = @($tenantOrder[1], $tenantOrder[0])
        (@($reversed | Sort-Object Identity, Rights))[0].Rights | Should -Be $owner -Because 'order-stability means the tenant may return these either way round and the export must not change'
    }
}

Describe 'The redacting export preserves well-known symbolic identities (#225)' {
    # Found live: the dev tenant's `Pilot - Confidential A1 (Lab)` label
    # holds IPC_USER_ID_OWNER -- a Microsoft rights-management constant
    # meaning "the content owner", not a principal. -RedactIdentities
    # rewrote it to user@contoso.com like any UPN, which was wrong twice:
    # it is a disclosure no-op (the value is identical in every tenant on
    # earth), and it destroys real desired-state meaning, replacing "the
    # owner holds OWNER" with a placeholder principal that means something
    # else. The label then drifted forever, because the tenant kept
    # returning the symbolic form while the repo committed the placeholder.
    #
    # labels.schema.json's own Identity description already anticipated
    # this by naming AuthenticatedUsers as a legitimate value; only the
    # redaction path did not know.

    BeforeAll {
        $script:LabelsSource = Get-Content -LiteralPath $script:ScriptPath -Raw
        $symbolicBlock = [regex]::Match($script:LabelsSource,
            '\$script:WellKnownSymbolicIdentities\s*=\s*@\(([^)]*)\)')
        $script:SymbolicList = @(
            [regex]::Matches($symbolicBlock.Groups[1].Value, "'([^']+)'") |
                ForEach-Object { $_.Groups[1].Value })
    }

    It 'the allow-list exists in production source and is fail-closed in shape' {
        $script:SymbolicList.Count | Should -BeGreaterThan 0 -Because 'the export path consults this list; an empty one silently restores the old redact-everything behaviour'
        $script:SymbolicList | Should -Contain 'IPC_USER_ID_OWNER'
    }

    It 'the redaction branch consults the allow-list rather than redacting unconditionally' {
        # Anchored to the export path's own decision, not a mention: the
        # constant is also described in prose above its definition.
        $script:LabelsSource | Should -Match 'WellKnownSymbolicIdentities -contains' -Because 'the redaction must be a lookup, not an unconditional rewrite'
    }

    It 'redacts addressable principals but preserves symbolic ones (the live dev shape)' {
        # Mirrors the production expression rather than invoking the
        # exporter, which would need a tenant connection. The three inputs
        # inputs mirror the SHAPE the dev tenant returns -- a UPN, a
        # group SMTP address and a service constant -- with the two
        # addressable ones written in the synthetic namespace, because
        # this file ports to the public template (issue #329).
        $tenant = @(
            [pscustomobject]@{ Identity = 'owner@contoso-dev.cloud'; Rights = 'OWNER' }
            [pscustomobject]@{ Identity = 'allcompany@contoso.onmicrosoft.com'; Rights = 'VIEW' }
            [pscustomobject]@{ Identity = 'IPC_USER_ID_OWNER'; Rights = 'OWNER' }
        )
        $out = foreach ($rd in $tenant) {
            if ($script:SymbolicList -contains [string]$rd.Identity) { [string]$rd.Identity } else { 'user@contoso.com' }
        }
        $out[0] | Should -Be 'user@contoso.com' -Because 'a real UPN must be redacted'
        $out[1] | Should -Be 'user@contoso.com' -Because 'a real group SMTP address must be redacted'
        $out[2] | Should -Be 'IPC_USER_ID_OWNER' -Because 'a service constant carries no tenant information and must survive verbatim, or the label drifts forever'
    }

    It 'an unknown symbolic-looking value is still redacted (fail-closed)' {
        # The list is an allow-list on purpose: a future constant we have
        # not seen is over-redacted, which shows up as drift and prompts
        # review, rather than being disclosed silently.
        $unknown = 'IPC_USER_ID_SOMETHING_NEW'
        $script:SymbolicList | Should -Not -Contain $unknown
        $result = if ($script:SymbolicList -contains $unknown) { $unknown } else { 'user@contoso.com' }
        $result | Should -Be 'user@contoso.com'
    }
}

Describe 'rightsDefinitions comparison is PER-ENTRY, not all-or-nothing (#225)' {
    # Preserving well-known symbolic identities made MIXED files the normal
    # case: lab's tenant produces one `AuthenticatedUsers` alongside four
    # redacted placeholders. The original mitigation only engaged when EVERY
    # desired identity was a placeholder, so a mixed file fell through to
    # strict identity comparison and compared `user@contoso.com` literally
    # against real tenant principals it can never equal -- reporting drift on
    # three lab labels forever.
    #
    # Caught by running a repo-wins -WhatIf against the live lab tenant after
    # the symbolic-identity change: the plan showed 4 Updates where only 1 was
    # intended. This is #225's option 3, deferred at the time and made
    # necessary by the symbolic fix.
    #
    # The rule: a REDACTED identity is opaque and may only be matched on
    # Rights; a real or symbolic identity is matched exactly. Both sides must
    # pair one-to-one.

    BeforeAll {
        function Get-TestRightsEntry { param([string]$Id, [string]$Rights) [pscustomobject]@{ Identity = $Id; Rights = $Rights } }
        function Get-TestEncryptionHash { param([object[]]$Rd) @{ encryption = @{ enabled = $true; rightsDefinitions = $Rd } } }
        function Test-Drift {
            param([object[]]$Desired, [object[]]$Tenant)
            @(Compare-LabelHash -Desired (Get-TestEncryptionHash $Desired) -Tenant (Get-TestEncryptionHash $Tenant)) -contains 'encryption.rightsDefinitions'
        }
        $script:MixedDesired = @(
            (Get-TestRightsEntry 'AuthenticatedUsers' 'OBJMODEL,VIEW')
            (Get-TestRightsEntry 'user@contoso.com' 'EDIT,VIEW')
            (Get-TestRightsEntry 'user@contoso.com' 'OWNER')
        )
    }

    It 'a MIXED file matching the tenant reports NO drift (the regression)' {
        $tenant = @(
            (Get-TestRightsEntry 'AuthenticatedUsers' 'OBJMODEL,VIEW')
            (Get-TestRightsEntry 'real@lab.test' 'EDIT,VIEW')
            (Get-TestRightsEntry 'other@lab.test' 'OWNER')
        )
        Test-Drift -Desired $script:MixedDesired -Tenant $tenant | Should -BeFalse -Because 'the placeholders are opaque and the symbolic identity matches, so nothing has actually drifted'
    }

    It 'a MIXED file still reports drift when a placeholder''s Rights change' {
        $tenant = @(
            (Get-TestRightsEntry 'AuthenticatedUsers' 'OBJMODEL,VIEW')
            (Get-TestRightsEntry 'real@lab.test' 'EDIT,VIEW')
            (Get-TestRightsEntry 'other@lab.test' 'PRINT')
        )
        Test-Drift -Desired $script:MixedDesired -Tenant $tenant | Should -BeTrue -Because 'opaque means unknown WHO, not unknown WHAT -- a rights change is real drift'
    }

    It 'a MIXED file reports drift when the SYMBOLIC identity is absent from the tenant' {
        $tenant = @(
            (Get-TestRightsEntry 'someone@lab.test' 'OBJMODEL,VIEW')
            (Get-TestRightsEntry 'real@lab.test' 'EDIT,VIEW')
            (Get-TestRightsEntry 'other@lab.test' 'OWNER')
        )
        Test-Drift -Desired $script:MixedDesired -Tenant $tenant | Should -BeTrue -Because 'a symbolic identity is meaningful and must be matched exactly, never treated as opaque'
    }

    It 'a FULLY redacted file still compares opaquely (the #137 behaviour must survive)' {
        $desired = @( (Get-TestRightsEntry 'user@contoso.com' 'A'), (Get-TestRightsEntry 'user@contoso.com' 'B') )
        Test-Drift -Desired $desired -Tenant @( (Get-TestRightsEntry 'x@lab.test' 'A'), (Get-TestRightsEntry 'y@lab.test' 'B') ) | Should -BeFalse
        Test-Drift -Desired $desired -Tenant @( (Get-TestRightsEntry 'x@lab.test' 'A'), (Get-TestRightsEntry 'y@lab.test' 'Z') ) | Should -BeTrue
        Test-Drift -Desired $desired -Tenant @( (Get-TestRightsEntry 'x@lab.test' 'A') ) | Should -BeTrue -Because 'a count mismatch is drift regardless of opacity'
    }

    It 'the apply path omits EncryptionRightsDefinitions when ANY identity is a placeholder' {
        # Not just when ALL are. EncryptionRightsDefinitions is written whole,
        # so a mixed set has no correct partial write: sending it would push
        # user@contoso.com at the tenant (TextEmptyException), and if it landed
        # it would drop the rights of every entry not named.
        $mixed = ConvertTo-LabelCmdletArgument -Desired @{
            displayName = 'X'
            encryption  = @{ enabled = $true; protectionType = 'Template'; rightsDefinitions = $script:MixedDesired }
        }
        $mixed.ContainsKey('EncryptionRightsDefinitions') | Should -BeFalse -Because 'a mixed set cannot be written without either failing server-side or silently revoking the unnamed entries'

        $realOnly = ConvertTo-LabelCmdletArgument -Desired @{
            displayName = 'X'
            encryption  = @{ enabled = $true; protectionType = 'Template'; rightsDefinitions = @((Get-TestRightsEntry 'real@lab.test' 'OWNER')) }
        }
        $realOnly['EncryptionRightsDefinitions'] | Should -Be 'real@lab.test:OWNER' -Because 'a fully resolvable set must still be written'
    }
}
