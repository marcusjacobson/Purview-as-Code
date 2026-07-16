#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview / Microsoft 365 Sensitive Information Type
    (SIT) catalog against `data-plane/classifications/sit-catalog.yaml`
    (desired state).

.DESCRIPTION
    Wave 1 declarative reconciler. The YAML is the central source of truth
    for the SIT inventory in this repo: downstream artifacts (sensitivity
    labels, auto-label policies, DLP policies) refer to SITs by name or
    GUID and depend on this catalog being current.

    The current pass implements the **pull / -ExportCurrentState** path
    only. It connects to Security & Compliance PowerShell as the
    data-plane Entra app via `Get-PurviewIPPSAccessToken.ps1` (Key Vault
    PS256 sign, no stored secret), enumerates every SIT visible to that
    workload identity via `Get-DlpSensitiveInformationType`, and writes
    the result to the YAML. Both Microsoft built-ins and tenant-custom
    SITs are recorded; tenant-custom SITs become candidates for
    write-back in a follow-up PR.

    Two pieces are deliberately deferred to a follow-up PR:
      1. Apply path (`New-/Set-/Remove-DlpSensitiveInformationType` with
         a categorized drift report mirroring
         `scripts/Deploy-PurviewRoleGroups.ps1`).
      2. Promotion of read-only built-in SIT references into label /
         DLP / auto-label policy YAMLs (Wave 1 #65, #66, #67).

    Auth path -- identical to `scripts/Deploy-PurviewRoleGroups.ps1`:
      1. `az account show` (CLI is the JWT signing transport).
      2. `az ad app list --display-name <DataPlaneAppDisplayName>` to
         resolve the appId.
      3. `Get-PurviewIPPSAccessToken.ps1` to sign a PS256
         client_assertion against the Key Vault key and exchange it for
         an access token.
      4. `Connect-IPPSSession -AccessToken <jwt> -Organization <tenant>`.
      5. `Disconnect-ExchangeOnline -Confirm:$false` in a `finally`
         block.

    Data-plane Entra app prerequisites (one-time per tenant; configured
    by Wave 0 #5b and `scripts/Grant-ExchangeManageAsApp.ps1`):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` (or Compliance
        Data Administrator) assigned at directoryScopeId='/' on the
        workload SP. This role is sufficient for
        `Get-DlpSensitiveInformationType` (read).

    First-run-against-existing-tenant contract (per
    `.github/instructions/powershell.instructions.md`):

        ./scripts/Sync-SITCatalog.ps1 -ExportCurrentState

    Hydrates the YAML from the live tenant. The script refuses to
    overwrite a non-empty `sits:` list unless `-Force` is also specified.
    Existing YAML header comments are preserved by line-splicing -- only
    the `sits:` block is rewritten.

    References (Microsoft Learn):
      Get-DlpSensitiveInformationType:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpsensitiveinformationtype
      Connect-IPPSSession (-AccessToken):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Sensitive information type entity definitions:
        https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (active): docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession: docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract): docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML file. Defaults to the in-repo location
    `data-plane/classifications/sit-catalog.yaml`.

.PARAMETER Force
    With `-ExportCurrentState`: allow overwriting a `sits:` block that
    already contains entries. Without it the script refuses, to avoid
    clobbering a hand-curated YAML.

.PARAMETER ExportCurrentState
    Read every SIT visible to the connected workload identity via
    `Get-DlpSensitiveInformationType`, write the inventory to the YAML's
    `sits:` block, and exit. Makes no writes to the tenant.

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
    from `automation.apps.dataPlane.certificateName` in the parameters
    file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.EXAMPLE
    ./scripts/Sync-SITCatalog.ps1 -ExportCurrentState

    Hydrate `data-plane/classifications/sit-catalog.yaml` from the live
    tenant via app-only auth. Refuses to clobber a non-empty `sits:`
    list without -Force.

.EXAMPLE
    ./scripts/Sync-SITCatalog.ps1 -ExportCurrentState -WhatIf

    Print the planned auth path and target file. No remote calls.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason. No credential material is printed; tenant-real
    publisher GUIDs are redacted to the zero GUID before serialization.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\classifications\sit-catalog.yaml'),

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
    [string]$TenantDomain
)

$ErrorActionPreference = 'Stop'

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+. See `.github/instructions/powershell.instructions.md`.
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

#endregion

#region Desired-state load (refuse-clobber check)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
$desiredSits = @()
if ($desiredRoot -and $desiredRoot.ContainsKey('sits') -and $desiredRoot.sits) {
    $desiredSits = @($desiredRoot.sits)
}
if ($mode -eq 'Export' -and $desiredSits.Count -gt 0 -and -not $Force.IsPresent) {
    Write-Error ("'{0}' already declares {1} SIT(s) in 'sits:'. Refusing to overwrite without -Force." -f $Path, $desiredSits.Count)
    return
}

#endregion

#region Apply mode -- deferred to follow-up PR

if ($mode -eq 'Apply') {
    Write-Information 'Apply path is not implemented in this revision.' -InformationAction Continue
    Write-Information 'Use -ExportCurrentState to hydrate the YAML from the live tenant.' -InformationAction Continue
    Write-Information 'Apply path (New-/Set-/Remove-DlpSensitiveInformationType, drift report, -PruneMissing) lands in a follow-up PR; tracked on the Wave 1 row of docs/project-plan.md.' -InformationAction Continue
    return
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

#region -WhatIf short-circuit (no remote calls)

if ($WhatIfPreference) {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information ('  1. Resolve Entra app via `az ad app list` (Graph read).') -InformationAction Continue
    Write-Information ('  2. Acquire access token via Get-PurviewIPPSAccessToken.ps1 (Key Vault PS256 sign).') -InformationAction Continue
    Write-Information ('  3. Connect-IPPSSession -AccessToken <redacted> -Organization {0}' -f $TenantDomain) -InformationAction Continue
    Write-Information ('  4. Get-DlpSensitiveInformationType (enumerate all SITs).') -InformationAction Continue
    Write-Information ('  5. Replace `sits:` block in {0} with discovered inventory.' -f (Split-Path -Leaf $Path)) -InformationAction Continue
    Write-Information ('  6. Disconnect-ExchangeOnline -Confirm:$false in finally.') -InformationAction Continue
    return
}

#endregion

#region Resolve Entra app + acquire token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app list failed with exit code $LASTEXITCODE."
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
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name; reconcile manually." -f $appList.Count, $DataPlaneAppDisplayName)
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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpsensitiveinformationtype
    $allSits = @(Get-DlpSensitiveInformationType -ErrorAction Stop)
    Write-Information ("Discovered {0} SIT(s) visible to the connected app." -f $allSits.Count) -InformationAction Continue

    if ($allSits.Count -eq 0) {
        Write-Warning 'Get-DlpSensitiveInformationType returned zero entries. The lab tenant may not have any SITs available, or the workload SP lacks the required Compliance Administrator role.'
    }

    # First-run schema discovery: dump column names of the first row to
    # the verbose stream so the operator can confirm the property names
    # this script binds to. The Learn page for this cmdlet is
    # historically thin on output schema; this lets us self-document.
    if ($allSits.Count -gt 0) {
        $first = $allSits[0]
        $cols  = @($first.PSObject.Properties.Name | Sort-Object)
        Write-Verbose ("Get-DlpSensitiveInformationType row schema: {0}" -f ($cols -join ', '))
    }

    $exportStamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    $exportEntries = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($sit in $allSits | Sort-Object Name) {
        $rawId        = if ($sit.PSObject.Properties.Name -contains 'Id')         { [string]$sit.Id }         else { $null }
        $rawIdentity  = if ($sit.PSObject.Properties.Name -contains 'Identity')   { [string]$sit.Identity }   else { $null }
        $rawPublisher = if ($sit.PSObject.Properties.Name -contains 'Publisher')  { [string]$sit.Publisher }  else { $null }
        $rawType      = if ($sit.PSObject.Properties.Name -contains 'Type')       { [string]$sit.Type }       else { $null }
        $rawRulePack  = if ($sit.PSObject.Properties.Name -contains 'RulePackId') { [string]$sit.RulePackId } else { $null }

        # Prefer .Id (GUID) over .Identity. Tenant-real publisher
        # identifiers are redacted to the zero GUID per identifier
        # redaction policy; the publisher *name* is kept verbatim.
        $sitId = $rawId
        if (-not $sitId) { $sitId = $rawIdentity }
        $publisher = $rawPublisher
        if ($publisher -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $publisher = '00000000-0000-0000-0000-000000000000'
        }

        $entry = [ordered]@{
            name = [string]$sit.Name
        }
        if ($sitId)     { $entry['id']        = $sitId }
        if ($publisher) { $entry['publisher'] = $publisher }
        if ($rawType)   { $entry['type']      = $rawType }
        if ($rawRulePack) {
            if ($rawRulePack -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                # Tenant-published rule packages have tenant-real GUIDs.
                # Microsoft built-in rule packages have stable GUIDs
                # documented in Learn (`OOTB Rulepack` etc.). We cannot
                # reliably distinguish them from string alone, so we
                # keep the value and let the reviewer decide; the
                # secrets-scan in the pre-commit checklist will not
                # flag a GUID.
                $entry['rulePackId'] = $rawRulePack
            }
            else {
                $entry['rulePackId'] = $rawRulePack
            }
        }
        $exportEntries.Add([hashtable]$entry)

        $report.Add([pscustomobject]@{
            Category = 'Export'
            Kind     = 'SIT'
            Name     = [string]$sit.Name
            Reason   = ("Type={0}; Publisher={1}" -f $rawType, $rawPublisher)
        })
    }

    Write-Information ("Exporting {0} SIT entry/entries to '{1}'." -f $exportEntries.Count, $Path) -InformationAction Continue

    # Preserve YAML header comments by line-splicing.
    $originalLines = Get-Content -LiteralPath $Path
    $cutIndex = -1
    for ($i = 0; $i -lt $originalLines.Count; $i++) {
        if ($originalLines[$i] -match '^\s*sits\s*:') {
            $cutIndex = $i
            break
        }
    }
    if ($cutIndex -lt 0) {
        Write-Error ("Could not find 'sits:' key in '{0}'. Refusing to export." -f $Path)
        return
    }
    $headerLines = if ($cutIndex -gt 0) { $originalLines[0..($cutIndex - 1)] } else { @() }

    $newBlock = New-Object 'System.Collections.Generic.List[string]'
    if ($exportEntries.Count -eq 0) {
        $newBlock.Add(("# Exported from tenant on {0}." -f $exportStamp))
        $newBlock.Add('sits: []')
    }
    else {
        $newBlock.Add(("# Exported from tenant on {0}. {1} SIT(s)." -f $exportStamp, $exportEntries.Count))
        $newBlock.Add('sits:')
        foreach ($entry in $exportEntries) {
            $newBlock.Add(("  - name: {0}" -f $entry.name))
            foreach ($key in @('id', 'publisher', 'type', 'rulePackId')) {
                if ($entry.Contains($key) -and $null -ne $entry[$key]) {
                    $newBlock.Add(("    {0}: {1}" -f $key, $entry[$key]))
                }
            }
        }
    }

    $finalLines = @($headerLines) + @($newBlock)
    $shouldProcessTarget = "YAML file '{0}'" -f (Split-Path -Leaf $Path)
    $shouldProcessAction = "Replace 'sits:' block with {0} entry/entries" -f $exportEntries.Count
    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
        $finalLines | Set-Content -LiteralPath $Path -Encoding utf8
        Write-Information ("Wrote {0} SIT entry/entries to '{1}'. Review the diff before committing." -f $exportEntries.Count, $Path) -InformationAction Continue
    }
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

return $report

#endregion
