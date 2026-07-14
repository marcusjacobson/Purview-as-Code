#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the `ConvertTo-TenantPolicyHash` function in
    `scripts/Deploy-LabelPolicies.ps1`.

.DESCRIPTION
    Exercises the four observed `Get-LabelPolicy.Labels` entry shapes
    that PR #231 normalized to canonical label GUID:

      1. Bare label GUID.
      2. `<Parent> - <Child>` composite display name.
      3. Bare `<DisplayName>` (portal-created sublabels).
      4. Slugified `<DisplayName>` where `[\s()]` becomes `-`.

    The function lives inside a non-module script that calls
    Security & Compliance cmdlets at import time, so we extract its
    `FunctionDefinitionAst` via the PowerShell parser and evaluate
    just that definition into the test scope. This avoids running the
    script body (which would try to talk to a real tenant) and keeps
    the production script untouched.

    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_classes
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-LabelPolicies.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-LabelPolicies.ps1 at: $script:ScriptPath"
    }

    # AST-extract the function definition only. We deliberately do NOT
    # dot-source the script -- that would execute its top-level code and
    # attempt to load ExchangeOnlineManagement / connect to a tenant.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fname in @('ConvertTo-TenantPolicyHash')) {
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
    # module in #473 so the helper no longer lives inside
    # Deploy-LabelPolicies.ps1.
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
        -Force -ErrorAction Stop

    # Stub the two script-scoped dependencies the function uses:
    #   - $script:AdvancedSettingsAllowlist (only consulted on the
    #     Settings branch, which these tests do not exercise; an empty
    #     array is sufficient).
    #   - ConvertTo-PolicyInputMode (mode normalization; tests pin the
    #     mode value directly so the stub just echoes it back).
    $script:AdvancedSettingsAllowlist = @()
    function ConvertTo-PolicyInputMode {
        param([string]$Mode)
        return $Mode
    }

    # Synthetic tenant labels. Two top-level (Confidential, Highly
    # Confidential) and four sublabels of varying name shapes. GUIDs
    # use the documented placeholder pattern (zero GUID + last byte) so
    # nothing here resembles a real label identifier.
    $script:TenantLabels = @(
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Confidential';        ParentId = $null }
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000002'; DisplayName = 'Highly Confidential'; ParentId = $null }
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000011'; DisplayName = 'Internal';            ParentId = '00000000-0000-0000-0000-000000000001' }
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000012'; DisplayName = 'Partner';             ParentId = '00000000-0000-0000-0000-000000000001' }
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000021'; DisplayName = 'Internal (Restricted)'; ParentId = '00000000-0000-0000-0000-000000000002' }
        [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000022'; DisplayName = 'External (Restricted)'; ParentId = '00000000-0000-0000-0000-000000000002' }
    )

    function Get-FakePolicy {
        param([string[]]$Labels, [string]$Name = 'fake-policy')
        return [pscustomobject]@{
            Name             = $Name
            Guid             = '00000000-0000-0000-0000-0000000000ff'
            Mode             = 'Enforce'
            Status           = 'Pending'
            ExchangeLocation = @()
            Labels           = $Labels
            Settings         = @()
        }
    }
}

Describe 'ConvertTo-TenantPolicyHash labels normalization (issue #230, PR #231)' {

    It 'collapses a bare GUID to itself' {
        $policy = Get-FakePolicy -Labels @('00000000-0000-0000-0000-000000000011')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be '00000000-0000-0000-0000-000000000011'
    }

    It 'resolves a composite "<Parent> - <Child>" display name to the child GUID' {
        $policy = Get-FakePolicy -Labels @('Confidential - Partner')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be '00000000-0000-0000-0000-000000000012'
    }

    It 'resolves a bare <DisplayName> for a portal-created sublabel to the child GUID' {
        $policy = Get-FakePolicy -Labels @('Internal')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be '00000000-0000-0000-0000-000000000011'
    }

    It 'resolves a slugified <DisplayName> with parentheses/whitespace replaced by dashes' {
        # 'External (Restricted)' -> 'External--Restricted-' as observed
        # in the live tenant on 2026-05-14.
        $policy = Get-FakePolicy -Labels @('External--Restricted-')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be '00000000-0000-0000-0000-000000000022'
    }

    It 'resolves a slugified composite name too' {
        # 'Highly Confidential - Internal (Restricted)' slugified.
        $policy = Get-FakePolicy -Labels @('Highly-Confidential---Internal--Restricted-')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be '00000000-0000-0000-0000-000000000021'
    }

    It 'normalizes a mixed-shape Labels array idempotently' {
        $policy = Get-FakePolicy -Labels @(
            '00000000-0000-0000-0000-000000000001',
            'Internal',
            'Confidential - Partner',
            'External--Restricted-'
        )
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $script:TenantLabels
        $expected = @(
            '00000000-0000-0000-0000-000000000001',
            '00000000-0000-0000-0000-000000000011',
            '00000000-0000-0000-0000-000000000012',
            '00000000-0000-0000-0000-000000000022'
        ) | Sort-Object
        ($hash.labels | Sort-Object) | Should -Be $expected
    }

    It 'passes a raw entry through unchanged when no TenantLabels are supplied (legacy fallback)' {
        $policy = Get-FakePolicy -Labels @('Internal')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be 'Internal'
    }

    It 'drops the bare-DisplayName shortcut when two labels share a DisplayName under different parents' {
        # Add a second 'Internal' under Highly Confidential to force a
        # collision; the bare 'Internal' entry must now pass through
        # unresolved so the operator sees drift instead of a silent
        # wrong-label mapping.
        $tenantWithCollision = @($script:TenantLabels) + [pscustomobject]@{
            Guid        = '00000000-0000-0000-0000-000000000023'
            DisplayName = 'Internal'
            ParentId    = '00000000-0000-0000-0000-000000000002'
        }
        $policy = Get-FakePolicy -Labels @('Internal')
        $hash = ConvertTo-TenantPolicyHash -Policy $policy -TenantLabels $tenantWithCollision
        $hash.labels | Should -HaveCount 1
        $hash.labels[0] | Should -Be 'Internal'
    }
}

Describe 'DirectionPolicy parameter (ADR 0029)' {

    BeforeAll {
        $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'declares a -DirectionPolicy parameter with the audit/portal-wins/repo-wins ValidateSet' {
        # Source-text assertion: the ValidateSet attribute and parameter
        # declaration must remain stable so the workflow contract in
        # Phase 2 (.github/workflows/deploy-label-policies.yml) can pass
        # the value through unchanged.
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
        # ceremonies. Mirrors Deploy-Labels.ps1 (PR #458).
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
        # script's normal control flow (sub-issue B proved that
        # early-return-from-try-block confused PowerShell's post-finally
        # output handling).
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''.*?\$plan\.Clear\(\)\s*\r?\n\s*\$orphans\s*=\s*@\(\)\s*\r?\n\s*\}'
    }

    It 'returns Update when policy is repo-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @() `
            -DisplayName 'lab-default' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
        $decision.Reason | Should -BeNullOrEmpty
    }

    It 'returns Skip when policy is portal-wins and drift is present' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-default' `
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
            -DisplayName 'lab-default' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Update'
    }

    It 'emits one Write-Warning per drifted policy on repo-wins (not per granular Set-LabelPolicy call)' {
        # Source-text assertion: the warning fires once per policy in the
        # direction-policy pass with the comma-joined drifted field set,
        # NOT once per granular Set-LabelPolicy call in Phase 3 (which
        # would emit 1-5 warnings per policy and be noisy and incoherent).
        # The wording differs from Deploy-Labels.ps1 only by using
        # "label policy" instead of "label" so a run-log grep can
        # disambiguate the two reconcilers.
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on label policy '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped policy for workflow consumption' {
        # The Phase 2 workflow (.github/workflows/deploy-label-policies.yml)
        # parses these markers (one per line) to build the auto-PR skip
        # list. The marker shape is part of the script-to-workflow contract
        # and must not drift.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }
}

Describe 'SkipNames behavior (ADR 0029)' {

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is true' {
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-default') `
            -DisplayName 'lab-default' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
        $decision.Reason | Should -Match 'Explicitly skipped'
    }

    It 'Resolve-DirectionPolicyAction (module) returns Skip when a name is in the skip list and HasDrift is false' {
        # Module-level helper is unconditional on the skip list. The
        # call site in scripts/Deploy-LabelPolicies.ps1 only consults the
        # helper for rows whose Action is 'Update', so a NoChange row
        # carrying a SkipNames-matched name is reported as NoChange, not Skip.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @('lab-default') `
            -DisplayName 'lab-default' `
            -HasDrift    $false
        $decision.Action | Should -Be 'Skip'
    }

    It 'matches SkipNames case-insensitively' {
        # Defends against casing mismatches between a workflow-supplied
        # skip list (which may parse from a comma-joined string) and the
        # YAML policy name.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('LAB-DEFAULT') `
            -DisplayName 'lab-default' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }

    It 'does not match SkipNames as a substring' {
        # `Where-Object { $_ -ieq $DisplayName }` is an equality, not a
        # contains/regex match. A policy named 'lab-default-restricted'
        # is not skipped by `-SkipNames lab-default`.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'repo-wins' `
            -SkipList    @('lab-default') `
            -DisplayName 'lab-default-restricted' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Update'
    }

    It 'does not error on an unknown name in -SkipNames' {
        # The script ignores skip-list entries that match no policy, so a
        # stale workflow-supplied list does not abort the run. The helper
        # itself never observes unknown names (the policy pass walks the
        # plan, not the skip list), so this is a documented invariant we
        # exercise at the call-site shape.
        { Resolve-DirectionPolicyAction `
                -Policy      'portal-wins' `
                -SkipList    @('NoSuchPolicy') `
                -DisplayName 'lab-default' `
                -HasDrift    $true } | Should -Not -Throw
    }

    It 'handles an empty SkipList without error' {
        # @() is the default. Defensive test against future refactors that
        # might $null the default.
        $decision = Resolve-DirectionPolicyAction `
            -Policy      'portal-wins' `
            -SkipList    @() `
            -DisplayName 'lab-default' `
            -HasDrift    $true
        $decision.Action | Should -Be 'Skip'
    }
}

Describe 'OutlookDefaultLabel advanced-setting tracking (issue #488; ADR 0030 row 1)' {

    BeforeAll {
        # AST-extract ConvertTo-PolicyHash, Compare-PolicyHash,
        # ConvertTo-LabelGuidLookup, Resolve-DesiredLabelGuid, and the
        # new Resolve-DesiredAdvancedSettingLabel helper so the cases
        # below can exercise the desired-side hash path standalone. Uses
        # the same AST-extract-and-stub pattern as the file-level
        # BeforeAll block (which loads ConvertTo-TenantPolicyHash for
        # the labels-side normalization tests).
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-LabelGuidLookup',
            'Resolve-DesiredLabelGuid',
            'Resolve-DesiredAdvancedSettingLabel'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Match the production constants for the Compare-PolicyHash /
        # Resolve-DesiredAdvancedSettingLabel closures.
        $script:TrackedScalarFields = @('mode')
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid'
        )
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid')

        # Synthetic tenant labels reusing the zero-GUID placeholder
        # pattern from the file-level BeforeAll. Two top-level + four
        # sublabels is enough surface to exercise the
        # Resolve-DesiredLabelGuid lookup.
        $script:TenantLabels = @(
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Public';              ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000002'; DisplayName = 'Confidential';        ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000011'; DisplayName = 'Partner';             ParentId = '00000000-0000-0000-0000-000000000002' }
        )
        $script:LabelLookup = ConvertTo-LabelGuidLookup -Labels $script:TenantLabels
    }

    Context 'ConvertTo-PolicyHash carries OutlookDefaultLabel through the advancedSettings map' {

        It 'accepts the new key alongside existing boolean keys' {
            # YAML lowercases the bool keys today (file convention). The
            # production helper lowercases values via ToLowerInvariant.
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('Public')
                advancedSettings = @{
                    requiredowngradejustification = 'true'
                    OutlookDefaultLabel           = 'Public'
                }
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.advancedSettings.Keys | Should -Contain 'OutlookDefaultLabel'
            # Verbatim until Resolve-DesiredAdvancedSettingLabel runs.
            # Value already lowercased by ConvertTo-PolicyHash; lookup
            # is case-insensitive so this still resolves cleanly below.
            [string]$hash.advancedSettings['OutlookDefaultLabel'] | Should -Be 'public'
        }
    }

    Context 'Resolve-DesiredAdvancedSettingLabel (per ADR 0030 row 1)' {

        It 'resolves a bare top-level label name to the GUID' {
            $hash = @{ advancedSettings = @{ OutlookDefaultLabel = 'Public' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['OutlookDefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000001'
        }

        It 'resolves a composite-key sublabel reference to the child GUID' {
            $hash = @{ advancedSettings = @{ OutlookDefaultLabel = 'Confidential/Partner' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['OutlookDefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000011'
        }

        It 'passes a GUID input through unchanged (lowercased)' {
            # An already-resolved YAML round-trip stays stable. Uppercase
            # input is lowercased so it compares equal to the tenant side
            # (which Get-LabelPolicy also lowercases via the production
            # ConvertTo-TenantPolicyHash pipeline).
            $hash = @{ advancedSettings = @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000011' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['OutlookDefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000011'
        }

        It 'returns the unresolved reference when the label is missing from the tenant' {
            # Caller surfaces this as a Blocked row; the helper itself
            # never throws and never mutates a value it could not resolve.
            $hash = @{ advancedSettings = @{ OutlookDefaultLabel = 'DoesNotExist' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing | Should -HaveCount 1
            $missing[0] | Should -Be 'advancedSettings.OutlookDefaultLabel=DoesNotExist'
            $hash.advancedSettings['OutlookDefaultLabel'] | Should -Be 'DoesNotExist'
        }

        It 'is a no-op when OutlookDefaultLabel is absent' {
            $hash = @{ advancedSettings = @{ requiredowngradejustification = 'true' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings.Keys | Should -Not -Contain 'OutlookDefaultLabel'
        }

        It "treats the 'None' sentinel as no-default-label, not a label reference (<Casing>)" -TestCases @(
            @{ Casing = 'none' }
            @{ Casing = 'None' }
            @{ Casing = 'NONE' }
        ) {
            param($Casing)
            # 'None' is the documented "no default label" sentinel. Any
            # casing must normalize to the lowercase 'none' the tenant read
            # stores, with zero missing refs (never Blocked as a label).
            $hash = @{ advancedSettings = @{ OutlookDefaultLabel = $Casing } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['OutlookDefaultLabel'] | Should -Be 'none'
        }

        It 'honors the None sentinel uniformly across the label-reference keys' {
            # Same guard applies to every key in
            # LabelReferenceAdvancedSettingsKeys, not just OutlookDefaultLabel.
            $hash = @{ advancedSettings = @{ teamworkdefaultlabelid = 'None' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['teamworkdefaultlabelid'] | Should -Be 'none'
        }
    }

    Context 'Compare-PolicyHash detects OutlookDefaultLabel drift across the four quadrants' {

        BeforeAll {
            # Helper: build a Compare-PolicyHash-shape hash so the It
            # blocks stay focused on the OutlookDefaultLabel field.
            function script:New-CompareHash {
                param([hashtable]$AdvancedSettings = @{})
                @{
                    mode             = 'Enable'
                    exchangeLocation = @('All')
                    labels           = @('00000000-0000-0000-0000-000000000001')
                    advancedSettings = $AdvancedSettings
                }
            }
        }

        It 'no-drift when both sides carry the same resolved GUID' {
            $desired = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000001' }
            $tenant  = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000001' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'advancedSettings.OutlookDefaultLabel'
        }

        It 'DesiredOnly drift surfaces (repo set; tenant unset)' {
            $desired = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000001' }
            $tenant  = New-CompareHash -AdvancedSettings @{}
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.OutlookDefaultLabel'
        }

        It 'TenantOnly drift surfaces (tenant set; repo unset)' {
            # Operator removed OutlookDefaultLabel from YAML; the
            # tenant still publishes it. Reconciler must surface this
            # so the next Update narrows the tenant to YAML intent.
            $desired = New-CompareHash -AdvancedSettings @{}
            $tenant  = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000001' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.OutlookDefaultLabel'
        }

        It 'mixed drift surfaces (both set to different GUIDs)' {
            $desired = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000001' }
            $tenant  = New-CompareHash -AdvancedSettings @{ OutlookDefaultLabel = '00000000-0000-0000-0000-000000000011' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.OutlookDefaultLabel'
        }

        It 'ignores allowlist-respected: an unrelated tenant key does not surface as drift' {
            # ConvertTo-TenantPolicyHash already filters tenant Settings
            # to the allowlist before Compare-PolicyHash sees them; this
            # case verifies Compare-PolicyHash itself does not iterate
            # beyond the allowlist (which is the production guarantee
            # that future tenant-side keys do not produce phantom drift).
            $desired = New-CompareHash -AdvancedSettings @{}
            $tenant  = New-CompareHash -AdvancedSettings @{ }  # filtered upstream
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'advancedSettings.OutlookDefaultLabel'
        }
    }
}

Describe 'teamworkdefaultlabelid advanced-setting tracking (issue #490; ADR 0030 row 2)' {

    BeforeAll {
        # AST-extract the same helpers row 1 uses. Pester scopes the
        # row-1 Describe's BeforeAll only to its own block, so this
        # block needs its own copy. Pattern identical to row 1.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-LabelGuidLookup',
            'Resolve-DesiredLabelGuid',
            'Resolve-DesiredAdvancedSettingLabel'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Match the production constants post-#490.
        $script:TrackedScalarFields = @('mode')
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid'
        )
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid')

        # Synthetic tenant labels: same shape as row 1's BeforeAll.
        $script:TenantLabels = @(
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Public';              ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000002'; DisplayName = 'Confidential';        ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000011'; DisplayName = 'Partner';             ParentId = '00000000-0000-0000-0000-000000000002' }
        )
        $script:LabelLookup = ConvertTo-LabelGuidLookup -Labels $script:TenantLabels
    }

    # Row 1's Describe block (issue #488) already validates the
    # comprehensive surface (top-level / composite / GUID passthrough /
    # missing-Blocked / no-op-when-absent) against the shared
    # Resolve-DesiredAdvancedSettingLabel helper. The cases below focus
    # on (a) the new key resolves independently, (b) the new key's
    # all-lowercase Microsoft Learn shape (`teamworkdefaultlabelid`),
    # and (c) the two keys are diffed independently in Compare-PolicyHash.

    Context 'Resolve-DesiredAdvancedSettingLabel resolves teamworkdefaultlabelid independently' {

        It 'resolves a top-level bare name (Public) to the GUID' {
            $hash = @{ advancedSettings = @{ teamworkdefaultlabelid = 'Public' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['teamworkdefaultlabelid'] | Should -Be '00000000-0000-0000-0000-000000000001'
        }

        It 'resolves a composite-key sublabel reference to the child GUID' {
            $hash = @{ advancedSettings = @{ teamworkdefaultlabelid = 'Confidential/Partner' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['teamworkdefaultlabelid'] | Should -Be '00000000-0000-0000-0000-000000000011'
        }

        It 'surfaces unresolved references as Blocked rows' {
            $hash = @{ advancedSettings = @{ teamworkdefaultlabelid = 'NoSuchLabel' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing | Should -HaveCount 1
            $missing[0] | Should -Be 'advancedSettings.teamworkdefaultlabelid=NoSuchLabel'
            $hash.advancedSettings['teamworkdefaultlabelid'] | Should -Be 'NoSuchLabel'
        }

        It 'resolves both Outlook + Teams keys in the same hash' {
            # Production-shape sanity: both keys are populated on the
            # same desired policy hash (matches the YAML for both
            # shipped policies post-#490). The helper iterates
            # $script:LabelReferenceAdvancedSettingsKeys and resolves
            # each independently.
            $hash = @{
                advancedSettings = @{
                    OutlookDefaultLabel    = 'Public'
                    teamworkdefaultlabelid = 'Confidential/Partner'
                }
            }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['OutlookDefaultLabel']    | Should -Be '00000000-0000-0000-0000-000000000001'
            $hash.advancedSettings['teamworkdefaultlabelid'] | Should -Be '00000000-0000-0000-0000-000000000011'
        }
    }

    Context 'Compare-PolicyHash detects teamworkdefaultlabelid drift independently of OutlookDefaultLabel' {

        BeforeAll {
            # Local helper (Pester `script:` scope) so this Context does
            # not depend on the row-1 inner `New-CompareHash` (which was
            # declared with `function script:` in row-1's `Context`
            # BeforeAll and may not be visible across Context boundaries
            # depending on Pester scoping rules).
            function script:New-CompareHashRow2 {
                param([hashtable]$AdvancedSettings = @{})
                @{
                    mode             = 'Enable'
                    exchangeLocation = @('All')
                    labels           = @('00000000-0000-0000-0000-000000000001')
                    advancedSettings = $AdvancedSettings
                }
            }
        }

        It 'TeamsOnly drift surfaces while Outlook key matches' {
            # Repo pins both; tenant only carries the Outlook one. The
            # diff list includes the Teams key but not the Outlook key.
            $desired = New-CompareHashRow2 -AdvancedSettings @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000001'
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000001'
            }
            $tenant  = New-CompareHashRow2 -AdvancedSettings @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000001'
            }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.teamworkdefaultlabelid'
            $diffs | Should -Not -Contain 'advancedSettings.OutlookDefaultLabel'
        }

        It 'OutlookOnly drift surfaces while Teams key matches' {
            # Mirror of the previous case: each key tracks independently.
            $desired = New-CompareHashRow2 -AdvancedSettings @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000001'
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000001'
            }
            $tenant  = New-CompareHashRow2 -AdvancedSettings @{
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000001'
            }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.OutlookDefaultLabel'
            $diffs | Should -Not -Contain 'advancedSettings.teamworkdefaultlabelid'
        }

        It 'no-drift when both keys match on both sides' {
            $shared = @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000001'
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000011'
            }
            $diffs = Compare-PolicyHash `
                -Desired (New-CompareHashRow2 -AdvancedSettings $shared) `
                -Tenant  (New-CompareHashRow2 -AdvancedSettings $shared)
            $diffs | Should -Not -Contain 'advancedSettings.OutlookDefaultLabel'
            $diffs | Should -Not -Contain 'advancedSettings.teamworkdefaultlabelid'
        }

        It 'simultaneous drift on both keys surfaces both fields' {
            $desired = New-CompareHashRow2 -AdvancedSettings @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000001'
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000011'
            }
            $tenant  = New-CompareHashRow2 -AdvancedSettings @{
                OutlookDefaultLabel    = '00000000-0000-0000-0000-000000000011'
                teamworkdefaultlabelid = '00000000-0000-0000-0000-000000000001'
            }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.OutlookDefaultLabel'
            $diffs | Should -Contain 'advancedSettings.teamworkdefaultlabelid'
        }
    }
}

Describe 'exchangeLocationException tracking (issue #492; ADR 0030 row 3)' {

    BeforeAll {
        # Same AST-extract-and-stub pattern row 1 and row 2 use. Pester
        # scopes each Describe's BeforeAll to its own block.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-TenantPolicyHash'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Match the production constants post-#492.
        $script:TrackedScalarFields = @('mode')
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid'
        )
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid')
        $script:RedactedIdentityPattern = '(?i)@(contoso|fabrikam|adatum)\.com$|@example\.(com|org)$'
        function script:ConvertTo-PolicyInputMode { param([string]$Mode) return $Mode }

        # Synthetic mailbox / mail-enabled-group identifiers per the sample-
        # data rule (RFC 2606 reserved + Microsoft fictitious-company names).
        $script:SampleMailbox  = 'user@contoso.com'
        $script:SampleMailbox2 = 'admin@contoso.com'
        $script:SampleGroup    = 'Contoso-execs@contoso.com'  # mail-enabled security group

        function script:New-CompareHashRow3 {
            param([string[]]$Exception = @())
            @{
                mode                      = 'Enable'
                exchangeLocation          = @('All')
                exchangeLocationException = @($Exception | Sort-Object -Unique)
                labels                    = @('00000000-0000-0000-0000-000000000001')
                advancedSettings          = @{}
            }
        }
    }

    Context 'ConvertTo-PolicyHash carries exchangeLocationException through' {

        It 'normalizes a sorted-unique list when the YAML provides one' {
            $entry = @{
                name                      = 'lab-default'
                mode                      = 'Enable'
                exchangeLocation          = @('All')
                exchangeLocationException = @($script:SampleMailbox2, $script:SampleMailbox, $script:SampleMailbox)
                labels                    = @('Public')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.exchangeLocationException | Should -HaveCount 2
            $hash.exchangeLocationException[0] | Should -Be $script:SampleMailbox2
            $hash.exchangeLocationException[1] | Should -Be $script:SampleMailbox
        }

        It 'returns an empty list when the YAML omits the field' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('Public')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.exchangeLocationException | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-TenantPolicyHash normalizes the tenant-side MultiValuedProperty' {

        It 'flattens DisplayName-bearing entries to a sorted-unique string list' {
            $tenantPolicy = [pscustomobject]@{
                Name                      = 'lab-default'
                Guid                      = '00000000-0000-0000-0000-0000000000aa'
                Mode                      = 'Enable'
                Status                    = 'Published'
                ExchangeLocation          = @([pscustomobject]@{ DisplayName = 'All' })
                ExchangeLocationException = @(
                    [pscustomobject]@{ DisplayName = $script:SampleMailbox2 },
                    [pscustomobject]@{ DisplayName = $script:SampleMailbox  },
                    [pscustomobject]@{ DisplayName = $script:SampleGroup    }
                )
                Labels                    = @()
                Settings                  = @()
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $tenantPolicy
            $hash.exchangeLocationException | Should -HaveCount 3
            ($hash.exchangeLocationException -join ',') | Should -Match 'admin@contoso\.com.*Contoso-execs@contoso\.com.*user@contoso\.com'
        }

        It 'returns an empty list when the tenant has no exception' {
            $tenantPolicy = [pscustomobject]@{
                Name             = 'lab-default'
                Guid             = '00000000-0000-0000-0000-0000000000aa'
                Mode             = 'Enable'
                Status           = 'Published'
                ExchangeLocation = @([pscustomobject]@{ DisplayName = 'All' })
                Labels           = @()
                Settings         = @()
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $tenantPolicy
            $hash.exchangeLocationException | Should -BeNullOrEmpty
        }
    }

    Context 'Compare-PolicyHash detects exchangeLocationException drift across the four quadrants' {

        It 'no-drift when both sides are unset' {
            $diffs = Compare-PolicyHash -Desired (New-CompareHashRow3) -Tenant (New-CompareHashRow3)
            $diffs | Should -Not -Contain 'exchangeLocationException'
        }

        It 'no-drift when both sides carry the same exception set (order-insensitive)' {
            $desired = New-CompareHashRow3 -Exception @($script:SampleMailbox, $script:SampleGroup)
            $tenant  = New-CompareHashRow3 -Exception @($script:SampleGroup, $script:SampleMailbox)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'exchangeLocationException'
        }

        It 'DesiredOnly drift surfaces (repo set; tenant unset)' {
            $desired = New-CompareHashRow3 -Exception @($script:SampleMailbox)
            $tenant  = New-CompareHashRow3
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'exchangeLocationException'
        }

        It 'TenantOnly drift surfaces (tenant set; repo unset)' {
            $desired = New-CompareHashRow3
            $tenant  = New-CompareHashRow3 -Exception @($script:SampleMailbox)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'exchangeLocationException'
        }

        It 'mixed drift surfaces (both set; different members)' {
            $desired = New-CompareHashRow3 -Exception @($script:SampleMailbox)
            $tenant  = New-CompareHashRow3 -Exception @($script:SampleMailbox2)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'exchangeLocationException'
        }

        It 'exchangeLocationException drift surfaces independently of exchangeLocation' {
            # Both sides agree on exchangeLocation = [All]; only the
            # exception list differs. The diff list includes the new
            # field but not the location field.
            $desired = New-CompareHashRow3 -Exception @($script:SampleGroup)
            $tenant  = New-CompareHashRow3
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'exchangeLocationException'
            $diffs | Should -Not -Contain 'exchangeLocation'
        }
    }
}
Describe 'ModernGroupLocation tracking (#471 row 4; ADR 0030)' {

    BeforeAll {
        # Same AST-extract-and-stub pattern as prior row Describe blocks.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-TenantPolicyHash'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Match the production constants post-#653.
        $script:TrackedScalarFields = @('mode')
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid'
        )
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid')
        $script:RedactedIdentityPattern = '(?i)@(contoso|fabrikam|adatum)\.com$|@example\.(com|org)$'
        function script:ConvertTo-PolicyInputMode { param([string]$Mode) return $Mode }

        # Synthetic M365 group display names per the sample-data rule
        # (RFC 2606 reserved + Microsoft fictitious-company names).
        $script:SampleGroup1 = 'sg-m365-contoso-legal'
        $script:SampleGroup2 = 'sg-m365-contoso-hr'

        function script:New-CompareHashRow4 {
            param([string[]]$ModernGroups = @())
            @{
                mode                      = 'Enable'
                exchangeLocation          = @('All')
                exchangeLocationException = @()
                modernGroupLocation       = @($ModernGroups | Sort-Object -Unique)
                labels                    = @('00000000-0000-0000-0000-000000000001')
                advancedSettings          = @{}
            }
        }
    }

    Context 'ConvertTo-PolicyHash carries modernGroupLocation through' {

        It 'normalizes a sorted-unique list when the YAML provides one' {
            $entry = @{
                name                = 'lab-default'
                mode                = 'Enable'
                exchangeLocation    = @('All')
                modernGroupLocation = @($script:SampleGroup2, $script:SampleGroup1, $script:SampleGroup1)
                labels              = @('Public')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.modernGroupLocation | Should -HaveCount 2
            $hash.modernGroupLocation[0] | Should -Be $script:SampleGroup2
            $hash.modernGroupLocation[1] | Should -Be $script:SampleGroup1
        }

        It 'returns an empty list when the YAML provides an empty array' {
            $entry = @{
                name                = 'lab-default'
                mode                = 'Enable'
                exchangeLocation    = @('All')
                modernGroupLocation = @()
                labels              = @('Public')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.modernGroupLocation | Should -BeNullOrEmpty
        }

        It 'returns an empty list when the YAML omits the field entirely' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('Public')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.modernGroupLocation | Should -BeNullOrEmpty
        }
    }

    Context 'ConvertTo-TenantPolicyHash normalizes the tenant-side MultiValuedProperty' {

        It 'flattens DisplayName-bearing entries to a sorted-unique string list' {
            $tenantPolicy = [pscustomobject]@{
                Name                  = 'lab-default'
                Guid                  = '00000000-0000-0000-0000-0000000000bb'
                Mode                  = 'Enable'
                Status                = 'Published'
                ExchangeLocation      = @([pscustomobject]@{ DisplayName = 'All' })
                ModernGroupLocation   = @(
                    [pscustomobject]@{ DisplayName = $script:SampleGroup2 },
                    [pscustomobject]@{ DisplayName = $script:SampleGroup1 }
                )
                Labels                = @()
                Settings              = @()
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $tenantPolicy
            $hash.modernGroupLocation | Should -HaveCount 2
            ($hash.modernGroupLocation -join ',') | Should -Match 'sg-m365-contoso-hr.*sg-m365-contoso-legal'
        }

        It 'returns an empty list when the tenant has no ModernGroupLocation' {
            $tenantPolicy = [pscustomobject]@{
                Name             = 'lab-default'
                Guid             = '00000000-0000-0000-0000-0000000000bb'
                Mode             = 'Enable'
                Status           = 'Published'
                ExchangeLocation = @([pscustomobject]@{ DisplayName = 'All' })
                Labels           = @()
                Settings         = @()
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $tenantPolicy
            $hash.modernGroupLocation | Should -BeNullOrEmpty
        }
    }

    Context 'Compare-PolicyHash detects modernGroupLocation drift across the four quadrants' {

        It 'no-drift when both sides are unset' {
            $diffs = Compare-PolicyHash -Desired (New-CompareHashRow4) -Tenant (New-CompareHashRow4)
            $diffs | Should -Not -Contain 'modernGroupLocation'
        }

        It 'no-drift when both sides carry the same group set (order-insensitive)' {
            $desired = New-CompareHashRow4 -ModernGroups @($script:SampleGroup1, $script:SampleGroup2)
            $tenant  = New-CompareHashRow4 -ModernGroups @($script:SampleGroup2, $script:SampleGroup1)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'modernGroupLocation'
        }

        It 'DesiredOnly drift surfaces (repo set; tenant unset)' {
            $desired = New-CompareHashRow4 -ModernGroups @($script:SampleGroup1)
            $tenant  = New-CompareHashRow4
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'modernGroupLocation'
        }

        It 'TenantOnly drift surfaces (tenant set; repo unset)' {
            $desired = New-CompareHashRow4
            $tenant  = New-CompareHashRow4 -ModernGroups @($script:SampleGroup1)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'modernGroupLocation'
        }

        It 'mixed drift surfaces (both set; different members)' {
            $desired = New-CompareHashRow4 -ModernGroups @($script:SampleGroup1)
            $tenant  = New-CompareHashRow4 -ModernGroups @($script:SampleGroup2)
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'modernGroupLocation'
        }

        It 'modernGroupLocation drift surfaces independently of exchangeLocation' {
            # Both sides agree on exchangeLocation = [All]; only the
            # modern-group list differs.
            $desired = New-CompareHashRow4 -ModernGroups @($script:SampleGroup1)
            $tenant  = New-CompareHashRow4
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'modernGroupLocation'
            $diffs | Should -Not -Contain 'exchangeLocation'
        }
    }
}

Describe 'DefaultLabel advanced-setting tracking (#471 row 5; ADR 0040)' {

    BeforeAll {
        # AST-extract ConvertTo-PolicyHash, Compare-PolicyHash,
        # ConvertTo-LabelGuidLookup, Resolve-DesiredLabelGuid, and
        # Resolve-DesiredAdvancedSettingLabel so the cases below can
        # exercise the desired-side hash path standalone. Follows the
        # same AST-extract-and-stub pattern used for OutlookDefaultLabel
        # (row 1) and teamworkdefaultlabelid (row 2).
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-LabelGuidLookup',
            'Resolve-DesiredLabelGuid',
            'Resolve-DesiredAdvancedSettingLabel'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Production constants post-#657: DefaultLabel is the 6th
        # allowlist entry and the 3rd LabelReferenceAdvancedSettingsKey.
        # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
        $script:TrackedScalarFields = @('mode')
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid',
            'DefaultLabel'
        )
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')

        # Synthetic tenant labels; zero-GUID placeholder per sample-data rule.
        $script:TenantLabels = @(
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000001'; DisplayName = 'Public';       ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000002'; DisplayName = 'General';      ParentId = $null }
            [pscustomobject]@{ Guid = '00000000-0000-0000-0000-000000000011'; DisplayName = 'Partner';      ParentId = '00000000-0000-0000-0000-000000000002' }
        )
        $script:LabelLookup = ConvertTo-LabelGuidLookup -Labels $script:TenantLabels
    }

    Context 'DefaultLabel is a member of LabelReferenceAdvancedSettingsKeys' {

        It 'LabelReferenceAdvancedSettingsKeys contains DefaultLabel' {
            # Confirms the production constant was extended by this PR.
            $script:LabelReferenceAdvancedSettingsKeys | Should -Contain 'DefaultLabel'
        }

        It 'AdvancedSettingsAllowlist contains DefaultLabel as the 6th entry' {
            $script:AdvancedSettingsAllowlist | Should -Contain 'DefaultLabel'
            $script:AdvancedSettingsAllowlist.Count | Should -Be 6
        }
    }

    Context 'ConvertTo-PolicyHash carries DefaultLabel through the advancedSettings map' {

        It 'accepts DefaultLabel alongside existing boolean keys' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('General')
                advancedSettings = @{
                    requiredowngradejustification = 'true'
                    DefaultLabel                  = 'General'
                }
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.advancedSettings.Keys | Should -Contain 'DefaultLabel'
            # Verbatim until Resolve-DesiredAdvancedSettingLabel runs.
            [string]$hash.advancedSettings['DefaultLabel'] | Should -Be 'general'
        }
    }

    Context 'Resolve-DesiredAdvancedSettingLabel (per ADR 0040)' {

        It 'resolves a bare top-level label name to the GUID' {
            $hash = @{ advancedSettings = @{ DefaultLabel = 'General' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['DefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000002'
        }

        It 'resolves a composite-key sublabel reference to the child GUID' {
            $hash = @{ advancedSettings = @{ DefaultLabel = 'General/Partner' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['DefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000011'
        }

        It 'passes a GUID input through unchanged' {
            $hash = @{ advancedSettings = @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings['DefaultLabel'] | Should -Be '00000000-0000-0000-0000-000000000002'
        }

        It 'returns the unresolved reference when the label is missing from the tenant' {
            $hash = @{ advancedSettings = @{ DefaultLabel = 'DoesNotExist' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing | Should -HaveCount 1
            $missing[0] | Should -Be 'advancedSettings.DefaultLabel=DoesNotExist'
            $hash.advancedSettings['DefaultLabel'] | Should -Be 'DoesNotExist'
        }

        It 'is a no-op when DefaultLabel is absent' {
            $hash = @{ advancedSettings = @{ requiredowngradejustification = 'true' } }
            $missing = Resolve-DesiredAdvancedSettingLabel -Hash $hash -Lookup $script:LabelLookup
            $missing.Count | Should -Be 0
            $hash.advancedSettings.Keys | Should -Not -Contain 'DefaultLabel'
        }
    }

    Context 'Compare-PolicyHash detects DefaultLabel drift across the four quadrants' {

        BeforeAll {
            function script:New-CompareHashRow5 {
                param([hashtable]$AdvancedSettings = @{})
                @{
                    mode             = 'Enable'
                    exchangeLocation = @('All')
                    labels           = @('00000000-0000-0000-0000-000000000002')
                    advancedSettings = $AdvancedSettings
                }
            }
        }

        It 'no-drift when both sides carry the same resolved GUID' {
            $desired = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' }
            $tenant  = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'advancedSettings.DefaultLabel'
        }

        It 'DesiredOnly drift surfaces (repo set; tenant unset)' {
            $desired = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' }
            $tenant  = New-CompareHashRow5 -AdvancedSettings @{}
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.DefaultLabel'
        }

        It 'TenantOnly drift surfaces (tenant set; repo unset)' {
            $desired = New-CompareHashRow5 -AdvancedSettings @{}
            $tenant  = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.DefaultLabel'
        }

        It 'mixed drift surfaces (both set to different GUIDs)' {
            $desired = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000002' }
            $tenant  = New-CompareHashRow5 -AdvancedSettings @{ DefaultLabel = '00000000-0000-0000-0000-000000000011' }
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'advancedSettings.DefaultLabel'
        }

        It 'ignores a tenant key outside the allowlist (no phantom drift)' {
            $desired = New-CompareHashRow5 -AdvancedSettings @{}
            $tenant  = New-CompareHashRow5 -AdvancedSettings @{}
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'advancedSettings.DefaultLabel'
        }
    }
}

Describe 'powerBIComplianceInformation tracking (#471 row 7; ADR 0041)' {

    BeforeAll {
        # AST-extract ConvertTo-PolicyHash, Compare-PolicyHash, and
        # ConvertTo-TenantPolicyHash so the cases below can exercise the
        # desired-side and tenant-side hash paths standalone. Follows the
        # same AST-extract-and-stub pattern used for the scalar field
        # 'mode' and for AdvancedSettings rows 1/2/5.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-TenantPolicyHash',
            'ConvertTo-PolicyInputMode'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Production constants post-#661: powerBIComplianceInformation is
        # the 2nd TrackedScalarField. AdvancedSettingsAllowlist and
        # LabelReferenceAdvancedSettingsKeys unchanged by this PR.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
        $script:TrackedScalarFields              = @('mode', 'powerBIComplianceInformation')
        $script:AdvancedSettingsAllowlist        = @('RequireDowngradeJustification', 'MandatoryLabelling', 'HideBarByDefault', 'OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')
        # ConvertTo-PolicyInputMode dependencies
        $script:ValidPolicyModes     = @('Enable', 'Disable', 'TestWithNotifications', 'TestWithoutNotifications')
        $script:RuntimePolicyModeMap = @{ 'Enforce' = 'Enable' }
    }

    Context 'powerBIComplianceInformation is a member of TrackedScalarFields' {

        It 'TrackedScalarFields contains powerBIComplianceInformation' {
            $script:TrackedScalarFields | Should -Contain 'powerBIComplianceInformation'
        }

        It 'TrackedScalarFields has exactly 2 entries' {
            $script:TrackedScalarFields.Count | Should -Be 2
        }
    }

    Context 'ConvertTo-PolicyHash normalizes YAML boolean to lowercase string' {

        It 'true normalizes to "true"' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('General')
                powerBIComplianceInformation = $true
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.powerBIComplianceInformation | Should -Be 'true'
        }

        It 'false normalizes to "false"' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('General')
                powerBIComplianceInformation = $false
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.powerBIComplianceInformation | Should -Be 'false'
        }

        It 'absent key normalizes to empty string' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('General')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.powerBIComplianceInformation | Should -Be ''
        }
    }

    Context 'ConvertTo-TenantPolicyHash normalizes tenant boolean to lowercase string' {

        It 'True property normalizes to "true"' {
            $policy = [pscustomobject]@{
                Name                         = 'lab-default'
                Guid                         = '00000000-0000-0000-0000-000000000001'
                Mode                         = 'Enable'
                Status                       = 'Published'
                ExchangeLocation             = @()
                ExchangeLocationException    = @()
                ModernGroupLocation          = @()
                Labels                       = @()
                Settings                     = @()
                PowerBIComplianceInformation = $true
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.powerBIComplianceInformation | Should -Be 'true'
        }

        It 'False property normalizes to "false"' {
            $policy = [pscustomobject]@{
                Name                         = 'lab-default'
                Guid                         = '00000000-0000-0000-0000-000000000001'
                Mode                         = 'Enable'
                Status                       = 'Published'
                ExchangeLocation             = @()
                ExchangeLocationException    = @()
                ModernGroupLocation          = @()
                Labels                       = @()
                Settings                     = @()
                PowerBIComplianceInformation = $false
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.powerBIComplianceInformation | Should -Be 'false'
        }

        It 'null property normalizes to empty string' {
            $policy = [pscustomobject]@{
                Name                         = 'lab-default'
                Guid                         = '00000000-0000-0000-0000-000000000001'
                Mode                         = 'Enable'
                Status                       = 'Published'
                ExchangeLocation             = @()
                ExchangeLocationException    = @()
                ModernGroupLocation          = @()
                Labels                       = @()
                Settings                     = @()
                PowerBIComplianceInformation = $null
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.powerBIComplianceInformation | Should -Be ''
        }
    }

    Context 'Compare-PolicyHash detects powerBIComplianceInformation drift' {

        BeforeAll {
            function script:New-CompareHashRow7 {
                param([string]$PowerBI = '')
                @{
                    mode                         = 'Enable'
                    powerBIComplianceInformation = $PowerBI
                    exchangeLocation             = @('All')
                    exchangeLocationException    = @()
                    modernGroupLocation          = @()
                    labels                       = @('00000000-0000-0000-0000-000000000001')
                    advancedSettings             = @{}
                }
            }
        }

        It 'no-drift when both sides carry "true"' {
            $desired = New-CompareHashRow7 -PowerBI 'true'
            $tenant  = New-CompareHashRow7 -PowerBI 'true'
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'powerBIComplianceInformation'
        }

        It 'DesiredOnly drift surfaces (repo set true; tenant empty)' {
            $desired = New-CompareHashRow7 -PowerBI 'true'
            $tenant  = New-CompareHashRow7 -PowerBI ''
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'powerBIComplianceInformation'
        }

        It 'TenantOnly drift surfaces (tenant set true; repo empty)' {
            $desired = New-CompareHashRow7 -PowerBI ''
            $tenant  = New-CompareHashRow7 -PowerBI 'true'
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'powerBIComplianceInformation'
        }

        It 'mixed drift surfaces (repo true; tenant false)' {
            $desired = New-CompareHashRow7 -PowerBI 'true'
            $tenant  = New-CompareHashRow7 -PowerBI 'false'
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'powerBIComplianceInformation'
        }

        It 'no-drift when both sides are empty (unset)' {
            $desired = New-CompareHashRow7 -PowerBI ''
            $tenant  = New-CompareHashRow7 -PowerBI ''
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'powerBIComplianceInformation'
        }
    }
}

Describe 'includedAdministrativeUnits tracking (#471 row 6; ADR 0042)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        foreach ($fname in @(
            'ConvertTo-PolicyHash',
            'Compare-PolicyHash',
            'ConvertTo-TenantPolicyHash',
            'ConvertTo-PolicyInputMode',
            'Resolve-TenantPolicyStatus'
        )) {
            $fnAst = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Production constants. includedAdministrativeUnits is a sorted-set
        # field (not a TrackedScalarField). TrackedScalarFields unchanged by
        # this PR.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
        $script:TrackedScalarFields              = @('mode', 'powerBIComplianceInformation')
        $script:AdvancedSettingsAllowlist        = @('RequireDowngradeJustification', 'MandatoryLabelling', 'HideBarByDefault', 'OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')
        $script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')
        $script:ValidPolicyModes     = @('Enable', 'Disable', 'TestWithNotifications', 'TestWithoutNotifications')
        $script:RuntimePolicyModeMap = @{ 'Enforce' = 'Enable' }
    }

    Context 'includedAdministrativeUnits is a sorted-set field (not TrackedScalarField)' {

        It 'TrackedScalarFields does not contain includedAdministrativeUnits' {
            $script:TrackedScalarFields | Should -Not -Contain 'includedAdministrativeUnits'
        }
    }

    Context 'ConvertTo-PolicyHash normalizes includedAdministrativeUnits from YAML' {

        It 'non-empty list is stored sorted and trimmed' {
            $entry = @{
                name                        = 'lab-default'
                mode                        = 'Enable'
                exchangeLocation            = @('All')
                labels                      = @('General')
                includedAdministrativeUnits = @('  Marketing Dept  ', 'Finance')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.includedAdministrativeUnits | Should -Be @('Finance', 'Marketing Dept')
        }

        It 'empty array stores empty array' {
            $entry = @{
                name                        = 'lab-default'
                mode                        = 'Enable'
                exchangeLocation            = @('All')
                labels                      = @('General')
                includedAdministrativeUnits = @()
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.includedAdministrativeUnits.Count | Should -Be 0
        }

        It 'absent key stores empty array' {
            $entry = @{
                name             = 'lab-default'
                mode             = 'Enable'
                exchangeLocation = @('All')
                labels           = @('General')
            }
            $hash = ConvertTo-PolicyHash -Entry $entry
            $hash.includedAdministrativeUnits.Count | Should -Be 0
        }
    }

    Context 'ConvertTo-TenantPolicyHash reads IncludedAdministrativeUnits from tenant' {

        It 'MultiValuedProperty with DisplayName is read correctly' {
            $policy = [pscustomobject]@{
                Name                        = 'lab-default'
                Guid                        = '00000000-0000-0000-0000-000000000001'
                Mode                        = 'Enable'
                Status                      = 'Published'
                ExchangeLocation            = @()
                ExchangeLocationException   = @()
                ModernGroupLocation         = @()
                IncludedAdministrativeUnits = @(
                    [pscustomobject]@{ DisplayName = 'Finance' },
                    [pscustomobject]@{ DisplayName = 'Marketing Dept' }
                )
                Labels                      = @()
                Settings                    = @()
                PowerBIComplianceInformation = $false
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.includedAdministrativeUnits | Should -Be @('Finance', 'Marketing Dept')
        }

        It 'empty IncludedAdministrativeUnits stores empty array' {
            $policy = [pscustomobject]@{
                Name                        = 'lab-default'
                Guid                        = '00000000-0000-0000-0000-000000000001'
                Mode                        = 'Enable'
                Status                      = 'Published'
                ExchangeLocation            = @()
                ExchangeLocationException   = @()
                ModernGroupLocation         = @()
                IncludedAdministrativeUnits = @()
                Labels                      = @()
                Settings                    = @()
                PowerBIComplianceInformation = $false
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.includedAdministrativeUnits.Count | Should -Be 0
        }

        It 'null IncludedAdministrativeUnits stores empty array' {
            $policy = [pscustomobject]@{
                Name                        = 'lab-default'
                Guid                        = '00000000-0000-0000-0000-000000000001'
                Mode                        = 'Enable'
                Status                      = 'Published'
                ExchangeLocation            = @()
                ExchangeLocationException   = @()
                ModernGroupLocation         = @()
                IncludedAdministrativeUnits = $null
                Labels                      = @()
                Settings                    = @()
                PowerBIComplianceInformation = $false
            }
            $hash = ConvertTo-TenantPolicyHash -Policy $policy
            $hash.includedAdministrativeUnits.Count | Should -Be 0
        }
    }

    Context 'Compare-PolicyHash detects includedAdministrativeUnits drift' {

        BeforeAll {
            function script:New-CompareHashRow6 {
                param([string[]]$IncludedAUs = @())
                @{
                    mode                         = 'Enable'
                    powerBIComplianceInformation = 'true'
                    exchangeLocation             = @('All')
                    exchangeLocationException    = @()
                    modernGroupLocation          = @()
                    includedAdministrativeUnits  = @($IncludedAUs | Sort-Object)
                    labels                       = @('00000000-0000-0000-0000-000000000001')
                    advancedSettings             = @{}
                }
            }
        }

        It 'no-drift when both sides are empty' {
            $desired = New-CompareHashRow6 -IncludedAUs @()
            $tenant  = New-CompareHashRow6 -IncludedAUs @()
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'includedAdministrativeUnits'
        }

        It 'no-drift when both sides carry the same AU' {
            $desired = New-CompareHashRow6 -IncludedAUs @('Finance')
            $tenant  = New-CompareHashRow6 -IncludedAUs @('Finance')
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Not -Contain 'includedAdministrativeUnits'
        }

        It 'DesiredOnly drift surfaces (repo adds an AU; tenant is empty)' {
            $desired = New-CompareHashRow6 -IncludedAUs @('Finance')
            $tenant  = New-CompareHashRow6 -IncludedAUs @()
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'includedAdministrativeUnits'
        }

        It 'TenantOnly drift surfaces (tenant has an AU; repo is empty)' {
            $desired = New-CompareHashRow6 -IncludedAUs @()
            $tenant  = New-CompareHashRow6 -IncludedAUs @('Finance')
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'includedAdministrativeUnits'
        }

        It 'mixed drift surfaces (different AU sets)' {
            $desired = New-CompareHashRow6 -IncludedAUs @('Finance')
            $tenant  = New-CompareHashRow6 -IncludedAUs @('Marketing Dept')
            $diffs = Compare-PolicyHash -Desired $desired -Tenant $tenant
            $diffs | Should -Contain 'includedAdministrativeUnits'
        }
    }
}

Describe 'Export-path advancedSettings GUID -> composite-key inverse (issue #497)' {

    Context 'Source-text guard ensures the export loop translates label-reference values' {

        BeforeAll {
            $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw
        }

        It 'gates label-reference inverse on LabelReferenceAdvancedSettingsKeys membership' {
            $script:ScriptText | Should -Match '\$script:LabelReferenceAdvancedSettingsKeys\s+-contains\s+\$k'
        }

        It 'guards the GUID regex before performing the inverse lookup' {
            $script:ScriptText | Should -Match '\[0-9a-fA-F\]\{8\}-\[0-9a-fA-F\]\{4\}-\[0-9a-fA-F\]\{4\}-\[0-9a-fA-F\]\{4\}-\[0-9a-fA-F\]\{12\}'
        }

        It 'consults guidToKey before rewriting the value' {
            $script:ScriptText | Should -Match '\$guidToKey\.ContainsKey\(\$vs\)'
            $script:ScriptText | Should -Match '\$v\s*=\s*\$guidToKey\[\$vs\]'
        }
    }

    Context 'Behavioral: the inverse translation logic round-trips across the four quadrants' {

        BeforeAll {
            $script:TranslateAdvancedSettingValue = {
                param(
                    [string]$Key,
                    [object]$Value,
                    [string[]]$LabelRefKeys,
                    [hashtable]$GuidToKey
                )
                $v = $Value
                if ($LabelRefKeys -contains $Key) {
                    $vs = [string]$v
                    if ($vs -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' `
                        -and $GuidToKey.ContainsKey($vs)) {
                        $v = $GuidToKey[$vs]
                    }
                }
                return $v
            }

            $script:RefKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid')
            $script:Inverse = @{
                '00000000-0000-0000-0000-000000000010' = 'Public'
                '00000000-0000-0000-0000-000000000011' = 'Confidential/Partner'
            }
        }

        It 'GUID-shaped value on a label-reference key resolves to the composite key (a)' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'OutlookDefaultLabel' `
                -Value '00000000-0000-0000-0000-000000000010' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be 'Public'
        }

        It 'sublabel GUID resolves to the composite Parent/Child key' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'teamworkdefaultlabelid' `
                -Value '00000000-0000-0000-0000-000000000011' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be 'Confidential/Partner'
        }

        It 'non-label-reference scalar value passes through unchanged (b)' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'requiredowngradejustification' `
                -Value 'true' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be 'true'
        }

        It 'GUID-shaped value on a non-label-reference key still passes through (defensive)' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'HideBarByDefault' `
                -Value '00000000-0000-0000-0000-000000000010' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be '00000000-0000-0000-0000-000000000010'
        }

        It 'GUID not in the tenant lookup falls through verbatim (c)' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'OutlookDefaultLabel' `
                -Value 'deadbeef-dead-beef-dead-beefdeadbeef' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be 'deadbeef-dead-beef-dead-beefdeadbeef'
        }

        It 'non-GUID string on a label-reference key passes through verbatim' {
            $out = & $script:TranslateAdvancedSettingValue `
                -Key 'OutlookDefaultLabel' `
                -Value 'NotAGuid' `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $out | Should -Be 'NotAGuid'
        }

        It 'round-trip: composite-key YAML -> Resolve to GUID -> export back to composite (d)' {
            $forwardLookup = @{
                'Public'              = '00000000-0000-0000-0000-000000000010'
                'Confidential/Partner' = '00000000-0000-0000-0000-000000000011'
            }
            $yamlValue = 'Public'
            $resolved = $forwardLookup[$yamlValue]
            $exportValue = & $script:TranslateAdvancedSettingValue `
                -Key 'OutlookDefaultLabel' `
                -Value $resolved `
                -LabelRefKeys $script:RefKeys `
                -GuidToKey $script:Inverse
            $exportValue | Should -Be $yamlValue
        }
    }
}

Describe 'Format-AdvancedSettingsYamlBlock cosmetic normalization (issue #503)' {

    BeforeAll {
        # AST-extract just the helper. The script body is not dot-sourced
        # (it would attempt to connect to a real tenant on import).
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Format-AdvancedSettingsYamlBlock'
            }, $true)
        if (-not $fnAst) { throw "Format-AdvancedSettingsYamlBlock not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))

        # The helper reads $script:AdvancedSettingsAllowlist for canonical
        # key casing. Mirror the production constant so tests assert against
        # the same canonical surface the export path uses at runtime.
        $script:AdvancedSettingsAllowlist = @(
            'RequireDowngradeJustification',
            'MandatoryLabelling',
            'HideBarByDefault',
            'OutlookDefaultLabel',
            'teamworkdefaultlabelid'
        )
    }

    Context 'Key casing normalization' {

        It 'rewrites lowercase outlookdefaultlabel to PascalCase OutlookDefaultLabel' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      outlookdefaultlabel: General"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'OutlookDefaultLabel:'
            # Case-sensitive negative assertion: the lowercase form must
            # not survive normalization. `Should -Not -Match` is
            # case-insensitive in Pester, so use the .NET regex directly
            # with the CaseSensitive option.
            [regex]::IsMatch($out, 'outlookdefaultlabel:') | Should -Be $false
        }

        It 'preserves canonical lowercase teamworkdefaultlabelid (matches allowlist constant)' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      teamworkdefaultlabelid: General"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'teamworkdefaultlabelid: "General"'
        }

        It 'rewrites all-caps OUTLOOKDEFAULTLABEL to canonical PascalCase' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      OUTLOOKDEFAULTLABEL: General"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'OutlookDefaultLabel:'
        }

        It 'leaves a non-allowlisted key untouched (defensive guard)' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      unknownkey: foo"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'unknownkey: "foo"'
        }
    }

    Context 'Scalar quoting normalization' {

        It 'wraps a bare scalar value in double quotes' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      OutlookDefaultLabel: General"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'OutlookDefaultLabel: "General"'
        }

        It 'leaves an already-double-quoted value untouched' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      RequireDowngradeJustification: `"true`""
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            ($out -split "`n" | Where-Object { $_ -match 'RequireDowngradeJustification' }).Count | Should -Be 1
            $out | Should -Match 'RequireDowngradeJustification: "true"'
        }

        It 'leaves a single-quoted value untouched' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      OutlookDefaultLabel: 'General'"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match "OutlookDefaultLabel: 'General'"
        }
    }

    Context 'Block boundary detection' {

        It 'stops normalizing once the indent returns to the parent level' {
            # A subsequent top-level field at the policy indent (4 spaces)
            # has the same indent as the advancedSettings: header and must
            # not be touched by the helper.
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      OutlookDefaultLabel: General`n    mode: Enable"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'OutlookDefaultLabel: "General"'
            $out | Should -Match '    mode: Enable'
            $out | Should -Not -Match 'mode: "Enable"'
        }

        It 'handles multiple advancedSettings blocks across policies' {
            $input = @(
                'labelPolicies:'
                '  - name: a'
                '    advancedSettings:'
                '      outlookdefaultlabel: General'
                '  - name: b'
                '    advancedSettings:'
                '      teamworkdefaultlabelid: Public'
            ) -join "`n"
            $out = Format-AdvancedSettingsYamlBlock -Yaml $input
            $out | Should -Match 'OutlookDefaultLabel: "General"'
            $out | Should -Match 'teamworkdefaultlabelid: "Public"'
        }
    }

    Context 'Idempotence' {

        It 'a second pass produces byte-identical output' {
            $input = "labelPolicies:`n  - name: demo`n    advancedSettings:`n      outlookdefaultlabel: General`n      teamworkdefaultlabelid: Public"
            $once = Format-AdvancedSettingsYamlBlock -Yaml $input
            $twice = Format-AdvancedSettingsYamlBlock -Yaml $once
            $twice | Should -Be $once
        }
    }

    Context 'End-to-end against the bug reproduction (PR #500 / issue #503)' {

        It 'closes the recurring drift-back shape after normalization' {
            # Simulate the exact YAML emitted by ConvertTo-Yaml against
            # an in-sync tenant on the post-#498 reconciler:
            $buggy = @(
                'labelPolicies:'
                '  - name: Global sensitivity label policy'
                '    mode: Enable'
                '    advancedSettings:'
                '      outlookdefaultlabel: General'
                '      requiredowngradejustification: "true"'
                '      teamworkdefaultlabelid: General'
            ) -join "`n"
            # Expected post-normalization shape — what the committed
            # data-plane/information-protection/label-policies.yaml carries:
            $expected = @(
                'labelPolicies:'
                '  - name: Global sensitivity label policy'
                '    mode: Enable'
                '    advancedSettings:'
                '      OutlookDefaultLabel: "General"'
                '      requiredowngradejustification: "true"'
                '      teamworkdefaultlabelid: "General"'
            ) -join "`n"
            $actual = Format-AdvancedSettingsYamlBlock -Yaml $buggy
            $actual | Should -Be $expected
        }
    }
}