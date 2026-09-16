#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Guards the Key Vault firewall window-ownership contract (issues #306, #311).

.DESCRIPTION
    Eleven workflows open the ONE shared Key Vault firewall at the start of
    their tenant-touching job and close it in an `if: always()` step. Nothing
    serialises them, and one push can fan out to five.

    Two measured failure modes, needing different halves of the fix:

      #306 -- the first run to FINISH re-locks the vault while the others are
      still working. Handled by the re-open-and-retry in
      scripts/Get-PurviewIPPSAccessToken.ps1.

      #311 -- retry alone cannot save the LAST run standing, because every
      sibling re-locks on exit and that stream of re-locks lasts as long as the
      spread of finish times. Measured on dev run 34775754734: three attempts,
      three losses, each to the next sibling to finish. Handled by ownership --
      only the run that actually changed the vault from locked to open re-locks
      it.

    The contract this file pins:

      1. Every workflow with a restore step uses the shared composite action to
         open, rather than an inline `az keyvault update`.
      2. Its restore step fires only for a run that owns the window, by either
         route: it opened the vault, or the #306 retry re-opened one a sibling
         had closed.
      3. The action itself reads the posture before writing, and only claims
         ownership when it actually changed something.

    Workflows are DISCOVERED by the presence of the restore step, never listed,
    so a twelfth workflow that starts toggling the firewall is covered without
    editing this file -- the same rule DriftBackExportValidation.Tests.ps1 uses
    for export producers.

    Reference: https://docs.github.com/en/actions/sharing-automations/avoiding-duplication
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'

    # Discovery rule: a workflow that re-locks the vault must have opened it.
    $script:TogglingWorkflows = @(
        Get-ChildItem -LiteralPath $script:WorkflowsDir -Filter '*.yml' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Restore Key Vault network defaults' } |
            ForEach-Object { $_.Name }
    )
}

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github' 'workflows'
    $script:ActionPath = Join-Path $script:RepoRoot '.github' 'actions' 'open-key-vault-firewall' 'action.yml'

    # Recomputed for the run phase: BeforeDiscovery variables drive -ForEach at
    # discovery time and are not in scope inside an It.
    $script:DiscoveredToggling = @(
        Get-ChildItem -LiteralPath $script:WorkflowsDir -Filter '*.yml' -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Restore Key Vault network defaults' } |
            ForEach-Object { $_.Name }
    )
}

Describe 'The shared open action exists and is ownership-aware' {

    It 'the composite action is present' {
        Test-Path -LiteralPath $script:ActionPath | Should -BeTrue
    }

    It 'reads the vault posture BEFORE it writes' {
        # Without this read the `opened` output means "this job ran the open
        # command", which is true for every run -- the pre-#311 defect.
        # Compare the COMMANDS, not any mention: the header comment cites the
        # az keyvault update reference doc long before either command appears.
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $readAt = $text.IndexOf('$state = az keyvault show')
        $writeAt = $text.IndexOf('az keyvault update `')
        $readAt | Should -BeGreaterThan -1
        $writeAt | Should -BeGreaterThan -1
        $readAt | Should -BeLessThan $writeAt
    }

    It 'claims ownership only when it actually opened the vault' {
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $text | Should -Match "opened=false"
        $text | Should -Match "opened=true"
    }

    It 'judges openness through the testable module, not an inline predicate' {
        # The inline version required defaultAction -eq 'Allow' and was
        # therefore dead code against a vault that reads back 'None'. It
        # shipped inert because nothing could unit-test it (issue #315).
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $text | Should -Match 'Import-Module \./scripts/modules/KeyVaultFirewall\.psm1'
        $text | Should -Match 'Test-KeyVaultIsOpen'
        # Anchored to the assignment, not the phrase: the third source guard
        # today to be defeated by its own change's explanatory comment.
        $text | Should -Not -Match '(?m)^\s*\$alreadyOpen = \('
    }

    It 'treats a ConflictError as a signal that another run won the open' {
        # Read-once cannot deduplicate a simultaneous fan-out: on dev run
        # 34778953168 all five runs read 'Disabled/Deny' before any of them
        # had written. The conflict is the only ownership signal available in
        # that case, so it must be acted on rather than just retried.
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $text | Should -Match 'was opened by another run while this one was writing'
    }

    It 'retries the open on ConflictError rather than failing the run' {
        # Five runs writing to one vault within seconds makes ARM reject the
        # losers; observed on dev run 34774457895 (issue #311).
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $text | Should -Match 'ConflictError'
    }

    It 'fails OPEN if the posture read does not work' {
        # A role without Microsoft.KeyVault/vaults/read must degrade to the
        # pre-#311 unconditional open, not to a job that cannot start.
        $text = Get-Content -LiteralPath $script:ActionPath -Raw
        $text | Should -Match 'Falling back to an unconditional open'
    }
}

Describe 'Every firewall-toggling workflow honours the ownership contract' {

    It 'discovers the toggling workflows by their restore step, not a hard-coded list' {
        $script:DiscoveredToggling.Count | Should -BeGreaterThan 0
    }

    Context 'in <_>' -ForEach $script:TogglingWorkflows {

        BeforeAll {
            $script:WorkflowText = Get-Content -LiteralPath (Join-Path $script:WorkflowsDir $_) -Raw
        }

        It 'opens through the shared composite action' {
            $script:WorkflowText | Should -Match 'uses: \./\.github/actions/open-key-vault-firewall'
        }

        It 'no longer opens the vault with an inline az keyvault update' {
            # Red-replay of the pre-#311 shape. The restore step still uses
            # `az keyvault update` to re-lock, so this asserts on the Enabled
            # form specifically.
            $script:WorkflowText | Should -Not -Match '--public-network-access Enabled'
        }

        It 'restores only when this run owns the window' {
            $script:WorkflowText | Should -Match "steps\.kv-open\.outputs\.opened == 'true'"
        }

        It 'also restores when the #306 retry re-opened the vault' {
            # Without this clause a run whose retry re-opened the vault would
            # leave it open with nobody owning it, because the run that first
            # opened it has already re-locked and finished.
            $script:WorkflowText | Should -Match "env\.KV_REOPENED_BY_RETRY == 'true'"
        }

        It 'keeps the restore on always(), so a failed job still re-locks' {
            $script:WorkflowText | Should -Match 'if: always\(\) && \(steps\.kv-open\.outputs\.opened'
        }
    }
}

Describe 'The script side sets the flag the restore step reads' {

    It 'writes KV_REOPENED_BY_RETRY when the retry re-opens the vault' {
        $script = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts' 'Get-PurviewIPPSAccessToken.ps1') -Raw
        $script | Should -Match 'KV_REOPENED_BY_RETRY=true'
        $script | Should -Match '\$null = Set-KeyVaultReopenedFlag'
    }

    It 'suppresses the helper return value so it cannot pollute the output stream' {
        # A bare call returns the helper's boolean alongside the certificate
        # JSON, and the caller parses @($false, '{"cer":...}').
        $script = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts' 'Get-PurviewIPPSAccessToken.ps1') -Raw
        $script | Should -Not -Match '(?m)^\s+Set-KeyVaultReopenedFlag\s*$'
    }
}
