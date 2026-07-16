#Requires -Version 7.4
<#
.SYNOPSIS
    Enable (or revoke) the Microsoft 365 unified audit log ingestion via
    Exchange Online PowerShell, using a Key Vault-signed access token for
    app-only auth.

.DESCRIPTION
    Wave 0 item #4 of docs/project-plan.md. Sets
    `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true` on the lab
    tenant and verifies the change with `Get-AdminAuditLogConfig`. Per
    [Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable)
    this cmdlet is exposed by the Exchange Online endpoint, not the
    Security & Compliance (IPPS) endpoint -- empirically verified on
    2026-04-24: `Get-AdminAuditLogConfig` is shared, but `Set-AdminAuditLogConfig`
    is only proxied through `Connect-ExchangeOnline`.

    Authenticates via the Key Vault-side JWT signing path mandated by the
    [ADR 0011 Decision #3 supersession addendum](../docs/adr/0011-certificate-lifecycle.md):

      * Resolves the data-plane Entra app by display name (ADR 0010).
      * Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](./Get-PurviewIPPSAccessToken.ps1)
        which builds an RFC 7523 client_assertion JWT (header alg=PS256,
        x5t#S256) and signs the SHA-256 digest via `az keyvault key sign`
        against the certificate's underlying RSA key. The same
        `https://outlook.office365.com/.default` token works for both EXO
        and IPPS endpoints. The private key never leaves Key Vault.
      * Calls [`Connect-ExchangeOnline -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline)
        (added in `ExchangeOnlineManagement` v3.7.0+).
      * Reads current state with [`Get-AdminAuditLogConfig`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig).
      * If already in the desired state: `NoChange`. Else:
        [`Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled <bool>`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-adminauditlogconfig);
        then re-read to confirm.
      * Always [`Disconnect-ExchangeOnline -Confirm:$false`](https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline)
        in a `finally` block so the session is released even on failure.

    Idempotency: the read-before-write gate is the only idempotency boundary
    needed -- `UnifiedAuditLogIngestionEnabled` is a single scalar tenant flag,
    not a reconcilable collection. Drift report shape: a single
    Create/NoChange (or Revoke/NoOp) row.

    Propagation caveat: per the `Set-AdminAuditLogConfig` Learn page, the flag
    may take up to 60 minutes to fully propagate across Microsoft 365 services.
    The read-back verification in this script only confirms that the tenant
    config object reports the new value immediately; downstream search-ingestion
    lag is expected and is not treated as a failure.

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted, resolved
    from `resources.keyVault.name:` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved from
    `automation.apps.dataPlane.certificateName:` in the parameters file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName:` in the parameters
    file.

.PARAMETER TenantDomain
    Tenant primary domain (for example `contoso.onmicrosoft.com`), passed to
    `Connect-ExchangeOnline -Organization`. When omitted, resolved from
    `automation.tenantDomain:` in the parameters file.

.PARAMETER Revoke
    Flip `UnifiedAuditLogIngestionEnabled` to `$false` instead of `$true`.
    Symmetric inverse for emergency disable / lab cleanup. Default: not set
    (enable path).

.PARAMETER Interactive
    Bypass app-only authentication (Key Vault + cert JWT) and connect to
    Exchange Online PowerShell as the calling user via
    `Connect-ExchangeOnline -UserPrincipalName`. Intended for local-dev
    runs from a workstation that cannot reach the Key Vault (PNA=
    Disabled, no private-link path). Opens a browser MFA flow. CI must
    not use this switch; any workflow running this reconciler always
    runs app-only via the KV-side JWT signing path. NOTE: no
    per-solution workflow owns the unified audit log today (ADR 0051;
    backfill tracked in issue #80), so the documented apply path for
    this surface is a LOCAL run of this script.

.PARAMETER UserPrincipalName
    UPN to pre-populate in the interactive sign-in dialog. Used only
    when `-Interactive` is supplied. When omitted with `-Interactive`,
    the UPN is read from `az account show --query user.name -o tsv`.

.EXAMPLE
    ./scripts/Enable-UnifiedAuditLog.ps1 -WhatIf

    Prints planned behaviour without contacting Graph, Key Vault, or
    Exchange Online PowerShell.

.EXAMPLE
    ./scripts/Enable-UnifiedAuditLog.ps1

    Reads the current tenant config; flips `UnifiedAuditLogIngestionEnabled`
    to `$true` when it is not already; re-reads and prints the confirmed
    state.

.EXAMPLE
    ./scripts/Enable-UnifiedAuditLog.ps1 -Revoke

    Flips `UnifiedAuditLogIngestionEnabled` to `$false` if currently `$true`.

.EXAMPLE
    ./scripts/Enable-UnifiedAuditLog.ps1 -Interactive

    Same as the default Apply path but authenticates as the calling user via
    browser MFA. Requires no Key Vault access. Suitable for local-dev re-
    verification when the workstation cannot reach `kv-contoso-lab-01`
    (public network access disabled). The calling user must hold the
    Exchange `Organization Management` role group (or the legacy `Audit
    Logs` role) to run `Set-AdminAuditLogConfig`.

.NOTES
    Caller role requirements (the principal running this script):
      * Active `az login` session (CLI is the signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
        Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
      * `Key Vault Certificate User` on the target vault (certs/get for the
        public cert -- needed to compute x5t#S256).

    Data-plane Entra app prerequisites (one-time, idempotent via
    [`scripts/Grant-ExchangeManageAsApp.ps1`](./Grant-ExchangeManageAsApp.ps1)):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        (application) granted with admin consent.
      * Entra directory role `Compliance Administrator` assigned at
        `directoryScopeId = /` on the workload SP.
        References:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
        https://learn.microsoft.com/en-us/purview/audit-log-enable-disable

    Output: prints the previous and current `UnifiedAuditLogIngestionEnabled`
    values plus a one-line action ('NoChange', 'Set', 'Revoke', or 'NoOp').
    No credential material is printed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [Parameter()]
    [switch]$Revoke,

    [Parameter()]
    [switch]$Interactive,

    [Parameter()]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$UserPrincipalName
)

$ErrorActionPreference = 'Stop'

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

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

if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

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
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'. See ADR 0012 Decision #3 and Connect-IPPSSession docs." -f $ParametersFile)
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

$desiredValue = -not $Revoke.IsPresent
$actionLabel  = if ($Revoke.IsPresent) { 'Revoke' } else { 'Set' }
$noopLabel    = if ($Revoke.IsPresent) { 'NoOp' }   else { 'NoChange' }
$authMode     = if ($Interactive.IsPresent) { 'Interactive (user, browser MFA)' } else { 'App-only (Key Vault cert)' }

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Auth            : {0}" -f $authMode) -InformationAction Continue
if (-not $Interactive.IsPresent) {
    Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
    Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
    Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
}
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("Desired value   : UnifiedAuditLogIngestionEnabled = `${0}" -f $desiredValue) -InformationAction Continue

#endregion

#region Azure context (read-only preamble)

# `az account show` is a local token-cache read; safe to run in -WhatIf. Real
# tenant / subscription IDs must not appear in stdout per
# `Environment and identifier boundaries` in copilot-instructions.md, so we
# only print the subscription display name here. The TenantId GUID is
# captured for the JWT 'aud' claim and passed to the helper, never logged.
# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region ExchangeOnlineManagement module

# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
# Connect-ExchangeOnline -AccessToken added in ExchangeOnlineManagement v3.7.0+;
# ADR 0011 Decision #3 supersession requires this module version or newer.
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
}
Import-Module $module -ErrorAction Stop

#endregion

#region Connect, probe, (optionally) set, verify

# All Azure-dependent operations (Entra app lookup, Key Vault key sign, S&C
# PowerShell connection) run only inside ShouldProcess. A `-WhatIf`
# invocation prints intent and exits without contacting any remote service,
# so it can be exercised by anyone with `az login` regardless of Graph or
# Key Vault RBAC.
$action = $noopLabel
$previousValue = $null
$currentValue = $null

$shouldProcessTarget = "Exchange Online PowerShell (tenant {0})" -f $TenantDomain
$shouldProcessAction = if ($Revoke.IsPresent) {
    'Read Get-AdminAuditLogConfig; set UnifiedAuditLogIngestionEnabled=$false only if currently $true'
} else {
    'Read Get-AdminAuditLogConfig; set UnifiedAuditLogIngestionEnabled=$true only if currently $false'
}

if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {

    $tok = $null

    if (-not $Interactive.IsPresent) {
        # Resolve Entra app (Graph read).
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
            Write-Error ("Entra application '{0}' not found. Run Wave 0 #5b (`./scripts/New-AutomationEntraApp.ps1 -Plane data`) first." -f $DataPlaneAppDisplayName)
            return
        }
        if ($appList.Count -gt 1) {
            Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name; reconcile manually." -f $appList.Count, $DataPlaneAppDisplayName)
            return
        }
        $appId = [string]$appList[0].appId
        # NOTE: $appId deliberately not printed. It is a real tenant identifier
        # under copilot-instructions.md `Environment and identifier boundaries`.

        # Acquire access token via Key Vault-side JWT signing.
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
    }
    else {
        # Interactive mode: resolve the UPN from `az account show` when the
        # caller did not pass one. Connect-ExchangeOnline -UserPrincipalName
        # uses MSAL to open a browser sign-in with MFA. The KV cert path is
        # skipped entirely so a local-dev run never reaches the vault.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline
        if (-not $UserPrincipalName) {
            $UserPrincipalName = (az account show --query user.name -o tsv 2>$null)
            if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
                Write-Error 'Interactive mode requires a UPN. Pass -UserPrincipalName or run `az login` first.'
                return
            }
        }
        Write-Information ("Interactive UPN : {0} (browser MFA will be triggered)" -f $UserPrincipalName) -InformationAction Continue
    }

    try {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline
        # Note: Connect-ExchangeOnline (not Connect-IPPSSession) is required
        # because Set-AdminAuditLogConfig is only proxied through the EXO
        # endpoint per https://learn.microsoft.com/en-us/purview/audit-log-enable-disable.
        if ($Interactive.IsPresent) {
            Connect-ExchangeOnline `
                -UserPrincipalName $UserPrincipalName `
                -ShowBanner:$false `
                -ErrorAction       Stop | Out-Null
            Write-Information ("Connected to Exchange Online PowerShell as user '{0}'." -f $UserPrincipalName) -InformationAction Continue
        }
        else {
            Connect-ExchangeOnline `
                -AccessToken  $tok.AccessToken `
                -Organization $TenantDomain `
                -ShowBanner:$false `
                -ErrorAction  Stop | Out-Null
            Write-Information ("Connected to Exchange Online PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue
        }

        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-adminauditlogconfig
        $current = Get-AdminAuditLogConfig -ErrorAction Stop
        $previousValue = [bool]$current.UnifiedAuditLogIngestionEnabled
        Write-Information ("Previous UnifiedAuditLogIngestionEnabled = {0}" -f $previousValue) -InformationAction Continue

        if ($previousValue -eq $desiredValue) {
            $currentValue = $previousValue
            $action = $noopLabel
        }
        else {
            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-adminauditlogconfig
            Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $desiredValue -Confirm:$false -ErrorAction Stop
            $action = $actionLabel

            $verify = Get-AdminAuditLogConfig -ErrorAction Stop
            $currentValue = [bool]$verify.UnifiedAuditLogIngestionEnabled
            if ($currentValue -ne $desiredValue) {
                Write-Error ("Set-AdminAuditLogConfig reported success but Get-AdminAuditLogConfig still returns {0}. Propagation may take up to 60 minutes; re-run later to re-verify." -f $currentValue)
                return
            }
        }
    }
    finally {
        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/disconnect-exchangeonline
        try {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message)
        }
    }
}
else {
    # -WhatIf path: do not contact Graph, Key Vault, or Exchange Online.
    Write-Information "-WhatIf specified. Planned behaviour (no remote calls made):" -InformationAction Continue
    $step = 0
    if ($Interactive.IsPresent) {
        $plannedUpn = if ($UserPrincipalName) { $UserPrincipalName } else { '<resolved at run time from `az account show --query user.name`>' }
        Write-Information ("  {0}. Skip Entra app lookup and Key Vault token acquisition (interactive auth)." -f (++$step)) -InformationAction Continue
        Write-Information ("  {0}. Connect-ExchangeOnline -UserPrincipalName {1} (browser MFA)." -f (++$step), $plannedUpn) -InformationAction Continue
    }
    else {
        Write-Information ("  {0}. Resolve Entra app '{1}' via 'az ad app list' (Graph read)." -f (++$step), $DataPlaneAppDisplayName) -InformationAction Continue
        Write-Information ("  {0}. Acquire access token via Get-PurviewIPPSAccessToken.ps1 (Key Vault-side PS256 sign against key '{1}' in vault '{2}')." -f (++$step), $CertificateName, $VaultName) -InformationAction Continue
        Write-Information ("  {0}. Connect-ExchangeOnline -AccessToken <redacted> -Organization {1}" -f (++$step), $TenantDomain) -InformationAction Continue
    }
    Write-Information ("  {0}. Read UnifiedAuditLogIngestionEnabled via Get-AdminAuditLogConfig." -f (++$step)) -InformationAction Continue
    Write-Information ("  {0}. If currently not `${1}, run Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled `${1}; then re-read to verify." -f (++$step), $desiredValue) -InformationAction Continue
    Write-Information ("  {0}. Disconnect-ExchangeOnline in a finally block." -f (++$step)) -InformationAction Continue
}

#endregion

#region Summary

[pscustomobject]@{
    tenantDomain                            = $TenantDomain
    dataPlaneApp                            = $DataPlaneAppDisplayName
    desiredUnifiedAuditLogIngestionEnabled  = $desiredValue
    previousUnifiedAuditLogIngestionEnabled = $previousValue
    currentUnifiedAuditLogIngestionEnabled  = $currentValue
    action                                  = $action
} | Format-List

if ($action -in @('Set', 'Revoke')) {
    Write-Information 'Propagation across Microsoft 365 services may take up to 60 minutes per the Set-AdminAuditLogConfig docs.' -InformationAction Continue
}

#endregion
