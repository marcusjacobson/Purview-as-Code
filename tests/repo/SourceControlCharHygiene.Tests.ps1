#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    STRAY CONTROL CHARACTERS - corruption you cannot see in a diff.

    A C0 control character other than tab / LF / CR has no legitimate place in
    this repository's source. When one lands it is invisible: `git diff` renders
    it as nothing (or as a colour-code artefact), code review reads straight
    past it, and every existing test stays green because the byte sits inside a
    comment or a message string rather than in a token the parser cares about.

    This guard exists because that happened TWICE in a single session, from two
    different directions, and neither was caught by anything else:

      1. `scripts/Invoke-LocalIrmDriftSync.ps1` and
         `Invoke-LocalDlpDriftSync.ps1` both wrapped a remediation command in
         backticks inside a DOUBLE-QUOTED PowerShell string. `` `a `` is
         PowerShell's recognized escape for the alert/BEL control character
         (0x07), not a literal backtick, so the operator-facing error message
         silently read "Run z account set ..." with an invisible BEL where the
         "a" belonged. Fixed under #215; pinned by a red-replay in
         tests/scripts/TenantContextGuard.Tests.ps1.
      2. `scripts/Deploy-LabelPolicies.ps1` carried the SAME corruption baked
         into a committed comment (`# Normalize <BEL>dvancedSettings:`), from
         the same backtick-escape mistake, and had shipped that way. Nothing
         flagged it -- ScriptAnalyzer is clean on it, the file parses, and the
         byte is inside a comment. Found under #235 only because a byte-level
         sweep was run by hand.

    The generating mistake is not specific to PowerShell: writing `\b` in a
    Python string that emits source produces a literal BACKSPACE (0x08) the
    same way, which is exactly how a backspace nearly shipped into this very
    test suite during #235 -- caught by red-replay, not by review.

    So the durable fix is a byte-level assertion over the tracked tree rather
    than another per-file regression test. Binary blobs are excluded via
    `git ls-files --eol` (the "i/-text" marker), the same index-driven
    mechanism IndexEolHygiene.Tests.ps1 already uses, so the check is
    checkout-independent and behaves identically on every platform.

    References:
      https://git-scm.com/docs/git-ls-files#Documentation/git-ls-files.txt---eol
      https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_special_characters
#>

Describe 'Source control-character hygiene' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

        # Tab (0x09), LF (0x0A) and CR (0x0D) are the only control bytes this
        # repository's text files may contain. Everything else in the C0 range,
        # plus DEL (0x7F), is corruption.
        $script:AllowedControlBytes = @(0x09, 0x0A, 0x0D)

        function Get-StrayControlByte {
            param([Parameter(Mandatory = $true)][byte[]]$Bytes)
            $found = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($b in $Bytes) {
                if (($b -lt 0x20 -and $b -notin $script:AllowedControlBytes) -or $b -eq 0x7F) {
                    $null = $found.Add([int]$b)
                }
            }
            return @($found | Sort-Object)
        }
        $script:GetStrayControlByte = ${function:Get-StrayControlByte}
    }

    It 'the detector itself flags BEL and BS (non-vacuity: a scan that finds nothing must be able to find something)' {
        # Both bytes this repository has actually been bitten by, built here
        # rather than committed as a fixture -- a fixture file carrying them
        # would be flagged by the assertion below, which is the point.
        $corrupt = [byte[]]@(0x23, 0x20, 0x07, 0x64, 0x08, 0x65)
        $hits = Get-StrayControlByte -Bytes $corrupt
        $hits | Should -Contain 7  -Because 'BEL (0x07) is the backtick-escape corruption from #215 and #235'
        $hits | Should -Contain 8  -Because 'BS (0x08) is the Python \b corruption that nearly shipped under #235'

        $clean = [byte[]]@(0x23, 0x09, 0x41, 0x0D, 0x0A)
        Get-StrayControlByte -Bytes $clean | Should -BeNullOrEmpty -Because 'tab, CR and LF are legitimate and must not be flagged'
    }

    It 'no tracked text file contains a stray control character' {
        $eol = @(& git -C $script:RepoRoot ls-files --eol)
        $LASTEXITCODE | Should -Be 0 -Because 'git ls-files must be runnable, or this guard is vacuous'

        $textFiles = @($eol |
                Where-Object { $_ -notmatch 'i/-text' } |
                ForEach-Object { ($_ -split "`t")[-1] } |
                Where-Object { $_ })
        $textFiles.Count | Should -BeGreaterThan 100 -Because 'the repo tracks hundreds of text files; a short list means the guard read the wrong tree'

        $offenders = @()
        foreach ($relative in $textFiles) {
            $full = Join-Path $script:RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $bytes = [System.IO.File]::ReadAllBytes($full)
            $stray = Get-StrayControlByte -Bytes $bytes
            if ($stray) {
                $offenders += ('{0} [{1}]' -f $relative, (($stray | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' '))
            }
        }

        $offenders | Should -BeNullOrEmpty -Because (
            'a C0 control character other than tab/LF/CR is invisible in review and in git diff, ' +
            'and every other test stays green when one lands inside a comment or message string. ' +
            'The usual cause is backtick-escaping in a double-quoted PowerShell string (`a -> BEL) ' +
            'or \b in a generator script (-> BS). Offenders: ' + ($offenders -join '; '))
    }
}
