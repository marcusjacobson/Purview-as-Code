#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Data Loss Prevention (DLP) compliance
    policies and their nested rules against
    `data-plane/dlp/policies.yaml` (desired state).

.DESCRIPTION
    Wave 2b declarative reconciler for Microsoft Purview DLP policies.
    The YAML is the central source of truth: any add / update / remove
    of a DLP policy or one of its rules flows through this script,
    which converges the live tenant to match. Sibling of
    `scripts/Set-AuditRetentionPolicy.ps1` (same auth path, same
    drift vocabulary, same export contract).

    The script connects to Security & Compliance PowerShell via the
    lab automation identity (Key Vault-signed JWT, see ADR 0011),
    reads the desired-state YAML, schema-validates it, enumerates
    tenant policies via `Get-DlpCompliancePolicy` and rules via
    `Get-DlpComplianceRule`, resolves sensitivity-label display names
    to immutable GUIDs via `Get-Label`, diffs each tracked field, and
    applies the categorized plan under `ShouldProcess` (`-WhatIf` /
    `-Confirm`). `-PruneMissing` enables removal of tenant policies
    and rules absent from the YAML. `-ExportCurrentState` round-trips
    the live tenant back into the YAML's `policies:` block.

    Drift contract (per `.github/instructions/powershell.instructions.md`
    "Drift report format"):

      1. GET every policy via `Get-DlpCompliancePolicy` and every rule
         via `Get-DlpComplianceRule`.
      2. Match desired vs. tenant by `Name` (policy) and by
         (policy name, rule name) for rules.
      3. Diff each desired entry against the tenant copy.
      4. Emit a categorized report:
            Create   -- in YAML; not in tenant.
            Update   -- in both; tracked fields differ.
            NoChange -- in both; tracked fields identical.
            Orphan   -- in tenant; not in YAML. Written only with
                        -PruneMissing.
      5. Act only on categories the caller has authorized
         (-WhatIf / -PruneMissing).

    References (Microsoft Learn):
      Microsoft Purview DLP overview:
        https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp
      Create, test, and tune a DLP policy:
        https://learn.microsoft.com/en-us/purview/dlp-test-dlp-policies
      Get-DlpCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy
      New-DlpCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
      Set-DlpCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy
      Remove-DlpCompliancePolicy:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-dlpcompliancepolicy
      Get-DlpComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancerule
      New-DlpComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule
      Set-DlpComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancerule
      Remove-DlpComplianceRule:
        https://learn.microsoft.com/en-us/powershell/module/exchange/remove-dlpcompliancerule
      Get-Label (sensitivity label resolution):
        https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
      Connect-IPPSSession (S&C PowerShell):
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
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
      ADR 0031 (DLP AdvancedRule YAML shape):
        docs/adr/0031-dlp-advancedrule-yaml-shape.md
      ADR 0032 (DLP generic Locations YAML shape):
        docs/adr/0032-dlp-generic-locations-shape.md

.PARAMETER Path
    Path to the desired-state YAML. Defaults to the in-repo location
    `data-plane/dlp/policies.yaml`.

.PARAMETER PruneMissing
    Allow removal of tenant DLP policies and rules that are not declared
    in the YAML. Default $false.

.PARAMETER Force
    With -ExportCurrentState: allow overwriting a `policies:` block that
    already contains entries.

.PARAMETER ExportCurrentState
    Read every DLP policy + its rules visible to the connected app,
    write to the YAML's `policies:` block, and exit. Makes no writes
    to the tenant.

.PARAMETER ParametersFile
    Path to the environment parameters YAML (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER VaultName
    Key Vault that holds the automation certificate.

.PARAMETER CertificateName
    Key Vault certificate (and key) object name.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010).

.PARAMETER TenantDomain
    Tenant primary domain passed to `Connect-IPPSSession -Organization`.

.PARAMETER DirectionPolicy
    Source-of-truth direction for shared-property drift between the
    desired YAML and the live tenant. One of:
      * `audit`       -- read-only verification. Build the plan,
                         emit the categorized report, and exit.
                         No New-/Set-/Remove-DlpCompliancePolicy or
                         *Rule call fires under any circumstance.
                         Equivalent to a forced -WhatIf at the script
                         boundary.
      * `portal-wins` -- (default) skip any shared policy or rule whose
                         tracked fields differ; emit a Skip plan row
                         per skipped object and a `[ADR0029-SKIP]
                         <name>` line per skip so an upstream workflow
                         can capture the list for an auto-PR. Create /
                         Update / NoChange and orphan handling are
                         unchanged.
      * `repo-wins`   -- apply the full plan including shared-property
                         drift. Emit one Write-Warning per overwritten
                         shared object naming the drifted field(s).
                         The typed-confirmation gate
                         ('overwrite portal') is a CI-layer concern
                         enforced by the workflow per ADR 0029; local
                         script callers are operator-trusted.
    Default `portal-wins`. Reference:
    `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipNames
    Internal contract used by the workflow's `portal-wins` skip-drift
    logic to pass a pre-computed skip list to the script. When set,
    each named policy / rule that would otherwise drift is emitted as
    a Skip plan row instead of an Update row (reason: "explicitly
    skipped by caller"). NoChange, Create, and Orphan rows are
    unaffected. Names not present in the YAML or the tenant are
    silently ignored (defends against a stale skip list from the
    workflow). The match is case-insensitive and tests against the
    policy `Name` (for policy-level entries) and the rule `Name`
    (for rule-level entries); composite `Policy\Rule` keys are NOT
    matched. Ignored in `-DirectionPolicy audit` mode. Default `@()`.
    Reference: `docs/adr/0029-source-of-truth-direction-policy.md`.

.PARAMETER SkipSchemaValidation
    Bypass schema validation of the desired-state YAML. Do not use in CI.

.EXAMPLE
    ./scripts/Deploy-DLPPolicies.ps1 -WhatIf

    Connect read-only and emit the plan table for what an apply would
    do; make no remote writes.

.EXAMPLE
    ./scripts/Deploy-DLPPolicies.ps1

    Reconcile the tenant against the YAML. Without -PruneMissing,
    tenant-only policies and rules are reported as Orphan and skipped.

.EXAMPLE
    ./scripts/Deploy-DLPPolicies.ps1 -PruneMissing -WhatIf

    Show every Create / Update / Remove the reconciler would perform.

.EXAMPLE
    ./scripts/Deploy-DLPPolicies.ps1 -ExportCurrentState

    Round-trip the live tenant's DLP policies back into the YAML's
    `policies:` block.

.NOTES
    Caller role requirements (the local principal running this script):
      * Active `az login` session (CLI is the JWT signing transport).
      * `Key Vault Crypto User` on the target vault (keys/sign).
      * `Key Vault Certificate User` on the target vault (certs/get).

    Data-plane Entra app prerequisites (one-time per tenant):
      * App-role `Office 365 Exchange Online > Exchange.ManageAsApp`
        granted with admin consent.
      * Entra directory role `Compliance Administrator` assigned at
        directoryScopeId='/'.

    Output: a list of PSCustomObjects with columns Category / Kind /
    Name / Reason. Suitable for capture to `$GITHUB_STEP_SUMMARY` or
    a file. No credential material is printed.
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
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\dlp\policies.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$Force,

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
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'


#region Helpers

function ConvertFrom-AdvancedRuleWire {
    # Parse Microsoft's wire JSON for AdvancedRule into the normalized
    # YAML hash shape from ADR 0031. The wire shape is:
    #   { Version, Condition: { Operator, SubConditions: [{ ConditionName,
    #     Value: [{ Operator, Groups: [{ Name, Operator, Sensitivetypes:
    #     [{ Name, Id, Mincount?, Maxcount?, Confidencelevel?,
    #        Minconfidence?, Maxconfidence?, Classifiertype? }] }] }] }] } }
    # Returns @{ Recognized = $bool; Normalized = [ordered]; Reason = $str }.
    # Reference: docs/adr/0031-dlp-advancedrule-yaml-shape.md "Lossless-transform claim".
    param([Parameter(Mandatory = $true)][object]$Wire)

    function Format-UnrecognizedAdvancedRuleResult { param([string]$why) @{ Recognized = $false; Normalized = $null; Reason = $why } }

    try {
        if ($Wire -is [string]) {
            $obj = $Wire | ConvertFrom-Json -ErrorAction Stop
        } else {
            $obj = $Wire
        }
    } catch {
        return (Format-UnrecognizedAdvancedRuleResult ("AdvancedRule body did not parse as JSON: {0}" -f $_.Exception.Message))
    }

    if (-not $obj) { return (Format-UnrecognizedAdvancedRuleResult 'AdvancedRule body parsed as null.') }
    if ([string]$obj.Version -ne '1.0')             { return (Format-UnrecognizedAdvancedRuleResult ("Unexpected AdvancedRule.Version='{0}' (expected '1.0')." -f $obj.Version)) }
    if (-not $obj.Condition)                        { return (Format-UnrecognizedAdvancedRuleResult 'AdvancedRule body missing Condition wrapper.') }
    if ([string]$obj.Condition.Operator -ne 'And')  { return (Format-UnrecognizedAdvancedRuleResult ("Unexpected Condition.Operator='{0}' (expected 'And')." -f $obj.Condition.Operator)) }
    $subs = [object[]]@($obj.Condition.SubConditions)
    if ($subs.Count -ne 1)                          { return (Format-UnrecognizedAdvancedRuleResult ("Expected exactly one SubCondition, got {0}." -f $subs.Count)) }
    $sub = $subs[0]
    if ([string]$sub.ConditionName -ne 'ContentContainsSensitiveInformation') {
        return (Format-UnrecognizedAdvancedRuleResult ("Unsupported SubCondition.ConditionName='{0}' (only ContentContainsSensitiveInformation is modeled today)." -f $sub.ConditionName))
    }
    $vals = [object[]]@($sub.Value)
    if ($vals.Count -ne 1)                          { return (Format-UnrecognizedAdvancedRuleResult ("Expected exactly one SubCondition.Value entry, got {0}." -f $vals.Count)) }
    $val = $vals[0]
    $outerOp = [string]$val.Operator
    if ($outerOp -notin @('And','Or'))              { return (Format-UnrecognizedAdvancedRuleResult ("Unsupported outer Operator='{0}'." -f $outerOp)) }

    $groupResults = [System.Collections.ArrayList]::new()
    foreach ($g in @($val.Groups)) {
        if (-not $g) { continue }
        $op = [string]$g.Operator
        if ($op -notin @('And','Or')) { return (Format-UnrecognizedAdvancedRuleResult ("Unsupported group Operator='{0}' on group '{1}'." -f $op, $g.Name)) }
        $sitResults   = [System.Collections.ArrayList]::new()
        $clsfrResults = [System.Collections.ArrayList]::new()
        foreach ($st in @($g.Sensitivetypes)) {
            if (-not $st) { continue }
            $id = [string]$st.Id
            if (-not $id) { $id = [string]$st.Name }
            if (-not $id -or $id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { continue }
            $guid = $id.ToLowerInvariant()
            $name = [string]$st.Name
            $hasClassifier = -not [string]::IsNullOrEmpty([string]$st.Classifiertype)
            if ($hasClassifier) {
                $tc = [ordered]@{}
                $tc['guid'] = $guid
                if ($name -and $name -ne $id) { $tc['name'] = $name }
                [void]$clsfrResults.Add($tc)
            } else {
                $so = [ordered]@{}
                $so['guid'] = $guid
                if ($name -and $name -ne $id)            { $so['name']            = $name }
                if ($null -ne $st.Mincount)              { $so['minCount']        = [int]$st.Mincount }
                if ($null -ne $st.Maxcount)              { $so['maxCount']        = [int]$st.Maxcount }
                if (-not [string]::IsNullOrEmpty([string]$st.Confidencelevel)) { $so['confidenceLevel'] = [string]$st.Confidencelevel }
                if ($null -ne $st.Minconfidence)         { $so['minConfidence']   = [int]$st.Minconfidence }
                if ($null -ne $st.Maxconfidence)         { $so['maxConfidence']   = [int]$st.Maxconfidence }
                [void]$sitResults.Add($so)
            }
        }
        if ($sitResults.Count -eq 0 -and $clsfrResults.Count -eq 0) {
            return (Format-UnrecognizedAdvancedRuleResult ("Group '{0}' contained no recognizable Sensitivetypes entries." -f $g.Name))
        }
        $ge = [ordered]@{}
        $ge['name']     = [string]$g.Name
        $ge['operator'] = $op
        if ($sitResults.Count   -gt 0) { $ge['sensitiveInfoTypes']   = [object[]]$sitResults.ToArray() }
        if ($clsfrResults.Count -gt 0) { $ge['trainableClassifiers'] = [object[]]$clsfrResults.ToArray() }
        [void]$groupResults.Add($ge)
    }
    if ($groupResults.Count -eq 0) {
        return (Format-UnrecognizedAdvancedRuleResult 'AdvancedRule body parsed but produced zero recognizable groups.')
    }

    $normalized = [ordered]@{}
    $normalized['outerOperator'] = $outerOp
    $normalized['groups']        = [object[]]$groupResults.ToArray()
    return @{ Recognized = $true; Normalized = $normalized; Reason = $null }
}

function ConvertTo-NormalizedAdvancedRule {
    # Take an `advancedRule` block from YAML and return the canonical
    # [ordered] hash shape used by the comparator and the apply path.
    # Lowercases GUIDs, drops empty optional fields, preserves group
    # and entry order (Microsoft's evaluation honors order).
    # Reference: docs/adr/0031-dlp-advancedrule-yaml-shape.md.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Source)

    $groupResults = [System.Collections.ArrayList]::new()
    foreach ($g in @($Source['groups'])) {
        if (-not $g) { continue }
        $gh = $g
        $ge = [ordered]@{}
        $ge['name']     = [string]$gh['name']
        $ge['operator'] = [string]$gh['operator']

        if ($gh.Contains('sensitiveInfoTypes') -and $gh['sensitiveInfoTypes']) {
            $sitResults = [System.Collections.ArrayList]::new()
            foreach ($sit in @($gh['sensitiveInfoTypes'])) {
                $sh = $sit
                $o  = [ordered]@{}
                $o['guid'] = ([string]$sh['guid']).ToLowerInvariant()
                if ($sh.Contains('name') -and $sh['name'])                                  { $o['name']            = [string]$sh['name'] }
                if ($sh.Contains('minCount'))                                               { $o['minCount']        = [int]$sh['minCount'] }
                if ($sh.Contains('maxCount'))                                               { $o['maxCount']        = [int]$sh['maxCount'] }
                if ($sh.Contains('confidenceLevel') -and $sh['confidenceLevel'])            { $o['confidenceLevel'] = [string]$sh['confidenceLevel'] }
                if ($sh.Contains('minConfidence'))                                          { $o['minConfidence']   = [int]$sh['minConfidence'] }
                if ($sh.Contains('maxConfidence'))                                          { $o['maxConfidence']   = [int]$sh['maxConfidence'] }
                [void]$sitResults.Add($o)
            }
            if ($sitResults.Count -gt 0) { $ge['sensitiveInfoTypes'] = [object[]]$sitResults.ToArray() }
        }

        if ($gh.Contains('trainableClassifiers') -and $gh['trainableClassifiers']) {
            $tcResults = [System.Collections.ArrayList]::new()
            foreach ($tc in @($gh['trainableClassifiers'])) {
                $th = $tc
                $o  = [ordered]@{}
                $o['guid'] = ([string]$th['guid']).ToLowerInvariant()
                if ($th.Contains('name') -and $th['name']) { $o['name'] = [string]$th['name'] }
                [void]$tcResults.Add($o)
            }
            if ($tcResults.Count -gt 0) { $ge['trainableClassifiers'] = [object[]]$tcResults.ToArray() }
        }

        [void]$groupResults.Add($ge)
    }

    $out = [ordered]@{}
    $out['outerOperator'] = [string]$Source['outerOperator']
    $out['groups']        = [object[]]$groupResults.ToArray()
    return $out
}

function ConvertTo-AdvancedRuleWire {
    # Serialize a normalized `advancedRule` hash back into the wire
    # JSON shape Microsoft's New-/Set-DlpComplianceRule accepts via
    # the -AdvancedRule parameter. Reconstructs the three constant
    # wrappers (Version, Condition.Operator, ConditionName) per ADR 0031
    # "Captured-field coverage" table.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$AdvancedRule)

    $wireGroups = @()
    foreach ($g in @($AdvancedRule.groups)) {
        $wireSits = @()
        foreach ($s in @($g.sensitiveInfoTypes)) {
            if (-not $s) { continue }
            $w = [ordered]@{}
            if ($s.Contains('name') -and $s.name) { $w.Name = [string]$s.name } else { $w.Name = [string]$s.guid }
            $w.Id = [string]$s.guid
            if ($s.Contains('minCount'))        { $w.Mincount        = [int]$s.minCount }
            if ($s.Contains('maxCount'))        { $w.Maxcount        = [int]$s.maxCount }
            if ($s.Contains('confidenceLevel')) { $w.Confidencelevel = [string]$s.confidenceLevel }
            if ($s.Contains('minConfidence'))   { $w.Minconfidence   = [int]$s.minConfidence }
            if ($s.Contains('maxConfidence'))   { $w.Maxconfidence   = [int]$s.maxConfidence }
            $wireSits += $w
        }
        foreach ($c in @($g.trainableClassifiers)) {
            if (-not $c) { continue }
            $w = [ordered]@{}
            if ($c.Contains('name') -and $c.name) { $w.Name = [string]$c.name } else { $w.Name = [string]$c.guid }
            $w.Id            = [string]$c.guid
            $w.Classifiertype = 'MLModel'
            $wireSits += $w
        }
        $wireGroups += [ordered]@{
            Name           = [string]$g.name
            Operator       = [string]$g.operator
            Sensitivetypes = $wireSits
        }
    }

    $doc = [ordered]@{
        Version   = '1.0'
        Condition = [ordered]@{
            Operator     = 'And'
            SubConditions = @(
                [ordered]@{
                    ConditionName = 'ContentContainsSensitiveInformation'
                    Value         = @(
                        [ordered]@{
                            Operator = [string]$AdvancedRule.outerOperator
                            Groups   = $wireGroups
                        }
                    )
                }
            )
        }
    }
    return $doc | ConvertTo-Json -Depth 12 -Compress:$false
}

function ConvertTo-NormalizedAdvancedRuleJson {
    # Produce a stable, key-sorted, whitespace-free JSON string from a
    # normalized advancedRule hash. Used by Compare-DlpRule for an
    # order-stable equality check. Groups and entries-within-groups
    # are NOT reordered (order has semantic meaning under Microsoft's
    # boolean evaluation); only object-key order is canonicalized.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$AdvancedRule)

    function ConvertTo-SortedAdvancedRuleNode {
        param($node)
        if ($node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in ($node.Keys | Sort-Object -Property { [string]$_ })) {
                $out[$k] = ConvertTo-SortedAdvancedRuleNode $node[$k]
            }
            return $out
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            return @($node | ForEach-Object { ConvertTo-SortedAdvancedRuleNode $_ })
        }
        return $node
    }

    return (ConvertTo-SortedAdvancedRuleNode $AdvancedRule) | ConvertTo-Json -Depth 12 -Compress
}

function ConvertFrom-GenericLocationsWire {
    # Parse Microsoft's wire JSON for the -Locations parameter into the
    # normalized YAML hash shape from ADR 0032. Wire shape is:
    #   [{ Workload, Location, LocationDisplayName, LocationSource,
    #      LocationType, Inclusions: [{ Type, Identity, DisplayName, Name }],
    #      Exclusions: [{ Type, Identity, DisplayName, Name }] }]
    # Returns @{ Recognized = $bool; Normalized = [object[]]; Reason = $str }.
    # Reference: docs/adr/0032-dlp-generic-locations-shape.md.
    param([Parameter(Mandatory = $true)][object]$Wire)

    function Format-UnrecognizedGenericLocationsResult { param([string]$why) @{ Recognized = $false; Normalized = $null; Reason = $why } }

    try {
        if ($Wire -is [string]) {
            $obj = $Wire | ConvertFrom-Json -ErrorAction Stop
        } else {
            $obj = $Wire
        }
    } catch {
        return (Format-UnrecognizedGenericLocationsResult ("Locations body did not parse as JSON: {0}" -f $_.Exception.Message))
    }

    # ConvertFrom-Json returns $null for an empty array '[]'. Treat
    # "parsed successfully but produced zero entries" the same as
    # an explicitly empty array.
    $entries = if ($null -eq $obj) { @() } else { [object[]]@($obj) }
    if ($entries.Count -eq 0) {
        return (Format-UnrecognizedGenericLocationsResult 'Locations body parsed but produced zero entries.')
    }

    $resultEntries = [System.Collections.ArrayList]::new()
    foreach ($e in $entries) {
        if (-not $e) { continue }
        $workload = [string]$e.Workload
        $location = [string]$e.Location
        if ([string]::IsNullOrEmpty($workload) -or [string]::IsNullOrEmpty($location)) {
            return (Format-UnrecognizedGenericLocationsResult "Locations entry missing required Workload or Location.")
        }
        $h = [ordered]@{}
        $h['workload'] = $workload
        $h['location'] = $location
        # locationDisplayName preserved verbatim (Microsoft returns null for Copilot)
        if ($e.PSObject.Properties.Match('LocationDisplayName').Count -gt 0) {
            $h['locationDisplayName'] = $e.LocationDisplayName
        }
        if (-not [string]::IsNullOrEmpty([string]$e.LocationSource)) { $h['locationSource'] = [string]$e.LocationSource }
        if (-not [string]::IsNullOrEmpty([string]$e.LocationType))   { $h['locationType']   = [string]$e.LocationType }

        $inclusions = [System.Collections.ArrayList]::new()
        foreach ($i in @($e.Inclusions)) {
            if (-not $i) { continue }
            $ih = [ordered]@{}
            $ih['type']     = [string]$i.Type
            $ih['identity'] = [string]$i.Identity
            if (-not [string]::IsNullOrEmpty([string]$i.DisplayName)) { $ih['displayName'] = [string]$i.DisplayName }
            if (-not [string]::IsNullOrEmpty([string]$i.Name))        { $ih['name']        = [string]$i.Name }
            [void]$inclusions.Add($ih)
        }
        if ($inclusions.Count -gt 0) { $h['inclusions'] = [object[]]$inclusions.ToArray() }

        $exclusions = [System.Collections.ArrayList]::new()
        foreach ($x in @($e.Exclusions)) {
            if (-not $x) { continue }
            $xh = [ordered]@{}
            $xh['type']     = [string]$x.Type
            $xh['identity'] = [string]$x.Identity
            if (-not [string]::IsNullOrEmpty([string]$x.DisplayName)) { $xh['displayName'] = [string]$x.DisplayName }
            if (-not [string]::IsNullOrEmpty([string]$x.Name))        { $xh['name']        = [string]$x.Name }
            [void]$exclusions.Add($xh)
        }
        if ($exclusions.Count -gt 0) { $h['exclusions'] = [object[]]$exclusions.ToArray() }

        [void]$resultEntries.Add($h)
    }

    return @{ Recognized = $true; Normalized = [object[]]$resultEntries.ToArray(); Reason = $null }
}

function ConvertTo-NormalizedGenericLocations {
    # Take a `genericLocations` array from YAML and return the canonical
    # [object[]] of ordered-hash entries used by the comparator and the
    # apply path. Preserves entry order (Microsoft's evaluation honors
    # order); drops empty optional fields.
    # Reference: docs/adr/0032-dlp-generic-locations-shape.md.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function operates on an array of generic-location entries; plural matches Microsoft -Locations parameter shape.')]
    param([Parameter(Mandatory = $true)][object[]]$Source)

    $resultEntries = [System.Collections.ArrayList]::new()
    foreach ($e in $Source) {
        if (-not $e) { continue }
        $eh = $e
        $h = [ordered]@{}
        $h['workload'] = [string]$eh['workload']
        $h['location'] = [string]$eh['location']
        if ($eh.Contains('locationDisplayName')) { $h['locationDisplayName'] = $eh['locationDisplayName'] }
        if ($eh.Contains('locationSource') -and $eh['locationSource']) { $h['locationSource'] = [string]$eh['locationSource'] }
        if ($eh.Contains('locationType')   -and $eh['locationType'])   { $h['locationType']   = [string]$eh['locationType'] }

        if ($eh.Contains('inclusions') -and $eh['inclusions']) {
            $incl = [System.Collections.ArrayList]::new()
            foreach ($i in @($eh['inclusions'])) {
                $ih = $i
                $o = [ordered]@{}
                $o['type']     = [string]$ih['type']
                $o['identity'] = [string]$ih['identity']
                if ($ih.Contains('displayName') -and $ih['displayName']) { $o['displayName'] = [string]$ih['displayName'] }
                if ($ih.Contains('name')        -and $ih['name'])        { $o['name']        = [string]$ih['name'] }
                [void]$incl.Add($o)
            }
            if ($incl.Count -gt 0) { $h['inclusions'] = [object[]]$incl.ToArray() }
        }

        if ($eh.Contains('exclusions') -and $eh['exclusions']) {
            $excl = [System.Collections.ArrayList]::new()
            foreach ($x in @($eh['exclusions'])) {
                $xh = $x
                $o = [ordered]@{}
                $o['type']     = [string]$xh['type']
                $o['identity'] = [string]$xh['identity']
                if ($xh.Contains('displayName') -and $xh['displayName']) { $o['displayName'] = [string]$xh['displayName'] }
                if ($xh.Contains('name')        -and $xh['name'])        { $o['name']        = [string]$xh['name'] }
                [void]$excl.Add($o)
            }
            if ($excl.Count -gt 0) { $h['exclusions'] = [object[]]$excl.ToArray() }
        }

        [void]$resultEntries.Add($h)
    }
    return [object[]]$resultEntries.ToArray()
}

function ConvertTo-GenericLocationsWire {
    # Serialize a normalized `genericLocations` array back into the wire
    # JSON string Microsoft's New-/Set-DlpCompliancePolicy accepts via the
    # -Locations parameter. Reconstructs PascalCase keys from the YAML's
    # lowerCamelCase per ADR 0032.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
    param([Parameter(Mandatory = $true)][object[]]$GenericLocations)

    $wireEntries = @()
    foreach ($e in $GenericLocations) {
        $w = [ordered]@{}
        $w.Workload = [string]$e['workload']
        $w.Location = [string]$e['location']
        if ($e.Contains('locationDisplayName')) { $w.LocationDisplayName = $e['locationDisplayName'] }
        if ($e.Contains('locationSource'))      { $w.LocationSource      = [string]$e['locationSource'] }
        if ($e.Contains('locationType'))        { $w.LocationType        = [string]$e['locationType'] }

        $wireIncl = @()
        foreach ($i in @($e['inclusions'])) {
            if (-not $i) { continue }
            $iw = [ordered]@{}
            $iw.Type     = [string]$i['type']
            $iw.Identity = [string]$i['identity']
            if ($i.Contains('displayName')) { $iw.DisplayName = [string]$i['displayName'] }
            if ($i.Contains('name'))        { $iw.Name        = [string]$i['name'] }
            $wireIncl += $iw
        }
        if ($wireIncl.Count -gt 0) { $w.Inclusions = $wireIncl }

        $wireExcl = @()
        foreach ($x in @($e['exclusions'])) {
            if (-not $x) { continue }
            $xw = [ordered]@{}
            $xw.Type     = [string]$x['type']
            $xw.Identity = [string]$x['identity']
            if ($x.Contains('displayName')) { $xw.DisplayName = [string]$x['displayName'] }
            if ($x.Contains('name'))        { $xw.Name        = [string]$x['name'] }
            $wireExcl += $xw
        }
        if ($wireExcl.Count -gt 0) { $w.Exclusions = $wireExcl }

        $wireEntries += $w
    }
    return ($wireEntries | ConvertTo-Json -Depth 10 -Compress)
}

function ConvertTo-NormalizedGenericLocationsJson {
    # Produce a stable, key-sorted, whitespace-free JSON string from a
    # normalized genericLocations array. Used by Compare-DlpPolicy for an
    # order-stable equality check. Entry order is NOT reordered (Microsoft's
    # evaluation honors order); only object-key order is canonicalized.
    param([Parameter(Mandatory = $true)][object[]]$GenericLocations)

    function ConvertTo-SortedGenericLocationNode {
        param($node)
        if ($node -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in ($node.Keys | Sort-Object -Property { [string]$_ })) {
                $out[$k] = ConvertTo-SortedGenericLocationNode $node[$k]
            }
            return $out
        }
        if ($node -is [System.Collections.IEnumerable] -and -not ($node -is [string])) {
            return @($node | ForEach-Object { ConvertTo-SortedGenericLocationNode $_ })
        }
        return $node
    }

    return (ConvertTo-SortedGenericLocationNode $GenericLocations) | ConvertTo-Json -Depth 10 -Compress
}

function ConvertTo-NormalizedPolicyTemplateInfo {
    # Project Microsoft's PolicyTemplateInfo wire shape into a stable,
    # deterministic [ordered] hashtable suitable for YAML serialization.
    # Per ADR 0032 the field is exporter-write / applier-skip; the only
    # contract is that two consecutive exports against the same tenant
    # produce byte-equal YAML so round-trips don't churn (fixes #524).
    #
    # Microsoft returns PolicyTemplateInfo as either:
    #   1. [Hashtable] / [IDictionary] -- the Microsoft 365 Copilot policy
    #      shape; keys like Id / CategoryId carry the meaningful data.
    #      System.Collections.Hashtable bucket order is NOT stable across
    #      processes, so we must enumerate via .Keys + sort.
    #   2. [PSCustomObject] -- the legacy / deserialized-remoting shape.
    #      Enumerate via Get-Member sorted by name.
    #
    # Returns $null when the input has no meaningful entries.
    param([Parameter()]$Source)

    if ($null -eq $Source) { return $null }

    $out = [ordered]@{}

    if ($Source -is [System.Collections.IDictionary]) {
        # Enumerate the dictionary's actual key/value pairs, sorted by key
        # ordinal. This deliberately ignores .Count / .IsFixedSize /
        # .IsReadOnly / .IsSynchronized / .Keys / .Values / .SyncRoot
        # noise that Get-Member would surface on a [Hashtable].
        foreach ($k in (@($Source.Keys) | Sort-Object -Property { [string]$_ })) {
            $v = $Source[$k]
            if ($null -ne $v) { $out[[string]$k] = [string]$v }
        }
    } else {
        # PSCustomObject path: enumerate properties sorted by name.
        # Filter out IDictionary-shape noise (Count/Keys/Values/SyncRoot/
        # IsFixedSize/IsReadOnly/IsSynchronized) defensively, in case a
        # caller passes a [Hashtable] wrapped as a PSObject.
        $noise = @('Count','Keys','Values','SyncRoot','IsFixedSize','IsReadOnly','IsSynchronized')
        foreach ($p in ($Source | Get-Member -MemberType Property,NoteProperty | Sort-Object Name)) {
            if ($noise -contains $p.Name) { continue }
            $v = $Source.($p.Name)
            if ($null -ne $v) { $out[[string]$p.Name] = [string]$v }
        }
    }

    if ($out.Count -eq 0) { return $null }
    return $out
}

function Resolve-AdaptiveScopeMap {
    # Build a Name -> Guid lookup map for Microsoft Purview adaptive
    # policy scopes. Mirrors Resolve-SensitivityLabelMap. Used at apply
    # time to validate that any YAML-referenced adaptive scope exists in
    # the tenant before splatting to New-/Set-DlpCompliancePolicy.
    # Reference: https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes
    $map = @{}
    try {
        $scopes = @(Get-AdaptiveScope -ErrorAction Stop)
    } catch {
        Write-Verbose ('Get-AdaptiveScope failed (non-fatal if no policies reference adaptive scopes): {0}' -f $_.Exception.Message)
        return $map
    }
    foreach ($s in $scopes) {
        $n = [string]$s.Name
        $g = $null
        if ($s.Guid)             { $g = [string]$s.Guid }
        elseif ($s.Identity)     { $g = [string]$s.Identity }
        elseif ($s.ExchangeObjectId) { $g = [string]$s.ExchangeObjectId }
        if ($n -and $g) { $map[$n] = $g.ToLowerInvariant() }
    }
    return $map
}

function ConvertTo-AdaptiveScopeRef {
    # Resolve a YAML adaptive scope entry (with required `name` and
    # optional `guid`) to a canonical { name; guid } pair. If the entry
    # carries a guid, honor it. Otherwise look up via $ScopeMap and throw
    # if the scope does not exist in the tenant. An empty $ScopeMap
    # (unit-test path) disables validation.
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [Parameter()][hashtable]$ScopeMap = @{},
        [Parameter()][string]$ContextName = ''
    )

    $n = $null; $g = $null
    if ($Entry -is [hashtable] -or $Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains('name')) { $n = [string]$Entry['name'] }
        if ($Entry.Contains('guid') -and $Entry['guid']) { $g = ([string]$Entry['guid']).ToLowerInvariant() }
    } else {
        $names = @($Entry.PSObject.Properties | Where-Object { $_.Name -eq 'name' })
        if ($names.Count -gt 0) { $n = [string]$names[0].Value }
        $guids = @($Entry.PSObject.Properties | Where-Object { $_.Name -eq 'guid' })
        if ($guids.Count -gt 0 -and $guids[0].Value) { $g = ([string]$guids[0].Value).ToLowerInvariant() }
    }
    if ([string]::IsNullOrWhiteSpace($n)) {
        throw "Adaptive scope entry is missing required field 'name'."
    }
    if ([string]::IsNullOrEmpty($g) -and $ScopeMap.Count -gt 0) {
        if (-not $ScopeMap.ContainsKey($n)) {
            $where = if ($ContextName) { " referenced by policy '$ContextName'" } else { '' }
            throw ("Adaptive scope '{0}'{1} was not found via Get-AdaptiveScope. Create it first or declare the GUID inline." -f $n, $where)
        }
        $g = $ScopeMap[$n]
    }
    $o = [ordered]@{ name = $n }
    if ($g) { $o.guid = $g }
    return [pscustomobject]$o
}

function ConvertTo-NormalizedAdaptiveScopes {
    # Normalize an array of YAML / tenant adaptive scope entries into a
    # sort-stable [object[]] of { name; [guid] } pscustomobjects. Sorted
    # by name ordinal so two semantically-equal lists compare equal under
    # JSON string equality.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function operates on an array of adaptive-scope entries; plural matches Microsoft -*AdaptiveScopes cmdlet parameter shape.')]
    param([Parameter()][object[]]$Source)
    if (-not $Source) { return @() }
    $out = @()
    foreach ($e in $Source) {
        if ($null -eq $e) { continue }
        if ($e -is [string]) {
            $out += [pscustomobject][ordered]@{ name = [string]$e }
        } else {
            $h = if ($e -is [hashtable]) { $e } else { @{} + $e }
            $n = [string]$h.name
            if (-not $n -and $h.Name) { $n = [string]$h.Name }
            if (-not $n -and $h.DisplayName) { $n = [string]$h.DisplayName }
            if (-not $n) { continue }
            $g = $null
            if ($h.ContainsKey('guid') -and $h.guid) { $g = ([string]$h.guid).ToLowerInvariant() }
            elseif ($h.Guid) { $g = ([string]$h.Guid).ToLowerInvariant() }
            elseif ($h.Identity) { $g = ([string]$h.Identity).ToLowerInvariant() }
            $o = [ordered]@{ name = $n }
            if ($g) { $o.guid = $g }
            $out += [pscustomobject]$o
        }
    }
    return [object[]]@($out | Sort-Object -Property { [string]$_.name })
}

function ConvertTo-NormalizedAdaptiveScopesJson {
    # Canonical compact JSON projection of a normalized adaptive scopes
    # bucket. Used by Compare-DlpPolicy for order-stable equality.
    param([Parameter()][object[]]$Scopes)
    if (-not $Scopes -or $Scopes.Count -eq 0) { return '[]' }
    return ($Scopes | ForEach-Object {
        $o = [ordered]@{}
        foreach ($k in ($_.PSObject.Properties.Name | Sort-Object -Property { [string]$_ })) {
            $o[$k] = $_.$k
        }
        $o
    }) | ConvertTo-Json -Depth 5 -Compress
}

# ADR 0033 Batch 4/1 (#521 slice G) helpers: endpointDlpRestrictions is a
# structured per-app endpoint enforcement matrix (array of
# {setting, value, appgroup, defaultmessage} objects). The cmdlet declares
# the parameter as System.Object[] and the tenant returns ArrayList[Hashtable];
# the YAML carries the same shape. Reorder-only diffs must be silent, so the
# comparator normalizes both sides by sorting items on `setting` before
# emitting compact JSON. Same pattern as ConvertTo-NormalizedAdaptiveScopes /
# Json above (the #520 precedent).
function ConvertTo-NormalizedEndpointDlpRestrictions {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function operates on an array of endpoint-restriction items; plural matches the Microsoft -EndpointDlpRestrictions cmdlet parameter shape.')]
    param([Parameter()][object[]]$Source)
    if (-not $Source) { return @() }
    $out = @()
    foreach ($e in $Source) {
        if ($null -eq $e) { continue }
        $h = if ($e -is [hashtable]) { $e } else { @{} + $e }
        $setting = [string]$h.setting
        if (-not $setting -and $h.Setting) { $setting = [string]$h.Setting }
        if (-not $setting) { continue }
        $o = [ordered]@{ setting = $setting }
        if ($h.ContainsKey('value')          -and $h.value)          { $o.value          = [string]$h.value }          elseif ($h.Value)          { $o.value          = [string]$h.Value }
        if ($h.ContainsKey('appgroup')       -and $h.appgroup)       { $o.appgroup       = [string]$h.appgroup }       elseif ($h.Appgroup)       { $o.appgroup       = [string]$h.Appgroup }
        if ($h.ContainsKey('defaultmessage') -and $h.defaultmessage) { $o.defaultmessage = [string]$h.defaultmessage } elseif ($h.Defaultmessage) { $o.defaultmessage = [string]$h.Defaultmessage }
        $out += [pscustomobject]$o
    }
    return [object[]]@($out | Sort-Object -Property { [string]$_.setting })
}

function ConvertTo-NormalizedEndpointDlpRestrictionsJson {
    # Canonical compact JSON projection of a normalized endpointDlpRestrictions
    # array. Used by Compare-DlpRule for order-stable equality.
    param([Parameter()][object[]]$Restrictions)
    if (-not $Restrictions -or $Restrictions.Count -eq 0) { return '[]' }
    return ($Restrictions | ForEach-Object {
        $o = [ordered]@{}
        foreach ($k in ($_.PSObject.Properties.Name | Sort-Object -Property { [string]$_ })) {
            $o[$k] = $_.$k
        }
        $o
    }) | ConvertTo-Json -Depth 3 -Compress
}

# ADR 0033 Batch 4/2 (#521 slice H) helpers: alertProperties is a free-form
# per-rule alert-aggregation property bag (single object, NOT an array). The
# cmdlet declares the parameter as System.Object and the tenant returns
# System.Collections.Hashtable; today the lab tenant populates this on the
# Microsoft-shipped Copilot rule with a single key {AggregationType: 'None'}.
# The reconciler honors whatever keys the tenant returns; the comparator uses
# sorted-key compact JSON so key-order-only diffs are silent. Per ADR 0033 section 2
# trigger-list evaluation, this field's actual shape does NOT require a new ADR.
function ConvertTo-NormalizedAlertProperties {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function name mirrors the Microsoft -AlertProperties cmdlet parameter shape.')]
    param([Parameter()][object]$Source)
    if ($null -eq $Source) { return $null }
    $h = if ($Source -is [hashtable]) { $Source } elseif ($Source -is [System.Collections.IDictionary]) { @{} + $Source } else { @{} + $Source }
    if ($h.Count -eq 0) { return $null }
    $o = [ordered]@{}
    foreach ($k in ($h.Keys | Sort-Object -Property { [string]$_ })) {
        $v = $h[$k]
        if ($null -eq $v) { continue }
        $o[[string]$k] = [string]$v
    }
    if ($o.Keys.Count -eq 0) { return $null }
    return [pscustomobject]$o
}

function ConvertTo-NormalizedAlertPropertiesJson {
    # Canonical compact JSON projection of a normalized alertProperties bag.
    # Keys are emitted in sorted order; values are coerced to string.
    param([Parameter()][object]$Properties)
    if ($null -eq $Properties) { return '{}' }
    $o = [ordered]@{}
    foreach ($p in ($Properties.PSObject.Properties | Sort-Object -Property { [string]$_.Name })) {
        $o[$p.Name] = [string]$p.Value
    }
    if ($o.Keys.Count -eq 0) { return '{}' }
    return $o | ConvertTo-Json -Depth 3 -Compress
}

# ADR 0033 Batch 4/3 (#521 slice I) helpers: restrictAccess is a per-action
# access-restriction array on Microsoft 365 Copilot rules. Wire shape is
# identical to endpointDlpRestrictions (Batch 4/1) -- ArrayList[Hashtable] with
# 2 keys per item {setting, value}. Today the lab tenant carries 1 item on the
# Copilot rule: {setting: UploadText, value: Block}. The reconciler honors the
# wire shape; the comparator uses sorted-by-setting compact JSON so reorder-
# only diffs are silent. Per ADR 0033 section 2 trigger-list evaluation
# (Copilot-crossover question), this field's actual shape does NOT require a
# new ADR: it parameterizes per-action enforcement on a Copilot rule, the
# Copilot routing decision is already modeled via enforcementPlanes
# (PR #515 era), and the structured shape mirrors Batch 4/1.
function ConvertTo-NormalizedRestrictAccess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function operates on an array of restrict-access items; plural matches the Microsoft -RestrictAccess cmdlet parameter shape.')]
    param([Parameter()][object[]]$Source)
    if (-not $Source) { return @() }
    $out = @()
    foreach ($e in $Source) {
        if ($null -eq $e) { continue }
        $h = if ($e -is [hashtable]) { $e } else { @{} + $e }
        $setting = [string]$h.setting
        if (-not $setting -and $h.Setting) { $setting = [string]$h.Setting }
        if (-not $setting) { continue }
        $o = [ordered]@{ setting = $setting }
        if ($h.ContainsKey('value') -and $h.value) { $o.value = [string]$h.value } elseif ($h.Value) { $o.value = [string]$h.Value }
        $out += [pscustomobject]$o
    }
    return [object[]]@($out | Sort-Object -Property { [string]$_.setting })
}

function ConvertTo-NormalizedRestrictAccessJson {
    # Canonical compact JSON projection of a normalized restrictAccess array.
    # Used by Compare-DlpRule for order-stable equality.
    param([Parameter()][object[]]$RestrictAccess)
    if (-not $RestrictAccess -or $RestrictAccess.Count -eq 0) { return '[]' }
    return ($RestrictAccess | ForEach-Object {
        $o = [ordered]@{}
        foreach ($k in ($_.PSObject.Properties.Name | Sort-Object -Property { [string]$_ })) {
            $o[$k] = $_.$k
        }
        $o
    }) | ConvertTo-Json -Depth 3 -Compress
}

function ConvertTo-DesiredDlpPolicyHash {
    # Normalize a desired-state policy entry from the YAML into a
    # comparable hashtable. Reference: ./policies.schema.json.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    # Per-workload location buckets. The 6 primary + 12 variant buckets (exception /
    # on-premises / third-party) are kept in lockstep across this site,
    # ConvertTo-TenantDlpPolicyHash, Compare-DlpPolicy, Get-DlpPolicySplat, and
    # Invoke-DlpExport. Adding a bucket means editing all 5 sites. See #519.
    $locations = @{
        exchange                       = @()
        sharePoint                     = @()
        oneDrive                       = @()
        teams                          = @()
        endpoint                       = @()
        powerBI                        = @()
        exchangeOnPremises             = @()
        oneDriveException              = @()
        sharePointException            = @()
        sharePointOnPremisesException  = @()
        sharePointServer               = @()
        teamsException                 = @()
        endpointException              = @()
        onPremisesScanner              = @()
        onPremisesScannerException     = @()
        powerBIException               = @()
        thirdPartyApp                  = @()
        thirdPartyAppException         = @()
    }
    if ($Entry.ContainsKey('locations') -and $Entry.locations) {
        foreach ($bucket in @(
            'exchange','sharePoint','oneDrive','teams','endpoint','powerBI',
            'exchangeOnPremises','oneDriveException','sharePointException',
            'sharePointOnPremisesException','sharePointServer','teamsException',
            'endpointException','onPremisesScanner','onPremisesScannerException',
            'powerBIException','thirdPartyApp','thirdPartyAppException'
        )) {
            if ($Entry.locations.ContainsKey($bucket)) {
                $val = $Entry.locations[$bucket]
                if ($val -is [string] -and $val -eq 'All') {
                    $locations[$bucket] = @('All')
                } elseif ($val) {
                    $locations[$bucket] = @($val | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                }
            }
        }
    }

    $rules = @()
    if ($Entry.ContainsKey('rules') -and $Entry.rules) {
        $rules = @($Entry.rules | ForEach-Object { ConvertTo-DesiredDlpRuleHash -Entry ([hashtable]$_) })
    }

    $genericLocations = @()
    if ($Entry.ContainsKey('genericLocations') -and $Entry.genericLocations) {
        # Force array semantics on the assignment; ConvertTo-NormalizedGenericLocations
        # returns [object[]], but PowerShell's = unrolls single-element arrays.
        $genericLocations = [object[]]@(ConvertTo-NormalizedGenericLocations -Source @($Entry.genericLocations))
    }

    # Adaptive scopes per-workload buckets (#520). Kept in lockstep with
    # ConvertTo-TenantDlpPolicyHash, Compare-DlpPolicy, Get-DlpPolicySplat,
    # and Invoke-DlpExport. Adding a bucket means editing all 5 sites.
    $adaptiveScopes = @{
        endpoint = @(); endpointException = @()
        exchange = @(); exchangeException = @()
        oneDrive = @(); oneDriveException = @()
        sharePoint = @(); sharePointException = @()
        teams = @(); teamsException = @()
    }
    if ($Entry.ContainsKey('adaptiveScopes') -and $Entry.adaptiveScopes) {
        foreach ($bucket in @(
            'endpoint','endpointException','exchange','exchangeException',
            'oneDrive','oneDriveException','sharePoint','sharePointException',
            'teams','teamsException'
        )) {
            if ($Entry.adaptiveScopes.ContainsKey($bucket) -and $Entry.adaptiveScopes[$bucket]) {
                $adaptiveScopes[$bucket] = [object[]]@(ConvertTo-NormalizedAdaptiveScopes -Source @($Entry.adaptiveScopes[$bucket]))
            }
        }
    }

    return @{
        name              = [string]$Entry.name
        description       = if ($Entry.ContainsKey('description')) { [string]$Entry.description } else { $null }
        mode              = [string]$Entry.mode
        priority          = if ($Entry.ContainsKey('priority')) { [int]$Entry.priority } else { $null }
        locations         = $locations
        genericLocations  = $genericLocations
        enforcementPlanes = if ($Entry.ContainsKey('enforcementPlanes')) { [string]$Entry.enforcementPlanes } else { $null }
        policyTemplateInfo = if ($Entry.ContainsKey('policyTemplateInfo')) { $Entry.policyTemplateInfo } else { $null }
        adaptiveScopes    = $adaptiveScopes
        rules             = $rules
        notes             = if ($Entry.ContainsKey('notes')) { [string]$Entry.notes } else { $null }
    }
}

function ConvertTo-DesiredDlpRuleHash {
    # Normalize a desired-state rule entry into a comparable hashtable.
    param([Parameter(Mandatory = $true)][hashtable]$Entry)

    $sits = @()
    if ($Entry.ContainsKey('sensitiveInfoTypes') -and $Entry.sensitiveInfoTypes) {
        $sits = @($Entry.sensitiveInfoTypes | ForEach-Object {
            $h = [hashtable]$_
            $o = [ordered]@{ guid = ([string]$h.guid).ToLowerInvariant() }
            if ($h.ContainsKey('minCount'))        { $o.minCount        = [int]$h.minCount }
            if ($h.ContainsKey('maxCount'))        { $o.maxCount        = [int]$h.maxCount }
            if ($h.ContainsKey('confidenceLevel')) { $o.confidenceLevel = [string]$h.confidenceLevel }
            [pscustomobject]$o
        } | Sort-Object -Property guid)
    }

    $labels = @()
    if ($Entry.ContainsKey('sensitivityLabels') -and $Entry.sensitivityLabels) {
        $labels = @($Entry.sensitivityLabels | ForEach-Object {
            $h = [hashtable]$_
            [pscustomobject]@{ displayName = [string]$h.displayName }
        } | Sort-Object -Property displayName)
    }

    $advancedRule = $null
    if ($Entry.ContainsKey('advancedRule') -and $Entry.advancedRule) {
        $advancedRule = ConvertTo-NormalizedAdvancedRule -Source ([hashtable]$Entry.advancedRule)
    }

    return @{
        name                   = [string]$Entry.name
        priority               = if ($Entry.ContainsKey('priority')) { [int]$Entry.priority } else { $null }
        sensitiveInfoTypes     = $sits
        sensitivityLabels      = $labels
        advancedRule           = $advancedRule
        blockAccess            = if ($Entry.ContainsKey('blockAccess'))            { [bool]$Entry.blockAccess } else { $null }
        notifyUser             = if ($Entry.ContainsKey('notifyUser'))             { @($Entry.notifyUser             | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        generateIncidentReport = if ($Entry.ContainsKey('generateIncidentReport')) { @($Entry.generateIncidentReport | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        generateAlert          = if ($Entry.ContainsKey('generateAlert'))          { @($Entry.generateAlert          | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        # ADR 0033 Batch 1 (#521 slice B): 3 mechanical default-value scalars.
        # Each surfaces in lockstep with ConvertTo-TenantDlpRuleHash, Compare-DlpRule,
        # Get-DlpRuleSplat, and Invoke-DlpExport. $null means the desired-state
        # YAML didn't declare the field (treated as not-tracked).
        enforcePortalAccess                  = if ($Entry.ContainsKey('enforcePortalAccess'))                  { [bool]$Entry.enforcePortalAccess } else { $null }
        notifyEmailExchangeIncludeAttachment = if ($Entry.ContainsKey('notifyEmailExchangeIncludeAttachment')) { [bool]$Entry.notifyEmailExchangeIncludeAttachment } else { $null }
        reportSeverityLevel                  = if ($Entry.ContainsKey('reportSeverityLevel'))                  { [string]$Entry.reportSeverityLevel } else { $null }
        # ADR 0033 Batch 2 (#521 slice C): 2 operator-meaningful scalars.
        comment                              = if ($Entry.ContainsKey('comment'))                              { [string]$Entry.comment } else { $null }
        accessScope                          = if ($Entry.ContainsKey('accessScope'))                          { [string]$Entry.accessScope } else { $null }
        # ADR 0033 Batch 3a (#521 slice D): 3 operator-facing notify-content scalars.
        notifyEmailCustomText                = if ($Entry.ContainsKey('notifyEmailCustomText'))                { [string]$Entry.notifyEmailCustomText } else { $null }
        notifyPolicyTipCustomText            = if ($Entry.ContainsKey('notifyPolicyTipCustomText'))            { [string]$Entry.notifyPolicyTipCustomText } else { $null }
        notifyPolicyTipDisplayOption         = if ($Entry.ContainsKey('notifyPolicyTipDisplayOption'))         { [string]$Entry.notifyPolicyTipDisplayOption } else { $null }
        # ADR 0033 Batch 3b (#521 slice E): 3 operator-facing notify recipient/override/remediation enums.
        notifyUserType                        = if ($Entry.ContainsKey('notifyUserType'))                        { [string]$Entry.notifyUserType } else { $null }
        notifyOverrideRequirements            = if ($Entry.ContainsKey('notifyOverrideRequirements'))            { [string]$Entry.notifyOverrideRequirements } else { $null }
        notifyEmailOnedriveRemediationActions = if ($Entry.ContainsKey('notifyEmailOnedriveRemediationActions')) { [string]$Entry.notifyEmailOnedriveRemediationActions } else { $null }
        # ADR 0033 Batch 3c (#521 slice F): 2 operator-facing notify override / incident-report scalars (final Batch 3 sub-PR).
        notifyAllowOverride                   = if ($Entry.ContainsKey('notifyAllowOverride'))                   { [string]$Entry.notifyAllowOverride } else { $null }
        incidentReportContent                 = if ($Entry.ContainsKey('incidentReportContent'))                 { [string]$Entry.incidentReportContent } else { $null }
        # ADR 0033 Batch 4/1 (#521 slice G): structured per-app endpoint enforcement matrix.
        # Normalized (sorted by `setting`) so reorder-only diffs are silent.
        endpointDlpRestrictions               = if ($Entry.ContainsKey('endpointDlpRestrictions') -and $Entry.endpointDlpRestrictions) { ConvertTo-NormalizedEndpointDlpRestrictions -Source @($Entry.endpointDlpRestrictions) } else { @() }
        # ADR 0033 Batch 4/2 (#521 slice H): per-rule alert-aggregation property bag.
        # Normalized (sorted keys, coerced to string) for order-stable comparison.
        alertProperties                       = if ($Entry.ContainsKey('alertProperties') -and $Entry.alertProperties) { ConvertTo-NormalizedAlertProperties -Source $Entry.alertProperties } else { $null }
        # ADR 0033 Batch 4/3 (#521 slice I): per-action access restriction array on Copilot rules.
        # Normalized (sorted by `setting`) so reorder-only diffs are silent.
        restrictAccess                        = if ($Entry.ContainsKey('restrictAccess') -and $Entry.restrictAccess) { ConvertTo-NormalizedRestrictAccess -Source @($Entry.restrictAccess) } else { @() }
        notes                  = if ($Entry.ContainsKey('notes'))                  { [string]$Entry.notes } else { $null }
    }
}

function ConvertTo-TenantDlpPolicyHash {
    # Normalize Get-DlpCompliancePolicy result into the same shape as
    # the desired hash (rules are merged in by the caller).
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy
    param([Parameter(Mandatory = $true)]$Policy)

    # Bucket list kept in lockstep with ConvertTo-DesiredDlpPolicyHash,
    # Compare-DlpPolicy, Get-DlpPolicySplat, and Invoke-DlpExport. See #519.
    $loc = @{
        exchange = @(); sharePoint = @(); oneDrive = @(); teams = @(); endpoint = @(); powerBI = @()
        exchangeOnPremises = @(); oneDriveException = @(); sharePointException = @()
        sharePointOnPremisesException = @(); sharePointServer = @(); teamsException = @()
        endpointException = @(); onPremisesScanner = @(); onPremisesScannerException = @()
        powerBIException = @(); thirdPartyApp = @(); thirdPartyAppException = @()
    }
    foreach ($pair in @(
        @{ Tenant = 'ExchangeLocation';                       Bucket = 'exchange' },
        @{ Tenant = 'SharePointLocation';                     Bucket = 'sharePoint' },
        @{ Tenant = 'OneDriveLocation';                       Bucket = 'oneDrive' },
        @{ Tenant = 'TeamsLocation';                          Bucket = 'teams' },
        @{ Tenant = 'EndpointDlpLocation';                    Bucket = 'endpoint' },
        @{ Tenant = 'PowerBIDlpLocation';                     Bucket = 'powerBI' },
        @{ Tenant = 'ExchangeOnPremisesLocation';             Bucket = 'exchangeOnPremises' },
        @{ Tenant = 'OneDriveLocationException';              Bucket = 'oneDriveException' },
        @{ Tenant = 'SharePointLocationException';            Bucket = 'sharePointException' },
        @{ Tenant = 'SharePointOnPremisesLocationException';  Bucket = 'sharePointOnPremisesException' },
        @{ Tenant = 'SharePointServerLocation';               Bucket = 'sharePointServer' },
        @{ Tenant = 'TeamsLocationException';                 Bucket = 'teamsException' },
        @{ Tenant = 'EndpointDlpLocationException';           Bucket = 'endpointException' },
        @{ Tenant = 'OnPremisesScannerDlpLocation';           Bucket = 'onPremisesScanner' },
        @{ Tenant = 'OnPremisesScannerDlpLocationException';  Bucket = 'onPremisesScannerException' },
        @{ Tenant = 'PowerBIDlpLocationException';            Bucket = 'powerBIException' },
        @{ Tenant = 'ThirdPartyAppDlpLocation';               Bucket = 'thirdPartyApp' },
        @{ Tenant = 'ThirdPartyAppDlpLocationException';      Bucket = 'thirdPartyAppException' }
    )) {
        $raw = $Policy.($pair.Tenant)
        if (-not $raw) { continue }
        $items = @($raw | ForEach-Object {
            if ($_.Name)        { [string]$_.Name }
            elseif ($_.Address) { [string]$_.Address }
            else                { [string]$_ }
        } | Where-Object { $_ } | Sort-Object -Unique)
        if ($items.Count -eq 1 -and $items[0] -eq 'All') {
            $loc[$pair.Bucket] = @('All')
        } else {
            $loc[$pair.Bucket] = $items
        }
    }

    # genericLocations extraction (ADR 0032). The wire shape is a JSON string
    # carried on the .Locations property; parse via ConvertFrom-GenericLocationsWire.
    $genericLocations = @()
    if ($Policy.Locations) {
        $parsed = ConvertFrom-GenericLocationsWire -Wire $Policy.Locations
        if ($parsed.Recognized) { $genericLocations = [object[]]@($parsed.Normalized) }
    }

    # enforcementPlanes: round-tripped verbatim (Microsoft Copilot policy = 'CopilotExperiences').
    $enforcementPlanes = $null
    if ($Policy.EnforcementPlanes) { $enforcementPlanes = [string]$Policy.EnforcementPlanes }

    # policyTemplateInfo: defensive exporter-write / applier-skip per ADR 0032.
    # Preserved verbatim so round-trips are byte-equal; never emitted to the cmdlet.
    # Helper handles both [Hashtable] (Microsoft Copilot policy shape, which
    # has non-deterministic bucket order across processes -- #524) and
    # [PSCustomObject] (legacy / deserialized shape).
    $policyTemplateInfo = ConvertTo-NormalizedPolicyTemplateInfo -Source $Policy.PolicyTemplateInfo

    # adaptiveScopes extraction (#520). Each of the 10 cmdlet fields is
    # always returned (typically as an empty System.Collections.ArrayList);
    # treat empty-or-null as "no scopes" to avoid spurious drift.
    $adaptiveScopes = @{
        endpoint = @(); endpointException = @()
        exchange = @(); exchangeException = @()
        oneDrive = @(); oneDriveException = @()
        sharePoint = @(); sharePointException = @()
        teams = @(); teamsException = @()
    }
    foreach ($pair in @(
        @{ Tenant = 'EndpointDlpAdaptiveScopes';            Bucket = 'endpoint' },
        @{ Tenant = 'EndpointDlpAdaptiveScopesException';   Bucket = 'endpointException' },
        @{ Tenant = 'ExchangeAdaptiveScopes';               Bucket = 'exchange' },
        @{ Tenant = 'ExchangeAdaptiveScopesException';      Bucket = 'exchangeException' },
        @{ Tenant = 'OneDriveAdaptiveScopes';               Bucket = 'oneDrive' },
        @{ Tenant = 'OneDriveAdaptiveScopesException';      Bucket = 'oneDriveException' },
        @{ Tenant = 'SharePointAdaptiveScopes';             Bucket = 'sharePoint' },
        @{ Tenant = 'SharePointAdaptiveScopesException';    Bucket = 'sharePointException' },
        @{ Tenant = 'TeamsAdaptiveScopes';                  Bucket = 'teams' },
        @{ Tenant = 'TeamsAdaptiveScopesException';         Bucket = 'teamsException' }
    )) {
        $raw = $Policy.($pair.Tenant)
        if (-not $raw -or @($raw).Count -eq 0) { continue }
        $adaptiveScopes[$pair.Bucket] = [object[]]@(ConvertTo-NormalizedAdaptiveScopes -Source @($raw))
    }

    return @{
        name              = [string]$Policy.Name
        description       = if ($Policy.Comment) { [string]$Policy.Comment } else { $null }
        mode              = [string]$Policy.Mode
        priority          = if ($null -ne $Policy.Priority) { [int]$Policy.Priority } else { $null }
        locations         = $loc
        genericLocations  = $genericLocations
        enforcementPlanes = $enforcementPlanes
        policyTemplateInfo = $policyTemplateInfo
        adaptiveScopes    = $adaptiveScopes
        rules             = @()
    }
}

function ConvertTo-TenantDlpRuleHash {
    # Normalize a Get-DlpComplianceRule entry into the desired shape.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancerule
    param([Parameter(Mandatory = $true)]$Rule)

    $sits = @()
    if ($Rule.ContentContainsSensitiveInformation) {
        foreach ($entry in $Rule.ContentContainsSensitiveInformation) {
            if (-not $entry) { continue }
            $guid = $null
            if ($entry.id)       { $guid = [string]$entry.id }
            elseif ($entry.name) { $guid = [string]$entry.name }
            if (-not $guid) { continue }
            if ($guid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { continue }
            $o = [ordered]@{ guid = $guid.ToLowerInvariant() }
            if ($null -ne $entry.minCount)        { $o.minCount        = [int]$entry.minCount }
            if ($null -ne $entry.maxCount)        { $o.maxCount        = [int]$entry.maxCount }
            if ($entry.confidencelevel)           { $o.confidenceLevel = [string]$entry.confidencelevel }
            $sits += [pscustomobject]$o
        }
        $sits = @($sits | Sort-Object -Property guid)
    }

    # AdvancedRule extraction (ADR 0031). When IsAdvancedRule=True and
    # the wire shape matches the captured shape, surface the normalized
    # hash; otherwise leave null so the caller can fall back to the
    # notes pass-through introduced by PR #516.
    $advancedRule = $null
    if (([bool]$Rule.IsAdvancedRule) -and $Rule.AdvancedRule) {
        $parsed = ConvertFrom-AdvancedRuleWire -Wire $Rule.AdvancedRule
        if ($parsed.Recognized) { $advancedRule = $parsed.Normalized }
    }

    return @{
        name                   = [string]$Rule.Name
        priority               = if ($null -ne $Rule.Priority) { [int]$Rule.Priority } else { $null }
        sensitiveInfoTypes     = $sits
        sensitivityLabels      = @()   # not round-tripped by name in Phase 1
        advancedRule           = $advancedRule
        blockAccess            = if ($null -ne $Rule.BlockAccess) { [bool]$Rule.BlockAccess } else { $null }
        notifyUser             = if ($Rule.NotifyUser)             { @($Rule.NotifyUser             | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        generateIncidentReport = if ($Rule.GenerateIncidentReport) { @($Rule.GenerateIncidentReport | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        generateAlert          = if ($Rule.GenerateAlert)          { @($Rule.GenerateAlert          | ForEach-Object { [string]$_ } | Sort-Object -Unique) } else { @() }
        # ADR 0033 Batch 1 (#521 slice B): 3 mechanical default-value scalars.
        # Tenant always returns these; surface as null only if the cmdlet
        # genuinely omits them (defensive).
        enforcePortalAccess                  = if ($null -ne $Rule.EnforcePortalAccess)                  { [bool]$Rule.EnforcePortalAccess } else { $null }
        notifyEmailExchangeIncludeAttachment = if ($null -ne $Rule.NotifyEmailExchangeIncludeAttachment) { [bool]$Rule.NotifyEmailExchangeIncludeAttachment } else { $null }
        reportSeverityLevel                  = if ($Rule.ReportSeverityLevel)                           { [string]$Rule.ReportSeverityLevel } else { $null }
        # ADR 0033 Batch 2 (#521 slice C): 2 operator-meaningful scalars.
        comment                              = if ($Rule.Comment)                                       { [string]$Rule.Comment } else { $null }
        accessScope                          = if ($Rule.AccessScope)                                   { [string]$Rule.AccessScope } else { $null }
        # ADR 0033 Batch 3a (#521 slice D): 3 operator-facing notify-content scalars.
        notifyEmailCustomText                = if ($Rule.NotifyEmailCustomText)                         { [string]$Rule.NotifyEmailCustomText } else { $null }
        notifyPolicyTipCustomText            = if ($Rule.NotifyPolicyTipCustomText)                     { [string]$Rule.NotifyPolicyTipCustomText } else { $null }
        notifyPolicyTipDisplayOption         = if ($Rule.NotifyPolicyTipDisplayOption)                  { [string]$Rule.NotifyPolicyTipDisplayOption } else { $null }
        # ADR 0033 Batch 3b (#521 slice E): 3 operator-facing notify recipient/override/remediation enums.
        notifyUserType                        = if ($Rule.NotifyUserType)                                { [string]$Rule.NotifyUserType } else { $null }
        notifyOverrideRequirements            = if ($Rule.NotifyOverrideRequirements)                    { [string]$Rule.NotifyOverrideRequirements } else { $null }
        notifyEmailOnedriveRemediationActions = if ($Rule.NotifyEmailOnedriveRemediationActions)         { [string]$Rule.NotifyEmailOnedriveRemediationActions } else { $null }
        # ADR 0033 Batch 3c (#521 slice F): 2 operator-facing notify override / incident-report scalars.
        # Cmdlet declares both as System.Object[] but tenant returns System.String (comma-joined when multi-value);
        # reconciler honors the wire shape (string).
        notifyAllowOverride                   = if ($Rule.NotifyAllowOverride)                            { [string]$Rule.NotifyAllowOverride } else { $null }
        incidentReportContent                 = if ($Rule.IncidentReportContent)                          { [string]$Rule.IncidentReportContent } else { $null }
        # ADR 0033 Batch 4/1 (#521 slice G): structured per-app endpoint enforcement matrix.
        endpointDlpRestrictions               = if ($Rule.EndpointDlpRestrictions)                        { ConvertTo-NormalizedEndpointDlpRestrictions -Source @($Rule.EndpointDlpRestrictions) } else { @() }
        # ADR 0033 Batch 4/2 (#521 slice H): per-rule alert-aggregation property bag.
        alertProperties                       = if ($Rule.AlertProperties)                                { ConvertTo-NormalizedAlertProperties -Source $Rule.AlertProperties } else { $null }
        # ADR 0033 Batch 4/3 (#521 slice I): per-action access restriction array on Copilot rules.
        restrictAccess                        = if ($Rule.RestrictAccess)                                 { ConvertTo-NormalizedRestrictAccess -Source @($Rule.RestrictAccess) } else { @() }
        policyName             = [string]$Rule.ParentPolicyName
    }
}

function Compare-DlpPolicy {
    # Return a list of field names that differ between desired and
    # tenant policy hashes. Only declared (non-null / non-empty)
    # desired fields are compared. `mode` is required and always
    # compared.
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

    if ([string]$Desired.mode -ne [string]$Tenant.mode) {
        $diffs.Add('mode') | Out-Null
    }

    if ($null -ne $Desired.priority) {
        if ([int]$Desired.priority -ne [int]$Tenant.priority) {
            $diffs.Add('priority') | Out-Null
        }
    }

    # Bucket list kept in lockstep with ConvertTo-DesiredDlpPolicyHash,
    # ConvertTo-TenantDlpPolicyHash, Get-DlpPolicySplat, and Invoke-DlpExport. See #519.
    foreach ($bucket in @(
        'exchange','sharePoint','oneDrive','teams','endpoint','powerBI',
        'exchangeOnPremises','oneDriveException','sharePointException',
        'sharePointOnPremisesException','sharePointServer','teamsException',
        'endpointException','onPremisesScanner','onPremisesScannerException',
        'powerBIException','thirdPartyApp','thirdPartyAppException'
    )) {
        $d = @($Desired.locations[$bucket] | Sort-Object -Unique)
        if ($d.Count -eq 0) { continue }
        $t = @($Tenant.locations[$bucket]  | Sort-Object -Unique)
        $delta = Compare-Object -ReferenceObject $t -DifferenceObject $d
        if ($delta) { $diffs.Add(("locations.{0}" -f $bucket)) | Out-Null }
    }

    # genericLocations (ADR 0032): compare by canonical key-sorted JSON.
    # Both sides empty -> no drift. One side empty and the other set ->
    # drift on genericLocations (covers a policy transitioning location
    # surfaces). Both sides set -> JSON string compare.
    # Note: @($null).Count returns 1, so check for null + empty explicitly.
    $dGl = if ($null -eq $Desired.genericLocations) { @() } else { @($Desired.genericLocations) }
    $tGl = if ($null -eq $Tenant.genericLocations)  { @() } else { @($Tenant.genericLocations) }
    $dHasGl = $dGl.Count -gt 0
    $tHasGl = $tGl.Count -gt 0
    if ($dHasGl -or $tHasGl) {
        if ($dHasGl -xor $tHasGl) {
            $diffs.Add('genericLocations') | Out-Null
        } else {
            $dJson = ConvertTo-NormalizedGenericLocationsJson -GenericLocations $dGl
            $tJson = ConvertTo-NormalizedGenericLocationsJson -GenericLocations $tGl
            if ($dJson -ne $tJson) { $diffs.Add('genericLocations') | Out-Null }
        }
    }

    # enforcementPlanes (ADR 0032): compare only if desired declares it.
    if (-not [string]::IsNullOrEmpty([string]$Desired.enforcementPlanes)) {
        if ([string]$Desired.enforcementPlanes -ne [string]$Tenant.enforcementPlanes) {
            $diffs.Add('enforcementPlanes') | Out-Null
        }
    }

    # policyTemplateInfo: NOT compared. Per ADR 0032, this field is
    # tenant-set and exporter-write-only; mutating it via the cmdlet could
    # re-type the policy. Drift on this field is silently ignored to
    # prevent accidental Updates that change Microsoft-template identity.

    # adaptiveScopes (#520): per-bucket compare via canonical sort-stable
    # JSON. Both sides empty for a bucket -> no diff. One side empty and
    # the other set -> drift on the specific bucket. Both sides set ->
    # JSON string compare on the normalized {name,[guid]} entries.
    foreach ($bucket in @(
        'endpoint','endpointException','exchange','exchangeException',
        'oneDrive','oneDriveException','sharePoint','sharePointException',
        'teams','teamsException'
    )) {
        $dAs = if ($null -eq $Desired.adaptiveScopes) { @() } elseif ($null -eq $Desired.adaptiveScopes[$bucket]) { @() } else { @($Desired.adaptiveScopes[$bucket]) }
        $tAs = if ($null -eq $Tenant.adaptiveScopes)  { @() } elseif ($null -eq $Tenant.adaptiveScopes[$bucket])  { @() } else { @($Tenant.adaptiveScopes[$bucket]) }
        $dHas = $dAs.Count -gt 0
        $tHas = $tAs.Count -gt 0
        if (-not $dHas -and -not $tHas) { continue }
        if ($dHas -xor $tHas) {
            $diffs.Add(("adaptiveScopes.{0}" -f $bucket)) | Out-Null
            continue
        }
        $dJson = ConvertTo-NormalizedAdaptiveScopesJson -Scopes $dAs
        $tJson = ConvertTo-NormalizedAdaptiveScopesJson -Scopes $tAs
        if ($dJson -ne $tJson) { $diffs.Add(("adaptiveScopes.{0}" -f $bucket)) | Out-Null }
    }

    return $diffs
}

function Compare-DlpRule {
    # Return a list of field names that differ between desired and
    # tenant rule hashes. Only declared (non-null / non-empty)
    # desired fields are compared.
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )

    $diffs = New-Object 'System.Collections.Generic.List[string]'

    if ($null -ne $Desired.priority) {
        if ([int]$Desired.priority -ne [int]$Tenant.priority) {
            $diffs.Add('priority') | Out-Null
        }
    }

    if ($null -ne $Desired.blockAccess) {
        if ([bool]$Desired.blockAccess -ne [bool]$Tenant.blockAccess) {
            $diffs.Add('blockAccess') | Out-Null
        }
    }

    # ADR 0033 Batch 1 (#521 slice B) scalars: only diff when desired declares
    # the field, consistent with existing scalar handling above.
    if ($null -ne $Desired.enforcePortalAccess) {
        if ([bool]$Desired.enforcePortalAccess -ne [bool]$Tenant.enforcePortalAccess) {
            $diffs.Add('enforcePortalAccess') | Out-Null
        }
    }
    if ($null -ne $Desired.notifyEmailExchangeIncludeAttachment) {
        if ([bool]$Desired.notifyEmailExchangeIncludeAttachment -ne [bool]$Tenant.notifyEmailExchangeIncludeAttachment) {
            $diffs.Add('notifyEmailExchangeIncludeAttachment') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.reportSeverityLevel)) {
        if ([string]$Desired.reportSeverityLevel -ne [string]$Tenant.reportSeverityLevel) {
            $diffs.Add('reportSeverityLevel') | Out-Null
        }
    }

    # ADR 0033 Batch 2 (#521 slice C) scalars: same only-when-declared semantics.
    if (-not [string]::IsNullOrEmpty([string]$Desired.comment)) {
        if ([string]$Desired.comment -ne [string]$Tenant.comment) {
            $diffs.Add('comment') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.accessScope)) {
        if ([string]$Desired.accessScope -ne [string]$Tenant.accessScope) {
            $diffs.Add('accessScope') | Out-Null
        }
    }

    # ADR 0033 Batch 3a (#521 slice D) scalars: same only-when-declared semantics.
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyEmailCustomText)) {
        if ([string]$Desired.notifyEmailCustomText -ne [string]$Tenant.notifyEmailCustomText) {
            $diffs.Add('notifyEmailCustomText') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyPolicyTipCustomText)) {
        if ([string]$Desired.notifyPolicyTipCustomText -ne [string]$Tenant.notifyPolicyTipCustomText) {
            $diffs.Add('notifyPolicyTipCustomText') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyPolicyTipDisplayOption)) {
        if ([string]$Desired.notifyPolicyTipDisplayOption -ne [string]$Tenant.notifyPolicyTipDisplayOption) {
            $diffs.Add('notifyPolicyTipDisplayOption') | Out-Null
        }
    }

    # ADR 0033 Batch 3b (#521 slice E) scalars: same only-when-declared semantics.
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyUserType)) {
        if ([string]$Desired.notifyUserType -ne [string]$Tenant.notifyUserType) {
            $diffs.Add('notifyUserType') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyOverrideRequirements)) {
        if ([string]$Desired.notifyOverrideRequirements -ne [string]$Tenant.notifyOverrideRequirements) {
            $diffs.Add('notifyOverrideRequirements') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyEmailOnedriveRemediationActions)) {
        if ([string]$Desired.notifyEmailOnedriveRemediationActions -ne [string]$Tenant.notifyEmailOnedriveRemediationActions) {
            $diffs.Add('notifyEmailOnedriveRemediationActions') | Out-Null
        }
    }

    # ADR 0033 Batch 3c (#521 slice F) scalars: same only-when-declared semantics.
    if (-not [string]::IsNullOrEmpty([string]$Desired.notifyAllowOverride)) {
        if ([string]$Desired.notifyAllowOverride -ne [string]$Tenant.notifyAllowOverride) {
            $diffs.Add('notifyAllowOverride') | Out-Null
        }
    }
    if (-not [string]::IsNullOrEmpty([string]$Desired.incidentReportContent)) {
        if ([string]$Desired.incidentReportContent -ne [string]$Tenant.incidentReportContent) {
            $diffs.Add('incidentReportContent') | Out-Null
        }
    }

    # ADR 0033 Batch 4/1 (#521 slice G): per-bucket xor + sort-stable JSON compare.
    # Both sides empty -> no diff. One side empty -> drift. Both set -> normalized
    # JSON string equality (items sorted by `setting`).
    $dEdr = if ($null -eq $Desired.endpointDlpRestrictions) { @() } else { @($Desired.endpointDlpRestrictions) }
    $tEdr = if ($null -eq $Tenant.endpointDlpRestrictions)  { @() } else { @($Tenant.endpointDlpRestrictions) }
    $dEdrHas = $dEdr.Count -gt 0
    $tEdrHas = $tEdr.Count -gt 0
    if ($dEdrHas -or $tEdrHas) {
        if ($dEdrHas -and -not $tEdrHas) {
            $diffs.Add('endpointDlpRestrictions') | Out-Null
        } elseif ($dEdrHas) {
            $dEdrJson = ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $dEdr
            $tEdrJson = ConvertTo-NormalizedEndpointDlpRestrictionsJson -Restrictions $tEdr
            if ($dEdrJson -ne $tEdrJson) { $diffs.Add('endpointDlpRestrictions') | Out-Null }
        }
        # Comparator stays asymmetric for consistency with other rule-level fields:
        # tenant-only data does not produce drift unless desired declares the field.
    }

    # ADR 0033 Batch 4/2 (#521 slice H): per-rule alert-aggregation property bag.
    # Same asymmetric only-when-declared semantics as other rule-level fields.
    if ($null -ne $Desired.alertProperties) {
        $dApJson = ConvertTo-NormalizedAlertPropertiesJson -Properties $Desired.alertProperties
        $tApJson = ConvertTo-NormalizedAlertPropertiesJson -Properties $Tenant.alertProperties
        if ($dApJson -ne $tApJson) { $diffs.Add('alertProperties') | Out-Null }
    }

    # ADR 0033 Batch 4/3 (#521 slice I): per-action access restriction array on Copilot rules.
    # Same xor + sort-stable JSON compare as Batch 4/1 (endpointDlpRestrictions).
    $dRa = if ($null -eq $Desired.restrictAccess) { @() } else { @($Desired.restrictAccess) }
    $tRa = if ($null -eq $Tenant.restrictAccess)  { @() } else { @($Tenant.restrictAccess) }
    $dRaHas = $dRa.Count -gt 0
    $tRaHas = $tRa.Count -gt 0
    if ($dRaHas -or $tRaHas) {
        if ($dRaHas -and -not $tRaHas) {
            $diffs.Add('restrictAccess') | Out-Null
        } elseif ($dRaHas) {
            $dRaJson = ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $dRa
            $tRaJson = ConvertTo-NormalizedRestrictAccessJson -RestrictAccess $tRa
            if ($dRaJson -ne $tRaJson) { $diffs.Add('restrictAccess') | Out-Null }
        }
        # Comparator stays asymmetric for consistency with other rule-level fields:
        # tenant-only data does not produce drift unless desired declares the field.
    }

    foreach ($field in @('notifyUser','generateIncidentReport','generateAlert')) {
        $d = @($Desired[$field] | Sort-Object -Unique)
        if ($d.Count -eq 0) { continue }
        $t = @($Tenant[$field] | Sort-Object -Unique)
        $delta = Compare-Object -ReferenceObject $t -DifferenceObject $d
        if ($delta) { $diffs.Add($field) | Out-Null }
    }

    # sensitiveInfoTypes: order-insensitive deep compare on (guid,
    # minCount, maxCount, confidenceLevel) tuples.
    if ($Desired.sensitiveInfoTypes.Count -gt 0) {
        $dKeys = @($Desired.sensitiveInfoTypes | ForEach-Object {
            ('{0}|{1}|{2}|{3}' -f $_.guid, $_.minCount, $_.maxCount, $_.confidenceLevel)
        } | Sort-Object)
        $tKeys = @($Tenant.sensitiveInfoTypes  | ForEach-Object {
            ('{0}|{1}|{2}|{3}' -f $_.guid, $_.minCount, $_.maxCount, $_.confidenceLevel)
        } | Sort-Object)
        $delta = Compare-Object -ReferenceObject $tKeys -DifferenceObject $dKeys
        if ($delta) { $diffs.Add('sensitiveInfoTypes') | Out-Null }
    }

    # sensitivityLabels: desired-side only (tenant round-trip by name
    # is out of scope for Phase 1; see ConvertTo-TenantDlpRuleHash).
    # A non-empty desired list always forces a rule update on first
    # apply; subsequent runs treat it as not-tracked.
    if ($Desired.sensitivityLabels.Count -gt 0 -and $Tenant.sensitivityLabels.Count -eq 0) {
        $diffs.Add('sensitivityLabels') | Out-Null
    }

    # advancedRule (ADR 0031): compare by canonical key-sorted JSON.
    # Both sides null -> no drift. One side null and the other set ->
    # drift on advancedRule (covers a rule transitioning predicate
    # types). Both sides set -> JSON string compare.
    $dHasAdv = $null -ne $Desired.advancedRule
    $tHasAdv = $null -ne $Tenant.advancedRule
    if ($dHasAdv -or $tHasAdv) {
        if ($dHasAdv -xor $tHasAdv) {
            $diffs.Add('advancedRule') | Out-Null
        } else {
            $dJson = ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $Desired.advancedRule
            $tJson = ConvertTo-NormalizedAdvancedRuleJson -AdvancedRule $Tenant.advancedRule
            if ($dJson -ne $tJson) { $diffs.Add('advancedRule') | Out-Null }
        }
    }

    return $diffs
}

function Get-DlpPolicySplat {
    # Build a splattable hashtable for New- or Set-DlpCompliancePolicy.
    # New- expects -Name; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [Parameter()][hashtable]$AdaptiveScopeMap = @{},
        [switch]$ForSet
    )

    $splat = @{}
    if ($ForSet.IsPresent) { $splat.Identity = $Hash.name } else { $splat.Name = $Hash.name }
    if (-not [string]::IsNullOrEmpty($Hash.description)) { $splat.Comment = $Hash.description }
    if (-not $ForSet.IsPresent) { $splat.Mode = $Hash.mode } else { $splat.Mode = $Hash.mode }
    if ($null -ne $Hash.priority) { $splat.Priority = [int]$Hash.priority }

    # Location, generic-location, and adaptive-scope parameters are
    # declarative on New-DlpCompliancePolicy but delta-shaped on
    # Set-DlpCompliancePolicy (the cmdlet exposes -Add*Location /
    # -Remove*Location instead). Emitting these to Set-* fails parameter
    # binding with "A parameter cannot be found that matches parameter
    # name 'TeamsLocation'." (#564). The reconciler's contract is
    # declarative-only, so we omit them entirely on the Set path; to
    # change a policy's location/scope set, the operator removes from
    # YAML, runs -PruneMissing, re-adds with the new set, and re-applies.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy
    if (-not $ForSet.IsPresent) {
        # Bucket->cmdlet-param map kept in lockstep with ConvertTo-DesiredDlpPolicyHash,
        # ConvertTo-TenantDlpPolicyHash, Compare-DlpPolicy, and Invoke-DlpExport. See #519.
        foreach ($pair in @(
            @{ Bucket = 'exchange';                       Param = 'ExchangeLocation' },
            @{ Bucket = 'sharePoint';                     Param = 'SharePointLocation' },
            @{ Bucket = 'oneDrive';                       Param = 'OneDriveLocation' },
            @{ Bucket = 'teams';                          Param = 'TeamsLocation' },
            @{ Bucket = 'endpoint';                       Param = 'EndpointDlpLocation' },
            @{ Bucket = 'powerBI';                        Param = 'PowerBIDlpLocation' },
            @{ Bucket = 'exchangeOnPremises';             Param = 'ExchangeOnPremisesLocation' },
            @{ Bucket = 'oneDriveException';              Param = 'OneDriveLocationException' },
            @{ Bucket = 'sharePointException';            Param = 'SharePointLocationException' },
            @{ Bucket = 'sharePointOnPremisesException';  Param = 'SharePointOnPremisesLocationException' },
            @{ Bucket = 'sharePointServer';               Param = 'SharePointServerLocation' },
            @{ Bucket = 'teamsException';                 Param = 'TeamsLocationException' },
            @{ Bucket = 'endpointException';              Param = 'EndpointDlpLocationException' },
            @{ Bucket = 'onPremisesScanner';              Param = 'OnPremisesScannerDlpLocation' },
            @{ Bucket = 'onPremisesScannerException';     Param = 'OnPremisesScannerDlpLocationException' },
            @{ Bucket = 'powerBIException';               Param = 'PowerBIDlpLocationException' },
            @{ Bucket = 'thirdPartyApp';                  Param = 'ThirdPartyAppDlpLocation' },
            @{ Bucket = 'thirdPartyAppException';         Param = 'ThirdPartyAppDlpLocationException' }
        )) {
            $vals = @($Hash.locations[$pair.Bucket])
            if ($vals.Count -gt 0) {
                $splat[$pair.Param] = [string[]]$vals
            }
        }

        # genericLocations -> -Locations (string JSON). Per ADR 0032.
        if (@($Hash.genericLocations).Count -gt 0) {
            $splat.Locations = ConvertTo-GenericLocationsWire -GenericLocations $Hash.genericLocations
        }
    }

    # enforcementPlanes -> -EnforcementPlanes. Per ADR 0032.
    if (-not [string]::IsNullOrEmpty([string]$Hash.enforcementPlanes)) {
        $splat.EnforcementPlanes = [string]$Hash.enforcementPlanes
    }

    # policyTemplateInfo: NEVER emitted to the cmdlet per ADR 0032.
    # The field is exporter-write / applier-skip; mutating it could
    # re-type the policy. This is the defensive boundary.

    if (-not $ForSet.IsPresent) {
        # adaptiveScopes -> 10 cmdlet parameters (#520). Each declared bucket
        # is emitted as a [string[]] of resolved scope names. The map is
        # consulted only to validate the YAML name exists in the tenant; the
        # cmdlet input is the name, not the guid. An empty map disables
        # validation (unit-test path).
        foreach ($pair in @(
            @{ Bucket = 'endpoint';             Param = 'EndpointDlpAdaptiveScopes' },
            @{ Bucket = 'endpointException';    Param = 'EndpointDlpAdaptiveScopesException' },
            @{ Bucket = 'exchange';             Param = 'ExchangeAdaptiveScopes' },
            @{ Bucket = 'exchangeException';    Param = 'ExchangeAdaptiveScopesException' },
            @{ Bucket = 'oneDrive';             Param = 'OneDriveAdaptiveScopes' },
            @{ Bucket = 'oneDriveException';    Param = 'OneDriveAdaptiveScopesException' },
            @{ Bucket = 'sharePoint';           Param = 'SharePointAdaptiveScopes' },
            @{ Bucket = 'sharePointException';  Param = 'SharePointAdaptiveScopesException' },
            @{ Bucket = 'teams';                Param = 'TeamsAdaptiveScopes' },
            @{ Bucket = 'teamsException';       Param = 'TeamsAdaptiveScopesException' }
        )) {
            $entries = @()
            if ($null -ne $Hash.adaptiveScopes) { $entries = @($Hash.adaptiveScopes[$pair.Bucket]) }
            if ($entries.Count -eq 0) { continue }
            $names = foreach ($e in $entries) {
                $ref = ConvertTo-AdaptiveScopeRef -Entry $e -ScopeMap $AdaptiveScopeMap -ContextName $Hash.name
                [string]$ref.name
            }
            $splat[$pair.Param] = [string[]]@($names | Sort-Object -Unique)
        }
    }

    return $splat
}

function Get-DlpRuleSplat {
    # Build a splattable hashtable for New- or Set-DlpComplianceRule.
    # New- expects -Name + -Policy; Set- expects -Identity.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancerule
    param(
        [Parameter(Mandatory = $true)][hashtable]$Hash,
        [Parameter()][string]$PolicyName,
        [Parameter()][hashtable]$LabelGuidMap = @{},
        [switch]$ForSet
    )

    $splat = @{}
    if ($ForSet.IsPresent) {
        $splat.Identity = ('{0}\{1}' -f $PolicyName, $Hash.name)
    } else {
        $splat.Name   = $Hash.name
        $splat.Policy = $PolicyName
    }
    if ($null -ne $Hash.priority)    { $splat.Priority    = [int]$Hash.priority }
    if ($null -ne $Hash.blockAccess) { $splat.BlockAccess = [bool]$Hash.blockAccess }
    if ($Hash.notifyUser.Count             -gt 0) { $splat.NotifyUser             = [string[]]$Hash.notifyUser }
    if ($Hash.generateIncidentReport.Count -gt 0) { $splat.GenerateIncidentReport = [string[]]$Hash.generateIncidentReport }
    if ($Hash.generateAlert.Count          -gt 0) { $splat.GenerateAlert          = [string[]]$Hash.generateAlert }

    # ADR 0033 Batch 1 (#521 slice B) scalars -> 3 cmdlet parameters.
    if ($null -ne $Hash.enforcePortalAccess)                  { $splat.EnforcePortalAccess                  = [bool]$Hash.enforcePortalAccess }
    if ($null -ne $Hash.notifyEmailExchangeIncludeAttachment) { $splat.NotifyEmailExchangeIncludeAttachment = [bool]$Hash.notifyEmailExchangeIncludeAttachment }
    if (-not [string]::IsNullOrEmpty([string]$Hash.reportSeverityLevel)) {
        $splat.ReportSeverityLevel = [string]$Hash.reportSeverityLevel
    }

    # ADR 0033 Batch 2 (#521 slice C) scalars -> 2 cmdlet parameters.
    if (-not [string]::IsNullOrEmpty([string]$Hash.comment)) {
        $splat.Comment = [string]$Hash.comment
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.accessScope)) {
        $splat.AccessScope = [string]$Hash.accessScope
    }

    # ADR 0033 Batch 3a (#521 slice D) scalars -> 3 cmdlet parameters.
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyEmailCustomText)) {
        $splat.NotifyEmailCustomText = [string]$Hash.notifyEmailCustomText
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyPolicyTipCustomText)) {
        $splat.NotifyPolicyTipCustomText = [string]$Hash.notifyPolicyTipCustomText
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyPolicyTipDisplayOption)) {
        $splat.NotifyPolicyTipDisplayOption = [string]$Hash.notifyPolicyTipDisplayOption
    }

    # ADR 0033 Batch 3b (#521 slice E) scalars -> 3 cmdlet parameters.
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyUserType)) {
        $splat.NotifyUserType = [string]$Hash.notifyUserType
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyOverrideRequirements)) {
        $splat.NotifyOverrideRequirements = [string]$Hash.notifyOverrideRequirements
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyEmailOnedriveRemediationActions)) {
        $splat.NotifyEmailOnedriveRemediationActions = [string]$Hash.notifyEmailOnedriveRemediationActions
    }

    # ADR 0033 Batch 3c (#521 slice F) scalars -> 2 cmdlet parameters.
    if (-not [string]::IsNullOrEmpty([string]$Hash.notifyAllowOverride)) {
        $splat.NotifyAllowOverride = [string]$Hash.notifyAllowOverride
    }
    if (-not [string]::IsNullOrEmpty([string]$Hash.incidentReportContent)) {
        $splat.IncidentReportContent = [string]$Hash.incidentReportContent
    }

    # ADR 0033 Batch 4/1 (#521 slice G): emit -EndpointDlpRestrictions as a
    # plain hashtable[]. Each item is rebuilt from the normalized pscustomobject
    # so the cmdlet receives a Microsoft-shaped @{setting=...; value=...; ...} payload.
    if ($Hash.endpointDlpRestrictions -and @($Hash.endpointDlpRestrictions).Count -gt 0) {
        $splat.EndpointDlpRestrictions = @($Hash.endpointDlpRestrictions | ForEach-Object {
            $row = @{}
            foreach ($p in $_.PSObject.Properties) { $row[$p.Name] = $p.Value }
            $row
        })
    }

    # ADR 0033 Batch 4/2 (#521 slice H): emit -AlertProperties as a plain
    # hashtable. The cmdlet expects a single Microsoft-shaped @{key=value; ...} bag.
    if ($null -ne $Hash.alertProperties) {
        $apBag = @{}
        foreach ($p in $Hash.alertProperties.PSObject.Properties) { $apBag[$p.Name] = $p.Value }
        if ($apBag.Count -gt 0) { $splat.AlertProperties = $apBag }
    }

    # ADR 0033 Batch 4/3 (#521 slice I): emit -RestrictAccess as a plain
    # hashtable[]. Same shape as -EndpointDlpRestrictions but with 2 keys per item.
    if ($Hash.restrictAccess -and @($Hash.restrictAccess).Count -gt 0) {
        $splat.RestrictAccess = @($Hash.restrictAccess | ForEach-Object {
            $row = @{}
            foreach ($p in $_.PSObject.Properties) { $row[$p.Name] = $p.Value }
            $row
        })
    }

    # ContentContainsSensitiveInformation accepts either plain SIT
    # entries (each a hashtable with Name=<GUID> + optional minCount /
    # maxCount / confidencelevel) OR grouped objects that combine SITs
    # with sensitivity labels. We emit plain entries when only SITs
    # are declared, and the grouped form when sensitivity labels are
    # involved.
    # Reference: https://learn.microsoft.com/en-us/purview/dlp-conditions-and-exceptions
    $sitEntries = @($Hash.sensitiveInfoTypes | ForEach-Object {
        $h = @{ Name = $_.guid }
        if ($null -ne $_.minCount)        { $h.minCount        = [int]$_.minCount }
        if ($null -ne $_.maxCount)        { $h.maxCount        = [int]$_.maxCount }
        if (-not [string]::IsNullOrEmpty($_.confidenceLevel)) { $h.confidencelevel = [string]$_.confidenceLevel }
        $h
    })

    $labelEntries = @($Hash.sensitivityLabels | ForEach-Object {
        $displayName = [string]$_.displayName
        if (-not $LabelGuidMap.ContainsKey($displayName)) {
            throw ("Sensitivity label '{0}' referenced by rule '{1}' was not found via Get-Label. Declare it under data-plane/information-protection/labels.yaml first." -f $displayName, $Hash.name)
        }
        @{ name = $LabelGuidMap[$displayName]; type = 'Sensitivity' }
    })

    if ($labelEntries.Count -gt 0) {
        $group = @{
            operator = 'And'
            groups   = @(
                @{
                    operator     = 'Or'
                    name         = ('{0}-Group' -f $Hash.name)
                    sensitivetypes = $sitEntries
                    labels         = $labelEntries
                }
            )
        }
        $splat.ContentContainsSensitiveInformation = $group
    } elseif ($sitEntries.Count -gt 0) {
        $splat.ContentContainsSensitiveInformation = $sitEntries
    }

    # AdvancedRule predicate (ADR 0031). Mutually exclusive with
    # ContentContainsSensitiveInformation per the schema, but defensive
    # against the YAML carrying both: only emit -AdvancedRule when
    # ContentContainsSensitiveInformation is not already set above.
    if ($Hash.advancedRule -and -not $splat.ContainsKey('ContentContainsSensitiveInformation')) {
        $splat.AdvancedRule = ConvertTo-AdvancedRuleWire -AdvancedRule $Hash.advancedRule
    }

    return $splat
}

function Resolve-SensitivityLabelMap {
    # Build a displayName -> ImmutableId lookup map for sensitivity
    # labels. Tenant lookup via Get-Label.
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-label
    $map = @{}
    try {
        $labels = @(Get-Label -ErrorAction Stop)
    } catch {
        Write-Verbose ('Get-Label failed (non-fatal if no rules reference labels): {0}' -f $_.Exception.Message)
        return $map
    }
    foreach ($l in $labels) {
        $dn  = [string]$l.DisplayName
        $iid = $null
        if ($l.ImmutableId)       { $iid = [string]$l.ImmutableId }
        elseif ($l.Guid)          { $iid = [string]$l.Guid }
        elseif ($l.ExchangeObjectId) { $iid = [string]$l.ExchangeObjectId }
        if ($dn -and $iid) { $map[$dn] = $iid.ToLowerInvariant() }
    }
    return $map
}

function Invoke-DlpExport {
    # Round-trip tenant policies + rules back into the YAML's
    # `policies:` block.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantPolicies,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantRules,
        [switch]$Force
    )

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
        if ($existing -and $existing.ContainsKey('policies') -and $existing.policies -and @($existing.policies).Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("Target YAML '{0}' already declares {1} policy entries. Re-run with -Force to overwrite." -f $Path, @($existing.policies).Count)
            return
        }
    }

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

    $rulesByPolicy = @{}
    foreach ($r in $TenantRules) {
        $pn = [string]$r.ParentPolicyName
        if (-not $rulesByPolicy.ContainsKey($pn)) { $rulesByPolicy[$pn] = @() }
        $rulesByPolicy[$pn] += $r
    }

    $exported = @()
    foreach ($t in $TenantPolicies) {
        $entry = [ordered]@{ name = [string]$t.Name }
        if ($t.Comment) { $entry.description = [string]$t.Comment }
        $entry.mode = [string]$t.Mode
        if ($null -ne $t.Priority) { $entry.priority = [int]$t.Priority }

        # Bucket list kept in lockstep with ConvertTo-DesiredDlpPolicyHash,
        # ConvertTo-TenantDlpPolicyHash, Compare-DlpPolicy, and Get-DlpPolicySplat. See #519.
        $loc = [ordered]@{}
        foreach ($pair in @(
            @{ Tenant = 'ExchangeLocation';                       Bucket = 'exchange' },
            @{ Tenant = 'SharePointLocation';                     Bucket = 'sharePoint' },
            @{ Tenant = 'OneDriveLocation';                       Bucket = 'oneDrive' },
            @{ Tenant = 'TeamsLocation';                          Bucket = 'teams' },
            @{ Tenant = 'EndpointDlpLocation';                    Bucket = 'endpoint' },
            @{ Tenant = 'PowerBIDlpLocation';                     Bucket = 'powerBI' },
            @{ Tenant = 'ExchangeOnPremisesLocation';             Bucket = 'exchangeOnPremises' },
            @{ Tenant = 'OneDriveLocationException';              Bucket = 'oneDriveException' },
            @{ Tenant = 'SharePointLocationException';            Bucket = 'sharePointException' },
            @{ Tenant = 'SharePointOnPremisesLocationException';  Bucket = 'sharePointOnPremisesException' },
            @{ Tenant = 'SharePointServerLocation';               Bucket = 'sharePointServer' },
            @{ Tenant = 'TeamsLocationException';                 Bucket = 'teamsException' },
            @{ Tenant = 'EndpointDlpLocationException';           Bucket = 'endpointException' },
            @{ Tenant = 'OnPremisesScannerDlpLocation';           Bucket = 'onPremisesScanner' },
            @{ Tenant = 'OnPremisesScannerDlpLocationException';  Bucket = 'onPremisesScannerException' },
            @{ Tenant = 'PowerBIDlpLocationException';            Bucket = 'powerBIException' },
            @{ Tenant = 'ThirdPartyAppDlpLocation';               Bucket = 'thirdPartyApp' },
            @{ Tenant = 'ThirdPartyAppDlpLocationException';      Bucket = 'thirdPartyAppException' }
        )) {
            $raw = $t.($pair.Tenant)
            if (-not $raw) { continue }
            $items = @($raw | ForEach-Object {
                if ($_.Name)        { [string]$_.Name }
                elseif ($_.Address) { [string]$_.Address }
                else                { [string]$_ }
            } | Where-Object { $_ } | Sort-Object -Unique)
            if ($items.Count -eq 1 -and $items[0] -eq 'All') {
                $loc[$pair.Bucket] = 'All'
            } elseif ($items.Count -gt 0) {
                $loc[$pair.Bucket] = $items
            }
        }
        if ($loc.Count -gt 0) { $entry.locations = $loc }

        # genericLocations export (ADR 0032). When the policy uses the
        # generic -Locations parameter (e.g. the Microsoft 365 Copilot
        # policy with Workload=Applications/Location=Copilot.M365),
        # parse the wire JSON into a structured `genericLocations:`
        # block. Falls back to a `notes:` marker only if the wire JSON
        # is unparseable.
        $genericLocationsNote = $null
        if ($t.Locations) {
            $parsedGl = ConvertFrom-GenericLocationsWire -Wire $t.Locations
            if ($parsedGl.Recognized -and @($parsedGl.Normalized).Count -gt 0) {
                $entry.genericLocations = @($parsedGl.Normalized)
            } elseif (-not $parsedGl.Recognized) {
                $genericLocationsNote = ("Tenant policy has a generic -Locations payload that did not parse ({0}). Reconciler treats this entry as inert pass-through until follow-up support lands." -f $parsedGl.Reason)
            }
        }

        # enforcementPlanes export (ADR 0032). Round-trip verbatim;
        # the Microsoft Copilot policy uses 'CopilotExperiences'.
        if ($t.EnforcementPlanes) {
            $entry.enforcementPlanes = [string]$t.EnforcementPlanes
        }

        # policyTemplateInfo export (ADR 0032 defensive pattern).
        # Exporter-write / applier-skip. Round-tripped so YAML round-trip
        # stays byte-equal; never emitted to New-/Set-DlpCompliancePolicy.
        # Helper (added by #524) handles [Hashtable] / [IDictionary] / [PSCustomObject]
        # input shapes with sort-stable output regardless of bucket order.
        $pti = ConvertTo-NormalizedPolicyTemplateInfo -Source $t.PolicyTemplateInfo
        if ($null -ne $pti) { $entry.policyTemplateInfo = $pti }

        # adaptiveScopes export (#520). 10 cmdlet fields surfaced under a
        # single `adaptiveScopes:` block. Empty ArrayLists are dropped so
        # YAML round-trips stay clean; populated buckets are sorted by
        # name for stable diff output.
        $asBlock = [ordered]@{}
        foreach ($pair in @(
            @{ Tenant = 'EndpointDlpAdaptiveScopes';            Bucket = 'endpoint' },
            @{ Tenant = 'EndpointDlpAdaptiveScopesException';   Bucket = 'endpointException' },
            @{ Tenant = 'ExchangeAdaptiveScopes';               Bucket = 'exchange' },
            @{ Tenant = 'ExchangeAdaptiveScopesException';      Bucket = 'exchangeException' },
            @{ Tenant = 'OneDriveAdaptiveScopes';               Bucket = 'oneDrive' },
            @{ Tenant = 'OneDriveAdaptiveScopesException';      Bucket = 'oneDriveException' },
            @{ Tenant = 'SharePointAdaptiveScopes';             Bucket = 'sharePoint' },
            @{ Tenant = 'SharePointAdaptiveScopesException';    Bucket = 'sharePointException' },
            @{ Tenant = 'TeamsAdaptiveScopes';                  Bucket = 'teams' },
            @{ Tenant = 'TeamsAdaptiveScopesException';         Bucket = 'teamsException' }
        )) {
            $raw = $t.($pair.Tenant)
            if (-not $raw -or @($raw).Count -eq 0) { continue }
            $normed = ConvertTo-NormalizedAdaptiveScopes -Source @($raw)
            if (@($normed).Count -gt 0) {
                $asBlock[$pair.Bucket] = @($normed | ForEach-Object {
                    $o = [ordered]@{ name = [string]$_.name }
                    if ($_.PSObject.Properties.Name -contains 'guid' -and $_.guid) { $o.guid = [string]$_.guid }
                    $o
                })
            }
        }
        if ($asBlock.Count -gt 0) { $entry.adaptiveScopes = $asBlock }

        # If the policy has neither per-workload locations nor a parseable
        # generic-Locations payload, fall back to the `notes:` marker so
        # the entry round-trips through the schema without falsely claiming
        # an empty policy.
        if ($loc.Count -eq 0 -and -not $entry.Contains('genericLocations') -and $t.Locations -and @($t.Locations).Count -gt 0) {
            $entry.notes = if ($genericLocationsNote) { $genericLocationsNote } else { "Tenant policy carries a Locations payload that this reconciler doesn't yet model. Reconciler treats this entry as inert pass-through until follow-up support lands." }
        }

        $ruleEntries = @()
        if ($rulesByPolicy.ContainsKey([string]$t.Name)) {
            foreach ($r in $rulesByPolicy[[string]$t.Name]) {
                $re = [ordered]@{ name = [string]$r.Name }
                if ($null -ne $r.Priority)    { $re.priority    = [int]$r.Priority }
                $sits = @()
                if ($r.ContentContainsSensitiveInformation) {
                    foreach ($s in $r.ContentContainsSensitiveInformation) {
                        if (-not $s) { continue }
                        $guid = $null
                        if ($s.id)       { $guid = [string]$s.id }
                        elseif ($s.name) { $guid = [string]$s.name }
                        if (-not $guid -or $guid -notmatch '^[0-9a-fA-F-]{36}$') { continue }
                        $so = [ordered]@{ guid = $guid.ToLowerInvariant() }
                        if ($null -ne $s.minCount) { $so.minCount = [int]$s.minCount }
                        if ($null -ne $s.maxCount) { $so.maxCount = [int]$s.maxCount }
                        if ($s.confidencelevel)    { $so.confidenceLevel = [string]$s.confidencelevel }
                        $sits += $so
                    }
                }
                if ($sits.Count -gt 0)              { $re.sensitiveInfoTypes     = $sits }
                if ($null -ne $r.BlockAccess)       { $re.blockAccess            = [bool]$r.BlockAccess }
                if ($r.NotifyUser)                  { $re.notifyUser             = @($r.NotifyUser             | ForEach-Object { [string]$_ } | Sort-Object -Unique) }
                if ($r.GenerateIncidentReport)      { $re.generateIncidentReport = @($r.GenerateIncidentReport | ForEach-Object { [string]$_ } | Sort-Object -Unique) }
                if ($r.GenerateAlert)               { $re.generateAlert          = @($r.GenerateAlert          | ForEach-Object { [string]$_ } | Sort-Object -Unique) }

                # ADR 0033 Batch 1 (#521 slice B): export the 3 scalars when
                # the tenant has them (always true in lab today). Comparator
                # only diffs when desired declares the field, so exporting
                # them on round-trip keeps the YAML byte-stable.
                if ($null -ne $r.EnforcePortalAccess)                  { $re.enforcePortalAccess                  = [bool]$r.EnforcePortalAccess }
                if ($null -ne $r.NotifyEmailExchangeIncludeAttachment) { $re.notifyEmailExchangeIncludeAttachment = [bool]$r.NotifyEmailExchangeIncludeAttachment }
                if ($r.ReportSeverityLevel)                            { $re.reportSeverityLevel                  = [string]$r.ReportSeverityLevel }

                # ADR 0033 Batch 2 (#521 slice C): export the 2 operator-meaningful
                # scalars only when the tenant has them set (most rules carry
                # Comment; only the externally-shared rules carry AccessScope).
                if ($r.Comment)     { $re.comment     = [string]$r.Comment }
                if ($r.AccessScope) { $re.accessScope = [string]$r.AccessScope }

                # ADR 0033 Batch 3a (#521 slice D): export the 3 operator-facing
                # notify-content scalars only when the tenant has them set.
                # Empty string (e.g. NotifyEmailCustomText on the Fabric PII rule)
                # is treated as unset for round-trip stability with the comparator.
                if ($r.NotifyEmailCustomText)        { $re.notifyEmailCustomText        = [string]$r.NotifyEmailCustomText }
                if ($r.NotifyPolicyTipCustomText)    { $re.notifyPolicyTipCustomText    = [string]$r.NotifyPolicyTipCustomText }
                if ($r.NotifyPolicyTipDisplayOption) { $re.notifyPolicyTipDisplayOption = [string]$r.NotifyPolicyTipDisplayOption }

                # ADR 0033 Batch 3b (#521 slice E): export the 3 operator-facing
                # notify recipient/override/remediation enums only when the tenant
                # has them set. All currently return sentinel defaults
                # ('NotSet' / 'None') on the 3 lab rules that persist them.
                if ($r.NotifyUserType)                        { $re.notifyUserType                        = [string]$r.NotifyUserType }
                if ($r.NotifyOverrideRequirements)            { $re.notifyOverrideRequirements            = [string]$r.NotifyOverrideRequirements }
                if ($r.NotifyEmailOnedriveRemediationActions) { $re.notifyEmailOnedriveRemediationActions = [string]$r.NotifyEmailOnedriveRemediationActions }

                # ADR 0033 Batch 3c (#521 slice F): export the 2 operator-facing
                # notify override / incident-report scalars only when the tenant
                # has them set. Cmdlet declares both as System.Object[] but tenant
                # returns System.String (comma-joined when multi-value); reconciler
                # honors the wire shape. Closes out Batch 3 of ADR 0033.
                if ($r.NotifyAllowOverride)   { $re.notifyAllowOverride   = [string]$r.NotifyAllowOverride }
                if ($r.IncidentReportContent) { $re.incidentReportContent = [string]$r.IncidentReportContent }

                # ADR 0033 Batch 4/1 (#521 slice G): export the structured
                # endpointDlpRestrictions array only when the tenant has it set.
                # Normalize (sort by `setting`) so the YAML is byte-stable across
                # round-trips, then emit each item as an ordered hashtable so the
                # serializer renders consistent key order.
                if ($r.EndpointDlpRestrictions -and @($r.EndpointDlpRestrictions).Count -gt 0) {
                    $normalized = ConvertTo-NormalizedEndpointDlpRestrictions -Source @($r.EndpointDlpRestrictions)
                    $re.endpointDlpRestrictions = @($normalized | ForEach-Object {
                        $o = [ordered]@{}
                        foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
                        $o
                    })
                }

                # ADR 0033 Batch 4/2 (#521 slice H): export the alert-aggregation
                # property bag only when the tenant has it set. Normalize (sort
                # keys + coerce values to string) so the YAML is byte-stable across
                # round-trips. Today only the Microsoft-shipped Copilot rule
                # populates this with {AggregationType: 'None'}.
                if ($r.AlertProperties) {
                    $apNorm = ConvertTo-NormalizedAlertProperties -Source $r.AlertProperties
                    if ($null -ne $apNorm) {
                        $apOut = [ordered]@{}
                        foreach ($p in $apNorm.PSObject.Properties) { $apOut[$p.Name] = $p.Value }
                        if ($apOut.Keys.Count -gt 0) { $re.alertProperties = $apOut }
                    }
                }

                # ADR 0033 Batch 4/3 (#521 slice I): export the per-action
                # access-restriction array only when the tenant has it set.
                # Same shape as endpointDlpRestrictions (Batch 4/1): sort items
                # by `setting` and emit each item as an ordered hashtable so the
                # YAML serializer renders consistent key order. Today the only
                # populated rule is the Copilot rule carrying {setting: UploadText,
                # value: Block}. Closes out Batch 4 and umbrella #521.
                if ($r.RestrictAccess -and @($r.RestrictAccess).Count -gt 0) {
                    $raNormalized = ConvertTo-NormalizedRestrictAccess -Source @($r.RestrictAccess)
                    $re.restrictAccess = @($raNormalized | ForEach-Object {
                        $o = [ordered]@{}
                        foreach ($p in $_.PSObject.Properties) { $o[$p.Name] = $p.Value }
                        $o
                    })
                }

                # AdvancedRule extraction (ADR 0031). When IsAdvancedRule=True,
                # try to parse the wire JSON into the modeled `advancedRule:`
                # shape; only fall back to the `notes:` pass-through (introduced
                # by PR #516) when the wire shape doesn't match the captured
                # ContentContainsSensitiveInformation tree.
                $advancedRuleEntry = $null
                $advancedRuleNote  = $null
                if (([bool]$r.IsAdvancedRule) -and $r.AdvancedRule) {
                    $parsed = ConvertFrom-AdvancedRuleWire -Wire $r.AdvancedRule
                    if ($parsed.Recognized) {
                        $advancedRuleEntry = $parsed.Normalized
                    } else {
                        $advancedRuleNote = ("Tenant rule predicate is carried in AdvancedRule but the wire shape isn't yet modeled ({0}). Reconciler treats this entry as inert pass-through until follow-up support lands." -f $parsed.Reason)
                    }
                }
                if ($advancedRuleEntry) { $re.advancedRule = $advancedRuleEntry }

                # If the rule carries no modeled predicate, fall back to a
                # notes marker so the entry round-trips through the schema
                # without falsely claiming an empty rule. This covers:
                #   - Microsoft-shipped rules whose AdvancedRule body uses a
                #     predicate type the transform doesn't yet model (e.g.
                #     ExceptIfContentContainsSensitiveInformation).
                #   - Tenant-only shapes the exporter doesn't yet recognize.
                if ($sits.Count -eq 0 -and -not $advancedRuleEntry) {
                    if ($advancedRuleNote) {
                        $re.notes = $advancedRuleNote
                    } else {
                        $re.notes = "Tenant rule has no modeled predicate (no ContentContainsSensitiveInformation, no sensitivity label group). Reconciler treats this entry as inert pass-through."
                    }
                }
                $ruleEntries += $re
            }
        }
        if ($ruleEntries.Count -gt 0) { $entry.rules = $ruleEntries }
        $exported += $entry
    }

    $doc  = [ordered]@{ policies = $exported }
    # WithIndentedSequences indents block-sequence items 2 spaces from
    # their parent key, matching the hand-curated style in the rest of
    # data-plane/ and satisfying the default yamllint indentation rule.
    # Reference: https://www.powershellgallery.com/packages/powershell-yaml
    $body = ConvertTo-Yaml $doc -Options WithIndentedSequences

    # Build the final line list (header + body), strip trailing blank
    # lines introduced by the serializer's final newline so yamllint's
    # empty-lines rule stays happy, then write with explicit LF line
    # endings and exactly one trailing newline so yamllint's new-lines
    # rule is satisfied regardless of host OS. Pattern mirrors
    # scripts/Deploy-Labels.ps1 Export branch.
    $bodyLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($body -split "`n")) { $bodyLines.Add($line.TrimEnd()) }
    while ($bodyLines.Count -gt 0 -and [string]::IsNullOrEmpty($bodyLines[$bodyLines.Count - 1])) {
        $bodyLines.RemoveAt($bodyLines.Count - 1)
    }
    $finalLines = @($headerLines) + @($bodyLines)
    $content = ($finalLines -join "`n") + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
    Write-Information ("Exported {0} tenant policies (and their rules) to '{1}'." -f $exported.Count, $Path) -InformationAction Continue
}

#endregion


#region Module dependencies

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

# Connect-IPPSSession -AccessToken requires ExchangeOnlineManagement
# v3.8.0-Preview1+ (install with -AllowPrerelease until GA).
# Reference: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2
$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

# In-repo ADR 0029 direction-policy decision helper. Shared with the
# sibling Deploy-*.ps1 reconcilers (Deploy-Labels.ps1,
# Deploy-LabelPolicies.ps1, Deploy-AutoLabelPolicies.ps1, ...). The
# module is pure and unit-tested independently; do not re-inline the
# decision logic here.
# Reference: docs/adr/0029-source-of-truth-direction-policy.md
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') `
    -Force -Scope Local -ErrorAction Stop

# In-repo ADR 0052 destructive-operation confirmation gate. Wraps
# $PSCmdlet.ShouldContinue() -- which prompts unconditionally, independent
# of $ConfirmPreference -- so the prune and repo-wins overwrite branches
# cannot be entered unattended from a local terminal.
# Reference: docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1') `
    -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

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
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'." -f $ParametersFile, $key)
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
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.dataPlane'." -f $ParametersFile)
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

#endregion

#region Desired-state load

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
        $schemaPath = Join-Path $scriptRoot '..\data-plane\dlp\policies.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath)) {
            Write-Error ("Schema file not found at '{0}'." -f $schemaPath)
            return
        }
        $schemaText = Get-Content -LiteralPath $schemaPath -Raw
        $docJson = $desiredRoot | ConvertTo-Json -Depth 10
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
        $desiredEntries = @($desiredRoot.policies | ForEach-Object { ConvertTo-DesiredDlpPolicyHash -Entry ([hashtable]$_) })
    }
    Write-Information ("Desired policies: {0}" -f $desiredEntries.Count) -InformationAction Continue
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

#region Connect, enumerate, plan, apply

$report = New-Object 'System.Collections.Generic.List[object]'

try {
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession
    Connect-IPPSSession `
        -AccessToken  $tok.AccessToken `
        -Organization $TenantDomain `
        -ShowBanner:$false `
        -ErrorAction  Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy
    $tenantPolicies = @(Get-DlpCompliancePolicy -ErrorAction Stop)
    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancerule
    $tenantRules    = @(Get-DlpComplianceRule    -ErrorAction Stop)
    Write-Information ("Tenant policies : {0}" -f $tenantPolicies.Count) -InformationAction Continue
    Write-Information ("Tenant rules    : {0}" -f $tenantRules.Count)    -InformationAction Continue

    if ($mode -eq 'Export') {
        Invoke-DlpExport -Path $Path -TenantPolicies $tenantPolicies -TenantRules $tenantRules -Force:$Force.IsPresent
        return
    }

    # Sensitivity-label display-name -> GUID resolution (issue #65).
    $labelGuidMap = Resolve-SensitivityLabelMap

    # Adaptive scope Name -> GUID resolution (#520). Passed to
    # Get-DlpPolicySplat so apply throws clearly if a YAML-referenced
    # adaptive scope is missing from the tenant. Empty map (e.g. tenant
    # has no adaptive scopes) is acceptable when no policy references them.
    $adaptiveScopeMap = Resolve-AdaptiveScopeMap

    # Index tenant data for O(1) lookups.
    $tenantPolicyByName = @{}
    foreach ($t in $tenantPolicies) {
        $tenantPolicyByName[[string]$t.Name] = ConvertTo-TenantDlpPolicyHash -Policy $t
    }
    $tenantRuleByKey = @{}
    foreach ($r in $tenantRules) {
        $key = ('{0}\{1}' -f [string]$r.ParentPolicyName, [string]$r.Name)
        $tenantRuleByKey[$key] = ConvertTo-TenantDlpRuleHash -Rule $r
    }
    $desiredPolicyNames = @($desiredEntries | ForEach-Object { $_.name })

    # ---- Policy-level plan ------------------------------------------------
    $policyPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        # Notes-only pass-through: a policy that declares only structural
        # fields plus 'notes' (no modeled locations and no rules with
        # modeled predicates) can't be created via New-DlpCompliancePolicy
        # because at least one location bucket is required. Skip the
        # Create branch; if the policy already exists in the tenant the
        # Compare-DlpPolicy diff stays empty (no per-workload location
        # buckets are tracked) and the row falls through to NoChange.
        $hasLoc = $false
        foreach ($bucket in @('exchange','sharePoint','oneDrive','teams','endpoint','powerBI')) {
            if (@($d.locations[$bucket]).Count -gt 0) { $hasLoc = $true; break }
        }
        $hasGl = @($d.genericLocations).Count -gt 0
        $isNotesOnly = -not [string]::IsNullOrEmpty([string]$d.notes) -and -not $hasLoc -and -not $hasGl -and (@($d.rules).Count -eq 0)
        if ($isNotesOnly -and -not $tenantPolicyByName.ContainsKey($d.name)) {
            $policyPlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'Notes-only pass-through; no tenant counterpart and no modeled state to create.' })
            continue
        }
        if ($tenantPolicyByName.ContainsKey($d.name)) {
            $diffs = Compare-DlpPolicy -Desired $d -Tenant $tenantPolicyByName[$d.name]
            if ($diffs.Count -eq 0) {
                $policyPlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $d.name; Desired = $d; Reason = 'In sync with tenant.'; Fields = '' })
            } else {
                $policyPlan.Add([pscustomobject]@{ Action = 'Update'; Name = $d.name; Desired = $d; Reason = ('Drift in: {0}' -f ($diffs -join ', ')); Fields = ($diffs -join ',') })
            }
        } else {
            $policyPlan.Add([pscustomobject]@{ Action = 'Create'; Name = $d.name; Desired = $d; Reason = 'Declared in YAML; absent from tenant.'; Fields = '' })
        }
    }
    foreach ($t in $tenantPolicies) {
        $tn = [string]$t.Name
        if ($desiredPolicyNames -notcontains $tn) {
            $reason = if ($PruneMissing.IsPresent) { 'Tenant-only; will be removed (-PruneMissing).' } else { 'Tenant-only; skipped (no -PruneMissing).' }
            $policyPlan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $tn; Desired = $null; Reason = $reason; Fields = '' })
        }
    }

    # ---- Rule-level plan -------------------------------------------------
    # Two-pass structure (planning then applying) so the ADR 0029
    # direction-policy filter and the audit-mode short-circuit below
    # can act on the full rule plan before any New-/Set-/Remove-
    # DlpComplianceRule call fires. Mirrors the policy plan above.
    $rulePlan       = New-Object 'System.Collections.Generic.List[object]'
    $ruleOrphanPlan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($d in $desiredEntries) {
        $desiredRuleNames = @($d.rules | ForEach-Object { $_.name })
        foreach ($dr in $d.rules) {
            $key = ('{0}\{1}' -f $d.name, $dr.name)
            # Notes-only pass-through: a rule that declares only
            # structural fields plus 'notes' (no sensitiveInfoTypes,
            # no sensitivityLabels, no advancedRule) has no predicate
            # the reconciler can send to New-/Set-DlpComplianceRule.
            # Skip Create/Update; plan as NoChange so the row is
            # visible.
            if (-not [string]::IsNullOrEmpty([string]$dr.notes) -and @($dr.sensitiveInfoTypes).Count -eq 0 -and @($dr.sensitivityLabels).Count -eq 0 -and (-not $dr.advancedRule)) {
                $rulePlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $dr.name; Key = $key; Desired = $dr; PolicyName = $d.name; Reason = 'Notes-only pass-through; no Create/Update against tenant.'; Fields = '' })
                continue
            }
            if ($tenantRuleByKey.ContainsKey($key)) {
                $diffs = Compare-DlpRule -Desired $dr -Tenant $tenantRuleByKey[$key]
                if ($diffs.Count -eq 0) {
                    $rulePlan.Add([pscustomobject]@{ Action = 'NoChange'; Name = $dr.name; Key = $key; Desired = $dr; PolicyName = $d.name; Reason = 'In sync with tenant.'; Fields = '' })
                } else {
                    $rulePlan.Add([pscustomobject]@{ Action = 'Update'; Name = $dr.name; Key = $key; Desired = $dr; PolicyName = $d.name; Reason = ('Drift in: {0}' -f ($diffs -join ', ')); Fields = ($diffs -join ',') })
                }
            } else {
                $rulePlan.Add([pscustomobject]@{ Action = 'Create'; Name = $dr.name; Key = $key; Desired = $dr; PolicyName = $d.name; Reason = 'Declared in YAML; absent from tenant.'; Fields = '' })
            }
        }

        # Orphan rules under a managed policy.
        $managedTenantRuleNames = @($tenantRuleByKey.Keys | Where-Object { $_ -like ("{0}\*" -f $d.name) } | ForEach-Object { ($_ -split '\\', 2)[1] })
        foreach ($trn in $managedTenantRuleNames) {
            if ($desiredRuleNames -notcontains $trn) {
                $key = ('{0}\{1}' -f $d.name, $trn)
                $ruleOrphanPlan.Add([pscustomobject]@{ Action = 'Orphan'; Name = $trn; Key = $key; PolicyName = $d.name; Reason = 'Tenant-only rule under managed policy.' })
            }
        }
    }

    # ---- ADR 0029: direction-policy pass ---------------------------------
    # Walk the Update entries in BOTH plans (policies + rules) and
    # consult Resolve-DirectionPolicyAction (from the shared module
    # imported above) to decide Skip vs. Update under the configured
    # policy and operator-supplied SkipNames list. Create / NoChange /
    # Orphan entries are unaffected (a policy or rule that exists in
    # YAML but not in the tenant has no shared-property drift to
    # arbitrate; orphan-removal is gated by -PruneMissing, not by the
    # direction-policy contract). Audit mode is handled by a separate
    # short-circuit below and does not enter this pass. The
    # Write-Warning for repo-wins fires ONCE per drifted object with
    # the comma-joined drifted-field set, matching the per-object
    # shape proven in the sibling Deploy-*.ps1 reconcilers.
    # Reference: docs/adr/0029-source-of-truth-direction-policy.md
    # ADR 0052: names of the objects a repo-wins run would overwrite.
    # Collected across both passes and consumed by the destructive-operation
    # confirmation gate below.
    $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'
    if ($DirectionPolicy -ne 'audit') {
        $skipDecisions = New-Object 'System.Collections.Generic.List[object]'

        # Pass 1: policies. SkipNames is matched against policy.Name.
        foreach ($row in $policyPlan) {
            if ($row.Action -ne 'Update') { continue }
            $displayName = [string]$row.Name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'Policy'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = [string]$row.Fields
                })
                continue
            }
            $fieldsText = [string]$row.Fields
            Write-Warning ("Overwriting tenant on DLP policy '{0}' fields: {1}" -f $displayName, $fieldsText)
            # Keyed on the PLAN, not on $DirectionPolicy: whatever policy let
            # this row through, it IS going to be overwritten. See
            # ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
            $repoWinsOverwrites.Add(("policy '{0}'" -f $displayName))
        }

        # Pass 2: rules. SkipNames is matched against rule.Name (NOT
        # the composite Policy\Rule key) per the AutoLabel precedent
        # and operator expectation.
        foreach ($row in $rulePlan) {
            if ($row.Action -ne 'Update') { continue }
            $displayName = [string]$row.Name
            $decision = Resolve-DirectionPolicyAction `
                -Policy      $DirectionPolicy `
                -SkipList    $SkipNames `
                -DisplayName $displayName `
                -HasDrift    $true
            if ($decision.Action -eq 'Skip') {
                $row.Action = 'Skip'
                $row.Reason = $decision.Reason
                $skipDecisions.Add([pscustomobject]@{
                    Kind        = 'Rule'
                    DisplayName = $displayName
                    Reason      = $decision.Reason
                    Fields      = [string]$row.Fields
                })
                continue
            }
            $fieldsText = [string]$row.Fields
            Write-Warning ("Overwriting tenant on DLP rule '{0}' fields: {1}" -f $displayName, $fieldsText)
            # Keyed on the PLAN, not on $DirectionPolicy. See ConfirmGate.psm1
            # "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
            $repoWinsOverwrites.Add(("rule '{0}'" -f $displayName))
        }

        # Machine-readable marker per skipped object for the workflow's
        # auto-PR step. One line per skipped object so a simple
        # `grep '\[ADR0029-SKIP\]'` over the run log yields the full
        # skip list. Format must match the exact regex
        # `^\[ADR0029-SKIP\] (.+)$` per the github-actions
        # instructions rule, so we do not prefix the Kind here.
        foreach ($s in $skipDecisions) {
            Write-Information ("[ADR0029-SKIP] {0}" -f $s.DisplayName) -InformationAction Continue
        }
    }

    # ---- ADR 0029: audit-mode short-circuit ------------------------------
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

    # ---- ADR 0052: destructive-operation confirmation gate ----
    # The last point before any write at which nothing has been written.
    # Both destructive branches -- the repo-wins overwrite (Set-Dlp*) and the
    # -PruneMissing delete (Remove-Dlp*) -- are gated here, once per run, via
    # $PSCmdlet.ShouldContinue() -- NOT ShouldProcess(). ShouldContinue
    # prompts unconditionally; ShouldProcess only prompts when
    # ConfirmImpact >= $ConfirmPreference, which is the comparison that
    # silently defeated this gate before issue #85.
    #
    # Both gates are keyed on the PLAN -- the set of objects this run will
    # actually overwrite or delete -- and never on $DirectionPolicy. See
    # ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
    #
    # The $yesToAll / $noToAll pair is shared by both gates, so a run that
    # trips the overwrite gate AND the prune gate prompts once, not twice,
    # and never once per object.
    #
    # Suppressed by -Force and by an explicit -Confirm:$false (the CI path --
    # deploy-dlp.yml binds it on every apply step). Skipped under -WhatIf (and
    # therefore under -DirectionPolicy audit, which sets $WhatIfPreference
    # above) so a dry run previews the deletes without blocking on input.
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
        $overwriteQuery = "This run will OVERWRITE tenant fields on {0} shared DLP object(s) with the values from YAML: {1}. Portal edits to those fields are lost. Continue?" -f `
            $repoWinsOverwrites.Count, (($repoWinsOverwrites | Sort-Object) -join ', ')
        if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
            throw 'Aborted by operator at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.'
        }
    }

    if ($PruneMissing.IsPresent) {
        $pruneTargets = @(
            @($policyPlan | Where-Object { $_.Action -eq 'Orphan' } | ForEach-Object { "policy '{0}'" -f $_.Name }) +
            @($ruleOrphanPlan | ForEach-Object { "rule '{0}'" -f $_.Key })
        )
        if ($pruneTargets.Count -gt 0) {
            $pruneQuery = "-PruneMissing will DELETE {0} orphan DLP object(s) from the tenant: {1}. This cannot be undone. Continue?" -f `
                $pruneTargets.Count, (($pruneTargets | Sort-Object) -join ', ')
            if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
                throw 'Aborted by operator at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.'
            }
        }
    }

    # Apply policy-level plan. Policies must exist before rules can
    # bind to them; orphan deletions run last so that rules under an
    # orphan policy can be removed first.
    foreach ($row in ($policyPlan | Where-Object { $_.Action -in @('Create','Update','NoChange','Skip') })) {
        $target = "DLP policy '{0}'" -f $row.Name
        switch ($row.Action) {
            'Create' {
                $splat  = Get-DlpPolicySplat -Hash $row.Desired -AdaptiveScopeMap $adaptiveScopeMap
                $opDesc = 'New-DlpCompliancePolicy ({0})' -f $row.Desired.mode
                if ($PSCmdlet.ShouldProcess($target, $opDesc)) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy
                        New-DlpCompliancePolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Policy'; Name = $row.Name; Reason = ('Would create. {0}' -f $row.Reason) })
                }
            }
            'Update' {
                $splat  = Get-DlpPolicySplat -Hash $row.Desired -AdaptiveScopeMap $adaptiveScopeMap -ForSet
                if ($PSCmdlet.ShouldProcess($target, 'Set-DlpCompliancePolicy')) {
                    try {
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy
                        Set-DlpCompliancePolicy @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Updated'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Policy'; Name = $row.Name; Reason = ('Would update. {0}' -f $row.Reason) })
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason })
            }
            'Skip' {
                # ADR 0029: shared-property drift preserved per
                # portal-wins policy, OR caller-supplied SkipNames hit.
                # Reported only; no write attempted.
                $reason = if ([string]$row.Fields) { ('{0} Drift fields: {1}.' -f $row.Reason, $row.Fields) } else { [string]$row.Reason }
                $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Policy'; Name = $row.Name; Reason = $reason })
            }
        }
    }

    # Apply rule-level plan (Create / Update / NoChange / Skip).
    foreach ($row in $rulePlan) {
        $target = "DLP rule '{0}'" -f $row.Key
        switch ($row.Action) {
            'Create' {
                if ($PSCmdlet.ShouldProcess($target, 'New-DlpComplianceRule')) {
                    try {
                        $splat = Get-DlpRuleSplat -Hash $row.Desired -PolicyName $row.PolicyName -LabelGuidMap $labelGuidMap
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule
                        New-DlpComplianceRule @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Created'; Kind = 'Rule'; Name = $row.Key; Reason = 'Declared in YAML; absent from tenant.' })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $row.Key; Reason = ('Create failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Create'; Kind = 'Rule'; Name = $row.Key; Reason = 'Would create. Declared in YAML; absent from tenant.' })
                }
            }
            'Update' {
                if ($PSCmdlet.ShouldProcess($target, 'Set-DlpComplianceRule')) {
                    try {
                        $splat = Get-DlpRuleSplat -Hash $row.Desired -PolicyName $row.PolicyName -LabelGuidMap $labelGuidMap -ForSet
                        # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancerule
                        Set-DlpComplianceRule @splat -ErrorAction Stop | Out-Null
                        $report.Add([pscustomobject]@{ Category = 'Updated'; Kind = 'Rule'; Name = $row.Key; Reason = $row.Reason })
                    } catch {
                        $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $row.Key; Reason = ('Update failed: {0}' -f $_.Exception.Message) })
                    }
                } else {
                    $report.Add([pscustomobject]@{ Category = 'Update'; Kind = 'Rule'; Name = $row.Key; Reason = ('Would update. {0}' -f $row.Reason) })
                }
            }
            'NoChange' {
                $report.Add([pscustomobject]@{ Category = 'NoChange'; Kind = 'Rule'; Name = $row.Key; Reason = $row.Reason })
            }
            'Skip' {
                # ADR 0029: see policy Skip branch above.
                $reason = if ([string]$row.Fields) { ('{0} Drift fields: {1}.' -f $row.Reason, $row.Fields) } else { [string]$row.Reason }
                $report.Add([pscustomobject]@{ Category = 'Skip'; Kind = 'Rule'; Name = $row.Key; Reason = $reason })
            }
        }
    }

    # Apply rule-level orphan plan (Remove under -PruneMissing).
    foreach ($row in $ruleOrphanPlan) {
        if ($PruneMissing.IsPresent) {
            $target = "DLP rule '{0}'" -f $row.Key
            if ($PSCmdlet.ShouldProcess($target, 'Remove-DlpComplianceRule')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-dlpcompliancerule
                    Remove-DlpComplianceRule -Identity $row.Key -Confirm:$false -ErrorAction Stop | Out-Null
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Rule'; Name = $row.Key; Reason = $row.Reason })
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Rule'; Name = $row.Key; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Rule'; Name = $row.Key; Reason = 'Would remove tenant-only rule under managed policy.' })
            }
        } else {
            $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Rule'; Name = $row.Key; Reason = ('{0} Skipped (no -PruneMissing).' -f $row.Reason) })
        }
    }

    # ---- Orphan policy removal (last, so rule-cascade is harmless) -------
    foreach ($row in ($policyPlan | Where-Object { $_.Action -eq 'Orphan' })) {
        $target = "DLP policy '{0}'" -f $row.Name
        if ($PruneMissing.IsPresent) {
            if ($PSCmdlet.ShouldProcess($target, 'Remove-DlpCompliancePolicy')) {
                try {
                    # Reference: https://learn.microsoft.com/en-us/powershell/module/exchange/remove-dlpcompliancepolicy
                    Remove-DlpCompliancePolicy -Identity $row.Name -Confirm:$false -ErrorAction Stop | Out-Null
                    $report.Add([pscustomobject]@{ Category = 'Removed'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason })
                } catch {
                    $report.Add([pscustomobject]@{ Category = 'Failed'; Kind = 'Policy'; Name = $row.Name; Reason = ('Remove failed: {0}' -f $_.Exception.Message) })
                }
            } else {
                $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Policy'; Name = $row.Name; Reason = ('Would remove. {0}' -f $row.Reason) })
            }
        } else {
            $report.Add([pscustomobject]@{ Category = 'Orphan'; Kind = 'Policy'; Name = $row.Name; Reason = $row.Reason })
        }
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

# Emit the categorized plan. Columns: Category / Kind / Name / Reason.
$report
