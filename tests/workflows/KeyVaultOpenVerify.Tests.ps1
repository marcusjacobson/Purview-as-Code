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
    # This suite's own text, for the issue-#38 portability assertions below.
    $script:SelfPath   = Join-Path $PSScriptRoot 'KeyVaultOpenVerify.Tests.ps1'
    $script:SelfSource = Get-Content -LiteralPath $script:SelfPath -Raw
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

    # Quote a value for POSIX sh: wrap in single quotes and close/escape/reopen
    # around any embedded single quote. The replay values are simple words
    # today ('Enabled', 'None', ''), but a helper that silently breaks on a
    # quote is the kind that gets reused later and misleads.
    function ConvertTo-ShSingleQuoted {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
        return "'" + ($Value -replace "'", "'\''") + "'"
    }

    # Run a script through `bash -s`, writing it to stdin BYTE-EXACTLY.
    #
    # The obvious `$script | & bash -s` does not do that on Windows: the
    # pipeline preserves interior newlines but terminates the final line with
    # the platform newline, so bash receives a trailing CRLF. If the script
    # already ended in a newline that leaves a line containing nothing but a
    # carriage return, and bash reports
    #   /bin/bash: line 32: $'\r': command not found
    # then exits 127 -- AFTER running the script correctly and printing the
    # expected output. A contract assertion on that output would pass while
    # the exit-code assertion failed, which is a genuinely confusing shape.
    #
    # Driving the process directly is the only way to control the bytes:
    # StreamWriter.NewLine is set to LF and the text is written verbatim.
    #
    # FileName is the RESOLVED path, never the bare word 'bash'. Win32's
    # search order for CreateProcess puts the System32 directory ahead of
    # PATH, and on a GitHub `windows-latest` runner
    # C:\Windows\System32\bash.exe is the legacy WSL launcher with no
    # distribution installed -- it answers every invocation with
    # "Windows Subsystem for Linux has no installed distributions" (in
    # UTF-16, for good measure) and exits 1. PowerShell's `& bash` resolves
    # through Get-Command, which walks PATH and finds the real bash, so
    # handing ProcessStartInfo the bare name silently changes which shell
    # runs. Resolve it the same way PowerShell would, and pass the full path.
    function Invoke-BashScript {
        param([Parameter(Mandatory)][string]$Script)
        $bash = (Get-Command bash -CommandType Application -ErrorAction Stop |
                Select-Object -First 1).Source
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $bash
        $psi.Arguments              = '-s'
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $proc.StandardInput.NewLine = "`n"
            $proc.StandardInput.Write($Script)
            $proc.StandardInput.Close()
            # Output here is a few hundred bytes, far inside the pipe buffer,
            # so sequential reads cannot deadlock.
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $code = $proc.ExitCode
        }
        finally {
            $proc.Dispose()
        }
        $text = (($stdout + $stderr) -replace "`r`n", "`n").TrimEnd("`n")
        return [pscustomobject]@{ ExitCode = $code; Output = $text }
    }

    # Replay the extracted block with `az` stubbed to a synthetic read-back
    # (FAKE_PNA / FAKE_DA), returning the block's exit code and merged output.
    # KEY_VAULT_NAME / RESOURCE_GROUP are set so the block's `set -u` does not
    # abort on their expansion (they are only ever passed to the stubbed `az`).
    #
    # ISSUE #38 -- NOTHING CROSSES THE WINDOWS/BASH BOUNDARY BUT THE SCRIPT
    # TEXT, AND IT CROSSES ON STDIN.
    #
    # This used to write the block to a Windows temp file and call
    # `& bash $shPath`, passing the four values through the process
    # environment. Both halves of that break the moment `bash` resolves to
    # the WSL shim at
    # AppData/Local/Microsoft/WindowsApps/bash.exe -- which is what a Windows
    # 11 box with WSL installed resolves by DEFAULT, ahead of Git Bash:
    #
    #   * WSL cannot open a Windows path, and eats the backslashes as
    #     escapes, so the invocation fails with
    #     `C:UsersyouAppDataLocalTempkvverify-xxxx.sh: No such file or
    #     directory` and exit 127; and
    #   * WSL does not forward Windows environment variables unless they are
    #     named in WSLENV, so even reaching the script leaves it dying on
    #     `KEY_VAULT_NAME: unbound variable` under the block's `set -u`.
    #
    # The second half is the trap: a path-only fix LOOKS like it works,
    # because the two exit-0 cases start passing while the Deny and
    # PNA!=Enabled cases still fail -- or worse, pass for the wrong reason
    # with FAKE_PNA empty. So the values are inlined into the script text and
    # the whole thing goes in on stdin via Invoke-BashScript. No temp file, no
    # PATH translation, no environment inheritance, nothing for a shell
    # flavour to disagree about. `KeyVaultOpenVerify portability (issue #38)`
    # below pins all of that.
    function Invoke-VerifyBlock {
        param(
            [Parameter(Mandatory)][string]$RunScript,
            [Parameter(Mandatory)][string]$Pna,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Da
        )
        $preamble = @(
            "FAKE_PNA=$(ConvertTo-ShSingleQuoted -Value $Pna); export FAKE_PNA"
            "FAKE_DA=$(ConvertTo-ShSingleQuoted -Value $Da); export FAKE_DA"
            "KEY_VAULT_NAME='kv-test'; export KEY_VAULT_NAME"
            "RESOURCE_GROUP='rg-test'; export RESOURCE_GROUP"
            'az() { printf ''%s\t%s\n'' "${FAKE_PNA}" "${FAKE_DA}"; }'
        ) -join "`n"
        $full = ($preamble + "`n" + $RunScript) -replace "`r`n", "`n"
        return Invoke-BashScript -Script $full
    }

    # The source text of the two helpers above, extracted by AST so the
    # portability assertions inspect the FUNCTIONS rather than this file --
    # a whole-file regex scan matches the assertion's own pattern literal and
    # fails on itself.
    $tok = $null
    $errs = $null
    $selfAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:SelfPath, [ref]$tok, [ref]$errs)
    if ($errs) { throw ("Parse errors in {0}: {1}" -f $script:SelfPath, ($errs -join '; ')) }
    $script:ReplaySource = (@('Invoke-VerifyBlock', 'Invoke-BashScript') | ForEach-Object {
            $fname = $_
            $fn = $selfAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $fname
                }, $true)
            if (-not $fn) { throw "$fname not found in $script:SelfPath" }
            $fn.Extent.Text
        }) -join "`n"
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

Describe 'KeyVaultOpenVerify portability (issue #38)' {

    # The replay above is the only place in the suite that hands work to an
    # external shell, and it used to hand it a Windows path plus a process
    # environment -- neither of which survives `bash` resolving to the WSL
    # shim, the default on a Windows 11 box with WSL installed. The result
    # was 8 of this file's 10 cases failing at exit 127 for reasons entirely
    # unrelated to the contract under test, which cost the third end-to-end
    # IRM synchronisation run (#255) its first Leg 0.
    #
    # These assertions exist because the temp-file form is the one someone
    # reaches for by habit, and reintroducing it would fail only on machines
    # the author does not have.

    It 'writes no script file: nothing is handed to bash by path' {
        $script:ReplaySource | Should -Not -Match 'GetTempPath'
        $script:ReplaySource | Should -Not -Match 'WriteAllText'
        $script:ReplaySource | Should -Not -Match 'Join-Path'
    }

    It 'feeds the replayed block to bash on stdin, byte-exactly' {
        $script:ReplaySource | Should -Match 'RedirectStandardInput'
        $script:ReplaySource | Should -Match 'StandardInput\.Write'
        # LF, not the platform newline: the pipeline operator terminates its
        # final line with CRLF, which leaves bash a bare-CR line and exit 127.
        $script:ReplaySource | Should -Match 'StandardInput\.NewLine'
    }

    It 'resolves bash through Get-Command rather than letting Win32 search System32 first' {
        # CreateProcess searches System32 ahead of PATH, and on a GitHub
        # windows-latest runner System32 holds the legacy WSL launcher with no
        # distribution installed. Passing the bare name 'bash' silently runs
        # that instead of the real shell.
        $script:ReplaySource | Should -Match 'Get-Command bash'
        $script:ReplaySource | Should -Not -Match "FileName\s*=\s*'bash'"
    }

    It 'the bash it resolves actually works (guards against a stub launcher)' {
        # A shell that cannot run anything would otherwise surface as a
        # confusing contract failure rather than an environment problem.
        $r = Invoke-BashScript -Script "printf 'ALIVE'"
        $r.ExitCode | Should -Be 0 -Because "resolved bash: $((Get-Command bash -CommandType Application | Select-Object -First 1).Source). Output: $($r.Output)"
        $r.Output   | Should -BeExactly 'ALIVE'
    }

    It 'inlines the four replay variables instead of exporting them from PowerShell' {
        # $env:FAKE_PNA and friends do not cross into WSL without WSLENV, so
        # the values must be assigned inside the script text itself.
        foreach ($name in @('FAKE_PNA', 'FAKE_DA', 'KEY_VAULT_NAME', 'RESOURCE_GROUP')) {
            $script:ReplaySource | Should -Not -Match ('\$env:' + $name)
            $script:ReplaySource | Should -Match ($name + '=.*export ' + $name)
        }
    }

    It 'quotes a replay value safely for POSIX sh, embedded single quote included' {
        ConvertTo-ShSingleQuoted -Value 'Enabled'   | Should -BeExactly "'Enabled'"
        ConvertTo-ShSingleQuoted -Value ''          | Should -BeExactly "''"
        ConvertTo-ShSingleQuoted -Value "it's"      | Should -BeExactly "'it'\''s'"
    }

    It 'actually round-trips a value carrying a single quote through the shell (the quoting is not decorative)' {
        # Proves the preamble this suite builds survives bash, rather than
        # asserting only about the PowerShell-side string.
        $probe = "a'b"
        $r = Invoke-BashScript -Script ("V=$(ConvertTo-ShSingleQuoted -Value $probe)`nprintf '%s' `"`$V`"`n")
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeExactly $probe
    }

    It 'a script ending in a newline still exits cleanly (the CRLF regression that exit-127s)' {
        # The bare-CR line the pipeline operator would introduce shows up
        # only when the script already ends in a newline -- and it exits 127
        # AFTER printing the right answer, so an output-only assertion would
        # not catch it.
        $r = Invoke-BashScript -Script "printf 'DONE'`n"
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -BeExactly 'DONE'
    }

    It 'the portability guards have teeth: each one fires on the pre-fix shape (red-replay)' {
        # Without this, the three source assertions above are only evidence
        # that the current code does not contain some strings -- which an
        # empty string would also satisfy. This is the shape they exist to
        # reject, reproduced verbatim from the pre-#38 helper.
        $preFix = @'
        $shPath = Join-Path ([System.IO.Path]::GetTempPath()) ("kvverify-" + [System.IO.Path]::GetRandomFileName() + ".sh")
        [System.IO.File]::WriteAllText($shPath, $full, (New-Object System.Text.UTF8Encoding $false))
        $env:FAKE_PNA = $Pna
        $env:FAKE_DA = $Da
        $env:KEY_VAULT_NAME = 'kv-test'
        $env:RESOURCE_GROUP = 'rg-test'
        $out = & bash $shPath 2>&1
'@
        # "writes no script file" would have failed on it:
        $preFix | Should -Match 'GetTempPath'
        $preFix | Should -Match 'WriteAllText'
        $preFix | Should -Match 'Join-Path'
        # "feeds the replayed block to bash on stdin" would have failed on it:
        $preFix | Should -Not -Match 'RedirectStandardInput'
        $preFix | Should -Not -Match 'StandardInput\.Write'
        # "inlines the four replay variables" would have failed on it:
        foreach ($name in @('FAKE_PNA', 'FAKE_DA', 'KEY_VAULT_NAME', 'RESOURCE_GROUP')) {
            $preFix | Should -Match ('\$env:' + $name)
            $preFix | Should -Not -Match ($name + '=.*export ' + $name)
        }
    }

    It 'the replayed block sees the injected values (red-replay: a broken transport would leave them empty)' {
        # If the values ever stopped reaching bash -- the exact #38 failure --
        # this returns an empty string rather than the marker, while the
        # contract tests above could still coincidentally pass.
        $r = Invoke-VerifyBlock -RunScript "printf 'GOT[%s][%s][%s][%s]' `"`$FAKE_PNA`" `"`$FAKE_DA`" `"`$KEY_VAULT_NAME`" `"`$RESOURCE_GROUP`"" -Pna 'Enabled' -Da 'None'
        $r.Output | Should -BeExactly 'GOT[Enabled][None][kv-test][rg-test]'
    }
}
