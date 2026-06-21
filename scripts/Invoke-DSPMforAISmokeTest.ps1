#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/dspm-for-ai-end-to-end-smoke.md
    for capturing v2 §5.4 DSPM for AI watch-list re-verification evidence
    in one command.

.DESCRIPTION
    Runs scripts/Test-DSPMforAIPosture.ps1 -ConnectTenant against the live
    contoso.onmicrosoft.com tenant and writes a timestamped Markdown evidence file
    under .copilot-tracking/smoke/dspm-for-ai-<UTC>.md that the operator
    pastes verbatim into the v2 §5.4 close-out PR.

    DSPM for AI has no documented programmatic authoring surface per
    ADR 0022 (docs/adr/0022-dspm-for-ai-authoring-surface.md); there is
    no exporter, no reconciler, no mutating cmdlet path. The wrapper is
    therefore READ-ONLY by construction with no destructive-confirmation
    prompt and no throwaway-object lifecycle.

    Hard rule (v2 §5.4 / issue #368): the underlying verifier is read-only.
    The wrapper introduces no new auth path; all tenant interaction flows
    through scripts/Get-PurviewIPPSAccessToken.ps1 + Connect-IPPSSession
    -AccessToken (Key Vault-signed JWT per ADR 0011 Decision #3
    supersession).

    AI agents must not execute this wrapper. The wrapper is operator-
    launched per .github/instructions/mcp-tool-usage.instructions.md;
    the agent's role is restricted to consuming the evidence file the
    wrapper produces.

    References:
      - https://learn.microsoft.com/en-us/purview/dspm-for-ai
      - https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-considerations
      - https://learn.microsoft.com/en-us/purview/ai-microsoft-purview-permissions
      - docs/adr/0022-dspm-for-ai-authoring-surface.md
      - docs/runbooks/dspm-for-ai-end-to-end-smoke.md

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence file.
    Defaults to .copilot-tracking/smoke/ under -RepoRoot. The
    .copilot-tracking/ folder is gitignored at the repo root; the wrapper
    refuses to write outside that umbrella.

.PARAMETER TestScript
    Path to scripts/Test-DSPMforAIPosture.ps1. Defaults to the sibling
    under $PSScriptRoot. Override only for fixture testing.

.EXAMPLE
    PS> ./scripts/Invoke-DSPMforAISmokeTest.ps1

    Runs Test-DSPMforAIPosture -ConnectTenant end-to-end. Writes the
    evidence file path on success.

.NOTES
    Output: a single [pscustomobject] per step on the success stream
    with the fields Step, Title, Result (PASS/FAIL), Reason.

    Exit codes:
      0  every step PASSED
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
    [string]$TestScript = (Join-Path $PSScriptRoot 'Test-DSPMforAIPosture.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = Join-Path $RepoRoot '.copilot-tracking' 'smoke'
}

# region Helpers (AST-extractable; covered by tests/scripts/Invoke-DSPMforAISmokeTest.Tests.ps1)

function Test-DSPMforAIPostureRowShape {
    # Inspect the rows emitted by scripts/Test-DSPMforAIPosture.ps1 and
    # assert the contract: no row has Status='Fail'. Returns
    # @{ Pass = $bool; Reasons = [string[]] }. Warn rows are allowed
    # (the YAML's roleGroups: [] default emits a Warn row by design
    # until the operator populates it).
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $failed = @($Rows | Where-Object { $_.Status -eq 'Fail' })
    foreach ($r in $failed) {
        $reasons.Add(("Test-DSPMforAIPosture Fail: {0} -- {1}" -f $r.Check, $r.Detail)) | Out-Null
    }
    if ($Rows.Count -eq 0) {
        $reasons.Add('Test-DSPMforAIPosture produced no rows. Expected at least 6.') | Out-Null
    }
    return @{ Pass = ($reasons.Count -eq 0); Reasons = $reasons }
}

function New-DSPMforAISmokeEvidence {
    # Render the per-step result list as a Markdown evidence file
    # suitable for pasting verbatim into the v2 §5.4 close-out PR.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory = $true)][string]$EvidenceFile
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# DSPM for AI watch-list re-verification evidence')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(("Generated: {0:o}" -f (Get-Date).ToUniversalTime()))
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

if (-not (Test-Path -LiteralPath $TestScript)) {
    Write-Error ("Required script not found at '{0}'." -f $TestScript)
    exit 2
}

if ($EvidenceDirectory -notmatch '\.copilot-tracking[/\\]') {
    Write-Error ("EvidenceDirectory '{0}' must live under .copilot-tracking/ (gitignored)." -f $EvidenceDirectory)
    exit 2
}
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force -ErrorAction Stop

$evidenceStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$evidenceFile  = Join-Path $EvidenceDirectory ("dspm-for-ai-{0}.md" -f $evidenceStamp)

# endregion

$results = New-Object 'System.Collections.Generic.List[object]'
$anyFail = $false

# region Step 1 — Test-DSPMforAIPosture -ConnectTenant

Write-Information '' -InformationAction Continue
Write-Information '== Step 1: Test-DSPMforAIPosture -ConnectTenant ==' -InformationAction Continue
try {
    $postureRows = & $TestScript -ConnectTenant
    $postureRows | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    $assertion = Test-DSPMforAIPostureRowShape -Rows @($postureRows)
    if ($assertion.Pass) {
        $results.Add([pscustomobject]@{
            Step = 1; Title = 'Test-DSPMforAIPosture -ConnectTenant'; Result = 'PASS'
            Reason = ("{0} rows; no Fail." -f $postureRows.Count)
        })
    } else {
        $anyFail = $true
        $results.Add([pscustomobject]@{
            Step = 1; Title = 'Test-DSPMforAIPosture -ConnectTenant'; Result = 'FAIL'
            Reason = ($assertion.Reasons -join '; ')
        })
    }
} catch {
    $anyFail = $true
    $results.Add([pscustomobject]@{
        Step = 1; Title = 'Test-DSPMforAIPosture -ConnectTenant'; Result = 'FAIL'
        Reason = $_.Exception.Message
    })
}

# endregion

# region Evidence + exit

New-DSPMforAISmokeEvidence -Results $results -EvidenceFile $evidenceFile | Out-Null
Write-Information '' -InformationAction Continue
Write-Information ('Evidence: {0}' -f $evidenceFile) -InformationAction Continue

$results

if ($anyFail) { exit 1 } else { exit 0 }

# endregion
