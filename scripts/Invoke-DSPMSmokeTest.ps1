#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/dspm-end-to-end-smoke.md
    for capturing v2 §5.4 Data Security Posture Management evidence in
    one command.

.DESCRIPTION
    Chains Steps 1-2 of the operator-driven DSPM end-to-end smoke
    runbook against the live contoso.onmicrosoft.com tenant. Both
    underlying scripts are READ-ONLY — DSPM has no mutating cmdlet
    surface — so the wrapper has no destructive-confirmation prompt
    and no throwaway-object lifecycle:

      Step 1: scripts/Test-DSPMPosture.ps1 -ConnectTenant
              Verifies the local YAML schema, source paths,
              gitignore, and tenant-side audit-log + role-group
              prerequisites for Get-ContentExplorerData. No writes.

      Step 2: scripts/Export-ContentExplorerData.ps1
              Pages Get-ContentExplorerData across the resolved
              (item, Workload) plan per data-plane/dspm/dspm-config.yaml
              and writes one JSON per pair plus a manifest.json.
              Read API only.

    Writes a timestamped Markdown evidence file under
    .copilot-tracking/smoke/dspm-<UTC>.md that the operator pastes
    verbatim into the v2 §5.4 close-out PR.

    Hard rule (v2 §5.4 / issue #366): both underlying scripts are
    read-only — there is no mutating call path to gate. The wrapper
    introduces no new auth path; all tenant interaction flows through
    scripts/Get-PurviewIPPSAccessToken.ps1 + Connect-IPPSSession
    -AccessToken (Key Vault-signed JWT per ADR 0011 Decision #3
    supersession).

    AI agents must not execute this wrapper. The wrapper is
    operator-launched per
    .github/instructions/mcp-tool-usage.instructions.md; the agent's
    role is restricted to consuming the evidence file the wrapper
    produces.

    References:
      - https://learn.microsoft.com/en-us/purview/dspm
      - https://learn.microsoft.com/en-us/purview/data-classification-content-explorer
      - https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata
      - docs/adr/0021-dspm-content-explorer-cadence.md
      - docs/runbooks/dspm-end-to-end-smoke.md

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence
    file. Defaults to .copilot-tracking/smoke/ under -RepoRoot. The
    .copilot-tracking/ folder is gitignored at the repo root; the
    wrapper refuses to write outside that umbrella.

.PARAMETER TestScript
    Path to scripts/Test-DSPMPosture.ps1. Defaults to the sibling
    under $PSScriptRoot. Override only for fixture testing.

.PARAMETER ExportScript
    Path to scripts/Export-ContentExplorerData.ps1. Defaults to the
    sibling under $PSScriptRoot. Override only for fixture testing.

.PARAMETER SkipExport
    Skip Step 2 (the live Get-ContentExplorerData export). Use when
    re-running just the posture check after a YAML edit. Step 1 still
    runs.

.PARAMETER StopOnFailure
    Abort the wrapper as soon as any step's expected/actual contract
    fails. Default $true.

.EXAMPLE
    PS> ./scripts/Invoke-DSPMSmokeTest.ps1

    Run Steps 1-2 end-to-end. Pastes the evidence file path on success.

.EXAMPLE
    PS> ./scripts/Invoke-DSPMSmokeTest.ps1 -SkipExport

    Run only Step 1 (posture verifier with -ConnectTenant). Use for
    quick post-edit re-verification.

.NOTES
    Output: a single [pscustomobject] per step on the success stream
    with the fields Step, Title, Result (PASS/FAIL/SKIPPED), Reason.
    The full Markdown evidence file is the durable artifact; the
    stream output is for interactive feedback.

    Exit codes:
      0  every step PASSED (or was SKIPPED)
      1  at least one step FAILED
      2  preconditions failed
#>

[CmdletBinding()]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceDirectory,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TestScript = (Join-Path $PSScriptRoot 'Test-DSPMPosture.ps1'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ExportScript = (Join-Path $PSScriptRoot 'Export-ContentExplorerData.ps1'),

    [Parameter()]
    [switch]$SkipExport,

    [Parameter()]
    [bool]$StopOnFailure = $true
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = Join-Path $RepoRoot '.copilot-tracking' 'smoke'
}

# region Helpers (AST-extractable; covered by tests/scripts/Invoke-DSPMSmokeTest.Tests.ps1)

function Test-DSPMPostureRowShape {
    # Inspect the rows emitted by scripts/Test-DSPMPosture.ps1 and
    # assert the contract: no row has Status='Fail'. Returns
    # @{ Pass = $bool; Reasons = [string[]] }. Warn rows are allowed
    # (they document non-blocking gaps such as gitignore drift the
    # operator may want to triage).
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $failed = @($Rows | Where-Object { $_.Status -eq 'Fail' })
    foreach ($r in $failed) {
        $reasons.Add(("Test-DSPMPosture Fail: {0} -- {1}" -f $r.Check, $r.Detail)) | Out-Null
    }
    if ($Rows.Count -eq 0) {
        $reasons.Add('Test-DSPMPosture produced no rows. Expected at least 6.') | Out-Null
    }
    return @{ Pass = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Test-DSPMExportManifestShape {
    # Inspect a manifest object emitted by
    # scripts/Export-ContentExplorerData.ps1 and assert:
    #   1. manifest has a non-empty rows[] array.
    #   2. every row carries Status='OK' (no partial failures).
    # Returns @{ Pass = $bool; Reasons = [string[]] }.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]$Manifest
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $rows = @($Manifest.rows)
    if ($rows.Count -eq 0) {
        $reasons.Add('Export manifest contains zero rows. Resolved scope was empty.') | Out-Null
    }
    $bad = @($rows | Where-Object { $_.Status -ne 'OK' })
    foreach ($r in $bad) {
        $reasons.Add(("Export row failed: Kind={0} Name={1} Workload={2} Status={3}" -f $r.Kind, $r.Name, $r.Workload, $r.Status)) | Out-Null
    }
    return @{ Pass = ($reasons.Count -eq 0); Reasons = $reasons }
}

function New-DSPMSmokeEvidence {
    # Render the per-step result list as a Markdown evidence file
    # suitable for pasting verbatim into the v2 §5.4 close-out PR.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$EvidenceFile,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# DSPM end-to-end smoke evidence')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(("Generated: {0:o}" -f (Get-Date).ToUniversalTime()))
    [void]$sb.AppendLine(("Manifest:  {0}" -f $ManifestPath))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Step | Title | Result | Reason |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($r in $Results) {
        [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $r.Step, $r.Title, $r.Result, ($r.Reason -replace '\|', '\|')))
    }
    if ($PSCmdlet.ShouldProcess($EvidenceFile, 'Write evidence file')) {
        Set-Content -LiteralPath $EvidenceFile -Value $sb.ToString() -Encoding utf8
    }
    return $EvidenceFile
}

# endregion

# region Preconditions

foreach ($p in @($TestScript, $ExportScript)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Error ("Required script not found at '{0}'." -f $p)
        exit 2
    }
}

if ($EvidenceDirectory -notmatch '\.copilot-tracking[/\\]') {
    Write-Error ("EvidenceDirectory '{0}' must live under .copilot-tracking/ (gitignored)." -f $EvidenceDirectory)
    exit 2
}
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force -ErrorAction Stop

$evidenceStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$evidenceFile  = Join-Path $EvidenceDirectory ("dspm-{0}.md" -f $evidenceStamp)

# endregion

$results = New-Object 'System.Collections.Generic.List[object]'
$anyFail = $false

# region Step 1 — Test-DSPMPosture -ConnectTenant

Write-Information '' -InformationAction Continue
Write-Information '== Step 1: Test-DSPMPosture -ConnectTenant ==' -InformationAction Continue
try {
    $postureRows = & $TestScript -ConnectTenant
    $postureRows | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    $assertion = Test-DSPMPostureRowShape -Rows @($postureRows)
    if ($assertion.Pass) {
        $results.Add([pscustomobject]@{
            Step = 1; Title = 'Test-DSPMPosture -ConnectTenant'; Result = 'PASS'
            Reason = ("{0} rows OK." -f $postureRows.Count)
        })
    } else {
        $anyFail = $true
        $results.Add([pscustomobject]@{
            Step = 1; Title = 'Test-DSPMPosture -ConnectTenant'; Result = 'FAIL'
            Reason = ($assertion.Reasons -join '; ')
        })
        if ($StopOnFailure) {
            New-DSPMSmokeEvidence -Results $results -EvidenceFile $evidenceFile -ManifestPath '(no export run)' | Out-Null
            Write-Information ('Evidence: {0}' -f $evidenceFile) -InformationAction Continue
            exit 1
        }
    }
} catch {
    $anyFail = $true
    $results.Add([pscustomobject]@{
        Step = 1; Title = 'Test-DSPMPosture -ConnectTenant'; Result = 'FAIL'
        Reason = $_.Exception.Message
    })
    if ($StopOnFailure) {
        New-DSPMSmokeEvidence -Results $results -EvidenceFile $evidenceFile -ManifestPath '(no export run)' | Out-Null
        Write-Information ('Evidence: {0}' -f $evidenceFile) -InformationAction Continue
        exit 1
    }
}

# endregion

# region Step 2 — Export-ContentExplorerData

$manifestPath = '(skipped)'

if ($SkipExport.IsPresent) {
    Write-Information '' -InformationAction Continue
    Write-Information '== Step 2: Export-ContentExplorerData (SKIPPED by -SkipExport) ==' -InformationAction Continue
    $results.Add([pscustomobject]@{
        Step = 2; Title = 'Export-ContentExplorerData'; Result = 'SKIPPED'
        Reason = '-SkipExport supplied.'
    })
} else {
    Write-Information '' -InformationAction Continue
    Write-Information '== Step 2: Export-ContentExplorerData ==' -InformationAction Continue
    try {
        & $ExportScript

        # The exporter writes to verify-dspm-export-output/<UTC>/ by default.
        # Resolve the latest subdir and read its manifest.json.
        $exportRoot = Join-Path $RepoRoot 'verify-dspm-export-output'
        $latest = Get-ChildItem -LiteralPath $exportRoot -Directory -ErrorAction Stop |
            Sort-Object Name -Descending |
            Select-Object -First 1
        if (-not $latest) {
            throw ("Export root '{0}' contains no run subdirectory." -f $exportRoot)
        }
        $manifestPath = Join-Path $latest.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw ("Run directory '{0}' has no manifest.json." -f $latest.FullName)
        }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $assertion = Test-DSPMExportManifestShape -Manifest $manifest
        if ($assertion.Pass) {
            $results.Add([pscustomobject]@{
                Step = 2; Title = 'Export-ContentExplorerData'; Result = 'PASS'
                Reason = ("{0} (item, Workload) pairs exported OK." -f @($manifest.rows).Count)
            })
        } else {
            $anyFail = $true
            $results.Add([pscustomobject]@{
                Step = 2; Title = 'Export-ContentExplorerData'; Result = 'FAIL'
                Reason = ($assertion.Reasons -join '; ')
            })
        }
    } catch {
        $anyFail = $true
        $results.Add([pscustomobject]@{
            Step = 2; Title = 'Export-ContentExplorerData'; Result = 'FAIL'
            Reason = $_.Exception.Message
        })
    }
}

# endregion

# region Evidence + exit

New-DSPMSmokeEvidence -Results $results -EvidenceFile $evidenceFile -ManifestPath $manifestPath | Out-Null
Write-Information '' -InformationAction Continue
Write-Information ('Evidence: {0}' -f $evidenceFile) -InformationAction Continue

$results

if ($anyFail) { exit 1 } else { exit 0 }

# endregion
