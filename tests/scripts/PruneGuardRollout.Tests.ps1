#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester source-ordering tests for the rollout of guard 1
    (`Assert-PruneDesiredSetNotEmpty`) across the twenty `Deploy-*.ps1`
    reconcilers that implement `-PruneMissing`. Issue #13, part B.

.DESCRIPTION
    `tests/scripts/PruneGuard.Tests.ps1` pins the BEHAVIOUR of the shared
    module and its first consumer, `Deploy-Labels.ps1`. This file pins the
    ROLLOUT: that every other reconciler imports the module, calls guard 1,
    and -- the part that actually matters -- calls it before it touches the
    tenant.

    WHY SOURCE ORDERING RATHER THAN EXECUTION
    -----------------------------------------
    The property under test is "the guard runs before the first tenant
    contact". Proving that by execution needs an authenticated session and a
    real Purview/Graph endpoint, which makes it a live-tenant test; even
    `-WhatIf` does not help, because the reconcilers reach `az account show`
    and `Connect-IPPSSession` before any `ShouldProcess` call. The ordering
    is a static property of the file, so it is asserted statically. The
    guard's runtime behaviour is already covered by PruneGuard.Tests.ps1
    against the module directly.

    FIRST-TENANT-CONTACT ANCHORS
    ----------------------------
    The anchor is per-script and deliberately written as the CALL SITE, not
    just the cmdlet name, because:

      * `az account show` and `Connect-IPPSSession` both appear far earlier
        in every script's comment-based help, and
      * the Graph scripts DEFINE `Get-GraphToken` (whose body contains
        `az account get-access-token`) above the point where they INVOKE it.

    Matching the definition or the help text instead of the invocation would
    make the assertion vacuously fail, or worse, vacuously pass.

    SCRIPTS DELIBERATELY NOT COVERED HERE
    -------------------------------------
    `Deploy-Labels.ps1` -- covered by PruneGuard.Tests.ps1 as the reference
    implementation.

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #13
#>

BeforeDiscovery {
    # Each row: the reconciler, the regex matching its FIRST tenant contact
    # (see the anchor rationale in the file header), and the object-type noun
    # the guard is expected to report. The noun is asserted so a copy-paste
    # rollout that leaves the wrong noun behind -- the most likely silent
    # error in a twenty-file change -- fails here rather than in a CI log
    # that says "zero sensitivity labels" during a retention-policy run.
    $script:PruneGuardConsumers = @(
        @{ Script = 'Deploy-AdaptiveScopes';              Contact = '^\$accountJson = az account show';                      Noun = 'adaptive scope' }
        @{ Script = 'Deploy-AdministrativeUnits';         Contact = '^\$token\s+= Get-GraphToken';                           Noun = 'administrative unit' }
        @{ Script = 'Deploy-AutoLabelPolicies';           Contact = '^\$accountJson = az account show';                      Noun = 'auto-labeling policy or rule' }
        @{ Script = 'Deploy-Classifications';             Contact = '^\$accountJson = az account show';                      Noun = 'classification type or rule' }
        @{ Script = 'Deploy-Collections';                 Contact = '^\$accountJson = az account show';                      Noun = 'collection' }
        @{ Script = 'Deploy-CommunicationCompliance';     Contact = '^\$accountJson = az account show';                      Noun = 'communication compliance policy' }
        @{ Script = 'Deploy-DLPPolicies';                 Contact = '^\$accountJson = az account show';                      Noun = 'DLP policy' }
        @{ Script = 'Deploy-DataSources';                 Contact = '^\$accountJson = az account show';                      Noun = 'data source' }
        @{ Script = 'Deploy-EntraDirectoryRoles';         Contact = '^\$accountJson = az account show';                      Noun = 'directory role assignment' }
        @{ Script = 'Deploy-FilePlan';                    Contact = '^\$accountJson = az account show';                      Noun = 'file plan property or retention label' }
        @{ Script = 'Deploy-Glossary';                    Contact = '^\$accountJson = az account show';                      Noun = 'glossary term' }
        @{ Script = 'Deploy-IRMEntityLists';              Contact = '^\$accountJson = az account show';                      Noun = 'IRM entity list' }
        @{ Script = 'Deploy-IRMPolicies';                 Contact = '^\$accountJson = az account show';                      Noun = 'insider risk management policy' }
        @{ Script = 'Deploy-LabelPolicies';               Contact = '^\$accountJson = az account show';                      Noun = 'label policy' }
        @{ Script = 'Deploy-PurviewRoleGroups';           Contact = '^\$accountJson = az account show';                      Noun = 'role group' }
        @{ Script = 'Deploy-RetentionPolicies';           Contact = '^\$accountJson = az account show';                      Noun = 'retention policy' }
        @{ Script = 'Deploy-RoleGroupBackingEntraGroups'; Contact = '^\$token\s+= Get-GraphToken';                           Noun = 'backing Entra security group' }
        @{ Script = 'Deploy-Scans';                       Contact = '^\$accountJson = az account show';                      Noun = 'scan or scan ruleset' }
        @{ Script = 'Deploy-UnifiedCatalog';              Contact = 'Get-UnifiedCatalogApiContext -AccountName \$AccountName'; Noun = 'Unified Catalog item' }
        @{ Script = 'Deploy-UnifiedCatalogPolicies';      Contact = 'Get-UnifiedCatalogApiContext -AccountName \$AccountName'; Noun = 'data access policy assignment' }
    )
}

BeforeAll {
    $script:RepoRoot   = Join-Path $PSScriptRoot '..' '..'
    $script:ScriptsDir = Join-Path $script:RepoRoot 'scripts'

    # Index of the first line matching $Pattern, or -1. Returned as a line
    # number so failure messages point at something an operator can open.
    function Get-FirstMatchLine {
        param(
            # AllowEmptyString: a source file is full of blank lines, and a
            # Mandatory [string[]] rejects empty elements.
            [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
            [Parameter(Mandatory)][string]$Pattern
        )
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match $Pattern) { return $i + 1 }
        }
        return -1
    }
}

Describe 'Guard 1 rollout across the -PruneMissing reconcilers' {

    Context '<Script>' -ForEach $script:PruneGuardConsumers {

        BeforeAll {
            $script:Path = Join-Path $script:ScriptsDir ("{0}.ps1" -f $Script)
            $script:Lines = @(Get-Content -LiteralPath $script:Path)
            $script:Source = $script:Lines -join "`n"
        }

        It 'imports the shared PruneGuard module' {
            # Anchored on the Import-Module statement so the prose references
            # to the module path in the guard's own comment block do not
            # satisfy this on their own.
            $script:Source |
                Should -Match "Import-Module \(Join-Path \`$PSScriptRoot 'modules[\\/]PruneGuard\.psm1'\)"
        }

        It 'calls Assert-PruneDesiredSetNotEmpty exactly once' {
            # Exactly once: a second call would mean a merge duplicated the
            # block, and two guards on different counts is a contradiction
            # rather than defence in depth.
            $matched = [regex]::Matches($script:Source, 'Assert-PruneDesiredSetNotEmpty\s+`')
            $matched.Count | Should -Be 1
        }

        It 'reports the object-type noun <Noun>' {
            $script:Source | Should -Match ([regex]::Escape("-ObjectTypeNoun '$Noun'"))
        }

        It 'gates the guard on the -PruneMissing switch' {
            # The guard must be about the destructive branch only: an empty
            # desired-state file is a legitimate no-op on a create-only run.
            $guardLine = Get-FirstMatchLine -Lines $script:Lines -Pattern 'Assert-PruneDesiredSetNotEmpty\s+`'
            $guardLine | Should -BeGreaterThan 0

            # Walk back to the nearest enclosing `if (` -- the guard is always
            # the first statement of its own block.
            $conditionLine = $null
            for ($i = $guardLine - 2; $i -ge 0; $i--) {
                if ($script:Lines[$i] -match '^\s*if \(') { $conditionLine = $script:Lines[$i]; break }
            }
            $conditionLine | Should -Not -BeNullOrEmpty
            $conditionLine | Should -Match '\$PruneMissing'
        }

        It 'calls the guard before the first tenant contact' {
            # The whole point of the guard: a refusal that happens after
            # `az account show` or a token acquisition has already leaked the
            # run into the tenant's auth path, and a refusal that happens
            # after Connect-* is no protection at all.
            $guardLine   = Get-FirstMatchLine -Lines $script:Lines -Pattern 'Assert-PruneDesiredSetNotEmpty\s+`'
            $contactLine = Get-FirstMatchLine -Lines $script:Lines -Pattern $Contact

            $guardLine   | Should -BeGreaterThan 0
            $contactLine | Should -BeGreaterThan 0 -Because "the tenant-contact anchor '$Contact' must still exist in $Script; if the script was restructured, update the anchor in this test"
            $guardLine   | Should -BeLessThan $contactLine -Because "the guard at line $guardLine must precede the first tenant contact at line $contactLine in $Script"
        }
    }
}

Describe 'Guard 2 and the failure reporter are only where they were analysed' {

    # Issue #13 part B wired guard 1 only. Guard 2's denominator is the LIVE
    # object count, which each script obtains differently (and some obtain in
    # pages, or per-collection), so binding it still needs per-script analysis
    # and is deliberately deferred everywhere it has not been done. Pinning its
    # absence keeps a future copy-paste from wiring it without that analysis.
    #
    # Write-PruneFailure targets a collect-then-throw prune loop, which is a
    # per-script restructure of the prune loop. Both guard 2 and the reporter
    # were analysed and wired into a growing set of reconcilers:
    #
    #   * Deploy-AutoLabelPolicies (part C, PR #18) -- reporter only; its two
    #     prune loops (rules, then policies) obtain no single live denominator,
    #     so guard 2 stayed deferred there.
    #   * Deploy-AdaptiveScopes and Deploy-LabelPolicies (part C) -- the two
    #     clean "mechanical mirror" cases with a single live denominator
    #     (@($tenantScopes).Count / @($tenantPolicies).Count), so both guard 2
    #     AND the reporter were wired.
    #   * Deploy-Glossary, Deploy-DataSources, Deploy-CommunicationCompliance,
    #     Deploy-IRMEntityLists, Deploy-IRMPolicies (part C batch 2) -- the
    #     report-row reconcilers whose prune failure path previously did
    #     Add-Report 'Failed' + continue but never threw an aggregate (a failed
    #     prune exited 0); the reporter now collects failures and throws one
    #     aggregate (behaviour change: failed prune exits non-zero), and guard 2
    #     is wired against each script's single live denominator.
    #   * Deploy-Scans (part C batch 2) -- REPORTER ONLY. A scan/trigger
    #     teardown legitimately prunes a majority, so the ratio guard does not
    #     fit; guard 2 stays deferred there (owner decision).
    #   * Deploy-AdministrativeUnits and Deploy-RoleGroupBackingEntraGroups
    #     (part C batch 3) -- the two Graph reconcilers whose apply phase is a
    #     mixed Create/Update/Delete switch that previously had NO try/catch
    #     (under $ErrorActionPreference='Stop' the first failed delete
    #     terminated the run); a try/catch was introduced around the delete,
    #     the reporter collects failures with one aggregate throw, and guard 2
    #     is keyed on each script's single live denominator (@($current).Count).
    #   * Deploy-Classifications, Deploy-DLPPolicies, Deploy-RetentionPolicies,
    #     Deploy-FilePlan (part C batch 4) -- the multi-loop reconcilers whose
    #     prune catches added a 'Failed' report row but never threw (a failed
    #     prune exited 0); each gains the reporter with ONE $pruneFailures
    #     across all prune passes and an aggregate throw (inside the try, so
    #     the IPPS finally still disconnects). Guard 2 is wired PER TIER
    #     (rules vs policies / types) in the first three, because a blended
    #     ratio can mask a single-collection wipe; the audit-mode two gate it
    #     on $DirectionPolicy -ne 'audit'. Deploy-FilePlan is REPORTER-ONLY:
    #     a file-plan teardown legitimately prunes a majority (owner decision).
    #   * Deploy-EntraDirectoryRoles, Deploy-PurviewRoleGroups (part C batch 5)
    #     -- the two membership-revoke reconcilers whose revoke catch did
    #     Write-Error + return (first-failure abort). Both gain the reporter
    #     with the aggregate throw inside the enclosing try (token scrub / IPPS
    #     disconnect preserved) and preserve their idempotent-not-found
    #     downgrade branch. EntraDirectoryRoles ALSO gains guard 2, keyed on a
    #     NEW Phase-1 live-assignment accumulator ($liveAssignmentCount) since
    #     its denominator is not materialized in one place. Deploy-PurviewRoleGroups
    #     is REPORTER-ONLY: membership churn is legitimately high-ratio and no
    #     single live-member denominator is captured (owner decision).
    #   * Deploy-UnifiedCatalog, Deploy-UnifiedCatalogPolicies (part C batch 6)
    #     -- the two Unified Catalog reconcilers. UnifiedCatalog gains the
    #     reporter (the non-404 delete catch now collects instead of rethrowing;
    #     the post-cascade 404 tolerance is unchanged) plus PER-KIND guard 2
    #     over the six $tenantState.* collections (key results via the flat
    #     $keyResultTenant list), gated on $DirectionPolicy -ne 'audit'.
    #     UnifiedCatalogPolicies gains a POLICY-LEVEL reporter (revokes fold into
    #     a per-policy PUT, so the unit is the policy PUT) plus guard 2 on the
    #     prune plan over the live assignment set (no audit conjunct needed --
    #     Invoke-DirectionPolicyPlan empties the plan under audit).
    #   * Deploy-Collections (part C batch 7, the FINAL reconciler) -- the Orphan
    #     delete catch added a 'Failed' report row but never threw (a failed prune
    #     exited 0); the catch now also calls Write-PruneFailure and collects, and
    #     an aggregate throw after the apply loop exits non-zero. REPORTER-ONLY:
    #     a collection subtree teardown legitimately prunes a majority (owner
    #     decision), so guard 2 does not fit. No audit/WhatIf reporter gate is
    #     needed -- under audit the script flips $WhatIfPreference, so the DELETE
    #     ShouldProcess returns false and the catch never runs.
    #
    # With batch 7 the rollout is COMPLETE: the reporter is wired in all twenty
    # reconcilers. Guard 2 is pinned absent only where it does not fit --
    # Deploy-AutoLabelPolicies, Deploy-Scans, Deploy-FilePlan,
    # Deploy-PurviewRoleGroups and Deploy-Collections (reporter-only, five of
    # twenty). Adding a script to either allow-list is the conscious act that
    # records the per-script analysis having been done -- do not widen either
    # list casually.

    BeforeAll {
        # Guard 2 needs a live-object denominator (single, per-tier, per-kind, or
        # the EntraDirectoryRoles accumulator), which these fifteen of the twenty
        # rolled-out reconcilers expose.
        $script:Guard2AllowList = @(
            'Deploy-AdaptiveScopes', 'Deploy-LabelPolicies',
            'Deploy-Glossary', 'Deploy-DataSources', 'Deploy-CommunicationCompliance',
            'Deploy-IRMEntityLists', 'Deploy-IRMPolicies',
            'Deploy-AdministrativeUnits', 'Deploy-RoleGroupBackingEntraGroups',
            'Deploy-Classifications', 'Deploy-DLPPolicies', 'Deploy-RetentionPolicies',
            'Deploy-EntraDirectoryRoles',
            'Deploy-UnifiedCatalog', 'Deploy-UnifiedCatalogPolicies'
        )
        # The reporter (collect-then-throw prune loop) is now wired in ALL twenty
        # rolled-out reconcilers: the fifteen guard-2 scripts above plus
        # Deploy-AutoLabelPolicies (PR #18), Deploy-Scans, Deploy-FilePlan,
        # Deploy-PurviewRoleGroups and Deploy-Collections (reporter-only, no guard 2).
        $script:ReporterAllowList = @(
            'Deploy-AutoLabelPolicies', 'Deploy-AdaptiveScopes', 'Deploy-LabelPolicies',
            'Deploy-Glossary', 'Deploy-DataSources', 'Deploy-CommunicationCompliance',
            'Deploy-IRMEntityLists', 'Deploy-IRMPolicies', 'Deploy-Scans',
            'Deploy-AdministrativeUnits', 'Deploy-RoleGroupBackingEntraGroups',
            'Deploy-Classifications', 'Deploy-DLPPolicies', 'Deploy-RetentionPolicies',
            'Deploy-FilePlan', 'Deploy-EntraDirectoryRoles', 'Deploy-PurviewRoleGroups',
            'Deploy-UnifiedCatalog', 'Deploy-UnifiedCatalogPolicies', 'Deploy-Collections'
        )
        $script:RolloutScriptCount = 20
    }

    It 'only the analysed reconcilers call Assert-PruneRatioWithinThreshold' -ForEach $script:PruneGuardConsumers {
        $source = Get-Content -LiteralPath (Join-Path $script:ScriptsDir ("{0}.ps1" -f $Script)) -Raw
        if ($Script -in $script:Guard2AllowList) {
            $source | Should -Match 'Assert-PruneRatioWithinThreshold\s+`'
        }
        else {
            $source | Should -Not -Match 'Assert-PruneRatioWithinThreshold\s+`'
        }
    }

    It 'only the analysed reconcilers call Write-PruneFailure' -ForEach $script:PruneGuardConsumers {
        $source = Get-Content -LiteralPath (Join-Path $script:ScriptsDir ("{0}.ps1" -f $Script)) -Raw
        if ($Script -in $script:ReporterAllowList) {
            $source | Should -Match 'Write-PruneFailure\s'
        }
        else {
            $source | Should -Not -Match 'Write-PruneFailure\s'
        }
    }

    It 'permits only the analysed exceptions, so the tripwire still covers the rest' {
        # Guards the guard: if a later change widens either allow-list, this
        # count fails and the widening has to be argued for in review. The
        # reporter rollout is COMPLETE (all 20); guard 2 is pinned absent on the
        # 5 reconcilers where a majority prune is legitimate.
        $script:Guard2AllowList.Count   | Should -Be 15
        $script:ReporterAllowList.Count | Should -Be 20
        $script:RolloutScriptCount      | Should -Be 20
    }
}
