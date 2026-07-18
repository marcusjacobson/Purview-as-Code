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

    Pattern: AST + text assertions. Per tests/README.md "No script
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

    It 'filters tenant members to Group recipients with non-null ExternalDirectoryObjectId' {
        $script:ScriptText | Should -Match "RecipientTypeDetails\s*-eq\s*'Group'\s*-and\s*\`$_\.ExternalDirectoryObjectId"
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
