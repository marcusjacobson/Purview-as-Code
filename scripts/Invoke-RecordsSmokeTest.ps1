#Requires -Version 7.4

<#
.SYNOPSIS
    Near-unattended wrapper around docs/runbooks/records-end-to-end-smoke.md
    for capturing v2 section 5.3 Records Management evidence in one command.

.DESCRIPTION
    Executes Steps 1-10 of the operator-driven Records Management
    end-to-end smoke runbook against the live contoso.onmicrosoft.com tenant,
    prompts for explicit confirmation before the two destructive
    steps (Step 8 -PruneMissing on the smoke label, Step 9 -PruneMissing
    on the smoke category), and writes a timestamped Markdown evidence
    file under .copilot-tracking/smoke/records-<UTC>.md that the operator
    pastes verbatim into the v2 section 5.3 close-out PR (and any future PR
    that re-enters the build loop on the Records Management reconciler).

    Wraps the existing runbook one-for-one; introduces no new auth path
    and no new Microsoft Purview / IPPS cmdlet beyond what the runbook
    already documents. All tenant interaction flows through
    scripts/Deploy-FilePlan.ps1 with the operator's Az / Key Vault
    session.

    Safety model (matches the runbook's "Safety constraints" block):

      - Aborts on any local edit under data-plane/records/** before
        Step 1 starts (the wrapper relies on git checkout to revert
        its own transient YAML edits between phases; a pre-existing
        edit would be silently discarded).
      - Performs each runbook YAML edit in-place against
        data-plane/records/file-plan.yaml, runs the step, and reverts
        via `git checkout --` between phases so the working tree is
        always clean at step boundaries.
      - Prompts the operator for y/yes/confirm before the two
        destructive -PruneMissing steps. Any other answer aborts the
        wrapper and reverts the YAML.
      - Never sets isRecordLabel: true except in Step 6 (DriftWarn
        smoke), which never applies and reverts immediately.
      - Never invokes -PruneMissing without -SkipNames carrying the
        29-name seed list from docs/adr/0035-records-seed-content-immovable.md.

    AI agents (e.g. the @artifact-resolver flow described in
    .github/copilot-instructions.md and the runbook front-matter) must
    not execute this wrapper. The wrapper is operator-launched per the
    mcp-tool-usage policy in .github/instructions/mcp-tool-usage.instructions.md;
    the agent's role is restricted to consuming the evidence file the
    wrapper produces.

    References:
      - https://learn.microsoft.com/en-us/purview/records-management
      - https://learn.microsoft.com/en-us/purview/file-plan-manager
      - https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag
      - https://learn.microsoft.com/en-us/powershell/module/exchange/get-fileplanpropertyauthority

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of $PSScriptRoot.
    Used to scope git status checks and to anchor relative paths.

.PARAMETER YamlPath
    Path to the desired-state YAML the wrapper drives. Defaults to
    data-plane/records/file-plan.yaml under -RepoRoot. The wrapper
    requires this file to be clean (no staged or working-tree edits)
    before Step 1.

.PARAMETER EvidenceDirectory
    Directory under which the wrapper writes the Markdown evidence
    file. Defaults to .copilot-tracking/smoke/ under -RepoRoot.
    The .copilot-tracking/ folder is gitignored at the repo root; the
    wrapper refuses to write outside that umbrella.

.PARAMETER CategoryName
    Name of the synthetic file plan category created and torn down
    end-to-end. Defaults to lab-fp-cat-smoke-001 per the runbook's
    "Pick a synthetic naming pattern now" section. Must start with
    'lab-fp-' to keep accidental real-content collisions impossible.

.PARAMETER LabelName
    Name of the synthetic retention label created and torn down
    end-to-end. Defaults to lab-fp-label-smoke-001. Must start with
    'lab-fp-' (same reason as -CategoryName).

.PARAMETER DeployFilePlanScript
    Path to scripts/Deploy-FilePlan.ps1. Defaults to the sibling under
    $PSScriptRoot. Override only for fixture testing.

.PARAMETER SkipDestructiveConfirmation
    Skip the operator y/n prompts before Step 8 and Step 9. Reserved
    for fully-automated re-runs after a clean dry-run; default off so
    the runbook's safety stance is preserved on first invocation.
    The wrapper still aborts on any -StopOnFailure trip earlier in the
    flow.

.PARAMETER StopOnFailure
    Abort the wrapper as soon as any step's expected/actual contract
    fails, reverting the YAML before exit. Default on. Disabling this
    is useful only when triaging a tenant that is already in an
    unexpected state -- the evidence file still records every step's
    outcome.

.EXAMPLE
    PS> ./scripts/Invoke-RecordsSmokeTest.ps1

    Run Steps 1-10 end-to-end with default names and confirmation
    prompts. Pastes the evidence file path on success.

.EXAMPLE
    PS> ./scripts/Invoke-RecordsSmokeTest.ps1 -SkipDestructiveConfirmation -WhatIf

    Dry-run plan rows for every step (no tenant writes; -WhatIf is
    propagated through to each Deploy-FilePlan.ps1 invocation).

.NOTES
    Output: a single [pscustomobject] per step on the success stream
    with the fields Step, Title, Result (PASS/FAIL/SKIPPED), Reason,
    PlanRowCount. The full Markdown evidence file is the durable
    artifact; the stream output is for interactive feedback.

    Exit code:
      0  every step PASSED (or was SKIPPED by -WhatIf during a dry-run)
      1  at least one step FAILED, or the operator declined a
         destructive-confirmation prompt
      2  preconditions failed (dirty working tree, missing
         Deploy-FilePlan.ps1, evidence directory outside
         .copilot-tracking/)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param (
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$YamlPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$EvidenceDirectory,

    [Parameter()]
    [ValidatePattern('^lab-fp-[a-z0-9-]{3,40}$')]
    [string]$CategoryName = 'lab-fp-cat-smoke-001',

    [Parameter()]
    [ValidatePattern('^lab-fp-[a-z0-9-]{3,40}$')]
    [string]$LabelName = 'lab-fp-label-smoke-001',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DeployFilePlanScript = (Join-Path $PSScriptRoot 'Deploy-FilePlan.ps1'),

    [Parameter()]
    [switch]$SkipDestructiveConfirmation,

    [Parameter()]
    [bool]$StopOnFailure = $true
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('YamlPath')) {
    $YamlPath = Join-Path $RepoRoot 'data-plane' 'records' 'file-plan.yaml'
}
if (-not $PSBoundParameters.ContainsKey('EvidenceDirectory')) {
    $EvidenceDirectory = Join-Path $RepoRoot '.copilot-tracking' 'smoke'
}

# region Helpers (AST-extractable; covered by tests/scripts/Invoke-RecordsSmokeTest.Tests.ps1)

function Get-RecordsSmokeSeed {
    # The 29-unique-name Microsoft File Plan Manager seed list per
    # docs/adr/0035-records-seed-content-immovable.md (which describes
    # 31 tenant property objects -- Legal and Procurement each appear
    # under two kinds). Treated as a copy-paste regression check by
    # tests/scripts/Invoke-RecordsSmokeTest.Tests.ps1; any drift here
    # must move the ADR table first.
    @(
        'Business', 'Legal', 'Regulatory',
        'Accounts payable', 'Accounts receivable', 'Administration', 'Compliance',
        'Contracting', 'Financial statements', 'Learning and development',
        'Payroll', 'Planning', 'Policies and procedures', 'Procurement',
        'Recruiting and hiring', 'Research and development',
        'Commodity Exchange Act',
        'Health Insurance Portability and Accountability Act of 1996',
        'OSHA Injury and Illness Recordkeeping and Reporting Requirements',
        'Sarbanes-Oxley Act of 2002', 'Truth in Lending Act',
        'Finance', 'Human resources', 'Information technology', 'Marketing',
        'Operations', 'Products', 'Sales', 'Services'
    )
}

function Get-RecordsSmokeYamlTail {
    # Deterministic YAML tail per smoke phase. Returns just the desired
    # state body (filePlanProperties: + retentionLabels:); the wrapper
    # splices this onto everything above the first `filePlanProperties:`
    # line of the on-disk YAML so the long header comment is preserved.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Empty', 'CategoryOnly', 'CategoryAndLabel', 'CategoryAndLabelEdited', 'CategoryAndLabelImmutable')]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^lab-fp-[a-z0-9-]{3,40}$')]
        [string]$CategoryName,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^lab-fp-[a-z0-9-]{3,40}$')]
        [string]$LabelName
    )

    $catBlock = switch ($Phase) {
        'Empty'                          { '  categories: []' }
        default                          { "  categories:`n    - name: $CategoryName" }
    }

    $labelBlock = switch ($Phase) {
        'CategoryAndLabel'               { @"
retentionLabels:
  - name: $LabelName
    description: 'E2E smoke test for Records Management reconciler. Safe to delete.'
    isRecordLabel: false
    retentionDuration: 30
    retentionAction: Keep
    retentionType: ModificationAgeInDays
    filePlanProperty:
      category: $CategoryName
"@ }
        'CategoryAndLabelEdited'         { @"
retentionLabels:
  - name: $LabelName
    description: 'E2E smoke test for Records Management reconciler. Safe to delete.'
    isRecordLabel: false
    retentionDuration: 60
    retentionAction: Keep
    retentionType: ModificationAgeInDays
    filePlanProperty:
      category: $CategoryName
"@ }
        'CategoryAndLabelImmutable'      { @"
retentionLabels:
  - name: $LabelName
    description: 'E2E smoke test for Records Management reconciler. Safe to delete.'
    isRecordLabel: true
    retentionDuration: 60
    retentionAction: Keep
    retentionType: ModificationAgeInDays
    filePlanProperty:
      category: $CategoryName
"@ }
        default                          { 'retentionLabels: []' }
    }

    @"
filePlanProperties:
  authorities: []
$catBlock
  citations: []
  departments: []
  referenceIds: []
  subCategories: []

$labelBlock
"@
}

function Set-RecordsYamlFile {
    # Splice the given tail onto the on-disk YAML, preserving every
    # line before the first `filePlanProperties:` (i.e. the long header
    # comment). Writes UTF-8 without BOM per data-plane-yaml conventions.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$YamlPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Tail
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw ("YAML file not found: {0}" -f $YamlPath)
    }

    $lines = Get-Content -LiteralPath $YamlPath
    $anchor = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^filePlanProperties:\s*$') { $anchor = $i; break }
    }
    if ($anchor -lt 0) {
        throw ('Could not locate filePlanProperties: anchor in {0}' -f $YamlPath)
    }

    $header = if ($anchor -gt 0) { ($lines[0..($anchor - 1)] -join "`n") + "`n" } else { '' }
    $tailNormalized = $Tail.TrimEnd("`r", "`n") + "`n"
    $content = $header + $tailNormalized

    if ($PSCmdlet.ShouldProcess($YamlPath, 'Splice records YAML tail')) {
        [System.IO.File]::WriteAllText(
            $YamlPath,
            $content,
            [System.Text.UTF8Encoding]::new($false))
    }
}

function Reset-RecordsYamlFile {
    # Reverts the YAML to its committed state via `git checkout --`.
    # Run between phases so subsequent edits build on clean head, and
    # always on wrapper exit (success or failure).
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$YamlPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot
    )

    if ($PSCmdlet.ShouldProcess($YamlPath, 'git checkout --')) {
        Push-Location -LiteralPath $RepoRoot
        try {
            $null = & git checkout -- $YamlPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("git checkout failed for {0}; exit {1}" -f $YamlPath, $LASTEXITCODE)
            }
        } finally {
            Pop-Location
        }
    }
}

function Assert-CleanRecordsTree {
    # Refuse to start if the operator has any working-tree or staged
    # edits under data-plane/records/. The wrapper revert path is a
    # git checkout, which would silently discard such edits.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot
    )

    Push-Location -LiteralPath $RepoRoot
    try {
        $statusLines = & git status --short -- 'data-plane/records' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("git status failed in {0}; exit {1}" -f $RepoRoot, $LASTEXITCODE)
        }
        $statusLines = @($statusLines | Where-Object { $_ -and $_.Trim() })
        if ($statusLines.Count -gt 0) {
            throw ("data-plane/records/ has uncommitted edits; commit or stash before running:`n{0}" -f ($statusLines -join "`n"))
        }
    } finally {
        Pop-Location
    }
}

function Read-DestructiveConfirmation {
    # Prompt the operator. Returns $true only on an exact-match
    # affirmative (y / yes / confirm, case-insensitive). Any other
    # input -- including Enter, n, abort, secrets -- returns $false.
    # Never call Read-Host for secret input; this prompt is for a
    # workflow gate only.
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    $answer = Read-Host -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $false }
    return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes', 'confirm'))
}

function Test-StepExpectation {
    # Pure assertion: given the plan rows from one Deploy-FilePlan.ps1
    # invocation and an expected-shape hashtable, return PASS / FAIL
    # plus a one-line diagnostic. Operator never reads this -- the
    # evidence file does.
    #
    # Expected hashtable schema:
    #   CategoryCounts = @{ Create=0; Update=0; NoChange=0; Orphan=0;
    #                       Removed=0; DriftWarn=0; Skipped=29 or omitted }
    #   ContainsRow    = @( @{ Category='Create'; Kind='Category'; Name='lab-fp-cat-smoke-001' }, ... )
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        $PlanRows,

        [Parameter(Mandatory = $true)]
        [hashtable]$Expected
    )

    $rows = @($PlanRows | Where-Object { $_ -and $_.PSObject.Properties['Category'] })
    $issues = New-Object System.Collections.Generic.List[string]

    if ($Expected.ContainsKey('CategoryCounts')) {
        foreach ($pair in $Expected.CategoryCounts.GetEnumerator()) {
            $actual = @($rows | Where-Object Category -eq $pair.Key).Count
            if ($actual -ne $pair.Value) {
                $issues.Add(("Category={0}: expected={1} actual={2}" -f $pair.Key, $pair.Value, $actual))
            }
        }
    }

    if ($Expected.ContainsKey('ContainsRow')) {
        foreach ($needle in $Expected.ContainsRow) {
            $match = $rows | Where-Object {
                $_.Category -eq $needle.Category -and
                $_.Kind     -eq $needle.Kind     -and
                $_.Name     -eq $needle.Name
            } | Select-Object -First 1
            if (-not $match) {
                $issues.Add(("Missing row: Category={0} Kind={1} Name={2}" -f $needle.Category, $needle.Kind, $needle.Name))
            }
        }
    }

    if ($issues.Count -eq 0) {
        return [pscustomobject]@{ Result = 'PASS'; Reason = '' }
    }
    return [pscustomobject]@{ Result = 'FAIL'; Reason = ($issues -join '; ') }
}

function New-StepRecord {
    # Factory for the per-step pscustomobject the wrapper emits on the
    # success stream and folds into the evidence file. Pure data factory;
    # the 'New' verb is required for evidence-file readability and triggers
    # a false-positive on PSUseShouldProcessForStateChangingFunctions.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$Step,
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $true)] [ValidateSet('PASS', 'FAIL', 'SKIPPED', 'ABORTED')] [string]$Result,
        [Parameter()] [string]$Reason = '',
        [Parameter()] [AllowNull()] [AllowEmptyCollection()] $PlanRows = @(),
        [Parameter()] [string]$Command = ''
    )
    [pscustomobject]@{
        Step         = $Step
        Title        = $Title
        Result       = $Result
        Reason       = $Reason
        PlanRows     = @($PlanRows)
        PlanRowCount = @($PlanRows).Count
        Command      = $Command
    }
}

function Get-EvidenceFilePath {
    # Build the .copilot-tracking/smoke/records-<UTC>.md path. Refuses
    # any directory outside .copilot-tracking/ (the gitignore umbrella).
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EvidenceDirectory,

        [Parameter()]
        [datetime]$Timestamp = [datetime]::UtcNow
    )

    if ($EvidenceDirectory -notmatch '\.copilot-tracking') {
        throw ('Refusing to write evidence outside .copilot-tracking/: {0}' -f $EvidenceDirectory)
    }
    $stamp = $Timestamp.ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    Join-Path $EvidenceDirectory ('records-{0}Z.md' -f $stamp)
}

function Format-RecordsSmokeEvidence {
    # Build the Markdown body for the evidence file. Mirrors the
    # runbook's "Paste evidence into the PR description" step (Step 12).
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [psobject[]]$Steps,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CategoryName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LabelName,

        [Parameter()]
        [datetime]$Timestamp = [datetime]::UtcNow
    )

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Records Management end-to-end smoke evidence')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(('- Generated: {0}' -f $Timestamp.ToString('yyyy-MM-ddTHH:mm:ssZ')))
    [void]$sb.AppendLine(('- Category : `{0}`' -f $CategoryName))
    [void]$sb.AppendLine(('- Label    : `{0}`' -f $LabelName))
    [void]$sb.AppendLine('- Runbook  : [`docs/runbooks/records-end-to-end-smoke.md`](../../docs/runbooks/records-end-to-end-smoke.md)')
    [void]$sb.AppendLine('- Wrapper  : [`scripts/Invoke-RecordsSmokeTest.ps1`](../../scripts/Invoke-RecordsSmokeTest.ps1)')
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Result summary')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Step | Title | Result | Plan rows |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($s in $Steps) {
        [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} |' -f $s.Step, $s.Title, $s.Result, $s.PlanRowCount))
    }
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Per-step detail')
    [void]$sb.AppendLine()
    foreach ($s in $Steps) {
        [void]$sb.AppendLine(('### {0} {1}' -f $s.Step, $s.Title))
        [void]$sb.AppendLine()
        [void]$sb.AppendLine(('- Result: **{0}**' -f $s.Result))
        if ($s.Reason) {
            [void]$sb.AppendLine(('- Reason: {0}' -f $s.Reason))
        }
        if ($s.Command) {
            [void]$sb.AppendLine('- Command:')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('  ```pwsh')
            [void]$sb.AppendLine(('  {0}' -f $s.Command))
            [void]$sb.AppendLine('  ```')
        }
        if ($s.PlanRowCount -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('  Plan rows:')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('  | Category | Kind | Name | Reason |')
            [void]$sb.AppendLine('  |---|---|---|---|')
            foreach ($r in $s.PlanRows) {
                $cat = if ($r.PSObject.Properties['Category']) { [string]$r.Category } else { '' }
                $knd = if ($r.PSObject.Properties['Kind'])     { [string]$r.Kind }     else { '' }
                $nme = if ($r.PSObject.Properties['Name'])     { [string]$r.Name }     else { '' }
                $rsn = if ($r.PSObject.Properties['Reason'])   { [string]$r.Reason }   else { '' }
                $rsn = ($rsn -replace '\|', '\|' -replace '\r?\n', ' ')
                [void]$sb.AppendLine(('  | {0} | {1} | {2} | {3} |' -f $cat, $knd, $nme, $rsn))
            }
        }
        [void]$sb.AppendLine()
    }

    $sb.ToString()
}

# endregion

# region Step runner (top-level orchestrator -- not AST-extracted)

function Invoke-RecordsSmokeStep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [string]$Step,
        [Parameter(Mandatory = $true)] [string]$Title,
        [Parameter(Mandatory = $true)] [hashtable]$DeployArgs,
        [Parameter(Mandatory = $true)] [hashtable]$Expected,
        [Parameter(Mandatory = $true)] [string]$DeployFilePlanScript
    )

    $cmd = "Deploy-FilePlan.ps1 " + (($DeployArgs.GetEnumerator() | ForEach-Object {
        if ($_.Value -is [switch] -or $_.Value -is [bool]) { "-$($_.Key)" }
        elseif ($_.Value -is [array])                       { "-$($_.Key) @(...)" }
        else                                                { "-$($_.Key) '$($_.Value)'" }
    }) -join ' ')

    Write-Information ('--- {0} {1}' -f $Step, $Title) -InformationAction Continue
    Write-Information ('    {0}' -f $cmd) -InformationAction Continue

    $rawOutput = & $DeployFilePlanScript @DeployArgs 6>&1
    $planRows = @($rawOutput | Where-Object {
        $_ -is [pscustomobject] -and $_.PSObject.Properties['Category'] -and $_.PSObject.Properties['Kind']
    })

    $verdict = Test-StepExpectation -PlanRows $planRows -Expected $Expected
    $reasonText = $verdict.Reason

    Write-Information ('    {0}: {1} ({2} plan rows)' -f $verdict.Result, $reasonText, $planRows.Count) -InformationAction Continue

    New-StepRecord -Step $Step -Title $Title -Result $verdict.Result `
        -Reason $reasonText -PlanRows $planRows -Command $cmd
}

# endregion

# region Top-level execution

try {
    Write-Information ('Records E2E smoke wrapper starting against {0}' -f $YamlPath) -InformationAction Continue
    Write-Information ('Evidence will land at {0}' -f $EvidenceDirectory) -InformationAction Continue
    Write-Information '' -InformationAction Continue

    if (-not (Test-Path -LiteralPath $DeployFilePlanScript)) {
        Write-Error ('Deploy-FilePlan.ps1 not found at {0}' -f $DeployFilePlanScript)
        exit 2
    }
    if (-not (Test-Path -LiteralPath $YamlPath)) {
        Write-Error ('YAML not found at {0}' -f $YamlPath)
        exit 2
    }

    try {
        Assert-CleanRecordsTree -RepoRoot $RepoRoot
    } catch {
        Write-Error ('Precondition failed: {0}' -f $_.Exception.Message)
        exit 2
    }

    if (-not (Test-Path -LiteralPath $EvidenceDirectory)) {
        $null = New-Item -ItemType Directory -Path $EvidenceDirectory -Force
    }

    $seeds = Get-RecordsSmokeSeed
    Write-Information ('Loaded {0} seed names from Get-RecordsSmokeSeed' -f $seeds.Count) -InformationAction Continue
    Write-Information '' -InformationAction Continue

    $steps = New-Object System.Collections.Generic.List[psobject]
    $aborted = $false

    function Add-Step {
        param([psobject]$Record)
        $steps.Add($Record) | Out-Null
        if ($Record.Result -eq 'FAIL' -and $StopOnFailure) {
            throw ('StopOnFailure: step {0} failed: {1}' -f $Record.Step, $Record.Reason)
        }
    }

    $baseArgs = @{
        DirectionPolicy = 'portal-wins'
        SkipNames       = $seeds
    }

    # --- Step 1: baseline confirmation -----------------------------------
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '1' -Title 'Baseline confirmation' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ CategoryCounts = @{ Skipped = 31; Orphan = 0; Create = 0; Update = 0; Removed = 0 } } `
        -DeployFilePlanScript $DeployFilePlanScript)

    # --- Step 2: create category (Create path) ---------------------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '2a' -Title 'Create category (-WhatIf)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'WhatIf'; Kind = 'Category'; Name = $CategoryName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)
    if (-not $WhatIfPreference) {
        Add-Step (Invoke-RecordsSmokeStep `
            -Step '2b' -Title 'Create category (apply)' `
            -DeployArgs $baseArgs `
            -Expected @{ ContainsRow = @( @{ Category = 'Create'; Kind = 'Category'; Name = $CategoryName } ) } `
            -DeployFilePlanScript $DeployFilePlanScript)
    }

    # --- Step 3: create label bound to category --------------------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryAndLabel -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '3a' -Title 'Create label (-WhatIf)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{
            ContainsRow = @(
                @{ Category = 'WhatIf';   Kind = 'Label';    Name = $LabelName },
                @{ Category = 'NoChange'; Kind = 'Category'; Name = $CategoryName }
            )
        } `
        -DeployFilePlanScript $DeployFilePlanScript)
    if (-not $WhatIfPreference) {
        Add-Step (Invoke-RecordsSmokeStep `
            -Step '3b' -Title 'Create label (apply)' `
            -DeployArgs $baseArgs `
            -Expected @{ ContainsRow = @( @{ Category = 'Create'; Kind = 'Label'; Name = $LabelName } ) } `
            -DeployFilePlanScript $DeployFilePlanScript)
    }

    # --- Step 4: idempotency check ---------------------------------------
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '4' -Title 'Idempotency check (-WhatIf, no edits)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{
            ContainsRow = @(
                @{ Category = 'NoChange'; Kind = 'Category'; Name = $CategoryName },
                @{ Category = 'NoChange'; Kind = 'Label';    Name = $LabelName }
            )
            CategoryCounts = @{ Create = 0; Update = 0; WhatIf = 0 }
        } `
        -DeployFilePlanScript $DeployFilePlanScript)

    # --- Step 5: edit retentionDuration (Update path) --------------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryAndLabelEdited -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '5a' -Title 'Edit label retentionDuration (-WhatIf)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'WhatIf'; Kind = 'Label'; Name = $LabelName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)
    if (-not $WhatIfPreference) {
        Add-Step (Invoke-RecordsSmokeStep `
            -Step '5b' -Title 'Edit label retentionDuration (apply)' `
            -DeployArgs $baseArgs `
            -Expected @{ ContainsRow = @( @{ Category = 'Update'; Kind = 'Label'; Name = $LabelName } ) } `
            -DeployFilePlanScript $DeployFilePlanScript)
    }

    # --- Step 6: DriftWarn smoke (do not apply) --------------------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryAndLabelImmutable -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '6' -Title 'DriftWarn smoke (-WhatIf; never apply)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'DriftWarn'; Kind = 'Label'; Name = $LabelName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)
    # Revert the isRecordLabel flip and re-author the edited-state YAML
    Reset-RecordsYamlFile -YamlPath $YamlPath -RepoRoot $RepoRoot
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryAndLabelEdited -CategoryName $CategoryName -LabelName $LabelName)

    # --- Step 7: orphan no-op (remove label from YAML) -------------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase CategoryOnly -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '7' -Title 'Orphan label (no -PruneMissing)' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'Orphan'; Kind = 'Label'; Name = $LabelName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)

    # --- Step 8: -PruneMissing the label (DESTRUCTIVE) -------------------
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '8a' -Title 'Prune label (-PruneMissing -WhatIf)' `
        -DeployArgs ($baseArgs + @{ PruneMissing = $true; WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'WhatIf'; Kind = 'Label'; Name = $LabelName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)

    if (-not $WhatIfPreference) {
        $confirmed = $SkipDestructiveConfirmation -or `
            (Read-DestructiveConfirmation -Prompt ("Step 8 will Remove-ComplianceTag '{0}'. Type 'yes' to proceed" -f $LabelName))
        if (-not $confirmed) {
            Add-Step (New-StepRecord -Step '8b' -Title 'Prune label (apply)' -Result 'ABORTED' -Reason 'Operator declined confirmation')
            throw 'Operator aborted at Step 8 destructive-confirmation gate'
        }
        Add-Step (Invoke-RecordsSmokeStep `
            -Step '8b' -Title 'Prune label (apply)' `
            -DeployArgs ($baseArgs + @{ PruneMissing = $true }) `
            -Expected @{ ContainsRow = @( @{ Category = 'Removed'; Kind = 'Label'; Name = $LabelName } ) } `
            -DeployFilePlanScript $DeployFilePlanScript)
    }

    # --- Step 9: -PruneMissing the category (DESTRUCTIVE) ----------------
    Set-RecordsYamlFile -YamlPath $YamlPath `
        -Tail (Get-RecordsSmokeYamlTail -Phase Empty -CategoryName $CategoryName -LabelName $LabelName)
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '9a' -Title 'Prune category (-PruneMissing -WhatIf)' `
        -DeployArgs ($baseArgs + @{ PruneMissing = $true; WhatIf = $true }) `
        -Expected @{ ContainsRow = @( @{ Category = 'WhatIf'; Kind = 'Category'; Name = $CategoryName } ) } `
        -DeployFilePlanScript $DeployFilePlanScript)

    if (-not $WhatIfPreference) {
        $confirmed = $SkipDestructiveConfirmation -or `
            (Read-DestructiveConfirmation -Prompt ("Step 9 will Remove-FilePlanPropertyCategory '{0}'. Type 'yes' to proceed" -f $CategoryName))
        if (-not $confirmed) {
            Add-Step (New-StepRecord -Step '9b' -Title 'Prune category (apply)' -Result 'ABORTED' -Reason 'Operator declined confirmation')
            throw 'Operator aborted at Step 9 destructive-confirmation gate'
        }
        Add-Step (Invoke-RecordsSmokeStep `
            -Step '9b' -Title 'Prune category (apply)' `
            -DeployArgs ($baseArgs + @{ PruneMissing = $true }) `
            -Expected @{ ContainsRow = @( @{ Category = 'Removed'; Kind = 'Category'; Name = $CategoryName } ) } `
            -DeployFilePlanScript $DeployFilePlanScript)
    }

    # --- Step 10: final baseline confirmation ----------------------------
    Add-Step (Invoke-RecordsSmokeStep `
        -Step '10' -Title 'Final baseline confirmation' `
        -DeployArgs ($baseArgs + @{ WhatIf = $true }) `
        -Expected @{ CategoryCounts = @{ Skipped = 31; Orphan = 0; Create = 0; Update = 0; Removed = 0 } } `
        -DeployFilePlanScript $DeployFilePlanScript)

} catch {
    $aborted = $true
    Write-Warning ('Wrapper aborted: {0}' -f $_.Exception.Message)
} finally {
    try {
        Reset-RecordsYamlFile -YamlPath $YamlPath -RepoRoot $RepoRoot -Confirm:$false
    } catch {
        Write-Warning ('YAML revert failed during teardown: {0}' -f $_.Exception.Message)
    }
}

# Step 11 (disconnect) is intentionally left to the operator -- the IPPS
# session lifetime is owned by the Deploy-FilePlan.ps1 invocations, and
# this wrapper does not hold onto a session of its own to tear down.

# Step 12: emit the evidence file
$timestamp = [datetime]::UtcNow
$evidencePath = Get-EvidenceFilePath -EvidenceDirectory $EvidenceDirectory -Timestamp $timestamp
$evidenceBody = Format-RecordsSmokeEvidence -Steps $steps `
    -CategoryName $CategoryName -LabelName $LabelName -Timestamp $timestamp
[System.IO.File]::WriteAllText($evidencePath, $evidenceBody, [System.Text.UTF8Encoding]::new($false))
Write-Information '' -InformationAction Continue
Write-Information ('Evidence written to: {0}' -f $evidencePath) -InformationAction Continue

# Surface per-step records on the success stream for piping / inspection
$steps | Select-Object Step, Title, Result, Reason, PlanRowCount

$failed = @($steps | Where-Object { $_.Result -in @('FAIL', 'ABORTED') })
if ($aborted -or $failed.Count -gt 0) { exit 1 }
exit 0

# endregion
