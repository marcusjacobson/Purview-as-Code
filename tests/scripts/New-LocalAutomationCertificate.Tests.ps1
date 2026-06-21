#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Unit tests for scripts/New-LocalAutomationCertificate.ps1 helpers.

.DESCRIPTION
    Locks in ADR 0028 invariants for the keyCredentials merge path:

      1. The deterministic subject CN derives from the app display name
         plus a (user, machine) tuple so any future Entra keyCredentials
         listing traces back to the operator workstation that uploaded
         the public cert.
      2. Merge-KeyCredentialList NEVER drops or replaces an existing
         credential. The KV-signed credential (ADR 0011) must coexist
         with the local cert (ADR 0028) on the data-plane app.
      3. Re-running the merge with the same cert is a no-op (dedup on
         customKeyIdentifier) so an idempotent re-run produces no Graph
         PATCH drift.

    The script's top-level body calls 'az ad app list' and 'az rest'
    PATCH against live Microsoft Graph -- so it cannot be dot-sourced
    as-is. Following the AST-extraction pattern, only the testable
    helper functions are pulled in.

    Reference: docs/adr/0028-co-equal-local-cert-credential.md
    Reference: docs/adr/0011-certificate-lifecycle.md
    Reference: https://learn.microsoft.com/en-us/graph/api/resources/keycredential
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'New-LocalAutomationCertificate.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate New-LocalAutomationCertificate.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $allFns = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    foreach ($targetName in @('Get-LocalCertSubject', 'Find-LocalCertBySubject', 'ConvertTo-GraphKeyCredentialEntry', 'Merge-KeyCredentialList')) {
        $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
        if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Build a throwaway in-memory cert for ConvertTo-GraphKeyCredentialEntry.
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

Describe 'Get-LocalCertSubject' {

    It 'composes a deterministic CN from app + user + machine' {
        $cn = Get-LocalCertSubject -AppDisplayName 'gh-oidc-purview-data-plane' -UserName 'alice' -MachineName 'BOX01'
        $cn | Should -Be 'CN=gh-oidc-purview-data-plane-local-alice-box01'
    }

    It 'lowercases and strips non-alphanumeric characters from user and machine' {
        $cn = Get-LocalCertSubject -AppDisplayName 'gh-oidc-purview-data-plane' -UserName 'Alice.Smith' -MachineName 'BOX-02!'
        $cn | Should -Be 'CN=gh-oidc-purview-data-plane-local-alicesmith-box-02'
    }

    It 'substitutes "unknown" when user or machine resolve to empty after sanitisation' {
        $cn = Get-LocalCertSubject -AppDisplayName 'gh-oidc-purview-data-plane' -UserName '!!!' -MachineName ''
        $cn | Should -Be 'CN=gh-oidc-purview-data-plane-local-unknown-unknown'
    }
}

Describe 'Find-LocalCertBySubject' {

    It 'returns the newest non-expired match' {
        $entries = @(
            [pscustomobject]@{ Subject = 'CN=app'; NotAfter = (Get-Date).AddDays(30);  Thumbprint = 'AAA1' },
            [pscustomobject]@{ Subject = 'CN=app'; NotAfter = (Get-Date).AddDays(365); Thumbprint = 'AAA2' },
            [pscustomobject]@{ Subject = 'CN=app'; NotAfter = (Get-Date).AddDays(180); Thumbprint = 'AAA3' }
        )
        $r = Find-LocalCertBySubject -Subject 'CN=app' -CertStoreLookup { $entries }
        $r.Thumbprint | Should -Be 'AAA2'
    }

    It 'skips expired matches' {
        $entries = @(
            [pscustomobject]@{ Subject = 'CN=app'; NotAfter = (Get-Date).AddDays(-1); Thumbprint = 'OLD' }
        )
        $r = Find-LocalCertBySubject -Subject 'CN=app' -CertStoreLookup { $entries }
        $r | Should -BeNullOrEmpty
    }

    It 'skips subjects that do not match exactly' {
        $entries = @(
            [pscustomobject]@{ Subject = 'CN=other-app'; NotAfter = (Get-Date).AddDays(30); Thumbprint = 'XYZ' }
        )
        $r = Find-LocalCertBySubject -Subject 'CN=app' -CertStoreLookup { $entries }
        $r | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-GraphKeyCredentialEntry' {

    It 'returns the Graph keyCredential shape' {
        $entry = ConvertTo-GraphKeyCredentialEntry -Certificate $script:TestCert
        $entry.type  | Should -Be 'AsymmetricX509Cert'
        $entry.usage | Should -Be 'Verify'
        $entry.key   | Should -Not -BeNullOrEmpty
        $entry.customKeyIdentifier | Should -Not -BeNullOrEmpty
        $entry.startDateTime | Should -Match '^\d{4}-\d{2}-\d{2}T'
        $entry.endDateTime   | Should -Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'uses SHA-256(cert.RawData) as customKeyIdentifier' {
        $entry = ConvertTo-GraphKeyCredentialEntry -Certificate $script:TestCert
        $expected = [Convert]::ToBase64String(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash($script:TestCert.RawData))
        $entry.customKeyIdentifier | Should -Be $expected
    }
}

Describe 'Merge-KeyCredentialList -- co-equal invariant (ADR 0028)' {

    It 'appends without dropping existing credentials' {
        $existing = @(
            [pscustomobject]@{ customKeyIdentifier = 'EXISTING_KV_CRED'; displayName = 'CN=kv-signed' }
        )
        $newEntry = @{ customKeyIdentifier = 'NEW_LOCAL_CERT'; displayName = 'CN=local' }
        $merged = Merge-KeyCredentialList -Existing $existing -NewEntry $newEntry
        $merged.Count | Should -Be 2
        $merged[0].customKeyIdentifier | Should -Be 'EXISTING_KV_CRED'
        $merged[1].customKeyIdentifier | Should -Be 'NEW_LOCAL_CERT'
    }

    It 'is a no-op when the new entry already exists (dedup by customKeyIdentifier)' {
        $existing = @(
            [pscustomobject]@{ customKeyIdentifier = 'EXISTING_KV_CRED'; displayName = 'CN=kv-signed' },
            [pscustomobject]@{ customKeyIdentifier = 'NEW_LOCAL_CERT';  displayName = 'CN=local' }
        )
        $newEntry = @{ customKeyIdentifier = 'NEW_LOCAL_CERT'; displayName = 'CN=local' }
        $merged = Merge-KeyCredentialList -Existing $existing -NewEntry $newEntry
        $merged.Count | Should -Be 2
    }

    It 'handles an empty existing list' {
        $newEntry = @{ customKeyIdentifier = 'FIRST_CRED'; displayName = 'CN=first' }
        $merged = Merge-KeyCredentialList -Existing @() -NewEntry $newEntry
        $merged.Count | Should -Be 1
        $merged[0].customKeyIdentifier | Should -Be 'FIRST_CRED'
    }
}
