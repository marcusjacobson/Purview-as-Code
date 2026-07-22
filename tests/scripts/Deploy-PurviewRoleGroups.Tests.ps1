#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-PurviewRoleGroups.ps1.

.DESCRIPTION
    Pins the read-phase / plan-phase contract that prune-path revocation
    depends on (issue #401):

      1. The categorize step computes $toRevoke as
         "$tenantGroupOids where -not $desiredSet.Contains($_)" --
         which must produce a non-empty plan row when YAML members are
         empty AND the tenant still holds at least one Entra-group OID.
      2. The plan-add gate fires when -PruneMissing is present and
         $toRevoke is non-empty, even if $toCreate is empty.
      3. The read phase emits Write-Verbose instrumentation for raw
         member count, filtered OID count, and per-RG plan summary so
         future occurrences of empty-read symptoms are diagnosable
         from log output alone (acceptance criterion on #401).
      4. The Add path emits a post-Add Get-RoleGroupMember verification
         under Write-Verbose / Write-Warning, gated by visibility not
         by tenant-side state, so silent non-persistence is detectable
         from log output alone.

    Also pins the RecipientTypeDetails classification fix (issue #57):
    `RecipientTypeDetails -eq 'Group'` is not a real value in Microsoft's
    documented Get-Recipient / Get-RoleGroupMember enum under any auth
    mode -- both the -ExportCurrentState member loop and the -Apply
    read/diff filter used it and therefore never matched a real Entra
    group. The fix checks the documented values ('MailNonUniversalGroup',
    'MailUniversalSecurityGroup') and resolves `ExternalDirectoryObjectId`
    via the ADR 0023 displayName-resolution helper when it is empirically
    blank for those rows.

    Pattern: AST + text assertions, plus targeted dot-sourced execution of
    small, self-contained inline blocks extracted by anchor text (never
    the whole script's top-level body). Per tests/README.md "No script
    execution" -- the script shells out to az / Key Vault and connects
    to Security & Compliance PowerShell, so we never invoke its body.

    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-rolegroupmember
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/add-rolegroupmember
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-rolegroupmember
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-PurviewRoleGroups.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-PurviewRoleGroups.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    # AST-extract the ADR 0023 Category 3 (issue #95) dual-shape member
    # functions so they can be exercised directly, without dot-sourcing
    # the whole script (which would attempt Connect-IPPSSession /
    # Key Vault / az calls at import time; forbidden per tests/README.md).
    foreach ($fname in @('Test-IsGuid', 'Test-IsRoleMemberShapeValid', 'Resolve-DesiredRoleGroupMemberIds')) {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- read-phase / plan contract (issue #401)' {

    It 'computes $toRevoke as tenant OIDs minus desired set' {
        # Hypothesis 3 from issue #401 is ruled out only as long as
        # this exact set-difference pattern remains. A future refactor
        # that re-derives $toRevoke from $desiredMembers (instead of
        # $tenantGroupOids) would silently re-introduce the empty-
        # members-no-revoke regression.
        $script:ScriptText | Should -Match '\$toRevoke\s*=\s*@\(\$tenantGroupOids\s*\|\s*Where-Object\s*\{\s*-not\s*\$desiredSet\.Contains\(\$_\)\s*\}\)'
    }

    It 'computes $toCreate as desired members minus tenant set' {
        $script:ScriptText | Should -Match '\$toCreate\s*=\s*@\(\$desiredMembers\s*\|\s*Where-Object\s*\{\s*-not\s*\$tenantSet\.Contains\(\$_\)\s*\}\)'
    }

    It 'gates plan entry on (toCreate>0) OR (PruneMissing AND toRevoke>0)' {
        # Prune-path revoke must be planned even when toCreate is
        # empty, which is the exact case that broke on #401:
        # DataCatalogCurators had YAML members:[] and a tenant member.
        $script:ScriptText | Should -Match '\$toCreate\.Count\s*-gt\s*0\s*-or\s*\(\s*\$PruneMissing\.IsPresent\s*-and\s*\$toRevoke\.Count\s*-gt\s*0\s*\)'
    }

    It 'filters tenant members to the documented Entra-security-group RecipientTypeDetails values (issue #57)' {
        # 'Group' is not a real RecipientTypeDetails value under any auth
        # mode (confirmed against Microsoft's official Get-Recipient /
        # Get-RoleGroupMember documentation) -- the read/diff phase must
        # match on the real documented values instead.
        $script:ScriptText | Should -Match "RecipientTypeDetails\s*-in\s*@\('MailNonUniversalGroup',\s*'MailUniversalSecurityGroup'\)"
    }

    It 'uses an OrdinalIgnoreCase HashSet for desired-vs-tenant OID comparison' {
        # Entra OIDs are case-insensitive in practice; the script must
        # not regress to case-sensitive comparison, which would cause
        # spurious Create/Revoke pairs.
        $script:ScriptText | Should -Match '\[System\.StringComparer\]::OrdinalIgnoreCase'
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- read-phase instrumentation (issue #401)' {

    It 'emits Write-Verbose with the raw Get-RoleGroupMember count' {
        # Acceptance criterion on #401: future occurrence of the empty-
        # read symptom must be diagnosable from log output alone.
        $script:ScriptText | Should -Match '\[read\][^\n]*Get-RoleGroupMember returned'
    }

    It 'emits Write-Verbose for each raw member with type details and OID' {
        $script:ScriptText | Should -Match '\[read\][^\n]*RecipientTypeDetails'
        $script:ScriptText | Should -Match '\[read\][^\n]*ExternalDirectoryObjectId'
    }

    It 'emits Write-Verbose with the post-filter Entra group OID count' {
        $script:ScriptText | Should -Match '\[read\][^\n]*after filter,'
    }

    It 'emits a per-role-group plan summary including PruneMissing state' {
        $script:ScriptText | Should -Match '\[plan\][^\n]*toCreate='
        $script:ScriptText | Should -Match '\[plan\][^\n]*toRevoke='
        $script:ScriptText | Should -Match '\[plan\][^\n]*PruneMissing='
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- write-phase verification (issue #401)' {

    It 'performs a post-Add Get-RoleGroupMember verification' {
        # Diagnoses hypothesis 2: silent non-persistence where
        # Add-RoleGroupMember returns success but the row never lands.
        $script:ScriptText | Should -Match '\[verify-add\]'
        $script:ScriptText | Should -Match 'post-Add read'
    }

    It 'warns when the post-Add read does not see the new member' {
        $script:ScriptText | Should -Match 'Write-Warning[^\n]*\[verify-add\][^\n]*did NOT see'
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- local-dev interactive mode (issue #355 Phase 3)' {

    BeforeAll {
        $paramBlock = $script:Ast.ParamBlock
        $script:Parameters = @{}
        foreach ($p in $paramBlock.Parameters) {
            $script:Parameters[$p.Name.VariablePath.UserPath] = $p
        }
    }

    It 'declares an -Interactive switch parameter' {
        $script:Parameters.ContainsKey('Interactive') | Should -BeTrue
        $script:Parameters['Interactive'].StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter'
    }

    It 'declares an -Interactive parameter on both Apply and Export parameter sets' {
        $sets = @($script:Parameters['Interactive'].Attributes |
            Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ParameterSetName' }).Argument.Value })
        $sets | Should -Contain 'Apply'
        $sets | Should -Contain 'Export'
    }

    It 'declares an -UserPrincipalName parameter with email validation' {
        $script:Parameters.ContainsKey('UserPrincipalName') | Should -BeTrue
        $script:Parameters['UserPrincipalName'].StaticType.FullName | Should -Be 'System.String'
        $validate = $script:Parameters['UserPrincipalName'].Attributes |
            Where-Object { $_.TypeName.Name -eq 'ValidatePattern' } |
            Select-Object -First 1
        $validate | Should -Not -BeNullOrEmpty
        $validate.PositionalArguments[0].Value | Should -Match '@'
    }

    It 'guards the app-only token acquisition behind -not $Interactive.IsPresent' {
        # The KV + cert + Get-PurviewIPPSAccessToken.ps1 path must be
        # skipped under -Interactive so a local-dev run never reaches
        # the vault. AST check: locate the `if` whose condition is
        # `-not $Interactive.IsPresent` and whose body contains the
        # token-helper literal.
        $ifGuards = $script:Ast.FindAll({
            param($node)
            if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
            $cond = $node.Clauses[0].Item1.Extent.Text
            return ($cond -match '-not\s+\$Interactive\.IsPresent')
        }, $true)
        $ifGuards.Count | Should -BeGreaterOrEqual 1
        $guardsTokenHelper = $false
        foreach ($g in $ifGuards) {
            if ($g.Clauses[0].Item2.Extent.Text -match 'Get-PurviewIPPSAccessToken\.ps1') {
                $guardsTokenHelper = $true
                break
            }
        }
        $guardsTokenHelper | Should -BeTrue -Because 'the KV-side token helper must be skipped under -Interactive'
    }

    It 'branches Connect-IPPSSession to -UserPrincipalName when Interactive' {
        # Both connect sites (initial + Phase 2 reconnect) must honour
        # the switch. Two -UserPrincipalName occurrences expected.
        $matches = [regex]::Matches($script:ScriptText, 'Connect-IPPSSession\s+(?:`\s*\n\s*)?-UserPrincipalName')
        $matches.Count | Should -BeGreaterOrEqual 2
    }

    It 'preserves the app-only -AccessToken connect path for CI' {
        # CI must keep working unchanged. Two -AccessToken connect
        # sites expected (initial + Phase 2 reconnect).
        $matches = [regex]::Matches($script:ScriptText, 'Connect-IPPSSession\s+`\s*\n\s*-AccessToken')
        $matches.Count | Should -BeGreaterOrEqual 2
    }

    It 'falls back to `az account show --query user.name` when UPN is omitted' {
        # Convenience: in interactive mode a missing UPN is read from
        # the active Azure CLI session, not prompted for.
        $script:ScriptText | Should -Match 'az account show --query user\.name'
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- -WhatIf produces a real drift report (issue #355 Phase 3)' {

    It 'does not short-circuit -WhatIf before Connect-IPPSSession' {
        # Old behaviour: `if ($WhatIfPreference -and $mode -eq 'Apply')
        # { ...print plan...; return }` ran before Connect, so -WhatIf
        # produced no drift report. Fix: writes are guarded by
        # SupportsShouldProcess; the read phase runs unconditionally.
        $script:ScriptText | Should -Not -Match 'if\s*\(\s*\$WhatIfPreference\s+-and\s+\$mode\s+-eq\s+''Apply'''
        $script:ScriptText | Should -Not -Match '-WhatIf specified\. Planned behaviour'
    }

    It 'still gates Add-RoleGroupMember on ShouldProcess so -WhatIf is safe' {
        # Read phase must run, write phase must not. ShouldProcess
        # remains the gate.
        $script:ScriptText | Should -Match "ShouldProcess\(\s*\`$shouldProcessTarget\s*,\s*\`$shouldProcessAction\s*\)"
    }
}

Describe 'Test-IsRoleMemberShapeValid dual-shape validation (ADR 0023 Category 3, issue #95)' {

    It 'accepts a raw Entra group object ID (GUID) string' {
        Test-IsRoleMemberShapeValid -Value '00000000-0000-0000-0000-000000000000' | Should -BeTrue
    }

    It 'rejects a non-GUID string' {
        Test-IsRoleMemberShapeValid -Value 'sg-purview-compliance-administrators' | Should -BeFalse
    }

    It 'accepts a { displayName: <name> } mapping' {
        Test-IsRoleMemberShapeValid -Value @{ displayName = 'sg-purview-compliance-administrators' } | Should -BeTrue
    }

    It 'rejects a mapping missing the displayName key' {
        Test-IsRoleMemberShapeValid -Value @{ notDisplayName = 'sg-purview-compliance-administrators' } | Should -BeFalse
    }

    It 'rejects a mapping with a blank displayName' {
        Test-IsRoleMemberShapeValid -Value @{ displayName = '   ' } | Should -BeFalse
    }

    It 'rejects a value that is neither a string nor a mapping' {
        Test-IsRoleMemberShapeValid -Value 42 | Should -BeFalse
    }
}

Describe 'Resolve-DesiredRoleGroupMemberIds dual-shape resolution (ADR 0023 Category 3, issue #95)' {

    It 'passes a raw OID through unchanged and never invokes the resolver (back-compat regression)' {
        $resolver = { param($displayName) throw 'resolver must not be invoked for a raw-OID entry' }
        $result = Resolve-DesiredRoleGroupMemberIds -Members @('00000000-0000-0000-0000-000000000000') -Resolver $resolver
        $result | Should -Be @('00000000-0000-0000-0000-000000000000')
    }

    It 'resolves a { displayName: } entry via the supplied resolver' {
        $resolver = { param($displayName) return '11111111-1111-1111-1111-111111111111' }
        $result = Resolve-DesiredRoleGroupMemberIds -Members @(@{ displayName = 'sg-purview-compliance-administrators' }) -Resolver $resolver
        $result | Should -Be @('11111111-1111-1111-1111-111111111111')
    }

    It 'resolves a mixed list of raw OIDs and displayName entries in declared order' {
        $resolver = { param($displayName) return '22222222-2222-2222-2222-222222222222' }
        $result = Resolve-DesiredRoleGroupMemberIds `
            -Members @('00000000-0000-0000-0000-000000000000', @{ displayName = 'sg-purview-ediscovery-managers' }) `
            -Resolver $resolver
        $result | Should -Be @('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222')
    }

    It 'throws when the resolver reports "no match" (not-found) -- fail-closed, per issue #95' {
        $resolver = { param($displayName) throw "No Group found in Microsoft Entra with displayName '$displayName'. Create the principal or fix the YAML." }
        { Resolve-DesiredRoleGroupMemberIds -Members @(@{ displayName = 'sg-does-not-exist' }) -Resolver $resolver } | Should -Throw
    }

    It 'throws when the resolver reports ambiguity (more than one match) -- hard error, never first-match-wins' {
        $resolver = { param($displayName) throw "Multiple Groups found in Microsoft Entra with displayName '$displayName'. Display name must be unique for ADR 0023 resolution to succeed." }
        { Resolve-DesiredRoleGroupMemberIds -Members @(@{ displayName = 'sg-ambiguous' }) -Resolver $resolver } | Should -Throw
    }

    It 'throws on a mapping entry missing the required displayName field' {
        { Resolve-DesiredRoleGroupMemberIds -Members @(@{ notDisplayName = 'x' }) -Resolver { param($d) 'unused' } } | Should -Throw
    }

    It 'throws on an entry that is neither a string nor a mapping' {
        { Resolve-DesiredRoleGroupMemberIds -Members @(42) -Resolver { param($d) 'unused' } } | Should -Throw
    }

    It 'THE LOAD-BEARING REGRESSION: a resolution failure never returns a shrunk/partial member list alongside earlier successes' {
        # If the resolver's failure on the SECOND entry were caught and
        # `continue`d past (instead of thrown), this call would return a
        # one-element array containing only the first (successful)
        # resolution -- silently shrinking the desired set exactly the
        # way issue #95 forbids: under -PruneMissing, a shrunk desired
        # set is read as "revoke every real member of this role group".
        # Assert the whole call throws instead, so no partial array is
        # ever produced or consumed by a caller.
        $resolver = {
            param($displayName)
            if ($displayName -eq 'sg-ok') { return '55555555-5555-5555-5555-555555555555' }
            throw "No Group found in Microsoft Entra with displayName '$displayName'."
        }
        { Resolve-DesiredRoleGroupMemberIds -Members @(@{ displayName = 'sg-ok' }, @{ displayName = 'sg-missing' }) -Resolver $resolver } | Should -Throw
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- single-member Create path produces a scalar OID (issue #55)' {

    It 'call site does NOT wrap Resolve-DesiredRoleGroupMemberIds in an outer @() (regression guard)' {
        # issue #55: the outer @() double-wrapped the function's own
        # comma-idiom return value (`return , $result.ToArray()`), so a
        # single-member row produced a 1-element array whose sole element
        # was itself a 1-element string[] -- not a scalar OID -- by the
        # time it reached the write-phase Add-RoleGroupMember call. The
        # function's own comma-return already guarantees array-typed
        # output for 0/1/N elements; the caller must never re-wrap it.
        $script:ScriptText | Should -Not -Match '\$desiredMembers\s*=\s*@\(Resolve-DesiredRoleGroupMemberIds'
        $script:ScriptText | Should -Match '\$desiredMembers\s*=\s*Resolve-DesiredRoleGroupMemberIds\s+-Members\s+@\(\$rg\.members\)\s+-Resolver\s*\{'
    }

    It 'produces a scalar [string] $oid at the write-phase loop for a single-member row' {
        # Reproduces the real call site's exact shape (no outer @()) plus
        # the $toCreate construction (Where-Object piping, no deep
        # flatten), then walks $toCreate the same way the write-phase
        # foreach loop does.
        $resolver = { param($displayName) return $displayName }
        $rg = @{ members = @('11111111-1111-1111-1111-111111111111') }
        $desiredMembers = Resolve-DesiredRoleGroupMemberIds -Members @($rg.members) -Resolver $resolver
        $tenantSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $toCreate = @($desiredMembers | Where-Object { -not $tenantSet.Contains($_) })

        $toCreate.Count | Should -Be 1
        foreach ($oid in $toCreate) {
            $oid | Should -BeOfType [string]
            $oid | Should -Be '11111111-1111-1111-1111-111111111111'
        }
    }

    It 'produces scalar [string] $oid entries at the write-phase loop for a multi-member row (sanity, never broken)' {
        $resolver = { param($displayName) return $displayName }
        $rg = @{ members = @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') }
        $desiredMembers = Resolve-DesiredRoleGroupMemberIds -Members @($rg.members) -Resolver $resolver
        $tenantSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $toCreate = @($desiredMembers | Where-Object { -not $tenantSet.Contains($_) })

        $toCreate.Count | Should -Be 2
        foreach ($oid in $toCreate) {
            $oid | Should -BeOfType [string]
        }
        $toCreate | Should -Contain '11111111-1111-1111-1111-111111111111'
        $toCreate | Should -Contain '22222222-2222-2222-2222-222222222222'
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- member-resolution failure aborts the run (issue #95 regression)' {

    It 'wraps member resolution in try/catch that aborts via Write-Error + return, never continue' {
        # Source-text guard: the Phase 1 call site must catch a
        # Resolve-DesiredRoleGroupMemberIds failure and abort the WHOLE
        # run before any write -- a future refactor that swaps `return`
        # for `continue` here would silently reintroduce the
        # empty-desired-set / revoke-everything hazard under
        # -PruneMissing.
        $script:ScriptText | Should -Match (
            [regex]::Escape('catch {') + '\s*' +
            [regex]::Escape('Write-Error ("Failed to resolve declared member(s) for role group ''{0}'': {1}" -f $rgName, $_.Exception.Message)') + '\s*' +
            [regex]::Escape('return')
        )
    }

    It 'calls Resolve-DesiredRoleGroupMemberIds with a resolver closing over Get-EntraPrincipalIdByDisplayName.ps1' {
        $script:ScriptText | Should -Match 'Resolve-DesiredRoleGroupMemberIds\s+-Members\s+@\(\$rg\.members\)\s+-Resolver'
        $script:ScriptText | Should -Match '&\s+\$resolvePrincipalScript\s+-DisplayName\s+\$displayName\s+-Kind\s+''Group'''
    }

    It 'resolves the Get-EntraPrincipalIdByDisplayName.ps1 helper path and fails loudly if it is missing' {
        $script:ScriptText | Should -Match "Join-Path \`$scriptRoot 'Get-EntraPrincipalIdByDisplayName\.ps1'"
        $script:ScriptText | Should -Match "Helper not found: '\{0\}'"
    }

    It 'validates the static members shape (GUID or displayName mapping) before any tenant call' {
        $script:ScriptText | Should -Match 'Test-IsRoleMemberShapeValid -Value \$m'
    }
}

Describe 'Deploy-PurviewRoleGroups.ps1 -- -ExportCurrentState emits the displayName shape (issue #95)' {

    It 'captures each member''s displayName from Get-RoleGroupMember output without an extra round-trip' {
        $script:ScriptText | Should -Match '\$memberDisplayName = \[string\]\$m\.Name'
    }

    It 'falls back to the legacy raw-OID shape with a warning when a displayName is blank' {
        $script:ScriptText | Should -Match "Shape = 'oid'"
        $script:ScriptText | Should -Match "a member's displayName was blank during export"
    }

    It 'serializes a displayName-shape member as a quoted YAML displayName mapping' {
        $script:ScriptText | Should -Match ([regex]::Escape('$newBlock.Add(''      - displayName: "'' + $escapedName + ''"'')'))
    }

    It 'serializes a raw-OID-shape member as the bare dash-prefixed OID line, unchanged from prior behaviour' {
        $script:ScriptText | Should -Match '\(\s*"      - \{0\}"\s*-f\s*\$member\.Value\s*\)'
    }
}

# ---------------------------------------------------------------------------
# Issue #57: `RecipientTypeDetails -eq 'Group'` is not a real value in
# Microsoft's documented Get-Recipient / Get-RoleGroupMember enum under any
# auth mode -- both the -ExportCurrentState member loop and the -Apply
# read/diff filter used it and therefore NEVER matched a real Entra group.
# Fixed to check the documented values ('MailNonUniversalGroup',
# 'MailUniversalSecurityGroup') and to resolve `ExternalDirectoryObjectId`
# via the ADR 0023 displayName-resolution helper when it is empirically
# blank (confirmed live, both places), rather than trusting a property
# Microsoft's docs do not document population rules for.
#
# The two source blocks under test are extracted by anchor text (same
# pattern as the "Prune failure reporting executed through the script
# wiring" block below) and dot-sourced so their locally-declared variables
# ($memberEntries / $seenOids / $userCount, $tenantGroupOids / $tenantOidSet)
# are inspectable afterwards -- this exercises the REAL script source, not a
# reimplementation of it.
# ---------------------------------------------------------------------------
Describe 'Deploy-PurviewRoleGroups.ps1 -- RecipientTypeDetails classification (issue #57)' {

    BeforeAll {
        $script:RGLines = @(Get-Content -LiteralPath $script:ScriptPath)

        function Get-RoleGroupsSourceBlock {
            param([string]$StartPattern, [string]$EndPattern)
            $s = -1; $e = -1
            for ($i = 0; $i -lt $script:RGLines.Count; $i++) {
                if ($s -lt 0 -and $script:RGLines[$i] -match $StartPattern) { $s = $i; continue }
                if ($s -ge 0 -and $script:RGLines[$i] -match $EndPattern) { $e = $i; break }
            }
            if ($s -lt 0 -or $e -lt 0) {
                throw "Could not locate source block for pattern '$StartPattern' .. '$EndPattern'; update the anchor in this test."
            }
            return ($script:RGLines[$s..$e] -join [Environment]::NewLine)
        }

        # -ExportCurrentState per-role-group member classification loop.
        $script:ExportClassifyBlock = Get-RoleGroupsSourceBlock `
            -StartPattern '^\s*\$seenOids = \[System\.Collections\.Generic\.HashSet' `
            -EndPattern '^\s*\$userCount = @\(\$members'

        # -Apply read/diff phase tenant-group-OID detection.
        $script:ApplyClassifyBlock = Get-RoleGroupsSourceBlock `
            -StartPattern '^\s*\$tenantGroupMemberRows = @\(\$tenantMembers' `
            -EndPattern '^\s*\$tenantGroupOids = @\(\$tenantOidSet\)'
    }

    It 'no longer uses RecipientTypeDetails -eq ''Group'' as an actual filter condition (regression guard)' {
        # The literal string still appears in explanatory comments
        # documenting the old bug (issue #57) -- only the live
        # `Where-Object { $_.RecipientTypeDetails -eq 'Group' ...}` filter
        # shape is forbidden here.
        $script:ScriptText | Should -Not -Match "Where-Object\s*\{\s*\`$_\.RecipientTypeDetails\s*-eq\s*'Group'"
    }

    It 'both the export and apply filters check the documented Entra-security-group values' {
        ([regex]::Matches($script:ScriptText, "RecipientTypeDetails\s*-in\s*@\('MailNonUniversalGroup',\s*'MailUniversalSecurityGroup'\)")).Count | Should -BeGreaterOrEqual 2
    }

    Context '-ExportCurrentState member classification' {

        It 'PRIMARY REGRESSION PIN: recognizes a MailNonUniversalGroup member with a blank ExternalDirectoryObjectId, resolving the objectId via displayName' {
            $rg = @{ Name = 'TestRoleGroup' }
            $members = @(
                [pscustomobject]@{ Name = 'sg-purview-test-group'; RecipientTypeDetails = 'MailNonUniversalGroup'; ExternalDirectoryObjectId = $null }
            )
            $resolverCalls = New-Object 'System.Collections.Generic.List[string]'
            $resolvePrincipalScript = {
                param($DisplayName, $Kind)
                $resolverCalls.Add($DisplayName)
                return '11111111-1111-1111-1111-111111111111'
            }

            . ([scriptblock]::Create($script:ExportClassifyBlock))

            $memberEntries.Count | Should -Be 1
            $memberEntries[0].Shape | Should -Be 'displayName'
            $memberEntries[0].Value | Should -Be 'sg-purview-test-group'
            $resolverCalls | Should -Contain 'sg-purview-test-group'
            $userCount | Should -Be 0
        }

        It 'SANITY CASE: recognizes a MailUniversalSecurityGroup member and prefers a populated ExternalDirectoryObjectId over the resolver' {
            $rg = @{ Name = 'TestRoleGroup' }
            $members = @(
                [pscustomobject]@{ Name = 'sg-purview-other-group'; RecipientTypeDetails = 'MailUniversalSecurityGroup'; ExternalDirectoryObjectId = '22222222-2222-2222-2222-222222222222' }
            )
            $resolvePrincipalScript = { param($DisplayName, $Kind) throw 'resolver must not be invoked when ExternalDirectoryObjectId is already populated' }

            . ([scriptblock]::Create($script:ExportClassifyBlock))

            $memberEntries.Count | Should -Be 1
            $memberEntries[0].Shape | Should -Be 'displayName'
            $memberEntries[0].Value | Should -Be 'sg-purview-other-group'
        }

        It 'still ignores a non-group recipient (e.g. MailUser) on export, unchanged from prior behaviour' {
            $rg = @{ Name = 'TestRoleGroup' }
            $members = @(
                [pscustomobject]@{ Name = 'Marcus Jacobson'; RecipientTypeDetails = 'MailUser'; ExternalDirectoryObjectId = $null }
            )
            $resolvePrincipalScript = { param($DisplayName, $Kind) throw 'resolver must not be invoked for a non-group recipient' }

            . ([scriptblock]::Create($script:ExportClassifyBlock))

            $memberEntries.Count | Should -Be 0
            $userCount | Should -Be 1
        }
    }

    Context '-Apply read/diff phase tenant-group-OID detection' {

        It 'PRIMARY REGRESSION PIN: recognizes a MailNonUniversalGroup member with a blank ExternalDirectoryObjectId, resolving the objectId via displayName' {
            $rgName = 'TestRoleGroup'
            $tenantMembers = @(
                [pscustomobject]@{ Name = 'sg-purview-test-group'; RecipientTypeDetails = 'MailNonUniversalGroup'; ExternalDirectoryObjectId = $null }
            )
            $resolverCalls = New-Object 'System.Collections.Generic.List[string]'
            $resolvePrincipalScript = {
                param($DisplayName, $Kind)
                $resolverCalls.Add($DisplayName)
                return '33333333-3333-3333-3333-333333333333'
            }

            . ([scriptblock]::Create($script:ApplyClassifyBlock))

            $tenantGroupOids.Count | Should -Be 1
            $tenantGroupOids | Should -Contain '33333333-3333-3333-3333-333333333333'
            $resolverCalls | Should -Contain 'sg-purview-test-group'
        }

        It 'SANITY CASE: recognizes a MailUniversalSecurityGroup member and prefers a populated ExternalDirectoryObjectId over the resolver' {
            $rgName = 'TestRoleGroup'
            $tenantMembers = @(
                [pscustomobject]@{ Name = 'sg-purview-other-group'; RecipientTypeDetails = 'MailUniversalSecurityGroup'; ExternalDirectoryObjectId = '44444444-4444-4444-4444-444444444444' }
            )
            $resolvePrincipalScript = { param($DisplayName, $Kind) throw 'resolver must not be invoked when ExternalDirectoryObjectId is already populated' }

            . ([scriptblock]::Create($script:ApplyClassifyBlock))

            $tenantGroupOids.Count | Should -Be 1
            $tenantGroupOids | Should -Contain '44444444-4444-4444-4444-444444444444'
        }

        It 'confirms -PruneMissing revoke-candidate detection also sees the resolved OID, since $toRevoke is derived from this same $tenantGroupOids set' {
            # Before the fix, $tenantGroupOids was always empty, so
            # $toRevoke (= $tenantGroupOids where not in $desiredSet) could
            # never contain a real orphaned group membership either --
            # -PruneMissing's revoke path was silently defeated by the same
            # root cause. This is fixed as a side effect of this same
            # classification fix (no -PruneMissing behaviour change).
            $rgName = 'TestRoleGroup'
            $tenantMembers = @(
                [pscustomobject]@{ Name = 'sg-purview-orphan-group'; RecipientTypeDetails = 'MailNonUniversalGroup'; ExternalDirectoryObjectId = $null }
            )
            $resolvePrincipalScript = { param($DisplayName, $Kind) return '55555555-5555-5555-5555-555555555555' }

            . ([scriptblock]::Create($script:ApplyClassifyBlock))

            $desiredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $toRevoke = @($tenantGroupOids | Where-Object { -not $desiredSet.Contains($_) })

            $toRevoke | Should -Contain '55555555-5555-5555-5555-555555555555'
        }
    }
}

# ---------------------------------------------------------------------------
# Issue #13, part C batch 5: failure reporter ONLY. The ratio guard (guard 2)
# is deliberately NOT wired here -- role-group membership churn is legitimately
# high-ratio and this reconciler captures no single live-member denominator
# (owner decision) -- and its absence is pinned below. The revoke catch
# previously did Write-Error + return (first-failure abort). The reporter
# region is lifted from the REAL script source and executed against stubs.
# PRIVACY: this reconciler redacts principal object IDs ('<oid>'); the reporter
# tests assert no stub OID leaks into a failure message.
# ---------------------------------------------------------------------------
Describe 'Prune failure reporter wiring -- reporter only, guard 2 pinned absent (issue #13, batch 5)' {

    BeforeAll {
        $script:B5Source = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:B5Source | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:B5Source | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the failure reporter in the revoke catch' {
        $script:B5Source | Should -Match 'Write-PruneFailure'
        $script:B5Source | Should -Match '\$pruneFailures'
    }
    It 'does NOT wire guard 2 (owner decision: membership churn is legitimately high-ratio)' {
        $script:B5Source | Should -Not -Match 'Assert-PruneRatioWithinThreshold'
    }
    It 'does NOT acquire -AllowMajorityPrune / -MaxPruneRatio (no guard 2, no override surface)' {
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters.Keys | Should -Not -Contain 'AllowMajorityPrune'
        $cmd.Parameters.Keys | Should -Not -Contain 'MaxPruneRatio'
    }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 5)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-PurviewRoleGroups.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-PurviewRoleGroups.ps1; update the anchor in this test.' }
        $depth = 0; $e = -1
        for ($j = $ifStart; $j -lt $script:RepLines.Count; $j++) {
            $depth += ([regex]::Matches($script:RepLines[$j], '\{')).Count
            $depth -= ([regex]::Matches($script:RepLines[$j], '\}')).Count
            if ($depth -le 0) { $e = $j; break }
        }
        $script:ReporterRegion = ($script:RepLines[$s..$e] -join [Environment]::NewLine)
        $script:ReporterShouldProcessCount = ([regex]::Matches($script:ReporterRegion, '\$PSCmdlet\.ShouldProcess\(')).Count
        $script:ReporterRunnable = $script:ReporterRegion -replace '\$PSCmdlet\.ShouldProcess\(', '$ShouldProcessStub.ShouldProcess('

        # OID sentinel that must NEVER appear in any reporter output. A
        # fully-monotone synthetic GUID (ADR 0055 residue-scan-safe, like the
        # other synthetic OIDs in this file) and unused elsewhere here, so if
        # it surfaces in a failure message the redaction test below catches it.
        $script:SecretOid = '99999999-9999-9999-9999-999999999999'

        function Invoke-PruneRegion {
            # Each entry revokes the sentinel OID from one role group. $Fail lists
            # role-group names whose Remove throws a non-idempotent error;
            # $Idempotent lists names whose Remove throws MemberNotFoundException.
            param([string[]]$RoleGroups = @(), [string[]]$Fail = @(), [string[]]$Idempotent = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Remove-RoleGroupMember {
                # No explicit -Confirm param: [CmdletBinding(SupportsShouldProcess)]
                # already supplies it as a common parameter, and re-declaring it
                # is a "defined multiple times" binding error.
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$Identity, [string]$Member)
                $null = $Member
                $attempted.Add($Identity)
                if ($Idempotent -contains $Identity) { throw "MemberNotFoundException: not a member" }
                if ($Fail -contains $Identity) { throw "TenantBlockerException on $Identity" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($RoleGroups | ForEach-Object {
                    [pscustomobject]@{
                        RoleGroup = $_
                        ToCreate  = @()
                        ToRevoke  = @($script:SecretOid)
                    }
                })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $report, $plan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown }
        }
    }

    It 'attempts every revoke after a failure (no first-failure abort)' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1', 'rg2', 'rg3') -Fail @('rg1')
        $r.Attempted | Should -Be @('rg1', 'rg2', 'rg3')
    }
    It 'treats an idempotent MemberNotFoundException as a no-op, not a failure' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1', 'rg2') -Idempotent @('rg1')
        $r.Reported | Should -BeNullOrEmpty
        $r.Thrown   | Should -BeNullOrEmpty
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1', 'rg2') -Fail @('rg2')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException'
    }
    It 'throws one aggregate naming every failed role group (non-zero exit preserved)' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1', 'rg2', 'rg3') -Fail @('rg1', 'rg3')
        $r.Thrown | Should -Match 'rg1'
        $r.Thrown | Should -Match 'rg3'
        $r.Thrown | Should -Match '2 role-group member revoke'
    }
    It 'NEVER names a principal object ID in any reporter output (privacy: <oid> redaction)' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1') -Fail @('rg1')
        $r.Thrown       | Should -Not -Match ([regex]::Escape($script:SecretOid))
        ($r.Reported -join ' ') | Should -Not -Match ([regex]::Escape($script:SecretOid))
    }
    It 'throws nothing when every revoke succeeds' {
        $r = Invoke-PruneRegion -RoleGroups @('rg1', 'rg2')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the revoke behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the reporter and the aggregate throw in the lifted region (mutation check vs pre-batch first-failure abort)' {
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error.*Remove-RoleGroupMember'
    }
}
