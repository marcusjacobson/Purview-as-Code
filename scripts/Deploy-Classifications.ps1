#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview custom classifications (Data Map
    `type` typedefs) and classification rules (Scanning data plane)
    against `data-plane/classifications/classifications.yaml`.

.DESCRIPTION
    Phase 1+2 reconciler per ADR 0026. The YAML file is the desired
    state. This script performs:

      1. GET current classification typedefs (Atlas types/typedefs,
         filtered to `type=classification`) and classification rules
         (Scanning `/scan/classificationrules`).
      2. Diff desired vs. tenant by `name` for both kinds.
      3. Emit a per-object plan table:
           Create / Update / NoChange / Orphan / Conflict.
      4. Apply only authorized actions (`-WhatIf`, `-PruneMissing`,
         `-Force`) using per-write `$PSCmdlet.ShouldProcess(...)`.
      5. Support deterministic `-ExportCurrentState` to hydrate the YAML.

    Apply ordering:
      A rule's `classificationName` foreign-keys to a classification
      type. Apply runs Types first (Create/Update), then Rules
      (Create/Update). On prune, Rules are removed first, then Types,
      so the foreign key never dangles.

    Plan-phase validation:
      * Every rule's `classificationName` must resolve to a type
        present either in YAML or already in the tenant. An orphan
        reference aborts the plan with a named error before any write.
      * Every Regex rule pattern (both row-level `regex.pattern` and
        each `columnPatterns[].pattern`) is validated for shape per
        `.github/instructions/sample-data.instructions.md` section "Regex
        rules for classification patterns":
          - Must be anchored (`^`, `$`, or `\b`).
          - Must not be unanchored AND contain unbounded `.*` / `.+`.
          - Must not contain nested unbounded quantifiers such as
            `(x+)+`, `(x*)*`, `(x+)*`, `(.+)*`.
        A regex-safety violation aborts the plan.

    System filter:
      Tenant classification types with the prefix `MICROSOFT.` are
      Microsoft-shipped system types. They are stripped from
      enumeration entirely (never reported as Orphan, never proposed
      for deletion). Mirrors the `System*` ruleset filter convention
      used by `Deploy-Scans.ps1` per PR #619.

    Out of scope (Phase 3+4, separate item):
      * `-DirectionPolicy` / `-SkipNames` ADR 0029 wiring.
      * Sensitive-information-type bridging (Microsoft SIT GUIDs in
        rule `classificationName` references).
      * Smoke wrapper, runbook, solution doc, full ADR 0029 Pester
        decision matrix.

    YAML schema:
      classifications:
        - name: <namespace>.<TypeName>   # composite key, case-insensitive
          description: <text>            # optional
          category: <free-form tag>      # optional, YAML-only metadata;
                                         # never sent to Atlas (Atlas
                                         # category is always
                                         # CLASSIFICATION) and never
                                         # compared against tenant.
      rules:
        - name: <namespace>.<RuleName>   # composite key, case-insensitive
          classificationName: <type>     # must resolve in Plan phase
          description: <text>            # optional
          ruleStatus: Enabled|Disabled   # default Enabled
          kind: Regex                    # Phase 1+2: Regex only
          minimumPercentageMatch: <int>  # 0..100, default 60
          regex:
            pattern: '<anchored, bounded regex>'
            regexFlags:
              ignoreCase: true|false     # default true
              multiline: true|false      # default false
          columnPatterns:
            - kind: Regex
              pattern: '<anchored, bounded regex>'

    References:
      Atlas types/typedefs REST (corrects scaffold `/types` → `/type`
      semantics; the Atlas endpoint exposes `/types/typedefs`):
        https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/types
      Type REST (per-typedef GET / DELETE):
        https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type
      Classification rules REST:
        https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules
      Purview API auth:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      Custom classifications and classification rules:
        https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule
      ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012 (-ParametersFile contract):
        docs/adr/0012-environment-parameters-file.md
      ADR 0026 (this reconciler):
        docs/adr/0026-glossary-custom-classifications-reconciler.md
      Regex safety rules:
        .github/instructions/sample-data.instructions.md

.PARAMETER Path
    Desired-state YAML path. Defaults to
    `data-plane/classifications/classifications.yaml`.

.PARAMETER PruneMissing
    Remove tenant types/rules not present in YAML. Default `$false`.

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
    Apply parameter set only. Permit `Update` writes against tenant
    classification types and rules whose authorship (`updatedBy` /
    `modifiedBy` / `createdBy`) differs from the current deploy principal.
    Without it, such an object is reported as a `Conflict` row and left
    untouched.
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
    Export live tenant classification typedefs and rules to YAML and
    exit. Makes no writes to Purview.

.PARAMETER ParametersFile
    Environment parameters YAML path (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved from repo root.

.PARAMETER AccountName
    Purview account name. When omitted, resolved from
    `purviewAccountName` in `-ParametersFile`.

.EXAMPLE
    ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -WhatIf

.EXAMPLE
    ./scripts/Deploy-Classifications.ps1 -AccountName purview-contoso-lab -ExportCurrentState
#>
# ConfirmImpact = 'High' is load-bearing, not decorative. PowerShell only
# raises a ShouldProcess confirmation when ConfirmImpact >= $ConfirmPreference,
# and $ConfirmPreference defaults to 'High'. This script shipped 'Medium'
# until ADR 0052, so every $PSCmdlet.ShouldProcess(...) call below returned
# $true without ever prompting. Do not lower it back to 'Medium'.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\classifications\classifications.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

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

# Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules
# Pinned per ADR 0026 Decision item 2 (all three endpoints share 2023-09-01).
$script:TypesApiVersion = '2023-09-01'
$script:RulesApiVersion = '2023-09-01'

# Microsoft-shipped classification typedefs use the `MICROSOFT.` namespace
# prefix (verified against tenant 2026-06-15: 211/212 defs match this
# prefix; the 1 remainder was operator-authored). Strip from enumeration
# so the reconciler never proposes to manage or delete them. Mirrors the
# `System*` ruleset filter convention in `Deploy-Scans.ps1` (PR #619).
$script:SystemTypeNamePrefixes = @('MICROSOFT.')

# Atlas typedef fields the GET returns that the POST/PUT body must not
# carry and that the desired-state YAML must not carry. Stripping these
# symmetrically before comparison guarantees deterministic round-trips.
$script:TypeComputedFields = @(
    'guid', 'createTime', 'createdBy', 'updateTime', 'updatedBy',
    'version', 'typeVersion', 'lastModifiedTS',
    'serviceType', 'subTypes', 'options',
    'attributeDefs', 'superTypes', 'entityTypes'
)

# YAML-only metadata fields stripped from both desired and tenant sides
# (never sent to Atlas, never read back). `category` here refers to the
# free-form repo tag, not the Atlas `category` enum (always
# `CLASSIFICATION` for classification typedefs).
$script:TypeYamlOnlyFields = @('category')

# Scanning classification-rule fields the GET returns that the PUT body
# must not carry. Tenant rule shapes wrap user-settable values inside a
# `properties` block.
$script:RuleComputedFields = @(
    'id', 'systemData', 'lastModifiedTS', 'version',
    'createdBy', 'createdAt', 'modifiedBy', 'modifiedAt'
)

#region Helpers — generic

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
        foreach ($item in $Value) { $list.Add((ConvertTo-CanonicalValue -Value $item)) | Out-Null }
        return $list.ToArray()
    }
    return $Value
}

function ConvertTo-ComparableJson {
    param([AllowNull()]$Value)
    $canonical = ConvertTo-CanonicalValue -Value $Value
    return ($canonical | ConvertTo-Json -Depth 25 -Compress)
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
    param([Parameter(Mandatory = $true)]$Raw)
    foreach ($c in @($Raw.updatedBy, $Raw.modifiedBy, $Raw.createdBy)) {
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
    # classification AT SOURCE: the row was never emitted, the type/rule fell
    # through to a plain Update, and the portal-authored object was silently
    # overwritten with no record anywhere in the drift report.
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
    $last = Get-LastModifiedByIdentity -Raw $TenantRaw
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

function Test-IsSystemType {
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($p in $script:SystemTypeNamePrefixes) {
        if ($Name -like "$p*") { return $true }
    }
    return $false
}

#endregion

#region Helpers — regex safety
# Reference: .github/instructions/sample-data.instructions.md
#   section "Regex rules for classification patterns"
# Reference: https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule

function Test-RegexSafetyViolation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Context
    )
    $violations = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($Pattern)) {
        $violations.Add(("{0}: pattern is empty." -f $Context)) | Out-Null
        return $violations.ToArray()
    }
    # Strip non-capturing-group prefixes like `(?i)` / `(?m)` for the
    # anchor check so an inline-flag prefix does not count as a non-anchor.
    $stripped = $Pattern -replace '^\(\?[a-zA-Z]+\)', ''
    $hasAnchor = ($stripped -match '\^' -or $stripped -match '\$' -or $stripped -match '\\b' -or $stripped -match '\\B')
    $hasUnbounded = ($stripped -match '\.\*' -or $stripped -match '\.\+')
    if (-not $hasAnchor -and $hasUnbounded) {
        $violations.Add(("{0}: pattern is unanchored AND contains unbounded '.*' / '.+'. Add a `^` / `$` / `\b` anchor or replace `.*` with `.{{0,N}}`." -f $Context)) | Out-Null
    }
    if (-not $hasAnchor) {
        $violations.Add(("{0}: pattern has no `^`, `$`, or `\b` anchor. Anchor the pattern to avoid cross-cell substring matches." -f $Context)) | Out-Null
    }
    # Catastrophic-backtracking shapes: nested unbounded quantifiers.
    # Examples flagged: (x+)+, (x*)*, (x+)*, (x*)+, (.+)*, (.*)+
    if ($Pattern -match '\([^)]*[+*]\)[+*]') {
        $violations.Add(("{0}: pattern contains a nested unbounded quantifier (e.g., (x+)+, (x*)*, (.+)*). Refactor to bounded repetition." -f $Context)) | Out-Null
    }
    return $violations.ToArray()
}

function Test-RuleRegexSafety {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Rule)
    $violations = New-Object 'System.Collections.Generic.List[string]'
    $name = [string]$Rule.name
    $kind = if ($Rule.ContainsKey('kind')) { [string]$Rule.kind } else { 'Regex' }
    if ($kind -ne 'Regex') {
        # Phase 1+2: only Regex rules are supported. Non-Regex (e.g. SIT
        # bridging) is deferred to a follow-up item.
        $violations.Add(("Rule '{0}': kind '{1}' is not supported in Phase 1+2 (Regex only)." -f $name, $kind)) | Out-Null
        return $violations.ToArray()
    }
    if (-not ($Rule.ContainsKey('regex') -and $Rule.regex)) {
        $violations.Add(("Rule '{0}': missing required block 'regex'." -f $name)) | Out-Null
        return $violations.ToArray()
    }
    $regex = [hashtable]$Rule.regex
    if (-not $regex.ContainsKey('pattern')) {
        $violations.Add(("Rule '{0}': missing required field 'regex.pattern'." -f $name)) | Out-Null
    } else {
        foreach ($v in (Test-RegexSafetyViolation -Pattern ([string]$regex.pattern) -Context ("Rule '{0}' regex.pattern" -f $name))) {
            $violations.Add($v) | Out-Null
        }
    }
    if ($Rule.ContainsKey('columnPatterns') -and $Rule.columnPatterns) {
        $i = 0
        foreach ($cp in $Rule.columnPatterns) {
            $cph = [hashtable]$cp
            $ctx = ("Rule '{0}' columnPatterns[{1}].pattern" -f $name, $i)
            if (-not $cph.ContainsKey('pattern')) {
                $violations.Add(("{0}: missing required field 'pattern'." -f $ctx)) | Out-Null
            } else {
                foreach ($v in (Test-RegexSafetyViolation -Pattern ([string]$cph.pattern) -Context $ctx)) {
                    $violations.Add($v) | Out-Null
                }
            }
            $i++
        }
    }
    return $violations.ToArray()
}

#endregion

#region Helpers — type hashing

function ConvertTo-DesiredTypeHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Type)
    if (-not $Type.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$Type.name)) {
        throw "Classification entry is missing required field 'name'."
    }
    $out = @{ name = [string]$Type.name }
    if ($Type.ContainsKey('description') -and $null -ne $Type.description) {
        $out['description'] = [string]$Type.description
    }
    return $out
}

function ConvertTo-TenantTypeHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Type)
    $h = ($Type | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    $out = @{}
    foreach ($key in $h.Keys) {
        $name = [string]$key
        if ($script:TypeComputedFields -contains $name) { continue }
        if ($script:TypeYamlOnlyFields -contains $name) { continue }
        if ($name -eq 'category') { continue }  # Atlas enum, never compared
        $out[$name] = $h[$key]
    }
    return $out
}

function Compare-TypeHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @('name', 'description')) {
        $d = if ($Desired.ContainsKey($k)) { [string]$Desired[$k] } else { '' }
        $t = if ($Tenant.ContainsKey($k))  { [string]$Tenant[$k]  } else { '' }
        if ($d -ne $t) { $diffs.Add($k) | Out-Null }
    }
    return $diffs.ToArray()
}

#endregion

#region Helpers — rule hashing

function Get-RuleProperty {
    param([Parameter(Mandatory = $true)]$Raw)
    # Scanning classification-rule GETs wrap user-settable values inside
    # `properties`; PUT bodies use the same wrapping. Normalize so both
    # the desired and tenant sides compare as flat hashtables.
    if ($Raw -is [System.Collections.IDictionary] -and $Raw.ContainsKey('properties') -and $Raw.properties) {
        return [hashtable]$Raw.properties
    }
    return [hashtable]$Raw
}

function ConvertTo-DesiredRuleHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Rule)
    if (-not $Rule.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$Rule.name)) {
        throw "Classification rule entry is missing required field 'name'."
    }
    if (-not $Rule.ContainsKey('classificationName') -or [string]::IsNullOrWhiteSpace([string]$Rule.classificationName)) {
        throw ("Classification rule '{0}' is missing required field 'classificationName'." -f $Rule.name)
    }
    $out = @{
        name               = [string]$Rule.name
        kind               = if ($Rule.ContainsKey('kind')) { [string]$Rule.kind } else { 'Regex' }
        classificationName = [string]$Rule.classificationName
        ruleStatus         = if ($Rule.ContainsKey('ruleStatus')) { [string]$Rule.ruleStatus } else { 'Enabled' }
        minimumPercentageMatch = if ($Rule.ContainsKey('minimumPercentageMatch')) { [int]$Rule.minimumPercentageMatch } else { 60 }
    }
    if ($Rule.ContainsKey('description') -and $null -ne $Rule.description) {
        $out['description'] = [string]$Rule.description
    }
    if ($Rule.ContainsKey('regex') -and $Rule.regex) {
        $rh = [hashtable]$Rule.regex
        $reg = @{ pattern = [string]$rh.pattern }
        if ($rh.ContainsKey('regexFlags') -and $rh.regexFlags) {
            $rf = [hashtable]$rh.regexFlags
            $flags = @{}
            foreach ($fk in @('ignoreCase', 'multiline')) {
                if ($rf.ContainsKey($fk)) { $flags[$fk] = [bool]$rf[$fk] }
            }
            if ($flags.Count -gt 0) { $reg['regexFlags'] = $flags }
        }
        $out['regex'] = $reg
    }
    if ($Rule.ContainsKey('columnPatterns') -and $Rule.columnPatterns) {
        $cps = New-Object 'System.Collections.Generic.List[object]'
        foreach ($cp in $Rule.columnPatterns) {
            $cph = [hashtable]$cp
            $entry = @{
                kind    = if ($cph.ContainsKey('kind')) { [string]$cph.kind } else { 'Regex' }
                pattern = [string]$cph.pattern
            }
            $cps.Add($entry) | Out-Null
        }
        $out['columnPatterns'] = $cps.ToArray()
    }
    return $out
}

function ConvertTo-TenantRuleHash {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Rule)
    $top = ($Rule | ConvertTo-Json -Depth 25 | ConvertFrom-Json -AsHashtable)
    $props = Get-RuleProperty -Raw $top
    $out = @{
        name = [string]$top.name
        kind = [string]$top.kind
    }
    foreach ($k in @('classificationName', 'ruleStatus', 'description')) {
        if ($props.ContainsKey($k) -and $null -ne $props[$k]) { $out[$k] = [string]$props[$k] }
    }
    if ($props.ContainsKey('minimumPercentageMatch') -and $null -ne $props.minimumPercentageMatch) {
        $out['minimumPercentageMatch'] = [int]$props.minimumPercentageMatch
    }
    if (-not $out.ContainsKey('ruleStatus')) { $out['ruleStatus'] = 'Enabled' }
    if (-not $out.ContainsKey('minimumPercentageMatch')) { $out['minimumPercentageMatch'] = 60 }
    if ($props.ContainsKey('regex') -and $props.regex) {
        $rh = [hashtable]$props.regex
        $reg = @{ pattern = [string]$rh.pattern }
        if ($rh.ContainsKey('regexFlags') -and $rh.regexFlags) {
            $rf = [hashtable]$rh.regexFlags
            $flags = @{}
            foreach ($fk in @('ignoreCase', 'multiline')) {
                if ($rf.ContainsKey($fk)) { $flags[$fk] = [bool]$rf[$fk] }
            }
            if ($flags.Count -gt 0) { $reg['regexFlags'] = $flags }
        }
        $out['regex'] = $reg
    }
    if ($props.ContainsKey('columnPatterns') -and $props.columnPatterns) {
        $cps = New-Object 'System.Collections.Generic.List[object]'
        foreach ($cp in $props.columnPatterns) {
            $cph = [hashtable]$cp
            $entry = @{
                kind    = if ($cph.ContainsKey('kind')) { [string]$cph.kind } else { 'Regex' }
                pattern = [string]$cph.pattern
            }
            $cps.Add($entry) | Out-Null
        }
        $out['columnPatterns'] = $cps.ToArray()
    }
    return $out
}

function Compare-RuleHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $diffs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in @('name', 'kind', 'classificationName', 'ruleStatus', 'description')) {
        $d = if ($Desired.ContainsKey($k)) { [string]$Desired[$k] } else { '' }
        $t = if ($Tenant.ContainsKey($k))  { [string]$Tenant[$k]  } else { '' }
        if ($d -ne $t) { $diffs.Add($k) | Out-Null }
    }
    foreach ($k in @('minimumPercentageMatch')) {
        $d = if ($Desired.ContainsKey($k)) { [int]$Desired[$k] } else { 0 }
        $t = if ($Tenant.ContainsKey($k))  { [int]$Tenant[$k]  } else { 0 }
        if ($d -ne $t) { $diffs.Add($k) | Out-Null }
    }
    foreach ($k in @('regex', 'columnPatterns')) {
        $d = if ($Desired.ContainsKey($k)) { ConvertTo-ComparableJson -Value $Desired[$k] } else { 'null' }
        $t = if ($Tenant.ContainsKey($k))  { ConvertTo-ComparableJson -Value $Tenant[$k]  } else { 'null' }
        if ($d -ne $t) { $diffs.Add($k) | Out-Null }
    }
    return $diffs.ToArray()
}

#endregion

#region Helpers — tenant enumeration

function Get-TenantClassificationType {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/types/get-typedefs
    $uri = "$BaseUri/datamap/api/atlas/v2/types/typedefs?type=classification&api-version=$ApiVersion"
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
    return @($resp.classificationDefs)
}

function Get-TenantClassificationRule {
    param(
        [Parameter(Mandatory = $true)][string]$ScanBaseUri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][string]$ApiVersion
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules/list-all
    $uri = "$ScanBaseUri/classificationrules?api-version=$ApiVersion"
    $items = New-Object 'System.Collections.Generic.List[object]'
    do {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $Headers -ErrorAction Stop
        if ($resp.value) { foreach ($v in $resp.value) { $items.Add($v) | Out-Null } }
        $uri = if ($resp.PSObject.Properties.Match('nextLink').Count -gt 0) { $resp.nextLink } else { $null }
    } while ($uri)
    return $items.ToArray()
}

#endregion

#region Helpers — export

function ConvertTo-ClassificationsExportDoc {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Types,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Rules
    )
    $typesOrdered = @($Types | Sort-Object -Property { $_.name.ToLowerInvariant() })
    $rulesOrdered = @($Rules | Sort-Object -Property { $_.name.ToLowerInvariant() })
    return [ordered]@{
        classifications = @($typesOrdered | ForEach-Object {
            $entry = [ordered]@{ name = $_.name }
            if ($_.ContainsKey('description')) { $entry['description'] = $_.description }
            $entry
        })
        rules = @($rulesOrdered | ForEach-Object {
            $entry = [ordered]@{
                name               = $_.name
                classificationName = $_.classificationName
                ruleStatus         = $_.ruleStatus
                kind               = $_.kind
                minimumPercentageMatch = $_.minimumPercentageMatch
            }
            if ($_.ContainsKey('description')) { $entry['description'] = $_.description }
            if ($_.ContainsKey('regex')) {
                $rh = [hashtable]$_.regex
                $reg = [ordered]@{ pattern = [string]$rh.pattern }
                if ($rh.ContainsKey('regexFlags')) {
                    $rfo = [ordered]@{}
                    foreach ($fk in @('ignoreCase', 'multiline')) {
                        if ($rh.regexFlags.ContainsKey($fk)) { $rfo[$fk] = [bool]$rh.regexFlags[$fk] }
                    }
                    $reg['regexFlags'] = $rfo
                }
                $entry['regex'] = $reg
            }
            if ($_.ContainsKey('columnPatterns')) {
                $entry['columnPatterns'] = @($_.columnPatterns | ForEach-Object {
                    [ordered]@{ kind = $_.kind; pattern = $_.pattern }
                })
            }
            $entry
        })
    }
}

function Invoke-ClassificationsExport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Types,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable[]]$Rules,
        [Parameter(Mandatory = $true)][bool]$ForceOverwrite
    )
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw
        $hasBody = $false
        if ($existing) {
            try {
                $existingDoc = $existing | ConvertFrom-Yaml -ErrorAction Stop
                if ($existingDoc -and (
                    ($existingDoc.ContainsKey('classifications') -and $existingDoc.classifications -and $existingDoc.classifications.Count -gt 0) -or
                    ($existingDoc.ContainsKey('rules') -and $existingDoc.rules -and $existingDoc.rules.Count -gt 0)
                )) {
                    $hasBody = $true
                }
            } catch { $hasBody = $false }
        }
        if ($hasBody -and -not $ForceOverwrite) {
            Write-Error ("Target YAML '{0}' already declares classifications or rules. Re-run with -Force to overwrite." -f $Path)
            return
        }
    }
    $headerLines = @()
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match '^\s*$' -or $line -match '^\s*#') { $headerLines += $line } else { break }
        }
    }
    $doc = ConvertTo-ClassificationsExportDoc -Types $Types -Rules $Rules
    $body = ConvertTo-Yaml $doc
    $nl = [Environment]::NewLine
    $output = if ($headerLines.Count) { ($headerLines -join $nl) + $nl + $body } else { $body }
    Set-Content -LiteralPath $Path -Value $output -Encoding utf8
    Write-Information ("Exported {0} type(s) and {1} rule(s) to '{2}'." -f $Types.Count, $Rules.Count, $Path) -InformationAction Continue
}

#endregion

#region Pre-flight

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the -PruneMissing delete branch cannot be
# entered unattended from a local terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
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

$desiredTypes = @()
$desiredRules = @()
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
    if (-not $desiredRoot.ContainsKey('classifications')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'classifications' (use [] when none)." -f $Path)
        return
    }
    if (-not $desiredRoot.ContainsKey('rules')) {
        Write-Error ("Desired-state YAML '{0}' is missing top-level key 'rules' (use [] when none)." -f $Path)
        return
    }
    $desiredTypes = @($desiredRoot.classifications | ForEach-Object { ConvertTo-DesiredTypeHash -Type ([hashtable]$_) })
    $desiredRules = @($desiredRoot.rules           | ForEach-Object { ConvertTo-DesiredRuleHash -Rule ([hashtable]$_) })
    Write-Information ("Desired         : {0} type(s), {1} rule(s)" -f $desiredTypes.Count, $desiredRules.Count) -InformationAction Continue
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
$scanBaseUri = "$baseUri/scan"
Write-Information ("Endpoint        : {0}" -f $baseUri) -InformationAction Continue

#endregion

#region Enumerate tenant

try {
    $tenantTypesRaw = @(Get-TenantClassificationType -BaseUri $baseUri -Headers $ctx.DataHeaders -ApiVersion $script:TypesApiVersion)
} catch {
    Write-Error ("Failed to list tenant classification types: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
$tenantTypesUserAuthored = @($tenantTypesRaw | Where-Object { -not (Test-IsSystemType -Name ([string]$_.name)) })
Write-Information ("Tenant types    : {0} total, {1} system (filtered), {2} user-authored" -f $tenantTypesRaw.Count, ($tenantTypesRaw.Count - $tenantTypesUserAuthored.Count), $tenantTypesUserAuthored.Count) -InformationAction Continue

try {
    $tenantRulesRaw = @(Get-TenantClassificationRule -ScanBaseUri $scanBaseUri -Headers $ctx.DataHeaders -ApiVersion $script:RulesApiVersion)
} catch {
    Write-Error ("Failed to list tenant classification rules: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
    return
}
Write-Information ("Tenant rules    : {0}" -f $tenantRulesRaw.Count) -InformationAction Continue

#endregion

#region Export branch

if ($mode -eq 'Export') {
    $typeHashes = @($tenantTypesUserAuthored | ForEach-Object { ConvertTo-TenantTypeHash -Type $_ })
    $ruleHashes = @($tenantRulesRaw          | ForEach-Object { ConvertTo-TenantRuleHash -Rule $_ })
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
    if ($PSCmdlet.ShouldProcess($exportTarget, 'Write exported classifications + rules state')) {
        Invoke-ClassificationsExport -Path $exportTarget -Types $typeHashes -Rules $ruleHashes -ForceOverwrite $Force.IsPresent
    } else {
        Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no file written):' -InformationAction Continue
        Write-Information ("  Would write {0} type(s) and {1} rule(s) to '{2}'." -f $typeHashes.Count, $ruleHashes.Count, $exportTarget) -InformationAction Continue
    }
    return
}

#endregion

#region Plan-phase validation

# Regex safety — every Regex rule in desired YAML must pass the validator.
$regexViolations = New-Object 'System.Collections.Generic.List[string]'
foreach ($r in $desiredRules) {
    foreach ($v in (Test-RuleRegexSafety -Rule $r)) { $regexViolations.Add($v) | Out-Null }
}
if ($regexViolations.Count -gt 0) {
    foreach ($v in $regexViolations) { Write-Error $v -ErrorAction Continue }
    Write-Error ("Regex-safety validation failed ({0} violation(s)). Plan aborted before any write. See `.github/instructions/sample-data.instructions.md` section `Regex rules for classification patterns`." -f $regexViolations.Count)
    return
}

# Foreign-key — every rule.classificationName must resolve to a type that
# is either declared in YAML or already present in the tenant (excluding
# system-shipped types we never manage).
$desiredTypeNameSet = @{}
foreach ($t in $desiredTypes) { $desiredTypeNameSet[$t.name.ToLowerInvariant()] = $true }
$tenantUserTypeNameSet = @{}
foreach ($t in $tenantTypesUserAuthored) { $tenantUserTypeNameSet[([string]$t.name).ToLowerInvariant()] = $true }
$orphanRefs = New-Object 'System.Collections.Generic.List[string]'
foreach ($r in $desiredRules) {
    $cn = [string]$r.classificationName
    $key = $cn.ToLowerInvariant()
    if (-not $desiredTypeNameSet.ContainsKey($key) -and -not $tenantUserTypeNameSet.ContainsKey($key)) {
        $orphanRefs.Add(("Rule '{0}' references classificationName '{1}', which is neither declared in YAML nor present in the tenant." -f $r.name, $cn)) | Out-Null
    }
}
if ($orphanRefs.Count -gt 0) {
    foreach ($v in $orphanRefs) { Write-Error $v -ErrorAction Continue }
    Write-Error ("Foreign-key validation failed ({0} orphan classificationName reference(s)). Declare the missing type(s) in YAML or remove the rule. Plan aborted before any write." -f $orphanRefs.Count)
    return
}

# Duplicate-name guards.
foreach ($collectionName in @('types', 'rules')) {
    $coll = if ($collectionName -eq 'types') { $desiredTypes } else { $desiredRules }
    $seen = @{}
    foreach ($entry in $coll) {
        $k = ([string]$entry.name).ToLowerInvariant()
        if ($seen.ContainsKey($k)) {
            Write-Error ("Duplicate {0} name '{1}' in YAML. Names must be unique." -f $collectionName.TrimEnd('s'), $entry.name)
            return
        }
        $seen[$k] = $true
    }
}

#endregion

#region Plan computation

$plan = New-Object 'System.Collections.Generic.List[object]'

$tenantTypeByName = @{}
$tenantTypeRawByName = @{}
foreach ($t in $tenantTypesUserAuthored) {
    $h = ConvertTo-TenantTypeHash -Type $t
    $key = ([string]$h.name).ToLowerInvariant()
    $tenantTypeByName[$key] = $h
    $tenantTypeRawByName[$key] = $t
}

$tenantRuleByName = @{}
$tenantRuleRawByName = @{}
foreach ($r in $tenantRulesRaw) {
    $h = ConvertTo-TenantRuleHash -Rule $r
    if ([string]::IsNullOrWhiteSpace([string]$h.name)) { continue }
    $key = ([string]$h.name).ToLowerInvariant()
    $tenantRuleByName[$key] = $h
    $tenantRuleRawByName[$key] = $r
}

$desiredTypeByName = @{}
foreach ($t in $desiredTypes) { $desiredTypeByName[$t.name.ToLowerInvariant()] = $t }
$desiredRuleByName = @{}
foreach ($r in $desiredRules) { $desiredRuleByName[$r.name.ToLowerInvariant()] = $r }

# Types — Create / Update / NoChange / Conflict.
foreach ($d in ($desiredTypes | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $key = $d.name.ToLowerInvariant()
    if ($tenantTypeByName.ContainsKey($key)) {
        $diffs = Compare-TypeHash -Desired $d -Tenant $tenantTypeByName[$key]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Kind = 'Type'; Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            # ADR 0053: classify authorship first (pure), then let
            # Resolve-ConflictPlanAction decide whether the override authorises
            # the write. The Conflict row is emitted either way.
            $isConflict = Test-ConflictRow -TenantRaw $tenantTypeRawByName[$key] -DeployIdentity $deployIdentity
            $who = if ($isConflict) { [string](Get-LastModifiedByIdentity -Raw $tenantTypeRawByName[$key]) } else { '' }
            $decision = Resolve-ConflictPlanAction `
                -IsConflict $isConflict `
                -OverwriteForeignAuthor $OverwriteForeignAuthor.IsPresent `
                -DriftText ($diffs -join ', ') `
                -Who $who
            $plan.Add([pscustomobject]@{ Kind = 'Type'; Action = $decision.Action; Name = $d.name; Desired = $d; Reason = $decision.Reason; Conflict = $decision.Conflict }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Kind = 'Type'; Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}
# Types — Orphan.
foreach ($t in ($tenantTypeByName.Values | Where-Object { -not $desiredTypeByName.ContainsKey($_.name.ToLowerInvariant()) } | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Kind = 'Type'; Action = 'Orphan'; Name = $t.name; Desired = $null; Reason = $reason }) | Out-Null
}

# Rules — Create / Update / NoChange / Conflict.
foreach ($d in ($desiredRules | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $key = $d.name.ToLowerInvariant()
    if ($tenantRuleByName.ContainsKey($key)) {
        $diffs = Compare-RuleHash -Desired $d -Tenant $tenantRuleByName[$key]
        if ($diffs.Count -eq 0) {
            $plan.Add([pscustomobject]@{ Kind = 'Rule'; Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.' }) | Out-Null
        } else {
            # ADR 0053: classify authorship first (pure), then let
            # Resolve-ConflictPlanAction decide whether the override authorises
            # the write. The Conflict row is emitted either way.
            $isConflict = Test-ConflictRow -TenantRaw $tenantRuleRawByName[$key] -DeployIdentity $deployIdentity
            $who = if ($isConflict) { [string](Get-LastModifiedByIdentity -Raw $tenantRuleRawByName[$key]) } else { '' }
            $decision = Resolve-ConflictPlanAction `
                -IsConflict $isConflict `
                -OverwriteForeignAuthor $OverwriteForeignAuthor.IsPresent `
                -DriftText ($diffs -join ', ') `
                -Who $who
            $plan.Add([pscustomobject]@{ Kind = 'Rule'; Action = $decision.Action; Name = $d.name; Desired = $d; Reason = $decision.Reason; Conflict = $decision.Conflict }) | Out-Null
        }
    } else {
        $plan.Add([pscustomobject]@{ Kind = 'Rule'; Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.' }) | Out-Null
    }
}
# Rules — Orphan.
foreach ($r in ($tenantRuleByName.Values | Where-Object { -not $desiredRuleByName.ContainsKey($_.name.ToLowerInvariant()) } | Sort-Object -Property { $_.name.ToLowerInvariant() })) {
    $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
    $plan.Add([pscustomobject]@{ Kind = 'Rule'; Action = 'Orphan'; Name = $r.name; Desired = $null; Reason = $reason }) | Out-Null
}

#endregion

#region Apply

$report = New-Object 'System.Collections.Generic.List[object]'

function Invoke-TypeUpsert {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][ValidateSet('POST', 'PUT')][string]$Method
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/types/create-typedefs
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/types/update-typedefs
    $def = @{
        category = 'CLASSIFICATION'
        name     = $Desired.name
        superTypes = @()
        attributeDefs = @()
    }
    if ($Desired.ContainsKey('description')) { $def['description'] = $Desired.description }
    $body = @{ classificationDefs = @($def) }
    $uri = "$baseUri/datamap/api/atlas/v2/types/typedefs?api-version=$script:TypesApiVersion"
    $payload = $body | ConvertTo-Json -Depth 10 -Compress
    $null = Invoke-RestMethod -Method $Method -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop
}

function Invoke-TypeDelete {
    param([Parameter(Mandatory = $true)][string]$Name)
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/types/delete-type-by-name
    $uri = "$baseUri/datamap/api/atlas/v2/types/typedef/name/$([uri]::EscapeDataString($Name))?api-version=$script:TypesApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

function ConvertTo-RuleBody {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)
    # Scanning PUT body wraps user-settable values inside `properties`.
    $props = @{
        classificationName     = $Desired.classificationName
        ruleStatus             = $Desired.ruleStatus
        minimumPercentageMatch = $Desired.minimumPercentageMatch
    }
    if ($Desired.ContainsKey('description')) { $props['description'] = $Desired.description }
    if ($Desired.ContainsKey('regex')) { $props['regex'] = $Desired.regex }
    if ($Desired.ContainsKey('columnPatterns')) { $props['columnPatterns'] = $Desired.columnPatterns }
    return @{
        kind       = $Desired.kind
        properties = $props
    }
}

function Invoke-RuleUpsert {
    param([Parameter(Mandatory = $true)][hashtable]$Desired)
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules/create-or-update
    $body = ConvertTo-RuleBody -Desired $Desired
    $uri = "$scanBaseUri/classificationrules/$([uri]::EscapeDataString($Desired.name))?api-version=$script:RulesApiVersion"
    $payload = $body | ConvertTo-Json -Depth 15 -Compress
    $null = Invoke-RestMethod -Method PUT -Uri $uri -Headers $ctx.DataHeaders -Body $payload -ContentType 'application/json' -ErrorAction Stop
}

function Invoke-RuleDelete {
    param([Parameter(Mandatory = $true)][string]$Name)
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules/delete
    $uri = "$scanBaseUri/classificationrules/$([uri]::EscapeDataString($Name))?api-version=$script:RulesApiVersion"
    $null = Invoke-RestMethod -Method DELETE -Uri $uri -Headers $ctx.DataHeaders -ErrorAction Stop
}

function Add-Report {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $report.Add([pscustomobject]@{ Category = $Category; Kind = $Kind; Name = $Name; Reason = $Reason }) | Out-Null
}

# ---- ADR 0052: destructive-operation confirmation gate ----
# The last point before the write loops at which nothing has been written.
# This script is Class B: it declares no -DirectionPolicy, so it has no
# repo-wins overwrite branch and exactly ONE destructive branch -- the
# -PruneMissing delete. That branch is gated here, once per run, via
# $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue prompts
# unconditionally; ShouldProcess only prompts when ConfirmImpact >=
# $ConfirmPreference, which is precisely the comparison that silently
# defeated this gate before issue #85.
#
# The gate is keyed on the PLAN -- the Orphan rows the two delete loops
# below actually iterate (steps 4 and 5) -- and never on a policy.
# $orphans is derived from $plan here and read a few lines later, so it
# cannot diverge from the deletes it speaks for. Both Kinds are counted in
# one prompt: rules and types are deleted in the same run, in reverse
# foreign-key order, and the operator is entitled to see the whole blast
# radius before answering once.
#
# NOTE: -OverwriteForeignAuthor (ADR 0053) is NOT a second destructive
# branch and gets no gate. It grants permission to overwrite a
# foreign-authored object; it does not delete one. ADR 0052's overwrite
# gate is scoped to the -DirectionPolicy repo-wins branch, which this
# script does not have.
#
# Suppressed by -Force, by an explicit -Confirm:$false (the CI path), and
# skipped under -WhatIf so a dry run still previews the deletes without
# blocking on input.
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

$orphans = @($plan | Where-Object { $_.Action -eq 'Orphan' })
if ($PruneMissing.IsPresent -and $orphans.Count -gt 0) {
    $orphanNames = @($orphans | ForEach-Object { '{0} {1}' -f $_.Kind, $_.Name })
    $pruneQuery = "-PruneMissing will DELETE {0} orphan classification object(s) from the Purview account: {1}. This cannot be undone. Continue?" -f `
        $orphanNames.Count, (($orphanNames | Sort-Object) -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

# Apply order:
#   1) Type Create / Update (so rule classificationName foreign keys resolve)
#   2) Type NoChange / Conflict (no-op rows)
#   3) Rule Create / Update / NoChange / Conflict
#   4) Rule Orphan (DELETE rules first, then types — reverse FK order)
#   5) Type Orphan

# Step 1+2: types non-orphan rows.
foreach ($row in ($plan | Where-Object { $_.Kind -eq 'Type' -and $_.Action -ne 'Orphan' })) {
    $target = "Purview classification type '$($row.Name)'"
    switch ($row.Action) {
        'NoChange' { Add-Report -Category 'NoChange' -Kind 'Type' -Name $row.Name -Reason $row.Reason; continue }
        'Conflict' { Add-Report -Category 'Conflict' -Kind 'Type' -Name $row.Name -Reason $row.Reason; continue }
        'Create' {
            if ($PSCmdlet.ShouldProcess($target, 'POST classification typedef (Create)')) {
                try {
                    Invoke-TypeUpsert -Desired $row.Desired -Method 'POST'
                    Add-Report -Category 'Create' -Kind 'Type' -Name $row.Name -Reason $row.Reason
                } catch {
                    Add-Report -Category 'Failed' -Kind 'Type' -Name $row.Name -Reason ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
                }
            } else {
                Add-Report -Category 'Create' -Kind 'Type' -Name $row.Name -Reason $row.Reason
            }
            continue
        }
        'Update' {
            # ADR 0053: an Update that overwrites a foreign-authored type is
            # reported as a Conflict row, never laundered into a plain Update.
            # The switch grants permission, not silence.
            $updateCategory = if ($row.PSObject.Properties['Conflict'] -and $row.Conflict) { 'Conflict' } else { 'Update' }
            if ($PSCmdlet.ShouldProcess($target, 'PUT classification typedef (Update)')) {
                try {
                    Invoke-TypeUpsert -Desired $row.Desired -Method 'PUT'
                    Add-Report -Category $updateCategory -Kind 'Type' -Name $row.Name -Reason $row.Reason
                } catch {
                    Add-Report -Category 'Failed' -Kind 'Type' -Name $row.Name -Reason ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
                }
            } else {
                Add-Report -Category $updateCategory -Kind 'Type' -Name $row.Name -Reason $row.Reason
            }
            continue
        }
    }
}

# Step 3: rules non-orphan rows.
foreach ($row in ($plan | Where-Object { $_.Kind -eq 'Rule' -and $_.Action -ne 'Orphan' })) {
    $target = "Purview classification rule '$($row.Name)'"
    switch ($row.Action) {
        'NoChange' { Add-Report -Category 'NoChange' -Kind 'Rule' -Name $row.Name -Reason $row.Reason; continue }
        'Conflict' { Add-Report -Category 'Conflict' -Kind 'Rule' -Name $row.Name -Reason $row.Reason; continue }
        'Create' {
            if ($PSCmdlet.ShouldProcess($target, 'PUT classification rule (Create)')) {
                try {
                    Invoke-RuleUpsert -Desired $row.Desired
                    Add-Report -Category 'Create' -Kind 'Rule' -Name $row.Name -Reason $row.Reason
                } catch {
                    Add-Report -Category 'Failed' -Kind 'Rule' -Name $row.Name -Reason ("Create failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
                }
            } else {
                Add-Report -Category 'Create' -Kind 'Rule' -Name $row.Name -Reason $row.Reason
            }
            continue
        }
        'Update' {
            # ADR 0053: an Update that overwrites a foreign-authored rule is
            # reported as a Conflict row, never laundered into a plain Update.
            # The switch grants permission, not silence.
            $updateCategory = if ($row.PSObject.Properties['Conflict'] -and $row.Conflict) { 'Conflict' } else { 'Update' }
            if ($PSCmdlet.ShouldProcess($target, 'PUT classification rule (Update)')) {
                try {
                    Invoke-RuleUpsert -Desired $row.Desired
                    Add-Report -Category $updateCategory -Kind 'Rule' -Name $row.Name -Reason $row.Reason
                } catch {
                    Add-Report -Category 'Failed' -Kind 'Rule' -Name $row.Name -Reason ("Update failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
                }
            } else {
                Add-Report -Category $updateCategory -Kind 'Rule' -Name $row.Name -Reason $row.Reason
            }
            continue
        }
    }
}

# Step 4: rule orphans (delete rules before types so FK never dangles).
foreach ($row in ($plan | Where-Object { $_.Kind -eq 'Rule' -and $_.Action -eq 'Orphan' })) {
    $target = "Purview classification rule '$($row.Name)'"
    if (-not $PruneMissing.IsPresent) {
        Add-Report -Category 'Orphan' -Kind 'Rule' -Name $row.Name -Reason $row.Reason
        continue
    }
    if ($PSCmdlet.ShouldProcess($target, 'DELETE classification rule')) {
        try {
            Invoke-RuleDelete -Name $row.Name
            Add-Report -Category 'Removed' -Kind 'Rule' -Name $row.Name -Reason 'Deleted (-PruneMissing).'
        } catch {
            Add-Report -Category 'Failed' -Kind 'Rule' -Name $row.Name -Reason ("Delete failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
        }
    } else {
        Add-Report -Category 'Removed' -Kind 'Rule' -Name $row.Name -Reason 'Would be deleted (-PruneMissing).'
    }
}

# Step 5: type orphans.
foreach ($row in ($plan | Where-Object { $_.Kind -eq 'Type' -and $_.Action -eq 'Orphan' })) {
    $target = "Purview classification type '$($row.Name)'"
    if (-not $PruneMissing.IsPresent) {
        Add-Report -Category 'Orphan' -Kind 'Type' -Name $row.Name -Reason $row.Reason
        continue
    }
    if ($PSCmdlet.ShouldProcess($target, 'DELETE classification typedef')) {
        try {
            Invoke-TypeDelete -Name $row.Name
            Add-Report -Category 'Removed' -Kind 'Type' -Name $row.Name -Reason 'Deleted (-PruneMissing).'
        } catch {
            Add-Report -Category 'Failed' -Kind 'Type' -Name $row.Name -Reason ("Delete failed: {0}" -f (Format-PurviewRestError -ErrorRecord $_))
        }
    } else {
        Add-Report -Category 'Removed' -Kind 'Type' -Name $row.Name -Reason 'Would be deleted (-PruneMissing).'
    }
}

$report

$counts = @{}
foreach ($r in $report) {
    if (-not $counts.ContainsKey($r.Category)) { $counts[$r.Category] = 0 }
    $counts[$r.Category]++
}
$bannerParts = @()
foreach ($k in @('Create', 'Update', 'NoChange', 'Orphan', 'Conflict', 'Removed', 'Failed')) {
    if ($counts.ContainsKey($k)) { $bannerParts += ("{0} {1}" -f $counts[$k], $k) }
}
if ($bannerParts.Count -gt 0) {
    Write-Information ("Plan: {0}" -f ($bannerParts -join ', ')) -InformationAction Continue
} else {
    Write-Information 'Plan: 0 changes.' -InformationAction Continue
}

#endregion
