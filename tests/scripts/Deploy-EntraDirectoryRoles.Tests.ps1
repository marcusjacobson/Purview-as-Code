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

Describe 'Deploy-EntraDirectoryRoles.ps1 -- single-member Create path produces a scalar OID (issue #55)' {

    It 'call site does NOT wrap Resolve-DesiredRoleMemberIds in an outer @() (regression guard)' {
        # issue #55: the outer @() double-wrapped the function's own
        # comma-idiom return value (`return , $result.ToArray()`), so a
        # single-member row produced a 1-element array whose sole element
        # was itself a 1-element string[] -- not a scalar OID -- by the
        # time it reached the write-phase primitive call. The function's
        # own comma-return already guarantees array-typed output for
        # 0/1/N elements; the caller must never re-wrap it.
        $script:ScriptText | Should -Not -Match '\$desiredMembers\s*=\s*@\(Resolve-DesiredRoleMemberIds'
        $script:ScriptText | Should -Match '\$desiredMembers\s*=\s*Resolve-DesiredRoleMemberIds\s+-Members\s+@\(\$row\.members\)\s+-Resolver\s*\{'
    }

    It 'produces a scalar [string] $oid at the write-phase loop for a single-member row' {
        # Reproduces the real call site's exact shape (no outer @()) plus
        # the $toCreate construction (Where-Object piping, no deep
        # flatten), then walks $toCreate the same way the write-phase
        # foreach loop does.
        $resolver = { param($displayName) return $displayName }
        $row = @{ members = @('11111111-1111-1111-1111-111111111111') }
        $desiredMembers = Resolve-DesiredRoleMemberIds -Members @($row.members) -Resolver $resolver
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
        $row = @{ members = @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') }
        $desiredMembers = Resolve-DesiredRoleMemberIds -Members @($row.members) -Resolver $resolver
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

# ---------------------------------------------------------------------------
# Issue #13, part C batch 5: guard 2 (with a NEW Phase-1 live-count
# accumulator) and the failure reporter. The revoke catch previously did
# Write-Error + return (first-failure abort). The regions below are lifted
# from the REAL script source (not transcribed) and executed against stubs,
# so the tests cannot keep passing after the script regresses.
# PRIVACY: this reconciler redacts principal object IDs everywhere ('<oid>');
# the reporter tests assert no stub OID leaks into a failure message.
# ---------------------------------------------------------------------------
Describe 'Prune guard 2 and failure reporter wiring (issue #13, batch 5)' {

    BeforeAll {
        $script:B5Source = Get-Content -LiteralPath $script:ScriptPath -Raw
    }

    It 'imports the shared PruneGuard module' {
        $script:B5Source | Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
    }
    It 'still calls guard 1 (empty-desired-set) -- earlier rollout not regressed' {
        $script:B5Source | Should -Match 'Assert-PruneDesiredSetNotEmpty'
    }
    It 'calls the sanity-ratio guard with the directory-role-assignment noun' {
        $script:B5Source | Should -Match 'Assert-PruneRatioWithinThreshold'
        $script:B5Source | Should -Match ([regex]::Escape("-ObjectTypeNoun 'directory role assignment'"))
    }
    It 'keys guard 2 on the Phase-1 live-assignment accumulator (denominator not materialized elsewhere)' {
        # The accumulator is initialized to 0 and incremented per row by the
        # deduplicated tenant-map count.
        $script:B5Source | Should -Match ([regex]::Escape('$liveAssignmentCount = 0'))
        $script:B5Source | Should -Match ([regex]::Escape('$liveAssignmentCount += $tenantMap.Count'))
        $script:B5Source | Should -Match ([regex]::Escape('-LiveCount      $liveAssignmentCount'))
    }
    It 'surfaces the ratio override and threshold parameters on the Apply parameter set' {
        $script:B5Source | Should -Match '\[switch\]\$AllowMajorityPrune'
        $script:B5Source | Should -Match '\[double\]\$MaxPruneRatio\s*=\s*0\.5'
        $cmd = Get-Command -Name $script:ScriptPath -CommandType ExternalScript
        $cmd.Parameters['AllowMajorityPrune'].ParameterSets.Keys | Should -Not -Contain 'Export'
        $cmd.Parameters['MaxPruneRatio'].ParameterSets.Keys | Should -Not -Contain 'Export'
    }
    It 'places guard 2 before the ADR 0052 confirmation gate' {
        $ratioIdx = $script:B5Source.IndexOf('Assert-PruneRatioWithinThreshold')
        $gateIdx  = $script:B5Source.IndexOf('Assert-DestructiveOperationConfirmed @gateArgs')
        $ratioIdx | Should -BeGreaterThan 0
        $gateIdx  | Should -BeGreaterThan 0
        $ratioIdx | Should -BeLessThan $gateIdx
    }
}

Describe 'Prune sanity-ratio guard executed through the script wiring (issue #13, batch 5)' {

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
        if ($start -lt 0) { throw 'Could not locate the guard-2 region in Deploy-EntraDirectoryRoles.ps1; update the anchor in this test.' }
        $script:Guard2Region = ($lines[$start..$end] -join [Environment]::NewLine)

        function Invoke-Guard2 {
            param([int]$Prune, [int]$Live, [double]$Max = 0.5, [switch]$Allow)
            $PruneMissing = [switch]$true
            $MaxPruneRatio = $Max
            $AllowMajorityPrune = [switch]$Allow
            $revokes = @(for ($i = 0; $i -lt $Prune; $i++) { "role-$i @ /" })
            $liveAssignmentCount = $Live
            $null = $PruneMissing, $MaxPruneRatio, $AllowMajorityPrune, $revokes, $liveAssignmentCount
            & ([scriptblock]::Create($script:Guard2Region)) 3>$null
        }
    }

    It 'passes below the threshold (2 of 10 live)' { { Invoke-Guard2 -Prune 2 -Live 10 } | Should -Not -Throw }
    It 'passes exactly at the threshold (5 of 10 live)' { { Invoke-Guard2 -Prune 5 -Live 10 } | Should -Not -Throw }
    It 'throws above the threshold (6 of 10 live)' { { Invoke-Guard2 -Prune 6 -Live 10 } | Should -Throw }
    It 'permits an over-threshold prune when -AllowMajorityPrune is supplied' { { Invoke-Guard2 -Prune 10 -Live 10 -Allow } | Should -Not -Throw }
    It 'honours a caller-supplied -MaxPruneRatio' { { Invoke-Guard2 -Prune 6 -Live 10 -Max 0.7 } | Should -Not -Throw }
}

Describe 'Prune failure reporting executed through the script wiring (issue #13, batch 5)' {

    BeforeAll {
        $script:RepLines = @(Get-Content -LiteralPath $script:ScriptPath)
        $s = -1
        for ($i = 0; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*\$pruneFailures = New-Object') { $s = $i; break }
        }
        if ($s -lt 0) { throw 'Could not locate the $pruneFailures declaration in Deploy-EntraDirectoryRoles.ps1; update the anchor in this test.' }
        $ifStart = -1
        for ($i = $s; $i -lt $script:RepLines.Count; $i++) {
            if ($script:RepLines[$i] -match '^\s*if \(\$pruneFailures\.Count -gt 0\) \{') { $ifStart = $i; break }
        }
        if ($ifStart -lt 0) { throw 'Could not locate the aggregate-throw block in Deploy-EntraDirectoryRoles.ps1; update the anchor in this test.' }
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
            # Each entry revokes one principal (the sentinel OID) at role@scope.
            # The tenant assignment id is "assign-<role>" (no reserved chars, so
            # EscapeDataString is a no-op and the stub can recover it from the
            # DELETE URI's last segment). $Fail lists assignment ids whose DELETE
            # throws a non-idempotent error; $Idempotent lists ids whose DELETE
            # throws a ResourceNotFound (already-gone) error.
            param([string[]]$Roles = @(), [string[]]$Fail = @(), [string[]]$Idempotent = @())
            $attempted = New-Object 'System.Collections.Generic.List[string]'
            $reported  = New-Object 'System.Collections.Generic.List[string]'
            function Invoke-EntraGraphRequest {
                param($Method, $Uri, $Body, $AccessToken)
                $null = $Body, $AccessToken
                if ($Method -ne 'DELETE') { throw "Unexpected non-DELETE call in revoke-only run: $Method $Uri" }
                $assignId = ($Uri -split '/')[-1]
                $attempted.Add($assignId)
                if ($Idempotent -contains $assignId) { throw "ResourceNotFound: assignment $assignId does not exist" }
                if ($Fail -contains $assignId) { throw "TenantBlockerException on $assignId" }
            }
            function Write-PruneFailure { param([Parameter(Position = 0)][string]$Message) $reported.Add($Message) }
            $PruneMissing = [switch]$true
            $graphBase = 'https://graph.unit.test/v1.0'
            $accessToken = 'unit-test-token'
            $report = New-Object 'System.Collections.Generic.List[object]'
            $plan = @($Roles | ForEach-Object {
                    $rn = $_
                    [pscustomobject]@{
                        RowName   = $rn
                        RowScope  = '/'
                        RoleDefId = 'roledef-1'
                        ToCreate  = @()
                        ToRevoke  = @($script:SecretOid)
                        TenantMap = @{ $script:SecretOid = ("assign-{0}" -f $rn) }
                    }
                })
            $ShouldProcessStub = [pscustomobject]@{}
            $ShouldProcessStub | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $null = $Target, $Action; $true }
            $null = $PruneMissing, $graphBase, $accessToken, $report, $plan, $ShouldProcessStub
            $thrown = $null
            try { & ([scriptblock]::Create($script:ReporterRunnable)) 6>$null 3>$null } catch { $thrown = $_.Exception.Message }
            [pscustomobject]@{ Attempted = $attempted.ToArray(); Reported = $reported.ToArray(); Thrown = $thrown; Report = $report.ToArray() }
        }
    }

    It 'attempts every revoke after a failure (no first-failure abort)' {
        $r = Invoke-PruneRegion -Roles @('r1', 'r2', 'r3') -Fail @('assign-r1')
        $r.Attempted | Should -Be @('assign-r1', 'assign-r2', 'assign-r3')
    }
    It 'treats an idempotent ResourceNotFound as a no-op, not a failure' {
        $r = Invoke-PruneRegion -Roles @('r1', 'r2') -Idempotent @('assign-r1')
        $r.Reported | Should -BeNullOrEmpty
        $r.Thrown   | Should -BeNullOrEmpty
    }
    It 'reports each failure with the tenant''s own error text' {
        $r = Invoke-PruneRegion -Roles @('r1', 'r2') -Fail @('assign-r2')
        $r.Reported.Count | Should -Be 1
        $r.Reported[0] | Should -Match 'TenantBlockerException'
    }
    It 'throws one aggregate naming every failed role @ scope (non-zero exit preserved)' {
        $r = Invoke-PruneRegion -Roles @('r1', 'r2', 'r3') -Fail @('assign-r1', 'assign-r3')
        $r.Thrown | Should -Match 'r1 @ /'
        $r.Thrown | Should -Match 'r3 @ /'
        $r.Thrown | Should -Match '2 directory-role assignment revoke'
    }
    It 'NEVER names a principal object ID in any reporter output (privacy: <oid> redaction)' {
        $r = Invoke-PruneRegion -Roles @('r1') -Fail @('assign-r1')
        $r.Thrown       | Should -Not -Match ([regex]::Escape($script:SecretOid))
        ($r.Reported -join ' ') | Should -Not -Match ([regex]::Escape($script:SecretOid))
    }
    It 'throws nothing when every revoke succeeds' {
        $r = Invoke-PruneRegion -Roles @('r1', 'r2')
        $r.Thrown   | Should -BeNullOrEmpty
        $r.Reported | Should -BeNullOrEmpty
    }
    It 'keeps the revoke behind a ShouldProcess gate (substitution non-vacuous)' {
        $script:ReporterShouldProcessCount | Should -BeGreaterThan 0
    }
    It 'carries the reporter and the aggregate throw in the lifted region (mutation check vs pre-batch first-failure abort)' {
        # Non-vacuous: the lift anchors on the $pruneFailures declaration,
        # which the pre-change file lacked entirely (revoke catch did
        # Write-Error + return).
        $script:ReporterRegion | Should -Match 'Write-PruneFailure'
        $script:ReporterRegion | Should -Match 'throw'
        $script:ReporterRegion | Should -Not -Match '(?m)^\s*Write-Error.*DELETE roleAssignments'
    }
}
