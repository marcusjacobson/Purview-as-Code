#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for `scripts/Deploy-AdaptiveScopes.ps1` (issue
    #550, ADR 0034 reconciler).

.DESCRIPTION
    Exercises four contracts in the adaptive-scopes reconciler:

      1. Parameter declaration shape (ADR 0012 `-ParametersFile`,
         ADR 0029 `-DirectionPolicy` + `-SkipNames`, and the four
         standard switches `-WhatIf`/`-PruneMissing`/`-Force`/
         `-ExportCurrentState` plus the `-SkipSchemaValidation`
         escape hatch). Source-text assertions against the script so
         a refactor that breaks the workflow-side contract surfaces
         here, not in a live run.

      2. ADR 0029 apply-path direction policy. Source-text guards
         around the audit-mode short-circuit (must clear the plan
         and the orphan list, never `return` from inside the try
         block), the scope-specific repo-wins Write-Warning shape,
         and the [ADR0029-SKIP] marker emission shape. The shared
         `Resolve-DirectionPolicyAction` helper itself is covered
         exhaustively by the labels / label-policies / auto-label
         test files (PRs #458, #468, #474); this file just confirms
         the reconciler imports the module and emits the
         scope-specific warning text so a run-log grep can
         disambiguate the four reconcilers.

      3. ADR 0034 schema constraints (data-plane/adaptive-scopes/
         scopes.schema.json). Locks in the 4 negative + 2 positive
         tests proven manually during P1 of issue #550.

      4. The four AST-extracted helper functions from the
         reconciler: ConvertTo-DesiredAdaptiveScopeHash,
         ConvertTo-TenantAdaptiveScopeHash, Compare-AdaptiveScope,
         Get-AdaptiveScopeSplat. Extracted via the FunctionDefinitionAst
         pattern documented in
         `.github/instructions/tests.instructions.md` (the script
         body cannot be dot-sourced because it imports
         ExchangeOnlineManagement and would connect to a tenant).

    Reference: docs/adr/0034-adaptive-scope-schema.md
    Reference: docs/adr/0029-source-of-truth-direction-policy.md
    Reference: docs/adr/0012-environment-parameters-file.md
    Reference: scripts/modules/DirectionPolicy.psm1
    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-AdaptiveScopes.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-AdaptiveScopes.ps1 at: $script:ScriptPath"
    }
    $script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'data-plane' 'adaptive-scopes' 'scopes.schema.json'
    if (-not (Test-Path $script:SchemaPath)) {
        throw "Could not locate scopes.schema.json at: $script:SchemaPath"
    }
    $script:SchemaText = Get-Content -LiteralPath $script:SchemaPath -Raw
    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    # Parse once; reused by the helper-extraction Describe blocks
    # below to avoid re-parsing the ~1100-line script per block.
    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Deploy-AdaptiveScopes.ps1 has parse errors: {0}" -f ($errors | ForEach-Object Message | Join-String -Separator '; '))
    }

    # Import the in-repo ADR 0029 direction-policy module so any
    # block that wants to call Resolve-DirectionPolicyAction directly
    # can (sibling test files cover the helper exhaustively; this
    # file uses it sparingly to confirm Kind-agnostic wiring).
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') `
        -Force -ErrorAction Stop
}

Describe 'Parameter declaration shape (ADR 0012 + ADR 0029 + standard switches)' {

    It 'declares -ParametersFile (ADR 0012) on Apply and Export sets' {
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateNotNullOrEmpty\(\)\]\s*\r?\n\s*\[string\]\$ParametersFile'
    }

    It 'declares -DirectionPolicy with the audit/portal-wins/repo-wins ValidateSet and portal-wins default (ADR 0029)' {
        $script:ScriptText | Should -Match '\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy\s*=\s*''portal-wins'''
    }

    It 'attaches -DirectionPolicy to both Apply and Export parameter sets' {
        # Mirrors Deploy-AutoLabelPolicies.ps1 / Deploy-LabelPolicies.ps1 /
        # Deploy-Labels.ps1: -ExportCurrentState callers may opt into
        # audit mode without separate parameter ceremonies.
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[ValidateSet\(\s*''audit''\s*,\s*''portal-wins''\s*,\s*''repo-wins''\s*\)\]\s*\r?\n\s*\[string\]\$DirectionPolicy'
    }

    It 'declares -SkipNames on the Apply parameter set only with default @()' {
        # The Apply path is the only one where a workflow-side skip
        # list applies; the export path has no use for it.
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[string\[\]\]\$SkipNames\s*=\s*@\(\)'
    }

    It 'declares SupportsShouldProcess on CmdletBinding so -WhatIf is automatic' {
        $script:ScriptText | Should -Match '\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true'
    }

    It 'declares -PruneMissing on the Apply parameter set' {
        $script:ScriptText | Should -Match '(?m)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[switch\]\$PruneMissing'
    }

    It 'declares -Force on both Apply and Export sets' {
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[switch\]\$Force'
    }

    It 'declares -ExportCurrentState as Mandatory on the Export parameter set' {
        $script:ScriptText | Should -Match '\[Parameter\(ParameterSetName\s*=\s*''Export''\s*,\s*Mandatory\s*=\s*\$true\)\]\s*\r?\n\s*\[switch\]\$ExportCurrentState'
    }

    It 'declares -SkipSchemaValidation as an emergency escape hatch on both sets' {
        $script:ScriptText | Should -Match '(?ms)\[Parameter\(ParameterSetName\s*=\s*''Apply''\)\]\s*\r?\n\s*\[Parameter\(ParameterSetName\s*=\s*''Export''\)\]\s*\r?\n\s*\[switch\]\$SkipSchemaValidation'
    }

    It 'defaults -Path to data-plane/adaptive-scopes/scopes.yaml' {
        $script:ScriptText | Should -Match '\[string\]\$Path\s*=\s*\(Join-Path \$PSScriptRoot ''\.\.\\data-plane\\adaptive-scopes\\scopes\.yaml''\)'
    }
}

Describe 'Apply-path direction policy branches (ADR 0029)' {

    It 'imports the shared DirectionPolicy.psm1 module (does not re-inline Resolve-DirectionPolicyAction)' {
        # Per ADR 0029 / issue #463 the helper must be loaded from the
        # in-repo module, not pasted into every reconciler. A future
        # refactor that re-inlines the helper would silently bypass
        # the shared contract; this guard surfaces that.
        $script:ScriptText | Should -Match 'Import-Module \(Join-Path \$PSScriptRoot ''modules/DirectionPolicy\.psm1''\)'
        # And the file must not declare its own Resolve-DirectionPolicyAction.
        $script:ScriptText | Should -Not -Match 'function\s+Resolve-DirectionPolicyAction'
    }

    It 'has an audit-mode short-circuit that empties the plan AND the orphan list before Phase 2' {
        # Source-text guard: audit mode keeps the categorized report
        # intact for end-of-script emission but empties $plan and
        # $orphanScopes so the write loops are no-ops. Reassignment
        # patterns differ across reconcilers (auto-label uses @();
        # this script uses .Clear() on the orphan list because it is
        # a List[object] not an array). The match accepts both.
        $script:ScriptText | Should -Match '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{\s*\r?\n\s*Write-Information ''\[ADR0029-AUDIT\][^'']*''.*?\$plan\.Clear\(\).*?(\$orphanScopes\.Clear\(\)|\$orphanScopes\s*=\s*@\(\))\s*\r?\n\s*\}'
    }

    It 'does not early-return from inside the try block in audit mode (would break post-finally output)' {
        # PR #458 lesson: an early `return` from inside the try {}
        # block breaks the post-finally `$report` emission. The
        # audit-mode block must clear+continue, not return.
        $auditBlockMatch = [regex]::Match(
            $script:ScriptText,
            '(?ms)if \(\$DirectionPolicy -eq ''audit''\) \{(.*?)\r?\n\s*\}\s*\r?\n\s*# ---- Phase 2')
        $auditBlockMatch.Success | Should -BeTrue -Because 'audit-mode short-circuit must precede the Phase 2 marker'
        $auditBlockMatch.Groups[1].Value | Should -Not -Match '(?m)^\s*return\b'
    }

    It 'emits one Write-Warning per drifted adaptive scope on repo-wins (Kind-specific wording)' {
        # The warning fires once per scope in the direction-policy
        # pass with the comma-joined drifted-field set. The wording
        # differs from the sibling reconcilers only by using
        # "adaptive scope" so a run-log grep can disambiguate the
        # four IPPS reconcilers.
        $script:ScriptText | Should -Match 'Write-Warning \("repo-wins overwriting tenant on adaptive scope '''
    }

    It 'emits a [ADR0029-SKIP] marker per skipped object for workflow consumption' {
        # Format must match `^\[ADR0029-SKIP\] (.+)$` per the
        # github-actions instructions rule (no Kind prefix in the
        # marker line). Identical shape across reconcilers.
        $script:ScriptText | Should -Match 'Write-Information \("\[ADR0029-SKIP\] \{0\}"\s*-f\s*\$s\.DisplayName'
    }

    It 'tags ADR 0029 skip decisions with Kind=AdaptiveScope' {
        # Each Kind value must be reconciler-specific so a downstream
        # workflow consumer can group by reconciler. Auto-label uses
        # AutoLabelPolicy / AutoLabelRule; this reconciler uses
        # AdaptiveScope.
        $script:ScriptText | Should -Match 'Kind\s*=\s*''AdaptiveScope'''
    }

    It 'returns Skip / Update / Update / Skip from Resolve-DirectionPolicyAction for the scope flow' {
        # Sanity-check the shared helper from this file too, so a
        # broken module import surfaces here even if the sibling
        # files happen to be skipped.
        $skip = Resolve-DirectionPolicyAction -Policy 'portal-wins' -SkipList @() -DisplayName 'lab-as-marketing' -HasDrift $true
        $skip.Action | Should -Be 'Skip'

        $update = Resolve-DirectionPolicyAction -Policy 'repo-wins' -SkipList @() -DisplayName 'lab-as-marketing' -HasDrift $true
        $update.Action | Should -Be 'Update'

        $noDrift = Resolve-DirectionPolicyAction -Policy 'portal-wins' -SkipList @() -DisplayName 'lab-as-marketing' -HasDrift $false
        $noDrift.Action | Should -Be 'Update'

        $forced = Resolve-DirectionPolicyAction -Policy 'repo-wins' -SkipList @('lab-as-marketing') -DisplayName 'lab-as-marketing' -HasDrift $true
        $forced.Action | Should -Be 'Skip'
    }
}

Describe 'Schema constraints (ADR 0034 lock-in of P1 manual proof)' {

    # These six cases were proven manually during P1 commit 5ac5f4d
    # of issue #550 (4 negatives, 2 positives). Locking them in
    # Pester so a future edit to scopes.schema.json that drops a
    # constraint surfaces here instead of at apply time.

    It 'rejects a name without the lab-as- prefix' {
        $doc = '{"scopes":[{"name":"bad-prefix-01","locationType":"User","filterConditions":"{}"}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Throw
    }

    It 'rejects an invalid locationType (Mailbox is not in the enum)' {
        $doc = '{"scopes":[{"name":"lab-as-test","locationType":"Mailbox","filterConditions":"{}"}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Throw
    }

    It 'rejects filterConditions that is not a string (ADR 0034 Decision 1)' {
        # The cmdlet rejects hashtable input at depth 1; the schema
        # enforces the JSON-string boundary so the operator gets a
        # clear validation error client-side.
        $doc = '{"scopes":[{"name":"lab-as-test","locationType":"User","filterConditions":{"Conjunction":"And"}}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Throw
    }

    It 'rejects unknown top-level scope fields (additionalProperties: false)' {
        # Defends against typo'd fields like "mode" silently surviving
        # the schema gate and ending up ignored by the reconciler.
        $doc = '{"scopes":[{"name":"lab-as-test","locationType":"User","filterConditions":"{}","mode":"Enable"}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Throw
    }

    It 'accepts a minimal valid scope (no comment field)' {
        $doc = '{"scopes":[{"name":"lab-as-minimal","locationType":"User","filterConditions":"{}"}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Not -Throw
    }

    It 'accepts a valid scope with the optional comment field' {
        # Comment is documentation-only per ADR 0034 (the cmdlet has
        # no -Comment parameter) but the schema permits it. Locks in
        # the Option-1 contract from P2's design decision.
        $doc = '{"scopes":[{"name":"lab-as-minimal","locationType":"User","filterConditions":"{}","comment":"docs only"}]}'
        { $doc | Test-Json -Schema $script:SchemaText -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'ConvertTo-DesiredAdaptiveScopeHash (YAML entry -> comparable hashtable)' {

    BeforeAll {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertTo-DesiredAdaptiveScopeHash'
            }, $true)
        if (-not $fnAst) { throw 'ConvertTo-DesiredAdaptiveScopeHash not found in script.' }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    It 'returns the three tracked fields when all required fields are present' {
        $entry = @{
            name             = 'lab-as-marketing'
            locationType     = 'User'
            filterConditions = '{"Conjunction":"And","Conditions":[{"Name":"Department","Value":"Marketing","Operator":"Equals"}]}'
        }
        $h = ConvertTo-DesiredAdaptiveScopeHash -Entry $entry
        $h.name             | Should -Be 'lab-as-marketing'
        $h.locationType     | Should -Be 'User'
        $h.filterConditions | Should -Be '{"Conjunction":"And","Conditions":[{"Name":"Department","Value":"Marketing","Operator":"Equals"}]}'
    }

    It 'drops the optional comment field (Option 1 from P2 design decision)' {
        # The cmdlet has no -Comment parameter; including it in the
        # diff hash would make every scope with a comment drift
        # forever. Locks in the Option-1 choice.
        $entry = @{
            name             = 'lab-as-marketing'
            locationType     = 'User'
            filterConditions = '{"Conjunction":"And","Conditions":[]}'
            comment          = 'docs only'
        }
        $h = ConvertTo-DesiredAdaptiveScopeHash -Entry $entry
        $h.ContainsKey('comment') | Should -BeFalse
        $h.Keys.Count             | Should -Be 3
    }

    It 'throws on a missing name field' {
        $entry = @{ locationType = 'User'; filterConditions = '{}' }
        { ConvertTo-DesiredAdaptiveScopeHash -Entry $entry } | Should -Throw
    }

    It 'throws on an invalid locationType' {
        $entry = @{ name = 'lab-as-x'; locationType = 'Mailbox'; filterConditions = '{}' }
        { ConvertTo-DesiredAdaptiveScopeHash -Entry $entry } | Should -Throw
    }

    It 'throws on filterConditions that is not well-formed JSON (ADR 0034 Decision 1)' {
        # The reconciler validates well-formedness only via Test-Json;
        # it does NOT parse or canonicalize. A malformed string is
        # rejected client-side rather than producing a confusing
        # cmdlet error later.
        $entry = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{not-json' }
        { ConvertTo-DesiredAdaptiveScopeHash -Entry $entry } | Should -Throw
    }

    It 'throws on $null input' {
        { ConvertTo-DesiredAdaptiveScopeHash -Entry $null } | Should -Throw
    }
}

Describe 'ConvertTo-TenantAdaptiveScopeHash (Get-AdaptiveScope row -> comparable hashtable)' {

    BeforeAll {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertTo-TenantAdaptiveScopeHash'
            }, $true)
        if (-not $fnAst) { throw 'ConvertTo-TenantAdaptiveScopeHash not found in script.' }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    It 'normalizes a tenant scope returned as a PSCustomObject' {
        $tenant = [pscustomobject]@{
            Name             = 'lab-as-marketing'
            LocationType     = 'User'
            FilterConditions = '{"Conjunction":"And","Conditions":[{"Name":"Department","Value":"Marketing","Operator":"Equals"}]}'
        }
        $h = ConvertTo-TenantAdaptiveScopeHash -Scope $tenant
        $h.name             | Should -Be 'lab-as-marketing'
        $h.locationType     | Should -Be 'User'
        $h.filterConditions | Should -Be '{"Conjunction":"And","Conditions":[{"Name":"Department","Value":"Marketing","Operator":"Equals"}]}'
    }

    It 'preserves the FilterConditions string byte-for-byte (ADR 0034 Decision 1)' {
        # Round-trip stability comes from preserving the tenant's
        # canonical JSON string unchanged. No reordering, no
        # whitespace normalization, no key sorting.
        $opaque = '{"Conjunction":"Or","Conditions":[{"Name":"Office","Value":"HQ","Operator":"Equals"},{"Name":"Title","Value":"VP","Operator":"Equals"}]}'
        $tenant = [pscustomobject]@{
            Name = 'lab-as-x'; LocationType = 'User'; FilterConditions = $opaque
        }
        (ConvertTo-TenantAdaptiveScopeHash -Scope $tenant).filterConditions | Should -BeExactly $opaque
    }

    It 'normalizes a tenant scope returned as a hashtable' {
        $tenant = @{
            Name             = 'lab-as-marketing'
            LocationType     = 'User'
            FilterConditions = '{}'
        }
        $h = ConvertTo-TenantAdaptiveScopeHash -Scope $tenant
        $h.name | Should -Be 'lab-as-marketing'
        $h.filterConditions | Should -Be '{}'
    }

    It 'serializes a non-string FilterConditions payload via ConvertTo-Json -Compress' {
        # Older cmdlet versions returned a typed object instead of a
        # string. The helper falls back to compact JSON so the diff
        # has a stable shape; the next -ExportCurrentState run will
        # overwrite the YAML with the tenant's authoritative string.
        $typed  = [pscustomobject]@{ Conjunction = 'And'; Conditions = @() }
        $tenant = [pscustomobject]@{ Name = 'lab-as-x'; LocationType = 'User'; FilterConditions = $typed }
        $h = ConvertTo-TenantAdaptiveScopeHash -Scope $tenant
        $h.filterConditions | Should -BeOfType ([string])
        ($h.filterConditions | ConvertFrom-Json).Conjunction | Should -Be 'And'
    }

    It 'returns an empty filterConditions string when the tenant property is $null' {
        $tenant = [pscustomobject]@{ Name = 'lab-as-x'; LocationType = 'User'; FilterConditions = $null }
        (ConvertTo-TenantAdaptiveScopeHash -Scope $tenant).filterConditions | Should -Be ''
    }

    It 'throws when the tenant scope has no readable Name property' {
        $tenant = [pscustomobject]@{ Name = ''; LocationType = 'User'; FilterConditions = '{}' }
        { ConvertTo-TenantAdaptiveScopeHash -Scope $tenant } | Should -Throw
    }

    It 'throws on $null input' {
        { ConvertTo-TenantAdaptiveScopeHash -Scope $null } | Should -Throw
    }
}

Describe 'Compare-AdaptiveScope (decision function for Create/Update/NoChange/Orphan/Blocked)' {

    BeforeAll {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Compare-AdaptiveScope'
            }, $true)
        if (-not $fnAst) { throw 'Compare-AdaptiveScope not found in script.' }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    It 'returns Create when the desired scope is present and the tenant scope is absent' {
        $desired = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{}' }
        $r = Compare-AdaptiveScope -Desired $desired -Tenant $null
        $r.Action | Should -Be 'Create'
        $r.Fields | Should -BeNullOrEmpty
    }

    It 'returns Orphan when the tenant scope is present and the desired scope is absent' {
        $tenant = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{}' }
        $r = Compare-AdaptiveScope -Desired $null -Tenant $tenant
        $r.Action | Should -Be 'Orphan'
    }

    It 'returns NoChange when both sides match byte-for-byte' {
        $fc = '{"Conjunction":"And","Conditions":[{"Name":"Alias","Value":"x","Operator":"Equals"}]}'
        $d  = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = $fc }
        $t  = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = $fc }
        $r  = Compare-AdaptiveScope -Desired $d -Tenant $t
        $r.Action | Should -Be 'NoChange'
        $r.Fields | Should -BeNullOrEmpty
    }

    It 'returns Update with Fields=filterConditions when only the JSON string differs' {
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{"Conjunction":"And","Conditions":[]}' }
        $t = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{"Conjunction":"Or","Conditions":[]}' }
        $r = Compare-AdaptiveScope -Desired $d -Tenant $t
        $r.Action | Should -Be 'Update'
        $r.Fields | Should -Be @('filterConditions')
    }

    It 'returns Blocked with Fields=locationType when the LocationType differs (immutable per Microsoft Learn)' {
        # The reconciler does NOT emit Update for a LocationType
        # change because the cmdlet refuses to mutate it in place.
        # The operator must rename the desired scope or delete the
        # tenant scope and re-apply.
        $d = @{ name = 'lab-as-x'; locationType = 'User';  filterConditions = '{}' }
        $t = @{ name = 'lab-as-x'; locationType = 'Group'; filterConditions = '{}' }
        $r = Compare-AdaptiveScope -Desired $d -Tenant $t
        $r.Action | Should -Be 'Blocked'
        $r.Fields | Should -Be @('locationType')
    }

    It 'treats filterConditions equality case-sensitively (byte-for-byte string compare)' {
        # ADR 0034 Decision 3 says no canonicalization. Two JSON
        # strings that differ only by case in a Value are different.
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{"Conjunction":"And","Conditions":[{"Name":"Office","Value":"hq","Operator":"Equals"}]}' }
        $t = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{"Conjunction":"And","Conditions":[{"Name":"Office","Value":"HQ","Operator":"Equals"}]}' }
        (Compare-AdaptiveScope -Desired $d -Tenant $t).Action | Should -Be 'Update'
    }

    It 'throws when both Desired and Tenant are $null (caller bug)' {
        { Compare-AdaptiveScope -Desired $null -Tenant $null } | Should -Throw
    }
}

Describe 'Get-AdaptiveScopeSplat (splat hashtable for New-/Set-AdaptiveScope)' {

    BeforeAll {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-AdaptiveScopeSplat'
            }, $true)
        if (-not $fnAst) { throw 'Get-AdaptiveScopeSplat not found in script.' }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    It 'returns Name/LocationType/FilterConditions for the Create operation' {
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{"Conjunction":"And","Conditions":[]}' }
        $s = Get-AdaptiveScopeSplat -Desired $d -Operation 'Create'
        ($s.Keys | Sort-Object) -join ',' | Should -Be 'FilterConditions,LocationType,Name'
        $s.Name             | Should -Be 'lab-as-x'
        $s.LocationType     | Should -Be 'User'
        $s.FilterConditions | Should -Be '{"Conjunction":"And","Conditions":[]}'
    }

    It 'returns Identity/FilterConditions for the Update operation (Name+LocationType are not mutable)' {
        # Name is identity; LocationType is immutable -> Blocked at
        # the diff stage. Only FilterConditions ever ships in an
        # update splat.
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{}' }
        $s = Get-AdaptiveScopeSplat -Desired $d -Operation 'Update'
        ($s.Keys | Sort-Object) -join ',' | Should -Be 'FilterConditions,Identity'
        $s.Identity         | Should -Be 'lab-as-x'
        $s.FilterConditions | Should -Be '{}'
    }

    It 'passes filterConditions through byte-for-byte (no canonicalization, no re-serialization)' {
        # ADR 0034 Decision 3 -- the splat carries the desired
        # string unchanged so the cmdlet sees exactly what YAML
        # declares.
        $opaque = '{"Conjunction":"Or","Conditions":[{"Name":"Department","Value":"  Spaces  ","Operator":"Equals"}]}'
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = $opaque }
        (Get-AdaptiveScopeSplat -Desired $d -Operation 'Create').FilterConditions | Should -BeExactly $opaque
        (Get-AdaptiveScopeSplat -Desired $d -Operation 'Update').FilterConditions | Should -BeExactly $opaque
    }

    It 'rejects an Operation value outside {Create, Update}' {
        $d = @{ name = 'lab-as-x'; locationType = 'User'; filterConditions = '{}' }
        { Get-AdaptiveScopeSplat -Desired $d -Operation 'Delete' } | Should -Throw
    }

    It 'throws when the desired hash is missing a required key' {
        $d = @{ name = 'lab-as-x'; locationType = 'User' }  # missing filterConditions
        { Get-AdaptiveScopeSplat -Desired $d -Operation 'Create' } | Should -Throw
    }
}
