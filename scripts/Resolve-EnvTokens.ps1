#Requires -Version 7.4
<#
.SYNOPSIS
    Substitute `${env:VAR}` tokens in YAML-derived strings against an
    explicit allow-list of environment variables.

.DESCRIPTION
    Helper used by data-plane reconcilers (Wave 4a-ii and later) that need
    to emit real tenant / subscription / resource IDs in payloads sent to
    Microsoft Purview, Microsoft Entra, or Azure Resource Manager — without
    those IDs being committed to source.

    Authoritative for the §Decision Category 2 contract in
    docs/adr/0023-identifier-resolution.md.

    Behaviour:
      * Replaces every `${env:VAR}` token whose `VAR` is on the allow-list
        below with the current value of `[Environment]::GetEnvironmentVariable(VAR)`.
      * Throws if a token references a variable that is not on the
        allow-list (defence against accidental exfiltration via typo, e.g.
        `${env:AZURE_CLIENT_SECRET}`).
      * Throws if a token's allow-listed variable is unset in the current
        process environment (defence against silent identifier collapse).
      * Returns the input unchanged when no tokens are present.
      * Operates recursively on hashtables and arrays via `-InputObject`
        so that an entire parsed-YAML object graph can be substituted in
        one call.

    Adding a new variable to the allow-list is an explicit PR amendment
    here AND in `docs/adr/0023-identifier-resolution.md` §Decision
    Category 2. Silent expansion is prohibited.

    References:
      Variables in GitHub Actions (the source of truth in CI):
        https://docs.github.com/en/actions/learn-github-actions/variables
      ADR 0023 (this script's contract):
        docs/adr/0023-identifier-resolution.md

.PARAMETER InputString
    A single string to substitute. Mutually exclusive with `-InputObject`.

.PARAMETER InputObject
    A hashtable, array, or scalar (typically the output of `ConvertFrom-Yaml`)
    to substitute recursively. Mutually exclusive with `-InputString`.

.EXAMPLE
    $resolved = ./scripts/Resolve-EnvTokens.ps1 -InputString `
        '/subscriptions/${env:AZURE_SUBSCRIPTION_ID}/resourceGroups/${env:PURVIEW_RG}'

.EXAMPLE
    $desired = Get-Content data-plane/scans/scans.yaml -Raw | ConvertFrom-Yaml
    $resolved = ./scripts/Resolve-EnvTokens.ps1 -InputObject $desired
#>
[CmdletBinding(DefaultParameterSetName = 'String')]
param(
    [Parameter(ParameterSetName = 'String', Mandatory = $true, Position = 0)]
    [AllowEmptyString()]
    [string]$InputString,

    [Parameter(ParameterSetName = 'Object', Mandatory = $true)]
    [AllowNull()]
    $InputObject
)

$ErrorActionPreference = 'Stop'

# Allow-list of environment variables that ${env:VAR} tokens may resolve.
# Adding to this list requires a paired update to docs/adr/0023-identifier-resolution.md §Decision Category 2.
$script:AllowedVariables = @(
    'AZURE_TENANT_ID',
    'AZURE_SUBSCRIPTION_ID',
    'PURVIEW_ACCOUNT_NAME',
    'PURVIEW_RG',
    'DATABRICKS_METASTORE_ID'
)

$script:TokenPattern = [regex]'\$\{env:([A-Z0-9_]+)\}'

function Resolve-StringToken {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return $Value
    }

    return $script:TokenPattern.Replace($Value, {
        param($match)
        $varName = $match.Groups[1].Value

        if ($script:AllowedVariables -notcontains $varName) {
            throw "Token '`${env:$varName}' references a variable not on the ADR 0023 allow-list. Allowed: $($script:AllowedVariables -join ', '). To extend the allow-list, amend scripts/Resolve-EnvTokens.ps1 and docs/adr/0023-identifier-resolution.md."
        }

        $envValue = [Environment]::GetEnvironmentVariable($varName)
        if ([string]::IsNullOrEmpty($envValue)) {
            throw "Token '`${env:$varName}' is allow-listed but the environment variable is unset. Set it in the GitHub environment (CI) or export it in the local shell (interactive)."
        }

        return $envValue
    })
}

function Resolve-ObjectToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return Resolve-StringToken -Value $Value
    }

    # Treat hashtables and ordered dictionaries as key/value bags.
    if ($Value -is [System.Collections.IDictionary]) {
        $clone = @{}
        foreach ($key in $Value.Keys) {
            $clone[$key] = Resolve-ObjectToken -Value $Value[$key]
        }
        return $clone
    }

    # Arrays / generic enumerables (but not strings, handled above).
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $result = @()
        foreach ($item in $Value) {
            $result += , (Resolve-ObjectToken -Value $item)
        }
        return , $result
    }

    # Scalar non-string (bool, int, etc.) — return as-is.
    return $Value
}

if ($PSCmdlet.ParameterSetName -eq 'String') {
    return Resolve-StringToken -Value $InputString
}

return Resolve-ObjectToken -Value $InputObject

