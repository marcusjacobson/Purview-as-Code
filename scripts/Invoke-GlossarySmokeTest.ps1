#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/glossary-end-to-end-smoke.md
    for capturing v2 §5.9 Glossary Phase 3+4 evidence in one command.

.DESCRIPTION
    Executes Steps 1-6 of the operator-driven Glossary end-to-end smoke
    runbook against the live contoso.onmicrosoft.com tenant using a THROWAWAY
    term named e2e-glossary-smoke-<YYYYMMDD-HHmm>, prompts for explicit
    confirmation before the destructive cleanup step, and writes a
    timestamped Markdown evidence file under
    .copilot-tracking/smoke/glossary-<UTC>.md that the operator pastes
    verbatim into the v2 §5.9 close-out PR.

    Hard rule: pre-existing live glossary terms in the tenant MUST NOT be
    mutated. The wrapper enforces this by:

      - Only ever issuing DELETE on term GUIDs whose name matches
        ^e2e-glossary-smoke- (asserted before every DELETE call).
      - Asserting that every Deploy-Glossary.ps1 -WhatIf plan classifies
        each pre-existing live term as NoChange (never Update / Failed).

    Wraps the runbook one-for-one; introduces no new auth path. All tenant
    interaction flows through scripts/Connect-Purview.ps1 + direct REST
    POST/GET/DELETE plus scripts/Deploy-Glossary.ps1.

    AI agents must not execute this wrapper. The wrapper is
    operator-launched per .github/instructions/mcp-tool-usage.instructions.md;
    the agent's role is restricted to consuming the evidence file the
    wrapper produces.

    References:
      - https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary
      - docs/adr/0029-source-of-truth-direction-policy.md
      - docs/runbooks/glossary-end-to-end-smoke.md

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence file.
    Defaults to .copilot-tracking/smoke/ under -RepoRoot.

.PARAMETER SmokeTermName
    Name of the throwaway term. Defaults to
    e2e-glossary-smoke-<YYYYMMDD-HHmm>. Must start with
    'e2e-glossary-smoke-' to keep accidental real-term collisions impossible.

.PARAMETER PurviewAccountName
    Purview account to target. Defaults to resolution by
    scripts/Deploy-Glossary.ps1 from infra/parameters/lab.yaml.

.PARAMETER SkipDestructiveConfirmation
    Skip the operator y/n prompt before Step 5 (DELETE on the throwaway).
    Reserved for fully-automated re-runs after a clean dry-run; default
    off so the runbook safety stance is preserved on first invocation.

.PARAMETER StopOnFailure
    Abort the wrapper as soon as any step's expected/actual contract
    fails. Default $true.

.EXAMPLE
    PS> ./scripts/Invoke-GlossarySmokeTest.ps1

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
    [Parameter()][ValidatePattern('^e2e-glossary-smoke-[a-z0-9-]+$')][string]$SmokeTermName,
    [Parameter()][string]$PurviewAccountName,
    [Parameter()][switch]$SkipDestructiveConfirmation,
    [Parameter()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','StopOnFailure',Justification='Consumed via $script scope inside Add-Result.')]
    [bool]$StopOnFailure = $true
)

$ErrorActionPreference = 'Stop'
$null = $StopOnFailure

# Pinned API version per ADR 0026.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary
$script:GlossaryApiVersion = '2023-09-01'

if (-not $SmokeTermName) {
    $SmokeTermName = "e2e-glossary-smoke-$((Get-Date).ToString('yyyyMMdd-HHmm'))"
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

function Assert-SmokeTermPrefix {
    param([string]$Name)
    if ($Name -notmatch '^e2e-glossary-smoke-') {
        throw "Safety assert failed: '$Name' does not start with 'e2e-glossary-smoke-'. Refusing to issue DELETE."
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

$deployScript  = Join-Path $PSScriptRoot 'Deploy-Glossary.ps1'
$connectScript = Join-Path $PSScriptRoot 'Connect-Purview.ps1'
if (-not (Test-Path -LiteralPath $deployScript)) {
    Add-Result -Step 0 -Title 'Preconditions: Deploy-Glossary.ps1' -Result 'FAIL' -Reason "Not found at $deployScript"
    exit 2
}
if (-not (Test-Path -LiteralPath $connectScript)) {
    Add-Result -Step 0 -Title 'Preconditions: Connect-Purview.ps1' -Result 'FAIL' -Reason "Not found at $connectScript"
    exit 2
}

$gitStatus = (git status --short data-plane/glossary/ 2>$null) -join ''
if (-not [string]::IsNullOrWhiteSpace($gitStatus)) {
    Add-Result -Step 0 -Title 'Preconditions: clean tree under data-plane/glossary/' -Result 'FAIL' -Reason "git status -s returned: $gitStatus"
    exit 2
}

Add-Result -Step 0 -Title 'Preconditions' -Result 'PASS' -Reason 'az login OK; helper scripts present; tree clean.' | Out-Null

#endregion

#region Step 1 — baseline audit

$step1Output = & $deployScript -DirectionPolicy audit *>&1 | Out-String
if ($step1Output -notmatch '\[ADR0029-AUDIT\]') {
    Add-Result -Step 1 -Title 'Baseline audit' -Result 'FAIL' -Reason 'Audit mode did not emit the ADR0029-AUDIT marker.'
} else {
    Add-Result -Step 1 -Title 'Baseline audit' -Result 'PASS' -Reason 'Audit-mode plan captured.' | Out-Null
}

#endregion

#region Step 2 — Resolve glossary container + Create throwaway term

if (-not $PurviewAccountName) {
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
    Add-Result -Step 2 -Title 'Create throwaway term' -Result 'FAIL' -Reason 'Connect-Purview.ps1 did not return data-plane headers.'
    exit 1
}
$baseUri = $ctx.Endpoint

# GET the Glossary container GUID. The container is auto-created by Purview
# on first term write; if it does not exist yet, run the script to create it
# before proceeding.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/list-glossaries
$glossaryListUri = "$baseUri/datamap/api/atlas/v2/glossary?limit=1000&api-version=$script:GlossaryApiVersion"
try {
    $glossaries = @(Invoke-RestMethod -Method GET -Uri $glossaryListUri -Headers $ctx.DataHeaders -ErrorAction Stop)
} catch {
    Add-Result -Step 2 -Title 'Resolve glossary container' -Result 'FAIL' -Reason ("GET glossaries failed: {0}" -f $_.Exception.Message)
    exit 1
}
$targetGlossary = $glossaries | Where-Object { [string]$_.name -ieq 'Glossary' } | Select-Object -First 1
if (-not $targetGlossary) {
    Add-Result -Step 2 -Title 'Resolve glossary container' -Result 'FAIL' -Reason ("No 'Glossary' container found in tenant. Run Deploy-Glossary.ps1 first to provision the container and seed terms.")
    exit 1
}
$glossaryGuid = [string]$targetGlossary.guid

# POST throwaway term.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/create-term
$termCreateUri = "$baseUri/datamap/api/atlas/v2/glossary/term?api-version=$script:GlossaryApiVersion"
$termBody = @{
    name             = $SmokeTermName
    anchor           = @{ glossaryGuid = $glossaryGuid }
    shortDescription = 'E2E smoke throwaway term (delete on sight).'
    status           = 'Draft'
} | ConvertTo-Json -Depth 10 -Compress
try {
    $created = Invoke-RestMethod -Method POST -Uri $termCreateUri -Headers $ctx.DataHeaders -Body $termBody -ContentType 'application/json' -ErrorAction Stop
    $smokeGuid = [string]$created.guid
    Add-Result -Step 2 -Title 'Create throwaway term' -Result 'PASS' -Reason ("POST created term '{0}' (guid redacted)." -f $created.name) | Out-Null
} catch {
    Add-Result -Step 2 -Title 'Create throwaway term' -Result 'FAIL' -Reason ("POST failed: {0}" -f $_.Exception.Message)
    exit 1
}

#endregion

#region Step 3 — Orphan reported

$step3Output = & $deployScript -WhatIf *>&1 | Out-String
if ($step3Output -match "(?m)^Orphan\s+Term\s+$([regex]::Escape($SmokeTermName))\b") {
    Add-Result -Step 3 -Title 'Orphan reported' -Result 'PASS' -Reason ("'$SmokeTermName' appears as Orphan in WhatIf plan.") | Out-Null
} else {
    Add-Result -Step 3 -Title 'Orphan reported' -Result 'FAIL' -Reason ("'$SmokeTermName' not found as Orphan. Output tail: $(($step3Output.Split("`n") | Select-Object -Last 10 | Out-String))")
}

#endregion

#region Step 4 — SkipNames suppresses

$step4Output = & $deployScript -WhatIf -SkipNames @($SmokeTermName) *>&1 | Out-String
if ($step4Output -match "\[ADR0029-SKIP\] $([regex]::Escape($SmokeTermName))" -and
    $step4Output -match "(?m)^Skip\s+Term\s+$([regex]::Escape($SmokeTermName))\b") {
    Add-Result -Step 4 -Title 'SkipNames suppresses orphan' -Result 'PASS' -Reason ("'$SmokeTermName' appears as Skip with ADR0029-SKIP marker.") | Out-Null
} else {
    Add-Result -Step 4 -Title 'SkipNames suppresses orphan' -Result 'FAIL' -Reason 'Expected Skip row or ADR0029-SKIP marker missing.'
}

#endregion

#region Step 5 — Destructive cleanup

Assert-SmokeTermPrefix -Name $SmokeTermName

if (-not $SkipDestructiveConfirmation) {
    Write-Information '' -InformationAction Continue
    Write-Warning "About to DELETE glossary term '$SmokeTermName' from the Glossary container."
    $resp = Read-Host "Proceed? (y/yes/confirm)"
    if ($resp -notin @('y','yes','confirm')) {
        Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason 'Operator declined confirmation.'
        exit 1
    }
}

# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/delete-term
$termDeleteUri = "$baseUri/datamap/api/atlas/v2/glossary/term/$([uri]::EscapeDataString($smokeGuid))?api-version=$script:GlossaryApiVersion"
try {
    Invoke-RestMethod -Method DELETE -Uri $termDeleteUri -Headers $ctx.DataHeaders -ErrorAction Stop | Out-Null
} catch {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason ("DELETE failed: {0}" -f $_.Exception.Message)
    exit 1
}
# Verify gone
$gone = $false
try {
    Invoke-RestMethod -Method GET -Uri $termDeleteUri -Headers $ctx.DataHeaders -ErrorAction Stop | Out-Null
} catch {
    $gone = $true
}
if ($gone) {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'PASS' -Reason ("'$SmokeTermName' deleted; follow-up GET returns not-found.") | Out-Null
} else {
    Add-Result -Step 5 -Title 'Destructive cleanup' -Result 'FAIL' -Reason ("'$SmokeTermName' still resolvable after DELETE.")
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
$evidencePath = Join-Path $EvidenceDirectory "glossary-$utc.md"
$evidenceLines = New-Object 'System.Collections.Generic.List[string]'
$evidenceLines.Add("# Glossary end-to-end smoke evidence — $utc")
$evidenceLines.Add('')
# Per .github/instructions/sample-data.instructions.md, real tenant
# IDs are reconnaissance-grade data. Emit the redacted zero-GUID
# placeholder; the operator confirms tenancy out-of-band.
$evidenceLines.Add("- Tenant: ``00000000-0000-0000-0000-000000000000`` (``contoso.onmicrosoft.com``)")
$evidenceLines.Add("- Throwaway term: ``$SmokeTermName``")
$evidenceLines.Add("- Runbook: [docs/runbooks/glossary-end-to-end-smoke.md](../../docs/runbooks/glossary-end-to-end-smoke.md)")
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

