#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/modules/TenantContextGuard.psm1, the
    shared issue #215 az-context-vs-parameters-file tenant guard (the #41
    incident guard).

.DESCRIPTION
    Two layers, matching the convention this repo already uses for
    az-calling code (see Invoke-LocalIrmDriftSync.Tests.ps1's own
    docstring: "impure helpers ... are pinned only by static-source
    assertions below, not by behaviour tests" -- no test in this repo
    mocks the `az` executable, and this suite does not start):

      1. BEHAVIOUR -- Test-TenantDomainMatch is pure over its inputs (the
         caller is responsible for producing $Tenants and $CurrentTenantId
         from live `az` calls), so it is exercised directly against
         synthetic tenant lists. These tests were moved here, unchanged,
         from Invoke-LocalIrmDriftSync.Tests.ps1 and
         Invoke-LocalDlpDriftSync.Tests.ps1, which carried byte-identical
         copies before this module existed.
      2. STATIC-SOURCE -- Assert-TenantContextMatchesParametersFile calls
         `az rest` directly, so it is pinned by source assertions instead:
         that it calls `az rest` (not a process-invocation helper, so
         importing this module adds no new dependency for callers that
         don't already use one), that its confirmation goes through
         Write-Information rather than Write-Host (the #124/#231 lesson:
         a caller whose stdout is a machine-readable payload must never
         have this land in it), and -- the reason for the extraction, not
         just a moved copy -- that the throw message's command-name
         quoting is genuinely NOT PowerShell backtick-escaping. Both
         scripts this was extracted from carried the exact same bug: a
         double-quoted string wrapping `az account set --subscription
         <name>` in backticks, where `` `a `` is PowerShell's recognized
         escape for the alert/BEL control character, not a literal
         backtick -- so the "a" in "az" silently became an invisible BEL
         and the closing backtick before the trailing space vanished too.
         Reproduced directly below before asserting the fix.

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #41 (the incident this guard is named for)
    Reference: issue #215 (this extraction)
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModulePath = Join-Path $script:RepoRoot 'scripts' 'modules' 'TenantContextGuard.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate TenantContextGuard.psm1 at: $script:ModulePath"
    }
    $script:ModuleSource = Get-Content -LiteralPath $script:ModulePath -Raw
    Import-Module $script:ModulePath -Force -ErrorAction Stop

    # Synthetic tenant IDs (reserved 00000000-0000-0000-0000-<counter>
    # namespace, ADR 0055) and .example domains (RFC 2606) -- never real
    # tenant identifiers, per the ADR 0055 residue scan.
    $script:LabTenantId = '00000000-0000-0000-0000-000000000001'
    $script:DevTenantId = '00000000-0000-0000-0000-000000000002'
    $script:Tenants = @(
        [pscustomobject]@{
            tenantId      = $script:LabTenantId
            defaultDomain = 'contoso-lab.example'
            domains       = @('contosolab.onmicrosoft.example', 'contoso-lab.example')
        },
        [pscustomobject]@{
            tenantId      = $script:DevTenantId
            defaultDomain = 'contoso-dev.example'
            domains       = @('contosodev.onmicrosoft.example', 'contoso-dev.example')
        }
    )
}

Describe 'Test-TenantDomainMatch' {
    It 'matches on defaultDomain' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeTrue
    }

    It 'matches on a domains[] entry that is not the default' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contosolab.onmicrosoft.example' | Should -BeTrue
    }

    It 'matches case-insensitively' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId.ToUpper() -ExpectedDomain 'CONTOSO-LAB.EXAMPLE' | Should -BeTrue
    }

    It 'returns $false when the tenant matches but the domain does not (wrong tenant, the #41 trap)' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:DevTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }

    It 'returns $false when the current tenant ID is absent from the list' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId '00000000-0000-0000-0000-000000000000' -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }

    It 'returns $false for an empty tenants list' {
        Test-TenantDomainMatch -Tenants @() -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }
}

Describe 'Assert-TenantContextMatchesParametersFile -- static-source checks (az-calling, not unit-testable per this repo''s convention)' {
    BeforeAll {
        # Anchored to the two executable statements, not the module's own
        # explanatory prose (its .DESCRIPTION discusses Invoke-ChildProcess
        # and the backtick bug by name, which would make a whole-file regex
        # match the comment instead of the code -- same lesson
        # Get-UpstreamDelta.Tests.ps1 already applies: "anchored to a
        # statement, not a mention").
        $script:AzRestLine = (($script:ModuleSource -split "`r?`n") | Where-Object { $_ -match '^\s*\$tenantsJson = az rest' })
        $script:ThrowMismatchLine = (($script:ModuleSource -split "`r?`n") | Where-Object { $_ -match '^\s*throw .*does not resolve to the expected tenant domain' })
        $script:AzRestLine | Should -Not -BeNullOrEmpty -Because 'the az rest call site must exist for the rest of this Describe to test anything real'
        $script:ThrowMismatchLine | Should -Not -BeNullOrEmpty -Because 'the mismatch throw statement must exist for the rest of this Describe to test anything real'
    }

    It 'calls az rest directly (not a process-invocation helper), pinned to the ARM tenants API version literal' {
        # This exact assertion used to live in Invoke-LocalIrmDriftSync.Tests.ps1
        # and Invoke-LocalDlpDriftSync.Tests.ps1, when each carried the inline
        # az rest call this module now owns. Moved here with the code, not
        # deleted -- the literal genuinely lives in this file now.
        $script:AzRestLine | Should -Match "az rest --method get --url 'https://management\.azure\.com/tenants\?api-version=2022-12-01'"
        $script:AzRestLine | Should -Not -Match 'Invoke-ChildProcess' -Because 'importing this module must add no new dependency for a caller that does not already route az calls through that helper'
    }

    It 'confirms success via Write-Information, never Write-Host (#124/#231 lesson)' {
        $calls = @([regex]::Matches($script:ModuleSource, '(?m)^\s*(Write-Host)\b') | ForEach-Object { $_.Value.Trim() })
        $calls | Should -BeNullOrEmpty -Because "Write-Host writes to stdout under pwsh -File, which a caller capturing this script's own -AsJson-style output must never see"
        $script:ModuleSource | Should -Match "Write-Information \(.az context OK"
    }

    It 'the mismatch throw statement quotes the remediation command with plain quotes, not backticks (regression: both scripts this was extracted from silently ate the "a" in "az")' {
        # `` `a `` inside a double-quoted string is PowerShell's recognized
        # escape for the alert/BEL control character, not a literal
        # backtick -- so a double-quoted throw wrapping the remediation
        # command in backticks silently corrupted it. Assert the fix
        # directly against the executable statement: the corrected
        # single-quoted form is present, and the backtick-quoted form the
        # bug shipped as is gone.
        $script:ThrowMismatchLine | Should -Match ([regex]::Escape("'az account set --subscription <name>'")) -Because 'the remediation command must be quoted with plain single quotes'
        $script:ThrowMismatchLine | Should -Not -Match '`az account set' -Because 'a backtick immediately before "az" reproduces the BEL-corruption bug (`a is the alert-character escape, not a literal backtick)'
    }

    It 'red-replay: reproduces the backtick-corruption bug directly, to prove the assertion above is not vacuous' {
        # Non-vacuity pattern used across this repo's suites: prove the
        # *fixture* actually exhibits the defect being guarded against,
        # not just that the shipped source happens to look right.
        $buggy = "Run `az account set --subscription <name>` for the dev environment first."
        $buggy | Should -Not -Match 'Run az account set' -Because 'the backtick-escaped form must NOT read as the literal command -- if it did, this fixture would no longer reproduce the defect this test exists to catch'
        $fixed = ('Run {0}az account set --subscription <name>{0} for the dev environment first.' -f "'")
        $fixed | Should -Match 'Run .az account set --subscription <name>. for the dev environment first\.'
    }
}

Describe 'Every Deploy-*.ps1 reconciler that can bind the guard imports and calls it (issue #215 rollout, widened by #235)' {
    BeforeAll {
        # Same discovery pattern validate.yml's "Full-circle reconciler
        # contract guard" job already uses (Get-ChildItem -Filter
        # 'Deploy-*.ps1'), so a future new reconciler is picked up
        # automatically.
        #
        # This list started at nine exemptions under #215, when three
        # genuinely different tenant-identity architectures were found and
        # only one of them fit this guard's plumbing. #235 investigated the
        # other two and closed all nine:
        #
        #   1. az account show + az ad app list + Get-PurviewIPPSAccessToken.ps1,
        #      resolving $TenantDomain from -ParametersFile's
        #      automation.tenantDomain -- 13 reconcilers, wired under #215.
        #      This is the architecture issue #215 was filed against.
        #   2. Connect-Purview.ps1-based -- the five classic Data Map
        #      reconcilers and the two Unified Catalog ones. All seven
        #      already accepted -ParametersFile, and automation.tenantDomain
        #      is present in every parameters file, so the guard bound to
        #      them unchanged. Wired under #235. The Unified Catalog pair
        #      needed it most: their endpoint is the GLOBAL
        #      api.purview-service.microsoft.com, so the token's tenant was
        #      the only thing deciding which tenant they wrote to.
        #   3. Graph-token direct against the equally global
        #      https://graph.microsoft.com/v1.0 (Deploy-AdministrativeUnits.ps1,
        #      Deploy-RoleGroupBackingEntraGroups.ps1). These two took no
        #      -ParametersFile at all, so nothing declared which tenant a run
        #      was meant for and there was no value to compare against --
        #      the one gap no edit confined to those files could close. They
        #      were also the highest-risk of the nine: global endpoint plus a
        #      DELETE path under -PruneMissing, run only by hand. #235 added
        #      -ParametersFile to both and wired the guard.
        #
        # The list is now EMPTY, and that is the assertion: every
        # Deploy-*.ps1 in this repository verifies its az context against a
        # declared environment before contacting a tenant. It is kept as a
        # hashtable rather than deleted so a future architecture that
        # genuinely cannot bind the guard has a documented place to go --
        # with a reason, the way validate.yml's own exempt list works --
        # instead of the discovery glob being narrowed silently.
        $script:ArchitectureExempt = @{}
        $script:Reconcilers = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter 'Deploy-*.ps1' -File |
                Where-Object { -not $script:ArchitectureExempt.ContainsKey($_.Name) })
        $script:AllReconcilers = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'scripts') -Filter 'Deploy-*.ps1' -File)
        $script:Reconcilers.Count | Should -BeGreaterThan 0 -Because 'the discovery glob itself must find something, or every It below passes vacuously'
        $script:Reconcilers.Count | Should -Be $script:AllReconcilers.Count -Because 'the exempt list is empty as of #235: every Deploy-*.ps1 must be in scope, so a re-exemption has to be argued for here rather than slipping in'
    }

    It 'every non-exempt reconciler imports TenantContextGuard.psm1' {
        # Anchored to an EXECUTABLE Import-Module statement, not a bare
        # mention of the file name. A whole-file substring match would be
        # satisfied by the module's name appearing in a comment -- the same
        # 'anchored to a statement, not a mention' lesson this file already
        # applies to its own static-source checks above, and that
        # Get-UpstreamDelta.Tests.ps1 established. Caught by red-replay
        # under #235: commenting out a wired guard left both this assertion
        # and the one below still passing.
        $missing = @($script:Reconcilers | Where-Object {
                (Get-Content -LiteralPath $_.FullName -Raw) -notmatch '(?m)^\s*Import-Module .*TenantContextGuard\.psm1'
            } | ForEach-Object { $_.Name })
        $missing | Should -BeNullOrEmpty -Because "these reconcilers resolve tenant identity from az without the #215 guard: $($missing -join ', ')"
    }

    It 'every non-exempt reconciler calls Assert-TenantContextMatchesParametersFile' {
        # Executable call site only -- see the note above. A commented-out
        # guard is exactly the regression this assertion exists to catch,
        # so it must not be satisfied by the name inside a comment.
        $missing = @($script:Reconcilers | Where-Object {
                (Get-Content -LiteralPath $_.FullName -Raw) -notmatch '(?m)^\s*Assert-TenantContextMatchesParametersFile\b'
            } | ForEach-Object { $_.Name })
        $missing | Should -BeNullOrEmpty -Because "importing the module is not enough on its own -- these reconcilers never call the guard: $($missing -join ', ')"
    }

    It 'the guard call resolves ExpectedDomain from a variable, not a hardcoded literal (would silently defeat the whole guard)' {
        $bad = @($script:Reconcilers | Where-Object {
                $src = Get-Content -LiteralPath $_.FullName -Raw
                $m = [regex]::Match($src, 'Assert-TenantContextMatchesParametersFile[\s\S]*?-ExpectedDomain\s+(\S+)')
                $m.Success -and ($m.Groups[1].Value -notmatch '^\$')
            } | ForEach-Object { $_.Name })
        $bad | Should -BeNullOrEmpty -Because "these reconcilers pass a non-variable -ExpectedDomain, which would compare against itself and always pass: $($bad -join ', ')"
    }

    It 'no exempted file has quietly grown the IPPS-pattern shape this guard fits (staleness check on the exempt list itself)' {
        # Mirrors validate.yml's own exempt-list staleness concern: an
        # exemption reason is a claim about a specific file's shape at
        # the time it was written, and shapes drift. If an exempt file
        # ever grows the exact pattern the wired reconcilers share,
        # this fails loudly instead of the guard silently staying absent
        # from a file that now needs it.
        $staleExemptions = @()
        foreach ($name in $script:ArchitectureExempt.Keys) {
            $path = Join-Path $script:RepoRoot 'scripts' $name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $src = Get-Content -LiteralPath $path -Raw
            if ($src -match 'az ad app list' -and $src -match '\$TenantDomain\s*=\s*\[string\]\$parameters\.automation\.tenantDomain') {
                $staleExemptions += $name
            }
        }
        $staleExemptions | Should -BeNullOrEmpty -Because "these exempted files now have the IPPS-pattern shape this guard fits -- update the exempt list and wire the guard: $($staleExemptions -join ', ')"
    }
    It 'the seven reconcilers widened into scope by #235 are covered, not quietly re-exempted' {
        # The exempt list is the one thing that can silently shrink this
        # contract back down: re-adding a name here would make every
        # assertion above stop looking at that file, and still pass. These
        # seven were exempt under #215 and wired under #235 because each
        # accepts -ParametersFile, whose automation block carries
        # tenantDomain. Name them explicitly so a future edit to the exempt
        # list has to argue with a test rather than slip through.
        $widenedByIssue235 = @(
            'Deploy-Classifications.ps1'
            'Deploy-Collections.ps1'
            'Deploy-DataSources.ps1'
            'Deploy-Glossary.ps1'
            'Deploy-Scans.ps1'
            'Deploy-UnifiedCatalog.ps1'
            'Deploy-UnifiedCatalogPolicies.ps1'
            # The two Graph-token reconcilers, wired last because closing
            # their gap needed a new -ParametersFile on an operator-facing
            # interface rather than a two-line edit. Global Graph endpoint
            # plus DELETE under -PruneMissing, so re-exempting one of these
            # is the most expensive mistake this list can absorb.
            'Deploy-AdministrativeUnits.ps1'
            'Deploy-RoleGroupBackingEntraGroups.ps1'
        )
        $reExempted = @($widenedByIssue235 | Where-Object { $script:ArchitectureExempt.ContainsKey($_) })
        $reExempted | Should -BeNullOrEmpty -Because "#235 wired these; re-exempting one silently drops it from every assertion above: $($reExempted -join ', ')"

        $discovered = @($script:Reconcilers | ForEach-Object { $_.Name })
        $notDiscovered = @($widenedByIssue235 | Where-Object { $_ -notin $discovered })
        $notDiscovered | Should -BeNullOrEmpty -Because "the discovery glob must actually reach these files for the assertions above to cover them: $($notDiscovered -join ', ')"
    }
}

Describe 'Test-TenantDomainEvidenceAvailable -- no evidence is not contrary evidence (#225 follow-up)' {
    # The #215 guard shipped treating an unresolvable domain as a MISMATCH,
    # and broke every CI data-plane run the moment it rolled out: the ARM
    # /tenants endpoint answers a USER principal richly (defaultDomain +
    # domains[]) but tells a SERVICE PRINCIPAL almost nothing, so an
    # OIDC-federated run threw against its own CORRECT tenant.
    # Caught live on sync-labels-from-tenant.yml run 34141626934.
    #
    # Failing open on absent evidence does not reopen #41: that incident is
    # a stale INTERACTIVE session, and a user context is exactly the case
    # ARM answers fully -- so a wrong tenant is still found, still has
    # domains, still fails to match, and still throws. CI has no ambient
    # session to drift; its tenant is pinned by the federated credential.

    BeforeAll {
        $script:UserShaped = @([pscustomobject]@{
                tenantId = $script:LabTenantId
                defaultDomain = 'contoso-lab.example'
                domains = @('contosolab.onmicrosoft.example', 'contoso-lab.example')
            })
        # What a service principal typically sees: its own tenant absent, or
        # present with no domain fields at all.
        $script:SpShapedNoFields = @([pscustomobject]@{ tenantId = $script:LabTenantId })
        $script:SpShapedEmpty = @([pscustomobject]@{ tenantId = $script:LabTenantId; defaultDomain = ''; domains = @() })
    }

    It 'reports evidence when ARM returns the current tenant with domains' {
        Test-TenantDomainEvidenceAvailable -Tenants $script:UserShaped -CurrentTenantId $script:LabTenantId | Should -BeTrue
    }

    It 'reports NO evidence when the current tenant is absent from the list' {
        Test-TenantDomainEvidenceAvailable -Tenants $script:UserShaped -CurrentTenantId $script:DevTenantId | Should -BeFalse
    }

    It 'reports NO evidence when the tenant is present but carries no domain properties' {
        # Regression anchor for a bug in this very function: @($null).Count
        # is 1, not 0, so an unguarded count on a missing `domains` property
        # reported evidence that does not exist. Caught by exercising it
        # rather than by reading it.
        Test-TenantDomainEvidenceAvailable -Tenants $script:SpShapedNoFields -CurrentTenantId $script:LabTenantId | Should -BeFalse
    }

    It 'reports NO evidence for an empty defaultDomain and an empty domains array' {
        Test-TenantDomainEvidenceAvailable -Tenants $script:SpShapedEmpty -CurrentTenantId $script:LabTenantId | Should -BeFalse
    }

    It 'reports NO evidence for an empty tenants list' {
        Test-TenantDomainEvidenceAvailable -Tenants @() -CurrentTenantId $script:LabTenantId | Should -BeFalse
    }

    It 'the guard WARNS and returns on absent evidence, but still THROWS on a resolved mismatch' {
        # Static-source, per this repo's no-mocking-az convention. Anchored
        # to the two executable branches, not to the prose above them.
        $evidenceBranch = (($script:ModuleSource -split "`r?`n") |
            Where-Object { $_ -match 'if \(-not \(Test-TenantDomainEvidenceAvailable' })
        $evidenceBranch | Should -Not -BeNullOrEmpty -Because 'the guard must consult the evidence check before asserting a mismatch'
        $script:ModuleSource | Should -Match 'Write-Warning \("Could not verify the az context' -Because 'absent evidence must degrade to a warning, or every service-principal run fails against a correct tenant'
        $script:ThrowMismatchLine | Should -Not -BeNullOrEmpty -Because 'the mismatch throw must survive: failing open on absent evidence must not become failing open on a real mismatch'
    }
}
