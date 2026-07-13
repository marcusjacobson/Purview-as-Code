#Requires -Version 7.4
<#
.SYNOPSIS
    Create (or reconcile) the kv-temp-unlock workflow Entra app per Epic #246 / Issue #257.

.DESCRIPTION
    PR D1b. Creates one Microsoft Entra application registration + service
    principal + federated credential for the kv-temp-unlock workflow
    (`gh-oidc-purview-kv-unlock`), a purpose-specific OIDC identity distinct
    from the control- and data-plane apps from ADR 0010. The resulting
    identity holds only the custom `Purview-Lab-KV-Firewall-Toggler` role
    (granted by `scripts/New-KvUnlockRbac.ps1`, PR D1b) at the lab Key Vault
    scope, never Contributor on the resource group.

    The federated-credential subject is bound to a dedicated GitHub
    Environment (`kv-unlock`) rather than the shared `lab` environment so
    the kv-temp-unlock approval gate (required reviewers, wait timer) is
    configurable independently from `deploy-infra.yml` and the per-solution
    `deploy-<solution>.yml` data-plane workflows.

    What this script does:

      1. Load and validate the parameters file (ADR 0012). Surfaces the
         `automation.apps.kvUnlock` block introduced in PR D1a.
      2. Resolve the expected federated-credential shape from
         `automation.githubOrg`, `automation.githubRepo`, and
         `automation.apps.kvUnlock.githubEnvironment`.
      3. `az ad app list` probe for the display name. Create the app if
         missing (single-tenant, no reply URLs, no redirect URIs).
      4. `az ad sp show` probe for the service principal. Create if missing.
      5. `az ad app federated-credential list` probe. Create the
         `gh-env-kv-unlock` credential if missing; verify every field
         matches the expected shape; fail on any second credential
         (single-subject invariant -- ADR 0010 decision #4 applied to the
         kv-unlock app).

    What this script does NOT do (scoped out per Issue #257):

      * No role assignments. RBAC is owned by `scripts/New-KvUnlockRbac.ps1`
        (PR D1b) and the custom role is declared in
        `infra/modules/role-definitions.bicep` (PR D1a). Splitting identity
        creation from RBAC keeps each script auditable in isolation.
      * No client secret, no certificate, no second federated credential.
        The kv-unlock workflow uses GitHub Actions OIDC end-to-end.
      * No GitHub Environment creation. The lab owner creates `kv-unlock`
        manually with owner-only reviewer protection (operator runbook in
        the PR description).
      * No GitHub repo secret writes. The lab owner stores
        `AZURE_CLIENT_ID_KV_UNLOCK` manually after this script prints the
        `appId`.

    References (Learn):
      Workload identity federation overview:
        https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
      Configure an app to trust an external IdP:
        https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust
      Configuring OpenID Connect in Azure (GitHub side):
        https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure
      OIDC subject claim formats:
        https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
      az ad app:
        https://learn.microsoft.com/en-us/cli/azure/ad/app
      az ad app federated-credential:
        https://learn.microsoft.com/en-us/cli/azure/ad/ad-app-federated-credential
      az ad sp:
        https://learn.microsoft.com/en-us/cli/azure/ad/sp

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.

.PARAMETER DisplayName
    Override the Entra app display name. When omitted (the default), the
    name is read from `automation.apps.kvUnlock.displayName:` in the
    parameters file. Override only for experimental or non-lab runs.

.EXAMPLE
    ./scripts/New-KvUnlockEntraApp.ps1 -WhatIf

    Prints the planned Entra writes for the kv-unlock app without creating
    anything.

.EXAMPLE
    ./scripts/New-KvUnlockEntraApp.ps1

    Creates (or reconciles) the kv-unlock app. A second run with no source
    changes is a no-op.

.NOTES
    Caller role requirement: an Entra role that permits creating application
    registrations -- `Application Administrator` or `Cloud Application
    Administrator`, per [Least privileged roles by task](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/delegate-by-task#application-registrations).
    `Application Developer` is insufficient because this script also creates
    the service principal and the federated credential.

    Output: prints the app's `appId`, the service principal's `objectId`,
    and the federated credential's `id`. These values are intentionally
    printed rather than captured to a file -- the operator stores the
    `appId` as the `AZURE_CLIENT_ID_KV_UNLOCK` GitHub repo secret by hand
    per the PR D1b operator runbook.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DisplayName
)

$ErrorActionPreference = 'Stop'

#region Helpers (AST-extractable for unit tests)

# Resolve and validate the kv-unlock expected federated-credential shape
# from a parsed parameters hashtable. Pure function: no az / Az / network
# calls, no script-scope writes. Tests AST-extract this and pass synthetic
# hashtables.
#
# Throws (via `throw`, so callers can `try/catch` or rely on
# `$ErrorActionPreference = 'Stop'` to terminate) on any missing key. The
# error messages name the exact YAML path so the operator does not have to
# guess which block of `lab.yaml` is wrong.
function Get-KvUnlockExpectedShape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters,

        [Parameter()]
        [string]$DisplayNameOverride
    )

    if (-not $Parameters.ContainsKey('automation')) {
        throw "Parameters file is missing required top-level key 'automation'. Reference: docs/adr/0012-environment-parameters-file.md."
    }
    $automation = $Parameters.automation
    foreach ($key in @('githubOrg', 'githubRepo', 'apps')) {
        if (-not $automation.ContainsKey($key)) {
            throw "Parameters file is missing required key 'automation.$key'. Reference: docs/adr/0010-automation-identity-subject-model.md decision #2."
        }
    }
    if (-not $automation.apps.ContainsKey('kvUnlock')) {
        throw "Parameters file is missing required key 'automation.apps.kvUnlock'. PR D1a should have shipped this block; rebase against main and re-run."
    }
    $kvUnlock = $automation.apps.kvUnlock
    foreach ($key in @('displayName', 'githubEnvironment')) {
        if (-not $kvUnlock.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$kvUnlock[$key])) {
            throw "Parameters file is missing required key 'automation.apps.kvUnlock.$key'. PR D1a should have shipped this block; rebase against main and re-run."
        }
    }

    $githubOrg = [string]$automation.githubOrg
    $githubRepo = [string]$automation.githubRepo
    $githubEnv = [string]$kvUnlock.githubEnvironment

    $resolvedDisplayName = if ($DisplayNameOverride) { $DisplayNameOverride } else { [string]$kvUnlock.displayName }

    # ADR 0010 decision #2 subject shape, scoped to the kv-unlock
    # environment so the workflow's protection rules gate it independently.
    return [ordered]@{
        DisplayName = $resolvedDisplayName
        FcName      = "gh-env-$githubEnv"
        Subject     = "repo:$githubOrg/$githubRepo`:environment:$githubEnv"
        Issuer      = 'https://token.actions.githubusercontent.com'
        Audiences   = @('api://AzureADTokenExchange')
    }
}

# Enforce the single-subject invariant + verify every field of an existing
# federated credential matches the expected shape. Pure function. Tests
# AST-extract this and pass synthetic FC objects.
#
# Returns:
#   * $null when $FcList is empty (caller should create the credential).
#   * The matching FC object when exactly one credential matches the
#     expected shape.
# Throws on:
#   * Any FC count > 1 (single-subject invariant violation).
#   * Exactly one FC whose name, issuer, subject, or audiences disagree
#     with the expected shape (silent reconcile is forbidden -- operator
#     must reconcile by hand).
function Assert-KvUnlockFederatedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$FcList,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Expected,

        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    if ($FcList.Count -gt 1) {
        $names = ($FcList | ForEach-Object { $_.name }) -join ', '
        throw "Application '$DisplayName' has $($FcList.Count) federated credentials ($names). The kv-unlock app must hold exactly one credential bound to subject '$($Expected.Subject)'. A second credential -- regardless of subject -- is itself an anomaly signal: it could exfiltrate the role assignment to a different GitHub Environment that lacks the kv-unlock approval gate. Remove the extra credentials manually and re-run."
    }

    if ($FcList.Count -eq 0) {
        return $null
    }

    $fc = $FcList[0]
    $mismatches = @()
    if ($fc.name -ne $Expected.FcName) {
        $mismatches += "name: expected '$($Expected.FcName)', actual '$($fc.name)'"
    }
    if ($fc.issuer -ne $Expected.Issuer) {
        $mismatches += "issuer: expected '$($Expected.Issuer)', actual '$($fc.issuer)'"
    }
    if ($fc.subject -ne $Expected.Subject) {
        $mismatches += "subject: expected '$($Expected.Subject)', actual '$($fc.subject)'"
    }
    $actualAudiences = @($fc.audiences)
    $expectedAudiences = @($Expected.Audiences)
    $audienceMismatch = $false
    if ($actualAudiences.Count -ne $expectedAudiences.Count) {
        $audienceMismatch = $true
    }
    else {
        foreach ($a in $expectedAudiences) {
            if ($actualAudiences -notcontains $a) { $audienceMismatch = $true }
        }
    }
    if ($audienceMismatch) {
        $mismatches += "audiences: expected '$($expectedAudiences -join ',')', actual '$($actualAudiences -join ',')'"
    }

    if ($mismatches.Count -gt 0) {
        throw "Application '$DisplayName' has a federated credential whose shape does not match the kv-unlock contract. Mismatches: $($mismatches -join '; '). Refusing to mutate; reconcile manually."
    }

    return $fc
}

#endregion

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

if (-not $ParametersFile) {
    $ParametersFile = Join-Path $repoRoot 'infra/parameters/lab.yaml'
}
if (-not (Test-Path -LiteralPath $ParametersFile)) {
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md for the expected shape and infra/parameters/README.md for the consumer contract." -f $ParametersFile)
    return
}
$ParametersFile = (Resolve-Path -LiteralPath $ParametersFile).Path

# Reference: https://www.powershellgallery.com/packages/powershell-yaml
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Information 'Installing powershell-yaml module to CurrentUser scope.' -InformationAction Continue
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force -AllowClobber
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Yaml
if (-not $parameters) {
    Write-Error ("Parameters file '{0}' parsed as empty or null." -f $ParametersFile)
    return
}

$expected = Get-KvUnlockExpectedShape -Parameters $parameters -DisplayNameOverride $DisplayName
$DisplayName = $expected.DisplayName

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("App display name: {0}" -f $DisplayName) -InformationAction Continue
Write-Information ("Federated credential name: {0}" -f $expected.FcName) -InformationAction Continue
Write-Information ("Federated credential subject: {0}" -f $expected.Subject) -InformationAction Continue

#endregion

#region Azure context preflight

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` with an account that holds Application Administrator or Cloud Application Administrator before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
Write-Information ("Tenant: {0}" -f $account.tenantId) -InformationAction Continue

#endregion

#region Application probe

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
# `--display-name` filters server-side, but the list can still contain
# unrelated matches if the name is a substring. Post-filter in-memory for
# an exact match.
$appListJson = az ad app list --display-name $DisplayName -o json --only-show-errors 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app list failed with exit code $LASTEXITCODE. Verify that the signed-in account has directory read permissions."
    return
}
$appList = @()
if ($appListJson) {
    $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DisplayName })
}

if ($appList.Count -gt 1) {
    Write-Error ("Found {0} Entra applications with display name '{1}'. The kv-unlock app must be unique by display name; remove the duplicates manually (preserve the one with a federated credential matching subject '{2}') and re-run." -f $appList.Count, $DisplayName, $expected.Subject)
    return
}

$app = $null
if ($appList.Count -eq 1) {
    $app = $appList[0]
    Write-Information ("NoChange probe: application '{0}' already exists (appId: {1}, objectId: {2})." -f $DisplayName, $app.appId, $app.id) -InformationAction Continue
}
else {
    Write-Information ("Create probe: application '{0}' does not exist." -f $DisplayName) -InformationAction Continue
}

#endregion

#region WhatIf gate

$target = "Entra application '$DisplayName' + service principal + federated credential '$($expected.FcName)'"
$action = "Ensure kv-unlock automation identity per Epic #246 / Issue #257"

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    Write-Information '' -InformationAction Continue
    Write-Information '-WhatIf specified. Planned writes:' -InformationAction Continue
    if (-not $app) {
        Write-Information ("  + Create application '{0}' (single-tenant, no redirect URIs)." -f $DisplayName) -InformationAction Continue
        Write-Information ("  + Create service principal for the new app.") -InformationAction Continue
        Write-Information ("  + Create federated credential '{0}' with subject '{1}'." -f $expected.FcName, $expected.Subject) -InformationAction Continue
    }
    else {
        Write-Information ("  = Reuse application '{0}' (appId: {1})." -f $DisplayName, $app.appId) -InformationAction Continue
        Write-Information ('  ? Service principal probe skipped under -WhatIf.') -InformationAction Continue
        Write-Information ('  ? Federated credential probe skipped under -WhatIf. Re-run without -WhatIf to reconcile.') -InformationAction Continue
    }
    return
}

#endregion

#region Application create

if (-not $app) {
    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-create
    # `--sign-in-audience AzureADMyOrg` = single-tenant. No redirect URIs,
    # no reply URLs, no implicit-grant flags -- this is a workload identity,
    # not an interactive app.
    $createJson = az ad app create `
        --display-name $DisplayName `
        --sign-in-audience 'AzureADMyOrg' `
        -o json `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "az ad app create failed with exit code $LASTEXITCODE. Inspect the output above before retrying."
        return
    }
    $app = ($createJson -join "`n") | ConvertFrom-Json
    Write-Information ("  + Created application (appId: {0}, objectId: {1})." -f $app.appId, $app.id) -InformationAction Continue
}

$appId = $app.appId
$appObjectId = $app.id

#endregion

#region Service principal reconcile

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-show
$spJson = az ad sp show --id $appId -o json --only-show-errors 2>$null
if ($LASTEXITCODE -eq 0 -and $spJson) {
    $sp = ($spJson -join "`n") | ConvertFrom-Json
    Write-Information ("  = Service principal exists (objectId: {0})." -f $sp.id) -InformationAction Continue
}
else {
    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-create
    $spCreateJson = az ad sp create --id $appId -o json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "az ad sp create failed with exit code $LASTEXITCODE. Inspect the output above before retrying."
        return
    }
    $sp = ($spCreateJson -join "`n") | ConvertFrom-Json
    Write-Information ("  + Created service principal (objectId: {0})." -f $sp.id) -InformationAction Continue
}

#endregion

#region Federated credential reconcile

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/ad-app-federated-credential#az-ad-app-federated-credential-list
$fcListJson = az ad app federated-credential list --id $appObjectId -o json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app federated-credential list failed with exit code $LASTEXITCODE."
    return
}
$fcList = @()
if ($fcListJson) {
    $fcList = @(($fcListJson -join "`n") | ConvertFrom-Json)
}

$existingFc = Assert-KvUnlockFederatedCredential -FcList $fcList -Expected $expected -DisplayName $DisplayName

if ($existingFc) {
    Write-Information ("  = Federated credential matches expected shape (id: {0})." -f $existingFc.id) -InformationAction Continue
    $fcId = $existingFc.id
}
else {
    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/ad-app-federated-credential#az-ad-app-federated-credential-create
    $fcBody = [ordered]@{
        name        = $expected.FcName
        issuer      = $expected.Issuer
        subject     = $expected.Subject
        description = "Epic #246 / Issue #257 -- kv-temp-unlock workflow OIDC subject."
        audiences   = $expected.Audiences
    }
    $fcBodyJson = $fcBody | ConvertTo-Json -Compress -Depth 4

    # Temp file avoids pwsh -> az CLI quoting issues with nested JSON.
    $tempFile = New-TemporaryFile
    try {
        Set-Content -LiteralPath $tempFile.FullName -Value $fcBodyJson -NoNewline -Encoding utf8
        $fcCreateJson = az ad app federated-credential create `
            --id $appObjectId `
            --parameters "@$($tempFile.FullName)" `
            -o json `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Error "az ad app federated-credential create failed with exit code $LASTEXITCODE."
            return
        }
    }
    finally {
        Remove-Item -LiteralPath $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }
    $fc = ($fcCreateJson -join "`n") | ConvertFrom-Json
    $fcId = $fc.id
    Write-Information ("  + Created federated credential '{0}' (id: {1})." -f $expected.FcName, $fcId) -InformationAction Continue
}

#endregion

#region Output

Write-Information '' -InformationAction Continue
Write-Information ('appId                    : {0}' -f $appId) -InformationAction Continue
Write-Information ('application objectId     : {0}' -f $appObjectId) -InformationAction Continue
Write-Information ('servicePrincipal objectId: {0}' -f $sp.id) -InformationAction Continue
Write-Information ('federatedCredential id   : {0}' -f $fcId) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Next steps (operator runbook, PR D1b):' -InformationAction Continue
Write-Information '  1. Store the above appId as the GitHub repo secret `AZURE_CLIENT_ID_KV_UNLOCK`.' -InformationAction Continue
Write-Information '  2. Create the GitHub Environment `kv-unlock` with owner-only required reviewer.' -InformationAction Continue
Write-Information '  3. Run `./scripts/New-KvUnlockRbac.ps1` to grant `Purview-Lab-KV-Firewall-Toggler` at the vault scope.' -InformationAction Continue

#endregion
