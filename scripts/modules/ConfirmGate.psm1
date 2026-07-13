#Requires -Version 7.4
<#
.SYNOPSIS
    Destructive-operation confirmation gate for the `Deploy-*.ps1`
    reconcilers, per ADR 0052.

.DESCRIPTION
    `Assert-DestructiveOperationConfirmed` is the single script-layer gate
    that stands in front of the two destructive branches every reconciler
    can take:

      * the `-PruneMissing` **delete** branch (orphan tenant objects), and
      * the `-DirectionPolicy repo-wins` **overwrite** branch (tenant
        fields replaced with YAML values).

    It calls `$PSCmdlet.ShouldContinue()` -- NOT `$PSCmdlet.ShouldProcess()`.
    That distinction is the whole point of this module and must not be
    "simplified" away:

      `ShouldProcess` prompts only when the cmdlet's `ConfirmImpact` is
      greater than or equal to the caller's `$ConfirmPreference`. The
      PowerShell default for `$ConfirmPreference` is `High`. Every
      reconciler in this repo shipped `ConfirmImpact = 'Medium'`, and
      `Medium < High`, so every `ShouldProcess` call returned `$true`
      **without ever prompting**. The confirmation the contract mandated
      was dead code from the day it was written (issue #85).

      `ShouldContinue` has no impact/preference comparison at all. It
      prompts unconditionally whenever it is reached. It therefore cannot
      be silently defeated by an impact/preference mismatch, which is
      exactly the failure this module exists to prevent.

    Reaching the gate is the caller's job; the caller must not reach it
    under `-WhatIf` (see `-IsWhatIf` below).

    Suppression, in precedence order:

      1. `-IsWhatIf`  -- a dry run never prompts. Returns `$true` so the
         branch is still WALKED and the per-write `ShouldProcess` calls
         inside it emit their "What if:" preview lines. A gate that
         returned `$false` here would silently hide the very deletions
         `-WhatIf` exists to preview.
      2. `-Force`     -- the operator's explicit "do not ask me" switch.
      3. `-Confirm:$false` explicitly bound by the caller -- the
         unattended / CI path. Every workflow apply step passes this, so
         raising `ConfirmImpact` to `High` cannot hang CI.

    Note that `$ConfirmPreference` is deliberately NOT consulted. Honouring
    it would re-introduce the exact defect this module fixes.

    The `yesToAll` / `noToAll` reference pair is threaded through by the
    caller and SHARED across both gates within a single run, so a run that
    trips both the overwrite gate and the prune gate prompts once and
    carries the answer forward. One prompt per run, never one per object.

    Consumers (ADR 0052 reference implementations):
      * `scripts/Deploy-Labels.ps1`
      * `scripts/Deploy-FilePlan.ps1`
      * `scripts/Deploy-DLPPolicies.ps1`

    Rollout to the remaining 18 reconcilers is issue #83; the repo-wide
    guard test that asserts no reconciler ships `ConfirmImpact = 'Medium'`
    is issue #84.

    Each consumer imports the module via:

        Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
            -Force -Scope Local -ErrorAction Stop

    References:
      ADR:  docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
      ADR:  docs/adr/0029-source-of-truth-direction-policy.md
      Rule: .github/instructions/powershell.instructions.md
            #destructive-operation-confirmation-gate-adr-0052
      ShouldContinue: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.cmdlet.shouldcontinue
      Everything about ShouldProcess: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      about_Preference_Variables ($ConfirmPreference): https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables
#>

function Assert-DestructiveOperationConfirmed {
    <#
    .SYNOPSIS
        Prompt once, per run, before a reconciler executes a destructive
        branch. Returns $true to proceed, $false to decline.

    .DESCRIPTION
        Wraps `$PSCmdlet.ShouldContinue($Query, $Caption, [ref]$YesToAll,
        [ref]$NoToAll)` -- the four-argument overload -- so the operator's
        "Yes to All" / "No to All" answer carries across every gate in the
        run.

        Returns `$true` when the caller may proceed with the destructive
        branch, `$false` when the operator declined.

    .PARAMETER Cmdlet
        The calling script's `$PSCmdlet`. Required because `ShouldContinue`
        is an instance method on the caller's cmdlet object -- the prompt
        must be raised against the caller's host, not the module's.

        Typed `[object]` rather than `[System.Management.Automation.PSCmdlet]`
        so the unit tests can inject a stub exposing a `ShouldContinue`
        ScriptMethod. A real `PSCmdlet` cannot raise a prompt under a
        non-interactive Pester run, so a hard type here would make the
        prompt-emission path -- the single most important behaviour in this
        module -- untestable. The parameter is contract-checked below: an
        object with no `ShouldContinue` method throws immediately.

    .PARAMETER Caption
        Short prompt caption, e.g. 'Destructive operation'.

    .PARAMETER Query
        The full question shown to the operator. Must name the object
        count and the irreversible effect, e.g.
        'Delete 3 orphan sensitivity label(s) from the tenant? This cannot be undone.'

    .PARAMETER YesToAll
        `[ref]` to the caller's run-scoped `$yesToAll` boolean. When it is
        already `$true` on entry the gate returns `$true` without
        prompting.

    .PARAMETER NoToAll
        `[ref]` to the caller's run-scoped `$noToAll` boolean. When it is
        already `$true` on entry the gate returns `$false` without
        prompting.

    .PARAMETER Force
        The caller's `-Force` switch value. Suppresses the prompt.

        Per ADR 0052, `-Force` on a reconciler has exactly one meaning,
        stated at the level of abstraction that covers both parameter
        sets: "suppress the safety guard that would otherwise block or
        question this operation."

          * Apply mode  -- the guard is this confirmation prompt.
          * Export mode -- the guard is `-ExportCurrentState`'s refusal to
            clobber a non-empty managed block in the target YAML.

        The two never overlap: the destructive gates live only in the
        Apply parameter set, the YAML-clobber guard only in the Export
        parameter set.

        The third historical meaning -- "allow overwriting objects whose
        `lastModifiedBy` is not the current deploy principal" -- is
        RETIRED by ADR 0052, not reassigned. It was never implemented in
        any of the 21 reconcilers because the IPPS / S&C cmdlets do not
        return a `lastModifiedBy` to diff against. If a future Purview
        surface exposes one, it gets its OWN switch
        (`-OverwriteForeignAuthor`); it must not be folded back onto
        `-Force`.

    .PARAMETER IsWhatIf
        The caller's `$WhatIfPreference`. A dry run must never block on
        input, so the gate returns `$true` without prompting and lets the
        per-write `ShouldProcess` calls inside the branch render the
        preview.

    .PARAMETER ConfirmBound
        `$true` when the caller was invoked with an explicit `-Confirm`
        (either `-Confirm` or `-Confirm:$false`). Callers pass
        `$Cmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')`.

    .PARAMETER ConfirmValue
        The value of that explicitly-bound `-Confirm`. `-Confirm:$false`
        is the unattended/CI consent signal and suppresses the prompt.

    .OUTPUTS
        [bool] $true to proceed with the destructive branch; $false to skip it.

    .EXAMPLE
        $yesToAll = $false
        $noToAll  = $false
        $proceed = Assert-DestructiveOperationConfirmed `
            -Cmdlet       $PSCmdlet `
            -Caption      'Destructive operation' `
            -Query        'Delete 3 orphan sensitivity label(s)? This cannot be undone.' `
            -YesToAll     ([ref]$yesToAll) `
            -NoToAll      ([ref]$noToAll) `
            -Force:$Force `
            -IsWhatIf:$WhatIfPreference `
            -ConfirmBound $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm') `
            -ConfirmValue $confirmValue

    .NOTES
        Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Cmdlet,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Caption,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Query,

        [Parameter(Mandatory = $true)]
        [ref]$YesToAll,

        [Parameter(Mandatory = $true)]
        [ref]$NoToAll,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$IsWhatIf,

        [Parameter()]
        [bool]$ConfirmBound,

        [Parameter()]
        [bool]$ConfirmValue
    )

    # Contract check for the [object]-typed $Cmdlet (see .PARAMETER Cmdlet).
    # Fail loudly here rather than with a confusing MethodNotFound at the
    # moment we would otherwise have prompted.
    if (-not ($Cmdlet.PSObject.Methods.Name -contains 'ShouldContinue')) {
        throw "Assert-DestructiveOperationConfirmed: -Cmdlet must expose a ShouldContinue method (pass the caller's `$PSCmdlet). Got: $($Cmdlet.GetType().FullName)."
    }

    # 1. -WhatIf: never prompt in a dry run. Return $true so the caller
    #    still walks the destructive branch and the per-write
    #    $PSCmdlet.ShouldProcess(...) calls inside it emit their
    #    "What if:" lines. This is what makes `-PruneMissing -WhatIf` a
    #    usable delete preview.
    if ($IsWhatIf) { return $true }

    # 2. -Force: the operator has already said "don't ask".
    if ($Force) { return $true }

    # 3. Explicit -Confirm:$false: the unattended / CI consent signal.
    #    Every workflow apply step binds it, which is what lets the
    #    reconcilers run at ConfirmImpact = 'High' without hanging a
    #    GitHub Actions job on a prompt no one can answer.
    #    $ConfirmPreference is deliberately NOT consulted here -- doing so
    #    would resurrect the Medium-vs-High defect (issue #85).
    if ($ConfirmBound -and -not $ConfirmValue) { return $true }

    # 4. Carry the operator's prior "No to All" / "Yes to All" answer
    #    forward across every gate in this run, so a run that trips both
    #    the overwrite gate and the prune gate prompts at most once.
    if ($NoToAll.Value) { return $false }
    if ($YesToAll.Value) { return $true }

    # 5. Prompt. ShouldContinue's four-argument overload renders
    #    Yes / Yes to All / No / No to All and writes the operator's
    #    "to all" choice back through the [ref] pair.
    #    Reference: https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.cmdlet.shouldcontinue
    $yes = [bool]$YesToAll.Value
    $no = [bool]$NoToAll.Value
    $answer = $Cmdlet.ShouldContinue($Query, $Caption, [ref]$yes, [ref]$no)
    $YesToAll.Value = $yes
    $NoToAll.Value = $no
    return $answer
}

Export-ModuleMember -Function 'Assert-DestructiveOperationConfirmed'
