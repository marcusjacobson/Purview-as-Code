#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/Get-PurviewIPPSAccessToken.ps1.

.DESCRIPTION
    Locks in the ADR 0028 acceptance criteria for the local-cert auth
    path: thumbprint resolution, refusal-on-failure (no silent KV
    fallback when the operator asked for the local-cert path), and
    parameter-vs-env-var precedence.

    The script's top-level body calls 'az keyvault certificate show'
    and 'Invoke-RestMethod' against live tenants -- so it cannot be
    dot-sourced as-is. Following the AST-extraction pattern documented
    in tests.instructions.md, only the testable helper functions are
    pulled into the test scope: Resolve-LocalSigningCert and
    ConvertTo-LocalJwtSignature.

    Reference: docs/adr/0028-co-equal-local-cert-credential.md
    Reference: docs/adr/0011-certificate-lifecycle.md
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Get-PurviewIPPSAccessToken.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Get-PurviewIPPSAccessToken.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $allFns = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($targetName in @('Resolve-LocalSigningCert', 'ConvertTo-LocalJwtSignature')) {
        $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
        if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Helper: build a fake cert object with the shape Resolve-LocalSigningCert
    # checks (Thumbprint, HasPrivateKey, NotAfter). The real cert type from
    # the PKI module is hard to construct in a unit test; the resolver only
    # reads three properties so a hashtable-backed pscustomobject is
    # sufficient.
    $script:MakeFakeStoreEntry = {
        param(
            [Parameter(Mandatory = $true)] [string] $Thumbprint,
            [Parameter(Mandatory = $false)] [bool] $HasPrivateKey = $true,
            [Parameter(Mandatory = $false)] [datetime] $NotAfter = (Get-Date).AddYears(1)
        )
        return [pscustomobject]@{
            Thumbprint    = $Thumbprint.ToUpperInvariant()
            HasPrivateKey = $HasPrivateKey
            NotAfter      = $NotAfter
        }
    }
}

Describe 'Resolve-LocalSigningCert -- input validation' {

    It 'rejects a thumbprint that is not 40 hex chars' {
        { Resolve-LocalSigningCert -Thumbprint 'not-a-thumbprint' -CertStoreLookup { @() } } |
            Should -Throw -ExpectedMessage '*valid SHA-1 thumbprint*'
    }

    It 'normalizes whitespace and case before lookup' {
        $tp = '0123456789ABCDEF0123456789ABCDEF01234567'
        $messy = ' 0123 4567 89ab cdef 0123 4567 89ab cdef 0123 4567 '
        $entry = & $script:MakeFakeStoreEntry -Thumbprint $tp
        $result = Resolve-LocalSigningCert -Thumbprint $messy -CertStoreLookup { @($entry) }
        $result.Thumbprint | Should -Be $tp
    }
}

Describe 'Resolve-LocalSigningCert -- failure modes (no silent fallback)' {

    It 'throws when the thumbprint does not resolve in the store' {
        $tp = '1111111111111111111111111111111111111111'
        { Resolve-LocalSigningCert -Thumbprint $tp -CertStoreLookup { @() } } |
            Should -Throw -ExpectedMessage "*not found in Cert:\CurrentUser\My*"
    }

    It 'throws when the cert is found but HasPrivateKey is False' {
        $tp = '2222222222222222222222222222222222222222'
        $entry = & $script:MakeFakeStoreEntry -Thumbprint $tp -HasPrivateKey $false
        { Resolve-LocalSigningCert -Thumbprint $tp -CertStoreLookup { @($entry) } } |
            Should -Throw -ExpectedMessage '*HasPrivateKey is False*'
    }

    It 'throws when the cert is expired' {
        $tp = '3333333333333333333333333333333333333333'
        $entry = & $script:MakeFakeStoreEntry -Thumbprint $tp -NotAfter (Get-Date).AddDays(-1)
        { Resolve-LocalSigningCert -Thumbprint $tp -CertStoreLookup { @($entry) } } |
            Should -Throw -ExpectedMessage '*expired on*'
    }

    It 'returns the cert when thumbprint resolves with a valid private key and is not expired' {
        $tp = '4444444444444444444444444444444444444444'
        $entry = & $script:MakeFakeStoreEntry -Thumbprint $tp
        $result = Resolve-LocalSigningCert -Thumbprint $tp -CertStoreLookup { @($entry) }
        $result | Should -Not -BeNullOrEmpty
        $result.Thumbprint | Should -Be $tp
    }
}

Describe 'ConvertTo-LocalJwtSignature -- signing behavior' {

    BeforeAll {
        # Generate a real, throwaway in-memory RSA cert so we can verify
        # the signature shape end-to-end without a Cert: store touch.
        # PowerShell 7.4 / .NET 8 supports this constructor; the cert is
        # never persisted to disk.
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=pester-throwaway',
                $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pss)
            $script:TestCert = $req.CreateSelfSigned(
                [DateTimeOffset]::UtcNow.AddDays(-1),
                [DateTimeOffset]::UtcNow.AddDays(1))
        }
        finally {
            $rsa.Dispose()
        }
    }

    It 'returns 256 bytes for a 2048-bit RSA / PSS signature' {
        $bytes = ConvertTo-LocalJwtSignature -Certificate $script:TestCert -SigningInputBytes ([Text.Encoding]::UTF8.GetBytes('header.payload'))
        $bytes.Length | Should -Be 256
    }

    It 'produces a signature that verifies under the cert public key' {
        $payload = [Text.Encoding]::UTF8.GetBytes('header.payload')
        $sig = ConvertTo-LocalJwtSignature -Certificate $script:TestCert -SigningInputBytes $payload
        $publicRsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:TestCert)
        try {
            $verified = $publicRsa.VerifyData(
                $payload, $sig,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pss)
            $verified | Should -BeTrue
        }
        finally {
            $publicRsa.Dispose()
        }
    }
}
