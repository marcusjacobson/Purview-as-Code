#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester unit tests for scripts/Export-ContentExplorerData.ps1
    (Wave 3a Phase 2 / Issue #74).

.DESCRIPTION
    Locks in the deterministic, parse-only contract of the exporter:

      1. `Resolve-LabelScope` returns the union of `displayName`/`name`
         fields from each source YAML under the `labels` /
         `sensitivityLabels` keys, sorted-unique.
      2. `Resolve-SitScope` returns the same for `classifications` /
         `sensitiveInformationTypes` / `sits`.
      3. `Get-RowField` and `Test-DocHasKey` work for both hashtable
         and PSCustomObject rows (powershell-yaml returns hashtables;
         tests pin both shapes).
      4. The exporter manifest object emits the JSON shape ADR 0021
         Decision 5 commits to: top-level keys `timestamp`,
         `tenantDomain`, `desiredStatePath`, `parametersFile`,
         `workloads`, `pageSize`, `throttleSeconds`, `maxRetries`,
         `rowCount`, `failureCount`, `rows`; per-row OK keys include
         `Kind`, `Name`, `Workload`, `Status`, `Retries`, `Pages`,
         `File`, `Started`, `DurationSeconds`; per-row Fail keys
         include `Kind`, `Name`, `Workload`, `Status`, `Retries`,
         `Error`, `Started`, `DurationSeconds`.

    Pattern: AST-extract function definitions from the script and
    evaluate them into the test scope. We deliberately do NOT
    dot-source the script -- that would execute its top-level code
    and attempt to load ExchangeOnlineManagement / acquire a token.

    Reference: docs/adr/0021-dspm-content-explorer-cadence.md
    Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata
    Reference: https://pester.dev/docs/quick-start
#>

# Resilient on-demand acquisition of the powershell-yaml module.
#
# The repo Pester runner (tests/Run-Pester.ps1) does not pre-install third-party
# modules, so Resolve-LabelScope / Resolve-SitScope, which call ConvertFrom-Yaml,
# need powershell-yaml installed on demand. PSGallery occasionally fails transiently
# (TLS reset, gallery throttling). A single hard failure here used to cascade into
# 15 unrelated test failures (issue #333, triggering run 26368977491).
#
# Contract:
#   - Returns @{ Available = [bool]; Reason = [string] }.
#   - If a satisfying version is already installed, returns Available=$true without
#     touching the network.
#   - Otherwise retries Install-Module with bounded exponential backoff.
#   - On unrecoverable failure, returns Available=$false with a human-readable reason
#     so callers can Set-ItResult -Skipped instead of throwing.
#
# Reference: https://learn.microsoft.com/en-us/powershell/module/powershellget/install-module
# Reference: https://pester.dev/docs/usage/skip
function Initialize-PowerShellYaml {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$MaxAttempts = 3,
        [string]$MinimumVersion = '0.4.7'
    )

    $existing = $null
    try {
        $existing = Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction Stop |
            Where-Object { $_.Version -ge [version]$MinimumVersion } |
            Select-Object -First 1
    } catch {
        # Get-Module itself can fail (corrupt PSModulePath); fall through to install.
        $existing = $null
    }
    if ($existing) {
        return @{ Available = $true; Reason = $null }
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Install-Module -Name 'powershell-yaml' `
                -MinimumVersion $MinimumVersion `
                -Scope CurrentUser `
                -Force `
                -AllowClobber `
                -SkipPublisherCheck `
                -ErrorAction Stop
            return @{ Available = $true; Reason = $null }
        } catch {
            $lastError = $_
            if ($attempt -lt $MaxAttempts) {
                # Bounded exponential backoff: 2s, 4s. Mocked to no-op in unit tests.
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
            }
        }
    }

    $msg = if ($lastError) { $lastError.Exception.Message } else { 'unknown error' }
    return @{
        Available = $false
        Reason    = "powershell-yaml acquisition failed after $MaxAttempts attempts: $msg"
    }
}

BeforeDiscovery {
    # Determine module availability at discovery time so we can mark
    # yaml-dependent Describes with -Skip rather than throwing in BeforeAll
    # and cascading into N unrelated failures.
    # Reference: https://pester.dev/docs/usage/data-driven-tests#beforediscovery
    $yamlState = Initialize-PowerShellYaml
    $script:YamlAvailable  = $yamlState.Available
    $script:YamlSkipReason = $yamlState.Reason
}

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Export-ContentExplorerData.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Could not locate Export-ContentExplorerData.ps1 at: $script:ScriptPath"
    }

    # Re-declare Initialize-PowerShellYaml in the run-time scope so the
    # 'Initialize-PowerShellYaml (issue #333 BeforeAll hardening)' Describe
    # below can invoke it. Pester 5 evaluates script-level code only at
    # discovery time; functions defined at file scope are not visible
    # inside It blocks at run time. The body must remain in sync with the
    # top-level definition.
    # Reference: https://pester.dev/docs/usage/discovery-and-run
    function Initialize-PowerShellYaml {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [int]$MaxAttempts = 3,
            [string]$MinimumVersion = '0.4.7'
        )

        $existing = $null
        try {
            $existing = Get-Module -ListAvailable -Name 'powershell-yaml' -ErrorAction Stop |
                Where-Object { $_.Version -ge [version]$MinimumVersion } |
                Select-Object -First 1
        } catch {
            $existing = $null
        }
        if ($existing) {
            return @{ Available = $true; Reason = $null }
        }

        $lastError = $null
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                Install-Module -Name 'powershell-yaml' `
                    -MinimumVersion $MinimumVersion `
                    -Scope CurrentUser `
                    -Force `
                    -AllowClobber `
                    -SkipPublisherCheck `
                    -ErrorAction Stop
                return @{ Available = $true; Reason = $null }
            } catch {
                $lastError = $_
                if ($attempt -lt $MaxAttempts) {
                    Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
                }
            }
        }

        $msg = if ($lastError) { $lastError.Exception.Message } else { 'unknown error' }
        return @{
            Available = $false
            Reason    = "powershell-yaml acquisition failed after $MaxAttempts attempts: $msg"
        }
    }

    # Only import powershell-yaml if discovery confirmed it's available.
    # Yaml-dependent Describes are -Skip'd when this is $false, so the
    # Import-Module call would never be exercised anyway.
    if ($script:YamlAvailable) {
        Import-Module 'powershell-yaml' -ErrorAction Stop
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:ScriptPath, [ref]$tokens, [ref]$errors)

    foreach ($fname in @('Get-RowField', 'Test-DocHasKey', 'Resolve-LabelScope', 'Resolve-SitScope')) {
        $fnAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $fname
            }, $true)
        if (-not $fnAst) { throw "$fname not found in $script:ScriptPath" }
        . ([ScriptBlock]::Create($fnAst.Extent.Text))
    }

    # Resolve-LabelScope / Resolve-SitScope close over $repoRoot. Point it
    # at a per-test temp dir so we can stage synthetic source YAMLs. The
    # closure read is invisible to PSScriptAnalyzer (functions are loaded
    # via [ScriptBlock]::Create above); the Write-Verbose below silences
    # the false-positive PSUseDeclaredVarsMoreThanAssignments warning.
    $script:RepoRootStub = Join-Path ([System.IO.Path]::GetTempPath()) ("cetests-{0}" -f ([guid]::NewGuid()))
    New-Item -ItemType Directory -Path $script:RepoRootStub -Force | Out-Null
    $repoRoot = $script:RepoRootStub
    Write-Verbose ("Test repo-root stub: {0}" -f $repoRoot)
}

AfterAll {
    if ($script:RepoRootStub -and (Test-Path -LiteralPath $script:RepoRootStub)) {
        Remove-Item -LiteralPath $script:RepoRootStub -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-RowField' {
    It 'returns the value of a present field on an IDictionary row' {
        $row = @{ name = 'Public'; displayName = 'Public Label' }
        Get-RowField -Row $row -Field 'name' | Should -Be 'Public'
    }

    It 'returns $null for a missing field on an IDictionary row' {
        $row = @{ name = 'Public' }
        Get-RowField -Row $row -Field 'displayName' | Should -BeNullOrEmpty
    }

    It 'returns the value of a present property on a PSCustomObject row' {
        $row = [pscustomobject]@{ name = 'Public'; displayName = 'Public Label' }
        Get-RowField -Row $row -Field 'displayName' | Should -Be 'Public Label'
    }
}

Describe 'Test-DocHasKey' {
    It 'returns true for an IDictionary containing the key' {
        Test-DocHasKey -Doc @{ labels = @() } -Key 'labels' | Should -BeTrue
    }

    It 'returns false for an IDictionary missing the key' {
        Test-DocHasKey -Doc @{ classifications = @() } -Key 'labels' | Should -BeFalse
    }

    It 'returns true for a PSCustomObject containing the key' {
        Test-DocHasKey -Doc ([pscustomobject]@{ labels = @() }) -Key 'labels' | Should -BeTrue
    }
}

Describe 'Resolve-LabelScope' -Skip:(-not $YamlAvailable) {
    It 'returns sorted-unique displayName values across multiple sources' {
        $a = Join-Path $script:RepoRootStub 'a.yaml'
        $b = Join-Path $script:RepoRootStub 'b.yaml'
        @"
labels:
  - name: l-public
    displayName: Public
  - name: l-general
    displayName: General
"@ | Set-Content -LiteralPath $a -Encoding utf8
        @"
labels:
  - name: l-confidential
    displayName: Confidential
  - name: l-public
    displayName: Public
"@ | Set-Content -LiteralPath $b -Encoding utf8

        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('a.yaml', 'b.yaml') }
        $result = Resolve-LabelScope -Selector $selector
        $result | Should -Be @('Confidential', 'General', 'Public')
    }

    It 'falls back to name when displayName is absent' {
        $a = Join-Path $script:RepoRootStub 'c.yaml'
        @"
labels:
  - name: only-name
"@ | Set-Content -LiteralPath $a -Encoding utf8
        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('c.yaml') }
        Resolve-LabelScope -Selector $selector | Should -Be @('only-name')
    }

    It 'also reads the sensitivityLabels key' {
        $a = Join-Path $script:RepoRootStub 'd.yaml'
        @"
sensitivityLabels:
  - displayName: Internal
"@ | Set-Content -LiteralPath $a -Encoding utf8
        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('d.yaml') }
        Resolve-LabelScope -Selector $selector | Should -Be @('Internal')
    }

    It 'silently skips sources that do not exist' {
        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('missing.yaml') }
        Resolve-LabelScope -Selector $selector | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-SitScope' -Skip:(-not $YamlAvailable) {
    It 'reads the classifications key by name (sorted-unique)' {
        $a = Join-Path $script:RepoRootStub 'sit-a.yaml'
        @"
classifications:
  - name: SIT-Two
  - name: SIT-One
  - name: SIT-Two
"@ | Set-Content -LiteralPath $a -Encoding utf8
        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('sit-a.yaml') }
        Resolve-SitScope -Selector $selector | Should -Be @('SIT-One', 'SIT-Two')
    }

    It 'also reads sensitiveInformationTypes and sits keys' {
        $a = Join-Path $script:RepoRootStub 'sit-b.yaml'
        @"
sensitiveInformationTypes:
  - name: SIT-Alpha
sits:
  - name: SIT-Beta
"@ | Set-Content -LiteralPath $a -Encoding utf8
        Import-Module powershell-yaml -ErrorAction Stop
        $selector = @{ sources = @('sit-b.yaml') }
        Resolve-SitScope -Selector $selector | Should -Be @('SIT-Alpha', 'SIT-Beta')
    }
}

Describe 'Manifest JSON shape (ADR 0021 Decision 5)' {
    It 'emits all required top-level keys' {
        $manifest = [pscustomobject]@{
            timestamp        = '2026-05-17-0700'
            tenantDomain     = 'contoso.com'
            desiredStatePath = 'data-plane/dspm/dspm-config.yaml'
            parametersFile   = 'infra/parameters/lab.yaml'
            workloads        = @('Exchange', 'SharePoint')
            pageSize         = 100
            throttleSeconds  = 1
            maxRetries       = 3
            rowCount         = 0
            failureCount     = 0
            rows             = @()
        }
        $required = @('timestamp', 'tenantDomain', 'desiredStatePath', 'parametersFile',
            'workloads', 'pageSize', 'throttleSeconds', 'maxRetries',
            'rowCount', 'failureCount', 'rows')
        foreach ($k in $required) {
            $manifest.PSObject.Properties[$k] | Should -Not -BeNullOrEmpty -Because "manifest must expose '$k' per ADR 0021"
        }
    }

    It 'per-row OK shape contains Kind/Name/Workload/Status/Retries/Pages/File/Started/DurationSeconds' {
        $row = [pscustomobject]@{
            Kind            = 'Label'
            Name            = 'Public'
            Workload        = 'Exchange'
            Status          = 'OK'
            Retries         = 0
            Pages           = 1
            File            = 'Label__public__Exchange.json'
            Started         = '2026-05-17T07:00:00Z'
            DurationSeconds = 2
        }
        $required = @('Kind', 'Name', 'Workload', 'Status', 'Retries', 'Pages', 'File', 'Started', 'DurationSeconds')
        foreach ($k in $required) {
            $row.PSObject.Properties[$k] | Should -Not -BeNullOrEmpty -Because "OK row must expose '$k'"
        }
        $row.Status | Should -Be 'OK'
    }

    It 'per-row Fail shape contains Kind/Name/Workload/Status/Retries/Error/Started/DurationSeconds' {
        $row = [pscustomobject]@{
            Kind            = 'SIT'
            Name            = 'SIT-One'
            Workload        = 'Teams'
            Status          = 'Fail'
            Retries         = 3
            Error           = 'HTTP 429 after 3 retries'
            Started         = '2026-05-17T07:01:00Z'
            DurationSeconds = 5
        }
        $required = @('Kind', 'Name', 'Workload', 'Status', 'Retries', 'Error', 'Started', 'DurationSeconds')
        foreach ($k in $required) {
            $row.PSObject.Properties[$k] | Should -Not -BeNullOrEmpty -Because "Fail row must expose '$k'"
        }
        $row.Status | Should -Be 'Fail'
    }
}

Describe 'Initialize-PowerShellYaml (issue #333 BeforeAll hardening)' {
    It 'returns Available=$true without calling Install-Module when a satisfying version is already installed' {
        Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' } -MockWith {
            [pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]'0.4.7' }
        }
        Mock Install-Module {}
        Mock Start-Sleep {}

        $result = Initialize-PowerShellYaml -MaxAttempts 3 -MinimumVersion '0.4.7'

        $result.Available | Should -BeTrue
        $result.Reason    | Should -BeNullOrEmpty
        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'retries Install-Module up to MaxAttempts on transient failure and returns Available=$false with a reason' {
        Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' } -MockWith { @() }
        Mock Install-Module { throw 'transient PSGallery hiccup' }
        Mock Start-Sleep {}

        $result = Initialize-PowerShellYaml -MaxAttempts 3 -MinimumVersion '0.4.7'

        $result.Available | Should -BeFalse
        $result.Reason    | Should -Match 'failed after 3 attempts'
        $result.Reason    | Should -Match 'transient PSGallery hiccup'
        Should -Invoke Install-Module -Times 3 -Exactly
        # Two backoff sleeps between three attempts; none after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'succeeds on the second attempt after one transient failure' {
        Mock Get-Module -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' } -MockWith { @() }
        $script:CallCount = 0
        Mock Install-Module {
            $script:CallCount++
            if ($script:CallCount -lt 2) { throw 'first attempt blip' }
        }
        Mock Start-Sleep {}

        $result = Initialize-PowerShellYaml -MaxAttempts 3 -MinimumVersion '0.4.7'

        $result.Available | Should -BeTrue
        $result.Reason    | Should -BeNullOrEmpty
        Should -Invoke Install-Module -Times 2 -Exactly
    }
}
