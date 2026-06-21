<#
.SYNOPSIS
    Grant (or revoke) Microsoft Purview data-plane roles to a principal at the
    lowest collection that works.

.DESCRIPTION
    Wave 0 / item #2 of docs/project-plan.md. This is the **Purview data-plane**
    sibling of infra/modules/rbac.bicep — the two surfaces are intentionally
    separate per the 3-plane disambiguation in that module's header:

      * Azure RBAC     -> infra/modules/rbac.bicep (control-plane ops on
                          Microsoft.Purview/accounts, Key Vault, storage, etc.).
      * Purview data   -> THIS SCRIPT. Catalog-plane roles that gate reading and
                          writing catalog metadata (collections, scans, assets).
      * Entra roles    -> scripts/Grant-M365ComplianceRoles.ps1 (Wave 0 item #3).

    Purview catalog roles live inside a metadata policy attached to a
    collection. A principal is "in" a role when its object ID is present in the
    `attributeValueIncludedIn` array of the matching attributeRule's
    dnfCondition. The script:

      1. GET  /policyStore/metadataPolicies?collectionName={name}   (one policy / collection)
      2. Locate the attributeRule for the target role.
      3. Check whether the principal is already present.
      4. Emit a NoChange / Create / Revoke row; act only if the caller opted in.
      5. PUT the full policy back (only on Create / Revoke, never on NoChange).

    Least-privilege scope: default is the caller-supplied collection (no
    magic root fallback — the caller must state their intent). Root is named
    after the account, so `-CollectionName $AccountName` grants at root.
    Prefer the lowest collection that works, per:
      https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#define-least-privilege-model
      https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions

    References:
      https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions
      https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/metadata-policy
      https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/metadata-roles/list
      https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

.PARAMETER AccountName
    Name of the Purview account (for example, purview-contoso-lab). The account
    host is `https://$AccountName.purview.azure.com`.

.PARAMETER PrincipalId
    Object ID (GUID) of the Entra principal (user, group, service principal,
    or managed identity). Validated against the standard GUID shape.

.PARAMETER Role
    One or more Purview metadata-policy roles to grant. Allowed values are the
    five roles exposed by the `/policyStore/metadataPolicies` surface:
    CollectionAdmin, DataSourceAdmin, DataCurator, PurviewReader,
    WorkflowAdministrator. Note: `PolicyAuthor` (DevOps policies) lives on
    `/policyStore/policies`, not on this surface; it is intentionally out of
    scope for this script and belongs to a future DevOps-policies item.
    Reference: https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions#roles

.PARAMETER CollectionName
    Collection at which to grant the role. Defaults to the root collection
    (root is named after the account). Callers should override this with the
    lowest collection that satisfies the workload.

.PARAMETER Revoke
    If set, remove the principal from each named role instead of adding it.
    Destructive. Required opt-in per the drift-report contract in
    .github/instructions/powershell.instructions.md. Defaults to $false.

.EXAMPLE
    ./scripts/Grant-PurviewDataMapRole.ps1 `
        -AccountName purview-contoso-lab `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -Role DataCurator, DataSourceAdmin `
        -CollectionName enterprise-finance -WhatIf

    Drift report for two role grants at collection `enterprise-finance`,
    without making any change.

.EXAMPLE
    ./scripts/Grant-PurviewDataMapRole.ps1 `
        -AccountName purview-contoso-lab `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -Role DataCurator `
        -CollectionName purview-contoso-lab

    Grants Data Curator to the principal at the root collection (idempotent —
    a re-run is a NoChange).

.EXAMPLE
    ./scripts/Grant-PurviewDataMapRole.ps1 `
        -AccountName purview-contoso-lab `
        -PrincipalId 00000000-0000-0000-0000-000000000000 `
        -Role DataCurator `
        -CollectionName purview-contoso-lab `
        -Revoke

    Removes the principal from Data Curator at the root collection.

.NOTES
    Caller role requirement: the caller must hold Collection Administrator on
    the target collection (or a parent) to mutate its metadata policy.
    Reference: https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions#roles
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{1,48}[a-zA-Z0-9]$')]
    [string]$AccountName,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$PrincipalId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('CollectionAdmin', 'DataSourceAdmin', 'DataCurator', 'PurviewReader', 'WorkflowAdministrator')]
    [string[]]$Role,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CollectionName,

    [switch]$Revoke
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Role -> attributeRule-id slug map. Slugs are the published Purview built-in
# role names; the attributeRule id in a metadata policy has the shape
#   purviewmetadatarole_builtin_<slug>:<collectionName>
# Reference: https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions#roles
# ---------------------------------------------------------------------------
$script:RoleSlugMap = @{
    CollectionAdmin       = 'collection-administrator'
    DataSourceAdmin       = 'data-source-administrator'
    DataCurator           = 'data-curator'
    PurviewReader         = 'purview-reader'
    WorkflowAdministrator = 'workflow-administrator'
}

if (-not $CollectionName) {
    # Root collection is named after the account.
    # Reference: https://learn.microsoft.com/en-us/purview/reference-purview-glossary#collection
    $CollectionName = $AccountName
    Write-Information "CollectionName not provided; defaulting to root collection '$AccountName'." -InformationAction Continue
}

# ---------------------------------------------------------------------------
# Acquire a Purview data-plane token via Azure CLI. Works with OIDC federated
# login in GitHub Actions and with `az login` locally.
# Reference: https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-get-access-token
# ---------------------------------------------------------------------------
function Get-PurviewDataPlaneToken {
    $raw = az account get-access-token --resource 'https://purview.azure.net' --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire Purview data-plane token. Run 'az login' or configure OIDC."
    }
    return ($raw | ConvertFrom-Json).accessToken
}

$endpoint = "https://$AccountName.purview.azure.com"
$token    = Get-PurviewDataPlaneToken
$headers  = @{
    Authorization  = "Bearer $token"
    'Content-Type' = 'application/json'
}

# Pinned per .github/instructions/powershell.instructions.md "One version per
# endpoint family across the repo". 2021-07-01 is the GA version for the
# metadata-policy surface; the preview 2022-08-01 version is used only for the
# DevOps /policyStore/policies surface (see docs/architecture.md).
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/
$apiVersion = '2021-07-01'

# ---------------------------------------------------------------------------
# Fetch the metadata policy for the target collection. The collectionName
# query parameter filters server-side so the response contains at most one
# policy.
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/metadata-policy/list
# ---------------------------------------------------------------------------
$encodedCollection = [System.Uri]::EscapeDataString($CollectionName)
$listUri = "$endpoint/policyStore/metadataPolicies?collectionName=$encodedCollection&api-version=$apiVersion"
$listResponse = Invoke-RestMethod -Method Get -Uri $listUri -Headers $headers

if (-not $listResponse.values -or $listResponse.values.Count -eq 0) {
    throw "No metadata policy found for collection '$CollectionName' under account '$AccountName'. " +
          "Verify the collection exists and that the caller has Collection Administrator on it or a parent."
}

$policy     = $listResponse.values[0]
$policyId   = $policy.id     # GUID used on the PUT path.
$policyName = $policy.name   # Human-readable `policy_collection_<coll>`, used for logging only.

Write-Information "Loaded metadata policy '$policyName' (id=$policyId) for collection '$CollectionName'." -InformationAction Continue

# ---------------------------------------------------------------------------
# Build the drift report.
# Categories (subset of the full 5 in powershell.instructions.md — Orphan and
# Conflict do not apply to a parameter-driven grant):
#   Create   - role grant missing; will be added.
#   NoChange - role grant already present; nothing to do.
#   Revoke   - -Revoke set and grant present; will be removed.
#   NoOp     - -Revoke set and grant already absent; nothing to do.
# ---------------------------------------------------------------------------
$report = New-Object 'System.Collections.Generic.List[object]'
$mutated = $false

foreach ($r in $Role) {
    $slug    = $script:RoleSlugMap[$r]
    $ruleIdSuffix = ":$CollectionName"
    $ruleIdMarker = "_${slug}${ruleIdSuffix}"

    $rule = $policy.properties.attributeRules | Where-Object { $_.id -like "*$ruleIdMarker*" } | Select-Object -First 1

    if (-not $rule) {
        throw "attributeRule for role '$r' (slug '$slug') not found on collection '$CollectionName'. " +
              "The collection's metadata policy may be malformed; re-check in the Purview portal."
    }

    # Find the principal condition (attributeName = principal.microsoft.id) inside the rule's DNF.
    # Reference: https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/metadata-policy/update
    $principalCond = $null
    foreach ($condGroup in $rule.dnfCondition) {
        foreach ($cond in $condGroup) {
            if ($cond.attributeName -eq 'principal.microsoft.id') {
                $principalCond = $cond
                break
            }
        }
        if ($principalCond) { break }
    }

    if (-not $principalCond) {
        throw "attributeRule for role '$r' on collection '$CollectionName' has no principal.microsoft.id condition. " +
              "The policy shape is unexpected; do not attempt to mutate."
    }

    $existing = @($principalCond.attributeValueIncludedIn)
    $alreadyPresent = $existing -contains $PrincipalId

    if ($Revoke) {
        if ($alreadyPresent) {
            $report.Add([pscustomobject]@{
                Category = 'Revoke'
                Kind     = 'PurviewRoleGrant'
                Name     = "$r @ $CollectionName"
                Reason   = 'Principal present; -Revoke set.'
            })
            $principalCond.attributeValueIncludedIn = @($existing | Where-Object { $_ -ne $PrincipalId })
            $mutated = $true
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'NoOp'
                Kind     = 'PurviewRoleGrant'
                Name     = "$r @ $CollectionName"
                Reason   = 'Principal already absent.'
            })
        }
    }
    else {
        if ($alreadyPresent) {
            $report.Add([pscustomobject]@{
                Category = 'NoChange'
                Kind     = 'PurviewRoleGrant'
                Name     = "$r @ $CollectionName"
                Reason   = 'Principal already in role.'
            })
        }
        else {
            $report.Add([pscustomobject]@{
                Category = 'Create'
                Kind     = 'PurviewRoleGrant'
                Name     = "$r @ $CollectionName"
                Reason   = 'Principal missing from role; will be added.'
            })
            $principalCond.attributeValueIncludedIn = @($existing + $PrincipalId)
            $mutated = $true
        }
    }
}

# Emit the drift report via Write-Information so callers can capture to files
# or $GITHUB_STEP_SUMMARY per the drift-report contract.
$report | Sort-Object Category, Name | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

# ---------------------------------------------------------------------------
# Apply: one PUT per invocation if any change was computed. No PUT on NoChange
# / NoOp-only runs (idempotent).
# Reference: https://learn.microsoft.com/en-us/rest/api/purview/metadatapolicydataplane/metadata-policy/update
# ---------------------------------------------------------------------------
if ($mutated) {
    $putUri = "$endpoint/policyStore/metadataPolicies/$([System.Uri]::EscapeDataString($policyId))?api-version=$apiVersion"
    $body   = $policy | ConvertTo-Json -Depth 50 -Compress

    $action = if ($Revoke) { 'Revoke Purview role(s)' } else { 'Grant Purview role(s)' }
    if ($PSCmdlet.ShouldProcess("metadata policy '$policyName' (collection '$CollectionName')", $action)) {
        Invoke-RestMethod -Method Put -Uri $putUri -Headers $headers -Body $body | Out-Null
        Write-Information "Metadata policy updated for collection '$CollectionName'." -InformationAction Continue
    }
}
else {
    Write-Information "No changes required for collection '$CollectionName'." -InformationAction Continue
}

# Return the report so callers and tests can assert on it.
return $report
