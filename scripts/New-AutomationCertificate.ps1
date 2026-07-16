#Requires -Version 7.4
<#
.SYNOPSIS
    Create (or reconcile) the data-plane automation certificate per ADR 0011.

.DESCRIPTION
    Wave 0 item #5c of docs/project-plan.md. Generates a self-signed
    certificate in the lab Key Vault, uploads its public key to the
    data-plane Entra application as a keyCredential, and assigns the two
    Key Vault RBAC roles the app needs at runtime and at rotation time.
    Matches decisions #1, #2, and #5 of
    [ADR 0011](../docs/adr/0011-certificate-lifecycle.md):

      * Self-signed, RSA 2048, SHA-256, 12-month validity, non-exportable
        private key, subject `CN=<data-plane app display name>`, key usage
        `digitalSignature` + `keyEncipherment`. Every one of these is an
        ADR invariant and stays hardwired here -- only the cert's Key Vault
        object name (environment-variable) is read from lab.yaml.
      * Private key stays inside Key Vault: creation is server-side via
        `az keyvault certificate create`, so the PFX never hits the
        caller's disk.
      * Initial upload to the Entra app uses `PATCH /applications/{id}`
        with a single-entry `keyCredentials` array, because
        `application:addKey` requires an existing valid certificate on
        the app to sign the proof (per [application: addKey](https://learn.microsoft.com/en-us/graph/api/application-addkey)).
        Rotation (ADR 0011 decision #4, shipped by a later `Rotate-*` PR)
        uses `addKey`.
      * RBAC grants on the data-plane app's service principal (ADR 0011
        decision #2):
          - `Key Vault Certificate User` scoped to this one certificate
            (`{vault}/certificates/{name}`) -- least-privilege read for
            every deploy run.
          - `Key Vault Certificates Officer` scoped to the vault -- needed
            by the rotation workflow so the same identity can create the
            next cert version. The admin separation is the GitHub
            Environment reviewer gate (ADR 0010 decision #3), not an RBAC
            split.
      * Control-plane app intentionally gets nothing. ADR 0011 decision
        #5 forbids attaching a cert to `gh-oidc-purview-control-plane`
        because its only call surface is Azure ARM, serviceable by the
        OIDC federated token alone. The `-Plane` parameter is therefore
        fixed to `data` and not exposed -- the script refuses to run
        against the control-plane app by construction.

    Idempotency and invariant enforcement:

      * Certificate exists: `az keyvault certificate show` -- skip create.
      * Entra app already carries the cert thumbprint: NoChange on the
        keyCredentials reconcile. If the app carries a *different* single
        thumbprint, abort with an anomaly -- this is the startup-invariant
        surface of ADR 0011 decision #6 layer 3; the script never silently
        overwrites. If the app carries two or more thumbprints (rotation
        overlap), abort with an anomaly -- the rotation script, not this
        bootstrap, owns that state.
      * Role assignment exists: `az role assignment list` -- skip create.

    References (Learn):
      Certificate policy:
        https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-policy
      Create a certificate in Key Vault:
        https://learn.microsoft.com/en-us/azure/key-vault/certificates/create-certificate
      Key Vault RBAC roles:
        https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
      Update application (Graph):
        https://learn.microsoft.com/en-us/graph/api/application-update
      keyCredential resource:
        https://learn.microsoft.com/en-us/graph/api/resources/keycredential
      az keyvault certificate:
        https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate
      az role assignment:
        https://learn.microsoft.com/en-us/cli/azure/role/assignment

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER ResourceGroupName
    Resource group that owns the Key Vault. When omitted, resolved from
    `resourceGroupName:` in the parameters file.

.PARAMETER VaultName
    Key Vault holding the certificate. When omitted, resolved from
    `resources.keyVault.name:` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate object name. When omitted, resolved from
    `automation.apps.dataPlane.certificateName:` in the parameters file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName:` in the
    parameters file. Also drives the certificate subject CN.

.EXAMPLE
    ./scripts/New-AutomationCertificate.ps1 -WhatIf

    Prints the planned cert, keyCredentials, and RBAC writes without
    making any change.

.EXAMPLE
    ./scripts/New-AutomationCertificate.ps1

    Creates (or reconciles) the data-plane certificate, uploads it to the
    Entra app, and grants the two Key Vault RBAC roles.

.NOTES
    Caller role requirements:
      * `Key Vault Certificates Officer` on the vault -- to create the cert.
      * `User Access Administrator` or `Owner` on the vault -- to create the
        two role assignments.
      * Entra directory role that permits updating the target application's
        keyCredentials: `Application Administrator` or
        `Cloud Application Administrator` per [Least privileged roles by task](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/delegate-by-task#application-registrations).

    Output: prints the certificate's thumbprint, Key Vault secret ID,
    keyCredentials entry keyId, and the two role-assignment IDs. No
    credential material is printed because none leaves Key Vault.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._()-]{0,88}[a-zA-Z0-9_()]$')]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName
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

# Shape validation: every missing key is a named, actionable failure.
foreach ($key in @('resourceGroupName', 'resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
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

# Resolution order per ADR 0012: explicit CLI parameter wins.
if (-not $ResourceGroupName)        { $ResourceGroupName        = [string]$parameters.resourceGroupName }
if (-not $VaultName)                { $VaultName                = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)          { $CertificateName          = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName)  { $DataPlaneAppDisplayName  = [string]$parameters.automation.apps.dataPlane.displayName }

# ADR 0011 decision #1 invariants -- stay hardwired. Not configurable.
$certSubject = "CN=${DataPlaneAppDisplayName}"
$certKeySize = 2048
$certKeyType = 'RSA'
$certExportable = $false
$certValidityMonths = 12
$certKeyUsage = @('digitalSignature', 'keyEncipherment')
# ADR 0011 decision #2 -- KV RBAC roles (built-in GUIDs are stable; from the
# "Azure built-in roles for Key Vault data plane operations" table).
# Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
$roleCertUserId = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'     # Key Vault Certificate User
$roleCertOfficerId = 'a4417e6f-fecd-4de8-b567-7b0420556985'   # Key Vault Certificates Officer

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault: {0} / {1}" -f $ResourceGroupName, $VaultName) -InformationAction Continue
Write-Information ("Certificate name: {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Target Entra app: {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Certificate subject: {0}" -f $certSubject) -InformationAction Continue

#endregion

#region Azure context + Key Vault preflight

$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
$subscriptionId = $account.id
Write-Information ("Subscription: {0} ({1})" -f $account.name, $subscriptionId) -InformationAction Continue

# Verify the vault exists (5a must have run).
$vaultJson = az resource show `
    --resource-type 'Microsoft.KeyVault/vaults' `
    --name $VaultName `
    --resource-group $ResourceGroupName `
    -o json --only-show-errors 2>$null
if (-not $vaultJson) {
    Write-Error ("Key Vault '{0}' not found in '{1}'. Run Wave 0 #5a (`scripts/New-AutomationKeyVault.ps1`) first." -f $VaultName, $ResourceGroupName)
    return
}
$vault = ($vaultJson -join "`n") | ConvertFrom-Json
$vaultResourceId = $vault.id
$certificateScope = "$vaultResourceId/certificates/$CertificateName"

#endregion

#region Target Entra app resolution

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
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 decision #1 mandates one app per display name. Reconcile manually before re-running." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$app = $appList[0]
$appId = $app.appId
$appObjectId = $app.id

# Resolve the service principal -- RBAC assignments go against the SP's
# object ID, not the app's object ID.
$spJson = az ad sp show --id $appId -o json --only-show-errors 2>$null
if (-not $spJson) {
    Write-Error ("Service principal for app '{0}' not found. Re-run Wave 0 #5b to reconcile." -f $DataPlaneAppDisplayName)
    return
}
$sp = ($spJson -join "`n") | ConvertFrom-Json
$spObjectId = $sp.id
Write-Information ("Entra app objectId      : {0}" -f $appObjectId) -InformationAction Continue
Write-Information ("Entra app appId         : {0}" -f $appId) -InformationAction Continue
Write-Information ("ServicePrincipal objectId: {0}" -f $spObjectId) -InformationAction Continue

#endregion

#region Certificate probe

# Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-show
$existingCertJson = az keyvault certificate show `
    --vault-name $VaultName `
    --name $CertificateName `
    -o json --only-show-errors 2>$null

$certExists = [bool]$existingCertJson
$existingCert = $null
if ($certExists) {
    $existingCert = ($existingCertJson -join "`n") | ConvertFrom-Json
    Write-Information ("NoChange probe: certificate '{0}' already exists in vault '{1}' (thumbprint x5t: {2})." -f $CertificateName, $VaultName, $existingCert.x509ThumbprintHex) -InformationAction Continue
}
else {
    Write-Information ("Create probe: certificate '{0}' does not exist in vault '{1}'. Will generate self-signed per ADR 0011 decision #1." -f $CertificateName, $VaultName) -InformationAction Continue
}

#endregion

#region WhatIf gate

$target = "certificate '$CertificateName' in vault '$VaultName' + keyCredential on app '$DataPlaneAppDisplayName' + KV RBAC on SP '$spObjectId'"
$action = "Bootstrap data-plane automation certificate per ADR 0011"

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    Write-Information '' -InformationAction Continue
    Write-Information '-WhatIf specified. Planned writes:' -InformationAction Continue
    if (-not $certExists) {
        Write-Information ("  + Create certificate '{0}' in vault '{1}' (self-signed, RSA-{2}, SHA-256, {3}-month, non-exportable, subject '{4}')." -f $CertificateName, $VaultName, $certKeySize, $certValidityMonths, $certSubject) -InformationAction Continue
    }
    else {
        Write-Information ("  = Reuse certificate '{0}'." -f $CertificateName) -InformationAction Continue
    }
    Write-Information ("  ? keyCredentials reconcile on app '{0}' (requires cert thumbprint; skipped under -WhatIf)." -f $DataPlaneAppDisplayName) -InformationAction Continue
    Write-Information ("  ? RBAC 'Key Vault Certificate User' on SP '{0}' scoped to '{1}' (skipped under -WhatIf)." -f $spObjectId, $certificateScope) -InformationAction Continue
    Write-Information ("  ? RBAC 'Key Vault Certificates Officer' on SP '{0}' scoped to '{1}' (skipped under -WhatIf)." -f $spObjectId, $vaultResourceId) -InformationAction Continue
    return
}

#endregion

#region Certificate create

if (-not $certExists) {
    # Build the certificate policy per ADR 0011 decision #1.
    # Reference: https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-policy
    $policy = [ordered]@{
        issuerParameters = @{ name = 'Self' }
        keyProperties = [ordered]@{
            exportable = $certExportable
            keyType    = $certKeyType
            keySize    = $certKeySize
            reuseKey   = $false
        }
        secretProperties = @{ contentType = 'application/x-pkcs12' }
        x509CertificateProperties = [ordered]@{
            subject           = $certSubject
            keyUsage          = $certKeyUsage
            validityInMonths  = $certValidityMonths
        }
        lifetimeActions = @(
            [ordered]@{
                trigger = @{ daysBeforeExpiry = 45 }
                action  = @{ actionType = 'EmailContacts' }
            }
        )
    }
    $policyJson = $policy | ConvertTo-Json -Depth 6 -Compress

    $policyFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $policyFile.FullName -Value $policyJson -NoNewline -Encoding utf8
        # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-create
        $null = az keyvault certificate create `
            --vault-name $VaultName `
            --name $CertificateName `
            --policy "@$($policyFile.FullName)" `
            -o json --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Error "az keyvault certificate create failed with exit code $LASTEXITCODE."
            return
        }
    }
    finally {
        Remove-Item -LiteralPath $policyFile.FullName -Force -ErrorAction SilentlyContinue
    }

    # Re-fetch via `show` to capture the finalized x509Thumbprint — the
    # create response returns before async finalization and leaves the
    # thumbprint fields null. Reference:
    # https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-show
    $showJson = az keyvault certificate show `
        --vault-name $VaultName `
        --name $CertificateName `
        -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $showJson) {
        Write-Error 'Certificate create reported success but subsequent show call failed; re-run to retry.'
        return
    }
    $existingCert = ($showJson -join "`n") | ConvertFrom-Json
    Write-Information ("  + Created certificate '{0}' (thumbprint x5t: {1})." -f $CertificateName, $existingCert.x509ThumbprintHex) -InformationAction Continue
}

# Normalize thumbprint to hex-uppercase with no separators for comparison.
if (-not $existingCert.x509ThumbprintHex) {
    Write-Error "Certificate '$CertificateName' returned a null thumbprint. Re-run after the async create completes, or inspect the vault manually."
    return
}
$thumbprint = ([string]$existingCert.x509ThumbprintHex).ToUpperInvariant()

# Pull the raw DER-encoded public cert for upload to Graph keyCredentials.
# Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-show
# The `cer` field of the cert object is already base64-encoded DER.
$certBlob = [string]$existingCert.cer
if (-not $certBlob) {
    # Older az versions surface the cert body under `x509Certificate` instead.
    $showJson = az keyvault certificate show --vault-name $VaultName --name $CertificateName -o json --only-show-errors
    $showObj = ($showJson -join "`n") | ConvertFrom-Json
    $certBlob = [string]$showObj.cer
    if (-not $certBlob) {
        Write-Error "Failed to read the certificate public-key blob from Key Vault."
        return
    }
}

#endregion

#region Entra keyCredential reconcile

# Startup-invariant enforcement (ADR 0011 decision #6 layer 3): the app
# must currently carry either zero credentials (bootstrap) or exactly
# one credential whose thumbprint matches the one we just resolved.
# Any other state is an anomaly and the script refuses to overwrite.
# Reference: https://learn.microsoft.com/en-us/graph/api/application-get
$appDetailJson = az ad app show --id $appObjectId -o json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app show failed with exit code $LASTEXITCODE."
    return
}
$appDetail = ($appDetailJson -join "`n") | ConvertFrom-Json
$existingCreds = @($appDetail.keyCredentials)

function Format-Thumbprint {
    param([object]$Entry)
    # customKeyIdentifier is the SHA-1 thumbprint. Microsoft Graph returns
    # it base64-encoded (28 chars); `az ad app show` pre-decodes it to
    # uppercase hex (40 chars). Handle both and normalize to uppercase
    # hex with no separators for comparison.
    if ($null -eq $Entry.customKeyIdentifier) { return $null }
    $value = [string]$Entry.customKeyIdentifier
    if ($value -match '^[0-9A-Fa-f]{40}$') {
        return $value.ToUpperInvariant()
    }
    try {
        $bytes = [Convert]::FromBase64String($value)
        return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToUpperInvariant()
    }
    catch {
        return $null
    }
}

$existingThumbprints = @($existingCreds | ForEach-Object { Format-Thumbprint $_ } | Where-Object { $_ })

if ($existingThumbprints.Count -eq 0) {
    # Bootstrap path -- PATCH the application with a single keyCredentials
    # entry. `application:addKey` cannot be used on an app with zero
    # existing credentials per the Graph docs. Reference:
    # https://learn.microsoft.com/en-us/graph/api/application-addkey
    # https://learn.microsoft.com/en-us/graph/api/application-update
    $keyCredBody = [ordered]@{
        keyCredentials = @(
            [ordered]@{
                type        = 'AsymmetricX509Cert'
                usage       = 'Verify'
                key         = $certBlob  # base64-encoded DER
                displayName = "kv:${VaultName}/${CertificateName}"
            }
        )
    }
    $keyCredJson = $keyCredBody | ConvertTo-Json -Depth 6 -Compress

    $patchFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $patchFile.FullName -Value $keyCredJson -NoNewline -Encoding utf8
        $null = az rest `
            --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$($patchFile.FullName)" `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Graph PATCH /applications/{id} keyCredentials failed with exit code $LASTEXITCODE."
            return
        }
    }
    finally {
        Remove-Item -LiteralPath $patchFile.FullName -Force -ErrorAction SilentlyContinue
    }

    # Re-read to capture the keyId Graph assigned.
    $appAfterJson = az ad app show --id $appObjectId -o json --only-show-errors
    $appAfter = ($appAfterJson -join "`n") | ConvertFrom-Json
    $newCred = @($appAfter.keyCredentials) | Where-Object { (Format-Thumbprint $_) -eq $thumbprint } | Select-Object -First 1
    if (-not $newCred) {
        Write-Error 'keyCredentials PATCH succeeded but the new thumbprint could not be found on the app. Re-run to retry.'
        return
    }
    Write-Information ("  + Attached keyCredential (keyId: {0}, thumbprint: {1})." -f $newCred.keyId, $thumbprint) -InformationAction Continue
    $keyCredentialId = $newCred.keyId
}
elseif ($existingThumbprints.Count -eq 1) {
    if ($existingThumbprints[0] -eq $thumbprint) {
        $matchCred = @($existingCreds | Where-Object { (Format-Thumbprint $_) -eq $thumbprint })[0]
        Write-Information ("  = keyCredential already present (keyId: {0})." -f $matchCred.keyId) -InformationAction Continue
        $keyCredentialId = $matchCred.keyId
    }
    else {
        Write-Error ("App '{0}' already carries a single keyCredential with thumbprint '{1}' which does not match the Key Vault certificate '{2}' (thumbprint '{3}'). ADR 0011 decision #6 layer 3: refusing to overwrite an existing credential. Reconcile manually (rotation path, or delete the stale credential) before re-running." -f $DataPlaneAppDisplayName, $existingThumbprints[0], $CertificateName, $thumbprint)
        return
    }
}
else {
    Write-Error ("App '{0}' carries {1} keyCredentials ({2}). ADR 0011 decision #6 layer 3: only the rotation workflow is permitted to create an overlap state. Bootstrap refuses to proceed." -f $DataPlaneAppDisplayName, $existingThumbprints.Count, ($existingThumbprints -join ', '))
    return
}

#endregion

#region Key Vault RBAC reconcile

function Assert-RoleAssignment {
    param(
        [Parameter(Mandatory)][string]$RoleId,
        [Parameter(Mandatory)][string]$RoleName,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$PrincipalObjectId
    )

    # Reference: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-list
    $existingJson = az role assignment list `
        --assignee $PrincipalObjectId `
        --role $RoleId `
        --scope $Scope `
        -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "az role assignment list failed with exit code $LASTEXITCODE (role: $RoleName, scope: $Scope)."
        return $null
    }
    $existing = @()
    if ($existingJson) { $existing = @(($existingJson -join "`n") | ConvertFrom-Json) }
    # Filter for exact scope + role ID (the CLI sometimes returns parent-scope assignments).
    $exact = @($existing | Where-Object { $_.scope -eq $Scope -and $_.roleDefinitionId -like "*/$RoleId" })
    if ($exact.Count -gt 0) {
        Write-Information ("  = RBAC '{0}' already assigned to SP '{1}' at '{2}' (assignment id: {3})." -f $RoleName, $PrincipalObjectId, $Scope, $exact[0].id) -InformationAction Continue
        return $exact[0].id
    }

    # Reference: https://learn.microsoft.com/en-us/cli/azure/role/assignment#az-role-assignment-create
    $createJson = az role assignment create `
        --assignee-object-id $PrincipalObjectId `
        --assignee-principal-type 'ServicePrincipal' `
        --role $RoleId `
        --scope $Scope `
        -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "az role assignment create failed with exit code $LASTEXITCODE (role: $RoleName, scope: $Scope)."
        return $null
    }
    $created = ($createJson -join "`n") | ConvertFrom-Json
    Write-Information ("  + Granted RBAC '{0}' to SP '{1}' at '{2}' (assignment id: {3})." -f $RoleName, $PrincipalObjectId, $Scope, $created.id) -InformationAction Continue
    return $created.id
}

$certUserAssignmentId = Assert-RoleAssignment -RoleId $roleCertUserId -RoleName 'Key Vault Certificate User' -Scope $certificateScope -PrincipalObjectId $spObjectId
if (-not $certUserAssignmentId) { return }
$certOfficerAssignmentId = Assert-RoleAssignment -RoleId $roleCertOfficerId -RoleName 'Key Vault Certificates Officer' -Scope $vaultResourceId -PrincipalObjectId $spObjectId
if (-not $certOfficerAssignmentId) { return }

#endregion

#region Output

Write-Information '' -InformationAction Continue
Write-Information ('certificateName         : {0}' -f $CertificateName) -InformationAction Continue
Write-Information ('certificateThumbprint   : {0}' -f $thumbprint) -InformationAction Continue
Write-Information ('certificateSecretId     : {0}' -f $existingCert.sid) -InformationAction Continue
Write-Information ('keyCredential keyId     : {0}' -f $keyCredentialId) -InformationAction Continue
Write-Information ('rbac certUser assignment: {0}' -f $certUserAssignmentId) -InformationAction Continue
Write-Information ('rbac certOfficer assignment: {0}' -f $certOfficerAssignmentId) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Done. Wave 0 automation identity (5.0 + 5a + 5b + 5c) is complete. Next: downstream Wave 0 items (a.1, a.3, #3, #4, #8) can now consume the data-plane app at `Connect-IPPSSession -AppId <appId> -CertificateThumbprint <thumbprint> -Organization contoso.onmicrosoft.com`.' -InformationAction Continue

#endregion
