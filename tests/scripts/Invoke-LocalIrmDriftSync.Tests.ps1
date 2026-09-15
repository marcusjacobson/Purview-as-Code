#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the pure helper functions in
    scripts/Invoke-LocalIrmDriftSync.ps1, the ADR 0060 local reverse-sync
    for the Insider Risk Management (IRM) policy surface.

.DESCRIPTION
    Pattern: AST-extract each PURE function definition and dot-source it
    into the test scope (same technique as Deploy-IRMPolicies.Tests.ps1).
    We do NOT dot-source the script itself -- its top-level code requires
    a real Azure/az context, a Purview tenant, and gh/git network access,
    none of which belong in the unit suite per tests/Run-Pester.ps1. The
    impure helpers (Invoke-ChildProcess, Invoke-GhApiCall) are pinned only
    by static-source assertions below, not by behaviour tests.

    Coverage:
      1. Get-ExpectedEnvironmentForBranch -- ADR 0057's branch mapping.
      2. The #41-incident tenant-match guard itself lives in
         scripts/modules/TenantContextGuard.psm1 (issue #215) and is
         tested there, not here -- this file's static-source checks below
         assert this script imports that module and no longer carries its
         own copy of Test-TenantDomainMatch.
      3. ConvertFrom-IrmInformationCount -- parses Deploy-IRMPolicies.ps1's
         two count lines out of a captured -InformationVariable. This
         surface has no rules, so there is no third line: a copied-over
         "Tenant rules" branch would silently never match.
      4. ConvertTo-IrmAuditRecord -- the JSON audit-record shape, including
         the #132 lesson that `rows` must serialize as a JSON array at
         0/1/N entries, and that no tenant identifier ever appears in it.
      5. ConvertFrom-GitRemoteUrl -- HTTPS/SSH remote URL parsing.
      6. Invoke-ChildProcess -- exercised against `pwsh` itself (not
         git/gh/az) to pin the single-line-output array-unroll regression
         (the #132 lesson): `return $lines` unrolls a 1-element array to a
         bare string on the caller's assignment, so a caller's `(...)[0]`
         silently indexes the string's first CHARACTER instead of the
         array's first element. Fixed with `return , $lines`.
      7. PR shape -- pinned as literals and asserted not to collide with
         either CI producer on this surface. Unlike the DLP twin there is
         no workflow PR to hold parity with; see that Describe's comment.
      8. Static-source checks: no gh pr create/edit, --force-with-lease
         present, ExportDiffFilter.psm1 imported, ADR 0028 env var
         required, -DirectionPolicy audit always paired with -WhatIf,
         git worktree used (operator checkout never switched), and
         -PruneMissing never passed.

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #190
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'Invoke-LocalIrmDriftSync.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Invoke-LocalIrmDriftSync.ps1 at: $script:ScriptPath"
    }
    $script:ScriptSource = Get-Content -LiteralPath $script:ScriptPath -Raw

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    foreach ($fname in @(
            'Get-ExpectedEnvironmentForBranch',
            'ConvertFrom-IrmInformationCount',
            'Get-DesiredPolicyCountFromYaml',
            'ConvertTo-IrmAuditRecord',
            'ConvertFrom-GitRemoteUrl',
            'Invoke-ChildProcess')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Both CI producers that write to this surface, read as text. The
    # DLP twin's suite parses its sync workflow and compares PR title /
    # labels / checklist; that is impossible here (see the PR-shape
    # Describe), so these are used only to prove divergence.
    $script:SyncWorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'sync-irm-from-tenant.yml'
    $script:DeployWorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'deploy-irm.yml'
    foreach ($p in @($script:SyncWorkflowPath, $script:DeployWorkflowPath)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Could not locate workflow: $p" }
    }
    $script:SyncWorkflowSource = Get-Content -LiteralPath $script:SyncWorkflowPath -Raw
    $script:DeployWorkflowSource = Get-Content -LiteralPath $script:DeployWorkflowPath -Raw
}

Describe 'Get-ExpectedEnvironmentForBranch' {
    It 'maps dev -> dev' {
        Get-ExpectedEnvironmentForBranch -Branch 'dev' | Should -Be 'dev'
    }
    It 'maps lab -> lab' {
        Get-ExpectedEnvironmentForBranch -Branch 'lab' | Should -Be 'lab'
    }
    It 'maps main -> lab' {
        Get-ExpectedEnvironmentForBranch -Branch 'main' | Should -Be 'lab'
    }
    It 'maps an arbitrary feature branch -> lab' {
        Get-ExpectedEnvironmentForBranch -Branch 'fix/some-thing' | Should -Be 'lab'
    }
}

Describe 'ConvertFrom-IrmInformationCount' {
    It 'parses both shipped count-line formats exactly (padded spaces included)' {
        # Deploy-IRMPolicies.ps1 emits "Desired policies: N" unpadded and
        # "Tenant policies : N" with one padding space before the colon.
        # Both literals are reproduced here exactly as the script writes
        # them; a regex that tolerated either spacing would not catch a
        # future change to the producer.
        $lines = @(
            'Desired policies: 7',
            'Tenant policies : 8'
        )
        $result = ConvertFrom-IrmInformationCount -Lines $lines
        $result.DesiredPolicies | Should -Be 7
        $result.TenantPolicies | Should -Be 8
    }

    It 'exposes no TenantRules property: this surface has no rules' {
        # The DLP twin parses a third "Tenant rules : N" line. IRM policies
        # have no rule objects at all, so carrying the property over would
        # publish a permanently-null count in every audit record.
        $result = ConvertFrom-IrmInformationCount -Lines @('Desired policies: 7')
        $result.PSObject.Properties.Name | Should -Not -Contain 'TenantRules'
    }

    It 'ignores unrelated lines and leaves missing counts as $null' {
        $lines = @('Mode            : Export', 'Desired policies: 7')
        $result = ConvertFrom-IrmInformationCount -Lines $lines
        $result.DesiredPolicies | Should -Be 7
        $result.TenantPolicies | Should -BeNullOrEmpty
    }

    It 'returns all-$null for an empty line set' {
        $result = ConvertFrom-IrmInformationCount -Lines @()
        $result.DesiredPolicies | Should -BeNullOrEmpty
        $result.TenantPolicies | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-IrmAuditRecord' {
    BeforeAll {
        $script:Counts = [pscustomobject]@{ DesiredPolicies = 7; TenantPolicies = 8 }
    }

    It 'includes every documented key' {
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $record.schemaVersion | Should -Be 1
        $record.surface | Should -Be 'irm'
        $record.environment | Should -Be 'lab'
        $record.mode | Should -Be 'audit'
        $record.counts.desiredPolicies | Should -Be 7
        $record.counts.tenantPolicies | Should -Be 8
        $record.drift.detected | Should -BeFalse
        $record.pr | Should -BeNullOrEmpty
    }

    It 'declares schemaVersion 1, the shape the operations console already reads' {
        # The console globs .copilot-tracking/audit/*.json and renders any
        # record generically (Start-OperationsConsole.ps1's
        # ConvertFrom-TenantAuditRecord). Bumping the version here without
        # touching the console would silently drop this surface's panel
        # row, so the version is pinned rather than merely present.
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $record.schemaVersion | Should -Be 1
        $record.tool | Should -Be 'Invoke-LocalIrmDriftSync.ps1'
    }

    It 'carries no tenantRules count, unlike the DLP record' {
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $record.counts.PSObject.Properties.Name | Should -Not -Contain 'tenantRules'
    }

    It 'carries no tenant identifier (tenant ID, tenant domain, subscription, app ID)' {
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'sync' -WhatIfMode $false `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows @()
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Not -Match '(?i)tenantid'
        $json | Should -Not -Match '(?i)tenantdomain'
        $json | Should -Not -Match '(?i)subscription'
        $json | Should -Not -Match '(?i)appid'
    }

    It 'serializes rows as a JSON array with exactly 0 entries' {
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Match '"rows":\s*\[\s*\]'
    }

    It 'serializes rows as a JSON array with exactly 1 entry (the #132 lesson)' {
        $rows = @([pscustomobject]@{ Category = 'Update'; Kind = 'IRMPolicy'; Name = 'X'; Reason = 'drift' })
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows $rows
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Match '"rows":\s*\['
        $parsed = $json | ConvertFrom-Json -Depth 12
        @($parsed.rows).Count | Should -Be 1
    }

    It 'serializes rows as a JSON array with N entries' {
        $rows = @(
            [pscustomobject]@{ Category = 'Update'; Kind = 'IRMPolicy'; Name = 'X'; Reason = 'drift' },
            [pscustomobject]@{ Category = 'NoChange'; Kind = 'IRMPolicy'; Name = 'Y'; Reason = '' }
        )
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows $rows
        $parsed = ($record | ConvertTo-Json -Depth 12) | ConvertFrom-Json -Depth 12
        @($parsed.rows).Count | Should -Be 2
    }

    It 'populates pr when a PR number is supplied' {
        $record = ConvertTo-IrmAuditRecord -Environment 'lab' -Mode 'sync' -WhatIfMode $false `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/irm-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows @() `
            -PrNumber 165 -PrUrl 'https://github.com/x/y/pull/165' -PrOperation 'created'
        $record.pr.number | Should -Be 165
        $record.pr.operation | Should -Be 'created'
    }
}

Describe 'Invoke-ChildProcess' {
    BeforeAll {
        $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    It 'returns an array a caller can safely index with [0] for a single line of output (regression: the #132-style unroll bug)' {
        $lines = Invoke-ChildProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NoLogo', '-Command', "Write-Output 'single-line-only'")
        $lines.GetType().IsArray | Should -BeTrue -Because 'a bare string return would unroll on the caller''s assignment'
        $lines[0] | Should -Be 'single-line-only' -Because 'indexing [0] must return the whole first line, not its first character'
    }

    It 'returns all lines for multi-line output' {
        $lines = Invoke-ChildProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NoLogo', '-Command', "Write-Output 'line1'; Write-Output 'line2'")
        @($lines).Count | Should -Be 2
        $lines[0] | Should -Be 'line1'
        $lines[1] | Should -Be 'line2'
    }

    It 'throws with the captured output on a non-zero exit code' {
        { Invoke-ChildProcess -FilePath $script:PwshPath -ArgumentList @('-NoProfile', '-NoLogo', '-Command', "Write-Output 'boom'; exit 3") } | Should -Throw '*boom*'
    }
}

Describe 'ConvertFrom-GitRemoteUrl' {
    It 'parses an HTTPS remote URL' {
        $result = ConvertFrom-GitRemoteUrl -RemoteUrl 'https://github.com/marcusjacobson/Purview-as-Code-Operations.git'
        $result.Owner | Should -Be 'marcusjacobson'
        $result.Repo | Should -Be 'Purview-as-Code-Operations'
    }

    It 'parses an SSH remote URL' {
        $result = ConvertFrom-GitRemoteUrl -RemoteUrl 'git@github.com:marcusjacobson/Purview-as-Code-Operations.git'
        $result.Owner | Should -Be 'marcusjacobson'
        $result.Repo | Should -Be 'Purview-as-Code-Operations'
    }

    It 'throws on an unparseable URL' {
        { ConvertFrom-GitRemoteUrl -RemoteUrl 'not-a-url' } | Should -Throw
    }
}

Describe 'PR shape is script-owned and collides with neither CI producer' {
    # The DLP twin's suite compares this script's PR title, labels and
    # review checklist against sync-dlp-from-tenant.yml's 'Open or update
    # drift-back PR' step, so the local and CI paths can never drift
    # apart. That comparison is impossible here and would be wrong:
    # sync-irm-from-tenant.yml opens a GitHub ISSUE, not a pull request,
    # so there is no workflow PR shape to hold parity with. What this
    # surface needs pinned instead is that the script owns its PR shape
    # outright, and that its branch cannot collide with either of the two
    # workflows that also write here.

    It 'has no CI counterpart to hold parity with: the reverse-sync workflow opens an issue' {
        $script:SyncWorkflowSource | Should -Match 'gh issue create'
        $script:SyncWorkflowSource | Should -Not -Match 'create-pull-request'
    }

    It 'pins the PR title and the commit subject to the same conventional-commit line' {
        $subject = 'chore(data-plane): sync IRM policies from tenant'
        $script:ScriptSource | Should -Match ([regex]::Escape("title=$subject"))
        $script:ScriptSource | Should -Match ([regex]::Escape("`$commitMessage = `"$subject"))
    }

    It 'applies exactly the two review labels, and never the drift-detected issue label' {
        # drift-detected belongs to the reverse-sync workflow's issue, which
        # self-provisions it. A pull request is not a drift issue, and this
        # script provisions no labels -- a POST against a missing label
        # would fail the run.
        $script:ScriptSource | Should -Match ([regex]::Escape('labels[]=needs-review'))
        $script:ScriptSource | Should -Match ([regex]::Escape('labels[]=squad:automation-engineer'))
        $script:ScriptSource | Should -Not -Match ([regex]::Escape('labels[]=drift-detected'))
        $script:ScriptSource | Should -Not -Match 'gh label create'
    }

    It 'opens a pull request and never an issue' {
        $script:ScriptSource | Should -Match ([regex]::Escape('-Path "$repoPath/pulls" -Method POST'))
        # The labels endpoint is /issues/<n>/labels because GitHub models a
        # PR as an issue; that is the only /issues path allowed here.
        foreach ($m in [regex]::Matches($script:ScriptSource, '\$repoPath/issues[^"]*')) {
            $m.Value | Should -Match '^\$repoPath/issues/\$\(\$prResult\.Number\)/labels$'
        }
    }

    It 'names every IRM-specific hazard in the review checklist' {
        # Each item exists because a reviewer cannot get it from the diff
        # alone: the system-managed policies are invisible by design, the
        # residue scan cannot see non-GUID identities, and a scenario
        # change can never be applied at all.
        $script:ScriptSource | Should -Match 'IRM_Tenant_Setting_\*'
        $script:ScriptSource | Should -Match 'residue scan is GUID-shaped only'
        $script:ScriptSource | Should -Match 'InsiderRiskScenario.. is set-once'
        $script:ScriptSource | Should -Match 'direction_policy=portal-wins'
    }

    It 'defaults to a sync branch distinct from the forward workflow''s drift-back branch' {
        # deploy-irm.yml re-exports on a portal-wins push and opens its own
        # PR on auto/irm-portal-wins-drift-<env>. Two producers sharing one
        # branch would have them overwrite each other's commits.
        $script:DeployWorkflowSource | Should -Match 'branch: auto/irm-portal-wins-drift-'
        $defaultLines = @(($script:ScriptSource -split "`n") | Where-Object { $_ -match '\$SyncBranch\s*=\s*"auto/' })
        $defaultLines.Count | Should -Be 1
        $defaultLines[0] | Should -Match 'auto/irm-drift-sync-'
        $defaultLines[0] | Should -Not -Match 'portal-wins'
    }
}

Describe 'Static-source checks' {
    It 'never invokes gh pr create or gh pr edit as executable code (prose mentions in comments are fine)' {
        # All gh calls in this script go through Invoke-GhApiCall, which
        # always shells `gh api ...`. Assert that shape, and separately
        # that no line resembling an actual `gh pr create`/`gh pr edit`
        # invocation (as opposed to prose naming them, which the comment-
        # based help does deliberately) is present.
        $script:ScriptSource | Should -Match "FilePath 'gh' -ArgumentList \`$ghArgs\.ToArray\(\)" -Because 'every gh call must go through Invoke-GhApiCall'
        foreach ($line in ($script:ScriptSource -split "`n")) {
            if ($line -match '^\s*#' -or $line -match '<#' -or $line -match '#>') { continue }
            $line | Should -Not -Match "gh\.exe\s+pr\s+(create|edit)"
            $line | Should -Not -Match "&\s*gh\s+pr\s+(create|edit)"
        }
    }

    It 'requires PURVIEW_LOCAL_CERT_THUMBPRINT before any tenant/az call' {
        $script:ScriptSource | Should -Match 'PURVIEW_LOCAL_CERT_THUMBPRINT'
    }

    It 'imports ExportDiffFilter.psm1' {
        $script:ScriptSource | Should -Match 'ExportDiffFilter\.psm1'
    }

    It 'imports TenantContextGuard.psm1, and no longer carries its own Test-TenantDomainMatch (issue #215)' {
        $script:ScriptSource | Should -Match 'TenantContextGuard\.psm1'
        $script:ScriptSource | Should -Not -Match 'function Test-TenantDomainMatch' -Because 'this used to be a byte-identical copy shared with Invoke-LocalDlpDriftSync.ps1; both now import the shared module instead'
        $script:ScriptSource | Should -Match 'Assert-TenantContextMatchesParametersFile'
    }

    It 'uses git worktree rather than switching the operator''s own checkout' {
        # git calls go through Invoke-ChildProcess with -ArgumentList as
        # an array literal (e.g. @('-C', $repoRoot, 'worktree', 'add', ...)),
        # not a single joined command string.
        $script:ScriptSource | Should -Match "'worktree'\s*,\s*'add'\s*,\s*'--detach'"
        $script:ScriptSource | Should -Match "'worktree'\s*,\s*'remove'\s*,\s*'--force'"
    }

    It 'pushes with --force-with-lease' {
        $script:ScriptSource | Should -Match '--force-with-lease'
    }

    It 'declares SupportsShouldProcess' {
        $script:ScriptSource | Should -Match 'SupportsShouldProcess\s*=\s*\$true'
    }

    It 'always pairs -DirectionPolicy audit with -WhatIf' {
        $script:ScriptSource | Should -Match '-DirectionPolicy audit -WhatIf'
    }

    It 'never calls Connect-IPPSSession directly (delegates auth to Deploy-IRMPolicies.ps1)' {
        $script:ScriptSource | Should -Not -Match 'Connect-IPPSSession'
    }

    It 'never passes -PruneMissing' {
        # Deletion is out of scope for a drift-back sync in either
        # direction, and -PruneMissing is banned outright on this surface
        # (data-plane/irm/policies.yaml's header records the ruling).
        $script:ScriptSource | Should -Not -Match '-PruneMissing'
    }

    It 'stamps Kind on every audit row so the console panel renders a value' {
        # Deploy-IRMPolicies.ps1's report rows carry Category/Name/Reason
        # only. The console reads row.Kind; without this the IRM records
        # would be the one surface showing a blank column.
        $script:ScriptSource | Should -Match "Kind = 'IRMPolicy'"
    }
}

Describe 'Get-DesiredPolicyCountFromYaml (issue #258)' {
    # A SYNC run drives Deploy-IrmPolicies.ps1 with -ExportCurrentState,
    # whose desired-state load region is guarded `if ($mode -eq 'Apply')`.
    # So "Desired policies: N" is never emitted on a sync run's success
    # path, and the audit record used to ship counts.desiredPolicies =
    # null -- which site/app.js renders as "Desired: --" for every
    # drifted surface. This helper is where the count now comes from.

    It 'counts the entries of a well-formed desired-state document' {
        $yaml = @'
policies:
  - name: alpha
    enabled: false
  - name: beta
    enabled: true
  - name: gamma
    enabled: true
'@
        Get-DesiredPolicyCountFromYaml -YamlText $yaml | Should -Be 3
    }

    It 'ignores comment headers, which every committed file carries' {
        $yaml = @'
# ----------------------------------------------------------------
# A long explanatory header, as shipped on every data-plane file.
# ----------------------------------------------------------------
policies:
  - name: only-one
    enabled: false
'@
        Get-DesiredPolicyCountFromYaml -YamlText $yaml | Should -Be 1
    }

    It 'returns 0 for an explicitly empty policy list' {
        Get-DesiredPolicyCountFromYaml -YamlText "policies: []`n" | Should -Be 0
    }

    It 'returns 0, not 1, for a null policies key (the @($null).Count trap)' {
        # @($null).Count is 1 in PowerShell, so a naive implementation
        # reports one desired policy for a document that declares none.
        Get-DesiredPolicyCountFromYaml -YamlText "policies:`n" | Should -Be 0
    }

    It 'returns 0 for a document with no policies key at all' {
        Get-DesiredPolicyCountFromYaml -YamlText "entityLists: []`n" | Should -Be 0
    }

    It 'returns 0 rather than throwing on empty, whitespace, or null input' {
        Get-DesiredPolicyCountFromYaml -YamlText '' | Should -Be 0
        Get-DesiredPolicyCountFromYaml -YamlText "   `n  " | Should -Be 0
        Get-DesiredPolicyCountFromYaml -YamlText $null | Should -Be 0
    }

    It 'returns 0 rather than throwing on a document that does not parse' {
        # This feeds a reporting field. A desired-state file this broken
        # fails the reconciler with a far better message than this helper
        # could give, so it must not be the thing that raises.
        { Get-DesiredPolicyCountFromYaml -YamlText "policies:`n  - name: [unclosed`n" } | Should -Not -Throw
    }

    It 'exactly one entry is a real count, not a truthiness test' {
        Get-DesiredPolicyCountFromYaml -YamlText "policies:`n  - name: solo`n" | Should -Be 1
    }
}

Describe 'the sync-mode desired count is wired in (red-replay for issue #258)' {
    It 'ConvertFrom-IrmInformationCount really does return $null on a sync run''s captured stream' {
        # The defect, reproduced directly: this is the information stream
        # a real -ExportCurrentState run emits -- note there is no
        # "Desired policies:" line in it at all. Without this assertion
        # the fallback below could be dead code and the suite would not
        # notice.
        $syncStream = @(
            'Mode            : Export'
            'Environment     : lab'
            'az context OK: contoso-lab.cloud -> example.onmicrosoft.com'
            'Tenant policies : 8'
        )
        $counts = ConvertFrom-IrmInformationCount -Lines $syncStream
        $counts.DesiredPolicies | Should -BeNullOrEmpty
        $counts.TenantPolicies | Should -Be 8
    }

    It 'the script takes the count BEFORE the export overwrites the file' {
        # Ordering is the whole fix: read it after the export and the
        # number is the tenant's, not the repo's, and the record silently
        # stops meaning what it says.
        $capture = [regex]::Match($script:ScriptSource, '(?s)\$desiredCountBeforeExport = Get-DesiredPolicyCountFromYaml.*?
?
')
        $capture.Success | Should -BeTrue
        $exportCall = $script:ScriptSource.IndexOf('-ExportCurrentState -Force -Confirm:$false -Path $yamlPath')
        $exportCall | Should -BeGreaterThan 0
        $capture.Index | Should -BeLessThan $exportCall
    }

    It 'the fallback only fires when the reconciler supplied no count' {
        $script:ScriptSource | Should -Match '\$null -eq \$counts\.DesiredPolicies\) \{ \$counts\.DesiredPolicies = \$desiredCountBeforeExport \}'
    }
}

Describe 'The drift-back push survives a stale remote-tracking ref (issue #279)' {
    # --force-with-lease takes its expected value from
    # refs/remotes/<remote>/<syncBranch>. This runbook's own workflow deletes
    # that branch from the remote once the drift-back PR is closed, and a plain
    # `git fetch` never prunes the now-stale tracking ref -- so run N+1 on the
    # same workstation died with `! [rejected] ... (stale info)` AFTER
    # detecting the drift and making the commit. Deterministic, not flaky.

    It 'prunes the sync branch''s tracking ref immediately before pushing' {
        $script:ScriptSource | Should -Match "'fetch', '--prune'"
        $prune = $script:ScriptSource.IndexOf("'fetch', '--prune'")
        $push  = $script:ScriptSource.IndexOf("'push', '--force-with-lease'")
        $prune | Should -BeGreaterThan 0
        $push  | Should -BeGreaterThan 0
        $prune | Should -BeLessThan $push
    }

    It 'uses a WILDCARD refspec, because an exact one is fatal when the branch is gone' {
        # `git fetch --prune origin +refs/heads/b:refs/remotes/origin/b` fails
        # with "couldn't find remote ref" and prunes nothing when the branch is
        # absent remotely -- which is exactly the case this fixes. Only a
        # wildcard pattern prunes. Verified empirically before shipping.
        $script:ScriptSource | Should -Match '\+refs/heads/\$SyncBranch\*:refs/remotes/\$Remote/\$SyncBranch\*'
    }

    It 'anchors the wildcard to the sync branch, so other auto/* refs are untouched' {
        $script:ScriptSource | Should -Not -Match '\+refs/heads/auto/\*'
    }

    It 'KEEPS the lease rather than reaching for --force' {
        # The branch is force-pushed; the lease is what stops a concurrent
        # update -- another operator's run, or a reviewer's commit on the PR --
        # from being silently overwritten. Dropping it would fix the symptom by
        # deleting the safety property.
        $script:ScriptSource | Should -Match "'push', '--force-with-lease'"
        $script:ScriptSource | Should -Not -Match "'push', '--force'"
    }

    It 'prunes in the REPO, not the throwaway worktree' {
        # The stale ref lives in the operator's own clone; pruning inside the
        # temporary worktree would fix nothing that outlives the run.
        $script:ScriptSource | Should -Match "'-C', \`$repoRoot, 'fetch', '--prune'"
    }
}
