#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview unified audit log retention policies against
    `data-plane/audit/retention-policies.yaml` (desired state).

.DESCRIPTION
    Wave 2a declarative reconciler for audit log retention. The YAML is
    the central source of truth: any add / update / remove of a retention
    policy flows through this script, which converges the live tenant to
    match. Sibling of `scripts/Deploy-Labels.ps1` (same auth path, same
    drift vocabulary).

    Status: full reconciler. The script connects to Security &
    Compliance PowerShell via the lab automation identity (Key
    Vault-signed JWT, see ADR 0011), reads the desired-state YAML,
    schema-validates it, enumerates tenant policies via
    `Get-UnifiedAuditLogRetentionPolicy`, diffs each tracked field, and
    applies the categorized plan (Create / Update / NoChange / Orphan)
    under `ShouldProcess` (`-WhatIf` / `-Confirm`). `-PruneMissing`
    enables removal of tenant policies absent from the YAML.
    `-ExportCurrentState` round-trips the live tenant back into the
    YAML's `policies:` block; leading comment-block header lines are
    preserved and the YAML body is regenerated.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every policy via `Get-UnifiedAuditLogRetentionPolicy`.
      2. Match desired vs. tenant by `Name`.
      3. Diff each desired policy against the tenant copy (Phase 3).
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing). Phase 2 acts on none.

    References (Microsoft Learn):
      Manage audit log retention policies:
        https://learn.microsoft.com/en-us/purview/audit-log-retention-policies
      Get-UnifiedAuditLogRetentionPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy
      New-UnifiedAuditLogRetentionPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-unifiedauditlogretentionpolicy
      Set-UnifiedAuditLogRetentionPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-unifiedauditlogretentionpolicy
      Remove-UnifiedAuditLogRetentionPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-unifiedauditlogretentionpolicy
      Connect-IPPSSession (S&C PowerShell):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
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
    `data-plane/audit/retention-policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant policies that are not declared in the YAML.
    Default $false. Honored only by Phase 3+ write code.

.PARAMETER Force
    With -ExportCurrentState: allow overwriting a `policies:` block that
    already contains entries. Reserved for the export path (Phase 3+).

.PARAMETER ExportCurrentState
    Read every policy visible to the connected app, write to the YAML's
    `policies:` block, and exit. Makes no writes to the tenant.
    Implementation deferred to Phase 3.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

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

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit.
                         No New-/Set-/Remove- call fires under any
                         circumstance. Equivalent to a forced -WhatIf
                         at the script boundary.
      * `portal-wins` -- (default) skip any policy whose tracked
                         fields differ; emit a Skip plan row and a
                         `[ADR0029-SKIP] <Name>` marker line so an
                         upstream workflow can capture the list for
                         an auto-PR.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         policy. The typed-confirmation gate
                         ('overwrite portal') is a CI-layer concern
                         enforced by the workflow per ADR 0029; local
                         script callers are operator-trusted.
    Default `portal-wins`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. When set,
    each named policy that would otherwise drift is emitted as a Skip
    plan row instead of an Update row. NoChange, Create, and Orphan
    rows are unaffected. Names not present in the YAML or the tenant
    are silently ignored (defends against a stale skip list from the
    workflow).
    Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.EXAMPLE
    ./scripts/Set-AuditRetentionPolicy.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply would do;
    make no remote writes. In Phase 2 this is the only supported mode --
    the script never writes regardless of -WhatIf.

.EXAMPLE
    ./scripts/Set-AuditRetentionPolicy.ps1

    Phase 3+: reconcile the tenant against the YAML. Phase 2: behaves
    identically to -WhatIf (read-only enumerate-and-print).

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` or
        `Organization Management` assigned at directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Name /
    Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or a file.
    No credential material is printed.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/audit/retention-policies.schema.json`
        (JSON Schema Draft-07) at script start, after `ConvertFrom-Yaml`
        and before any reconcile work.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\audit\retention-policies.yaml'),

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

function ConvertTo-DesiredPolicyHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # Reference: docs/adr/0015-label-policy-shape.md (sibling normalization pattern)
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    return @{
        name              = [string]$Entry.name
        description       = if ($Entry.ContainsKey('description')) { [string]$Entry.description } else { $null }
        recordTypes       = if ($Entry.ContainsKey('recordTypes'))  { @($Entry.recordTypes  | Sort-Object -Unique) } else { @() }
        operations        = if ($Entry.ContainsKey('operations'))   { @($Entry.operations   | Sort-Object -Unique) } else { @() }
        userIds           = if ($Entry.ContainsKey('userIds'))      { @($Entry.userIds      | Sort-Object -Unique) } else { @() }
        retentionDuration = [string]$Entry.retentionDuration
        priority          = if ($Entry.ContainsKey('priority')) { [int]$Entry.priority } else { $null }
    }
}

function ConvertTo-TenantPolicyHash {
    # Normalize a Get-UnifiedAuditLogRetentionPolicy result into the
    # same comparable shape as ConvertTo-DesiredPolicyHash.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy
    param([Parameter(Mandatory = $true)]$Policy)

    return @{
        name              = [string]$Policy.Name
        description       = if ($Policy.Description) { [string]$Policy.Description } else { $null }
        recordTypes       = @($Policy.RecordTypes | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        operations        = @($Policy.Operations  | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        userIds           = @($Policy.UserIds     | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        retentionDuration = [string]$Policy.RetentionDuration
        priority          = if ($null -ne $Policy.Priority) { [int]$Policy.Priority } else { $null }
    }
}

function Compare-AuditPolicy {
    # Return a list of field names that differ between desired and
    # tenant. Compares only fields the YAML actually declares -- a
    # missing description / priority / array in YAML is treated as
    # "don't manage", not as a diff. Required fields
    # (retentionDuration) are always compared.
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

    foreach ($field in @('recordTypes', 'operations', 'userIds')) {
        $d = @($Desired[$field] | Sort-Object -Unique)
        if ($d.Count -eq 0) { continue }
        $t = @($Tenant[$field] | Sort-Object -Unique)
        $delta = Compare-Object -ReferenceObject $t -DifferenceObject $d
        if ($delta) { $diffs.Add($field) | Out-Null }
    }

    if ([string]$Desired.retentionDuration -ne [string]$Tenant.retentionDuration) {
        $diffs.Add('retentionDuration') | Out-Null
    }

    if ($null -ne $Desired.priority) {
        if ([int]$Desired.priority -ne [int]$Tenant.priority) {
            $diffs.Add('priority') | Out-Null
        }
    }

    return $diffs
}

function Get-AuditPolicySplat {
    # Build a splattable argument hashtable for New- or Set-
    # UnifiedAuditLogRetentionPolicy from a normalized desired hash.
    # New- expects -Name; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-unifiedauditlogretentionpolicy
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-unifiedauditlogretentionpolicy
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [switch]$ForSet
    )

    $splat = @{}
    if ($ForSet.IsPresent) { $splat.Identity = $Hash.name } else { $splat.Name = $Hash.name }
    if (-not [string]::IsNullOrEmpty($Hash.description))      { $splat.Description = $Hash.description }
    if ($Hash.recordTypes -and $Hash.recordTypes.Count -gt 0) { $splat.RecordTypes = [string[]]$Hash.recordTypes }
    if ($Hash.operations  -and $Hash.operations.Count  -gt 0) { $splat.Operations  = [string[]]$Hash.operations }
    if ($Hash.userIds     -and $Hash.userIds.Count     -gt 0) { $splat.UserIds     = [string[]]$Hash.userIds }
    $splat.RetentionDuration = $Hash.retentionDuration
    if ($null -ne $Hash.priority) { $splat.Priority = [int]$Hash.priority }
    return $splat
}

function Invoke-AuditRetentionExport {
    # Round-trip tenant policies back into the YAML's `policies:`
    # block. Leading comment / blank-line header is preserved; the
    # YAML body is regenerated. Refuses to overwrite a non-empty
    # policies block unless -Force.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantPolicies,
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

    $exported = @()
    foreach ($t in $TenantPolicies) {
        $entry = [ordered]@{ name = [string]$t.Name }
        if ($t.Description) { $entry.description = [string]$t.Description }
        $rt = @($t.RecordTypes | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        if ($rt.Count) { $entry.recordTypes = $rt }
        $op = @($t.Operations  | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        if ($op.Count) { $entry.operations  = $op }
        $u  = @($t.UserIds     | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        if ($u.Count)  { $entry.userIds     = $u }
        $entry.retentionDuration = [string]$t.RetentionDuration
        if ($null -ne $t.Priority) { $entry.priority = [int]$t.Priority }
        $exported += $entry
    }

    $doc  = [ordered]@{ policies = $exported }
    $body = ConvertTo-Yaml $doc
    $nl   = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} tenant policies to '{1}'." -f $exported.Count, $Path) -InformationAction Continue
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

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
if ($mode -eq 'Apply') {
    Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
    if ($SkipNames.Count -gt 0) {
        Write-Information ("SkipNames       : {0}" -f ($SkipNames -join ', ')) -InformationAction Continue
    }
}

#endregion

#region Desired-state load

# In Export mode the YAML at -Path is a *target* (may not exist yet);
# desired-state load + schema validation are Apply-only concerns.
$desiredEntries = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

    # Schema validation (JSON Schema Draft-07). Issue #69.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    if (-not $SkipSchemaValidation.IsPresent) {
        $schemaPath = Join-Path $scriptRoot '..\data-plane\audit\retention-policies.schema.json'
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
        $desiredEntries = @($desiredRoot.policies | ForEach-Object { ConvertTo-DesiredPolicyHash -Entry ([hashtable]$_) })
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

#region Connect, enumerate, disconnect

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-unifiedauditlogretentionpolicy
    $tenantPolicies = @(Get-UnifiedAuditLogRetentionPolicy -ErrorAction Stop)
    Write-Information ("Tenant policies : {0}" -f $tenantPolicies.Count) -InformationAction Continue

    if ($mode -eq 'Export') {
        Invoke-AuditRetentionExport -Path $Path -TenantPolicies $tenantPolicies -Force:$Force.IsPresent
        return
    }

    # Index tenant policies by Name for O(1) lookup.
    $tenantByName = @{}
    foreach ($t in $tenantPolicies) {
        $tenantByName[[string]$t.Name] = ConvertTo-TenantPolicyHash -Policy $t
    }
    $desiredNames = @($desiredEntries | ForEach-Object { $_.name })

    # Categorize: Create / Update / NoChange (desired-side) +
    # Orphan (tenant-only).
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantByName.ContainsKey($d.name)) {
            $diffs = Compare-AuditPolicy -Desired $d -Tenant $tenantByName[$d.name]
            if ($diffs.Count -eq 0) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantPolicies) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- ADR 0029: direction-policy pass ----
    # Walk Update plan entries; for each, consult Resolve-DirectionPolicyAction
    # to decide Skip vs. Update. Create / NoChange / Orphan entries are
    # unaffected (a policy absent from the tenant has no shared-property
    # drift to arbitrate). Audit mode is handled by a separate short-circuit
    # below and does not enter this pass.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -ne 'audit') {
        $policyPlan = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $plan) {
            if ($p.Action -ne 'Update') {
                $policyPlan.Add($p)
                continue
            }
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $p.Name `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $policyPlan.Add([pscustomobject]@{
                    Action  = 'Skip'
                    Name    = $p.Name
                    Desired = $p.Desired
                    Reason  = $decision.Reason
                })
                # Machine-readable marker for the workflow's auto-PR step.
                # One line per skipped policy so a simple grep captures the
                # full skip list.
                Write-Information ("[ADR0029-SKIP] {0}" -f $p.Name) -InformationAction Continue
            } else {
                # repo-wins: keep the Update entry, emit a warning per ADR 0029.
                Write-Warning ("repo-wins overwriting tenant policy '{0}': {1}" -f $p.Name, $p.Reason)
                $policyPlan.Add($p)
            }
        }
        $plan.Clear()
        foreach ($p in $policyPlan) { $plan.Add($p) }
    }

    # ---- ADR 0029: audit-mode short-circuit ----
    # Keeps the categorized report intact for end-of-script emission but
    # sets $WhatIfPreference = $true so no New-/Set-/Remove- call fires in
    # the write loop below under any circumstance.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes would have fired. Plan above is read-only.' -InformationAction Continue
        $WhatIfPreference = $true
    }

    # Execute each plan row under ShouldProcess. -WhatIf / -Confirm
    # flow naturally via $PSCmdlet.ShouldProcess.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    foreach ($row in $plan) {
        $target = "Audit retention policy '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $splat  = Get-AuditPolicySplat -Hash $row.Desired
                $opDesc = 'New-UnifiedAuditLogRetentionPolicy ({0})' -f $row.Desired.retentionDuration
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-unifiedauditlogretentionpolicy
                        New-UnifiedAuditLogRetentionPolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $splat  = Get-AuditPolicySplat -Hash $row.Desired -ForSet
                $opDesc = 'Set-UnifiedAuditLogRetentionPolicy'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-unifiedauditlogretentionpolicy
                        Set-UnifiedAuditLogRetentionPolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Updated'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Update'; Name = $row.Name; Reason = ('Would update. {0}' -f $row.Reason) })
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Name = $row.Name; Reason = $row.Reason })
            }
            'Skip' {
                $report.Add([pscustomobject]@{ Category = 'Skip'; Name = $row.Name; Reason = $row.Reason })
            }
            'Orphan' {
                if ($PruneMissing.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($target, 'Remove-UnifiedAuditLogRetentionPolicy')) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-unifiedauditlogretentionpolicy
                            Remove-UnifiedAuditLogRetentionPolicy -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                            $report.Add([pscustomobject]@{ Category = 'Removed'; Name = $row.Name; Reason = $row.Reason })
                        } catch {
                            $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                        }
                    } else {
                        $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = ('Would remove. {0}' -f $row.Reason) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = $row.Reason })
                }
            }
        }
    }
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
    }
}

#endregion

# Emit the categorized plan. Suitable for | Format-Table or capture to
# $GITHUB_STEP_SUMMARY. Categories: Created / Updated / Removed for
# completed writes; Create / Update / Orphan for -WhatIf rows; NoChange
# for in-sync; Skip for ADR 0029 direction-policy skips; Failed for
# caught exceptions.
$report
