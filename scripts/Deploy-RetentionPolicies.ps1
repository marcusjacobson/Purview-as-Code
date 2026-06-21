#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Data Lifecycle Management (DLM) retention
    compliance policies and their nested rules against
    `data-plane/data-lifecycle/retention-policies.yaml` (desired state).

.DESCRIPTION
    Wave 2c.i declarative reconciler for Microsoft Purview retention
    compliance policies. The YAML is the central source of truth: any
    add / update / remove of a retention policy or one of its rules
    flows through this script, which converges the live tenant to
    match. Sibling of `scripts/Deploy-DLPPolicies.ps1` (same auth
    path, same drift vocabulary, same export contract).

    The script connects to Security & Compliance PowerShell via the
    lab automation identity (Key Vault-signed JWT, see ADR 0011),
    reads the desired-state YAML, schema-validates it, enumerates
    tenant policies via `Get-RetentionCompliancePolicy` and rules via
    `Get-RetentionComplianceRule`, diffs each tracked field, and
    applies the categorized plan under `ShouldProcess` (`-WhatIf` /
    `-Confirm`). `-PruneMissing` enables removal of tenant policies
    and rules absent from the YAML. `-ExportCurrentState` round-trips
    the live tenant back into the YAML's `policies:` block.

    Drift contract (per `.github/instructions/powershell.instructions.md`
    "Drift report format"):

      1. GET every policy via `Get-RetentionCompliancePolicy` and every
         rule via `Get-RetentionComplianceRule`.
      2. Match desired vs. tenant by `Name` (policy) and by
         (policy name, rule name) for rules.
      3. Diff each desired entry against the tenant copy.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    Preservation Lock (`restrictiveRetention = $true`) is irreversible
    once applied. Treat the first apply that sets it as a destructive
    change: it requires the `destructive` PR label per the pre-commit
    checklist.

    References (Microsoft Learn):
      Microsoft Purview Data Lifecycle Management overview:
        https://learn.microsoft.com/en-us/purview/data-lifecycle-management
      Learn about retention policies:
        https://learn.microsoft.com/en-us/purview/retention
      Get-RetentionCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy
      New-RetentionCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy
      Set-RetentionCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy
      Remove-RetentionCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancepolicy
      Get-RetentionComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule
      New-RetentionComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule
      Set-RetentionComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancerule
      Remove-RetentionComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancerule
      Preservation Lock for retention policies:
        https://learn.microsoft.com/en-us/purview/retention-preservation-lock
      Connect-IPPSSession (S&C PowerShell):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
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
    `data-plane/data-lifecycle/retention-policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant retention policies and rules that are not
    declared in the YAML. Default $false.

.PARAMETER Force
    With -ExportCurrentState: allow overwriting a `policies:` block that
    already contains entries.

.PARAMETER ExportCurrentState
    Read every retention policy + its rules visible to the connected
    app, write to the YAML's `policies:` block, and exit. Makes no
    writes to the tenant.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER VaultName
    Key Vault that holds the automation certificate.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010).

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit.
                         No New-/Set-/Remove-RetentionCompliancePolicy
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
                         The typed-confirmation gate
                         ('overwrite portal') is a CI-layer concern
                         enforced by the workflow per ADR 0029; local
                         script callers are operator-trusted.
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
    workflow). The match is case-insensitive and tests against the
    policy `Name` (for policy-level entries) and the rule `Name`
    (for rule-level entries); composite `Policy\Rule` keys are NOT
    matched. Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Deploy-RetentionPolicies.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply would
    do; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-RetentionPolicies.ps1

    Reconcile the tenant against the YAML. Without -PruneMissing,
    tenant-only policies and rules are reported as Orphan and skipped.

.EXAMPLE
    ./scripts/Deploy-RetentionPolicies.ps1 -PruneMissing -WhatIf

    Show every Create / Update / Remove the reconciler would perform.

.EXAMPLE
    ./scripts/Deploy-RetentionPolicies.ps1 -ExportCurrentState

    Round-trip the live tenant's retention policies back into the
    YAML's `policies:` block.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` assigned at
        directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or
    a file. No credential material is printed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\data-lifecycle\retention-policies.yaml'),

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

$script:LocationBuckets = @(
    @{ Bucket = 'exchange';            Param = 'ExchangeLocation' },
    @{ Bucket = 'sharePoint';          Param = 'SharePointLocation' },
    @{ Bucket = 'oneDrive';            Param = 'OneDriveLocation' },
    @{ Bucket = 'modernGroup';         Param = 'ModernGroupLocation' },
    @{ Bucket = 'skype';               Param = 'SkypeLocation' },
    @{ Bucket = 'teamsChannel';        Param = 'TeamsChannelLocation' },
    @{ Bucket = 'teamsChat';           Param = 'TeamsChatLocation' },
    @{ Bucket = 'teamsPrivateChannel'; Param = 'TeamsPrivateChannelLocation' },
    @{ Bucket = 'publicFolder';        Param = 'PublicFolderLocation' }
)
$script:LocationBucketNames = @($script:LocationBuckets | ForEach-Object { $_.Bucket })


#region Helpers

function ConvertTo-DesiredRetentionPolicyHash {
    # Normalize a desired-state policy entry from the YAML into a
    # comparable hashtable. Reference: ./retention-policies.schema.json.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $locations = @{}
    foreach ($b in $script:LocationBucketNames) { $locations[$b] = @() }
    if ($Entry.ContainsKey('locations') -and $Entry.locations) {
        foreach ($bucket in $script:LocationBucketNames) {
            if ($Entry.locations.ContainsKey($bucket)) {
                $val = $Entry.locations[$bucket]
                if ($val -is [string] -and $val -eq 'All') {
                    $locations[$bucket] = @('All')
                } elseif ($val) {
                    $locations[$bucket] = @($val | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                }
            }
        }
    }

    $rules = @()
    if ($Entry.ContainsKey('rules') -and $Entry.rules) {
        $rules = @($Entry.rules | ForEach-Object { ConvertTo-DesiredRetentionRuleHash -Entry ([hashtable]$_) })
    }

    return @{
        name                 = [string]$Entry.name
        description          = if ($Entry.ContainsKey('description'))          { [string]$Entry.description } else { $null }
        enabled              = if ($Entry.ContainsKey('enabled'))              { [bool]$Entry.enabled }     else { $true }
        restrictiveRetention = if ($Entry.ContainsKey('restrictiveRetention')) { [bool]$Entry.restrictiveRetention } else { $false }
        locations            = $locations
        rules                = $rules
    }
}

function ConvertTo-DesiredRetentionRuleHash {
    # Normalize a desired-state rule entry into a comparable hashtable.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    return @{
        name                 = [string]$Entry.name
        description          = if ($Entry.ContainsKey('description'))          { [string]$Entry.description } else { $null }
        retentionDuration    = $Entry.retentionDuration   # 'Unlimited' or [int]
        retentionAction      = [string]$Entry.retentionAction
        expirationDateOption = if ($Entry.ContainsKey('expirationDateOption')) { [string]$Entry.expirationDateOption } else { $null }
        contentMatchQuery    = if ($Entry.ContainsKey('contentMatchQuery'))    { [string]$Entry.contentMatchQuery }    else { $null }
    }
}

function ConvertTo-TenantRetentionPolicyHash {
    # Normalize Get-RetentionCompliancePolicy result into the same
    # shape as the desired hash (rules are merged in by the caller).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy
    param([Parameter(Mandatory = $true)]$Policy)

    $loc = @{}
    foreach ($b in $script:LocationBucketNames) { $loc[$b] = @() }
    foreach ($pair in $script:LocationBuckets) {
        $raw = $Policy.($pair.Param)
        if (-not $raw) { continue }
        $items = @($raw | ForEach-Object { Get-RetentionLocationIdentity -Item $_ } |
            Where-Object { $_ } | Sort-Object -Unique)
        if ($items.Count -eq 1 -and $items[0] -eq 'All') {
            $loc[$pair.Bucket] = @('All')
        } else {
            $loc[$pair.Bucket] = $items
        }
    }

    return @{
        name                 = [string]$Policy.Name
        description          = if ($Policy.Comment) { [string]$Policy.Comment } else { $null }
        enabled              = if ($null -ne $Policy.Enabled) { [bool]$Policy.Enabled } else { $true }
        restrictiveRetention = if ($null -ne $Policy.RestrictiveRetention) { [bool]$Policy.RestrictiveRetention } else { $false }
        locations            = $loc
        rules                = @()
    }
}

function Get-RetentionLocationIdentity {
    # Extract the round-trippable identity string from a single
    # Get-RetentionCompliancePolicy *Location entry. The IPPS cmdlets
    # normalize the SMTP / UPN we POST (e.g. via -ExchangeLocation) to a
    # recipient object whose .Name carries the DisplayName, not the
    # SMTP. To keep YAML <-> tenant comparisons stable we prefer the
    # SMTP / UPN-shaped fields documented on the recipient pipeline
    # (PrimarySmtpAddress, WindowsLiveID, UserPrincipalName, Address)
    # and SharePoint-shaped fields (Url, SitePath) before falling back
    # to .Name. The 'All' sentinel is preserved verbatim. String inputs
    # are returned as-is.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy
    param([Parameter(Mandatory = $true)][AllowNull()]$Item)

    if ($null -eq $Item) { return $null }
    if ($Item -is [string]) { return $Item }
    foreach ($field in @('PrimarySmtpAddress','WindowsLiveID','UserPrincipalName','Address','Url','SitePath')) {
        $val = $Item.$field
        if ($val) { return [string]$val }
    }
    if ($Item.Name) { return [string]$Item.Name }
    return [string]$Item
}

function ConvertTo-TenantRetentionRuleHash {
    # Normalize a Get-RetentionComplianceRule entry into the desired shape.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule
    param([Parameter(Mandatory = $true)]$Rule)

    $duration = $null
    if ($null -ne $Rule.RetentionDuration) {
        $raw = [string]$Rule.RetentionDuration
        if ($raw -eq 'Unlimited') {
            $duration = 'Unlimited'
        } elseif ($raw -match '^\d+$') {
            $duration = [int]$raw
        } else {
            $duration = $raw
        }
    }

    return @{
        name                 = [string]$Rule.Name
        description          = if ($Rule.Comment) { [string]$Rule.Comment } else { $null }
        retentionDuration    = $duration
        retentionAction      = [string]$Rule.RetentionComplianceAction
        expirationDateOption = if ($Rule.ExpirationDateOption) { [string]$Rule.ExpirationDateOption } else { $null }
        contentMatchQuery    = if ($Rule.ContentMatchQuery)    { [string]$Rule.ContentMatchQuery }    else { $null }
        policyName           = [string]$Rule.Policy
    }
}

function Resolve-TenantRulePolicyName {
    # Translate the .Policy value returned by Get-RetentionComplianceRule
    # to the parent policy's friendly Name as exposed by
    # Get-RetentionCompliancePolicy. The IPPS cmdlet build can return
    # .Policy as the friendly Name, Identity, Guid, or DistinguishedName;
    # the rule key used by the reconciler must always be the friendly
    # Name so it can be compared against the YAML's policy.name. Returns
    # the original $RulePolicy string when no match is found (defensive
    # -- preserves prior key shape for genuinely orphan rules whose
    # parent policy is not in the $TenantPolicies snapshot).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RulePolicy,
        [Parameter(Mandatory = $true)][AllowNull()]$TenantPolicies
    )
    if ([string]::IsNullOrEmpty($RulePolicy)) { return $RulePolicy }
    if (-not $TenantPolicies) { return $RulePolicy }
    foreach ($p in @($TenantPolicies)) {
        if ($null -eq $p) { continue }
        foreach ($field in @('Name','Identity','Guid','DistinguishedName','ExchangeObjectId','ImmutableId')) {
            $val = $p.$field
            if ($null -ne $val -and ([string]$val) -eq $RulePolicy) {
                return [string]$p.Name
            }
        }
    }
    return $RulePolicy
}

function Compare-RetentionPolicy {
    # Return a list of field names that differ between desired and
    # tenant policy hashes. `enabled` and `restrictiveRetention` are
    # always compared. `description` and per-bucket `locations` are
    # compared only when declared on the desired side.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    if ([bool]$Desired.enabled -ne [bool]$Tenant.enabled) {
        $diffs.Add('enabled') | Out-Null
    }

    if ([bool]$Desired.restrictiveRetention -ne [bool]$Tenant.restrictiveRetention) {
        $diffs.Add('restrictiveRetention') | Out-Null
    }

    foreach ($bucket in $script:LocationBucketNames) {
        $d = @($Desired.locations[$bucket] | Sort-Object -Unique)
        if ($d.Count -eq 0) { continue }
        $t = @($Tenant.locations[$bucket]  | Sort-Object -Unique)
        $delta = Compare-Object -ReferenceObject $t -DifferenceObject $d
        if ($delta) { $diffs.Add(("locations.{0}" -f $bucket)) | Out-Null }
    }

    return $diffs
}

function Compare-RetentionRule {
    # Return a list of field names that differ between desired and
    # tenant rule hashes. `retentionDuration` and `retentionAction`
    # are always compared. Other fields are compared only when
    # declared on the desired side.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    $dDur = $Desired.retentionDuration
    $tDur = $Tenant.retentionDuration
    if ($dDur -is [int] -and $tDur -is [int]) {
        if ([int]$dDur -ne [int]$tDur) { $diffs.Add('retentionDuration') | Out-Null }
    } elseif ([string]$dDur -ne [string]$tDur) {
        $diffs.Add('retentionDuration') | Out-Null
    }

    if ([string]$Desired.retentionAction -ne [string]$Tenant.retentionAction) {
        $diffs.Add('retentionAction') | Out-Null
    }

    if (-not [string]::IsNullOrEmpty($Desired.expirationDateOption)) {
        if ([string]$Desired.expirationDateOption -ne [string]$Tenant.expirationDateOption) {
            $diffs.Add('expirationDateOption') | Out-Null
        }
    }

    if (-not [string]::IsNullOrEmpty($Desired.contentMatchQuery)) {
        if ([string]$Desired.contentMatchQuery -ne [string]$Tenant.contentMatchQuery) {
            $diffs.Add('contentMatchQuery') | Out-Null
        }
    }

    return $diffs
}

function Get-RetentionPolicySplat {
    # Build a splattable hashtable for New- or Set-RetentionCompliancePolicy.
    # New- expects -Name; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [switch]$ForSet
    )

    $splat = @{}
    if ($ForSet.IsPresent) { $splat.Identity = $Hash.name } else { $splat.Name = $Hash.name }
    if (-not [string]::IsNullOrEmpty($Hash.description)) { $splat.Comment = $Hash.description }
    $splat.Enabled = [bool]$Hash.enabled
    if ([bool]$Hash.restrictiveRetention) { $splat.RestrictiveRetention = $true }

    foreach ($pair in $script:LocationBuckets) {
        $vals = @($Hash.locations[$pair.Bucket])
        if ($vals.Count -gt 0) {
            $splat[$pair.Param] = [string[]]$vals
        }
    }

    return $splat
}

function Get-RetentionRuleSplat {
    # Build a splattable hashtable for New- or Set-RetentionComplianceRule.
    # New- expects -Name + -Policy; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancerule
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [Parameter()][string]$PolicyName,
        [switch]$ForSet
    )

    $splat = @{}
    if ($ForSet.IsPresent) {
        $splat.Identity = ('{0}\{1}' -f $PolicyName, $Hash.name)
    } else {
        $splat.Name   = $Hash.name
        $splat.Policy = $PolicyName
    }
    if (-not [string]::IsNullOrEmpty($Hash.description))          { $splat.Comment              = $Hash.description }
    if ($null -ne $Hash.retentionDuration)                        { $splat.RetentionDuration    = $Hash.retentionDuration }
    if (-not [string]::IsNullOrEmpty($Hash.retentionAction))      { $splat.RetentionComplianceAction = $Hash.retentionAction }
    if (-not [string]::IsNullOrEmpty($Hash.expirationDateOption)) { $splat.ExpirationDateOption = $Hash.expirationDateOption }
    if (-not [string]::IsNullOrEmpty($Hash.contentMatchQuery))    { $splat.ContentMatchQuery    = $Hash.contentMatchQuery }

    return $splat
}

function Invoke-RetentionExport {
    # Round-trip tenant policies + rules back into the YAML's
    # `policies:` block.
    #
    # Round-trip stability is best-effort by design. The rules: block
    # under each policy is contractual (operators rely on
    # -ExportCurrentState -Force as a "snapshot tenant -> commit YAML"
    # loop and must not silently lose rule entries). String quoting
    # and indentation, however, are cosmetic: powershell-yaml's
    # ConvertTo-Yaml emits 2-space indent and unquoted scalars by
    # default and does not expose user-facing knobs to force 4-space
    # / single-quote output. Files authored by hand at 4-space +
    # single-quote will be reformatted by export; the resulting YAML
    # still parses to the same in-memory shape and the reconciler
    # still reports NoChange on the next -WhatIf.
    # Reference: https://github.com/cloudbase/powershell-yaml
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantPolicies,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantRules,
        [switch]$Force
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
        if ($existing -and $existing.ContainsKey('policies') -and $existing.policies -and @($existing.policies).Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("Target YAML '{0}' already declares {1} policy entries. Re-run with -Force to overwrite." -f $Path, @($existing.policies).Count)
            return
        }
    }

    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') {
                $headerLines += $line
            } else {
                break
            }
        }
    }

    $rulesByPolicy = @{}
    foreach ($r in $TenantRules) {
        $pn = Resolve-TenantRulePolicyName -RulePolicy ([string]$r.Policy) -TenantPolicies $TenantPolicies
        if (-not $rulesByPolicy.ContainsKey($pn)) { $rulesByPolicy[$pn] = @() }
        $rulesByPolicy[$pn] += $r
    }

    $exported = @()
    foreach ($t in $TenantPolicies) {
        $entry = [ordered]@{ name = [string]$t.Name }
        if ($t.Comment)                            { $entry.description          = [string]$t.Comment }
        if ($null -ne $t.Enabled)                  { $entry.enabled              = [bool]$t.Enabled }
        if ([bool]$t.RestrictiveRetention)         { $entry.restrictiveRetention = $true }

        $loc = [ordered]@{}
        foreach ($pair in $script:LocationBuckets) {
            $raw = $t.($pair.Param)
            if (-not $raw) { continue }
            $items = @($raw | ForEach-Object { Get-RetentionLocationIdentity -Item $_ } |
                Where-Object { $_ } | Sort-Object -Unique)
            if ($items.Count -eq 1 -and $items[0] -eq 'All') {
                $loc[$pair.Bucket] = 'All'
            } elseif ($items.Count -gt 0) {
                $loc[$pair.Bucket] = $items
            }
        }
        if ($loc.Count -gt 0) { $entry.locations = $loc }

        $ruleEntries = @()
        if ($rulesByPolicy.ContainsKey([string]$t.Name)) {
            foreach ($r in $rulesByPolicy[[string]$t.Name]) {
                $re = [ordered]@{ name = [string]$r.Name }
                if ($r.Comment)                                { $re.description          = [string]$r.Comment }
                if ($null -ne $r.RetentionDuration) {
                    $raw = [string]$r.RetentionDuration
                    if ($raw -eq 'Unlimited')   { $re.retentionDuration = 'Unlimited' }
                    elseif ($raw -match '^\d+$') { $re.retentionDuration = [int]$raw }
                    else                         { $re.retentionDuration = $raw }
                }
                if ($r.RetentionComplianceAction)              { $re.retentionAction      = [string]$r.RetentionComplianceAction }
                if ($r.ExpirationDateOption)                   { $re.expirationDateOption = [string]$r.ExpirationDateOption }
                if ($r.ContentMatchQuery)                      { $re.contentMatchQuery    = [string]$r.ContentMatchQuery }
                $ruleEntries += $re
            }
        }
        if ($ruleEntries.Count -gt 0) { $entry.rules = $ruleEntries }
        $exported += $entry
    }

    $doc  = [ordered]@{ policies = $exported }
    $body = ConvertTo-Yaml $doc
    $nl   = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} tenant policies (and their rules) to '{1}'." -f $exported.Count, $Path) -InformationAction Continue
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
# sibling Deploy-*.ps1 reconcilers (Deploy-DLPPolicies.ps1,
# Deploy-Labels.ps1, Deploy-LabelPolicies.ps1, ...). The module is
# pure and unit-tested independently; do not re-inline the decision
# logic here.
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
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'." -f $ParametersFile, $key)
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
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'." -f $ParametersFile)
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
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue

#endregion

#region Desired-state load

$desiredEntries = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

    # Schema validation (JSON Schema Draft-07).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    if (-not $SkipSchemaValidation.IsPresent) {
        $schemaPath = Join-Path $scriptRoot '..\data-plane\data-lifecycle\retention-policies.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath)) {
            Write-Error ("Schema file not found at '{0}'." -f $schemaPath)
            return
        }
        $schemaText = Get-Content -LiteralPath $schemaPath -Raw
        $docJson = $desiredRoot | ConvertTo-Json -Depth 10
        try {
            $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
        }
        catch {
            Write-Error ("Desired-state YAML failed schema validation: {0}" -f $_.Exception.Message)
            return
        }
        Write-Information ("Schema OK       : {0}" -f $schemaPath) -InformationAction Continue
    }

    if ($desiredRoot -and $desiredRoot.ContainsKey('policies') -and $desiredRoot.policies) {
        $desiredEntries = @($desiredRoot.policies | ForEach-Object { ConvertTo-DesiredRetentionPolicyHash -Entry ([hashtable]$_) })
    }
    Write-Information ("Desired policies: {0}" -f $desiredEntries.Count) -InformationAction Continue
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

#region Resolve data-plane app + acquire access token

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
    Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName)
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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancepolicy
    # -DistributionDetail is required: without it, ExchangeLocation /
    # SharePointLocation / OneDriveLocation etc. come back as empty
    # collections even when the policy carries real locations, causing
    # spurious `locations.<bucket>` drift on every Compare-RetentionPolicy.
    $tenantPolicies = @(Get-RetentionCompliancePolicy -DistributionDetail -ErrorAction Stop)
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-retentioncompliancerule
    $tenantRules    = @(Get-RetentionComplianceRule    -ErrorAction Stop)
    Write-Information ("Tenant policies : {0}" -f $tenantPolicies.Count) -InformationAction Continue
    Write-Information ("Tenant rules    : {0}" -f $tenantRules.Count)    -InformationAction Continue

    if ($mode -eq 'Export') {
        Invoke-RetentionExport -Path $Path -TenantPolicies $tenantPolicies -TenantRules $tenantRules -Force:$Force.IsPresent
        return
    }

    # Index tenant data for O(1) lookups.
    $tenantPolicyByName = @{}
    foreach ($t in $tenantPolicies) {
        $tenantPolicyByName[[string]$t.Name] = ConvertTo-TenantRetentionPolicyHash -Policy $t
    }
    $tenantRuleByKey = @{}
    foreach ($r in $tenantRules) {
        $resolvedPolicy = Resolve-TenantRulePolicyName -RulePolicy ([string]$r.Policy) -TenantPolicies $tenantPolicies
        $key = ('{0}\{1}' -f $resolvedPolicy, [string]$r.Name)
        $tenantRuleByKey[$key] = ConvertTo-TenantRetentionRuleHash -Rule $r
    }
    $desiredPolicyNames = @($desiredEntries | ForEach-Object { $_.name })

    # ---- Policy-level plan ------------------------------------------------
    $policyPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantPolicyByName.ContainsKey($d.name)) {
            $diffs = Compare-RetentionPolicy -Desired $d -Tenant $tenantPolicyByName[$d.name]
            if ($diffs.Count -eq 0) {
                $policyPlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } else {
                $policyPlan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $policyPlan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantPolicies) {
        $tn = [string]$t.Name
        if ($desiredPolicyNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $policyPlan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- Rule-level plan --------------------------------------------------
    # Built before any apply so the ADR 0029 direction-policy pass can
    # arbitrate policy and rule drift in a single sweep before any
    # cmdlet writes. `$existingPolicyNames` includes desired names so
    # rules under a YAML-only policy plan as Create rather than
    # Skipped; the defensive `Skipped` branch only fires when the
    # rule's parent is neither in the tenant nor in YAML, which
    # cannot happen in normal operation.
    $existingPolicyNames = @($tenantPolicyByName.Keys) + @($desiredPolicyNames) | Sort-Object -Unique
    $rulePlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        foreach ($dr in $d.rules) {
            $key = ('{0}\{1}' -f $d.name, $dr.name)
            if ($tenantRuleByKey.ContainsKey($key)) {
                $diffs = Compare-RetentionRule -Desired $dr -Tenant $tenantRuleByKey[$key]
                if ($diffs.Count -eq 0) {
                    $rulePlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $key; RuleName = $dr.name; PolicyName = $d.name; Desired = $dr; Reason = 'In sync with tenant.'; Fields = '' })
                } else {
                    $rulePlan.Add([pscustomobject]@{ Action = 'Update'; Name = $key; RuleName = $dr.name; PolicyName = $d.name; Desired = $dr; Reason = ('Drift in: {0}' -f ($diffs -join ', ')); Fields = ($diffs -join ', ') })
                }
            } else {
                if ($existingPolicyNames -notcontains $d.name) {
                    $rulePlan.Add([pscustomobject]@{ Action = 'Skipped'; Name = $key; RuleName = $dr.name; PolicyName = $d.name; Desired = $dr; Reason = 'Parent policy not yet created.'; Fields = '' })
                } else {
                    $rulePlan.Add([pscustomobject]@{ Action = 'Create'; Name = $key; RuleName = $dr.name; PolicyName = $d.name; Desired = $dr; Reason = 'Declared in YAML; absent from tenant.'; Fields = '' })
                }
            }
        }
    }

    # ---- ADR 0029: direction-policy pass ---------------------------------
    # Walk the Update entries in BOTH plans (policies + rules) and
    # consult Resolve-DirectionPolicyAction (from the shared module
    # imported above) to decide Skip vs. Update under the configured
    # policy and operator-supplied SkipNames list. Create / NoChange /
    # Orphan entries are unaffected (a policy or rule that exists in
    # YAML but not in the tenant has no shared-property drift to
    # arbitrate; orphan-removal is gated by -PruneMissing, not by the
    # direction-policy contract). Audit mode is handled by a separate
    # short-circuit below and does not enter this pass. The
    # Write-Warning for repo-wins fires ONCE per drifted object with
    # the comma-joined drifted-field set, matching the per-object
    # shape proven in the sibling Deploy-*.ps1 reconcilers.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'

        # Pass 1: policies. SkipNames is matched against policy.Name.
        foreach ($row in $policyPlan) {
            if ($row.Action -ne 'Update') { continue }
            $displayName = [string]$row.Name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'Policy'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                })
                continue
            }
            $fieldsText = ($row.Reason -replace '^Drift in: ', '')
            Write-Warning ("repo-wins overwriting tenant on retention policy '{0}' fields: {1}" -f $displayName, $fieldsText)
        }

        # Pass 2: rules. SkipNames is matched against rule.Name (NOT
        # the composite Policy\Rule key) per the DLP precedent and
        # operator expectation.
        foreach ($row in $rulePlan) {
            if ($row.Action -ne 'Update') { continue }
            $displayName = [string]$row.RuleName
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'Rule'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                })
                continue
            }
            $fieldsText = [string]$row.Fields
            Write-Warning ("repo-wins overwriting tenant on retention rule '{0}' fields: {1}" -f $row.Name, $fieldsText)
        }

        # Machine-readable marker per skipped object for the workflow's
        # auto-PR step. One line per skipped object so a simple
        # `grep '\[ADR0029-SKIP\]'` over the run log yields the full
        # skip list. Format must match the exact regex
        # `^\[ADR0029-SKIP\] (.+)$` per the github-actions
        # instructions rule, so we do not prefix the Kind here.
        foreach ($s in $skipDecisions) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # ---- ADR 0029: audit-mode short-circuit ------------------------------
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

    # Apply policy-level plan. Policies must exist before rules can
    # bind to them; orphan deletions run last so that rules under an
    # orphan policy can be removed first.
    foreach ($row in ($policyPlan | Where-Object { $_.Action -in @('Create','Update','NoChange','Skip') })) {
        $target = "Retention policy '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $splat  = Get-RetentionPolicySplat -Hash $row.Desired
                $opDesc = 'New-RetentionCompliancePolicy (enabled={0}, restrictiveRetention={1})' -f $row.Desired.enabled, $row.Desired.restrictiveRetention
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancepolicy
                        New-RetentionCompliancePolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Policy'; Name = $row.Name; Reason = ('Would create: {0}' -f $opDesc) }) | Out-Null
                }
            }
            'Update' {
                $splat  = Get-RetentionPolicySplat -Hash $row.Desired -ForSet
                $opDesc = 'Set-RetentionCompliancePolicy ({0})' -f $row.Reason
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancepolicy
                        Set-RetentionCompliancePolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Update failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Policy'; Name = $row.Name; Reason = ('Would update: {0}' -f $row.Reason) }) | Out-Null
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            'Skip' {
                $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
        }
    }

    # Apply rule-level plan.
    foreach ($row in $rulePlan) {
        $key        = $row.Name
        $ruleTarget = "Retention rule '{0}'" -f $key
        switch ($row.Action) {
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Rule'; Name = $key; Reason = $row.Reason }) | Out-Null
            }
            'Skip' {
                $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Rule'; Name = $key; Reason = $row.Reason }) | Out-Null
            }
            'Skipped' {
                $report.Add([pscustomobject]@{ Category = 'Skipped'; Kind = 'Rule'; Name = $key; Reason = $row.Reason }) | Out-Null
            }
            'Create' {
                $splat  = Get-RetentionRuleSplat -Hash $row.Desired -PolicyName $row.PolicyName
                $opDesc = 'New-RetentionComplianceRule (action={0})' -f $row.Desired.retentionAction
                if ($PSCmdlet.ShouldProcess($ruleTarget, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-retentioncompliancerule
                        New-RetentionComplianceRule @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Rule'; Name = $key; Reason = $row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $key; Reason = ('Create failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Rule'; Name = $key; Reason = ('Would create: {0}' -f $opDesc) }) | Out-Null
                }
            }
            'Update' {
                $splat  = Get-RetentionRuleSplat -Hash $row.Desired -PolicyName $row.PolicyName -ForSet
                $opDesc = 'Set-RetentionComplianceRule ({0})' -f $row.Reason
                if ($PSCmdlet.ShouldProcess($ruleTarget, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-retentioncompliancerule
                        Set-RetentionComplianceRule @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Rule'; Name = $key; Reason = $row.Reason }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $key; Reason = ('Update failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Rule'; Name = $key; Reason = ('Would update: {0}' -f $row.Reason) }) | Out-Null
                }
            }
        }
    }

    # ---- Orphan rules + orphan policies (deletion last) -------------------
    # Tenant rules whose (policy, name) tuple is absent from the YAML.
    $desiredRuleKeys = @()
    foreach ($d in $desiredEntries) {
        foreach ($dr in $d.rules) { $desiredRuleKeys += ('{0}\{1}' -f $d.name, $dr.name) }
    }
    foreach ($key in $tenantRuleByKey.Keys) {
        if ($desiredRuleKeys -contains $key) { continue }
        $tr = $tenantRuleByKey[$key]
        # Orphan rules from a still-present policy: remove only with -PruneMissing.
        # Orphan rules from an orphan policy: removed below alongside the parent.
        $parentPolicy = $tr.policyName
        $parentIsDesired = $desiredPolicyNames -contains $parentPolicy
        if ($parentIsDesired) {
            if ($PruneMissing.IsPresent) {
                $ruleTarget = "Retention rule '{0}'" -f $key
                $opDesc     = 'Remove-RetentionComplianceRule'
                if ($PSCmdlet.ShouldProcess($ruleTarget, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancerule
                        Remove-RetentionComplianceRule -Identity $key -Confirm:$false -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Rule'; Name = $key; Reason = 'Tenant-only; removed (-PruneMissing).' }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $key; Reason = ('Remove failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Rule'; Name = $key; Reason = 'Would remove: tenant-only orphan.' }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Rule'; Name = $key; Reason = 'Tenant-only; skipped (no -PruneMissing).' }) | Out-Null
            }
        }
    }

    # Orphan policies (process LAST so child rules get removed first).
    foreach ($row in ($policyPlan | Where-Object { $_.Action -eq 'Orphan' })) {
        $target = "Retention policy '{0}'" -f $row.Name
        if ($PruneMissing.IsPresent) {
            # First remove every tenant rule under this orphan policy.
            $childRules = @($tenantRules | Where-Object { [string]$_.Policy -eq $row.Name })
            foreach ($cr in $childRules) {
                $ruleKey    = ('{0}\{1}' -f $row.Name, [string]$cr.Name)
                $ruleTarget = "Retention rule '{0}'" -f $ruleKey
                if ($PSCmdlet.ShouldProcess($ruleTarget, 'Remove-RetentionComplianceRule (orphan parent)')) {
                    try {
                        Remove-RetentionComplianceRule -Identity $ruleKey -Confirm:$false -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Rule'; Name = $ruleKey; Reason = 'Removed as part of orphan parent policy.' }) | Out-Null
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $ruleKey; Reason = ('Remove failed: {0}' -f $_.Exception.Message) }) | Out-Null
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Rule'; Name = $ruleKey; Reason = 'Would remove with parent.' }) | Out-Null
                }
            }
            if ($PSCmdlet.ShouldProcess($target, 'Remove-RetentionCompliancePolicy')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-retentioncompliancepolicy
                    Remove-RetentionCompliancePolicy -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'WhatIf'; Kind = 'Policy'; Name = $row.Name; Reason = 'Would remove: tenant-only orphan.' }) | Out-Null
            }
        } else {
            $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
        }
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

# Emit the report objects to the pipeline.
$report

#endregion
