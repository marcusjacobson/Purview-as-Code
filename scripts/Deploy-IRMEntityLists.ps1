#Requires -Version 7.4
<#
.SYNOPSIS
    PARKED (ADR 0064) -- Reconcile Microsoft Purview Insider Risk
    Management entity lists against `data-plane/irm/entity-lists.yaml`.

.DESCRIPTION
    ##################################################################
    #  PARKED -- DO NOT RUN, DO NOT UN-PARK WITHOUT A FOLLOW-UP ADR   #
    ##################################################################

    This reconciler models a surface that does not exist as designed.
    Retained on disk as the record of an attempted model, and as the
    reference implementation several AST-derived contract suites assert
    over (the ADR 0052 gate class map, the issue #13 prune-guard
    rollout tables, the validate.yml full-circle exempt list). Nothing
    invokes it: `deploy-irm-entity-lists.yml` was removed under ADR
    0064, and `data-plane/irm/entity-lists.yaml` ships -- and stays --
    an empty root list.

    Live findings that parked it (2026-09-03, lab tenant; full evidence
    ladder in docs/adr/0064-irm-entity-lists-are-microsoft-managed.md):

      1. `Get-InsiderRiskEntityList` REJECTS a bare call -- "Either
         Identity or Type should be provided as parameter." The read
         phase below calls it bare and has therefore never once run.
      2. The ADR 0039 `type` model is fictional. `UserType` /
         `GroupType` / `SiteType` are not members of the live
         `IrmEntityListType` enum, which has 23 entirely different
         values (HveLists, DomainLists, GlobalExclusionSGMapping, ...).
         `New-InsiderRiskEntityList -Type` takes the same enum, so the
         Create path could never have succeeded either.
      3. `-IncludeEntities` is declared by the cmdlet but rejected by
         the service as not implemented.
      4. `.Entities` is EMPTY on every list, via per-type enumeration
         and via a single-object `-Identity` fetch. Membership -- the
         only field carrying operator intent -- is not readable, so it
         cannot be converged. This is the decisive finding.
      5. `.Type` is the constant 'InsiderRiskEntityList'; the real
         discriminator is `.ListType`.
      6. `IRM-Lab-Priority-Users`, the ADR 0039 skip-baseline name,
         does not exist on the tenant.
      7. All 32 lists on lab are Microsoft-provisioned configuration
         containers (Irm* / Dspm* / Purview*) -- the IRM settings
         surface, the analogue of ADR 0036's IRM_Tenant_Setting_*.

    The broken enumerate call is left in place deliberately. Fixing it
    is a per-type loop, which finding 4 then makes pointless; a future
    un-parking ADR owns that repair.

    Everything below this block is the original Wave 2d reconciler,
    unchanged, and is accurate about its own intent -- it is the intent
    that turned out not to be reachable. Original description:

    Wave 2d declarative reconciler for Insider Risk Management entity
    lists (issue #606). The YAML is the central source of truth: add /
    update / remove flows through this script, which converges the live
    tenant to match. Sibling of `scripts/Deploy-IRMPolicies.ps1` -- same
    auth path, same drift vocabulary.

    IRM entity lists are named, typed collections of users, groups, or
    sites used to scope IRM policies. A list of type UserType holds UPNs;
    GroupType holds group identifiers; SiteType holds SharePoint/Teams
    site URLs.

    Drift contract (per
    `.github/instructions/powershell.instructions.md` "Drift report
    format"):

      1. GET every entity list via `Get-InsiderRiskEntityList`.
      2. Match desired vs. tenant by `Name`.
      3. Diff each desired list against the tenant copy on tracked fields:
         displayName, description, entities.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    `Type` is immutable after creation (analogous to InsiderRiskScenario
    on policies). It is stored in the desired hash for Create but is NOT
    diffed for existing lists. See docs/adr/0039-irm-entity-list-tracked-fields.md.

    `entities` comparison is order-insensitive: both arrays are normalized
    to lowercase sorted form before comparing.

    References (Microsoft Learn):
      Insider Risk Management -- priority user groups:
        https://learn.microsoft.com/en-us/purview/insider-risk-management-settings-priority-user-groups
      Get-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
      New-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
      Set-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
      Remove-InsiderRiskEntityList:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist
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
      ADR 0029 (source-of-truth direction policy):
        docs/adr/0029-source-of-truth-direction-policy.md
      ADR 0039 (entity-list tracked fields):
        docs/adr/0039-irm-entity-list-tracked-fields.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/irm/entity-lists.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant entity lists that are not declared in the YAML.
    Default $false. NEVER removes a name listed in -SkipNames (the
    baseline carries `IRM-Lab-Priority-Users` per
    `docs/adr/0039-irm-entity-list-tracked-fields.md`).

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would delete more than `-MaxPruneRatio` of
    the live IRM entity lists is refused before any tenant write. Supply it
    when a large prune is genuinely intended (a deliberate consolidation);
    the ratio is then reported as a warning and the run proceeds. Has no
    effect on the empty-desired-set guard, which cannot be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the live IRM entity lists `-PruneMissing` may delete
    without `-AllowMajorityPrune`, as a fraction in (0, 1]. Default 0.5.
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
      * `portal-wins` -- (default) skip any list whose tracked fields
                         differ; emit a Skip plan row per skipped list
                         and a `[ADR0029-SKIP] <name>` line per skip so
                         an upstream workflow can capture the list for an
                         auto-PR. Create / NoChange / Orphan handling are
                         unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         list naming the drifted field(s). The overwrite is
                         gated at the SCRIPT layer by the ADR 0052 typed-
                         confirmation prompt: it names the lists it is about
                         to overwrite, asks EVERY caller -- local operators
                         included -- and aborts with no tenant writes if
                         declined. Suppress with -Force, or -Confirm:$false
                         as CI does. The workflow's 'overwrite portal' input
                         is an ADDITIONAL gate per ADR 0029, not the only
                         one: a clone of this template that has not run
                         kickoff has no CI at all, so the script-layer gate
                         is its only defence.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. A name matched
    here is treated as a Skip plan row. NoChange and Create rows are
    unaffected. -PruneMissing still respects -SkipNames. The match is
    case-insensitive against the bare `Name`. Ignored in
    `-DirectionPolicy audit` mode.
    Default `@()`. This script's workflow baseline carries `IRM-Lab-Priority-Users`
    per docs/adr/0039-irm-entity-list-tracked-fields.md.

.PARAMETER ExportCurrentState
    Round-trip the live tenant's Insider Risk Management entity lists
    back into the desired-state YAML at `-Path` instead of reconciling
    against it. Selects the `Export` parameter set: the prune switches
    (`-PruneMissing`, `-AllowMajorityPrune`, `-MaxPruneRatio`) and
    `-SkipNames` are not available, because an export neither plans nor
    writes to the tenant -- it is a read followed by a local file write.
    `name` and `type` are always emitted (both are schema-required, and
    `type` is immutable per ADR 0039, so it must survive a round trip to
    stay available to the Create splat). `entities` is always emitted --
    lowercased and sorted to match the comparator, with an empty tenant
    list writing `entities: []`, the declared-empty form. Optional
    fields the tenant leaves unset are omitted rather than written as
    empty strings, so a fresh export re-compares `NoChange` by
    construction. An existing file's leading comment header is
    preserved; a file that already declares entity-list entries is
    refused unless `-Force` is passed.
    Reference: docs/adr/0039-irm-entity-list-tracked-fields.md.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for. This
    script has two: the ADR 0052 destructive-operation confirmation
    prompt raised before the `repo-wins` overwrite branch and before
    the `-PruneMissing` delete branch, and -- under
    `-ExportCurrentState` -- the guard that refuses to clobber a YAML
    file already declaring entity-list entries.
    `-Force` does NOT authorize overwriting a foreign-authored tenant
    object, and it does NOT suppress `Conflict` rows -- that meaning was
    split out to `-OverwriteForeignAuthor` by ADR 0053 (a switch this
    IPPS-surface script does not carry, because
    `Get-InsiderRiskEntityList` returns no authorship field to diff
    against).
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
    ./scripts/Deploy-IRMEntityLists.ps1 -WhatIf

    Connect read-only and emit the plan table; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-IRMEntityLists.ps1

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
        `data-plane/irm/entity-lists.schema.json`
        (JSON Schema Draft-07) at script start.
        Reference:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\irm\entity-lists.yaml'),

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

function ConvertTo-DesiredEntityListHash {
    # Normalize a desired-state YAML entry into a comparable hashtable.
    # entities: null means key absent (do-not-manage); empty array means
    # desired-empty. Both the desired and tenant arrays are sorted/lowercased
    # before comparison to make the diff order-insensitive.
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $entitiesNormalized = $null
    if ($Entry.ContainsKey('entities') -and ($null -ne $Entry.entities)) {
        $entitiesNormalized = @($Entry.entities |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object)
    }

    return @{
        name        = [string]$Entry.name
        type        = [string]$Entry.type
        displayName = if ($Entry.ContainsKey('displayName') -and
                          (-not [string]::IsNullOrEmpty($Entry.displayName))) {
                          [string]$Entry.displayName
                      } else { $null }
        description = if ($Entry.ContainsKey('description') -and
                          (-not [string]::IsNullOrEmpty($Entry.description))) {
                          [string]$Entry.description
                      } else { $null }
        entities    = $entitiesNormalized
    }
}

function ConvertTo-TenantEntityListHash {
    # Normalize a Get-InsiderRiskEntityList result into the same comparable
    # shape as ConvertTo-DesiredEntityListHash.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    param([Parameter(Mandatory = $true)]$EntityList)

    $entitiesNormalized = @()
    if ($null -ne $EntityList.Entities -and @($EntityList.Entities).Count -gt 0) {
        $entitiesNormalized = @($EntityList.Entities |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object)
    }

    return @{
        name        = [string]$EntityList.Name
        type        = if ($null -ne $EntityList.Type) { [string]$EntityList.Type } else { $null }
        displayName = if ($null -ne $EntityList.DisplayName -and
                          [string]$EntityList.DisplayName -ne '') {
                          [string]$EntityList.DisplayName
                      } else { $null }
        description = if ($null -ne $EntityList.Description -and
                          [string]$EntityList.Description -ne '') {
                          [string]$EntityList.Description
                      } else { $null }
        entities    = $entitiesNormalized
    }
}

function Compare-EntityList {
    # Return a list of field names that differ between desired and tenant.
    # Compares only fields the YAML actually declares -- a missing optional
    # in YAML is treated as "don't manage", not a diff.
    # entities: null (key absent) means do-not-manage; @() (declared empty)
    # means desired-empty and will diff against a non-empty tenant list.
    # type is NOT compared here (immutable after creation per ADR 0039).
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if (-not [string]::IsNullOrEmpty($Desired.displayName)) {
        if ([string]$Desired.displayName -ne [string]$Tenant.displayName) {
            $diffs.Add('displayName') | Out-Null
        }
    }

    if (-not [string]::IsNullOrEmpty($Desired.description)) {
        if ([string]$Desired.description -ne [string]$Tenant.description) {
            $diffs.Add('description') | Out-Null
        }
    }

    # entities: compare only when desired declares the key (null = do-not-manage).
    if ($null -ne $Desired.entities) {
        $desiredStr = $Desired.entities -join '|'
        $tenantStr  = $Tenant.entities  -join '|'
        if ($desiredStr -ne $tenantStr) {
            $diffs.Add('entities') | Out-Null
        }
    }

    return $diffs
}

function Invoke-IRMEntityListExport {
    # Round-trip the live tenant's IRM entity lists back into the YAML's
    # `entityLists:` block (issue #177). Shape copied from
    # Deploy-DLPPolicies.ps1's Invoke-DlpExport, mirroring
    # Deploy-IRMPolicies.ps1's Invoke-IRMPolicyExport.
    #
    # Rows are normalized through ConvertTo-TenantEntityListHash -- the SAME
    # function the comparator consumes -- so export and compare can never
    # disagree about a field's canonical form (notably the lowercased, sorted
    # `entities` list). That is what makes a freshly exported file re-compare
    # all-NoChange by construction.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantEntityLists,
        [switch]$Force
    )

    # YAML-clobber guard. An export overwrites the operator's curated
    # desired state, so a file that already declares entries needs -Force.
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
        if ($existing -and $existing.ContainsKey('entityLists') -and $existing.entityLists -and @($existing.entityLists).Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("Target YAML '{0}' already declares {1} entity-list entries. Re-run with -Force to overwrite." -f $Path, @($existing.entityLists).Count)
            return
        }
    }

    # Preserve the file's curated comment header (every leading blank or
    # comment line up to the first content line).
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
    foreach ($e in ($TenantEntityLists | Sort-Object { [string]$_.Name })) {
        $h = ConvertTo-TenantEntityListHash -EntityList $e

        # `type` is schema-required AND immutable after creation (ADR 0039):
        # it is excluded from the comparator but still feeds the Create splat,
        # so it must survive the round trip. A tenant row without one cannot
        # be represented.
        if ([string]::IsNullOrEmpty($h.type)) {
            Write-Warning ("Skipping tenant entity list '{0}': it reports no Type, which the schema requires and the Create path needs." -f $h.name)
            continue
        }

        # Emit the tracked fields, and only the optional ones the tenant
        # actually carries. `entities` is always emitted: the tenant-side
        # normalizer defaults it to @(), which is the declared-empty form the
        # comparator expects, so omitting it would flip the field to
        # do-not-manage and silently stop reconciling membership.
        $entry = [ordered]@{ name = $h.name; type = $h.type }
        if (-not [string]::IsNullOrEmpty($h.displayName)) { $entry.displayName = $h.displayName }
        if (-not [string]::IsNullOrEmpty($h.description)) { $entry.description = $h.description }
        $entry.entities = @($h.entities)
        $exported += $entry
    }

    $doc = [ordered]@{ entityLists = $exported }
    # WithIndentedSequences indents block-sequence items 2 spaces from their
    # parent key, matching the hand-curated style in the rest of data-plane/
    # and satisfying the default yamllint indentation rule.
    # Reference: https://www.powershellgallery.com/packages/powershell-yaml
    $body = ConvertTo-Yaml $doc -Options WithIndentedSequences

    # Header + body, trailing blanks stripped, explicit LF endings and
    # exactly one trailing newline so yamllint is satisfied regardless of
    # host OS.
    $bodyLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($body -split "`n")) { $bodyLines.Add($line.TrimEnd()) }
    while ($bodyLines.Count -gt 0 -and [string]::IsNullOrEmpty($bodyLines[$bodyLines.Count - 1])) {
        $bodyLines.RemoveAt($bodyLines.Count - 1)
    }
    $finalLines = @($headerLines) + @($bodyLines)
    $content = ($finalLines -join "`n") + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
    Write-Information ("Exported {0} tenant entity lists to '{1}'." -f $exported.Count, $Path) -InformationAction Continue
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
        $schemaPath = Join-Path $scriptRoot '..\data-plane\irm\entity-lists.schema.json'
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

    if ($desiredRoot -and $desiredRoot.ContainsKey('entityLists') -and $desiredRoot.entityLists) {
        $desiredEntries = @($desiredRoot.entityLists | ForEach-Object { ConvertTo-DesiredEntityListHash -Entry ([hashtable]$_) })
    }
    Write-Information ("Desired lists   : {0}" -f $desiredEntries.Count) -InformationAction Continue

    # Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
    #
    # With zero desired entries every live tenant IRM entity list falls out of the
    # orphan match below, so the run would classify the entire set as orphans and
    # delete it. The rationale, the likely causes, and the 2026-07-19 production
    # hit are documented in scripts/modules/PruneGuard.psm1.
    #
    # This whole block is Apply-only, so reaching it already implies Apply mode
    # and the prune switch alone selects the destructive branch. Placed in the
    # desired-state load region so it fires before the tenant is contacted at
    # all -- before `az account show`, before Connect-IPPSSession, and before
    # any write phase.
    if ($PruneMissing.IsPresent) {
        Assert-PruneDesiredSetNotEmpty `
            -DesiredCount   $desiredEntries.Count `
            -ObjectTypeNoun 'IRM entity list' `
            -SourcePath     $Path `
            -CollectionKey  'entityLists'
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

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist
    $tenantLists = @(Get-InsiderRiskEntityList -ErrorAction Stop)
    Write-Information ("Tenant lists    : {0}" -f $tenantLists.Count) -InformationAction Continue

    # Export mode short-circuit (issue #177). Placed after the enumerate and
    # before any planning: an export is a read plus a local file write, so it
    # never builds a plan, never reaches the ADR 0052 gate, and never touches
    # the tenant. The `return` exits through the finally below, so the S&C
    # session is still disconnected.
    if ($mode -eq 'Export') {
        Invoke-IRMEntityListExport -Path $Path -TenantEntityLists $tenantLists -Force:$Force.IsPresent
        return
    }

    # Index tenant entity lists by Name for O(1) lookup.
    $tenantByName = @{}
    foreach ($t in $tenantLists) {
        $tenantByName[[string]$t.Name] = ConvertTo-TenantEntityListHash -EntityList $t
    }
    $desiredNames = @($desiredEntries | ForEach-Object { $_.name })

    # Categorize: Create / Update / NoChange (desired-side) +
    # Orphan (tenant-only).
    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        if ($tenantByName.ContainsKey($d.name)) {
            $diffs = Compare-EntityList -Desired $d -Tenant $tenantByName[$d.name]
            if ($diffs.Count -eq 0) {
                $plan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' })
            } else {
                $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')) })
            }
        } else {
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' })
        }
    }
    foreach ($t in $tenantLists) {
        $tn = [string]$t.Name
        if ($desiredNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $plan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason })
        }
    }

    # ---- ADR 0029: audit-mode short-circuit + SkipNames pre-pass ----
    # `-DirectionPolicy audit` flips $WhatIfPreference for the rest of
    # this script so every $PSCmdlet.ShouldProcess(...) call below
    # returns false. No New-/Set-/Remove- cmdlet writes against the
    # tenant under any circumstance.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
        $WhatIfPreference = $true
    }

    # ADR 0029 direction-policy pass on the entity-list plan.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    # Reference: docs/adr/0039-irm-entity-list-tracked-fields.md
    $script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'

    # ADR 0052: every entity list whose tenant fields this run WILL overwrite.
    # Constructed OUTSIDE the policy test below so the gate can read .Count
    # on it unconditionally -- under `audit` the pass never runs, the list
    # stays empty, and the gate correctly stays silent.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    if ($DirectionPolicy -ne 'audit') {
        foreach ($row in $plan) {
            if ($row.Action -notin @('Create', 'Update', 'NoChange', 'Orphan')) { continue }
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
                    Kind        = 'IRMEntityList'
                    DisplayName = [string]$row.Name
                    Reason      = $decision.Reason
                })
                continue
            }
            if ($row.Action -eq 'Update') {
                $fieldsText = ($row.Reason -replace '^Drift in: ', '')
                if ($DirectionPolicy -eq 'repo-wins') {
                    Write-Warning ("repo-wins overwriting tenant on IRM entity list '{0}' fields: {1}" -f $row.Name, $fieldsText)
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

        foreach ($s in $script:Adr0029Skips) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # ---- Issue #13, guard 2: prune sanity ratio ----
    # Guard 1 (desired-state load region) catches only the total wipe. This
    # catches the near-total one: an entity-lists.yaml that lost most of its
    # entries to a bad merge, or a -Path pointing at a smaller environment's
    # file, both of which leave a non-zero desired count and so clear guard 1.
    #
    # Keyed on the Orphan set this run would delete against the live entity-
    # list count. Gated on $DirectionPolicy -ne 'audit': this script implements
    # audit mode by flipping $WhatIfPreference (it does NOT empty the orphan
    # rows), so a read-only `-DirectionPolicy audit -PruneMissing` run must not
    # be refused by the ratio guard. Sits inside the enclosing try/finally and
    # before the ADR 0052 gate, so a refusal still runs the finally that
    # disconnects the S&C session.
    # Reference: scripts/modules/PruneGuard.psm1
    if ($PruneMissing.IsPresent -and $DirectionPolicy -ne 'audit') {
        Assert-PruneRatioWithinThreshold `
            -PruneCount     @($plan | Where-Object { $_.Action -eq 'Orphan' }).Count `
            -LiveCount      @($tenantLists).Count `
            -ObjectTypeNoun 'IRM entity list' `
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
    # Suppressed by -Force, by an explicit -Confirm:$false (the CI path), and
    # skipped under -WhatIf so a dry run still previews the deletes without
    # blocking on input. `-DirectionPolicy audit` sets $WhatIfPreference above,
    # so an audit run cannot prompt either.
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
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} IRM entity list(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
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
        $pruneQuery = "-PruneMissing will DELETE {0} orphan IRM entity list(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
            $pruneNames.Count, ($pruneNames -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
            throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    # Execute each plan row under ShouldProcess.
    # Reference: https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
    # Issue #13: orphan prune failures are reported via Write-PruneFailure
    # (Write-Warning plus an '::error::' annotation, not Write-Error, which
    # shell: pwsh's $ErrorActionPreference='stop' would promote to terminating
    # and abandon the remaining orphans) and collected here; a single aggregate
    # throw after the loop names every failure so a failed prune exits non-zero.
    $pruneFailures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($row in $plan) {
        $target = "IRM entity list '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $opDesc = 'New-InsiderRiskEntityList ({0})' -f $row.Desired.type
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-insiderriskentitylist
                        $splat = @{ Name = $row.Desired.name; Type = $row.Desired.type }
                        if (-not [string]::IsNullOrEmpty($row.Desired.displayName)) { $splat.DisplayName  = $row.Desired.displayName }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Description  = $row.Desired.description }
                        if ($null -ne $row.Desired.entities -and $row.Desired.entities.Count -gt 0) { $splat.Entities = $row.Desired.entities }
                        New-InsiderRiskEntityList @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $opDesc = 'Set-InsiderRiskEntityList'
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-insiderriskentitylist
                        $splat = @{ Identity = $row.Desired.name }
                        if (-not [string]::IsNullOrEmpty($row.Desired.displayName)) { $splat.DisplayName  = $row.Desired.displayName }
                        if (-not [string]::IsNullOrEmpty($row.Desired.description)) { $splat.Description  = $row.Desired.description }
                        if ($null -ne $row.Desired.entities) { $splat.Entities = $row.Desired.entities }
                        Set-InsiderRiskEntityList @splat -ErrorAction Stop | Out-Null
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
            'Orphan' {
                if ($PruneMissing.IsPresent) {
                    if ($PSCmdlet.ShouldProcess($target, 'Remove-InsiderRiskEntityList')) {
                        try {
                            # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-insiderriskentitylist
                            Remove-InsiderRiskEntityList -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                            $report.Add([pscustomobject]@{ Category = 'Removed'; Name = $row.Name; Reason = $row.Reason })
                        } catch {
                            $report.Add([pscustomobject]@{ Category = 'Failed'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                            Write-PruneFailure ("Remove IRM entity list '{0}' failed: {1}" -f $row.Name, $_.Exception.Message)
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
        throw ("Reconciliation aborted: {0} orphan IRM entity list(s) could not be removed: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
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

# Emit the categorized plan. Categories: Created / Updated / Removed for
# completed writes; Create / Update / Orphan for -WhatIf rows; NoChange
# for in-sync; Failed for caught exceptions; Skipped for ADR 0029 skips.
$report
