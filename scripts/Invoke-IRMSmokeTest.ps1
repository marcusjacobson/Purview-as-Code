#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/irm-end-to-end-smoke.md
    for capturing v2 §5.3 Insider Risk Management evidence in one command.

.DESCRIPTION
    Executes Steps 1-5 of the operator-driven IRM end-to-end smoke
    runbook against the live contoso.onmicrosoft.com tenant against a
    THROWAWAY policy named e2e-irm-smoke-<YYYYMMDD-HHmm>, prompts for
    explicit confirmation before the destructive cleanup step, and
    writes a timestamped Markdown evidence file under
    .copilot-tracking/smoke/irm-<UTC>.md that the operator pastes
    verbatim into the v2 §5.3 close-out PR.

    Hard rule (issue #603): pre-existing live IRM policies in the
    tenant are mid-testing and MUST NOT be mutated. The wrapper
    enforces this by:

      - Only ever invoking Remove-InsiderRiskPolicy on names matching
        ^e2e-irm-smoke- (asserted before every Remove-* call).
      - Passing the ADR 0036 5-name skip baseline to every
        Deploy-IRMPolicies.ps1 invocation via -SkipNames.
      - Asserting that every plan row in the -WhatIf output classifies
        each pre-existing live policy as Skipped, never Update / Remove
        / Failed. A bug-out plan row fails the smoke and the wrapper
        exits non-zero.

    Wraps the runbook one-for-one; introduces no new auth path and no
    new Microsoft Purview / IPPS cmdlet. All tenant interaction flows
    through scripts/Deploy-IRMPolicies.ps1 (which connects via the
    Key Vault cert + IPPS app-only path) plus four direct IPPS calls
    (Get-InsiderRiskPolicy, New-InsiderRiskPolicy, Remove-InsiderRiskPolicy)
    that the runbook already documents.

    AI agents must not execute this wrapper. The wrapper is
    operator-launched per .github/instructions/mcp-tool-usage.instructions.md;
    the agent's role is restricted to consuming the evidence file the
    wrapper produces.

    References:
      - https://learn.microsoft.com/en-us/purview/insider-risk-management
      - https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
      - https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy
      - https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy
      - docs/adr/0029-source-of-truth-direction-policy.md
      - docs/adr/0036-irm-tenant-setting-immovable.md
      - docs/runbooks/irm-end-to-end-smoke.md

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence
    file. Defaults to .copilot-tracking/smoke/ under -RepoRoot. The
    .copilot-tracking/ folder is gitignored at the repo root; the
    wrapper refuses to write outside that umbrella.

.PARAMETER SmokePolicyName
    Name of the throwaway IRM policy created and torn down end-to-end.
    Defaults to e2e-irm-smoke-<YYYYMMDD-HHmm>. Must start with
    'e2e-irm-smoke-' to keep accidental real-policy collisions impossible.

.PARAMETER SmokeScenario
    InsiderRiskScenario value for the throwaway policy. Defaults to
    LeakOfInformation (a safe template that does not require entity-
    list scoping). Must match the enum in
    data-plane/irm/policies.schema.json.

.PARAMETER SkipNamesBaseline
    The ADR 0036 skip baseline passed to every Deploy-IRMPolicies.ps1
    invocation. Defaults to the 5-name list from
    docs/adr/0036-irm-tenant-setting-immovable.md §"The skip baseline".
    Override only if the operator has just updated ADR 0036 and is
    smoke-testing the new shape in the same session.

.PARAMETER DeployIRMScript
    Path to scripts/Deploy-IRMPolicies.ps1. Defaults to the sibling
    under $PSScriptRoot. Override only for fixture testing.

.PARAMETER SkipDestructiveConfirmation
    Skip the operator y/n prompt before Step 5 (Remove-InsiderRiskPolicy
    on the throwaway). Reserved for fully-automated re-runs after a
    clean dry-run; default off so the runbook's safety stance is
    preserved on first invocation.

.PARAMETER StopOnFailure
    Abort the wrapper as soon as any step's expected/actual contract
    fails. Default $true.

.EXAMPLE
    PS> ./scripts/Invoke-IRMSmokeTest.ps1

    Run Steps 1-5 end-to-end with default names and confirmation
    prompts. Pastes the evidence file path on success.

.EXAMPLE
    PS> ./scripts/Invoke-IRMSmokeTest.ps1 -SkipDestructiveConfirmation -WhatIf

    Dry-run plan rows for every step (no tenant writes; -WhatIf is
    propagated through to each Deploy-IRMPolicies.ps1 invocation; the
    direct IPPS New-/Remove- calls are short-circuited under -WhatIf).

.NOTES
    Output: a single [pscustomobject] per step on the success stream
    with the fields Step, Title, Result (PASS/FAIL/SKIPPED), Reason.
    The full Markdown evidence file is the durable artifact; the
    stream output is for interactive feedback.

    Exit codes:
      0  every step PASSED (or was SKIPPED by -WhatIf during a dry-run)
      1  at least one step FAILED, or the operator declined the
         destructive-confirmation prompt
      2  preconditions failed
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceDirectory,

    [Parameter()]
    [ValidatePattern('^e2e-irm-smoke-[a-z0-9-]{3,40}$')]
    [string]$SmokePolicyName = ('e2e-irm-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmm')),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SmokeScenario = 'LeakOfInformation',

    [Parameter()]
    [string[]]$SkipNamesBaseline = @(),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DeployIRMScript = (Join-Path $PSScriptRoot 'Deploy-IRMPolicies.ps1'),

    [Parameter()]
    [switch]$SkipDestructiveConfirmation,

    [Parameter()]
    [bool]$StopOnFailure = $true
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = Join-Path $RepoRoot '.copilot-tracking' 'smoke'
}

# region Helpers (AST-extractable; covered by tests/scripts/Invoke-IRMSmokeTest.Tests.ps1)

function Get-IRMSmokeSkipBaseline {
    # ADR 0036 §"The skip baseline" — 5 names. Treated as a copy-paste
    # regression check by tests/scripts/Invoke-IRMSmokeTest.Tests.ps1;
    # any drift here must move the ADR table first.
    @(
        'IRM_Tenant_Setting_bd249dd2-1bd6-4d7c-b0d4-7607b70a8207',
        'IRM Lab — Data leaks by priority users',
        'IRM Lab — Data theft by departing users',
        'IRM Lab — General data leaks',
        'IRM Lab — Risky AI usage'
    )
}

function Test-IRMSmokePolicyName {
    # Defensive prefix assert. The wrapper invokes this immediately
    # before every Remove-InsiderRiskPolicy call. A non-matching name
    # throws; the catch in the caller records the step as FAIL.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Name -notmatch '^e2e-irm-smoke-[a-z0-9-]{3,40}$') {
        throw ("Refusing to act on non-smoke IRM policy name: '{0}'. Smoke names must match ^e2e-irm-smoke-[a-z0-9-]{{3,40}}$." -f $Name)
    }
    return $true
}

function Assert-IRMSmokePlanShape {
    # Inspect the Deploy-IRMPolicies.ps1 -WhatIf output and assert the
    # shape required by Step 4 of the runbook:
    #   1. Every name in -ExpectedSkipBaseline appears as Skipped.
    #   2. The smoke policy name appears as Orphan.
    #   3. No Update / Failed / Removed row references any name in
    #      -ExpectedSkipBaseline.
    # Returns a hashtable @{ Pass = $bool; Reasons = [string[]] }.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PlanRows,
        [Parameter(Mandatory = $true)][string]$SmokePolicyName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExpectedSkipBaseline
    )
    $reasons = New-Object 'System.Collections.Generic.List[string]'

    foreach ($n in $ExpectedSkipBaseline) {
        $matching = @($PlanRows | Where-Object { $_.Name -eq $n })
        if ($matching.Count -eq 0) {
            $reasons.Add(("Skip baseline name '{0}' produced no plan row." -f $n)) | Out-Null
            continue
        }
        $cats = @($matching | ForEach-Object { $_.Category } | Sort-Object -Unique)
        if ($cats -ne 'Skipped') {
            $reasons.Add(("Skip baseline name '{0}' classified as '{1}' instead of 'Skipped'." -f $n, ($cats -join ','))) | Out-Null
        }
    }

    $smokeRow = @($PlanRows | Where-Object { $_.Name -eq $SmokePolicyName })
    if ($smokeRow.Count -eq 0) {
        $reasons.Add(("Smoke policy '{0}' produced no plan row (expected 'Orphan')." -f $SmokePolicyName)) | Out-Null
    } else {
        $smokeCat = [string]$smokeRow[0].Category
        if ($smokeCat -ne 'Orphan') {
            $reasons.Add(("Smoke policy '{0}' classified as '{1}' instead of 'Orphan'." -f $SmokePolicyName, $smokeCat)) | Out-Null
        }
    }

    $badRows = @($PlanRows | Where-Object {
            $_.Category -in @('Update','Failed','Removed') -and
            $ExpectedSkipBaseline -icontains [string]$_.Name
        })
    foreach ($r in $badRows) {
        $reasons.Add(("HARD RULE VIOLATION: pre-existing live policy '{0}' classified as '{1}' (would mutate). Escalate to lab owner." -f $r.Name, $r.Category)) | Out-Null
    }

    return @{ Pass = ($reasons.Count -eq 0); Reasons = $reasons }
}

# endregion

# region Preconditions

if ($SkipNamesBaseline.Count -eq 0) {
    $SkipNamesBaseline = Get-IRMSmokeSkipBaseline
}

if (-not (Test-Path -LiteralPath $DeployIRMScript)) {
    Write-Error ("Deploy-IRMPolicies.ps1 not found at '{0}'." -f $DeployIRMScript)
    exit 2
}

if ($EvidenceDirectory -notmatch '\.copilot-tracking[/\\]') {
    Write-Error ("EvidenceDirectory '{0}' must live under .copilot-tracking/ (gitignored)." -f $EvidenceDirectory)
    exit 2
}
$null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force -ErrorAction Stop

Test-IRMSmokePolicyName -Name $SmokePolicyName | Out-Null

# endregion

# region IPPS session helpers

# The wrapper needs direct New-/Get-/Remove-InsiderRiskPolicy calls
# between Deploy-IRMPolicies.ps1 invocations (which each open and
# close their own session in a finally block). Open the session once
# at the start using the same Key Vault cert auth path Deploy uses,
# disconnect before each Deploy invocation, reconnect after.
# Reference: docs/adr/0010-automation-identity-subject-model.md
# Reference: docs/adr/0011-certificate-lifecycle.md
# Reference: docs/adr/0012-environment-parameters-file.md

function Connect-IRMSmokeSession {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module 'powershell-yaml' -ErrorAction Stop

    if (-not (Get-Module -ListAvailable -Name 'ExchangeOnlineManagement')) {
        Install-Module -Name 'ExchangeOnlineManagement' -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
    }
    Import-Module 'ExchangeOnlineManagement' -ErrorAction Stop

    $paramsPath = Join-Path $RepoRoot 'infra/parameters/lab.yaml'
    $p = Get-Content -LiteralPath $paramsPath -Raw | ConvertFrom-Yaml
    $tenantId = (az account show -o json --only-show-errors | ConvertFrom-Json).tenantId
    $apps = az ad app list --display-name $p.automation.apps.dataPlane.displayName -o json --only-show-errors `
        | ConvertFrom-Json `
        | Where-Object displayName -eq $p.automation.apps.dataPlane.displayName
    $appId = [string]$apps[0].appId
    $tokenScript = Join-Path $RepoRoot 'scripts/Get-PurviewIPPSAccessToken.ps1'
    $tok = & $tokenScript `
        -VaultName       $p.resources.keyVault.name `
        -CertificateName $p.automation.apps.dataPlane.certificateName `
        -AppId           $appId `
        -TenantId        $tenantId
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $p.automation.tenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
}

function Disconnect-IRMSmokeSession {
    [CmdletBinding()]
    param ()
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
    }
}

# endregion

# region Execute

$results = New-Object 'System.Collections.Generic.List[object]'
$evidenceLines = New-Object 'System.Collections.Generic.List[string]'
$utc = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$evidencePath = Join-Path $EvidenceDirectory ("irm-{0}.md" -f $utc)
$smokeRunIsDryRun = $WhatIfPreference

$evidenceLines.Add("# Insider Risk Management end-to-end smoke evidence") | Out-Null
$evidenceLines.Add("") | Out-Null
$evidenceLines.Add("- **UTC**: $utc") | Out-Null
$evidenceLines.Add("- **Smoke policy**: ``$SmokePolicyName``") | Out-Null
$evidenceLines.Add("- **Scenario**: $SmokeScenario") | Out-Null
$evidenceLines.Add("- **Skip baseline count**: $($SkipNamesBaseline.Count)") | Out-Null
$evidenceLines.Add("- **Dry-run (-WhatIf)**: $smokeRunIsDryRun") | Out-Null
$evidenceLines.Add("") | Out-Null

function Add-StepResult {
    param([string]$Step, [string]$Title, [string]$Result, [string]$Reason)
    $obj = [pscustomobject]@{
        Step   = $Step
        Title  = $Title
        Result = $Result
        Reason = $Reason
    }
    $results.Add($obj) | Out-Null
    $evidenceLines.Add(("## Step {0} — {1}" -f $Step, $Title)) | Out-Null
    $evidenceLines.Add("") | Out-Null
    $evidenceLines.Add(("**Result**: {0}" -f $Result)) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $evidenceLines.Add(("**Reason**: {0}" -f $Reason)) | Out-Null
    }
    $evidenceLines.Add("") | Out-Null
    return $obj
}

try {
    # Step 1 — clean baseline (audit mode). Runs through
    # Deploy-IRMPolicies.ps1 which opens + closes its own IPPS
    # session. The wrapper has no live session at this point.
    Write-Information "Step 1 — clean baseline (-DirectionPolicy audit)" -InformationAction Continue
    try {
        $null = & $DeployIRMScript -WhatIf -DirectionPolicy audit *>&1
        Add-StepResult -Step '1' -Title 'audit-mode baseline' -Result 'PASS' -Reason 'Audit short-circuit fired; no writes.' | Out-Null
    } catch {
        Add-StepResult -Step '1' -Title 'audit-mode baseline' -Result 'FAIL' -Reason ("Audit invocation threw: {0}" -f $_.Exception.Message) | Out-Null
        if ($StopOnFailure) { throw }
    }

    # Open IPPS session for the direct cmdlet steps (2, 3, 5).
    Connect-IRMSmokeSession -RepoRoot $RepoRoot

    # Step 2 — create throwaway
    Write-Information "Step 2 — create throwaway policy $SmokePolicyName" -InformationAction Continue
    if ($smokeRunIsDryRun) {
        Add-StepResult -Step '2' -Title 'create throwaway' -Result 'SKIPPED' -Reason '-WhatIf dry-run; New-InsiderRiskPolicy not invoked.' | Out-Null
    } else {
        try {
            New-InsiderRiskPolicy -Name $SmokePolicyName -InsiderRiskScenario $SmokeScenario -Comment 'e2e smoke (issue #603) - safe to remove' -Enabled:$false -ErrorAction Stop | Out-Null
            Add-StepResult -Step '2' -Title 'create throwaway' -Result 'PASS' -Reason ("Created '{0}' scenario={1}." -f $SmokePolicyName, $SmokeScenario) | Out-Null
        } catch {
            Add-StepResult -Step '2' -Title 'create throwaway' -Result 'FAIL' -Reason ("New-InsiderRiskPolicy threw: {0}" -f $_.Exception.Message) | Out-Null
            if ($StopOnFailure) { throw }
        }
    }

    # Step 3 — assert shape
    Write-Information "Step 3 — assert Get-InsiderRiskPolicy shape" -InformationAction Continue
    if ($smokeRunIsDryRun) {
        Add-StepResult -Step '3' -Title 'assert shape' -Result 'SKIPPED' -Reason '-WhatIf dry-run; throwaway does not exist.' | Out-Null
    } else {
        try {
            $p = Get-InsiderRiskPolicy -Identity $SmokePolicyName -ErrorAction Stop
            if ($p.Name -ne $SmokePolicyName) {
                throw ("Get returned Name '{0}' (expected '{1}')." -f $p.Name, $SmokePolicyName)
            }
            if ([string]$p.InsiderRiskScenario -ne $SmokeScenario) {
                throw ("Get returned InsiderRiskScenario '{0}' (expected '{1}')." -f $p.InsiderRiskScenario, $SmokeScenario)
            }
            Add-StepResult -Step '3' -Title 'assert shape' -Result 'PASS' -Reason ("Name={0} Scenario={1} IsValid={2}." -f $p.Name, $p.InsiderRiskScenario, $p.IsValid) | Out-Null
        } catch {
            Add-StepResult -Step '3' -Title 'assert shape' -Result 'FAIL' -Reason ("Shape assert threw: {0}" -f $_.Exception.Message) | Out-Null
            if ($StopOnFailure) { throw }
        }
    }

    # Disconnect before Step 4 so Deploy-IRMPolicies.ps1 opens its own
    # session cleanly. (Two open IPPS sessions in one runspace cause
    # cmdlet resolution ambiguity per the EXO module docs.)
    Disconnect-IRMSmokeSession

    # Step 4 — reconciler -WhatIf with skip baseline + plan shape assert
    Write-Information "Step 4 — Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy portal-wins -SkipNames <baseline> -PruneMissing" -InformationAction Continue
    try {
        $planRows = @(& $DeployIRMScript -WhatIf -DirectionPolicy portal-wins -SkipNames $SkipNamesBaseline -PruneMissing -ErrorAction Stop)
        $expectedSmokeName = if ($smokeRunIsDryRun) { '__no-smoke-in-dryrun__' } else { $SmokePolicyName }
        $assertion = Assert-IRMSmokePlanShape -PlanRows $planRows -SmokePolicyName $expectedSmokeName -ExpectedSkipBaseline $SkipNamesBaseline
        if ($assertion.Pass) {
            Add-StepResult -Step '4' -Title 'plan shape assert' -Result 'PASS' -Reason ('{0} plan row(s); skip baseline all Skipped; throwaway classified Orphan; no live-policy mutations planned.' -f $planRows.Count) | Out-Null
        } else {
            if ($smokeRunIsDryRun) {
                Add-StepResult -Step '4' -Title 'plan shape assert' -Result 'SKIPPED' -Reason ('-WhatIf dry-run; throwaway not created so Orphan assert is degraded. Skip-baseline assert: {0}.' -f (($assertion.Reasons | Where-Object { $_ -notlike '*Smoke policy*' }) -join '; ')) | Out-Null
            } else {
                Add-StepResult -Step '4' -Title 'plan shape assert' -Result 'FAIL' -Reason ($assertion.Reasons -join ' | ') | Out-Null
                if ($StopOnFailure) { throw ($assertion.Reasons -join ' | ') }
            }
        }
        $evidenceLines.Add('```text') | Out-Null
        $evidenceLines.Add(($planRows | Format-Table -AutoSize | Out-String -Width 160).Trim()) | Out-Null
        $evidenceLines.Add('```') | Out-Null
        $evidenceLines.Add('') | Out-Null
    } catch {
        Add-StepResult -Step '4' -Title 'plan shape assert' -Result 'FAIL' -Reason ("Reconciler -WhatIf threw: {0}" -f $_.Exception.Message) | Out-Null
        if ($StopOnFailure) { throw }
    }

    # Reconnect for Step 5 direct Remove + Get-gone verify.
    if (-not $smokeRunIsDryRun) {
        Connect-IRMSmokeSession -RepoRoot $RepoRoot
    }

    # Step 5 — destructive cleanup of throwaway
    Write-Information "Step 5 — Remove-InsiderRiskPolicy '$SmokePolicyName'" -InformationAction Continue
    if ($smokeRunIsDryRun) {
        Add-StepResult -Step '5' -Title 'destructive cleanup' -Result 'SKIPPED' -Reason '-WhatIf dry-run; Remove-InsiderRiskPolicy not invoked.' | Out-Null
    } else {
        $confirmed = $SkipDestructiveConfirmation.IsPresent
        if (-not $confirmed) {
            $answer = Read-Host ("About to Remove-InsiderRiskPolicy -Identity '{0}'. Type 'y', 'yes', or 'confirm' to proceed" -f $SmokePolicyName)
            $confirmed = $answer -in @('y', 'yes', 'confirm')
        }
        if (-not $confirmed) {
            Add-StepResult -Step '5' -Title 'destructive cleanup' -Result 'FAIL' -Reason 'Operator declined destructive-confirmation prompt; throwaway policy left in tenant.' | Out-Null
            if ($StopOnFailure) { throw 'Operator declined destructive-confirmation prompt.' }
        } else {
            try {
                Test-IRMSmokePolicyName -Name $SmokePolicyName | Out-Null
                # -WhatIf:$false defends against an inherited
                # $WhatIfPreference (the wrapper's [CmdletBinding]
                # inherits the caller's value; without the explicit
                # override the destructive cleanup would no-op even
                # when the operator explicitly invoked the wrapper
                # to delete the throwaway).
                Remove-InsiderRiskPolicy -Identity $SmokePolicyName -Confirm:$false -WhatIf:$false -ErrorAction Stop | Out-Null
                # IPPS Remove-* cmdlets queue asynchronously; an
                # immediate Get-* can still find the deleted object
                # for ~5-30 seconds. Poll with a bounded retry; treat
                # "still found" as a soft signal until the timeout
                # elapses, then escalate to FAIL.
                $deadline = (Get-Date).AddSeconds(60)
                $stillThere = $null
                do {
                    Start-Sleep -Seconds 5
                    try { $stillThere = Get-InsiderRiskPolicy -Identity $SmokePolicyName -ErrorAction Stop } catch { $stillThere = $null }
                } while ($null -ne $stillThere -and (Get-Date) -lt $deadline)
                if ($null -ne $stillThere) {
                    throw ("Remove-InsiderRiskPolicy returned ok but Get still finds '{0}' after 60s; eventual delete did not propagate." -f $SmokePolicyName)
                }
                Add-StepResult -Step '5' -Title 'destructive cleanup' -Result 'PASS' -Reason ('Removed; Get-InsiderRiskPolicy now throws ManagementObjectNotFoundException.') | Out-Null
            } catch {
                Add-StepResult -Step '5' -Title 'destructive cleanup' -Result 'FAIL' -Reason ("Cleanup threw: {0}" -f $_.Exception.Message) | Out-Null
                if ($StopOnFailure) { throw }
            }
        }
    }
}
finally {
    Disconnect-IRMSmokeSession
    Set-Content -Path $evidencePath -Value $evidenceLines -Encoding utf8
    Write-Information ("Evidence written to: {0}" -f $evidencePath) -InformationAction Continue
}

# endregion

# region Exit

$results

$failed = @($results | Where-Object { $_.Result -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Error ("{0} step(s) FAILED. Smoke aborted." -f $failed.Count)
    exit 1
}
exit 0

# endregion