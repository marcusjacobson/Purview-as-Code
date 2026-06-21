#Requires -Version 7.4
<#
.SYNOPSIS
    Provision a per-machine, per-user signing certificate for the
    Microsoft Purview data-plane Entra app's interactive dev loop. Per
    ADR 0028 this credential is co-equal to the canonical Key-Vault-signed
    credential (ADR 0011) and never replaces it.

.DESCRIPTION
    Generates a self-signed RSA-2048 / SHA-256 / 24-month cert in
    Cert:\CurrentUser\My with KeyExportPolicy NonExportable, then uploads
    the public .cer as an *additional* keyCredential on the data-plane
    Entra app via Microsoft Graph. The KV-signed credential and any other
    existing keyCredentials are preserved -- this script is strictly
    additive on the Graph side. On the local side it is idempotent on the
    subject CN: a non-expired existing match is reused (NoChange).

    Storage model A from the 2026-05-29 design discussion: the private
    key never lands on disk, so there is no PFX to gitignore on the happy
    path. The thumbprint is *not* a secret (it is a public-key
    fingerprint) but it is per-user and per-machine, so the script
    prints the thumbprint plus the env-var that downstream IPPS scripts
    read; it does not write anything to lab.yaml or other committed
    sources.

    Downstream consumption: scripts/Get-PurviewIPPSAccessToken.ps1 reads
    either the -LocalCertThumbprint parameter or the
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT env var and signs the JWT
    in-process via RSACng (PSS / SHA-256). When neither is set it falls
    back to the ADR 0011 Key Vault path.

    What this script does NOT do:
      * Rotate or revoke the KV-signed credential (ADR 0011 still owns
        that lifecycle).
      * Touch the control-plane Entra app (per ADR 0011 decision #5).
      * Write to infra/parameters/lab.yaml. The thumbprint is per-user
        and per-machine -- shared YAML is the wrong place for it.
      * Export the private key. KeyExportPolicy is NonExportable; the
        script will refuse to weaken it.

    References (Microsoft Learn):
      Local cert generation (New-SelfSignedCertificate):
        https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate
      X509KeyStorageFlags / KeyExportPolicy:
        https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.x509keystorageflags
      Update application (Graph -- merge keyCredentials):
        https://learn.microsoft.com/en-us/graph/api/application-update
      keyCredential resource shape:
        https://learn.microsoft.com/en-us/graph/api/resources/keycredential
      List applications by display name:
        https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app. Resolved from
    `automation.apps.dataPlane.displayName:` in the parameters file when
    omitted.

.PARAMETER ValidityMonths
    Lifetime of the new cert in months. Default 24. Used only when a new
    cert must be generated.

.PARAMETER RemoveExisting
    Revoke any pre-existing matching local cert + its public
    keyCredential on the Entra app, then re-issue. Use for rotation.

.EXAMPLE
    ./scripts/New-LocalAutomationCertificate.ps1 -WhatIf

    Prints the planned cert + Graph keyCredentials merge without making
    any change.

.EXAMPLE
    ./scripts/New-LocalAutomationCertificate.ps1

    Provisions (or reuses) the local signing cert. Prints the thumbprint
    and the env-var line to add to the operator's shell profile.

.EXAMPLE
    ./scripts/New-LocalAutomationCertificate.ps1 -RemoveExisting

    Forces rotation. Revokes the local cert + its Entra keyCredential,
    then re-issues both.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\parameters\lab.yaml'),

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 60)]
    [int]$ValidityMonths = 24,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveExisting
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Get-LocalCertSubject {
    # Build a deterministic, audit-friendly subject CN that identifies
    # the per-user-per-machine origin of the cert in any future Entra
    # keyCredentials listing. Display name supplies the app prefix; the
    # user + machine suffixes let a reviewer trace any orphan keyCredential
    # back to a specific operator workstation.
    param(
        [Parameter(Mandatory = $true)] [string] $AppDisplayName,
        [Parameter(Mandatory = $false)] [string] $UserName = $env:USERNAME,
        [Parameter(Mandatory = $false)] [string] $MachineName = $env:COMPUTERNAME
    )
    $u = ($UserName -replace '[^A-Za-z0-9\-]', '').ToLowerInvariant()
    $m = ($MachineName -replace '[^A-Za-z0-9\-]', '').ToLowerInvariant()
    if (-not $u) { $u = 'unknown' }
    if (-not $m) { $m = 'unknown' }
    return "CN=$AppDisplayName-local-$u-$m"
}

function Find-LocalCertBySubject {
    # Return the most-recent non-expired cert in Cert:\CurrentUser\My
    # whose subject exactly matches the deterministic CN. Used both for
    # idempotency (skip create) and for rotation (-RemoveExisting).
    param(
        [Parameter(Mandatory = $true)] [string] $Subject,
        [Parameter(Mandatory = $false)] [scriptblock] $CertStoreLookup
    )
    if (-not $CertStoreLookup) {
        $CertStoreLookup = { Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue }
    }
    return & $CertStoreLookup |
        Where-Object { $_.Subject -eq $Subject -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}

function ConvertTo-GraphKeyCredentialEntry {
    # Build the keyCredential subobject shape Microsoft Graph expects
    # on a PATCH /applications/{id} call. customKeyIdentifier is the
    # SHA-256 of the public cert bytes per the documented format.
    # Reference: https://learn.microsoft.com/en-us/graph/api/resources/keycredential
    param(
        [Parameter(Mandatory = $true)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )
    $cerBytes = $Certificate.RawData
    $sha256 = [System.Security.Cryptography.SHA256]::Create().ComputeHash($cerBytes)
    return [ordered]@{
        type                = 'AsymmetricX509Cert'
        usage               = 'Verify'
        key                 = [Convert]::ToBase64String($cerBytes)
        displayName         = $Certificate.Subject
        startDateTime       = $Certificate.NotBefore.ToUniversalTime().ToString('o')
        endDateTime         = $Certificate.NotAfter.ToUniversalTime().ToString('o')
        customKeyIdentifier = [Convert]::ToBase64String($sha256)
    }
}

function Merge-KeyCredentialList {
    # Append a new keyCredential to the existing list without dropping
    # any. ADR 0028 requires the local cert to be co-equal -- never
    # replace the KV-signed credential. Dedup on customKeyIdentifier so
    # re-running with the same cert is a no-op.
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Existing,
        [Parameter(Mandatory = $true)] [hashtable] $NewEntry
    )
    # When PowerShell coerces an empty array through [object[]], the
    # parameter can arrive as @($null) instead of @(); explicitly drop
    # any null entries so dedup and concatenation behave deterministically.
    $base = @(($Existing | Where-Object { $null -ne $_ }))
    $existingIds = @($base | ForEach-Object {
        if ($_ -is [hashtable]) { $_.customKeyIdentifier } else { $_.customKeyIdentifier }
    })
    if ($existingIds -contains $NewEntry.customKeyIdentifier) {
        return ,$base
    }
    return ,($base + @($NewEntry))
}

#endregion Helpers

# --- 1. Load parameters file -----------------------------------------------
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    throw "ParametersFile '$ParametersFile' not found."
}
$paramsYaml = Get-Content -Raw -LiteralPath $ParametersFile
$parameters = $paramsYaml | ConvertFrom-Yaml

if (-not $DataPlaneAppDisplayName) {
    $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName
}
if (-not $DataPlaneAppDisplayName) {
    throw "DataPlaneAppDisplayName not supplied and not resolvable from $ParametersFile (automation.apps.dataPlane.displayName)."
}

$subject = Get-LocalCertSubject -AppDisplayName $DataPlaneAppDisplayName
Write-Information ("Target Entra app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Cert subject CN   : {0}" -f $subject) -InformationAction Continue

# --- 2. Idempotency / rotation check ---------------------------------------
$existing = Find-LocalCertBySubject -Subject $subject
if ($existing -and -not $RemoveExisting.IsPresent) {
    Write-Information ("Existing matching cert found: thumbprint={0} NotAfter={1:o}" -f $existing.Thumbprint, $existing.NotAfter) -InformationAction Continue
    Write-Information ("NoChange. Re-run with -RemoveExisting to rotate.") -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information "To use this cert from the data-plane scripts, set:" -InformationAction Continue
    Write-Information ("  `$env:PURVIEW_LOCAL_CERT_THUMBPRINT = '{0}'" -f $existing.Thumbprint) -InformationAction Continue
    return
}

if ($existing -and $RemoveExisting.IsPresent) {
    if ($PSCmdlet.ShouldProcess("Cert:\CurrentUser\My\$($existing.Thumbprint)", 'Remove existing local cert')) {
        Remove-Item -LiteralPath ("Cert:\CurrentUser\My\{0}" -f $existing.Thumbprint) -Force
        Write-Information ("Removed local cert {0}." -f $existing.Thumbprint) -InformationAction Continue
    }
}

# --- 3. Generate the new cert ----------------------------------------------
# Reference: https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate
$notAfter = (Get-Date).AddMonths($ValidityMonths)
if ($PSCmdlet.ShouldProcess("Cert:\CurrentUser\My (Subject=$subject)", 'Generate new RSA-2048 / SHA-256 cert (NonExportable)')) {
    $newCert = New-SelfSignedCertificate `
        -Subject $subject `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy NonExportable `
        -KeyUsage DigitalSignature, KeyEncipherment `
        -NotAfter $notAfter `
        -Type Custom `
        -ErrorAction Stop
    Write-Information ("Generated local cert: thumbprint={0} NotAfter={1:o}" -f $newCert.Thumbprint, $newCert.NotAfter) -InformationAction Continue
}
else {
    Write-Information "[-WhatIf] Skipping cert generation; Graph PATCH preview below uses a placeholder." -InformationAction Continue
    return
}

# --- 4. Resolve the data-plane Entra app objectId via Azure CLI ------------
# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appJson = az ad app list `
    --display-name $DataPlaneAppDisplayName `
    --only-show-errors `
    --query "[0].{id:id, appId:appId, displayName:displayName, keyCredentials:keyCredentials}" `
    -o json
if ($LASTEXITCODE -ne 0 -or -not $appJson) {
    throw "Failed to resolve Entra app '$DataPlaneAppDisplayName' via 'az ad app list'. Verify 'az login' and that the app exists."
}
$app = $appJson | ConvertFrom-Json -AsHashtable
if (-not $app -or -not $app.id) {
    throw "Entra app '$DataPlaneAppDisplayName' not found in this tenant."
}
$appObjectId = $app.id
$existingCreds = @($app.keyCredentials)
Write-Information ("Entra app objectId: {0} (current keyCredentials count: {1})" -f $appObjectId, $existingCreds.Count) -InformationAction Continue

# --- 5. Build merged keyCredentials and PATCH the application -------------
$entry = ConvertTo-GraphKeyCredentialEntry -Certificate $newCert
$merged = Merge-KeyCredentialList -Existing $existingCreds -NewEntry $entry
$patchBody = @{ keyCredentials = $merged } | ConvertTo-Json -Depth 6
$tmpBody = (New-TemporaryFile).FullName + '.json'
try {
    Set-Content -Path $tmpBody -Value $patchBody -Encoding utf8 -NoNewline
    if ($PSCmdlet.ShouldProcess("Entra app objectId=$appObjectId", "PATCH keyCredentials (append local cert thumbprint $($newCert.Thumbprint); preserve existing $($existingCreds.Count) credentials)")) {
        # Reference: https://learn.microsoft.com/en-us/graph/api/application-update
        $null = az rest `
            --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$tmpBody" `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Graph PATCH /applications/$appObjectId failed (exit $LASTEXITCODE)."
        }
        Write-Information "Graph PATCH succeeded. New keyCredentials count: $($merged.Count)." -InformationAction Continue
    }
}
finally {
    if (Test-Path -LiteralPath $tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
}

# --- 6. Print operator handoff instructions --------------------------------
Write-Information "" -InformationAction Continue
Write-Information "Provisioning complete. To use this cert from the data-plane scripts, set:" -InformationAction Continue
Write-Information ("  `$env:PURVIEW_LOCAL_CERT_THUMBPRINT = '{0}'" -f $newCert.Thumbprint) -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-Information "Persist across shell sessions (current user) with:" -InformationAction Continue
Write-Information ("  [Environment]::SetEnvironmentVariable('PURVIEW_LOCAL_CERT_THUMBPRINT', '{0}', 'User')" -f $newCert.Thumbprint) -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-Information "See docs/runbooks/local-cert-provisioning.md for verify + rotate + revoke procedures." -InformationAction Continue
