#Requires -Version 7.4
<#
.SYNOPSIS
    Local, operator-run drift-back sync for the Insider Risk Management
    (IRM) policy surface on a governance-locked tenant (ADR 0060).

.DESCRIPTION
    `sync-irm-from-tenant.yml`'s scheduled run is a preflight no-op on
    lab: `vars.CI_DATA_PLANE_ENABLED = 'false'` (set 2026-08-16, ADR 0060,
    because lab's Key Vault governance policy blocks the workflow's
    temporary public-network-access step). `deploy-irm.yml` carries no
    such gate, so every qualifying push to lab still runs and still dies
    at the first Key Vault certificate read. The only path that reaches
    lab's tenant today is a local run using the ADR 0028 local-certificate
    transport, which never touches Key Vault at all.

    The CI reverse leg for this surface opens a GitHub **issue** rather
    than a pull request, so there is no workflow whose PR this script
    reproduces. It owns its own PR shape (see -SyncBranch), and delivers
    the outcome that issue asks an operator to reach by hand: the repo
    regains source-of-truth over the tenant's live policy set.

      1. Verifies `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` is set (ADR 0028)
         and that the current `az` context's tenant matches the
         parameters file's `automation.tenantDomain` (the "#41 incident"
         wrong-tenant trap -- an inherited env var pointed a run at the
         wrong subscription with no error until the tenant call landed).
      2. Verifies the target branch maps to the parameters file's
         `environment` per ADR 0057 (dev -> dev, everything else -> lab).
      3. Runs `Deploy-IRMPolicies.ps1 -ExportCurrentState -Force` (or,
         under `-AuditOnly`, `-DirectionPolicy audit -WhatIf`) against a
         detached git worktree checked out from `<remote>/<BaseBranch>` --
         the operator's own working-tree checkout is never touched.
      4. Classifies the resulting diff via `Test-ExportDiffMeaningful`
         (scripts/modules/ExportDiffFilter.psm1, shared with the sibling
         sync workflows) and, if meaningful, commits, pushes, and opens or
         updates a PR via `gh api` REST calls -- never `gh pr create` /
         `gh pr edit`, both of which fail on this repo's token with a
         bogus "Head sha can't be blank" GraphQL error.
      5. Writes a JSON audit record (schema v1, no tenant identifiers) so
         the operations console can show the last local audit result per
         environment without ever calling the tenant itself.

    `-WhatIf` runs steps 1-3 and prints the diff / summary; it never
    commits, pushes, or opens a PR. `-AuditOnly` runs a read-only
    `-DirectionPolicy audit -WhatIf` pass instead of an export -- use it
    to read the drift rows, including any `Blocked` row, which reports an
    immutable `scenario` difference that no export and no apply can
    resolve. The export path is otherwise safe to run on this surface:
    it skips the system-managed `IRM_Tenant_Setting_*` policies (ADR
    0036), and the four `IRM Lab -- *` skip-baseline names have been
    codified in the tracked YAML since #187, so the ADR 0036 baseline no
    longer hides anything from the round-trip.

    References:
      ADR 0028: docs/adr/0028-co-equal-local-cert-credential.md
      ADR 0036: docs/adr/0036-irm-tenant-setting-immovable.md
      ADR 0057: docs/adr/0057-multi-environment-and-branch-model.md
      ADR 0060: docs/adr/0060-governance-locked-kv-local-cert-apply.md
      .github/workflows/sync-irm-from-tenant.yml
      docs/runbooks/irm-local-drift-sync.md

.PARAMETER ParametersFile
    Path to the environment parameters file. Defaults to
    $env:PURVIEW_PARAMETERS_FILE, then infra/parameters/lab.yaml.

.PARAMETER BaseBranch
    Branch to sync against (checked out from <Remote>/<BaseBranch> into a
    detached worktree). Defaults to the current branch.

.PARAMETER SyncBranch
    Name of the drift-back branch. Defaults to
    auto/irm-drift-sync-<environment>. Unlike the DLP equivalent, this
    name matches no CI workflow: sync-irm-from-tenant.yml opens an issue,
    not a PR, so this script owns the PR shape outright. It is
    deliberately distinct from deploy-irm.yml's
    auto/irm-portal-wins-drift-<environment>, which that workflow's
    push-time re-export produces -- two different producers must never
    share one branch.

.PARAMETER Remote
    Git remote to fetch/push against. Defaults to 'origin'.

.PARAMETER AuditOnly
    Run a read-only -DirectionPolicy audit -WhatIf pass instead of
    -ExportCurrentState. No commit, push, or PR in either case; this
    switch changes what Deploy-IRMPolicies.ps1 is asked to do, not whether
    ShouldProcess gates anything.

.PARAMETER AuditRecordPath
    Path to write the JSON audit record. Defaults to
    <repo>/.copilot-tracking/audit/irm-<environment>.json (gitignored).
    Overridable via $env:PURVIEW_AUDIT_RECORD_ROOT (a directory; the file
    name is still irm-<environment>.json).

.PARAMETER NoAuditRecord
    Skip writing the audit record.

.EXAMPLE
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT = '<lab cert thumbprint>'
    $env:PURVIEW_PARAMETERS_FILE = 'infra/parameters/lab.yaml'
    ./scripts/Invoke-LocalIrmDriftSync.ps1 -AuditOnly -WhatIf

    Read-only audit against lab; prints the plan, writes an audit record,
    commits/pushes/opens nothing.

.EXAMPLE
    ./scripts/Invoke-LocalIrmDriftSync.ps1

    Full local drift-sync against the current branch's tenant: export,
    classify, and (if meaningful) commit + push + open/update the
    drift-back PR.

.NOTES
    Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/ps101/10-script-modules
    Reference: https://cli.github.com/manual/gh_api
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ParametersFile,

    [string]$BaseBranch,

    [string]$SyncBranch,

    [string]$Remote = 'origin',

    [switch]$AuditOnly,

    [string]$AuditRecordPath,

    [switch]$NoAuditRecord
)

$ErrorActionPreference = 'Stop'

#region Pure helpers (unit-tested by AST extraction in
#        tests/scripts/Invoke-LocalIrmDriftSync.Tests.ps1 -- no az/gh/git
#        calls in this region, so every function here is directly
#        testable against synthetic inputs).

function Get-ExpectedEnvironmentForBranch {
    <#
    .SYNOPSIS
        ADR 0057's branch -> environment mapping: dev -> dev, everything
        else (lab, main, a feature branch, ...) -> lab.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Branch
    )
    if ($Branch -eq 'dev') { return 'dev' }
    return 'lab'
}

function Test-TenantDomainMatch {
    <#
    .SYNOPSIS
        Returns $true if the current az context's tenant ID resolves (via
        the ARM /tenants list) to a tenant whose defaultDomain or domains[]
        contains ExpectedDomain, case-insensitively.

    .DESCRIPTION
        Pure over its inputs -- the caller is responsible for producing
        $Tenants from `az rest --url https://management.azure.com/tenants?api-version=2022-12-01`
        and $CurrentTenantId from `az account show`. This is the #41
        incident guard: an inherited $env:PURVIEW_PARAMETERS_FILE / az
        context mismatch pointed a run at the wrong subscription with no
        error until the tenant call itself failed or, worse, silently
        succeeded against the wrong tenant.

    .PARAMETER Tenants
        Array of objects (or hashtables) each with at least tenantId,
        defaultDomain, and domains (array of string).

    .PARAMETER CurrentTenantId
        The tenantId from `az account show`.

    .PARAMETER ExpectedDomain
        The parameters file's automation.tenantDomain value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tenants,
        [Parameter(Mandatory = $true)][string]$CurrentTenantId,
        [Parameter(Mandatory = $true)][string]$ExpectedDomain
    )
    $match = $Tenants | Where-Object { [string]$_.tenantId -ieq $CurrentTenantId }
    if (-not $match) { return $false }
    foreach ($tenant in @($match)) {
        if ([string]$tenant.defaultDomain -ieq $ExpectedDomain) { return $true }
        foreach ($domain in @($tenant.domains)) {
            if ([string]$domain -ieq $ExpectedDomain) { return $true }
        }
    }
    return $false
}

function ConvertFrom-IrmInformationCount {
    <#
    .SYNOPSIS
        Parses Deploy-IRMPolicies.ps1's two Write-Information count lines
        ("Desired policies: N", "Tenant policies : N") out of its
        captured -InformationVariable.

    .PARAMETER Lines
        The captured information records, coerced to strings by the
        caller (e.g. `$iv | ForEach-Object { $_.MessageData }`).

    .OUTPUTS
        [pscustomobject] with DesiredPolicies / TenantPolicies, each
        [int] or $null if the line was not present (e.g. audit mode's
        early short-circuit skips the tenant-side line when the script
        errors before reaching it). This surface has no rules, so there
        is no third count line to parse.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines
    )
    $result = [pscustomobject]@{
        DesiredPolicies = $null
        TenantPolicies  = $null
    }
    foreach ($line in $Lines) {
        if ($line -match '^\s*Desired policies\s*:\s*(\d+)\s*$') {
            $result.DesiredPolicies = [int]$Matches[1]
        } elseif ($line -match '^\s*Tenant policies\s*:\s*(\d+)\s*$') {
            $result.TenantPolicies = [int]$Matches[1]
        }
    }
    return $result
}

function ConvertTo-IrmAuditRecord {
    <#
    .SYNOPSIS
        Builds the JSON-serializable audit record written to
        .copilot-tracking/audit/irm-<environment>.json.

    .DESCRIPTION
        Schema v1. Deliberately carries no tenant identifiers (tenant ID,
        tenant domain, subscription ID, app ID) -- only environment name,
        branch/commit, counts, and drift-row summaries, none of which are
        secrets. `Rows` is always wrapped with @(...) so it serializes as
        a JSON array at 0, 1, or N entries (the #132 lesson: a bare
        single-element PowerShell collection can unroll to a scalar on
        return/pipeline emission, though a property assignment inside a
        pscustomobject literal, as here, does not hit that path).

    .PARAMETER Rows
        Category/Kind/Name/Reason rows built from Deploy-IRMPolicies.ps1's
        pipeline output (audit mode only; empty in export mode). That
        script emits Category/Name/Reason and no Kind -- this surface has
        exactly one kind of object -- so the caller stamps Kind before
        calling here, keeping the record shape identical to the one the
        operations console already renders for the sibling surface.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Environment,
        [Parameter(Mandatory = $true)][ValidateSet('sync', 'audit')][string]$Mode,
        [Parameter(Mandatory = $true)][bool]$WhatIfMode,
        [Parameter(Mandatory = $true)][datetime]$Timestamp,
        [Parameter(Mandatory = $true)][string]$BaseBranch,
        [Parameter(Mandatory = $true)][string]$BaseCommit,
        [string]$SyncBranch,
        [Parameter(Mandatory = $true)][pscustomobject]$Counts,
        [Parameter(Mandatory = $true)][bool]$DriftDetected,
        [Parameter(Mandatory = $true)][bool]$CosmeticOnly,
        [int]$AddedLines = 0,
        [int]$RemovedLines = 0,
        [AllowNull()][object[]]$Rows,
        [AllowNull()][Nullable[int]]$PrNumber,
        [string]$PrUrl,
        [string]$PrOperation
    )
    $pr = if ($PrNumber) {
        [pscustomobject]@{ number = $PrNumber; url = $PrUrl; operation = $PrOperation }
    } else {
        $null
    }
    return [pscustomobject]@{
        schemaVersion = 1
        surface       = 'irm'
        environment   = $Environment
        mode          = $Mode
        whatIf        = $WhatIfMode
        timestamp     = $Timestamp.ToUniversalTime().ToString('o')
        baseBranch    = $BaseBranch
        baseCommit    = $BaseCommit
        syncBranch    = $SyncBranch
        counts        = [pscustomobject]@{
            desiredPolicies = $Counts.DesiredPolicies
            tenantPolicies  = $Counts.TenantPolicies
        }
        drift         = [pscustomobject]@{
            detected     = $DriftDetected
            cosmeticOnly = $CosmeticOnly
            addedLines   = $AddedLines
            removedLines = $RemovedLines
        }
        rows          = @($Rows)
        pr            = $pr
        tool          = 'Invoke-LocalIrmDriftSync.ps1'
    }
}

function ConvertFrom-GitRemoteUrl {
    <#
    .SYNOPSIS
        Parses {owner}/{repo} out of an `origin` remote URL, HTTPS or SSH.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$RemoteUrl
    )
    $trimmed = $RemoteUrl.Trim()
    $trimmed = $trimmed -replace '\.git$', ''
    if ($trimmed -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+)$') {
        return [pscustomobject]@{ Owner = $Matches['owner']; Repo = $Matches['repo'] }
    }
    throw "Could not parse owner/repo from remote URL: $RemoteUrl"
}

#endregion

#region Impure helpers (git / gh / az child-process wrappers)

function Invoke-ChildProcess {
    <#
    .SYNOPSIS
        Runs an external command as a child process and throws with the
        captured output on a non-zero exit code. Never trusts stdout/exit
        code implicitly (same discipline as Start-OperationsConsole.ps1's
        Invoke-GhApiRaw / Invoke-RepoGit).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkingDirectory
    )
    $prevLocation = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Set-Location -LiteralPath $prevLocation
    }
    # The outer @(...) is load-bearing, not decorative: piping a
    # single-element collection through ForEach-Object and assigning the
    # result WITHOUT @(...) also unrolls to a bare scalar string at this
    # assignment (before `return` is ever reached) whenever the external
    # command produced exactly one line of output. `return , $lines`
    # alone does not fix that -- the comma operator only preserves an
    # array through return when the wrapped value is already a genuine
    # array, not a scalar. Both layers are required together (the #132
    # lesson, hit twice in one function while smoke-testing this script).
    $lines = @(@($output) | ForEach-Object { [string]$_ })
    if ($exitCode -ne 0) {
        throw ("{0} {1} failed (exit {2}): {3}" -f $FilePath, ($ArgumentList -join ' '), $exitCode, ($lines -join "`n"))
    }
    return , $lines
}

function Invoke-GhApiCall {
    <#
    .SYNOPSIS
        Shells `gh api` out as a child process. Never uses `gh pr create`
        / `gh pr edit`, both of which fail on this repo's token with a
        bogus "Head sha can't be blank" GraphQL error.

    .PARAMETER Field
        Raw `key=value` strings, each passed as a separate `-f` argument.
        Supports repeated keys (e.g. multiple `labels[]=<name>` entries),
        which a hashtable parameter cannot represent.

    .PARAMETER FileField
        Raw `key=@path` strings, each passed as a separate `-F` argument
        (used for `body=@<tempfile>` so a multi-line PR body never has to
        survive shell quoting).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [string[]]$Field = @(),
        [string[]]$FileField = @()
    )
    $ghArgs = [System.Collections.Generic.List[string]]::new()
    $ghArgs.Add('api')
    $ghArgs.Add($Path)
    if ($Method -ne 'GET') {
        $ghArgs.Add('-X')
        $ghArgs.Add($Method)
    }
    foreach ($f in $Field) { $ghArgs.Add('-f'); $ghArgs.Add($f) }
    foreach ($f in $FileField) { $ghArgs.Add('-F'); $ghArgs.Add($f) }

    $lines = Invoke-ChildProcess -FilePath 'gh' -ArgumentList $ghArgs.ToArray()
    $text = ($lines -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json -Depth 100)
}

#endregion

#region Main

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

Import-Module (Join-Path $scriptRoot 'modules/ExportDiffFilter.psm1') -Force -Scope Local -ErrorAction Stop

# --- Parameters file resolution (mirrors Deploy-IRMPolicies.ps1) ---
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    throw "Parameters file not found: '$ParametersFile'."
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
Import-Module powershell-yaml -ErrorAction Stop
$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters -or -not $parameters.ContainsKey('environment') -or -not $parameters.ContainsKey('automation') -or
    -not $parameters.automation.ContainsKey('tenantDomain')) {
    throw "Parameters file '$ParametersFile' is missing required keys 'environment' / 'automation.tenantDomain'."
}
$environmentName = [string]$parameters.environment
$expectedTenantDomain = [string]$parameters.automation.tenantDomain

# --- ADR 0028 local-cert requirement ---
if ([string]::IsNullOrWhiteSpace($env:PURVIEW_LOCAL_CERT_THUMBPRINT)) {
    throw "`$env:PURVIEW_LOCAL_CERT_THUMBPRINT is not set. This script requires the ADR 0028 local-certificate transport -- see docs/runbooks/irm-local-drift-sync.md."
}

# --- az context / tenant-match guard (the #41 incident) ---
$accountJson = Invoke-ChildProcess -FilePath 'az' -ArgumentList @('account', 'show', '-o', 'json')
$account = ($accountJson -join "`n") | ConvertFrom-Json -Depth 10
$tenantsJson = Invoke-ChildProcess -FilePath 'az' -ArgumentList @('rest', '--method', 'get', '--url', 'https://management.azure.com/tenants?api-version=2022-12-01')
$tenants = (($tenantsJson -join "`n") | ConvertFrom-Json -Depth 10).value
if (-not (Test-TenantDomainMatch -Tenants $tenants -CurrentTenantId $account.tenantId -ExpectedDomain $expectedTenantDomain)) {
    throw ("The current az context (tenant '{0}', account '{1}') does not resolve to the expected tenant domain '{2}' from '{3}'. Run `az account set --subscription <name>` for the {4} environment first." -f $account.tenantId, $account.name, $expectedTenantDomain, $ParametersFile, $environmentName)
}
Write-Information ("az context OK: {0} -> {1}" -f $account.name, $expectedTenantDomain) -InformationAction Continue

# --- ADR 0057 branch/environment guard ---
if (-not $BaseBranch) {
    $BaseBranch = (Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'rev-parse', '--abbrev-ref', 'HEAD'))[0]
}
$expectedEnvironment = Get-ExpectedEnvironmentForBranch -Branch $BaseBranch
if ($expectedEnvironment -ne $environmentName) {
    throw ("Branch '{0}' maps to environment '{1}' per ADR 0057, but the parameters file declares environment '{2}'. Pass -BaseBranch or -ParametersFile explicitly." -f $BaseBranch, $expectedEnvironment, $environmentName)
}

if (-not $SyncBranch) { $SyncBranch = "auto/irm-drift-sync-$environmentName" }

# --- Worktree setup: the operator's own checkout is never touched ---
Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'fetch', $Remote, $BaseBranch) | Out-Null
$worktreePath = Join-Path ([System.IO.Path]::GetTempPath()) ("irm-drift-sync-{0}-{1}" -f $environmentName, [guid]::NewGuid().ToString('N').Substring(0, 8))
Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'worktree', 'add', '--detach', $worktreePath, "$Remote/$BaseBranch") | Out-Null

try {
    $baseCommit = (Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'rev-parse', 'HEAD'))[0]
    $irmScriptPath = Join-Path $worktreePath 'scripts/Deploy-IRMPolicies.ps1'
    $yamlPath = Join-Path $worktreePath 'data-plane/irm/policies.yaml'
    $mode = if ($AuditOnly.IsPresent) { 'audit' } else { 'sync' }

    $rows = @()
    if ($AuditOnly.IsPresent) {
        $reportRows = & $irmScriptPath -DirectionPolicy audit -WhatIf -Confirm:$false -Path $yamlPath -ParametersFile $ParametersFile -InformationVariable iv 6>$null
        # Deploy-IRMPolicies.ps1's report rows carry Category/Name/Reason
        # but no Kind: unlike the DLP surface there is no second object
        # type to disambiguate. The console's audit panel renders a Kind
        # column for every record, so stamp the only kind this surface
        # has rather than shipping a record whose column is blank.
        $rows = @(@($reportRows) | ForEach-Object {
                [pscustomobject]@{ Category = $_.Category; Kind = 'IRMPolicy'; Name = $_.Name; Reason = $_.Reason }
            })
    } else {
        & $irmScriptPath -ExportCurrentState -Force -Confirm:$false -Path $yamlPath -ParametersFile $ParametersFile -InformationVariable iv 6>$null | Out-Null
    }
    $infoLines = @($iv) | ForEach-Object { [string]$_.MessageData }
    $counts = ConvertFrom-IrmInformationCount -Lines $infoLines
    Write-Information ("Desired policies: {0}  Tenant policies: {1}" -f $counts.DesiredPolicies, $counts.TenantPolicies) -InformationAction Continue

    $diffDetected = $false
    $summary = @{ AddedLines = 0; RemovedLines = 0; MeaningfulLines = 0; CosmeticOnly = $false }
    $prResult = @{ Number = $null; Url = $null; Operation = 'none' }

    if (-not $AuditOnly.IsPresent) {
        $diffText = (Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'diff', '-U0', '--', 'data-plane/irm/policies.yaml')) -join "`n"
        $summary = Get-ExportDiffSummary -DiffText $diffText
        $meaningful = Test-ExportDiffMeaningful -DiffText $diffText

        if (-not $meaningful) {
            Write-Information 'Diff is cosmetic-only or empty. No drift-back PR needed.' -InformationAction Continue
            if (-not [string]::IsNullOrEmpty($diffText)) {
                Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'checkout', 'HEAD', '--', 'data-plane/irm/policies.yaml') | Out-Null
            }
        } else {
            $diffDetected = $true
            Write-Information 'Meaningful drift detected.' -InformationAction Continue

            if ($PSCmdlet.ShouldProcess($SyncBranch, "commit, push, and open/update the drift-back PR against $BaseBranch")) {
                Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'switch', '-C', $SyncBranch) | Out-Null
                Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'add', 'data-plane/irm/policies.yaml') | Out-Null
                $commitMessage = "chore(data-plane): sync IRM policies from tenant`n`nAutomated drift-back from scripts/Invoke-LocalIrmDriftSync.ps1 (ADR 0060).`nRe-exports the live Microsoft Purview Insider Risk Management (IRM)`npolicy set in the $environmentName tenant into`ndata-plane/irm/policies.yaml so the repo remains source of truth."
                Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'commit', '-m', $commitMessage) | Out-Null
                Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'push', '--force-with-lease', $Remote, "HEAD:refs/heads/$SyncBranch") | Out-Null

                $remoteUrl = (Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $worktreePath, 'remote', 'get-url', $Remote))[0]
                $repoInfo = ConvertFrom-GitRemoteUrl -RemoteUrl $remoteUrl
                $repoPath = "repos/$($repoInfo.Owner)/$($repoInfo.Repo)"

                $existing = Invoke-GhApiCall -Path "$repoPath/pulls?state=open&head=$($repoInfo.Owner):$SyncBranch&base=$BaseBranch"
                $bodyText = "Automated drift-back from ``scripts/Invoke-LocalIrmDriftSync.ps1`` (ADR 0060 local reverse-sync for a tenant whose Key Vault governance policy blocks every CI data-plane path).`n`nThe live Microsoft Purview Insider Risk Management (IRM) policy set in the $environmentName tenant no longer matches ``data-plane/irm/policies.yaml``. This PR re-exports the tenant state via ``scripts/Deploy-IRMPolicies.ps1 -ExportCurrentState`` so the repo regains source-of-truth before the next ``deploy-irm.yml`` apply.`n`n``.github/workflows/sync-irm-from-tenant.yml`` watches the same surface but opens an **issue** rather than a pull request, so this PR has no CI counterpart to match. Its branch is also deliberately distinct from ``deploy-irm.yml``'s ``auto/irm-portal-wins-drift-$environmentName``, which that workflow produces from its own push-time re-export.`n`n## Review checklist`n`n- [ ] The diff reflects an intended portal edit. If the portal edit was a mistake, **close this PR** and revert the edit in the Microsoft Purview portal instead.`n- [ ] No ``IRM_Tenant_Setting_*`` row appears in the diff. Those policies are system-managed (ADR 0036) and the exporter excludes them by design, so one appearing here means the export path changed.`n- [ ] Policy names and descriptions carry no real tenant identifiers. The ADR 0055 residue scan is GUID-shaped only, so a UPN, group name, or site URL passes it silently and has to be caught by eye here.`n- [ ] No ``scenario`` value changed. ``InsiderRiskScenario`` is set-once on ``New-InsiderRiskPolicy``, so a scenario difference can never be applied -- it reports ``Blocked`` on every run until the tenant policy is deleted and recreated.`n- [ ] After merge, the next ``deploy-irm.yml`` push run should report 0 drift under ``direction_policy=portal-wins``.`n`n## Notes`n`n- Trigger: local operator run via ``scripts/Invoke-LocalIrmDriftSync.ps1``, base commit ``$baseCommit``."
                $bodyTempFile = [System.IO.Path]::GetTempFileName()
                try {
                    Set-Content -LiteralPath $bodyTempFile -Value $bodyText -NoNewline -Encoding utf8
                    if (-not $existing -or @($existing).Count -eq 0) {
                        $created = Invoke-GhApiCall -Path "$repoPath/pulls" -Method POST `
                            -Field @('title=chore(data-plane): sync IRM policies from tenant', "head=$SyncBranch", "base=$BaseBranch") `
                            -FileField @("body=@$bodyTempFile")
                        $prResult = @{ Number = $created.number; Url = $created.html_url; Operation = 'created' }
                    } else {
                        $pr = @($existing)[0]
                        $updated = Invoke-GhApiCall -Path "$repoPath/pulls/$($pr.number)" -Method PATCH -FileField @("body=@$bodyTempFile")
                        $prResult = @{ Number = $updated.number; Url = $updated.html_url; Operation = 'updated' }
                    }
                } finally {
                    Remove-Item -LiteralPath $bodyTempFile -Force -ErrorAction SilentlyContinue
                }
                Invoke-GhApiCall -Path "$repoPath/issues/$($prResult.Number)/labels" -Method POST `
                    -Field @('labels[]=needs-review', 'labels[]=squad:automation-engineer') | Out-Null
                Write-Information ("Drift PR {0}: #{1} {2}" -f $prResult.Operation, $prResult.Number, $prResult.Url) -InformationAction Continue
            } else {
                Write-Information "WhatIf: would commit, push $SyncBranch, and open/update a drift-back PR against $BaseBranch." -InformationAction Continue
                Write-Information ($diffText) -InformationAction Continue
            }
        }
    }

    if (-not $NoAuditRecord.IsPresent) {
        $recordPath = $AuditRecordPath
        if (-not $recordPath) {
            $recordRoot = if ($env:PURVIEW_AUDIT_RECORD_ROOT) { $env:PURVIEW_AUDIT_RECORD_ROOT } else { Join-Path $repoRoot '.copilot-tracking/audit' }
            $recordPath = Join-Path $recordRoot "irm-$environmentName.json"
        }
        $record = ConvertTo-IrmAuditRecord `
            -Environment $environmentName -Mode $mode -WhatIfMode ([bool]$WhatIfPreference) `
            -Timestamp (Get-Date) -BaseBranch $BaseBranch -BaseCommit $baseCommit -SyncBranch $SyncBranch `
            -Counts $counts -DriftDetected $diffDetected -CosmeticOnly ([bool]$summary.CosmeticOnly) `
            -AddedLines ([int]$summary.AddedLines) -RemovedLines ([int]$summary.RemovedLines) -Rows $rows `
            -PrNumber $prResult.Number -PrUrl $prResult.Url -PrOperation $prResult.Operation

        $recordDir = Split-Path -Parent $recordPath
        # The audit record documents a READ (the tenant call already
        # happened above); it is not the mutating action -WhatIf exists to
        # suppress. Without -WhatIf:$false here, these ShouldProcess-aware
        # cmdlets silently inherit the script's ambient $WhatIfPreference
        # and skip writing -- which previously left the "Audit record
        # written" message below false under -WhatIf.
        if (-not (Test-Path -LiteralPath $recordDir)) { New-Item -ItemType Directory -Path $recordDir -Force -WhatIf:$false | Out-Null }
        $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recordPath -Encoding utf8 -WhatIf:$false
        Write-Information ("Audit record written: {0}" -f $recordPath) -InformationAction Continue
    }
} finally {
    Invoke-ChildProcess -FilePath 'git' -ArgumentList @('-C', $repoRoot, 'worktree', 'remove', '--force', $worktreePath) -ErrorAction SilentlyContinue | Out-Null
}

#endregion
