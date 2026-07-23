#Requires -Version 7.4
<#
    Pester coverage for scripts/Test-IdentifierResidue.ps1 — the identifier-shaped
    residual scan ratified by docs/adr/0055-identifier-shaped-residual-scan.md.

    The contract under test is FAIL CLOSED: a non-zero GUID anywhere in a tracked
    file is a Finding unless a manifest rule explicitly acquits it. The tests that
    matter most are therefore the ones that plant an identifier somewhere the scan
    has never been taught about — a new file, a new key — and assert it still
    fails. A scan that only catches identifiers in the places we already looked
    would not have caught the disclosure that motivated it.

    NOTE ON FIXTURES: this file contains no literal high-entropy GUID. Planted
    identifiers are minted at run time with [guid]::NewGuid(), which is both more
    honest (a genuinely novel value the allow-list has never seen) and keeps the
    scan green over its own test file. Fixture identifiers that must be stable use
    the reserved synthetic namespace 00000000-0000-0000-0000-<counter>.

    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'Test-IdentifierResidue.ps1'
    $script:ManifestPath = Join-Path $script:RepoRoot '.github' 'agents' 'tenant-placeholders.yaml'

    Import-Module 'powershell-yaml' -ErrorAction Stop
    $script:Manifest = (Get-Content -LiteralPath $script:ManifestPath -Raw) | ConvertFrom-Yaml

    # Build a hermetic throwaway git repo so the behavioural tests never depend on
    # (or mutate) the real working tree.
    function New-FixtureRepo {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("idres-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Push-Location $root
        try {
            & git init --quiet 2>&1 | Out-Null
            & git config user.email 'fixture@example.invalid' 2>&1 | Out-Null
            & git config user.name 'fixture' 2>&1 | Out-Null
        }
        finally { Pop-Location }
        return $root
    }

    function Set-FixtureFile {
        param([string]$Root, [string]$RelativePath, [string]$Content)
        $full = Join-Path $Root $RelativePath
        $dir = Split-Path -Parent $full
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $full -Value $Content -NoNewline
        Push-Location $Root
        try { & git add -- $RelativePath 2>&1 | Out-Null } finally { Pop-Location }
    }

    function Invoke-Scan {
        param([string]$Root, [string]$Manifest)
        if (-not $Manifest) { $Manifest = $script:ManifestPath }
        $rows = & $script:ScriptPath -RepoRoot $Root -ManifestPath $Manifest 2>$null 6>$null
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Rows     = @($rows)
            Findings = @($rows | Where-Object Verdict -EQ 'Finding')
            Reviews  = @($rows | Where-Object Verdict -EQ 'Review')
        }
    }

    $script:NewFixtureRepo = ${function:New-FixtureRepo}
    $script:SetFixtureFile = ${function:Set-FixtureFile}
    $script:InvokeScan = ${function:Invoke-Scan}
}

Describe 'Test-IdentifierResidue — manifest contract' {

    It 'declares schemaVersion 3 or later (the identifierScan block, ADR 0055)' {
        [int]$script:Manifest.schemaVersion | Should -BeGreaterOrEqual 3
    }

    It 'carries an identifierScan block with every required key' {
        $script:Manifest.Keys | Should -Contain 'identifierScan'
        foreach ($k in @('guidPattern', 'syntheticShapes', 'catalogKeys', 'microsoftConstants')) {
            $script:Manifest.identifierScan.Keys | Should -Contain $k
        }
    }

    It 'declares NO path-exclusion key — a path exclusion is what caused the disclosure' {
        # This is the regression guard on the ADR 0046 defect itself. If somebody
        # ever adds an `excludePaths` / `intentionalSamples` style escape hatch to
        # identifierScan, this test fails and the ADR 0055 argument has to be
        # re-litigated in review rather than bypassed in a diff.
        foreach ($forbidden in @('excludePaths', 'excludePathspecs', 'intentionalSamples', 'ignorePaths', 'skipPaths')) {
            $script:Manifest.identifierScan.Keys | Should -Not -Contain $forbidden
        }
    }

    It 'gives every Microsoft constant a human-readable name (a value with no name is unreviewable)' {
        foreach ($c in $script:Manifest.identifierScan.microsoftConstants) {
            [string]$c.value | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            [string]$c.name | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives every committed tenant identifier a value, a name AND a reason (Rule 5 acquits real tenant OIDs, so each MUST be justified)' {
        # ADR 0055 Rule 5 (issue #71). This category acquits tenant-SPECIFIC GUIDs by
        # exact value — the one place a real object ID is legitimately committed — so
        # unlike every other rule each entry MUST carry a written reason, or it is
        # indistinguishable from laundering an OID into the allow-list. Optional key:
        # @() makes the loop a no-op when the category is absent.
        foreach ($c in @($script:Manifest.identifierScan.committedTenantIdentifiers)) {
            [string]$c.value  | Should -Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            [string]$c.name   | Should -Not -BeNullOrEmpty
            [string]$c.reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'scopes every catalogKeys entry to a specific file AND specific keys (never a whole directory)' {
        foreach ($entry in $script:Manifest.identifierScan.catalogKeys) {
            [string]$entry.path | Should -Not -Match '[*?]'          # no globs — one file
            [string]$entry.path | Should -Not -Match '/$'            # not a directory
            @($entry.keys).Count | Should -BeGreaterThan 0
        }
    }

    It 'PINS the reviewRequired quarantine to exactly the known entries (EMPTY — #98), BY VALUE' {
        # The quarantine is a quarantine, not an escape hatch.
        #
        # Pinning the COUNT alone is not enough, and the gap is not theoretical:
        # with only a count pinned, entries could be SWAPPED for different ones —
        # count unchanged, test still green — and the quarantine would now be
        # covering identifiers nobody reviewed. A quarantine that can be
        # SUBSTITUTED is a path exclusion with better PR.
        #
        # So pin the literal digests too (there are none left to pin, which is
        # itself the assertion). This is safe to do in the open precisely BECAUSE
        # they are hashes: they disclose nothing about the identifiers they cover,
        # which is the whole reason reviewRequired is SHA-256-keyed. Growing OR
        # substituting the quarantine now requires editing this test, which is a
        # deliberate, visible review signal.
        #
        # Formerly 2 entries (docs/adr/0035 — File Plan property `Guid` and
        # `Policy` GUID). Issue #98 established both GUIDs' provenance by
        # empirical cross-tenant verification and promoted them to
        # identifierScan.microsoftConstants in the manifest, emptying this list.
        # validate.yml now runs Test-IdentifierResidue.ps1 -FailOnReview, so a
        # future addition here fails the build immediately rather than passing in
        # report-mode — see .github/agents/tenant-placeholders.yaml
        # identifierScan.reviewRequired.
        $expected = @()
        $actual = @($script:Manifest.identifierScan.reviewRequired |
                ForEach-Object { ([string]$_.sha256).ToLowerInvariant() } | Sort-Object)

        $actual.Count | Should -Be 0 -Because 'both prior entries were promoted to microsoftConstants (#98); the quarantine must not GROW without review'
        $actual | Should -Be (@($expected) | Sort-Object) -Because 'the quarantine must not be SUBSTITUTED without review'
    }

    It 'keys every reviewRequired entry by SHA-256, never by value (never restate a doubtful identifier)' {
        foreach ($r in $script:Manifest.identifierScan.reviewRequired) {
            [string]$r.sha256 | Should -Match '^[0-9a-f]{64}$'
            $r.Keys | Should -Not -Contain 'value'
            [string]$r.location | Should -Not -BeNullOrEmpty
            # A quarantine entry with no named owner decision is an escape hatch
            # with extra steps. Every entry must say what would retire it.
            [string]$r.ownerDecision | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Test-IdentifierResidue — acquittal rules' {

    BeforeAll {
        ${function:New-FixtureRepo} = $script:NewFixtureRepo
        ${function:Set-FixtureFile} = $script:SetFixtureFile
        ${function:Invoke-Scan} = $script:InvokeScan
    }

    It 'acquits the zero GUID (the sanctioned placeholder)' {
        $repo = New-FixtureRepo
        try {
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/x.yaml' -Content "members:`n  - 00000000-0000-0000-0000-000000000000`n"
            $r = Invoke-Scan -Root $repo
            $r.Findings.Count | Should -Be 0
            $r.ExitCode | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'acquits the reserved synthetic fixture namespace (00000000-...-<counter>)' {
        $repo = New-FixtureRepo
        try {
            Set-FixtureFile -Root $repo -RelativePath 'tests/scripts/Some.Tests.ps1' -Content "`$id = '00000000-0000-0000-0000-000000000042'`n"
            $r = Invoke-Scan -Root $repo
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'acquits repeated-nibble fixture GUIDs' {
        $repo = New-FixtureRepo
        try {
            Set-FixtureFile -Root $repo -RelativePath 'tests/scripts/Some.Tests.ps1' -Content "`$a = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'`n"
            $r = Invoke-Scan -Root $repo
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'acquits a Microsoft constant by exact value, wherever it appears' {
        $repo = New-FixtureRepo
        try {
            # Compliance Administrator directory-role template ID, in a Bicep var —
            # no enclosing YAML key, so only the value rule can acquit it.
            $contributor = ($script:Manifest.identifierScan.microsoftConstants |
                    Where-Object { $_.name -like 'Contributor*' } | Select-Object -First 1).value
            Set-FixtureFile -Root $repo -RelativePath 'infra/modules/x.bicep' -Content "var contributorRoleId = '$contributor'`n"
            $r = Invoke-Scan -Root $repo
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'acquits a catalog GUID under an allow-listed key, and then anywhere else in the repo' {
        $repo = New-FixtureRepo
        try {
            # Minted at run time, exactly like the fail-closed plants: a value the
            # allow-list has never seen, so the ONLY thing that can acquit it is the
            # catalogKeys derivation under test. A literal here would (a) be a GUID
            # in a tracked source file that the repo scan must then itself acquit,
            # and (b) weaken the test if it happened to match a synthetic shape.
            $sit = [guid]::NewGuid().ToString()
            # Declared under sit-catalog.yaml `id:` — the derived value set.
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/classifications/sit-catalog.yaml' `
                -Content "sits:`n  - name: Example SIT`n    id: $sit`n"
            # ...then cited in prose in a doc, with no key at all. Still acquitted.
            Set-FixtureFile -Root $repo -RelativePath 'docs/architecture.md' `
                -Content "The Example SIT (``$sit``) is a Microsoft built-in.`n"
            $r = Invoke-Scan -Root $repo
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-IdentifierResidue — FAIL CLOSED (the contract that decides whether this control is real)' {

    BeforeAll {
        ${function:New-FixtureRepo} = $script:NewFixtureRepo
        ${function:Set-FixtureFile} = $script:SetFixtureFile
        ${function:Invoke-Scan} = $script:InvokeScan
    }

    It 'FAILS on a raw object ID under `members:` — the exact shape of the disclosure' {
        # ADR 0023 says a principal is named by displayName. A raw GUID under
        # `members:` is, by construction, a violation. It is also precisely what
        # shipped to a public repo while the ADR 0046 token scan reported clean.
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/purview-role-groups/role-groups.yaml' `
                -Content "roleGroups:`n  - name: OrganizationManagement`n    members:`n      - $oid   # sg-purview-admins`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
            $r.Findings.Count | Should -Be 1
            $r.Findings[0].File | Should -Be 'data-plane/purview-role-groups/role-groups.yaml'
            $r.Findings[0].Rule | Should -Be 'unclaimed'
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on an object ID in a file and under a key the scan has NEVER been taught about' {
        # The load-bearing test. A scan that only knows the places we already
        # looked would have missed the original leak too. A brand-new solution
        # directory, a brand-new key, a value nobody has enumerated: still fails.
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/some-new-solution/brand-new.yaml' `
                -Content "newThings:`n  - someKeyNobodyEnumerated: $oid`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
            $r.Findings.Count | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on an object ID under a NEW key inside an ALREADY-allow-listed catalog file' {
        # Proves catalogKeys is (file, key)-scoped, not file-scoped. Allow-listing
        # sit-catalog.yaml `id:` must not turn the whole file into a safe harbour.
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/classifications/sit-catalog.yaml' `
                -Content "sits:`n  - name: Example`n    id: 00000000-0000-0000-0000-000000000001`n    ownerObjectId: $oid`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
            $r.Findings.Count | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on an object ID pasted into tests/ — there is no tests/ path exclusion' {
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'tests/scripts/Some.Tests.ps1' -Content "`$groupId = '$oid'`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
            $r.Findings.Count | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on an object ID pasted into docs/ — there is no docs/ path exclusion either' {
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'docs/runbooks/thing.md' -Content "Run against group ``$oid``.`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on an object ID in an UNTRACKED (not yet staged) file' {
        # Regression guard. The first cut of this scanner enumerated `git ls-files`
        # only, so a brand-new file was invisible until it was staged. A contributor
        # could write a file holding a real object ID, run the scan, be told PASS,
        # commit, and discover the leak only in CI. A local PASS that a later commit
        # turns into a FAIL is worse than no local run, because it is trusted.
        # (This is not hypothetical: it is exactly how this scanner's own test file
        # slipped past its own local run and was caught by CI.)
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            New-Item -ItemType Directory -Path (Join-Path $repo 'data-plane') -Force | Out-Null
            $full = Join-Path $repo 'data-plane/never-staged.yaml'
            Set-Content -LiteralPath $full -Value "members:`n  - $oid`n" -NoNewline   # NOT git add-ed
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1
            $r.Findings.Count | Should -Be 1
            $r.Findings[0].File | Should -Be 'data-plane/never-staged.yaml'
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'FAILS on a single-line file with no trailing newline (the local run must not lie)' {
        # REGRESSION GUARD -- this defect shipped, and it shipped inside the fix
        # for its own twin.
        #
        # `$raw -split "\r?\n"` on a single-line file with no trailing newline
        # yields a ONE-element array, which PowerShell unrolls to a bare string.
        # `$lines.Count` then throws under Set-StrictMode -Version Latest, the
        # scan loop never runs, and the file is never read.
        #
        # Under CI ($ErrorActionPreference='Stop') that exits 1 -- fail-closed.
        # But a BARE LOCAL run printed a red error and left $LASTEXITCODE = 0:
        # the planted object ID was never reported and the operator was told
        # nothing was wrong. ADR 0055 Decision 7: "a local PASS that a later
        # commit turns into a FAIL is worse than no local run, because it is
        # trusted."
        #
        # The exit-code assertion below is the whole point. A test that only
        # checked for a thrown error would have passed VACUOUSLY against the
        # broken scanner, because the error WAS raised -- it was the exit code
        # that lied.
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            # WriteAllText, not Set-Content: no trailing newline, one line only.
            [System.IO.File]::WriteAllText((Join-Path $repo 'leak.yaml'), "members: [$oid]")
            Push-Location $repo
            try { & git add -- 'leak.yaml' 2>&1 | Out-Null } finally { Pop-Location }

            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 1 -Because 'a bare local run must not exit 0 while failing to read the file'
            $r.Findings.Count | Should -Be 1
            $r.Findings[0].File | Should -Be 'leak.yaml'
            $r.Findings[0].Line | Should -Be 1
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'scans a single-line file with no trailing newline that is CLEAN, without erroring' {
        # The other half: the fix must not turn a clean one-liner into a failure.
        $repo = New-FixtureRepo
        try {
            [System.IO.File]::WriteAllText((Join-Path $repo 'ok.yaml'), 'members: [00000000-0000-0000-0000-000000000000]')
            Push-Location $repo
            try { & git add -- 'ok.yaml' 2>&1 | Out-Null } finally { Pop-Location }

            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 0
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does NOT scan gitignored files (they never reach the remote; tenant exports land there)' {
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath '.gitignore' -Content "exports/`n"
            New-Item -ItemType Directory -Path (Join-Path $repo 'exports') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'exports/tenant-dump.yaml') -Value "members:`n  - $oid`n" -NoNewline
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 0
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'PASSES again once the planted identifier is removed' {
        $repo = New-FixtureRepo
        try {
            $oid = [guid]::NewGuid().ToString()
            Set-FixtureFile -Root $repo -RelativePath 'data-plane/x.yaml' -Content "members:`n  - $oid`n"
            (Invoke-Scan -Root $repo).ExitCode | Should -Be 1

            Set-FixtureFile -Root $repo -RelativePath 'data-plane/x.yaml' -Content "members: []`n"
            $r = Invoke-Scan -Root $repo
            $r.ExitCode | Should -Be 0
            $r.Findings.Count | Should -Be 0
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to run against a manifest older than schemaVersion 3 rather than scan with no allow-list' {
        # A scan that silently ran with an empty allow-list would flag all ~385
        # legitimate GUIDs and be disabled within a day. Fail loudly instead.
        $repo = New-FixtureRepo
        try {
            $stale = Join-Path $repo 'stale-manifest.yaml'
            Set-Content -LiteralPath $stale -Value "schemaVersion: 2`nintentionalSamples: []`n"
            { & $script:ScriptPath -RepoRoot $repo -ManifestPath $stale } |
                Should -Throw -ExpectedMessage '*schemaVersion 3 or later*'
        }
        finally { Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-IdentifierResidue — regression against this repository' {

    BeforeAll {
        ${function:Invoke-Scan} = $script:InvokeScan
    }

    It 'reports ZERO unclaimed identifiers against the current working tree' {
        # If this fails, either a real identifier just landed, or the allow-list is
        # wrong. Both are worth stopping the build for. Neither is worth silencing.
        $r = Invoke-Scan -Root $script:RepoRoot
        $detail = ($r.Findings | ForEach-Object { "$($_.File):$($_.Line) [$($_.Identifier)]" }) -join '; '
        $r.Findings.Count | Should -Be 0 -Because "unclaimed identifiers found: $detail"
    }

    It 'redacts identifiers in its own output (CI logs on a public repo are public)' {
        $r = Invoke-Scan -Root $script:RepoRoot
        foreach ($row in $r.Rows) {
            # first 8 hex + ellipsis, never the full value
            $row.Identifier | Should -Match '^[0-9a-f]{8}-\.\.\.$'
        }
    }
}
