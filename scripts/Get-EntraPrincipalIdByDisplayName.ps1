#Requires -Version 7.4
<#
.SYNOPSIS
    Resolve a Microsoft Entra principal display name to its `objectId`.

.DESCRIPTION
    Helper used by data-plane reconcilers (Wave 4a-ii and later) that bind
    catalog content to real Entra principals. The reconciler stores the
    semantic `displayName` in YAML (committable, non-secret); this script
    resolves it to an `objectId` at deploy time via Microsoft Graph.

    Authoritative for the §Decision Category 3 contract in
    docs/adr/0023-identifier-resolution.md.

    Fail-fast on:
      * Graph returns zero matches (the principal does not exist).
      * Graph returns more than one match (display name is not unique).
      * Graph call errors out (transport or auth failure).

    The result of a successful lookup is cached for the lifetime of the
    PowerShell session in a global hashtable
    `$global:PurviewIdentifierCache` keyed by `($Kind, $DisplayName)`.
    The cache is intentionally per-session and not persisted to disk so
    that every fresh reconciler run re-validates against the live
    directory.

    References:
      Microsoft Graph - Get groups (filter by displayName):
        https://learn.microsoft.com/en-us/graph/api/group-list
      Microsoft Graph - List users:
        https://learn.microsoft.com/en-us/graph/api/user-list
      Microsoft Graph - List servicePrincipals:
        https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list
      Azure CLI - az rest (Graph passthrough):
        https://learn.microsoft.com/en-us/cli/azure/reference-index#az-rest
      ADR 0023 (this script's contract):
        docs/adr/0023-identifier-resolution.md

.PARAMETER DisplayName
    The exact `displayName` of the Entra principal to resolve. Case-
    insensitive on the Graph side, but the cache key preserves the caller's
    casing for diagnostic clarity.

.PARAMETER Kind
    The principal kind. One of `Group` (default), `User`, or
    `ServicePrincipal`. Determines which Graph collection is queried.

.PARAMETER ApiVersion
    Microsoft Graph API version segment. Defaults to `v1.0`. Use `beta`
    only when a v1.0 endpoint genuinely cannot serve the lookup; add an
    inline comment justifying the choice.

.PARAMETER NoCache
    Bypass the session cache. Forces a fresh Graph lookup. Use only in
    tests or when the lab owner has just recreated the principal in the
    same shell session.

.EXAMPLE
    $id = ./scripts/Get-EntraPrincipalIdByDisplayName.ps1 `
        -DisplayName 'sg-purview-devops-sql-readers'

.EXAMPLE
    $id = ./scripts/Get-EntraPrincipalIdByDisplayName.ps1 `
        -DisplayName 'svc-purview-scanner' -Kind ServicePrincipal
#>
[CmdletBinding()]
[OutputType([string])]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars', '',
    Justification = 'Global $PurviewIdentifierCache is the documented cross-invocation cache surface per ADR 0023; session-scoped, never persisted, and contains only non-secret object IDs.')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter()]
    [ValidateSet('Group', 'User', 'ServicePrincipal')]
    [string]$Kind = 'Group',

    [Parameter()]
    [ValidateSet('v1.0', 'beta')]
    [string]$ApiVersion = 'v1.0',

    [Parameter()]
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

# Initialize the session-scope cache on first use.
if (-not (Get-Variable -Name 'PurviewIdentifierCache' -Scope Global -ErrorAction SilentlyContinue)) {
    $global:PurviewIdentifierCache = @{}
}

function Resolve-EntraPrincipalId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,

        [Parameter()]
        [ValidateSet('Group', 'User', 'ServicePrincipal')]
        [string]$Kind = 'Group',

        [Parameter()]
        [ValidateSet('v1.0', 'beta')]
        [string]$ApiVersion = 'v1.0'
    )

    # Endpoint segment per Graph collection.
    # Reference: https://learn.microsoft.com/en-us/graph/api/group-list (and sibling pages cited in script header).
    $collection = switch ($Kind) {
        'Group'            { 'groups' }
        'User'             { 'users' }
        'ServicePrincipal' { 'servicePrincipals' }
    }

    # Escape a single quote in the display name per OData filter rules: '' inside the literal.
    # Reference: https://learn.microsoft.com/en-us/graph/query-parameters#filter-parameter
    $escaped = $DisplayName.Replace("'", "''")
    $filter  = "displayName eq '$escaped'"
    $select  = 'id,displayName'

    $uri = "https://graph.microsoft.com/$ApiVersion/$($collection)?`$filter=$filter&`$select=$select"

    Write-Verbose "Resolving $Kind '$DisplayName' via $uri"

    # Reference: https://learn.microsoft.com/en-us/cli/azure/reference-index#az-rest
    $raw = az rest --method GET --uri $uri --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Microsoft Graph lookup for $Kind '$DisplayName' failed. Run 'az login' or check the automation identity's Graph permissions (Group.Read.All / User.Read.All / Application.Read.All)."
    }

    $response = $raw | ConvertFrom-Json
    $matched  = @($response.value)

    if ($matched.Count -eq 0) {
        throw "No $Kind found in Microsoft Entra with displayName '$DisplayName'. Create the principal or fix the YAML."
    }

    if ($matched.Count -gt 1) {
        $ids = ($matched | ForEach-Object { $_.id }) -join ', '
        throw "Multiple ${Kind}s found in Microsoft Entra with displayName '$DisplayName' (objectIds: $ids). Display name must be unique for ADR 0023 resolution to succeed."
    }

    return $matched[0].id
}

$cacheKey = "$Kind|$DisplayName"

if (-not $NoCache -and $global:PurviewIdentifierCache.ContainsKey($cacheKey)) {
    Write-Verbose "Cache hit for $cacheKey -> $($global:PurviewIdentifierCache[$cacheKey])"
    return $global:PurviewIdentifierCache[$cacheKey]
}

$objectId = Resolve-EntraPrincipalId -DisplayName $DisplayName -Kind $Kind -ApiVersion $ApiVersion

# Cache and return.
$global:PurviewIdentifierCache[$cacheKey] = $objectId
return $objectId

