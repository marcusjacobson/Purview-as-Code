#Requires -Version 7.4
<#
.SYNOPSIS
    Deploy the lab automation RBAC grants via infra/modules/automation-rbac.bicep.

.DESCRIPTION
    Wave 0 item #5d of docs/project-plan.md. Reconciles the role assignments
    required by the two OIDC apps from ADR 0010 whose target resources exist
    at Bicep deploy time:

      * Control-plane SP `gh-oidc-purview-control-plane` -> `Contributor`
        at `rg-purview-lab`. Required by ADR 0010 decision §5; without it
        `azure/login@v2` succeeds but `az account show` reports
        `No subscriptions found for ***`. This is the exact Wave 0 #15 smoke
        failure observed on 2026-04-25.

      * Data-plane SP `gh-oidc-purview-data-plane` -> `Key Vault Crypto User`
        at vault scope on `kv-contoso-lab-01`. Required by ADR 0011
        §3-supersession-addendum (2026-04-24). The Connect-IPPSSession path
        signs an RFC 7523 JWT assertion against the cert's underlying RSA
        key via `az keyvault key sign`; that is the `keys/sign` data-plane
        operation this role grants.

      * Data-plane SP `gh-oidc-purview-data-plane` -> `Key Vault Contributor`
        at vault scope on `kv-contoso-lab-01`. Required by ADR 0049
        (2026-07-11). Every single-login data-plane workflow briefly opens
        the vault firewall via `az keyvault update --public-network-access
        Enabled` — a management-plane `Microsoft.KeyVault/vaults/write` call
        that `Key Vault Crypto User` does not include. `Key Vault Contributor`
        is the narrowest built-in covering `vaults/write`; it is management-
        plane only (empty dataActions) so it cannot read secrets/keys/certs
        and cannot assign RBAC.

    OUT of scope (intentionally owned by Wave 0 #5c):

      * `Key Vault Certificate User` at cert scope on the data-plane SP.
      * `Key Vault Certificates Officer` at vault scope on the data-plane SP.

    These cert-scoped grants live in `scripts/New-AutomationCertificate.ps1`
    because the certificate object only exists at the time that script runs;
    Bicep cannot resolve `{vault}/certificates/{name}` ahead of time. Each
    script owns a clean, non-overlapping slice of the data-plane SP's KV
    permissions.

    This script is a **thin orchestrator** around the Bicep module, matching
    the shape established by `scripts/New-AutomationKeyVault.ps1`:

      * Idempotency: Bicep role-assignment names are derived from
        `guid(scope, principalId, roleDefinitionId)` in `infra/modules/rbac.bicep`,
        so a re-run is a no-op once the assignment matches.
      * WhatIf: honoured via `[CmdletBinding(SupportsShouldProcess)]`. A
        `-WhatIf` run prints `az deployment group what-if` and short-circuits
        before `az deployment group create`.
      * No `-PruneMissing` / `-Force` / `-ExportCurrentState` — this is an
        imperative primitive per the ADR 0011 addendum's 5a/5b/5c/5d shape,
        not a `Deploy-*.ps1` reconciler, so the four-switch contract in
        .github/instructions/powershell.instructions.md does not apply.

    References:
      https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
      https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles
      https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
      https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
      https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-show

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER ResourceGroupName
    Resource group that owns the Key Vault and is the scope of the Contributor
    grant. When omitted, resolved from `resourceGroupName:` in the parameters
    file.

.PARAMETER VaultName
    Key Vault that scopes the Crypto User grant. When omitted, resolved from
    `resources.keyVault.name:` in the parameters file.

.PARAMETER ControlPlaneAppDisplayName
    Entra display name of the control-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.controlPlane.displayName:` in the
    parameters file.

.PARAMETER DataPlaneAppDisplayName
    Entra display name of the data-plane app (ADR 0010). When omitted,
    resolved from `automation.apps.dataPlane.displayName:` in the parameters
    file.

.EXAMPLE
    ./scripts/New-AutomationRbac.ps1 -WhatIf

    Prints an `az deployment group what-if` plan for the two role assignments
    using values from `infra/parameters/lab.yaml` and makes no writes.

.EXAMPLE
    ./scripts/New-AutomationRbac.ps1

    Deploys (or reconciles) the two role assignments per
    `infra/parameters/lab.yaml`. Re-run is a no-op once both assignments are
    present.

.NOTES
    Caller role requirement: `User Access Administrator` or `Owner` at the
    resource-group scope. `Contributor` is NOT sufficient — creating role
    assignments requires `Microsoft.Authorization/roleAssignments/write`
    which only the two former roles include.
    Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/privileged#user-access-administrator

    Output: prints both role-assignment IDs. No credential material is read
    or printed because no credential material is involved.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._()-]{0,88}[a-zA-Z0-9_()]$')]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$')]
    [string]$VaultName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ControlPlaneAppDisplayName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataPlaneAppDisplayName
)

$ErrorActionPreference = 'Stop'

#region Parameters file resolution

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot

# When -ParametersFile is omitted, the PURVIEW_PARAMETERS_FILE environment
# variable (set per-environment by the CI workflows) selects the parameters
# file. See docs/adr/0057-multi-environment-and-branch-model.md.
if (-not $ParametersFile) {
    $ParametersFile = if ($env:PURVIEW_PARAMETERS_FILE) {
        $env:PURVIEW_PARAMETERS_FILE
    } else {
        Join-Path $repoRoot 'infra/parameters/lab.yaml'
    }
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

foreach ($key in @('resourceGroupName', 'resources', 'automation')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps'." -f $ParametersFile)
    return
}
foreach ($plane in @('controlPlane', 'dataPlane')) {
    if (-not $parameters.automation.apps.ContainsKey($plane) -or -not $parameters.automation.apps[$plane].ContainsKey('displayName')) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.{1}.displayName'." -f $ParametersFile, $plane)
        return
    }
}

if (-not $ResourceGroupName)         { $ResourceGroupName         = [string]$parameters.resourceGroupName }
if (-not $VaultName)                 { $VaultName                 = [string]$parameters.resources.keyVault.name }
if (-not $ControlPlaneAppDisplayName) { $ControlPlaneAppDisplayName = [string]$parameters.automation.apps.controlPlane.displayName }
if (-not $DataPlaneAppDisplayName)    { $DataPlaneAppDisplayName    = [string]$parameters.automation.apps.dataPlane.displayName }

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue

#endregion

#region Module path resolution

$moduleBicep = Join-Path $repoRoot 'infra/modules/automation-rbac.bicep'
if (-not (Test-Path -LiteralPath $moduleBicep)) {
    Write-Error "Bicep module not found at $moduleBicep. Expected path: <repo>/infra/modules/automation-rbac.bicep."
    return
}
$moduleBicep = (Resolve-Path -LiteralPath $moduleBicep).Path

#endregion

#region Azure context preflight

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` (or ensure the OIDC step ran) before invoking this script.'
    return
}
$account = ($accountJson -join "`n") | ConvertFrom-Json
Write-Information ("Subscription: {0} ({1})" -f $account.name, $account.id) -InformationAction Continue

# Reference: https://learn.microsoft.com/en-us/cli/azure/group#az-group-show
$rgJson = az group show --name $ResourceGroupName -o json --only-show-errors 2>$null
if (-not $rgJson) {
    Write-Error ("Resource group '{0}' was not found in subscription '{1}'." -f $ResourceGroupName, $account.id)
    return
}

# Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-show
$vaultJson = az resource show `
    --resource-type 'Microsoft.KeyVault/vaults' `
    --name $VaultName `
    --resource-group $ResourceGroupName `
    -o json `
    --only-show-errors 2>$null
if (-not $vaultJson) {
    Write-Error ("Key Vault '{0}' was not found in '{1}'. Run Wave 0 #5a (`scripts/New-AutomationKeyVault.ps1`) first." -f $VaultName, $ResourceGroupName)
    return
}

#endregion

#region Service-principal resolution

# Resolve each app's service-principal object ID via display name. Mirrors the
# pattern in scripts/New-AutomationCertificate.ps1: list apps by display name,
# fail closed if zero or >1 match (ADR 0010 decision §1 mandates one app per
# display name), then `az ad sp show --id <appId>` to get the SP object ID
# (RBAC assignments target SP object IDs, not app IDs or app object IDs).
function Resolve-AutomationSp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$Plane
    )

    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
    $appListJson = az ad app list --display-name $DisplayName -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "az ad app list failed with exit code $LASTEXITCODE for display name '$DisplayName'."
    }
    $appList = @()
    if ($appListJson) {
        $appList = @(($appListJson -join "`n") | ConvertFrom-Json | Where-Object { $_.displayName -eq $DisplayName })
    }
    if ($appList.Count -eq 0) {
        throw "Entra application '$DisplayName' not found. Run Wave 0 #5b (./scripts/New-AutomationEntraApp.ps1 -Plane $Plane) first."
    }
    if ($appList.Count -gt 1) {
        throw "Found $($appList.Count) Entra applications with display name '$DisplayName'. ADR 0010 decision §1 mandates one app per display name. Reconcile manually before re-running."
    }
    $appId = $appList[0].appId

    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-show
    $spJson = az ad sp show --id $appId -o json --only-show-errors 2>$null
    if (-not $spJson) {
        throw "Service principal for app '$DisplayName' not found. Re-run Wave 0 #5b to reconcile."
    }
    return (($spJson -join "`n") | ConvertFrom-Json).id
}

$controlPlaneSpObjectId = Resolve-AutomationSp -DisplayName $ControlPlaneAppDisplayName -Plane 'control'
$dataPlaneSpObjectId    = Resolve-AutomationSp -DisplayName $DataPlaneAppDisplayName    -Plane 'data'

Write-Information ("Control-plane SP objectId: {0}" -f $controlPlaneSpObjectId) -InformationAction Continue
Write-Information ("Data-plane    SP objectId: {0}" -f $dataPlaneSpObjectId)    -InformationAction Continue

#endregion

#region Deployment

$deploymentName = "rbac-automation-$($parameters.environment)"

$parameterArgs = @(
    "controlPlaneSpObjectId=$controlPlaneSpObjectId",
    "dataPlaneSpObjectId=$dataPlaneSpObjectId",
    "keyVaultName=$VaultName"
)

Write-Information '' -InformationAction Continue
Write-Information '--- what-if ---' -InformationAction Continue
# Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
az deployment group what-if `
    --resource-group $ResourceGroupName `
    --name $deploymentName `
    --template-file $moduleBicep `
    --parameters @parameterArgs `
    --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Error "what-if failed with exit code $LASTEXITCODE. Inspect the output above before retrying."
    return
}

$target = "RBAC grants in resource group '$ResourceGroupName' (CP Contributor + DP Crypto User & KV Contributor on '$VaultName')"
$action = 'Deploy automation RBAC via infra/modules/automation-rbac.bicep'

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    Write-Information '' -InformationAction Continue
    Write-Information '-WhatIf specified. Skipping `az deployment group create`.' -InformationAction Continue
    return
}

Write-Information '' -InformationAction Continue
Write-Information '--- create ---' -InformationAction Continue
# Reference: https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli
$deploymentJson = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $deploymentName `
    --template-file $moduleBicep `
    --parameters @parameterArgs `
    -o json `
    --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Error "az deployment group create failed with exit code $LASTEXITCODE. Inspect the output above before retrying."
    return
}

$deployment = ($deploymentJson -join "`n") | ConvertFrom-Json
$outputs = $deployment.properties.outputs

Write-Information '' -InformationAction Continue
Write-Information ('controlPlaneContributorAssignmentId    : {0}' -f $outputs.controlPlaneContributorAssignmentId.value) -InformationAction Continue
Write-Information ('dataPlaneCryptoUserAssignmentId        : {0}' -f $outputs.dataPlaneCryptoUserAssignmentId.value)     -InformationAction Continue
Write-Information ('dataPlaneKeyVaultContributorAssignmentId : {0}' -f $outputs.dataPlaneKeyVaultContributorAssignmentId.value) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Done. Re-dispatch `.github/workflows/validate-oidc-auth.yml` on main to verify the Wave 0 #15 smoke now passes.' -InformationAction Continue

#endregion
