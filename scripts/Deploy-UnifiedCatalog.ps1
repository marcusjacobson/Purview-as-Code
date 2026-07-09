#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Unified Catalog desired state.

.DESCRIPTION
    Promotes Deploy-UnifiedCatalog.ps1 from the placeholder plan-only shape to a
    live full-circle reconciler for the five Unified Catalog concept manifests
    that this repo currently wires to the 2026-03-20-preview API:

      * business-domains.yaml
      * data-products.yaml
      * okrs.yaml
      * critical-data-elements.yaml
      * glossary-terms.yaml

    The script keeps the existing schema-validation gate (Test-Json against the
    co-located Draft-07 schema), reads live tenant state from the preview Unified
    Catalog REST API, emits a categorized drift report, and then performs per-item
    create/update/delete writes behind SupportsShouldProcess.

    Out of scope by design:
      * data-access-policies.yaml
      * health-controls.yaml

    Those manifests remain intentionally unwired because issue #45 only promotes
    the five operation groups above. Keep them out of the live concept table until
    their own API-backed reconciler work lands.

    References:
      Unified Catalog auth for Purview data plane:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      Business Domain REST group:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/
      Data Products REST group:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/
      Okr REST group:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/
      Critical Data Elements REST group:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/critical-data-elements/
      Terms REST group:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/terms/
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012:
        docs/adr/0012-environment-parameters-file.md
      ADR 0047:
        docs/adr/0047-unified-catalog-preview-api-coexistence.md
      ADR 0048:
        docs/adr/0048-purview-account-discovery-gate.md
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\unified-catalog'),

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
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [Alias('PurviewAccountName')]
    [string]$AccountName,

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateSet('audit', 'portal-wins', 'repo-wins')]
    [string]$DirectionPolicy = 'portal-wins',

    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [AllowEmptyCollection()]
    [string[]]$SkipNames = @()
)

$ErrorActionPreference = 'Stop'
$script:SkipNameList = @($SkipNames)
if ($Force.IsPresent) {
    $ConfirmPreference = 'None'
}

#region Module dependencies
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop
#endregion

$script:UnifiedCatalogApiVersion = '2026-03-20-preview'
$script:UnifiedCatalogEndpoint = 'https://api.purview-service.microsoft.com'
$script:CurrentPrincipalIds = @()
$script:ResolvePrincipalScript = Join-Path $PSScriptRoot 'Get-EntraPrincipalIdByDisplayName.ps1'

$script:UnifiedCatalogConcepts = @(
    [ordered]@{ Kind = 'BusinessDomain'; Yaml = 'business-domains.yaml'; Schema = 'business-domains.schema.json'; Order = 1 },
    [ordered]@{ Kind = 'DataProduct'; Yaml = 'data-products.yaml'; Schema = 'data-products.schema.json'; Order = 2 },
    [ordered]@{ Kind = 'Okr'; Yaml = 'okrs.yaml'; Schema = 'okrs.schema.json'; Order = 3 },
    [ordered]@{ Kind = 'CriticalDataElement'; Yaml = 'critical-data-elements.yaml'; Schema = 'critical-data-elements.schema.json'; Order = 4 },
    [ordered]@{ Kind = 'Term'; Yaml = 'glossary-terms.yaml'; Schema = 'glossary-terms.schema.json'; Order = 5 }
)

function Get-DesiredItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$YamlPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $YamlPath)) {
        throw ("Desired-state YAML not found: '{0}'." -f $YamlPath)
    }
    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        throw ("Schema file not found: '{0}'." -f $SchemaPath)
    }

    $raw = Get-Content -LiteralPath $YamlPath -Raw
    $doc = $raw | ConvertFrom-Yaml
    if ($null -eq $doc) {
        throw ("YAML '{0}' parsed as empty." -f $YamlPath)
    }
    if (-not ($doc -is [System.Collections.IDictionary])) {
        throw ("YAML '{0}' did not parse as a mapping at the document root." -f $YamlPath)
    }
    if (-not $doc.ContainsKey('items')) {
        throw ("YAML '{0}' is missing required top-level key 'items' (use [] when none)." -f $YamlPath)
    }

    $json = $doc | ConvertTo-Json -Depth 50
    $null = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction Stop
    return @($doc.items)
}

function ConvertTo-JsonComparable {
    param([Parameter(Mandatory = $true)][object]$InputObject)
    return ($InputObject | ConvertTo-Json -Depth 50 -Compress)
}

function ConvertTo-StringArrayNormalized {
    param([object]$Values)
    if ($null -eq $Values) { return @() }
    return ,@(
        $Values |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
}

function ConvertTo-StatusFromDesired {
    param([string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return 'Draft' }
    return $Status
}

function ConvertTo-StatusToDesired {
    param([string]$Status)
    if ([string]::IsNullOrWhiteSpace($Status)) { return 'Draft' }
    return $Status
}

function ConvertTo-BusinessDomainTypeFromDesired {
    param([string]$Type)
    switch ($Type) {
        'BusinessUnit' { return 'LineOfBusiness' }
        'Functional'   { return 'FunctionalUnit' }
        'ProjectName'  { return 'Project' }
        default        { return $Type }
    }
}

function ConvertTo-BusinessDomainTypeToDesired {
    param([string]$Type)
    switch ($Type) {
        'LineOfBusiness' { return 'BusinessUnit' }
        'FunctionalUnit' { return 'Functional' }
        'Project'        { return 'ProjectName' }
        default          { return $Type }
    }
}

function ConvertTo-CdeDataTypeFromDesired {
    param([string]$Type)
    switch ($Type) {
        'String'     { return 'TEXT' }
        'Number'     { return 'NUMBER' }
        'Date'       { return 'DATETIME' }
        'Boolean'    { return 'BOOLEAN' }
        'Identifier' { return 'TEXT' }
        'Other'      { return 'TEXT' }
        default      { return $Type }
    }
}

function ConvertTo-CdeDataTypeToDesired {
    param([string]$Type)
    switch ($Type) {
        'TEXT'     { return 'String' }
        'NUMBER'   { return 'Number' }
        'DATETIME' { return 'Date' }
        'BOOLEAN'  { return 'Boolean' }
        default    { return 'Other' }
    }
}

function ConvertTo-DataProductTypeFromDesired {
    param([string]$Type)
    switch ($Type) {
        'Dataset'     { return 'Dataset' }
        'Dashboard'   { return 'Dashboard' }
        'MLModel'     { return 'AI' }
        'Operational' { return 'Operational' }
        'MasterData'  { return 'Master' }
        'Reference'   { return 'Reference' }
        'Other'       { return 'Other' }
        default       { return $Type }
    }
}

function ConvertTo-DataProductTypeToDesired {
    param([string]$Type)
    switch ($Type) {
        'AI'     { return 'MLModel' }
        'Master' { return 'MasterData' }
        default  { return $Type }
    }
}

function Resolve-DesiredNumericValue {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $out = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
        return [double]$out
    }
    return $null
}

function ConvertTo-ContactDisplayNameSetFromPayload {
    param(
        [object]$Contacts,
        [string]$Key
    )
    if ($null -eq $Contacts) { return @() }
    $bucket = $Contacts.$Key
    if ($null -eq $bucket) { return @() }
    return ConvertTo-StringArrayNormalized -Values (@($bucket | ForEach-Object {
                if ($_.description) { [string]$_.description }
                elseif ($_.displayName) { [string]$_.displayName }
            }))
}

function Resolve-PrincipalIdByDisplayName {
    param([string]$DisplayName)
    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        throw 'DisplayName must not be empty.'
    }
    if (-not (Test-Path -LiteralPath $script:ResolvePrincipalScript)) {
        throw ("Helper not found: '{0}'." -f $script:ResolvePrincipalScript)
    }
    return (& $script:ResolvePrincipalScript -DisplayName $DisplayName)
}

function ConvertTo-ContactPayloadFromDisplayNameList {
    param([string[]]$DisplayNames)
    $values = ConvertTo-StringArrayNormalized -Values $DisplayNames
    if ($values.Count -eq 0) { return $null }
    $payload = @()
    foreach ($displayName in $values) {
        $payload += [ordered]@{
            id          = [string](Resolve-PrincipalIdByDisplayName -DisplayName $displayName)
            description = $displayName
        }
    }
    return ,@($payload)
}

function ConvertTo-HashtableSansNull {
    param([hashtable]$InputObject)
    $output = [ordered]@{}
    foreach ($key in $InputObject.Keys) {
        $value = $InputObject[$key]
        if ($null -eq $value) { continue }
        $output[$key] = $value
    }
    return $output
}

function Compare-ComparableFieldSet {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Desired,
        [Parameter(Mandatory = $true)][hashtable]$Tenant
    )
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @($Desired.Keys + $Tenant.Keys | Sort-Object -Unique)) {
        $desiredJson = ConvertTo-JsonComparable -InputObject ($Desired[$name])
        $tenantJson = ConvertTo-JsonComparable -InputObject ($Tenant[$name])
        if ($desiredJson -ne $tenantJson) {
            $names.Add([string]$name) | Out-Null
        }
    }
    return $names.ToArray()
}

function ConvertTo-BusinessDomainComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        type        = if ($Item.type) { [string](ConvertTo-BusinessDomainTypeFromDesired -Type $Item.type) } else { '' }
        status      = [string](ConvertTo-StatusFromDesired -Status $Item.status)
    }
}

function ConvertTo-BusinessDomainComparableTenant {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        type        = if ($Item.type) { [string]$Item.type } else { '' }
        status      = [string](ConvertTo-StatusToDesired -Status $Item.status)
    }
}

function ConvertTo-DataProductComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        domain      = [string]$Item.domain
        type        = if ($Item.type) { [string](ConvertTo-DataProductTypeFromDesired -Type $Item.type) } else { '' }
        businessUse = if ($Item.businessUse) { [string]$Item.businessUse } else { '' }
        owners      = ConvertTo-StringArrayNormalized -Values $Item.owners
        status      = [string](ConvertTo-StatusFromDesired -Status $Item.status)
    }
}

function ConvertTo-DataProductComparableTenant {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][hashtable]$DomainById
    )
    $domainName = ''
    if ($Item.domain -and $DomainById.ContainsKey([string]$Item.domain)) {
        $domainName = [string]$DomainById[[string]$Item.domain].name
    }
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        domain      = $domainName
        type        = if ($Item.type) { [string](ConvertTo-DataProductTypeToDesired -Type $Item.type) } else { '' }
        businessUse = if ($Item.businessUse) { [string]$Item.businessUse } else { '' }
        owners      = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'owner'
        status      = [string](ConvertTo-StatusToDesired -Status $Item.status)
    }
}

function ConvertTo-CriticalDataElementComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        domain      = [string]$Item.domain
        dataType    = if ($Item.dataType) { [string](ConvertTo-CdeDataTypeFromDesired -Type $Item.dataType) } else { '' }
        owners      = ConvertTo-StringArrayNormalized -Values $Item.owners
        status      = [string](ConvertTo-StatusFromDesired -Status $Item.status)
    }
}

function ConvertTo-CriticalDataElementComparableTenant {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][hashtable]$DomainById
    )
    $domainName = ''
    if ($Item.domain -and $DomainById.ContainsKey([string]$Item.domain)) {
        $domainName = [string]$DomainById[[string]$Item.domain].name
    }
    return [ordered]@{
        name        = [string]$Item.name
        description = if ($Item.description) { [string]$Item.description } else { '' }
        domain      = $domainName
        dataType    = if ($Item.dataType) { [string](ConvertTo-CdeDataTypeToDesired -Type $Item.dataType) } else { '' }
        owners      = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'owner'
        status      = [string](ConvertTo-StatusToDesired -Status $Item.status)
    }
}

function ConvertTo-OkrComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name       = [string]$Item.name
        domain     = [string]$Item.domain
        targetDate = if ($Item.targetDate) { [string]$Item.targetDate } else { '' }
        owners     = ConvertTo-StringArrayNormalized -Values $Item.owners
        status     = [string](ConvertTo-StatusFromDesired -Status $Item.status)
    }
}

function ConvertTo-OkrComparableTenant {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][hashtable]$DomainById
    )
    $domainName = ''
    if ($Item.domain -and $DomainById.ContainsKey([string]$Item.domain)) {
        $domainName = [string]$DomainById[[string]$Item.domain].name
    }
    $targetDate = ''
    if ($Item.targetDate) {
        $targetDate = ([datetime]$Item.targetDate).ToString('yyyy-MM-dd')
    }
    return [ordered]@{
        name       = [string]$Item.definition
        domain     = $domainName
        targetDate = $targetDate
        owners     = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'owner'
        status     = [string](ConvertTo-StatusToDesired -Status $Item.status)
    }
}

function ConvertTo-KeyResultComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name         = [string]$Item.name
        target       = Resolve-DesiredNumericValue -Value $Item.target
        currentValue = Resolve-DesiredNumericValue -Value $Item.currentValue
    }
}

function ConvertTo-KeyResultComparableTenant {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name         = [string]$Item.definition
        target       = if ($null -ne $Item.goal) { [double]$Item.goal } else { $null }
        currentValue = if ($null -ne $Item.progress) { [double]$Item.progress } else { $null }
    }
}

function ConvertTo-TermComparableDesired {
    param([Parameter(Mandatory = $true)][object]$Item)
    return [ordered]@{
        name              = [string]$Item.name
        domain            = [string]$Item.domain
        description       = if ($Item.description) { [string]$Item.description } else { '' }
        status            = [string](ConvertTo-StatusFromDesired -Status $Item.status)
        acronyms          = ConvertTo-StringArrayNormalized -Values $Item.acronyms
        isLeaf            = [bool]$Item.isLeaf
        parentTerm        = if ($Item.parentTerm) { [string]$Item.parentTerm } else { '' }
        owners            = ConvertTo-StringArrayNormalized -Values $Item.owners
        experts           = ConvertTo-StringArrayNormalized -Values $Item.experts
        databaseAdmins    = ConvertTo-StringArrayNormalized -Values $Item.databaseAdmins
        resources         = @($Item.resources | ForEach-Object { [ordered]@{ name = [string]$_.name; url = [string]$_.url } } | Sort-Object name, url)
        managedAttributes = @($Item.managedAttributes | ForEach-Object { [ordered]@{ name = [string]$_.name } } | Sort-Object name)
    }
}

function ConvertTo-TermComparableTenant {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][hashtable]$DomainById,
        [Parameter(Mandatory = $true)][hashtable]$TermById
    )
    $domainName = ''
    if ($Item.domain -and $DomainById.ContainsKey([string]$Item.domain)) {
        $domainName = [string]$DomainById[[string]$Item.domain].name
    }
    $parentTerm = ''
    if ($Item.parentId -and $TermById.ContainsKey([string]$Item.parentId)) {
        $parentTerm = [string]$TermById[[string]$Item.parentId].name
    }
    $resources = @()
    foreach ($resource in @($Item.resources)) {
        $resources += [ordered]@{ name = [string]$resource.name; url = [string]$resource.url }
    }
    $managedAttributes = @()
    foreach ($attribute in @($Item.managedAttributes)) {
        $managedAttributes += [ordered]@{ name = [string]$attribute.name }
    }
    return [ordered]@{
        name              = [string]$Item.name
        domain            = $domainName
        description       = if ($Item.description) { [string]$Item.description } else { '' }
        status            = [string](ConvertTo-StatusToDesired -Status $Item.status)
        acronyms          = ConvertTo-StringArrayNormalized -Values $Item.acronyms
        isLeaf            = [bool]$Item.isLeaf
        parentTerm        = $parentTerm
        owners            = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'owner'
        experts           = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'expert'
        databaseAdmins    = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Item.contacts -Key 'databaseAdmin'
        resources         = @($resources | Sort-Object name, url)
        managedAttributes = @($managedAttributes | Sort-Object name)
    }
}

function Get-EntityDisplayName {
    param(
        [string]$Kind,
        [object]$Desired,
        [object]$Tenant
    )
    switch ($Kind) {
        'BusinessDomain'      { return [string]$(if ($Desired) { $Desired.name } else { $Tenant.name }) }
        'DataProduct'         { return [string]$(if ($Desired) { $Desired.name } else { $Tenant.name }) }
        'CriticalDataElement' { return [string]$(if ($Desired) { $Desired.name } else { $Tenant.name }) }
        'Okr'                 { return [string]$(if ($Desired) { $Desired.name } else { $Tenant.definition }) }
        'Term'                { return [string]$(if ($Desired) { "{0}/{1}" -f $Desired.domain, $Desired.name } else { $Tenant.name }) }
        'OkrKeyResult'        { return [string]$(if ($Desired) { "{0}/{1}" -f $Desired.__objectiveName, $Desired.name } else { "{0}/{1}" -f $Tenant.__objectiveName, $Tenant.definition }) }
        default               { return '(unknown)' }
    }
}

function Test-IsConflict {
    param([object]$Tenant)
    if ($null -eq $Tenant) { return $false }
    if ($null -eq $Tenant.systemData) { return $false }
    $lastModifiedBy = [string]$Tenant.systemData.lastModifiedBy
    if ([string]::IsNullOrWhiteSpace($lastModifiedBy)) { return $false }
    if (-not $script:CurrentPrincipalIds -or $script:CurrentPrincipalIds.Count -eq 0) { return $false }
    return (-not ($script:CurrentPrincipalIds -contains $lastModifiedBy))
}

function ConvertTo-ReportRow {
    param(
        [string]$Category,
        [string]$Kind,
        [string]$Name,
        [string]$Reason = '',
        [string[]]$Fields = @()
    )
    return [pscustomobject]@{
        Category = $Category
        Kind     = $Kind
        Name     = $Name
        Reason   = $Reason
        Field    = (@($Fields) -join ',')
    }
}

function Get-ReconciliationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DesiredItems,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantItems,
        [Parameter(Mandatory = $true)][scriptblock]$DesiredComparable,
        [Parameter(Mandatory = $true)][scriptblock]$TenantComparable,
        [Parameter(Mandatory = $true)][scriptblock]$DesiredKeySelector,
        [Parameter(Mandatory = $true)][scriptblock]$TenantKeySelector,
        [switch]$AllowConflictOverwrite
    )

    $report = @()
    $plan = @()
    $orphans = @()
    $desiredByKey = @{}
    $tenantByKey = @{}

    foreach ($desired in @($DesiredItems)) {
        $key = [string](& $DesiredKeySelector $desired)
        $desiredByKey[$key] = $desired
    }
    foreach ($tenant in @($TenantItems)) {
        $key = [string](& $TenantKeySelector $tenant)
        $tenantByKey[$key] = $tenant
    }

    foreach ($key in @($desiredByKey.Keys | Sort-Object)) {
        $desired = $desiredByKey[$key]
        $name = Get-EntityDisplayName -Kind $Kind -Desired $desired -Tenant $null
        if (-not $tenantByKey.ContainsKey($key)) {
            $report += (ConvertTo-ReportRow -Category 'Create' -Kind $Kind -Name $name)
            $plan += [pscustomobject]@{ Action = 'Create'; Kind = $Kind; Name = $name; Desired = $desired; Tenant = $null; Fields = @(); Conflict = $false }
            continue
        }

        $tenant = $tenantByKey[$key]
        $desiredHash = & $DesiredComparable $desired
        $tenantHash = & $TenantComparable $tenant
        $fields = @(Compare-ComparableFieldSet -Desired $desiredHash -Tenant $tenantHash)
        if ($fields.Count -eq 0) {
            $report += (ConvertTo-ReportRow -Category 'NoChange' -Kind $Kind -Name $name)
            continue
        }

        if ((Test-IsConflict -Tenant $tenant) -and -not $AllowConflictOverwrite.IsPresent) {
            $report += (ConvertTo-ReportRow -Category 'Conflict' -Kind $Kind -Name $name -Reason 'Tenant object was last modified by a different principal. Re-run with -Force to overwrite.' -Fields $fields)
            continue
        }

        if (Test-IsConflict -Tenant $tenant) {
            $report += (ConvertTo-ReportRow -Category 'Conflict' -Kind $Kind -Name $name -Reason 'Conflict will be overwritten because -Force was supplied.' -Fields $fields)
        }
        else {
            $report += (ConvertTo-ReportRow -Category 'Update' -Kind $Kind -Name $name -Fields $fields)
        }
        $plan += [pscustomobject]@{ Action = 'Update'; Kind = $Kind; Name = $name; Desired = $desired; Tenant = $tenant; Fields = $fields; Conflict = (Test-IsConflict -Tenant $tenant) }
    }

    foreach ($key in @($tenantByKey.Keys | Sort-Object)) {
        if ($desiredByKey.ContainsKey($key)) { continue }
        $tenant = $tenantByKey[$key]
        $name = Get-EntityDisplayName -Kind $Kind -Desired $null -Tenant $tenant
        $report += (ConvertTo-ReportRow -Category 'Orphan' -Kind $Kind -Name $name -Reason 'Exists in the tenant but not in desired state.')
        $orphans += $tenant
    }

    return [pscustomobject]@{
        Report  = @($report)
        Plan    = @($plan)
        Orphans = @($orphans)
    }
}

function ConvertFrom-JwtPayload {
    param([Parameter(Mandatory = $true)][string]$Token)
    $segments = $Token.Split('.')
    if ($segments.Count -lt 2) {
        throw 'Access token does not look like a JWT.'
    }
    $payload = $segments[1].Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    $bytes = [Convert]::FromBase64String($payload)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return ($json | ConvertFrom-Json)
}

function Get-UnifiedCatalogApiContext {
    param([Parameter(Mandatory = $true)][string]$AccountName)

    $connectScript = Join-Path $PSScriptRoot 'Connect-Purview.ps1'
    if (-not (Test-Path -LiteralPath $connectScript)) {
        throw ("Helper not found: '{0}'." -f $connectScript)
    }

    # Reuse the existing auth ladder unchanged first. Connect-Purview.ps1 masks
    # header values by design, so the live Unified Catalog reconciler reacquires
    # the same Purview audience token via az account get-access-token without
    # modifying the shared helper.
    $null = & $connectScript -AccountName $AccountName

    # api-version justification: the Unified Catalog preview endpoints implemented
    # by this reconciler are documented under the 2026-03-20-preview Learn view and
    # ADR 0047 explicitly authorizes that preview contract for issue #45.
    # Reference: https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
    $raw = az account get-access-token --resource https://purview.azure.net --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire the Purview data-plane token. Run 'az login' or configure OIDC."
    }
    $tokenResponse = $raw | ConvertFrom-Json
    $claims = ConvertFrom-JwtPayload -Token $tokenResponse.accessToken

    $principalIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($claims.oid, $claims.appid, $claims.sub)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $principalIds.Add([string]$candidate) | Out-Null
        }
    }
    $script:CurrentPrincipalIds = @($principalIds | Sort-Object -Unique)

    return [pscustomobject]@{
        Endpoint = $script:UnifiedCatalogEndpoint
        Headers  = @{ Authorization = "Bearer $($tokenResponse.accessToken)"; 'Content-Type' = 'application/json' }
        Claims   = $claims
    }
}

function Invoke-UnifiedCatalogRestMethod {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [object]$Body
    )

    if ($PSBoundParameters.ContainsKey('Body')) {
        $json = $Body | ConvertTo-Json -Depth 50
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $json -ErrorAction Stop
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-PagedContinuationUri {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][string]$BaseUri
    )
    if ($Response.nextLink) { return [string]$Response.nextLink }
    if ($Response.skipToken) { return "$BaseUri&`$skipToken=$([uri]::EscapeDataString([string]$Response.skipToken))" }
    if ($Response.'$skipToken') { return "$BaseUri&`$skipToken=$([uri]::EscapeDataString([string]$Response.'$skipToken'))" }
    return $null
}

function Get-UnifiedCatalogBusinessDomainSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/businessdomains?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Business Domain - Enumerate documents the businessdomains
        # list endpoint for 2026-03-20-preview.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items.Add($item) | Out-Null }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCBusinessDomainCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/businessdomains?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 implements Business Domain create against
    # the preview API contract adopted by ADR 0047.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/create?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCBusinessDomainUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$DomainId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $DomainId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/businessdomains/$DomainId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 implements Business Domain update against
    # the preview API contract adopted by ADR 0047.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCBusinessDomainDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$DomainId)
    $null = $DomainId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/businessdomains/$DomainId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 implements Business Domain delete against
    # the preview API contract adopted by ADR 0047.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/delete?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogDataProductSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/dataProducts?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Data Products - List documents the dataProducts list endpoint.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items.Add($item) | Out-Null }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCDataProductCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/dataProducts?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live data-product create using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/create?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCDataProductUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$DataProductId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $DataProductId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/dataProducts/$DataProductId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live data-product update using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCDataProductDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$DataProductId)
    $null = $DataProductId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/dataProducts/$DataProductId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live data-product delete using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/delete?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogObjectiveSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/objectives?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Okr - List documents the objectives list endpoint.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items.Add($item) | Out-Null }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCObjectiveCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live objective create using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/create?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCObjectiveUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$ObjectiveId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $ObjectiveId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live objective update using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCObjectiveDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$ObjectiveId)
    $null = $ObjectiveId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live objective delete using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/delete?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogKeyResultSet {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$ObjectiveId,
        [Parameter(Mandatory = $true)][string]$ObjectiveName
    )
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId/keyResults?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: issue #45 wires live key-result enumeration using
        # the Okr - List Key Results preview endpoint documented by Learn.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/list-key-results?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) {
            $item | Add-Member -NotePropertyName '__objectiveId' -NotePropertyValue $ObjectiveId -Force
            $item | Add-Member -NotePropertyName '__objectiveName' -NotePropertyValue $ObjectiveName -Force
            $items.Add($item) | Out-Null
        }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCKeyResultCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$ObjectiveId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId/keyResults?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live key-result create using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/create-key-result?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCKeyResultUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$ObjectiveId, [Parameter(Mandatory = $true)][string]$KeyResultId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $KeyResultId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId/keyResults/$KeyResultId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live key-result update using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/update-key-result?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCKeyResultDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$ObjectiveId, [Parameter(Mandatory = $true)][string]$KeyResultId)
    $null = $KeyResultId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/objectives/$ObjectiveId/keyResults/$KeyResultId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live key-result delete using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/okr/delete-key-result?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogCriticalDataElementSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/criticalDataElements?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Critical Data Elements - List documents this endpoint.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/critical-data-elements/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items.Add($item) | Out-Null }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCCriticalDataElementCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/criticalDataElements?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live critical-data-element create
    # using the 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/critical-data-elements/create?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCCriticalDataElementUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$CriticalDataElementId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $CriticalDataElementId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/criticalDataElements/$CriticalDataElementId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live critical-data-element update
    # using the 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/critical-data-elements/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCCriticalDataElementDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$CriticalDataElementId)
    $null = $CriticalDataElementId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/criticalDataElements/$CriticalDataElementId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live critical-data-element delete
    # using the 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/critical-data-elements/delete?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogTermSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = New-Object 'System.Collections.Generic.List[object]'
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/terms?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Terms - List documents this endpoint.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/terms/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items.Add($item) | Out-Null }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return $items.ToArray()
}

function Invoke-UCTermCreate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $uri = "$($Context.Endpoint)/datagovernance/catalog/terms?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live term create using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/terms/create?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method POST -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCTermUpdate {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$TermId, [Parameter(Mandatory = $true)][hashtable]$Payload)
    $null = $TermId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/terms/$TermId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live term update using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/terms/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $Context.Headers -Body $Payload
}

function Invoke-UCTermDelete {
    param([Parameter(Mandatory = $true)][object]$Context, [Parameter(Mandatory = $true)][string]$TermId)
    $null = $TermId
    $uri = "$($Context.Endpoint)/datagovernance/catalog/terms/$TermId?api-version=$($script:UnifiedCatalogApiVersion)"
    # api-version justification: issue #45 wires live term delete using the
    # 2026-03-20-preview operation documented by Microsoft Learn.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/terms/delete?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    return Invoke-UnifiedCatalogRestMethod -Method DELETE -Uri $uri -Headers $Context.Headers
}

function Get-UnifiedCatalogTenantState {
    param([Parameter(Mandatory = $true)][object]$Context)
    $domains = @(Get-UnifiedCatalogBusinessDomainSet -Context $Context)
    $domainById = @{}
    $domainByName = @{}
    foreach ($domain in $domains) {
        $domainById[[string]$domain.id] = $domain
        $domainByName[[string]$domain.name] = $domain
    }

    $dataProducts = @(Get-UnifiedCatalogDataProductSet -Context $Context)
    $objectives = @(Get-UnifiedCatalogObjectiveSet -Context $Context)
    foreach ($objective in $objectives) {
        $objectiveKeyResults = @(Get-UnifiedCatalogKeyResultSet -Context $Context -ObjectiveId ([string]$objective.id) -ObjectiveName ([string]$objective.definition))
        $objective | Add-Member -NotePropertyName keyResults -NotePropertyValue $objectiveKeyResults -Force
    }
    $criticalDataElements = @(Get-UnifiedCatalogCriticalDataElementSet -Context $Context)
    $terms = @(Get-UnifiedCatalogTermSet -Context $Context)
    $termById = @{}
    foreach ($term in $terms) {
        $termById[[string]$term.id] = $term
    }

    return [pscustomobject]@{
        Domains              = $domains
        DomainById           = $domainById
        DomainByName         = $domainByName
        DataProducts         = $dataProducts
        Objectives           = $objectives
        CriticalDataElements = $criticalDataElements
        Terms                = $terms
        TermById             = $termById
    }
}

function ConvertTo-BusinessDomainCreatePayload {
    param([object]$Desired)
    return (ConvertTo-HashtableSansNull -InputObject @{
            id                = [guid]::NewGuid().Guid
            name              = [string]$Desired.name
            description       = if ($Desired.description) { [string]$Desired.description } else { $null }
            type              = if ($Desired.type) { [string](ConvertTo-BusinessDomainTypeFromDesired -Type $Desired.type) } else { $null }
            status            = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
            isRestricted      = $false
            domains           = @()
            managedAttributes = @()
            thumbnail         = @{}
            systemData        = @{}
        })
}

function ConvertTo-BusinessDomainUpdatePayload {
    param([object]$Desired, [object]$Tenant)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }
    $payload['name'] = [string]$Desired.name
    $payload['description'] = if ($Desired.description) { [string]$Desired.description } else { $null }
    $payload['type'] = if ($Desired.type) { [string](ConvertTo-BusinessDomainTypeFromDesired -Type $Desired.type) } else { $null }
    $payload['status'] = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-DataProductCreatePayload {
    param([object]$Desired, [hashtable]$DomainByName)
    if (-not $DomainByName.ContainsKey([string]$Desired.domain)) {
        throw ("Business domain '{0}' must exist before creating data product '{1}'." -f $Desired.domain, $Desired.name)
    }
    return (ConvertTo-HashtableSansNull -InputObject @{
            id          = [guid]::NewGuid().Guid
            name        = [string]$Desired.name
            description = if ($Desired.description) { [string]$Desired.description } else { $null }
            domain      = [string]$DomainByName[[string]$Desired.domain].id
            type        = if ($Desired.type) { [string](ConvertTo-DataProductTypeFromDesired -Type $Desired.type) } else { $null }
            businessUse = if ($Desired.businessUse) { [string]$Desired.businessUse } else { $null }
            contacts    = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
            status      = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
        })
}

function ConvertTo-DataProductUpdatePayload {
    param([object]$Desired, [object]$Tenant, [hashtable]$DomainByName)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }
    $payload['name'] = [string]$Desired.name
    $payload['description'] = if ($Desired.description) { [string]$Desired.description } else { $null }
    $payload['domain'] = [string]$DomainByName[[string]$Desired.domain].id
    $payload['type'] = if ($Desired.type) { [string](ConvertTo-DataProductTypeFromDesired -Type $Desired.type) } else { $null }
    $payload['businessUse'] = if ($Desired.businessUse) { [string]$Desired.businessUse } else { $null }
    $payload['contacts'] = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
    $payload['status'] = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-ObjectiveCreatePayload {
    param([object]$Desired, [hashtable]$DomainByName)
    if (-not $DomainByName.ContainsKey([string]$Desired.domain)) {
        throw ("Business domain '{0}' must exist before creating objective '{1}'." -f $Desired.domain, $Desired.name)
    }
    $targetDate = $null
    if ($Desired.targetDate) {
        $targetDate = ([datetime]::ParseExact([string]$Desired.targetDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return (ConvertTo-HashtableSansNull -InputObject @{
            id         = [guid]::NewGuid().Guid
            definition = [string]$Desired.name
            domain     = [string]$DomainByName[[string]$Desired.domain].id
            targetDate = $targetDate
            contacts   = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
            status     = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
        })
}

function ConvertTo-ObjectiveUpdatePayload {
    param([object]$Desired, [object]$Tenant, [hashtable]$DomainByName)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        if ($property.Name -eq 'keyResults') { continue }
        $payload[$property.Name] = $property.Value
    }
    $payload['definition'] = [string]$Desired.name
    $payload['domain'] = [string]$DomainByName[[string]$Desired.domain].id
    $payload['status'] = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
    if ($Desired.targetDate) {
        $payload['targetDate'] = ([datetime]::ParseExact([string]$Desired.targetDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    else {
        $payload['targetDate'] = $null
    }
    $payload['contacts'] = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-KeyResultCreatePayload {
    param([object]$Desired, [string]$DomainId)
    $goal = Resolve-DesiredNumericValue -Value $Desired.target
    $progress = Resolve-DesiredNumericValue -Value $Desired.currentValue
    return (ConvertTo-HashtableSansNull -InputObject @{
            id         = [guid]::NewGuid().Guid
            definition = [string]$Desired.name
            domainId   = $DomainId
            goal       = $goal
            max        = $goal
            progress   = $progress
            status     = 'NotTracked'
        })
}

function ConvertTo-KeyResultUpdatePayload {
    param([object]$Desired, [object]$Tenant, [string]$DomainId)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        if ($property.Name -like '__*') { continue }
        $payload[$property.Name] = $property.Value
    }
    $goal = Resolve-DesiredNumericValue -Value $Desired.target
    $progress = Resolve-DesiredNumericValue -Value $Desired.currentValue
    $payload['definition'] = [string]$Desired.name
    $payload['domainId'] = $DomainId
    $payload['goal'] = $goal
    $payload['max'] = $goal
    $payload['progress'] = $progress
    $payload['status'] = 'NotTracked'
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-CriticalDataElementCreatePayload {
    param([object]$Desired, [hashtable]$DomainByName)
    if (-not $DomainByName.ContainsKey([string]$Desired.domain)) {
        throw ("Business domain '{0}' must exist before creating critical data element '{1}'." -f $Desired.domain, $Desired.name)
    }
    return (ConvertTo-HashtableSansNull -InputObject @{
            id          = [guid]::NewGuid().Guid
            name        = [string]$Desired.name
            description = if ($Desired.description) { [string]$Desired.description } else { $null }
            domain      = [string]$DomainByName[[string]$Desired.domain].id
            dataType    = if ($Desired.dataType) { [string](ConvertTo-CdeDataTypeFromDesired -Type $Desired.dataType) } else { $null }
            contacts    = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
            status      = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
        })
}

function ConvertTo-CriticalDataElementUpdatePayload {
    param([object]$Desired, [object]$Tenant, [hashtable]$DomainByName)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }
    $payload['name'] = [string]$Desired.name
    $payload['description'] = if ($Desired.description) { [string]$Desired.description } else { $null }
    $payload['domain'] = [string]$DomainByName[[string]$Desired.domain].id
    $payload['dataType'] = if ($Desired.dataType) { [string](ConvertTo-CdeDataTypeFromDesired -Type $Desired.dataType) } else { $null }
    $payload['contacts'] = if ($Desired.owners) { @{ owner = @(ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners) } } else { $null }
    $payload['status'] = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-TermCreatePayload {
    param([object]$Desired, [hashtable]$DomainByName, [hashtable]$TermIdByKey)
    if (-not $DomainByName.ContainsKey([string]$Desired.domain)) {
        throw ("Business domain '{0}' must exist before creating term '{1}'." -f $Desired.domain, $Desired.name)
    }
    $parentId = $null
    if ($Desired.parentTerm) {
        $key = "{0}|{1}" -f $Desired.domain, $Desired.parentTerm
        if (-not $TermIdByKey.ContainsKey($key)) {
            throw ("Parent term '{0}' for term '{1}' is not available yet." -f $Desired.parentTerm, $Desired.name)
        }
        $parentId = [string]$TermIdByKey[$key]
    }
    return (ConvertTo-HashtableSansNull -InputObject @{
            id                = [guid]::NewGuid().Guid
            name              = [string]$Desired.name
            domain            = [string]$DomainByName[[string]$Desired.domain].id
            description       = if ($Desired.description) { [string]$Desired.description } else { $null }
            status            = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
            acronyms          = ConvertTo-StringArrayNormalized -Values $Desired.acronyms
            isLeaf            = [bool]$Desired.isLeaf
            parentId          = $parentId
            contacts          = (ConvertTo-HashtableSansNull -InputObject @{
                    owner         = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners
                    expert        = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.experts
                    databaseAdmin = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.databaseAdmins
                })
            resources         = @($Desired.resources | ForEach-Object { [ordered]@{ name = [string]$_.name; url = [string]$_.url } })
            managedAttributes = @($Desired.managedAttributes | ForEach-Object { [ordered]@{ name = [string]$_.name } })
        })
}

function ConvertTo-TermUpdatePayload {
    param([object]$Desired, [object]$Tenant, [hashtable]$DomainByName, [hashtable]$TermIdByKey)
    $payload = [ordered]@{}
    foreach ($property in $Tenant.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }
    $payload['name'] = [string]$Desired.name
    $payload['domain'] = [string]$DomainByName[[string]$Desired.domain].id
    $payload['description'] = if ($Desired.description) { [string]$Desired.description } else { $null }
    $payload['status'] = [string](ConvertTo-StatusFromDesired -Status $Desired.status)
    $payload['acronyms'] = ConvertTo-StringArrayNormalized -Values $Desired.acronyms
    $payload['isLeaf'] = [bool]$Desired.isLeaf
    if ($Desired.parentTerm) {
        $key = "{0}|{1}" -f $Desired.domain, $Desired.parentTerm
        $payload['parentId'] = [string]$TermIdByKey[$key]
    }
    else {
        $payload['parentId'] = $null
    }
    $payload['contacts'] = (ConvertTo-HashtableSansNull -InputObject @{
            owner         = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.owners
            expert        = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.experts
            databaseAdmin = ConvertTo-ContactPayloadFromDisplayNameList -DisplayNames $Desired.databaseAdmins
        })
    $payload['resources'] = @($Desired.resources | ForEach-Object { [ordered]@{ name = [string]$_.name; url = [string]$_.url } })
    $payload['managedAttributes'] = @($Desired.managedAttributes | ForEach-Object { [ordered]@{ name = [string]$_.name } })
    return (ConvertTo-HashtableSansNull -InputObject $payload)
}

function ConvertTo-BusinessDomainExportEntry {
    param([object]$Tenant)
    $entry = [ordered]@{ name = [string]$Tenant.name }
    if ($Tenant.description) { $entry['description'] = [string]$Tenant.description }
    if ($Tenant.type) { $entry['type'] = [string](ConvertTo-BusinessDomainTypeToDesired -Type $Tenant.type) }
    if ($Tenant.status) { $entry['status'] = [string](ConvertTo-StatusToDesired -Status $Tenant.status) }
    return $entry
}

function ConvertTo-DataProductExportEntry {
    param([object]$Tenant, [hashtable]$DomainById)
    $entry = [ordered]@{ name = [string]$Tenant.name }
    if ($Tenant.description) { $entry['description'] = [string]$Tenant.description }
    if ($Tenant.domain -and $DomainById.ContainsKey([string]$Tenant.domain)) {
        $entry['domain'] = [string]$DomainById[[string]$Tenant.domain].name
    }
    if ($Tenant.type) { $entry['type'] = [string](ConvertTo-DataProductTypeToDesired -Type $Tenant.type) }
    if ($Tenant.businessUse) { $entry['businessUse'] = [string]$Tenant.businessUse }
    $owners = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'owner'
    if ($owners.Count -gt 0) { $entry['owners'] = $owners }
    if ($Tenant.status) { $entry['status'] = [string](ConvertTo-StatusToDesired -Status $Tenant.status) }
    return $entry
}

function ConvertTo-OkrExportEntry {
    param([object]$Tenant, [hashtable]$DomainById)
    $entry = [ordered]@{ name = [string]$Tenant.definition }
    if ($Tenant.domain -and $DomainById.ContainsKey([string]$Tenant.domain)) {
        $entry['domain'] = [string]$DomainById[[string]$Tenant.domain].name
    }
    if ($Tenant.targetDate) {
        $entry['targetDate'] = ([datetime]$Tenant.targetDate).ToString('yyyy-MM-dd')
    }
    $owners = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'owner'
    if ($owners.Count -gt 0) { $entry['owners'] = $owners }
    if ($Tenant.status) { $entry['status'] = [string](ConvertTo-StatusToDesired -Status $Tenant.status) }
    $keyResults = @()
    foreach ($keyResult in @($Tenant.keyResults | Sort-Object definition)) {
        $item = [ordered]@{ name = [string]$keyResult.definition }
        if ($null -ne $keyResult.goal) { $item['target'] = [string]([double]$keyResult.goal) }
        if ($null -ne $keyResult.progress) { $item['currentValue'] = [string]([double]$keyResult.progress) }
        $keyResults += $item
    }
    if ($keyResults.Count -gt 0) { $entry['keyResults'] = $keyResults }
    return $entry
}

function ConvertTo-CriticalDataElementExportEntry {
    param([object]$Tenant, [hashtable]$DomainById)
    $entry = [ordered]@{ name = [string]$Tenant.name }
    if ($Tenant.description) { $entry['description'] = [string]$Tenant.description }
    if ($Tenant.domain -and $DomainById.ContainsKey([string]$Tenant.domain)) {
        $entry['domain'] = [string]$DomainById[[string]$Tenant.domain].name
    }
    if ($Tenant.dataType) { $entry['dataType'] = [string](ConvertTo-CdeDataTypeToDesired -Type $Tenant.dataType) }
    $owners = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'owner'
    if ($owners.Count -gt 0) { $entry['owners'] = $owners }
    if ($Tenant.status) { $entry['status'] = [string](ConvertTo-StatusToDesired -Status $Tenant.status) }
    return $entry
}

function ConvertTo-TermExportEntry {
    param([object]$Tenant, [hashtable]$DomainById, [hashtable]$TermById)
    $entry = [ordered]@{ name = [string]$Tenant.name }
    if ($Tenant.domain -and $DomainById.ContainsKey([string]$Tenant.domain)) {
        $entry['domain'] = [string]$DomainById[[string]$Tenant.domain].name
    }
    if ($Tenant.description) { $entry['description'] = [string]$Tenant.description }
    if ($Tenant.status) { $entry['status'] = [string](ConvertTo-StatusToDesired -Status $Tenant.status) }
    $acronyms = ConvertTo-StringArrayNormalized -Values $Tenant.acronyms
    if ($acronyms.Count -gt 0) { $entry['acronyms'] = $acronyms }
    if ($null -ne $Tenant.isLeaf) { $entry['isLeaf'] = [bool]$Tenant.isLeaf }
    if ($Tenant.parentId -and $TermById.ContainsKey([string]$Tenant.parentId)) {
        $entry['parentTerm'] = [string]$TermById[[string]$Tenant.parentId].name
    }
    $owners = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'owner'
    if ($owners.Count -gt 0) { $entry['owners'] = $owners }
    $experts = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'expert'
    if ($experts.Count -gt 0) { $entry['experts'] = $experts }
    $databaseAdmins = ConvertTo-ContactDisplayNameSetFromPayload -Contacts $Tenant.contacts -Key 'databaseAdmin'
    if ($databaseAdmins.Count -gt 0) { $entry['databaseAdmins'] = $databaseAdmins }
    $resources = @()
    foreach ($resource in @($Tenant.resources | Sort-Object name, url)) {
        $resources += [ordered]@{ name = [string]$resource.name; url = [string]$resource.url }
    }
    if ($resources.Count -gt 0) { $entry['resources'] = $resources }
    $managedAttributes = @()
    foreach ($attribute in @($Tenant.managedAttributes | Sort-Object name)) {
        $managedAttributes += [ordered]@{ name = [string]$attribute.name }
    }
    if ($managedAttributes.Count -gt 0) { $entry['managedAttributes'] = $managedAttributes }
    return $entry
}

function Write-YamlItemsBlock {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries
    )

    $originalLines = Get-Content -LiteralPath $FilePath
    $cutIndex = -1
    for ($i = 0; $i -lt $originalLines.Count; $i++) {
        if ($originalLines[$i] -match '^\s*items\s*:') {
            $cutIndex = $i
            break
        }
    }
    if ($cutIndex -lt 0) {
        throw ("Could not find 'items:' key in '{0}'." -f $FilePath)
    }
    $headerLines = if ($cutIndex -gt 0) { $originalLines[0..($cutIndex - 1)] } else { @() }
    $newBlock = New-Object 'System.Collections.Generic.List[string]'
    if ($Entries.Count -eq 0) {
        $newBlock.Add('items: []') | Out-Null
    }
    else {
        $body = ([ordered]@{ items = @($Entries) }) | ConvertTo-Yaml -Options WithIndentedSequences
        foreach ($line in ($body -split "`n")) { $newBlock.Add($line.TrimEnd()) | Out-Null }
        while ($newBlock.Count -gt 0 -and [string]::IsNullOrEmpty($newBlock[$newBlock.Count - 1])) {
            $newBlock.RemoveAt($newBlock.Count - 1)
        }
    }
    $finalLines = @($headerLines) + $newBlock.ToArray()
    $content = ($finalLines -join "`n") + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($FilePath, $content, $utf8NoBom)
}

function Show-PlanSummary {
    param([object[]]$Report)
    $rows = @($Report | Sort-Object Category, Kind, Name)
    if ($rows.Count -eq 0) {
        Write-Information 'Plan summary: no rows.' -InformationAction Continue
        return
    }
    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $rows | Format-Table Category, Kind, Name, Field, Reason -Wrap | Out-String | Write-Information -InformationAction Continue
}

function Invoke-DirectionPolicyPlan {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Plan,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Report
    )
    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes would have fired.' -InformationAction Continue
        $Plan.Clear()
        return
    }

    $keptPlan = New-Object 'System.Collections.Generic.List[object]'
    $skippedNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Plan.ToArray()) {
        if ($entry.Action -ne 'Update') {
            $keptPlan.Add($entry) | Out-Null
            continue
        }
        $decision = Resolve-DirectionPolicyAction -Policy $DirectionPolicy -SkipList $script:SkipNameList -DisplayName ([string]$entry.Name) -HasDrift $true
        if ($decision.Action -eq 'Skip') {
            $skippedNames.Add([string]$entry.Name) | Out-Null
            $Report.Add((ConvertTo-ReportRow -Category 'Skip' -Kind $entry.Kind -Name ([string]$entry.Name) -Reason $decision.Reason -Fields $entry.Fields)) | Out-Null
            Write-Information ("[ADR0029-SKIP] {0}" -f $entry.Name) -InformationAction Continue
            continue
        }
        if ($entry.Conflict -or $DirectionPolicy -eq 'repo-wins') {
            Write-Warning ("repo-wins overwriting tenant object '{0}' fields: {1}" -f $entry.Name, (@($entry.Fields) -join ','))
        }
        $keptPlan.Add($entry) | Out-Null
    }

    if ($skippedNames.Count -gt 0) {
        $keptReport = @($Report | Where-Object { -not (($_.Category -eq 'Update') -and ($skippedNames -contains [string]$_.Name)) })
        $Report.Clear()
        foreach ($row in $keptReport) { $Report.Add($row) | Out-Null }
    }
    $Plan.Clear()
    foreach ($entry in $keptPlan) { $Plan.Add($entry) | Out-Null }
}

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra\parameters\lab.yaml'
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path
$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}
if (-not $parameters.ContainsKey('purviewAccountName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'purviewAccountName'." -f $ParametersFile)
    return
}
if (-not $AccountName) {
    $AccountName = [string]$parameters.purviewAccountName
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error ("Unified Catalog folder not found: '{0}'." -f $Path)
    return
}
$Path = (Resolve-Path -LiteralPath $Path).Path
$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }
Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $AccountName) -InformationAction Continue
Write-Information ("YAML folder     : {0}" -f $Path) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
Write-Information ("PruneMissing    : {0}" -f $PruneMissing.IsPresent) -InformationAction Continue
Write-Information ("Force           : {0}" -f $Force.IsPresent) -InformationAction Continue

$desiredDocs = @{}
foreach ($concept in $script:UnifiedCatalogConcepts) {
    $yamlPath = Join-Path $Path $concept.Yaml
    $schemaPath = Join-Path $Path $concept.Schema
    $desiredDocs[$concept.Kind] = @(Get-DesiredItem -YamlPath $yamlPath -SchemaPath $schemaPath)
}

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    foreach ($concept in $script:UnifiedCatalogConcepts) {
        Write-Information ("  Export {0} -> {1}" -f $concept.Kind, $concept.Yaml) -InformationAction Continue
    }
    return
}

$context = $null
try {
    $context = Get-UnifiedCatalogApiContext -AccountName $AccountName
}
catch {
    if ($WhatIfPreference -and $mode -eq 'Apply') {
        Write-Warning ("Could not reach the live Unified Catalog API in this environment: {0}" -f $_.Exception.Message)
        return ,@()
    }
    throw
}

$tenantState = $null
try {
    $tenantState = Get-UnifiedCatalogTenantState -Context $context
}
catch {
    if ($WhatIfPreference -and $mode -eq 'Apply') {
        Write-Warning ("Could not read live Unified Catalog state in this environment: {0}" -f $_.Exception.Message)
        return ,@()
    }
    throw
}

if ($mode -eq 'Export') {
    foreach ($concept in $script:UnifiedCatalogConcepts) {
        $existingCount = @($desiredDocs[$concept.Kind]).Count
        if ($existingCount -gt 0 -and -not $Force.IsPresent) {
            throw ("'{0}' already declares {1} item(s). Re-run with -Force to overwrite." -f $concept.Yaml, $existingCount)
        }
    }

    $domainEntries = @($tenantState.Domains | Sort-Object name | ForEach-Object { ConvertTo-BusinessDomainExportEntry -Tenant $_ })
    $dataProductEntries = @($tenantState.DataProducts | Sort-Object name | ForEach-Object { ConvertTo-DataProductExportEntry -Tenant $_ -DomainById $tenantState.DomainById })
    $okrEntries = @($tenantState.Objectives | Sort-Object definition | ForEach-Object { ConvertTo-OkrExportEntry -Tenant $_ -DomainById $tenantState.DomainById })
    $cdeEntries = @($tenantState.CriticalDataElements | Sort-Object name | ForEach-Object { ConvertTo-CriticalDataElementExportEntry -Tenant $_ -DomainById $tenantState.DomainById })
    $termEntries = @($tenantState.Terms | Sort-Object name | ForEach-Object { ConvertTo-TermExportEntry -Tenant $_ -DomainById $tenantState.DomainById -TermById $tenantState.TermById })

    $exportMap = @{
        'business-domains.yaml'      = $domainEntries
        'data-products.yaml'         = $dataProductEntries
        'okrs.yaml'                  = $okrEntries
        'critical-data-elements.yaml' = $cdeEntries
        'glossary-terms.yaml'        = $termEntries
    }

    foreach ($fileName in $exportMap.Keys) {
        $fullPath = Join-Path $Path $fileName
        $shouldProcessTarget = "YAML file '$fileName'"
        $shouldProcessAction = "Replace 'items:' block with $(@($exportMap[$fileName]).Count) item(s)"
        if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
            Write-YamlItemsBlock -FilePath $fullPath -Entries @($exportMap[$fileName])
        }
    }
    return
}

$report = New-Object 'System.Collections.Generic.List[object]'
$plan = New-Object 'System.Collections.Generic.List[object]'
$orphans = New-Object 'System.Collections.Generic.List[object]'
$blockedRows = New-Object 'System.Collections.Generic.List[object]'

$domainPlan = Get-ReconciliationPlan -Kind 'BusinessDomain' -DesiredItems @($desiredDocs.BusinessDomain) -TenantItems @($tenantState.Domains) -DesiredComparable { param($item) ConvertTo-BusinessDomainComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-BusinessDomainComparableTenant -Item $item } -DesiredKeySelector { param($item) [string]$item.name } -TenantKeySelector { param($item) [string]$item.name } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $domainPlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $domainPlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $domainPlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'BusinessDomain'; Item = $orphan }) | Out-Null }

$domainAvailability = @{}
foreach ($tenant in $tenantState.Domains) { $domainAvailability[[string]$tenant.name] = [string]$tenant.id }
foreach ($entry in @($domainPlan.Plan | Where-Object Action -eq 'Create')) { $domainAvailability[[string]$entry.Desired.name] = '00000000-0000-0000-0000-000000000000' }

foreach ($desired in @($desiredDocs.DataProduct)) {
    if (-not $domainAvailability.ContainsKey([string]$desired.domain)) {
        $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'DataProduct' -Name ([string]$desired.name) -Reason ("Missing business domain '{0}'." -f $desired.domain))) | Out-Null
    }
}
foreach ($desired in @($desiredDocs.Okr)) {
    if (-not $domainAvailability.ContainsKey([string]$desired.domain)) {
        $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'Okr' -Name ([string]$desired.name) -Reason ("Missing business domain '{0}'." -f $desired.domain))) | Out-Null
    }
}
foreach ($desired in @($desiredDocs.CriticalDataElement)) {
    if (-not $domainAvailability.ContainsKey([string]$desired.domain)) {
        $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'CriticalDataElement' -Name ([string]$desired.name) -Reason ("Missing business domain '{0}'." -f $desired.domain))) | Out-Null
    }
}
foreach ($desired in @($desiredDocs.Term)) {
    if (-not $domainAvailability.ContainsKey([string]$desired.domain)) {
        $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'Term' -Name ([string]$desired.name) -Reason ("Missing business domain '{0}'." -f $desired.domain))) | Out-Null
    }
}

$dataProductPlan = Get-ReconciliationPlan -Kind 'DataProduct' -DesiredItems @($desiredDocs.DataProduct) -TenantItems @($tenantState.DataProducts) -DesiredComparable { param($item) ConvertTo-DataProductComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-DataProductComparableTenant -Item $item -DomainById $tenantState.DomainById } -DesiredKeySelector { param($item) [string]$item.name } -TenantKeySelector { param($item) [string]$item.name } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $dataProductPlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $dataProductPlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $dataProductPlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'DataProduct'; Item = $orphan }) | Out-Null }

$okrPlan = Get-ReconciliationPlan -Kind 'Okr' -DesiredItems @($desiredDocs.Okr) -TenantItems @($tenantState.Objectives) -DesiredComparable { param($item) ConvertTo-OkrComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-OkrComparableTenant -Item $item -DomainById $tenantState.DomainById } -DesiredKeySelector { param($item) [string]$item.name } -TenantKeySelector { param($item) [string]$item.definition } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $okrPlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $okrPlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $okrPlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'Okr'; Item = $orphan }) | Out-Null }

$keyResultDesired = @()
foreach ($desiredObjective in @($desiredDocs.Okr)) {
    foreach ($keyResult in @($desiredObjective.keyResults)) {
        $copy = [pscustomobject]@{
            __objectiveName = [string]$desiredObjective.name
            __domainName    = [string]$desiredObjective.domain
            name            = [string]$keyResult.name
            target          = $keyResult.target
            currentValue    = $keyResult.currentValue
        }
        $keyResultDesired += $copy
        if ($null -eq (Resolve-DesiredNumericValue -Value $keyResult.target) -and -not [string]::IsNullOrWhiteSpace([string]$keyResult.target)) {
            $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'OkrKeyResult' -Name ("{0}/{1}" -f $desiredObjective.name, $keyResult.name) -Reason 'target must be numeric for the preview API key-result model.')) | Out-Null
        }
        if ($null -eq (Resolve-DesiredNumericValue -Value $keyResult.currentValue) -and -not [string]::IsNullOrWhiteSpace([string]$keyResult.currentValue)) {
            $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'OkrKeyResult' -Name ("{0}/{1}" -f $desiredObjective.name, $keyResult.name) -Reason 'currentValue must be numeric for the preview API key-result model.')) | Out-Null
        }
    }
}
$keyResultTenant = @()
foreach ($objective in @($tenantState.Objectives)) {
    foreach ($keyResult in @($objective.keyResults)) { $keyResultTenant += $keyResult }
}
$keyResultPlan = Get-ReconciliationPlan -Kind 'OkrKeyResult' -DesiredItems $keyResultDesired -TenantItems $keyResultTenant -DesiredComparable { param($item) ConvertTo-KeyResultComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-KeyResultComparableTenant -Item $item } -DesiredKeySelector { param($item) "{0}|{1}" -f $item.__objectiveName, $item.name } -TenantKeySelector { param($item) "{0}|{1}" -f $item.__objectiveName, $item.definition } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $keyResultPlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $keyResultPlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $keyResultPlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'OkrKeyResult'; Item = $orphan }) | Out-Null }

$cdePlan = Get-ReconciliationPlan -Kind 'CriticalDataElement' -DesiredItems @($desiredDocs.CriticalDataElement) -TenantItems @($tenantState.CriticalDataElements) -DesiredComparable { param($item) ConvertTo-CriticalDataElementComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-CriticalDataElementComparableTenant -Item $item -DomainById $tenantState.DomainById } -DesiredKeySelector { param($item) [string]$item.name } -TenantKeySelector { param($item) [string]$item.name } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $cdePlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $cdePlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $cdePlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'CriticalDataElement'; Item = $orphan }) | Out-Null }

$termDesiredByKey = @{}
foreach ($term in @($desiredDocs.Term)) { $termDesiredByKey[("{0}|{1}" -f $term.domain, $term.name)] = $term }
foreach ($term in @($desiredDocs.Term)) {
    if ($term.parentTerm) {
        $parentKey = "{0}|{1}" -f $term.domain, $term.parentTerm
        if (-not $termDesiredByKey.ContainsKey($parentKey) -and -not (@($tenantState.Terms | Where-Object { $_.name -eq $term.parentTerm }).Count -gt 0)) {
            $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'Term' -Name ([string]$term.name) -Reason ("Parent term '{0}' is missing." -f $term.parentTerm))) | Out-Null
        }
    }
}
$termPlan = Get-ReconciliationPlan -Kind 'Term' -DesiredItems @($desiredDocs.Term) -TenantItems @($tenantState.Terms) -DesiredComparable { param($item) ConvertTo-TermComparableDesired -Item $item } -TenantComparable { param($item) ConvertTo-TermComparableTenant -Item $item -DomainById $tenantState.DomainById -TermById $tenantState.TermById } -DesiredKeySelector { param($item) "{0}|{1}" -f $item.domain, $item.name } -TenantKeySelector { param($item) if ($tenantState.DomainById.ContainsKey([string]$item.domain)) { "{0}|{1}" -f $tenantState.DomainById[[string]$item.domain].name, $item.name } else { $item.name } } -AllowConflictOverwrite:$Force.IsPresent
foreach ($row in $termPlan.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $termPlan.Plan) { $plan.Add($entry) | Out-Null }
foreach ($orphan in $termPlan.Orphans) { $orphans.Add([pscustomobject]@{ Kind = 'Term'; Item = $orphan }) | Out-Null }

Invoke-DirectionPolicyPlan -Plan $plan -Report $report
foreach ($blocked in $blockedRows) { $report.Add($blocked) | Out-Null }
Show-PlanSummary -Report $report.ToArray()

if ($blockedRows.Count -gt 0) {
    throw ("Reconciliation aborted: {0} blocked item(s)." -f $blockedRows.Count)
}

$createdDomainIds = @{}
$effectiveDomainByName = @{}
foreach ($domain in $tenantState.Domains) { $effectiveDomainByName[[string]$domain.name] = $domain }
$termIdByKey = @{}
foreach ($term in $tenantState.Terms) {
    if ($tenantState.DomainById.ContainsKey([string]$term.domain)) {
        $termIdByKey[("{0}|{1}" -f $tenantState.DomainById[[string]$term.domain].name, $term.name)] = [string]$term.id
    }
}
$objectiveIdByName = @{}
foreach ($objective in $tenantState.Objectives) { $objectiveIdByName[[string]$objective.definition] = [string]$objective.id }

$writeOrder = @('BusinessDomain', 'DataProduct', 'Okr', 'OkrKeyResult', 'CriticalDataElement', 'Term')
foreach ($kind in $writeOrder) {
    foreach ($entry in @($plan | Where-Object { $_.Kind -eq $kind })) {
        switch ($entry.Kind) {
            'BusinessDomain' {
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-BusinessDomainCreatePayload -Desired $entry.Desired
                    $target = "Business domain '$($entry.Desired.name)'"
                    $action = 'Create business domain'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        $created = Invoke-UCBusinessDomainCreate -Context $context -Payload $payload
                        $createdDomainIds[[string]$entry.Desired.name] = [string]$created.id
                        $effectiveDomainByName[[string]$entry.Desired.name] = $created
                    }
                    else {
                        $createdDomainIds[[string]$entry.Desired.name] = '00000000-0000-0000-0000-000000000000'
                        $effectiveDomainByName[[string]$entry.Desired.name] = [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000000'; name = [string]$entry.Desired.name }
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-BusinessDomainUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant
                    $target = "Business domain '$($entry.Desired.name)'"
                    $action = 'Update business domain'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        $updated = Invoke-UCBusinessDomainUpdate -Context $context -DomainId ([string]$entry.Tenant.id) -Payload $payload
                        $effectiveDomainByName[[string]$entry.Desired.name] = $updated
                    }
                }
            }
            'DataProduct' {
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-DataProductCreatePayload -Desired $entry.Desired -DomainByName $effectiveDomainByName
                    $target = "Data product '$($entry.Desired.name)'"
                    $action = 'Create data product'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCDataProductCreate -Context $context -Payload $payload)
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-DataProductUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant -DomainByName $effectiveDomainByName
                    $target = "Data product '$($entry.Desired.name)'"
                    $action = 'Update data product'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCDataProductUpdate -Context $context -DataProductId ([string]$entry.Tenant.id) -Payload $payload)
                    }
                }
            }
            'Okr' {
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-ObjectiveCreatePayload -Desired $entry.Desired -DomainByName $effectiveDomainByName
                    $target = "Objective '$($entry.Desired.name)'"
                    $action = 'Create objective'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        $created = Invoke-UCObjectiveCreate -Context $context -Payload $payload
                        $objectiveIdByName[[string]$entry.Desired.name] = [string]$created.id
                    }
                    else {
                        $objectiveIdByName[[string]$entry.Desired.name] = '00000000-0000-0000-0000-000000000000'
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-ObjectiveUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant -DomainByName $effectiveDomainByName
                    $target = "Objective '$($entry.Desired.name)'"
                    $action = 'Update objective'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCObjectiveUpdate -Context $context -ObjectiveId ([string]$entry.Tenant.id) -Payload $payload)
                    }
                    $objectiveIdByName[[string]$entry.Desired.name] = [string]$entry.Tenant.id
                }
            }
            'OkrKeyResult' {
                $objectiveId = $null
                if ($objectiveIdByName.ContainsKey([string]$entry.Desired.__objectiveName)) {
                    $objectiveId = [string]$objectiveIdByName[[string]$entry.Desired.__objectiveName]
                }
                elseif ($entry.Tenant) {
                    $objectiveId = [string]$entry.Tenant.__objectiveId
                }
                $domainId = if ($effectiveDomainByName.ContainsKey([string]$entry.Desired.__domainName)) { [string]$effectiveDomainByName[[string]$entry.Desired.__domainName].id } else { '00000000-0000-0000-0000-000000000000' }
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-KeyResultCreatePayload -Desired $entry.Desired -DomainId $domainId
                    $target = "Key result '$($entry.Name)'"
                    $action = 'Create key result'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCKeyResultCreate -Context $context -ObjectiveId $objectiveId -Payload $payload)
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-KeyResultUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant -DomainId $domainId
                    $target = "Key result '$($entry.Name)'"
                    $action = 'Update key result'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCKeyResultUpdate -Context $context -ObjectiveId $objectiveId -KeyResultId ([string]$entry.Tenant.id) -Payload $payload)
                    }
                }
            }
            'CriticalDataElement' {
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-CriticalDataElementCreatePayload -Desired $entry.Desired -DomainByName $effectiveDomainByName
                    $target = "Critical data element '$($entry.Desired.name)'"
                    $action = 'Create critical data element'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCCriticalDataElementCreate -Context $context -Payload $payload)
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-CriticalDataElementUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant -DomainByName $effectiveDomainByName
                    $target = "Critical data element '$($entry.Desired.name)'"
                    $action = 'Update critical data element'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCCriticalDataElementUpdate -Context $context -CriticalDataElementId ([string]$entry.Tenant.id) -Payload $payload)
                    }
                }
            }
            'Term' {
                if ($entry.Action -eq 'Create') {
                    $payload = ConvertTo-TermCreatePayload -Desired $entry.Desired -DomainByName $effectiveDomainByName -TermIdByKey $termIdByKey
                    $target = "Term '$($entry.Desired.name)'"
                    $action = 'Create term'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        $created = Invoke-UCTermCreate -Context $context -Payload $payload
                        $termIdByKey[("{0}|{1}" -f $entry.Desired.domain, $entry.Desired.name)] = [string]$created.id
                    }
                    else {
                        $termIdByKey[("{0}|{1}" -f $entry.Desired.domain, $entry.Desired.name)] = '00000000-0000-0000-0000-000000000000'
                    }
                }
                elseif ($entry.Action -eq 'Update') {
                    $payload = ConvertTo-TermUpdatePayload -Desired $entry.Desired -Tenant $entry.Tenant -DomainByName $effectiveDomainByName -TermIdByKey $termIdByKey
                    $target = "Term '$($entry.Desired.name)'"
                    $action = 'Update term'
                    if ($PSCmdlet.ShouldProcess($target, $action)) {
                        [void](Invoke-UCTermUpdate -Context $context -TermId ([string]$entry.Tenant.id) -Payload $payload)
                    }
                    $termIdByKey[("{0}|{1}" -f $entry.Desired.domain, $entry.Desired.name)] = [string]$entry.Tenant.id
                }
            }
        }
    }
}

if ($PruneMissing.IsPresent) {
    foreach ($entry in $orphans.ToArray()) {
        switch ($entry.Kind) {
            'OkrKeyResult' {
                $target = "Key result '$($entry.Item.__objectiveName)/$($entry.Item.definition)'"
                $action = 'Remove orphan key result'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCKeyResultDelete -Context $context -ObjectiveId ([string]$entry.Item.__objectiveId) -KeyResultId ([string]$entry.Item.id))
                }
            }
            'Term' {
                $target = "Term '$($entry.Item.name)'"
                $action = 'Remove orphan term'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCTermDelete -Context $context -TermId ([string]$entry.Item.id))
                }
            }
            'CriticalDataElement' {
                $target = "Critical data element '$($entry.Item.name)'"
                $action = 'Remove orphan critical data element'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCCriticalDataElementDelete -Context $context -CriticalDataElementId ([string]$entry.Item.id))
                }
            }
            'Okr' {
                $target = "Objective '$($entry.Item.definition)'"
                $action = 'Remove orphan objective'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCObjectiveDelete -Context $context -ObjectiveId ([string]$entry.Item.id))
                }
            }
            'DataProduct' {
                $target = "Data product '$($entry.Item.name)'"
                $action = 'Remove orphan data product'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCDataProductDelete -Context $context -DataProductId ([string]$entry.Item.id))
                }
            }
            'BusinessDomain' {
                $target = "Business domain '$($entry.Item.name)'"
                $action = 'Remove orphan business domain'
                if ($PSCmdlet.ShouldProcess($target, $action)) {
                    [void](Invoke-UCBusinessDomainDelete -Context $context -DomainId ([string]$entry.Item.id))
                }
            }
        }
    }
}

return @($report | Sort-Object Category, Kind, Name)


