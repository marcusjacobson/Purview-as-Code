#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Insider Risk Management entity lists
    against `data-plane/irm/entity-lists.yaml` (desired state).

.DESCRIPTION
    Wave 2d declarative reconciler for Insider Risk Management entity
    lists (issue #606). The YAML is the central source of truth: add /
    update / remove flows through this script, which converges the live
    tenant to match. Sibling of `scripts/Deploy-IRMPolicies.ps1` -- same
    auth path, same drift vocabulary.

    IRM entity lists are named, typed collections of users, groups, or
    sites used to scope IRM policies. A list of type UserType holds UPNs;
    GroupType holds group identifiers; SiteType holds SharePoint/Teams
    site URLs.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every entity list via `Get-InsiderRiskEntityList`.
      2. Match desired vs. tenant by `Name`.
      3. Diff each desired list against the tenant copy on tracked fields:
         displayName, description, entities.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    `Type` is immutable after creation (analogous to InsiderRiskScenario
    on policies). It is stored in the desired hash for Create but is NOT
    diffed for existing lists. See docs/adr/0039-irm-entity-list-tracked-fields.md.

    `entities` comparison is order-insensitive: both arrays are normalized
    to lowercase sorted form before comparing.

    References (Microsoft Learn):
      Insider Risk Management -- priority user groups:
        https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups
      Get-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
      New-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
      Set-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
      Remove-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist
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
      ADR 0029 (source-of-truth direction policy):
        docs/adr/0029-source-of-truth-direction-policy.md
      ADR 0039 (entity-list tracked fields):
        docs/adr/0039-irm-entity-list-tracked-fields.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/irm/entity-lists.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant entity lists that are not declared in the YAML.
    Default $false. NEVER removes a name listed in -SkipNames (the
    baseline carries `IRM-Lab-Priority-Users` per
    `docs/adr/0039-irm-entity-list-tracked-fields.md`).

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit. No
                         New-/Set-/Remove- cmdlet writes against the
                         tenant fire under any circumstance.
                         Equivalent to a forced -WhatIf at the script
                         boundary.
      * `portal-wins` -- (default) skip any list whose tracked fields
                         differ; emit a Skip plan row per skipped list
                         and a `[ADR0029-SKIP] <name>` line per skip so
                         an upstream workflow can capture the list for an
                         auto-PR. Create / NoChange / Orphan handling are
                         unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         list naming the drifted field(s). The
                         typed-confirmation gate ('overwrite portal') is a
                         CI-layer concern enforced by the workflow per
                         ADR 0029; local script callers are
                         operator-trusted.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. A name matched
    here is treated as a Skip plan row. NoChange and Create rows are
    unaffected. -PruneMissing still respects -SkipNames. The match is
    case-insensitive against the bare `Name`. Ignored in
    `-DirectionPolicy audit` mode.
    Default `@()`. This script's workflow baseline carries `IRM-Lab-Priority-Users`
    per docs/adr/0039-irm-entity-list-tracked-fields.md.

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

.EXAMPLE
    ./scripts/Deploy-IRMEntityLists.ps1 -WhatIf

    Connect read-only and emit the plan table; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-IRMEntityLists.ps1

    Reconcile the tenant against the YAML. Without `-PruneMissing`,
    Orphan rows are reported but not removed.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Insider Risk Management` (or higher,
        e.g. `Compliance Administrator`) assigned at
        directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Name /
    Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or a file.
    No credential material is printed.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/irm/entity-lists.schema.json`
        (JSON Schema Draft-07) at script start.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\irm\entity-lists.yaml'),

    [switch]$PruneMissing,

    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [string[]]$SkipNames = @(),

    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'
#region Helpers

function ConvertTo-DesiredEntityListHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # entities: null means key absent (do-not-manage); empty array means
    # desired-empty. Both the desired and tenant arrays are sorted/lowercased
    # before comparison to make the diff order-insensitive.
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $entitiesNormalized = $null
    if ($Entry.ContainsKey('entities') -and ($null -ne $Entry.entities)) {
        $entitiesNormalized = @($Entry.entities |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object)
    }

    return @{
        name        = [string]$Entry.name
        type        = [string]$Entry.type
        displayName = if ($Entry.ContainsKey('displayName') -and
                          (-not [string]::IsNullOrEmpty($Entry.displayName))) {
                          [string]$Entry.displayName
                      } else { $null }
        description = if ($Entry.ContainsKey('description') -and
                          (-not [string]::IsNullOrEmpty($Entry.description))) {
                          [string]$Entry.description
                      } else { $null }
        entities    = $entitiesNormalized
    }
}

function ConvertTo-TenantEntityListHash {
    # Normalize a Get-InsiderRiskEntityList result into the same comparable
    # shape as ConvertTo-DesiredEntityListHash.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    param([Parameter(Mandatory = $true)]$EntityList)

    $entitiesNormalized = @()
    if ($null -ne $EntityList.Entities -and @($EntityList.Entities).Count -gt 0) {
        $entitiesNormalized = @($EntityList.Entities |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object)
    }

    return @{
        name        = [string]$EntityList.Name
        type        = if ($null -ne $EntityList.Type) { [string]$EntityList.Type } else { $null }
        displayName = if ($null -ne $EntityList.DisplayName -and
                          [string]$EntityList.DisplayName -ne '') {
                          [string]$EntityList.DisplayName
                      } else { $null }
        description = if ($null -ne $EntityList.Description -and
                          [string]$EntityList.Description -ne '') {
                          [string]$EntityList.Description
                      } else { $null }
        entities    = $entitiesNormalized
    }
}

function Compare-EntityList {
    # Return a list of field names that differ between desired and tenant.
    # Compares only fields the YAML actually declares -- a missing optional
    # in YAML is treated as "don't manage", not a diff.
    # entities: null (key absent) means do-not-manage; @() (declared empty)
    # means desired-empty and will diff against a non-empty tenant list.
    # type is NOT compared here (immutable after creation per ADR 0039).
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.displayName)) {
        if ([string]$Desired.displayName -ne [string]$Tenant.displayName) {
            $diffs.Add('displayName') | Out-Null
        }
    }

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    # entities: compare only when desired declares the key (null = do-not-manage).
    if ($null -ne $Desired.entities) {
        $desiredStr = $Desired.entities -join '|'
        $tenantStr  = $Tenant.entities  -join '|'
        if ($desiredStr -ne $tenantStr) {
            $diffs.Add('entities') | Out-Null
        }
    }

    return $diffs
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
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

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

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
Write-Information ("SkipNames count : {0}" -f $SkipNames.Count) -InformationAction Continue

#endregion

#region Desired-state load

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

# Schema validation (JSON Schema Draft-07).
# Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
if (-not $SkipSchemaValidation.IsPresent) {
    $schemaPath = Join-Path $scriptRoot '..\data-plane\irm\entity-lists.schema.json'
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

$desiredEntries = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('entityLists') -and $desiredRoot.entityLists) {
    $desiredEntries = @($desiredRoot.entityLists | ForEach-Object { ConvertTo-DesiredEntityListHash -Entry ([hashtable]$_) })
}
Write-Information ("Desired lists   : {0}" -f $desiredEntries.Count) -InformationAction Continue

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

#region Connect, enumerate, apply

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    $tenantLists = @(Get-InsiderRiskEntityList -ErrorAction Stop)
    Write-Information ("Tenant lists    : {0}" -f $tenantLists.Count) -InformationAction Continue

    # Index tenant entity lists by Name for O(1) lookup.
    $tenantByName = @{}
    foreach ($t in $tenantLists) {
        $tenantByName[[string]$t.Name] = ConvertTo-TenantEntityListHash -EntityList $t
    }
    $desiredNames = @($desiredEntries | ForEach-Object { $_.name })

    # Categorize: Create / Update / NoChange (desired-side) +
    # Orphan (tenant-only).
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantByName.ContainsKey($d.name)) {
            $diffs = Compare-EntityList -Desired $d -Tenant $tenantByName[$d.name]
            if ($diffs.Count -eq 0) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantLists) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- ADR 0029: audit-mode short-circuit + SkipNames pre-pass ----
    # `-DirectionPolicy audit` flips $WhatIfPreference for the rest of
    # this script so every $PSCmdlet.ShouldProcess(...) call below
    # returns false. No New-/Set-/Remove- cmdlet writes against the
    # tenant under any circumstance.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
        $WhatIfPreference = $true
    }

    # ADR 0029 direction-policy pass on the entity-list plan.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    $script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'
    if ($DirectionPolicy -ne 'audit') {
        foreach ($row in $plan) {
            if ($row.Action -notin @('Create', 'Update', 'NoChange', 'Orphan')) { continue }
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
                    Kind        = 'IRMEntityList'
                    DisplayName = [string]$row.Name
                    Reason      = $decision.Reason
                })
                continue
            }
            if ($row.Action -eq 'Update' -and $DirectionPolicy -eq 'repo-wins') {
                $fieldsText = ($row.Reason -replace '^Drift in: ', '')
                Write-Warning ("repo-wins overwriting tenant on IRM entity list '{0}' fields: {1}" -f $row.Name, $fieldsText)
            }
        }

        foreach ($s in $script:Adr0029Skips) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # Execute each plan row under ShouldProcess.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    foreach ($row in $plan) {
        $target = "IRM entity list '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $opDesc = 'New-InsiderRiskEntityList ({0})' -f $row.Desired.type
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
                        $splat = @{ Name = $row.Desired.name; Type = $row.Desired.type }
                        if (-not [string]::IsNullOrEmpty($row.Desired.displayName)) { $splat.DisplayName  = $row.Desired.displayName }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Description  = $row.Desired.description }
                        if ($null -ne $row.Desired.entities -and $row.Desired.entities.Count -gt 0) { $splat.Entities = $row.Desired.entities }
                        New-InsiderRiskEntityList @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $opDesc = 'Set-InsiderRiskEntityList'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
                        $splat = @{ Identity = $row.Desired.name }
                        if (-not [string]::IsNullOrEmpty($row.Desired.displayName)) { $splat.DisplayName  = $row.Desired.displayName }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Description  = $row.Desired.description }
                        if ($null -ne $row.Desired.entities) { $splat.Entities = $row.Desired.entities }
                        Set-InsiderRiskEntityList @splat -ErrorAction Stop | Out-Null
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
                $report.Add([pscustomobject]@{ Category = 'Skipped'; Name = $row.Name; Reason = $row.Reason })
            }
            'Orphan' {
                if ($PruneMissing.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($target, 'Remove-InsiderRiskEntityList')) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist
                            Remove-InsiderRiskEntityList -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
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

# Emit the categorized plan. Categories: Created / Updated / Removed for
# completed writes; Create / Update / Orphan for -WhatIf rows; NoChange
# for in-sync; Failed for caught exceptions; Skipped for ADR 0029 skips.
$report
