#Requires -Version 7.4
<#
.SYNOPSIS
    Pure decision helper for the ADR 0029 source-of-truth direction policy.

.DESCRIPTION
    `Resolve-DirectionPolicyAction` maps the inputs `(Policy, SkipList,
    DisplayName, HasDrift)` to a `Skip` / `Update` decision plus a
    human-readable reason text. It is intentionally pure -- no Azure /
    Microsoft Graph / IPPS calls, no module imports beyond
    `Microsoft.PowerShell.Core`, no `$script:`-level state. This is
    what makes it unit-testable against a synthetic skip list without a
    tenant connection.

    Audit mode is handled by a per-script short-circuit (see ADR 0029
    "Audit-mode short-circuit" in each consumer `Deploy-*.ps1`) and does
    not enter this helper.

    Consumers:
      * `scripts/Deploy-Labels.ps1`
      * `scripts/Deploy-LabelPolicies.ps1`
      * (future) `scripts/Deploy-AutoLabelPolicies.ps1` -- issue #466
      * (future) every `Deploy-<Domain>.ps1` per ADR 0029 cross-domain
        rollout (issue #463).

    Each consumer imports the module via:

        Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
            -Force -Scope Local -ErrorAction Stop

    The skip-list match is case-insensitive to defend against casing
    mismatches between the workflow-side pre-computed list (parsed from
    `[ADR0029-SKIP] <DisplayName>` markers) and the YAML.

    References:
      ADR: docs/adr/0029-source-of-truth-direction-policy.md
      Rule: .github/instructions/powershell.instructions.md
            #direction-policy-contract-adr-0029
      PowerShell modules: https://learn.microsoft.com/en-us/powershell/scripting/developer/module/writing-a-windows-powershell-module
#>

function Resolve-DirectionPolicyAction {
    <#
    .SYNOPSIS
        Decide whether a shared-property drift entry should Skip or Update
        under the ADR 0029 source-of-truth direction policy.

    .DESCRIPTION
        Returns a hashtable @{ Action = 'Skip' | 'Update'; Reason = '<text>' }.

        Precedence:
          1. `SkipList` match (case-insensitive equality) -> Skip,
             reason "Explicitly skipped by caller ...".
          2. `Policy = 'portal-wins'` AND `HasDrift = $true` -> Skip,
             reason "Shared-property drift; preserved per portal-wins ...".
          3. Otherwise -> Update with empty reason.

        Audit mode is not represented here -- it short-circuits in the
        consumer script before the policy pass runs.

    .PARAMETER Policy
        One of 'portal-wins' or 'repo-wins'. The audit short-circuit in
        each consumer script means 'audit' never reaches this helper.

    .PARAMETER SkipList
        Caller-supplied display names to force-skip regardless of drift.
        Workflow-side: parsed from the enumerate pass's
        `[ADR0029-SKIP] <DisplayName>` markers, then threaded into the
        apply pass via `-SkipNames`.

    .PARAMETER DisplayName
        The object's display name (label, label policy, etc).

    .PARAMETER HasDrift
        $true when the consumer has detected shared-property drift
        between the desired YAML and the live tenant for this object.

    .OUTPUTS
        [hashtable] with keys `Action` ('Skip' | 'Update') and `Reason` (string).

    .EXAMPLE
        Resolve-DirectionPolicyAction `
            -Policy 'portal-wins' `
            -SkipList @() `
            -DisplayName 'Confidential' `
            -HasDrift $true
        # @{ Action = 'Skip'; Reason = 'Shared-property drift; ...' }

    .NOTES
        Reference: docs/adr/0029-source-of-truth-direction-policy.md
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('portal-wins', 'repo-wins')][string]$Policy,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SkipList,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][bool]$HasDrift
    )
    # SkipList match is case-insensitive to defend against casing
    # mismatches between the workflow's pre-computed list and the YAML.
    if ($SkipList -and ($SkipList | Where-Object { $_ -ieq $DisplayName })) {
        return @{
            Action = 'Skip'
            Reason = 'Explicitly skipped by caller (workflow pre-computed skip list).'
        }
    }
    if ($HasDrift -and $Policy -eq 'portal-wins') {
        return @{
            Action = 'Skip'
            Reason = 'Shared-property drift; preserved per portal-wins policy. Tenant edits win; open a drift-back PR via the matching sync-<domain>-from-tenant.yml workflow to surface the change in YAML.'
        }
    }
    return @{
        Action = 'Update'
        Reason = ''
    }
}

Export-ModuleMember -Function 'Resolve-DirectionPolicyAction'