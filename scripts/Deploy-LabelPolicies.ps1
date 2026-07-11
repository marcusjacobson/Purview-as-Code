#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 sensitivity-label POLICIES
    against `data-plane/information-protection/label-policies.yaml`
    (desired state).

.DESCRIPTION
    Wave 1 declarative reconciler for sensitivity-label policies. Sibling
    of `scripts/Deploy-Labels.ps1` (#65) -- same drift vocabulary, same
    auth path, same single-session two-phase reconciliation. Where
    `Deploy-Labels.ps1` owns the label TAXONOMY, this script owns the
    BINDING of those labels to end-user locations via `*-LabelPolicy`
    cmdlets.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET each policy via `Get-LabelPolicy`.
      2. GET each label via `Get-Label` so the YAML's `<parent>/<name>`
         label references can be resolved to the live label GUIDs that
         `Get-LabelPolicy.Labels` returns.
      3. Match desired vs. tenant by `name` (the immutable identity).
      4. Diff each desired policy's tracked fields:
            - mode                 (Enable / Disable / TestWithNotifications /
                                    TestWithoutNotifications)
            - exchangeLocation     (sorted set; 'All' or list of mailboxes)
            - modernGroupLocation  (sorted set; M365 group identifiers;
                                    #471 row 4; ADR 0030)
            - includedAdministrativeUnits (sorted set; Entra admin unit
                                    display names; #471 row 6; ADR 0042)
            - labels               (GUID set, normalized via Get-Label lookup)
            - advancedSettings     (allowlist enforced -- see ADR 0015 section 3)
      5. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
            Conflict -- not produced. The label-policy cmdlets do not
                        expose a per-policy `lastModifiedBy` we can diff
                        against, so `-Force` is reserved for the export
                        path only.
      6. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    Two-phase reconciliation (mirrors `Deploy-Labels.ps1` and
    `Deploy-PurviewRoleGroups.ps1`):

      Phase 1 (read)  -- enumerate live policies + live labels, build
                         per-policy plan.
      Phase 2 (reset) -- Disconnect + reload ExchangeOnlineManagement +
                         Reconnect (only if writes are planned). Same
                         long-lived-session degradation as the label
                         reconciler.
      Phase 3 (write) -- New-LabelPolicy / Set-LabelPolicy /
                         Remove-LabelPolicy calls against the refreshed
                         session.

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md`):

        ./scripts/Deploy-LabelPolicies.ps1 -ExportCurrentState

    Hydrates the YAML from the live tenant (every visible policy).
    Refuses to overwrite a non-empty `labelPolicies:` list unless
    -Force is also specified. Existing YAML header comments are
    preserved by line-splicing -- only the `labelPolicies:` block is
    rewritten.

    `advancedSettings` allowlist (ADR 0015 section 3): only
    `RequireDowngradeJustification`, `MandatoryLabelling`, and
    `HideBarByDefault` are accepted in the YAML on the Apply path.
    Any other key is a hard validation error. The `-ExportCurrentState`
    path filters tenant-side keys to the same allowlist before writing.
    Adding a fourth key requires a new ADR follow-up issue with a
    Microsoft Learn citation.

    References (Microsoft Learn):
      Sensitivity labels overview:
        https://learn.microsoft.com/en-us/purview/sensitivity-labels
      Publish sensitivity labels by creating a label policy:
        https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#publish-sensitivity-labels-by-creating-a-label-policy
      Custom configurations / advanced settings:
        https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Get-LabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
      New-LabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
      Set-LabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
      Remove-LabelPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-labelpolicy
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

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/information-protection/label-policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant policies that are not declared in the YAML.
    Default $false. `Remove-LabelPolicy` is destructive -- the policy
    must usually be set to `Mode Disable` first; the reconciler
    surfaces the server error if the tenant refuses.

.PARAMETER Force
    With `-ExportCurrentState`: allow overwriting a `labelPolicies:` block
    that already contains entries. Without it the script refuses, to avoid
    clobbering hand-curated YAML. Reserved for the export path.

.PARAMETER ExportCurrentState
    Read every label policy visible to the connected app, write to the
    YAML's `labelPolicies:` block, and exit. Makes no writes to the tenant.

.PARAMETER VerifyPublished
    Connect read-only and assert every desired policy in the YAML has
    reached `Status: Published` (for policies with `mode: Enable`) or
    is at least present in the tenant (for policies with `mode:
    Disable`, which intentionally do not publish). Emits a PSCustomObject
    table with columns Name / DesiredMode / TenantStatus / Result
    (`Pass` / `Fail` / `Missing`) and throws on any non-`Pass` row so a
    CI runner exits non-zero. Mutually exclusive with `-ExportCurrentState`.
    Makes no writes to the tenant.
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy

.PARAMETER CompareWithTenant
    Connect read-only and structurally compare the desired-state YAML
    against the live tenant via the same already-sorted hash functions
    used by Apply. Throws (non-zero exit) on any drift: a policy
    declared in YAML but not in the tenant (`DesiredOnly`), present in
    the tenant but not in YAML (`TenantOnly`), or present in both with
    differing tracked fields (`FieldDiff`). Used by
    `.github/workflows/deploy-label-policies.yml` as the conflict
    guard. Order of elements inside unordered set-shaped fields
    (`labels:`, `exchangeLocation:`) and YAML comments are intentionally
    not considered: Microsoft Learn documents no order semantics for
    these fields, and `Get-LabelPolicy` does not reproduce YAML
    comments (issue #235). Makes no writes to the tenant.
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved
    from `automation.apps.dataPlane.certificateName` in the parameters
    file.

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
                         No New-/Set-/Remove-LabelPolicy call fires
                         under any circumstance. Equivalent to a
                         forced -WhatIf at the script boundary.
      * `portal-wins` -- (default) skip any shared policy whose
                         tracked fields differ; emit a Skip plan row
                         per skipped policy and a `[ADR0029-SKIP]
                         <name>` line per skipped policy so an
                         upstream workflow can capture the list for
                         an auto-PR. Create / Update / NoChange and
                         orphan handling are unchanged.
      * `repo-wins`   -- apply the full plan including shared-
                         property drift. Emit one Write-Warning per
                         overwritten shared policy naming the
                         drifted field(s). The typed-confirmation
                         gate ('overwrite portal') is a CI-layer
                         concern enforced by the workflow per
                         ADR 0029; local script callers are
                         operator-trusted.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. When set,
    each named policy that would otherwise drift is emitted as a Skip
    plan row instead of an Update row (reason: "explicitly skipped by
    caller"). NoChange, Create, and Orphan rows are unaffected. Names
    not present in the YAML or the tenant are silently ignored
    (defends against a stale skip list from the workflow).
    Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.EXAMPLE
    ./scripts/Deploy-LabelPolicies.ps1 -WhatIf

    Connect read-only and emit the per-policy Create / Update / NoChange
    plan table for what an Apply would do; make no remote writes. Pair
    with `-PruneMissing` to additionally surface the orphan rows that a
    destructive Apply would remove.

.EXAMPLE
    ./scripts/Deploy-LabelPolicies.ps1

    Create or update policies declared in the YAML. Tenant-only
    policies are reported and skipped (no `-PruneMissing`).

.EXAMPLE
    ./scripts/Deploy-LabelPolicies.ps1 -ExportCurrentState

    Hydrate `data-plane/information-protection/label-policies.yaml`
    from the live tenant. Refuses to overwrite non-empty managed
    state without `-Force`.

.EXAMPLE
    ./scripts/Deploy-LabelPolicies.ps1 -VerifyPublished

    Connect read-only and assert every policy declared in the YAML
    with `mode: Enable` has reached `Status: Published`. Throws on any
    `Fail` or `Missing` row. Intended for use in CI immediately after
    an Apply step (mirrors the inline Verify-Published block in
    `.github/workflows/deploy-label-policies.yml`).

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
        `Compliance Data Administrator` assigned at directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason / Field. Suitable for capture to
    `$GITHUB_STEP_SUMMARY` or a file. No credential material is
    printed; tenant-real identifiers (policy GUIDs, appId, tenantId)
    are not echoed at INFO level.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/information-protection/label-policies.schema.json`
        (JSON Schema Draft-07) at script start, after
        `ConvertFrom-Yaml` and before any reconcile work.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      * Pass `-SkipSchemaValidation` to bypass the check in emergency
        scenarios (e.g. fixing the schema itself). Do not use in CI.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Compare')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\information-protection\label-policies.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Verify', Mandatory = $true)]
    [switch]$VerifyPublished,

    [Parameter(ParameterSetName = 'Compare', Mandatory = $true)]
    [switch]$CompareWithTenant,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [Parameter(ParameterSetName = 'Compare')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [Parameter(ParameterSetName = 'Compare')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [Parameter(ParameterSetName = 'Compare')]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [Parameter(ParameterSetName = 'Compare')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [Parameter(ParameterSetName = 'Verify')]
    [Parameter(ParameterSetName = 'Compare')]
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
    [Parameter(ParameterSetName = 'Compare')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

# Allowed `Mode` values per New-LabelPolicy / Set-LabelPolicy. The cmdlets
# accept these four; anything else is rejected client-side here so the
# operator gets a clear validation error instead of a Microsoft cmdlet
# stack at write time.
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
$script:ValidPolicyModes = @('Enable', 'Disable', 'TestWithNotifications', 'TestWithoutNotifications')

# Map of `Get-LabelPolicy.Mode` read-only runtime states to the cmdlet-input
# `Mode` values listed above. `Get-LabelPolicy` can surface runtime states
# (notably `Enforce` for a published policy whose input mode was `Enable`)
# that `Set-LabelPolicy -Mode` rejects on writeback. Normalizing here
# keeps the Apply / Export round-trip deterministic: an exported YAML must
# be replayable through Apply without further edits. Unmapped states throw
# on encounter so a future Microsoft Purview-side change surfaces as a
# loud failure rather than a silent drift artifact (issue #192).
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
$script:RuntimePolicyModeMap = @{
    'Enforce' = 'Enable'
}

function ConvertTo-PolicyInputMode {
    # Normalize a `Get-LabelPolicy.Mode` value to the cmdlet-input form
    # accepted by `Set-LabelPolicy -Mode`. Pass-through for the four
    # input-valid values; mapped for known read-only runtime states;
    # throws for anything else.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Mode)

    if ([string]::IsNullOrWhiteSpace($Mode)) { return '' }
    if ($script:ValidPolicyModes -contains $Mode) { return $Mode }
    if ($script:RuntimePolicyModeMap.ContainsKey($Mode)) {
        return $script:RuntimePolicyModeMap[$Mode]
    }
    throw ("Unmapped tenant Mode value: '{0}'. Allowed input modes: {1}. Known runtime mappings: {2}. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy" -f 
        $Mode, ($script:ValidPolicyModes -join ', '), (($script:RuntimePolicyModeMap.Keys | Sort-Object) -join ', '))
}

function Resolve-TenantPolicyStatus {
    # Returns the normalized verify-report TenantStatus for a tenant policy.
    # `Get-LabelPolicy.Status` is empty for some long-lived published policies
    # (notably the built-in `Global sensitivity label policy`) even when the
    # policy is actively deployed. When `Status` is empty but `Mode` is a
    # known deployed runtime state (e.g. `Enforce`), treat it as `Published`
    # so verify reflects reality. Issue #200 / PR #201.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Status,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Mode,
        [Parameter(Mandatory = $false)][hashtable]$RuntimeModeMap = $script:RuntimePolicyModeMap
    )

    if ($Status) { return [string]$Status }
    if ($RuntimeModeMap -and $RuntimeModeMap.ContainsKey([string]$Mode)) {
        return 'Published'
    }
    return '<empty>'
}

# Allowed `advancedSettings:` keys on the Apply path per ADR 0015 section 3
# (extended by ADR 0030 row 1 per issue #488 — `OutlookDefaultLabel`; row 2
# per issue #490 — `teamworkdefaultlabelid`).
# Comparison is case-insensitive (PowerShell `-contains`) so YAML may use
# either camelCase or lowercase. Adding a key requires a follow-up issue
# with a Microsoft Learn citation justifying the addition. The Export
# path filters tenant-side keys to this same set so a round-trip Apply
# against an exported YAML is deterministic.
# Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
# Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-aip#outlook-specific-options-for-default-label-and-mandatory-labeling
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
# Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-meetings
# Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
$script:AdvancedSettingsAllowlist = @('RequireDowngradeJustification', 'MandatoryLabelling', 'HideBarByDefault', 'OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')

# Subset of `$script:AdvancedSettingsAllowlist` whose VALUE is a label
# reference (composite key or bare display name) that must be resolved
# to an immutable label GUID before the Compare-PolicyHash diff. The
# other allowlist keys carry boolean / string scalars and are compared
# verbatim. `Resolve-DesiredAdvancedSettingLabel` reads this list to
# decide which `advancedSettings` values to translate.
$script:LabelReferenceAdvancedSettingsKeys = @('OutlookDefaultLabel', 'teamworkdefaultlabelid', 'DefaultLabel')

# Tracked-field set used for diffing desired YAML vs. tenant
# Get-LabelPolicy. Anything outside this set is intentionally ignored on
# the Apply path; #68 (the JSON schema) will gate field additions.
# Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
$script:TrackedScalarFields = @('mode', 'powerBIComplianceInformation')

function Format-AdvancedSettingsYamlBlock {
    # Post-process a ConvertTo-Yaml output string so the
    # advancedSettings: sub-block round-trips byte-identical against
    # the committed YAML convention regardless of the casing the live
    # tenant returns from Get-LabelPolicy.Settings and regardless of
    # whether YamlDotNet emits scalar values quoted or bare.
    #
    # Two normalizations are applied to every key/value line nested
    # under an advancedSettings: parent:
    #   1. Key casing rewritten to the canonical casing declared in
    #      $script:AdvancedSettingsAllowlist (case-insensitive match;
    #      non-allowlisted keys are left untouched as a defensive guard).
    #   2. Bare unquoted scalar values are wrapped in double quotes to
    #      match the apply-side YAML convention. Values already quoted
    #      (single or double) or that open a flow collection ([ or {)
    #      are left untouched.
    #
    # Issue: #503 (recurring cosmetic drift-back PRs from
    # sync-label-policies-from-tenant.yml).
    # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Yaml
    )

    if ([string]::IsNullOrEmpty($Yaml)) { return $Yaml }

    $canonicalByLower = @{}
    foreach ($k in $script:AdvancedSettingsAllowlist) {
        $canonicalByLower[$k.ToLowerInvariant()] = $k
    }

    # Character class matches literal " (char 34), ' (char 39), [, or {.
    # Built via [char] codes to avoid escaping nightmares across the
    # double-quote / single-quote / backtick interaction in PS literals.
    $quoteOrBracket = [regex]('^[' + [char]34 + [char]39 + '\[\{]')
    $kvLine = [regex]'^(?<lead>\s+)(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?<val>.*)$'
    $blockHeader = [regex]'^(\s*)advancedSettings\s*:\s*$'
    $blank = [regex]'^\s*$'

    $outLines = $Yaml -split "`n"
    $inBlock = $false
    $blockIndent = -1
    for ($i = 0; $i -lt $outLines.Count; $i++) {
        $line = $outLines[$i]
        $hdr = $blockHeader.Match($line)
        if ($hdr.Success) {
            $inBlock = $true
            $blockIndent = $hdr.Groups[1].Length
            continue
        }
        if (-not $inBlock) { continue }
        if ($blank.IsMatch($line)) { continue }
        $leadMatch = [regex]::Match($line, "^(\s*)")
        $lead = $leadMatch.Groups[1].Length
        if ($lead -le $blockIndent) {
            $inBlock = $false
            $blockIndent = -1
            continue
        }
        $kvMatch = $kvLine.Match($line)
        if (-not $kvMatch.Success) { continue }
        $leadOut = $kvMatch.Groups["lead"].Value
        $keyOut = $kvMatch.Groups["key"].Value
        $valOut = $kvMatch.Groups["val"].Value
        $keyLower = $keyOut.ToLowerInvariant()
        if ($canonicalByLower.ContainsKey($keyLower)) {
            $keyOut = $canonicalByLower[$keyLower]
        }
        $trimmedVal = $valOut.Trim()
        if ($trimmedVal.Length -gt 0 -and -not $quoteOrBracket.IsMatch($trimmedVal)) {
            $valOut = ([char]34 + $trimmedVal + [char]34)
        }
        $outLines[$i] = "{0}{1}: {2}" -f $leadOut, $keyOut, $valOut
    }
    return ($outLines -join "`n")
}

function ConvertTo-PolicyHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # Drops nulls, sorts list-typed fields for stable equality.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $h = @{
        name                         = [string]$Entry.name
        mode                         = if ($Entry.ContainsKey('mode')) { [string]$Entry.mode } else { '' }
        # Normalize YAML boolean to lowercase string for drift comparison.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
        powerBIComplianceInformation = if ($Entry.ContainsKey('powerBIComplianceInformation')) { ([string]$Entry.powerBIComplianceInformation).ToLowerInvariant() } else { '' }
        exchangeLocation             = @()
        exchangeLocationException    = @()
        modernGroupLocation          = @()
        includedAdministrativeUnits  = @()
        labels                       = @()
        advancedSettings             = @{}
    }
    if ($Entry.ContainsKey('exchangeLocation') -and $Entry.exchangeLocation) {
        $h.exchangeLocation = @(($Entry.exchangeLocation |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    # exchangeLocationException: mailbox SMTP / DN / GUID, or mail-enabled
    # group identifier. Cmdlet accepts the value verbatim; no Microsoft
    # Graph principal-id resolution required (verified 2026-05-31 against
    # the Set-LabelPolicy reference -ExchangeLocationException entry).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
    if ($Entry.ContainsKey('exchangeLocationException') -and $Entry.exchangeLocationException) {
        $h.exchangeLocationException = @(($Entry.exchangeLocationException |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    # modernGroupLocation: Microsoft 365 group identifiers targeting the
    # Sites & Groups wizard step of the Edit-policy UI. The
    # Set-LabelPolicy -ModernGroupLocation parameter accepts the group
    # display name or object identifier. Group display names are resolved
    # at deploy time per ADR 0023 Category 3
    # (Get-EntraPrincipalIdByDisplayName.ps1). #471 row 4; ADR 0030.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
    if ($Entry.ContainsKey('modernGroupLocation') -and $Entry.modernGroupLocation) {
        $h.modernGroupLocation = @(($Entry.modernGroupLocation |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    # includedAdministrativeUnits: Entra administrative unit display names
    # restricting this policy to users in the specified AUs. Display names
    # are passed to Set-LabelPolicy -IncludedAdministrativeUnits at deploy
    # time. Lab desired state is empty; no Graph resolution calls are made
    # for the empty-list case. #471 row 6; ADR 0042.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
    if ($Entry.ContainsKey('includedAdministrativeUnits') -and $Entry.includedAdministrativeUnits) {
        $h.includedAdministrativeUnits = @(($Entry.includedAdministrativeUnits |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Entry.ContainsKey('labels') -and $Entry.labels) {
        $h.labels = @(($Entry.labels |
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
    # Normalize a tenant Get-LabelPolicy result into the same shape as
    # ConvertTo-PolicyHash. The cmdlet returns Labels as a GUID array;
    # we keep them as GUIDs and let the caller (which has the
    # Get-Label lookup in scope) translate desired composite keys to
    # GUIDs before comparing.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
    # NOTE: on the Security & Compliance endpoint, `Get-LabelPolicy.Labels`
    # returns a heterogeneous mix of (a) label GUIDs, (b) `<Parent> - <Child>`
    # composite display names, and (c) bare `<DisplayName>` strings for
    # sublabels created via the Purview portal. Pass `-TenantLabels (Get-Label)`
    # to translate each entry to the immutable label GUID so Apply diff and
    # Export YAML emission see one canonical shape (issues #195, #230).
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $false)][object[]]$TenantLabels = @()
    )

    $h = @{
        name                         = [string]$Policy.Name
        guid                         = [string]$Policy.Guid
        mode                         = ConvertTo-PolicyInputMode -Mode ([string]$Policy.Mode)
        status                       = if ($Policy.Status) { [string]$Policy.Status } else { '' }
        # Normalize tenant boolean to lowercase string matching ConvertTo-PolicyHash.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        powerBIComplianceInformation = if ($null -ne $Policy.PowerBIComplianceInformation) { ([string]$Policy.PowerBIComplianceInformation).ToLowerInvariant() } else { '' }
        exchangeLocation             = @()
        exchangeLocationException    = @()
        modernGroupLocation          = @()
        includedAdministrativeUnits  = @()
        labels                       = @()
        advancedSettings             = @{}
    }
    if ($Policy.ExchangeLocation) {
        # ExchangeLocation comes back as a strongly-typed result-set;
        # `.DisplayName` carries the user-visible value (`All` or a
        # mailbox SMTP). Normalize to a sorted unique list of strings.
        $h.exchangeLocation = @(($Policy.ExchangeLocation |
                ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.DisplayName) { [string]$_.DisplayName }
                    else { [string]$_ }
                } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Policy.ExchangeLocationException) {
        # ExchangeLocationException returns the same MultiValuedProperty
        # shape as ExchangeLocation. `DisplayName` carries the mailbox
        # SMTP / DN. Mail-enabled-group expansion happens server-side at
        # publish time (per the Set-LabelPolicy reference); the tenant-
        # read returns the group identifier the operator originally typed,
        # not the expanded membership.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        $h.exchangeLocationException = @(($Policy.ExchangeLocationException |
                ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.DisplayName) { [string]$_.DisplayName }
                    else { [string]$_ }
                } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Policy.ModernGroupLocation) {
        # ModernGroupLocation returns the same MultiValuedProperty shape as
        # ExchangeLocation. `DisplayName` carries the M365 group identifier
        # (display name or object ID as originally supplied). #471 row 4.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        $h.modernGroupLocation = @(($Policy.ModernGroupLocation |
                ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.DisplayName) { [string]$_.DisplayName }
                    else { [string]$_ }
                } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Policy.IncludedAdministrativeUnits) {
        # IncludedAdministrativeUnits returns a MultiValuedProperty. Each
        # entry is a display name or GUID as originally supplied to the cmdlet.
        # Read .DisplayName when present; fall back to string representation.
        # #471 row 6; ADR 0042.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        $h.includedAdministrativeUnits = @(($Policy.IncludedAdministrativeUnits |
                ForEach-Object {
                    if ($_ -is [string]) { $_ }
                    elseif ($_.DisplayName) { [string]$_.DisplayName }
                    else { [string]$_ }
                } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }) | Sort-Object -Unique)
    }
    if ($Policy.Labels) {
        # Build display-name -> GUID lookup from the supplied Get-Label
        # results. `Get-LabelPolicy.Labels` returns a heterogeneous mix:
        #   - bare label GUIDs (most common for Apply-time created labels)
        #   - "<Parent> - <Child>" composite display names (occasional)
        #   - bare <DisplayName> for sublabels created via the Purview
        #     portal (observed 2026-05-14; issue #230)
        #   - slugified <DisplayName> where ' ', '(' and ')' have been
        #     replaced with '-' (e.g. `External--Restricted-` for
        #     `External (Restricted)`; also observed 2026-05-14; issue #230)
        # All four shapes must collapse to the same canonical GUID so
        # downstream delta comparisons against the YAML's GUID-translated
        # desired state do not produce false-positive add/remove churn.
        # If no labels were supplied, fall back to the raw strings so
        # behavior is unchanged for callers that haven't been updated
        # yet (issue #195).
        $renderToGuid = @{}
        $bareToGuid = @{}
        $bareCollisions = New-Object 'System.Collections.Generic.HashSet[string]'
        if ($TenantLabels.Count -gt 0) {
            $labelById = @{}
            foreach ($l in $TenantLabels) { $labelById[[string]$l.Guid] = $l }
            foreach ($l in $TenantLabels) {
                $rendered = if ($l.ParentId -and $labelById.ContainsKey([string]$l.ParentId)) {
                    "{0} - {1}" -f [string]$labelById[[string]$l.ParentId].DisplayName, [string]$l.DisplayName
                }
                else { [string]$l.DisplayName }
                $renderToGuid[$rendered] = [string]$l.Guid
                $renderSlug = $rendered -replace '[\s()]', '-'
                if (-not $renderToGuid.ContainsKey($renderSlug)) {
                    $renderToGuid[$renderSlug] = [string]$l.Guid
                }
                # Track bare DisplayName for the portal-created sublabel
                # case. If two labels share a bare DisplayName, mark the
                # collision and skip the bare lookup -- the caller will
                # see the raw entry passed through and the diff will
                # surface as drift the operator can resolve in YAML.
                $bare = [string]$l.DisplayName
                $bareSlug = $bare -replace '[\s()]', '-'
                foreach ($key in @($bare, $bareSlug)) {
                    if ($bareToGuid.ContainsKey($key)) {
                        if ($bareToGuid[$key] -ne [string]$l.Guid) {
                            [void]$bareCollisions.Add($key)
                        }
                    }
                    else {
                        $bareToGuid[$key] = [string]$l.Guid
                    }
                }
            }
            foreach ($c in $bareCollisions) { [void]$bareToGuid.Remove($c) }
        }
        $translated = @()
        foreach ($entry in $Policy.Labels) {
            $s = [string]$entry
            if ($renderToGuid.ContainsKey($s)) { $translated += $renderToGuid[$s] }
            elseif ($bareToGuid.ContainsKey($s)) { $translated += $bareToGuid[$s] }
            else { $translated += $s }
        }
        $h.labels = @($translated | Sort-Object -Unique)
    }
    if ($Policy.Settings) {
        # Settings is a list of `[Key, Value]` two-element strings on
        # Get-LabelPolicy; project into a hashtable and lowercase
        # values for stable comparison. Filter to the ADR 0015 section 3
        # allowlist so unrelated tenant-side keys are not surfaced as
        # drift.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
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
    # Returns a list of differing field names (strings). Empty list
    # means equal across the tracked surface. `Desired.labels` carries
    # GUIDs by the time this runs (the caller resolved composite-key
    # references against Get-Label), so it can compare directly to
    # `Tenant.labels`.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = @()
    foreach ($f in $script:TrackedScalarFields) {
        if (([string]$Desired[$f]) -ne ([string]$Tenant[$f])) { $diffs += $f }
    }
    if (($Desired.exchangeLocation -join ',') -ne ($Tenant.exchangeLocation -join ',')) {
        $diffs += 'exchangeLocation'
    }
    if (($Desired.exchangeLocationException -join ',') -ne ($Tenant.exchangeLocationException -join ',')) {
        $diffs += 'exchangeLocationException'
    }
    if (($Desired.modernGroupLocation -join ',') -ne ($Tenant.modernGroupLocation -join ',')) {
        $diffs += 'modernGroupLocation'
    }
    if (($Desired.includedAdministrativeUnits -join ',') -ne ($Tenant.includedAdministrativeUnits -join ',')) {
        $diffs += 'includedAdministrativeUnits'
    }
    if (($Desired.labels -join ',') -ne ($Tenant.labels -join ',')) {
        $diffs += 'labels'
    }
    # AdvancedSettings: compare allowlisted keys only. The desired side
    # was already validated against the allowlist before normalization.
    foreach ($k in $script:AdvancedSettingsAllowlist) {
        $d = if ($Desired.advancedSettings.ContainsKey($k)) { $Desired.advancedSettings[$k] } else { $null }
        $t = if ($Tenant.advancedSettings.ContainsKey($k))  { $Tenant.advancedSettings[$k]  } else { $null }
        if (([string]$d) -ne ([string]$t)) { $diffs += "advancedSettings.$k" }
    }
    return $diffs
}

function ConvertTo-LabelGuidLookup {
    # Build a lookup from composite key (`<parent>/<displayName>` for
    # sublabels, bare `<displayName>` for top-level) to label GUID.
    # Mirrors the disambiguation Deploy-Labels.ps1 already uses (#131).
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
    # Resolve a desired YAML label reference (composite or bare key)
    # to a label GUID via the lookup. Returns $null if the label is
    # not present in the tenant; the caller decides whether that is a
    # blocker (Apply: yes) or skipped (Export: never called).
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][hashtable]$Lookup
    )
    if ($Lookup.ContainsKey($Reference)) { return $Lookup[$Reference] }
    return $null
}

function Resolve-DesiredAdvancedSettingLabel {
    # Walk the keys in $script:LabelReferenceAdvancedSettingsKeys; for
    # each that is populated on the desired hash, resolve the value via
    # Resolve-DesiredLabelGuid and rewrite the hash to carry the
    # lowercase GUID. Returns the list of advanced-setting label
    # references that failed to resolve (caller surfaces these as
    # Blocked rows, same shape as labels-side miss).
    # GUID-shaped inputs pass through unchanged (lowercased) so an
    # already-resolved YAML round-trip stays stable.
    # Reference: docs/adr/0030-label-policies-tracked-field-expansion.md
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [Parameter(Mandatory = $true)][hashtable]$Lookup
    )
    $missing = @()
    if (-not $Hash.advancedSettings) { return ,$missing }
    foreach ($k in $script:LabelReferenceAdvancedSettingsKeys) {
        if (-not $Hash.advancedSettings.ContainsKey($k)) { continue }
        $ref = [string]$Hash.advancedSettings[$k]
        if ([string]::IsNullOrWhiteSpace($ref)) { continue }
        # 'None' is the documented "no default label" sentinel for the
        # label-reference advanced settings (OutlookDefaultLabel,
        # DefaultLabel, teamworkdefaultlabelid), NOT a label display name.
        # Get-LabelPolicy.Settings stores it lowercased as 'none'; normalize
        # the desired side to the same lowercase sentinel and never attempt a
        # label lookup, so a group-scoped-only policy that opts out of a
        # default label reconverges to NoChange instead of Blocking.
        # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-aip#outlook-specific-options-for-default-label-and-mandatory-labeling
        if ($ref -ieq 'none') {
            $Hash.advancedSettings[$k] = 'none'
            continue
        }
        if ($ref -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $Hash.advancedSettings[$k] = $ref.ToLowerInvariant()
            continue
        }
        $g = Resolve-DesiredLabelGuid -Reference $ref -Lookup $Lookup
        if ($g) {
            $Hash.advancedSettings[$k] = ([string]$g).ToLowerInvariant()
        }
        else {
            $missing += ("advancedSettings.{0}={1}" -f $k, $ref)
        }
    }
    return ,$missing
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
# scripts/Deploy-Labels.ps1 (and future Deploy-*.ps1 reconcilers
# per issue #463). Extracted in #473.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
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
        elseif ($CompareWithTenant.IsPresent) { 'Compare' }
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
    $schemaPath = Join-Path $scriptRoot '..\data-plane\information-protection\label-policies.schema.json'
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

$desiredEntries = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('labelPolicies') -and $desiredRoot.labelPolicies) {
    $desiredEntries = @($desiredRoot.labelPolicies)
}

$desiredHashes = @()
if ($mode -eq 'Apply' -or $mode -eq 'Verify' -or $mode -eq 'Compare') {
    foreach ($e in $desiredEntries) {
        if (-not $e.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$e.name)) {
            Write-Error ("Label-policy entry in '{0}' is missing the required 'name' field." -f $Path)
            return
        }
        if (-not $e.ContainsKey('mode') -or [string]::IsNullOrWhiteSpace([string]$e.mode)) {
            Write-Error ("Label policy '{0}' is missing the required 'mode' field. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy" -f $e.name)
            return
        }
        if ($script:ValidPolicyModes -notcontains [string]$e.mode) {
            Write-Error ("Label policy '{0}' has invalid mode '{1}'. Allowed: {2}. Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy" -f $e.name, $e.mode, ($script:ValidPolicyModes -join ', '))
            return
        }
        if ($e.ContainsKey('advancedSettings') -and $e.advancedSettings) {
            foreach ($k in $e.advancedSettings.Keys) {
                if ($script:AdvancedSettingsAllowlist -notcontains [string]$k) {
                    Write-Error ("Label policy '{0}' declares advancedSettings key '{1}' which is not in the ADR 0015 section 3 allowlist ({2}). Adding a key requires a new ADR follow-up issue with a Microsoft Learn citation." -f $e.name, $k, ($script:AdvancedSettingsAllowlist -join ', '))
                    return
                }
            }
        }
        $desiredHashes += ConvertTo-PolicyHash -Entry $e
    }
    # Validate uniqueness on `name`.
    $seenNames = @{}
    foreach ($h in $desiredHashes) {
        if ($seenNames.ContainsKey($h.name)) {
            Write-Error ("Label-policy name '{0}' is declared more than once in '{1}'." -f $h.name, $Path)
            return
        }
        $seenNames[$h.name] = $true
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

#region -WhatIf short-circuit (Export only -- Apply runs the read phase)

# -WhatIf on the Apply path deliberately does NOT short-circuit. The Apply
# branch's per-write `$PSCmdlet.ShouldProcess(...)` calls already gate every
# New-LabelPolicy / Set-LabelPolicy / Remove-LabelPolicy invocation, so
# connecting and running the read phase under -WhatIf produces the same
# per-policy plan table the operator sees during a real Apply -- exactly
# what destructive-change PR previews require. Mirrors Deploy-Labels.ps1
# (issue #152).
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute#supportsshouldprocess
# Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Connect, run Get-LabelPolicy + Get-Label, write every visible policy to {0}.' -f $Path) -InformationAction Continue
    return
}

if ($WhatIfPreference -and $mode -eq 'Verify') {
    Write-Information '-WhatIf specified with -VerifyPublished. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Connect, run Get-LabelPolicy, assert every desired policy has reached Status: Published.') -InformationAction Continue
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
# NOTE: $appId deliberately not echoed at INFO -- real tenant identifier.

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

#region Connect, reconcile, disconnect (single session for the whole run)

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

        #region -VerifyPublished
        #
        # Stronger signal than the inline `-WhatIf reconcile == NoChange`
        # check in `.github/workflows/deploy-label-policies.yml`: reads
        # `Status` from `Get-LabelPolicy` directly. A reconciled policy
        # can still sit at `Status: Pending` for a few seconds after
        # Apply; this switch is the explicit post-Apply gate.
        #
        # Result semantics:
        #   Pass    - mode: Enable  -> tenant exists AND Status == Published
        #             mode: Disable -> tenant exists (status not checked)
        #             mode: Test*   -> tenant exists (status not checked;
        #                              test modes do not publish to users)
        #   Fail    - tenant exists but Status diverges (only checked for
        #             mode: Enable).
        #   Missing - desired policy not present in the tenant.
        #
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        # Reference: https://learn.microsoft.com/en-us/purview/create-sensitivity-labels#publish-sensitivity-labels-by-creating-a-label-policy

        $tenantPolicies = @(Get-LabelPolicy -ErrorAction Stop)
        Write-Information ("Read {0} policy/policies from tenant for verification." -f $tenantPolicies.Count) -InformationAction Continue

        $tenantByName = @{}
        foreach ($p in $tenantPolicies) { $tenantByName[[string]$p.Name] = $p }

        $verifyRows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($d in $desiredHashes) {
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
            # Normalize runtime status: empty `Get-LabelPolicy.Status` paired with
            # a known runtime Mode reports as `Published`. Issue #200 / PR #201.
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
            $tenantStatus = Resolve-TenantPolicyStatus -Status $tenantPolicy.Status -Mode $tenantPolicy.Mode
            if ($d.mode -eq 'Enable') {
                $result = if ($tenantStatus -eq 'Published') { 'Pass' } else { 'Fail' }
            }
            else {
                # Disable / TestWithNotifications / TestWithoutNotifications
                # do not publish to end users; presence is the only check.
                $result = 'Pass'
            }
            $verifyRows.Add([pscustomobject]@{
                Name         = $d.name
                DesiredMode  = $d.mode
                TenantStatus = $tenantStatus
                Result       = $result
            })
        }

        Write-Information '' -InformationAction Continue
        Write-Information 'Verify-Published report:' -InformationAction Continue
        $verifyRows |
            Sort-Object Result, Name |
            Format-Table Name, DesiredMode, TenantStatus, Result -AutoSize |
            Out-String |
            Write-Information -InformationAction Continue

        # Emit rows to the pipeline so callers can capture for further
        # processing (e.g. $GITHUB_STEP_SUMMARY).
        $verifyRows

        $failures = @($verifyRows | Where-Object { $_.Result -ne 'Pass' })
        if ($failures.Count -gt 0) {
            throw ("Verify-Published failed: {0} policy/policies did not pass. See report above." -f $failures.Count)
        }

        Write-Information ("Verify-Published passed: all {0} declared policy/policies satisfy the publication contract." -f $verifyRows.Count) -InformationAction Continue
        return

        #endregion
    }

    if ($mode -eq 'Compare') {

        #region -CompareWithTenant
        #
        # Structural drift detection for the GitHub Actions conflict
        # guard (issue #235). Replaces the prior `git diff --no-index`
        # against the committed YAML and the tenant export, which was
        # both order- and comment-sensitive: the tenant returns labels
        # alphabetized while the author-ordered YAML lists them in a
        # different sequence, and `Get-LabelPolicy` does not reproduce
        # YAML comments, so any descriptive comment block above a list
        # field tripped the byte-level diff.
        #
        # This mode hashes desired YAML and tenant policies via the
        # same already-sorted ConvertTo-PolicyHash /
        # ConvertTo-TenantPolicyHash functions used by Apply, then
        # compares per-policy via Compare-PolicyHash. Comments and
        # element ordering inside unordered set-shaped fields (labels,
        # exchangeLocation) are invisible to the comparison by
        # construction. Microsoft Learn documents no order semantics
        # for these fields on Set-LabelPolicy / New-LabelPolicy, so
        # treating them as sets is correct.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
        #
        # Exit semantics: any drift row (DesiredOnly, TenantOnly,
        # FieldDiff) throws so the workflow step fails with non-zero
        # exit code. A clean comparison returns silently after writing
        # an informational confirmation line.

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        $tenantPolicies = @(Get-LabelPolicy -ErrorAction Stop)
        Write-Information ("Read {0} policy/policies from tenant." -f $tenantPolicies.Count) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
        $tenantLabels = @(Get-Label -ErrorAction Stop)
        $labelLookup = ConvertTo-LabelGuidLookup -Labels $tenantLabels

        # Resolve desired composite-key label references to GUIDs so
        # the comparison runs against canonical identifiers (same as
        # the Apply path's pre-categorize step).
        $resolvedDesired = @()
        foreach ($d in $desiredHashes) {
            $resolved = @()
            $missing = @()
            foreach ($ref in $d.labels) {
                $g = Resolve-DesiredLabelGuid -Reference $ref -Lookup $labelLookup
                if ($g) { $resolved += $g } else { $missing += $ref }
            }
            $advMissing = Resolve-DesiredAdvancedSettingLabel -Hash $d -Lookup $labelLookup
            if ($advMissing -and $advMissing.Count -gt 0) { $missing += $advMissing }
            if ($missing.Count -gt 0) {
                throw ("Conflict guard: label reference(s) not found in tenant for policy '{0}': {1}. Run scripts/Deploy-Labels.ps1 to apply the label taxonomy first, then re-run." -f $d.name, ($missing -join ', '))
            }
            $d.labels = @($resolved | Sort-Object -Unique)
            $resolvedDesired += $d
        }

        $tenantByName = @{}
        foreach ($p in $tenantPolicies) { $tenantByName[[string]$p.Name] = $p }
        $desiredByName = @{}
        foreach ($d in $resolvedDesired) { $desiredByName[$d.name] = $d }

        $driftRows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($name in ($desiredByName.Keys | Sort-Object)) {
            if (-not $tenantByName.ContainsKey($name)) {
                $driftRows.Add([pscustomobject]@{
                    Name   = $name
                    Drift  = 'DesiredOnly'
                    Fields = '(policy declared in YAML but not present in tenant)'
                })
                continue
            }
            $tenantHash = ConvertTo-TenantPolicyHash -Policy $tenantByName[$name] -TenantLabels $tenantLabels
            $diffs = Compare-PolicyHash -Desired $desiredByName[$name] -Tenant $tenantHash
            if ($diffs.Count -gt 0) {
                $driftRows.Add([pscustomobject]@{
                    Name   = $name
                    Drift  = 'FieldDiff'
                    Fields = ($diffs -join ', ')
                })
            }
        }
        foreach ($name in ($tenantByName.Keys | Sort-Object)) {
            if (-not $desiredByName.ContainsKey($name)) {
                $driftRows.Add([pscustomobject]@{
                    Name   = $name
                    Drift  = 'TenantOnly'
                    Fields = '(policy present in tenant but not declared in YAML)'
                })
            }
        }

        if ($driftRows.Count -gt 0) {
            Write-Information ("Conflict guard drift report ({0} row(s)):" -f $driftRows.Count) -InformationAction Continue
            $driftRows |
                Format-Table Name, Drift, Fields -AutoSize |
                Out-String |
                Write-Information -InformationAction Continue
            throw ("Conflict guard: live tenant has drifted from data-plane/information-protection/label-policies.yaml. {0} drift row(s) reported above. Drift kinds: DesiredOnly = policy in YAML but not tenant; TenantOnly = policy in tenant but not YAML; FieldDiff = present in both, tracked field(s) differ. Run scripts/Deploy-LabelPolicies.ps1 -ExportCurrentState locally, file the resulting drift-back PR, merge it, then re-run this workflow against the new SHA." -f $driftRows.Count)
        }

        Write-Information ("Conflict guard passed: tenant matches '{0}' (structural comparison; label and exchangeLocation ordering and YAML comments are intentionally not considered)." -f $Path) -InformationAction Continue
        return

        #endregion
    }

    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredEntries.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("'{0}' already declares {1} policy/policies in 'labelPolicies:'. Refusing to overwrite without -Force." -f $Path, $desiredEntries.Count)
            return
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
        $allPolicies = @(Get-LabelPolicy -ErrorAction Stop)
        Write-Information ("Discovered {0} policy/policies visible to the connected app." -f $allPolicies.Count) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
        $allLabels = @(Get-Label -ErrorAction Stop)
        $byGuid = @{}
        foreach ($l in $allLabels) { $byGuid[[string]$l.Guid] = $l }
        $byKey = ConvertTo-LabelGuidLookup -Labels $allLabels
        $guidToKey = @{}
        foreach ($k in $byKey.Keys) { $guidToKey[$byKey[$k]] = $k }

        # Stable top-level key sequence: name, mode, exchangeLocation,
        # labels, advancedSettings. Keys with empty values are still
        # emitted to keep the YAML self-describing (a placeholder
        # policy with empty `labels: []` round-trips clean).
        $exportEntries = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
        foreach ($p in $allPolicies | Sort-Object Name) {
            $h = ConvertTo-TenantPolicyHash -Policy $p -TenantLabels $allLabels
            $entry = [ordered]@{}
            $entry['name'] = $h.name
            $entry['mode'] = $h.mode
            # Sort the location list so two consecutive exports against
            # the same tenant produce byte-identical YAML.
            $entry['exchangeLocation'] = @($h.exchangeLocation | Sort-Object)
            # Emit exchangeLocationException only when present so the export YAML
            # stays minimal for the common scope-unset case.
            if ($h.exchangeLocationException -and $h.exchangeLocationException.Count -gt 0) {
                $entry['exchangeLocationException'] = @($h.exchangeLocationException | Sort-Object)
            }
            # Emit modernGroupLocation only when present. #471 row 4; ADR 0030.
            if ($h.modernGroupLocation -and $h.modernGroupLocation.Count -gt 0) {
                $entry['modernGroupLocation'] = @($h.modernGroupLocation | Sort-Object)
            }
            # Emit includedAdministrativeUnits only when present. #471 row 6; ADR 0042.
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
            if ($h.includedAdministrativeUnits -and $h.includedAdministrativeUnits.Count -gt 0) {
                $entry['includedAdministrativeUnits'] = @($h.includedAdministrativeUnits | Sort-Object)
            }
            # Emit powerBIComplianceInformation when set. #471 row 7; ADR 0041.
            # Convert the normalized string back to a boolean for unquoted YAML emission.
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
            if ($h.powerBIComplianceInformation -ne '') {
                $entry['powerBIComplianceInformation'] = ($h.powerBIComplianceInformation -eq 'true')
            }
            # Translate GUID -> composite key where possible. A label
            # whose GUID is not present in the tenant's label list is a
            # data anomaly; emit the raw GUID so the export round-trip
            # stays lossless and the operator can investigate.
            $labelKeys = @()
            foreach ($g in @($h.labels | Sort-Object)) {
                if ($guidToKey.ContainsKey($g)) {
                    $labelKeys += $guidToKey[$g]
                }
                else {
                    $labelKeys += $g
                }
            }
            $entry['labels'] = @($labelKeys | Sort-Object)
            # Emit advanced settings in sorted-key order with lowercase
            # values for stable comparison. Non-allowlisted tenant keys
            # were already filtered by ConvertTo-TenantPolicyHash.
            # For LabelReferenceAdvancedSettingsKeys members the value
            # is the immutable label GUID at this point (post
            # Resolve-DesiredAdvancedSettingLabel on the apply side or
            # post Get-LabelPolicy on the export side). Translate back
            # to the human-readable composite key via $guidToKey so the
            # exported YAML round-trips byte-identical against committed
            # YAML that uses the composite key (issue #497).
            # GUID-not-in-tenant falls through verbatim, mirroring the
            # ``labels`` emission loop above (lossless export anomaly path).
            $advanced = [ordered]@{}
            foreach ($k in @($h.advancedSettings.Keys | Sort-Object)) {
                $v = $h.advancedSettings[$k]
                if ($script:LabelReferenceAdvancedSettingsKeys -contains $k) {
                    $vs = [string]$v
                    if ($vs -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' `
                        -and $guidToKey.ContainsKey($vs)) {
                        $v = $guidToKey[$vs]
                    }
                }
                $advanced[$k] = $v
            }
            $entry['advancedSettings'] = $advanced
            $exportEntries.Add($entry)
        }

        Write-Information ("Exporting {0} policy/policies." -f $exportEntries.Count) -InformationAction Continue

        # Preserve YAML header comments by line-splicing.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*labelPolicies\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'labelPolicies:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = $originalLines[0..($cutIndex - 1)]

        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        if ($exportEntries.Count -eq 0) {
            $newBlock.Add('labelPolicies: []')
        }
        else {
            # Reference: https://www.powershellgallery.com/packages/powershell-yaml
            $body = ([ordered]@{ labelPolicies = @($exportEntries) }) | ConvertTo-Yaml -Options WithIndentedSequences
            # Normalize dvancedSettings: block to canonical key casing +
            # double-quoted scalar values per issue #503 so the export round-trips
            # byte-identical against the apply-side YAML convention.
            $body = Format-AdvancedSettingsYamlBlock -Yaml $body
            foreach ($line in ($body -split "`n")) { $newBlock.Add($line.TrimEnd()) }
            while ($newBlock.Count -gt 0 -and [string]::IsNullOrEmpty($newBlock[$newBlock.Count - 1])) {
                $newBlock.RemoveAt($newBlock.Count - 1)
            }
        }

        $finalLines = @($headerLines) + @($newBlock)
        $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
        $shouldProcessAction = "Replace 'labelPolicies:' block with {0} entry/entries" -f $exportEntries.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            $content = ($finalLines -join "`n") + "`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
            Write-Information ("Wrote {0} policy entry/entries to '{1}'." -f $exportEntries.Count, $Path) -InformationAction Continue
        }
        return

        #endregion
    }

    #region Apply mode: two-phase reconciliation

    # Empty-YAML guard: Apply against an empty desired list is a no-op
    # rather than a destructive prune of the tenant. -PruneMissing is
    # still required to remove tenant-only policies.
    if ($desiredHashes.Count -eq 0 -and -not $PruneMissing.IsPresent) {
        Write-Information 'No label policies declared in YAML. Nothing to reconcile (use -PruneMissing to remove tenant-only policies).' -InformationAction Continue
        return @()
    }

    # ---- Phase 1: Read + categorize ----
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-labelpolicy
    $tenantPolicies = @(Get-LabelPolicy -ErrorAction Stop)
    Write-Information ("Read {0} policy/policies from tenant." -f $tenantPolicies.Count) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-label
    $tenantLabels = @(Get-Label -ErrorAction Stop)
    Write-Information ("Read {0} label(s) from tenant for label-reference resolution." -f $tenantLabels.Count) -InformationAction Continue
    $labelLookup = ConvertTo-LabelGuidLookup -Labels $tenantLabels

    $tenantByName = @{}
    foreach ($p in $tenantPolicies) { $tenantByName[[string]$p.Name] = $p }

    $blockedRows = New-Object 'System.Collections.Generic.List[object]'
    $resolvedDesired = @()
    foreach ($d in $desiredHashes) {
        $resolvedLabels = @()
        $missing = @()
        foreach ($ref in $d.labels) {
            $guid = Resolve-DesiredLabelGuid -Reference $ref -Lookup $labelLookup
            if ($guid) { $resolvedLabels += $guid }
            else { $missing += $ref }
        }
        $advMissing = Resolve-DesiredAdvancedSettingLabel -Hash $d -Lookup $labelLookup
        if ($advMissing -and $advMissing.Count -gt 0) { $missing += $advMissing }
        if ($missing.Count -gt 0) {
            $reason = "Label reference(s) not found in tenant: $($missing -join ', '). Run scripts/Deploy-Labels.ps1 to apply the label taxonomy first, or correct the reference (composite '<parent>/<displayName>' for sublabels, bare '<displayName>' for top-level)."
            $blockedRows.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'LabelPolicy'
                Name     = $d.name
                Reason   = $reason
                Field    = ''
            })
            $report.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'LabelPolicy'
                Name     = $d.name
                Reason   = $reason
                Field    = ''
            })
            continue
        }
        $d.labels = @($resolvedLabels | Sort-Object -Unique)
        $resolvedDesired += $d
    }

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $resolvedDesired) {
        if ($tenantByName.ContainsKey($d.name)) {
            $tenantHash = ConvertTo-TenantPolicyHash -Policy $tenantByName[$d.name] -TenantLabels $tenantLabels
            $diffs = Compare-PolicyHash -Desired $d -Tenant $tenantHash
            if ($diffs.Count -eq 0) {
                $report.Add([pscustomobject]@{
                    Category = 'NoChange'
                    Kind     = 'LabelPolicy'
                    Name     = $d.name
                    Reason   = 'Declared in YAML and present in tenant; tracked fields identical.'
                    Field    = ''
                })
            }
            else {
                foreach ($f in $diffs) {
                    $report.Add([pscustomobject]@{
                        Category = 'Update'
                        Kind     = 'LabelPolicy'
                        Name     = $d.name
                        Reason   = 'Tracked field differs from tenant.'
                        Field    = $f
                    })
                }
                $plan.Add([pscustomobject]@{
                    Action  = 'Update'
                    Desired = $d
                    Tenant  = $tenantByName[$d.name]
                    TenantHash = $tenantHash
                    Fields  = @($diffs)
                })
            }
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'Create'
                Kind     = 'LabelPolicy'
                Name     = $d.name
                Reason   = 'Declared in YAML; not present in tenant.'
                Field    = ''
            })
            $plan.Add([pscustomobject]@{
                Action  = 'Create'
                Desired = $d
                Tenant  = $null
            })
        }
    }

    # Orphans: tenant policies not declared in YAML.
    $desiredNames = @{}
    foreach ($d in $resolvedDesired) { $desiredNames[$d.name] = $true }
    $orphans = @()
    foreach ($p in $tenantPolicies) {
        if (-not $desiredNames.ContainsKey([string]$p.Name)) {
            $orphans += $p
            $cat = if ($PruneMissing.IsPresent) { 'Orphan' } else { 'NoOp' }
            $reason = if ($PruneMissing.IsPresent) {
                'Tenant policy not in YAML; will Remove-LabelPolicy under -PruneMissing.'
            }
            else {
                'Tenant policy not in YAML; skipped (use -PruneMissing to remove).'
            }
            $report.Add([pscustomobject]@{
                Category = $cat
                Kind     = 'LabelPolicy'
                Name     = [string]$p.Name
                Reason   = $reason
                Field    = ''
            })
        }
    }

    # ---- ADR 0029: direction-policy pass ----
    # Walk the Update plan entries; for each, consult Resolve-DirectionPolicyAction
    # to decide Skip vs. Update under the configured policy and operator-
    # supplied SkipNames list. Create entries are unaffected (a policy that
    # exists in YAML but not in the tenant has no shared-property drift to
    # arbitrate). Audit mode is handled by a separate short-circuit below
    # and does not enter this pass. The Write-Warning for repo-wins fires
    # ONCE per drifted policy with the comma-joined drifted-field set --
    # the granular Set-LabelPolicy calls in Phase 3 (Mode, ExchangeLocation,
    # AddLabels, RemoveLabels, AdvancedSettings) stay unchanged so 1-5
    # warnings per policy would be noisy and incoherent.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'
        $keptPolicyPlan = @()
        foreach ($p in $plan) {
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
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = @($p.Fields)
                })
                continue
            }
            # repo-wins keeps the Update plan entry. Emit a single warning so
            # the run log calls out every shared policy whose tenant fields
            # this run will overwrite, with the drifted field set, per
            # ADR 0029 section "repo-wins mode".
            $fieldsText = @($p.Fields) -join ','
            Write-Warning ("repo-wins overwriting tenant on label policy '{0}' fields: {1}" -f $displayName, $fieldsText)
            $keptPolicyPlan += $p
        }
        if ($skipDecisions.Count -gt 0) {
            $plan.Clear()
            foreach ($k in $keptPolicyPlan) { $plan.Add($k) }
            # Drop the existing Update report rows for any skipped policy so
            # the plan summary shows the Skip row (and only the Skip row)
            # per skipped policy.
            $skippedDisplayNames = @($skipDecisions | ForEach-Object { $_.DisplayName })
            $kept = @($report | Where-Object {
                -not ($_.Kind -eq 'LabelPolicy' -and $_.Category -eq 'Update' -and ($skippedDisplayNames -contains [string]$_.Name))
            })
            $report.Clear()
            foreach ($r in $kept) { $report.Add($r) }
            foreach ($s in $skipDecisions) {
                $report.Add([pscustomobject]@{
                    Category = 'Skip'
                    Kind     = 'LabelPolicy'
                    Name     = $s.DisplayName
                    Reason   = $s.Reason
                    Field    = (@($s.Fields) -join ',')
                })
                # Machine-readable marker for the workflow's auto-PR step.
                # One line per skipped policy so a simple
                # `grep '\[ADR0029-SKIP\]'` over the run log yields the
                # full skip list.
                Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
            }
        }
    }

    # ---- Plan summary: emit one row per policy BEFORE writes execute ----
    # Mirrors Deploy-Labels.ps1 #137: a write-phase failure must still
    # leave the per-policy diagnostic on stdout. One row per policy;
    # multiple Update field rows collapse into a comma-joined Fields cell.
    $planRows = $report |
        Group-Object Category, Name |
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
        Sort-Object Category, Name

    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $planRows |
        Format-Table Category, Kind, Name, Fields -Wrap |
        Out-String |
        Write-Information -InformationAction Continue

    # Fail-fast on Blocked rows so no write phase is entered.
    if ($blockedRows.Count -gt 0) {
        foreach ($b in $blockedRows) {
            Write-Error ("Label policy '{0}' is Blocked: {1}" -f $b.Name, $b.Reason)
        }
        throw ("Reconciliation aborted: {0} policy/policies blocked. See plan summary above." -f $blockedRows.Count)
    }

    # ---- ADR 0029: audit-mode short-circuit ----
    # `-DirectionPolicy audit` keeps the categorized report intact for
    # the end-of-script emission, but empties the plan and orphan lists
    # so Phase 2 (session refresh) and Phase 3 (write loop) become
    # no-ops without disrupting the script's normal control flow.
    # Use $plan.Clear() + $orphans = @() rather than `return` -- the
    # sibling labels script (PR #458) proved that an early return from
    # within the try block breaks the post-finally output handling.
    # The audit marker line is the operator-visible signal that no
    # writes would have fired under any circumstance.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit — no writes would have fired. Plan above is read-only.' -InformationAction Continue
        $plan.Clear()
        $orphans = @()
    }

    # ---- Phase 2: Refresh session before any writes ----
    $writeCount = $plan.Count
    if ($PruneMissing.IsPresent) { $writeCount += $orphans.Count }

    # Under -WhatIf no New-/Set-/Remove-LabelPolicy call will execute
    # (each is gated by $PSCmdlet.ShouldProcess in Phase 3), so the
    # read/write session refresh is unnecessary work. Skip it under
    # -WhatIf and let Phase 3 walk the plan against the existing
    # read-phase session for the per-policy plan table. Mirrors
    # Deploy-Labels.ps1 #152.
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
        # Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
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

    # ---- Phase 3: Write ----
    foreach ($entry in $plan) {
        $d = $entry.Desired
        switch ($entry.Action) {

            'Create' {
                # New-LabelPolicy minimal call: -Name + at least one
                # *Location parameter. Mode defaults to TestWithoutNotifications;
                # we always pass it explicitly so the YAML is the source
                # of truth on day 1. AdvancedSettings is hashtable-typed
                # per the Learn reference.
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
                $newArgs = @{
                    Name             = $d.name
                    ExchangeLocation = $d.exchangeLocation
                }
                if ($d.exchangeLocationException.Count -gt 0) {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
                    $newArgs['ExchangeLocationException'] = $d.exchangeLocationException
                }
                if ($d.modernGroupLocation.Count -gt 0) {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
                    $newArgs['ModernGroupLocation'] = $d.modernGroupLocation
                }
                if ($d.includedAdministrativeUnits.Count -gt 0) {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
                    $newArgs['IncludedAdministrativeUnits'] = $d.includedAdministrativeUnits
                }
                if ($d.powerBIComplianceInformation -ne '') {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-labelpolicy
                    $newArgs['PowerBIComplianceInformation'] = ($d.powerBIComplianceInformation -eq 'true')
                }
                if ($d.labels.Count -gt 0) { $newArgs['Labels'] = $d.labels }
                if ($d.advancedSettings.Count -gt 0) {
                    $advHash = @{}
                    foreach ($k in $d.advancedSettings.Keys) { $advHash[$k] = $d.advancedSettings[$k] }
                    $newArgs['AdvancedSettings'] = $advHash
                }
                $shouldProcessTarget = "Sensitivity label policy '{0}'" -f $d.name
                $shouldProcessAction = 'New-LabelPolicy'
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    try {
                        $created = New-LabelPolicy @newArgs -Confirm:$false -ErrorAction Stop
                        Write-Information ("Created label policy '{0}'." -f $d.name) -InformationAction Continue
                        # Mode is Set- only on a follow-up call to keep the
                        # Create splat minimal; New-LabelPolicy defaults to
                        # TestWithoutNotifications and the next Set-LabelPolicy
                        # call below converges to the desired Mode.
                        if ($d.mode -and $d.mode -ne 'TestWithoutNotifications') {
                            $modeAction = "Set-LabelPolicy -Mode {0}" -f $d.mode
                            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $modeAction)) {
                                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                                Set-LabelPolicy -Identity $d.name -Mode $d.mode -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-Information ("Set label policy '{0}' Mode={1}." -f $d.name, $d.mode) -InformationAction Continue
                            }
                        }
                        $null = $created
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists') {
                            Write-Information ("Label policy '{0}' already exists server-side; treating as no-op." -f $d.name) -InformationAction Continue
                            continue
                        }
                        Write-Error ("New-LabelPolicy '{0}' failed: {1}" -f $d.name, $_.Exception.Message)
                        return
                    }
                }
            }

            'Update' {
                $changedFields = @($entry.Fields)
                $tenantHash = $entry.TenantHash
                $shouldProcessTarget = "Sensitivity label policy '{0}'" -f $d.name

                # Issue mirror of Deploy-Labels.ps1 #157: only carry the
                # parameters whose tracked field actually changed. The
                # cmdlet rejects empty arrays for *Location and the
                # *AddLabels/RemoveLabels family is keyed off a delta,
                # not a full set.
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                if ($changedFields -contains 'mode') {
                    $action = "Set-LabelPolicy -Mode {0}" -f $d.mode
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            Set-LabelPolicy -Identity $d.name -Mode $d.mode -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated label policy '{0}' Mode={1}." -f $d.name, $d.mode) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (Mode) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'exchangeLocation') {
                    $action = 'Set-LabelPolicy -ExchangeLocation'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            Set-LabelPolicy -Identity $d.name -ExchangeLocation $d.exchangeLocation -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated label policy '{0}' ExchangeLocation." -f $d.name) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (ExchangeLocation) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'exchangeLocationException') {
                    $action = 'Set-LabelPolicy -ExchangeLocationException'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            # Passing the full desired set is idempotent: the cmdlet
                            # replaces the policy's exception list with the new
                            # value. The Add*/Remove* partner parameters are
                            # available but the policy is small (few exceptions)
                            # so the full-set assignment stays readable.
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                            if ($d.exchangeLocationException.Count -gt 0) {
                                Set-LabelPolicy -Identity $d.name -ExchangeLocationException $d.exchangeLocationException -Confirm:$false -ErrorAction Stop | Out-Null
                            }
                            else {
                                # Clearing the exception list. The Remove* partner
                                # parameter is the documented clearing path when
                                # the tenant has values; pass each tenant-side
                                # entry to RemoveExchangeLocationException.
                                if ($tenantHash.exchangeLocationException.Count -gt 0) {
                                    Set-LabelPolicy -Identity $d.name -RemoveExchangeLocationException $tenantHash.exchangeLocationException -Confirm:$false -ErrorAction Stop | Out-Null
                                }
                            }
                            Write-Information ("Updated label policy '{0}' ExchangeLocationException." -f $d.name) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (ExchangeLocationException) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'modernGroupLocation') {
                    $action = 'Set-LabelPolicy -ModernGroupLocation'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            # Passing the full desired set is idempotent: the cmdlet
                            # replaces the policy's modern-group list with the new
                            # value. When the desired list is empty, use the Remove*
                            # partner parameter to clear the tenant-side set.
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                            if ($d.modernGroupLocation.Count -gt 0) {
                                Set-LabelPolicy -Identity $d.name -ModernGroupLocation $d.modernGroupLocation -Confirm:$false -ErrorAction Stop | Out-Null
                            }
                            else {
                                # Clearing the list. Pass each tenant-side entry to
                                # RemoveModernGroupLocation.
                                if ($tenantHash.modernGroupLocation.Count -gt 0) {
                                    Set-LabelPolicy -Identity $d.name -RemoveModernGroupLocation $tenantHash.modernGroupLocation -Confirm:$false -ErrorAction Stop | Out-Null
                                }
                            }
                            Write-Information ("Updated label policy '{0}' ModernGroupLocation." -f $d.name) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (ModernGroupLocation) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'includedAdministrativeUnits') {
                    $action = 'Set-LabelPolicy -IncludedAdministrativeUnits'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            # Passing the full desired set replaces the policy's AU list.
                            # When the desired list is empty use RemoveIncludedAdministrativeUnits
                            # to clear the tenant-side set. #471 row 6; ADR 0042.
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                            if ($d.includedAdministrativeUnits.Count -gt 0) {
                                Set-LabelPolicy -Identity $d.name -IncludedAdministrativeUnits $d.includedAdministrativeUnits -Confirm:$false -ErrorAction Stop | Out-Null
                            }
                            else {
                                if ($tenantHash.includedAdministrativeUnits.Count -gt 0) {
                                    Set-LabelPolicy -Identity $d.name -RemoveIncludedAdministrativeUnits $tenantHash.includedAdministrativeUnits -Confirm:$false -ErrorAction Stop | Out-Null
                                }
                            }
                            Write-Information ("Updated label policy '{0}' IncludedAdministrativeUnits." -f $d.name) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (IncludedAdministrativeUnits) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'powerBIComplianceInformation') {
                    $action = 'Set-LabelPolicy -PowerBIComplianceInformation'
                    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-labelpolicy
                            $pbicValue = ($d.powerBIComplianceInformation -eq 'true')
                            Set-LabelPolicy -Identity $d.name -PowerBIComplianceInformation $pbicValue -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-Information ("Updated label policy '{0}' PowerBIComplianceInformation={1}." -f $d.name, $pbicValue) -InformationAction Continue
                        }
                        catch {
                            Write-Error ("Set-LabelPolicy '{0}' (PowerBIComplianceInformation) failed: {1}" -f $d.name, $_.Exception.Message)
                            return
                        }
                    }
                }
                if ($changedFields -contains 'labels') {
                    $tenantSet = New-Object 'System.Collections.Generic.HashSet[string]'
                    foreach ($g in $tenantHash.labels) { [void]$tenantSet.Add($g) }
                    $desiredSet = New-Object 'System.Collections.Generic.HashSet[string]'
                    foreach ($g in $d.labels) { [void]$desiredSet.Add($g) }
                    $toAdd    = @($d.labels    | Where-Object { -not $tenantSet.Contains($_) })
                    $toRemove = @($tenantHash.labels | Where-Object { -not $desiredSet.Contains($_) })
                    if ($toAdd.Count -gt 0) {
                        $action = "Set-LabelPolicy -AddLabels ({0})" -f $toAdd.Count
                        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                            try {
                                Set-LabelPolicy -Identity $d.name -AddLabels $toAdd -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-Information ("Added {0} label(s) to policy '{1}'." -f $toAdd.Count, $d.name) -InformationAction Continue
                            }
                            catch {
                                Write-Error ("Set-LabelPolicy '{0}' (AddLabels) failed: {1}" -f $d.name, $_.Exception.Message)
                                return
                            }
                        }
                    }
                    if ($toRemove.Count -gt 0) {
                        $action = "Set-LabelPolicy -RemoveLabels ({0})" -f $toRemove.Count
                        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                            try {
                                Set-LabelPolicy -Identity $d.name -RemoveLabels $toRemove -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-Information ("Removed {0} label(s) from policy '{1}'." -f $toRemove.Count, $d.name) -InformationAction Continue
                            }
                            catch {
                                Write-Error ("Set-LabelPolicy '{0}' (RemoveLabels) failed: {1}" -f $d.name, $_.Exception.Message)
                                return
                            }
                        }
                    }
                }
                $advChanges = @($changedFields | Where-Object { $_ -like 'advancedSettings.*' })
                if ($advChanges.Count -gt 0) {
                    # AdvancedSettings is set as a hashtable; passing
                    # the full desired set is idempotent and preserves
                    # the allowlisted shape.
                    # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels-office-apps#configure-advanced-settings
                    $advHash = @{}
                    foreach ($k in $d.advancedSettings.Keys) { $advHash[$k] = $d.advancedSettings[$k] }
                    if ($advHash.Count -gt 0) {
                        $action = "Set-LabelPolicy -AdvancedSettings ({0} key(s))" -f $advHash.Count
                        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $action)) {
                            try {
                                Set-LabelPolicy -Identity $d.name -AdvancedSettings $advHash -Confirm:$false -ErrorAction Stop | Out-Null
                                Write-Information ("Updated label policy '{0}' AdvancedSettings ({1} key(s))." -f $d.name, $advHash.Count) -InformationAction Continue
                            }
                            catch {
                                Write-Error ("Set-LabelPolicy '{0}' (AdvancedSettings) failed: {1}" -f $d.name, $_.Exception.Message)
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    if ($PruneMissing.IsPresent) {
        foreach ($p in $orphans) {
            $shouldProcessTarget = "Sensitivity label policy '{0}'" -f $p.Name
            $shouldProcessAction = 'Remove-LabelPolicy'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-labelpolicy
                    Remove-LabelPolicy -Identity ([string]$p.Name) -Confirm:$false -ErrorAction Stop | Out-Null
                    Write-Information ("Removed orphan label policy '{0}'." -f $p.Name) -InformationAction Continue
                }
                catch {
                    Write-Error ("Remove-LabelPolicy '{0}' failed: {1}" -f $p.Name, $_.Exception.Message)
                    return
                }
            }
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
