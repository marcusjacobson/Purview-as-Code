#Requires -Version 7.4
<#
.SYNOPSIS
    Shared az-context-vs-parameters-file tenant guard (issue #215; the #41 incident).

.DESCRIPTION
    Every `Deploy-*.ps1` reconciler, and both local drift-sync scripts, resolve
    their tenant and app identity from the Azure CLI (`az account show`,
    `az ad app list`) -- never from `-ParametersFile`. `-ParametersFile` only
    supplies `automation.tenantDomain`, which is passed to
    `Connect-IPPSSession -Organization`, and the *token's* tenant wins if the
    two disagree. Nothing checked that the `az` context and the parameters
    file actually agreed, so a stale or wrong `az` session could silently read
    or write the wrong tenant while every log line printed the *intended*
    environment (issue #215 -- a live false alarm during the second IRM
    end-to-end run, 2026-09-04, mistaken for a deleted tenant policy; the
    incident it is named for, #41, reached a merge before it was caught).

    A domain-to-domain string comparison is not sufficient on its own: the
    `az` CLI's default (often `*.onmicrosoft.com`) domain and the IPPS
    `automation.tenantDomain` can legitimately differ for the *same* tenant --
    true of this repo's own lab tenant. `Test-TenantDomainMatch` instead
    resolves the current `az` context's tenant ID to every domain ARM reports
    as verified for that tenant (`az rest .../tenants`) and checks membership,
    so a domain that merely looks different but genuinely belongs to the
    signed-in tenant is never a false failure.

    Extracted from `scripts/Invoke-LocalIrmDriftSync.ps1` and
    `scripts/Invoke-LocalDlpDriftSync.ps1`, which carried byte-identical
    copies of `Test-TenantDomainMatch` before this module existed.
    `Assert-TenantContextMatchesParametersFile` is new: a thin wrapper over it
    that both local-sync scripts and every `Deploy-*.ps1` reconciler can call
    from their existing "Azure context (read-only preamble)" region, once each
    has already resolved `$account` (from its own `az account show`) and the
    parameters file's declared `tenantDomain` / `environment`.

    Consumers:
      * `scripts/Invoke-LocalIrmDriftSync.ps1`
      * `scripts/Invoke-LocalDlpDriftSync.ps1`
      * every `scripts/Deploy-*.ps1` reconciler's Azure-context preamble

    Each consumer imports the module via:

        Import-Module (Join-Path $PSScriptRoot 'modules/TenantContextGuard.psm1') `
            -Force -Scope Local -ErrorAction Stop

    References:
      Issue #41  (the incident this guard is named for)
      Issue #215 (this extraction)
#>

function Test-TenantDomainMatch {
    <#
    .SYNOPSIS
        Returns $true if the current az context's tenant ID resolves (via
        the ARM /tenants list) to a tenant whose defaultDomain or domains[]
        contains ExpectedDomain, case-insensitively.

    .DESCRIPTION
        Pure over its inputs -- the caller is responsible for producing
        $Tenants from `az rest --url https://management.azure.com/tenants?api-version=2022-12-01`
        and $CurrentTenantId from `az account show`.

    .PARAMETER Tenants
        Array of objects (or hashtables) each with at least tenantId,
        defaultDomain, and domains (array of string).

    .PARAMETER CurrentTenantId
        The tenantId from `az account show`.

    .PARAMETER ExpectedDomain
        The parameters file's automation.tenantDomain value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Tenants,
        [Parameter(Mandatory = $true)][string]$CurrentTenantId,
        [Parameter(Mandatory = $true)][string]$ExpectedDomain
    )
    $match = $Tenants | Where-Object { [string]$_.tenantId -ieq $CurrentTenantId }
    if (-not $match) { return $false }
    foreach ($tenant in @($match)) {
        if ([string]$tenant.defaultDomain -ieq $ExpectedDomain) { return $true }
        foreach ($domain in @($tenant.domains)) {
            if ([string]$domain -ieq $ExpectedDomain) { return $true }
        }
    }
    return $false
}

function Test-TenantDomainEvidenceAvailable {
    <#
    .SYNOPSIS
        Returns $true if the ARM tenants list can actually speak to the
        current tenant's verified domains, so a domain comparison means
        something. Pure over its inputs, like Test-TenantDomainMatch.

    .DESCRIPTION
        The ARM /tenants endpoint enumerates tenants for the CALLER. A user
        principal gets defaultDomain + domains[]; a service principal (an
        OIDC-federated CI login) typically gets a list that omits its own
        tenant entirely, or carries the tenant with no domain fields.

        Without this distinction the caller cannot tell "the context is
        wrong" from "ARM declined to say", and treating the second as the
        first turns every service-principal run into a hard failure against
        a perfectly correct tenant. That is exactly what happened when the
        #215 guard first reached CI (issue #225 follow-up).

    .PARAMETER Tenants
        The .value array from the ARM tenants response.

    .PARAMETER CurrentTenantId
        The tenantId reported by `az account show`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Tenants,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CurrentTenantId
    )
    if (-not $CurrentTenantId) { return $false }
    foreach ($t in @($Tenants)) {
        if ([string]$t.tenantId -ieq [string]$CurrentTenantId) {
            if ($t.defaultDomain) { return $true }
            # Filter falsy entries before counting: @($null).Count is 1, not
            # 0, so a tenant with NO domains property would otherwise report
            # evidence it does not have -- which is the precise failure this
            # function exists to prevent.
            if (@($t.domains | Where-Object { $_ }).Count -gt 0) { return $true }
            return $false
        }
    }
    return $false
}

function Assert-TenantContextMatchesParametersFile {
    <#
    .SYNOPSIS
        Throws unless the current az CLI context's tenant resolves to ExpectedDomain.

    .DESCRIPTION
        Side-effecting wrapper around Test-TenantDomainMatch for callers that
        have already run `az account show` and hold the parsed result. Calls
        `az rest` for the ARM tenants list, checks membership via
        Test-TenantDomainMatch, and throws the standard message naming both
        the observed and expected tenant if it does not match. On success,
        writes the confirmation via Write-Information -- never Write-Host --
        so a caller whose stdout is a machine-readable payload (issue
        #124 / #231's lesson) never has this line land in it. Returns nothing
        either way.

        Calls `az rest` directly rather than through a process-invocation
        helper, matching how every Deploy-*.ps1 reconciler already calls `az`
        in this region -- the majority of this function's callers -- so the
        two local drift-sync scripts (which route other `az`/`git` calls
        through their own Invoke-ChildProcess) gain no new dependency on that
        helper by importing this module.

    .PARAMETER Account
        The parsed object from `az account show -o json` (must carry
        .tenantId and .name).

    .PARAMETER ExpectedDomain
        The parameters file's automation.tenantDomain value.

    .PARAMETER EnvironmentName
        The parameters file's declared environment, for the error message only.

    .PARAMETER ParametersFile
        The parameters file path, for the error message only.

    .EXAMPLE
        Assert-TenantContextMatchesParametersFile -Account $account `
            -ExpectedDomain $TenantDomain -EnvironmentName $parameters.environment `
            -ParametersFile $ParametersFile
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Account,
        [Parameter(Mandatory = $true)][string]$ExpectedDomain,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$ParametersFile
    )
    # Reference: https://learn.microsoft.com/en-us/rest/api/resources/tenants/list
    # NO EVIDENCE is not the same as CONTRARY EVIDENCE (issue #225 follow-up).
    #
    # The ARM /tenants endpoint enumerates tenants for the *caller*, and it
    # answers a USER principal richly (defaultDomain + domains[]) but tells a
    # SERVICE PRINCIPAL almost nothing -- an OIDC-federated CI login gets a
    # list that either omits its own tenant or carries no domain fields at
    # all. The first cut of this guard treated that silence as a mismatch and
    # threw, which broke every CI data-plane run the moment it rolled out
    # (caught live on sync-labels-from-tenant.yml run 34141626934, which
    # failed against the CORRECT tenant).
    #
    # Failing open here does not reopen #41. That incident is a stale
    # INTERACTIVE session drifting onto the wrong tenant, and a user context
    # is exactly the case ARM answers fully -- a wrong tenant is found, has
    # domains, and does not match, so it still throws. CI has no ambient
    # session to drift: its tenant is pinned by the federated credential and
    # the environment's secrets, so there is nothing for this check to catch
    # that the OIDC trust does not already guarantee.
    #
    # So: throw on a resolved mismatch, warn loudly when ARM cannot tell us.
    $tenantsJson = az rest --method get --url 'https://management.azure.com/tenants?api-version=2022-12-01' -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $tenantsJson) {
        Write-Warning ("Could not verify the az context against '{0}': az rest to the ARM tenants endpoint failed (exit {1}). Continuing unverified -- confirm the tenant yourself before trusting a destructive run." -f $ExpectedDomain, $LASTEXITCODE)
        return
    }
    $tenants = (($tenantsJson -join "`n") | ConvertFrom-Json -Depth 10).value

    # Can ARM actually speak to this tenant's domains? If our own tenant is
    # absent from the list, or present with no domain data, there is nothing
    # to compare and a throw would be an assertion about evidence we do not
    # have.
    if (-not (Test-TenantDomainEvidenceAvailable -Tenants $tenants -CurrentTenantId $Account.tenantId)) {
        Write-Warning ("Could not verify the az context against '{0}': the ARM tenants list returned no verified-domain data for the current tenant (typical for a service principal / OIDC login). Continuing unverified." -f $ExpectedDomain)
        return
    }

    if (-not (Test-TenantDomainMatch -Tenants $tenants -CurrentTenantId $Account.tenantId -ExpectedDomain $ExpectedDomain)) {
        # Single-quoted format string, deliberately: a backtick-quoted command
        # name here (`` `az account set ...` ``) is a genuine PowerShell trap
        # inside a double-quoted string -- `` `a `` is the recognized escape
        # for the alert/BEL control character, not a literal backtick, so
        # "an" silently became a BEL-then-"n" and the closing backtick before
        # the trailing space vanished too. Both local drift-sync scripts
        # carried this exact bug before this extraction; fixed here rather
        # than carried forward.
        throw ('The current az context (tenant ''{0}'', account ''{1}'') does not resolve to the expected tenant domain ''{2}'' from ''{3}''. Run ''az account set --subscription <name>'' for the {4} environment first.' -f $Account.tenantId, $Account.name, $ExpectedDomain, $ParametersFile, $EnvironmentName)
    }
    Write-Information ("az context OK: {0} -> {1}" -f $Account.name, $ExpectedDomain) -InformationAction Continue
}

Export-ModuleMember -Function 'Test-TenantDomainMatch', 'Test-TenantDomainEvidenceAvailable', 'Assert-TenantContextMatchesParametersFile'
