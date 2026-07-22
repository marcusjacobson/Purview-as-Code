#Requires -Version 7.4

<#
.SYNOPSIS
    Reconcile Microsoft Purview retention labels and file plan properties
    (Records Management) from declarative YAML.

.DESCRIPTION
    Reads data-plane/records/file-plan.yaml plus its Draft-07 schema and
    reconciles two object kinds against the tenant via Security & Compliance
    PowerShell over Connect-IPPSSession:

        - File plan property objects: authorities, categories, citations,
          departments, referenceIds, subCategories
        - Retention labels (ComplianceTag) optionally bound to the
          property objects above

    Standard drift contract (matching Deploy-RetentionPolicies.ps1 and
    Deploy-DLPPolicies.ps1):

        - Plan / apply with ShouldProcess (-WhatIf / -Confirm)
        - Tenant-only ("orphan") entries are reported but never removed
          unless -PruneMissing is supplied
        - -ExportCurrentState round-trips tenant state to YAML

    Auth uses a Key Vault-signed JWT (ADR 0011 Decision #3) acquired by
    scripts/Get-PurviewIPPSAccessToken.ps1 and presented to
    Connect-IPPSSession -AccessToken (requires
    ExchangeOnlineManagement v3.8.0-Preview1 or later).

    File plan property objects (authorities, categories, citations,
    departments, referenceIds, subCategories) have NO Set-* cmdlet on the
    Purview API. The reconciler therefore supports only Create / NoChange /
    Orphan for properties. If a citation URL or a subCategory's
    parentCategory changes in YAML versus the tenant, the reconciler emits
    a DriftWarn record and continues -- the lab owner must remove and
    re-create the property by hand (which itself requires removing every
    retention label that references it). The default empty YAML makes this
    moot for the first apply.

    Retention labels (ComplianceTag) support Create / Update (via
    Set-ComplianceTag) / NoChange / Orphan. Set-ComplianceTag cannot change
    IsRecordLabel or Regulatory after creation; drift on those fields is
    reported as DriftWarn and not auto-fixed.

    Reconciler ordering:

        Apply:  properties first, then labels (so labels can bind by name).
        Prune:  labels first, then properties (parent-before-children).

    References:
      - https://learn.microsoft.com/en-us/purview/records-management
      - https://learn.microsoft.com/en-us/purview/file-plan-manager
      - https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
      - https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag
      - https://learn.microsoft.com/en-us/powershell/module/exchange/set-compliancetag
      - https://learn.microsoft.com/en-us/powershell/module/exchange/remove-compliancetag
      - https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertyauthority
      - https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession

.PARAMETER Path
    Path to the desired-state YAML. Defaults to
    data-plane/records/file-plan.yaml relative to the repository root.

.PARAMETER PruneMissing
    When supplied, remove tenant entries that are not declared in YAML.
    Default: leave them in place and report them as orphans.

.PARAMETER Force
    Permit -ExportCurrentState to overwrite a non-empty target YAML.

.PARAMETER ExportCurrentState
    Read tenant state and write it back to -Path. Skips the desired-state
    load and the plan/apply loop.

.PARAMETER ParametersFile
    Path to the environment parameters file (per ADR 0012). Defaults to
    infra/parameters/lab.yaml. Required keys:
        resources.keyVault.name
        automation.tenantDomain
        automation.apps.dataPlane.{displayName,certificateName}
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault name. Overrides resources.keyVault.name from the parameters
    file.

.PARAMETER CertificateName
    Certificate name in Key Vault used to sign the data-plane JWT.
    Overrides automation.apps.dataPlane.certificateName.

.PARAMETER DataPlaneAppDisplayName
    Display name of the Entra application whose certificate signs the JWT.
    Overrides automation.apps.dataPlane.displayName.

.PARAMETER TenantDomain
    Verified tenant domain used for Connect-IPPSSession -Organization.
    Overrides automation.tenantDomain.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit.
                         No New-/Set-/Remove-* cmdlet writes against
                         the tenant fire under any circumstance.
                         Equivalent to a forced -WhatIf at the script
                         boundary.
      * `portal-wins` -- (default) skip any shared label whose tracked
                         fields differ; emit a Skip plan row per
                         skipped label and a `[ADR0029-SKIP] <name>`
                         line per skip so an upstream workflow can
                         capture the list for an auto-PR. Create /
                         Update / NoChange and orphan handling are
                         unchanged. File plan property objects have no
                         Set-* cmdlet, so only labels participate in
                         shared-property drift arbitration; the
                         DriftWarn plan rows on properties are
                         orthogonal to the direction policy.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift on labels. Emit one Write-Warning per
                         overwritten label naming the drifted field(s).
                         The overwrite is gated at the SCRIPT layer
                         by the ADR 0052 typed-confirmation prompt:
                         it names the labels it is about to
                         overwrite, asks EVERY caller -- local
                         operators included -- and aborts with no
                         tenant writes if declined. Suppress with
                         -Force, or -Confirm:$false as CI does. The
                         workflow's 'overwrite portal' input is an
                         ADDITIONAL gate per ADR 0029, not the only
                         one: a clone of this template that has not
                         run kickoff has no CI at all, so the
                         script-layer gate is its only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. Applies to
    BOTH label rows and file plan property rows -- a name matched
    here is treated as a Skip plan row instead of an Update / Create /
    DriftWarn row (reason: "explicitly skipped by caller"). NoChange
    and Orphan rows are unaffected; -PruneMissing still ignores
    -SkipNames for orphans (use the workflow's orphan-handling toggles
    for that). Names not present in the YAML or the tenant are
    silently ignored (defends against a stale skip list from the
    workflow). The match is case-insensitive and tests against the
    bare `Name` (no kind disambiguation -- the IPPS surface forbids
    duplicate Name values across the six property kinds). Ignored in
    `-DirectionPolicy audit` mode. Default `@()`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`. This script's
    workflow baseline includes the 31 Microsoft File Plan Manager
    seed property objects per
    `docs/adr/0035-records-seed-content-immovable.md`.

.PARAMETER SkipSchemaValidation
    Skip Test-Json validation of the YAML against the shipped schema.
    Intended for local debugging only; CI must not pass this flag.

.EXAMPLE
    PS> ./scripts/Deploy-FilePlan.ps1 -WhatIf
    Dry-run reconciliation against the default lab parameters file and YAML
    path. Prints planned Create / Update / NoChange / Orphan / DriftWarn
    actions without making any changes.

.EXAMPLE
    PS> ./scripts/Deploy-FilePlan.ps1
    Apply the desired state to the tenant (interactive Confirm prompts).

.EXAMPLE
    PS> ./scripts/Deploy-FilePlan.ps1 -PruneMissing -Confirm:$false
    Apply and remove tenant entries not declared in YAML, without
    confirmation prompts. Use only after reviewing -WhatIf output.

.EXAMPLE
    PS> ./scripts/Deploy-FilePlan.ps1 -ExportCurrentState -Path .\file-plan.exported.yaml
    Export current tenant retention labels + file plan properties to a YAML
    file.

.NOTES
    Caller-role requirements:
      - Compliance Administrator OR Compliance Data Administrator on the
        Microsoft Purview compliance portal.

    Data-plane Entra app prerequisites:
      - Office 365 Exchange Online > Exchange.ManageAsApp (application
        permission, admin-consented).
      - Directory role: Compliance Administrator OR Compliance Data
        Administrator, assigned to the application's service principal.
      - Certificate uploaded to the app registration; private key in the
        Key Vault named in the parameters file.

    Output: a stream of [pscustomobject] records with the fields
    Category, Kind, Name, Reason. Category is one of Create, Update,
    NoChange, Orphan, Removed, DriftWarn, Skipped, WhatIf, Failed.
#>

# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path (Split-Path -Parent $PSCommandPath) '..\data-plane\records\file-plan.yaml'),

    [Parameter()]
    [switch]$PruneMissing,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$ExportCurrentState,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]{3,24}$')]
    [string]$VaultName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]{1,127}$')]
    [string]$CertificateName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataPlaneAppDisplayName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')]
    [string]$TenantDomain,

    [Parameter()]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter()]
    [string[]]$SkipNames = @(),

    [Parameter()]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

# Property-kind table. Drives reconciler enumeration, planning, and Invoke-FilePlanExport.
# All six families share the New/Remove cmdlet shape; only Citation/SubCategory have
# additional non-name fields.
$script:PropertyKinds = @(
    @{ Yaml = 'authorities';   Display = 'Authority';   Cmdlet = 'FilePlanPropertyAuthority';   ExtraFields = @() },
    @{ Yaml = 'categories';    Display = 'Category';    Cmdlet = 'FilePlanPropertyCategory';    ExtraFields = @() },
    @{ Yaml = 'citations';     Display = 'Citation';    Cmdlet = 'FilePlanPropertyCitation';    ExtraFields = @('url','jurisdiction') },
    @{ Yaml = 'departments';   Display = 'Department';  Cmdlet = 'FilePlanPropertyDepartment';  ExtraFields = @() },
    @{ Yaml = 'referenceIds';  Display = 'ReferenceId'; Cmdlet = 'FilePlanPropertyReferenceId'; ExtraFields = @() },
    @{ Yaml = 'subCategories'; Display = 'SubCategory'; Cmdlet = 'FilePlanPropertySubCategory'; ExtraFields = @('parentCategory') }
)


#region Helpers

function ConvertTo-DesiredPropertyHash {
    # Normalize a desired property entry into a comparable hashtable.
    # Reference: ./file-plan.schema.json
    param(
        [Parameter(Mandatory = $true)][hashtable]$Entry,
        [Parameter(Mandatory = $true)][string]$Display
    )
    $h = @{ name = [string]$Entry.name; display = $Display }
    foreach ($k in @('url', 'jurisdiction', 'parentCategory')) {
        if ($Entry.ContainsKey($k)) { $h[$k] = [string]$Entry[$k] }
    }
    return $h
}

function ConvertTo-DesiredLabelHash {
    # Normalize a desired retention label entry. File plan property
    # references are kept as a sub-hashtable, resolved at apply time.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $fp = @{}
    if ($Entry.ContainsKey('filePlanProperty') -and $Entry.filePlanProperty) {
        foreach ($k in @('authority','category','subCategory','citation','department','referenceId')) {
            if ($Entry.filePlanProperty.ContainsKey($k)) { $fp[$k] = [string]$Entry.filePlanProperty[$k] }
        }
    }

    $reviewers = @()
    if ($Entry.ContainsKey('reviewerEmail') -and $Entry.reviewerEmail) {
        $reviewers = @($Entry.reviewerEmail | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    return @{
        name              = [string]$Entry.name
        description       = if ($Entry.ContainsKey('description'))   { [string]$Entry.description } else { $null }
        notes             = if ($Entry.ContainsKey('notes'))         { [string]$Entry.notes }       else { $null }
        isRecordLabel     = if ($Entry.ContainsKey('isRecordLabel')) { [bool]$Entry.isRecordLabel } else { $false }
        regulatory        = if ($Entry.ContainsKey('regulatory'))    { [bool]$Entry.regulatory }    else { $false }
        retentionDuration = $Entry.retentionDuration
        retentionAction   = [string]$Entry.retentionAction
        retentionType     = [string]$Entry.retentionType
        reviewerEmail     = $reviewers
        filePlanProperty  = $fp
    }
}

function ConvertTo-TenantPropertyHash {
    # Normalize a Get-FilePlanProperty* result into the desired shape.
    param(
        [Parameter(Mandatory = $true)]$Obj,
        [Parameter(Mandatory = $true)][string]$Display
    )
    $h = @{ name = [string]$Obj.Name; display = $Display }
    # Citation extras (CitationUrl / CitationJurisdiction) and
    # SubCategory parent (ParentCategoryName) appear on the cmdlet output.
    if ($null -ne $Obj.PSObject.Properties['CitationUrl']         -and $Obj.CitationUrl)         { $h.url            = [string]$Obj.CitationUrl }
    if ($null -ne $Obj.PSObject.Properties['CitationJurisdiction'] -and $Obj.CitationJurisdiction) { $h.jurisdiction   = [string]$Obj.CitationJurisdiction }
    if ($null -ne $Obj.PSObject.Properties['ParentCategoryName']  -and $Obj.ParentCategoryName)  { $h.parentCategory = [string]$Obj.ParentCategoryName }
    elseif ($null -ne $Obj.PSObject.Properties['ParentCategory']  -and $Obj.ParentCategory)      { $h.parentCategory = [string]$Obj.ParentCategory }
    return $h
}

function ConvertTo-TenantLabelHash {
    # Normalize a Get-ComplianceTag result into the desired shape.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
    param([Parameter(Mandatory = $true)]$Tag)

    $duration = $null
    if ($null -ne $Tag.RetentionDuration) {
        $raw = [string]$Tag.RetentionDuration
        if     ($raw -eq 'Unlimited')   { $duration = 'Unlimited' }
        elseif ($raw -match '^\d+$')    { $duration = [int]$raw }
        else                            { $duration = $raw }
    }

    $fp = @{}
    if ($Tag.FilePlanMetadata) {
        # FilePlanMetadata is a JSON blob. Documented shape per Get-ComplianceTag
        # is a Settings[] array of {Key, Value} pairs (symmetric to the write-side
        # New-ComplianceTag -FilePlanProperty contract). Legacy flat shape is
        # accepted as a defensive fallback for tenant heterogeneity; Settings[]
        # wins when both are present.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
        try {
            $meta = $Tag.FilePlanMetadata | ConvertFrom-Json -ErrorAction Stop
            $values = @{}
            if ($meta.PSObject.Properties['Settings'] -and $meta.Settings) {
                foreach ($entry in @($meta.Settings)) {
                    if ($entry -and $entry.PSObject.Properties['Key'] -and $entry.Key) {
                        $values[[string]$entry.Key] = [string]$entry.Value
                    }
                }
            }
            foreach ($pair in @(
                @{ Key='authority';   Field='FilePlanPropertyAuthority' },
                @{ Key='category';    Field='FilePlanPropertyCategory' },
                @{ Key='subCategory'; Field='FilePlanPropertySubCategory' },
                @{ Key='citation';    Field='FilePlanPropertyCitation' },
                @{ Key='department';  Field='FilePlanPropertyDepartment' },
                @{ Key='referenceId'; Field='FilePlanPropertyReferenceId' }
            )) {
                if ($values.ContainsKey($pair.Field) -and $values[$pair.Field]) {
                    $fp[$pair.Key] = $values[$pair.Field]
                    continue
                }
                if ($meta.PSObject.Properties[$pair.Field]) {
                    $legacy = $meta.($pair.Field)
                    if ($legacy -and $legacy.PSObject.Properties['Name'] -and $legacy.Name) {
                        $fp[$pair.Key] = [string]$legacy.Name
                    }
                }
            }
        } catch {
            Write-Verbose ('FilePlanMetadata parse failed (non-fatal): {0}' -f $_.Exception.Message)
        }
    }

    $reviewers = @()
    if ($Tag.ReviewerEmail) {
        $reviewers = @($Tag.ReviewerEmail | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    }

    return @{
        name              = [string]$Tag.Name
        description       = if ($Tag.Comment) { [string]$Tag.Comment } else { $null }
        notes             = if ($Tag.Notes)   { [string]$Tag.Notes }   else { $null }
        isRecordLabel     = [bool]$Tag.IsRecordLabel
        regulatory        = if ($null -ne $Tag.Regulatory) { [bool]$Tag.Regulatory } else { $false }
        retentionDuration = $duration
        retentionAction   = [string]$Tag.RetentionAction
        retentionType     = [string]$Tag.RetentionType
        reviewerEmail     = $reviewers
        filePlanProperty  = $fp
    }
}

function Compare-PropertyField {
    # Compare extra (non-name) property fields between desired and tenant.
    # Returns the list of field names that differ. Name match is assumed
    # by the caller (the index lookup keys on name).
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @('url','jurisdiction','parentCategory')) {
        if ($Desired.ContainsKey($k)) {
            if ([string]$Desired[$k] -ne [string]$Tenant[$k]) { $diffs.Add($k) | Out-Null }
        }
    }
    return $diffs
}

function Compare-RetentionLabel {
    # Compare tracked fields between desired and tenant retention labels.
    # Mutable-via-Set-ComplianceTag fields are flagged as Update; immutable
    # fields (isRecordLabel, regulatory) are flagged separately by the caller.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $mutable   = New-Object 'System.Collections.Generic.List[string]'
    $immutable = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) { $mutable.Add('description') | Out-Null }
    }
    if (-not [string]::IsNullOrEmpty($Desired.notes)) {
        if ([string]$Desired.notes -ne [string]$Tenant.notes) { $mutable.Add('notes') | Out-Null }
    }

    $dDur = $Desired.retentionDuration; $tDur = $Tenant.retentionDuration
    if ($dDur -is [int] -and $tDur -is [int]) {
        if ([int]$dDur -ne [int]$tDur) { $mutable.Add('retentionDuration') | Out-Null }
    } elseif ([string]$dDur -ne [string]$tDur) {
        $mutable.Add('retentionDuration') | Out-Null
    }

    if ([string]$Desired.retentionAction -ne [string]$Tenant.retentionAction) { $mutable.Add('retentionAction') | Out-Null }
    if ([string]$Desired.retentionType   -ne [string]$Tenant.retentionType)   { $mutable.Add('retentionType')   | Out-Null }

    $dRev = @($Desired.reviewerEmail | Sort-Object -Unique)
    $tRev = @($Tenant.reviewerEmail  | Sort-Object -Unique)
    if (Compare-Object -ReferenceObject $tRev -DifferenceObject $dRev) { $mutable.Add('reviewerEmail') | Out-Null }

    foreach ($k in @('authority','category','subCategory','citation','department','referenceId')) {
        $dv = if ($Desired.filePlanProperty.ContainsKey($k)) { [string]$Desired.filePlanProperty[$k] } else { '' }
        $tv = if ($Tenant.filePlanProperty.ContainsKey($k))  { [string]$Tenant.filePlanProperty[$k] }  else { '' }
        if ($dv -ne $tv) { $mutable.Add(("filePlanProperty.{0}" -f $k)) | Out-Null }
    }

    if ([bool]$Desired.isRecordLabel -ne [bool]$Tenant.isRecordLabel) { $immutable.Add('isRecordLabel') | Out-Null }
    if ([bool]$Desired.regulatory    -ne [bool]$Tenant.regulatory)    { $immutable.Add('regulatory')    | Out-Null }

    return [pscustomobject]@{ Mutable = $mutable; Immutable = $immutable }
}

function Get-PropertyCreateSplat {
    # Build a splat for New-FilePlanProperty<Display>.
    param([Parameter(Mandatory = $true)][hashtable]$Hash)
    $splat = @{ Name = $Hash.name }
    if ($Hash.ContainsKey('url') -and $Hash.url)                   { $splat.CitationUrl          = $Hash.url }
    if ($Hash.ContainsKey('jurisdiction') -and $Hash.jurisdiction) { $splat.CitationJurisdiction = $Hash.jurisdiction }
    if ($Hash.ContainsKey('parentCategory') -and $Hash.parentCategory) { $splat.ParentCategory   = $Hash.parentCategory }
    return $splat
}

function Get-ComplianceTagSplat {
    # Build a splat for New-ComplianceTag (Create) or Set-ComplianceTag
    # (Update). New- expects -Name; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-compliancetag
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [switch]$ForSet
    )
    $splat = @{}
    if ($ForSet.IsPresent) { $splat.Identity = $Hash.name } else { $splat.Name = $Hash.name }

    if (-not [string]::IsNullOrEmpty($Hash.description))     { $splat.Comment = $Hash.description }
    if (-not [string]::IsNullOrEmpty($Hash.notes))           { $splat.Notes   = $Hash.notes }
    if ($null -ne $Hash.retentionDuration)                   { $splat.RetentionDuration = $Hash.retentionDuration }
    if (-not [string]::IsNullOrEmpty($Hash.retentionAction)) { $splat.RetentionAction   = $Hash.retentionAction }
    if (-not [string]::IsNullOrEmpty($Hash.retentionType))   { $splat.RetentionType     = $Hash.retentionType }
    if (@($Hash.reviewerEmail).Count -gt 0)                  { $splat.ReviewerEmail     = [string[]]@($Hash.reviewerEmail) }

    # Immutable on Set- so skip them in the Set- splat.
    if (-not $ForSet.IsPresent) {
        if ([bool]$Hash.isRecordLabel) { $splat.IsRecordLabel = $true }
        if ([bool]$Hash.regulatory)    { $splat.Regulatory    = $true }
    }

    if ($Hash.filePlanProperty -and $Hash.filePlanProperty.Count -gt 0) {
        # Build the Settings[] array of Key/Value pairs per the documented
        # New-ComplianceTag / Set-ComplianceTag -FilePlanProperty contract.
        # The flat {Key:Value} shape is rejected by IPPS with
        # "Failed to parse File plan metadata value" (verified against
        # contoso.onmicrosoft.com on 2026-06-07, #591).
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag#-fileplanproperty
        $settings = New-Object 'System.Collections.Generic.List[object]'
        foreach ($pair in @(
            @{ K='authority';   F='FilePlanPropertyAuthority' },
            @{ K='category';    F='FilePlanPropertyCategory' },
            @{ K='subCategory'; F='FilePlanPropertySubCategory' },
            @{ K='citation';    F='FilePlanPropertyCitation' },
            @{ K='department';  F='FilePlanPropertyDepartment' },
            @{ K='referenceId'; F='FilePlanPropertyReferenceId' }
        )) {
            if ($Hash.filePlanProperty.ContainsKey($pair.K) -and $Hash.filePlanProperty[$pair.K]) {
                $settings.Add(@{ Key = $pair.F; Value = [string]$Hash.filePlanProperty[$pair.K] }) | Out-Null
            }
        }
        if ($settings.Count -gt 0) {
            $payload = [pscustomobject]@{ Settings = $settings.ToArray() }
            $splat.FilePlanProperty = ($payload | ConvertTo-Json -Compress -Depth 5)
        }
    }

    return $splat
}

function Invoke-FilePlanExport {
    # Round-trip tenant file plan properties + retention labels back to YAML.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$TenantPropertiesByKind,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantTags,
        [switch]$Force
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
        $hasContent = $false
        if ($existing) {
            if ($existing.ContainsKey('retentionLabels') -and @($existing.retentionLabels).Count -gt 0) { $hasContent = $true }
            if ($existing.ContainsKey('filePlanProperties') -and $existing.filePlanProperties) {
                foreach ($k in @('authorities','categories','citations','departments','referenceIds','subCategories')) {
                    if ($existing.filePlanProperties.ContainsKey($k) -and @($existing.filePlanProperties[$k]).Count -gt 0) { $hasContent = $true }
                }
            }
        }
        if ($hasContent -and -not $Force.IsPresent) {
            Write-Error ("Target YAML '{0}' already declares file plan content. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }

    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }

    $fp = [ordered]@{}
    foreach ($kind in $script:PropertyKinds) {
        $items = @()
        $list  = $TenantPropertiesByKind[$kind.Yaml]
        if ($list) {
            foreach ($o in $list) {
                $h = ConvertTo-TenantPropertyHash -Obj $o -Display $kind.Display
                $e = [ordered]@{ name = $h.name }
                if ($h.ContainsKey('url'))            { $e.url            = $h.url }
                if ($h.ContainsKey('jurisdiction'))   { $e.jurisdiction   = $h.jurisdiction }
                if ($h.ContainsKey('parentCategory')) { $e.parentCategory = $h.parentCategory }
                $items += $e
            }
        }
        $fp[$kind.Yaml] = $items
    }

    $labels = @()
    foreach ($t in $TenantTags) {
        $h = ConvertTo-TenantLabelHash -Tag $t
        $e = [ordered]@{ name = $h.name }
        if ($h.description) { $e.description = $h.description }
        if ($h.notes)       { $e.notes       = $h.notes }
        if ([bool]$h.isRecordLabel) { $e.isRecordLabel = $true }
        if ([bool]$h.regulatory)    { $e.regulatory    = $true }
        if ($null -ne $h.retentionDuration) { $e.retentionDuration = $h.retentionDuration }
        if ($h.retentionAction)             { $e.retentionAction   = $h.retentionAction }
        if ($h.retentionType)               { $e.retentionType     = $h.retentionType }
        if (@($h.reviewerEmail).Count -gt 0) { $e.reviewerEmail    = $h.reviewerEmail }
        if ($h.filePlanProperty.Count -gt 0) {
            $sub = [ordered]@{}
            foreach ($k in @('authority','category','subCategory','citation','department','referenceId')) {
                if ($h.filePlanProperty.ContainsKey($k)) { $sub[$k] = $h.filePlanProperty[$k] }
            }
            $e.filePlanProperty = $sub
        }
        $labels += $e
    }

    $doc = [ordered]@{
        filePlanProperties = $fp
        retentionLabels    = $labels
    }
    $body = ConvertTo-Yaml $doc
    $nl   = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} retention labels and tenant file plan properties to '{1}'." -f $labels.Count, $Path) -InformationAction Continue
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

# In-repo ADR 0029 direction-policy decision helper. Shared with the
# sibling Deploy-*.ps1 reconcilers (Deploy-Labels.ps1,
# Deploy-LabelPolicies.ps1, Deploy-DLPPolicies.ps1,
# Deploy-RetentionPolicies.ps1, ...). The module is pure and
# unit-tested independently; do not re-inline the decision logic
# here.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the prune and repo-wins overwrite branches
# cannot be entered unattended from a local terminal. This script has NO
# workflow caller, so the local terminal is the only way it ever runs and
# this gate is the only gate it has.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo -PruneMissing safety guard (issue #13): the empty-desired-set
# refusal, which prevents a prune against a zero-entry desired state from
# classifying every live tenant object as an orphan. Shared with the other
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
foreach ($key in @('resources','automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile); return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'." -f $ParametersFile); return
}
if (-not $parameters.automation.ContainsKey('apps') -or -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'." -f $ParametersFile); return
}
foreach ($key in @('displayName','certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key); return
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Mode            : {0}" -f $mode)                    -InformationAction Continue
Write-Information ("Parameters file : {0}" -f $ParametersFile)          -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName)               -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName)         -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain)            -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path)                    -InformationAction Continue
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy)         -InformationAction Continue

#endregion

#region ADR 0035 seed-skip baseline

# The 31 Microsoft File Plan Manager seed property objects are undeletable on
# the documented IPPS surface -- every Remove-FilePlanProperty* call against
# them fails with ErrorRuleNotFoundException (ADR 0035 "Context"; issue #582).
# A -PruneMissing run that does not skip them produces 31 Failed plan rows,
# not 31 deletions. ADR 0035 Decision #3 mandates a baseline skip list.
#
# That baseline used to be the `skip_names_records` workflow_dispatch input
# default of .github/workflows/deploy-data-plane.yml. ADR 0051 retired that
# workflow (PR #82), and this script has no other workflow caller -- the only
# way it runs is an operator at a local terminal. The mandated baseline was
# therefore left with nowhere executable to live. ADR 0052 relocates it to a
# checked-in data file that the reconciler reads by default on EVERY run,
# including the local run that is now the only run there is.
#
# The baseline is UNIONed into the effective skip list. Operators may EXTEND
# it via -SkipNames; they cannot SHRINK it from the command line. Shrinking it
# means editing the data file in a reviewed PR -- exactly what ADR 0035
# Decision #3 requires ("may extend ... should not shrink it without
# superseding this ADR") and what ADR 0035 "Consequences" promised ("a future
# revert is a single-PR change").
# Reference: docs/adr/0035-records-seed-content-immovable.md
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
$seedSkipPath = Join-Path $scriptRoot '..\data-plane\records\seed-skip-names.yaml'
if (-not (Test-Path -LiteralPath $seedSkipPath)) {
    Write-Error ("ADR 0035 seed-skip baseline not found at '{0}'. This file is the mandated prune-safety baseline; restore it from source control before running a reconcile." -f $seedSkipPath)
    return
}
$seedSkipRoot = Get-Content -LiteralPath $seedSkipPath -Raw | ConvertFrom-Yaml
$seedSkipNames = @($seedSkipRoot.seedSkipNames)
if ($seedSkipNames.Count -eq 0) {
    Write-Error ("ADR 0035 seed-skip baseline at '{0}' declares no names under 'seedSkipNames:'. Refusing to run with an empty safety baseline." -f $seedSkipPath)
    return
}

# Union, case-insensitively, preserving the caller's names first.
$effectiveSkipNames = [System.Collections.Generic.List[string]]::new()
foreach ($n in @($SkipNames)) {
    if (-not [string]::IsNullOrWhiteSpace($n) -and -not ($effectiveSkipNames | Where-Object { $_ -ieq $n })) {
        $effectiveSkipNames.Add([string]$n)
    }
}
foreach ($n in $seedSkipNames) {
    if (-not [string]::IsNullOrWhiteSpace($n) -and -not ($effectiveSkipNames | Where-Object { $_ -ieq $n })) {
        $effectiveSkipNames.Add([string]$n)
    }
}
$SkipNames = @($effectiveSkipNames)
Write-Information ("Skip list       : {0} name(s) ({1} from the ADR 0035 seed baseline at {2})." -f $SkipNames.Count, $seedSkipNames.Count, (Split-Path -Leaf $seedSkipPath)) -InformationAction Continue

#endregion

#region Desired-state load

$desiredPropertiesByKind = @{}
foreach ($kind in $script:PropertyKinds) { $desiredPropertiesByKind[$kind.Yaml] = @() }
$desiredLabels = @()

if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path); return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

    # Schema validation (JSON Schema Draft-07).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    if (-not $SkipSchemaValidation.IsPresent) {
        $schemaPath = Join-Path $scriptRoot '..\data-plane\records\file-plan.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath)) {
            Write-Error ("Schema file not found at '{0}'." -f $schemaPath); return
        }
        $schemaText = Get-Content -LiteralPath $schemaPath -Raw
        $docJson    = $desiredRoot | ConvertTo-Json -Depth 10
        try {
            $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
        } catch {
            Write-Error ("Desired-state YAML failed schema validation: {0}" -f $_.Exception.Message); return
        }
        Write-Information ("Schema OK       : {0}" -f $schemaPath) -InformationAction Continue
    }

    if ($desiredRoot -and $desiredRoot.ContainsKey('filePlanProperties') -and $desiredRoot.filePlanProperties) {
        foreach ($kind in $script:PropertyKinds) {
            if ($desiredRoot.filePlanProperties.ContainsKey($kind.Yaml) -and $desiredRoot.filePlanProperties[$kind.Yaml]) {
                $desiredPropertiesByKind[$kind.Yaml] = @(
                    $desiredRoot.filePlanProperties[$kind.Yaml] | ForEach-Object {
                        ConvertTo-DesiredPropertyHash -Entry ([hashtable]$_) -Display $kind.Display
                    }
                )
            }
        }
    }
    if ($desiredRoot -and $desiredRoot.ContainsKey('retentionLabels') -and $desiredRoot.retentionLabels) {
        $desiredLabels = @($desiredRoot.retentionLabels | ForEach-Object { ConvertTo-DesiredLabelHash -Entry ([hashtable]$_) })
    }

    # Referential validation (cheap pre-flight; surfaces typos before connect).
    $catNames = @($desiredPropertiesByKind['categories'] | ForEach-Object { $_.name })
    foreach ($sc in $desiredPropertiesByKind['subCategories']) {
        if (-not [string]::IsNullOrEmpty($sc.parentCategory) -and ($catNames -notcontains $sc.parentCategory)) {
            Write-Error ("SubCategory '{0}' references parentCategory '{1}', which is not declared under filePlanProperties.categories." -f $sc.name, $sc.parentCategory); return
        }
    }

    $desiredCounts = ($script:PropertyKinds | ForEach-Object { "{0}={1}" -f $_.Yaml, @($desiredPropertiesByKind[$_.Yaml]).Count }) -join ', '
    Write-Information ("Desired props   : {0}" -f $desiredCounts) -InformationAction Continue
    Write-Information ("Desired labels  : {0}" -f $desiredLabels.Count) -InformationAction Continue

    # Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
    #
    # This reconciler manages several collections -- one file plan property
    # collection per kind in $script:PropertyKinds (categories, subCategories,
    # citations, departments, authorities) plus retentionLabels -- so the guard
    # is keyed on their TOTAL. A prune is only catastrophic when NOTHING at all
    # is declared; a file that legitimately declares labels but no properties
    # (or only some property kinds) must still be prunable.
    #
    # With a zero total, every live file plan property and retention label falls
    # out of the orphan match below and the run would delete the whole set. The
    # rationale, the likely causes, and the 2026-07-19 production hit are
    # documented in scripts/modules/PruneGuard.psm1.
    #
    # This whole block is Apply-only, so reaching it already implies Apply mode.
    # Placed in the desired-state load region so it fires before the tenant is
    # contacted at all -- before `az account show`, before Connect-IPPSSession,
    # and before any write phase.
    if ($PruneMissing.IsPresent) {
        $desiredTotal = $desiredLabels.Count
        foreach ($kind in $script:PropertyKinds) {
            $desiredTotal += @($desiredPropertiesByKind[$kind.Yaml]).Count
        }
        Assert-PruneDesiredSetNotEmpty `
            -DesiredCount   $desiredTotal `
            -ObjectTypeNoun 'file plan property or retention label' `
            -SourcePath     $Path `
            -CollectionKey  'filePlanProperties/retentionLabels'
    }
}

#endregion

#region Azure context (read-only preamble)

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'; return
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) { Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'; return }
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region Resolve data-plane app + acquire access token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error ("az ad app list failed with exit code {0}." -f $LASTEXITCODE); return }
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) { Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName); return }
if ($appList.Count -gt 1) { Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name." -f $appList.Count, $DataPlaneAppDisplayName); return }
$appId = [string]$appList[0].appId

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) { Write-Error ("Helper not found: '{0}'." -f $tokenScript); return }
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId
if (-not $tok -or -not $tok.AccessToken) { Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'; return }
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion


#region Connect, enumerate, plan, apply

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Enumerate tenant file plan properties (one Get-* call per kind).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-fileplanpropertyauthority
    $tenantPropertiesByKind = @{}
    foreach ($kind in $script:PropertyKinds) {
        $getCmd = "Get-{0}" -f $kind.Cmdlet
        try {
            $tenantPropertiesByKind[$kind.Yaml] = @(& $getCmd -ErrorAction Stop)
        } catch {
            Write-Error ("{0} failed: {1}" -f $getCmd, $_.Exception.Message); return
        }
    }
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
    $tenantTags = @(Get-ComplianceTag -ErrorAction Stop)

    $tenantCounts = ($script:PropertyKinds | ForEach-Object { "{0}={1}" -f $_.Yaml, @($tenantPropertiesByKind[$_.Yaml]).Count }) -join ', '
    Write-Information ("Tenant props    : {0}" -f $tenantCounts) -InformationAction Continue
    Write-Information ("Tenant labels   : {0}" -f $tenantTags.Count) -InformationAction Continue

    if ($mode -eq 'Export') {
        Invoke-FilePlanExport `
            -Path                    $Path `
            -TenantPropertiesByKind  $tenantPropertiesByKind `
            -TenantTags              $tenantTags `
            -Force:$Force.IsPresent
        return
    }

    # ---- Property-level plan ----------------------------------------------
    # Index tenant properties by (kind, name).
    $tenantPropertyHashes = @{}
    foreach ($kind in $script:PropertyKinds) {
        $tenantPropertyHashes[$kind.Yaml] = @{}
        foreach ($o in $tenantPropertiesByKind[$kind.Yaml]) {
            $h = ConvertTo-TenantPropertyHash -Obj $o -Display $kind.Display
            $tenantPropertyHashes[$kind.Yaml][$h.name] = $h
        }
    }

    $propertyPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($kind in $script:PropertyKinds) {
        $desiredNames = @($desiredPropertiesByKind[$kind.Yaml] | ForEach-Object { $_.name })
        foreach ($d in $desiredPropertiesByKind[$kind.Yaml]) {
            if ($tenantPropertyHashes[$kind.Yaml].ContainsKey($d.name)) {
                $diffs = Compare-PropertyField -Desired $d -Tenant $tenantPropertyHashes[$kind.Yaml][$d.name]
                if ($diffs.Count -eq 0) {
                    $propertyPlan.Add([pscustomobject]@{ Action='NoChange'; Kind=$kind; Name=$d.name; Desired=$d; Reason='In sync with tenant.' })
                } else {
                    # No Set-FilePlanProperty* cmdlet exists -> warn only.
                    $propertyPlan.Add([pscustomobject]@{ Action='DriftWarn'; Kind=$kind; Name=$d.name; Desired=$d; Reason=("Tenant metadata differs ({0}) but no Set-* cmdlet exists; remove and recreate manually after detaching dependent labels." -f ($diffs -join ', ')) })
                }
            } else {
                $propertyPlan.Add([pscustomobject]@{ Action='Create'; Kind=$kind; Name=$d.name; Desired=$d; Reason='Declared in YAML; absent from tenant.' })
            }
        }
        foreach ($name in $tenantPropertyHashes[$kind.Yaml].Keys) {
            if ($desiredNames -notcontains $name) {
                $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
                $propertyPlan.Add([pscustomobject]@{ Action='Orphan'; Kind=$kind; Name=$name; Desired=$null; Reason=$reason })
            }
        }
    }

    # ---- ADR 0029: audit-mode short-circuit + property-side SkipNames ----
    # `-DirectionPolicy audit` flips $WhatIfPreference for the rest of
    # this script so every $PSCmdlet.ShouldProcess(...) call below
    # returns false and falls into its existing "Would ..." else
    # branch. No New-/Set-/Remove- cmdlet writes against the tenant
    # under any circumstance, while the categorized plan-with-would-
    # rows is preserved end-to-end. The AUDIT marker line is the
    # operator-visible signal that no writes would have fired.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
        $WhatIfPreference = $true
    }

    # ADR 0029 SkipNames pre-pass on the property plan. File plan
    # property objects have no Set-* cmdlet (drift becomes DriftWarn,
    # never Update), so the only direction-policy decision that
    # applies to properties is the SkipList match. Walk every row
    # whose Name appears in -SkipNames (case-insensitive) and mutate
    # it to Skip. Records the skip in $script:Adr0029Skips so the
    # post-label-plan pass below can emit all [ADR0029-SKIP] markers
    # together. The seed-name baseline shipped by the workflow per
    # ADR 0035 lands here for every Microsoft File Plan Manager seed
    # the tenant reports as Orphan. Reference:
    # docs/adr/0029-source-of-truth-direction-policy.md
    # docs/adr/0035-records-seed-content-immovable.md
    $script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'
    if ($DirectionPolicy -ne 'audit') {
        foreach ($row in $propertyPlan) {
            if ($row.Action -notin @('Create','NoChange','DriftWarn','Orphan')) { continue }
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName ([string]$row.Name) `
                -HasDrift    $false
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $script:Adr0029Skips.Add([pscustomobject]@{
                    Kind        = $row.Kind.Display
                    DisplayName = [string]$row.Name
                    Reason      = $decision.Reason
                })
            }
        }
    }

    # Apply property Create / NoChange / DriftWarn before labels reference them.
    # Order within Create: categories before subCategories (subCategory parent must exist).
    $createOrder = @('authorities','categories','citations','departments','referenceIds','subCategories')
    foreach ($yamlBucket in $createOrder) {
        $kind = $script:PropertyKinds | Where-Object { $_.Yaml -eq $yamlBucket }
        foreach ($row in ($propertyPlan | Where-Object { $_.Kind.Yaml -eq $yamlBucket -and $_.Action -in @('Create','NoChange','DriftWarn','Skip') })) {
            $target = "File plan {0} '{1}'" -f $kind.Display, $row.Name
            switch ($row.Action) {
                'Create' {
                    $splat  = Get-PropertyCreateSplat -Hash $row.Desired
                    $newCmd = "New-{0}" -f $kind.Cmdlet
                    $opDesc = "{0}" -f $newCmd
                    if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                        try {
                            & $newCmd @splat -ErrorAction Stop | Out-Null
                            $report.Add([pscustomobject]@{ Category='Create'; Kind=$kind.Display; Name=$row.Name; Reason=$row.Reason }) | Out-Null
                        } catch {
                            $report.Add([pscustomobject]@{ Category='Failed'; Kind=$kind.Display; Name=$row.Name; Reason=("{0} failed: {1}" -f $newCmd, $_.Exception.Message) }) | Out-Null
                        }
                    } else {
                        $report.Add([pscustomobject]@{ Category='WhatIf'; Kind=$kind.Display; Name=$row.Name; Reason=("Would create: {0}" -f $opDesc) }) | Out-Null
                    }
                }
                'NoChange'  { $report.Add([pscustomobject]@{ Category='NoChange';  Kind=$kind.Display; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
                'DriftWarn' { $report.Add([pscustomobject]@{ Category='DriftWarn'; Kind=$kind.Display; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
                'Skip'      { $report.Add([pscustomobject]@{ Category='Skipped';   Kind=$kind.Display; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
            }
        }
    }

    # ---- Label-level plan -------------------------------------------------
    $tenantTagHashes = @{}
    foreach ($t in $tenantTags) {
        $h = ConvertTo-TenantLabelHash -Tag $t
        $tenantTagHashes[$h.name] = $h
    }
    $desiredLabelNames = @($desiredLabels | ForEach-Object { $_.name })

    $labelPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredLabels) {
        if ($tenantTagHashes.ContainsKey($d.name)) {
            $cmp = Compare-RetentionLabel -Desired $d -Tenant $tenantTagHashes[$d.name]
            if ($cmp.Mutable.Count -eq 0 -and $cmp.Immutable.Count -eq 0) {
                $labelPlan.Add([pscustomobject]@{ Action='NoChange'; Name=$d.name; Desired=$d; Reason='In sync with tenant.' })
            } elseif ($cmp.Immutable.Count -gt 0) {
                $labelPlan.Add([pscustomobject]@{ Action='DriftWarn'; Name=$d.name; Desired=$d; Reason=("Immutable drift on {0}; recreate manually after removing dependent retention label policies." -f ($cmp.Immutable -join ', ')) })
            } else {
                $labelPlan.Add([pscustomobject]@{ Action='Update'; Name=$d.name; Desired=$d; Reason=("Drift in: {0}" -f ($cmp.Mutable -join ', ')) })
            }
        } else {
            $labelPlan.Add([pscustomobject]@{ Action='Create'; Name=$d.name; Desired=$d; Reason='Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($name in $tenantTagHashes.Keys) {
        if ($desiredLabelNames -notcontains $name) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $labelPlan.Add([pscustomobject]@{ Action='Orphan'; Name=$name; Desired=$null; Reason=$reason })
        }
    }

    # ADR 0052: names of the retention labels a repo-wins run would overwrite.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    # ---- ADR 0029: direction-policy pass on the label plan --------------
    # Labels are the only file plan object kind with a documented
    # Set-* cmdlet, so portal-wins / repo-wins drift arbitration on
    # Update rows applies here. SkipNames mutation applies to every
    # row category (Create / Update / NoChange / DriftWarn / Orphan)
    # so the workflow can suppress noise on operator-named entries
    # regardless of category. Audit mode does not enter this pass --
    # the audit short-circuit above sets $WhatIfPreference so the
    # apply loop's ShouldProcess calls fall into the WhatIf branch.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -ne 'audit') {
        foreach ($row in $labelPlan) {
            if ($row.Action -notin @('Create','Update','NoChange','DriftWarn','Orphan')) { continue }
            $hasDrift = ($row.Action -eq 'Update')
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName ([string]$row.Name) `
                -HasDrift    $hasDrift
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $script:Adr0029Skips.Add([pscustomobject]@{
                    Kind        = 'Label'
                    DisplayName = [string]$row.Name
                    Reason      = $decision.Reason
                })
                continue
            }
            # decision.Action is 'Update' for non-Skip rows; the only
            # Write-Warning we owe here is the overwrite warning when we
            # are about to overwrite tenant drift.
            #
            # Keyed on the row surviving the policy as an Update -- the PLAN --
            # not on $DirectionPolicy. Whatever policy let this row through, it
            # IS going to be overwritten, so it belongs in the list the ADR 0052
            # gate names. See ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON
            # THE POLICY".
            if ($row.Action -eq 'Update') {
                $fieldsText = ($row.Reason -replace '^Drift in: ', '')
                Write-Warning ("Overwriting tenant on retention label '{0}' fields: {1}" -f $row.Name, $fieldsText)
                # ADR 0052: feed the destructive-operation confirmation gate below.
                $repoWinsOverwrites.Add([string]$row.Name)
            }
        }

        # Machine-readable marker per skipped object for the workflow's
        # auto-PR step. One line per skipped object so a simple
        # `grep '\[ADR0029-SKIP\]'` over the run log yields the full
        # skip list. Format must match the exact regex
        # `^\[ADR0029-SKIP\] (.+)$` per the github-actions
        # instructions rule, so we do not prefix the Kind here.
        foreach ($s in $script:Adr0029Skips) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # Placed before the label apply loop -- the first loop that can overwrite
    # (Set-ComplianceTag) or, further down, delete (Remove-ComplianceTag /
    # Remove-FilePlanProperty*). The property apply loop above only Creates,
    # so nothing destructive has run when this gate is reached.
    #
    # Both destructive branches are gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue
    # prompts unconditionally; ShouldProcess only prompts when
    # ConfirmImpact >= $ConfirmPreference, which is the comparison that
    # silently defeated this gate before issue #85.
    #
    # Both gates are keyed on the PLAN -- the set of objects this run will
    # actually overwrite or delete -- and never on $DirectionPolicy. See
    # ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
    #
    # The $yesToAll / $noToAll pair is shared by both gates, so a run that
    # trips the overwrite gate AND the prune gate prompts once, not twice,
    # and never once per object.
    #
    # Suppressed by -Force and by an explicit -Confirm:$false. Skipped under
    # -WhatIf (and therefore under -DirectionPolicy audit, which sets
    # $WhatIfPreference above) so a dry run previews the deletes without
    # blocking on input.
    #
    # The orphan count below counts only what -PruneMissing would ACTUALLY
    # try to delete. The 31 ADR 0035 seeds have already been mutated to Skip
    # rows by the seed-skip baseline, so they are not counted and not named:
    # the prompt names operator-authored objects, which are the objects that
    # actually delete.
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
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} shared retention label(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
            $repoWinsOverwrites.Count, (($repoWinsOverwrites | Sort-Object) -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
            throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    if ($PruneMissing.IsPresent) {
        $pruneTargets = @(
            @($labelPlan | Where-Object { $_.Action -eq 'Orphan' } | ForEach-Object { "Label '{0}'" -f $_.Name }) +
            @($propertyPlan | Where-Object { $_.Action -eq 'Orphan' } | ForEach-Object { "{0} '{1}'" -f $_.Kind.Display, $_.Name })
        )
        if ($pruneTargets.Count -gt 0) {
            $pruneQuery = "-PruneMissing will DELETE {0} orphan file plan object(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
                $pruneTargets.Count, (($pruneTargets | Sort-Object) -join ', ')
            if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
                throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
            }
        }
    }

    foreach ($row in ($labelPlan | Where-Object { $_.Action -in @('Create','Update','NoChange','DriftWarn','Skip') })) {
        $target = "Retention label '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $splat  = Get-ComplianceTagSplat -Hash $row.Desired
                $opDesc = 'New-ComplianceTag (isRecordLabel={0}, regulatory={1})' -f $row.Desired.isRecordLabel, $row.Desired.regulatory
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag
                        New-ComplianceTag @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category='Create'; Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category='Failed'; Kind='Label'; Name=$row.Name; Reason=("Create failed: {0}" -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category='WhatIf'; Kind='Label'; Name=$row.Name; Reason=("Would create: {0}" -f $opDesc) }) | Out-Null
                }
            }
            'Update' {
                $splat  = Get-ComplianceTagSplat -Hash $row.Desired -ForSet
                $opDesc = "Set-ComplianceTag ({0})" -f $row.Reason
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-compliancetag
                        Set-ComplianceTag @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category='Update'; Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category='Failed'; Kind='Label'; Name=$row.Name; Reason=("Update failed: {0}" -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category='WhatIf'; Kind='Label'; Name=$row.Name; Reason=("Would update: {0}" -f $row.Reason) }) | Out-Null
                }
            }
            'NoChange'  { $report.Add([pscustomobject]@{ Category='NoChange';  Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
            'DriftWarn' { $report.Add([pscustomobject]@{ Category='DriftWarn'; Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
            'Skip'      { $report.Add([pscustomobject]@{ Category='Skipped';   Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null }
        }
    }

    # ---- Prune (labels first, then properties; subCategories before categories) --
    $pruneFailures = New-Object 'System.Collections.Generic.List[string]'

    # Issue #13: in-loop prune failures keep their 'Failed' report row AND are
    # reported via Write-PruneFailure (scripts/modules/PruneGuard.psm1), which
    # uses Write-Warning plus an '::error::' workflow command rather than
    # Write-Error. Previously the catch added the row and moved on, so a
    # failed prune exited 0. The aggregate `throw` after the prune region --
    # inside this try, so the finally still disconnects -- is the terminal
    # outcome, so a failed prune now exits non-zero after every orphan has
    # been attempted. The issue #13 ratio guard (guard 2) is deliberately NOT
    # wired here: a file-plan teardown legitimately prunes a majority of the
    # property buckets (owner decision), so only guard 1 and this reporter
    # protect the prune path.
    if ($PruneMissing.IsPresent) {
        foreach ($row in ($labelPlan | Where-Object { $_.Action -eq 'Orphan' })) {
            $target = "Retention label '{0}'" -f $row.Name
            $opDesc = 'Remove-ComplianceTag'
            if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-compliancetag
                    Remove-ComplianceTag -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                    $report.Add([pscustomobject]@{ Category='Removed'; Kind='Label'; Name=$row.Name; Reason='Pruned tenant-only label.' }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category='Failed'; Kind='Label'; Name=$row.Name; Reason=("Remove failed: {0}" -f $_.Exception.Message) }) | Out-Null
                    Write-PruneFailure ("Remove-ComplianceTag '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
                    $pruneFailures.Add(("label '{0}'" -f $row.Name))
                    continue
                }
            } else {
                $report.Add([pscustomobject]@{ Category='WhatIf'; Kind='Label'; Name=$row.Name; Reason=("Would remove: {0}" -f $opDesc) }) | Out-Null
            }
        }

        $pruneOrder = @('subCategories','referenceIds','departments','citations','categories','authorities')
        foreach ($yamlBucket in $pruneOrder) {
            $kind = $script:PropertyKinds | Where-Object { $_.Yaml -eq $yamlBucket }
            foreach ($row in ($propertyPlan | Where-Object { $_.Kind.Yaml -eq $yamlBucket -and $_.Action -eq 'Orphan' })) {
                $target    = "File plan {0} '{1}'" -f $kind.Display, $row.Name
                $removeCmd = "Remove-{0}" -f $kind.Cmdlet
                $opDesc    = $removeCmd
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        & $removeCmd -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category='Removed'; Kind=$kind.Display; Name=$row.Name; Reason='Pruned tenant-only property.' }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category='Failed'; Kind=$kind.Display; Name=$row.Name; Reason=("{0} failed: {1}" -f $removeCmd, $_.Exception.Message) }) | Out-Null
                        Write-PruneFailure ("{0} '{1}' failed: {2}" -f $removeCmd, $row.Name, $_.Exception.Message)
                        $pruneFailures.Add(("{0} '{1}'" -f $kind.Display, $row.Name))
                        continue
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category='WhatIf'; Kind=$kind.Display; Name=$row.Name; Reason=("Would remove: {0}" -f $opDesc) }) | Out-Null
                }
            }
        }
    } else {
        foreach ($row in ($labelPlan | Where-Object { $_.Action -eq 'Orphan' })) {
            $report.Add([pscustomobject]@{ Category='Orphan'; Kind='Label'; Name=$row.Name; Reason=$row.Reason }) | Out-Null
        }
        foreach ($row in ($propertyPlan | Where-Object { $_.Action -eq 'Orphan' })) {
            $report.Add([pscustomobject]@{ Category='Orphan'; Kind=$row.Kind.Display; Name=$row.Name; Reason=$row.Reason }) | Out-Null
        }
    }

    if ($pruneFailures.Count -gt 0) {
        throw ("Reconciliation aborted: {0} orphan file plan object(s) could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
    }
}
finally {
    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
    }
}

# Emit the report.
$report

#endregion
