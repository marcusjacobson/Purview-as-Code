#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 sensitivity labels against
    `data-plane/information-protection/labels.yaml` (desired state).

.DESCRIPTION
    Wave 1 declarative reconciler for the sensitivity-label taxonomy. The
    YAML is the central source of truth: any add / update of a label flows
    through this script, which converges the live tenant to match. Sibling
    of `scripts/Deploy-PurviewRoleGroups.ps1` (same drift vocabulary, same
    auth path, same single-session two-phase reconciliation pattern).

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET each label visible to the connected app via `Get-Label`.
      2. Match desired vs. tenant by `displayName`. Resolve parent
         labels first, then sublabels (children carry a `parent:` field
         in YAML; the reconciler resolves the parent's GUID and passes
         it to `New-Label -ParentId`).
      3. Diff each desired label's tracked fields (tooltip, comment,
         contentType, contentMarking header / footer / watermark, and
         encryption fields) against the tenant copy.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
            Conflict -- not produced. Sensitivity-label cmdlets do not
                        expose a per-label `lastModifiedBy` we can
                        diff against, so `-Force` is reserved for the
                        export path only.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    Two-phase reconciliation (mirrors Deploy-PurviewRoleGroups.ps1):
      Phase 1 (read)  -- enumerate live labels, build per-label plan.
      Phase 2 (reset) -- Disconnect + reload ExchangeOnlineManagement +
                         Reconnect (only if writes are planned). The
                         S&C REST proxy auto-disconnects long-lived
                         app-only sessions after a high-volume read
                         loop; the EXO module's tmpEXO_* stub cache
                         degrades and rejects subsequent named-
                         parameter calls.
      Phase 3 (write) -- New-Label / Set-Label / Remove-Label calls
                         against the refreshed session.

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md`):

        ./scripts/Deploy-Labels.ps1 -ExportCurrentState

    Hydrates the YAML from the live taxonomy (every visible label).
    Refuses to overwrite a non-empty `labels:` list unless -Force is
    also specified. Existing YAML header comments are preserved by
    line-splicing -- only the `labels:` block is rewritten.

    References (Microsoft Learn):
      Sensitivity labels overview:
        https://learn.microsoft.com/en-us/purview/sensitivity-labels
      Encryption with sensitivity labels:
        https://learn.microsoft.com/en-us/purview/encryption-sensitivity-labels
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Connect-IPPSSession:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Get-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
      New-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
      Set-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
      Remove-Label:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-label
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/information-protection/labels.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant labels that are not declared in the YAML.
    Default $false. `Remove-Label` is destructive — only Disabled
    labels can be removed without a separate disable step; the
    reconciler attempts disable + remove and surfaces the server error
    if the tenant refuses.

.PARAMETER Force
    With -ExportCurrentState: allow overwriting a `labels:` block that
    already contains entries. Without it the script refuses, to avoid
    clobbering hand-curated YAML. Reserved for the export path; on the
    Apply path no `Conflict` category is produced (see .DESCRIPTION).

.PARAMETER ExportCurrentState
    Read every label visible to the connected app, write to the YAML's
    `labels:` block, and exit. Makes no writes to the tenant.

.PARAMETER RedactIdentities
    Only valid with -ExportCurrentState. Replaces every encryption
    `Identity` value emitted to YAML with the synthetic placeholder
    `user@contoso.com`. Use this when bootstrapping `labels.yaml` from
    a live tenant that contains real UPNs or group addresses, so the
    committed YAML satisfies `.github/instructions/sample-data.instructions.md`.
    Default OFF: a raw export is useful for local diff review against
    the live tenant before commit. The redaction happens after the
    rights set is normalized, so the per-label `Rights` string is
    preserved.

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
                         No New-/Set-/Remove-Label call fires under
                         any circumstance. Equivalent to a forced
                         -WhatIf at the script boundary.
      * `portal-wins` -- (default) skip any shared label whose
                         tracked fields differ; emit a Skip plan row
                         per skipped label and a `[ADR0029-SKIP]
                         <displayName>` line per skipped label so an
                         upstream workflow can capture the list for
                         an auto-PR. Create / Update / NoChange and
                         orphan handling are unchanged.
      * `repo-wins`   -- apply the full plan including shared-
                         property drift. Emit one Write-Warning per
                         overwritten shared label naming the
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
    each named label that would otherwise drift is emitted as a Skip
    plan row instead of an Update row (reason: "explicitly skipped by
    caller"). NoChange, Create, and Orphan rows are unaffected. Names
    not present in the YAML or the tenant are silently ignored
    (defends against a stale skip list from the workflow).
    Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.EXAMPLE
    ./scripts/Deploy-Labels.ps1 -WhatIf

    Connect read-only and emit the per-label Create / Update / NoChange
    plan table for what an apply would do; make no remote writes. Pair
    with `-PruneMissing` to additionally surface the orphan rows that a
    destructive apply would remove.

.EXAMPLE
    ./scripts/Deploy-Labels.ps1

    Create or update labels declared in the YAML. Tenant-only labels
    are reported and skipped (no -PruneMissing).

.EXAMPLE
    ./scripts/Deploy-Labels.ps1 -ExportCurrentState

    Hydrate `data-plane/information-protection/labels.yaml` from the
    live tenant.

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
    printed; tenant-real identifiers (label GUIDs, appId, tenantId)
    are not echoed at INFO level.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/information-protection/labels.schema.json`
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
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\information-protection\labels.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [Parameter(ParameterSetName = 'Export')]
    [switch]$RedactIdentities,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

# Tracked field set used for diffing desired YAML vs. tenant Get-Label
# output. Anything outside this set is intentionally ignored on the
# Apply path; #68 (the JSON schema) will gate field additions.
$script:TrackedScalarFields = @('tooltip', 'comment')

# Synthetic-placeholder identity pattern. Identities matching this
# regex are treated as redacted commit-time placeholders (see
# `-RedactIdentities` and `.github/instructions/sample-data.instructions.md`),
# not as real principals. The comparator and the cmdlet-arg builder
# both need to recognize them so a `-RedactIdentities` export round-
# trips clean against the live tenant. Domains: contoso.com,
# fabrikam.com, adatum.com, example.com, example.org (the last three
# include RFC 2606-reserved DNS). See issue #137.
$script:RedactedIdentityPattern = '(?i)@(contoso|fabrikam|adatum)\.com$|@example\.(com|org)$'

function ConvertTo-LabelHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # Drops nulls, lowercases enum-like content types into a sorted
    # joined string for stable equality comparisons.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $h = @{
        displayName = [string]$Entry.displayName
        parent      = if ($Entry.ContainsKey('parent') -and $Entry.parent) { [string]$Entry.parent } else { $null }
        tooltip     = if ($Entry.ContainsKey('tooltip')) { [string]$Entry.tooltip } else { '' }
        # Issue #157: distinguish "YAML omits this field" from
        # "YAML sets this field to empty". Absent => $null sentinel
        # (preserve tenant value); explicit empty string => ''
        # (clear tenant value). The comparator and the cmdlet-arg
        # builder both honor this so Set-Label is not asked to clear
        # text fields the operator never declared.
        comment     = if ($Entry.ContainsKey('comment')) { [string]$Entry.comment } else { $null }
        contentType = $null
    }
    if ($Entry.ContainsKey('contentType')) {
        # Filter the 'None' sentinel: Get-Label returns 'None' to indicate
        # "no content types set", but New-Label/Set-Label reject 'None'
        # as input. Treat it the same as an absent / empty list so the
        # exporter's output is round-trip idempotent. See issue #129.
        $h.contentType = @($Entry.contentType |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -and $_ -ne 'None' } |
            Sort-Object -Unique)
    }
    foreach ($section in @('header', 'footer', 'watermark')) {
        $key = "marking_$section"
        $h[$key] = $null
        if ($Entry.ContainsKey('contentMarking') -and $Entry.contentMarking -and $Entry.contentMarking.ContainsKey($section)) {
            $sub = $Entry.contentMarking[$section]
            if ($sub) {
                $h[$key] = @{
                    enabled   = [bool]$sub.enabled
                    text      = if ($sub.ContainsKey('text')) { [string]$sub.text } else { '' }
                    fontSize  = if ($sub.ContainsKey('fontSize')) { [int]$sub.fontSize } else { 0 }
                    fontColor = if ($sub.ContainsKey('fontColor')) { [string]$sub.fontColor } else { '' }
                    alignment = if ($sub.ContainsKey('alignment')) { [string]$sub.alignment } else { '' }
                    layout    = if ($sub.ContainsKey('layout')) { [string]$sub.layout } else { '' }
                }
            }
        }
    }
    $h['encryption'] = $null
    if ($Entry.ContainsKey('encryption') -and $Entry.encryption) {
        $enc = $Entry.encryption
        $rights = @()
        if ($enc.ContainsKey('rightsDefinitions') -and $enc.rightsDefinitions) {
            $rights = @($enc.rightsDefinitions | ForEach-Object {
                [pscustomobject]@{
                    Identity = [string]$_.identity
                    Rights   = (([string]$_.rights) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join ','
                }
            } | Sort-Object Identity)
        }
        $h['encryption'] = @{
            enabled                            = [bool]$enc.enabled
            protectionType                     = if ($enc.ContainsKey('protectionType')) { [string]$enc.protectionType } else { 'UserDefined' }
            contentExpiredOnDateInDaysOrNever  = if ($enc.ContainsKey('contentExpiredOnDateInDaysOrNever')) { [string]$enc.contentExpiredOnDateInDaysOrNever } else { 'Never' }
            offlineAccessDays                  = if ($enc.ContainsKey('offlineAccessDays')) { [int]$enc.offlineAccessDays } else { 0 }
            doNotForward                       = [bool]$enc.doNotForward
            encryptOnly                        = [bool]$enc.encryptOnly
            # Derived from protectionType (not a YAML field, per #420 scope).
            # Set-Label requires EncryptionPromptUser=$true when protectionType=UserDefined
            # and ContentType covers File+Email; we always emit so drift compares cleanly.
            promptUser                         = ([string]$enc.protectionType -eq 'UserDefined')
            rightsDefinitions                  = $rights
        }
    }
    # Issue #212: client-side auto-apply block. Normalize the SIT list with
    # a stable sort by sitId (ascending, lowercased) so hash-equality is
    # round-trip stable. minCount defaults to 1, minConfidence defaults to
    # 75, matching the schema defaults. `mode` and `policyTip` are retained
    # for forward-compat but are excluded from the Apply-time write splat
    # (see ConvertTo-LabelCmdletArgument) and the drift comparator pending
    # the schema-amendment follow-up (#215). Reference:
    # https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically
    $h['autoApplicationOf'] = $null
    if ($Entry.ContainsKey('autoApplicationOf') -and $Entry.autoApplicationOf) {
        $aa = $Entry.autoApplicationOf
        $sits = @()
        if ($aa.ContainsKey('sensitiveInformationTypes') -and $aa.sensitiveInformationTypes) {
            $sits = @($aa.sensitiveInformationTypes | ForEach-Object {
                # The YAML parser returns each SIT entry as a hashtable;
                # use ContainsKey to detect missing fields (PSObject.Properties
                # does not enumerate hashtable keys).
                $sit = $_
                [pscustomobject]@{
                    sitId         = ([string]$sit.sitId).ToLowerInvariant()
                    minCount      = if ($sit.ContainsKey('minCount')      -and $null -ne $sit.minCount)      { [int]$sit.minCount }      else { 1 }
                    minConfidence = if ($sit.ContainsKey('minConfidence') -and $null -ne $sit.minConfidence) { [int]$sit.minConfidence } else { 75 }
                }
            } | Sort-Object sitId)
        }
        $h['autoApplicationOf'] = @{
            mode                      = if ($aa.ContainsKey('mode') -and $aa.mode) { [string]$aa.mode } else { $null }
            policyTip                 = if ($aa.ContainsKey('policyTip') -and $aa.policyTip) { [string]$aa.policyTip } else { $null }
            sensitiveInformationTypes = $sits
        }
    }
    return $h
}

function ConvertTo-TenantLabelHash {
    # Normalize a tenant Get-Label result into the same shape as
    # ConvertTo-LabelHash so the comparator can be field-by-field.
    # Get-Label exposes content marking and encryption as flat scalar
    # properties; we re-shape into the desired YAML's nested form.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
    param([Parameter(Mandatory = $true)]$Label)

    $h = @{
        displayName = [string]$Label.DisplayName
        guid        = [string]$Label.Guid
        parentGuid  = if ($Label.ParentId) { [string]$Label.ParentId } else { $null }
        tooltip     = if ($Label.Tooltip) { [string]$Label.Tooltip } else { '' }
        comment     = if ($Label.Comment) { [string]$Label.Comment } else { '' }
        contentType = @()
    }
    if ($Label.ContentType) {
        # Get-Label returns ContentType as a comma-joined string. The
        # literal value 'None' is a tenant-side sentinel meaning "no
        # content types set", but Set-Label rejects 'None' as input,
        # so filter it here to keep the exporter round-trip idempotent.
        # See issue #129.
        $h.contentType = @(([string]$Label.ContentType) -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -ne 'None' } |
            Sort-Object -Unique)
    }
    foreach ($section in @('Header', 'Footer')) {
        $sectionLower = $section.ToLowerInvariant()
        $enabledProp  = "ApplyContentMarking${section}Enabled"
        $textProp     = "ApplyContentMarking${section}Text"
        $sizeProp     = "ApplyContentMarking${section}FontSize"
        $colorProp    = "ApplyContentMarking${section}FontColor"
        $alignProp    = "ApplyContentMarking${section}Alignment"
        $key = "marking_$sectionLower"
        if ([bool]$Label.$enabledProp) {
            $h[$key] = @{
                enabled   = $true
                text      = if ($Label.$textProp) { [string]$Label.$textProp } else { '' }
                fontSize  = if ($Label.$sizeProp) { [int]$Label.$sizeProp } else { 0 }
                fontColor = if ($Label.$colorProp) { [string]$Label.$colorProp } else { '' }
                alignment = if ($Label.$alignProp) { [string]$Label.$alignProp } else { '' }
                layout    = ''
            }
        }
        else {
            $h[$key] = $null
        }
    }
    if ([bool]$Label.ApplyWaterMarkingEnabled) {
        $h['marking_watermark'] = @{
            enabled   = $true
            text      = if ($Label.ApplyWaterMarkingText) { [string]$Label.ApplyWaterMarkingText } else { '' }
            fontSize  = if ($Label.ApplyWaterMarkingFontSize) { [int]$Label.ApplyWaterMarkingFontSize } else { 0 }
            fontColor = if ($Label.ApplyWaterMarkingFontColor) { [string]$Label.ApplyWaterMarkingFontColor } else { '' }
            alignment = ''
            layout    = if ($Label.ApplyWaterMarkingLayout) { [string]$Label.ApplyWaterMarkingLayout } else { '' }
        }
    }
    else {
        $h['marking_watermark'] = $null
    }

    if ([bool]$Label.EncryptionEnabled) {
        $rights = @()
        if ($Label.EncryptionRightsDefinitions) {
            # Normalize the source into a flat list of entries to iterate. Get-Label
            # returns EncryptionRightsDefinitions in three observed shapes depending on
            # protectionType and the version of the S&C cmdlet binding:
            #   1. JSON-encoded string of an array (Template, RemoveProtection in modern
            #      tenants): '[{"Identity":"foo@bar","Rights":"VIEW,..."}]'.
            #   2. Strongly-typed object collection with Identity/Rights members.
            #   3. Legacy colon-separated string per entry: 'foo@bar:VIEW,EDIT,...'.
            # Splitting case-1 on the first ':' slices the JSON literal in half, which
            # is what blocked #118; treat strings JSON-first and only fall back to the
            # colon split when ConvertFrom-Json fails. Reference:
            # https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
            $rdSource = $Label.EncryptionRightsDefinitions
            $entries = @()
            if ($rdSource -is [string]) {
                $rdTrim = $rdSource.Trim()
                if ($rdTrim.StartsWith('[') -or $rdTrim.StartsWith('{')) {
                    try {
                        $parsed = $rdTrim | ConvertFrom-Json -ErrorAction Stop
                        $entries = @($parsed)
                    }
                    catch {
                        # Fall through to per-entry handling below.
                        $entries = @($rdSource)
                    }
                }
                else {
                    $entries = @($rdSource)
                }
            }
            else {
                $entries = @($rdSource)
            }

            foreach ($rd in $entries) {
                $identity = ''
                $rightsStr = ''
                if ($rd -is [string]) {
                    $rdTrim = $rd.Trim()
                    # Per-entry JSON object (rare, but handle defensively).
                    if ($rdTrim.StartsWith('{')) {
                        try {
                            $obj = $rdTrim | ConvertFrom-Json -ErrorAction Stop
                            $identity = if ($obj.Identity) { [string]$obj.Identity } else { '' }
                            $rightsStr = if ($obj.Rights) { [string]$obj.Rights } else { '' }
                        }
                        catch {
                            $identity = $rdTrim
                        }
                    }
                    else {
                        # Legacy 'identity:rights' colon-split form.
                        $parts = $rd -split ':', 2
                        if ($parts.Count -eq 2) {
                            $identity = $parts[0].Trim()
                            $rightsStr = $parts[1].Trim()
                        }
                    }
                }
                elseif ($rd.Identity) {
                    $identity = [string]$rd.Identity
                    $rightsStr = if ($rd.Rights) { [string]$rd.Rights } else { '' }
                }
                $rightsNorm = ($rightsStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join ','
                $rights += [pscustomobject]@{ Identity = $identity; Rights = $rightsNorm }
            }
            $rights = @($rights | Sort-Object Identity)
        }
        $h['encryption'] = @{
            enabled                            = $true
            protectionType                     = if ($Label.EncryptionProtectionType) { [string]$Label.EncryptionProtectionType } else { 'UserDefined' }
            contentExpiredOnDateInDaysOrNever  = if ($Label.EncryptionContentExpiredOnDateInDaysOrNever) { [string]$Label.EncryptionContentExpiredOnDateInDaysOrNever } else { 'Never' }
            offlineAccessDays                  = if ($Label.EncryptionOfflineAccessDays) { [int]$Label.EncryptionOfflineAccessDays } else { 0 }
            doNotForward                       = [bool]$Label.EncryptionDoNotForward
            encryptOnly                        = [bool]$Label.EncryptionEncryptOnly
            promptUser                         = [bool]$Label.EncryptionPromptUser
            rightsDefinitions                  = $rights
        }
    }
    else {
        $h['encryption'] = $null
    }
    # Issue #215: client-side auto-apply block. The verified Set-Label sink
    # is the `-Conditions` parameter carrying a nested And/Or/Settings JSON
    # structure. `autoapplytype` (Recommend|Automatic) maps to YAML
    # `mode`; the `policytip` Settings key maps to YAML `policyTip`; each
    # `Or` clause carries one SIT (Key='CCSI', Value=<sitId GUID>) with
    # Settings.{mincount, minconfidence}. Verified end-to-end against the
    # live contoso-lab tenant on 2026-05-16 (see issue #215 probe captures
    # under verify-set-label-output/215b-*).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    # Reference: https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically
    $h['autoApplicationOf'] = $null
    $conditionsRaw = [string]$Label.Conditions
    if (-not [string]::IsNullOrWhiteSpace($conditionsRaw)) {
        try {
            $parsed = $conditionsRaw | ConvertFrom-Json -ErrorAction Stop
            $orClauses = @()
            if ($parsed.PSObject.Properties['And'] -and $parsed.And -and @($parsed.And).Count -ge 1) {
                $firstAnd = @($parsed.And)[0]
                if ($firstAnd.PSObject.Properties['Or'] -and $firstAnd.Or) {
                    $orClauses = @($firstAnd.Or)
                }
            }
            $sits = @()
            $mode = $null
            $policyTip = $null
            foreach ($clause in $orClauses) {
                if (-not $clause.PSObject.Properties['Value'] -or -not $clause.Value) { continue }
                $sitId = ([string]$clause.Value).ToLowerInvariant()
                $minCount = 1
                $minConfidence = 75
                if ($clause.PSObject.Properties['Settings'] -and $clause.Settings) {
                    foreach ($kv in @($clause.Settings)) {
                        $key = [string]$kv.Key
                        $val = [string]$kv.Value
                        switch -Exact ($key.ToLowerInvariant()) {
                            'mincount'      { if ($val -match '^\d+$') { $minCount = [int]$val } }
                            'minconfidence' { if ($val -match '^\d+$') { $minConfidence = [int]$val } }
                            'autoapplytype' { if ($val) { $mode = $val } }
                            'policytip'     { if ($val) { $policyTip = $val } }
                        }
                    }
                }
                $sits += [pscustomobject]@{
                    sitId         = $sitId
                    minCount      = $minCount
                    minConfidence = $minConfidence
                }
            }
            $sits = @($sits | Where-Object { $_.sitId } | Sort-Object sitId)
            if ($sits.Count -gt 0) {
                $h['autoApplicationOf'] = @{
                    mode                      = $mode
                    policyTip                 = $policyTip
                    sensitiveInformationTypes = $sits
                }
            }
        }
        catch {
            Write-Verbose ("Failed to parse Conditions JSON on label '{0}': {1}" -f $Label.DisplayName, $_.Exception.Message)
        }
    }
    return $h
}

function Compare-LabelHash {
    # Returns a list of differing field names (strings). Empty list
    # means equal across the tracked surface.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = @()
    foreach ($f in $script:TrackedScalarFields) {
        # Issue #157: $null on the desired side means "YAML omits this
        # field; preserve whatever the tenant has". Skip the comparison
        # so an omitted field never produces drift, and the writer never
        # passes an empty-string parameter to Set-Label.
        if ($null -eq $Desired[$f]) { continue }
        if (([string]$Desired[$f]) -ne ([string]$Tenant[$f])) { $diffs += $f }
    }
    if ($null -ne $Desired.contentType) {
        $a = ($Desired.contentType -join ',')
        $b = ($Tenant.contentType  -join ',')
        if ($a -ne $b) { $diffs += 'contentType' }
    }

    foreach ($section in @('marking_header', 'marking_footer', 'marking_watermark')) {
        $d = $Desired[$section]; $t = $Tenant[$section]
        if (($null -eq $d) -and ($null -eq $t)) { continue }
        if (($null -eq $d) -xor ($null -eq $t)) { $diffs += $section; continue }
        foreach ($k in @('enabled','text','fontSize','fontColor','alignment','layout')) {
            if (([string]$d[$k]) -ne ([string]$t[$k])) { $diffs += "$section.$k" }
        }
    }

    # Issue #215: client-side auto-apply drift. Tracked-field surface
    # exposed strictly (presence-asymmetry produces an Update row, not
    # silent NoChange — per the AC). Diff mode + policyTip + SIT list
    # because all three are now round-trip stable via the verified
    # Set-Label -Conditions sink (Phase 1B probe 2026-05-16). Placed
    # BEFORE the encryption block because the encryption block early-
    # returns when both desired and tenant encryption are $null.
    # Reference: https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically
    $da = $Desired.autoApplicationOf
    $ta = $Tenant.autoApplicationOf
    if (($null -eq $da) -and ($null -eq $ta)) {
        # No-op.
    }
    elseif (($null -eq $da) -xor ($null -eq $ta)) {
        $diffs += 'autoApplicationOf'
    }
    else {
        if (([string]$da.mode) -ne ([string]$ta.mode)) { $diffs += 'autoApplicationOf.mode' }
        # Only diff policyTip when the YAML declares one. Schema-side
        # the field is optional; an omitted policyTip on the desired
        # side means "preserve whatever the tenant has", matching the
        # #157 convention for other optional scalars.
        if ($null -ne $da.policyTip) {
            if (([string]$da.policyTip) -ne ([string]$ta.policyTip)) { $diffs += 'autoApplicationOf.policyTip' }
        }
        $dSits = @($da.sensitiveInformationTypes)
        $tSits = @($ta.sensitiveInformationTypes)
        $dKey = ($dSits | ForEach-Object { "$($_.sitId)|$($_.minCount)|$($_.minConfidence)" }) -join ';'
        $tKey = ($tSits | ForEach-Object { "$($_.sitId)|$($_.minCount)|$($_.minConfidence)" }) -join ';'
        if ($dKey -ne $tKey) { $diffs += 'autoApplicationOf.sensitiveInformationTypes' }
    }

    $de = $Desired.encryption; $te = $Tenant.encryption
    if (($null -eq $de) -and ($null -eq $te)) {
        return $diffs
    }
    if (($null -eq $de) -xor ($null -eq $te)) {
        $diffs += 'encryption'
        return $diffs
    }
    foreach ($k in @('enabled','protectionType','contentExpiredOnDateInDaysOrNever','offlineAccessDays','doNotForward','encryptOnly','promptUser')) {
        if (([string]$de[$k]) -ne ([string]$te[$k])) { $diffs += "encryption.$k" }
    }
    # Issue #137: a `-RedactIdentities` export rewrites every Identity to
    # a synthetic placeholder (e.g., user@contoso.com). The committed YAML
    # then can never compare equal to the live tenant's real UPNs, which
    # both spuriously categorizes every encrypted label as 'Update' and,
    # if the writer runs, pushes the placeholder back into the tenant
    # (Set-Label rejects with TextEmptyException because the placeholder
    # cannot be resolved as a real principal). Treat the placeholder set
    # as opaque: when every desired identity matches the redaction
    # pattern AND the desired and tenant rights collections agree on
    # count and on the sorted set of Rights strings, declare no drift.
    # If any desired identity is real, fall back to strict identity-aware
    # comparison so contributors authoring real principals still get a
    # truthful diff.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
    $dRights = @($de.rightsDefinitions)
    $tRights = @($te.rightsDefinitions)
    $allDesiredRedacted = ($dRights.Count -gt 0) -and (-not ($dRights |
        Where-Object { $_.Identity -notmatch $script:RedactedIdentityPattern }))
    if ($allDesiredRedacted) {
        if ($dRights.Count -ne $tRights.Count) {
            $diffs += 'encryption.rightsDefinitions'
        }
        else {
            $dRightsSorted = @($dRights | ForEach-Object { $_.Rights } | Sort-Object)
            $tRightsSorted = @($tRights | ForEach-Object { $_.Rights } | Sort-Object)
            if (($dRightsSorted -join ';') -ne ($tRightsSorted -join ';')) {
                $diffs += 'encryption.rightsDefinitions'
            }
        }
    }
    else {
        $drd = ($dRights | ForEach-Object { "$($_.Identity)=$($_.Rights)" }) -join ';'
        $trd = ($tRights | ForEach-Object { "$($_.Identity)=$($_.Rights)" }) -join ';'
        if ($drd -ne $trd) { $diffs += 'encryption.rightsDefinitions' }
    }

    return $diffs
}

function ConvertTo-LabelCmdletArgument {
    # Build the splat hashtable for New-Label / Set-Label from a
    # normalized desired-state hashtable. ParentId is supplied
    # separately because it depends on live GUIDs resolved at apply
    # time. Returns a hashtable suitable for splatting.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [switch]$IncludeName
    )
    $cmdletArgs = @{
        DisplayName = $Desired.displayName
    }
    # Set-Label rejects an empty Tooltip with TextEmptyException, so
    # only include the parameter when the desired value is non-empty.
    # See issue #129.
    if ($Desired.tooltip) { $cmdletArgs['Tooltip'] = $Desired.tooltip }
    if ($Desired.comment) { $cmdletArgs['Comment'] = $Desired.comment }
    if ($null -ne $Desired.contentType -and $Desired.contentType.Count -gt 0) {
        $cmdletArgs['ContentType'] = ($Desired.contentType -join ',')
    }
    # Marking flags ($false) are emitted only on the Set-Label (Update) path.
    # New-Label (Create) rejects ApplyContentMarking{Header,Footer}Enabled=$false
    # and ApplyWaterMarkingEnabled=$false with TextEmptyException when no
    # companion text is supplied; new labels are default-disabled, so
    # omitting these flags from the Create splat is equivalent to $false.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
    foreach ($section in @('header','footer')) {
        $key = "marking_$section"
        $cap = (Get-Culture).TextInfo.ToTitleCase($section)
        if ($null -eq $Desired[$key]) {
            if (-not $IncludeName.IsPresent) {
                $cmdletArgs["ApplyContentMarking${cap}Enabled"] = $false
            }
            continue
        }
        $m = $Desired[$key]
        $cmdletArgs["ApplyContentMarking${cap}Enabled"]  = [bool]$m.enabled
        if ($m.text)      { $cmdletArgs["ApplyContentMarking${cap}Text"]      = $m.text }
        if ($m.fontSize)  { $cmdletArgs["ApplyContentMarking${cap}FontSize"]  = [int]$m.fontSize }
        if ($m.fontColor) { $cmdletArgs["ApplyContentMarking${cap}FontColor"] = $m.fontColor }
        if ($m.alignment) { $cmdletArgs["ApplyContentMarking${cap}Alignment"] = $m.alignment }
    }
    $w = $Desired['marking_watermark']
    if ($null -eq $w) {
        if (-not $IncludeName.IsPresent) {
            $cmdletArgs['ApplyWaterMarkingEnabled'] = $false
        }
    }
    else {
        $cmdletArgs['ApplyWaterMarkingEnabled'] = [bool]$w.enabled
        if ($w.text)      { $cmdletArgs['ApplyWaterMarkingText']      = $w.text }
        if ($w.fontSize)  { $cmdletArgs['ApplyWaterMarkingFontSize']  = [int]$w.fontSize }
        if ($w.fontColor) { $cmdletArgs['ApplyWaterMarkingFontColor'] = $w.fontColor }
        if ($w.layout)    { $cmdletArgs['ApplyWaterMarkingLayout']    = $w.layout }
    }
    $enc = $Desired['encryption']
    if ($null -eq $enc) {
        $cmdletArgs['EncryptionEnabled'] = $false
    }
    else {
        $cmdletArgs['EncryptionEnabled']                           = [bool]$enc.enabled
        $cmdletArgs['EncryptionProtectionType']                    = $enc.protectionType
        $cmdletArgs['EncryptionContentExpiredOnDateInDaysOrNever'] = $enc.contentExpiredOnDateInDaysOrNever
        if ($null -ne $enc.offlineAccessDays) { $cmdletArgs['EncryptionOfflineAccessDays'] = [int]$enc.offlineAccessDays }
        $cmdletArgs['EncryptionDoNotForward']                      = [bool]$enc.doNotForward
        $cmdletArgs['EncryptionEncryptOnly']                       = [bool]$enc.encryptOnly
        # Issue #420: Set-Label rejects UserDefined when ContentType covers
        # both File and Email unless EncryptionPromptUser=$true and one of
        # EncryptionEncryptOnly / EncryptionDoNotForward=$true. The hash
        # builders derive promptUser from protectionType, so propagate it
        # here unconditionally; Template / RemoveProtection emit $false,
        # matching the cmdlet default.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
        $cmdletArgs['EncryptionPromptUser']                        = [bool]$enc.promptUser
        if ($enc.rightsDefinitions -and $enc.rightsDefinitions.Count -gt 0) {
            # Issue #137: a Set-Label call carrying a redacted identity
            # (e.g., user@contoso.com) fails server-side with
            # TextEmptyException because the placeholder cannot be
            # resolved as a real principal. If every desired identity
            # is a synthetic placeholder, omit EncryptionRightsDefinitions
            # from the splat entirely and preserve whatever the tenant
            # already has. New-Label of a brand-new encrypted label from
            # a fully-redacted YAML is unsupported by design (the operator
            # must supply a real identity); call sites can detect this by
            # the absent splat key.
            $allRedacted = -not ($enc.rightsDefinitions |
                Where-Object { $_.Identity -notmatch $script:RedactedIdentityPattern })
            if (-not $allRedacted) {
                $cmdletArgs['EncryptionRightsDefinitions'] = ($enc.rightsDefinitions | ForEach-Object { "$($_.Identity):$($_.Rights)" }) -join ';'
            }
        }
    }
    # Issue #215: client-side auto-apply translation is handled at the
    # Set-Label call site, not in this pure desired-only transform.
    # The verified sink is `Set-Label -Conditions <json>` (Phase 1B
    # probe 2026-05-16), and building the final JSON requires reading
    # the tenant's existing Conditions to preserve server-managed keys
    # (name, rulepackage, groupname, confidencelevel, maxcount,
    # maxconfidence) via merge-update. See Merge-LabelConditionsJson.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    if ($IncludeName.IsPresent) {
        # New-Label requires -Name as the system identifier (immutable).
        # We derive it deterministically from displayName so it survives
        # rename of the display name.
        $cmdletArgs['Name'] = ($Desired.displayName -replace '[^A-Za-z0-9]', '-')
    }
    return $cmdletArgs
}

function Merge-LabelConditionsJson {
    # Issue #215: build a Set-Label -Conditions JSON by merge-update.
    # The tenant's existing Conditions JSON carries keys we do not own
    # (name, rulepackage, groupname, confidencelevel, maxcount,
    # maxconfidence) plus keys we do own (mincount, minconfidence,
    # policytip, autoapplytype). We replace only the schema-owned keys
    # inside each Or-clause whose SIT (Value=<sitId>) appears in the
    # desired list; clauses for SITs no longer in desired are dropped.
    # SITs new to the label (not already in tenant Conditions) cannot
    # be added here because we lack the SIT friendly-name and full
    # rulepackage metadata required by the Conditions schema; the
    # caller receives a $null result and must either skip or fall back.
    # Verified shape: Phase 1B probe 2026-05-16 (see
    # verify-set-label-output/215b-04-after.txt).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$CurrentConditions,
        [Parameter(Mandatory = $true)][hashtable]$DesiredAutoApply,
        [Parameter(Mandatory = $true)][string]$LabelDisplayName
    )
    if ([string]::IsNullOrWhiteSpace($CurrentConditions)) {
        Write-Warning ("Label '{0}': cannot apply autoApplicationOf because the tenant has no existing Conditions JSON to merge into. Author the initial Conditions block via the Purview portal, then re-run reconciliation. (Issue #215 follow-up: name-lookup-driven Create path.)" -f $LabelDisplayName)
        return $null
    }
    $current = $null
    try {
        $current = $CurrentConditions | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning ("Label '{0}': existing Conditions JSON did not parse: {1}. Skipping autoApplicationOf write." -f $LabelDisplayName, $_.Exception.Message)
        return $null
    }
    $existingOrClauses = @()
    if ($current.PSObject.Properties['And'] -and $current.And -and @($current.And).Count -ge 1) {
        $firstAnd = @($current.And)[0]
        if ($firstAnd.PSObject.Properties['Or'] -and $firstAnd.Or) {
            $existingOrClauses = @($firstAnd.Or)
        }
    }
    # Build sitId -> clause lookup (lowercase keys).
    $clauseBySitId = @{}
    foreach ($clause in $existingOrClauses) {
        if ($clause.PSObject.Properties['Value'] -and $clause.Value) {
            $clauseBySitId[([string]$clause.Value).ToLowerInvariant()] = $clause
        }
    }
    $newOrClauses = @()
    foreach ($desiredSit in @($DesiredAutoApply.sensitiveInformationTypes)) {
        $sitId = ([string]$desiredSit.sitId).ToLowerInvariant()
        $existing = $clauseBySitId[$sitId]
        if (-not $existing) {
            Write-Warning ("Label '{0}': SIT '{1}' is in YAML autoApplicationOf but absent from the tenant Conditions. Adding new SITs requires a SIT-name lookup not yet implemented; skipping this SIT in this run. (Issue #215 follow-up.)" -f $LabelDisplayName, $sitId)
            continue
        }
        $existingSettings = @()
        if ($existing.PSObject.Properties['Settings'] -and $existing.Settings) {
            $existingSettings = @($existing.Settings)
        }
        $newSettings = New-Object 'System.Collections.Generic.List[object]'
        $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($kv in $existingSettings) {
            $k = [string]$kv.Key
            $kl = $k.ToLowerInvariant()
            [void]$seenKeys.Add($kl)
            switch -Exact ($kl) {
                'mincount' {
                    [void]$newSettings.Add([ordered]@{ Key = $k; Value = ([string][int]$desiredSit.minCount) })
                }
                'minconfidence' {
                    [void]$newSettings.Add([ordered]@{ Key = $k; Value = ([string][int]$desiredSit.minConfidence) })
                }
                'autoapplytype' {
                    [void]$newSettings.Add([ordered]@{ Key = $k; Value = [string]$DesiredAutoApply.mode })
                }
                'policytip' {
                    if ($DesiredAutoApply.policyTip) {
                        [void]$newSettings.Add([ordered]@{ Key = $k; Value = [string]$DesiredAutoApply.policyTip })
                    }
                    # If desired omits policyTip, drop the existing key entirely.
                }
                default {
                    # Preserve every server-managed key verbatim.
                    [void]$newSettings.Add([ordered]@{ Key = $k; Value = [string]$kv.Value })
                }
            }
        }
        # Insert any owned key the tenant did not previously have.
        if (-not $seenKeys.Contains('mincount')) {
            [void]$newSettings.Add([ordered]@{ Key = 'mincount'; Value = ([string][int]$desiredSit.minCount) })
        }
        if (-not $seenKeys.Contains('minconfidence')) {
            [void]$newSettings.Add([ordered]@{ Key = 'minconfidence'; Value = ([string][int]$desiredSit.minConfidence) })
        }
        if (-not $seenKeys.Contains('autoapplytype') -and $DesiredAutoApply.mode) {
            [void]$newSettings.Add([ordered]@{ Key = 'autoapplytype'; Value = [string]$DesiredAutoApply.mode })
        }
        if (-not $seenKeys.Contains('policytip') -and $DesiredAutoApply.policyTip) {
            [void]$newSettings.Add([ordered]@{ Key = 'policytip'; Value = [string]$DesiredAutoApply.policyTip })
        }
        $newClause = [ordered]@{
            Key        = [string]$existing.Key
            Value      = [string]$existing.Value
            Properties = $existing.Properties
            Settings   = $newSettings.ToArray()
        }
        $newOrClauses += $newClause
    }
    if ($newOrClauses.Count -eq 0) {
        Write-Warning ("Label '{0}': no overlapping SITs between desired YAML and tenant Conditions; skipping autoApplicationOf write." -f $LabelDisplayName)
        return $null
    }
    $result = [ordered]@{
        And = @(
            [ordered]@{
                Or = $newOrClauses
            }
        )
    }
    return (ConvertTo-Json -InputObject $result -Depth 20 -Compress)
}

function Resolve-AutoApplyRemovalPlan {
    # Issue #429: when Compare-LabelHash emits the bare 'autoApplicationOf'
    # field on the diff list, the direction matters. The presence asymmetry
    # has two shapes:
    #   - desired SET, tenant null   -- the #215 add path, handled by
    #     Merge-LabelConditionsJson at apply time; stays inside the Update
    #     branch.
    #   - desired null, tenant SET   -- the removal path. Microsoft Learn
    #     documents no Set-Label -Conditions sentinel that clears the rule
    #     in-band (verified 2026-05-29; the spike candidates -- $null, '',
    #     '{}', '{"And":[]}' -- could not be probed against the live tenant
    #     because no sublabel carried a Conditions block at the time). See
    #     ADR 0027 for the deferral and the watch-list re-open triggers.
    # When the removal direction is detected, strip the bare field from the
    # diff list so the apply-time Update branch never receives it, and let
    # the caller emit a NeedsPortalAction report row instead of a
    # misleading Update row.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Diffs,
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffArray = @($Diffs)
    $needs = $false
    if ($diffArray -contains 'autoApplicationOf' -and
        -not $Desired.autoApplicationOf -and
        $Tenant.autoApplicationOf) {
        $needs = $true
        $diffArray = @($diffArray | Where-Object { $_ -ne 'autoApplicationOf' })
    }
    return @{
        NeedsPortalRemoval = $needs
        ApplyableDiffs     = $diffArray
    }
}

function Get-NeedsPortalActionSummary {
    # Issue #512 (replaces closed #429): when the reconciler emits one or
    # more NeedsPortalAction rows, surface them in a dedicated operator-
    # readable summary block at the end of the run. Two output shapes:
    #   - plain text  : for the console / -InformationAction Continue stream
    #   - markdown    : for GitHub Actions $GITHUB_STEP_SUMMARY (rendered
    #                   inline on the workflow run page)
    # Returns $null when no NeedsPortalAction rows exist, so callers can
    # `if ($block = Get-NeedsPortalActionSummary -Report $report) { ... }`
    # without an extra count check.
    # Reference: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#adding-a-job-summary
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Report,
        [Parameter(Mandatory = $false)][switch]$Markdown
    )
    $rows = @($Report | Where-Object { $_.Category -eq 'NeedsPortalAction' })
    if ($rows.Count -eq 0) { return $null }
    $names = @($rows | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    if ($Markdown.IsPresent) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('## :warning: Manual portal actions required')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine("The sensitivity-label reconciler cannot clear an ``autoApplicationOf`` (``Conditions``) block via PowerShell. Microsoft Learn documents no ``Set-Label`` clearing sentinel; this gap is tracked by [#512](../../issues/512) (watch-list per [ADR 0027](../../blob/main/docs/adr/0027-autoapplication-removal-watch-list.md)).")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### For each label below')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Microsoft Purview portal -> **Information Protection** -> **Sensitivity labels** -> _<label>_ -> **Auto-labeling for files and emails** tab -> **Remove** the rule.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(("### Affected labels ({0})" -f $names.Count))
        [void]$sb.AppendLine('')
        foreach ($n in $names) { [void]$sb.AppendLine(("- ``{0}``" -f $n)) }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### See')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('- Full operator walkthrough: [`docs/runbooks/labels-manual-portal-actions.md`](../../blob/main/docs/runbooks/labels-manual-portal-actions.md)')
        [void]$sb.AppendLine('- Tracking issue: [#512](../../issues/512)')
        [void]$sb.AppendLine('- Architecture decision: [`docs/adr/0027-autoapplication-removal-watch-list.md`](../../blob/main/docs/adr/0027-autoapplication-removal-watch-list.md)')
        return $sb.ToString()
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('================================================================')
    [void]$sb.AppendLine(("[!] MANUAL PORTAL ACTIONS REQUIRED -- {0} label(s)" -f $names.Count))
    [void]$sb.AppendLine('================================================================')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('The reconciler cannot clear an autoApplicationOf (Conditions) block')
    [void]$sb.AppendLine('via PowerShell. Microsoft Learn documents no Set-Label clearing')
    [void]$sb.AppendLine('sentinel; this gap is tracked by issue #512 (watch-list, ADR 0027).')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('For each label below, do this in the Microsoft Purview portal:')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('  Information Protection -> Sensitivity labels -> <label>')
    [void]$sb.AppendLine('    -> "Auto-labeling for files and emails" tab -> Remove the rule')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Affected labels:')
    foreach ($n in $names) { [void]$sb.AppendLine(("  - {0}" -f $n)) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Operator walkthrough: docs/runbooks/labels-manual-portal-actions.md')
    [void]$sb.AppendLine('Tracking issue:      #512')
    [void]$sb.AppendLine('ADR:                  docs/adr/0027-autoapplication-removal-watch-list.md')
    return $sb.ToString()
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
# scripts/Deploy-LabelPolicies.ps1 (and future Deploy-*.ps1 reconcilers
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

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }

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
    $schemaPath = Join-Path $scriptRoot '..\data-plane\information-protection\labels.schema.json'
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
if ($desiredRoot -and $desiredRoot.ContainsKey('labels') -and $desiredRoot.labels) {
    $desiredEntries = @($desiredRoot.labels)
}

$desiredHashes = @()
if ($mode -eq 'Apply') {
    foreach ($e in $desiredEntries) {
        if (-not $e.ContainsKey('displayName') -or [string]::IsNullOrWhiteSpace([string]$e.displayName)) {
            Write-Error ("Label entry in '{0}' is missing the required 'displayName' field." -f $Path)
            return
        }
        if (-not $e.ContainsKey('tooltip') -or [string]::IsNullOrWhiteSpace([string]$e.tooltip)) {
            Write-Error ("Label '{0}' is missing the required 'tooltip' field. Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label" -f $e.displayName)
            return
        }
        $desiredHashes += ConvertTo-LabelHash -Entry $e
    }
    # Validate parent references resolve within the YAML.
    $names = @{}
    foreach ($h in $desiredHashes) { $names[$h.displayName] = $true }
    foreach ($h in $desiredHashes) {
        if ($h.parent -and -not $names.ContainsKey($h.parent)) {
            Write-Error ("Label '{0}' references parent '{1}' which is not declared in the same YAML." -f $h.displayName, $h.parent)
            return
        }
    }

    # Issue #212 AC#5: cross-file SIT validation. Every sitId referenced
    # from a label's autoApplicationOf block must exist in
    # data-plane/classifications/sit-catalog.yaml. Run this BEFORE any
    # tenant write so an unknown GUID surfaces as a deterministic
    # pre-flight error rather than a Set-Label server-side failure. The
    # SIT catalog is the same reference used by Deploy-AutoLabelPolicies.ps1
    # (ADR 0016 §4); we accept GUIDs in any case and compare lowercased.
    # Reference: https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions
    $autoApplyEntries = @($desiredHashes | Where-Object { $_.autoApplicationOf })
    if ($autoApplyEntries.Count -gt 0) {
        $sitCatalogPath = Join-Path $scriptRoot '..\data-plane\classifications\sit-catalog.yaml'
        if (-not (Test-Path -LiteralPath $sitCatalogPath)) {
            Write-Error ("SIT catalog not found at '{0}'. autoApplicationOf cross-file validation requires the catalog. Run scripts/Sync-SITCatalog.ps1 first." -f $sitCatalogPath)
            return
        }
        $sitCatalogRoot = Get-Content -LiteralPath $sitCatalogPath -Raw | ConvertFrom-Yaml
        $sitCatalogGuids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        if ($sitCatalogRoot -and $sitCatalogRoot.ContainsKey('sits') -and $sitCatalogRoot.sits) {
            foreach ($s in @($sitCatalogRoot.sits)) {
                if ($s.ContainsKey('id') -and $s.id) {
                    [void]$sitCatalogGuids.Add([string]$s.id)
                }
            }
        }
        Write-Information ("SIT catalog OK  : {0} known sitId(s)." -f $sitCatalogGuids.Count) -InformationAction Continue
        foreach ($h in $autoApplyEntries) {
            foreach ($sit in @($h.autoApplicationOf.sensitiveInformationTypes)) {
                if (-not $sitCatalogGuids.Contains([string]$sit.sitId)) {
                    Write-Error ("Label '{0}' references autoApplicationOf sitId '{1}' which is not present in data-plane/classifications/sit-catalog.yaml. Add it to the catalog (or correct the GUID) before reconciling." -f $h.displayName, $sit.sitId)
                    return
                }
            }
        }
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

#region -WhatIf short-circuit (Export only — Apply runs the read phase)

# -WhatIf on the Apply path deliberately does NOT short-circuit. The Apply
# branch's per-write `$PSCmdlet.ShouldProcess(...)` calls already gate every
# New-Label / Set-Label / Remove-Label invocation, so connecting and running
# the read phase under -WhatIf produces the same per-label plan table the
# operator sees during a real apply -- exactly what destructive-change PR
# previews require. See issue #152.
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute#supportsshouldprocess
# Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  Connect, run Get-Label, write every visible label to {0}.' -f $Path) -InformationAction Continue
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

    if ($mode -eq 'Export') {

        #region -ExportCurrentState

        if ($desiredEntries.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("'{0}' already declares {1} label(s) in 'labels:'. Refusing to overwrite without -Force." -f $Path, $desiredEntries.Count)
            return
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
        # Note: -IncludeDetailedLabelActions is a [switch]; use colon-bound syntax so $true is
        # not bound positionally to -Identity. Reference:
        # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters
        # Filter Mode -eq 'PendingDeletion' rows: Remove-Label transitions a
        # label into PendingDeletion rather than hard-deleting; the Microsoft
        # Purview portal hides those rows but Get-Label returns them by
        # default. Re-importing one into committed YAML would undo the prune
        # on the next deploy-labels.yml apply. See issue #441 / #450.
        $allLabels = @(
            Get-Label -IncludeDetailedLabelActions:$true -ErrorAction Stop |
                Where-Object { $_.Mode -ne 'PendingDeletion' }
        )
        Write-Information ("Discovered {0} label(s) visible to the connected app." -f $allLabels.Count) -InformationAction Continue

        # Build a name lookup so we can express parent references by displayName.
        $byGuid = @{}
        foreach ($l in $allLabels) { $byGuid[[string]$l.Guid] = [string]$l.DisplayName }

        # Build entries as [ordered] dictionaries with a fixed key sequence so the
        # YAML emitter produces byte-stable output across runs. Casting back to
        # [hashtable] (or relying on source-hashtable enumeration order) made the
        # exporter non-deterministic and broke the conflict-guard step in
        # deploy-labels.yml. See issue #145.
        $exportEntries = New-Object 'System.Collections.Generic.List[System.Collections.Specialized.OrderedDictionary]'
        foreach ($l in $allLabels | Sort-Object @{Expression = { if ($_.ParentId) { 1 } else { 0 } }}, DisplayName) {
            $hash = ConvertTo-TenantLabelHash -Label $l
            # Stable top-level key sequence: displayName, parent, tooltip, comment,
            # contentType, contentMarking, encryption. Keys are only emitted when the
            # tenant has a value, matching the existing "no empty strings" rule from
            # PR #129.
            $entry = [ordered]@{}
            $entry['displayName'] = $hash.displayName
            if ($l.ParentId -and $byGuid.ContainsKey([string]$l.ParentId)) {
                $entry['parent'] = $byGuid[[string]$l.ParentId]
            }
            if ($hash.tooltip) { $entry['tooltip'] = $hash.tooltip }
            if ($hash.comment) { $entry['comment'] = $hash.comment }
            if ($hash.contentType -and $hash.contentType.Count -gt 0) { $entry['contentType'] = $hash.contentType }
            $marking = [ordered]@{}
            foreach ($section in @('header','footer','watermark')) {
                $key = "marking_$section"
                if ($null -ne $hash[$key]) {
                    # Re-project the unordered marking sub-hash from
                    # ConvertTo-TenantLabelHash into [ordered] with a fixed key
                    # sequence so the YAML serializer produces byte-stable
                    # output across pwsh hosts. The Linux pwsh CI runner emitted
                    # nested @{} keys in a different order than Windows pwsh,
                    # which tripped the conflict guard after #145 / PR #147.
                    $src = $hash[$key]
                    $sub = [ordered]@{}
                    $sub['enabled']   = [bool]$src.enabled
                    $sub['text']      = if ($null -ne $src.text)      { [string]$src.text }      else { '' }
                    $sub['fontSize']  = if ($null -ne $src.fontSize)  { [int]$src.fontSize }     else { 0 }
                    $sub['fontColor'] = if ($null -ne $src.fontColor) { [string]$src.fontColor } else { '' }
                    $sub['alignment'] = if ($null -ne $src.alignment) { [string]$src.alignment } else { '' }
                    $sub['layout']    = if ($null -ne $src.layout)    { [string]$src.layout }    else { '' }
                    $marking[$section] = $sub
                }
            }
            if ($marking.Count -gt 0) { $entry['contentMarking'] = $marking }
            if ($null -ne $hash['encryption']) {
                # Sample-data rule (sample-data.instructions.md): the export emits
                # whatever identities the live tenant returns. When committing back
                # to the repo, real UPNs / group addresses must be swapped for
                # synthetic placeholders. -RedactIdentities performs the swap at
                # export time so the YAML is repo-safe out of the box.
                $rightsDefs = $hash['encryption'].rightsDefinitions
                if ($RedactIdentities -and $rightsDefs) {
                    $redacted = @()
                    foreach ($rd in @($rightsDefs)) {
                        $redacted += [pscustomobject]@{
                            Identity = 'user@contoso.com'
                            Rights   = $rd.Rights
                        }
                    }
                    $rightsDefs = @($redacted | Sort-Object Identity)
                }
                # Stable encryption sub-key sequence.
                $enc = [ordered]@{}
                $enc['enabled']                           = [bool]$hash['encryption'].enabled
                $enc['protectionType']                    = [string]$hash['encryption'].protectionType
                $enc['contentExpiredOnDateInDaysOrNever'] = [string]$hash['encryption'].contentExpiredOnDateInDaysOrNever
                $enc['offlineAccessDays']                 = [int]$hash['encryption'].offlineAccessDays
                $enc['doNotForward']                      = [bool]$hash['encryption'].doNotForward
                $enc['encryptOnly']                       = [bool]$hash['encryption'].encryptOnly
                if ($null -ne $rightsDefs) { $enc['rightsDefinitions'] = @($rightsDefs) }
                $entry['encryption'] = $enc
            }
            # Issue #215: client-side auto-apply round-trip emit. The
            # parser in ConvertTo-TenantLabelHash now sources from
            # $Label.Conditions JSON (the verified Set-Label sink), so
            # mode, policyTip, and the SIT array are all round-trip
            # stable and safe to emit here.
            if ($null -ne $hash['autoApplicationOf']) {
                $aa = $hash['autoApplicationOf']
                $aaOrdered = [ordered]@{}
                if ($aa.mode)      { $aaOrdered['mode']      = [string]$aa.mode }
                if ($aa.policyTip) { $aaOrdered['policyTip'] = [string]$aa.policyTip }
                $sitsOrdered = @()
                foreach ($sit in @($aa.sensitiveInformationTypes)) {
                    $sitEntry = [ordered]@{}
                    $sitEntry['sitId']         = [string]$sit.sitId
                    $sitEntry['minCount']      = [int]$sit.minCount
                    $sitEntry['minConfidence'] = [int]$sit.minConfidence
                    $sitsOrdered += $sitEntry
                }
                $aaOrdered['sensitiveInformationTypes'] = $sitsOrdered
                $entry['autoApplicationOf'] = $aaOrdered
            }
            $exportEntries.Add($entry)
        }

        Write-Information ("Exporting {0} label(s)." -f $exportEntries.Count) -InformationAction Continue

        # Preserve YAML header comments by line-splicing.
        $originalLines = Get-Content -LiteralPath $Path
        $cutIndex = -1
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ($originalLines[$i] -match '^\s*labels\s*:') {
                $cutIndex = $i
                break
            }
        }
        if ($cutIndex -lt 0) {
            Write-Error ("Could not find 'labels:' key in '{0}'. Refusing to export." -f $Path)
            return
        }
        $headerLines = $originalLines[0..($cutIndex - 1)]

        $newBlock = New-Object 'System.Collections.Generic.List[string]'
        if ($exportEntries.Count -eq 0) {
            $newBlock.Add('labels: []')
        }
        else {
            # Use powershell-yaml's serialization for the body so nested
            # structures (contentMarking, encryption) round-trip cleanly.
            # WithIndentedSequences indents block-sequence items 2 spaces from
            # their parent key, matching the hand-curated style in this repo
            # and satisfying the default yamllint indentation rule.
            # Reference: https://www.powershellgallery.com/packages/powershell-yaml
            # Wrap with [ordered] so the top-level 'labels' key serializes
            # deterministically (issue #145).
            $body = ([ordered]@{ labels = @($exportEntries) }) | ConvertTo-Yaml -Options WithIndentedSequences
            foreach ($line in ($body -split "`n")) { $newBlock.Add($line.TrimEnd()) }
            # Drop trailing empty lines introduced by the serializer's final newline.
            while ($newBlock.Count -gt 0 -and [string]::IsNullOrEmpty($newBlock[$newBlock.Count - 1])) {
                $newBlock.RemoveAt($newBlock.Count - 1)
            }
        }

        $finalLines = @($headerLines) + @($newBlock)
        $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
        $shouldProcessAction = "Replace 'labels:' block with {0} entry/entries" -f $exportEntries.Count
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            # Write with explicit LF line endings (no CRLF) and exactly one trailing newline,
            # so yamllint's new-lines and empty-lines rules are satisfied regardless of host OS.
            $content = ($finalLines -join "`n") + "`n"
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
            Write-Information ("Wrote {0} label entry/entries to '{1}'." -f $exportEntries.Count, $Path) -InformationAction Continue
        }
        return

        #endregion
    }

    #region Apply mode: two-phase reconciliation

    if ($desiredHashes.Count -eq 0) {
        Write-Information 'No labels declared in YAML. Nothing to reconcile.' -InformationAction Continue
        return @()
    }

    # ---- Phase 1: Read + categorize ----
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
    # Note: -IncludeDetailedLabelActions is a [switch]; use colon-bound syntax so $true is
    # not bound positionally to -Identity. Reference:
    # https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters
    # Filter Mode -eq 'PendingDeletion' rows: Remove-Label transitions a
    # label into PendingDeletion rather than hard-deleting; the Microsoft
    # Purview portal hides those rows but Get-Label returns them by
    # default. Including them here would classify a just-pruned label as
    # a NoOp orphan on the next -WhatIf and inflate the B-strict
    # conflict-guard's orphan count in deploy-labels.yml. See issue
    # #441 / #450.
    $tenantLabels = @(
        Get-Label -IncludeDetailedLabelActions:$true -ErrorAction Stop |
            Where-Object { $_.Mode -ne 'PendingDeletion' }
    )
    Write-Information ("Read {0} label(s) from tenant." -f $tenantLabels.Count) -InformationAction Continue

    $tenantByGuid = @{}
    foreach ($l in $tenantLabels) {
        $tenantByGuid[[string]$l.Guid] = $l
    }

    # Sensitivity labels permit duplicate DisplayName across different
    # parents (e.g. 'Confidential / Associate' and 'Highly Confidential /
    # Associate'). Key the lookup by '<parentDisplayName>/<displayName>'
    # for sublabels, falling back to plain displayName for top-level
    # labels. Also keep a top-level-only lookup for resolving parent
    # references in Create paths, where the YAML 'parent' field is a
    # bare displayName. See issue #131.
    # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels
    $tenantByPath      = @{}
    $tenantTopByName   = @{}
    foreach ($l in $tenantLabels) {
        if ($l.ParentId -and $tenantByGuid.ContainsKey([string]$l.ParentId)) {
            $parentName = [string]$tenantByGuid[[string]$l.ParentId].DisplayName
            $tenantByPath["$parentName/$([string]$l.DisplayName)"] = $l
        }
        else {
            $tenantByPath[[string]$l.DisplayName] = $l
            $tenantTopByName[[string]$l.DisplayName] = $l
        }
    }

    # Order desired entries: parents first, then children. Stable beyond
    # that to keep diff output predictable.
    $orderedDesired = @($desiredHashes | Sort-Object @{ Expression = { if ($_.parent) { 1 } else { 0 } } }, displayName)

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $orderedDesired) {
        $desiredKey = if ($d.parent) { "$($d.parent)/$($d.displayName)" } else { $d.displayName }
        if ($tenantByPath.ContainsKey($desiredKey)) {
            $tenantHash = ConvertTo-TenantLabelHash -Label $tenantByPath[$desiredKey]
            $diffs = Compare-LabelHash -Desired $d -Tenant $tenantHash
            if ($diffs.Count -eq 0) {
                $report.Add([pscustomobject]@{
                    Category = 'NoChange'
                    Kind     = 'Label'
                    Name     = $d.displayName
                    Reason   = 'Declared in YAML and present in tenant; tracked fields identical.'
                    Field    = ''
                })
            }
            else {
                # Issue #429: split the bare 'autoApplicationOf' removal off
                # the apply set. The reconciler emits a NeedsPortalAction row
                # instead of an Update because Microsoft Learn documents no
                # Set-Label -Conditions sentinel that clears the rule in-band.
                # See ADR 0027 for the deferral and the watch-list re-open
                # triggers. Other diffs on the same label (tooltip, encryption,
                # marking, autoApplicationOf.mode/policyTip/SITs when both
                # sides have a block) stay on the Update plan.
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
                $resolution = Resolve-AutoApplyRemovalPlan -Diffs $diffs -Desired $d -Tenant $tenantHash
                $applyableDiffs = @($resolution.ApplyableDiffs)
                if ($resolution.NeedsPortalRemoval) {
                    $report.Add([pscustomobject]@{
                        Category = 'NeedsPortalAction'
                        Kind     = 'Label'
                        Name     = $d.displayName
                        Reason   = 'Tenant carries an autoApplicationOf (Conditions) block that this YAML omits; clear it in the Microsoft Purview portal (Information Protection -> Sensitivity labels -> <label> -> "Auto-labeling for files and emails" -> Remove). Tracked: #512. ADR 0027.'
                        Field    = 'autoApplicationOf'
                    })
                }
                if ($applyableDiffs.Count -gt 0) {
                    foreach ($f in $applyableDiffs) {
                        $report.Add([pscustomobject]@{
                            Category = 'Update'
                            Kind     = 'Label'
                            Name     = $d.displayName
                            Reason   = 'Tracked field differs from tenant.'
                            Field    = $f
                        })
                    }
                    $plan.Add([pscustomobject]@{
                        Action  = 'Update'
                        Desired = $d
                        Tenant  = $tenantByPath[$desiredKey]
                        Fields  = @($applyableDiffs)
                    })
                }
            }
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'Create'
                Kind     = 'Label'
                Name     = $d.displayName
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

    # Orphans: tenant labels not declared in YAML. Use composite-key
    # matching so a sublabel sharing a displayName with a label under a
    # different parent is not falsely classified as orphan. See #131.
    $desiredKeys = @{}
    foreach ($d in $orderedDesired) {
        $k = if ($d.parent) { "$($d.parent)/$($d.displayName)" } else { $d.displayName }
        $desiredKeys[$k] = $true
    }
    $orphans = @()
    foreach ($l in $tenantLabels) {
        $tenantKey = if ($l.ParentId -and $tenantByGuid.ContainsKey([string]$l.ParentId)) {
            "$([string]$tenantByGuid[[string]$l.ParentId].DisplayName)/$([string]$l.DisplayName)"
        }
        else {
            [string]$l.DisplayName
        }
        if (-not $desiredKeys.ContainsKey($tenantKey)) {
            $orphans += $l
            $cat = if ($PruneMissing.IsPresent) { 'Orphan' } else { 'NoOp' }
            $reason = if ($PruneMissing.IsPresent) {
                'Tenant label not in YAML; will Remove-Label under -PruneMissing.'
            }
            else {
                'Tenant label not in YAML; skipped (use -PruneMissing to remove).'
            }
            $report.Add([pscustomobject]@{
                Category = $cat
                Kind     = 'Label'
                Name     = [string]$l.DisplayName
                Reason   = $reason
                Field    = ''
            })
        }
    }

    # ---- Pre-write validation: parent must be a label group ----
    # Issue #140: New-Label rejects a sublabel whose parent is a leaf in the
    # modern label scheme with InvalidParentLabelInModernLabelSchemeException
    # (a parent label is only a "group" once it has at least one sublabel).
    # Catch this at read time so the script never enters the write phase
    # with an invalid plan, and the operator sees a single Write-Error with
    # the offending label and parent instead of a Microsoft cmdlet stack.
    # Reference: https://learn.microsoft.com/en-us/purview/sensitivity-labels#sublabels-grouping-labels
    $tenantParentGuids = @{}
    foreach ($l in $tenantLabels) {
        if ($l.ParentId) { $tenantParentGuids[[string]$l.ParentId] = $true }
    }
    $desiredTopByName = @{}
    foreach ($d in $orderedDesired) {
        if (-not $d.parent) { $desiredTopByName[[string]$d.displayName] = $true }
    }
    $blockedRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $orderedDesired) {
        if (-not $d.parent) { continue }
        $parentName = [string]$d.parent
        $tenantParent = $tenantTopByName[$parentName]
        $reason = $null
        if ($tenantParent) {
            # Parent exists in tenant. Valid iff it already has at least one sublabel.
            if (-not $tenantParentGuids.ContainsKey([string]$tenantParent.Guid)) {
                $reason = "Parent label '$parentName' is a leaf in the tenant (no existing sublabels). New-Label rejects sublabels of a leaf with InvalidParentLabelInModernLabelSchemeException; promote the parent to a group via the Microsoft Purview portal first, or choose a different parent."
            }
        }
        elseif (-not $desiredTopByName.ContainsKey($parentName)) {
            # Parent is neither in tenant nor declared as a top-level entry in YAML.
            $reason = "Parent label '$parentName' is not present in the tenant and not declared in YAML. Declare the parent as a top-level entry first or correct the parent name."
        }
        if ($reason) {
            $blockedRows.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'Label'
                Name     = [string]$d.displayName
                Reason   = $reason
                Field    = ''
            })
            # Strip prior Create/Update rows for this same desired entry so
            # the plan summary shows one row (Blocked) per offending label.
            # Note: do not call `New-Object List[object] (@(...))` to rebuild
            # the list; PowerShell unrolls the array as positional constructor
            # arguments and throws when the filtered array has != 1 item.
            $blockedDisplay = [string]$d.displayName
            $kept = @($report | Where-Object {
                -not ($_.Kind -eq 'Label' -and $_.Name -eq $blockedDisplay -and $_.Category -in @('Create','Update'))
            })
            $report.Clear()
            foreach ($r in $kept) { $report.Add($r) }
            $report.Add([pscustomobject]@{
                Category = 'Blocked'
                Kind     = 'Label'
                Name     = [string]$d.displayName
                Reason   = $reason
                Field    = ''
            })
            # Drop the corresponding plan entry so no write is attempted.
            $keptPlan = @($plan | Where-Object {
                -not ($_.Desired -and [string]$_.Desired.displayName -eq [string]$d.displayName -and [string]$_.Desired.parent -eq $parentName)
            })
            $plan.Clear()
            foreach ($p in $keptPlan) { $plan.Add($p) }
        }
    }

    # ---- ADR 0029: direction-policy pass ----
    # Walk the Update plan entries; for each, consult Resolve-DirectionPolicyAction
    # to decide Skip vs. Update under the configured policy and operator-
    # supplied SkipNames list. Create entries are unaffected (a label that
    # exists in YAML but not in the tenant has no shared-property drift to
    # arbitrate). Audit mode is handled by a separate short-circuit below
    # and does not enter this pass.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'
        $keptPolicyPlan = @()
        foreach ($p in $plan) {
            if ($p.Action -ne 'Update') {
                $keptPolicyPlan += $p
                continue
            }
            $displayName = [string]$p.Desired.displayName
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
            # the run log calls out every shared label whose tenant fields
            # this run will overwrite, with the drifted field set, per
            # ADR 0029 §"repo-wins mode".
            $fieldsText = @($p.Fields) -join ','
            Write-Warning ("repo-wins overwriting tenant on label '{0}' fields: {1}" -f $displayName, $fieldsText)
            $keptPolicyPlan += $p
        }
        if ($skipDecisions.Count -gt 0) {
            $plan.Clear()
            foreach ($k in $keptPolicyPlan) { $plan.Add($k) }
            # Drop the existing Update report rows for any skipped label so
            # the plan summary shows the Skip row (and only the Skip row)
            # per skipped label. The augmented $reportWithParent table built
            # below uses $report as its source.
            $skippedDisplayNames = @($skipDecisions | ForEach-Object { $_.DisplayName })
            $kept = @($report | Where-Object {
                -not ($_.Kind -eq 'Label' -and $_.Category -eq 'Update' -and ($skippedDisplayNames -contains [string]$_.Name))
            })
            $report.Clear()
            foreach ($r in $kept) { $report.Add($r) }
            foreach ($s in $skipDecisions) {
                $report.Add([pscustomobject]@{
                    Category = 'Skip'
                    Kind     = 'Label'
                    Name     = $s.DisplayName
                    Reason   = $s.Reason
                    Field    = (@($s.Fields) -join ',')
                })
                # Machine-readable marker for the workflow's auto-PR step
                # (sub-issue C). One line per skipped label so a simple
                # `grep '\[ADR0029-SKIP\]'` over the run log yields the
                # full skip list.
                Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
            }
        }
    }

    # ---- Plan summary: emit one row per label BEFORE writes execute ----
    # Issue #137: the post-write drift report (see end of this region)
    # never prints when a write throws, so the per-label categorization
    # is invisible at the moment it matters most. Emit a plan-row table
    # now so a write-phase failure still leaves the diagnostic on stdout.
    # One row per (parent, displayName) label — sublabels with the same
    # displayName under different parents must remain visually distinct.
    # Multiple 'Update' field rows for one label collapse into a single
    # comma-joined Fields cell so each label appears on exactly one row.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/format-table
    $desiredParentByKey = @{}
    foreach ($d in $orderedDesired) {
        $k = if ($d.parent) { "$($d.parent)/$($d.displayName)" } else { $d.displayName }
        $desiredParentByKey[$k] = if ($d.parent) { [string]$d.parent } else { '' }
    }
    # Augment each report row with a Parent so Group-Object below can
    # disambiguate sublabels that share a displayName.
    $reportWithParent = $report | ForEach-Object {
        $row = $_
        $parent = ''
        if ($row.Kind -eq 'Label') {
            foreach ($k in $desiredParentByKey.Keys) {
                if ($k -eq $row.Name -or $k.EndsWith("/$($row.Name)")) {
                    $parent = $desiredParentByKey[$k]
                    break
                }
            }
        }
        [pscustomobject]@{
            Category = $row.Category
            Kind     = $row.Kind
            Parent   = $parent
            Name     = $row.Name
            Field    = $row.Field
        }
    }

    $planRows = $reportWithParent |
        Group-Object Category, Parent, Name |
        ForEach-Object {
            $first = $_.Group[0]
            $fields = @($_.Group | Where-Object { $_.Field } | ForEach-Object { $_.Field }) -join ','
            [pscustomobject]@{
                Category = $first.Category
                Kind     = $first.Kind
                Parent   = $first.Parent
                Name     = $first.Name
                Fields   = $fields
            }
        } |
        Sort-Object Category, Parent, Name

    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $planRows |
        Format-Table Category, Kind, Parent, Name, Fields -Wrap |
        Out-String |
        Write-Information -InformationAction Continue

    # Fail-fast on Blocked rows so no write phase is entered. Issue #140.
    if ($blockedRows.Count -gt 0) {
        foreach ($b in $blockedRows) {
            Write-Error ("Label '{0}' is Blocked: {1}" -f $b.Name, $b.Reason)
        }
        throw ("Reconciliation aborted: {0} label(s) blocked by parent validation. See plan summary above." -f $blockedRows.Count)
    }

    # ---- ADR 0029: audit-mode short-circuit ----
    # `-DirectionPolicy audit` keeps the categorized report intact for
    # the end-of-script emission, but empties the plan and orphan lists
    # so Phase 2 (session refresh) and Phase 3 (write loop) become
    # no-ops without disrupting the script's normal control flow.
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

    # Under -WhatIf no New-/Set-/Remove-Label call will execute (each is
    # gated by $PSCmdlet.ShouldProcess in Phase 3), so the read/write
    # session refresh is unnecessary work. Skip it and let Phase 3 walk
    # the plan against the existing read-phase session for the per-label
    # plan table. Issue #152.
    if ($writeCount -gt 0 -and -not $WhatIfPreference) {
        Write-Information ("Read phase complete. Refreshing S&C session before {0} write operation(s)." -f $writeCount) -InformationAction Continue

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        # See Deploy-PurviewRoleGroups.ps1 for the rationale on tearing
        # down the EXO module entirely between read and write phases.
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
    # Track GUIDs of newly-created parent labels so a sublabel created
    # in the same run can resolve its ParentId without a second
    # Get-Label round-trip.
    $createdParentGuids = @{}

    # Microsoft Purview's modern label scheme requires a parent label to
    # be promoted to a "label group" before any sublabel can be attached
    # via -ParentId. Otherwise New-Label rejects the child with
    # InvalidParentLabelInModernLabelSchemeException. Detect any desired
    # top-level entry that has at least one child also being created in
    # this plan and promote it via the -IsLabelGroup switch on New-Label.
    # See #156.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
    $parentsRequiringGroup = @{}
    foreach ($e in $plan) {
        if ($e.Action -eq 'Create' -and $e.Desired.parent) {
            $parentsRequiringGroup[[string]$e.Desired.parent] = $true
        }
    }

    foreach ($entry in $plan) {
        $d = $entry.Desired
        switch ($entry.Action) {

            'Create' {
                $cmdletArgs = ConvertTo-LabelCmdletArgument -Desired $d -IncludeName
                if ($d.parent) {
                    # Parent reference in YAML is a bare displayName.
                    # Resolve against the top-level-only lookup to avoid
                    # collisions with sublabels that share a name. See #131.
                    $parentLabel = $tenantTopByName[$d.parent]
                    $parentGuid = if ($parentLabel) { [string]$parentLabel.Guid } else { $createdParentGuids[$d.parent] }
                    if (-not $parentGuid) {
                        Write-Error ("Cannot create '{0}': parent '{1}' has no resolved GUID. Was the parent declared in YAML and not yet created?" -f $d.displayName, $d.parent)
                        return
                    }
                    $cmdletArgs['ParentId'] = $parentGuid
                }
                elseif ($parentsRequiringGroup.ContainsKey([string]$d.displayName)) {
                    # Top-level label that will be the parent of one or
                    # more sublabels created in the same run. Promote to
                    # a label group at create time. See #156.
                    $cmdletArgs['IsLabelGroup'] = $true
                    # Microsoft Purview label groups reject the action-
                    # bearing parameters (ContentType, EncryptionEnabled,
                    # ApplyContentMarking*, ApplyWaterMarking*) with
                    # "A label group does not supports parameter
                    # 'LabelActions'." Strip them so the create call
                    # carries only display metadata.
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
                    foreach ($k in @(
                        'ContentType',
                        'EncryptionEnabled',
                        'EncryptionProtectionType',
                        'EncryptionContentExpiredOnDateInDaysOrNever',
                        'EncryptionOfflineAccessDays',
                        'EncryptionDoNotForward',
                        'EncryptionEncryptOnly',
                        'EncryptionPromptUser',
                        'EncryptionRightsDefinitions',
                        'ApplyContentMarkingHeaderEnabled',
                        'ApplyContentMarkingHeaderText',
                        'ApplyContentMarkingHeaderFontSize',
                        'ApplyContentMarkingHeaderFontColor',
                        'ApplyContentMarkingHeaderAlignment',
                        'ApplyContentMarkingFooterEnabled',
                        'ApplyContentMarkingFooterText',
                        'ApplyContentMarkingFooterFontSize',
                        'ApplyContentMarkingFooterFontColor',
                        'ApplyContentMarkingFooterAlignment',
                        'ApplyWaterMarkingEnabled',
                        'ApplyWaterMarkingText',
                        'ApplyWaterMarkingFontSize',
                        'ApplyWaterMarkingFontColor',
                        'ApplyWaterMarkingLayout'
                    )) {
                        if ($cmdletArgs.ContainsKey($k)) { $cmdletArgs.Remove($k) | Out-Null }
                    }
                }
                $shouldProcessTarget = "Sensitivity label '{0}'" -f $d.displayName
                $shouldProcessAction = 'New-Label'
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-label
                    try {
                        $created = New-Label @cmdletArgs -Confirm:$false -ErrorAction Stop
                        if ($created -and $created.Guid) {
                            $createdParentGuids[$d.displayName] = [string]$created.Guid
                        }
                        Write-Information ("Created label '{0}'." -f $d.displayName) -InformationAction Continue
                    }
                    catch {
                        if ($_.Exception.Message -match 'already exists' -or
                            $_.Exception.Message -match 'LabelAlreadyExists') {
                            Write-Information ("Label '{0}' already exists server-side; treating as no-op." -f $d.displayName) -InformationAction Continue
                            continue
                        }
                        Write-Error ("New-Label '{0}' failed: {1}" -f $d.displayName, $_.Exception.Message)
                        return
                    }
                }
                else {
                    # ShouldProcess returned $false (e.g. -WhatIf): no
                    # New-Label call was made, so no real GUID exists.
                    # Record a synthetic zero GUID for the just-skipped
                    # parent so any sublabel Create later in this plan
                    # can resolve its -ParentId argument and continue
                    # the simulation. The zero GUID matches the
                    # repo-wide placeholder convention; no remote write
                    # ever runs under WhatIf. Issue #217.
                    $createdParentGuids[$d.displayName] = '00000000-0000-0000-0000-000000000000'
                }
            }

            'Update' {
                $tenantLabel = $entry.Tenant
                $changedFields = @($entry.Fields)
                $cmdletArgs = ConvertTo-LabelCmdletArgument -Desired $d
                # Set-Label is keyed by Identity (the immutable Name or
                # the GUID). Use GUID for unambiguous targeting.
                $cmdletArgs.Remove('DisplayName') | Out-Null
                $cmdletArgs['Identity'] = [string]$tenantLabel.Guid

                # Issue #157: ConvertTo-LabelCmdletArgument builds a
                # full splat that always carries marking and encryption
                # toggles (and may carry empty-string text fields whose
                # YAML key was absent). Set-Label rejects empty-text
                # parameters with TextEmptyException, and emitting
                # toggles for unchanged sections both spuriously
                # rewrites tenant state and trips the same exception.
                # Filter the splat down to ONLY the parameter families
                # whose tracked field changed in the diff. Identity is
                # always retained. Create-path keeps full-splat
                # behavior because every field has a deterministic
                # initial value at create time.
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
                $keepKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                [void]$keepKeys.Add('Identity')
                foreach ($f in $changedFields) {
                    switch -Regex ($f) {
                        '^tooltip$'                { [void]$keepKeys.Add('Tooltip') }
                        '^comment$'                { [void]$keepKeys.Add('Comment') }
                        '^contentType$'            { [void]$keepKeys.Add('ContentType') }
                        '^marking_header(\.|$)'    {
                            @(
                                'ApplyContentMarkingHeaderEnabled','ApplyContentMarkingHeaderText',
                                'ApplyContentMarkingHeaderFontSize','ApplyContentMarkingHeaderFontColor',
                                'ApplyContentMarkingHeaderAlignment'
                            ) | ForEach-Object { [void]$keepKeys.Add($_) }
                        }
                        '^marking_footer(\.|$)'    {
                            @(
                                'ApplyContentMarkingFooterEnabled','ApplyContentMarkingFooterText',
                                'ApplyContentMarkingFooterFontSize','ApplyContentMarkingFooterFontColor',
                                'ApplyContentMarkingFooterAlignment'
                            ) | ForEach-Object { [void]$keepKeys.Add($_) }
                        }
                        '^marking_watermark(\.|$)' {
                            @(
                                'ApplyWaterMarkingEnabled','ApplyWaterMarkingText',
                                'ApplyWaterMarkingFontSize','ApplyWaterMarkingFontColor',
                                'ApplyWaterMarkingLayout'
                            ) | ForEach-Object { [void]$keepKeys.Add($_) }
                        }
                        '^encryption(\.|$)'        {
                            @(
                                'EncryptionEnabled','EncryptionProtectionType',
                                'EncryptionContentExpiredOnDateInDaysOrNever','EncryptionOfflineAccessDays',
                                'EncryptionDoNotForward','EncryptionEncryptOnly','EncryptionPromptUser',
                                'EncryptionRightsDefinitions'
                            ) | ForEach-Object { [void]$keepKeys.Add($_) }
                        }
                        '^autoApplicationOf(\.|$)' {
                            # Issue #215: verified Set-Label sink for client-
                            # side auto-apply is `-Conditions <json>` (Phase 1B
                            # probe 2026-05-16). Build the merged JSON by
                            # preserving server-managed Settings keys (name,
                            # rulepackage, groupname, confidencelevel,
                            # maxcount, maxconfidence) and overwriting only
                            # the four schema-owned keys (mincount,
                            # minconfidence, autoapplytype, policytip).
                            # LocaleSettings.autotooltip mirroring is
                            # deferred to a follow-up (single-locale lab
                            # uses Conditions.policytip as the operative
                            # field). Reference:
                            # https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
                            #
                            # Issue #429: the desired-omits + tenant-has
                            # removal direction never reaches this branch
                            # because Resolve-AutoApplyRemovalPlan strips
                            # the bare 'autoApplicationOf' field from
                            # $applyableDiffs at planner time and emits a
                            # NeedsPortalAction report row instead (no
                            # documented Set-Label clearing sentinel; see
                            # ADR 0027). Only the add/translate direction
                            # (desired set) reaches this code, so the
                            # $d.autoApplicationOf guard is always true
                            # here and the merge helper handles the rest.
                            $mergedConditions = Merge-LabelConditionsJson `
                                -CurrentConditions ([string]$tenantLabel.Conditions) `
                                -DesiredAutoApply  $d.autoApplicationOf `
                                -LabelDisplayName  $d.displayName
                            if ($mergedConditions) {
                                $cmdletArgs['Conditions'] = $mergedConditions
                                [void]$keepKeys.Add('Conditions')
                            }
                            # If the merge returned $null (no overlap, parse
                            # failure, empty tenant Conditions) the helper
                            # already wrote a Write-Warning explaining the
                            # skip; do not add the parameter to the splat.
                        }
                    }
                }
                foreach ($k in @($cmdletArgs.Keys)) {
                    if (-not $keepKeys.Contains($k)) { $cmdletArgs.Remove($k) | Out-Null }
                }

                $shouldProcessTarget = "Sensitivity label '{0}'" -f $d.displayName
                $shouldProcessAction = 'Set-Label'
                if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-label
                    try {
                        Set-Label @cmdletArgs -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Updated label '{0}'." -f $d.displayName) -InformationAction Continue
                    }
                    catch {
                        Write-Error ("Set-Label '{0}' failed: {1}" -f $d.displayName, $_.Exception.Message)
                        return
                    }
                }
            }
        }
    }

    if ($PruneMissing.IsPresent) {
        # Sort orphans depth-descending (deepest first) so child labels are
        # removed before their parents within a single pass. The Microsoft
        # Purview tenant rejects Remove-Label on a parent that still has
        # children with a non-throwing warning -- without this sort, the
        # script previously misreported parent removals as successful.
        # See #154.
        $depthFor = {
            param($lbl)
            $depth = 0
            $cursor = $lbl
            while ($cursor -and $cursor.ParentId -and $tenantByGuid.ContainsKey([string]$cursor.ParentId)) {
                $depth++
                $cursor = $tenantByGuid[[string]$cursor.ParentId]
            }
            return $depth
        }
        $sortedOrphans = $orphans | Sort-Object -Property @{ Expression = { & $depthFor $_ }; Descending = $true }, @{ Expression = 'DisplayName'; Descending = $false }

        $pruneFailures = New-Object 'System.Collections.Generic.List[string]'
        foreach ($l in $sortedOrphans) {
            $shouldProcessTarget = "Sensitivity label '{0}'" -f $l.DisplayName
            $shouldProcessAction = 'Remove-Label (destructive: drops a label)'
            if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
                # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-label
                # Capture the warning stream as well as terminating errors:
                # Microsoft Purview's Remove-Label can refuse a delete via a
                # non-throwing WARNING (for example, parent-with-children).
                # If any warning surfaces, treat it as a failure rather than
                # logging a false-positive 'Removed' line. See #154.
                $rmWarnings = $null
                try {
                    Remove-Label -Identity ([string]$l.Guid) -Confirm:$false `
                        -WarningAction SilentlyContinue -WarningVariable rmWarnings `
                        -ErrorAction Stop | Out-Null
                }
                catch {
                    Write-Error ("Remove-Label '{0}' failed: {1}" -f $l.DisplayName, $_.Exception.Message)
                    $pruneFailures.Add([string]$l.DisplayName)
                    continue
                }
                if ($rmWarnings -and $rmWarnings.Count -gt 0) {
                    $warnText = ($rmWarnings | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 1)
                    Write-Error ("Remove-Label '{0}' did not delete the label. Tenant warning: {1}" -f $l.DisplayName, $warnText)
                    $pruneFailures.Add([string]$l.DisplayName)
                    continue
                }
                Write-Information ("Removed label '{0}'." -f $l.DisplayName) -InformationAction Continue
            }
        }

        if ($pruneFailures.Count -gt 0) {
            throw ("Reconciliation aborted: {0} orphan label(s) could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
        }
    }

    #endregion
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
    }
}

#endregion

#region Drift report emission

$report | Sort-Object Category, Name, Field |
    Format-Table Category, Kind, Name, Field, Reason -AutoSize |
    Out-String | Write-Information -InformationAction Continue

# Issue #512 (closes #429): when any NeedsPortalAction rows exist in the
# report, surface them in a dedicated end-of-run operator block so the
# residual manual-action requirement is not buried inside the drift
# table. Two sinks:
#   1. Console / GitHub Actions log via Write-Information with the
#      ::warning:: workflow-command annotation prefix. GitHub Actions
#      parses workflow commands from any log line regardless of which
#      PowerShell stream emitted them, so this matches the existing
#      [ADR0029-SKIP] marker pattern at line ~1755 and keeps the script
#      PSScriptAnalyzer-clean (PSAvoidUsingWriteHost).
#   2. $GITHUB_STEP_SUMMARY (markdown) when running in GitHub Actions,
#      so the block lands at the top of the run-summary page without
#      requiring the workflow to grep the log.
# Both sinks render the same content via Get-NeedsPortalActionSummary.
# Reference: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#example-of-overwriting-job-summaries
# Reference: https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#setting-a-warning-message
$consoleBlock = Get-NeedsPortalActionSummary -Report $report
if ($consoleBlock) {
    Write-Information '::warning::Manual portal actions required. See block below and docs/runbooks/labels-manual-portal-actions.md.' -InformationAction Continue
    Write-Information $consoleBlock -InformationAction Continue
    if ($env:GITHUB_STEP_SUMMARY) {
        $mdBlock = Get-NeedsPortalActionSummary -Report $report -Markdown
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $mdBlock -Encoding utf8
    }
}

return $report

#endregion