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

function Test-KeyVaultFirewallClosure {
    # Classify an `az keyvault` failure as "the vault's public endpoint was
    # closed underneath us" rather than a permission or lookup problem.
    #
    # Both spellings are emitted by the same event: the CLI prints the ARM
    # error text, and the inner code is what the service returns. Matching
    # either keeps this working if one of the two wordings changes.
    # Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/network-security
    param([Parameter(Mandatory = $false)][AllowNull()][string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text -match 'ForbiddenByConnection') -or
           ($Text -match 'Public network access is disabled')
}

function Get-KeyVaultPublicAccessState {
    # Read back the vault's firewall posture for a diagnostic message. Best
    # effort by design: this runs on a path that has ALREADY failed, and the
    # control-plane read can fail too (no reader role, wrong subscription).
    # A diagnostic that throws would replace the real error with its own.
    # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show
    param([Parameter(Mandatory = $true)][string] $VaultName)

    try {
        $state = az keyvault show --name $VaultName `
            --query '{pna:properties.publicNetworkAccess,da:properties.networkAcls.defaultAction}' `
            --only-show-errors -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $state) { return 'unknown (control-plane read failed)' }
        return ([string]$state).Trim() -replace '\s+', '/'
    }
    catch { return 'unknown (control-plane read threw)' }
}

function Set-KeyVaultReopenedFlag {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Supporting ShouldProcess here would reintroduce the exact defect this function exists to prevent. Its callers run inside the deploy workflows enumerate pass, which invokes the reconciler with -WhatIf, and this function records a CLEANUP HINT for the surrounding job rather than performing the previewed operation. Muted under -WhatIf, a run whose retry re-opened the Key Vault would leave it open with no run owning the window -- see issues #311 and #312, where the same ShouldProcess-honouring plumbing silently swallowed a stderr capture. It changes no tenant, Azure or filesystem state beyond appending one line to the GitHub Actions env file.')]
    # Tell the surrounding GitHub Actions job that this run re-opened the
    # vault and therefore owns the window now. No-op outside Actions, and
    # best effort inside it: failing to write a cleanup hint must never be
    # what fails a run that has otherwise recovered.
    param([Parameter(Mandatory = $false)][string] $EnvFilePath = $env:GITHUB_ENV)

    if ([string]::IsNullOrWhiteSpace($EnvFilePath)) { return $false }
    try {
        $WhatIfPreference = $false
        Add-Content -LiteralPath $EnvFilePath -Value 'KV_REOPENED_BY_RETRY=true'
        return $true
    }
    catch { return $false }
}

function Invoke-KeyVaultCliWithFirewallRetry {
    # Run a Key Vault DATA-PLANE call, and survive the shared firewall being
    # closed underneath it mid-run.
    #
    # WHY THIS EXISTS (issue #306). Every deploy-* and sync-* workflow opens
    # the one shared vault firewall at the start of its job and closes it in
    # an `if: always()` step at the end. Nothing serialises them against each
    # other, so a push that fans out to several workflows -- any push touching
    # this file, `infra/parameters/*.yaml`, or `scripts/modules/DirectionPolicy.psm1`
    # -- has the first run to FINISH re-lock the vault while the rest are still
    # working. Measured on dev 2026-09-07: deploy-irm re-locked at 23:47:47 and
    # three sibling runs died within the next 27 seconds, each reporting a
    # permission problem that did not exist.
    #
    # WHAT THIS DOES NOT DO. It does not make the race impossible -- another
    # run can re-lock between the re-open and the retry. It makes it
    # survivable. That was the deliberate trade: the alternative that removes
    # the race outright (deferring the re-lock to a scheduled job) widens the
    # window in which the vault is publicly reachable, which is a posture
    # change rather than a bug fix. Here the vault still ends closed and each
    # open window stays tied to one run.
    #
    # A shared GitHub `concurrency.group` is NOT the fix and must not be added
    # to that set: only one run may be pending per group, so five workflows
    # from one push become one run, one pending, and three SILENTLY CANCELLED
    # -- a loud failure turned into a silent no-apply, which is the confusion
    # issue #245 exists to remove.
    #
    # -Call must return a hashtable with ExitCode, Output and Error keys, so
    # the retry logic stays pure and unit-testable without invoking `az`.
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Call,
        [Parameter(Mandatory = $true)][string] $VaultName,
        [Parameter(Mandatory = $true)][string] $Operation,
        [Parameter(Mandatory = $true)][string] $PermissionHint,
        [Parameter(Mandatory = $false)][ValidateRange(1, 10)][int] $MaxAttempts = 3,
        # Matches the propagation wait the workflows use after their own open
        # (30s, issue #144). A network-rule change is not instantly effective,
        # so retrying immediately would just burn an attempt.
        [Parameter(Mandatory = $false)][ValidateRange(0, 120)][int] $PropagationSeconds = 30,
        [Parameter(Mandatory = $false)][scriptblock] $ReopenVault,
        [Parameter(Mandatory = $false)][scriptblock] $WaitAction,
        # Injectable so the unit tests do not shell out to `az` on the
        # give-up path. Production leaves it unset.
        [Parameter(Mandatory = $false)][scriptblock] $StateReader
    )

    if (-not $ReopenVault) {
        # Same command the workflows' own "Temporarily allow Key Vault public
        # access" step runs, under the same az context, which has already
        # exercised this permission by the time the script is called in CI.
        # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-update
        $ReopenVault = {
            param($Vault)
            $out = az keyvault update --name $Vault `
                --public-network-access Enabled --default-action Allow `
                --only-show-errors -o none 2>&1
            return @{ Ok = ($LASTEXITCODE -eq 0); Text = ($out | Out-String) }
        }
    }
    if (-not $WaitAction) { $WaitAction = { param($Seconds) Start-Sleep -Seconds $Seconds } }
    if (-not $StateReader) { $StateReader = { param($Vault) Get-KeyVaultPublicAccessState -VaultName $Vault } }

    $reopenFailed = $false
    $reopenText = ''
    $lastText = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = & $Call
        if ($result.ExitCode -eq 0 -and $result.Output) { return $result.Output }

        $lastText = (@($result.Output, $result.Error) | Where-Object { $_ }) -join "`n"
        if (-not (Test-KeyVaultFirewallClosure -Text $lastText)) { break }
        if ($attempt -ge $MaxAttempts) { break }

        Write-Warning ("Key Vault '{0}' refused {1}: its public endpoint is closed. A concurrent workflow re-locked it mid-run (issue #306). Re-opening and retrying (attempt {2} of {3})." -f $VaultName, $Operation, ($attempt + 1), $MaxAttempts)
        # Accepts either a bare boolean or @{ Ok; Text }. The boolean form
        # is kept because it is the simplest thing a caller can inject, and
        # the tests use it wherever the reason does not matter.
        $reopen = & $ReopenVault $VaultName
        $reopenOk = if ($reopen -is [hashtable]) { [bool]$reopen.Ok } else { [bool]$reopen }
        if (-not $reopenOk -and ($reopen -is [hashtable])) { $reopenText = [string]$reopen.Text }
        if ($reopenOk) {
            # Re-opening makes THIS run responsible for the window, and the
            # run that originally opened it has already re-locked and gone.
            # Since #311 the workflows' restore step only fires for the run
            # that owns the window, so without this flag a recovered run
            # would leave the vault open with nobody closing it.
            # Reference: https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#setting-an-environment-variable
            # $null = ... is load-bearing. PowerShell adds ANY uncaptured
            # value to the output stream, so a bare call returns the helper's
            # boolean alongside the certificate JSON and the caller parses
            # @($false, '{"cer":...}') instead of the JSON.
            $null = Set-KeyVaultReopenedFlag
            & $WaitAction $PropagationSeconds
        }
        else {
            # Keep going: a sibling run may re-open the vault anyway, and the
            # final message records that this run could not.
            $reopenFailed = $true
            & $WaitAction $PropagationSeconds
        }
    }

    if (Test-KeyVaultFirewallClosure -Text $lastText) {
        $state = & $StateReader $VaultName
        # Do not guess at the cause of a failed re-open. ARM rejects
        # simultaneous writes to one vault with ConflictError (issue #311),
        # and that is a LOST RACE, not a missing role -- blaming RBAC there
        # is the same wrong signpost that cost the first hour of #306.
        $extra = if (-not $reopenFailed) { '' }
        elseif ($reopenText -match 'ConflictError') {
            ' This run also could not re-open the firewall, because another run was writing to the vault at the same moment (ConflictError). That is contention, not a permissions problem.'
        }
        elseif ($reopenText) {
            " This run also could not re-open the firewall: $($reopenText.Trim())"
        }
        else {
            ' This run also could not re-open the firewall, and reported no reason; a missing firewall-toggler role is one possible cause.'
        }
        throw ("{0} failed on vault '{1}': THE VAULT FIREWALL IS CLOSED, not a permission problem. Current posture (publicNetworkAccess/defaultAction): {2}. A concurrent deploy-*/sync-* run re-locks the shared vault when it finishes, which fails any run still working (issue #306); {3} attempt(s) with a re-open in between did not recover.{4}" -f $Operation, $VaultName, $state, $MaxAttempts, $extra)
    }
    throw ("{0} failed on vault '{1}'. {2} Error: {3}" -f $Operation, $VaultName, $PermissionHint, $lastText.Trim())
}

function Invoke-AzCliCapture {
    # Run `az` and capture stdout, stderr and the exit code together. stderr
    # goes to a temp FILE rather than through `2>&1`, which would merge
    # ErrorRecords into the success stream and corrupt the JSON the callers
    # parse on the happy path.
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    # -WhatIf MUST NOT reach this function's plumbing. The callers run under
    # the deploy workflows' `-WhatIf` enumerate pass, and PowerShell's file
    # redirection is implemented through Out-File, which honours
    # ShouldProcess -- so `2>$errFile` silently becomes a no-op, stderr is
    # never captured, and Test-KeyVaultFirewallClosure is handed an EMPTY
    # string. A firewall closure then classifies as a generic failure, the
    # retry never fires, and the operator gets the old misleading permission
    # hint with a blank `Error:` on the end. Observed on lab run 34775003781.
    # Nothing here is a tenant write that -WhatIf should be suppressing: the
    # `az` call is a read (or a crypto op) and runs regardless; only this
    # function's own temp file was being skipped -- which also leaked it,
    # since Remove-Item was suppressed too.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables
    $WhatIfPreference = $false

    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = $null
        $code = 0
        try {
            $out = & az @Arguments 2>$errFile
            $code = $LASTEXITCODE
        }
        catch {
            # The script runs under $ErrorActionPreference = 'Stop', and newer
            # PowerShell versions can promote a native command's non-zero exit
            # into a terminating error ($PSNativeCommandUseErrorActionPreference).
            # Today it does not -- the pre-#306 code reached its own
            # `if ($LASTEXITCODE -ne 0)` check, which is how the original error
            # text got into the run log -- but a thrown failure must still arrive
            # at the caller as a classifiable RESULT, or the retry would never
            # see the firewall error it exists to recognise.
            $code = if ($LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
            $out = ''
            Add-Content -LiteralPath $errFile -Value ([string]$_) -ErrorAction SilentlyContinue
        }
        $err = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
        return @{
            ExitCode = $code
            Output   = ($out | Out-String).Trim()
            Error    = $err
        }
    }
    finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
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
    $certJson = Invoke-KeyVaultCliWithFirewallRetry -VaultName $VaultName `
        -Operation "Reading certificate '$CertificateName'" `
        -PermissionHint "Verify 'Key Vault Certificate User' role and that the cert exists." `
        -Call {
            Invoke-AzCliCapture -Arguments @(
                'keyvault', 'certificate', 'show',
                '--vault-name', $VaultName,
                '--name', $CertificateName,
                '--only-show-errors',
                '--query', '{cer:cer, kid:kid}',
                '-o', 'json'
            )
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
    # Second data-plane call, and the reason the retry is a helper rather than
    # a patch at the certificate read: on 2026-09-07 deploy-label-policies got
    # its certificate, applied successfully, and THEN died here on the
    # -VerifyPublished pass's second token acquisition (issue #306).
    $signResult = Invoke-KeyVaultCliWithFirewallRetry -VaultName $VaultName `
        -Operation 'Signing the JWT digest' `
        -PermissionHint "Verify 'Key Vault Crypto User' role on '$VaultName'." `
        -Call {
            Invoke-AzCliCapture -Arguments @(
                'keyvault', 'key', 'sign',
                '--vault-name', $VaultName,
                '--name', $CertificateName,
                '--algorithm', 'PS256',
                '--digest', $digestB64,
                '--only-show-errors',
                '-o', 'json'
            )
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
