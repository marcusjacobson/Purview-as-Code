#Requires -Version 7.4
<#
.SYNOPSIS
    Resolve a Microsoft Entra administrative unit display name to its object ID,
    or reverse-resolve an object ID back to a display name.

.DESCRIPTION
    Helper used by data-plane reconcilers that scope sensitivity label policies
    to Entra administrative units via Set-LabelPolicy -IncludedAdministrativeUnits.
    The reconciler stores the semantic displayName in YAML (committable, non-secret);
    this script resolves it to an object ID at deploy time via Microsoft Graph v1.0.

    Authoritative for the ADR 0023 Category 3 contract extended to administrative
    units by ADR 0042 (docs/adr/0042-label-policy-admin-units.md).

    Fail-fast on:
      * Graph returns zero matches (the AU does not exist).
      * Graph returns more than one match (display name is not unique).
      * Graph call errors out (transport or auth failure).

    The result of a successful lookup is cached for the lifetime of the
    PowerShell session in the global hashtable $global:PurviewIdentifierCache
    (shared with Get-EntraPrincipalIdByDisplayName.ps1). Cache keys are prefixed
    with 'AdministrativeUnit|' to avoid collisions with principal lookups.

    References:
      Microsoft Graph - List administrativeUnits (forward lookup):
        https://learn.microsoft.com/en-us/graph/api/administrativeunit-list
      Microsoft Graph - Get administrativeUnit (reverse lookup by ID):
        https://learn.microsoft.com/en-us/graph/api/administrativeunit-get
      ADR 0042 (this script contract):
        docs/adr/0042-label-policy-admin-units.md
      ADR 0023 (identifier resolution):
        docs/adr/0023-identifier-resolution.md

.PARAMETER DisplayName
    The exact displayName of the administrative unit to resolve to an object ID.
    Mutually exclusive with -ObjectId.

.PARAMETER ObjectId
    The GUID object ID of the administrative unit to reverse-resolve to a
    displayName. Mutually exclusive with -DisplayName.

.PARAMETER ApiVersion
    Microsoft Graph API version segment. Defaults to v1.0. Use beta only when
    a v1.0 endpoint genuinely cannot serve the lookup; add an inline comment
    justifying the choice.
    Reference: https://learn.microsoft.com/en-us/graph/overview#whats-in-microsoft-graph

.PARAMETER NoCache
    Bypass the session cache. Forces a fresh Graph lookup. Use only in tests
    or when the admin unit has just been created in the same shell session.

.EXAMPLE
    $id = ./scripts/Get-AdministrativeUnitIdByDisplayName.ps1 `
        -DisplayName 'Marketing Dept'

.EXAMPLE
    $name = ./scripts/Get-AdministrativeUnitIdByDisplayName.ps1 `
        -ObjectId '00000000-0000-0000-0000-000000000001'
#>
[CmdletBinding(DefaultParameterSetName = 'ByDisplayName')]
[OutputType([string])]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars', '',
    Justification = 'Global $PurviewIdentifierCache is the documented cross-invocation cache surface per ADR 0023; session-scoped, never persisted, and contains only non-secret object IDs and display names.')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByDisplayName')]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByObjectId')]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$ObjectId,

    [Parameter()]
    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion = 'v1.0',

    [Parameter()]
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

# Initialize the session-scope cache on first use (shared with Get-EntraPrincipalIdByDisplayName.ps1).
# Reference: docs/adr/0023-identifier-resolution.md
if (-not (Get-Variable -Name 'PurviewIdentifierCache' -Scope Global -ErrorAction SilentlyContinue)) {
    $global:PurviewIdentifierCache = @{}
}

if ($PSCmdlet.ParameterSetName -eq 'ByDisplayName') {
    $cacheKey = "AdministrativeUnit|$DisplayName"

    if (-not $NoCache -and $global:PurviewIdentifierCache.ContainsKey($cacheKey)) {
        Write-Verbose "Cache hit for $cacheKey -> $($global:PurviewIdentifierCache[$cacheKey])"
        return $global:PurviewIdentifierCache[$cacheKey]
    }

    # Escape a single quote in the display name per OData filter rules.
    # Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter
    $escaped = $DisplayName.Replace("'", "''")
    $filter  = "displayName eq '$escaped'"
    $select  = 'id,displayName'

    $uri = "https://graph.microsoft.com/$ApiVersion/administrativeUnits?`$filter=$filter&`$select=$select"
    Write-Verbose "Resolving administrative unit '$DisplayName' via $uri"

    # Reference: https://learn.microsoft.com/en-us/cli/azure/reference-index#az-rest
    $raw = az rest --method GET --uri $uri --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft Graph lookup for administrative unit '$DisplayName' failed. Run 'az login' or check the automation identity's AdministrativeUnit.Read.All permission."
    }

    $response = $raw | ConvertFrom-Json
    $matched  = @($response.value)

    if ($matched.Count -eq 0) {
        throw "No administrative unit found in Microsoft Entra with displayName '$DisplayName'. Create the unit in Entra ID or fix the YAML (docs/adr/0042-label-policy-admin-units.md)."
    }
    if ($matched.Count -gt 1) {
        $ids = ($matched | ForEach-Object { $_.id }) -join ', '
        throw "Multiple administrative units found with displayName '$DisplayName' (objectIds: $ids). Display name must be unique for ADR 0023 resolution to succeed."
    }

    $objectId = $matched[0].id
    $global:PurviewIdentifierCache[$cacheKey] = $objectId
    Write-Verbose "Resolved administrative unit '$DisplayName' -> $objectId"
    return $objectId
}
else {
    # Reverse lookup: object ID -> display name.
    # Reference: https://learn.microsoft.com/en-us/graph/api/administrativeunit-get
    $cacheKey = "AdministrativeUnit|ById|$ObjectId"

    if (-not $NoCache -and $global:PurviewIdentifierCache.ContainsKey($cacheKey)) {
        Write-Verbose "Cache hit for $cacheKey -> $($global:PurviewIdentifierCache[$cacheKey])"
        return $global:PurviewIdentifierCache[$cacheKey]
    }

    $uri = "https://graph.microsoft.com/$ApiVersion/administrativeUnits/$ObjectId`?`$select=id,displayName"
    Write-Verbose "Reverse-resolving administrative unit '$ObjectId' via $uri"

    $raw = az rest --method GET --uri $uri --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft Graph lookup for administrative unit object ID '$ObjectId' failed. Run 'az login' or check the automation identity's AdministrativeUnit.Read.All permission."
    }

    $response = $raw | ConvertFrom-Json
    $displayNameResult = [string]$response.displayName

    if ([string]::IsNullOrWhiteSpace($displayNameResult)) {
        throw "Administrative unit '$ObjectId' returned an empty displayName. Verify the object exists and the caller has AdministrativeUnit.Read.All."
    }

    $global:PurviewIdentifierCache[$cacheKey] = $displayNameResult
    Write-Verbose "Reverse-resolved administrative unit '$ObjectId' -> '$displayNameResult'"
    return $displayNameResult
}
