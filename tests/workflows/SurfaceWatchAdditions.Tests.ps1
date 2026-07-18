#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    THE ADDITIONS PATH IS PROVEN, NOT ASSUMED, SO A TEST REPLAYS IT.

    surface-watch.yml's "Parse §3 inventory and fetch Learn pages" step
    declares `$additionsReport = @()` and, further down, renders it under
    "### New features on Learn (not in §3)" -- but until #114's fix nothing
    ever appended to it, so that half of the loop's own header claim
    ("new features documented on Learn but missing from §3") was dead code
    (issue #114, split from #112).

    The fix resolves each of a small curated list of feature names (the
    workloads named in .squad/memory/context.md's "Microsoft solution
    scope", plus Unified Catalog) to its current Learn entry-point URL via
    the live Learn TOC (https://learn.microsoft.com/en-us/purview/toc.json,
    confirmed 2026-07-17: HTTP 200, application/json, items[].children[]
    tree keyed by toc_title/href), then diffs each resolved URL against the
    §3 inventory already parsed from docs/project-plan.md.

    This suite reads the SHIPPED workflow file, extracts the real `run:`
    text of that step (same "test the committed artefact" reasoning as
    EnvironmentRouting.Tests.ps1 / KeyVaultOpenVerify.Tests.ps1), and
    REPLAYS it in a real pwsh subprocess against:
      - a synthetic docs/project-plan.md with exactly one §3 row (feature
        "Audit", already pointing at the TOC's resolved Audit URL); and
      - a synthetic Learn TOC fixture (Invoke-WebRequest stubbed, no live
        network) carrying all nine curated feature names, each with its own
        distinct entry-point href.

    Only "Audit" is in §3, so the other eight curated features must land in
    $additionsReport and render under the "### New features on Learn (not in
    §3)" heading -- the synthetic case #114's acceptance criteria calls for.
    "Audit" itself must NOT be reported (it is already tracked), proving the
    diff -- not just the presence of nine hardcoded names -- is what drives
    the result.

    References:
      https://learn.microsoft.com/en-us/purview/toc.json
      https://pester.dev/docs/quick-start
#>

BeforeAll {
    $script:RepoRoot     = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WorkflowsDir = Join-Path $script:RepoRoot '.github/workflows'
    Import-Module 'powershell-yaml' -ErrorAction Stop

    # Pull the exact `run:` script of the discovery step out of the SHIPPED
    # workflow (searched by step name, so surrounding step order can change
    # without touching this test).
    function Get-DiscoveryRun {
        param([string]$Name = 'surface-watch.yml')
        $path = Join-Path $script:WorkflowsDir $Name
        if (-not (Test-Path -LiteralPath $path)) { throw "Workflow not found: $Name" }
        $wf = (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Yaml
        foreach ($jobKey in $wf['jobs'].Keys) {
            foreach ($step in $wf['jobs'][$jobKey]['steps']) {
                if ($step['name'] -eq 'Parse §3 inventory and fetch Learn pages') {
                    return [string]$step['run']
                }
            }
        }
        throw "Step 'Parse §3 inventory and fetch Learn pages' not found in $Name"
    }

    $script:RunScript = Get-DiscoveryRun

    # Synthetic Learn TOC: all nine curated feature names, each resolving
    # (via a "Learn about <name>" child) to its own distinct entry-point
    # href. "Audit" deliberately matches the URL already present in the
    # synthetic §3 fixture below; the other eight do not exist in §3.
    $script:TocFixtureJson = @'
{
  "items": [
    { "toc_title": "Information protection", "children": [ { "href": "fixture-information-protection", "toc_title": "Learn about information protection" } ] },
    { "toc_title": "Data loss prevention", "children": [ { "href": "fixture-dlp", "toc_title": "Learn about DLP" } ] },
    { "toc_title": "Insider risk management", "children": [ { "href": "fixture-irm", "toc_title": "Learn about insider risk management" } ] },
    { "toc_title": "Communication compliance", "children": [ { "href": "fixture-comm-compliance", "toc_title": "Learn about communication compliance" } ] },
    { "toc_title": "Audit", "children": [ { "href": "audit-solutions-overview", "toc_title": "Learn about auditing solutions" } ] },
    { "toc_title": "Data lifecycle & records management", "children": [ { "href": "fixture-dlm-rm", "toc_title": "Learn about data lifecycle management" } ] },
    { "toc_title": "Data Map", "children": [ { "href": "fixture-data-map", "toc_title": "Learn about Data Map" } ] },
    { "toc_title": "Data Security Posture Management", "children": [ { "href": "fixture-dspm", "toc_title": "Learn about DSPM" } ] },
    { "toc_title": "Unified Catalog", "children": [ { "href": "fixture-unified-catalog", "toc_title": "Learn about Unified Catalog" } ] }
  ]
}
'@

    # Runs the extracted run: script in a real pwsh subprocess, CWD'd at a
    # synthetic repo root, with Invoke-WebRequest stubbed (no live network)
    # and $env:GITHUB_OUTPUT redirected to a temp file. Returns the parsed
    # GITHUB_OUTPUT lines plus surface-report.txt content (if written).
    function Invoke-DiscoveryRun {
        param(
            [Parameter(Mandatory)][string]$RunScript,
            [Parameter(Mandatory)][string]$ProjectPlanMarkdown,
            [Parameter(Mandatory)][string]$TocJson
        )

        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("surfacewatch-" + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'docs') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tmpRoot 'docs/project-plan.md') -Value $ProjectPlanMarkdown -NoNewline

        $outputFile = Join-Path $tmpRoot 'gh_output.txt'
        New-Item -ItemType File -Path $outputFile -Force | Out-Null

        # Stub definition + fixture + the real extracted script, written to
        # one standalone harness file so the stub takes precedence over the
        # real Invoke-WebRequest cmdlet for the whole run (function
        # resolution beats cmdlet resolution in the same session).
        $harness = @"
function Invoke-WebRequest {
    param([string]`$Uri, [string]`$Method = 'Get', [int]`$TimeoutSec, [string]`$ErrorAction)
    switch (`$Uri) {
        'https://learn.microsoft.com/en-us/purview/toc.json' {
            return [pscustomobject]@{ StatusCode = 200; Content = @'
$TocJson
'@ }
        }
        'https://learn.microsoft.com/en-us/purview/audit-solutions-overview' {
            if (`$Method -eq 'Head') { return [pscustomobject]@{ StatusCode = 200 } }
            return [pscustomobject]@{ StatusCode = 200; Content = '<title>Learn about auditing solutions | Microsoft Learn</title>' }
        }
        default { throw "Unexpected URI in test stub: `$Uri" }
    }
}

$RunScript
"@
        $harnessPath = Join-Path $tmpRoot 'harness.ps1'
        [System.IO.File]::WriteAllText($harnessPath, $harness, (New-Object System.Text.UTF8Encoding $false))

        Push-Location $tmpRoot
        try {
            $env:GITHUB_OUTPUT = $outputFile
            & pwsh -NoProfile -File $harnessPath 2>&1 | Out-Null
            $exitCode = $LASTEXITCODE
            $outputLines = @(Get-Content -LiteralPath $outputFile -ErrorAction SilentlyContinue)
            $reportPath = Join-Path $tmpRoot 'surface-report.txt'
            $report = if (Test-Path -LiteralPath $reportPath) { Get-Content -LiteralPath $reportPath -Raw } else { $null }
        }
        finally {
            Pop-Location
            Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            ExitCode    = $exitCode
            OutputLines = $outputLines
            Report      = $report
        }
    }

    # §3 carries exactly one row: Audit, already pointing at the TOC
    # fixture's resolved Audit URL.
    $script:ProjectPlanFixture = @'
## 3. Feature inventory

| Feature | Microsoft Learn entry point | Desired-state YAML | Reconciler | v1 origin |
|---|---|---|---|---|
| Audit | [Learn about auditing solutions](https://learn.microsoft.com/en-us/purview/audit-solutions-overview) | data-plane/audit/ | scripts/Deploy-Audit.ps1 | v1 |

## 4. Per-feature lifecycle
'@
}

Describe 'Surface-watch additions detection populates $additionsReport with a real discovery mechanism (#114)' {

    BeforeAll {
        $script:result = Invoke-DiscoveryRun -RunScript $script:RunScript -ProjectPlanMarkdown $script:ProjectPlanFixture -TocJson $script:TocFixtureJson
    }

    It 'runs the extracted step to completion (exit 0)' {
        $script:result.ExitCode | Should -Be 0 -Because "the harness output was: $($script:result.OutputLines -join '; ')"
    }

    It 'reports drift=true because at least one curated feature is missing from §3' {
        $script:result.OutputLines | Should -Contain 'drift=true'
    }

    It 'writes surface-report.txt with the "### New features on Learn (not in §3)" section' {
        $script:result.Report | Should -Not -BeNullOrEmpty
        $script:result.Report | Should -Match '### New features on Learn \(not in §3\)'
    }

    It 'lists each of the eight curated features absent from §3 as a bullet' -ForEach @(
        @{ Feature = 'Information protection' }
        @{ Feature = 'Data loss prevention' }
        @{ Feature = 'Insider risk management' }
        @{ Feature = 'Communication compliance' }
        @{ Feature = 'Data lifecycle & records management' }
        @{ Feature = 'Data Map' }
        @{ Feature = 'Data Security Posture Management' }
        @{ Feature = 'Unified Catalog' }
    ) {
        $script:result.Report | Should -Match ([regex]::Escape("**$Feature**")) -Because "$Feature is in the curated list, resolves via the TOC fixture, and is NOT in the synthetic §3 table -- it must be reported as a new feature"
    }

    It 'does NOT list Audit as a new feature (it is already tracked in §3)' {
        $script:result.Report | Should -Not -Match ([regex]::Escape('**Audit**: Documented on Learn'))
    }

    It 'keeps the removals/changes section behavior unaffected (no §3 removal/title-change entries in this fixture)' {
        $script:result.Report | Should -Not -Match '### Features in §3 but not accessible on Learn'
        $script:result.Report | Should -Not -Match '### Features with changed titles'
    }
}

Describe 'Surface-watch additions detection degrades gracefully when the Learn TOC is unreachable' {

    It 'does not fail the run when the TOC fetch throws, and reports no additions' {
        $failingHarnessScript = $script:RunScript -replace [regex]::Escape("`$tocUrl = 'https://learn.microsoft.com/en-us/purview/toc.json'"), "`$tocUrl = 'https://learn.microsoft.com/en-us/purview/toc-does-not-exist.json'"
        $result = Invoke-DiscoveryRun -RunScript $failingHarnessScript -ProjectPlanMarkdown $script:ProjectPlanFixture -TocJson $script:TocFixtureJson
        $result.ExitCode | Should -Be 0 -Because "a TOC fetch failure must not crash the read-only loop. Output: $($result.OutputLines -join '; ')"
        $result.OutputLines | Should -Contain 'drift=false' -Because 'the fixture §3 row (Audit) matches live and no additions could be resolved'
    }
}
