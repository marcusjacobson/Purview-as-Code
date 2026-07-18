#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-EntraDirectoryRoles.ps1.

.DESCRIPTION
    Pins the ADR 0023 Category 3 dual-shape `members:` contract added by
    issue #95:

      1. `Test-IsRoleMemberShapeValid` accepts EITHER a raw Entra group
         object ID (GUID) string (legacy-but-still-supported) OR a
         mapping `{ displayName: <name> }` (recommended for new entries);
         anything else is rejected.
      2. `Resolve-DesiredRoleMemberIds` normalizes a row's `members:` list
         to a flat objectId array: a string entry passes through
         unchanged (the resolver is never invoked for it); a
         `displayName` entry is resolved via the caller-supplied
         -Resolver script block (production wires this to
         `scripts/Get-EntraPrincipalIdByDisplayName.ps1`).
      3. THE LOAD-BEARING REGRESSION (issue #95's single most important
         acceptance criterion): a resolution failure -- not found,
         ambiguous, or any other resolver error -- THROWS. It is never
         caught-and-`continue`d into a shrunk or empty member list, which
         is exactly the shape that would let `-PruneMissing` read
         "resolution failed" as "revoke every real assignment for this
         role" (the #92-adjacent hazard this issue exists to close).
      4. The Phase 1 call site in the production script catches that
         throw and aborts the WHOLE run (`return`), before any Phase 3
         write for ANY row -- never `continue`s past it.

    Pattern: functions are AST-extracted and evaluated directly (no
    resolver script, no Graph, no tenant); the Phase 1 abort-vs-continue
    contract is pinned by a source-text assertion, following the
    `tests/scripts/Deploy-PurviewRoleGroups.Tests.ps1` convention for this
    non-modular script family. Per tests/README.md "No script execution"
    -- the script shells out to az / Key Vault / Graph, so we never
    invoke its top-level body.

    Reference: docs/adr/0023-identifier-resolution.md
    Reference: scripts/Get-EntraPrincipalIdByDisplayName.ps1
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-EntraDirectoryRoles.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Deploy-EntraDirectoryRoles.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $script:ScriptText = Get-Content -LiteralPath $script:ScriptPath -Raw

    # AST-extract the functions under test. We deliberately do NOT
    # dot-source the script -- that would execute its top-level code and
    # attempt an `az login` / Key Vault / Graph round-trip.
    foreach ($fname in @('Test-IsGuid', 'Test-IsRoleMemberShapeValid', 'Resolve-DesiredRoleMemberIds')) {
        $fnAst = $script:Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }
}

Describe 'Test-IsRoleMemberShapeValid dual-shape validation (ADR 0023 Category 3, issue #95)' {

    It 'accepts a raw Entra group object ID (GUID) string' {
        Test-IsRoleMemberShapeValid -Value '00000000-0000-0000-0000-000000000000' | Should -BeTrue
    }

    It 'rejects a non-GUID string' {
        Test-IsRoleMemberShapeValid -Value 'sg-purview-compliance-admins' | Should -BeFalse
    }

    It 'accepts a { displayName: <name> } mapping' {
        Test-IsRoleMemberShapeValid -Value @{ displayName = 'sg-purview-compliance-admins' } | Should -BeTrue
    }

    It 'rejects a mapping missing the displayName key' {
        Test-IsRoleMemberShapeValid -Value @{ notDisplayName = 'sg-purview-compliance-admins' } | Should -BeFalse
    }

    It 'rejects a mapping with a blank displayName' {
        Test-IsRoleMemberShapeValid -Value @{ displayName = '   ' } | Should -BeFalse
    }

    It 'rejects a value that is neither a string nor a mapping' {
        Test-IsRoleMemberShapeValid -Value 42 | Should -BeFalse
    }
}

Describe 'Resolve-DesiredRoleMemberIds dual-shape resolution (ADR 0023 Category 3, issue #95)' {

    It 'passes a raw OID through unchanged and never invokes the resolver (back-compat regression)' {
        $resolver = { param($displayName) throw 'resolver must not be invoked for a raw-OID entry' }
        $result = Resolve-DesiredRoleMemberIds -Members @('00000000-0000-0000-0000-000000000000') -Resolver $resolver
        $result | Should -Be @('00000000-0000-0000-0000-000000000000')
    }

    It 'resolves a { displayName: } entry via the supplied resolver' {
        $resolver = { param($displayName) return '11111111-1111-1111-1111-111111111111' }
        $result = Resolve-DesiredRoleMemberIds -Members @(@{ displayName = 'sg-purview-compliance-admins' }) -Resolver $resolver
        $result | Should -Be @('11111111-1111-1111-1111-111111111111')
    }

    It 'resolves a mixed list of raw OIDs and displayName entries in declared order' {
        $resolver = { param($displayName) return '22222222-2222-2222-2222-222222222222' }
        $result = Resolve-DesiredRoleMemberIds `
            -Members @('00000000-0000-0000-0000-000000000000', @{ displayName = 'sg-purview-ip-admins' }) `
            -Resolver $resolver
        $result | Should -Be @('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222')
    }

    It 'resolves every entry independently when several displayName rows are declared' {
        $resolver = {
            param($displayName)
            switch ($displayName) {
                'sg-one' { return '33333333-3333-3333-3333-333333333333' }
                'sg-two' { return '44444444-4444-4444-4444-444444444444' }
            }
        }
        $result = Resolve-DesiredRoleMemberIds -Members @(@{ displayName = 'sg-one' }, @{ displayName = 'sg-two' }) -Resolver $resolver
        $result | Should -Be @('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444')
    }

    It 'throws when the resolver reports "no match" (not-found) -- fail-closed, per issue #95' {
        $resolver = { param($displayName) throw "No Group found in Microsoft Entra with displayName '$displayName'. Create the principal or fix the YAML." }
        { Resolve-DesiredRoleMemberIds -Members @(@{ displayName = 'sg-does-not-exist' }) -Resolver $resolver } | Should -Throw
    }

    It 'throws when the resolver reports ambiguity (more than one match) -- hard error, never first-match-wins' {
        $resolver = { param($displayName) throw "Multiple Groups found in Microsoft Entra with displayName '$displayName'. Display name must be unique for ADR 0023 resolution to succeed." }
        { Resolve-DesiredRoleMemberIds -Members @(@{ displayName = 'sg-ambiguous' }) -Resolver $resolver } | Should -Throw
    }

    It 'throws on a mapping entry missing the required displayName field' {
        { Resolve-DesiredRoleMemberIds -Members @(@{ notDisplayName = 'x' }) -Resolver { param($d) 'unused' } } | Should -Throw
    }

    It 'throws on an entry that is neither a string nor a mapping' {
        { Resolve-DesiredRoleMemberIds -Members @(42) -Resolver { param($d) 'unused' } } | Should -Throw
    }

    It 'THE LOAD-BEARING REGRESSION: a resolution failure never returns a shrunk/partial member list alongside earlier successes' {
        # If the resolver's failure on the SECOND entry were caught and
        # `continue`d past (instead of thrown), this call would return a
        # one-element array containing only the first (successful)
        # resolution -- silently shrinking the desired set exactly the
        # way issue #95 forbids. Assert the whole call throws instead, so
        # no partial array is ever produced or consumed by a caller.
        $resolver = {
            param($displayName)
            if ($displayName -eq 'sg-ok') { return '55555555-5555-5555-5555-555555555555' }
            throw "No Group found in Microsoft Entra with displayName '$displayName'."
        }
        { Resolve-DesiredRoleMemberIds -Members @(@{ displayName = 'sg-ok' }, @{ displayName = 'sg-missing' }) -Resolver $resolver } | Should -Throw
    }
}

Describe 'Deploy-EntraDirectoryRoles.ps1 -- member-resolution failure aborts the run (issue #95 regression)' {

    It 'wraps member resolution in try/catch that aborts via Write-Error + return, never continue' {
        # Source-text guard: the Phase 1 call site must catch a
        # Resolve-DesiredRoleMemberIds failure and abort the WHOLE run
        # before Phase 3 -- exactly the "any Phase 1 failure on any row
        # aborts the whole run" contract this script already uses for
        # role-definition resolution and assignment reads. A future
        # refactor that swaps `return` for `continue` here would
        # silently reintroduce the empty-desired-set / revoke-everything
        # hazard under -PruneMissing.
        $script:ScriptText | Should -Match (
            [regex]::Escape('catch {') + '\s*' +
            [regex]::Escape('Write-Error ("Failed to resolve declared member(s) for role ''{0}'': {1}" -f $rowName, $_.Exception.Message)') + '\s*' +
            [regex]::Escape('return')
        )
    }

    It 'calls Resolve-DesiredRoleMemberIds with a resolver closing over Get-EntraPrincipalIdByDisplayName.ps1' {
        $script:ScriptText | Should -Match 'Resolve-DesiredRoleMemberIds\s+-Members\s+@\(\$row\.members\)\s+-Resolver'
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

Describe 'Deploy-EntraDirectoryRoles.ps1 -- -ExportCurrentState emits the displayName shape (issue #95)' {

    It 'resolves each exported group''s displayName via Get-GroupDisplayName' {
        $script:ScriptText | Should -Match 'function Get-GroupDisplayName'
        $script:ScriptText | Should -Match 'Get-GroupDisplayName -PrincipalId \$oid -AccessToken \$accessToken'
    }

    It 'falls back to the legacy raw-OID shape with a warning when a displayName cannot be read' {
        $script:ScriptText | Should -Match "Shape = 'oid'"
        $script:ScriptText | Should -Match 'Write-Warning \("Group principal resolved as role-assignable but its displayName could not be read'
    }

    It 'serializes a displayName-shape member as a quoted YAML displayName mapping' {
        $script:ScriptText | Should -Match ([regex]::Escape('$newBlock.Add(''      - displayName: "'' + $escapedName + ''"'')'))
    }

    It 'serializes a raw-OID-shape member as the bare dash-prefixed OID line, unchanged from prior behaviour' {
        $script:ScriptText | Should -Match '\(\s*"      - \{0\}"\s*-f\s*\$member\.Value\s*\)'
    }
}
