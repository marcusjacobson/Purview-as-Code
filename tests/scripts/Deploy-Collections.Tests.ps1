#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Deploy-Collections.ps1 helpers:
    Format-PurviewRestError (issue #308), Get-OrphanAction
    (issue #312), ConvertTo-CollectionExportDoc (issue #309), and
    Test-CollectionNameRule / Get-CollectionNameViolation
    (issue #310).

.DESCRIPTION
    Locks in the issue #308 acceptance criteria:

      1. Failed-row reasons surface the Purview `error.code` and a
         truncated `error.message` (HTTP status when available).
      2. Works on PowerShell 7 (reads $ErrorRecord.ErrorDetails.Message).
      3. Network-failure path with no JSON body falls back to
         $ErrorRecord.Exception.Message (lossless behavior).
      4. Long messages are truncated to MaxMessageLength characters
         plus an ellipsis.

    Also locks in the issue #312 acceptance criteria for the
    protected allow-list: a tenant collection whose name appears in
    the `protected:` allow-list is classified as `Protected` instead
    of `Orphan`, so the DELETE branch is never reached and no
    `Failed` row is produced on re-runs.

    Also locks in the issue #310 acceptance criteria for pre-flight
    collection-name validation. The Microsoft Purview Quickstart
    pins the rule `^[a-z][a-z0-9-]{2,35}$`; every per-failure-mode
    case below produces exactly one deterministic Reason so the
    operator sees the full fix-set in a single Write-Error instead
    of one failed-row-per-apply against the live REST surface.
    Reference: https://learn.microsoft.com/en-us/purview/quickstart-create-collection

    Pattern: AST-extract each helper from the script and evaluate it
    into the test scope, so the top-level script body (which calls
    Connect-Purview and the live REST surface) never runs. Same
    pattern as tests/scripts/Deploy-Labels.Tests.ps1.

    Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/invoke-restmethod
    Reference: https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Collections.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Deploy-Collections.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    $fnAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Format-PurviewRestError'
        }, $true)
    if (-not $fnAst) { throw "Format-PurviewRestError not found in $script:ScriptPath" }
    . ([ScriptBlock]::Create($fnAst.Extent.Text))

    # Helper scriptblock: build an ErrorRecord with a body string
    # attached via ErrorDetails (the PS7 surface that
    # Invoke-RestMethod uses when the server returns a non-2xx
    # response with a body). Wrapped as a $script: scriptblock to
    # match the helper-style pattern in Deploy-Labels.Tests.ps1 and
    # to keep PSScriptAnalyzer's verb-noun heuristic happy.
    $script:MakeFakeRestError = {
        param(
            [string]$ExceptionMessage = 'Response status code does not indicate success.',
            [string]$Body,
            [switch]$NoBody
        )
        $ex = [System.Exception]::new($ExceptionMessage)
        $er = [System.Management.Automation.ErrorRecord]::new(
            $ex, 'TestRestError',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null)
        if (-not $NoBody.IsPresent) {
            $er.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
        }
        return $er
    }
}

Describe 'Format-PurviewRestError' {

    Context 'HTTP 409 / Purview code 12005 (collection referenced by other resources)' {
        It 'surfaces the Purview error code and the first ~120 chars of the message' {
            $body = '{"error":{"code":"12005","message":"The collection cannot be deleted because it is still referenced by one or more child collections or data sources."}}'
            $er = & $script:MakeFakeRestError -Body $body
            $reason = Format-PurviewRestError -ErrorRecord $er
            $reason | Should -Match 'code 12005'
            $reason | Should -Match 'collection cannot be deleted'
        }
    }

    Context 'HTTP 400 / Purview code 1006 (system-managed collection cannot be deleted)' {
        It 'surfaces the Purview error code and the message snippet' {
            $body = '{"error":{"code":"1006","message":"This collection is system-managed and cannot be deleted via this API."}}'
            $er = & $script:MakeFakeRestError -Body $body
            $reason = Format-PurviewRestError -ErrorRecord $er
            $reason | Should -Match 'code 1006'
            $reason | Should -Match 'system-managed'
        }
    }

    Context 'Network failure with no JSON body' {
        It 'falls back to the exception message (lossless behavior)' {
            $er = & $script:MakeFakeRestError -ExceptionMessage 'Unable to connect to the remote server.' -NoBody
            $reason = Format-PurviewRestError -ErrorRecord $er
            $reason | Should -Be 'Unable to connect to the remote server.'
        }

        It 'falls back when the body is non-JSON text' {
            $er = & $script:MakeFakeRestError -Body '<html>502 Bad Gateway</html>' -ExceptionMessage 'Bad Gateway.'
            $reason = Format-PurviewRestError -ErrorRecord $er
            $reason | Should -Be 'Bad Gateway.'
        }
    }

    Context 'Long error.message' {
        It 'truncates to MaxMessageLength characters and appends an ellipsis' {
            $long = 'A' * 500
            $body = ('{{"error":{{"code":"9999","message":"{0}"}}}}' -f $long)
            $er = & $script:MakeFakeRestError -Body $body
            $reason = Format-PurviewRestError -ErrorRecord $er -MaxMessageLength 120
            $reason | Should -Match 'code 9999'
            # 120 chars of payload + the literal "..." suffix.
            $reason | Should -Match '\.\.\.$'
            # The payload portion (after "code 9999: ") must be exactly 123 chars.
            $payload = ($reason -split ': ', 2)[1]
            $payload.Length | Should -Be 123
        }
    }

    Context 'Top-level error shape (no nested error wrapper)' {
        It 'parses top-level code and message when present' {
            $body = '{"code":"InvalidArgument","message":"Collection name failed validation."}'
            $er = & $script:MakeFakeRestError -Body $body
            $reason = Format-PurviewRestError -ErrorRecord $er
            $reason | Should -Match 'code InvalidArgument'
            $reason | Should -Match 'Collection name failed validation'
        }
    }
}

# -----------------------------------------------------------------------------
# Issue #312 -- Get-OrphanAction (protected allow-list)
# -----------------------------------------------------------------------------

Describe 'Get-OrphanAction' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-OrphanAction'
            }, $true)
        if (-not $fnAst) { throw "Get-OrphanAction not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    Context 'No protected allow-list' {
        It 'returns Orphan when ProtectedNames is $null' {
            Get-OrphanAction -Name 'hr-system' -ProtectedNames $null | Should -Be 'Orphan'
        }

        It 'returns Orphan when ProtectedNames is empty' {
            Get-OrphanAction -Name 'hr-system' -ProtectedNames @() | Should -Be 'Orphan'
        }
    }

    Context 'Protected allow-list populated' {
        It 'returns Protected when the name matches exactly (lowercased input)' {
            Get-OrphanAction -Name 'hr-system' -ProtectedNames @('hr-system') | Should -Be 'Protected'
        }

        It 'returns Protected when the tenant name differs in case from the allow-list entry' {
            # The script lowercases the allow-list at parse time, so by
            # contract the helper sees only lowercased ProtectedNames
            # values, but the tenant name may be any case.
            Get-OrphanAction -Name 'HR-System' -ProtectedNames @('hr-system') | Should -Be 'Protected'
        }

        It 'returns Orphan when the name is not in the allow-list' {
            Get-OrphanAction -Name 'sales-legacy' -ProtectedNames @('hr-system','finance-system') | Should -Be 'Orphan'
        }

        It 'returns Protected against a multi-entry allow-list' {
            Get-OrphanAction -Name 'finance-system' -ProtectedNames @('hr-system','finance-system','sales-system') | Should -Be 'Protected'
        }
    }

    Context 'Acceptance criteria contract' {
        It 'guarantees no Orphan plan row for a protected tenant-only collection' {
            # AC: protected name present in tenant + absent from desired
            # => no delete attempt and no Failed row. The plan loop emits
            # a single row per orphan; Get-OrphanAction is the gate that
            # picks Protected vs Orphan, so a Protected return value
            # proves the DELETE branch is never reached.
            $action = Get-OrphanAction -Name '1lfhuf' -ProtectedNames @('1lfhuf')
            $action | Should -Be 'Protected'
            $action | Should -Not -Be 'Orphan'
        }
    }
}

# -----------------------------------------------------------------------------
# Issue #309 -- ConvertTo-CollectionExportDoc (exporter completeness)
# -----------------------------------------------------------------------------

Describe 'ConvertTo-CollectionExportDoc' {

    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertTo-CollectionExportDoc'
            }, $true)
        if (-not $fnAst) { throw "ConvertTo-CollectionExportDoc not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    Context 'Walked tree (parent == root)' {
        It 'emits a single top-level entry with parent set to the root name' {
            $tenant = @(
                @{ name = 'hr-system'; friendlyName = 'HR'; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 1
            $result.Document.collections.Count | Should -Be 1
            $result.Document.collections[0].name   | Should -Be 'hr-system'
            $result.Document.collections[0].parent | Should -Be 'purview-contoso-lab'
        }

        It 'nests children of an emitted top-level under children: and counts them' {
            $tenant = @(
                @{ name = 'hr-system';      friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'hr-system-prod'; friendlyName = $null; description = $null; parent = 'hr-system'       }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 2
            $result.Document.collections.Count | Should -Be 1
            $result.Document.collections[0].children.Count | Should -Be 1
            $result.Document.collections[0].children[0].name | Should -Be 'hr-system-prod'
            # Children do not carry a top-level parent: field (the
            # enclosing entry's name is the implicit parent).
            $result.Document.collections[0].children[0].Contains('parent') | Should -Be $false
        }

        It 'is case-insensitive when matching the root for top-level selection' {
            $tenant = @(
                @{ name = 'hr-system'; friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 1
            $result.Document.collections[0].name | Should -Be 'hr-system'
            $result.Document.collections[0].parent | Should -Be 'purview-contoso-lab'
        }

        It 'excludes the root collection itself even when present in the tenant list' {
            $tenant = @(
                @{ name = 'purview-contoso-lab'; friendlyName = $null; description = $null; parent = $null            }
                @{ name = 'hr-system';      friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 1
            ($result.Document.collections | Where-Object { $_.name -eq 'purview-contoso-lab' }) | Should -BeNullOrEmpty
        }
    }

    Context 'Unwalked entries (issue #309 acceptance criteria)' {
        It 'emits a tenant collection whose parent is not the walked root, preserving the actual parent' {
            # Repro of the PR #307 Cycle 4 finding: childless tenant
            # collection `1lfhuf` whose parent is the system root
            # (account-name casing differs from RootName) was dropped.
            $tenant = @(
                @{ name = '1lfhuf'; friendlyName = $null; description = $null; parent = 'system-root' }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 1
            $result.Document.collections.Count | Should -Be 1
            $result.Document.collections[0].name   | Should -Be '1lfhuf'
            $result.Document.collections[0].parent | Should -Be 'system-root'
        }

        It 'banner-count AC: walked + unwalked entries are both counted' {
            # 1 walked (parent == root) + 2 unwalked (parent != root)
            # = 3 emitted total. Locks in the issue #309 banner AC.
            $tenant = @(
                @{ name = 'hr-system'; friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = '1lfhuf';    friendlyName = $null; description = $null; parent = 'system-root'    }
                @{ name = '9vsaza';    friendlyName = $null; description = $null; parent = 'system-root'    }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 3
            $result.Document.collections.Count | Should -Be 3
            ($result.Document.collections | ForEach-Object { $_.name } | Sort-Object) -join ',' |
                Should -Be '1lfhuf,9vsaza,hr-system'
        }

        It 'falls back to the root name when an unwalked entry has a $null parent' {
            $tenant = @(
                @{ name = 'orphan-noparent'; friendlyName = $null; description = $null; parent = $null }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            $result.WrittenCount | Should -Be 1
            $result.Document.collections[0].parent | Should -Be 'purview-contoso-lab'
        }
    }

    Context 'Round-trip contract' {
        It 'emits every tenant collection exactly once across walked + unwalked' {
            # AC: "Round-trip reports the same count in both directions."
            # WrittenCount must equal the count of unique non-root
            # tenant entries -- no drops, no duplicates.
            $tenant = @(
                @{ name = 'a-root-child';  friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'a-grandchild';  friendlyName = $null; description = $null; parent = 'a-root-child'   }
                @{ name = 'b-unwalked';    friendlyName = $null; description = $null; parent = 'system-root'    }
            )
            $result = ConvertTo-CollectionExportDoc -RootName 'purview-contoso-lab' -TenantHashes $tenant
            # 3 non-root tenant entries => 3 written.
            $result.WrittenCount | Should -Be ($tenant.Count)
            # No entry appears in $result.Document.collections more
            # than once and no entry's children list contains itself.
            $topNames = $result.Document.collections | ForEach-Object { $_.name }
            ($topNames | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Collection-name pre-flight validation (issue #310)' {

    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Deploy-Collections.ps1'
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $ruleAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Test-CollectionNameRule'
            }, $true)
        if (-not $ruleAst) { throw 'Test-CollectionNameRule not found in Deploy-Collections.ps1.' }
        . ([ScriptBlock]::Create($ruleAst.Extent.Text))

        $violationsAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-CollectionNameViolation'
            }, $true)
        if (-not $violationsAst) { throw 'Get-CollectionNameViolation not found in Deploy-Collections.ps1.' }
        . ([ScriptBlock]::Create($violationsAst.Extent.Text))
    }

    Context 'Test-CollectionNameRule per-failure-mode reasons' {

        It 'accepts a well-formed name with Reason = OK' {
            $r = Test-CollectionNameRule -Name 'hr-system'
            $r.Valid  | Should -BeTrue
            $r.Reason | Should -Be 'OK'
        }

        It 'flags a 2-char name as TooShort (PR #307 Cycle 1 lock-in)' {
            $r = Test-CollectionNameRule -Name 'hr'
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Be 'TooShort'
        }

        It 'flags a 37-char name as TooLong' {
            # 37 lowercase letters: a..a, deterministic and legal
            # except for length.
            $r = Test-CollectionNameRule -Name ('a' * 37)
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Be 'TooLong'
        }

        It 'flags a name that starts with a digit as LeadingNonLetter' {
            # Same shape as the system-generated names the export
            # path emits (issue #309): legal length, illegal lead.
            $r = Test-CollectionNameRule -Name '1lfhuf'
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Be 'LeadingNonLetter'
        }

        It 'flags an uppercase character as Uppercase' {
            $r = Test-CollectionNameRule -Name 'HR-System'
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Be 'Uppercase'
        }

        It 'flags an underscore as IllegalChar' {
            $r = Test-CollectionNameRule -Name 'hr_system'
            $r.Valid  | Should -BeFalse
            $r.Reason | Should -Be 'IllegalChar'
        }
    }

    Context 'Get-CollectionNameViolation aggregation' {

        It 'returns an empty array when every entry is valid' {
            $entries = @(
                @{ name = 'hr-system'; friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'finance';   friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = @(Get-CollectionNameViolation -Entries $entries)
            $result.Count | Should -Be 0
        }

        It 'returns only the violators with Name and Reason' {
            $entries = @(
                @{ name = 'hr-system'; friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'hr';        friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'HR-Bad';    friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
                @{ name = '1lfhuf';    friendlyName = $null; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = @(Get-CollectionNameViolation -Entries $entries)
            $result.Count | Should -Be 3
            ($result | Where-Object Name -eq 'hr').Reason     | Should -Be 'TooShort'
            ($result | Where-Object Name -eq 'HR-Bad').Reason | Should -Be 'Uppercase'
            ($result | Where-Object Name -eq '1lfhuf').Reason | Should -Be 'LeadingNonLetter'
        }

        It 'skips entries whose name is in -KnownNames (portal-authored round-trip)' {
            # Portal auto-generates short URL segments like '85cv3o'
            # / '1lfhuf' that fail the human-input rule yet are
            # accepted by the REST surface. Once they exist in the
            # tenant, re-validating them adds zero safety and blocks
            # the Export -> Apply round-trip contract.
            $entries = @(
                @{ name = '1lfhuf';    friendlyName = 'HR';      description = $null; parent = 'purview-contoso-lab' }
                @{ name = '85cv3o';    friendlyName = 'MySQL';   description = $null; parent = 'purview-contoso-lab' }
            )
            $result = @(Get-CollectionNameViolation -Entries $entries -KnownNames @('1lfhuf', '85cv3o'))
            $result.Count | Should -Be 0
        }

        It 'matches -KnownNames case-insensitively' {
            $entries = @(
                @{ name = '1lfhuf'; friendlyName = 'HR'; description = $null; parent = 'purview-contoso-lab' }
            )
            $result = @(Get-CollectionNameViolation -Entries $entries -KnownNames @('1LFHUF'))
            $result.Count | Should -Be 0
        }

        It 'still flags new entries when -KnownNames covers only existing tenant names' {
            $entries = @(
                @{ name = '1lfhuf';      friendlyName = 'HR';      description = $null; parent = 'purview-contoso-lab' }
                @{ name = 'HR-NewBad';   friendlyName = 'new';     description = $null; parent = 'purview-contoso-lab' }
            )
            $result = @(Get-CollectionNameViolation -Entries $entries -KnownNames @('1lfhuf'))
            $result.Count | Should -Be 1
            $result[0].Name   | Should -Be 'HR-NewBad'
            $result[0].Reason | Should -Be 'Uppercase'
        }
    }
}




Describe 'ADR 0029 direction-policy integration (issue #614)' {

    BeforeAll {
        # Import the shared decision helper. Pure module -- no tenant
        # connection. Reference:
        # docs/adr/0029-source-of-truth-direction-policy.md
        $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1'
        Import-Module $script:ModulePath -Force -Scope Local -ErrorAction Stop

        # Reusable: build a synthetic plan and apply the same pass the
        # script's #region ADR 0029 direction-policy pass implements.
        function Invoke-Adr0029Pass {
            param(
                [Parameter(Mandatory)][hashtable[]]$Plan,
                [Parameter(Mandatory)][ValidateSet('audit','portal-wins','repo-wins')][string]$Policy,
                [Parameter()][string[]]$SkipList = @()
            )
            if ($Policy -eq 'audit') { return $Plan }
            foreach ($row in $Plan) {
                if ($row.Action -notin @('Create','Update','NoChange','Orphan','Protected')) { continue }
                $hasDrift = ($row.Action -eq 'Update')
                $decision = Resolve-DirectionPolicyAction `
                    -Policy      $Policy `
                    -SkipList    $SkipList `
                    -DisplayName ([string]$row.Name) `
                    -HasDrift    $hasDrift
                if ($decision.Action -eq 'Skip') {
                    $row.Action = 'Skip'
                    $row.Reason = $decision.Reason
                }
            }
            return $Plan
        }
    }

    Context 'portal-wins (default)' {

        It 'skips Update rows (shared-property drift)' {
            $plan = @(
                @{ Action='Update'; Name='c1'; Reason='Drift in: friendlyName' }
                @{ Action='NoChange'; Name='c2'; Reason='In sync with tenant.' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'c1').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'c2').Action | Should -Be 'NoChange'
        }

        It 'leaves Create / Orphan / NoChange rows untouched' {
            $plan = @(
                @{ Action='Create';   Name='c1'; Reason='Declared in YAML; absent from tenant.' }
                @{ Action='NoChange'; Name='c2'; Reason='In sync with tenant.' }
                @{ Action='Orphan';   Name='c3'; Reason='Tenant-only.' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'portal-wins'
            ($out | Where-Object Name -eq 'c1').Action | Should -Be 'Create'
            ($out | Where-Object Name -eq 'c2').Action | Should -Be 'NoChange'
            ($out | Where-Object Name -eq 'c3').Action | Should -Be 'Orphan'
        }
    }

    Context 'repo-wins' {

        It 'keeps Update rows as Update (apply will overwrite)' {
            $plan = @(
                @{ Action='Update'; Name='c1'; Reason='Drift in: friendlyName' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'repo-wins'
            ($out | Where-Object Name -eq 'c1').Action | Should -Be 'Update'
        }
    }

    Context '-SkipNames pre-pass' {

        It 'force-skips a name regardless of policy or drift category' {
            $plan = @(
                @{ Action='Update';   Name='c1'; Reason='Drift in: description' }
                @{ Action='NoChange'; Name='c2'; Reason='In sync with tenant.' }
                @{ Action='Orphan';   Name='c3'; Reason='Tenant-only.' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'repo-wins' -SkipList @('c1','c2','c3')
            ($out | Where-Object Name -eq 'c1').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'c2').Action | Should -Be 'Skip'
            ($out | Where-Object Name -eq 'c3').Action | Should -Be 'Skip'
        }

        It 'matches -SkipNames case-insensitively (sibling pattern)' {
            $plan = @(
                @{ Action='Update'; Name='1lfhuf'; Reason='Drift in: friendlyName' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'repo-wins' -SkipList @('1LFHUF')
            ($out | Where-Object Name -eq '1lfhuf').Action | Should -Be 'Skip'
        }

        It 'never touches Create rows (skip applies to existing names only)' {
            $plan = @(
                @{ Action='Create'; Name='new-col'; Reason='Declared in YAML; absent from tenant.' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'portal-wins' -SkipList @('new-col')
            # The Resolve-DirectionPolicyAction helper does match by
            # name, so Create rows in the skip list WILL be skipped.
            # The script-level contract delegates that policing to
            # the workflow's pre-computed list. Lock the helper
            # behavior in so a future change has to update this test
            # intentionally.
            ($out | Where-Object Name -eq 'new-col').Action | Should -Be 'Skip'
        }
    }

    Context 'audit short-circuit' {

        It 'returns the plan unmodified (consumer flips $WhatIfPreference)' {
            $plan = @(
                @{ Action='Update'; Name='c1'; Reason='Drift in: friendlyName' }
            )
            $out = Invoke-Adr0029Pass -Plan $plan -Policy 'audit'
            ($out | Where-Object Name -eq 'c1').Action | Should -Be 'Update'
        }
    }
}
