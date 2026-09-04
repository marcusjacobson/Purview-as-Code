#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the ADR 0029 direction-policy contract in
    `scripts/Deploy-AutoLabelPolicies.ps1`.

.DESCRIPTION
    Exercises the contract from
    `.github/instructions/powershell.instructions.md`
    "Direction-policy contract (ADR 0029)" against the script:

      * `-DirectionPolicy` parameter declaration shape and default.
      * `-SkipNames` parameter declaration shape.
      * Audit-mode short-circuit source-text guard (must clear BOTH
        plans and BOTH orphan lists, never `return`).
      * Repo-wins overwrite Write-Warning shape for BOTH kinds
        (auto-label policy + auto-label rule).
      * [ADR0029-SKIP] marker emission shape.
      * Three branches of `Resolve-DirectionPolicyAction` (audit short-
        circuit lives in the consumer script, not in the helper):
        portal-wins skip, repo-wins update, no-drift update.
      * SkipNames precedence (case-insensitive equality, not substring,
        not error on stale entries).

    The script body cannot be dot-sourced (it loads
    ExchangeOnlineManagement at import time and would connect to a
    real tenant). Pattern matches the sibling
    `tests/scripts/Deploy-LabelPolicies.Tests.ps1` (16 ADR 0029 cases
    added in PR #468, refactored in PR #474 to import the shared
    module): source-text assertions for script-level requirements +
    direct helper invocations from the shared module.

    Reference: docs/adr/0029-source-of-truth-direction-policy.md
    Reference: scripts/modules/DirectionPolicy.psm1
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-AutoLabelPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-AutoLabelPolicies.ps1 at: $script:ScriptPath"
    }

    # Import the in-repo ADR 0029 direction-policy module so the
    # `Describe 'Apply-path direction policy branches'` and
    # `Describe 'SkipNames behavior'` blocks can call
    # `Resolve-DirectionPolicyAction` directly. Shared with the labels
    # and label-policies test files since PR #474.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
        -Force -ErrorAction Stop
}

Describe 'DirectionPolicy parameter (ADR 0029)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'declares a -DirectionPolicy parameter with the audit/portal-wins/repo-wins ValidateSet' {
        # Source-text assertion: the ValidateSet attribute and parameter
        # declaration must remain stable so the workflow contract in
        # Phase 2 (.github/workflows/deploy-auto-label-policies.yml) can
        # pass the value through unchanged.
        $script:ScriptText | Should -Match '\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'defaults -DirectionPolicy to portal-wins per ADR 0029' {
        $script:ScriptText | Should -Match '\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'attaches -DirectionPolicy to both Apply and Export parameter sets' {
        # Mirrors Deploy-Labels.ps1 (PR #458) and Deploy-LabelPolicies.ps1
        # (PR #468). Allows -ExportCurrentState callers to opt into
        # audit mode without separate parameter ceremonies.
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy'
    }

    It 'declares -SkipNames on the Apply parameter set only' {
        # The workflow uses -SkipNames to pass a pre-computed skip list
        # to the apply path; the export path has no use for it. Single
        # Parameter attribute (Apply only), [string[]] type, default
        # empty array.
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'has an audit-mode short-circuit that empties BOTH plans and BOTH orphan lists before Phase 2' {
        # Source-text guard: the audit short-circuit must run after the
        # Blocked-rows fail-fast and before "Phase 2: Refresh session
        # before any writes". Audit mode keeps the categorized report
        # intact for the end-of-script emission but empties BOTH
        # $policyPlan and $rulePlan, and reassigns BOTH $orphanPolicies
        # and $orphanRules to empty arrays, so the write loops are
        # no-ops without disrupting the script's normal control flow
        # (early-return-from-try-block broke post-finally output
        # handling on the labels-side prototype). The match is
        # loose-but-anchored: AUDIT marker followed by clears of both
        # plans and reassignment of both orphan lists, before Phase 2.
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''.*?\$policyPlan\.Clear\(\).*?\$rulePlan\.Clear\(\).*?\$orphanPolicies\s*=\s*@\(\).*?\$orphanRules\s*=\s*@\(\)\s*\r?\n\s*\}'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'portal-wins'
    }

    It 'returns Update when policy is portal-wins and no drift is present' {
        # NoChange / Create entries do not call this helper, but the
        # contract is well-defined for the no-drift case so future
        # callers do not need to guard.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'emits one Write-Warning per drifted auto-label policy on repo-wins (not per granular Set-* call)' {
        # Source-text assertion: the warning fires once per policy in
        # the direction-policy pass with the comma-joined drifted field
        # set. The wording differs from Deploy-Labels.ps1 and
        # Deploy-LabelPolicies.ps1 only by using "auto-label policy"
        # so a run-log grep can disambiguate the three reconcilers.
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on auto-label policy '''
    }

    It 'emits one Write-Warning per drifted auto-label rule on repo-wins' {
        # Auto-label policies and their rules are reconciled separately
        # (two parallel plan lists). The direction-policy pass walks
        # both, emitting a kind-specific warning so the run log makes
        # the policy-vs-rule distinction obvious.
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on auto-label rule '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped object for workflow consumption' {
        # The Phase 2 workflow
        # (.github/workflows/deploy-auto-label-policies.yml, separate
        # PR) will parse these markers (one per line) to build the
        # auto-PR skip list. The marker shape is part of the
        # script-to-workflow contract and must not drift. Format must
        # match `^\[ADR0029-SKIP\] (.+)$` per the github-actions
        # instructions rule (no Kind prefix in the marker line).
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }
}

Describe 'SkipNames behavior (ADR 0029)' {

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-auto-confidential') `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is false' {
        # Module-level helper is unconditional on the skip list. The
        # call site in scripts/Deploy-AutoLabelPolicies.ps1 only consults
        # the helper for rows whose Action is 'Update', so a NoChange row
        # carrying a SkipNames-matched name is reported as NoChange, not Skip.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('lab-auto-confidential') `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        # Defends against casing mismatches between a workflow-supplied
        # skip list (parsed from comma-joined markers) and the YAML
        # display name.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('LAB-AUTO-CONFIDENTIAL') `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        # `Where-Object { $_ -ieq $DisplayName }` is an equality, not a
        # contains/regex match. A rule named 'lab-auto-confidential-rule'
        # is not skipped by `-SkipNames lab-auto-confidential`.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-auto-confidential') `
            -DisplayName 'lab-auto-confidential-rule' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames' {
        # The script ignores skip-list entries that match no object, so
        # a stale workflow-supplied list does not abort the run.
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchPolicy') `
                -DisplayName 'lab-auto-confidential' `
                -HasDrift    $true } | Should -Not -Throw
    }

    It 'handles an empty SkipList without error' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-auto-confidential' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }
}

Describe 'ConvertTo-TenantPolicyHash applyLabel sublabel resolution (issue #480)' {

    BeforeAll {
        # AST-extract ConvertTo-TenantPolicyHash and its sole helper
        # dependency ConvertTo-PolicyInputMode so the function body can
        # be evaluated standalone. Mirrors the labels-side
        # tests/scripts/Deploy-LabelPolicies.Tests.ps1 pattern (issue
        # #230, PR #231) and the AST-extract-and-stub conventions in
        # .github/instructions/tests.instructions.md.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @('ConvertTo-PolicyInputMode', 'ConvertTo-TenantPolicyHash')) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Stub the three script-scoped dependencies the function reads:
        #   - $script:AdvancedSettingsAllowlist (Settings branch only;
        #     these tests do not exercise Settings).
        #   - $script:ValidPolicyModes (ConvertTo-PolicyInputMode echoes
        #     known modes back).
        #   - $script:RuntimePolicyModeMap (empty; matches production
        #     commit 1 of Deploy-AutoLabelPolicies.ps1).
        $script:AdvancedSettingsAllowlist = @()
        $script:ValidPolicyModes = @('Enable', 'Disable', 'TestWithNotifications', 'TestWithoutNotifications')
        $script:RuntimePolicyModeMap = @{}

        # Synthetic tenant labels. Two top-level (Confidential, Highly
        # Confidential) and four sublabels of varying name shapes. GUIDs
        # use the documented zero-GUID placeholder pattern (last byte
        # varied) so nothing here resembles a real label identifier.
        $script:TenantLabels = @(
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Confidential';        ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000002'; DisplayName = 'Highly Confidential'; ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000011'; DisplayName = 'Internal';            ParentId = '00000000-0000-0000-0000-000000000001' }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000012'; DisplayName = 'Partner';             ParentId = '00000000-0000-0000-0000-000000000001' }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000021'; DisplayName = 'Internal (Restricted)'; ParentId = '00000000-0000-0000-0000-000000000002' }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000022'; DisplayName = 'External (Restricted)'; ParentId = '00000000-0000-0000-0000-000000000002' }
        )

        function Get-FakeAutoLabelPolicy {
            param([string]$ApplyLabel, [string]$Name = 'lab-auto-fake')
            return [pscustomobject]@{
                Name                  = $Name
                Guid                  = '00000000-0000-0000-0000-0000000000ff'
                Mode                  = 'Enable'
                Status                = 'Pending'
                ExchangeLocation      = @()
                ApplySensitivityLabel = $ApplyLabel
                Settings              = @()
            }
        }
    }

    It 'collapses a bare GUID applyLabel to itself' {
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel '00000000-0000-0000-0000-000000000012'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'resolves a "<Parent> - <Child>" applyLabel rendering to the child GUID' {
        # Default Get-AutoSensitivityLabelPolicy rendering for sublabels.
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Confidential - Partner'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'resolves a "<Parent>/<Child>" applyLabel rendering to the child GUID' {
        # Get-LabelPolicy / YAML composite-key rendering. Accepted on
        # input for symmetry with Deploy-LabelPolicies.
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Confidential/Partner'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'resolves a top-level bare <DisplayName> applyLabel to its GUID' {
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Confidential'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000001'
    }

    It 'resolves a bare child <DisplayName> applyLabel for a portal-created sublabel to the child GUID (regression for issue #480)' {
        # This is the bug surfaced in issue #480, run 26720507270 on
        # 2026-05-31: Get-AutoSensitivityLabelPolicy returned the bare
        # child name 'Partner' for the sublabel 'Confidential/Partner'.
        # Pre-fix, the helper failed to resolve and the export emitted
        # bare 'Partner', breaking the round-trip. Post-fix, the
        # bare-child fallback resolves to the child GUID so the export
        # path can render the canonical composite via
        # ConvertTo-LabelCompositeKey.
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Partner'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'prefers the qualified rendering over the bare-child fallback when both could match' {
        # 'Internal' is a sublabel under Confidential. The qualified
        # 'Confidential - Internal' rendering must still resolve to the
        # Internal GUID (first-pass match), not be confused by the bare
        # fallback path.
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Confidential - Internal'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000011'
    }

    It 'drops the bare-child shortcut when two sublabels share a DisplayName under different parents' {
        # Add a second 'Partner' under Highly Confidential to force a
        # collision. The bare 'Partner' entry must now pass through
        # unresolved so the operator sees drift instead of a silent
        # wrong-label mapping. Qualified renderings still win.
        $tenantWithCollision = @($script:TenantLabels) + [pscustomobject]@{
            Guid        = '00000000-0000-0000-0000-000000000023'
            DisplayName = 'Partner'
            ParentId    = '00000000-0000-0000-0000-000000000002'
        }
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Partner'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $tenantWithCollision
        # Bare-child fallback dropped due to collision; raw rendering
        # passes through.
        $hash.applyLabel | Should -Be 'Partner'

        # Qualified rendering still resolves correctly under the same
        # tenant shape -- collision detection is bare-name only.
        $qualified = Get-FakeAutoLabelPolicy -ApplyLabel 'Confidential - Partner'
        $qhash = ConvertTo-TenantPolicyHash -Policy $qualified -TenantLabels $tenantWithCollision
        $qhash.applyLabel | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'passes the raw applyLabel through unchanged when no TenantLabels are supplied' {
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel 'Partner'
        $hash = ConvertTo-TenantPolicyHash -Policy $policy
        $hash.applyLabel | Should -Be 'Partner'
    }

    It 'returns an empty applyLabel when the tenant policy carries no ApplySensitivityLabel' {
        $policy = Get-FakeAutoLabelPolicy -ApplyLabel ''
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.applyLabel | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-DesiredRuleWorkload — preserve human-authored workload on export (issue #499)' {

    BeforeAll {
        # AST-extract the helper without dot-sourcing the script.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Resolve-DesiredRuleWorkload'
            }, $true)
        if (-not $fnAst) { throw "Resolve-DesiredRuleWorkload not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    Context 'Map construction' {

        It 'returns an empty hashtable when DesiredRules is $null' {
            $map = Resolve-DesiredRuleWorkload -DesiredRules $null
            $map | Should -BeOfType [hashtable]
            $map.Count | Should -Be 0
        }

        It 'returns an empty hashtable when DesiredRules is an empty array' {
            $map = Resolve-DesiredRuleWorkload -DesiredRules @()
            $map.Count | Should -Be 0
        }

        It 'maps a single rule name to its YAML workload' {
            $rules = @(
                @{ name = 'rule-a'; workload = 'Exchange' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 1
            $map['rule-a'] | Should -Be 'Exchange'
        }

        It 'maps multiple rules' {
            $rules = @(
                @{ name = 'rule-a'; workload = 'Exchange' }
                @{ name = 'rule-b'; workload = 'SharePoint,OneDriveForBusiness' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 2
            $map['rule-a'] | Should -Be 'Exchange'
            $map['rule-b'] | Should -Be 'SharePoint,OneDriveForBusiness'
        }

        It 'skips rules with a missing name field' {
            $rules = @(
                @{ workload = 'Exchange' }
                @{ name = 'rule-b'; workload = 'SharePoint' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 1
            $map['rule-b'] | Should -Be 'SharePoint'
        }

        It 'skips rules with an empty / whitespace name field' {
            $rules = @(
                @{ name = '   '; workload = 'Exchange' }
                @{ name = 'rule-b'; workload = 'SharePoint' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 1
            $map.ContainsKey('rule-b') | Should -BeTrue
        }

        It 'skips rules with a missing workload field (so the caller falls back to the tenant readback)' {
            $rules = @(
                @{ name = 'rule-a' }
                @{ name = 'rule-b'; workload = 'Exchange' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 1
            $map.ContainsKey('rule-a') | Should -BeFalse
            $map['rule-b'] | Should -Be 'Exchange'
        }

        It 'skips rules with an empty / whitespace workload field' {
            $rules = @(
                @{ name = 'rule-a'; workload = '' }
                @{ name = 'rule-b'; workload = '  ' }
                @{ name = 'rule-c'; workload = 'Exchange' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map.Count | Should -Be 1
            $map.ContainsKey('rule-c') | Should -BeTrue
        }

        It 'tolerates pscustomobject rule entries (in addition to hashtables)' {
            $rules = @(
                [pscustomobject]@{ name = 'rule-a'; workload = 'Exchange' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map['rule-a'] | Should -Be 'Exchange'
        }

        It 'preserves the YAML workload verbatim (no normalization, no sorting, no expansion)' {
            # The whole point of the helper: the YAML value is the
            # human-authored input, and we want it on disk byte-identical
            # to what the operator wrote. No alphabetic re-sort, no
            # pipe-join, no expansion.
            $rules = @(
                @{ name = 'r'; workload = 'Exchange, OneDriveForBusiness' }
            )
            $map = Resolve-DesiredRuleWorkload -DesiredRules $rules
            $map['r'] | Should -Be 'Exchange, OneDriveForBusiness'
        }
    }

    Context 'Export-loop wire-in (source-text guard)' {

        BeforeAll {
            $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
        }

        It 'calls Resolve-DesiredRuleWorkload from inside the ExportCurrentState block' {
            $script:ScriptText | Should -Match 'Resolve-DesiredRuleWorkload\s+-DesiredRules\s+\$desiredRuleEntries'
        }

        It 'uses the desired map for the workload entry when the rule name is present' {
            $script:ScriptText | Should -Match '\$desiredWorkloadByRuleName\.ContainsKey\(\$rh\.name\)'
            $script:ScriptText | Should -Match "\`$entry\['workload'\]\s*=\s*\`$desiredWorkloadByRuleName\[\`$rh\.name\]"
        }

        It 'emits the single default workload (not the tenant-expanded readback) for greenfield rules new to the tenant (issue #24)' {
            # The greenfield else-branch must NOT write $rh.workload: that
            # is the tenant-EXPANDED multi-workload set, which
            # New-AutoSensitivityLabelRule -Workload rejects with
            # MultipleWorkloadsNotAllowedException. It must write the single
            # deployable default instead, and warn.
            $script:ScriptText | Should -Match "else\s*\{[\s\S]*?\`$entry\['workload'\]\s*=\s*\`$script:DefaultExportRuleWorkload"
            $script:ScriptText | Should -Not -Match "else\s*\{\s*\r?\n\s*\`$entry\['workload'\]\s*=\s*\`$rh\.workload"
        }

        It 'declares the single-workload export default as Exchange (issue #24)' {
            $script:ScriptText | Should -Match "\`$script:DefaultExportRuleWorkload\s*=\s*'Exchange'"
        }

        It 'warns per rule when the greenfield workload is defaulted (issue #24)' {
            $script:ScriptText | Should -Match 'defaulted the exported workload to the single value'
        }
    }
}

Describe 'Greenfield workload export cardinality (issue #24)' {

    # WHY THIS REGION IS EXTRACTED AND EXECUTED
    # -----------------------------------------
    # The defect is behavioural: a source-text assertion cannot prove that a
    # GREENFIELD export (no prior YAML workload) actually emits a single,
    # deployable workload rather than the tenant-expanded multi-value set that
    # New-AutoSensitivityLabelRule -Workload rejects. The script body cannot be
    # dot-sourced (it loads ExchangeOnlineManagement at import time and would
    # connect to a real tenant), so the specific if/else that decides the
    # emitted workload is lifted from the REAL source by AST and executed
    # against stubs. Lifting the real node (not a transcription) is the point:
    # if the else-branch is reverted to $rh.workload, the greenfield case below
    # emits the expanded pipe-set and the mutation-check assertion fails.

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        # Dot-source the REAL default-workload assignment so the extracted
        # else-branch reads the script's actual convention, not a duplicate
        # transcribed here.
        $assignAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$script:DefaultExportRuleWorkload'
            }, $true)
        if (-not $assignAst) { throw '$script:DefaultExportRuleWorkload assignment not found in Deploy-AutoLabelPolicies.ps1' }
        . ([ScriptBlock]::Create($assignAst.Extent.Text))

        # Locate the if/else that chooses the emitted workload by its
        # condition text and lift its full extent.
        $ifAsts = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true)
        $workloadIf = $ifAsts | Where-Object {
            $_.Clauses[0].Item1.Extent.Text -match '\$desiredWorkloadByRuleName\.ContainsKey\(\$rh\.name\)'
        } | Select-Object -First 1
        if (-not $workloadIf) { throw 'workload-emit if/else ($desiredWorkloadByRuleName.ContainsKey($rh.name)) not found in export block' }

        # $entry is a mutable OrderedDictionary passed by reference, so the
        # lifted branch mutates the instance the test holds. Warnings are
        # captured off the warning stream (3>&1).
        $script:WorkloadEmitBlock = [ScriptBlock]::Create(
            'param($desiredWorkloadByRuleName, $rh, $entry) ' + $workloadIf.Extent.Text)
    }

    Context 'Greenfield rule (no prior YAML workload)' {

        It 'emits the single default workload Exchange, not the tenant-expanded pipe-set' {
            $map   = @{}   # no prior YAML workload for this rule
            $entry = [ordered]@{}
            $rh    = @{
                name     = 'greenfield-rule'
                policy   = 'Lab-AutoLabel-CreditCards'
                # The tenant readback: the full EXPANDED workload set.
                workload = 'Applications|AWS|Azure|Exchange|OneDriveForBusiness|PowerBI|SharePoint'
            }
            $null = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1

            $entry['workload'] | Should -Be 'Exchange'
            # Mutation-check: the pre-fix behaviour emitted the expanded set.
            $entry['workload'] | Should -Not -Match '\|'
        }

        It 'emits a single deployable workload from the schema enum (no pipe, matches the apply cmdlet contract)' {
            $map   = @{}
            $entry = [ordered]@{}
            $rh    = @{ name = 'g'; policy = 'p'; workload = 'Exchange|SharePoint' }
            $null = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1
            ($entry['workload'] -split '\|').Count | Should -Be 1
        }

        It 'emits a Write-Warning noting the workload was defaulted' {
            $map   = @{}
            $entry = [ordered]@{}
            $rh    = @{ name = 'greenfield-rule'; policy = 'p'; workload = 'Exchange|SharePoint' }
            $warnings = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1

            $warningRecords = @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $warningRecords.Count | Should -Be 1
            [string]$warningRecords[0] | Should -Match 'greenfield-rule'
            [string]$warningRecords[0] | Should -Match 'Exchange'
        }
    }

    Context 'Rule with a prior YAML workload (issue #499 preservation, unchanged)' {

        It 'preserves the human-authored YAML workload verbatim' {
            $map   = @{ 'kept-rule' = 'SharePoint' }
            $entry = [ordered]@{}
            $rh    = @{
                name     = 'kept-rule'
                policy   = 'p'
                workload = 'Applications|AWS|Azure|Exchange|OneDriveForBusiness|PowerBI|SharePoint'
            }
            $null = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1

            $entry['workload'] | Should -Be 'SharePoint'
        }

        It 'does not warn when a prior YAML workload is preserved' {
            $map   = @{ 'kept-rule' = 'Exchange' }
            $entry = [ordered]@{}
            $rh    = @{ name = 'kept-rule'; policy = 'p'; workload = 'Exchange|SharePoint' }
            $warnings = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1

            @($warnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        }

        It 'preserves a multi-workload YAML value byte-for-byte (does not force it to the single default)' {
            # The preservation path must not clobber an operator who
            # deliberately authored a comma-set; only the greenfield emit is
            # forced to a single default.
            $map   = @{ 'kept-rule' = 'Exchange, OneDriveForBusiness' }
            $entry = [ordered]@{}
            $rh    = @{ name = 'kept-rule'; policy = 'p'; workload = 'Exchange|OneDriveForBusiness|SharePoint' }
            $null = & $script:WorkloadEmitBlock -desiredWorkloadByRuleName $map -rh $rh -entry $entry 3>&1
            $entry['workload'] | Should -Be 'Exchange, OneDriveForBusiness'
        }
    }
}

Describe 'Export-scope exclusion — rule/policy skip predicates (ADR 0016 §12)' {

    BeforeAll {
        # AST-extract the two inline export skip predicates by their
        # condition text and evaluate them standalone (no script import,
        # no tenant). The predicates live inside the -ExportCurrentState
        # region, not in a named function, so we locate the specific
        # IfStatementAst nodes by their condition extent text.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $ifAsts = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true)

        $ruleIf = $ifAsts | Where-Object {
            $_.Clauses[0].Item1.Extent.Text -match '@\(\$rh\.ccsi\)\.Count\s*-eq\s*0'
        } | Select-Object -First 1
        if (-not $ruleIf) { throw 'rule-skip predicate (@($rh.ccsi).Count -eq 0) not found in export block' }
        $script:RuleSkipPredicate = [ScriptBlock]::Create(
            'param($rh) ' + $ruleIf.Clauses[0].Item1.Extent.Text)

        $policyIf = $ifAsts | Where-Object {
            $_.Clauses[0].Item1.Extent.Text -match '-not\s+\$representablePolicyNames\.Contains\(\$h\.name\)'
        } | Select-Object -First 1
        if (-not $policyIf) { throw 'policy-skip predicate (-not $representablePolicyNames.Contains($h.name)) not found in export block' }
        $script:PolicySkipPredicate = [ScriptBlock]::Create(
            'param($representablePolicyNames, $h) ' + $policyIf.Clauses[0].Item1.Extent.Text)
    }

    Context 'Rule skip predicate (empty resolved CCSI)' {

        It 'skips a rule whose resolved CCSI is empty (EDM / ML / fingerprint)' {
            (& $script:RuleSkipPredicate -rh @{ ccsi = @() }) | Should -BeTrue
        }

        It 'keeps a rule with a single SIT triplet' {
            (& $script:RuleSkipPredicate -rh @{ ccsi = @('00000000-0000-0000-0000-000000000001|1|75') }) | Should -BeFalse
        }

        It 'keeps a rule with multiple SIT triplets' {
            (& $script:RuleSkipPredicate -rh @{ ccsi = @(
                        '00000000-0000-0000-0000-000000000001|1|75'
                        '00000000-0000-0000-0000-000000000002|2|85'
                    ) }) | Should -BeFalse
        }
    }

    Context 'Policy skip predicate (zero surviving rules)' {

        It 'skips a policy absent from the representable-policy set' {
            $set = New-Object 'System.Collections.Generic.HashSet[string]'
            (& $script:PolicySkipPredicate -representablePolicyNames $set -h @{ name = 'Lab-AutoLabel-EDM' }) | Should -BeTrue
        }

        It 'keeps a policy present in the representable-policy set' {
            $set = New-Object 'System.Collections.Generic.HashSet[string]'
            [void]$set.Add('Lab-AutoLabel-CreditCards')
            (& $script:PolicySkipPredicate -representablePolicyNames $set -h @{ name = 'Lab-AutoLabel-CreditCards' }) | Should -BeFalse
        }

        It 'is case-sensitive on the policy name (matches the tenant readback verbatim)' {
            $set = New-Object 'System.Collections.Generic.HashSet[string]'
            [void]$set.Add('Lab-AutoLabel-CreditCards')
            (& $script:PolicySkipPredicate -representablePolicyNames $set -h @{ name = 'lab-autolabel-creditcards' }) | Should -BeTrue
        }
    }
}

Describe 'Round-trip source-text guards (ADR 0016 §12)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    Context 'Export ordering and skip warnings' {

        It 'builds the rule export list before the policy export list (rules-first skip ordering)' {
            $ruleIdx   = $script:ScriptText.IndexOf('$ruleExport = New-Object')
            $policyIdx = $script:ScriptText.IndexOf('$policyExport = New-Object')
            $ruleIdx   | Should -BeGreaterThan 0
            $policyIdx | Should -BeGreaterThan 0
            $ruleIdx   | Should -BeLessThan $policyIdx
        }

        It 'tracks surviving policy names via a representablePolicyNames HashSet' {
            $script:ScriptText | Should -Match '\$representablePolicyNames\s*=\s*New-Object\s+''System\.Collections\.Generic\.HashSet\[string\]'''
            $script:ScriptText | Should -Match '\[void\]\$representablePolicyNames\.Add\(\$rh\.policy\)'
        }

        It 'warns per skipped non-representable rule' {
            $script:ScriptText | Should -Match 'Skipping non-representable auto-label rule'
        }

        It 'warns per skipped non-representable policy' {
            $script:ScriptText | Should -Match 'Skipping non-representable auto-label policy'
        }
    }

    Context 'Relaxed exchangeLocation input validation' {

        It 'requires the exchangeLocation key present but allows an empty array' {
            $script:ScriptText | Should -Match 'if \(-not \$e\.ContainsKey\(''exchangeLocation''\)\) \{'
        }

        It 'no longer rejects an empty exchangeLocation array in the input guard' {
            $script:ScriptText | Should -Not -Match '-not \$e\.exchangeLocation -or @\(\$e\.exchangeLocation\)\.Count -eq 0'
        }
    }

    Context 'Conditional Create / Update exchangeLocation arguments' {

        It 'includes -ExchangeLocation on Create only when the desired value is non-empty' {
            $script:ScriptText | Should -Match 'if \(@\(\$d\.exchangeLocation\)\.Count -gt 0\) \{'
            $script:ScriptText | Should -Match '\$newArgs\[''ExchangeLocation''\]\s*=\s*\$d\.exchangeLocation'
        }

        It 'no longer hardcodes ExchangeLocation in the Create argument splat' {
            $script:ScriptText | Should -Not -Match 'ExchangeLocation\s+=\s+\$d\.exchangeLocation\s+Mode\s+='
        }

        It 'skips the -ExchangeLocation write on Update when the desired value is empty' {
            $script:ScriptText | Should -Match 'if \(@\(\$d\.exchangeLocation\)\.Count -eq 0\) \{'
            $script:ScriptText | Should -Match 'skipping the -ExchangeLocation write to avoid clearing the tenant scope'
        }
    }
}
Describe 'Prune failure reporting (issue #13, part C)' {

    # WHY THE PRUNE REGION IS EXTRACTED AND EXECUTED
    # ----------------------------------------------
    # The properties under test are behavioural -- "the loop CONTINUES past a
    # failure" and "the aggregate throw fires" -- and source-text assertions
    # cannot distinguish a `continue` that is reached from one that is dead
    # code after an early `return`. The script body cannot be dot-sourced (it
    # loads ExchangeOnlineManagement at import time and would connect to a
    # real tenant), so the `if ($PruneMissing.IsPresent)` region is lifted out
    # of the source by brace matching and executed against stubbed cmdlets.
    #
    # Lifting the REAL source rather than a transcription of it is the point:
    # a transcription would keep passing after the script regressed. If the
    # region is restructured such that the anchor no longer matches, the
    # BeforeAll throws rather than silently testing nothing.
    #
    # Reference: issue #13
    # Reference: scripts/modules/PruneGuard.psm1

    BeforeAll {
        $script:PruneLines = @(Get-Content -LiteralPath $script:ScriptPath)

        # Anchor: the multi-line prune region opener. The other two
        # `$PruneMissing.IsPresent` sites are a compound condition (the ADR
        # 0052 gate) and a single-line write-count bump, so neither matches.
        $startIdx = -1
        for ($i = 0; $i -lt $script:PruneLines.Count; $i++) {
            if ($script:PruneLines[$i] -match '^\s*if \(\$PruneMissing\.IsPresent\) \{\s*$') { $startIdx = $i; break }
        }
        if ($startIdx -lt 0) {
            throw 'Could not locate the -PruneMissing region in Deploy-AutoLabelPolicies.ps1; update the anchor in this test.'
        }

        # Brace-match to the end of the region.
        $depth  = 0
        $endIdx = -1
        for ($i = $startIdx; $i -lt $script:PruneLines.Count; $i++) {
            $line = $script:PruneLines[$i]
            $depth += ([regex]::Matches($line, '\{')).Count
            $depth -= ([regex]::Matches($line, '\}')).Count
            if ($depth -le 0) { $endIdx = $i; break }
        }
        if ($endIdx -lt 0) { throw 'Unbalanced braces while extracting the -PruneMissing region.' }

        $script:PruneRegionSource = ($script:PruneLines[$startIdx..$endIdx] -join [Environment]::NewLine)

        # $PSCmdlet is a typed automatic variable and cannot be assigned a
        # stub, so the ONLY edit made to the lifted source is to redirect the
        # two ShouldProcess calls at an assignable stub object. The count is
        # asserted below so a restructure that drops a gate cannot make this
        # substitution silently vacuous. Everything else -- the loops, the
        # catch blocks, the continues, the aggregate throw -- runs verbatim.
        $script:PruneRegionShouldProcessCount =
            ([regex]::Matches($script:PruneRegionSource, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:PruneRegionRunnable = $script:PruneRegionSource -replace
            '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        # Runs the extracted region with stub cmdlets. -FailRules / -FailPolicies
        # name the objects whose Remove-* should throw, mimicking a tenant
        # delete-blocker (for example LabelIsReferencedByPoliciesException).
        function Invoke-PruneRegion {
            param(
                [string[]]$RuleNames    = @(),
                [string[]]$PolicyNames  = @(),
                [string[]]$FailRules    = @(),
                [string[]]$FailPolicies = @()
            )

            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'

            # Stubs shadow the real cmdlets for the extracted region's scope.
            function Remove-AutoSensitivityLabelRule {
                [CmdletBinding(SupportsShouldProcess)] param([string]$Identity)
                $attempted.Add("rule:$Identity")
                if ($FailRules -contains $Identity) { throw "LabelIsReferencedByPoliciesException: rule $Identity" }
            }
            function Remove-AutoSensitivityLabelPolicy {
                [CmdletBinding(SupportsShouldProcess)] param([string]$Identity)
                $attempted.Add("policy:$Identity")
                if ($FailPolicies -contains $Identity) { throw "LabelIsPublishedException: policy $Identity" }
            }
            # Stands in for the module's reporter so the test can assert that
            # every individual failure was still surfaced with its tenant text.
            function Write-PruneFailure {
                param([Parameter(Position = 0)][string]$Message)
                $reported.Add($Message)
            }

            # These three are read by the extracted region through dynamic
            # scoping, so PSScriptAnalyzer reports them as assigned-but-unused.
            $PruneMissing   = [switch]$true
            $orphanRules    = @($RuleNames   | ForEach-Object { [pscustomobject]@{ Name = $_ } })
            $orphanPolicies = @($PolicyNames | ForEach-Object { [pscustomobject]@{ Name = $_ } })

            # Always-consent ShouldProcess stub: the gate stays wired, but this
            # is a prune-failure test, not a -WhatIf test.
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }

            $thrown = $null
            try {
                & ([scriptblock]::Create($script:PruneRegionRunnable)) 6>$null 3>$null
            }
            catch { $thrown = $_.Exception.Message }

            [pscustomobject]@{
                Attempted = $attempted.ToArray()
                Reported  = $reported.ToArray()
                Thrown    = $thrown
            }
        }
    }

    It 'attempts every remaining rule after one rule fails' {
        $r = Invoke-PruneRegion -RuleNames @('r1', 'r2', 'r3') -FailRules @('r1')
        $r.Attempted | Should -Be @('rule:r1', 'rule:r2', 'rule:r3')
    }

    It 'still attempts the orphan policies after a rule fails' {
        # The regression that motivated part C: a `return` in the rules loop
        # meant no policy was ever attempted, so a whole class of blockers
        # stayed invisible until a later dispatch.
        $r = Invoke-PruneRegion -RuleNames @('r1') -PolicyNames @('p1', 'p2') -FailRules @('r1')
        $r.Attempted | Should -Contain 'policy:p1'
        $r.Attempted | Should -Contain 'policy:p2'
    }

    It 'attempts every remaining policy after one policy fails' {
        $r = Invoke-PruneRegion -PolicyNames @('p1', 'p2', 'p3') -FailPolicies @('p2')
        $r.Attempted | Should -Be @('policy:p1', 'policy:p2', 'policy:p3')
    }

    It 'keeps the rules-before-policies ordering that empties a parent policy first' {
        $r = Invoke-PruneRegion -RuleNames @('r1') -PolicyNames @('p1')
        $r.Attempted | Should -Be @('rule:r1', 'policy:p1')
    }

    It 'reports each individual failure with the tenant error message' {
        $r = Invoke-PruneRegion -RuleNames @('r1') -PolicyNames @('p1') -FailRules @('r1') -FailPolicies @('p1')
        $r.Reported.Count | Should -Be 2
        ($r.Reported -join '; ') | Should -Match 'LabelIsReferencedByPoliciesException'
        ($r.Reported -join '; ') | Should -Match 'LabelIsPublishedException'
    }

    It 'throws one aggregate naming every failure, so the run exits non-zero' {
        $r = Invoke-PruneRegion -RuleNames @('r1', 'r2') -PolicyNames @('p1') -FailRules @('r2') -FailPolicies @('p1')
        $r.Thrown | Should -Not -BeNullOrEmpty
        $r.Thrown | Should -Match 'Reconciliation aborted'
        $r.Thrown | Should -Match "rule 'r2'"
        $r.Thrown | Should -Match "policy 'p1'"
        $r.Thrown | Should -Not -Match "rule 'r1'"
    }

    It 'throws nothing when every prune succeeds' {
        $r = Invoke-PruneRegion -RuleNames @('r1', 'r2') -PolicyNames @('p1')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }

    It 'keeps both prune loops behind their own ShouldProcess gate' {
        # Also proves the ShouldProcess substitution above is not vacuous.
        $script:PruneRegionShouldProcessCount | Should -Be 2
    }

    It 'no longer carries a bare return or a Write-Error in either prune loop' {
        $script:PruneRegionSource | Should -Not -Match '(?m)^\s*return\s*$'
        $script:PruneRegionSource | Should -Not -Match '(?m)^\s*Write-Error'
    }
}
Describe 'Create-rule workload round-trip (issue #20)' {

    # WHY THE CREATE-RULE REGION IS EXTRACTED AND EXECUTED
    # ----------------------------------------------------
    # ConvertTo-TenantRuleHash normalizes a rule's `Workload` to a
    # sorted-unique PIPE-joined string on export (the on-disk drift-comparison
    # contract). New-AutoSensitivityLabelRule -Workload is a multi-valued flags
    # enum that rejects that pipe-joined string, so the apply path must split it
    # back into a `string[]` before the call. The property under test is
    # behavioural -- "the value the cmdlet RECEIVES is a multi-element array,
    # not the raw pipe-joined string" -- so a source-text assertion cannot prove
    # it: only capturing the actual `-Workload` argument a stubbed cmdlet binds
    # can. The script body cannot be dot-sourced (it loads
    # ExchangeOnlineManagement at import time and would connect to a real
    # tenant), so the `'Create' {` switch-case region is lifted out of the
    # source by brace matching and executed against a stub that records the
    # bound `-Workload`.
    #
    # Lifting the REAL source (not a transcription) is the point: this is the
    # mutation guard. Against the pre-fix line (`Workload = $d.workload`) the
    # stub would receive the raw pipe-joined [string] and every array/type
    # assertion below fails; against the fix it receives a trimmed `string[]`.
    #
    # Reference: issue #20
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule

    BeforeAll {
        $script:CreateLines = @(Get-Content -LiteralPath $script:ScriptPath)

        # Anchor: the RULE-plan 'Create' clause. Both the policy-plan and the
        # rule-plan switches carry a `'Create' {` line, so we walk every opener,
        # brace-match its clause, and keep the one whose body actually calls
        # New-AutoSensitivityLabelRule (the rule create).
        $startIdx = -1
        $endIdx   = -1
        for ($i = 0; $i -lt $script:CreateLines.Count; $i++) {
            if ($script:CreateLines[$i] -notmatch "^\s*'Create' \{\s*$") { continue }

            $depth = 0
            $close = -1
            for ($j = $i; $j -lt $script:CreateLines.Count; $j++) {
                $line = $script:CreateLines[$j]
                $depth += ([regex]::Matches($line, '\{')).Count
                $depth -= ([regex]::Matches($line, '\}')).Count
                if ($depth -le 0) { $close = $j; break }
            }
            if ($close -lt 0) { throw 'Unbalanced braces while extracting a Create region.' }

            $body = ($script:CreateLines[$i..$close] -join [Environment]::NewLine)
            if ($body -match 'New-AutoSensitivityLabelRule') {
                $startIdx = $i
                $endIdx   = $close
                break
            }
        }
        if ($startIdx -lt 0 -or $endIdx -lt 0) {
            throw "Could not locate the rule-plan 'Create' region in Deploy-AutoLabelPolicies.ps1; update the anchor in this test."
        }

        # Lift the INNER body of the clause (between the `'Create' {` opener and
        # its matching `}`): the clause itself is switch syntax, not a valid
        # standalone statement, but its body is a plain statement sequence.
        $script:CreateRegionSource = ($script:CreateLines[($startIdx + 1)..($endIdx - 1)] -join [Environment]::NewLine)

        # $PSCmdlet is a typed automatic variable and cannot be assigned a stub,
        # so the ONLY edit made to the lifted source is to redirect the single
        # ShouldProcess call at an assignable stub object. The count is asserted
        # below so a restructure that drops the gate cannot make this
        # substitution silently vacuous. Everything else -- the workload split,
        # the splat, the try/catch -- runs verbatim.
        $script:CreateRegionShouldProcessCount =
            ([regex]::Matches($script:CreateRegionSource, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:CreateRegionRunnable = $script:CreateRegionSource -replace
            '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        # Executes the lifted 'Create' region against a stub that records the
        # `-Workload` value the cmdlet actually binds. -Workload is the raw YAML
        # value under test (the pipe-joined on-disk form).
        function Invoke-CreateRegion {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Workload)

            $script:CapturedWorkload = 'UNSET'

            # Stub shadows the real cmdlet for the extracted region's scope and
            # records the bound -Workload. Typed [string[]] to model the real
            # cmdlet's multi-valued flags-enum parameter: an array binds
            # element-for-element, whereas the pre-fix raw pipe-joined scalar
            # binds as a SINGLE element -- so the multi-workload count assertion
            # below is the mutation guard (3 tokens post-fix vs 1 pre-fix).
            function New-AutoSensitivityLabelRule {
                [CmdletBinding(SupportsShouldProcess)]
                param(
                    [string]$Name,
                    [string]$Policy,
                    [string[]]$Workload,
                    $ContentContainsSensitiveInformation
                )
                $script:CapturedWorkload = $Workload
            }

            # Desired rule hash as the plan builds it: workload is the
            # pipe-joined export form.
            $d = @{
                name     = 'rule-under-test'
                policy   = 'policy-under-test'
                workload = $Workload
            }
            $ccsiArray = @(
                @{ Name = 'Credit Card Number'; id = '00000000-0000-0000-0000-000000000001'; mincount = '1'; minconfidence = '75' }
            )
            $shouldProcessTarget = "Auto-label rule '{0}'" -f $d.name

            # Always-consent ShouldProcess stub: the gate stays wired, but this
            # is not a -WhatIf test.
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }

            & ([scriptblock]::Create($script:CreateRegionRunnable)) 6>$null | Out-Null

            # Unary comma so a one-element or empty captured array survives the
            # pipeline/return unwrap and reaches the caller with its shape intact.
            return , $script:CapturedWorkload
        }
    }

    It 'keeps the ShouldProcess gate wired (substitution is not vacuous)' {
        $script:CreateRegionShouldProcessCount | Should -Be 1
    }

    It 'passes a multi-workload pipe-joined value as a multi-element string array' {
        $captured = Invoke-CreateRegion -Workload 'Applications|Exchange|SharePoint'
        # Mutation guard: pre-fix (`Workload = $d.workload`) this is the raw
        # [string], so -is [array] is False and @().Count is 1 -- both fail.
        ($captured -is [array])   | Should -BeTrue
        @($captured).Count        | Should -Be 3
        ($captured[0] -is [string]) | Should -BeTrue
        $captured[0]              | Should -Be 'Applications'
        $captured[1]              | Should -Be 'Exchange'
        $captured[2]              | Should -Be 'SharePoint'
    }

    It 'binds the multi-workload value as an array, not the raw pipe-joined string' {
        $captured = Invoke-CreateRegion -Workload 'Applications|Exchange|SharePoint'
        # The whole defect: a single pipe-joined scalar reaching the cmdlet.
        ($captured -is [array]) | Should -BeTrue
        foreach ($token in $captured) { $token | Should -Not -Match '\|' }
    }

    It 'passes a single-workload value (no pipe) as a one-element array' {
        $captured = Invoke-CreateRegion -Workload 'Exchange'
        ($captured -is [array]) | Should -BeTrue
        @($captured).Count      | Should -Be 1
        $captured[0]            | Should -Be 'Exchange'
    }

    It 'trims incidental whitespace around each workload token' {
        $captured = Invoke-CreateRegion -Workload ' Applications | Exchange | SharePoint '
        ($captured -is [array]) | Should -BeTrue
        @($captured).Count      | Should -Be 3
        $captured[0]            | Should -Be 'Applications'
        $captured[1]            | Should -Be 'Exchange'
        $captured[2]            | Should -Be 'SharePoint'
    }

    It 'drops empty tokens from a malformed value (leading/trailing/double pipe)' {
        $captured = Invoke-CreateRegion -Workload '|Exchange||SharePoint|'
        @($captured).Count | Should -Be 2
        $captured[0]       | Should -Be 'Exchange'
        $captured[1]       | Should -Be 'SharePoint'
    }

    It 'yields an empty array for an empty workload value' {
        $captured = Invoke-CreateRegion -Workload ''
        ($captured -is [array]) | Should -BeTrue
        @($captured).Count      | Should -Be 0
    }
}
