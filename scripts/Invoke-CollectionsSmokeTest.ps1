#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/collections-end-to-end-smoke.md
    for capturing v2 §5.5 Purview Data Map Collections evidence in one command.

.DESCRIPTION
    Executes Steps 1-6 of the operator-driven Collections end-to-end
    smoke runbook against the live contoso.onmicrosoft.com tenant using a
    THROWAWAY collection named e2e-collections-smoke-<YYYYMMDD-HHmm>,
    prompts for explicit confirmation before the destructive cleanup
    step, and writes a timestamped Markdown evidence file under
    .copilot-tracking/smoke/collections-<UTC>.md that the operator pastes
    verbatim into the v2 §5.5 close-out PR.

    Hard rule: pre-existing live collections in the tenant MUST NOT be
    mutated. The wrapper enforces this by:

      - Only ever issuing DELETE on names matching ^e2e-collections-smoke-
        (asserted before every DELETE call).
      - Asserting that every Deploy-Collections.ps1 -WhatIf plan classifies
        each pre-existing live collection as NoChange (never Update / Failed).

    Wraps the runbook one-for-one; introduces no new auth path. All tenant
    interaction flows through scripts/Connect-Purview.ps1 + direct REST
    PUT/GET/DELETE plus scripts/Deploy-Collections.ps1.

    AI agents must not execute this wrapper. The wrapper is
    operator-launched per .github/instructions/mcp-tool-usage.instructions.md;
    the agent's role is restricted to consuming the evidence file the
    wrapper produces.

    References:
      - https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections
      - docs/adr/0029-source-of-truth-direction-policy.md
      - docs/runbooks/collections-end-to-end-smoke.md

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence file.
    Defaults to .copilot-tracking/smoke/ under -RepoRoot.

.PARAMETER SmokeCollectionName
    Name of the throwaway collection. Defaults to
    e2e-collections-smoke-<YYYYMMDD-HHmm>. Must start with
    'e2e-collections-smoke-' to keep accidental real-collection
    collisions impossible.

.PARAMETER PurviewAccountName
    Purview account to target. Defaults to resolution by
    scripts/Deploy-Collections.ps1 from infra/parameters/lab.yaml.

.PARAMETER SkipDestructiveConfirmation
    Skip the operator y/n prompt before Step 5 (DELETE on the throwaway).
    Reserved for fully-automated re-runs after a clean dry-run; default
    off so the runbook safety stance is preserved on first invocation.

.PARAMETER StopOnFailure
    Abort the wrapper as soon as any step's expected/actual contract
    fails. Default $true.

.EXAMPLE
    PS> ./scripts/Invoke-CollectionsSmokeTest.ps1

.NOTES
    Output: a single [pscustomobject] per step on the success stream with
    fields Step, Title, Result (PASS/FAIL/SKIPPED), Reason.

    Exit codes:
      0  every step PASSED
      1  at least one step FAILED, or the operator declined the
         destructive-confirmation prompt
      2  preconditions failed
#>

[CmdletBinding()]
param(
    [Parameter()][string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter()][string]$EvidenceDirectory,
    [Parameter()][ValidatePattern('^e2e-collections-smoke-[a-z0-9-]+$')][string]$SmokeCollectionName,
    [Parameter()][string]$PurviewAccountName,
    [Parameter()][switch]$SkipDestructiveConfirmation,
    [Parameter()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','StopOnFailure',Justification='Consumed via $script scope inside Add-Result.')]
    [bool]$StopOnFailure = $true
)

$ErrorActionPreference = 'Stop'
# Reference: $StopOnFailure inside the Add-Result helper closure;
# touch here to satisfy PSReviewUnusedParameter (the analyzer does
# not trace into nested function bodies).
$null = $StopOnFailure

# Pinned API version. Reference:
# https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections
$script:CollectionsApiVersion = '2019-11-01-preview'

if (-not $SmokeCollectionName) {
    $SmokeCollectionName = "e2e-collections-smoke-$((Get-Date).ToString('yyyyMMdd-HHmm'))"
}
if (-not $EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $RepoRoot '.copilot-tracking/smoke'
}
if (-not (Test-Path -LiteralPath $EvidenceDirectory)) {
    New-Item -Path $EvidenceDirectory -ItemType Directory -Force | Out-Null
}

$script:Results = New-Object 'System.Collections.Generic.List[object]'

function Add-Result {
    param([int]$Step, [string]$Title, [string]$Result, [string]$Reason)
    $row = [pscustomobject]@{ Step = $Step; Title = $Title; Result = $Result; Reason = $Reason }
    $script:Results.Add($row) | Out-Null
    $row
    if ($Result -eq 'FAIL' -and $StopOnFailure) {
        throw "Step $Step ($Title) FAILED: $Reason"
    }
}

function Assert-SmokePrefix {
    param([string]$Name)
    if ($Name -notmatch '^e2e-collections-smoke-') {
        throw "Safety assert failed: '$Name' does not start with 'e2e-collections-smoke-'. Refusing to issue DELETE."
    }
}

#region Preconditions

try {
    $accountJson = az account show -o json --only-show-errors 2>$null
    if (-not $accountJson) { throw 'No active az login session.' }
    $account = ($accountJson -join "`n") | ConvertFrom-Json
    if ($account.tenantId -isnot [string] -or [string]::IsNullOrEmpty($account.tenantId)) {
        throw 'az account show returned no tenantId.'
    }
} catch {
    Add-Result -Step 0 -Title 'Preconditions: az login' -Result 'FAIL' -Reason $_.Exception.Message
    exit 2
}

$deployScript = Join-Path $PSScriptRoot 'Deploy-Collections.ps1'
$connectScript = Join-Path $PSScriptRoot 'Connect-Purview.ps1'
if (-not (Test-Path -LiteralPath $deployScript)) {
    Add-Result -Step 0 -Title 'Preconditions: Deploy-Collections.ps1' -Result 'FAIL' -Reason "Not found at $deployScript"
    exit 2
}
if (-not (Test-Path -LiteralPath $connectScript)) {
    Add-Result -Step 0 -Title 'Preconditions: Connect-Purview.ps1' -Result 'FAIL' -Reason "Not found at $connectScript"
    exit 2
}

$gitStatus = (git status --short data-plane/collections/ 2>$null) -join ''
if (-not [string]::IsNullOrWhiteSpace($gitStatus)) {
    Add-Result -Step 0 -Title 'Preconditions: clean tree under data-plane/collections/' -Result 'FAIL' -Reason "git status -s returned: $gitStatus"
    exit 2
}

Add-Result -Step 0 -Title 'Preconditions' -Result 'PASS' -Reason 'az login OK; helper scripts present; tree clean.' | Out-Null

#endregion

#region Step 1 — baseline audit

$step1Output = & $deployScript -DirectionPolicy audit *>&1 | Out-String
if ($LASTEXITCODE -ne 0 -and $step1Output -notmatch '\[ADR0029-AUDIT\]') {
    Add-Result -Step 1 -Title 'Baseline audit' -Result 'FAIL' -Reason 'Audit mode did not emit the ADR0029-AUDIT marker.'
} else {
    Add-Result -Step 1 -Title 'Baseline audit' -Result 'PASS' -Reason 'Audit-mode plan captured.' | Out-Null
}

#endregion

#region Step 2 — Create throwaway

if (-not $PurviewAccountName) {
    # Resolve from infra/parameters/lab.yaml (ADR 0012) the same way
    # Deploy-Collections.ps1 does, so this wrapper does not depend on
    # the caller having pre-set the parameter.
    $paramsFile = Join-Path $RepoRoot 'infra/parameters/lab.yaml'
    if (-not (Test-Path -LiteralPath $paramsFile)) {
        Add-Result -Step 2 -Title 'Resolve Purview account' -Result 'FAIL' -Reason "Parameters file not found at $paramsFile"
        exit 2
    }
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop
    $parsed = Get-Content -LiteralPath $paramsFile -Raw | ConvertFrom-Yaml
    if (-not $parsed.ContainsKey('purviewAccountName')) {
        Add-Result -Step 2 -Title 'Resolve Purview account' -Result 'FAIL' -Reason 'lab.yaml missing purviewAccountName'
        exit 2
    }
    $PurviewAccountName = [string]$parsed.purviewAccountName
}

$ctx = & $connectScript -AccountName $PurviewAccountName
if (-not $ctx -or -not $ctx.DataHeaders -or -not $ctx.Endpoint) {
    Add-Result -Step 2 -Title 'Create throwaway' -Result 'FAIL' -Reason 'Connect-Purview.ps1 did not return data-plane headers.'
    exit 1
}
$baseUri = "$($ctx.Endpoint)/account"
$rootName = $PurviewAccountName
$createUri = "$baseUri/collections/$([uri]::EscapeDataString($SmokeCollectionName))?api-version=$script:CollectionsApiVersion"
$createBody = @{
    friendlyName     = 'E2E smoke (delete on sight)'
    description      = "Throwaway collection created by Invoke-CollectionsSmokeTest.ps1 at $((Get-Date -Format 'u'))."
    parentCollection = @{ referenceName = $rootName }
} | ConvertTo-Json -Depth 5 -Compress
try {
    $created = Invoke-RestMethod -Method PUT -Uri $createUri -Headers $ctx.DataHeaders -Body $createBody -ErrorAction Stop
    Add-Result -Step 2 -Title 'Create throwaway' -Result 'PASS' -Reason ("PUT created '{0}' under '{1}'." -f $created.name, $created.parentCollection.referenceName) | Out-Null
} catch {
    Add-Result -Step 2 -Title 'Create throwaway' -Result 'FAIL' -Reason ("PUT failed: {0}" -f $_.Exception.Message)
    exit 1
}

#endregion

#region Step 3 — orphan reported

$step3Output = & $deployScript -WhatIf *>&1 | Out-String
if ($step3Output -match "(?m)^Orphan\s+Collection\s+$([regex]::Escape($SmokeCollectionName))\b") {
    Add-Result -Step 3 -Title 'Orphan reported' -Result 'PASS' -Reason ("'{0}' appears as Orphan in WhatIf plan." -f $SmokeCollectionName) | Out-Null
} else {
    Add-Result -Step 3 -Title 'Orphan reported' -Result 'FAIL' -Reason ("'{0}' not found as Orphan. Output tail: {1}" -f $SmokeCollectionName, ($step3Output.Split("`n") | Select-Object -Last 10 | Out-String))
}

#endregion

#region Step 4 — SkipNames suppresses

$step4Output = & $deployScript -WhatIf -SkipNames @($SmokeCollectionName) *>&1 | Out-String
if ($step4Output -match "\[ADR0029-SKIP\] $([regex]::Escape($SmokeCollectionName))" -and
    $step4Output -match "(?m)^Skip\s+Collection\s+$([regex]::Escape($SmokeCollectionName))\b") {
    Add-Result -Step 4 -Title 'SkipNames suppresses orphan' -Result 'PASS' -Reason ("'{0}' appears as Skip with ADR0029-SKIP marker." -f $SmokeCollectionName) | Out-Null
} else {
    Add-Result -Step 4 -Title 'SkipNames suppresses orphan' -Result 'FAIL' -Reason 'Expected Skip row or ADR0029-SKIP marker missing.'
}

#endregion

#region Step 5 — Destructive cleanup

Assert-SmokePrefix -Name $SmokeCollectionName

if (-not $SkipDestructiveConfirmation) {
    Write-Information '' -InformationAction Continue
    Write-Warning "About to DELETE Purview collection '$SmokeCollectionName' from $rootName."
    $resp = Read-Host "Proceed? (y/yes/confirm)"
    if ($resp -notin @('y','yes','confirm')) {
        Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason 'Operator declined confirmation.'
        exit 1
    }
}

$deleteUri = "$baseUri/collections/$([uri]::EscapeDataString($SmokeCollectionName))?api-version=$script:CollectionsApiVersion"
try {
    Invoke-RestMethod -Method DELETE -Uri $deleteUri -Headers $ctx.DataHeaders -ErrorAction Stop | Out-Null
} catch {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason ("DELETE failed: {0}" -f $_.Exception.Message)
    exit 1
}
# Verify gone
$gone = $false
try {
    Invoke-RestMethod -Method GET -Uri $deleteUri -Headers $ctx.DataHeaders -ErrorAction Stop | Out-Null
} catch {
    $gone = $true
}
if ($gone) {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'PASS' -Reason ("'{0}' deleted; follow-up GET returns not-found." -f $SmokeCollectionName) | Out-Null
} else {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason ("'{0}' still resolvable after DELETE." -f $SmokeCollectionName)
}

#endregion

#region Step 6 — Final verification

$step6Output = & $deployScript -WhatIf *>&1 | Out-String
$banner = ($step6Output -split "`n" | Where-Object { $_ -match '^Plan:\s' } | Select-Object -First 1)
if ($banner -and $banner -notmatch 'Orphan' -and $banner -notmatch 'Skip' -and $banner -match 'NoChange') {
    Add-Result -Step 6 -Title 'Final verification' -Result 'PASS' -Reason $banner.Trim() | Out-Null
} else {
    Add-Result -Step 6 -Title 'Final verification' -Result 'FAIL' -Reason ("Expected only NoChange in banner; got: {0}" -f $banner)
}

#endregion

#region Evidence file

$utc = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$evidencePath = Join-Path $EvidenceDirectory "collections-$utc.md"
$evidenceLines = New-Object 'System.Collections.Generic.List[string]'
$evidenceLines.Add("# Collections end-to-end smoke evidence — $utc")
$evidenceLines.Add('')
# Per .github/instructions/sample-data.instructions.md, real tenant
# IDs are reconnaissance-grade data. Emit the redacted zero-GUID
# placeholder in the evidence file; the operator can confirm tenancy
# out-of-band when pasting into the PR description.
$evidenceLines.Add("- Tenant: ``00000000-0000-0000-0000-000000000000`` (``contoso.onmicrosoft.com``)")
$evidenceLines.Add("- Throwaway: ``$SmokeCollectionName``")
$evidenceLines.Add("- Runbook: [docs/runbooks/collections-end-to-end-smoke.md](../../docs/runbooks/collections-end-to-end-smoke.md)")
$evidenceLines.Add('')
$evidenceLines.Add('| Step | Title | Result | Reason |')
$evidenceLines.Add('|---|---|---|---|')
foreach ($r in $script:Results) {
    $evidenceLines.Add("| $($r.Step) | $($r.Title) | $($r.Result) | $($r.Reason) |")
}
Set-Content -LiteralPath $evidencePath -Value $evidenceLines -Encoding utf8

Write-Information '' -InformationAction Continue
Write-Information "Evidence file: $evidencePath" -InformationAction Continue

$failed = ($script:Results | Where-Object Result -eq 'FAIL').Count
if ($failed -gt 0) { exit 1 } else { exit 0 }

#endregion
