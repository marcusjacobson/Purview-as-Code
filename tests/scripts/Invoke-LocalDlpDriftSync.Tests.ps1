#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for the pure helper functions in
    scripts/Invoke-LocalDlpDriftSync.ps1, the ADR 0060 local equivalent
    of sync-dlp-from-tenant.yml's sync job.

.DESCRIPTION
    Pattern: AST-extract each PURE function definition and dot-source it
    into the test scope (same technique as Deploy-DLPPolicies.Tests.ps1).
    We do NOT dot-source the script itself -- its top-level code requires
    a real Azure/az context, a Purview tenant, and gh/git network access,
    none of which belong in the unit suite per tests/Run-Pester.ps1. The
    impure helpers (Invoke-ChildProcess, Invoke-GhApiCall) are pinned only
    by static-source assertions below, not by behaviour tests.

    Coverage:
      1. Get-ExpectedEnvironmentForBranch -- ADR 0057's branch mapping.
      2. Test-TenantDomainMatch -- the #41-incident tenant-match guard.
      3. ConvertFrom-DlpInformationCount -- parses Deploy-DLPPolicies.ps1's
         three count lines out of a captured -InformationVariable.
      4. ConvertTo-DlpAuditRecord -- the JSON audit-record shape, including
         the #132 lesson that `rows` must serialize as a JSON array at
         0/1/N entries, and that no tenant identifier ever appears in it.
      5. ConvertFrom-GitRemoteUrl -- HTTPS/SSH remote URL parsing.
      6. Invoke-ChildProcess -- exercised against `pwsh` itself (not
         git/gh/az) to pin the single-line-output array-unroll regression
         found while smoke-testing this script: `return $lines` unrolls a
         1-element array to a bare string on the caller's assignment (the
         #132 lesson, hit here too), so a caller's `(...)[0]` silently
         indexes the string's first CHARACTER instead of the array's
         first element. Fixed with `return , $lines`.
      7. PR-shape parity with the shipped sync-dlp-from-tenant.yml
         workflow (title / labels / review-checklist text).
      8. Static-source checks: no gh pr create/edit, --force-with-lease
         present, ExportDiffFilter.psm1 imported, ADR 0028 env var
         required, -DirectionPolicy audit always paired with -WhatIf,
         git worktree used (operator checkout never switched).

    Reference: https://pester.dev/docs/quick-start
    Reference: issue #164
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'Invoke-LocalDlpDriftSync.ps1'
    if (-not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw "Could not locate Invoke-LocalDlpDriftSync.ps1 at: $script:ScriptPath"
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
            'Test-TenantDomainMatch',
            'ConvertFrom-DlpInformationCount',
            'ConvertTo-DlpAuditRecord',
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

    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'sync-dlp-from-tenant.yml'
    Import-Module 'powershell-yaml' -ErrorAction Stop
    $script:Workflow = (Get-Content -LiteralPath $script:WorkflowPath -Raw) | ConvertFrom-Yaml
    function Get-WorkflowStep {
        param([Parameter(Mandatory)][string]$NamePrefix)
        foreach ($jobKey in $script:Workflow['jobs'].Keys) {
            foreach ($step in $script:Workflow['jobs'][$jobKey]['steps']) {
                if ([string]$step['name'] -like "$NamePrefix*") { return $step }
            }
        }
        throw "Step matching '$NamePrefix*' not found in $script:WorkflowPath"
    }
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

Describe 'Test-TenantDomainMatch' {
    BeforeAll {
        # Synthetic tenant IDs (reserved 00000000-0000-0000-0000-<counter>
        # namespace, ADR 0055) and .example domains (RFC 2606) -- never
        # real tenant identifiers, per the ADR 0055 residue scan.
        $script:LabTenantId = '00000000-0000-0000-0000-000000000001'
        $script:DevTenantId = '00000000-0000-0000-0000-000000000002'
        $script:Tenants = @(
            [pscustomobject]@{
                tenantId       = $script:LabTenantId
                defaultDomain  = 'contoso-lab.example'
                domains        = @('contosolab.onmicrosoft.example', 'contoso-lab.example')
            },
            [pscustomobject]@{
                tenantId       = $script:DevTenantId
                defaultDomain  = 'contoso-dev.example'
                domains        = @('contosodev.onmicrosoft.example', 'contoso-dev.example')
            }
        )
    }

    It 'matches on defaultDomain' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeTrue
    }

    It 'matches on a domains[] entry that is not the default' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contosolab.onmicrosoft.example' | Should -BeTrue
    }

    It 'matches case-insensitively' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:LabTenantId.ToUpper() -ExpectedDomain 'CONTOSO-LAB.EXAMPLE' | Should -BeTrue
    }

    It 'returns $false when the tenant matches but the domain does not (wrong tenant, the #41 trap)' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId $script:DevTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }

    It 'returns $false when the current tenant ID is absent from the list' {
        Test-TenantDomainMatch -Tenants $script:Tenants -CurrentTenantId '00000000-0000-0000-0000-000000000000' -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }

    It 'returns $false for an empty tenants list' {
        Test-TenantDomainMatch -Tenants @() -CurrentTenantId $script:LabTenantId -ExpectedDomain 'contoso-lab.example' | Should -BeFalse
    }
}

Describe 'ConvertFrom-DlpInformationCount' {
    It 'parses all three shipped count-line formats exactly (padded spaces included)' {
        $lines = @(
            'Desired policies: 11',
            'Tenant policies : 11',
            'Tenant rules    : 24'
        )
        $result = ConvertFrom-DlpInformationCount -Lines $lines
        $result.DesiredPolicies | Should -Be 11
        $result.TenantPolicies | Should -Be 11
        $result.TenantRules | Should -Be 24
    }

    It 'ignores unrelated lines and leaves missing counts as $null' {
        $lines = @('Mode            : Export', 'Desired policies: 7')
        $result = ConvertFrom-DlpInformationCount -Lines $lines
        $result.DesiredPolicies | Should -Be 7
        $result.TenantPolicies | Should -BeNullOrEmpty
        $result.TenantRules | Should -BeNullOrEmpty
    }

    It 'returns all-$null for an empty line set' {
        $result = ConvertFrom-DlpInformationCount -Lines @()
        $result.DesiredPolicies | Should -BeNullOrEmpty
        $result.TenantPolicies | Should -BeNullOrEmpty
        $result.TenantRules | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-DlpAuditRecord' {
    BeforeAll {
        $script:Counts = [pscustomobject]@{ DesiredPolicies = 11; TenantPolicies = 11; TenantRules = 24 }
    }

    It 'includes every documented key' {
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $record.schemaVersion | Should -Be 1
        $record.surface | Should -Be 'dlp'
        $record.environment | Should -Be 'lab'
        $record.mode | Should -Be 'audit'
        $record.counts.desiredPolicies | Should -Be 11
        $record.drift.detected | Should -BeFalse
        $record.pr | Should -BeNullOrEmpty
    }

    It 'carries no tenant identifier (tenant ID, tenant domain, subscription, app ID)' {
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'sync' -WhatIfMode $false `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows @()
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Not -Match '(?i)tenantid'
        $json | Should -Not -Match '(?i)tenantdomain'
        $json | Should -Not -Match '(?i)subscription'
        $json | Should -Not -Match '(?i)appid'
    }

    It 'serializes rows as a JSON array with exactly 0 entries' {
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $false -CosmeticOnly $false -Rows @()
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Match '"rows":\s*\[\s*\]'
    }

    It 'serializes rows as a JSON array with exactly 1 entry (the #132 lesson)' {
        $rows = @([pscustomobject]@{ Category = 'Update'; Kind = 'Policy'; Name = 'X'; Reason = 'drift' })
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows $rows
        $json = $record | ConvertTo-Json -Depth 12
        $json | Should -Match '"rows":\s*\['
        $parsed = $json | ConvertFrom-Json -Depth 12
        @($parsed.rows).Count | Should -Be 1
    }

    It 'serializes rows as a JSON array with N entries' {
        $rows = @(
            [pscustomobject]@{ Category = 'Update'; Kind = 'Policy'; Name = 'X'; Reason = 'drift' },
            [pscustomobject]@{ Category = 'NoChange'; Kind = 'Policy'; Name = 'Y'; Reason = '' }
        )
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'audit' -WhatIfMode $true `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
            -Counts $script:Counts -DriftDetected $true -CosmeticOnly $false -Rows $rows
        $parsed = ($record | ConvertTo-Json -Depth 12) | ConvertFrom-Json -Depth 12
        @($parsed.rows).Count | Should -Be 2
    }

    It 'populates pr when a PR number is supplied' {
        $record = ConvertTo-DlpAuditRecord -Environment 'lab' -Mode 'sync' -WhatIfMode $false `
            -Timestamp (Get-Date) -BaseBranch 'lab' -BaseCommit 'abc123' -SyncBranch 'auto/dlp-drift-sync-lab' `
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

Describe 'PR-shape parity with sync-dlp-from-tenant.yml' {
    It 'uses the identical PR title' {
        $step = Get-WorkflowStep -NamePrefix 'Open or update drift-back PR'
        $expectedTitle = [string]$step['with']['title']
        $script:ScriptSource | Should -Match ([regex]::Escape($expectedTitle))
    }

    It 'applies the identical label set' {
        $step = Get-WorkflowStep -NamePrefix 'Open or update drift-back PR'
        $labels = ([string]$step['with']['labels']).Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($label in $labels) {
            $script:ScriptSource | Should -Match ([regex]::Escape("labels[]=$label"))
        }
    }

    It 'carries the same review-checklist items as the workflow body' {
        # Compare with backticks stripped on both sides: the workflow's
        # YAML body uses literal single backticks for inline code, while
        # the script's PowerShell double-quoted string must escape each
        # single backtick as a literal double-backtick (`` -> ` at
        # runtime) -- an escaping difference, not a content difference,
        # so raw source-text comparison must normalize it away.
        $step = Get-WorkflowStep -NamePrefix 'Open or update drift-back PR'
        $body = [string]$step['with']['body']
        $checklistLines = ($body -split "`n") | Where-Object { $_ -match '^\s*-\s*\[ \]' } | ForEach-Object { ($_ -replace '^\s*-\s*\[ \]\s*', '').Trim() }
        $normalizedSource = $script:ScriptSource -replace '`', ''
        foreach ($item in $checklistLines) {
            $normalizedItem = $item -replace '`', ''
            $firstWords = ($normalizedItem -split '\s+' | Select-Object -First 6) -join ' '
            $normalizedSource | Should -Match ([regex]::Escape($firstWords)) -Because "the script's PR body should carry the same checklist item: $item"
        }
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

    It 'never calls Connect-IPPSSession directly (delegates auth to Deploy-DLPPolicies.ps1)' {
        $script:ScriptSource | Should -Not -Match 'Connect-IPPSSession'
    }

    It 'pins the ARM tenants API version literal' {
        $script:ScriptSource | Should -Match 'tenants\?api-version=2022-12-01'
    }
}
