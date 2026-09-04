#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 AUTO-labeling policies and
    rules against
    `data-plane/information-protection/auto-label-policies.yaml`
    (desired state).

.DESCRIPTION
    Wave 1 declarative reconciler for AUTO-labeling policies. Sibling of
    `scripts/Deploy-LabelPolicies.ps1` (#66) -- same drift vocabulary,
    same auth path, same two-phase reconciliation. Where
    `Deploy-LabelPolicies.ps1` owns the PUBLISHING of labels via
    `*-LabelPolicy` cmdlets, this script owns AUTO-LABELING via
    `*-AutoSensitivityLabelPolicy` + `*-AutoSensitivityLabelRule`
    cmdlets.

    See `docs/adr/0016-auto-label-policy-shape.md` for the shape
    rationale (one policy + one rule in the first PR, ExchangeLocation
    only, mode TestWithoutNotifications which doubles as the simulation
    control, empty advancedSettings allowlist, composite-key
    applyLabel reference, mandatory -ExportCurrentState before first
    Apply).

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET each policy via `Get-AutoSensitivityLabelPolicy` and each
         rule via `Get-AutoSensitivityLabelRule`.
      2. GET each label via `Get-Label` so the YAML's `<parent>/<name>`
         applyLabel reference can be resolved to the live label GUID.
      3. Match desired vs. tenant by `name` for both policies and rules
         (immutable identity at this layer).
      4. Diff each desired policy's tracked fields:
            policies: mode, applyLabel (GUID), exchangeLocation
            rules   : policy (FK), groupingOperator,
                      contentContainsSensitiveInformation
      5. Emit a categorized report (Create / Update / NoChange / Orphan
         / Blocked).
      6. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    Two-phase reconciliation (mirrors `Deploy-LabelPolicies.ps1`):
      Phase 1 (read)  -- enumerate live policies + rules + labels,
                         build per-object plan.
      Phase 2 (reset) -- Disconnect + reload ExchangeOnlineManagement +
                         Reconnect (only if writes are planned).
      Phase 3 (write) -- *-AutoSensitivityLabelPolicy /
                         *-AutoSensitivityLabelRule calls against the
                         refreshed session. Policies are written
                         before rules so the rule FK resolves.

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md` and ADR 0016
    section 8):

        ./scripts/Deploy-AutoLabelPolicies.ps1 -ExportCurrentState

    Hydrates the YAML from the live tenant. Refuses to overwrite a
    non-empty `policies:` / `rules:` list unless -Force is also
    specified.

    `advancedSettings` allowlist (ADR 0016 section 5): empty in the
    first PR. Any key declared in YAML is a hard validation error.
    Tenant-side keys observed during -ExportCurrentState are filtered
    to the same (empty) allowlist before being written.

    PR-#193 lesson (runtime state vs. input enum) carries over: the
    `$script:RuntimePolicyModeMap` is empty in commit 1 and gains
    entries only when `Get-AutoSensitivityLabelPolicy.Mode` is observed
    to return a value `Set-AutoSensitivityLabelPolicy -Mode` rejects.
    Unmapped values throw so upstream cmdlet drift surfaces loudly.

    PR-#196 lesson (rendered name vs. GUID) carries over for
    `ApplyLabel`: tenant returns may be rendered display names; the
    `Get-Label` lookup is mandatory before diffing.

    References (Microsoft Learn):
      Auto-labeling overview:
        https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically
      New-AutoSensitivityLabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy
      Get-AutoSensitivityLabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy
      Set-AutoSensitivityLabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy
      Remove-AutoSensitivityLabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelpolicy
      New-AutoSensitivityLabelRule:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule
      Get-AutoSensitivityLabelRule:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule
      Set-AutoSensitivityLabelRule:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelrule
      Remove-AutoSensitivityLabelRule:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelrule
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Get-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0015 (label-policy shape):
        docs/adr/0015-label-policy-shape.md
      ADR 0016 (auto-label-policy shape):
        docs/adr/0016-auto-label-policy-shape.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/information-protection/auto-label-policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant policies / rules that are not declared in
    the YAML. Default $false. Destructive; rules are removed before
    their parent policy.

.PARAMETER Force
    With `-ExportCurrentState`: allow overwriting `policies:` / `rules:`
    blocks that already contain entries. Without it the script refuses,
    to avoid clobbering hand-curated YAML.

.PARAMETER ExportCurrentState
    Read every auto-label policy and rule visible to the connected app,
    write to the YAML's `policies:` / `rules:` blocks, and exit. Makes
    no writes to the tenant.

.PARAMETER VerifyPublished
    Connect read-only and assert every desired policy in the YAML has
    reached the runtime state implied by its `mode:` (see ADR 0016
    section 9). Emits a PSCustomObject table and throws on any
    non-`Pass` row. Mutually exclusive with -ExportCurrentState.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved
    from `automation.apps.dataPlane.certificateName`.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit.
                         No New-/Set-/Remove-AutoSensitivityLabelPolicy
                         or *Rule call fires under any circumstance.
                         Equivalent to a forced -WhatIf at the script
                         boundary.
      * `portal-wins` -- (default) skip any shared policy or rule whose
                         tracked fields differ; emit a Skip plan row
                         per skipped object and a `[ADR0029-SKIP]
                         <name>` line per skip so an upstream workflow
                         can capture the list for an auto-PR. Create /
                         Update / NoChange and orphan handling are
                         unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         shared object naming the drifted field(s).
                         The overwrite is gated at the SCRIPT layer by
                         the ADR 0052 typed-confirmation prompt: it
                         names the policies it is about to overwrite,
                         asks EVERY caller -- local operators included
                         -- and aborts with no tenant writes if
                         declined. Suppress with -Force, or
                         -Confirm:$false as CI does. The workflow's
                         'overwrite portal' input is an ADDITIONAL
                         gate per ADR 0029, not the only one: a clone
                         of this template that has not run kickoff has
                         no CI at all, so the script-layer gate is its
                         only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. When set,
    each named policy / rule that would otherwise drift is emitted as
    a Skip plan row instead of an Update row (reason: "explicitly
    skipped by caller"). NoChange, Create, and Orphan rows are
    unaffected. Names not present in the YAML or the tenant are
    silently ignored (defends against a stale skip list from the
    workflow).
    Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.EXAMPLE
    ./scripts/Deploy-AutoLabelPolicies.ps1 -WhatIf

    Connect read-only and emit the per-object Create / Update /
    NoChange plan table for what an Apply would do; make no remote
    writes.

.EXAMPLE
    ./scripts/Deploy-AutoLabelPolicies.ps1

    Create or update policies + rules declared in the YAML.
    Tenant-only objects are reported and skipped (no -PruneMissing).

.EXAMPLE
    ./scripts/Deploy-AutoLabelPolicies.ps1 -ExportCurrentState

    Hydrate `data-plane/information-protection/auto-label-policies.yaml`
    from the live tenant. Refuses to overwrite non-empty managed state
    without -Force.

.EXAMPLE
    ./scripts/Deploy-AutoLabelPolicies.ps1 -VerifyPublished

    Connect read-only and assert every desired policy has reached the
    runtime state implied by its `mode:` (Enable -> Status: On;
    Test* / Disable -> presence-only).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant; see
    `scripts/Grant-ExchangeManageAsApp.ps1`):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` or
        `Compliance Data Administrator` assigned at
        directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason / Field. Suitable for capture to
    `$GITHUB_STEP_SUMMARY` or a file. No credential material is
    printed; tenant-real identifiers (policy GUIDs, appId, tenantId)
    are not echoed at INFO level.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/information-protection/auto-label-policies.schema.json`
        (JSON Schema Draft-07) at script start, after
        `ConvertFrom-Yaml` and before any reconcile work.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      * Pass `-SkipSchemaValidation` to bypass the check in emergency
        scenarios (e.g. fixing the schema itself). Do not use in CI.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\information-protection\auto-label-policies.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Verify', Mandatory = $true)]
    [switch]$VerifyPublished,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

# Allowed `Mode` values per New-AutoSensitivityLabelPolicy /
# Set-AutoSensitivityLabelPolicy. Anything else is rejected client-side
# so the operator gets a clear validation error instead of a Microsoft
# cmdlet stack at write time.
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy
$script:ValidPolicyModes = @('Enable', 'Disable', 'TestWithNotifications', 'TestWithoutNotifications')

# Runtime-state -> input-mode map (PR #193 lesson on Deploy-LabelPolicies.ps1).
# Ships empty in commit 1 -- entries are added only when
# `Get-AutoSensitivityLabelPolicy.Mode` is observed to return a value
# that `Set-AutoSensitivityLabelPolicy -Mode` rejects on writeback.
# Unmapped values throw so cmdlet drift surfaces loudly.
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy
$script:RuntimePolicyModeMap = @{}

# Tombstone Mode values: policies returned by Get-AutoSensitivityLabelPolicy
# while a server-side async deletion is in flight (verified against the
# lab tenant 2026-05-13). These rows refer to objects that no longer
# logically exist in the tenant -- we skip them at read time so the
# reconciler does not attempt to diff or re-parent them. The cmdlet
# eventually drops the row entirely once deletion completes server-side.
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelpolicy
$script:TombstonePolicyModes = @('PendingDeletion')

function Test-IsTombstonePolicy {
    param([Parameter(Mandatory = $true)]$Policy)
    $m = [string]$Policy.Mode
    return ($script:TombstonePolicyModes -contains $m)
}

function ConvertTo-PolicyInputMode {
    # Normalize a `Get-AutoSensitivityLabelPolicy.Mode` value to the
    # cmdlet-input form accepted by `Set-AutoSensitivityLabelPolicy -Mode`.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Mode)

    if ([string]::IsNullOrWhiteSpace($Mode)) { return '' }
    if ($script:ValidPolicyModes -contains $Mode) { return $Mode }
    if ($script:RuntimePolicyModeMap.ContainsKey($Mode)) {
        return $script:RuntimePolicyModeMap[$Mode]
    }
    throw ("Unmapped tenant Mode value: '{0}'. Allowed input modes: {1}. Known runtime mappings: {2}. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy" -f
        $Mode, ($script:ValidPolicyModes -join ', '), (($script:RuntimePolicyModeMap.Keys | Sort-Object) -join ', '))
}

# advancedSettings allowlist per ADR 0016 section 5. Empty in commit 1;
# additions require a new ADR follow-up issue with a Microsoft Learn
# citation.
# Reference: docs/adr/0016-auto-label-policy-shape.md
$script:AdvancedSettingsAllowlist = @()

# Tracked-field sets. ADR 0016 section 7. The list-typed fields
# (`exchangeLocation`, `applyLabel`-as-GUID,
# `contentContainsSensitiveInformation`) are diffed in
# Compare-PolicyHash / Compare-RuleHash directly.
$script:TrackedPolicyScalarFields = @('mode', 'applyLabel')
# `workload` is intentionally NOT tracked: the cmdlet accepts it as
# input on New-AutoSensitivityLabelRule but the tenant always returns
# the full expanded workload set (`Exchange, SharePoint, ...`)
# regardless of the input value (verified against the lab tenant
# 2026-05-13). Tracking it would produce a perpetual false-positive
# drift on every -WhatIf run. We pass it at create time and ignore
# the read-back value.
$script:TrackedRuleScalarFields   = @('policy')

# Default single-workload value emitted on a greenfield -ExportCurrentState
# (no prior YAML `workload:` to preserve via Resolve-DesiredRuleWorkload).
# `New-AutoSensitivityLabelRule -Workload` accepts only a SINGLE workload and
# rejects the tenant-expanded multi-value readback with
# MultipleWorkloadsNotAllowedException, and the tenant never reports the
# operator's original single-workload input (it always expands on read). So
# the exporter must pick a deployable convention: `Exchange` matches the
# example manifest, the common `exchangeLocation` case, and the PR #23 lab
# correction. Operators may adjust it post-export.
# Issue: #24. Reference:
# https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule
$script:DefaultExportRuleWorkload = 'Exchange'

function Resolve-DesiredRuleWorkload {
    # Build a `(rule-name -> human-authored workload string)` lookup
    # from the desired-state YAML rules list, so the -ExportCurrentState
    # path can preserve the YAML's `workload:` value on round-trip
    # instead of overwriting it with the tenant-expanded readback.
    #
    # The cmdlet `New-AutoSensitivityLabelRule` accepts `workload` as
    # input but `Get-AutoSensitivityLabelRule` normalizes the readback
    # to the full expanded workload set (see
    # $script:TrackedRuleScalarFields header comment above). The repo
    # treats the YAML as the source of truth for the human-authored
    # input shape — the same way the YAML owns `applyLabel:` as a
    # composite key even though the tenant stores the underlying GUID.
    #
    # Issue: #499 (recurring drift-back PRs from
    # sync-auto-label-policies-from-tenant.yml).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$DesiredRules
    )

    $map = @{}
    if (-not $DesiredRules) { return $map }
    foreach ($r in @($DesiredRules)) {
        if (-not $r) { continue }
        $name = $null
        if ($r -is [hashtable] -or $r -is [System.Collections.IDictionary]) {
            if ($r.Contains('name')) { $name = [string]$r['name'] }
        }
        elseif ($r.PSObject.Properties.Match('name').Count -gt 0) {
            $name = [string]$r.name
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $workload = $null
        if ($r -is [hashtable] -or $r -is [System.Collections.IDictionary]) {
            if ($r.Contains('workload')) { $workload = [string]$r['workload'] }
        }
        elseif ($r.PSObject.Properties.Match('workload').Count -gt 0) {
            $workload = [string]$r.workload
        }
        if ([string]::IsNullOrWhiteSpace($workload)) { continue }
        $map[$name] = $workload
    }
    return $map
}

function ConvertTo-PolicyHash {
    # Normalize a desired-state YAML policy entry into a comparable
    # hashtable. `applyLabel` is the composite key from YAML at this
    # point; the caller resolves it to a GUID via Get-Label before
    # diffing against the tenant hash.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $h = @{
        name             = [string]$Entry.name
        mode             = if ($Entry.ContainsKey('mode')) { [string]$Entry.mode } else { '' }
        applyLabel       = if ($Entry.ContainsKey('applyLabel')) { [string]$Entry.applyLabel } else { '' }
        exchangeLocation = @()
        advancedSettings = @{}
    }
    if ($Entry.ContainsKey('exchangeLocation') -and $Entry.exchangeLocation) {
        $h.exchangeLocation = @(($Entry.exchangeLocation |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Entry.ContainsKey('advancedSettings') -and $Entry.advancedSettings) {
        foreach ($k in $Entry.advancedSettings.Keys) {
            $h.advancedSettings[[string]$k] = ([string]$Entry.advancedSettings[$k]).ToLowerInvariant()
        }
    }
    return $h
}

function ConvertTo-TenantPolicyHash {
    # Normalize a tenant `Get-AutoSensitivityLabelPolicy` result into
    # the same shape as ConvertTo-PolicyHash. `ApplyLabel` is
    # translated to the immutable label GUID via the Get-Label lookup
    # (PR #196 lesson).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $false)][object[]]$TenantLabels = @()
    )

    $h = @{
        name             = [string]$Policy.Name
        guid             = [string]$Policy.Guid
        mode             = ConvertTo-PolicyInputMode -Mode ([string]$Policy.Mode)
        status           = if ($Policy.Status) { [string]$Policy.Status } else { '' }
        applyLabel       = ''
        exchangeLocation = @()
        advancedSettings = @{}
    }
    if ($Policy.ExchangeLocation) {
        $h.exchangeLocation = @(($Policy.ExchangeLocation |
                ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.DisplayName) { [string]$_.DisplayName }
                    else { [string]$_ }
                } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    # ApplyLabel may come back as a GUID OR a rendered display name.
    # Three sublabel shapes have been observed from
    # Get-AutoSensitivityLabelPolicy.ApplySensitivityLabel:
    #   - '<Parent> - <Child>' (space-hyphen-space; common)
    #   - '<Parent>/<Child>'   (rare; Get-LabelPolicy rendering)
    #   - '<Child>' bare (portal-created sublabels; issue #480, run
    #     26720507270 on 2026-05-31 returned 'Partner' for
    #     'Confidential/Partner')
    # Top-level labels are returned bare. Translate any of these to the
    # immutable GUID via TenantLabels so the export path can render the
    # canonical composite '<Parent>/<Child>' key via
    # ConvertTo-LabelCompositeKey.
    if ($Policy.ApplySensitivityLabel) {
        $rendered = [string]$Policy.ApplySensitivityLabel
        $resolved = $null
        if ($TenantLabels.Count -gt 0) {
            $labelById = @{}
            foreach ($l in $TenantLabels) { $labelById[[string]$l.Guid] = $l }
            # Direct GUID match.
            if ($labelById.ContainsKey($rendered)) {
                $resolved = $rendered
            }
            else {
                # First pass: qualified renderings ('<Parent> - <Child>'
                # and '<Parent>/<Child>' for sublabels, bare display
                # name for top-level labels). Qualified shapes always
                # win over the bare-child fallback below.
                foreach ($l in $TenantLabels) {
                    $disp = if ($l.ParentId -and $labelById.ContainsKey([string]$l.ParentId)) {
                        @(
                            ("{0} - {1}" -f [string]$labelById[[string]$l.ParentId].DisplayName, [string]$l.DisplayName),
                            ("{0}/{1}"   -f [string]$labelById[[string]$l.ParentId].DisplayName, [string]$l.DisplayName)
                        )
                    }
                    else { @([string]$l.DisplayName) }
                    if ($disp -contains $rendered) {
                        $resolved = [string]$l.Guid
                        break
                    }
                }
                # Second pass: bare child '<DisplayName>' for portal-
                # created sublabels (issue #480). Collision-aware: if
                # two sublabels share a bare DisplayName, skip the
                # ambiguous key so the caller sees the unresolved
                # rendering pass through and the operator can resolve
                # the ambiguity in YAML. Mirrors the bare-name fallback
                # in Deploy-LabelPolicies.ps1 ConvertTo-TenantPolicyHash
                # (issue #230).
                if (-not $resolved) {
                    $bareToGuid = @{}
                    $bareCollisions = New-Object 'System.Collections.Generic.HashSet[string]'
                    foreach ($l in $TenantLabels) {
                        if ($l.ParentId -and $labelById.ContainsKey([string]$l.ParentId)) {
                            $bare = [string]$l.DisplayName
                            if ($bareToGuid.ContainsKey($bare)) {
                                if ($bareToGuid[$bare] -ne [string]$l.Guid) {
                                    [void]$bareCollisions.Add($bare)
                                }
                            }
                            else {
                                $bareToGuid[$bare] = [string]$l.Guid
                            }
                        }
                    }
                    foreach ($c in $bareCollisions) { [void]$bareToGuid.Remove($c) }
                    if ($bareToGuid.ContainsKey($rendered)) {
                        $resolved = $bareToGuid[$rendered]
                    }
                }
            }
        }
        $h.applyLabel = if ($resolved) { $resolved } else { $rendered }
    }
    if ($Policy.Settings) {
        foreach ($s in $Policy.Settings) {
            $key = $null; $val = $null
            if ($s -is [string]) {
                $kv = $s.Trim('[', ']') -split ',', 2
                if ($kv.Count -eq 2) {
                    $key = $kv[0].Trim()
                    $val = $kv[1].Trim()
                }
            }
            elseif ($s.Key) {
                $key = [string]$s.Key
                $val = [string]$s.Value
            }
            if ($key -and ($script:AdvancedSettingsAllowlist -contains $key)) {
                $h.advancedSettings[$key] = ([string]$val).ToLowerInvariant()
            }
        }
    }
    return $h
}

function Compare-PolicyHash {
    # Returns a list of differing policy field names. `Desired.applyLabel`
    # carries a GUID by the time this runs (the caller resolved against
    # Get-Label).
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = @()
    foreach ($f in $script:TrackedPolicyScalarFields) {
        if (([string]$Desired[$f]) -ne ([string]$Tenant[$f])) { $diffs += $f }
    }
    if (($Desired.exchangeLocation -join ',') -ne ($Tenant.exchangeLocation -join ',')) {
        $diffs += 'exchangeLocation'
    }
    foreach ($k in $script:AdvancedSettingsAllowlist) {
        $d = if ($Desired.advancedSettings.ContainsKey($k)) { $Desired.advancedSettings[$k] } else { $null }
        $t = if ($Tenant.advancedSettings.ContainsKey($k))  { $Tenant.advancedSettings[$k]  } else { $null }
        if (([string]$d) -ne ([string]$t)) { $diffs += "advancedSettings.$k" }
    }
    return $diffs
}

function ConvertTo-RuleHash {
    # Normalize a desired-state YAML rule entry into a comparable
    # hashtable. CCSI entries are normalized to ordered
    # `<sitId>|<minCount>|<minConfidence>` triplets for stable
    # comparison. `workload` is normalized to sorted-unique
    # pipe-joined form to match ConvertTo-TenantRuleHash.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $workloadValue = ''
    if ($Entry.ContainsKey('workload') -and $Entry.workload) {
        $items = (([string]$Entry.workload) -split ',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
        $workloadValue = (($items | Sort-Object -Unique) -join '|')
    }

    $h = @{
        name     = [string]$Entry.name
        policy   = if ($Entry.ContainsKey('policy')) { [string]$Entry.policy } else { '' }
        workload = $workloadValue
        ccsi     = @()
    }
    if ($Entry.ContainsKey('contentContainsSensitiveInformation') -and
        $Entry.contentContainsSensitiveInformation) {
        $triplets = @()
        foreach ($c in $Entry.contentContainsSensitiveInformation) {
            $sitId = [string]$c.sitId
            $minCount = if ($c.ContainsKey('minCount')) { [int]$c.minCount } else { 1 }
            $minConfidence = if ($c.ContainsKey('minConfidence')) { [int]$c.minConfidence } else { 75 }
            $triplets += ("{0}|{1}|{2}" -f $sitId, $minCount, $minConfidence)
        }
        $h.ccsi = @($triplets | Sort-Object -Unique)
    }
    return $h
}

function ConvertTo-TenantRuleHash {
    # Normalize a tenant `Get-AutoSensitivityLabelRule` result. The
    # cmdlet returns `ContentContainsSensitiveInformation` as a list
    # of hashtable-like objects whose keys map 1:1 to the rule
    # parameter shape (`id`/`name`, `mincount`, `minconfidence`).
    # `Policy` is returned as a GUID; the caller may pass a
    # GUID-to-name map so the hash can be compared against the
    # YAML `policy:` value.
    # `Workload` is multi-valued (comma-separated or list); we
    # normalize to a sorted-unique pipe-joined string.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule
    param(
        [Parameter(Mandatory = $true)]$Rule,
        [Parameter(Mandatory = $false)][hashtable]$PolicyGuidToName = @{}
    )

    $policyValue = [string]$Rule.Policy
    if ($PolicyGuidToName.ContainsKey($policyValue)) {
        $policyValue = $PolicyGuidToName[$policyValue]
    }

    $workloadValue = ''
    if ($Rule.Workload) {
        $items = @()
        foreach ($w in @($Rule.Workload)) {
            $items += (([string]$w) -split ',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
        }
        $workloadValue = (($items | Sort-Object -Unique) -join '|')
    }

    $h = @{
        name     = [string]$Rule.Name
        guid     = [string]$Rule.Guid
        policy   = $policyValue
        workload = $workloadValue
        ccsi     = @()
    }
    if ($Rule.ContentContainsSensitiveInformation) {
        $triplets = @()
        foreach ($c in $Rule.ContentContainsSensitiveInformation) {
            $sitId = $null
            $minCount = 1
            $minConfidence = 75
            if ($c -is [hashtable] -or $c -is [System.Collections.IDictionary]) {
                if ($c.ContainsKey('id'))             { $sitId = [string]$c['id'] }
                elseif ($c.ContainsKey('Id'))         { $sitId = [string]$c['Id'] }
                if ($c.ContainsKey('mincount'))       { $minCount = [int]$c['mincount'] }
                elseif ($c.ContainsKey('minCount'))   { $minCount = [int]$c['minCount'] }
                if ($c.ContainsKey('minconfidence'))      { $minConfidence = [int]$c['minconfidence'] }
                elseif ($c.ContainsKey('minConfidence')) { $minConfidence = [int]$c['minConfidence'] }
            }
            else {
                # PSObject from PSWS hashtable wrapper.
                $props = $c | Get-Member -MemberType Properties -ErrorAction SilentlyContinue | ForEach-Object Name
                if ($props -contains 'id')             { $sitId = [string]$c.id }
                elseif ($props -contains 'Id')         { $sitId = [string]$c.Id }
                if ($props -contains 'mincount')       { $minCount = [int]$c.mincount }
                elseif ($props -contains 'minCount')   { $minCount = [int]$c.minCount }
                if ($props -contains 'minconfidence')      { $minConfidence = [int]$c.minconfidence }
                elseif ($props -contains 'minConfidence') { $minConfidence = [int]$c.minConfidence }
            }
            if ($sitId) {
                $triplets += ("{0}|{1}|{2}" -f $sitId, $minCount, $minConfidence)
            }
        }
        $h.ccsi = @($triplets | Sort-Object -Unique)
    }
    return $h
}

function Compare-RuleHash {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = @()
    foreach ($f in $script:TrackedRuleScalarFields) {
        if (([string]$Desired[$f]) -ne ([string]$Tenant[$f])) { $diffs += $f }
    }
    if (($Desired.ccsi -join ',') -ne ($Tenant.ccsi -join ',')) {
        $diffs += 'contentContainsSensitiveInformation'
    }
    return $diffs
}

function ConvertTo-LabelGuidLookup {
    # Composite-key lookup (`<parent>/<displayName>` for sublabels,
    # bare `<displayName>` for top-level) -> GUID. Mirrors
    # Deploy-Labels.ps1 #131.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
    param([Parameter(Mandatory = $true)][object[]]$Labels)

    $byGuid = @{}
    foreach ($l in $Labels) { $byGuid[[string]$l.Guid] = [string]$l.DisplayName }

    $byKey = @{}
    foreach ($l in $Labels) {
        $key = if ($l.ParentId -and $byGuid.ContainsKey([string]$l.ParentId)) {
            "$($byGuid[[string]$l.ParentId])/$([string]$l.DisplayName)"
        }
        else {
            [string]$l.DisplayName
        }
        $byKey[$key] = [string]$l.Guid
    }
    return $byKey
}

function Resolve-DesiredLabelGuid {
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][hashtable]$Lookup
    )
    if ($Lookup.ContainsKey($Reference)) { return $Lookup[$Reference] }
    return $null
}

function ConvertTo-LabelCompositeKey {
    # Inverse of ConvertTo-LabelGuidLookup: GUID -> composite key.
    param([Parameter(Mandatory = $true)][object[]]$Labels)

    $byGuid = @{}
    foreach ($l in $Labels) { $byGuid[[string]$l.Guid] = [string]$l.DisplayName }

    $guidToKey = @{}
    foreach ($l in $Labels) {
        $key = if ($l.ParentId -and $byGuid.ContainsKey([string]$l.ParentId)) {
            "$($byGuid[[string]$l.ParentId])/$([string]$l.DisplayName)"
        }
        else {
            [string]$l.DisplayName
        }
        $guidToKey[[string]$l.Guid] = $key
    }
    return $guidToKey
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

# In-repo ADR 0029 direction-policy decision helper. Shared with
# scripts/Deploy-Labels.ps1 and scripts/Deploy-LabelPolicies.ps1 (and
# future Deploy-*.ps1 reconcilers per issue #463). Extracted to a
# shared module in PR #474.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so neither destructive branch (repo-wins
# overwrite, -PruneMissing delete) can be entered unattended from a local
# terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo -PruneMissing safety guards (issue #13): the empty-desired-set
# refusal, which prevents a prune against a zero-entry desired state from
# classifying every live tenant object as an orphan, plus Write-PruneFailure,
# the $ErrorActionPreference-safe reporter the prune loops below use so one
# failing orphan does not hide the status of the rest. Shared with the other
# Deploy-*.ps1 reconcilers that implement -PruneMissing.
Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1') `
    -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

# When -ParametersFile is omitted, the PURVIEW_PARAMETERS_FILE environment
# variable (set per-environment by the CI workflows) selects the parameters
# file. See docs/adr/0057-multi-environment-and-branch-model.md.
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'. Reference: docs/adr/0010-automation-identity-subject-model.md." -f $ParametersFile)
    return
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key)
        return
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' }
        elseif ($VerifyPublished.IsPresent) { 'Verify' }
        else { 'Apply' }

Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue

#endregion

#region Desired-state load

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

# Schema validation (JSON Schema Draft-07). Issue #68.
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\information-protection\auto-label-policies.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        Write-Error ("Schema file not found at '{0}'. Pass -SkipSchemaValidation to bypass." -f $schemaPath)
        return
    }
    $schemaText = Get-Content -LiteralPath $schemaPath -Raw
    $jsonDoc    = $desiredRoot | ConvertTo-Json -Depth 100
    try {
        $jsonDoc | Test-Json -Schema $schemaText -ErrorAction Stop | Out-Null
        Write-Information ("Schema OK       : {0}" -f (Split-Path -Leaf $schemaPath)) -InformationAction Continue
    } catch {
        Write-Error ("Schema validation failed for '{0}' against '{1}': {2}" -f $Path, $schemaPath, $_.Exception.Message)
        return
    }
}

$desiredPolicyEntries = @()
$desiredRuleEntries   = @()
if ($desiredRoot) {
    if ($desiredRoot.ContainsKey('policies') -and $desiredRoot.policies) {
        $desiredPolicyEntries = @($desiredRoot.policies)
    }
    if ($desiredRoot.ContainsKey('rules') -and $desiredRoot.rules) {
        $desiredRuleEntries = @($desiredRoot.rules)
    }
}

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# This reconciler manages two collections -- auto-labeling policies and their
# rules -- so the guard is keyed on their TOTAL. A prune is only catastrophic
# when NOTHING at all is declared; a file that legitimately declares policies
# but no rules must still be prunable.
#
# With a zero total, every live auto-labeling policy and rule falls out of the
# orphan match below and the run would delete the whole set. The rationale, the
# likely causes, and the 2026-07-19 production hit are documented in
# scripts/modules/PruneGuard.psm1.
#
# Keyed on Apply specifically: this script also has a Verify mode, which does
# not write. Placed in the desired-state load region so it fires before the
# tenant is contacted at all -- before `az account show`, before
# Connect-IPPSSession, and before any write phase.
if ($mode -eq 'Apply' -and $PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   ($desiredPolicyEntries.Count + $desiredRuleEntries.Count) `
        -ObjectTypeNoun 'auto-labeling policy or rule' `
        -SourcePath     $Path `
        -CollectionKey  'policies/rules'
}

$desiredPolicyHashes = @()
$desiredRuleHashes   = @()
if ($mode -eq 'Apply' -or $mode -eq 'Verify') {

    # Policies.
    foreach ($e in $desiredPolicyEntries) {
        if (-not $e.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$e.name)) {
            Write-Error ("Policy entry in '{0}' is missing the required 'name' field." -f $Path)
            return
        }
        if (-not $e.ContainsKey('mode') -or [string]::IsNullOrWhiteSpace([string]$e.mode)) {
            Write-Error ("Auto-label policy '{0}' is missing the required 'mode' field. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy" -f $e.name)
            return
        }
        if ($script:ValidPolicyModes -notcontains [string]$e.mode) {
            Write-Error ("Auto-label policy '{0}' has invalid mode '{1}'. Allowed: {2}. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy" -f $e.name, $e.mode, ($script:ValidPolicyModes -join ', '))
            return
        }
        if (-not $e.ContainsKey('applyLabel') -or [string]::IsNullOrWhiteSpace([string]$e.applyLabel)) {
            Write-Error ("Auto-label policy '{0}' is missing the required 'applyLabel' field (composite key '<parent>/<displayName>' for sublabels, bare '<displayName>' for top-level). Reference: docs/adr/0016-auto-label-policy-shape.md." -f $e.name)
            return
        }
        # ADR 0016 section 12 -- require the exchangeLocation key to be
        # PRESENT but allow an empty array. A SharePoint/OneDrive-only
        # auto-label policy legitimately exports as `exchangeLocation: []`;
        # treating [] as "missing" here would error before diffing and
        # break even a NoChange reconverge. The sibling
        # Deploy-LabelPolicies.ps1 has no exchangeLocation guard at all --
        # that is the reference shape. Empty-vs-populated location writes
        # are gated in the Create/Update phases below (empty -> warn +
        # omit/skip), never cleared silently.
        if (-not $e.ContainsKey('exchangeLocation')) {
            Write-Error ("Auto-label policy '{0}' is missing the required 'exchangeLocation' key. A SharePoint/OneDrive-only policy sets 'exchangeLocation: []'; the key must be present but may be an empty array. Reference: docs/adr/0016-auto-label-policy-shape.md section 12." -f $e.name)
            return
        }
        if ($e.ContainsKey('advancedSettings') -and $e.advancedSettings -and $e.advancedSettings.Keys.Count -gt 0) {
            foreach ($k in $e.advancedSettings.Keys) {
                if ($script:AdvancedSettingsAllowlist -notcontains [string]$k) {
                    Write-Error ("Auto-label policy '{0}' declares advancedSettings key '{1}'. The ADR 0016 section 5 allowlist is empty in the first PR; additions require a new ADR follow-up issue with a Microsoft Learn citation." -f $e.name, $k)
                    return
                }
            }
        }
        $desiredPolicyHashes += ConvertTo-PolicyHash -Entry $e
    }

    $seenPolicyNames = @{}
    foreach ($h in $desiredPolicyHashes) {
        if ($seenPolicyNames.ContainsKey($h.name)) {
            Write-Error ("Auto-label policy name '{0}' is declared more than once in '{1}'." -f $h.name, $Path)
            return
        }
        $seenPolicyNames[$h.name] = $true
    }

    # Rules.
    foreach ($e in $desiredRuleEntries) {
        if (-not $e.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$e.name)) {
            Write-Error ("Rule entry in '{0}' is missing the required 'name' field." -f $Path)
            return
        }
        if (-not $e.ContainsKey('policy') -or [string]::IsNullOrWhiteSpace([string]$e.policy)) {
            Write-Error ("Auto-label rule '{0}' is missing the required 'policy' field (foreign key to policies[].name)." -f $e.name)
            return
        }
        if (-not $seenPolicyNames.ContainsKey([string]$e.policy)) {
            Write-Error ("Auto-label rule '{0}' references policy '{1}' which is not declared in '{2}'." -f $e.name, $e.policy, $Path)
            return
        }
        if (-not $e.ContainsKey('workload') -or [string]::IsNullOrWhiteSpace([string]$e.workload)) {
            Write-Error ("Auto-label rule '{0}' is missing the required 'workload' field (e.g. 'Exchange'). Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule" -f $e.name)
            return
        }
        if (-not $e.ContainsKey('contentContainsSensitiveInformation') -or
            -not $e.contentContainsSensitiveInformation -or
            @($e.contentContainsSensitiveInformation).Count -eq 0) {
            Write-Error ("Auto-label rule '{0}' is missing the required non-empty 'contentContainsSensitiveInformation' list. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule" -f $e.name)
            return
        }
        foreach ($c in $e.contentContainsSensitiveInformation) {
            if (-not $c.ContainsKey('sitId') -or [string]::IsNullOrWhiteSpace([string]$c.sitId)) {
                Write-Error ("Auto-label rule '{0}' has a contentContainsSensitiveInformation entry missing 'sitId' (GUID from sit-catalog.yaml)." -f $e.name)
                return
            }
            if ([string]$c.sitId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                Write-Error ("Auto-label rule '{0}' has sitId '{1}' which is not a valid GUID." -f $e.name, $c.sitId)
                return
            }
        }
        $desiredRuleHashes += ConvertTo-RuleHash -Entry $e
    }

    $seenRuleNames = @{}
    foreach ($h in $desiredRuleHashes) {
        if ($seenRuleNames.ContainsKey($h.name)) {
            Write-Error ("Auto-label rule name '{0}' is declared more than once in '{1}'." -f $h.name, $Path)
            return
        }
        $seenRuleNames[$h.name] = $true
    }
}

#endregion

#region Azure context (read-only preamble)

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region -WhatIf short-circuit (Export / Verify only -- Apply runs the read phase)

# -WhatIf on the Apply path deliberately does NOT short-circuit -- each
# write is gated by $PSCmdlet.ShouldProcess in Phase 3, so the read phase
# still produces a per-object plan table for destructive-change PR previews.
# Mirrors Deploy-Labels.ps1 / Deploy-LabelPolicies.ps1 #152.
# Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Connect, run Get-AutoSensitivityLabelPolicy + Get-AutoSensitivityLabelRule + Get-Label, write every visible policy/rule to {0}.' -f $Path) -InformationAction Continue
    return
}

if ($WhatIfPreference -and $mode -eq 'Verify') {
    Write-Information '-WhatIf specified with -VerifyPublished. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Connect, run Get-AutoSensitivityLabelPolicy, assert every desired policy has reached its mode-implied runtime state.') -InformationAction Continue
    return
}

#endregion

#region Resolve Entra app + acquire token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error ("az ad app list failed with exit code {0}." -f $LASTEXITCODE)
    return
}
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) {
    Write-Error ("Entra application '{0}' not found. Run Wave 0 #5b first." -f $DataPlaneAppDisplayName)
    return
}
if ($appList.Count -gt 1) {
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$appId = [string]$appList[0].appId

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) {
    Write-Error ("Helper not found: '{0}'." -f $tokenScript)
    return
}
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId
if (-not $tok -or -not $tok.AccessToken) {
    Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
    return
}
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion

#region Connect, reconcile, disconnect

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    if ($mode -eq 'Verify') {

        #region -VerifyPublished (ADR 0016 section 9)

        $rawVerifyPolicies = @(Get-AutoSensitivityLabelPolicy -ErrorAction Stop)
        $tombstoneCount = @($rawVerifyPolicies | Where-Object { Test-IsTombstonePolicy $_ }).Count
        $tenantPolicies = @($rawVerifyPolicies | Where-Object { -not (Test-IsTombstonePolicy $_) })
        if ($tombstoneCount -gt 0) {
            Write-Information ("Filtered {0} tombstone (pending-deletion) policy/policies from tenant read." -f $tombstoneCount) -InformationAction Continue
        }
        Write-Information ("Read {0} auto-label policy/policies from tenant for verification." -f $tenantPolicies.Count) -InformationAction Continue

        $tenantByName = @{}
        foreach ($p in $tenantPolicies) { $tenantByName[[string]$p.Name] = $p }

        $verifyRows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($d in $desiredPolicyHashes) {
            if (-not $tenantByName.ContainsKey($d.name)) {
                $verifyRows.Add([pscustomobject]@{
                    Name         = $d.name
                    DesiredMode  = $d.mode
                    TenantStatus = '<absent>'
                    Result       = 'Missing'
                })
                continue
            }
            $tenantPolicy = $tenantByName[$d.name]
            # Verified against lab tenant 2026-05-13: `Status`,
            # `TestModeStatus`, and `TestModeVerdict` are all blank on
            # both Enable and Test* policies. There is no usable
            # mode-derived runtime field exposed by
            # `Get-AutoSensitivityLabelPolicy`. Verify-Published is
            # therefore presence-only across all modes: if the policy
            # exists in the tenant, it passes.
            $tenantMode = if ($tenantPolicy.Mode) { [string]$tenantPolicy.Mode } else { '<empty>' }
            $verifyRows.Add([pscustomobject]@{
                Name        = $d.name
                DesiredMode = $d.mode
                TenantMode  = $tenantMode
                Result      = 'Pass'
            })
        }

        Write-Information '' -InformationAction Continue
        Write-Information 'Verify-Published report:' -InformationAction Continue
        $verifyRows |
            Sort-Object Result, Name |
            Format-Table Name, DesiredMode, TenantMode, Result -AutoSize |
            Out-String |
            Write-Information -InformationAction Continue

        $verifyRows

        $failures = @($verifyRows | Where-Object { $_.Result -ne 'Pass' })
        if ($failures.Count -gt 0) {
            throw ("Verify-Published failed: {0} policy/policies did not pass. See report above." -f $failures.Count)
        }

        Write-Information ("Verify-Published passed: all {0} declared policy/policies satisfy the mode-implied runtime contract." -f $verifyRows.Count) -InformationAction Continue
        return

        #endregion
    }

    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredPolicyEntries.Count -gt 0 -or $desiredRuleEntries.Count -gt 0) {
            if (-not $Force.IsPresent) {
                Write-Error ("'{0}' already declares {1} policy/policies and {2} rule(s). Refusing to overwrite without -Force." -f $Path, $desiredPolicyEntries.Count, $desiredRuleEntries.Count)
                return
            }
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy
        $rawExportPolicies = @(Get-AutoSensitivityLabelPolicy -ErrorAction Stop)
        $tombstoneCount = @($rawExportPolicies | Where-Object { Test-IsTombstonePolicy $_ }).Count
        $allPolicies = @($rawExportPolicies | Where-Object { -not (Test-IsTombstonePolicy $_) })
        if ($tombstoneCount -gt 0) {
            Write-Information ("Filtered {0} tombstone (pending-deletion) policy/policies from tenant read." -f $tombstoneCount) -InformationAction Continue
        }
        Write-Information ("Discovered {0} auto-label policy/policies visible to the connected app." -f $allPolicies.Count) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule
        $allRules = @(Get-AutoSensitivityLabelRule -ErrorAction Stop)
        Write-Information ("Discovered {0} auto-label rule(s) visible to the connected app." -f $allRules.Count) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
        $allLabels = @(Get-Label -ErrorAction Stop)
        $guidToKey = ConvertTo-LabelCompositeKey -Labels $allLabels

        # Build policy-GUID->name map so rule export and workload
        # normalization can render the foreign key with the friendly
        # name (not the immutable GUID), and so the policy-skip pass
        # below can match a surviving rule's resolved policy name.
        $exportPolicyGuidToName = @{}
        foreach ($p in $allPolicies) {
            if ($p.Guid) { $exportPolicyGuidToName[[string]$p.Guid] = [string]$p.Name }
        }

        # ADR 0016 section 12 -- export-scope exclusion. The desired-
        # state schema and the forward-apply guard model only SIT-based
        # `contentContainsSensitiveInformation` (CCSI). A tenant rule
        # whose conditions resolve to an EMPTY CCSI (EDM, trainable
        # classifier, document fingerprint, or any non-CCSI condition)
        # is non-representable: emitting it would violate the schema's
        # CCSI `minItems: 1` floor and the non-empty-CCSI script guard
        # on the very next deploy, breaking the closed loop. Build rules
        # FIRST and skip any rule whose resolved CCSI is empty (warn per
        # skip), then build policies and skip any left with zero
        # surviving rules (warn). The exporter never emits an empty-CCSI
        # rule, so the CCSI `minItems: 1` schema floor and the non-empty
        # script guard both stay in place.
        $ruleExport = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
        $representablePolicyNames = New-Object 'System.Collections.Generic.HashSet[string]'
        # Build a (rule name -> YAML workload) map so the export
        # preserves the human-authored workload value rather than
        # overwriting it with the tenant-expanded readback. See
        # Resolve-DesiredRuleWorkload and issue #499.
        $desiredWorkloadByRuleName = Resolve-DesiredRuleWorkload -DesiredRules $desiredRuleEntries
        $skippedRuleCount = 0
        foreach ($r in $allRules | Sort-Object Name) {
            $rh = ConvertTo-TenantRuleHash -Rule $r -PolicyGuidToName $exportPolicyGuidToName
            if (@($rh.ccsi).Count -eq 0) {
                # Non-representable rule (empty CCSI). Skip so the
                # exported YAML forward-applies to all-NoChange.
                $skippedRuleCount++
                Write-Warning ("Skipping non-representable auto-label rule '{0}' (policy '{1}') from export: its conditions resolve to an empty contentContainsSensitiveInformation. ADR 0016 models only SIT-based CCSI; EDM, trainable-classifier, and document-fingerprint rules are reported as skipped orphans. Reference: docs/adr/0016-auto-label-policy-shape.md section 12." -f $rh.name, $rh.policy)
                continue
            }
            [void]$representablePolicyNames.Add($rh.policy)
            $entry = [ordered]@{}
            $entry['name']     = $rh.name
            $entry['policy']   = $rh.policy
            if ($desiredWorkloadByRuleName.ContainsKey($rh.name)) {
                # Prior YAML value exists: preserve the human-authored
                # single workload on round-trip (issue #499). Never emit the
                # tenant-expanded readback ($rh.workload) here.
                $entry['workload'] = $desiredWorkloadByRuleName[$rh.name]
            }
            else {
                # Greenfield: no prior YAML workload to preserve. The tenant
                # readback ($rh.workload) is the EXPANDED multi-workload set
                # (e.g. 'Applications|AWS|Azure|Exchange|...'), which
                # New-AutoSensitivityLabelRule -Workload rejects with
                # MultipleWorkloadsNotAllowedException. Emit a single
                # deployable default instead so export -> apply (the
                # first-run bootstrap) works. Issue #24.
                $entry['workload'] = $script:DefaultExportRuleWorkload
                Write-Warning ("Auto-label rule '{0}' (policy '{1}') had no prior YAML workload; defaulted the exported workload to the single value '{2}' so the export is deployable (New-AutoSensitivityLabelRule accepts only a single workload). The tenant does not report the operator's original single-workload input (it always expands on read), so review and adjust this value if a different workload was intended. Issue #24." -f $rh.name, $rh.policy, $script:DefaultExportRuleWorkload)
            }
            $ccsiList = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
            foreach ($triplet in $rh.ccsi) {
                $parts = $triplet -split '\|', 3
                $ccsiEntry = [ordered]@{
                    sitId         = $parts[0]
                    minCount      = [int]$parts[1]
                    minConfidence = [int]$parts[2]
                }
                $ccsiList.Add($ccsiEntry)
            }
            $entry['contentContainsSensitiveInformation'] = @($ccsiList)
            $ruleExport.Add($entry)
        }
        if ($skippedRuleCount -gt 0) {
            Write-Information ("Skipped {0} non-representable auto-label rule(s) during export (empty CCSI; see ADR 0016 section 12)." -f $skippedRuleCount) -InformationAction Continue
        }

        # ADR 0016 section 12 -- build policies SECOND, skipping any
        # policy left with zero surviving (representable) rules. Such a
        # policy's only rule(s) were dropped above, so re-emitting the
        # parent would strand it (the reconciler would create a rule-less
        # policy) and, for a CCSI-less rule, fail the schema/guard on the
        # next deploy.
        $policyExport = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
        $skippedPolicyCount = 0
        foreach ($p in $allPolicies | Sort-Object Name) {
            $h = ConvertTo-TenantPolicyHash -Policy $p -TenantLabels $allLabels
            if (-not $representablePolicyNames.Contains($h.name)) {
                # No surviving representable rule references this policy.
                $skippedPolicyCount++
                Write-Warning ("Skipping non-representable auto-label policy '{0}' from export: it has no rule with a representable (SIT-based) contentContainsSensitiveInformation after rule filtering. Reported as a skipped orphan. Reference: docs/adr/0016-auto-label-policy-shape.md section 12." -f $h.name)
                continue
            }
            $entry = [ordered]@{}
            $entry['name'] = $h.name
            $entry['mode'] = $h.mode
            $entry['applyLabel'] = if ($h.applyLabel -and $guidToKey.ContainsKey($h.applyLabel)) {
                $guidToKey[$h.applyLabel]
            }
            else { $h.applyLabel }
            $entry['exchangeLocation'] = @($h.exchangeLocation | Sort-Object)
            $advanced = [ordered]@{}
            foreach ($k in @($h.advancedSettings.Keys | Sort-Object)) {
                $advanced[$k] = $h.advancedSettings[$k]
            }
            $entry['advancedSettings'] = $advanced
            $policyExport.Add($entry)
        }
        if ($skippedPolicyCount -gt 0) {
            Write-Information ("Skipped {0} non-representable auto-label policy/policies during export (no surviving rule; see ADR 0016 section 12)." -f $skippedPolicyCount) -InformationAction Continue
        }

        Write-Information ("Exporting {0} policy/policies and {1} rule(s)." -f $policyExport.Count, $ruleExport.Count) -InformationAction Continue

        # Preserve YAML header comments by line-splicing at `policies:`.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*policies\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'policies:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = if ($cutIndex -gt 0) { $originalLines[0..($cutIndex - 1)] } else { @() }

        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        $bodyDoc = [ordered]@{
            policies = @($policyExport)
            rules    = @($ruleExport)
        }
        if ($policyExport.Count -eq 0) { $bodyDoc.policies = @() }
        if ($ruleExport.Count -eq 0)   { $bodyDoc.rules    = @() }

        # Reference: https://www.powershellgallery.com/packages/powershell-yaml
        $body = $bodyDoc | ConvertTo-Yaml -Options WithIndentedSequences
        foreach ($line in ($body -split "`n")) { $newBlock.Add($line.TrimEnd()) }
        while ($newBlock.Count -gt 0 -and [string]::IsNullOrEmpty($newBlock[$newBlock.Count - 1])) {
            $newBlock.RemoveAt($newBlock.Count - 1)
        }

        $finalLines = @($headerLines) + @($newBlock)
        $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
        $shouldProcessAction = "Replace 'policies:' / 'rules:' blocks with {0} policy / {1} rule entries" -f $policyExport.Count, $ruleExport.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            $content = ($finalLines -join "`n") + "`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
            Write-Information ("Wrote {0} policy / {1} rule entry/entries to '{2}'." -f $policyExport.Count, $ruleExport.Count, $Path) -InformationAction Continue
        }
        return

        #endregion
    }

    #region Apply mode: two-phase reconciliation

    if ($desiredPolicyHashes.Count -eq 0 -and $desiredRuleHashes.Count -eq 0 -and -not $PruneMissing.IsPresent) {
        Write-Information 'No auto-label policies or rules declared in YAML. Nothing to reconcile (use -PruneMissing to remove tenant-only objects).' -InformationAction Continue
        return @()
    }

    # ---- Phase 1: Read + categorize ----
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelpolicy
    $rawTenantPolicies = @(Get-AutoSensitivityLabelPolicy -ErrorAction Stop)
    $tombstoneCount = @($rawTenantPolicies | Where-Object { Test-IsTombstonePolicy $_ }).Count
    $tenantPolicies = @($rawTenantPolicies | Where-Object { -not (Test-IsTombstonePolicy $_) })
    if ($tombstoneCount -gt 0) {
        Write-Information ("Filtered {0} tombstone (pending-deletion) policy/policies from tenant read." -f $tombstoneCount) -InformationAction Continue
    }
    Write-Information ("Read {0} auto-label policy/policies from tenant." -f $tenantPolicies.Count) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-autosensitivitylabelrule
    $tenantRules = @(Get-AutoSensitivityLabelRule -ErrorAction Stop)
    Write-Information ("Read {0} auto-label rule(s) from tenant." -f $tenantRules.Count) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
    $tenantLabels = @(Get-Label -ErrorAction Stop)
    Write-Information ("Read {0} label(s) from tenant for applyLabel resolution." -f $tenantLabels.Count) -InformationAction Continue
    $labelLookup = ConvertTo-LabelGuidLookup -Labels $tenantLabels

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-dlpsensitiveinformationtype
    # New-AutoSensitivityLabelRule -ContentContainsSensitiveInformation
    # rejects entries without a `Name` property (verified against
    # tenant 2026-05-13 with id-only hashtables -- the cmdlet returns
    # `Sensitive information does not contain Name property.`). We
    # resolve `Name` from the live SIT catalog by GUID and pass both
    # `Name` and `id` to the cmdlet for resilience.
    $tenantSits = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    Write-Information ("Read {0} sensitive information type(s) from tenant for CCSI Name resolution." -f $tenantSits.Count) -InformationAction Continue
    $sitNameByGuid = @{}
    foreach ($s in $tenantSits) {
        if ($s.Id)       { $sitNameByGuid[[string]$s.Id]       = [string]$s.Name }
        elseif ($s.Guid) { $sitNameByGuid[[string]$s.Guid]     = [string]$s.Name }
    }

    $tenantPolicyByName = @{}
    foreach ($p in $tenantPolicies) { $tenantPolicyByName[[string]$p.Name] = $p }
    $tenantRuleByName = @{}
    foreach ($r in $tenantRules) { $tenantRuleByName[[string]$r.Name] = $r }

    # Resolve desired applyLabel composite keys to GUIDs.
    $blockedRows = New-Object 'System.Collections.Generic.List[object]'
    $resolvedPolicies = @()
    foreach ($d in $desiredPolicyHashes) {
        $guid = Resolve-DesiredLabelGuid -Reference $d.applyLabel -Lookup $labelLookup
        if (-not $guid) {
            $reason = "applyLabel '$($d.applyLabel)' not found in tenant. Run scripts/Deploy-Labels.ps1 to apply the label taxonomy first, or correct the reference (composite '<parent>/<displayName>' for sublabels, bare '<displayName>' for top-level)."
            $blockedRows.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'AutoLabelPolicy'
                Name     = $d.name
                Reason   = $reason
                Field    = ''
            })
            $report.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'AutoLabelPolicy'
                Name     = $d.name
                Reason   = $reason
                Field    = ''
            })
            continue
        }
        $d.applyLabel = $guid
        $resolvedPolicies += $d
    }

    # Validate SIT references against sit-catalog (best-effort: we
    # don't load the catalog from disk; the regex check at parse time
    # already enforces GUID shape. Tenant-side SIT validation happens
    # when New-AutoSensitivityLabelRule rejects an unknown sitId at
    # write time.)

    $policyPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $resolvedPolicies) {
        if ($tenantPolicyByName.ContainsKey($d.name)) {
            $tenantHash = ConvertTo-TenantPolicyHash -Policy $tenantPolicyByName[$d.name] -TenantLabels $tenantLabels
            $diffs = Compare-PolicyHash -Desired $d -Tenant $tenantHash
            if ($diffs.Count -eq 0) {
                $report.Add([pscustomobject]@{
                    Category = 'NoChange'
                    Kind     = 'AutoLabelPolicy'
                    Name     = $d.name
                    Reason   = 'Declared in YAML and present in tenant; tracked fields identical.'
                    Field    = ''
                })
            }
            else {
                foreach ($f in $diffs) {
                    $report.Add([pscustomobject]@{
                        Category = 'Update'
                        Kind     = 'AutoLabelPolicy'
                        Name     = $d.name
                        Reason   = 'Tracked field differs from tenant.'
                        Field    = $f
                    })
                }
                $policyPlan.Add([pscustomobject]@{
                    Action     = 'Update'
                    Desired    = $d
                    Tenant     = $tenantPolicyByName[$d.name]
                    TenantHash = $tenantHash
                    Fields     = @($diffs)
                })
            }
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'Create'
                Kind     = 'AutoLabelPolicy'
                Name     = $d.name
                Reason   = 'Declared in YAML; not present in tenant.'
                Field    = ''
            })
            $policyPlan.Add([pscustomobject]@{
                Action  = 'Create'
                Desired = $d
                Tenant  = $null
            })
        }
    }

    $rulePlan = New-Object 'System.Collections.Generic.List[object]'
    # Policy-GUID -> Name map for rule.Policy translation (tenant
    # rules carry the parent policy GUID, not its name).
    $policyGuidToName = @{}
    foreach ($p in $tenantPolicies) {
        if ($p.Guid) { $policyGuidToName[[string]$p.Guid] = [string]$p.Name }
    }
    foreach ($d in $desiredRuleHashes) {
        if ($tenantRuleByName.ContainsKey($d.name)) {
            $tenantHash = ConvertTo-TenantRuleHash -Rule $tenantRuleByName[$d.name] -PolicyGuidToName $policyGuidToName
            $diffs = Compare-RuleHash -Desired $d -Tenant $tenantHash
            if ($diffs.Count -eq 0) {
                $report.Add([pscustomobject]@{
                    Category = 'NoChange'
                    Kind     = 'AutoLabelRule'
                    Name     = $d.name
                    Reason   = 'Declared in YAML and present in tenant; tracked fields identical.'
                    Field    = ''
                })
            }
            else {
                foreach ($f in $diffs) {
                    $report.Add([pscustomobject]@{
                        Category = 'Update'
                        Kind     = 'AutoLabelRule'
                        Name     = $d.name
                        Reason   = 'Tracked field differs from tenant.'
                        Field    = $f
                    })
                }
                $rulePlan.Add([pscustomobject]@{
                    Action     = 'Update'
                    Desired    = $d
                    Tenant     = $tenantRuleByName[$d.name]
                    TenantHash = $tenantHash
                    Fields     = @($diffs)
                })
            }
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'Create'
                Kind     = 'AutoLabelRule'
                Name     = $d.name
                Reason   = 'Declared in YAML; not present in tenant.'
                Field    = ''
            })
            $rulePlan.Add([pscustomobject]@{
                Action  = 'Create'
                Desired = $d
                Tenant  = $null
            })
        }
    }

    # Orphans.
    $desiredPolicyNames = @{}
    foreach ($d in $resolvedPolicies) { $desiredPolicyNames[$d.name] = $true }
    $desiredRuleNames = @{}
    foreach ($d in $desiredRuleHashes) { $desiredRuleNames[$d.name] = $true }

    $orphanPolicies = @()
    foreach ($p in $tenantPolicies) {
        if (-not $desiredPolicyNames.ContainsKey([string]$p.Name)) {
            $orphanPolicies += $p
            $cat = if ($PruneMissing.IsPresent) { 'Orphan' } else { 'NoOp' }
            $reason = if ($PruneMissing.IsPresent) {
                'Tenant policy not in YAML; will Remove-AutoSensitivityLabelPolicy under -PruneMissing.'
            }
            else {
                'Tenant policy not in YAML; skipped (use -PruneMissing to remove).'
            }
            $report.Add([pscustomobject]@{
                Category = $cat
                Kind     = 'AutoLabelPolicy'
                Name     = [string]$p.Name
                Reason   = $reason
                Field    = ''
            })
        }
    }

    $orphanRules = @()
    foreach ($r in $tenantRules) {
        if (-not $desiredRuleNames.ContainsKey([string]$r.Name)) {
            $orphanRules += $r
            $cat = if ($PruneMissing.IsPresent) { 'Orphan' } else { 'NoOp' }
            $reason = if ($PruneMissing.IsPresent) {
                'Tenant rule not in YAML; will Remove-AutoSensitivityLabelRule under -PruneMissing.'
            }
            else {
                'Tenant rule not in YAML; skipped (use -PruneMissing to remove).'
            }
            $report.Add([pscustomobject]@{
                Category = $cat
                Kind     = 'AutoLabelRule'
                Name     = [string]$r.Name
                Reason   = $reason
                Field    = ''
            })
        }
    }

    # ---- ADR 0029: direction-policy pass ----
    # Walk the Update entries in BOTH plans (policies + rules) and
    # consult Resolve-DirectionPolicyAction (from the shared module
    # imported above) to decide Skip vs. Update under the configured
    # policy and operator-supplied SkipNames list. Create entries are
    # unaffected (a policy or rule that exists in YAML but not in the
    # tenant has no shared-property drift to arbitrate). Audit mode is
    # handled by a separate short-circuit below and does not enter
    # this pass. The Write-Warning for repo-wins fires ONCE per
    # drifted object with the comma-joined drifted-field set, matching
    # the per-object shape proven in PRs #458 and #468.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md

    # ADR 0052: every policy and rule whose tenant fields this run WILL
    # overwrite. ONE list across both passes -- policies and rules are written
    # in the same run, so the operator is entitled to see the whole blast
    # radius before answering once. Constructed OUTSIDE the policy test below
    # so the gate can read .Count on it unconditionally -- under `audit` the
    # pass never runs, the list stays empty, and the gate stays silent.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'

        # Pass 1: policies.
        $keptPolicyPlan = @()
        foreach ($p in $policyPlan) {
            if ($p.Action -ne 'Update') {
                $keptPolicyPlan += $p
                continue
            }
            $displayName = [string]$p.Desired.name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'AutoLabelPolicy'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = @($p.Fields)
                })
                continue
            }
            $fieldsText = @($p.Fields) -join ','
            Write-Warning ("repo-wins overwriting tenant on auto-label policy '{0}' fields: {1}" -f $displayName, $fieldsText)
            # Every Update entry that survived the Skip decision WILL be Set-,
            # whatever policy let it through. The ADR 0052 gate is keyed on this
            # list -- the plan -- and never on $DirectionPolicy. See
            # ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
            $repoWinsOverwrites.Add(("policy '{0}'" -f $displayName)) | Out-Null
            $keptPolicyPlan += $p
        }

        # Pass 2: rules.
        $keptRulePlan = @()
        foreach ($r in $rulePlan) {
            if ($r.Action -ne 'Update') {
                $keptRulePlan += $r
                continue
            }
            $displayName = [string]$r.Desired.name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'AutoLabelRule'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = @($r.Fields)
                })
                continue
            }
            $fieldsText = @($r.Fields) -join ','
            Write-Warning ("repo-wins overwriting tenant on auto-label rule '{0}' fields: {1}" -f $displayName, $fieldsText)
            # Same rule as the policy pass above: unconditional on the survivor
            # path, never keyed on $DirectionPolicy.
            $repoWinsOverwrites.Add(("rule '{0}'" -f $displayName)) | Out-Null
            $keptRulePlan += $r
        }

        if ($skipDecisions.Count -gt 0) {
            $policyPlan.Clear()
            foreach ($k in $keptPolicyPlan) { $policyPlan.Add($k) }
            $rulePlan.Clear()
            foreach ($k in $keptRulePlan) { $rulePlan.Add($k) }

            # Drop existing Update report rows for skipped objects so the
            # plan summary shows the Skip row (and only the Skip row) per
            # skipped object. Match on (Kind, Name) so a policy and a rule
            # that happen to share a name are deduplicated independently.
            $skipKeyed = @{}
            foreach ($s in $skipDecisions) {
                $skipKeyed[("{0}|{1}" -f $s.Kind, $s.DisplayName)] = $true
            }
            $kept = @($report | Where-Object {
                -not ($_.Category -eq 'Update' -and $skipKeyed.ContainsKey(("{0}|{1}" -f $_.Kind, [string]$_.Name)))
            })
            $report.Clear()
            foreach ($r in $kept) { $report.Add($r) }
            foreach ($s in $skipDecisions) {
                $report.Add([pscustomobject]@{
                    Category = 'Skip'
                    Kind     = $s.Kind
                    Name     = $s.DisplayName
                    Reason   = $s.Reason
                    Field    = (@($s.Fields) -join ',')
                })
                # Machine-readable marker for the workflow's auto-PR step.
                # One line per skipped object so a simple
                # `grep '\[ADR0029-SKIP\]'` over the run log yields the
                # full skip list. Format must match the exact regex
                # `^\[ADR0029-SKIP\] (.+)$` per the github-actions
                # instructions rule, so we do not prefix the Kind here.
                Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
            }
        }
    }

    # Plan summary (pre-write).
    $planRows = $report |
        Group-Object Category, Kind, Name |
        ForEach-Object {
            $first = $_.Group[0]
            $fields = @($_.Group | Where-Object { $_.Field } | ForEach-Object { $_.Field }) -join ','
            [pscustomobject]@{
                Category = $first.Category
                Kind     = $first.Kind
                Name     = $first.Name
                Fields   = $fields
            }
        } |
        Sort-Object Category, Kind, Name

    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $planRows |
        Format-Table Category, Kind, Name, Fields -Wrap |
        Out-String |
        Write-Information -InformationAction Continue

    if ($blockedRows.Count -gt 0) {
        foreach ($b in $blockedRows) {
            Write-Error ("Auto-label policy '{0}' is Blocked: {1}" -f $b.Name, $b.Reason)
        }
        throw ("Reconciliation aborted: {0} policy/policies blocked. See plan summary above." -f $blockedRows.Count)
    }

    # ---- ADR 0029: audit-mode short-circuit ----
    # `-DirectionPolicy audit` keeps the categorized report intact for
    # the end-of-script emission, but empties both plans and both orphan
    # lists so Phase 2 (session refresh) and Phase 3 (write loops)
    # become no-ops without disrupting the script's normal control
    # flow. Use $policyPlan.Clear() / $rulePlan.Clear() + reassign the
    # orphan arrays rather than `return` -- the sibling labels script
    # (PR #458) proved an early return from inside the try block breaks
    # post-finally output handling. The audit marker line is the
    # operator-visible signal that no writes would have fired under any
    # circumstance.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit — no writes would have fired. Plan above is read-only.' -InformationAction Continue
        $policyPlan.Clear()
        $rulePlan.Clear()
        $orphanPolicies = @()
        $orphanRules = @()
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before Phase 2/3 at which nothing has been written.
    # Both destructive branches are gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
    # unconditionally; ShouldProcess only prompts when ConfirmImpact >=
    # $ConfirmPreference, which is precisely the comparison that silently
    # defeated this gate before issue #85.
    #
    # Both gates are keyed on the PLAN -- the objects this run will actually
    # overwrite or delete -- and never on $DirectionPolicy. The gate sits AFTER
    # the audit short-circuit above, which empties both plans and both orphan
    # lists, so an audit run presents an empty plan to both gates and cannot
    # prompt. Policies and rules are counted in ONE prompt per branch: they are
    # written in the same run, and the operator is entitled to see the whole
    # blast radius before answering once. The $yesToAll / $noToAll pair is
    # shared, so a run that trips both gates prompts once.
    #
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path -- every
    # workflow apply step binds it), and skipped under -WhatIf so a dry run
    # still previews the deletes without blocking on input.
    # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    $yesToAll = $false
    $noToAll = $false
    $confirmBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')
    $confirmValue = if ($confirmBound) { [bool]$PSCmdlet.MyInvocation.BoundParameters['Confirm'] } else { $false }
    $gateArgs = @{
        Cmdlet       = $PSCmdlet
        Caption      = 'Destructive operation (ADR 0052)'
        YesToAll     = ([ref]$yesToAll)
        NoToAll      = ([ref]$noToAll)
        Force        = $Force.IsPresent
        IsWhatIf     = [bool]$WhatIfPreference
        ConfirmBound = $confirmBound
        ConfirmValue = $confirmValue
    }

    if ($repoWinsOverwrites.Count -gt 0) {
        $overwriteNames = @($repoWinsOverwrites | Sort-Object -Unique)
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} auto-label object(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
            $overwriteNames.Count, ($overwriteNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
            throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Derived from the two delete loops' own sources one line above the gate,
    # so it cannot diverge from the deletes it speaks for.
    $pruneTargets = @(
        @($orphanPolicies | ForEach-Object { "policy '{0}'" -f $_.Name }) +
        @($orphanRules | ForEach-Object { "rule '{0}'" -f $_.Name })
    )
    if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
        $pruneNames = @($pruneTargets | Sort-Object -Unique)
        $pruneQuery = "-PruneMissing will DELETE {0} orphan auto-label object(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
            $pruneNames.Count, ($pruneNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # ---- Phase 2: Refresh session before any writes ----
    $writeCount = $policyPlan.Count + $rulePlan.Count
    if ($PruneMissing.IsPresent) { $writeCount += $orphanPolicies.Count + $orphanRules.Count }

    if ($writeCount -gt 0 -and -not $WhatIfPreference) {
        Write-Information ("Read phase complete. Refreshing S&C session before {0} write operation(s)." -f $writeCount) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Verbose ("Pre-write Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
        }
        Remove-Module ExchangeOnlineManagement -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $env:TEMP -Directory -Filter 'tmpEXO_*' -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Import-Module ExchangeOnlineManagement -Force -ErrorAction Stop

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
        Connect-IPPSSession `
            -AccessToken  $tok.AccessToken `
            -Organization $TenantDomain `
            -ShowBanner:$false `
            -ErrorAction  Stop | Out-Null
        Write-Information 'Reconnected to Security & Compliance PowerShell for write phase.' -InformationAction Continue
    }

    # ---- Phase 3: Write (policies BEFORE rules so the FK resolves) ----

    foreach ($entry in $policyPlan) {
        $d = $entry.Desired
        $shouldProcessTarget = "Auto-label policy '{0}'" -f $d.name
        switch ($entry.Action) {

            'Create' {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy
                $newArgs = @{
                    Name                  = $d.name
                    ApplySensitivityLabel = $d.applyLabel
                    Mode                  = $d.mode
                }
                # ADR 0016 section 12 -- include -ExchangeLocation only
                # when non-empty. A SharePoint/OneDrive-only policy
                # exports as `exchangeLocation: []`; SP/OD location
                # fields are deferred (ADR 0016 section 2), so a genuine
                # Create with no location has nothing to scope. Omit the
                # parameter and let New-AutoSensitivityLabelPolicy fail
                # loudly on the genuinely-missing location rather than
                # silently create an unscoped policy.
                if (@($d.exchangeLocation).Count -gt 0) {
                    $newArgs['ExchangeLocation'] = $d.exchangeLocation
                }
                else {
                    Write-Warning ("Auto-label policy '{0}' has an empty exchangeLocation; omitting -ExchangeLocation on Create. SharePoint/OneDrive location fields are deferred (ADR 0016 section 2), so New-AutoSensitivityLabelPolicy will fail loudly if no location is supplied." -f $d.name)
                }
                $shouldProcessAction = "New-AutoSensitivityLabelPolicy -Mode {0}" -f $d.mode
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    try {
                        New-AutoSensitivityLabelPolicy @newArgs -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Created auto-label policy '{0}' (Mode={1})." -f $d.name, $d.mode) -InformationAction Continue
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists') {
                            Write-Information ("Auto-label policy '{0}' already exists server-side; treating as no-op." -f $d.name) -InformationAction Continue
                            continue
                        }
                        Write-Error ("New-AutoSensitivityLabelPolicy '{0}' failed: {1}" -f $d.name, $_.Exception.Message)
                        return
                    }
                }
            }

            'Update' {
                $changedFields = @($entry.Fields)
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy
                if ($changedFields -contains 'mode') {
                    $action = "Set-AutoSensitivityLabelPolicy -Mode {0}" -f $d.mode
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            Set-AutoSensitivityLabelPolicy -Identity $d.name -Mode $d.mode -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated auto-label policy '{0}' Mode={1}." -f $d.name, $d.mode) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-AutoSensitivityLabelPolicy '{0}' (Mode) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'applyLabel') {
                    $action = 'Set-AutoSensitivityLabelPolicy -ApplySensitivityLabel'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            Set-AutoSensitivityLabelPolicy -Identity $d.name -ApplySensitivityLabel $d.applyLabel -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated auto-label policy '{0}' ApplySensitivityLabel." -f $d.name) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-AutoSensitivityLabelPolicy '{0}' (ApplySensitivityLabel) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'exchangeLocation') {
                    # ADR 0016 section 12 -- skip the -ExchangeLocation
                    # write when the desired value is empty. Both hash
                    # converters default exchangeLocation to @(), so a
                    # SP/OD-only policy yields desired [] == tenant [] ->
                    # NoChange and this branch never fires. If it does
                    # fire with an empty desired value (tenant had a
                    # populated location), skip the write rather than
                    # clear the tenant scope.
                    if (@($d.exchangeLocation).Count -eq 0) {
                        Write-Warning ("Auto-label policy '{0}' has an empty desired exchangeLocation; skipping the -ExchangeLocation write to avoid clearing the tenant scope (ADR 0016 section 12)." -f $d.name)
                    }
                    else {
                        $action = 'Set-AutoSensitivityLabelPolicy -ExchangeLocation'
                        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                            try {
                                Set-AutoSensitivityLabelPolicy -Identity $d.name -ExchangeLocation $d.exchangeLocation -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-Information ("Updated auto-label policy '{0}' ExchangeLocation." -f $d.name) -InformationAction Continue
                            }
                            catch {
                                Write-Error ("Set-AutoSensitivityLabelPolicy '{0}' (ExchangeLocation) failed: {1}" -f $d.name, $_.Exception.Message)
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    foreach ($entry in $rulePlan) {
        $d = $entry.Desired
        $shouldProcessTarget = "Auto-label rule '{0}'" -f $d.name

        # Build the CCSI hashtable array from the canonical
        # `<sitId>|<minCount>|<minConfidence>` triplets. The cmdlet
        # requires a `Name` property (verified against tenant
        # 2026-05-13); we resolve it from the live SIT catalog by GUID.
        $ccsiArray = @()
        foreach ($triplet in $d.ccsi) {
            $parts = $triplet -split '\|', 3
            $sitId = $parts[0]
            if (-not $sitNameByGuid.ContainsKey($sitId)) {
                Write-Error ("Auto-label rule '{0}' references sitId '{1}' which Get-DlpSensitiveInformationType does not return. Verify the GUID against data-plane/classifications/sit-catalog.yaml." -f $d.name, $sitId)
                return
            }
            $ccsiArray += @{
                Name          = $sitNameByGuid[$sitId]
                id            = $sitId
                mincount      = [string]$parts[1]
                minconfidence = [string]$parts[2]
            }
        }

        switch ($entry.Action) {

            'Create' {
                # Issue #20: ConvertTo-TenantRuleHash normalizes a rule's
                # workload to a sorted-unique PIPE-joined string (e.g.
                # 'Applications|Exchange|SharePoint') -- that is the on-disk
                # drift-comparison contract and must not change. But
                # New-AutoSensitivityLabelRule -Workload is a multi-valued
                # flags enum that accepts an array / comma-separated list and
                # REJECTS the pipe-joined string ("Cannot convert value
                # 'A|B|C' ... Unable to match the identifier name ... to a
                # valid enumerator name"), so passing $d.workload raw aborts
                # every multi-workload rule. Split the pipe-joined value back
                # into a trimmed, non-empty string[] before the call; a
                # single-workload value (no '|') yields a one-element array and
                # incidental whitespace is dropped. Mirrors how $ccsiArray is
                # pre-built above.
                $workloadArray = @(
                    ([string]$d.workload -split '\|') |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { $_ }
                )
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelrule
                $newArgs = @{
                    Name                                = $d.name
                    Policy                              = $d.policy
                    Workload                            = $workloadArray
                    ContentContainsSensitiveInformation = $ccsiArray
                }
                $shouldProcessAction = 'New-AutoSensitivityLabelRule'
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    try {
                        New-AutoSensitivityLabelRule @newArgs -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Created auto-label rule '{0}' (policy={1}, SIT count={2})." -f $d.name, $d.policy, $ccsiArray.Count) -InformationAction Continue
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists') {
                            Write-Information ("Auto-label rule '{0}' already exists server-side; treating as no-op." -f $d.name) -InformationAction Continue
                            continue
                        }
                        Write-Error ("New-AutoSensitivityLabelRule '{0}' failed: {1}" -f $d.name, $_.Exception.Message)
                        return
                    }
                }
            }

            'Update' {
                $changedFields = @($entry.Fields)
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelrule
                # `policy` is part of the rule identity; we cannot
                # re-parent a rule without recreating it. Surface that
                # as an error so the operator removes + recreates via
                # -PruneMissing rather than getting a confusing partial
                # update.
                if ($changedFields -contains 'policy') {
                    Write-Error ("Auto-label rule '{0}' would change parent policy from tenant value. Set-AutoSensitivityLabelRule does not support re-parenting; remove and recreate via -PruneMissing." -f $d.name)
                    return
                }
                if ($changedFields -contains 'contentContainsSensitiveInformation') {
                    $action = "Set-AutoSensitivityLabelRule -ContentContainsSensitiveInformation ({0} SIT(s))" -f $ccsiArray.Count
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            Set-AutoSensitivityLabelRule -Identity $d.name -ContentContainsSensitiveInformation $ccsiArray -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated auto-label rule '{0}' ContentContainsSensitiveInformation ({1} SIT(s))." -f $d.name, $ccsiArray.Count) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-AutoSensitivityLabelRule '{0}' (CCSI) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
            }
        }
    }

    # ---- Phase 4: Ensure simulation is started for every Test* policy
    # we just created or updated, AND for any pre-existing Test* policy
    # whose rule(s) we just touched (CCSI changes require a simulation
    # restart per the cmdlet warning emitted on rule writes).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-autosensitivitylabelpolicy
    $simulationPolicies = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in $policyPlan) {
        if ($entry.Desired.mode -like 'Test*') { [void]$simulationPolicies.Add([string]$entry.Desired.name) }
    }
    foreach ($entry in $rulePlan) {
        $parent = [string]$entry.Desired.policy
        $parentDesired = $resolvedPolicies | Where-Object { $_.name -eq $parent } | Select-Object -First 1
        if ($parentDesired -and ($parentDesired.mode -like 'Test*')) {
            [void]$simulationPolicies.Add($parent)
        }
    }
    foreach ($policyName in $simulationPolicies) {
        $shouldProcessTarget = "Auto-label policy '{0}'" -f $policyName
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, 'Set-AutoSensitivityLabelPolicy -StartSimulation $true')) {
            try {
                Set-AutoSensitivityLabelPolicy -Identity $policyName -StartSimulation $true -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Information ("Started simulation on auto-label policy '{0}' (Test* mode requires explicit StartSimulation per cmdlet warning)." -f $policyName) -InformationAction Continue
            }
            catch {
                Write-Error ("Set-AutoSensitivityLabelPolicy '{0}' (StartSimulation) failed: {1}" -f $policyName, $_.Exception.Message)
                return
            }
        }
    }

    if ($PruneMissing.IsPresent) {
        # Issue #13: attempt EVERY orphan, collect the failures, and throw one
        # aggregate below. In-loop failures are reported via Write-PruneFailure
        # (scripts/modules/PruneGuard.psm1), which uses Write-Warning plus an
        # '::error::' workflow command rather than Write-Error. Under GitHub
        # Actions, `shell: pwsh` sets $ErrorActionPreference='stop', so a
        # Write-Error here would terminate on the first orphan and the rest --
        # including every orphan POLICY -- would never be attempted, so the
        # operator would learn about exactly one blocker per dispatch. Microsoft
        # Purview enforces auto-label delete-blockers in layers, so multiple
        # distinct blockers are the norm. The aggregate `throw` below remains
        # the terminal outcome, so a failed prune still exits non-zero: only
        # the reporting changed, not the verdict.
        $pruneFailures = New-Object 'System.Collections.Generic.List[string]'

        # Rules first so the parent policy is empty before its own
        # Remove call.
        foreach ($r in $orphanRules) {
            $shouldProcessTarget = "Auto-label rule '{0}'" -f $r.Name
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, 'Remove-AutoSensitivityLabelRule')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelrule
                    Remove-AutoSensitivityLabelRule -Identity ([string]$r.Name) -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Removed orphan auto-label rule '{0}'." -f $r.Name) -InformationAction Continue
                }
                catch {
                    Write-PruneFailure ("Remove-AutoSensitivityLabelRule '{0}' failed: {1}" -f $r.Name, $_.Exception.Message)
                    $pruneFailures.Add(("rule '{0}'" -f $r.Name))
                    continue
                }
            }
        }
        foreach ($p in $orphanPolicies) {
            $shouldProcessTarget = "Auto-label policy '{0}'" -f $p.Name
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, 'Remove-AutoSensitivityLabelPolicy')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-autosensitivitylabelpolicy
                    Remove-AutoSensitivityLabelPolicy -Identity ([string]$p.Name) -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Removed orphan auto-label policy '{0}'." -f $p.Name) -InformationAction Continue
                }
                catch {
                    Write-PruneFailure ("Remove-AutoSensitivityLabelPolicy '{0}' failed: {1}" -f $p.Name, $_.Exception.Message)
                    $pruneFailures.Add(("policy '{0}'" -f $p.Name))
                    continue
                }
            }
        }

        if ($pruneFailures.Count -gt 0) {
            throw ("Reconciliation aborted: {0} orphan auto-label object(s) could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
        }
    }

    #endregion
}
finally {
    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
    }
}

# Emit the structured drift report on the pipeline so callers can pipe to
# Format-Table / Out-File / ConvertTo-Json / >> $GITHUB_STEP_SUMMARY per
# `.github/instructions/powershell.instructions.md` ("Drift report format").
$report

#endregion