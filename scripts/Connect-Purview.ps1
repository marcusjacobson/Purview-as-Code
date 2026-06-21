<#
.SYNOPSIS
    Acquire access tokens for the Microsoft Purview control and data planes.

.DESCRIPTION
    Uses the Azure CLI token cache (works with OIDC federated login in GitHub Actions
    as well as `az login` locally). Emits a hashtable with both tokens and the
    canonical Atlas endpoint for the target account.

    References:
      https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane
      https://learn.microsoft.com/en-us/rest/api/purview/

.PARAMETER AccountName
    Name of the Purview account (control plane resource name).

.EXAMPLE
    $ctx = ./scripts/Connect-Purview.ps1 -AccountName purview-contoso-lab
    Invoke-RestMethod -Uri "$($ctx.Endpoint)/datamap/api/atlas/v2/types/typedefs" -Headers $ctx.DataHeaders
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AccountName
)

$ErrorActionPreference = 'Stop'

function Get-Token {
    param([string]$Resource)
    $raw = az account get-access-token --resource $Resource --only-show-errors -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to acquire token for $Resource. Run 'az login' or configure OIDC."
    }
    return ($raw | ConvertFrom-Json).accessToken
}

$dataToken = Get-Token -Resource 'https://purview.azure.net'
$armToken  = Get-Token -Resource 'https://management.azure.com'

[pscustomobject]@{
    AccountName = $AccountName
    Endpoint    = "https://$AccountName.purview.azure.com"
    DataHeaders = @{ Authorization = "Bearer $dataToken"; 'Content-Type' = 'application/json' }
    ArmHeaders  = @{ Authorization = "Bearer $armToken";  'Content-Type' = 'application/json' }
}
