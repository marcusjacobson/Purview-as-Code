#Requires -Version 7.4
<#
.SYNOPSIS
    Discover Microsoft.Purview/accounts resources across every visible Azure
    subscription and surface them for owner confirmation.

.DESCRIPTION
    Read-only discovery helper for the account discovery-and-confirmation gate
    ratified by docs/adr/0048-purview-account-discovery-gate.md. It enumerates
    the subscriptions the signed-in identity can see, then lists every
    `Microsoft.Purview/accounts` resource in each, and returns one structured
    object per hit (name, resource group, region, sku, subscription) plus a
    classification field.

    This script never writes, never deploys, and exposes no `-Force` /
    `-PruneMissing` surface. It is the shared implementation intended to be
    called by `@operator-tenant` (tailoring-time) and by a
    `/discover-purview-account` prompt (deploy-time) so both consume one code
    path instead of duplicating `az` logic.

    Classification is deliberately conservative. Microsoft Learn documents no
    property under `Microsoft.Purview/accounts` that reliably distinguishes a
    governance account from a pay-as-you-go metering resource, and no
    programmatic procedure for detecting whether an account exposes the classic
    Data Map data plane or the unified data plane (ADR 0048 §Decision items 3
    and 5). Every hit is therefore returned with a `Classification` of
    `RequiresOwnerConfirmation`; this script does not invent a heuristic to
    decide governance-vs-metering or classic-vs-unified.

    "Not found in ARM" is a first-class, non-error result: when no account is
    discovered (or none matches `-Name`), the script emits an informational
    message and returns an empty array, so the caller can drive the ADR 0048
    branch (tenant-level Unified Catalog at purview.microsoft.com / a classic
    account in another subscription or tenant the sign-in can't see / not yet
    created).

    When ARM enumeration finds nothing, an operator can additionally pass
    `-ProbeUnifiedCatalog` to run a read-only, opt-in reachability check
    against the Unified Catalog preview data plane (a single GET against the
    tenant-scoped `businessdomains` enumerate endpoint). An HTTP 200 confirms
    the tenant exposes a reachable unified data plane — a diagnostic signal
    for ADR 0048 §Decision item 4 scenario (a), NOT proof that any specific
    account is unified, NOT proof that no classic account exists elsewhere,
    and NOT the ADR 0047 reconcile-time routing decision. The probe is
    OFF by default and never changes the ARM-only discovery path's behavior.

    References:
      Azure CLI - az account list:
        https://learn.microsoft.com/en-us/cli/azure/account#az-account-list
      Azure CLI - az resource list:
        https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-list
      Microsoft.Purview/accounts (ARM schema):
        https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts
      Learn about data governance with Microsoft Purview:
        https://learn.microsoft.com/en-us/purview/data-governance-overview
      Business Domain - Enumerate (Unified Catalog preview data plane):
        https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate
      ADR 0048 (this script's contract):
        docs/adr/0048-purview-account-discovery-gate.md

.PARAMETER Name
    Optional. Filter the results to the account whose name matches (case-
    insensitive). Use this to check whether a candidate `purviewAccountName`
    (for example the value in infra/parameters/lab.yaml) actually resolves to a
    discoverable account. When no discovered account matches, the script
    returns an empty array — the ADR 0048 "unconfirmed target" signal.

.PARAMETER SubscriptionId
    Optional. Limit enumeration to the given subscription IDs. When omitted,
    every subscription the signed-in identity can see is enumerated.

.PARAMETER IncludeSubscriptionId
    Optional. Emit the real subscription ID in each result's SubscriptionId
    property for programmatic targeting (for example, a downstream
    `az account set`). OFF by default: without this switch, SubscriptionId is
    redacted to the zero-GUID placeholder so discovery output is safe to paste
    into chat, a PR, or a doc. Use SubscriptionName (never a GUID) to confirm
    the target with the owner. When this switch is set, the caller owns the
    redaction obligation before echoing the value anywhere.

.PARAMETER ProbeUnifiedCatalog
    Optional. OFF by default — no change to the existing ARM-only path. When
    set, and only after ARM enumeration finds no Microsoft.Purview/accounts
    resource (across every visible subscription, ignoring -Name and
    -SubscriptionId), runs a single read-only GET against the Unified Catalog
    preview data-plane tenant-scoped `businessdomains` enumerate endpoint
    (https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate).
    An HTTP 200 means the tenant exposes a reachable unified data plane — a
    diagnostic reachability signal for ADR 0048 §Decision item 4 scenario (a),
    not proof that a specific account is unified, not proof that no classic
    account exists, and not the ADR 0047 reconcile-time routing decision. The
    result is emitted as a single diagnostic object whose Name is the literal
    string 'unified-catalog (tenant default)'; this value must never be
    written to `purviewAccountName`. Never prints the bearer token; redacts
    `az` stderr.

.OUTPUTS
    [pscustomobject] with properties: Name, ResourceGroup, Location, Sku,
    SubscriptionName, SubscriptionId, Classification, Note. Zero objects are
    emitted when nothing is discovered and -ProbeUnifiedCatalog is not set.
    SubscriptionId is the zero-GUID placeholder unless -IncludeSubscriptionId
    is set. When -ProbeUnifiedCatalog is set and ARM enumeration finds
    nothing, a single diagnostic object is emitted instead of an empty array;
    its Classification is one of UnifiedCatalogTenantReachable,
    UnifiedCatalogUnauthorized, UnifiedCatalogProbeIndeterminate,
    UnifiedCatalogUnreachable, or UnifiedCatalogProbeSkipped.

.NOTES
    Identifier redaction: per ADR 0048 §Decision item 2 and the "Environment
    and identifier boundaries" section of .github/copilot-instructions.md, real
    subscription/tenant/resource IDs must not be echoed into chat or written to
    a file. This script is safe-by-default: the SubscriptionId property is the
    zero-GUID placeholder, and no informational, verbose, or error message ever
    prints a real subscription ID. Pass -IncludeSubscriptionId only when a
    caller needs the real value for programmatic targeting, and redact it before
    surfacing it anywhere a human will read it.

.EXAMPLE
    ./scripts/Find-PurviewAccount.ps1

    Enumerate every Microsoft.Purview/accounts resource across all visible
    subscriptions and return them for owner confirmation.

.EXAMPLE
    ./scripts/Find-PurviewAccount.ps1 -Name 'purview-contoso-lab'

    Check whether the candidate account name resolves to a discoverable
    account. An empty result means the name does not resolve in ARM.

.EXAMPLE
    ./scripts/Find-PurviewAccount.ps1 -ProbeUnifiedCatalog

    When no Microsoft.Purview/accounts resource is discovered in ARM, also run
    the opt-in, read-only Unified Catalog tenant-reachability probe and return
    its diagnostic classification instead of an empty array.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [switch]$IncludeSubscriptionId,

    [Parameter()]
    [switch]$ProbeUnifiedCatalog
)

$ErrorActionPreference = 'Stop'

# Zero-GUID placeholder used for redacted logging per the "Environment and
# identifier boundaries" section of .github/copilot-instructions.md.
$script:ZeroGuid = '00000000-0000-0000-0000-000000000000'

function Get-PurviewVisibleSubscription {
    <#
        Enumerate the subscriptions the signed-in identity can see.
        Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $raw = az account list --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "az account list failed. Run 'az login', then retry. Discovery cannot enumerate subscriptions without a signed-in identity."
    }

    $subscriptions = @(($raw | ConvertFrom-Json))
    foreach ($sub in $subscriptions) {
        [pscustomobject]@{
            Id       = $sub.id
            Name     = $sub.name
            TenantId = $sub.tenantId
            State    = $sub.state
        }
    }
}

function Get-PurviewAccountResource {
    <#
        List every Microsoft.Purview/accounts resource in one subscription.
        Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $raw = az resource list `
        --resource-type 'Microsoft.Purview/accounts' `
        --subscription $SubscriptionId `
        --output json `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "az resource list failed for subscription id (redacted: $script:ZeroGuid). Discovery is incomplete — this is not a 'not found in ARM' result. Confirm the signed-in identity can read resources in that subscription (Reader or above), then retry."
    }

    @(($raw | ConvertFrom-Json))
}

function Invoke-PurviewUnifiedCatalogProbe {
    <#
        Opt-in, read-only reachability probe against the Unified Catalog
        preview data plane. Runs one GET, tenant-scoped (ignores -Name and
        -SubscriptionId — there is no {account} segment; the tenant in the
        bearer token selects the account per Learn's URI parameter table).
        Never writes, never prints the token, redacts az stderr.

        # api-version justification: Unified Catalog data-plane API is
        # preview-only as of 2026-07-06 (ADR 0047 §Decision item 4). Pinned to
        # the single latest preview version for this endpoint family.
        Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $apiVersion = '2026-03-20-preview'
    $endpoint = 'https://api.purview-service.microsoft.com'
    $uri = "$endpoint/datagovernance/catalog/businessdomains?api-version=$apiVersion"

    $tokenRaw = az account get-access-token --resource 'https://purview.azure.net' --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenRaw)) {
        return [pscustomobject]@{ TokenAcquired = $false; Succeeded = $false; StatusCode = $null }
    }

    $token = $null
    try {
        $token = ($tokenRaw | ConvertFrom-Json).accessToken
    } catch {
        $token = $null
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [pscustomobject]@{ TokenAcquired = $false; Succeeded = $false; StatusCode = $null }
    }

    try {
        $headers = @{ Authorization = "Bearer $token" }
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        return [pscustomobject]@{ TokenAcquired = $true; Succeeded = $true; StatusCode = 200 }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        return [pscustomobject]@{ TokenAcquired = $true; Succeeded = $false; StatusCode = $statusCode }
    } finally {
        # Never leave the token resident longer than needed; never print it.
        $token = $null
        $headers = $null
    }
}

function Get-PurviewUnifiedCatalogClassification {
    <#
        Pure classification function for the opt-in Unified Catalog
        tenant-reachability probe. No az call, no HTTP — unit-testable
        without a tenant. Deliberately conservative: an HTTP 200 is a
        tenant-level diagnostic reachability signal only. It is NOT proof
        that a specific account is unified, NOT proof that no classic
        account exists elsewhere, and NOT the ADR 0047 reconcile-time
        routing decision.
        Reference: https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$TokenAcquired,

        [Parameter()]
        [bool]$Succeeded,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]]$StatusCode
    )

    if (-not $TokenAcquired) {
        return 'UnifiedCatalogProbeSkipped'
    }

    if ($Succeeded -and $StatusCode -eq 200) {
        return 'UnifiedCatalogTenantReachable'
    }

    if ($null -ne $StatusCode -and ($StatusCode -eq 401 -or $StatusCode -eq 403)) {
        return 'UnifiedCatalogUnauthorized'
    }

    if ($null -ne $StatusCode -and ($StatusCode -eq 429 -or ($StatusCode -ge 500 -and $StatusCode -le 599))) {
        return 'UnifiedCatalogProbeIndeterminate'
    }

    return 'UnifiedCatalogUnreachable'
}

function ConvertTo-PurviewUnifiedCatalogDiagnostic {
    <#
        Pure shaping function: map a probe classification to the same result
        surface ConvertTo-PurviewAccountResult emits, so callers can treat the
        diagnostic object like any other discovery hit. No az call, no HTTP —
        unit-testable without a tenant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'UnifiedCatalogTenantReachable',
            'UnifiedCatalogUnauthorized',
            'UnifiedCatalogProbeIndeterminate',
            'UnifiedCatalogUnreachable',
            'UnifiedCatalogProbeSkipped'
        )]
        [string]$Classification
    )

    $note = switch ($Classification) {
        'UnifiedCatalogTenantReachable' {
            'The tenant exposes a reachable Unified Catalog data plane (HTTP 200 from the businessdomains enumerate endpoint). This is a diagnostic reachability signal only (ADR 0048 §Decision item 4 scenario (a)) — it is NOT proof that a specific account is unified, NOT proof that no classic account exists elsewhere, and NOT the ADR 0047 reconcile-time routing decision. This label must NEVER be written to purviewAccountName: classic Deploy-*.ps1 reconcilers cannot drive this plane, and unified reconcilers are the ADR 0047 follow-up.'
        }
        'UnifiedCatalogUnauthorized' {
            'The Unified Catalog data-plane endpoint responded, but the signed-in identity lacks consent or permission (401/403). This neither confirms nor rules out tenant reachability; confirm access with the owner before drawing any conclusion.'
        }
        'UnifiedCatalogProbeIndeterminate' {
            'The probe received a transient response (429 or 5xx). Retry before concluding anything about tenant reachability.'
        }
        'UnifiedCatalogUnreachable' {
            'The probe received no successful response and no recognized error status. This does not confirm the tenant lacks a Unified Catalog data plane — only that this probe could not reach it.'
        }
        'UnifiedCatalogProbeSkipped' {
            'No token was acquired for the probe (az account get-access-token failed or returned no token). The probe did not run; this is not a reachability signal.'
        }
    }

    [pscustomobject]@{
        Name             = 'unified-catalog (tenant default)'
        ResourceGroup    = $null
        Location         = $null
        Sku              = $null
        SubscriptionName = $null
        SubscriptionId   = $script:ZeroGuid
        Classification   = $Classification
        Note             = $note
    }
}

function ConvertTo-PurviewAccountResult {
    <#
        Pure shaping function: map raw az account objects to the discovery
        result surface with the ADR 0048 owner-confirmation classification.
        No az call, no side effects — unit-testable without a tenant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Account,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId,

        [Parameter()]
        [switch]$IncludeSubscriptionId
    )

    $note = 'Microsoft Learn documents no property that reliably distinguishes a governance account from a pay-as-you-go metering resource (ADR 0048); a metering resource is NOT a governance target. Confirm the target with the lab owner. Classic-vs-unified account type must also be owner-confirmed — Learn documents no programmatic detection procedure.'

    # Safe-by-default: redact the subscription ID unless the caller explicitly
    # opts in. Reference: ADR 0048 §Decision item 2.
    $emittedSubscriptionId = if ($IncludeSubscriptionId) { $SubscriptionId } else { $script:ZeroGuid }

    foreach ($account in $Account) {
        [pscustomobject]@{
            Name             = $account.name
            ResourceGroup    = $account.resourceGroup
            Location         = $account.location
            Sku              = if ($account.sku) { $account.sku.name } else { $null }
            SubscriptionName = $SubscriptionName
            SubscriptionId   = $emittedSubscriptionId
            Classification   = 'RequiresOwnerConfirmation'
            Note             = $note
        }
    }
}

# --- Orchestration ---------------------------------------------------------

function Get-PurviewAccountDiscovery {
    <#
        Enumerate, shape, filter, and surface Microsoft.Purview/accounts hits.
        Extracted from the top-level flow so it is unit-testable with the
        sibling getters stubbed (no `az`, no live tenant). Reference: ADR 0048.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string[]]$SubscriptionId,

        [Parameter()]
        [switch]$IncludeSubscriptionId,

        [Parameter()]
        [switch]$ProbeUnifiedCatalog
    )

    $subscriptions = @(Get-PurviewVisibleSubscription)

    if ($SubscriptionId) {
        $subscriptions = @($subscriptions | Where-Object { $SubscriptionId -contains $_.Id })
        if ($subscriptions.Count -eq 0) {
            throw "None of the requested subscription IDs are visible to the signed-in identity. Check the identity's access, or omit -SubscriptionId to enumerate all visible subscriptions."
        }
    }

    Write-Verbose "Enumerating Microsoft.Purview/accounts across $($subscriptions.Count) visible subscription(s)."

    $results = foreach ($sub in $subscriptions) {
        # Never log the subscription ID; redact per ADR 0048 §Decision item 2.
        Write-Verbose "Scanning subscription '$($sub.Name)' (id redacted: $script:ZeroGuid)."
        $accounts = @(Get-PurviewAccountResource -SubscriptionId $sub.Id)
        ConvertTo-PurviewAccountResult -Account $accounts -SubscriptionName $sub.Name -SubscriptionId $sub.Id -IncludeSubscriptionId:$IncludeSubscriptionId
    }

    $results = @($results)

    if ($Name) {
        $results = @($results | Where-Object { $_.Name -eq $Name })
    }

    if ($results.Count -eq 0) {
        $scope = if ($Name) { "matching name '$Name'" } else { 'in any visible subscription' }
        Write-Information "No Microsoft.Purview/accounts resource found $scope across $($subscriptions.Count) visible subscription(s). This is not an error (ADR 0048). The governance target may be: (a) the tenant-level Unified Catalog at purview.microsoft.com, which is not an ARM resource; (b) a classic account in a subscription or tenant this sign-in cannot see; or (c) not yet created. Confirm with the lab owner before writing purviewAccountName." -InformationAction Continue

        if ($ProbeUnifiedCatalog) {
            Write-Verbose 'Running opt-in Unified Catalog tenant-reachability probe (read-only; ignores -Name and -SubscriptionId).'
            $probe = Invoke-PurviewUnifiedCatalogProbe
            $classification = Get-PurviewUnifiedCatalogClassification -TokenAcquired $probe.TokenAcquired -Succeeded $probe.Succeeded -StatusCode $probe.StatusCode
            $diagnostic = ConvertTo-PurviewUnifiedCatalogDiagnostic -Classification $classification
            Write-Information "Unified Catalog tenant-reachability probe result: $classification. $($diagnostic.Note)" -InformationAction Continue
            return @($diagnostic)
        }

        return @()
    }

    Write-Information "Discovered $($results.Count) Microsoft.Purview/accounts resource(s). Each requires owner confirmation: a pay-as-you-go metering resource is NOT a governance target, and classic-vs-unified account type must be confirmed separately (ADR 0048)." -InformationAction Continue

    return $results
}

# --- Main flow -------------------------------------------------------------

$discoveryParams = @{
    IncludeSubscriptionId = [bool]$IncludeSubscriptionId
    ProbeUnifiedCatalog   = [bool]$ProbeUnifiedCatalog
}
if ($PSBoundParameters.ContainsKey('Name')) { $discoveryParams['Name'] = $Name }
if ($PSBoundParameters.ContainsKey('SubscriptionId')) { $discoveryParams['SubscriptionId'] = $SubscriptionId }

Get-PurviewAccountDiscovery @discoveryParams
