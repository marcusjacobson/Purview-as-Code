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

Describe 'Key Vault firewall retry (issue #306)' {

    BeforeAll {
        # Same AST-extract pattern the blocks above use. Get-KeyVaultPublicAccessState
        # is extracted too, so the failure message is built by the real function
        # rather than a stub -- it short-circuits on a failed `az` call, which is
        # what happens here since no Azure context exists in a unit test.
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($targetName in @(
                'Test-KeyVaultFirewallClosure',
                'Get-KeyVaultPublicAccessState',
                'Set-KeyVaultReopenedFlag',
                'Invoke-KeyVaultCliWithFirewallRetry')) {
            $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
            if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # A -Call double that fails the first N attempts with the supplied text
        # and then succeeds. Records the attempt count so the tests can assert
        # the loop ran as many times as they expect and no more.
        $script:NewFailingCall = {
            param(
                [int] $FailTimes,
                [string] $ErrorText,
                [string] $SuccessOutput = '{"cer":"AAAA","kid":"https://v/keys/k/1"}'
            )
            $state = [pscustomobject]@{ Attempts = 0 }
            $call = {
                $state.Attempts++
                if ($state.Attempts -le $FailTimes) {
                    return @{ ExitCode = 1; Output = ''; Error = $ErrorText }
                }
                return @{ ExitCode = 0; Output = $SuccessOutput; Error = '' }
            }.GetNewClosure()
            return [pscustomobject]@{ State = $state; Call = $call }
        }

        # Re-open / wait doubles. No sleeping, no az, and both record their calls
        # so a test can prove the retry actually re-opened the vault rather than
        # just calling again and getting lucky.
        $script:Reopened = 0
        $script:Waited = 0
        $script:OkReopen = { param($Vault) $script:Reopened++; return $true }
        $script:FailReopen = { param($Vault) $script:Reopened++; return $false }
        $script:NoWait = { param($Seconds) $script:Waited++ }
        # Keeps `az` out of the unit tests: the give-up path reads the vault
        # posture for its message, and that read is a control-plane call.
        $script:FakeState = { param($Vault) 'Disabled/Deny' }

        $script:Forbidden = '(Forbidden) Public network access is disabled and request is not from a trusted service nor via an approved private link. Inner error: { "code": "ForbiddenByConnection" }'
        $script:Rbac = "Caller is not authorized to perform action 'Microsoft.KeyVault/vaults/certificates/read' on the resource."
    }

    BeforeEach {
        $script:Reopened = 0
        $script:Waited = 0
    }

    Context 'Test-KeyVaultFirewallClosure classifies the failure' {

        It 'matches the service inner error code' {
            Test-KeyVaultFirewallClosure -Text 'Inner error: { "code": "ForbiddenByConnection" }' |
                Should -BeTrue
        }

        It 'matches the CLI prose, which is the wording an operator sees first' {
            Test-KeyVaultFirewallClosure -Text $script:Forbidden | Should -BeTrue
        }

        It 'does NOT match a genuine permission failure' {
            # The whole point: an RBAC problem must still fail fast and loudly
            # rather than being retried three times and then mis-reported as a
            # firewall race.
            Test-KeyVaultFirewallClosure -Text $script:Rbac | Should -BeFalse
        }

        It 'does not match empty, whitespace or null input' {
            Test-KeyVaultFirewallClosure -Text '' | Should -BeFalse
            Test-KeyVaultFirewallClosure -Text '   ' | Should -BeFalse
            Test-KeyVaultFirewallClosure -Text $null | Should -BeFalse
        }
    }

    Context 'The retry recovers a call the shared firewall interrupted' {

        It 'returns the output after one transient closure' {
            $f = & $script:NewFailingCall -FailTimes 1 -ErrorText $script:Forbidden
            $out = Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' `
                -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState
            $out | Should -Be '{"cer":"AAAA","kid":"https://v/keys/k/1"}'
            $f.State.Attempts | Should -Be 2
        }

        It 'actually re-opens the vault and waits for propagation between attempts' {
            # Without the re-open the retry would be a bare loop hoping someone
            # else fixes the vault, and without the wait it would burn its
            # attempts before a network-rule change could take effect.
            $f = & $script:NewFailingCall -FailTimes 1 -ErrorText $script:Forbidden
            Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' `
                -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState | Out-Null
            $script:Reopened | Should -Be 1
            $script:Waited | Should -Be 1
        }

        It 'recovers on the last permitted attempt' {
            $f = & $script:NewFailingCall -FailTimes 2 -ErrorText $script:Forbidden
            Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' -MaxAttempts 3 `
                -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState | Out-Null
            $f.State.Attempts | Should -Be 3
        }

        It 'calls through exactly once when the first attempt succeeds' {
            $f = & $script:NewFailingCall -FailTimes 0 -ErrorText $script:Forbidden
            Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' `
                -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState | Out-Null
            $f.State.Attempts | Should -Be 1
            $script:Reopened | Should -Be 0
        }
    }

    Context 'It fails fast on anything that is not the firewall' {

        It 'does not retry a permission failure' {
            $f = & $script:NewFailingCall -FailTimes 99 -ErrorText $script:Rbac
            { Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint "Verify 'Key Vault Certificate User' role." `
                    -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState } |
                Should -Throw
            $f.State.Attempts | Should -Be 1
            $script:Reopened | Should -Be 0
        }

        It 'keeps the permission hint in the message for a non-firewall failure' {
            $f = & $script:NewFailingCall -FailTimes 99 -ErrorText $script:Rbac
            { Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint "Verify 'Key Vault Certificate User' role." `
                    -PropagationSeconds 0 -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState } |
                Should -Throw -ExpectedMessage "*Key Vault Certificate User*"
        }
    }

    Context 'When it gives up, the message names the firewall' {

        It 'stops after MaxAttempts and says the vault is closed, not that a role is missing' {
            # The defect this replaces reported "Verify 'Key Vault Certificate
            # User' role and that the cert exists" while the role and the cert
            # were both fine, which is what sent the first hour of #306 in the
            # wrong direction.
            $f = & $script:NewFailingCall -FailTimes 99 -ErrorText $script:Forbidden
            { Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint "Verify 'Key Vault Certificate User' role." `
                    -MaxAttempts 3 -PropagationSeconds 0 `
                    -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState } |
                Should -Throw -ExpectedMessage "*THE VAULT FIREWALL IS CLOSED*"
            $f.State.Attempts | Should -Be 3
        }

        It 'cites the issue so the next reader does not re-diagnose it' {
            $f = & $script:NewFailingCall -FailTimes 99 -ErrorText $script:Forbidden
            { Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint 'hint.' `
                    -MaxAttempts 2 -PropagationSeconds 0 `
                    -ReopenVault $script:OkReopen -WaitAction $script:NoWait -StateReader $script:FakeState } |
                Should -Throw -ExpectedMessage "*306*"
        }

        It 'reports that this run could not re-open the vault itself' {
            # Distinguishes "we raced and lost" from "this identity has no
            # firewall-toggler role", which need different fixes.
            $f = & $script:NewFailingCall -FailTimes 99 -ErrorText $script:Forbidden
            { Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint 'hint.' `
                    -MaxAttempts 2 -PropagationSeconds 0 `
                    -ReopenVault $script:FailReopen -WaitAction $script:NoWait -StateReader $script:FakeState } |
                Should -Throw -ExpectedMessage "*firewall-toggler role*"
        }

        It 'keeps retrying after a failed re-open, because a sibling run may open it' {
            $f = & $script:NewFailingCall -FailTimes 1 -ErrorText $script:Forbidden
            $out = Invoke-KeyVaultCliWithFirewallRetry -Call $f.Call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' `
                -PropagationSeconds 0 -ReopenVault $script:FailReopen -WaitAction $script:NoWait -StateReader $script:FakeState
            $out | Should -Not -BeNullOrEmpty
            $f.State.Attempts | Should -Be 2
        }
    }

    Context 'Both Key Vault data-plane calls are wrapped' {

        It 'routes the certificate read and the JWT sign through the retry' {
            # deploy-label-policies reads the certificate twice per run -- once to
            # apply and once for -VerifyPublished -- and on 2026-09-07 it survived
            # the first and died on the second. Wrapping only the first call would
            # not have saved that run.
            $text = Get-Content -LiteralPath $script:ScriptPath -Raw
            ([regex]::Matches($text, 'Invoke-KeyVaultCliWithFirewallRetry -VaultName')).Count |
                Should -Be 2
            $text | Should -Match "'keyvault', 'certificate', 'show'"
            $text | Should -Match "'keyvault', 'key', 'sign'"
        }

        It 'no longer calls either data-plane verb bare (red-replay of the pre-fix shape)' {
            $text = Get-Content -LiteralPath $script:ScriptPath -Raw
            $text | Should -Not -Match '(?m)^\s*\$certJson = az keyvault certificate show'
            $text | Should -Not -Match '(?m)^\s*\$signResult = az keyvault key sign'
        }

        It 'captures stderr to a file rather than merging it into the success stream' {
            # `2>&1` would fold ErrorRecords into the JSON the callers parse.
            $text = Get-Content -LiteralPath $script:ScriptPath -Raw
            $text | Should -Match '\$out = & az @Arguments 2>\$errFile'
        }
    }
}

Describe 'Invoke-AzCliCapture must not be muted by -WhatIf (issue #312)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($targetName in @('Invoke-AzCliCapture', 'Test-KeyVaultFirewallClosure')) {
            $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
            if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        # Shadow `az` with a function in the same scope. PowerShell resolves a
        # function ahead of an external command, so Invoke-AzCliCapture's
        # `& az @Arguments` reaches this instead of the real CLI -- no Azure
        # context, no network, and a stderr payload we control.
        function script:az {
            Write-Error 'ERROR: (Forbidden) Public network access is disabled. Inner error: { "code": "ForbiddenByConnection" }' -ErrorAction Continue
            $global:LASTEXITCODE = 1
        }
    }

    It 'captures stderr when no -WhatIf is in play' {
        $result = Invoke-AzCliCapture -Arguments @('keyvault', 'certificate', 'show')
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Not -BeNullOrEmpty
        Test-KeyVaultFirewallClosure -Text $result.Error | Should -BeTrue
    }

    It 'still captures stderr when the caller is running under -WhatIf' {
        # THE DEFECT. PowerShell implements `2>$file` through Out-File, which
        # honours ShouldProcess, so under -WhatIf the redirection silently does
        # nothing and stderr is lost. Every deploy-* workflow's "Enumerate
        # skipped ... (portal-wins read-only pass)" step runs the reconciler
        # with -WhatIf, so this is not an edge case: it is the first step of
        # five workflows. With stderr lost, a firewall closure classifies as a
        # generic failure, the #306 retry never fires, and the operator is sent
        # back to the permission hint that wasted the first hour of #306.
        $WhatIfPreference = $true
        $result = Invoke-AzCliCapture -Arguments @('keyvault', 'certificate', 'show')
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Not -BeNullOrEmpty
        Test-KeyVaultFirewallClosure -Text $result.Error | Should -BeTrue
    }

    It 'leaves no temp file behind under -WhatIf' {
        # Remove-Item is suppressed by the same mechanism, so the pre-fix shape
        # leaked one temp file per call as well as losing the diagnosis.
        $before = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue).Count
        $WhatIfPreference = $true
        Invoke-AzCliCapture -Arguments @('keyvault', 'certificate', 'show') | Out-Null
        $after = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue).Count
        $after | Should -BeLessOrEqual $before
    }

    It 'pins the guard in the source, so the next edit does not drop it' {
        $text = Get-Content -LiteralPath $script:ScriptPath -Raw
        $text | Should -Match '(?m)^\s*\$WhatIfPreference = \$false\s*$'
    }
}

Describe 'Key Vault window ownership (issue #311)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($targetName in @('Set-KeyVaultReopenedFlag', 'Invoke-KeyVaultCliWithFirewallRetry', 'Test-KeyVaultFirewallClosure')) {
            $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
            if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }
        $script:NoWait = { param($Seconds) }
        $script:OkReopen = { param($Vault) $true }
        $script:FakeState = { param($Vault) 'Disabled/Deny' }
        $script:Forbidden = 'Inner error: { "code": "ForbiddenByConnection" }'
    }

    Context 'Set-KeyVaultReopenedFlag' {

        It 'writes the flag the restore step reads' {
            $f = Join-Path $TestDrive 'github_env'
            Set-Content -LiteralPath $f -Value '' -NoNewline
            Set-KeyVaultReopenedFlag -EnvFilePath $f | Should -BeTrue
            (Get-Content -LiteralPath $f -Raw) | Should -Match 'KV_REOPENED_BY_RETRY=true'
        }

        It 'is a no-op outside GitHub Actions' {
            Set-KeyVaultReopenedFlag -EnvFilePath '' | Should -BeFalse
        }

        It 'never throws when the file cannot be written' {
            # Best effort by design: failing to write a cleanup hint must not be
            # what fails a run that has otherwise recovered.
            { Set-KeyVaultReopenedFlag -EnvFilePath (Join-Path $TestDrive 'no' 'such' 'dir' 'x') } |
                Should -Not -Throw
        }

        It 'writes even under -WhatIf' {
            # Add-Content honours ShouldProcess, and the callers run under the
            # enumerate pass's -WhatIf. Same trap as #312, one function over.
            $f = Join-Path $TestDrive 'github_env_whatif'
            Set-Content -LiteralPath $f -Value '' -NoNewline
            $WhatIfPreference = $true
            Set-KeyVaultReopenedFlag -EnvFilePath $f | Should -BeTrue
            (Get-Content -LiteralPath $f -Raw) | Should -Match 'KV_REOPENED_BY_RETRY=true'
        }
    }

    Context 'The retry claims the window when it re-opens' {

        It 'does not leak the flag helper return value into the output' {
            # PowerShell adds any uncaptured value to the output stream, so a
            # bare `Set-KeyVaultReopenedFlag` returns its boolean alongside the
            # certificate JSON and the caller parses @($false, '{...}').
            $state = [pscustomobject]@{ N = 0 }
            # Local, not $script: -- GetNewClosure captures locals, and a
            # script-scoped read from inside the closure came back empty,
            # which made the classifier see no firewall error at all.
            $forbidden = 'Inner error: { "code": "ForbiddenByConnection" }'
            $call = {
                $state.N++
                if ($state.N -eq 1) { return @{ ExitCode = 1; Output = ''; Error = $forbidden } }
                return @{ ExitCode = 0; Output = '{"cer":"AAAA"}'; Error = '' }
            }.GetNewClosure()

            $out = Invoke-KeyVaultCliWithFirewallRetry -Call $call -VaultName 'kv-test' `
                -Operation 'Reading certificate' -PermissionHint 'hint.' `
                -PropagationSeconds 0 -ReopenVault $script:OkReopen `
                -WaitAction $script:NoWait -StateReader $script:FakeState

            $out | Should -BeOfType [string]
            $out | Should -Be '{"cer":"AAAA"}'
        }
    }
}

Describe 'A failed re-open is diagnosed, not guessed at (issue #320)' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)
        $allFns = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)
        foreach ($targetName in @(
                'Test-KeyVaultFirewallClosure',
                'Set-KeyVaultReopenedFlag',
                'Invoke-KeyVaultCliWithFirewallRetry')) {
            $fnAst = $allFns | Where-Object { $_.Name -eq $targetName } | Select-Object -First 1
            if (-not $fnAst) { throw "Function '$targetName' not found in $script:ScriptPath" }
            . ([ScriptBlock]::Create($fnAst.Extent.Text))
        }

        $script:NoWait = { param($Seconds) }
        $script:FakeState = { param($Vault) 'Disabled/Deny' }

        # Always-failing call, so every case reaches the give-up message.
        $script:AlwaysForbidden = {
            @{ ExitCode = 1; Output = ''; Error = 'Inner error: { "code": "ForbiddenByConnection" }' }
        }

        function script:Invoke-GiveUp {
            param([scriptblock] $Reopen)
            try {
                Invoke-KeyVaultCliWithFirewallRetry -Call $script:AlwaysForbidden -VaultName 'kv-test' `
                    -Operation 'Reading certificate' -PermissionHint 'hint.' -MaxAttempts 2 `
                    -PropagationSeconds 0 -ReopenVault $Reopen -WaitAction $script:NoWait `
                    -StateReader $script:FakeState
            }
            catch { return [string]$_ }
            throw 'Expected the retry to give up and throw.'
        }
    }

    It 'names contention, not RBAC, when the re-open lost a race' {
        # ARM rejects simultaneous writes to one vault with ConflictError
        # (#311). That is a lost race. Blaming a missing role there is the
        # same wrong signpost that cost the first hour of #306.
        $msg = Invoke-GiveUp -Reopen {
            param($Vault)
            @{ Ok = $false; Text = 'ERROR: (ConflictError) A conflict occurred ... parallel operations' }
        }
        $msg | Should -Match 'ConflictError'
        $msg | Should -Match 'contention, not a permissions problem'
        $msg | Should -Not -Match 'firewall-toggler role'
    }

    It 'surfaces any other re-open failure verbatim rather than guessing' {
        $msg = Invoke-GiveUp -Reopen {
            param($Vault)
            @{ Ok = $false; Text = 'ERROR: (AuthorizationFailed) The client does not have authorization' }
        }
        $msg | Should -Match 'AuthorizationFailed'
        $msg | Should -Not -Match 'firewall-toggler role'
    }

    It 'falls back to naming the role only when the re-open reported no reason' {
        # The bare-boolean contract, where the caller supplies no detail. The
        # message must say the cause is unknown rather than assert it.
        $msg = Invoke-GiveUp -Reopen { param($Vault) $false }
        $msg | Should -Match 'reported no reason'
        $msg | Should -Match 'one possible cause'
    }

    It 'says nothing about the re-open when it succeeded' {
        $msg = Invoke-GiveUp -Reopen { param($Vault) $true }
        $msg | Should -Match 'THE VAULT FIREWALL IS CLOSED'
        $msg | Should -Not -Match 'could not re-open'
    }

    It 'still accepts a bare boolean from an injected re-open' {
        # Backward compatibility is deliberate: a boolean is the simplest thing
        # a caller can inject, and most cases do not care about the reason.
        $msg = Invoke-GiveUp -Reopen { param($Vault) $true }
        $msg | Should -Not -BeNullOrEmpty
    }

    It 'asks az for the failure text instead of discarding it' {
        # The production re-open used `2>$null`, which threw the reason away at
        # source -- no amount of message wording recovers it after that.
        $text = Get-Content -LiteralPath $script:ScriptPath -Raw
        $text | Should -Match 'az keyvault update --name \$Vault'
        $text | Should -Match 'Ok = \(\$LASTEXITCODE -eq 0\); Text ='
    }
}
