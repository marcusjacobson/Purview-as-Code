#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    THE VAULT-OPEN VERIFY IS A CONTRACT, SO A TEST PINS IT.

    validate-oidc-auth.yml and kv-temp-unlock.yml both open the automation Key
    Vault firewall with

        az keyvault update --public-network-access Enabled --default-action Allow

    and then, in a SEPARATE step ("Verify the open actually stuck (read back)"),
    read the state back and fail loudly if the open did not take -- the defense
    against a governed tenant's Azure Policy `modify` effect silently rewriting
    the open PUT while `az` still exits 0.

    THE GOTCHA THIS TEST PINS: enabling public network access with an all-Allow /
    no-rules ACL makes Azure NORMALIZE `networkAcls.defaultAction` to null -- it
    reads back as the string "None" via `-o tsv` (observed live: the open command
    itself returns `{"pna":"Enabled","da":null}`). So the openness gate MUST key
    on publicNetworkAccess, not on defaultAction == "Allow": a check that requires
    "Allow" false-positives on every normal open and mislabels it a policy modify.
    The correct contract:

      * PNA=Enabled + defaultAction Allow  -> open (verify passes)
      * PNA=Enabled + defaultAction None   -> open (verify passes; Azure-normalized)
      * PNA=Enabled + defaultAction Deny    -> blocked (verify fails: persisting Deny)
      * PNA != Enabled                      -> policy-modify defeat (verify fails,
                                               diagnosis keyed on publicNetworkAccess)

    This suite reads the SHIPPED workflow files and REPLAYS the actual verify
    `run:` block (with `az keyvault show` stubbed to a synthetic read-back), the
    same "test the committed artefact" reasoning as EnvironmentRouting.Tests.ps1.

    References:
      https://learn.microsoft.com/en-us/azure/key-vault/general/network-security
      https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify
      https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # Pull the exact `run:` script of the "Verify the open actually stuck" step
    # out of the SHIPPED workflow (searched across every job, so job structure
    # can change without touching this test).
    function Get-VerifyRun {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $script:WorkflowsDir $Name
        $wf = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
        foreach ($jobKey in $wf['jobs'].Keys) {
            foreach ($step in $wf['jobs'][$jobKey]['steps']) {
                if ($step['name'] -eq 'Verify the open actually stuck (read back)') {
                    return [string]$step['run']
                }
            }
        }
        throw "Step 'Verify the open actually stuck (read back)' not found in $Name"
    }

    # Replay the extracted block with `az` stubbed to a synthetic read-back
    # (FAKE_PNA / FAKE_DA), returning the block's exit code and merged output.
    # KEY_VAULT_NAME / RESOURCE_GROUP are set so the block's `set -u` does not
    # abort on their expansion (they are only ever passed to the stubbed `az`).
    function Invoke-VerifyBlock {
        param(
            [Parameter(Mandatory)][string]$RunScript,
            [Parameter(Mandatory)][string]$Pna,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Da
        )
        $stub = 'az() { printf ''%s\t%s\n'' "${FAKE_PNA}" "${FAKE_DA}"; }' + "`n"
        $full = ($stub + $RunScript) -replace "`r`n", "`n"
        $shPath = Join-Path ([System.IO.Path]::GetTempPath()) ("kvverify-" + [System.IO.Path]::GetRandomFileName() + ".sh")
        [System.IO.File]::WriteAllText($shPath, $full, (New-Object System.Text.UTF8Encoding $false))
        try {
            $env:FAKE_PNA = $Pna
            $env:FAKE_DA = $Da
            $env:KEY_VAULT_NAME = 'kv-test'
            $env:RESOURCE_GROUP = 'rg-test'
            $out = & bash $shPath 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            Remove-Item -LiteralPath $shPath -ErrorAction SilentlyContinue
            Remove-Item Env:FAKE_PNA, Env:FAKE_DA, Env:KEY_VAULT_NAME, Env:RESOURCE_GROUP -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ ExitCode = $code; Output = ($out -join "`n") }
    }
}

Describe 'Vault-open verify keys on publicNetworkAccess and tolerates a normalized (None) defaultAction' {

    Context 'in <File>' -ForEach @(
        @{ File = 'validate-oidc-auth.yml' }
        @{ File = 'kv-temp-unlock.yml' }
    ) {
        BeforeAll {
            $script:run = Get-VerifyRun -Name $File
        }

        It 'passes on PNA=Enabled + defaultAction=None (Azure-normalized all-Allow ACL)' {
            $r = Invoke-VerifyBlock -RunScript $script:run -Pna 'Enabled' -Da 'None'
            $r.ExitCode | Should -Be 0 -Because "PNA=Enabled with a None (allow-all) ACL is open; requiring literal Allow was the downstream false-positive. Output: $($r.Output)"
            $r.Output   | Should -Match 'Open verified'
        }

        It 'passes on PNA=Enabled + defaultAction=Allow' {
            $r = Invoke-VerifyBlock -RunScript $script:run -Pna 'Enabled' -Da 'Allow'
            $r.ExitCode | Should -Be 0 -Because "explicit Allow is open. Output: $($r.Output)"
        }

        It 'fails on PNA=Enabled + defaultAction=Deny (persisting Deny blocks the data plane)' {
            $r = Invoke-VerifyBlock -RunScript $script:run -Pna 'Enabled' -Da 'Deny'
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'defaultAction is still Deny'
        }

        It 'fails with the policy-modify diagnosis when PNA reads back != Enabled' {
            $r = Invoke-VerifyBlock -RunScript $script:run -Pna 'Disabled' -Da 'None'
            $r.ExitCode | Should -Be 1
            $r.Output   | Should -Match 'publicNetworkAccess'
            $r.Output   | Should -Match 'policies/modify/action'
        }

        It 'does NOT reject a non-Allow defaultAction outright (regression guard for the [ "$DA" != "Allow" ] false-positive)' {
            # The exact downstream failure: PNA=Enabled but DA read back as None.
            $r = Invoke-VerifyBlock -RunScript $script:run -Pna 'Enabled' -Da 'None'
            $r.Output | Should -Not -Match 'did not stick'
        }
    }
}
