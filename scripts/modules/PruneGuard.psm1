#Requires -Version 7.4
<#
.SYNOPSIS
    Shared `-PruneMissing` safety guards and failure reporting for the
    `Deploy-*.ps1` reconcilers. Issue #13.

.DESCRIPTION
    Every reconciler in this repo implements the same reconcile shape:
    read a desired-state YAML, read the live tenant, classify the tenant
    objects the YAML does not declare as ORPHANS, and -- under
    `-PruneMissing` -- delete them. That shape carries two failure modes
    that are identical across all twenty-one scripts, so the guards
    against them belong in one module rather than twenty-one copies.

    GUARD 1 -- EMPTY DESIRED SET (`Assert-PruneDesiredSetNotEmpty`)
    --------------------------------------------------------------
    When the desired-state YAML parses to zero entries, EVERY live tenant
    object falls out of the orphan match and the run attempts to delete
    the entire object space.

    The script cannot distinguish the two cases that both produce zero
    entries:

      1. Legitimate steady state -- an empty top-level collection (e.g.
         `labels: []`) is the documented no-op-safe default for a fresh
         repo, per each reconciler's first-run bootstrap contract.
      2. Operator error -- a stale/unpulled branch, a bad `-Path`, or a
         YAML parse that silently yields no top-level collection key.

    Case 2 is indistinguishable from case 1 at runtime, and case 2 is
    destructive. The safe reading of an ambiguous destructive plan is to
    refuse it, so a prune against an empty desired set is treated as
    never legitimate. An operator who genuinely wants to empty the object
    space does it through the Microsoft Purview portal or a purpose-built
    script; this reconciler will not infer that intent from an empty file.

    Hit in production on 2026-07-19: a local `dev` working tree sat behind
    `origin/dev` holding the bootstrap `labels: []`, while the merged
    10-label taxonomy existed only on the remote. A verification pass
    reported `Desired keys : 0`; a `-PruneMissing` run from that tree
    would have targeted all 14 live label objects rather than the intended
    4 orphans.

    GUARD 2 -- SANITY RATIO (`Assert-PruneRatioWithinThreshold`)
    -----------------------------------------------------------
    Guard 1 only catches the total-wipe case. A near-total wipe -- a YAML
    that lost most of its entries to a bad merge, or a `-Path` pointing at
    a different environment's smaller file -- still slips through with a
    non-zero desired count. A prune that removes most of the live object
    space is almost always a misconfiguration, so this guard refuses when
    the prune share exceeds a threshold (default 50%).

    Unlike guard 1 this one CAN have a legitimate hit -- a deliberate
    consolidation really may retire most of a taxonomy -- so it takes an
    explicit override. The override is a parameter of the function rather
    than a module-level setting so each caller surfaces it as its own
    switch and the operator's intent is recorded in the invocation.

    FAILURE REPORTING (`Write-PruneFailure`)
    ----------------------------------------
    The prune loop is designed to attempt every orphan, collect failures,
    and throw one aggregate at the end. `Write-Error` defeats that design
    under GitHub Actions: `shell: pwsh` sets `$ErrorActionPreference='stop'`,
    which promotes the first non-terminating error into a terminating one,
    so the remaining orphans are never attempted. Observed in run
    29694478494, where a `LabelIsReferencedByPoliciesException` on the
    first orphan masked the status of the other three.

    `Write-Warning` is unaffected by `$ErrorActionPreference`, and the
    `::error::` workflow command still renders the failure as a red
    annotation in the Actions UI. `Write-Host` is NOT used --
    `PSAvoidUsingWriteHost` is Warning-severity and CI runs
    `Invoke-ScriptAnalyzer -Severity Warning -EnableExit`.

    GENERIC ACROSS RECONCILERS
    --------------------------
    Nothing here is label-specific. Every function takes plain counts plus
    a caller-supplied object-type noun (`'sensitivity label'`,
    `'retention policy'`, `'collection'`, `'scan'`, ...) used only to
    compose messages, so the same module serves labels, retention
    policies, DLP policies, collections, scans, and the rest.

    Consumers:
      * `scripts/Deploy-Labels.ps1`
      * rollout to the remaining twenty `Deploy-*.ps1` reconcilers that
        implement `-PruneMissing` is the follow-up to issue #13.

    Each consumer imports the module via:

        Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1') `
            -Force -Scope Local -ErrorAction Stop

    Guard 1 must be called in the desired-state load region -- before the
    ADR 0052 confirmation gate, before the write phases, and before the
    tenant is contacted at all. Guard 2 needs the live counts, so it is
    called on the plan, immediately before the ADR 0052 gate: the last
    point at which nothing has been written.

    References:
      Issue: #13 (Deploy-Labels.ps1 -PruneMissing targets the entire taxonomy)
      ADR:  docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
      ADR:  docs/adr/0029-source-of-truth-direction-policy.md
      Rule: .github/instructions/powershell.instructions.md
      about_Preference_Variables: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables
      about_Throw: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_throw
      Write-Warning: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/write-warning
      Workflow commands (::error::): https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions#setting-an-error-message
      PowerShell modules: https://learn.microsoft.com/en-us/powershell/scripting/developer/module/writing-a-windows-powershell-module
#>

function Assert-PruneDesiredSetNotEmpty {
    <#
    .SYNOPSIS
        Refuse a prune whose desired-state set is empty. Throws on
        violation; returns nothing on success.

    .DESCRIPTION
        Guard 1 of issue #13. Throws a terminating error when a prune is
        requested against a zero-entry desired set, because every live
        tenant object would then be classified as an orphan and the run
        would delete the entire object space.

        The thrown message names the likely causes in observed-frequency
        order so the operator can self-diagnose from the CI log without
        opening the script.

        Callers invoke this only when the prune switch is actually
        present -- the guard is about the destructive branch, not about
        an empty YAML, which is a perfectly valid no-op on a read or
        create-only run.

    .PARAMETER DesiredCount
        Number of entries parsed from the desired-state YAML's top-level
        collection. Zero triggers the refusal.

    .PARAMETER ObjectTypeNoun
        Singular, lower-case noun for the object type this reconciler
        manages, used only to compose the message -- e.g.
        'sensitivity label', 'retention policy', 'collection'.

    .PARAMETER SourcePath
        Path of the desired-state YAML that produced `DesiredCount`.
        Named in the message so a wrong `-Path` is obvious on sight.

    .PARAMETER CollectionKey
        Top-level YAML key the entries were read from -- e.g. 'labels',
        'retentionPolicies'. Named in the message so a typo'd or
        mis-indented key is obvious on sight.

    .PARAMETER PruneParameterName
        Name of the caller's prune switch as the operator typed it, used
        in the message. Defaults to '-PruneMissing', which every
        reconciler in this repo uses.

    .OUTPUTS
        None. Throws a terminating error when the guard trips.

    .EXAMPLE
        Assert-PruneDesiredSetNotEmpty `
            -DesiredCount   $desiredEntries.Count `
            -ObjectTypeNoun 'sensitivity label' `
            -SourcePath     $Path `
            -CollectionKey  'labels'

    .NOTES
        Reference: issue #13.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$DesiredCount,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectTypeNoun,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CollectionKey,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PruneParameterName = '-PruneMissing'
    )

    if ($DesiredCount -gt 0) { return }

    throw (@(
        ("Refusing {0}: the desired-state set parsed from '{1}' contains zero {2}s." -f $PruneParameterName, $SourcePath, $ObjectTypeNoun),
        ("A prune against an empty desired set would classify every live tenant {0} as an orphan and delete the whole set." -f $ObjectTypeNoun),
        'Likely causes, in order of observed frequency:',
        '  1. Stale or unpulled branch -- the working tree is behind its remote and still holds the bootstrap empty collection, while the merged desired state exists only on the remote. Run `git pull --ff-only` and re-check.',
        ("  2. Wrong -Path -- '{0}' is not the file you meant to reconcile." -f $SourcePath),
        ("  3. A YAML parse that yielded no ``{0}`` key (typo, wrong indentation, or an empty/truncated file)." -f $CollectionKey),
        ("If the intent really is to empty the set, delete the {0}s through the Microsoft Purview portal or a purpose-built script -- this reconciler will not infer that intent from an empty file." -f $ObjectTypeNoun),
        'Hit in production on 2026-07-19: a local working tree sat behind its remote with an empty collection while the merged desired state existed only on the remote. See issue #13.'
    ) -join [Environment]::NewLine)
}

function Assert-PruneRatioWithinThreshold {
    <#
    .SYNOPSIS
        Refuse a prune that would remove more than a threshold share of
        the live objects. Throws on violation; returns nothing on success.

    .DESCRIPTION
        Guard 2 of issue #13. Guard 1 catches only the total wipe; this
        catches the near-total one -- a YAML that lost most of its entries
        to a bad merge, or a `-Path` pointing at a smaller environment's
        file. Both leave a non-zero desired count and so clear guard 1.

        Throws when `PruneCount / LiveCount` is STRICTLY GREATER than
        `MaxPruneRatio`. A prune exactly at the threshold passes: the
        boundary is a documented round number an operator may deliberately
        sit on, and refusing it would make the default value surprising.

        `LiveCount` of zero passes trivially -- there is nothing to
        delete, so there is no hazard to guard.

        Unlike guard 1, a trip here can be legitimate, so `-Allow` exists
        to let the operator proceed. It is a parameter rather than a
        module setting so each caller surfaces it as its own switch and
        the consent is recorded in the invocation.

    .PARAMETER PruneCount
        Number of objects the plan would delete (the orphan count).

    .PARAMETER LiveCount
        Number of objects currently in the tenant, the denominator of the
        ratio. Zero passes trivially.

    .PARAMETER ObjectTypeNoun
        Singular, lower-case noun for the object type this reconciler
        manages, used only to compose the message -- e.g.
        'sensitivity label', 'retention policy', 'collection'.

    .PARAMETER MaxPruneRatio
        Largest share of `LiveCount` the plan may delete without the
        override, as a fraction in (0, 1]. Default 0.5 -- a prune that
        removes most of the live set is almost always a misconfiguration.
        A value of 1 disables the guard, which is why 0 is not accepted:
        a zero threshold would refuse every prune and is never a useful
        configuration.

    .PARAMETER Allow
        The caller's override switch value. When set, the ratio is
        reported but not enforced, so a genuinely large prune remains
        possible.

    .PARAMETER OverrideParameterName
        Name of the caller's override switch as the operator would type
        it, quoted in the refusal message so the log tells them exactly
        how to proceed. Defaults to '-AllowMajorityPrune'.

    .OUTPUTS
        None. Throws a terminating error when the guard trips.

    .EXAMPLE
        Assert-PruneRatioWithinThreshold `
            -PruneCount     $orphans.Count `
            -LiveCount      $tenantLabels.Count `
            -ObjectTypeNoun 'sensitivity label' `
            -Allow:$AllowMajorityPrune

    .NOTES
        Reference: issue #13.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$PruneCount,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$LiveCount,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ObjectTypeNoun,

        [Parameter()]
        [ValidateRange(0.0000001, 1.0)]
        [double]$MaxPruneRatio = 0.5,

        [Parameter()]
        [switch]$Allow,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OverrideParameterName = '-AllowMajorityPrune'
    )

    # Nothing live means nothing to delete: no hazard, and the ratio is
    # undefined. Return before dividing.
    if ($LiveCount -le 0) { return }
    if ($PruneCount -le 0) { return }

    $ratio = $PruneCount / $LiveCount
    if ($ratio -le $MaxPruneRatio) { return }

    $pct    = [math]::Round($ratio * 100, 1)
    $maxPct = [math]::Round($MaxPruneRatio * 100, 1)

    if ($Allow) {
        Write-Warning (
            "Prune sanity ratio exceeded ({0} of {1} live {2}s, {3}%, over the {4}% threshold), but {5} was supplied -- proceeding." -f `
                $PruneCount, $LiveCount, $ObjectTypeNoun, $pct, $maxPct, $OverrideParameterName)
        return
    }

    throw (@(
        ("Refusing prune: the plan would delete {0} of {1} live {2}s ({3}%), over the {4}% sanity threshold." -f $PruneCount, $LiveCount, $ObjectTypeNoun, $pct, $maxPct),
        ("A prune that removes most of the live {0}s is almost always a misconfiguration -- a desired-state file that lost entries to a bad merge, or a -Path pointing at a different environment's file." -f $ObjectTypeNoun),
        'Review the Orphan rows in the plan above and confirm every one of them is genuinely meant to be deleted.',
        ("If the large prune is intended, re-run with {0}." -f $OverrideParameterName),
        'Reference: issue #13.'
    ) -join [Environment]::NewLine)
}

function Write-PruneFailure {
    <#
    .SYNOPSIS
        Report a per-object prune failure without terminating the loop,
        under any `$ErrorActionPreference`.

    .DESCRIPTION
        The prune loop attempts every orphan, collects failures, and
        throws one aggregate at the end. `Write-Error` breaks that: GitHub
        Actions' `shell: pwsh` sets `$ErrorActionPreference='stop'`, which
        promotes the first non-terminating error to a terminating one, so
        the later orphans are never attempted and their status is never
        learned.

        This reporter therefore uses `Write-Warning` -- unaffected by
        `$ErrorActionPreference` -- plus a `::error::` workflow command on
        the information stream, which still renders the failure as a red
        annotation in the Actions UI. The caller's aggregate `throw`
        remains the terminal outcome, so a failed prune still exits
        non-zero: only the reporting changed, not the verdict.

        `Write-Host` is deliberately not used. `PSAvoidUsingWriteHost` is
        Warning-severity and CI runs
        `Invoke-ScriptAnalyzer -Severity Warning -EnableExit`.

    .PARAMETER Message
        The failure text. Should name the object and the tenant's reason,
        e.g. "Remove-Label 'Confidential' failed: <server message>".

    .OUTPUTS
        None. Writes to the warning and information streams.

    .EXAMPLE
        Write-PruneFailure -Message ("Remove-Label '{0}' failed: {1}" -f $l.DisplayName, $_.Exception.Message)

    .NOTES
        Reference: issue #13.
        Reference: https://docs.github.com/en/actions/reference/workflow-commands-for-github-actions#setting-an-error-message
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    Write-Warning $Message
    # '::error::' via the information stream, matching the repo's existing
    # workflow-command convention (scripts/Test-IdentifierResidue.ps1).
    Write-Information ("::error::{0}" -f $Message) -InformationAction Continue
}

Export-ModuleMember -Function @(
    'Assert-PruneDesiredSetNotEmpty',
    'Assert-PruneRatioWithinThreshold',
    'Write-PruneFailure'
)
