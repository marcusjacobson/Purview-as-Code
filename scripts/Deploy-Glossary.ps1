#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview business glossary terms against
    `data-plane/glossary/glossary.yaml`.

.DESCRIPTION
    Reconciler per ADR 0026 (Phase 1+2) and issue #644 (Phase 3+4 ADR
    0029 retrofit). The YAML file is the desired state. This script performs:

      1. GET current glossaries + terms from the Data Map data plane.
      2. Diff desired vs. tenant by term `name` within the target
         glossary container.
      3. Emit a per-object plan table:
           Create / Update / NoChange / Orphan / Conflict / Skip.
      4. Apply the ADR 0029 direction-policy pass (audit / portal-wins /
         repo-wins) before any write.
      5. Apply only authorized actions (`-WhatIf`, `-PruneMissing`,
         `-Force`, `-DirectionPolicy`, `-SkipNames`) using per-write
         `$PSCmdlet.ShouldProcess(...)`.
      6. Support deterministic `-ExportCurrentState` to hydrate the YAML.

    Apply ordering:
      The target glossary container must exist before any term POST,
      because the term anchor carries the glossaryGuid. When the target
      glossary is absent the script plans a glossary Create row first,
      then term Create rows; -WhatIf surfaces both. Apply runs glossary
      Create before any term operation.

    Still deferred (separate follow-up):
      * `experts` / `stewards` Entra principal resolution (ADR 0023
        Category 3). These fields are stripped from comparison; a
        future item wires `displayName` resolution.

    YAML schema:
      glossary: <name>          # one container; default name `Glossary`
      terms:
        - name: <unique>        # composite key, case-insensitive
          shortDescription: <text>
          longDescription: <text>           # optional, multi-line
          status: Draft|Approved|Alert|Expired
          expert: []|[<displayName>]        # Phase 3+4 only
          steward: []|[<displayName>]       # Phase 3+4 only

    References:
      Atlas Glossary REST:
        https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary
      Purview API auth:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0026 (this reconciler):
        docs/adr/0026-glossary-custom-classifications-reconciler.md

.PARAMETER Path
    Desired-state YAML path. Defaults to `data-plane/glossary/glossary.yaml`.

.PARAMETER PruneMissing
    Remove tenant terms not present in YAML. Default `$false`.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for. In the
    Export parameter set that guard is `-ExportCurrentState`'s refusal
    to clobber a non-empty managed block in the target YAML. In the
    Apply parameter set it is the ADR 0052 destructive-operation
    confirmation prompt.
    `-Force` does NOT authorize overwriting a foreign-authored tenant
    object, and it does NOT suppress `Conflict` rows -- that meaning was
    split out to `-OverwriteForeignAuthor` by ADR 0053.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER OverwriteForeignAuthor
    Apply parameter set only. Permit `Update` writes against tenant terms
    whose authorship (`updatedBy` / `createdBy`) differs from the current
    deploy principal. Without it, such a term is reported as a `Conflict`
    row and left untouched.
    The `Conflict` row is emitted either way -- this switch authorizes the
    overwrite, it does not hide the finding. A write over a foreign-authored
    object is ALWAYS reported as a `Conflict` row, never laundered into a
    plain `Update`.
    Requires `-DirectionPolicy repo-wins` to have any effect: the direction
    policy and the authorship override are independent axes and both must
    permit the write. Under the default `portal-wins` a drifted object is
    skipped whatever its authorship. Default `$false`.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER ExportCurrentState
    Export live tenant glossary terms to YAML and exit. Makes no writes
    to Purview.

.PARAMETER ParametersFile
    Environment parameters YAML path (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved from repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER AccountName
    Purview account name. When omitted, resolved from `purviewAccountName`
    in `-ParametersFile`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit. No
                         POST / PUT / DELETE writes against the REST
                         surface fire under any circumstance.
      * `portal-wins` -- (default) skip any term whose tracked fields
                         differ; emit a Skip plan row per skipped term
                         and a `[ADR0029-SKIP] <name>` line per skip so
                         an upstream workflow can capture the list.
                         Create / NoChange / Orphan handling unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         term naming the drifted field(s). The overwrite
                         is gated at the SCRIPT layer by the ADR 0052
                         typed-confirmation prompt: it names the terms it
                         is about to overwrite, asks EVERY caller -- local
                         operators included -- and aborts with no tenant
                         writes if declined. Suppress with -Force, or
                         -Confirm:$false as CI does. The workflow's typed
                         `confirm_overwrite_glossary='overwrite portal'`
                         input is an ADDITIONAL gate, not the only one: a
                         clone of this template that has not run kickoff
                         has no CI at all, so the script-layer gate is its
                         only defence.
    Default `portal-wins`.
    Reference: docs/adr/0029-source-of-truth-direction-policy.md.

.PARAMETER SkipNames
    Caller-supplied list of term names to force-skip regardless of
    drift category. A matched name becomes a Skip plan row and emits a
    `[ADR0029-SKIP] <name>` machine-readable marker. Match is
    case-insensitive. `-PruneMissing` still respects `-SkipNames` -- a
    skipped term is never deleted. Names absent from both YAML and
    tenant are silently ignored. Ignored in audit mode. Default `@()`.
    Reference: docs/adr/0029-source-of-truth-direction-policy.md.

.EXAMPLE
    ./scripts/Deploy-Glossary.ps1 -AccountName purview-contoso-lab -WhatIf

.EXAMPLE
    ./scripts/Deploy-Glossary.ps1 -AccountName purview-contoso-lab -ExportCurrentState
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\glossary\glossary.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

    # ADR 0053: the foreign-author overwrite override is its own switch and
    # lives in the Apply parameter set only. The Export path has no tenant
    # object to be authored by anyone, so there is nothing for it to mean there.
    [Parameter(ParameterSetName = 'Apply')]
    [switch]$OverwriteForeignAuthor,

    [Parameter(ParameterSetName = 'Export', Mandatory = $true)]
    [switch]$ExportCurrentState,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [Alias('PurviewAccountName')]
    [string]$AccountName
)

$ErrorActionPreference = 'Stop'

# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary
# Pinned per ADR 0026 Decision item 2.
$script:GlossaryApiVersion = '2023-09-01'

# Server-computed fields that the Atlas glossary GET returns but the POST/PUT
# body must not (and the desired-state YAML must not) carry. Stripping these
# symmetrically before comparison guarantees deterministic round-trips.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/get-term
$script:TermComputedFields = @(
    'guid',
    'qualifiedName',
    'anchor',
    'createTime',
    'createdBy',
    'updateTime',
    'updatedBy',
    'lastModifiedTS',
    'version',
    'classifications',
    'attributes',
    'additionalAttributes'
)
# `experts` and `stewards` are stripped because Phase 1+2 does not resolve
# Entra principal references (ADR 0023 Category 3 wiring is Phase 3+4 scope
# per issue #628). If the live tenant carries populated lists, the export
# walker emits an empty `expert: []` / `steward: []` in YAML and the
# comparator ignores the field; a Phase 3+4 follow-up adds the displayName
# round-trip.
$script:TermDeferredFields = @('experts', 'stewards')

function Get-ComparableTermProperty {
    param([Parameter(Mandatory = $true)][AllowNull()]$Term)

    if ($null -eq $Term) { return @{} }
    if (-not ($Term -is [System.Collections.IDictionary])) { return $Term }

    $out = @{}
    foreach ($key in $Term.Keys) {
        $name = [string]$key
        if ($script:TermComputedFields -contains $name) { continue }
        if ($script:TermDeferredFields -contains $name) { continue }
        $out[$name] = $Term[$key]
    }
    return $out
}

function ConvertTo-DesiredTermHash {
    param([Parameter(Mandatory = $true)][hashtable]$Term)

    if (-not $Term.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$Term.name)) {
        throw "Glossary term entry is missing required field 'name'."
    }
    $out = @{ name = [string]$Term.name }
    foreach ($k in @('shortDescription', 'longDescription', 'status')) {
        if ($Term.ContainsKey($k) -and $null -ne $Term[$k]) {
            $out[$k] = [string]$Term[$k]
        }
    }
    return $out
}

function ConvertTo-TenantTermHash {
    param([Parameter(Mandatory = $true)]$Term)

    $h = ($Term | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    return (Get-ComparableTermProperty -Term $h)
}

function ConvertTo-CanonicalValue {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            $ordered[[string]$key] = ConvertTo-CanonicalValue -Value $Value[$key]
        }
        return $ordered
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $list = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) {
            $list.Add((ConvertTo-CanonicalValue -Value $item)) | Out-Null
        }
        return $list.ToArray()
    }
    return $Value
}

function ConvertTo-ComparableJson {
    param([AllowNull()]$Value)
    $canonical = ConvertTo-CanonicalValue -Value $Value
    return ($canonical | ConvertTo-Json -Depth 25 -Compress)
}

function Compare-TermHash {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'
    $desiredStripped = Get-ComparableTermProperty -Term $Desired
    $tenantStripped  = Get-ComparableTermProperty -Term $Tenant
    foreach ($k in @('name', 'shortDescription', 'longDescription', 'status')) {
        $d = if ($desiredStripped.ContainsKey($k)) { [string]$desiredStripped[$k] } else { '' }
        $t = if ($tenantStripped.ContainsKey($k))  { [string]$tenantStripped[$k]  } else { '' }
        if ($d -ne $t) { $diffs.Add($k) | Out-Null }
    }
    return $diffs.ToArray()
}

function Format-PurviewRestError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $message = $ErrorRecord.Exception.Message
    try {
        if ($ErrorRecord.Exception.Response) {
            $resp = $ErrorRecord.Exception.Response
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    return "HTTP response: $body"
                }
            }
            return $message
        }
    } catch { return $message }
    return $message
}

function Get-LastModifiedByIdentity {
    param([Parameter(Mandatory = $true)]$Term)
    foreach ($c in @($Term.updatedBy, $Term.createdBy)) {
        if ($null -ne $c -and -not [string]::IsNullOrWhiteSpace([string]$c)) { return [string]$c }
    }
    return $null
}

function Test-ConflictRow {
    # ADR 0053: a PURE authorship predicate. It knows nothing about any override
    # switch, by design.
    #
    # Before ADR 0053 this function opened with `if ($ForceEnabled) { return
    # $false }`, bound to $Force.IsPresent -- so -Force suppressed the Conflict
    # classification AT SOURCE: the row was never emitted, the term fell through
    # to a plain Update, and the portal-authored object was silently overwritten
    # with no record anywhere in the drift report.
    #
    # Merely renaming that parameter to -OverwriteForeignAuthor would have kept
    # the defect and relabelled it -- the alternative ADR 0053 section Alternatives-5
    # rejects by name ("the switch grants permission, not silence"). The override
    # decision therefore lives in Resolve-ConflictPlanAction, NOT here.
    param(
        [Parameter(Mandatory = $true)]$TenantRaw,
        [Parameter(Mandatory = $true)][string]$DeployIdentity
    )
    if ([string]::IsNullOrWhiteSpace($DeployIdentity)) { return $false }
    $last = Get-LastModifiedByIdentity -Term $TenantRaw
    if ([string]::IsNullOrWhiteSpace($last)) { return $false }
    return ($last -notlike "*$DeployIdentity*")
}

function Resolve-ConflictPlanAction {
    # ADR 0053: the authorship-override decision, isolated and pure.
    #
    # The Conflict row is emitted whenever authorship differs -- with OR without
    # -OverwriteForeignAuthor. The switch decides only whether the WRITE
    # proceeds; it never buys silence. A write over a foreign-authored object is
    # therefore never laundered into a plain `Update` row.
    #
    # Mirrors Deploy-UnifiedCatalog.ps1's Get-ReconciliationPlan (Mechanism B),
    # which had this shape right from the start.
    param(
        [Parameter(Mandatory = $true)][bool]$IsConflict,
        [Parameter(Mandatory = $true)][bool]$OverwriteForeignAuthor,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$DriftText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Who
    )

    if (-not $IsConflict) {
        return [pscustomobject]@{
            Action   = 'Update'
            Category = 'Update'
            Conflict = $false
            Reason   = ('Drift in: {0}' -f $DriftText)
        }
    }

    if ($OverwriteForeignAuthor) {
        return [pscustomobject]@{
            Action   = 'Update'
            Category = 'Conflict'
            Conflict = $true
            Reason   = ("Drift in: {0}; updatedBy '{1}' differs from deploy principal. Conflict will be overwritten because -OverwriteForeignAuthor was supplied." -f $DriftText, $Who)
        }
    }

    return [pscustomobject]@{
        Action   = 'Conflict'
        Category = 'Conflict'
        Conflict = $true
        Reason   = ("Drift in: {0}; updatedBy '{1}' differs from deploy principal. Re-run with -OverwriteForeignAuthor to overwrite." -f $DriftText, $Who)
    }
}

function Get-TenantGlossary {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/list-glossaries
    $uri = "$BaseUri/datamap/api/atlas/v2/glossary?limit=1000&api-version=$ApiVersion"
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
    return @($resp)
}

function Get-TenantTerm {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion,
        [Parameter(Mandatory = $true)][string]$GlossaryGuid
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/list-terms-by-glossary
    $uri = "$BaseUri/datamap/api/atlas/v2/glossary/$([uri]::EscapeDataString($GlossaryGuid))/terms?limit=1000&api-version=$ApiVersion"
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
    return @($resp)
}

function ConvertTo-GlossaryExportDoc {
    param(
        [Parameter(Mandatory = $true)][string]$GlossaryName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Terms
    )
    $ordered = @($Terms | Sort-Object -Property { $_.name.ToLowerInvariant() })
    return [ordered]@{
        glossary = $GlossaryName
        terms = @($ordered | ForEach-Object {
            $entry = [ordered]@{ name = $_.name }
            foreach ($k in @('shortDescription', 'longDescription', 'status')) {
                if ($_.ContainsKey($k)) { $entry[$k] = $_[$k] }
            }
            # Phase 1+2: emit empty principal lists; Phase 3+4 round-trips displayNames.
            $entry['expert']  = @()
            $entry['steward'] = @()
            $entry
        })
    }
}

function Invoke-GlossaryExport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$GlossaryName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Terms,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
        $hasBody = $false
        if ($existing) {
            try {
                $existingDoc = $existing | ConvertFrom-Yaml -ErrorAction Stop
                if ($existingDoc -and $existingDoc.ContainsKey('terms') -and $existingDoc.terms -and $existingDoc.terms.Count -gt 0) {
                    $hasBody = $true
                }
            } catch { $hasBody = $false }
        }
        if ($hasBody -and -not $ForceOverwrite) {
            Write-Error ("Target YAML '{0}' already declares terms. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }
    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }
    $doc = ConvertTo-GlossaryExportDoc -GlossaryName $GlossaryName -Terms $Terms
    $body = ConvertTo-Yaml $doc
    $nl = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} term(s) from glossary '{1}' to '{2}'." -f $Terms.Count, $GlossaryName, $Path) -InformationAction Continue
}

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

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

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
if (-not $parameters -or -not $parameters.ContainsKey('purviewAccountName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'purviewAccountName'." -f $ParametersFile)
    return
}
if (-not $AccountName) { $AccountName = [string]$parameters.purviewAccountName }

$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $AccountName) -InformationAction Continue
Write-Information ("YAML path       : {0}" -f $Path) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
if ($mode -eq 'Apply') {
    Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
    Write-Information ("SkipNames count : {0}" -f $SkipNames.Count) -InformationAction Continue
}

$desiredGlossaryName = $null
$desiredTerms = @()
if ($mode -eq 'Apply') {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error ("Desired-state YAML not found at '{0}'." -f $Path)
        return
    }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    $desiredRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
    if (-not $desiredRoot) {
        Write-Error ("Desired-state YAML '{0}' parsed as empty." -f $Path)
        return
    }
    if (-not $desiredRoot.ContainsKey('glossary') -or [string]::IsNullOrWhiteSpace([string]$desiredRoot.glossary)) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'glossary'." -f $Path)
        return
    }
    if (-not $desiredRoot.ContainsKey('terms')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'terms' (use [] when none)." -f $Path)
        return
    }
    $desiredGlossaryName = [string]$desiredRoot.glossary
    $desiredTerms = @($desiredRoot.terms | ForEach-Object { ConvertTo-DesiredTermHash -Term ([hashtable]$_) })
    Write-Information ("Desired         : glossary '{0}' with {1} term(s)" -f $desiredGlossaryName, $desiredTerms.Count) -InformationAction Continue
}

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
$deployIdentity = [string]$account.user.name
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

$connectScript = Join-Path $scriptRoot 'Connect-Purview.ps1'
if (-not (Test-Path -LiteralPath $connectScript)) {
    Write-Error ("Helper not found: '{0}'." -f $connectScript)
    return
}
$ctx = & $connectScript -AccountName $AccountName
if (-not $ctx -or -not $ctx.DataHeaders -or -not $ctx.Endpoint) {
    Write-Error 'Connect-Purview.ps1 did not return data-plane headers.'
    return
}
$baseUri = $ctx.Endpoint
Write-Information ("Endpoint        : {0}" -f $baseUri) -InformationAction Continue

# --- Enumerate tenant state ---
try {
    $tenantGlossaries = @(Get-TenantGlossary -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:GlossaryApiVersion)
} catch {
    Write-Error ("Failed to list tenant glossaries: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
Write-Information ("Tenant          : {0} glossary/glossaries" -f $tenantGlossaries.Count) -InformationAction Continue

# Pick the target glossary (case-insensitive name match). If absent in Apply
# mode, it will be planned for Create. In Export mode an empty tenant exports
# the YAML scaffold with 0 terms under the requested name.
$targetGlossary = $null
$targetGlossaryName = if ($mode -eq 'Apply') { $desiredGlossaryName } else { 'Glossary' }
if ($tenantGlossaries.Count -gt 0) {
    $targetGlossary = $tenantGlossaries | Where-Object { [string]$_.name -ieq $targetGlossaryName } | Select-Object -First 1
}

$tenantTermsRaw = @()
if ($targetGlossary) {
    try {
        $tenantTermsRaw = @(Get-TenantTerm -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:GlossaryApiVersion -GlossaryGuid ([string]$targetGlossary.guid))
    } catch {
        Write-Error ("Failed to list terms for glossary '{0}': {1}" -f $targetGlossaryName, (Format-PurviewRestError -ErrorRecord $_))
        return
    }
}
Write-Information ("Tenant terms    : {0} in glossary '{1}'" -f $tenantTermsRaw.Count, $targetGlossaryName) -InformationAction Continue

# --- Export branch ---
if ($mode -eq 'Export') {
    $tenantTermHashes = @($tenantTermsRaw | ForEach-Object { ConvertTo-TenantTermHash -Term $_ })
    $exportTarget = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) {
            Write-Error ("Parent directory does not exist: '{0}'." -f $parent)
            return
        }
        Join-Path ((Resolve-Path -LiteralPath $parent).Path) (Split-Path -Leaf $Path)
    }
    if ($PSCmdlet.ShouldProcess($exportTarget, 'Write exported glossary state')) {
        Invoke-GlossaryExport -Path $exportTarget -GlossaryName $targetGlossaryName -Terms $tenantTermHashes -ForceOverwrite $Force.IsPresent
    } else {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no file written):' -InformationAction Continue
        Write-Information ("  Would write {0} term(s) under glossary '{1}' to '{2}'." -f $tenantTermHashes.Count, $targetGlossaryName, $exportTarget) -InformationAction Continue
    }
    return
}

# --- Plan (Apply mode) ---
$plan = New-Object 'System.Collections.Generic.List[object]'

# Glossary container plan row. If absent, will be Created before any term op.
if (-not $targetGlossary) {
    $plan.Add([pscustomobject]@{ Kind = 'Glossary'; Action = 'Create'; Name = $targetGlossaryName; Desired = @{ name = $targetGlossaryName }; Reason = 'Glossary container absent from tenant.' }) | Out-Null
} else {
    $plan.Add([pscustomobject]@{ Kind = 'Glossary'; Action = 'NoChange'; Name = $targetGlossaryName; Desired = $null; Reason = 'Glossary container exists.' }) | Out-Null
}

$desiredByName = @{}
foreach ($t in $desiredTerms) {
    $key = $t.name.ToLowerInvariant()
    if ($desiredByName.ContainsKey($key)) {
        Write-Error ("Duplicate term name '{0}' in YAML. Names must be unique within a glossary." -f $t.name)
        return
    }
    $desiredByName[$key] = $t
}

$tenantByName = @{}
$tenantRawByName = @{}
foreach ($t in $tenantTermsRaw) {
    $h = ConvertTo-TenantTermHash -Term $t
    if (-not $h.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$h.name)) { continue }
    $key = ([string]$h.name).ToLowerInvariant()
    $tenantByName[$key] = $h
    $tenantRawByName[$key] = $t
}

foreach ($d in ($desiredTerms | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $key = $d.name.ToLowerInvariant()
    if ($tenantByName.ContainsKey($key)) {
        $diffs = Compare-TermHash -Desired $d -Tenant $tenantByName[$key]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Kind = 'Term'; Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            # ADR 0053: classify authorship first (pure), then let
            # Resolve-ConflictPlanAction decide whether the override authorises
            # the write. The Conflict row is emitted either way.
            $isConflict = Test-ConflictRow -TenantRaw $tenantRawByName[$key] -DeployIdentity $deployIdentity
            $who = if ($isConflict) { [string](Get-LastModifiedByIdentity -Term $tenantRawByName[$key]) } else { '' }
            $decision = Resolve-ConflictPlanAction `
                -IsConflict $isConflict `
                -OverwriteForeignAuthor $OverwriteForeignAuthor.IsPresent `
                -DriftText ($diffs -join ', ') `
                -Who $who
            $plan.Add([pscustomobject]@{ Kind = 'Term'; Action = $decision.Action; Name = $d.name; Desired = $d; Reason = $decision.Reason; Conflict = $decision.Conflict }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Kind = 'Term'; Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}
foreach ($t in ($tenantByName.Values | Where-Object { -not $desiredByName.ContainsKey($_.name.ToLowerInvariant()) } | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Kind = 'Term'; Action = 'Orphan'; Name = $t.name; Desired = $null; Reason = $reason }) | Out-Null
}

#region ADR 0029 direction-policy pass

# Audit short-circuit: `-DirectionPolicy audit` flips $WhatIfPreference
# for the rest of this script so every $PSCmdlet.ShouldProcess(...)
# call in the apply loop returns false. No POST / PUT / DELETE writes
# fire under any circumstance, while the categorized plan is preserved.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
if ($DirectionPolicy -eq 'audit') {
    Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.' -InformationAction Continue
    $WhatIfPreference = $true
}

# Direction-policy pass on Term rows. -SkipNames matches any row
# category; portal-wins drift arbitration applies to Update rows only.
# The Glossary container row (Kind='Glossary') is intentionally excluded
# -- the container is infrastructure, not a managed term.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
$script:Adr0029Skips = New-Object 'System.Collections.Generic.List[object]'

# ADR 0052: every glossary term whose tenant fields this run WILL overwrite.
# Constructed OUTSIDE the policy test below so the gate can read .Count on
# it unconditionally -- under `audit` the pass never runs, the list stays
# empty, and the gate correctly stays silent.
$repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

if ($DirectionPolicy -ne 'audit') {
    foreach ($row in $plan) {
        if ($row.Kind -ne 'Term') { continue }
        if ($row.Action -notin @('Create', 'Update', 'NoChange', 'Orphan', 'Conflict')) { continue }
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
                Kind        = 'Term'
                DisplayName = [string]$row.Name
                Reason      = $decision.Reason
            })
            continue
        }
        if ($row.Action -eq 'Update') {
            $fieldsText = ($row.Reason -replace '^Drift in: ', '')
            if ($DirectionPolicy -eq 'repo-wins') {
                Write-Warning ("repo-wins overwriting tenant on glossary term '{0}' fields: {1}" -f $row.Name, $fieldsText)
            }
            # Every Update row that survived the Skip decision WILL be PUT,
            # whatever policy let it through -- an ADR 0053 Conflict row that
            # -OverwriteForeignAuthor promoted to Update included. Collect it here,
            # OUTSIDE the repo-wins test above: the ADR 0052 gate is keyed on this
            # list -- the plan -- and never on $DirectionPolicy. Populating it only
            # under repo-wins would leave the list empty under portal-wins, the
            # plan-keyed gate would see zero, and the overwrite would proceed
            # unconfirmed. See ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON
            # THE POLICY".
            $repoWinsOverwrites.Add([string]$row.Name) | Out-Null
        }
    }
    # Machine-readable marker per skipped term for the workflow's
    # auto-PR step. Format must match `^\[ADR0029-SKIP\] (.+)$`.
    foreach ($s in $script:Adr0029Skips) {
        Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
    }
}

#endregion

#region ADR 0052 destructive-operation confirmation gate

# The last point before the apply loops at which nothing has been written.
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
    $overwriteQuery = "This run will OVERWRITE tenant fields on {0} glossary term(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
        $overwriteNames.Count, ($overwriteNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
        throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# Derived from the FINAL plan one line above the gate and read one line
# later, so it cannot diverge from the deletes it speaks for. Only Term rows
# are ever orphaned -- the Glossary container row is infrastructure and is
# never deleted.
$pruneTargets = @($plan | Where-Object { $_.Kind -eq 'Term' -and $_.Action -eq 'Orphan' })
if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
    $pruneNames = @($pruneTargets | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    $pruneQuery = "-PruneMissing will DELETE {0} orphan glossary term(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
        $pruneNames.Count, ($pruneNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

#endregion

# --- Apply ---
$report = New-Object 'System.Collections.Generic.List[object]'

function Invoke-GlossaryCreate {
    param([Parameter(Mandatory = $true)][string]$Name)
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/create
    $uri = "$baseUri/datamap/api/atlas/v2/glossary?api-version=$script:GlossaryApiVersion"
    $payload = @{ name = $Name; qualifiedName = $Name } | ConvertTo-Json -Depth 5 -Compress
    return Invoke-RestMethod -Method POST -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop
}

function Invoke-TermCreate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][string]$GlossaryGuid
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/create-term
    $body = @{
        name = $Desired.name
        anchor = @{ glossaryGuid = $GlossaryGuid }
    }
    foreach ($k in @('shortDescription', 'longDescription', 'status')) {
        if ($Desired.ContainsKey($k)) { $body[$k] = $Desired[$k] }
    }
    $uri = "$baseUri/datamap/api/atlas/v2/glossary/term?api-version=$script:GlossaryApiVersion"
    $payload = $body | ConvertTo-Json -Depth 10 -Compress
    $null = Invoke-RestMethod -Method POST -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop
}

function Invoke-TermUpdate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)]$TenantRaw
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/update-term
    $guid = [string]$TenantRaw.guid
    $body = @{
        name = $Desired.name
        anchor = @{ glossaryGuid = [string]$TenantRaw.anchor.glossaryGuid }
    }
    foreach ($k in @('shortDescription', 'longDescription', 'status')) {
        if ($Desired.ContainsKey($k)) { $body[$k] = $Desired[$k] }
    }
    $uri = "$baseUri/datamap/api/atlas/v2/glossary/term/$([uri]::EscapeDataString($guid))?api-version=$script:GlossaryApiVersion"
    $payload = $body | ConvertTo-Json -Depth 10 -Compress
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop
}

function Invoke-TermDelete {
    param([Parameter(Mandatory = $true)]$TenantRaw)
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary/delete-term
    $guid = [string]$TenantRaw.guid
    $uri = "$baseUri/datamap/api/atlas/v2/glossary/term/$([uri]::EscapeDataString($guid))?api-version=$script:GlossaryApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

# Process the glossary Create row first so subsequent term rows can use the
# new guid. NoChange row is a no-op.
$activeGlossaryGuid = if ($targetGlossary) { [string]$targetGlossary.guid } else { $null }
foreach ($row in $plan) {
    if ($row.Kind -ne 'Glossary') { continue }
    if ($row.Action -eq 'Create') {
        if ($PSCmdlet.ShouldProcess("Purview glossary '$($row.Name)'", 'POST glossary (Create)')) {
            try {
                $created = Invoke-GlossaryCreate -Name $row.Name
                $activeGlossaryGuid = [string]$created.guid
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Glossary'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            } catch {
                $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Glossary'; Name = $row.Name; Reason = ("Glossary Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
            }
        } else {
            $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Glossary'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
        }
    } else {
        $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Glossary'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
    }
}

foreach ($row in $plan) {
    if ($row.Kind -ne 'Term') { continue }
    $target = "Purview glossary term '$($row.Name)'"
    switch ($row.Action) {
        'NoChange' {
            $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Skip' {
            # ADR 0029 portal-wins drift skip or -SkipNames pre-pass.
            # Reported but never written; -PruneMissing is bypassed.
            $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Conflict' {
            $report.Add([pscustomobject]@{ Category = 'Conflict'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            continue
        }
        'Create' {
            if (-not $activeGlossaryGuid) {
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Term'; Name = $row.Name; Reason = ("Would be created after glossary '{0}' is provisioned." -f $targetGlossaryName) }) | Out-Null
                continue
            }
            if ($PSCmdlet.ShouldProcess($target, 'POST glossary term (Create)')) {
                try {
                    Invoke-TermCreate -Desired $row.Desired -GlossaryGuid $activeGlossaryGuid
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Term'; Name = $row.Name; Reason = ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Update' {
            # ADR 0053: an Update that overwrites a foreign-authored term is
            # reported as a Conflict row, never laundered into a plain Update.
            # The switch grants permission, not silence.
            $updateCategory = if ($row.PSObject.Properties['Conflict'] -and $row.Conflict) { 'Conflict' } else { 'Update' }
            if ($PSCmdlet.ShouldProcess($target, 'PUT glossary term (Update)')) {
                try {
                    Invoke-TermUpdate -Desired $row.Desired -TenantRaw $tenantRawByName[$row.Name.ToLowerInvariant()]
                    $report.Add([pscustomobject]@{ Category = $updateCategory; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Term'; Name = $row.Name; Reason = ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = $updateCategory; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
            }
            continue
        }
        'Orphan' {
            if (-not $PruneMissing.IsPresent) {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Term'; Name = $row.Name; Reason = $row.Reason }) | Out-Null
                continue
            }
            if ($PSCmdlet.ShouldProcess($target, 'DELETE glossary term')) {
                try {
                    Invoke-TermDelete -TenantRaw $tenantRawByName[$row.Name.ToLowerInvariant()]
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Term'; Name = $row.Name; Reason = 'Deleted (-PruneMissing).' }) | Out-Null
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Term'; Name = $row.Name; Reason = ("Delete failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_)) }) | Out-Null
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Term'; Name = $row.Name; Reason = 'Would be deleted (-PruneMissing).' }) | Out-Null
            }
            continue
        }
    }
}

$report

$counts = @{}
foreach ($r in $report) {
    if (-not $counts.ContainsKey($r.Category)) { $counts[$r.Category] = 0 }
    $counts[$r.Category]++
}
$bannerParts = @()
foreach ($k in @('Create', 'Update', 'NoChange', 'Orphan', 'Conflict', 'Skip', 'Removed', 'Failed')) {
    if ($counts.ContainsKey($k)) { $bannerParts += ("{0} {1}" -f $counts[$k], $k) }
}
if ($bannerParts.Count -gt 0) {
    Write-Information ("Plan: {0}" -f ($bannerParts -join ', ')) -InformationAction Continue
} else {
    Write-Information 'Plan: 0 changes.' -InformationAction Continue
}