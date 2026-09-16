#Requires -Version 7.4
<#
.SYNOPSIS
    Decide whether a Key Vault's public endpoint is already open.

.DESCRIPTION
    Extracted from `.github/actions/open-key-vault-firewall` so the predicate
    can be unit-tested. It shipped inert precisely because it could not be:
    the first version required `defaultAction -eq 'Allow'`, and this tenant's
    vault reads that property back as **`None`** once open, so the branch was
    dead code and every run in a fan-out claimed ownership of the window
    (issue #315, found on #314's own merge run).

    Observed read-backs of
    `{publicNetworkAccess, networkAcls.defaultAction}` on the dev vault:

      Disabled / Deny   -- steady state, locked
      Enabled  / None   -- after `az keyvault update --public-network-access
                           Enabled --default-action Allow`, on a vault with no
                           network rules configured

    `publicNetworkAccess` is the property that actually gates reachability, so
    it decides. `defaultAction` is informational EXCEPT when it is explicitly
    `Deny`: an `Enabled` vault whose ACL default is `Deny` still refuses
    traffic that no IP rule admits, so it is not treated as open.

    This is the second time in one day that an assumed read-back value made a
    filter silently inert -- see issue #307, where `Get-Label` reports
    `ContentType` as the literal `None` rather than empty. Check the value the
    service actually returns.

    Reference: https://learn.microsoft.com/en-us/azure/key-vault/general/network-security
    Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-show
#>

function Test-KeyVaultIsOpen {
    <#
    .SYNOPSIS
        True when the vault's public endpoint is reachable as-is.

    .PARAMETER PublicNetworkAccess
        `properties.publicNetworkAccess` -- 'Enabled' or 'Disabled'.

    .PARAMETER DefaultAction
        `properties.networkAcls.defaultAction` -- 'Allow', 'Deny', 'None', or
        empty. 'None' is what this tenant returns for an open vault with no
        network rules, and it must NOT be read as "not open".

    .EXAMPLE
        Test-KeyVaultIsOpen -PublicNetworkAccess 'Enabled' -DefaultAction 'None'   # True
        Test-KeyVaultIsOpen -PublicNetworkAccess 'Disabled' -DefaultAction 'Deny'  # False
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string] $PublicNetworkAccess,
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string] $DefaultAction
    )

    # No evidence is not evidence of openness. An unreadable posture must send
    # the caller down its fail-open path, not claim the vault is already open
    # and skip the open entirely.
    if ([string]::IsNullOrWhiteSpace($PublicNetworkAccess)) { return $false }

    if ($PublicNetworkAccess.Trim() -ine 'Enabled') { return $false }

    # Explicit Deny still blocks anything no IP rule admits, so an Enabled
    # vault with a Deny default is not open for our purposes.
    if ($DefaultAction -and $DefaultAction.Trim() -ieq 'Deny') { return $false }

    return $true
}

function ConvertFrom-KeyVaultPostureTsv {
    <#
    .SYNOPSIS
        Split the two-column TSV `az keyvault show --query ... -o tsv` returns.

    .DESCRIPTION
        Returns a hashtable with PublicNetworkAccess and DefaultAction, both
        possibly empty. Tolerates a tab, multiple spaces, a single column, or
        junk -- the caller's fail-open path handles the empty result, and a
        parser that throws here would turn a diagnostic into an outage.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string] $Tsv)

    $result = @{ PublicNetworkAccess = ''; DefaultAction = '' }
    if ([string]::IsNullOrWhiteSpace($Tsv)) { return $result }

    $parts = @($Tsv.Trim() -split '\s+' | Where-Object { $_ })
    if ($parts.Count -gt 0) { $result.PublicNetworkAccess = $parts[0] }
    if ($parts.Count -gt 1) { $result.DefaultAction = $parts[1] }
    return $result
}

Export-ModuleMember -Function Test-KeyVaultIsOpen, ConvertFrom-KeyVaultPostureTsv
