#Requires -Version 7.4
<#
.SYNOPSIS
    Run the repository Pester suite.

.DESCRIPTION
    Installs the pinned Pester version into the current user scope if it is
    not already present, discovers `tests/**/*.Tests.ps1`, runs them, and
    writes a JUnit-format result file to `tests/results/pester.xml` for CI
    consumption.

    Designed to be safe to run both locally and from
    `.github/workflows/validate.yml`. The suite is unit-only: tests must not
    depend on a live Microsoft Purview tenant, on `Connect-IPPSSession`, or
    on any module from `ExchangeOnlineManagement`. Live-tenant assertions
    belong in PR-time lab-smoke evidence, not here.

.NOTES
    Reference: https://pester.dev/docs/quick-start
    Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/ps101/10-script-modules
#>
[CmdletBinding()]
param(
    # Minimum acceptable Pester version. Anything older than this is replaced
    # via Install-Module -Force into CurrentUser scope. Bump deliberately;
    # do not float to the latest released version.
    [string]$PesterMinimumVersion = '5.5.0',

    # Output file (NUnit XML 2.5; consumed by GitHub Actions test reporters).
    [string]$ResultPath = (Join-Path $PSScriptRoot 'results/pester.xml')
)

$ErrorActionPreference = 'Stop'

# Reference: https://learn.microsoft.com/en-us/powershell/module/powershellget/install-module
$existing = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]$PesterMinimumVersion } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $existing) {
    Write-Information "Installing Pester $PesterMinimumVersion (CurrentUser scope)..." -InformationAction Continue
    Install-Module -Name Pester -MinimumVersion $PesterMinimumVersion -Scope CurrentUser -Force -SkipPublisherCheck
    $existing = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge [version]$PesterMinimumVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

Import-Module $existing.Path -Force

$resultDir = Split-Path -Parent $ResultPath
if (-not (Test-Path $resultDir)) {
    New-Item -ItemType Directory -Path $resultDir -Force | Out-Null
}

$config = New-PesterConfiguration
# Discover every *.Tests.ps1 under tests/, not just tests/scripts/. Widened by
# ADR 0055 so tests/data-plane/ — the guard tests that read the SHIPPED YAMLs
# rather than a fixture — are actually run. Before that ADR, zero tests loaded a
# shipped data-plane YAML, and the hazard was in the data.
$config.Run.Path             = $PSScriptRoot
$config.Run.Exit             = $true
$config.Run.Throw            = $false
$config.TestResult.Enabled   = $true
$config.TestResult.OutputPath= $ResultPath
$config.TestResult.OutputFormat = 'JUnitXml'
$config.Output.Verbosity     = 'Detailed'

Invoke-Pester -Configuration $config
