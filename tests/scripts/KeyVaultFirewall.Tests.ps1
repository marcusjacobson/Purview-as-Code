#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/modules/KeyVaultFirewall.psm1 (issue #315).

.DESCRIPTION
    The ownership predicate shipped INERT in #314 because it was inline in a
    composite action and therefore untestable. It required
    `defaultAction -eq 'Allow'`, and the dev vault reads that property back as
    `None` once open, so the already-open branch was dead code and all five
    runs in the #314 merge fan-out claimed ownership of the same window.

    Every posture string asserted here is one actually observed in a run log,
    or the explicit negative it has to be distinguished from. Assuming a
    read-back value is what caused the defect, so these cases are written
    against what the service returned, not against what the CLI was asked for.

    Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'KeyVaultFirewall.psm1'
    if (-not (Test-Path -LiteralPath $script:ModulePath)) {
        throw "Could not locate KeyVaultFirewall.psm1 at: $script:ModulePath"
    }
    Import-Module $script:ModulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module KeyVaultFirewall -Force -ErrorAction SilentlyContinue
}

Describe 'Test-KeyVaultIsOpen' {

    Context 'Postures observed on the live dev vault' {

        It 'treats Enabled/None as OPEN -- the defect that made #314 inert' {
            # What `az keyvault show` returns after
            # `--public-network-access Enabled --default-action Allow` on a
            # vault with no network rules. Four runs read exactly this on
            # 2026-09-13 19:52 and every one of them still claimed the window.
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Enabled' -DefaultAction 'None' | Should -BeTrue
        }

        It 'treats Disabled/Deny as NOT open -- the steady state' {
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Disabled' -DefaultAction 'Deny' | Should -BeFalse
        }
    }

    Context 'Postures that are plausible and must be judged correctly' {

        It 'treats Enabled/Allow as open' {
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Enabled' -DefaultAction 'Allow' | Should -BeTrue
        }

        It 'treats Enabled/Deny as NOT open' {
            # publicNetworkAccess alone is not enough: an explicit Deny default
            # still refuses anything no IP rule admits, so claiming this vault
            # is reachable would skip an open that is genuinely needed.
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Enabled' -DefaultAction 'Deny' | Should -BeFalse
        }

        It 'treats Enabled with an empty defaultAction as open' {
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Enabled' -DefaultAction '' | Should -BeTrue
        }

        It 'is case-insensitive on both properties' {
            Test-KeyVaultIsOpen -PublicNetworkAccess 'enabled' -DefaultAction 'none' | Should -BeTrue
            Test-KeyVaultIsOpen -PublicNetworkAccess 'ENABLED' -DefaultAction 'DENY' | Should -BeFalse
        }

        It 'tolerates surrounding whitespace from a TSV read' {
            Test-KeyVaultIsOpen -PublicNetworkAccess " Enabled`t" -DefaultAction ' None ' | Should -BeTrue
        }
    }

    Context 'No evidence is not evidence of openness' {

        It 'returns false for an empty or null publicNetworkAccess' {
            # An unreadable posture must send the caller down its fail-open
            # path. Returning true here would skip the open entirely and every
            # run would then fail at its first data-plane call.
            Test-KeyVaultIsOpen -PublicNetworkAccess '' -DefaultAction 'None' | Should -BeFalse
            Test-KeyVaultIsOpen -PublicNetworkAccess $null -DefaultAction 'None' | Should -BeFalse
            Test-KeyVaultIsOpen -PublicNetworkAccess '   ' -DefaultAction 'None' | Should -BeFalse
        }

        It 'returns false for an unexpected publicNetworkAccess value' {
            Test-KeyVaultIsOpen -PublicNetworkAccess 'Somethingelse' -DefaultAction 'Allow' | Should -BeFalse
        }
    }
}

Describe 'ConvertFrom-KeyVaultPostureTsv' {

    It 'splits the two-column TSV az returns' {
        $p = ConvertFrom-KeyVaultPostureTsv -Tsv "Enabled`tNone"
        $p.PublicNetworkAccess | Should -Be 'Enabled'
        $p.DefaultAction | Should -Be 'None'
    }

    It 'splits on runs of whitespace as well as a tab' {
        $p = ConvertFrom-KeyVaultPostureTsv -Tsv 'Disabled    Deny'
        $p.PublicNetworkAccess | Should -Be 'Disabled'
        $p.DefaultAction | Should -Be 'Deny'
    }

    It 'returns empty fields for empty, whitespace or null input' {
        foreach ($input in @('', '   ', $null)) {
            $p = ConvertFrom-KeyVaultPostureTsv -Tsv $input
            $p.PublicNetworkAccess | Should -Be ''
            $p.DefaultAction | Should -Be ''
        }
    }

    It 'never throws on junk, so a diagnostic cannot become an outage' {
        { ConvertFrom-KeyVaultPostureTsv -Tsv 'ERROR: (Forbidden) something went wrong' } | Should -Not -Throw
    }

    It 'round-trips into the predicate as NOT open for an unreadable posture' {
        $p = ConvertFrom-KeyVaultPostureTsv -Tsv ''
        Test-KeyVaultIsOpen -PublicNetworkAccess $p.PublicNetworkAccess -DefaultAction $p.DefaultAction |
            Should -BeFalse
    }
}
