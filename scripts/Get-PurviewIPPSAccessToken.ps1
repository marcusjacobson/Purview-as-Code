<#
.SYNOPSIS
    Acquire an OAuth2 access token for Microsoft Security & Compliance PowerShell
    (Connect-IPPSSession -AccessToken) using a JWT client_assertion signed by
    either a local-machine certificate (interactive dev loop) or an Azure Key
    Vault key (CI).

.DESCRIPTION
    Two signing transports are supported, picked at runtime per ADR 0028:

      A. Local cert (Cert:\CurrentUser\My) -- selected when either
         -LocalCertThumbprint is supplied or $env:PURVIEW_LOCAL_CERT_THUMBPRINT
         is set. The script resolves the thumbprint to a certificate with
         HasPrivateKey=$true and signs the JWT digest in-process via RSA-PSS
         (PS256) with SHA-256. No Key Vault call, so no KV unlock window is
         required. Used for interactive dev-loop runs from the lab owner's
         workstation. The cert is provisioned by
         scripts/New-LocalAutomationCertificate.ps1 with KeyExportPolicy
         NonExportable; the public .cer is uploaded to the data-plane Entra
         app as an *additional* keyCredential, co-equal to the KV-signed
         credential per ADR 0028.

      B. Key Vault sign (kv-contoso-lab-01) -- the original ADR 0011 path,
         used whenever no local thumbprint is supplied. The script fetches
         the public cert via 'az keyvault certificate show' and signs the
         JWT digest via 'az keyvault key sign --algorithm PS256'. Private
         material never leaves the vault. Used by every CI workflow run
         because hosted GitHub runners have no Cert:\CurrentUser\My to
         inherit from.

    In both transports the script:

      1. Builds an RFC 7523 client_assertion JWT (header alg=PS256, x5t#S256).
      2. SHA-256 digests header.payload, signs with PSS padding.
      3. Exchanges the signed assertion at the Microsoft identity platform
         v2.0 token endpoint for an access token in the requested scope.

    The caller must have, depending on the selected transport:
      - Transport A (local cert): a private key on the local machine for the
        provided thumbprint. No KV roles are needed.
      - Transport B (KV sign): 'Key Vault Crypto User' on the vault
        (keys/sign), 'Key Vault Certificate User' (certs/get), and an active
        'az login' session.

    The Entra app referenced by -AppId must, for either transport:
      - Carry the corresponding public certificate in its 'keyCredentials'
        (transport A: uploaded by New-LocalAutomationCertificate.ps1;
         transport B: uploaded by New-AutomationCertificate.ps1).
      - For S&C access: have 'Office 365 Exchange Online > Exchange.ManageAsApp'
        granted with admin consent, AND be assigned the 'Compliance
        Administrator' (or Exchange Administrator) Entra role.

    References (Microsoft Learn):
      Connect-IPPSSession -AccessToken:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      JWT client_assertion shape (PS256, x5t#S256):
        https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials
      Microsoft identity platform v2.0 token endpoint:
        https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow
      Key Vault sign operation (digest input, base64url signature output):
        https://learn.microsoft.com/en-us/cli/azure/keyvault/key#az-keyvault-key-sign
        https://learn.microsoft.com/en-us/rest/api/keyvault/keys/sign/sign
      Key Vault RBAC roles:
        https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
      App-only auth for Exchange / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      X509KeyStorageFlags / RSA-PSS:
        https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.signdata
        https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsasignaturepadding

.PARAMETER VaultName
    Name of the Key Vault that holds the automation certificate (and its
    underlying RSA key with the same name). Used only when the KV transport
    is selected; ignored when -LocalCertThumbprint or
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT is supplied.

.PARAMETER CertificateName
    Name of the certificate (and key) in the vault. The cert and key share a
    name when KV manages cert generation. Used only by the KV transport.

.PARAMETER AppId
    Application (client) ID of the Entra app whose key credential includes
    the signing certificate.

.PARAMETER TenantId
    Entra tenant ID (GUID) used in the JWT 'aud' claim and the token endpoint
    URL.

.PARAMETER LocalCertThumbprint
    Optional. SHA-1 thumbprint of a certificate in Cert:\CurrentUser\My whose
    private key signs the JWT in-process. When set, the script skips the KV
    transport entirely. If both this parameter and the environment variable
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT are set, the parameter wins.
    Provisioned by scripts/New-LocalAutomationCertificate.ps1; the matching
    public .cer must be a keyCredential on the Entra app per ADR 0028.
    A resolution failure (thumbprint missing, no private key, cert expired)
    throws -- the script never silently falls back to KV when the operator
    has explicitly asked for the local-cert path.

.PARAMETER Scope
    OAuth2 v2.0 scope to request. Defaults to
    'https://outlook.office365.com/.default' which is the documented S&C / EXO
    app-only scope. Use 'https://ps.compliance.protection.outlook.com/.default'
    if the default returns a 'AADSTS500011 resource principal not found' error.

.PARAMETER Lifetime
    JWT assertion lifetime in seconds. Microsoft identity platform caps at 600
    (10 minutes). Default 300.

.OUTPUTS
    pscustomobject with: AccessToken (string), ExpiresOn (DateTime, UTC),
    Scope (string), TokenType (string).

.EXAMPLE
    # Transport A -- local cert; no KV unlock required.
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT = '0123456789ABCDEF0123456789ABCDEF01234567'
    $tok = ./scripts/Get-PurviewIPPSAccessToken.ps1 `
        -VaultName 'kv-contoso-lab-01' `
        -CertificateName 'gh-oidc-purview-data-plane' `
        -AppId '00000000-0000-0000-0000-000000000000' `
        -TenantId '00000000-0000-0000-0000-000000000000'
    Connect-IPPSSession -AccessToken $tok.AccessToken `
        -Organization 'contoso.onmicrosoft.com' -ShowBanner:$false

.EXAMPLE
    # Transport B -- KV sign; canonical CI path. Requires KV unlock window.
    $tok = ./scripts/Get-PurviewIPPSAccessToken.ps1 `
        -VaultName 'kv-contoso-lab-01' `
        -CertificateName 'gh-oidc-purview-data-plane' `
        -AppId '00000000-0000-0000-0000-000000000000' `
        -TenantId '00000000-0000-0000-0000-000000000000'
    Connect-IPPSSession -AccessToken $tok.AccessToken `
        -Organization 'contoso.onmicrosoft.com' -ShowBanner:$false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $VaultName,
    [Parameter(Mandatory = $true)] [string] $CertificateName,
    [Parameter(Mandatory = $true)] [string] $AppId,
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $false)] [string] $LocalCertThumbprint,
    [Parameter(Mandatory = $false)] [string] $Scope = 'https://outlook.office365.com/.default',
    [Parameter(Mandatory = $false)] [ValidateRange(60, 600)] [int] $Lifetime = 300
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url {
    param([Parameter(Mandatory = $true)] [byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Std {
    # Tolerant decode: accept either base64url or base64-standard input.
    param([Parameter(Mandatory = $true)] [string] $Value)
    $s = $Value.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    return [Convert]::FromBase64String($s)
}

function Resolve-LocalSigningCert {
    # Resolve a thumbprint to a usable signing certificate in
    # Cert:\CurrentUser\My. Throws with an explicit reason if the cert
    # cannot be used so the operator can fix root cause instead of
    # falling back silently to the KV path. Per ADR 0028: when the
    # caller has asked for the local-cert path, refusal is loud.
    param(
        [Parameter(Mandatory = $true)] [string] $Thumbprint,
        [Parameter(Mandatory = $false)] [scriptblock] $CertStoreLookup
    )
    $tp = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    if (-not ($tp -match '^[0-9A-F]{40}$')) {
        throw "LocalCertThumbprint '$Thumbprint' is not a valid SHA-1 thumbprint (expected 40 hex chars)."
    }
    if (-not $CertStoreLookup) {
        $CertStoreLookup = { Get-ChildItem -Path 'Cert:\CurrentUser\My' -ErrorAction Stop }
    }
    $candidate = & $CertStoreLookup | Where-Object { $_.Thumbprint -eq $tp } | Select-Object -First 1
    if (-not $candidate) {
        throw "LocalCertThumbprint '$tp' not found in Cert:\CurrentUser\My. Provision via scripts/New-LocalAutomationCertificate.ps1 or omit -LocalCertThumbprint / unset PURVIEW_LOCAL_CERT_THUMBPRINT to use the Key Vault path."
    }
    if (-not $candidate.HasPrivateKey) {
        throw "LocalCertThumbprint '$tp' was found in Cert:\CurrentUser\My but HasPrivateKey is False. The local-cert path requires the private key on this machine."
    }
    if ($candidate.NotAfter -lt (Get-Date)) {
        throw "LocalCertThumbprint '$tp' expired on $($candidate.NotAfter.ToString('o')). Re-issue via scripts/New-LocalAutomationCertificate.ps1 -RemoveExisting."
    }
    return $candidate
}

function ConvertTo-LocalJwtSignature {
    # Sign the UTF-8 bytes of the JWT signing input with RSA-PSS / SHA-256
    # using the cert's local private key. PSS padding matches the PS256
    # algorithm advertised in the JWT header (RFC 7518 §3.5).
    param(
        [Parameter(Mandatory = $true)] [System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
        [Parameter(Mandatory = $true)] [byte[]] $SigningInputBytes
    )
    # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.rsacertificateextensions.getrsaprivatekey
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) {
        throw "Could not obtain an RSA private key from certificate '$($Certificate.Thumbprint)'. The cert may not use an RSA key, or the private key may not be accessible to the current user."
    }
    try {
        # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.signdata
        # Reference: https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsasignaturepadding
        return $rsa.SignData(
            $SigningInputBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pss)
    }
    finally {
        $rsa.Dispose()
    }
}

# --- 0. Resolve auth path: local cert vs Key Vault ------------------------
# Per ADR 0028. Parameter wins over env var. If either is set, we use the
# local-cert path (and refuse to fall back silently on failure). If neither
# is set, we use the ADR 0011 Key Vault path.
$resolvedLocalThumbprint = if ($LocalCertThumbprint) {
    $LocalCertThumbprint
}
elseif ($env:PURVIEW_LOCAL_CERT_THUMBPRINT) {
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT
}
else { $null }

$localCert = $null
if ($resolvedLocalThumbprint) {
    Write-Verbose "Auth path: Local cert (Cert:\CurrentUser\My)"
    $localCert = Resolve-LocalSigningCert -Thumbprint $resolvedLocalThumbprint
}
else {
    Write-Verbose "Auth path: Key Vault ($VaultName / $CertificateName)"
}

# --- 1. Public cert bytes (for x5t#S256) -----------------------------------
if ($localCert) {
    $certBytes = $localCert.RawData
}
else {
    # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-show
    Write-Verbose "Fetching certificate '$CertificateName' from vault '$VaultName'."
    $certJson = az keyvault certificate show `
        --vault-name $VaultName `
        --name $CertificateName `
        --only-show-errors `
        --query "{cer:cer, kid:kid}" `
        -o json
    if ($LASTEXITCODE -ne 0 -or -not $certJson) {
        throw "Failed to read certificate '$CertificateName' from vault '$VaultName'. Verify 'Key Vault Certificate User' role and that the cert exists."
    }
    $certInfo = $certJson | ConvertFrom-Json
    $certBytes = [Convert]::FromBase64String($certInfo.cer)
}
$x5tS256 = ConvertTo-Base64Url -Bytes ([System.Security.Cryptography.SHA256]::Create().ComputeHash($certBytes))

# --- 2. Build JWT header and payload ---------------------------------------
# Reference: https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials
$now = [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s))
$header = [ordered]@{
    alg       = 'PS256'
    typ       = 'JWT'
    'x5t#S256' = $x5tS256
}
$payload = [ordered]@{
    aud = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    iss = $AppId
    sub = $AppId
    jti = [guid]::NewGuid().ToString()
    nbf = $now
    iat = $now
    exp = $now + $Lifetime
}

$headerJson  = ($header  | ConvertTo-Json -Compress)
$payloadJson = ($payload | ConvertTo-Json -Compress)
$headerB64   = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($headerJson))
$payloadB64  = ConvertTo-Base64Url -Bytes ([Text.Encoding]::UTF8.GetBytes($payloadJson))
$signingInput = "$headerB64.$payloadB64"

# --- 3. SHA-256 digest of signing input ------------------------------------
$signingInputBytes = [Text.Encoding]::UTF8.GetBytes($signingInput)

# --- 4. Sign: local cert in-process (PSS) or Key Vault (PS256) --------------
if ($localCert) {
    # Reference: https://datatracker.ietf.org/doc/html/rfc7518#section-3.5
    Write-Verbose "Signing JWT with local cert thumbprint '$($localCert.Thumbprint)' (RSA-PSS / SHA-256)."
    $sigBytes = ConvertTo-LocalJwtSignature -Certificate $localCert -SigningInputBytes $signingInputBytes
}
else {
    # Reference: https://learn.microsoft.com/en-us/rest/api/keyvault/keys/sign/sign
    # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault/key#az-keyvault-key-sign
    $digestBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($signingInputBytes)
    $digestB64 = [Convert]::ToBase64String($digestBytes)
    Write-Verbose "Signing JWT digest with Key Vault key '$CertificateName' (PS256)."
    $signResult = az keyvault key sign `
        --vault-name $VaultName `
        --name $CertificateName `
        --algorithm PS256 `
        --digest $digestB64 `
        --only-show-errors `
        -o json
    if ($LASTEXITCODE -ne 0 -or -not $signResult) {
        throw "Key Vault sign failed. Verify 'Key Vault Crypto User' role on '$VaultName'."
    }
    $sig = ($signResult | ConvertFrom-Json).signature
    # Azure CLI returns signature as base64url already, but normalize defensively.
    $sigBytes = ConvertFrom-Base64Std -Value $sig
}
$sigB64Url = ConvertTo-Base64Url -Bytes $sigBytes
$assertion = "$signingInput.$sigB64Url"

# --- 5. Exchange the assertion for an access token -------------------------
# Reference: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow
$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$body = @{
    client_id             = $AppId
    scope                 = $Scope
    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    client_assertion      = $assertion
    grant_type            = 'client_credentials'
}
Write-Verbose "POST $tokenUrl (scope=$Scope)"
try {
    $response = Invoke-RestMethod `
        -Method POST `
        -Uri $tokenUrl `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $body `
        -ErrorAction Stop
}
catch {
    $err = $_.ErrorDetails.Message
    if (-not $err) { $err = $_.Exception.Message }
    throw "Token exchange failed: $err"
}

[pscustomobject]@{
    AccessToken = $response.access_token
    ExpiresOn   = (Get-Date).ToUniversalTime().AddSeconds([int]$response.expires_in)
    Scope       = $Scope
    TokenType   = $response.token_type
}
