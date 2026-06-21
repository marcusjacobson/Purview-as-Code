#Requires -Version 7.4
<#
.SYNOPSIS
    Deploy the lab automation Key Vault via infra/modules/keyvault.bicep.

.DESCRIPTION
    Wave 0 item #5a of docs/project-plan.md. Creates the lab Key Vault that
    holds the data-plane automation certificate defined by ADR 0011 decision
    §1. The vault ships with the required security settings from ADR 0011
    decision §2 (RBAC auth mode, 90-day soft-delete, purge-protection) and
    streams `AuditEvent` logs to the Log Analytics workspace produced by Wave
    0 #5.0.

    This script is a **thin orchestrator** around the Bicep module, matching
    the shape established by `scripts/New-LogAnalyticsWorkspace.ps1`:

      * Idempotency: `az resource show` reports NoChange when the vault already
        exists; Bicep's declarative deployment still reconciles any drift.
      * WhatIf: honoured via `[CmdletBinding(SupportsShouldProcess)]`. A
        `-WhatIf` run prints `az deployment group what-if` and short-circuits
        before `az deployment group create`.
      * No `-PruneMissing` / `-Force` / `-ExportCurrentState` — this is an
        imperative primitive per ADR 0011 addendum, not a `Deploy-*.ps1`
        reconciler, so the four-switch contract in
        .github/instructions/powershell.instructions.md does not apply.

    Out of scope (kept for 5c per ADR 0011 decomposition addendum):

      * Creating the certificate (5c, `New-AutomationCertificate.ps1`).
      * Assigning `Key Vault Certificate User` and
        `Key Vault Certificates Officer` to the data-plane Entra app (5c —
        the app OID does not exist until 5b has run).

    References:
      https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults
      https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide
      https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview
      https://learn.microsoft.com/en-us/azure/key-vault/general/logging
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if

    All environment-varying values (resource group, region, vault name,
    LAW name that backs the diagnostic sink) come from
    `infra/parameters/lab.yaml` per ADR 0012. Every value is independently
    overridable on the command line.

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root. Every
    value this script needs is read from that file unless explicitly
    overridden by one of the per-value parameters below. Reference:
    docs/adr/0012-environment-parameters-file.md.

.PARAMETER ResourceGroupName
    Resource group that owns the vault. When omitted, resolved from
    `resourceGroupName:` in the parameters file.

.PARAMETER VaultName
    Key Vault name. When omitted, resolved from
    `resources.keyVault.name:` in the parameters file.

.PARAMETER Location
    Azure region. When omitted, resolved from `location:` in the parameters
    file.

.PARAMETER LogAnalyticsWorkspaceId
    Full resource ID of the Log Analytics workspace that receives `AuditEvent`
    logs. When omitted, derived from the parameters file by resolving the
    workspace named in `resources.logAnalytics.name:` in the same resource
    group. Override only when pointing at a non-default workspace.

.EXAMPLE
    ./scripts/New-AutomationKeyVault.ps1 -WhatIf

    Prints an `az deployment group what-if` plan for the lab vault using
    values from `infra/parameters/lab.yaml` and makes no writes.

.EXAMPLE
    ./scripts/New-AutomationKeyVault.ps1

    Deploys (or updates) the lab automation vault per
    `infra/parameters/lab.yaml`. Re-run is a no-op once the vault matches the
    module's shape.

.EXAMPLE
    ./scripts/New-AutomationKeyVault.ps1 -ParametersFile infra/parameters/prod.yaml

    Deploys the vault defined by a non-lab environment file. Explicit
    per-value parameters still override file values.

.NOTES
    Caller role requirement: `Contributor` (or `Key Vault Contributor`) at the
    resource-group scope. No data-plane Key Vault permission is required to
    create the vault; 5c will add the per-identity RBAC grants later via its
    own deployment.
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
    [string]$Location,

    [Parameter()]
    [string]$LogAnalyticsWorkspaceId
)

$ErrorActionPreference = 'Stop'

#region Parameters file resolution

# Repo root is the parent of the script directory (`<repo>/scripts`).
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

# Module dependency: powershell-yaml
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

foreach ($key in @('resourceGroupName', 'location', 'resources')) {
    if (-not $parameters.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required top-level key '{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}
foreach ($section in @('keyVault', 'logAnalytics')) {
    if (-not $parameters.resources.ContainsKey($section)) {
        Write-Error ("Parameters file '{0}' is missing required key 'resources.{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $section)
        return
    }
    if (-not $parameters.resources[$section].ContainsKey('name')) {
        Write-Error ("Parameters file '{0}' is missing required key 'resources.{1}.name'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $section)
        return
    }
}

# Resolution order per ADR 0012: explicit CLI parameter wins; otherwise read
# the value from the parameters file.
if (-not $ResourceGroupName) { $ResourceGroupName = [string]$parameters.resourceGroupName }
if (-not $Location)          { $Location          = [string]$parameters.location }
if (-not $VaultName)         { $VaultName         = [string]$parameters.resources.keyVault.name }

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue

#endregion

#region Module path resolution

$moduleBicep = Join-Path $repoRoot 'infra/modules/keyvault.bicep'
if (-not (Test-Path -LiteralPath $moduleBicep)) {
    Write-Error "Bicep module not found at $moduleBicep. Expected path: <repo>/infra/modules/keyvault.bicep."
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
# `az` returns string[] in pwsh 7+; join before ConvertFrom-Json.
$account = ($accountJson -join "`n") | ConvertFrom-Json
Write-Information ("Subscription: {0} ({1})" -f $account.name, $account.id) -InformationAction Continue

# Reference: https://learn.microsoft.com/en-us/cli/azure/group#az-group-show
$rgJson = az group show --name $ResourceGroupName -o json --only-show-errors 2>$null
if (-not $rgJson) {
    Write-Error ("Resource group '{0}' was not found in subscription '{1}'. Create it first with `az group create -n {0} -l {2}` or verify you are in the right subscription." -f $ResourceGroupName, $account.id, $Location)
    return
}

#endregion

#region Log Analytics workspace resolution

if (-not $LogAnalyticsWorkspaceId) {
    # Default target: the workspace named in the parameters file, resolved
    # from the same RG.
    # Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-show
    $defaultWorkspaceName = [string]$parameters.resources.logAnalytics.name
    $lawJson = az resource show `
        --resource-type 'Microsoft.OperationalInsights/workspaces' `
        --name $defaultWorkspaceName `
        --resource-group $ResourceGroupName `
        -o json `
        --only-show-errors 2>$null
    if (-not $lawJson) {
        Write-Error ("Log Analytics workspace '{0}' was not found in '{1}'. Run Wave 0 #5.0 (`scripts/New-LogAnalyticsWorkspace.ps1`) first, or pass -LogAnalyticsWorkspaceId explicitly." -f $defaultWorkspaceName, $ResourceGroupName)
        return
    }
    $law = ($lawJson -join "`n") | ConvertFrom-Json
    $LogAnalyticsWorkspaceId = $law.id
    Write-Information ("Log Analytics workspace: {0}" -f $LogAnalyticsWorkspaceId) -InformationAction Continue
}

#endregion

#region Idempotency probe

# Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-show
$existingJson = az resource show `
    --resource-type 'Microsoft.KeyVault/vaults' `
    --name $VaultName `
    --resource-group $ResourceGroupName `
    -o json `
    --only-show-errors 2>$null

$alreadyExists = [bool]$existingJson
if ($alreadyExists) {
    $existing = ($existingJson -join "`n") | ConvertFrom-Json
    Write-Information ("NoChange probe: vault '{0}' already exists in '{1}' (resource id: {2})." -f $VaultName, $ResourceGroupName, $existing.id) -InformationAction Continue
    Write-Information 'Proceeding with Bicep deployment so the module reconciles any drift in SKU, RBAC mode, retention, purge-protection, or diagnostic settings.' -InformationAction Continue
}
else {
    # Soft-deleted vault check: a previously purged-protected vault blocks
    # creation at the same name until its soft-delete retention expires or it
    # is recovered. Surface the condition explicitly.
    # Reference: https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-list-deleted
    $deletedJson = az keyvault list-deleted --resource-type vault -o json --only-show-errors 2>$null
    if ($deletedJson) {
        $deleted = ($deletedJson -join "`n") | ConvertFrom-Json
        $match = $deleted | Where-Object { $_.name -eq $VaultName }
        if ($match) {
            Write-Error ("Soft-deleted vault '{0}' exists (scheduledPurgeDate: {1}). Recover it with `az keyvault recover --name {0}` or wait until purge, then re-run. Because ADR 0011 mandates enablePurgeProtection:true, the vault cannot be purged early." -f $VaultName, $match.properties.scheduledPurgeDate)
            return
        }
    }
    Write-Information ("Create probe: vault '{0}' does not exist in '{1}'. A full deployment will run." -f $VaultName, $ResourceGroupName) -InformationAction Continue
}

#endregion

#region Deployment

$deploymentName = "kv-$VaultName"

$parameterArgs = @(
    "vaultName=$VaultName",
    "location=$Location",
    "logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId"
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

$target = "vault '$VaultName' in resource group '$ResourceGroupName'"
$action = 'Deploy automation Key Vault via infra/modules/keyvault.bicep'

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
$vaultId = $outputs.vaultId.value
$vaultUri = $outputs.vaultUri.value

Write-Information '' -InformationAction Continue
Write-Information ('vaultId  : {0}' -f $vaultId) -InformationAction Continue
Write-Information ('vaultUri : {0}' -f $vaultUri) -InformationAction Continue
Write-Information ("vaultName: {0}" -f $outputs.vaultName.value) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Done. Wave 0 #5b (`scripts/New-AutomationEntraApp.ps1`) creates the Entra apps that 5c will bind to this vault.' -InformationAction Continue

#endregion
