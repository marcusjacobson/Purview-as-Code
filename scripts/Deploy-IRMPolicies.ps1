#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Insider Risk Management (IRM) policies
    against `data-plane/irm/policies.yaml` (desired state).

.DESCRIPTION
    Wave 2d declarative reconciler for Insider Risk Management
    policies (issue #81). The YAML is the central source of truth:
    add / update / remove flows through this script, which converges
    the live tenant to match. Sibling of `scripts/Set-AuditRetentionPolicy.ps1`
    (Wave 2a) -- same auth path, same drift vocabulary.

    Status: full reconciler. Wires up auth, schema validation, plan
    categorization, and the ShouldProcess apply switch. Create /
    Update / Remove cmdlet parameter shapes were re-verified against
    a live Security & Compliance PowerShell session (issue #267):
    `-Priority` is intentionally NOT plumbed because neither
    `New-InsiderRiskPolicy` nor `Set-InsiderRiskPolicy` accept it as
    a parameter despite `Get-InsiderRiskPolicy` returning a `Priority`
    property.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every policy via `Get-InsiderRiskPolicy`.
      2. Match desired vs. tenant by `Name`.
      3. Diff each desired policy against the tenant copy.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    References (Microsoft Learn):
      Insider Risk Management overview:
        https://learn.microsoft.com/en-us/purview/insider-risk-management
      Get-InsiderRiskPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
      New-InsiderRiskPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy
      Set-InsiderRiskPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicy
      Remove-InsiderRiskPolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy
      Connect-IPPSSession (S&C PowerShell):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
      Connect to S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell
      App-only auth for EXO / S&C PowerShell:
        https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0010 (automation identity subject model):
        docs/adr/0010-automation-identity-subject-model.md
      ADR 0011 Decision #3 supersession (Key Vault-signed JWT auth):
        docs/adr/0011-certificate-lifecycle.md
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/irm/policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant policies that are not declared in the YAML.
    Default $false. NEVER passes a name listed in -SkipNames (the
    baseline carries the system-managed `IRM_Tenant_Setting_*` policy
    plus any operator-authored mid-testing names per
    `docs/adr/0036-irm-tenant-setting-immovable.md`).

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would delete more than `-MaxPruneRatio` of
    the prunable IRM policies is refused before any tenant write. Supply it
    when a large prune is genuinely intended (a deliberate consolidation);
    the ratio is then reported as a warning and the run proceeds. Has no
    effect on the empty-desired-set guard, which cannot be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the prunable IRM policies `-PruneMissing` may delete
    without `-AllowMajorityPrune`, as a fraction in (0, 1]. Default 0.5.
    The denominator excludes the system-managed `IRM_Tenant_Setting_*`
    policy, which is never an orphan (ADR 0036), so the ratio reflects only
    policies the run could actually delete.
    Reference: scripts/modules/PruneGuard.psm1 (issue #13, guard 2).

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit. No
                         New-/Set-/Remove- cmdlet writes against the
                         tenant fire under any circumstance.
                         Equivalent to a forced -WhatIf at the script
                         boundary.
      * `portal-wins` -- (default) skip any policy whose tracked
                         fields differ; emit a Skip plan row per
                         skipped policy and a `[ADR0029-SKIP] <name>`
                         line per skip so an upstream workflow can
                         capture the list for an auto-PR. Create /
                         NoChange / Orphan handling are unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         policy naming the drifted field(s). The
                         overwrite is gated at the SCRIPT layer by
                         the ADR 0052 typed-confirmation prompt: it
                         names the policies it is about to overwrite,
                         asks EVERY caller -- local operators
                         included -- and aborts with no tenant writes
                         if declined. Suppress with -Force, or
                         -Confirm:$false as CI does. The workflow's
                         'overwrite portal' input is an ADDITIONAL
                         gate per ADR 0029, not the only one: a clone
                         of this template that has not run kickoff
                         has no CI at all, so the script-layer gate
                         is its only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. A name
    matched here is treated as a Skip plan row instead of an Update /
    Orphan row (reason: "explicitly skipped by caller"). NoChange and
    Create rows are unaffected. -PruneMissing still respects
    -SkipNames -- a skipped name is never deleted. Names not present
    in the YAML or the tenant are silently ignored (defends against a
    stale skip list from the workflow). The match is case-insensitive
    against the bare `Name`. Ignored in `-DirectionPolicy audit` mode.
    Default `@()`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`. This script's
    workflow baseline carries the names listed in
    `docs/adr/0036-irm-tenant-setting-immovable.md`.

.PARAMETER ExportCurrentState
    Round-trip the live tenant's Insider Risk Management policies back
    into the desired-state YAML at `-Path` instead of reconciling
    against it. Selects the `Export` parameter set: the prune switches
    (`-PruneMissing`, `-AllowMajorityPrune`, `-MaxPruneRatio`) and
    `-SkipNames` are not available, because an export neither plans nor
    writes to the tenant -- it is a read followed by a local file write.
    The system-managed `IRM_Tenant_Setting_<tenant-guid>` policy is
    never exported (ADR 0036: the reconciler classifies it `NoChange`
    by name-prefix wildcard, and its GUID-bearing name must never reach
    a committed file). Only the four tracked fields are emitted, and
    optional fields the tenant leaves unset are omitted rather than
    written as empty strings, so a fresh export re-compares `NoChange`
    by construction. An existing file's leading comment header is
    preserved; a file that already declares policy entries is refused
    unless `-Force` is passed.
    Reference: docs/adr/0036-irm-tenant-setting-immovable.md.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for. This
    script has two: the ADR 0052 destructive-operation confirmation
    prompt raised before the `repo-wins` overwrite branch and before
    the `-PruneMissing` delete branch, and -- under
    `-ExportCurrentState` -- the guard that refuses to clobber a YAML
    file already declaring policy entries.
    `-Force` does NOT authorize overwriting a foreign-authored tenant
    object, and it does NOT suppress `Conflict` rows -- that meaning was
    split out to `-OverwriteForeignAuthor` by ADR 0053 (a switch this
    IPPS-surface script does not carry, because `Get-InsiderRiskPolicy`
    returns no authorship field to diff against).
    Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER VaultName
    Key Vault that holds the automation certificate. When omitted,
    resolved from `resources.keyVault.name` in the parameters file.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name. When omitted, resolved
    from `automation.apps.dataPlane.certificateName`.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName`.

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.
    When omitted, resolved from `automation.tenantDomain`.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Deploy-IRMPolicies.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply would
    do; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-IRMPolicies.ps1

    Reconcile the tenant against the YAML. Without `-PruneMissing`,
    Orphan rows are reported but not removed.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Insider Risk Management` (or higher,
        e.g. `Compliance Administrator`) assigned at
        directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Name /
    Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or a file.
    No credential material is printed.

    Schema validation:
      * The desired-state YAML is validated against
        `data-plane/irm/policies.schema.json`
        (JSON Schema Draft-07) at script start.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\irm\policies.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    # Issue #13, guard 2: the prune sanity-ratio override and threshold.
    [Parameter(ParameterSetName = 'Apply')]
    [switch]$AllowMajorityPrune,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0.0000001, 1.0)]
    [double]$MaxPruneRatio = 0.5,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    # ADR 0052: the operator's "do not ask me" switch. Carries NO default --
    # a default of $true would suppress the confirmation gate on every run,
    # including runs where nobody passed -Force.
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    # Export mode (issue #177). Mandatory in its own parameter set, which is
    # what makes the set selectable: passing -ExportCurrentState binds Export
    # and takes the prune switches and -SkipNames off the table entirely.
    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[a-zA-Z0-9\-]{1,127}$')]
    [string]$CertificateName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DataPlaneAppDisplayName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{0,253}[A-Za-z0-9]$')]
    [string]$TenantDomain,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Helpers

function ConvertTo-DesiredIRMPolicyHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    return @{
        name        = [string]$Entry.name
        description = if ($Entry.ContainsKey('description')) { [string]$Entry.description } else { $null }
        scenario    = [string]$Entry.scenario
        enabled     = if ($Entry.ContainsKey('enabled'))  { [bool]$Entry.enabled }  else { $null }
    }
}

function ConvertTo-TenantIRMPolicyHash {
    # Normalize a Get-InsiderRiskPolicy result into the same comparable
    # shape as ConvertTo-DesiredIRMPolicyHash. Property names verified
    # against a live Security & Compliance PowerShell session (issue #267).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
    param([Parameter(Mandatory = $true)]$Policy)

    return @{
        name        = [string]$Policy.Name
        description = if ($null -ne $Policy.Comment) { [string]$Policy.Comment } else { $null }
        scenario    = if ($null -ne $Policy.InsiderRiskScenario) { [string]$Policy.InsiderRiskScenario } else { $null }
        enabled     = [bool]$Policy.Enabled
        isCustom    = [bool]$Policy.IsCustom
    }
}

function Compare-IRMPolicy {
    # Return a list of field names that differ between desired and
    # tenant. Compares only fields the YAML actually declares -- a
    # missing optional in YAML is treated as "don't manage", not a diff.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    if (-not [string]::IsNullOrEmpty($Desired.scenario)) {
        if ([string]$Desired.scenario -ne [string]$Tenant.scenario) {
            $diffs.Add('scenario') | Out-Null
        }
    }

    if ($null -ne $Desired.enabled) {
        if ([bool]$Desired.enabled -ne [bool]$Tenant.enabled) {
            $diffs.Add('enabled') | Out-Null
        }
    }

    return $diffs
}

function Get-IRMSettableFieldDrift {
    # Issue #196. Fields that still differ after a create AND that
    # Set-InsiderRiskPolicy can actually correct.
    #
    # `scenario` is deliberately excluded. InsiderRiskScenario is set-once
    # on New-InsiderRiskPolicy, so a post-create scenario difference is not
    # something to converge -- it means the create did not do what it was
    # told, and the caller must report Failed rather than retry a write
    # that can never succeed.
    #
    # This exists because New-InsiderRiskPolicy accepts -Enabled:$false and
    # creates the policy ENABLED anyway, while Set-InsiderRiskPolicy
    # honours the same flag. Reproduced on both tenants (issue #196), so it
    # is cmdlet-level rather than a tenant quirk. The defence is general on
    # purpose: any tracked field the service quietly declines to apply on
    # create is invisible to a create-only bootstrap, which is the same
    # blind spot ADR 0064 records on the read side.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $all = @(Compare-IRMPolicy -Desired $Desired -Tenant $Tenant)
    return @($all | Where-Object { $_ -ne 'scenario' })
}

function Invoke-IRMPolicyExport {
    # Round-trip the live tenant's IRM policies back into the YAML's
    # `policies:` block (issue #177). Shape copied from
    # Deploy-DLPPolicies.ps1's Invoke-DlpExport.
    #
    # Rows are normalized through ConvertTo-TenantIRMPolicyHash -- the SAME
    # function the comparator consumes -- so export and compare can never
    # disagree about a field's canonical form. That is what makes a freshly
    # exported file re-compare all-NoChange by construction, and it is the
    # #20 export-normalize/apply-raw defect class designed out rather than
    # tested for.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantPolicies,
        [switch]$Force
    )

    # YAML-clobber guard. An export overwrites the operator's curated
    # desired state, so a file that already declares entries needs -Force.
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
        if ($existing -and $existing.ContainsKey('policies') -and $existing.policies -and @($existing.policies).Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("Target YAML '{0}' already declares {1} policy entries. Re-run with -Force to overwrite." -f $Path, @($existing.policies).Count)
            return
        }
    }

    # Preserve the file's curated comment header (every leading blank or
    # comment line up to the first content line). The header carries the
    # field contract and the ADR references; an export must not eat it.
    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') {
                $headerLines += $line
            } else {
                break
            }
        }
    }

    $exported = @()
    foreach ($t in ($TenantPolicies | Sort-Object { [string]$_.Name })) {
        # ADR 0036: the per-tenant system-managed container is never
        # reconciled and must never be written to a committed file -- its
        # name embeds the real tenant GUID, which the ADR 0055 residue scan
        # fails closed on. Same name-prefix test the plan builder uses.
        if ([string]$t.Name -like 'IRM_Tenant_Setting_*') { continue }

        $h = ConvertTo-TenantIRMPolicyHash -Policy $t

        # `scenario` is schema-required. A tenant row without one cannot be
        # represented, so warn and skip rather than emit an invalid document.
        if ([string]::IsNullOrEmpty($h.scenario)) {
            Write-Warning ("Skipping tenant policy '{0}': it reports no InsiderRiskScenario, which the schema requires." -f $h.name)
            continue
        }

        # Emit only the tracked fields, and only when the tenant actually
        # carries them. Writing `description: ''` for an unset Comment would
        # round-trip as a declared-empty value and plan a perpetual Update.
        $entry = [ordered]@{ name = $h.name }
        if (-not [string]::IsNullOrEmpty($h.description)) { $entry.description = $h.description }
        $entry.scenario = $h.scenario
        $entry.enabled  = [bool]$h.enabled
        $exported += $entry
    }

    $doc = [ordered]@{ policies = $exported }
    # WithIndentedSequences indents block-sequence items 2 spaces from their
    # parent key, matching the hand-curated style in the rest of data-plane/
    # and satisfying the default yamllint indentation rule.
    # Reference: https://www.powershellgallery.com/packages/powershell-yaml
    $body = ConvertTo-Yaml $doc -Options WithIndentedSequences

    # Header + body, trailing blanks stripped, explicit LF endings and
    # exactly one trailing newline so yamllint is satisfied regardless of
    # host OS. Pattern mirrors Deploy-DLPPolicies.ps1's export branch.
    $bodyLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($body -split "`n")) { $bodyLines.Add($line.TrimEnd()) }
    while ($bodyLines.Count -gt 0 -and [string]::IsNullOrEmpty($bodyLines[$bodyLines.Count - 1])) {
        $bodyLines.RemoveAt($bodyLines.Count - 1)
    }
    $finalLines = @($headerLines) + @($bodyLines)
    $content = ($finalLines -join "`n") + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
    Write-Information ("Exported {0} tenant policies to '{1}'." -f $exported.Count, $Path) -InformationAction Continue
}

#endregion

#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so neither destructive branch (repo-wins
# overwrite, -PruneMissing delete) can be entered unattended from a local
# terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo -PruneMissing safety guard (issue #13): the empty-desired-set
# refusal, which prevents a prune against a zero-entry desired state from
# classifying every live tenant object as an orphan. Shared with the other
# Deploy-*.ps1 reconcilers that implement -PruneMissing.
Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1') `
    -Force -Scope Local -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

# When -ParametersFile is omitted, the PURVIEW_PARAMETERS_FILE environment
# variable (set per-environment by the CI workflows) selects the parameters
# file. See docs/adr/0057-multi-environment-and-branch-model.md.
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or
    -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.tenantDomain'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'. Reference: docs/adr/0010-automation-identity-subject-model.md." -f $ParametersFile)
    return
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key)
        return
    }
}

if (-not $VaultName)               { $VaultName               = [string]$parameters.resources.keyVault.name }
if (-not $CertificateName)         { $CertificateName         = [string]$parameters.automation.apps.dataPlane.certificateName }
if (-not $DataPlaneAppDisplayName) { $DataPlaneAppDisplayName = [string]$parameters.automation.apps.dataPlane.displayName }
if (-not $TenantDomain)            { $TenantDomain            = [string]$parameters.automation.tenantDomain }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }

Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment     : {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Vault           : {0}" -f $VaultName) -InformationAction Continue
Write-Information ("Certificate     : {0}" -f $CertificateName) -InformationAction Continue
Write-Information ("Data-plane app  : {0}" -f $DataPlaneAppDisplayName) -InformationAction Continue
Write-Information ("Tenant domain   : {0}" -f $TenantDomain) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
Write-Information ("SkipNames count : {0}" -f $SkipNames.Count) -InformationAction Continue

#endregion

#region Desired-state load

# Apply-only. Export reads the tenant and overwrites $Path, so it neither
# needs the current desired state nor should fail on a file that does not
# parse -- that is exactly the file an export exists to (re)generate.
$desiredEntries = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml

    # Schema validation (JSON Schema Draft-07).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
    if (-not $SkipSchemaValidation.IsPresent) {
        $schemaPath = Join-Path $scriptRoot '..\data-plane\irm\policies.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath)) {
            Write-Error ("Schema file not found at '{0}'." -f $schemaPath)
            return
        }
        $schemaText = Get-Content -LiteralPath $schemaPath -Raw
        # Depth 100 (the ConvertTo-Json maximum), matching Deploy-DLPPolicies.ps1 (#80):
        # -Depth 10 can silently truncate a deep desired-state document during
        # serialization, and Test-Json then rejects the truncated document with an
        # error pointing at an unrelated shallow field (#90).
        $docJson = $desiredRoot | ConvertTo-Json -Depth 100
        try {
            $null = $docJson | Test-Json -Schema $schemaText -ErrorAction Stop
        }
        catch {
            Write-Error ("Desired-state YAML failed schema validation: {0}" -f $_.Exception.Message)
            return
        }
        Write-Information ("Schema OK       : {0}" -f $schemaPath) -InformationAction Continue
    }

    if ($desiredRoot -and $desiredRoot.ContainsKey('policies') -and $desiredRoot.policies) {
        $desiredEntries = @($desiredRoot.policies | ForEach-Object { ConvertTo-DesiredIRMPolicyHash -Entry ([hashtable]$_) })
    }
    Write-Information ("Desired policies: {0}" -f $desiredEntries.Count) -InformationAction Continue

    # Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
    #
    # With zero desired entries every live tenant insider risk management policy
    # falls out of the orphan match below, so the run would classify the entire set
    # as orphans and delete it. The rationale, the likely causes, and the
    # 2026-07-19 production hit are documented in scripts/modules/PruneGuard.psm1.
    #
    # This whole block is Apply-only, so reaching it already implies Apply mode
    # and the prune switch alone selects the destructive branch. Placed in the
    # desired-state load region so it fires before the tenant is contacted at
    # all -- before `az account show`, before Connect-IPPSSession, and before
    # any write phase.
    if ($PruneMissing.IsPresent) {
        Assert-PruneDesiredSetNotEmpty `
            -DesiredCount   $desiredEntries.Count `
            -ObjectTypeNoun 'insider risk management policy' `
            -SourcePath     $Path `
            -CollectionKey  'policies'
    }
}

#endregion

#region Azure context (read-only preamble)

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) {
    Write-Error 'az account show did not return a tenantId. Re-run `az login` and retry.'
    return
}
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region Resolve data-plane app + acquire access token

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error ("az ad app list failed with exit code {0}." -f $LASTEXITCODE)
    return
}
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) {
    Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName)
    return
}
if ($appList.Count -gt 1) {
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 mandates one app per display name." -f $appList.Count, $DataPlaneAppDisplayName)
    return
}
$appId = [string]$appList[0].appId
# NOTE: $appId deliberately not echoed at INFO -- real tenant identifier.

# Reference: docs/adr/0011-certificate-lifecycle.md (Decision #3 supersession)
$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) {
    Write-Error ("Helper not found: '{0}'." -f $tokenScript)
    return
}
$tok = & $tokenScript `
    -VaultName       $VaultName `
    -CertificateName $CertificateName `
    -AppId           $appId `
    -TenantId        $tenantId
if (-not $tok -or -not $tok.AccessToken) {
    Write-Error 'Get-PurviewIPPSAccessToken.ps1 did not return an access token.'
    return
}
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion

#region Connect, enumerate, apply

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy
    $tenantPolicies = @(Get-InsiderRiskPolicy -ErrorAction Stop)
    Write-Information ("Tenant policies : {0}" -f $tenantPolicies.Count) -InformationAction Continue

    # Export mode short-circuit (issue #177). Placed after the enumerate and
    # before any planning: an export is a read plus a local file write, so it
    # never builds a plan, never reaches the ADR 0052 gate, and never touches
    # the tenant. The `return` exits through the finally below, so the S&C
    # session is still disconnected.
    if ($mode -eq 'Export') {
        Invoke-IRMPolicyExport -Path $Path -TenantPolicies $tenantPolicies -Force:$Force.IsPresent
        return
    }

    # Index tenant policies by Name for O(1) lookup.
    $tenantByName = @{}
    foreach ($t in $tenantPolicies) {
        $tenantByName[[string]$t.Name] = ConvertTo-TenantIRMPolicyHash -Policy $t
    }
    $desiredNames = @($desiredEntries | ForEach-Object { $_.name })

    # Categorize: Create / Update / NoChange (desired-side) +
    # Orphan (tenant-only).
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantByName.ContainsKey($d.name)) {
            $diffs = Compare-IRMPolicy -Desired $d -Tenant $tenantByName[$d.name]
            if ($diffs.Count -eq 0) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } elseif ($diffs -contains 'scenario') {
                # InsiderRiskScenario is set-once: it is a parameter on
                # New-InsiderRiskPolicy but NOT on Set-InsiderRiskPolicy (verified
                # against a live S&C session, issue #267 -- and see the Update
                # splat below, which cannot carry it). Planning an Update for
                # scenario drift would emit a row that can never converge, so the
                # run would report the same drift forever. Report it as Blocked
                # instead: visible in the plan, never written, and -- because the
                # ADR 0052 gate keys on Update rows only -- never counted as an
                # overwrite the operator is asked to confirm.
                $plan.Add([pscustomobject]@{
                    Action  = 'Blocked'
                    Name    = $d.name
                    Desired = $d
                    Reason  = ("Immutable field drift: scenario (YAML '{0}', tenant '{1}'). Set-InsiderRiskPolicy cannot change InsiderRiskScenario; remove the tenant policy and recreate it, or correct the YAML." -f $d.scenario, $tenantByName[$d.name].scenario)
                })
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantPolicies) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            # Skip system-managed policies: the per-tenant
            # IRM_Tenant_Setting_<tenantId> container surfaced by
            # Get-InsiderRiskPolicy is not deletable by
            # Remove-InsiderRiskPolicy and must not be classified as
            # Orphan. Identified strictly by name prefix; the
            # IsCustom property is unreliable here because the live
            # tenant returns IsCustom=False for user-created policies
            # as well (verified in issue #267). Ratified as permanent
            # declared orphan in docs/adr/0036-irm-tenant-setting-immovable.md.
            $isSystem = ($tn -like 'IRM_Tenant_Setting_*')
            if ($isSystem) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $tn; Desired = $null; Reason = 'System-managed tenant policy; not reconciled by this script.' })
                continue
            }
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- ADR 0029: audit-mode short-circuit + SkipNames pre-pass ----
    # `-DirectionPolicy audit` flips $WhatIfPreference for the rest of
    # this script so every $PSCmdlet.ShouldProcess(...) call below
    # returns false and falls into its existing "Would ..." else
    # branch. No New-/Set-/Remove- cmdlet writes against the tenant
    # under any circumstance, while the categorized plan-with-would-
    # rows is preserved end-to-end. The AUDIT marker line is the
    # operator-visible signal that no writes would have fired.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
        $WhatIfPreference = $true
    }

    # ADR 0029 direction-policy pass on the IRM policy plan. SkipNames
    # mutation applies to every row category (Create / Update /
    # NoChange / Orphan) so the workflow can suppress noise on the
    # system-managed IRM_Tenant_Setting_* policy and on operator-
    # authored mid-testing names regardless of category. portal-wins
    # drift arbitration on Update rows applies here. Audit mode does
    # not enter this pass -- the audit short-circuit above sets
    # $WhatIfPreference so the apply loop's ShouldProcess calls fall
    # into the WhatIf branch.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    # Reference: docs/adr/0036-irm-tenant-setting-immovable.md
    $script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'

    # ADR 0052: every IRM policy whose tenant fields this run WILL overwrite.
    # Constructed OUTSIDE the policy test below so the gate can read .Count
    # on it unconditionally -- under `audit` the pass never runs, the list
    # stays empty, and the gate correctly stays silent.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    if ($DirectionPolicy -ne 'audit') {
        foreach ($row in $plan) {
            if ($row.Action -notin @('Create','Update','NoChange','Orphan','Blocked')) { continue }
            $hasDrift = ($row.Action -eq 'Update')
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName ([string]$row.Name) `
                -HasDrift    $hasDrift
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $script:Adr0029Skips.Add([pscustomobject]@{
                    Kind        = 'IRMPolicy'
                    DisplayName = [string]$row.Name
                    Reason      = $decision.Reason
                })
                continue
            }
            if ($row.Action -eq 'Update') {
                $fieldsText = ($row.Reason -replace '^Drift in: ', '')
                if ($DirectionPolicy -eq 'repo-wins') {
                    Write-Warning ("repo-wins overwriting tenant on IRM policy '{0}' fields: {1}" -f $row.Name, $fieldsText)
                }
                # Every Update row that survived Resolve-DirectionPolicyAction's
                # Skip decision WILL be Set-, whatever policy let it through.
                # Collect it here, OUTSIDE the repo-wins test above: the ADR 0052
                # gate is keyed on this list -- the plan -- and never on
                # $DirectionPolicy. Populating it only under repo-wins would leave
                # the list empty under portal-wins, the plan-keyed gate would see
                # zero, and the overwrite would proceed unconfirmed. See
                # ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
                $repoWinsOverwrites.Add([string]$row.Name) | Out-Null
            }
        }

        # Machine-readable marker per skipped object for the workflow's
        # auto-PR step. One line per skipped object so a simple
        # `grep '\[ADR0029-SKIP\]'` over the run log yields the full
        # skip list. Format must match the exact regex
        # `^\[ADR0029-SKIP\] (.+)$` per the github-actions instructions
        # rule, so we do not prefix the Kind here.
        foreach ($s in $script:Adr0029Skips) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # ---- Issue #13, guard 2: prune sanity ratio ----
    # Guard 1 (desired-state load region) catches only the total wipe. This
    # catches the near-total one: a policies.yaml that lost most of its
    # entries to a bad merge, or a -Path pointing at a smaller environment's
    # file, both of which leave a non-zero desired count and so clear guard 1.
    #
    # Keyed on the Orphan set this run would delete against the PRUNABLE live
    # policy count. The denominator excludes the system-managed
    # IRM_Tenant_Setting_* policy (classified NoChange above, never Orphan per
    # ADR 0036), so a single custom orphan next to that immovable system
    # policy is not mis-read as a 50% prune. Gated on $DirectionPolicy -ne
    # 'audit': this script implements audit mode by flipping $WhatIfPreference
    # (it does NOT empty the orphan rows), so a read-only `-DirectionPolicy
    # audit -PruneMissing` run must not be refused by the ratio guard. Sits
    # inside the enclosing try/finally and before the ADR 0052 gate, so a
    # refusal still runs the finally that disconnects the S&C session.
    # Reference: scripts/modules/PruneGuard.psm1
    # Reference: docs/adr/0036-irm-tenant-setting-immovable.md
    if ($PruneMissing.IsPresent -and $DirectionPolicy -ne 'audit') {
        Assert-PruneRatioWithinThreshold `
            -PruneCount     @($plan | Where-Object { $_.Action -eq 'Orphan' }).Count `
            -LiveCount      @($tenantPolicies | Where-Object { [string]$_.Name -notlike 'IRM_Tenant_Setting_*' }).Count `
            -ObjectTypeNoun 'insider risk management policy' `
            -MaxPruneRatio  $MaxPruneRatio `
            -Allow:$AllowMajorityPrune
    }

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before the write loop at which nothing has been written.
    # Both destructive branches are gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
    # unconditionally; ShouldProcess only prompts when ConfirmImpact >=
    # $ConfirmPreference, which is precisely the comparison that silently
    # defeated this gate before issue #85.
    #
    # Both gates are keyed on the PLAN -- the objects this run will actually
    # overwrite or delete -- and never on $DirectionPolicy. The $yesToAll /
    # $noToAll pair is shared, so a run that trips both gates prompts once.
    #
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path --
    # deploy-irm.yml binds Confirm = $false in its apply splat), and skipped
    # under -WhatIf so a dry run still previews the deletes without blocking
    # on input. `-DirectionPolicy audit` sets $WhatIfPreference above, so an
    # audit run cannot prompt either.
    # Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
    $yesToAll = $false
    $noToAll = $false
    $confirmBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')
    $confirmValue = if ($confirmBound) { [bool]$PSCmdlet.MyInvocation.BoundParameters['Confirm'] } else { $false }
    $gateArgs = @{
        Cmdlet       = $PSCmdlet
        Caption      = 'Destructive operation (ADR 0052)'
        YesToAll     = ([ref]$yesToAll)
        NoToAll      = ([ref]$noToAll)
        Force        = $Force.IsPresent
        IsWhatIf     = [bool]$WhatIfPreference
        ConfirmBound = $confirmBound
        ConfirmValue = $confirmValue
    }

    if ($repoWinsOverwrites.Count -gt 0) {
        $overwriteNames = @($repoWinsOverwrites | Sort-Object -Unique)
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} IRM policy/policies with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
            $overwriteNames.Count, ($overwriteNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
            throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Derived from the FINAL plan one line above the gate and read one line
    # later, so it cannot diverge from the deletes it speaks for.
    $pruneTargets = @($plan | Where-Object { $_.Action -eq 'Orphan' })
    if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
        $pruneNames = @($pruneTargets | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
        $pruneQuery = "-PruneMissing will DELETE {0} orphan IRM policy/policies from the tenant: {1}. This cannot be undone. Continue?" -f `
            $pruneNames.Count, ($pruneNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Execute each plan row under ShouldProcess. -WhatIf / -Confirm
    # flow naturally via $PSCmdlet.ShouldProcess.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    # Issue #13: orphan prune failures are reported via Write-PruneFailure
    # (Write-Warning plus an '::error::' annotation, not Write-Error, which
    # shell: pwsh's $ErrorActionPreference='stop' would promote to terminating
    # and abandon the remaining orphans) and collected here; a single aggregate
    # throw after the loop names every failure so a failed prune exits non-zero.
    $pruneFailures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($row in $plan) {
        $target = "IRM policy '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $opDesc = 'New-InsiderRiskPolicy ({0})' -f $row.Desired.scenario
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskpolicy
                        # Note: -Priority is not a parameter on New-InsiderRiskPolicy;
                        # Priority is a read-only property on Get-InsiderRiskPolicy results.
                        # Verified against a live S&C PowerShell session (issue #267).
                        $splat = @{ Name = $row.Desired.name; InsiderRiskScenario = $row.Desired.scenario }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Comment = $row.Desired.description }
                        if ($null -ne $row.Desired.enabled)  { $splat.Enabled  = [bool]$row.Desired.enabled }
                        New-InsiderRiskPolicy @splat -ErrorAction Stop | Out-Null

                        # Issue #196: never trust the create to have applied
                        # what it was handed. New-InsiderRiskPolicy accepts
                        # -Enabled:$false and creates the policy ENABLED
                        # anyway; Set- honours the same flag. Read it back and
                        # converge whatever did not take.
                        #
                        # Each failure mode reports honestly and separately: a
                        # read-back that fails is NOT a failed create, but a
                        # corrective Set- that fails IS a tenant left holding
                        # state the repo did not declare.
                        $verifyReason = $row.Reason
                        $createVerified = $false
                        $createFailed = $false
                        $createdHash = $null

                        try {
                            $createdHash = ConvertTo-TenantIRMPolicyHash -Policy (Get-InsiderRiskPolicy -Identity $row.Desired.name -ErrorAction Stop)
                            $createVerified = $true
                        } catch {
                            Write-Warning ("Created IRM policy '{0}' but could not read it back to verify: {1}" -f $row.Name, $_.Exception.Message)
                            $verifyReason = ('{0} Post-create verification could not read the policy back; the declared state is unconfirmed.' -f $row.Reason)
                        }

                        if ($createVerified) {
                            $allDrift = @(Compare-IRMPolicy -Desired $row.Desired -Tenant $createdHash)
                            if ($allDrift -contains 'scenario') {
                                # Immutable, so unrecoverable in place: the
                                # service created the policy under a scenario
                                # other than the one requested.
                                $createFailed = $true
                                $report.Add([pscustomobject]@{
                                        Category = 'Failed'
                                        Name     = $row.Name
                                        Reason   = ("Created, but the tenant reports scenario '{0}' where YAML declares '{1}'. InsiderRiskScenario is set-once on New-InsiderRiskPolicy, so it cannot be corrected in place -- remove the tenant policy and re-apply." -f $createdHash.scenario, $row.Desired.scenario)
                                    })
                            } else {
                                $settable = @(Get-IRMSettableFieldDrift -Desired $row.Desired -Tenant $createdHash)
                                if ($settable.Count -gt 0) {
                                    Write-Warning ("Create did not honour {0} on IRM policy '{1}' (issue #196); converging with Set-InsiderRiskPolicy." -f ($settable -join ', '), $row.Name)
                                    try {
                                        $fixSplat = @{ Identity = $row.Desired.name }
                                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $fixSplat.Comment = $row.Desired.description }
                                        if ($null -ne $row.Desired.enabled) { $fixSplat.Enabled = [bool]$row.Desired.enabled }
                                        Set-InsiderRiskPolicy @fixSplat -ErrorAction Stop | Out-Null

                                        $recheckHash = ConvertTo-TenantIRMPolicyHash -Policy (Get-InsiderRiskPolicy -Identity $row.Desired.name -ErrorAction Stop)
                                        $stillDrifted = @(Get-IRMSettableFieldDrift -Desired $row.Desired -Tenant $recheckHash)
                                        if ($stillDrifted.Count -gt 0) {
                                            $createFailed = $true
                                            $report.Add([pscustomobject]@{
                                                    Category = 'Failed'
                                                    Name     = $row.Name
                                                    Reason   = ('Created, but {0} did not take on either the create or the follow-up Set-InsiderRiskPolicy. The tenant does not hold the declared state.' -f ($stillDrifted -join ', '))
                                                })
                                        } else {
                                            $verifyReason = ('{0} Create did not honour {1}; converged with a follow-up Set- (issue #196).' -f $row.Reason, ($settable -join ', '))
                                        }
                                    } catch {
                                        $createFailed = $true
                                        $report.Add([pscustomobject]@{
                                                Category = 'Failed'
                                                Name     = $row.Name
                                                Reason   = ('Created, but the follow-up Set-InsiderRiskPolicy that would have converged {0} failed: {1}' -f ($settable -join ', '), $_.Exception.Message)
                                            })
                                    }
                                }
                            }
                        }

                        if (-not $createFailed) {
                            $report.Add([pscustomobject]@{ Category = 'Created'; Name = $row.Name; Reason = $verifyReason })
                        }
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $opDesc = 'Set-InsiderRiskPolicy'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskpolicy
                        # Note: -Priority is not a parameter on Set-InsiderRiskPolicy.
                        # Verified against a live S&C PowerShell session (issue #267).
                        $splat = @{ Identity = $row.Desired.name }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Comment = $row.Desired.description }
                        if ($null -ne $row.Desired.enabled)  { $splat.Enabled  = [bool]$row.Desired.enabled }
                        Set-InsiderRiskPolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Updated'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Update'; Name = $row.Name; Reason = ('Would update. {0}' -f $row.Reason) })
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Name = $row.Name; Reason = $row.Reason })
            }
            'Skip' {
                $report.Add([pscustomobject]@{ Category = 'Skipped'; Name = $row.Name; Reason = $row.Reason })
            }
            'Blocked' {
                # Reported, never written. No ShouldProcess call: there is no
                # cmdlet invocation to gate, because the service exposes no way
                # to satisfy this drift in place.
                $report.Add([pscustomobject]@{ Category = 'Blocked'; Name = $row.Name; Reason = $row.Reason })
            }
            'Orphan' {
                if ($PruneMissing.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($target, 'Remove-InsiderRiskPolicy')) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskpolicy
                            Remove-InsiderRiskPolicy -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                            $report.Add([pscustomobject]@{ Category = 'Removed'; Name = $row.Name; Reason = $row.Reason })
                        } catch {
                            $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                            Write-PruneFailure ("Remove IRM policy '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
                            $pruneFailures.Add([string]$row.Name)
                        }
                    } else {
                        $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = ('Would remove. {0}' -f $row.Reason) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Orphan'; Name = $row.Name; Reason = $row.Reason })
                }
            }
        }
    }

    # Issue #13: a failed prune now exits non-zero (behaviour change). The
    # throw sits inside the try so the finally still disconnects the S&C
    # session; it fires after every orphan has been attempted, naming them all.
    if ($pruneFailures.Count -gt 0) {
        throw ("Reconciliation aborted: {0} orphan IRM policy/policies could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
    }
}
finally {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/disconnect-exchangeonline
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose ('Disconnect-ExchangeOnline failed (non-fatal): {0}' -f $_.Exception.Message)
    }
}

#endregion

# Emit the categorized plan. Suitable for | Format-Table or capture to
# $GITHUB_STEP_SUMMARY. Categories: Created / Updated / Removed for
# completed writes; Create / Update / Orphan for -WhatIf rows; NoChange
# for in-sync; Skipped for ADR 0029 direction-policy skips; Blocked for
# drift the service cannot satisfy in place (immutable scenario);
# Failed for caught exceptions.
#
# Export mode returns before this point -- it emits no plan.
$report
