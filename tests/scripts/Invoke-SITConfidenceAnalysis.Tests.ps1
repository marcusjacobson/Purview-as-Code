#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Invoke-SITConfidenceAnalysis.ps1
    (Wave 3 / issue #76).

.DESCRIPTION
    AST-extracts the analyzer's helper functions and locks in their
    deterministic, parse-only contracts:

      * Resolve-RunDirectory     -- explicit / newest / error paths.
      * Get-PairFileRecordCount  -- missing / empty / wrapper / array.
      * Get-SitIndex             -- malformed input safely empty.
      * Get-Recommendation       -- pure recommendation matrix.
      * ConvertTo-ReportRow      -- aggregation + cross-reference.
      * Format-ReportMarkdown    -- table + summary header.

    We do NOT dot-source the script: its top-level code requires the
    powershell-yaml module and a real export run on disk.

    References (Microsoft Learn):
      Pester quick start:
        https://pester.dev/docs/quick-start
      about_Functions_CmdletBindingAttribute:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_cmdletbindingattribute
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-SITConfidenceAnalysis.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Invoke-SITConfidenceAnalysis.ps1 at: $script:ScriptPath"
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw ("Parse errors in {0}: {1}" -f $script:ScriptPath, ($errors -join '; '))
    }

    $names = @(
        'Resolve-RunDirectory',
        'Get-PairFileRecordCount',
        'Get-SitIndex',
        'Get-Recommendation',
        'ConvertTo-ReportRow',
        'Format-ReportMarkdown'
    )
    foreach ($fname in $names) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    $script:FixtureRoot = Join-Path $PSScriptRoot '..' 'fixtures' 'sit-confidence'
}

Describe 'Resolve-RunDirectory' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sit-rrd-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item -Recurse -Force $script:TempRoot }
    }

    It 'returns the explicit RunDirectory when it has manifest.json' {
        $run = Join-Path $script:TempRoot 'run-a'
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        '{}' | Set-Content (Join-Path $run 'manifest.json')
        (Resolve-RunDirectory -RunDirectoryPath $run -ExportRootPath $null) |
            Should -Be (Resolve-Path $run).Path
    }

    It 'throws when explicit RunDirectory is missing manifest.json' {
        $run = Join-Path $script:TempRoot 'run-b'
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        { Resolve-RunDirectory -RunDirectoryPath $run -ExportRootPath $null } |
            Should -Throw -ExpectedMessage '*manifest.json*'
    }

    It 'throws when explicit RunDirectory does not exist' {
        $missing = Join-Path $script:TempRoot 'nope'
        { Resolve-RunDirectory -RunDirectoryPath $missing -ExportRootPath $null } |
            Should -Throw -ExpectedMessage '*not found*'
    }

    It 'picks the newest manifest-bearing subdirectory under ExportRoot' {
        foreach ($n in @('2026-01-01-0000', '2026-05-01-1200', '2026-03-15-0900')) {
            $d = Join-Path $script:TempRoot $n
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            '{}' | Set-Content (Join-Path $d 'manifest.json')
        }
        # Decoy without manifest -- must be skipped.
        New-Item -ItemType Directory -Path (Join-Path $script:TempRoot '2026-12-31-2359') -Force | Out-Null

        $picked = Resolve-RunDirectory -RunDirectoryPath '' -ExportRootPath $script:TempRoot
        (Split-Path -Leaf $picked) | Should -Be '2026-05-01-1200'
    }

    It 'throws when no candidate run exists under ExportRoot' {
        { Resolve-RunDirectory -RunDirectoryPath '' -ExportRootPath $script:TempRoot } |
            Should -Throw -ExpectedMessage '*No run subdirectory*'
    }
}

Describe 'Get-PairFileRecordCount' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("sit-gprc-{0}" -f ([guid]::NewGuid()))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:TempRoot) { Remove-Item -Recurse -Force $script:TempRoot }
    }

    It 'returns 0 when the file does not exist' {
        Get-PairFileRecordCount -Path (Join-Path $script:TempRoot 'nope.json') | Should -Be 0
    }

    It 'returns 0 for an empty file' {
        $f = Join-Path $script:TempRoot 'empty.json'
        '' | Set-Content $f
        Get-PairFileRecordCount -Path $f | Should -Be 0
    }

    It 'returns 0 for invalid JSON without throwing' {
        $f = Join-Path $script:TempRoot 'bad.json'
        'not json' | Set-Content $f
        Get-PairFileRecordCount -Path $f | Should -Be 0
    }

    It 'counts records across an array of array-pages' {
        $f = Join-Path $script:TempRoot 'pages.json'
        @(
            @(@{ a = 1 }, @{ a = 2 }, @{ a = 3 }),
            @(@{ a = 4 }, @{ a = 5 })
        ) | ConvertTo-Json -Depth 6 | Set-Content $f
        Get-PairFileRecordCount -Path $f | Should -Be 5
    }

    It 'counts a single-object page as one record' {
        $f = Join-Path $script:TempRoot 'one.json'
        @{ a = 1 } | ConvertTo-Json | Set-Content $f
        Get-PairFileRecordCount -Path $f | Should -Be 1
    }
}

Describe 'Get-SitIndex' {
    It 'returns empty hashtable for $null' {
        (Get-SitIndex -YamlDoc $null).Count | Should -Be 0
    }

    It 'returns empty hashtable when sits key is missing' {
        (Get-SitIndex -YamlDoc @{ other = 'x' }).Count | Should -Be 0
    }

    It 'indexes by name and exposes id/type/publisher' {
        $doc = @{
            sits = @(
                @{ name = 'Test Custom Credit Card'; id = '00000000-0000-0000-0000-000000000000'; type = 'Custom'; publisher = 'contoso' },
                @{ name = 'ABA Routing Number'; id = '11111111-1111-1111-1111-111111111111'; type = 'Entity'; publisher = 'Microsoft' },
                @{ name = ''; id = 'skip-me'; type = 'Custom' }
            )
        }
        $idx = Get-SitIndex -YamlDoc $doc
        $idx.Count | Should -Be 2
        $idx['Test Custom Credit Card'].Type | Should -Be 'Custom'
        $idx['ABA Routing Number'].Publisher | Should -Be 'Microsoft'
    }
}

Describe 'Get-Recommendation' {
    It 'returns Reference for any non-custom SIT' {
        $r = Get-Recommendation -IsCustom $false -Hits 999 -WorkloadsWithHits 5 -MinHits 5
        $r.Recommendation | Should -Be 'Reference'
    }

    It 'returns Retire for custom SIT with zero hits' {
        $r = Get-Recommendation -IsCustom $true -Hits 0 -WorkloadsWithHits 0 -MinHits 5
        $r.Signal         | Should -Be 'None'
        $r.Recommendation | Should -Be 'Retire'
    }

    It 'returns Review for custom SIT below MinHits' {
        $r = Get-Recommendation -IsCustom $true -Hits 3 -WorkloadsWithHits 1 -MinHits 5
        $r.Signal         | Should -Be 'Isolated'
        $r.Recommendation | Should -Be 'Review'
    }

    It 'returns Review for custom SIT with Isolated signal even above MinHits' {
        $r = Get-Recommendation -IsCustom $true -Hits 100 -WorkloadsWithHits 1 -MinHits 5
        $r.Signal         | Should -Be 'Isolated'
        $r.Recommendation | Should -Be 'Review'
    }

    It 'returns Retain for custom SIT broadly seen above MinHits' {
        $r = Get-Recommendation -IsCustom $true -Hits 50 -WorkloadsWithHits 3 -MinHits 5
        $r.Signal         | Should -Be 'Broad'
        $r.Recommendation | Should -Be 'Retain'
    }
}

Describe 'ConvertTo-ReportRow' {
    It 'aggregates per-workload manifest rows into one row per SIT' {
        $rows = @(
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Test Custom Credit Card'; Workload = 'Exchange';   Status = 'OK'; File = 'a.json' },
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Test Custom Credit Card'; Workload = 'SharePoint'; Status = 'OK'; File = 'b.json' },
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Test Custom Employee ID'; Workload = 'Exchange';   Status = 'OK'; File = 'c.json' },
            # Non-SIT rows are ignored.
            [pscustomobject]@{ Kind = 'Label'; Name = 'Confidential'; Workload = 'Exchange'; Status = 'OK'; File = 'd.json' }
        )
        $counts = @{ 'a.json' = 10; 'b.json' = 5; 'c.json' = 0; 'd.json' = 99 }
        $index = @{
            'Test Custom Credit Card' = @{ Id = '00000000-0000-0000-0000-000000000000'; Type = 'Custom';  Publisher = 'contoso' }
            'Test Custom Employee ID' = @{ Id = '11111111-1111-1111-1111-111111111111'; Type = 'Custom';  Publisher = 'contoso' }
        }

        $out = @(ConvertTo-ReportRow -ManifestRows $rows -PairCounts $counts -SitIndex $index -MinHits 5)
        $out.Count | Should -Be 2

        $cc = $out | Where-Object Name -EQ 'Test Custom Credit Card'
        $cc.Hits              | Should -Be 15
        $cc.WorkloadsWithHits | Should -Be 2
        $cc.WorkloadsScanned  | Should -Be 2
        $cc.Signal            | Should -Be 'Broad'
        $cc.Recommendation    | Should -Be 'Retain'

        $eid = $out | Where-Object Name -EQ 'Test Custom Employee ID'
        $eid.Hits              | Should -Be 0
        $eid.WorkloadsWithHits | Should -Be 0
        $eid.Recommendation    | Should -Be 'Retire'
    }

    It 'classifies unknown (non-catalogued) SITs as Reference' {
        $rows = @(
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Mystery SIT'; Workload = 'Exchange'; Status = 'OK'; File = 'm.json' }
        )
        $out = @(ConvertTo-ReportRow -ManifestRows $rows -PairCounts @{ 'm.json' = 7 } -SitIndex @{} -MinHits 5)
        $out.Count | Should -Be 1
        $out[0].Type           | Should -Be 'Unknown'
        $out[0].IsCustom       | Should -Be $false
        $out[0].Recommendation | Should -Be 'Reference'
    }

    It 'skips manifest rows with Status != OK from the hit count' {
        $rows = @(
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Test Custom Employee ID'; Workload = 'Exchange';   Status = 'OK';   File = 'ok.json' },
            [pscustomobject]@{ Kind = 'SIT'; Name = 'Test Custom Employee ID'; Workload = 'SharePoint'; Status = 'Fail'; File = 'x.json' }
        )
        $out = @(ConvertTo-ReportRow -ManifestRows $rows -PairCounts @{ 'ok.json' = 3; 'x.json' = 999 } -SitIndex @{
            'Test Custom Employee ID' = @{ Id = ''; Type = 'Custom'; Publisher = 'contoso' }
        } -MinHits 5)
        $out[0].Hits             | Should -Be 3
        $out[0].WorkloadsScanned | Should -Be 2
    }
}

Describe 'Format-ReportMarkdown' {
    It 'renders header, totals, and a row per SIT' {
        $rows = @(
            [pscustomobject]@{ Name = 'A'; Id = 'id-a'; Type = 'Custom'; IsCustom = $true;  Hits = 10; WorkloadsWithHits = 2; WorkloadsScanned = 2; Workloads = 'Exchange,SharePoint'; Signal = 'Broad';    Recommendation = 'Retain' }
            [pscustomobject]@{ Name = 'B'; Id = 'id-b'; Type = 'Custom'; IsCustom = $true;  Hits = 0;  WorkloadsWithHits = 0; WorkloadsScanned = 1; Workloads = 'Exchange';            Signal = 'None';     Recommendation = 'Retire' }
            [pscustomobject]@{ Name = 'C'; Id = 'id-c'; Type = 'Entity'; IsCustom = $false; Hits = 99; WorkloadsWithHits = 3; WorkloadsScanned = 3; Workloads = 'a,b,c';                 Signal = 'Broad';    Recommendation = 'Reference' }
        )
        $md = Format-ReportMarkdown -Rows $rows -RunDirectory 'C:\runs\2026-05-17' -MinHits 5 -GeneratedAt ([datetime]'2026-05-17T12:00:00Z')

        $md | Should -Match '# SIT confidence analysis'
        $md | Should -Match 'MinHits threshold: 5'
        $md | Should -Match 'Retain 1, Review 0, Retire 1, Reference 1'
        $md | Should -Match '\| A \|'
        $md | Should -Match '\| B \|'
        $md | Should -Match '\| C \|'
    }
}
