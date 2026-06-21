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

        It 'falls back to the tenant workload for rules new to the tenant' {
            $script:ScriptText | Should -Match "else\s*\{\s*\r?\n\s*\`$entry\['workload'\]\s*=\s*\`$rh\.workload"
        }
    }
}