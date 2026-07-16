#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    INDEX EOL HYGIENE - a mixed-EOL blob is a repo-wide checkout breaker.

    .gitattributes normalizes every text blob to LF in the object store
    ("* text=auto eol=lf"; *.ps1 additionally smudges to CRLF in the working
    tree). A blob committed with MIXED line endings (some CRLF lines inside an
    otherwise-LF blob) defeats that contract: on every fresh checkout the
    clean/smudge round-trip no longer reproduces the index blob, so the file
    appears permanently modified ("git status" dirty forever, branch switches
    blocked) in every clone - including downstream operator repos that consume
    this template's history (ADR 0057 section 8/9). Exactly this shipped once,
    in scripts/New-KvUnlockRbac.ps1, and was only caught downstream.

    "git ls-files --eol" reports the INDEX eol per tracked file ("i/lf",
    "i/crlf", "i/mixed", "i/-text" for binary, or empty for unresolved). The
    index column is checkout-independent - it describes the committed blob -
    so this assertion behaves identically on every platform and CI runner.
    Only "i/mixed" is asserted: "i/crlf" cannot occur for attr-covered text
    here (everything text normalizes to LF), and binary files report "i/-text"
    which is fine.

    References:
      https://git-scm.com/docs/git-ls-files#Documentation/git-ls-files.txt---eol
      https://git-scm.com/docs/gitattributes#_end_of_line_conversion
#>

Describe 'Repository index EOL hygiene' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'tracks no blob with a mixed-EOL index entry' {
        $lines = @(& git -C $script:RepoRoot ls-files --eol)
        $LASTEXITCODE | Should -Be 0 -Because 'git ls-files must be runnable, or this guard is vacuous'
        $lines.Count | Should -BeGreaterThan 100 -Because 'the repo tracks hundreds of files; a short list means the guard read the wrong tree'

        $mixed = @($lines | Where-Object { $_ -match '^i/mixed\b' })
        $mixed | Should -BeNullOrEmpty -Because (
            'a mixed-EOL index blob makes the clean/smudge round-trip unstable: the file shows as ' +
            'modified on every fresh checkout in every clone, including downstream operator repos. ' +
            'Fix the working copy, then re-stage with git add --renormalize <path>. Offenders: ' +
            (($mixed -join '; ')))
    }
}
