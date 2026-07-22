#Requires -Version 7.4
<#
.SYNOPSIS
    Reconcile Microsoft Purview Unified Catalog data access policies.

.DESCRIPTION
    Reconciles the simplified desired-state projection in
    data-plane/unified-catalog/data-access-policies.yaml against the preview
    Unified Catalog Policies REST API adopted by ADR 0047 item 9/10(c).

    The Policies operation group exposes built-in policy objects that are
    updated in place. The reconciler therefore plans and applies grant/revoke
    changes at the role-assignment row level, then materializes each policy's
    full decisionRules / attributeRules document for PUT.

    Security-sensitive behavior:
      * Every grant/revoke change is treated as destructive-equivalent.
      * The per-row diff is always printed before any write.
      * -Force suppresses interactive confirmation, never diff visibility.
      * -Force does NOT authorize overwriting a foreign-authored policy
        assignment. That is -OverwriteForeignAuthor (ADR 0053).
      * -PruneMissing is off by default and only enables explicit revokes.

    References:
      Unified Catalog auth for Purview data plane:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      Policies - List:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
      Policies - Update:
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
      Microsoft Graph directoryObject getByIds:
        https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids?view=graph-rest-1.0
      Test-Json:
        https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json
      Everything about ShouldProcess:
        https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess
      ADR 0012:
        docs/adr/0012-environment-parameters-file.md
      ADR 0023:
        docs/adr/0023-identifier-resolution.md
      ADR 0047:
        docs/adr/0047-unified-catalog-preview-api-coexistence.md
      ADR 0053:
        docs/adr/0053-overwrite-foreign-author-switch.md

.PARAMETER PruneMissing
    Revoke tenant Unified Catalog role assignments (principals) that are not
    declared in the YAML. A revoke is folded into the per-policy PUT that
    rewrites that policy's assignment set. Default `$false`.

    Two issue #13 guards stand in front of this switch, both implemented in
    `scripts/modules/PruneGuard.psm1`:

      * The desired-state set must be non-empty. A prune against an empty
        desired set would classify every live assignment as orphaned and
        revoke it.
      * The prune must not exceed `-MaxPruneRatio` of the live role
        assignments without `-AllowMajorityPrune`. The denominator is the
        full live assignment set. Under `-DirectionPolicy audit` the plan is
        emptied upstream, so there is no revoke to ratio-check and the guard
        passes trivially.

    Both refuse before the tenant is written to.

.PARAMETER AllowMajorityPrune
    Override for the issue #13 prune sanity-ratio guard. Without it, a
    `-PruneMissing` plan that would revoke more than `-MaxPruneRatio` of the
    live role assignments is refused before any write. Supply it when a large
    prune is genuinely intended (a deliberate consolidation); the ratio is
    then reported as a warning and the run proceeds. Has no effect on the
    empty-desired-set guard, which cannot be overridden.

.PARAMETER MaxPruneRatio
    Largest share of the live Unified Catalog role assignments `-PruneMissing`
    may revoke without `-AllowMajorityPrune`, as a fraction in (0, 1].
    Default 0.5. A prune exactly at the threshold passes; only a strictly
    larger share is refused. Set to 1 to disable the ratio guard for a single
    run.

.PARAMETER Force
    Suppress the safety guard on the operation you asked for. In the
    Export parameter set that guard is `-ExportCurrentState`'s refusal to
    clobber a non-empty managed block in the target YAML. In the Apply
    parameter set it is the ADR 0052 destructive-operation confirmation
    prompt.
    `-Force` does NOT authorize overwriting a foreign-authored tenant
    object -- that meaning was split out to `-OverwriteForeignAuthor` by
    ADR 0053. Reference: docs/adr/0053-overwrite-foreign-author-switch.md.

.PARAMETER OverwriteForeignAuthor
    Apply parameter set only. Permit `Update` writes against tenant policy
    assignments whose `LastModifiedBy` differs from the current deploy
    principal. Without it, such an assignment is reported as a `Conflict`
    row and left untouched.
    The `Conflict` row is emitted either way -- this switch authorizes the
    overwrite, it does not hide the finding. Default `$false`.
    Reference: docs/adr/0053-overwrite-foreign-author-switch.md.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Export')]
    [ValidateNotNullOrEmpty()]
    [string]$Path = (Join-Path $PSScriptRoot '..\data-plane\unified-catalog'),

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

# ADR 0053: the `if ($Force.IsPresent) { $ConfirmPreference = 'None' }` ambient
# self-disarm that used to sit here is DELETED. ADR 0052 line 89 requires that
# the destructive-operation gate "cannot be defeated by a caller who sets
# $ConfirmPreference = 'None'" -- a script that does it to itself is the same
# defeat, self-inflicted. This script is the ONE reconciler already at
# ConfirmImpact = 'High', so this line was precisely what had been neutering
# the only script that looked correct: its per-write ShouldProcess calls are
# now live under -Force. CI callers bind -Confirm:$false, which is the
# explicit, greppable consent signal ADR 0052 section 7 mandates.

#region Module dependencies
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\ConfirmGate.psm1') -Force -Scope Local -ErrorAction Stop
# In-repo -PruneMissing safety guard (issue #13): the empty-desired-set refusal,
# which prevents a prune against a zero-entry desired state from classifying
# every live tenant object as an orphan. Shared with the other Deploy-*.ps1
# reconcilers that implement -PruneMissing.
Import-Module (Join-Path $PSScriptRoot 'modules\PruneGuard.psm1') -Force -Scope Local -ErrorAction Stop
#endregion

$script:UnifiedCatalogApiVersion = '2026-03-20-preview'
$script:UnifiedCatalogEndpoint = 'https://api.purview-service.microsoft.com'
$script:ResolvePrincipalScript = Join-Path $PSScriptRoot 'Get-EntraPrincipalIdByDisplayName.ps1'
$script:DisplayNameByObjectId = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$script:PrincipalIdByDisplayName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
$script:CurrentPrincipalIds = @()
$script:ManagedRoleCatalog = @(
    [ordered]@{ FriendlyName = 'Governance Domain Owner'; RoleSlug = 'business-domain-owner'; Family = 'BusinessDomain'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Governance Domain Reader'; RoleSlug = 'business-domain-reader'; Family = 'BusinessDomain'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Product Owner'; RoleSlug = 'data-product-owner'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Steward'; RoleSlug = 'data-steward'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Quality Reader'; RoleSlug = 'data-quality-reader'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Quality Metadata Reader'; RoleSlug = 'data-quality-metadata-reader'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Profile Steward'; RoleSlug = 'data-profile-steward'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Profile Reader'; RoleSlug = 'data-profile-reader'; Family = 'DGDataQualityScope'; ScopeRequired = $true },
    [ordered]@{ FriendlyName = 'Data Governance Administrator'; RoleSlug = 'datagovernance-administrator'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
    [ordered]@{ FriendlyName = 'Data Health Reader'; RoleSlug = 'data-health-reader'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
    [ordered]@{ FriendlyName = 'Data Health Owner'; RoleSlug = 'data-health-owner'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
    [ordered]@{ FriendlyName = 'Governance Domain Creator'; RoleSlug = 'business-domain-creator'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
    [ordered]@{ FriendlyName = 'Global Asset Curator'; RoleSlug = 'governance-asset-curator'; Family = 'DataGovernanceApp'; ScopeRequired = $false },
    [ordered]@{ FriendlyName = 'Global Catalog Reader'; RoleSlug = 'global-catalog-reader'; Family = 'DataGovernanceApp'; ScopeRequired = $false }
)

function Get-OrdinalDictionary {
    [CmdletBinding()]
    param()
    return [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
}

function Get-RoleMetadataMap {
    if (-not $script:RoleMetadataMap) {
        $map = Get-OrdinalDictionary
        foreach ($entry in $script:ManagedRoleCatalog) {
            $map[[string]$entry.FriendlyName] = [pscustomobject]$entry
        }
        $script:RoleMetadataMap = $map
    }
    return $script:RoleMetadataMap
}

function Get-ManagedRolesForFamily {
    param([Parameter(Mandatory = $true)][string]$Family)
    return @($script:ManagedRoleCatalog | Where-Object { $_.Family -eq $Family })
}

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

function Get-AssignmentDisplayName {
    param(
        [string]$RoleName,
        [string]$ScopeLabel
    )
    if ([string]::IsNullOrWhiteSpace($ScopeLabel)) {
        return ("Global / {0}" -f $RoleName)
    }
    return ("{0} / {1}" -f $ScopeLabel, $RoleName)
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

    $null = & $connectScript -AccountName $AccountName

    # api-version justification: the Unified Catalog preview endpoints implemented
    # by this reconciler are documented under the 2026-03-20-preview Learn view and
    # ADR 0047 explicitly authorizes that preview contract for issue #47.
    # Reference: https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
    $raw = az account get-access-token --resource https://purview.azure.net --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire the Purview data-plane token. Run 'az login' or configure OIDC."
    }
    $tokenResponse = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.accessToken)) {
        throw 'az account get-access-token returned no accessToken field for the Purview data-plane audience.'
    }
    $claims = ConvertFrom-JwtPayload -Token $tokenResponse.accessToken

    $principalIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($claims.oid, $claims.appid, $claims.sub)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $principalIds.Add([string]$candidate) | Out-Null
        }
    }
    $script:CurrentPrincipalIds = @($principalIds | Sort-Object -Unique)

    return [pscustomobject]@{
        Endpoint    = $script:UnifiedCatalogEndpoint
        BearerToken = [string]$tokenResponse.accessToken
        Headers     = @{ Authorization = "Bearer $($tokenResponse.accessToken)"; 'Content-Type' = 'application/json' }
        Claims      = $claims
    }
}

function Invoke-UnifiedCatalogRestMethod {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [object]$Body
    )

    if ($PSBoundParameters.ContainsKey('Body')) {
        $json = $Body | ConvertTo-Json -Depth 100
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
    if ($Response.skipToken) { return "$BaseUri&skipToken=$([uri]::EscapeDataString([string]$Response.skipToken))" }
    if ($Response.'$skipToken') { return "$BaseUri&`$skipToken=$([uri]::EscapeDataString([string]$Response.'$skipToken'))" }
    return $null
}

function Get-UnifiedCatalogBusinessDomainSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = @()
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/businessdomains?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Business Domain - Enumerate documents the businessdomains
        # list endpoint for 2026-03-20-preview.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items += ,$item }
        foreach ($item in @($response.values)) { $items += ,$item }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return @($items)
}

function Get-UnifiedCatalogDataProductSet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = @()
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/dataProducts?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: ADR 0047 adopts the preview Unified Catalog
        # contract and Data Products - List documents the dataproducts endpoint
        # for 2026-03-20-preview.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/data-products/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.value)) { $items += ,$item }
        foreach ($item in @($response.values)) { $items += ,$item }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return @($items)
}

function Get-UnifiedCatalogPolicySet {
    param([Parameter(Mandatory = $true)][object]$Context)
    $items = @()
    $baseUri = "$($Context.Endpoint)/datagovernance/catalog/policies?api-version=$($script:UnifiedCatalogApiVersion)"
    $uri = $baseUri
    do {
        # api-version justification: the Policies operation group is preview-only
        # as of issue #47 and Policies - List documents the pinned 2026-03-20-preview
        # list endpoint.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/list?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        $response = Invoke-UnifiedCatalogRestMethod -Method GET -Uri $uri -Headers $Context.Headers
        foreach ($item in @($response.values)) { $items += ,$item }
        foreach ($item in @($response.value)) { $items += ,$item }
        $uri = Get-PagedContinuationUri -Response $response -BaseUri $baseUri
    } while ($uri)
    return @($items)
}

function Resolve-PrincipalIdByDisplayName {
    # NOTE: this reconciler resolves every principal as an Entra Group
    # (Get-EntraPrincipalIdByDisplayName.ps1 default Kind = 'Group'), and
    # ConvertTo-PolicyUpdatePayload's default 'principal.microsoft.groups'
    # attribute name for new grants assumes the same. data-access-policies
    # .schema.json's "group or user" wording is therefore aspirational for
    # `principals` today; a user-named principal will fail resolution with
    # a "No Group found" error rather than succeeding as a user. Threading
    # a per-principal Kind through resolution AND the attribute-rule
    # builder (User needs 'principal.microsoft.id', not '.groups') is
    # tracked as follow-up scope, not fixed in this pass.
    param([Parameter(Mandatory = $true)][string]$DisplayName)
    if ($script:PrincipalIdByDisplayName.ContainsKey($DisplayName)) {
        return [string]$script:PrincipalIdByDisplayName[$DisplayName]
    }
    $resolved = & $script:ResolvePrincipalScript -DisplayName $DisplayName
    $script:PrincipalIdByDisplayName[$DisplayName] = [string]$resolved
    return [string]$resolved
}

function Resolve-DisplayNameMapByObjectId {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ObjectIds)

    $pending = @($ObjectIds | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and -not $script:DisplayNameByObjectId.ContainsKey([string]$_)
        } | Sort-Object -Unique)
    if ($pending.Count -eq 0) {
        return $script:DisplayNameByObjectId
    }

    $graphTokenRaw = az account get-access-token --resource-type ms-graph --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to acquire a Microsoft Graph token for reverse-resolving policy principals.'
    }
    $graphToken = $graphTokenRaw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$graphToken.accessToken)) {
        throw 'az account get-access-token returned no accessToken field for Microsoft Graph.'
    }
    $graphHeaders = @{ Authorization = "Bearer $($graphToken.accessToken)"; 'Content-Type' = 'application/json' }

    for ($offset = 0; $offset -lt $pending.Count; $offset += 1000) {
        $batch = @($pending[$offset..([Math]::Min($pending.Count - 1, $offset + 999))])
        if ($batch.Count -eq 0) {
            continue
        }
        $body = @{ ids = @($batch) } | ConvertTo-Json -Depth 10
        # api-version justification: -ExportCurrentState must reverse-resolve Entra object
        # IDs back to human-readable display names, and Microsoft Graph directoryObject
        # getByIds is the documented batch lookup endpoint for persisted IDs.
        # Reference: https://learn.microsoft.com/en-us/graph/api/directoryobject-getbyids?view=graph-rest-1.0
        $response = Invoke-RestMethod -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' -Headers $graphHeaders -Body $body -ErrorAction Stop
        foreach ($item in @($response.value)) {
            $displayName = [string]$item.displayName
            if ([string]::IsNullOrWhiteSpace($displayName) -and $item.additionalProperties.displayName) {
                $displayName = [string]$item.additionalProperties.displayName
            }
            if ([string]::IsNullOrWhiteSpace($displayName) -and $item.appDisplayName) {
                $displayName = [string]$item.appDisplayName
            }
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                throw 'Microsoft Graph getByIds returned a directory object without a usable displayName/appDisplayName.'
            }
            $script:DisplayNameByObjectId[[string]$item.id] = $displayName
        }
    }

    foreach ($id in $pending) {
        if (-not $script:DisplayNameByObjectId.ContainsKey([string]$id)) {
            throw 'Microsoft Graph getByIds did not return every requested object ID for policy export.'
        }
    }
    return $script:DisplayNameByObjectId
}

function Get-PolicyFamilyFromEntityType {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$EntityType)
    switch ($EntityType) {
        'BusinessDomainReference' { return 'BusinessDomain' }
        'DGDataQualityScopeReference' { return 'DGDataQualityScope' }
        'DataGovernanceAppReference' { return 'DataGovernanceApp' }
        default { return $null }
    }
}

function Get-ManagedRoleRuleName {
    param([Parameter(Mandatory = $true)][string]$RoleSlug)
    return ("purviewdatagovernancerole_builtin_{0}" -f $RoleSlug)
}

function Get-ManagedRoleRuleId {
    param(
        [Parameter(Mandatory = $true)][string]$RoleSlug,
        [Parameter(Mandatory = $true)][string]$ScopeId
    )
    return ("{0}:{1}" -f (Get-ManagedRoleRuleName -RoleSlug $RoleSlug), $ScopeId)
}

function Get-ManagedPermissionRuleId {
    param(
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$ScopeId
    )
    switch ($Family) {
        'BusinessDomain' { return ("permission_dg:businessdomain_{0}" -f $ScopeId) }
        'DGDataQualityScope' { return ("permission_dg:dgdataqualityscope_{0}" -f $ScopeId) }
        'DataGovernanceApp' { return ("permission_dg:datagovernanceapp_{0}" -f $ScopeId) }
        default { throw ("Unsupported policy family '{0}'." -f $Family) }
    }
}

function Get-PrincipalIdsFromAttributeRule {
    param([object]$AttributeRule)
    if ($null -eq $AttributeRule) {
        return @()
    }
    $ids = @()
    foreach ($clause in @($AttributeRule.dnfCondition)) {
        foreach ($condition in @($clause)) {
            if ($condition.attributeName -in @('principal.microsoft.id', 'principal.microsoft.groups')) {
                foreach ($value in @($condition.attributeValueIncludedIn)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                        $ids += [string]$value
                    }
                }
            }
        }
    }
    return @($ids | Sort-Object -Unique)
}

function Get-PrincipalAttributeNameFromRule {
    param([object]$AttributeRule)
    foreach ($clause in @($AttributeRule.dnfCondition)) {
        foreach ($condition in @($clause)) {
            if ($condition.attributeName -in @('principal.microsoft.id', 'principal.microsoft.groups')) {
                return [string]$condition.attributeName
            }
        }
    }
    return 'principal.microsoft.id'
}

function Get-PolicyScopeLabel {
    param(
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][object]$TenantState
    )

    $family = Get-PolicyFamilyFromEntityType -EntityType ([string]$Policy.properties.entity.type)
    $scopeId = [string]$Policy.properties.entity.referenceName
    switch ($family) {
        'BusinessDomain' {
            if (-not $TenantState.DomainById.ContainsKey($scopeId)) {
                throw 'A business-domain policy referenced a scope ID that does not resolve to a live business domain name.'
            }
            return [string]$TenantState.DomainById[$scopeId].name
        }
        'DataGovernanceApp' {
            return $null
        }
        'DGDataQualityScope' {
            # TODO: not-on-Learn. The Policies List/Update pages expose
            # DGDataQualityScopeReference only as opaque IDs. The repo's simplified
            # projection needs a human-readable scope label, so we resolve the scope
            # ID against live Data Product IDs first and Business Domain IDs second.
            # Microsoft Learn does not currently document this behavior as of 2026-07-08.
            if ($TenantState.DataProductById.ContainsKey($scopeId)) {
                return [string]$TenantState.DataProductById[$scopeId].name
            }
            if ($TenantState.DomainById.ContainsKey($scopeId)) {
                return [string]$TenantState.DomainById[$scopeId].name
            }
            throw 'A data-quality policy scope could not be resolved to a live data product or business domain name.'
        }
        default {
            throw 'Unsupported Unified Catalog policy entity type.'
        }
    }
}

function Get-UnifiedCatalogTenantState {
    param([Parameter(Mandatory = $true)][object]$Context)

    $domains = @(Get-UnifiedCatalogBusinessDomainSet -Context $Context)
    $dataProducts = @(Get-UnifiedCatalogDataProductSet -Context $Context)
    $policies = @(Get-UnifiedCatalogPolicySet -Context $Context)

    $domainById = Get-OrdinalDictionary
    $domainByName = Get-OrdinalDictionary
    foreach ($item in $domains) {
        $domainById[[string]$item.id] = $item
        $domainByName[[string]$item.name] = $item
    }

    $dataProductById = Get-OrdinalDictionary
    $dataProductByName = Get-OrdinalDictionary
    foreach ($item in $dataProducts) {
        $dataProductById[[string]$item.id] = $item
        $dataProductByName[[string]$item.name] = $item
    }

    $businessDomainPolicyByScopeId = Get-OrdinalDictionary
    $dgDataQualityScopePolicyByScopeId = Get-OrdinalDictionary
    $dataGovernanceAppPolicies = @()
    foreach ($policy in $policies) {
        $family = Get-PolicyFamilyFromEntityType -EntityType ([string]$policy.properties.entity.type)
        if (-not $family) {
            continue
        }
        $scopeId = [string]$policy.properties.entity.referenceName
        switch ($family) {
            'BusinessDomain' { $businessDomainPolicyByScopeId[$scopeId] = $policy }
            'DGDataQualityScope' { $dgDataQualityScopePolicyByScopeId[$scopeId] = $policy }
            'DataGovernanceApp' { $dataGovernanceAppPolicies += ,$policy }
        }
    }

    return [pscustomobject]@{
        Domains                           = $domains
        DomainById                        = $domainById
        DomainByName                      = $domainByName
        DataProducts                      = $dataProducts
        DataProductById                   = $dataProductById
        DataProductByName                 = $dataProductByName
        Policies                          = $policies
        BusinessDomainPolicyByScopeId     = $businessDomainPolicyByScopeId
        DGDataQualityScopePolicyByScopeId = $dgDataQualityScopePolicyByScopeId
        DataGovernanceAppPolicies         = @($dataGovernanceAppPolicies)
    }
}

function Get-TenantAssignment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$TenantState)

    $rows = @()
    $allPrincipalIds = @()

    foreach ($policy in @($TenantState.Policies)) {
        $entityType = [string]$policy.properties.entity.type
        $family = Get-PolicyFamilyFromEntityType -EntityType $entityType
        if (-not $family) {
            continue
        }
        $scopeId = [string]$policy.properties.entity.referenceName
        $scopeLabel = Get-PolicyScopeLabel -Policy $policy -TenantState $TenantState
        $attrRules = @($policy.properties.attributeRules)

        foreach ($role in @(Get-ManagedRolesForFamily -Family $family)) {
            $ruleId = Get-ManagedRoleRuleId -RoleSlug ([string]$role.RoleSlug) -ScopeId $scopeId
            $attrRule = @($attrRules | Where-Object { [string]$_.id -eq $ruleId } | Select-Object -First 1)[0]
            $principalIds = @(Get-PrincipalIdsFromAttributeRule -AttributeRule $attrRule)
            if ($principalIds.Count -eq 0) {
                continue
            }
            foreach ($id in $principalIds) { $allPrincipalIds += [string]$id }
            $rows += [pscustomobject]@{
                    Key                    = ("{0}|{1}|{2}" -f $family, [string]$scopeLabel, [string]$role.FriendlyName)
                    Kind                   = 'UnifiedCatalogPolicy'
                    Name                   = Get-AssignmentDisplayName -RoleName ([string]$role.FriendlyName) -ScopeLabel ([string]$scopeLabel)
                    Family                 = $family
                    ScopeId                = $scopeId
                    ScopeLabel             = [string]$scopeLabel
                    RoleName               = [string]$role.FriendlyName
                    RoleSlug               = [string]$role.RoleSlug
                    PolicyId               = [string]$policy.id
                    Policy                 = $policy
                    PrincipalIds           = @($principalIds)
                    PrincipalDisplayNames  = @()
                    PrincipalAttributeName = Get-PrincipalAttributeNameFromRule -AttributeRule $attrRule
                    Description            = [string]$policy.properties.description
                    LastModifiedBy         = if ($policy.systemData.lastModifiedBy) { [string]$policy.systemData.lastModifiedBy } else { '' }
                }
        }
    }

    $displayNameMap = Resolve-DisplayNameMapByObjectId -ObjectIds @($allPrincipalIds)
    foreach ($row in $rows) {
        $names = @()
        foreach ($id in @($row.PrincipalIds)) {
            if (-not $displayNameMap.ContainsKey([string]$id)) {
                throw 'Could not reverse-resolve a live policy principal object ID to a display name.'
            }
            $names += [string]$displayNameMap[[string]$id]
        }
        $row.PrincipalDisplayNames = @($names | Sort-Object -Unique)
    }

    return @($rows)
}

function Resolve-TargetPolicyForDesiredAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Assignment,
        [Parameter(Mandatory = $true)][object]$TenantState
    )

    switch ($Assignment.Family) {
        'BusinessDomain' {
            if (-not $TenantState.DomainByName.ContainsKey([string]$Assignment.ScopeLabel)) {
                throw ("Business domain '{0}' does not exist in the live Unified Catalog tenant state." -f $Assignment.ScopeLabel)
            }
            $domain = $TenantState.DomainByName[[string]$Assignment.ScopeLabel]
            $scopeId = [string]$domain.id
            if (-not $TenantState.BusinessDomainPolicyByScopeId.ContainsKey($scopeId)) {
                throw ("The live tenant does not expose a built-in business-domain policy for '{0}'." -f $Assignment.ScopeLabel)
            }
            return $TenantState.BusinessDomainPolicyByScopeId[$scopeId]
        }
        'DGDataQualityScope' {
            # TODO: not-on-Learn. The YAML's legacy domain field carries a human-
            # readable scope label for data-quality roles because the documented
            # policy payload exposes only DGDataQualityScopeReference IDs.
            # Microsoft Learn does not currently document this behavior as of 2026-07-08.
            $scopeId = $null
            if ($TenantState.DataProductByName.ContainsKey([string]$Assignment.ScopeLabel)) {
                $scopeId = [string]$TenantState.DataProductByName[[string]$Assignment.ScopeLabel].id
            }
            elseif ($TenantState.DomainByName.ContainsKey([string]$Assignment.ScopeLabel)) {
                $scopeId = [string]$TenantState.DomainByName[[string]$Assignment.ScopeLabel].id
            }
            else {
                throw ("Data-quality policy scope '{0}' could not be resolved to a live data product or business domain." -f $Assignment.ScopeLabel)
            }
            if (-not $TenantState.DGDataQualityScopePolicyByScopeId.ContainsKey($scopeId)) {
                throw ("The live tenant does not expose a built-in data-quality policy for scope '{0}'." -f $Assignment.ScopeLabel)
            }
            return $TenantState.DGDataQualityScopePolicyByScopeId[$scopeId]
        }
        'DataGovernanceApp' {
            if (@($TenantState.DataGovernanceAppPolicies).Count -eq 0) {
                throw 'The live tenant does not expose a DataGovernanceApp policy.'
            }
            if (@($TenantState.DataGovernanceAppPolicies).Count -gt 1) {
                throw 'The live tenant exposed more than one DataGovernanceApp policy; this reconciler expects exactly one global policy object.'
            }
            return @($TenantState.DataGovernanceAppPolicies)[0]
        }
        default {
            throw 'Unsupported desired policy family.'
        }
    }
}

function Get-DesiredAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DesiredItems,
        [Parameter(Mandatory = $true)][object]$TenantState
    )

    $roleMap = Get-RoleMetadataMap
    $assignments = @()
    foreach ($item in @($DesiredItems)) {
        $roleName = [string]$item.role
        if (-not $roleMap.ContainsKey($roleName)) {
            throw ("Role '{0}' is not recognized by the Unified Catalog policy reconciler." -f $roleName)
        }
        $metadata = $roleMap[$roleName]
        $scopeLabel = if ($item.PSObject.Properties.Match('domain').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$item.domain)) {
            [string]$item.domain
        }
        else {
            $null
        }
        if ($metadata.ScopeRequired -and [string]::IsNullOrWhiteSpace([string]$scopeLabel)) {
            throw ("Role '{0}' requires a domain/scope label in data-access-policies.yaml." -f $roleName)
        }
        if ((-not $metadata.ScopeRequired) -and -not [string]::IsNullOrWhiteSpace([string]$scopeLabel)) {
            throw ("Role '{0}' is tenant-wide. Omit the domain field for this role." -f $roleName)
        }

        $principalIds = @()
        $principalDisplayNames = @()
        foreach ($displayName in @($item.principals)) {
            if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
                continue
            }
            $principalDisplayNames += [string]$displayName
            $principalIds += (Resolve-PrincipalIdByDisplayName -DisplayName ([string]$displayName))
        }
        $policy = Resolve-TargetPolicyForDesiredAssignment -Assignment ([pscustomobject]@{ Family = $metadata.Family; ScopeLabel = $scopeLabel }) -TenantState $TenantState
        $scopeId = [string]$policy.properties.entity.referenceName
        $assignments += [pscustomobject]@{
                Key                   = ("{0}|{1}|{2}" -f $metadata.Family, [string]$scopeLabel, $roleName)
                Kind                  = 'UnifiedCatalogPolicy'
                Name                  = Get-AssignmentDisplayName -RoleName $roleName -ScopeLabel $scopeLabel
                Family                = [string]$metadata.Family
                ScopeId               = $scopeId
                ScopeLabel            = [string]$scopeLabel
                RoleName              = $roleName
                RoleSlug              = [string]$metadata.RoleSlug
                PolicyId              = [string]$policy.id
                Policy                = $policy
                PrincipalIds          = @($principalIds | Sort-Object -Unique)
                PrincipalDisplayNames = @($principalDisplayNames | Sort-Object -Unique)
                Description           = if ($item.PSObject.Properties.Match('description').Count -gt 0) { [string]$item.description } else { '' }
                Status                = if ($item.PSObject.Properties.Match('status').Count -gt 0) { [string]$item.status } else { '' }
            }
    }
    return @($assignments)
}

function Get-PrincipalDiffText {
    param(
        [AllowEmptyCollection()][string[]]$DesiredDisplayNames,
        [AllowEmptyCollection()][string[]]$TenantDisplayNames
    )
    $toAdd = @($DesiredDisplayNames | Where-Object { $TenantDisplayNames -notcontains $_ } | Sort-Object -Unique)
    $toRemove = @($TenantDisplayNames | Where-Object { $DesiredDisplayNames -notcontains $_ } | Sort-Object -Unique)
    $parts = @()
    if ($toAdd.Count -gt 0) {
        $parts += ("Add principals: {0}" -f ($toAdd -join ', '))
    }
    if ($toRemove.Count -gt 0) {
        $parts += ("Remove principals: {0}" -f ($toRemove -join ', '))
    }
    if ($parts.Count -eq 0) {
        return 'Principal set already matches desired state.'
    }
    return ($parts -join '; ')
}

function Test-IsConflict {
    param([object]$TenantAssignment)
    if ($null -eq $TenantAssignment) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$TenantAssignment.LastModifiedBy)) { return $false }
    return ($script:CurrentPrincipalIds -notcontains [string]$TenantAssignment.LastModifiedBy)
}

function Get-ReconciliationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DesiredAssignments,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantAssignments,
        [switch]$AllowConflictOverwrite,
        [switch]$PruneMissing
    )

    $report = New-Object 'System.Collections.Generic.List[object]'
    $plan = New-Object 'System.Collections.Generic.List[object]'
    $desiredByKey = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    $tenantByKey = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)

    foreach ($desired in @($DesiredAssignments)) {
        $desiredByKey[[string]$desired.Key] = $desired
    }
    foreach ($tenant in @($TenantAssignments)) {
        $tenantByKey[[string]$tenant.Key] = $tenant
    }

    foreach ($key in @($desiredByKey.Keys | Sort-Object)) {
        $desired = $desiredByKey[$key]
        if (-not $tenantByKey.ContainsKey($key)) {
            $reason = if ($desired.PrincipalDisplayNames.Count -gt 0) { "Grant principals: $($desired.PrincipalDisplayNames -join ', ')" } else { 'Grant empty principal set.' }
            $report.Add((ConvertTo-ReportRow -Category 'Create' -Kind $desired.Kind -Name $desired.Name -Reason $reason -Fields @('principals'))) | Out-Null
            $plan.Add([pscustomobject]@{ Action = 'Create'; Name = $desired.Name; Kind = $desired.Kind; Desired = $desired; Tenant = $null; Fields = @('principals'); Conflict = $false; Reason = $reason }) | Out-Null
            continue
        }

        $tenant = $tenantByKey[$key]
        $desiredIds = @($desired.PrincipalIds | Sort-Object -Unique)
        $tenantIds = @($tenant.PrincipalIds | Sort-Object -Unique)
        $desiredJson = $desiredIds | ConvertTo-Json -Compress
        $tenantJson = $tenantIds | ConvertTo-Json -Compress
        if ($desiredJson -eq $tenantJson) {
            $report.Add((ConvertTo-ReportRow -Category 'NoChange' -Kind $desired.Kind -Name $desired.Name)) | Out-Null
            continue
        }

        $reason = Get-PrincipalDiffText -DesiredDisplayNames @($desired.PrincipalDisplayNames) -TenantDisplayNames @($tenant.PrincipalDisplayNames)
        # ADR 0053: -AllowConflictOverwrite is bound from -OverwriteForeignAuthor
        # at the call site, NOT from -Force. -Force no longer authorizes an
        # authorship overwrite.
        $isConflict = Test-IsConflict -TenantAssignment $tenant
        if ($isConflict -and -not $AllowConflictOverwrite.IsPresent) {
            $report.Add((ConvertTo-ReportRow -Category 'Conflict' -Kind $desired.Kind -Name $desired.Name -Reason 'Tenant policy was last modified by a different principal. Re-run with -OverwriteForeignAuthor to overwrite.' -Fields @('principals'))) | Out-Null
            continue
        }
        if ($isConflict) {
            $report.Add((ConvertTo-ReportRow -Category 'Conflict' -Kind $desired.Kind -Name $desired.Name -Reason 'Conflict will be overwritten because -OverwriteForeignAuthor was supplied.' -Fields @('principals'))) | Out-Null
        }
        else {
            $report.Add((ConvertTo-ReportRow -Category 'Update' -Kind $desired.Kind -Name $desired.Name -Reason $reason -Fields @('principals'))) | Out-Null
        }
        $plan.Add([pscustomobject]@{ Action = 'Update'; Name = $desired.Name; Kind = $desired.Kind; Desired = $desired; Tenant = $tenant; Fields = @('principals'); Conflict = $isConflict; Reason = $reason }) | Out-Null
    }

    foreach ($key in @($tenantByKey.Keys | Sort-Object)) {
        if ($desiredByKey.ContainsKey($key)) {
            continue
        }
        $tenant = $tenantByKey[$key]
        $reason = if ($tenant.PrincipalDisplayNames.Count -gt 0) { "Live-only principals: $($tenant.PrincipalDisplayNames -join ', ')" } else { 'Exists in the tenant but not in desired state.' }
        $report.Add((ConvertTo-ReportRow -Category 'Orphan' -Kind $tenant.Kind -Name $tenant.Name -Reason 'Exists in the tenant but not in desired state.' -Fields @('principals'))) | Out-Null
        if ($PruneMissing.IsPresent) {
            $plan.Add([pscustomobject]@{ Action = 'Remove'; Name = $tenant.Name; Kind = $tenant.Kind; Desired = $null; Tenant = $tenant; Fields = @('principals'); Conflict = $false; Reason = $reason }) | Out-Null
        }
    }

    return [pscustomobject]@{
        Report = $report.ToArray()
        Plan   = $plan.ToArray()
    }
}

function Invoke-DirectionPolicyPlan {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Plan,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Report
    )
    # Initialised before the audit short-circuit so the ADR 0052 gate can read
    # `.Count` on it unconditionally. Under `audit` the plan is emptied and no
    # overwrite is ever recorded, so both gates see zero and stay silent --
    # which is correct: audit writes nothing.
    $script:RepoWinsOverwrites = New-Object 'System.Collections.Generic.List[string]'

    if ($DirectionPolicy -eq 'audit') {
        Write-Information '[ADR0029-AUDIT] DirectionPolicy=audit - no writes would have fired. Plan above is read-only.' -InformationAction Continue
        $Plan.Clear()
        return
    }

    $keptPlan = New-Object 'System.Collections.Generic.List[object]'
    $skippedNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $Plan.ToArray()) {
        # Only an Update entry represents shared-property drift, and drift is
        # the only thing -DirectionPolicy arbitrates (ADR 0029). A Create has
        # no tenant object to preserve; a Remove is governed by -PruneMissing,
        # not by the direction policy. Passing both through the drift arm
        # would make `portal-wins` -- the DEFAULT -- skip every create and
        # every prune, silently turning this reconciler into a no-op.
        #
        # This filter is why -HasDrift can be $true below. It previously read
        # `-HasDrift $false` with no filter at all, which meant
        # Resolve-DirectionPolicyAction's `$HasDrift -and $Policy -eq
        # 'portal-wins'` skip arm could never be reached: `portal-wins` never
        # skipped, `repo-wins` was indistinguishable from it, and EVERY
        # drifted role assignment was overwritten regardless of policy, on a
        # permissions surface. Mirrors Deploy-UnifiedCatalog.ps1's loop, which
        # has had the filter all along.
        # Reference: docs/adr/0029-source-of-truth-direction-policy.md
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
        # Survived the policy: this run WILL overwrite the tenant's principal
        # set on this role assignment. Collect it so the ADR 0052 gate can
        # name the objects and the count. The gate is keyed on THIS LIST --
        # the plan -- never on $DirectionPolicy. See ConfirmGate.psm1
        # "KEY THE GATE ON THE PLAN, NOT ON THE POLICY".
        Write-Warning ("Overwriting tenant principals on {0} '{1}' fields: {2}" -f $entry.Kind, $entry.Name, (@($entry.Fields) -join ','))
        $script:RepoWinsOverwrites.Add([string]$entry.Name) | Out-Null
        $keptPlan.Add($entry) | Out-Null
    }

    if ($skippedNames.Count -gt 0) {
        $keptReport = @($Report | Where-Object { -not ((($_.Category -eq 'Create') -or ($_.Category -eq 'Update') -or ($_.Category -eq 'Orphan') -or ($_.Category -eq 'Conflict')) -and ($skippedNames -contains [string]$_.Name)) })
        $Report.Clear()
        foreach ($row in $keptReport) { $Report.Add($row) | Out-Null }
    }
    $Plan.Clear()
    foreach ($entry in $keptPlan) { $Plan.Add($entry) | Out-Null }
}

function Show-PlanSummary {
    param([object[]]$Report)
    $rows = @($Report | Sort-Object Category, Name)
    if ($rows.Count -eq 0) {
        Write-Information 'Plan summary: no rows.' -InformationAction Continue
        return
    }
    Write-Information '' -InformationAction Continue
    Write-Information 'Plan summary (pre-write):' -InformationAction Continue
    $rows | Format-Table Category, Kind, Name, Field, Reason -Wrap | Out-String | Write-Information -InformationAction Continue
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

function Get-FinalRoleAssignmentsByPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantAssignments,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$PlanEntries
    )

    $byPolicy = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($tenant in @($TenantAssignments)) {
        if (-not $byPolicy.ContainsKey([string]$tenant.PolicyId)) {
            $byPolicy[[string]$tenant.PolicyId] = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        }
        $roleMap = $byPolicy[[string]$tenant.PolicyId]
        $roleMap[[string]$tenant.RoleSlug] = @($tenant.PrincipalIds)
    }

    foreach ($entry in @($PlanEntries)) {
        $policyId = if ($entry.Desired) { [string]$entry.Desired.PolicyId } else { [string]$entry.Tenant.PolicyId }
        if (-not $byPolicy.ContainsKey($policyId)) {
            $byPolicy[$policyId] = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        }
        $roleMap = $byPolicy[$policyId]
        switch ($entry.Action) {
            'Create' { $roleMap[[string]$entry.Desired.RoleSlug] = @($entry.Desired.PrincipalIds) }
            'Update' { $roleMap[[string]$entry.Desired.RoleSlug] = @($entry.Desired.PrincipalIds) }
            'Remove' { $roleMap[[string]$entry.Tenant.RoleSlug] = @() }
        }
    }
    return $byPolicy
}

function ConvertTo-ManagedAttributeRule {
    param(
        [Parameter(Mandatory = $true)][string]$RoleSlug,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$PrincipalIds,
        [Parameter(Mandatory = $true)][string]$PrincipalAttributeName
    )
    $ruleName = Get-ManagedRoleRuleName -RoleSlug $RoleSlug
    return [ordered]@{
        kind = 'attributerule'
        id = ("{0}:{1}" -f $ruleName, $ScopeId)
        name = ("{0}:{1}" -f $ruleName, $ScopeId)
        dnfCondition = ,@(
            [ordered]@{
                attributeName = $PrincipalAttributeName
                attributeValueIncludedIn = @($PrincipalIds)
            },
            [ordered]@{
                fromRule = $ruleName
                attributeName = 'derived.purview.role'
                attributeValueIncludes = $ruleName
            }
        )
    }
}

function ConvertTo-ManagedPermissionRule {
    param(
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$ScopeId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ManagedRoleSlugs,
        [Parameter(Mandatory = $true)][object]$RoleAssignmentsBySlug
    )
    $permissionRuleId = Get-ManagedPermissionRuleId -Family $Family -ScopeId $ScopeId
    $dnf = @()
    foreach ($slug in @($ManagedRoleSlugs)) {
        $principalIds = @($RoleAssignmentsBySlug[$slug])
        if ($principalIds.Count -eq 0) {
            continue
        }
        $roleRuleId = Get-ManagedRoleRuleId -RoleSlug $slug -ScopeId $ScopeId
        $dnf += ,@(
            [ordered]@{
                fromRule = $roleRuleId
                attributeName = 'derived.purview.permission'
                attributeValueIncludes = $roleRuleId
            }
        )
    }
    return [ordered]@{
        kind = 'attributerule'
        id = $permissionRuleId
        name = $permissionRuleId
        dnfCondition = @($dnf)
    }
}

function ConvertTo-PolicyUpdatePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Policy,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TenantAssignments,
        [Parameter(Mandatory = $true)][object]$RoleAssignmentsBySlug
    )

    $family = Get-PolicyFamilyFromEntityType -EntityType ([string]$Policy.properties.entity.type)
    $scopeId = [string]$Policy.properties.entity.referenceName
    $payload = $Policy | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $attrRules = @($Policy.properties.attributeRules)
    $managedRoles = @(Get-ManagedRolesForFamily -Family $family)
    $managedRoleIds = @($managedRoles | ForEach-Object { Get-ManagedRoleRuleId -RoleSlug ([string]$_.RoleSlug) -ScopeId $scopeId })
    $permissionRuleId = Get-ManagedPermissionRuleId -Family $family -ScopeId $scopeId
    $preservedRules = @($attrRules | Where-Object { ([string]$_.id) -notin @($managedRoleIds + $permissionRuleId) })

    $newManagedRules = New-Object 'System.Collections.Generic.List[object]'
    foreach ($role in $managedRoles) {
        $slug = [string]$role.RoleSlug
        $principalIds = @($RoleAssignmentsBySlug[$slug])
        if ($principalIds.Count -eq 0) {
            continue
        }
        $existingAssignment = @($TenantAssignments | Where-Object { $_.RoleSlug -eq $slug } | Select-Object -First 1)[0]
        # Resolve-PrincipalIdByDisplayName always resolves against the Groups
        # collection (Get-EntraPrincipalIdByDisplayName.ps1 default Kind), so
        # every principal ID this reconciler produces is a Group object ID.
        # 'principal.microsoft.groups' is the attribute that matches a
        # caller's group memberships; 'principal.microsoft.id' only matches
        # an individual caller's own object ID and would never match here,
        # silently granting access to nobody on a brand-new (Create) role
        # assignment that has no pre-existing tenant rule to inherit the
        # attribute name from.
        $principalAttributeName = if ($existingAssignment) { [string]$existingAssignment.PrincipalAttributeName } else { 'principal.microsoft.groups' }
        $newManagedRules.Add((ConvertTo-ManagedAttributeRule -RoleSlug $slug -ScopeId $scopeId -PrincipalIds $principalIds -PrincipalAttributeName $principalAttributeName)) | Out-Null
    }
    $newManagedRules.Add((ConvertTo-ManagedPermissionRule -Family $family -ScopeId $scopeId -ManagedRoleSlugs @($managedRoles | ForEach-Object { [string]$_.RoleSlug }) -RoleAssignmentsBySlug $RoleAssignmentsBySlug)) | Out-Null

    $payload['properties']['attributeRules'] = @($preservedRules | ForEach-Object { $_ | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }) + $newManagedRules.ToArray()
    return $payload
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
$yamlPath = Join-Path $Path 'data-access-policies.yaml'
$schemaPath = Join-Path $Path 'data-access-policies.schema.json'
$desiredItems = @(Get-DesiredItem -YamlPath $yamlPath -SchemaPath $schemaPath)
$mode = if ($ExportCurrentState.IsPresent) { 'Export' } else { 'Apply' }

Write-Information ("Parameters file : {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Purview account : {0}" -f $AccountName) -InformationAction Continue
Write-Information ("YAML file       : {0}" -f $yamlPath) -InformationAction Continue
Write-Information ("Mode            : {0}" -f $mode) -InformationAction Continue
Write-Information ("DirectionPolicy : {0}" -f $DirectionPolicy) -InformationAction Continue
Write-Information ("PruneMissing    : {0}" -f $PruneMissing.IsPresent) -InformationAction Continue
Write-Information ("Force           : {0}" -f $Force.IsPresent) -InformationAction Continue
# ADR 0053: -Force and -OverwriteForeignAuthor are independent. Print both so
# the run log shows exactly which guard the operator suppressed.
Write-Information ("OverwriteForeignAuthor : {0}" -f $OverwriteForeignAuthor.IsPresent) -InformationAction Continue

# Issue #13, guard 1: empty-desired-set hard refusal for -PruneMissing.
#
# -Path here is a FOLDER; the desired set is the `items:` block of the single
# file data-access-policies.yaml inside it, so the guard reports $yamlPath
# rather than $Path -- that is the file a wrong -Path would have mis-selected.
#
# With zero desired items every live data-access policy assignment falls out of
# the orphan match below and the run would revoke the whole set. The rationale,
# the likely causes, and the 2026-07-19 production hit are documented in
# scripts/modules/PruneGuard.psm1.
#
# Placed immediately after the desired-state load and before
# Get-UnifiedCatalogApiContext, which is this script's first tenant contact
# (it acquires the Purview data-plane token via az account get-access-token).
if ($mode -eq 'Apply' -and $PruneMissing.IsPresent) {
    Assert-PruneDesiredSetNotEmpty `
        -DesiredCount   @($desiredItems).Count `
        -ObjectTypeNoun 'data access policy assignment' `
        -SourcePath     $yamlPath `
        -CollectionKey  'items'
}

if ($WhatIfPreference -and $mode -eq 'Export') {
    Write-Information '-WhatIf specified with -ExportCurrentState. Planned behaviour (no remote calls made):' -InformationAction Continue
    Write-Information '  Export Unified Catalog policy assignments -> data-access-policies.yaml' -InformationAction Continue
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

$tenantAssignments = @(Get-TenantAssignment -TenantState $tenantState)
if ($mode -eq 'Export') {
    if (@($desiredItems).Count -gt 0 -and -not $Force.IsPresent) {
        throw "'data-access-policies.yaml' already declares item(s). Re-run with -Force to overwrite."
    }
    $entries = @(
        $tenantAssignments |
            Sort-Object ScopeLabel, RoleName |
            ForEach-Object {
                $entry = [ordered]@{}
                if (-not [string]::IsNullOrWhiteSpace([string]$_.ScopeLabel)) {
                    $entry['domain'] = [string]$_.ScopeLabel
                }
                $entry['role'] = [string]$_.RoleName
                $entry['principals'] = @($_.PrincipalDisplayNames | Sort-Object -Unique)
                [pscustomobject]$entry
            }
    )
    $shouldProcessTarget = "YAML file 'data-access-policies.yaml'"
    $shouldProcessAction = "Replace 'items:' block with $(@($entries).Count) item(s)"
    if ($PSCmdlet.ShouldProcess($shouldProcessTarget, $shouldProcessAction)) {
        Write-YamlItemsBlock -FilePath $yamlPath -Entries $entries
    }
    return
}

$desiredAssignments = $null
$blockedRows = New-Object 'System.Collections.Generic.List[object]'
try {
    $desiredAssignments = @(Get-DesiredAssignment -DesiredItems $desiredItems -TenantState $tenantState)
}
catch {
    $blockedRows.Add((ConvertTo-ReportRow -Category 'Blocked' -Kind 'UnifiedCatalogPolicy' -Name 'Desired state' -Reason $_.Exception.Message)) | Out-Null
    $desiredAssignments = @()
}

$planResult = Get-ReconciliationPlan -DesiredAssignments $desiredAssignments -TenantAssignments $tenantAssignments -AllowConflictOverwrite:$OverwriteForeignAuthor.IsPresent -PruneMissing:$PruneMissing.IsPresent
$report = New-Object 'System.Collections.Generic.List[object]'
$plan = New-Object 'System.Collections.Generic.List[object]'
foreach ($row in $planResult.Report) { $report.Add($row) | Out-Null }
foreach ($entry in $planResult.Plan) { $plan.Add($entry) | Out-Null }
Invoke-DirectionPolicyPlan -Plan $plan -Report $report
foreach ($blocked in $blockedRows) { $report.Add($blocked) | Out-Null }
Show-PlanSummary -Report $report.ToArray()

if ($blockedRows.Count -gt 0) {
    throw ("Reconciliation aborted: {0} blocked item(s)." -f $blockedRows.Count)
}

# ---- Issue #13, guard 2: prune sanity ratio ----
# Guard 1 (desired-state load region) catches only the total wipe. This
# catches the near-total one: a desired set that lost most of its assignments
# to a bad merge, or a -Path pointing at a smaller environment's tree, both of
# which leave a non-zero desired count and so clear guard 1.
#
# Keyed on $prunePlan -- the Remove entries the ADR 0052 prune gate below also
# reads, so the guard and the prompt cannot disagree -- over the full live
# assignment set. Hoisted here so it fires before BOTH ADR 0052 gates: the
# operator is never prompted to confirm an overwrite for a plan whose prune
# the guard would refuse anyway.
#
# No audit gate is needed: Invoke-DirectionPolicyPlan clears $plan under
# `-DirectionPolicy audit` (it owns that decision), so $prunePlan is empty
# under audit and the guard's PruneCount is 0 -- Assert-PruneRatioWithinThreshold
# returns early on a zero prune, never refusing a read-only run.
# Reference: scripts/modules/PruneGuard.psm1
$prunePlan = @($plan | Where-Object { $_.Action -eq 'Remove' })
if ($PruneMissing.IsPresent) {
    Assert-PruneRatioWithinThreshold `
        -PruneCount     @($prunePlan).Count `
        -LiveCount      @($tenantAssignments).Count `
        -ObjectTypeNoun 'Unified Catalog role assignment' `
        -MaxPruneRatio  $MaxPruneRatio `
        -Allow:$AllowMajorityPrune
}

# ---- ADR 0052: destructive-operation confirmation gate ----
# The last point before the write loop at which nothing has been PUT.
# `Invoke-DirectionPolicyPlan` has already run, so `$plan` and
# `$script:RepoWinsOverwrites` are the FINAL plan -- what this run will
# actually do. Both gates are keyed on that plan and NEVER on
# `$DirectionPolicy`; see ConfirmGate.psm1 "KEY THE GATE ON THE PLAN, NOT
# ON THE POLICY". This script is the reason that rule exists: its
# hardcoded `-HasDrift $false` meant `portal-wins` never skipped, so a
# policy-keyed gate would have sat silent while a *permissions* surface
# was overwritten.
#
# ShouldContinue, not ShouldProcess: it performs no
# ConfirmImpact/$ConfirmPreference comparison, so it cannot be silently
# defeated (issue #85). The $yesToAll/$noToAll pair is shared by both
# gates, so a run that trips the overwrite gate AND the prune gate
# prompts once, not twice, and never once per object.
#
# Suppressed by -Force, by an explicit -Confirm:$false (the CI path), and
# skipped under -WhatIf -- where the branch is still WALKED so the
# per-write ShouldProcess calls render their "What if:" preview lines.
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

if ($script:RepoWinsOverwrites.Count -gt 0) {
    $overwriteNames = @($script:RepoWinsOverwrites | Sort-Object -Unique)
    $overwriteQuery = "This run will OVERWRITE the tenant principal set on {0} Unified Catalog role assignment(s) with the values from YAML: {1}. Principals granted in the portal but absent from YAML LOSE ACCESS. Continue?" -f `
        $overwriteNames.Count, ($overwriteNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $overwriteQuery)) {
        throw 'Aborted by operator at the overwrite confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

if ($prunePlan.Count -gt 0) {
    $pruneNames = @($prunePlan | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    $pruneQuery = "-PruneMissing will REVOKE {0} orphan Unified Catalog role assignment(s) from the tenant: {1}. The principals holding them lose access. This cannot be undone. Continue?" -f `
        $pruneNames.Count, ($pruneNames -join ', ')
    if (-not (Assert-DestructiveOperationConfirmed @gateArgs -Query $pruneQuery)) {
        throw 'Aborted by operator at the -PruneMissing revoke confirmation gate (ADR 0052). No tenant writes were made.'
    }
}

$planByPolicy = @($plan | Group-Object { if ($_.Desired) { [string]$_.Desired.PolicyId } else { [string]$_.Tenant.PolicyId } })
$finalAssignmentsByPolicy = Get-FinalRoleAssignmentsByPolicy -TenantAssignments $tenantAssignments -PlanEntries $plan.ToArray()

# Issue #13: the failure reporter, at POLICY granularity. Unlike the per-orphan
# delete reconcilers, revokes here are folded into a single per-policy PUT that
# rewrites the whole assignment set, so the reporting unit is the policy PUT,
# not an individual assignment. The variable keeps the shared $pruneFailures
# name (the rollout tripwire and lift harness anchor on it) even though each
# entry names a policy. Previously an $ErrorActionPreference='stop' PUT failure
# terminated the run on the first failed policy so the rest were never
# attempted; now each failure is reported via Write-PruneFailure and collected,
# and a single aggregate throw after the loop names every failed policy so a
# failed run still exits non-zero. NOTE: a policy PUT carries grants AND revokes
# together, so this reporter fires on any failed policy update, not only
# revoke-bearing ones -- a failed grant-only PUT exiting 0 is the same defect
# class, so the wider net is deliberate.
$pruneFailures = New-Object 'System.Collections.Generic.List[string]'

foreach ($policyGroup in $planByPolicy) {
    $policyId = [string]$policyGroup.Name
    $entries = @($policyGroup.Group)
    $policy = if ($entries[0].Desired) { $entries[0].Desired.Policy } else { $entries[0].Tenant.Policy }
    $tenantPolicyAssignments = @($tenantAssignments | Where-Object { [string]$_.PolicyId -eq $policyId })
    $roleAssignmentsBySlug = $finalAssignmentsByPolicy[$policyId]
    $payload = ConvertTo-PolicyUpdatePayload -Policy $policy -TenantAssignments $tenantPolicyAssignments -RoleAssignmentsBySlug $roleAssignmentsBySlug
    $targets = @($entries | ForEach-Object { "- $($_.Name): $($_.Reason)" })
    Write-Information '' -InformationAction Continue
    Write-Information ("Grant/revoke diff for policy '{0}':" -f $policy.name) -InformationAction Continue
    foreach ($line in $targets) {
        Write-Information $line -InformationAction Continue
    }
    $target = ("Unified Catalog policy '{0}'" -f $policy.name)
    $action = 'Update grant/revoke-sensitive policy assignments'
    if ($PSCmdlet.ShouldProcess($target, $action)) {
        # ${policyId} is brace-delimited deliberately: unbraced, PowerShell reads
        # the `?` as part of the variable name, so `$policyId?api-version` parses
        # as the (undefined) variable `${policyId?api}` and the URI collapses to
        # `.../policies/-version=...` -- no policy id, no `?` query separator.
        # Reference: https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_quoting_rules
        $uri = "$($context.Endpoint)/datagovernance/catalog/policies/${policyId}?api-version=$($script:UnifiedCatalogApiVersion)"
        # api-version justification: the Policies operation group is preview-only
        # as of issue #47 and Policies - Update documents the pinned 2026-03-20-preview
        # PUT contract, including the CatalogValue request body with decisionRules /
        # attributeRules.
        # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/policies/update?view=rest-purview-purview-unified-catalog-2026-03-20-preview
        try {
            [void](Invoke-UnifiedCatalogRestMethod -Method PUT -Uri $uri -Headers $context.Headers -Body $payload)
        }
        catch {
            Write-PruneFailure ("PUT policy '{0}' (grant/revoke update) failed: {1}" -f $policy.name, $_.Exception.Message)
            $pruneFailures.Add(("policy '{0}'" -f $policy.name)) | Out-Null
            continue
        }
    }
}

if ($pruneFailures.Count -gt 0) {
    throw ("Reconciliation aborted: {0} Unified Catalog policy update(s) could not be applied: {1}. See errors above." -f $pruneFailures.Count, ($pruneFailures -join ', '))
}

return $report.ToArray()
