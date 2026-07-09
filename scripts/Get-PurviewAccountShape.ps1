#Requires -Version 7.4
<#
.SYNOPSIS
    Detect whether a Microsoft Purview account exposes the classic Data Map host,
    the unified data plane, both, or neither.

.DESCRIPTION
    Read-only helper for ADR 0047 item 10(d). The script probes both supported
    data-plane shapes and combines the signals into a single routing
    classification:

    - Classic: the account answers on the classic Atlas Data Map host.
    - Unified: the tenant-scoped unified data-plane endpoint answers while the
      classic host does not.
    - Ambiguous: both probes succeed. This is legitimate and must not be
      treated as an error.
    - Indeterminate: neither probe proves a route, or auth / transient errors
      prevent a conclusion. Fail closed; never silently assume Classic.

    The classic-side probe reuses the existing Atlas host pattern documented in
    scripts/Connect-Purview.ps1 and Microsoft Learn's Data Map REST reference:
    https://{account}.purview.azure.com/datamap/api/atlas/v2/types/typedefs

    The unified-side probe reuses the tenant-scoped businessdomains enumerate
    call ratified by ADR 0048's 2026-07-08 addendum:
    https://api.purview-service.microsoft.com/datagovernance/catalog/businessdomains?api-version=2026-03-20-preview

    This script never writes. It performs one GET per side, never prints a
    bearer token, and redacts Azure CLI stderr by discarding it at the token-
    acquisition boundary.

.PARAMETER AccountName
    Optional. Purview account name to probe. When omitted, the script resolves
    purviewAccountName from -ParametersFile per the ADR 0012 contract used by
    the Deploy-*.ps1 scripts.

.PARAMETER ParametersFile
    Optional. Parameters file that supplies purviewAccountName when -AccountName
    is omitted. Defaults to infra/parameters/lab.yaml resolved relative to the
    repo root. The file must exist, parse as YAML, and contain the required
    purviewAccountName key.

.PARAMETER SubscriptionId
    Optional. Subscription context to use for az account get-access-token. When
    omitted, Azure CLI uses its current default account context.

.EXAMPLE
    ./scripts/Get-PurviewAccountShape.ps1 -AccountName purview-contoso-lab

    Probe the named account and return one object with Shape,
    ClassicProbeResult, UnifiedProbeResult, and Note.

.EXAMPLE
    ./scripts/Get-PurviewAccountShape.ps1 -ParametersFile .\infra\parameters\lab.yaml

    Resolve purviewAccountName from the parameters file, then run the same
    read-only account-shape detection.

.OUTPUTS
    [pscustomobject] with properties: AccountName, Shape, ClassicProbeResult,
    UnifiedProbeResult, Note.

.NOTES
    References:
      API authentication for Microsoft Purview data planes:
        https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      Type - List (classic Data Map typedefs probe):
        https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type/list?view=rest-purview-datamapdataplane-2023-09-01
      Business Domain - Enumerate (unified probe):
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview
      ADR 0047:
        docs/adr/0047-unified-catalog-preview-api-coexistence.md
      ADR 0048:
        docs/adr/0048-purview-account-discovery-gate.md
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,62}[A-Za-z0-9]$')]
    [Alias('PurviewAccountName')]
    [string]$AccountName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Get-PurviewAccessToken {
    <#
        Acquire a Microsoft Entra ID token through Azure CLI without ever
        writing the token or az stderr to the console.
        Reference: https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Resource,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $azArgs = @(
        'account', 'get-access-token',
        '--resource', $Resource,
        '--only-show-errors',
        '--output', 'json'
    )
    if ($SubscriptionId) {
        $azArgs += @('--subscription', $SubscriptionId)
    }

    $raw = & az @azArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        $token = ($raw | ConvertFrom-Json).accessToken
    } catch {
        $token = $null
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        return $null
    }

    return $token
}

function Invoke-PurviewClassicCatalogProbe {
    <#
        Probe the classic Atlas Data Map host with one lightweight GET.
        Reference: https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type/list?view=rest-purview-datamapdataplane-2023-09-01
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AccountName,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $token = Get-PurviewAccessToken -Resource 'https://purview.azure.net' -SubscriptionId $SubscriptionId
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{
            TokenAcquired = $false
            Succeeded     = $false
            StatusCode    = $null
            TransportError = $false
        }
    }

    $uri = "https://$AccountName.purview.azure.com/datamap/api/atlas/v2/types/typedefs?api-version=2023-09-01"

    try {
        $headers = @{
            Authorization = "Bearer $token"
            'Content-Type' = 'application/json'
        }
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        return [pscustomobject]@{
            TokenAcquired = $true
            Succeeded     = $true
            StatusCode    = 200
            TransportError = $false
        }
    } catch {
        $statusCode = $null
        $transportError = $false
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        } else {
            $transportError = $true
        }

        return [pscustomobject]@{
            TokenAcquired = $true
            Succeeded     = $false
            StatusCode    = $statusCode
            TransportError = $transportError
        }
    } finally {
        $token = $null
        $headers = $null
    }
}

function Invoke-PurviewUnifiedCatalogProbe {
    <#
        Probe the tenant-scoped Unified Catalog preview endpoint with one GET.
        Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $token = Get-PurviewAccessToken -Resource 'https://purview.azure.net' -SubscriptionId $SubscriptionId
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{
            TokenAcquired = $false
            Succeeded     = $false
            StatusCode    = $null
            TransportError = $false
        }
    }

    $endpoint = 'https://api.purview-service.microsoft.com'
    $apiVersion = '2026-03-20-preview'
    # api-version justification: Unified Catalog data-plane API is preview-only as of 2026-07-08.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate?view=rest-purview-purview-unified-catalog-2026-03-20-preview
    $uri = "$endpoint/datagovernance/catalog/businessdomains?api-version=$apiVersion"

    try {
        $headers = @{
            Authorization = "Bearer $token"
            'Content-Type' = 'application/json'
        }
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        return [pscustomobject]@{
            TokenAcquired = $true
            Succeeded     = $true
            StatusCode    = 200
            TransportError = $false
        }
    } catch {
        $statusCode = $null
        $transportError = $false
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        } else {
            $transportError = $true
        }

        return [pscustomobject]@{
            TokenAcquired = $true
            Succeeded     = $false
            StatusCode    = $statusCode
            TransportError = $transportError
        }
    } finally {
        $token = $null
        $headers = $null
    }
}

function Get-PurviewProbeResult {
    <#
        Pure helper: classify one probe outcome without making any az or HTTP
        calls. Mirrors the Get-PurviewUnifiedCatalogClassification split used by
        scripts/Find-PurviewAccount.ps1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Classic', 'Unified')]
        [string]$Plane,

        [Parameter(Mandatory = $true)]
        [bool]$TokenAcquired,

        [Parameter()]
        [bool]$Succeeded,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]]$StatusCode,

        [Parameter()]
        [bool]$TransportError
    )

    if (-not $TokenAcquired) {
        return '{0}ProbeSkipped' -f $Plane
    }

    if ($Succeeded -and $StatusCode -eq 200) {
        return '{0}Reachable' -f $Plane
    }

    if ($null -ne $StatusCode -and ($StatusCode -eq 401 -or $StatusCode -eq 403)) {
        return '{0}Unauthorized' -f $Plane
    }

    if ($null -ne $StatusCode -and ($StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599))) {
        return '{0}Indeterminate' -f $Plane
    }

    if ($TransportError -or $null -eq $StatusCode) {
        return '{0}Unreachable' -f $Plane
    }

    return '{0}Unreachable' -f $Plane
}

function Get-PurviewAccountShapeClassification {
    <#
        Pure account-routing classifier. Combines classic and unified probe
        signals into the final Shape plus human-readable diagnostics.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ClassicTokenAcquired,

        [Parameter()]
        [bool]$ClassicSucceeded,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]]$ClassicStatusCode,

        [Parameter()]
        [bool]$ClassicTransportError,

        [Parameter(Mandatory = $true)]
        [bool]$UnifiedTokenAcquired,

        [Parameter()]
        [bool]$UnifiedSucceeded,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]]$UnifiedStatusCode,

        [Parameter()]
        [bool]$UnifiedTransportError
    )

    $classicProbeResult = Get-PurviewProbeResult `
        -Plane 'Classic' `
        -TokenAcquired $ClassicTokenAcquired `
        -Succeeded $ClassicSucceeded `
        -StatusCode $ClassicStatusCode `
        -TransportError $ClassicTransportError

    $unifiedProbeResult = Get-PurviewProbeResult `
        -Plane 'Unified' `
        -TokenAcquired $UnifiedTokenAcquired `
        -Succeeded $UnifiedSucceeded `
        -StatusCode $UnifiedStatusCode `
        -TransportError $UnifiedTransportError

    $notePrefix = "Classic probe: $classicProbeResult. Unified probe: $unifiedProbeResult."

    if ($classicProbeResult -eq 'ClassicReachable' -and $unifiedProbeResult -eq 'UnifiedUnreachable') {
        return [pscustomobject]@{
            Shape              = 'Classic'
            ClassicProbeResult = $classicProbeResult
            UnifiedProbeResult = $unifiedProbeResult
            Note               = "$notePrefix The Atlas typedefs probe returned HTTP 200 from the account-scoped classic host while the tenant-scoped Unified Catalog probe did not. Route to the classic Data Map reconcilers."
        }
    }

    if ($classicProbeResult -eq 'ClassicUnreachable' -and $unifiedProbeResult -eq 'UnifiedReachable') {
        return [pscustomobject]@{
            Shape              = 'Unified'
            ClassicProbeResult = $classicProbeResult
            UnifiedProbeResult = $unifiedProbeResult
            Note               = "$notePrefix The tenant-scoped Unified Catalog businessdomains probe returned HTTP 200 while the classic Atlas host did not. Route to the Unified Catalog reconcilers."
        }
    }

    if ($classicProbeResult -eq 'ClassicReachable' -and $unifiedProbeResult -eq 'UnifiedReachable') {
        return [pscustomobject]@{
            Shape              = 'Ambiguous'
            ClassicProbeResult = $classicProbeResult
            UnifiedProbeResult = $unifiedProbeResult
            Note               = "$notePrefix Both probes succeeded. This can legitimately happen and must not be treated as an error, but the caller must not guess a route."
        }
    }

    return [pscustomobject]@{
        Shape              = 'Indeterminate'
        ClassicProbeResult = $classicProbeResult
        UnifiedProbeResult = $unifiedProbeResult
        Note               = "$notePrefix Fail closed: neither probe produced an exclusive success signal, or auth / transient errors prevented a conclusion. Never silently assume Classic or Unified."
    }
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

$classicProbe = Invoke-PurviewClassicCatalogProbe -AccountName $AccountName -SubscriptionId $SubscriptionId
$unifiedProbe = Invoke-PurviewUnifiedCatalogProbe -SubscriptionId $SubscriptionId
$classification = Get-PurviewAccountShapeClassification `
    -ClassicTokenAcquired $classicProbe.TokenAcquired `
    -ClassicSucceeded $classicProbe.Succeeded `
    -ClassicStatusCode $classicProbe.StatusCode `
    -ClassicTransportError $classicProbe.TransportError `
    -UnifiedTokenAcquired $unifiedProbe.TokenAcquired `
    -UnifiedSucceeded $unifiedProbe.Succeeded `
    -UnifiedStatusCode $unifiedProbe.StatusCode `
    -UnifiedTransportError $unifiedProbe.TransportError

[pscustomobject]@{
    AccountName        = $AccountName
    Shape              = $classification.Shape
    ClassicProbeResult = $classification.ClassicProbeResult
    UnifiedProbeResult = $classification.UnifiedProbeResult
    Note               = $classification.Note
}

