#Requires -Version 7.4
<#
.SYNOPSIS
    Deploy the kv-temp-unlock workflow's RBAC grant via infra/modules/kv-unlock-rbac.bicep (PR D1b / Issue #257).

.DESCRIPTION
    PR D1b. Deploys the `Purview-Lab-KV-Firewall-Toggler` -> kv-unlock SP
    role assignment at the lab Key Vault scope. Companion to
    `scripts/New-KvUnlockEntraApp.ps1`: that script creates the identity,
    this one binds the identity to the only permission it needs
    (`Microsoft.KeyVault/vaults/write`, declared as the single action of
    the custom role in `infra/modules/role-definitions.bicep`).

    Why a separate script (not folded into `New-AutomationRbac.ps1`):

      * The kv-unlock SP does not exist when `main.bicep` runs (it is
        created by PR D1b's Entra-app script on first invocation), so it
        cannot be a parameter to the control-plane stack.
      * The custom role's role-definition ID is emitted by
        `role-definitions.bicep` as an output and is not stable across
        subscriptions, so it must be resolved at runtime via
        `az role definition list`.
      * Splitting identity creation, role declaration, and role
        assignment into three audit-distinct primitives lets each step be
        reviewed and re-run in isolation (mirrors the Wave 0 5a/5b/5c/5d
        decomposition in `docs/project-plan.md`).

    Flow:

      1. Load and validate the parameters file (ADR 0012). Resolves the
         vault name, RG name, and kv-unlock app display name.
      2. Resolve the kv-unlock SP object ID via display-name lookup.
         Fail-closed if the app is missing -- the operator must run
         `./scripts/New-KvUnlockEntraApp.ps1` first.
      3. Resolve the `Purview-Lab-KV-Firewall-Toggler` custom-role
         definition ID. Fail-closed if missing -- the operator must
         deploy `infra/main.bicep` first (PR D1a wired
         `role-definitions.bicep` into the control-plane stack).
      4. `az deployment group what-if` -> show planned grant.
      5. `-WhatIf` gate via `ShouldProcess`; bail out before
         `az deployment group create` when set.
      6. `az deployment group create` -> idempotent role assignment.

    What this script does NOT do:

      * No identity creation. Run `./scripts/New-KvUnlockEntraApp.ps1`
        first.
      * No control-plane Bicep deployment. The custom role definition
        must already exist; run `az deployment group create -g
        rg-purview-lab -f infra/main.bicep -p infra/main.bicepparam` if
        the role lookup fails.
      * No `-PruneMissing` / `-Force` switches. Imperative primitive, not
        a reconciler.

    References:
      https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep
      https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
      https://learn.microsoft.com/en-us/cli/azure/role/definition#az-role-definition-list
      https://learn.microsoft.com/en-us/cli/azure/ad/app#az-ad-app-list
      https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-show

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER ResourceGroupName
    Resource group that owns the Key Vault. When omitted, resolved from
    `resourceGroupName:` in the parameters file.

.PARAMETER VaultName
    Key Vault whose firewall the kv-unlock workflow toggles. When omitted,
    resolved from `resources.keyVault.name:` in the parameters file.

.PARAMETER AppDisplayName
    Entra display name of the kv-unlock app. When omitted, resolved from
    `automation.apps.kvUnlock.displayName:` in the parameters file.

.PARAMETER RoleName
    Display name of the Key Vault firewall-toggler custom role. When omitted,
    resolved from `automation.kvFirewallTogglerRoleName:` in the parameters
    file (ADR 0057), falling back to `Purview-Lab-KV-Firewall-Toggler`.

.EXAMPLE
    ./scripts/New-KvUnlockRbac.ps1 -WhatIf

    Resolves the SP and custom role, then prints the planned role
    assignment via `az deployment group what-if`. Makes no writes.

.EXAMPLE
    ./scripts/New-KvUnlockRbac.ps1

    Deploys (or reconciles) the role assignment. Re-run is a no-op once
    the assignment is present.

.NOTES
    Caller role requirement: `User Access Administrator` or `Owner` at the
    resource group scope. `Contributor` is NOT sufficient -- creating role
    assignments requires `Microsoft.Authorization/roleAssignments/write`
    which is held only by the two former roles.
    Reference: https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/privileged#user-access-administrator
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
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$AppDisplayName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RoleName
)

$ErrorActionPreference = 'Stop'

#region Helpers (AST-extractable for unit tests)

# Resolve the kv-unlock service-principal object ID by display name. Pure
# (modulo `az`) -- callers in tests substitute a `Mock` for `az` invocation.
# Returns the SP `objectId` (NOT the application's `appId` and NOT the
# application's `id`/object-id; role assignments target SP object IDs).
#
# Throws on:
#   * `az ad app list` failure (non-zero exit).
#   * Zero applications matching the display name -- prompts the operator
#     to run `New-KvUnlockEntraApp.ps1` first.
#   * More than one application matching the display name -- the
#     uniqueness invariant from `New-KvUnlockEntraApp.ps1` was violated;
#     reconcile manually before proceeding.
#   * `az ad sp show` failure (non-zero exit).
function Resolve-KvUnlockSp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
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
        throw "Entra application '$DisplayName' not found. Run ./scripts/New-KvUnlockEntraApp.ps1 first."
    }
    if ($appList.Count -gt 1) {
        throw "Found $($appList.Count) Entra applications with display name '$DisplayName'. The kv-unlock app must be unique; reconcile manually before re-running."
    }
    $appId = $appList[0].appId

    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/sp#az-ad-sp-show
    $spJson = az ad sp show --id $appId -o json --only-show-errors 2>$null
    if (-not $spJson) {
        throw "Service principal for app '$DisplayName' (appId $appId) not found. Re-run ./scripts/New-KvUnlockEntraApp.ps1 to reconcile."
    }
    return (($spJson -join "`n") | ConvertFrom-Json).id
}

# Resolve the `Purview-Lab-KV-Firewall-Toggler` custom-role definition ID
# from the current subscription. Throws fail-closed with the exact
# remediation command when the role is missing -- the operator must
# deploy `infra/main.bicep` (which wires `role-definitions.bicep`) before
# this script can run.
#
# Returns the full role-definition resource ID
# (`/subscriptions/<sub>/providers/Microsoft.Authorization/roleDefinitions/<guid>`).
function Resolve-KvFirewallTogglerRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RoleName,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    # Reference: https://learn.microsoft.com/en-us/cli/azure/role/definition#az-role-definition-list
    # `--custom-role-only true` filters out built-ins; the custom role is
    # unique by name within the subscription.
    $roleJson = az role definition list --custom-role-only true --name $RoleName -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "az role definition list failed with exit code $LASTEXITCODE for role '$RoleName'."
    }
    $roles = @()
    if ($roleJson) {
        $roles = @(($roleJson -join "`n") | ConvertFrom-Json)
    }
    if ($roles.Count -eq 0) {
        throw @"
Custom role '$RoleName' was not found in the current subscription. PR D1a's `infra/modules/role-definitions.bicep` must be deployed before this script can run. Apply it with:

    az deployment group create -g $ResourceGroupName -f infra/main.bicep -p infra/main.bicepparam

The deploying identity needs Owner or User Access Administrator at subscription scope (Contributor does not include `Microsoft.Authorization/roleDefinitions/write`).
"@
    }
    if ($roles.Count -gt 1) {
        throw "Found $($roles.Count) custom roles named '$RoleName'. Reconcile manually before re-running."
    }
    return $roles[0].id
}

#endregion

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
    Write-Error ("Parameters file not found: '{0}'. See docs/adr/0012-environment-parameters-file.md for the expected shape." -f $ParametersFile)
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
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'." -f $ParametersFile, $key)
        return
    }
}
if (-not $parameters.resources.ContainsKey('keyVault') -or -not $parameters.resources.keyVault.ContainsKey('name')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.keyVault.name'." -f $ParametersFile)
    return
}
if (-not $parameters.automation.ContainsKey('apps') -or
    -not $parameters.automation.apps.ContainsKey('kvUnlock') -or
    -not $parameters.automation.apps.kvUnlock.ContainsKey('displayName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.kvUnlock.displayName'. PR D1a should have shipped this block." -f $ParametersFile)
    return
}

if (-not $ResourceGroupName) { $ResourceGroupName = [string]$parameters.resourceGroupName }
if (-not $VaultName)         { $VaultName         = [string]$parameters.resources.keyVault.name }
if (-not $AppDisplayName)    { $AppDisplayName    = [string]$parameters.automation.apps.kvUnlock.displayName }
if (-not $RoleName) {
    if ($parameters.automation.ContainsKey('kvFirewallTogglerRoleName') -and
        -not [string]::IsNullOrWhiteSpace([string]$parameters.automation.kvFirewallTogglerRoleName)) {
        $RoleName = [string]$parameters.automation.kvFirewallTogglerRoleName
    }
    else {
        $RoleName = 'Purview-Lab-KV-Firewall-Toggler'
    }
}

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Resource group: {0}" -f $ResourceGroupName) -InformationAction Continue
Write-Information ("Key Vault: {0}" -f $VaultName) -InformationAction Continue
Write-Information ("kv-unlock app: {0}" -f $AppDisplayName) -InformationAction Continue
Write-Information ("custom role   : {0}" -f $RoleName) -InformationAction Continue

#endregion

#region Module path resolution

$moduleBicep = Join-Path $repoRoot 'infra/modules/kv-unlock-rbac.bicep'
if (-not (Test-Path -LiteralPath $moduleBicep)) {
    Write-Error "Bicep module not found at $moduleBicep. Expected path: <repo>/infra/modules/kv-unlock-rbac.bicep (PR D1a)."
    return
}
$moduleBicep = (Resolve-Path -LiteralPath $moduleBicep).Path

#endregion

#region Azure context preflight

# Reference: https://learn.microsoft.com/en-us/cli/azure/account#az-account-show
$accountJson = az account show -o json --only-show-errors 2>$null
if (-not $accountJson) {
    Write-Error 'No active Azure CLI session. Run `az login` (with an account that holds Owner or User Access Administrator at the resource-group scope) before invoking this script.'
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

#region Resolve principals + role

$kvUnlockSpObjectId = Resolve-KvUnlockSp -DisplayName $AppDisplayName
Write-Information ("kv-unlock SP objectId: {0}" -f $kvUnlockSpObjectId) -InformationAction Continue

$kvFirewallTogglerRoleId = Resolve-KvFirewallTogglerRole -RoleName $RoleName -ResourceGroupName $ResourceGroupName
Write-Information ("custom role id      : {0}" -f $kvFirewallTogglerRoleId) -InformationAction Continue

#endregion

#region Deployment

$deploymentName = "rbac-kv-unlock-$($parameters.environment)"

$parameterArgs = @(
    "kvUnlockSpObjectId=$kvUnlockSpObjectId",
    "keyVaultName=$VaultName",
    "kvFirewallTogglerRoleId=$kvFirewallTogglerRoleId"
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

$target = "$RoleName -> kv-unlock SP at vault '$VaultName' scope"
$action = 'Deploy kv-unlock RBAC via infra/modules/kv-unlock-rbac.bicep'

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
Write-Information ('kvUnlockRoleAssignmentId: {0}' -f $outputs.kvUnlockRoleAssignmentId.value) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Done. Verify with:' -InformationAction Continue
Write-Information ('  az role assignment list --assignee {0} --scope <vault-id> -o table' -f $kvUnlockSpObjectId) -InformationAction Continue

#endregion
