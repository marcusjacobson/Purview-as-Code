#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile custom Microsoft Purview Sensitive Information Type (SIT) rule
    packages against `data-plane/classifications/sit-rule-packages.yaml`
    (desired state) plus the verbatim rule-package XML files it indexes.

.DESCRIPTION
    The full-circle declarative reconciler for custom pattern (regex / keyword)
    SITs, per docs/adr/0061-custom-sit-rule-package-shape.md. Custom SITs are
    managed as whole rule packages through the Security & Compliance PowerShell
    `*-DlpSensitiveInformationTypeRulePackage` cmdlet family (which takes a
    verbatim rule-package XML blob via `-FileData <byte[]>`), NOT the
    fingerprint-only `*-DlpSensitiveInformationType` triple. `sit-catalog.yaml`
    remains an export-only reference catalog owned by `Sync-SITCatalog.ps1`
    (ADR 0056 carve-out 1); this reconciler owns the custom-SIT *desired state*.

    DESIRED-STATE SHAPE (ADR 0061)
      * `data-plane/classifications/sit-rule-packages.yaml` -- a `rulePackages:`
        manifest. Each entry: { name, rulePackId, version, file, sits: [{name,id}] }.
      * `data-plane/classifications/rule-packages/*.xml` -- one verbatim
        rule-package XML per manifest entry. The manifest's rulePackId / version
        / entity ids MUST match the values declared inside the referenced XML;
        a mismatch is a `Blocked` row, never a silent write.

    MICROSOFT-MANAGED PACKS ARE OUT OF SCOPE (ADR 0061 decision 3)
      The reconciler manages ONLY packs whose rulePackId appears in the manifest.
      Four identifier classes are a reserved denylist and are never created,
      updated, or pruned -- a `Blocked` row is emitted if any is referenced or
      would be matched for prune:
        * the built-in `Microsoft Rule Package` (Publisher 'Microsoft Corporation');
        * any `IsFingerprintRuleCollection` pack (document fingerprints, out of
          scope per ADR 0016);
        * any EDM pack (XML namespace http://schemas.microsoft.com/office/2018/edm,
          out of scope per ADR 0016);
        * `Microsoft.SCCManaged.CustomRulePack` (fixed GUID
          5DA58D7A-25F1-4205-93D0-BEB10054C503) -- the Microsoft-provisioned
          container that holds PORTAL-created custom SITs. Portal customs stay
          portal-owned.

    DRIFT IS CANONICAL, NOT BYTE-EXACT (ADR 0061 decision 4)
      The service stamps `lastModifiedTime` on every `<Entity>` at write time, so
      an exported pack never byte-matches the uploaded XML. `NoChange` therefore
      normalizes both sides (strip service-stamped timestamps, sort attributes)
      before comparing. A content change with an unchanged `<Version>` is a
      `Blocked` row -- the service silently ignores an update whose version was
      not bumped (ADR 0061 decision 5).

    Two modes:
      -ExportCurrentState  Pull every reconcilable custom pack from the tenant,
                           write its XML under rule-packages/ and index it in the
                           manifest (header comments preserved by line-splicing).
                           Microsoft-managed packs are Skipped with a reason.
                           No tenant writes.
      (default) Apply      Plan Create / Update / NoChange / Orphan / Skip /
                           Blocked, gate destructive operations (ADR 0052), and
                           apply via New-/Set-/Remove-DlpSensitiveInformationTypeRulePackage.

    Auth path is identical to Sync-SITCatalog.ps1 / Deploy-*.ps1: `az account show`
    -> resolve the data-plane Entra app -> Get-PurviewIPPSAccessToken.ps1 (local
    cert or Key Vault sign) -> Connect-IPPSSession -AccessToken. The local-cert
    path (ADR 0028) is selected automatically inside the token helper when
    $env:PURVIEW_LOCAL_CERT_THUMBPRINT is set; this script needs no wiring for it.

    References (Microsoft Learn):
      New-DlpSensitiveInformationTypeRulePackage:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-dlpsensitiveinformationtyperulepackage
      Get-DlpSensitiveInformationTypeRulePackage:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-dlpsensitiveinformationtyperulepackage
      Remove-DlpSensitiveInformationTypeRulePackage:
        https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/remove-dlpsensitiveinformationtyperulepackage
      Create a custom SIT in PowerShell (rule-package XML schema + limits):
        https://learn.microsoft.com/en-us/purview/sit-create-a-custom-sensitive-information-type-in-scc-powershell
      ADR 0061 (this shape): docs/adr/0061-custom-sit-rule-package-shape.md
      ADR 0052 (confirm gate): docs/adr/0052-destructive-confirmation-gate-at-script-layer.md
      ADR 0029 (direction policy): docs/adr/0029-source-of-truth-direction-policy.md
      ADR 0012 (parameters file): docs/adr/0012-environment-parameters-file.md

.PARAMETER Path
    Path to the desired-state manifest YAML. Defaults to the in-repo location
    `data-plane/classifications/sit-rule-packages.yaml`.

.PARAMETER PruneMissing
    Authorize `Remove-DlpSensitiveInformationTypeRulePackage` for tenant custom
    packs absent from the manifest (orphans). Guarded by the empty-desired-set
    and sanity-ratio guards (PruneGuard.psm1) and the ADR 0052 gate. Reserved
    Microsoft-managed packs are never orphan candidates.

.PARAMETER AllowMajorityPrune
    Override for the sanity-ratio guard (guard 2) only. Permits a prune that
    would remove more than -MaxPruneRatio of the live custom packs.

.PARAMETER MaxPruneRatio
    Guard-2 threshold in (0, 1]. Default 0.5.

.PARAMETER Force
    On Export: allow overwriting a non-empty manifest. On Apply: suppress the
    ADR 0052 confirmation prompt (the attended equivalent of -Confirm:$false).

.PARAMETER ExportCurrentState
    Pull reconcilable custom packs from the tenant into the manifest + XML files
    and exit. Makes no writes to the tenant.

.PARAMETER ParametersFile
    Environment parameters YAML (ADR 0012). When omitted, PURVIEW_PARAMETERS_FILE
    (ADR 0057) is used, else infra/parameters/lab.yaml.

.PARAMETER VaultName
    Key Vault holding the automation certificate. Resolved from the parameters
    file when omitted.

.PARAMETER CertificateName
    Key Vault certificate/key object name. Resolved from the parameters file when
    omitted.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). Resolved from the
    parameters file when omitted.

.PARAMETER TenantDomain
    Tenant primary domain for Connect-IPPSSession -Organization. Resolved from the
    parameters file when omitted.

.PARAMETER DirectionPolicy
    ADR 0029 source-of-truth policy for Update drift: 'portal-wins' (default,
    preserve tenant edits, emit Skip), 'repo-wins' (overwrite from XML), or
    'audit' (plan only, no writes).

.PARAMETER SkipNames
    Rule-package names to force-skip on Update regardless of drift (ADR 0029).

.PARAMETER SkipSchemaValidation
    Bypass manifest JSON-schema validation (emergency use only).

.EXAMPLE
    ./scripts/Deploy-SITRulePackages.ps1 -ExportCurrentState
    Hydrate the manifest + rule-packages/*.xml from the live tenant. Refuses to
    clobber a non-empty manifest without -Force.

.EXAMPLE
    ./scripts/Deploy-SITRulePackages.ps1 -WhatIf
    Print the Create/Update/NoChange/Orphan/Skip/Blocked plan with no writes.

.EXAMPLE
    ./scripts/Deploy-SITRulePackages.ps1 -PruneMissing -Confirm:$false
    Apply the manifest and delete orphan custom packs (CI/unattended path).

.NOTES
    Output: a list of PSCustomObjects with columns Category / Kind / Name / Field
    / Reason. Category is one of Create, Update, NoChange, Orphan, NoOp, Skip,
    Blocked. No credential material is printed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\classifications\sit-rule-packages.yaml'),

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$PruneMissing,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$AllowMajorityPrune,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0.0000001, 1.0)]
    [double]$MaxPruneRatio = 0.5,

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
    [AllowEmptyCollection()]
    [string[]]$SkipNames = @(),

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [switch]$SkipSchemaValidation
)

$ErrorActionPreference = 'Stop'

#region Reserved-pack constants (ADR 0061 decision 3)

# The Microsoft-managed rule packs the reconciler must never create, update, or
# prune. Fingerprint packs are matched on the IsFingerprintRuleCollection flag
# and EDM packs on the XML namespace; the two below are matched by identity.
$script:MicrosoftBuiltinRuleCollectionName = 'Microsoft Rule Package'
# Microsoft.SCCManaged.CustomRulePack fixed container GUID. Claimed as a
# Microsoft constant in .github/agents/tenant-placeholders.yaml.
$script:SccManagedRulePackId             = '5da58d7a-25f1-4205-93d0-beb10054c503'
$script:SccManagedRuleCollectionName     = 'Microsoft.SCCManaged.CustomRulePack'
$script:EdmNamespace                     = 'http://schemas.microsoft.com/office/2018/edm'
# Microsoft Learn: keep the uploaded rule-package file under ~770 KB, and no more
# than 10 rule packages per tenant.
$script:MaxRulePackageBytes              = 770 * 1024
$script:MaxRulePackagesPerTenant         = 10

#endregion

#region Helpers (pure functions -- unit-tested via AST extraction)

function ConvertFrom-RulePackXmlContent {
    # Load rule-package bytes into an XmlDocument honouring the XML encoding
    # declaration (packs are UTF-16). Returns [xml].
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $doc = [System.Xml.XmlDocument]::new()
    $doc.PreserveWhitespace = $false
    $stream = [System.IO.MemoryStream]::new($Bytes)
    try { $doc.Load($stream) } finally { $stream.Dispose() }
    return $doc
}

function Get-RulePackIdFromXml {
    # Extract the <RulePack id> GUID (lower-cased) using local-name() XPath so
    # namespace prefixes never matter. Returns $null when absent.
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Doc)
    $node = $Doc.SelectSingleNode("//*[local-name()='RulePack']")
    if (-not $node) { return $null }
    $idAttr = $node.Attributes['id']
    if (-not $idAttr) { return $null }
    return $idAttr.Value.Trim().ToLowerInvariant()
}

function Get-RulePackVersionFromXml {
    # Extract the PACK version from RulePack/Version (NOT the Rules/Version
    # min-engine wrapper). Returns [version] or $null.
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Doc)
    $node = $Doc.SelectSingleNode("//*[local-name()='RulePack']/*[local-name()='Version']")
    if (-not $node) { return $null }
    $get = { param($n) $v = $node.Attributes[$n]; if ($v) { [int]$v.Value } else { 0 } }
    return [version]::new((& $get 'major'), (& $get 'minor'), (& $get 'build'), (& $get 'revision'))
}

function Get-RulePackEntitiesFromXml {
    # Return the SITs a pack defines: [{ id; name }] pulled from <Entity id> and
    # the matching <LocalizedStrings>/<Resource>/<Name>. Used for the manifest
    # cross-reference and for export.
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Doc)
    $names = @{}
    foreach ($res in $Doc.SelectNodes("//*[local-name()='LocalizedStrings']/*[local-name()='Resource']")) {
        $idRef = $res.Attributes['idRef']
        if (-not $idRef) { continue }
        $nameNode = $res.SelectSingleNode("*[local-name()='Name']")
        if ($nameNode) { $names[$idRef.Value.Trim().ToLowerInvariant()] = $nameNode.InnerText.Trim() }
    }
    $entities = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Doc.SelectNodes("//*[local-name()='Entity']")) {
        $idAttr = $e.Attributes['id']
        if (-not $idAttr) { continue }
        $id = $idAttr.Value.Trim().ToLowerInvariant()
        $entities.Add([pscustomobject]@{ id = $id; name = ($names.ContainsKey($id) ? $names[$id] : $null) })
    }
    return , $entities.ToArray()
}

function ConvertTo-CanonicalRulePackXml {
    # Produce a deterministic, comparison-stable string form of a rule package:
    # strip service-stamped volatile attributes (lastModifiedTime), default-fill
    # attributes the service injects on write when authored XML omits them, sort
    # every element's attributes, and emit without insignificant whitespace. This
    # is the NoChange comparator's normal form (ADR 0061 decision 4); it ignores
    # fields the service rewrites/adds on every write so an untouched pack reports
    # NoChange after an export round-trip. Phase 3's live gate validates it.
    param([Parameter(Mandatory = $true)][System.Xml.XmlDocument]$Doc)
    $volatile = @('lastModifiedTime')
    # <Entity relaxProximity> defaults to "false" and is stamped onto every entity
    # at write time when the authored XML omits it (observed live, #48 Phase 3;
    # undocumented on Microsoft Learn as of 2026-07-22). Default-filling it here,
    # rather than stripping it as volatile, keeps an explicit non-default value
    # (relaxProximity="true") a real, comparable drift.
    $entityDefaults = @{ relaxProximity = 'false' }
    $sb = [System.Text.StringBuilder]::new()
    $emit = {
        param($node)
        if ($node.NodeType -eq [System.Xml.XmlNodeType]::Text) {
            [void]$sb.Append($node.Value.Trim())
            return
        }
        if ($node.NodeType -ne [System.Xml.XmlNodeType]::Element) { return }
        [void]$sb.Append('<').Append($node.LocalName)
        $attrs = New-Object 'System.Collections.Generic.List[object]'
        foreach ($a in $node.Attributes) {
            if ($null -eq $a.Value -or $volatile -contains $a.LocalName) { continue }
            $attrs.Add([pscustomobject]@{ LocalName = $a.LocalName; Value = $a.Value })
        }
        if ($node.LocalName -eq 'Entity') {
            foreach ($defaultName in $entityDefaults.Keys) {
                if (-not ($attrs | Where-Object { $_.LocalName -eq $defaultName })) {
                    $attrs.Add([pscustomobject]@{ LocalName = $defaultName; Value = $entityDefaults[$defaultName] })
                }
            }
        }
        foreach ($a in ($attrs | Sort-Object LocalName)) {
            [void]$sb.Append(' ').Append($a.LocalName).Append('="').Append($a.Value.Trim()).Append('"')
        }
        [void]$sb.Append('>')
        foreach ($child in $node.ChildNodes) { & $emit $child }
        [void]$sb.Append('</').Append($node.LocalName).Append('>')
    }
    $root = $Doc.DocumentElement
    if ($root) { & $emit $root }
    return $sb.ToString()
}

function Test-ReservedRulePack {
    # $true when a pack (by rulePackId / RuleCollectionName / fingerprint flag /
    # EDM namespace) is Microsoft-managed and out of scope. Reason returned via
    # -ReasonRef for the Blocked/Skip row.
    param(
        [string]$RulePackId,
        [string]$RuleCollectionName,
        [bool]$IsFingerprint,
        [bool]$IsEdm,
        [ref]$ReasonRef
    )
    $id = if ($RulePackId) { $RulePackId.Trim().ToLowerInvariant() } else { '' }
    if ($RuleCollectionName -eq $script:MicrosoftBuiltinRuleCollectionName) {
        if ($ReasonRef) { $ReasonRef.Value = 'Microsoft built-in rule package -- read-only, out of scope (ADR 0061).' }
        return $true
    }
    if ($IsFingerprint) {
        if ($ReasonRef) { $ReasonRef.Value = 'Document-fingerprint rule package -- out of scope (ADR 0016/0061).' }
        return $true
    }
    if ($IsEdm) {
        if ($ReasonRef) { $ReasonRef.Value = 'EDM rule package -- out of scope (ADR 0016/0061).' }
        return $true
    }
    if ($id -eq $script:SccManagedRulePackId -or $RuleCollectionName -eq $script:SccManagedRuleCollectionName) {
        if ($ReasonRef) { $ReasonRef.Value = 'Microsoft.SCCManaged.CustomRulePack -- portal-managed custom-SIT container, out of scope (ADR 0061).' }
        return $true
    }
    return $false
}

function Get-RulePackIdFromIdentityDn {
    # Parse the rulePackId from a Get-DlpSensitiveInformationTypeRulePackage
    # object's Identity DN tail (.../Configuration/<guid>). The object exposes no
    # RulePackId property (verified live, #48 Phase 2.1). The built-in "Microsoft
    # Rule Package" returns an EMPTY Identity live (#48 Phase 3 finding) -- it has
    # no per-tenant Configuration object -- so this returns $null rather than
    # requiring a value; that pack is still classified as reserved via its
    # RuleCollectionName in Test-ReservedRulePack, which never depends on RulePackId.
    param([AllowEmptyString()][string]$IdentityDn)
    if ([string]::IsNullOrWhiteSpace($IdentityDn)) { return $null }
    $tail = ($IdentityDn -split '/')[-1]
    return $tail.Trim().ToLowerInvariant()
}

function ConvertTo-SafeFileName {
    # Deterministic, filesystem-safe basename for an exported pack XML.
    param([Parameter(Mandatory = $true)][string]$Name)
    $safe = ($Name -replace '[^A-Za-z0-9._-]', '-').Trim('-')
    if (-not $safe) { $safe = 'rule-package' }
    return $safe.ToLowerInvariant()
}

#endregion

#region Module dependencies

if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$module = 'ExchangeOnlineManagement'
if (-not (Get-Module -ListAvailable -Name $module)) {
    Write-Information ("Installing {0} module to CurrentUser scope." -f $module) -InformationAction Continue
    Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -AllowPrerelease
}
Import-Module $module -ErrorAction Stop

Import-Module (Join-Path $PSScriptRoot 'modules/PruneGuard.psm1')     -Force -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules/ConfirmGate.psm1')    -Force -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) { $env:PURVIEW_PARAMETERS_FILE }
    else { Join-Path $repoRoot 'infra/parameters/lab.yaml' }
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) { Write-Error ("Parameters file '{0}' parsed as empty." -f $ParametersFile); return }

foreach ($key in @('resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'." -f $ParametersFile, $key); return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing 'resources.keyVault.name'." -f $ParametersFile); return
}
if (-not $parameters.automation.ContainsKey('tenantDomain')) {
    Write-Error ("Parameters file '{0}' is missing 'automation.tenantDomain'." -f $ParametersFile); return
}
if (-not $parameters.automation.ContainsKey('apps') -or -not $parameters.automation.apps.ContainsKey('dataPlane')) {
    Write-Error ("Parameters file '{0}' is missing 'automation.apps.dataPlane'." -f $ParametersFile); return
}
foreach ($key in @('displayName', 'certificateName')) {
    if (-not $parameters.automation.apps.dataPlane.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing 'automation.apps.dataPlane.{1}'." -f $ParametersFile, $key); return
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
Write-Information ("Direction policy: {0}" -f $DirectionPolicy) -InformationAction Continue
Write-Information ("Manifest path   : {0}" -f $Path) -InformationAction Continue

#endregion

#region Desired-state load + guard 1

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Desired-state manifest not found at '{0}'." -f $Path); return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$manifestRoot = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Yaml
$desiredEntries = @()
if ($manifestRoot -and $manifestRoot.ContainsKey('rulePackages') -and $manifestRoot.rulePackages) {
    $desiredEntries = @($manifestRoot.rulePackages)
}

$manifestDir = Split-Path -Parent $Path

# The report is accumulated across both modes.
$report = New-Object 'System.Collections.Generic.List[object]'
function Add-Row {
    param([string]$Category, [string]$Name, [string]$Field = '', [string]$Reason = '')
    $report.Add([pscustomobject]@{ Category = $Category; Kind = 'SITRulePackage'; Name = $Name; Field = $Field; Reason = $Reason })
}

# Build the desired model (parse each XML, cross-validate against the manifest).
# Blocked rows here never touch the tenant.
$desired = New-Object 'System.Collections.Generic.List[object]'
foreach ($entry in $desiredEntries) {
    $name       = [string]$entry.name
    $rulePackId = ([string]$entry.rulePackId).Trim().ToLowerInvariant()
    $version    = [string]$entry.version
    $fileRel    = [string]$entry.file

    if (-not $fileRel) { Add-Row -Category 'Blocked' -Name $name -Reason 'Manifest entry has no `file`.'; continue }
    $xmlPath = Join-Path $manifestDir $fileRel
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        Add-Row -Category 'Blocked' -Name $name -Field 'file' -Reason ("Referenced XML not found: '{0}'." -f $fileRel); continue
    }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $xmlPath).Path)
    try { $doc = ConvertFrom-RulePackXmlContent -Bytes $bytes }
    catch { Add-Row -Category 'Blocked' -Name $name -Field 'file' -Reason ("XML failed to parse: {0}" -f $_.Exception.Message); continue }

    $xmlId  = Get-RulePackIdFromXml -Doc $doc
    $xmlVer = Get-RulePackVersionFromXml -Doc $doc

    $reason = ''
    if (Test-ReservedRulePack -RulePackId $rulePackId -RuleCollectionName $name -IsFingerprint $false -IsEdm ($doc.OuterXml -like "*$($script:EdmNamespace)*") -ReasonRef ([ref]$reason)) {
        Add-Row -Category 'Blocked' -Name $name -Reason ("Refusing to manage a reserved pack. {0}" -f $reason); continue
    }
    if (-not $xmlId) { Add-Row -Category 'Blocked' -Name $name -Field 'file' -Reason 'XML has no <RulePack id>.'; continue }
    if ($xmlId -ne $rulePackId) {
        Add-Row -Category 'Blocked' -Name $name -Field 'rulePackId' -Reason ("Manifest rulePackId '{0}' != XML <RulePack id> '{1}'." -f $rulePackId, $xmlId); continue
    }
    if ($version -and $xmlVer -and ([string]$xmlVer -ne $version)) {
        Add-Row -Category 'Blocked' -Name $name -Field 'version' -Reason ("Manifest version '{0}' != XML <Version> '{1}'." -f $version, [string]$xmlVer); continue
    }
    if ($bytes.Length -gt $script:MaxRulePackageBytes) {
        Add-Row -Category 'Blocked' -Name $name -Field 'file' -Reason ("Rule-package file is {0} bytes, over the ~{1} KB upload limit." -f $bytes.Length, [int]($script:MaxRulePackageBytes / 1024)); continue
    }

    $desired.Add([pscustomobject]@{
        Name       = $name
        RulePackId = $xmlId
        Version    = $xmlVer
        Bytes      = $bytes
        Canonical  = (ConvertTo-CanonicalRulePackXml -Doc $doc)
        XmlPath    = $xmlPath
    })
}

# Guard 1: refuse a prune whose valid desired set is empty (before any tenant contact).
if ($mode -eq 'Apply' -and $PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   $desired.Count `
        -ObjectTypeNoun 'custom SIT rule package' `
        -SourcePath     $Path `
        -CollectionKey  'rulePackages'
}

#endregion

#region Azure context (read-only preamble)

$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) { Write-Error 'No active Azure CLI session. Run `az login` first.'; return }
$account  = ($accountJson -join "`n") | ConvertFrom-Json
$tenantId = [string]$account.tenantId
if (-not $tenantId) { Write-Error 'az account show returned no tenantId.'; return }
Write-Information ("Subscription    : {0}" -f $account.name) -InformationAction Continue

#endregion

#region -WhatIf export short-circuit (no remote calls)

if ($mode -eq 'Export' -and $WhatIfPreference) {
    Write-Information '-WhatIf with -ExportCurrentState. Planned behaviour (no remote calls):' -InformationAction Continue
    Write-Information '  1. Resolve the data-plane Entra app, acquire a token, Connect-IPPSSession.' -InformationAction Continue
    Write-Information '  2. Get-DlpSensitiveInformationTypeRulePackage; skip Microsoft-managed packs.' -InformationAction Continue
    Write-Information '  3. Write each reconcilable pack to rule-packages/*.xml and rewrite the manifest.' -InformationAction Continue
    return $report
}

#endregion

#region Resolve Entra app + acquire token + connect

$appListJson = az ad app list --display-name $DataPlaneAppDisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "az ad app list failed with exit code $LASTEXITCODE."; return }
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DataPlaneAppDisplayName })
}
if ($appList.Count -eq 0) { Write-Error ("Entra application '{0}' not found." -f $DataPlaneAppDisplayName); return }
if ($appList.Count -gt 1) { Write-Error ("Found {0} apps named '{1}'; ADR 0010 mandates one." -f $appList.Count, $DataPlaneAppDisplayName); return }
$appId = [string]$appList[0].appId

$tokenScript = Join-Path $scriptRoot 'Get-PurviewIPPSAccessToken.ps1'
if (-not (Test-Path -LiteralPath $tokenScript)) { Write-Error ("Helper not found: '{0}'." -f $tokenScript); return }
$tok = & $tokenScript -VaultName $VaultName -CertificateName $CertificateName -AppId $appId -TenantId $tenantId
if (-not $tok -or -not $tok.AccessToken) { Write-Error 'Get-PurviewIPPSAccessToken.ps1 returned no access token.'; return }
Write-Information ("Token acquired  : scope {0}, expires {1:yyyy-MM-ddTHH:mm:ssZ}" -f $tok.Scope, $tok.ExpiresOn) -InformationAction Continue

#endregion

#region Connect, reconcile, disconnect

try {
    Connect-IPPSSession -AccessToken $tok.AccessToken -Organization $TenantDomain -ShowBanner:$false -ErrorAction Stop | Out-Null
    Write-Information ("Connected to Security & Compliance PowerShell as app '{0}'." -f $DataPlaneAppDisplayName) -InformationAction Continue

    # Enumerate tenant packs once; classify each into reconcilable vs reserved.
    $tenantPacks = @(Get-DlpSensitiveInformationTypeRulePackage -ErrorAction Stop)
    $reconcilable = New-Object 'System.Collections.Generic.List[object]'
    foreach ($p in $tenantPacks) {
        $bytes = [byte[]]$p.SerializedClassificationRuleCollection
        $isEdm = $false
        $doc   = $null
        if ($bytes -and $bytes.Length -gt 0) {
            try { $doc = ConvertFrom-RulePackXmlContent -Bytes $bytes; $isEdm = ($doc.OuterXml -like "*$($script:EdmNamespace)*") } catch { $doc = $null }
        }
        $rid = Get-RulePackIdFromIdentityDn -IdentityDn ([string]$p.Identity)
        $rcn = [string]$p.RuleCollectionName
        $reason = ''
        $reserved = Test-ReservedRulePack -RulePackId $rid -RuleCollectionName $rcn `
            -IsFingerprint ([bool]$p.IsFingerprintRuleCollection) -IsEdm $isEdm -ReasonRef ([ref]$reason)
        $reconcilable.Add([pscustomobject]@{
            RulePackId = $rid; RuleCollectionName = $rcn; Bytes = $bytes; Doc = $doc
            Version = $p.Version; Reserved = $reserved; ReservedReason = $reason
            Canonical = ($doc ? (ConvertTo-CanonicalRulePackXml -Doc $doc) : '')
        })
    }
    $managedTenant = @($reconcilable | Where-Object { -not $_.Reserved })

    if ($mode -eq 'Export') {
        #region Export path
        if ($desired.Count -gt 0 -and -not $Force.IsPresent) {
            Write-Error ("Manifest '{0}' already declares {1} rule package(s). Refusing to overwrite without -Force." -f $Path, $desired.Count); return
        }

        foreach ($p in $reconcilable | Where-Object { $_.Reserved }) {
            Add-Row -Category 'Skip' -Name $p.RuleCollectionName -Reason $p.ReservedReason
        }

        $rulePackDir = Join-Path $manifestDir 'rule-packages'
        $exportEntries = New-Object 'System.Collections.Generic.List[hashtable]'
        foreach ($p in $managedTenant) {
            if (-not $p.Doc) { Add-Row -Category 'Skip' -Name $p.RuleCollectionName -Reason 'Pack XML unavailable; cannot export.'; continue }
            $safe = ConvertTo-SafeFileName -Name $p.RuleCollectionName
            $fileRel = "rule-packages/$safe.xml"
            $entities = Get-RulePackEntitiesFromXml -Doc $p.Doc
            $exportEntries.Add([ordered]@{
                name = $p.RuleCollectionName; rulePackId = $p.RulePackId; version = [string]$p.Version
                file = $fileRel; bytes = $p.Bytes
                sits = @($entities | ForEach-Object { [ordered]@{ name = $_.name; id = $_.id } })
            })
            Add-Row -Category 'Export' -Name $p.RuleCollectionName -Reason ("rulePackId={0}; {1} SIT(s)" -f $p.RulePackId, $entities.Count)
        }

        $shouldTarget = "manifest '{0}' and rule-packages/" -f (Split-Path -Leaf $Path)
        if ($PSCmdlet.ShouldProcess($shouldTarget, ("Write {0} rule package(s)" -f $exportEntries.Count))) {
            if (-not (Test-Path -LiteralPath $rulePackDir)) { New-Item -ItemType Directory -Path $rulePackDir -Force | Out-Null }
            foreach ($e in $exportEntries) {
                [System.IO.File]::WriteAllBytes((Join-Path $manifestDir $e.file), [byte[]]$e.bytes)
            }
            # Header-splice the manifest: preserve comments above `rulePackages:`.
            $originalLines = Get-Content -LiteralPath $Path
            $cut = -1
            for ($i = 0; $i -lt $originalLines.Count; $i++) { if ($originalLines[$i] -match '^\s*rulePackages\s*:') { $cut = $i; break } }
            if ($cut -lt 0) { Write-Error ("Could not find 'rulePackages:' key in '{0}'." -f $Path); return }
            $headerLines = if ($cut -gt 0) { $originalLines[0..($cut - 1)] } else { @() }
            $block = New-Object 'System.Collections.Generic.List[string]'
            $block.Add(("# Exported from tenant on {0}. {1} custom rule package(s)." -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd')), $exportEntries.Count))
            if ($exportEntries.Count -eq 0) { $block.Add('rulePackages: []') }
            else {
                $block.Add('rulePackages:')
                foreach ($e in $exportEntries) {
                    $block.Add(("  - name: {0}" -f $e.name))
                    $block.Add(("    rulePackId: {0}" -f $e.rulePackId))
                    $block.Add(("    version: {0}" -f $e.version))
                    $block.Add(("    file: {0}" -f $e.file))
                    if ($e.sits.Count -eq 0) { $block.Add('    sits: []') }
                    else {
                        $block.Add('    sits:')
                        foreach ($s in $e.sits) { $block.Add(("      - name: {0}" -f $s.name)); $block.Add(("        id: {0}" -f $s.id)) }
                    }
                }
            }
            (@($headerLines) + @($block)) | Set-Content -LiteralPath $Path -Encoding utf8
            Write-Information ("Wrote {0} rule package(s) to the manifest. Review the diff before committing." -f $exportEntries.Count) -InformationAction Continue
        }
        #endregion
    }
    else {
        #region Apply path -- plan
        $tenantById = @{}
        foreach ($p in $managedTenant) { $tenantById[$p.RulePackId] = $p }
        $desiredIds = @($desired | ForEach-Object { $_.RulePackId })

        # Phase 1a: the raw plan (Create / NoChange / Blocked / Update candidate).
        # The ADR 0029 DirectionPolicy decision is a SEPARATE pass (Phase 1b) so the
        # ADR 0052 overwrite gate keys on the PLAN -- the packs a run will actually
        # overwrite -- and never on $DirectionPolicy (ConfirmGate.psm1: "KEY THE GATE
        # ON THE PLAN, NOT ON THE POLICY").
        $creates = New-Object 'System.Collections.Generic.List[object]'
        $updateCandidates = New-Object 'System.Collections.Generic.List[object]'
        foreach ($d in $desired) {
            $t = $tenantById[$d.RulePackId]
            if (-not $t) { Add-Row -Category 'Create' -Name $d.Name -Reason ("rulePackId={0}" -f $d.RulePackId); $creates.Add($d); continue }
            if ($d.Canonical -eq $t.Canonical) { Add-Row -Category 'NoChange' -Name $d.Name; continue }
            # Content differs. The service ignores an update whose Version was not
            # bumped, so refuse rather than silently no-op (ADR 0061 decision 5).
            $tVer = if ($t.Version) { [version]$t.Version } else { [version]'0.0.0.0' }
            if (-not ($d.Version -gt $tVer)) {
                Add-Row -Category 'Blocked' -Name $d.Name -Field 'version' -Reason ("Content differs but <Version> ({0}) is not greater than the tenant's ({1}); bump the version or the service will silently ignore the update." -f [string]$d.Version, [string]$tVer)
                continue
            }
            $updateCandidates.Add([pscustomobject]@{ Desired = $d; Name = $d.Name; FromVer = [string]$tVer })
        }

        # Orphans: managed (non-reserved) tenant packs absent from the manifest.
        $orphans = @($managedTenant | Where-Object { $desiredIds -notcontains $_.RulePackId })
        foreach ($o in $orphans) {
            if ($PruneMissing.IsPresent) { Add-Row -Category 'Orphan' -Name $o.RuleCollectionName -Reason ("rulePackId={0}; will be pruned" -f $o.RulePackId) }
            else { Add-Row -Category 'NoOp' -Name $o.RuleCollectionName -Reason ("rulePackId={0}; not in manifest (pass -PruneMissing to delete)" -f $o.RulePackId) }
        }

        # Tenant-limit pre-flight: creates that would exceed 10 total packs.
        $projectedTotal = @($tenantPacks).Count + $creates.Count
        if ($projectedTotal -gt $script:MaxRulePackagesPerTenant) {
            foreach ($d in $creates) { Add-Row -Category 'Blocked' -Name $d.Name -Reason ("Would bring the tenant to {0} rule packages, over the {1}-package limit." -f $projectedTotal, $script:MaxRulePackagesPerTenant) }
            $creates.Clear()
        }

        # Phase 1b: ADR 0029 DirectionPolicy resolution of the Update candidates.
        # $repoWinsOverwrites is the ADR 0052 overwrite-gate list -- the packs this run
        # WILL overwrite. Constructed BEFORE the audit short-circuit so the gate can read
        # .Count unconditionally; under `audit` the pass never runs, the list stays empty,
        # and the plan-keyed gate correctly stays silent. The population is gated only on
        # `-ne 'audit'` (both writing policies) and on the per-pack Skip decision from
        # Resolve-DirectionPolicyAction -- never on a `-eq 'repo-wins'` literal, which
        # would make the gate silent under portal-wins (ConfirmGate rule b).
        $repoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'
        $updates = New-Object 'System.Collections.Generic.List[object]'
        if ($DirectionPolicy -ne 'audit') {
            foreach ($u in $updateCandidates) {
                $decision = Resolve-DirectionPolicyAction -Policy $DirectionPolicy -SkipList $SkipNames -DisplayName $u.Name -HasDrift $true
                if ($decision.Action -eq 'Skip') { Add-Row -Category 'Skip' -Name $u.Name -Reason $decision.Reason; continue }
                Add-Row -Category 'Update' -Name $u.Name -Reason ("version {0} -> {1}" -f $u.FromVer, [string]$u.Desired.Version)
                $repoWinsOverwrites.Add($u.Name) | Out-Null
                $updates.Add($u.Desired)
            }
        }
        else {
            foreach ($u in $updateCandidates) { Add-Row -Category 'Update' -Name $u.Name -Reason ("version {0} -> {1} (audit preview)" -f $u.FromVer, [string]$u.Desired.Version) }
        }

        # Emit the plan table now (before any gate/writes).
        $report | Format-Table Category, Kind, Name, Field, Reason -AutoSize | Out-String | Write-Information -InformationAction Continue

        # Audit short-circuit (ADR 0029): plan only, no writes, guards cannot trip.
        if ($DirectionPolicy -eq 'audit') {
            Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit -- no writes fired. Plan above is read-only.' -InformationAction Continue
            return $report
        }

        # Guard 2 (sanity ratio) on the prune plan, before the ADR 0052 gate.
        if ($PruneMissing.IsPresent) {
            Assert-PruneRatioWithinThreshold `
                -PruneCount     $orphans.Count `
                -LiveCount      $managedTenant.Count `
                -ObjectTypeNoun 'custom SIT rule package' `
                -MaxPruneRatio  $MaxPruneRatio `
                -Allow:$AllowMajorityPrune
        }

        # ADR 0052 destructive-operation gate. Both gates key on the PLAN (their own
        # append-only lists), never on $DirectionPolicy, and each decline throws with
        # zero tenant writes made.
        $yesToAll = $false; $noToAll = $false
        $confirmBound = $PSCmdlet.MyInvocation.BoundParameters.ContainsKey('Confirm')
        $confirmValue = if ($confirmBound) { [bool]$PSCmdlet.MyInvocation.BoundParameters['Confirm'] } else { $false }
        $gateArgs = @{
            Cmdlet = $PSCmdlet; Caption = 'Destructive operation (ADR 0052)'
            YesToAll = ([ref]$yesToAll); NoToAll = ([ref]$noToAll)
            Force = $Force.IsPresent; IsWhatIf = [bool]$WhatIfPreference
            ConfirmBound = $confirmBound; ConfirmValue = $confirmValue
        }
        if ($repoWinsOverwrites.Count -gt 0) {
            $overwriteQuery = "This run will OVERWRITE {0} tenant custom rule package(s) with the repo XML: {1}. Portal edits are lost. Continue?" -f `
                $repoWinsOverwrites.Count, (@($repoWinsOverwrites | Sort-Object -Unique) -join ', ')
            if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) { throw 'Aborted at the repo-wins overwrite confirmation gate (ADR 0052). No tenant writes were made.' }
        }
        $pruneTargets = @($orphans | ForEach-Object { [string]$_.RuleCollectionName })
        if ($PruneMissing.IsPresent -and $pruneTargets.Count -gt 0) {
            $pruneQuery = "-PruneMissing will DELETE {0} orphan custom rule package(s): {1}. This cannot be undone. Continue?" -f `
                $pruneTargets.Count, (@($pruneTargets | Sort-Object -Unique) -join ', ')
            if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) { throw 'Aborted at the -PruneMissing delete confirmation gate (ADR 0052). No tenant writes were made.' }
        }

        # Execute: Create, Update, then prune (each ShouldProcess-gated).
        foreach ($d in $creates) {
            if ($PSCmdlet.ShouldProcess($d.Name, 'New-DlpSensitiveInformationTypeRulePackage')) {
                New-DlpSensitiveInformationTypeRulePackage -FileData $d.Bytes -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Information ("Created rule package '{0}'." -f $d.Name) -InformationAction Continue
            }
        }
        foreach ($d in $updates) {
            if ($PSCmdlet.ShouldProcess($d.Name, 'Set-DlpSensitiveInformationTypeRulePackage')) {
                Set-DlpSensitiveInformationTypeRulePackage -FileData $d.Bytes -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Information ("Updated rule package '{0}'." -f $d.Name) -InformationAction Continue
            }
        }
        if ($PruneMissing.IsPresent -and $orphans.Count -gt 0) {
            $pruneFailures = New-Object 'System.Collections.Generic.List[string]'
            foreach ($o in $orphans) {
                if ($PSCmdlet.ShouldProcess($o.RuleCollectionName, 'Remove-DlpSensitiveInformationTypeRulePackage')) {
                    try {
                        Remove-DlpSensitiveInformationTypeRulePackage -Identity $o.RulePackId -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-Information ("Pruned rule package '{0}'." -f $o.RuleCollectionName) -InformationAction Continue
                    }
                    catch {
                        Write-PruneFailure -Message ("Remove-DlpSensitiveInformationTypeRulePackage '{0}' failed: {1}" -f $o.RuleCollectionName, $_.Exception.Message)
                        $pruneFailures.Add($o.RuleCollectionName)
                        continue
                    }
                }
            }
            if ($pruneFailures.Count -gt 0) {
                throw ("Prune completed with failures; {0} rule package(s) could not be removed: {1}" -f $pruneFailures.Count, ($pruneFailures -join ', '))
            }
        }
        #endregion
    }
}
finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    catch { Write-Verbose ("Disconnect-ExchangeOnline failed: {0}" -f $_.Exception.Message) }
}

return $report

#endregion
