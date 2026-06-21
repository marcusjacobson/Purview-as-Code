#Requires -Version 7.4
<#
.SYNOPSIS
    Deploy the lab Log Analytics workspace via infra/modules/law.bicep.

.DESCRIPTION
    Wave 0 item #5.0 of docs/project-plan.md. Creates the lab Log Analytics
    workspace required as the target for the automation Key Vault's
    `AuditEvent` diagnostic sink (ADR 0011 decision §2). The workspace's
    resource ID is consumed by 5a (`scripts/New-AutomationKeyVault.ps1`) when
    it wires a `Microsoft.Insights/diagnosticSettings` child onto the Key Vault.

    This script is a **thin orchestrator** around the Bicep module, not a
    `Deploy-*.ps1` reconciler:

      * Idempotency: an `az resource show` probe reports NoChange when the
        workspace already exists with the intended shape; otherwise Bicep's
        declarative deployment handles create/update.
      * WhatIf: honoured via `[CmdletBinding(SupportsShouldProcess)]`. A
        `-WhatIf` run always executes `az deployment group what-if` and prints
        the result; it does not call `az deployment group create`.
      * No `-PruneMissing` / `-Force` / `-ExportCurrentState` — the four-switch
        reconciler contract in .github/instructions/powershell.instructions.md
        applies only to `Deploy-*.ps1` scripts that reconcile YAML against a
        mutable catalog. This script manages a single Azure resource.

    References:
      https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces
      https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli
      https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if
      https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess

    All environment-varying values (resource group, region, workspace name,
    retention, SKU) come from `infra/parameters/lab.yaml` per ADR 0012.
    Every value is independently overridable on the command line.

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root. Every
    value this script needs is read from that file unless explicitly
    overridden by one of the per-value parameters below. Reference:
    docs/adr/0012-environment-parameters-file.md.

.PARAMETER ResourceGroupName
    Resource group that owns the workspace. When omitted, resolved from
    `resourceGroupName:` in the parameters file.

.PARAMETER WorkspaceName
    Log Analytics workspace name. When omitted, resolved from
    `resources.logAnalytics.name:` in the parameters file.

.PARAMETER Location
    Azure region. When omitted, resolved from `location:` in the parameters
    file.

.PARAMETER RetentionInDays
    Data retention in days. When omitted, resolved from
    `resources.logAnalytics.retentionInDays:` in the parameters file.

.PARAMETER SkuName
    Workspace SKU. When omitted, resolved from
    `resources.logAnalytics.skuName:` in the parameters file.

.EXAMPLE
    ./scripts/New-LogAnalyticsWorkspace.ps1 -WhatIf

    Prints an `az deployment group what-if` plan for the lab workspace using
    values from `infra/parameters/lab.yaml` and makes no writes.

.EXAMPLE
    ./scripts/New-LogAnalyticsWorkspace.ps1

    Deploys (or updates) the lab workspace per `infra/parameters/lab.yaml`.
    Re-run is a no-op once the workspace matches the module's shape.

.EXAMPLE
    ./scripts/New-LogAnalyticsWorkspace.ps1 -ParametersFile infra/parameters/prod.yaml

    Deploys the workspace defined by a non-lab environment file. Explicit
    per-value parameters still override file values.

.NOTES
    Caller role requirement: `Contributor` (or `Log Analytics Contributor`) at
    the resource-group scope. No data-plane permission is required to create
    the workspace; 5a will add the diagnostic settings later via its own
    deployment.
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
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{2,61}[A-Za-z0-9]$')]
    [string]$WorkspaceName,

    [Parameter()]
    [string]$Location,

    [Parameter()]
    [ValidateRange(30, 730)]
    [Nullable[int]]$RetentionInDays,

    [Parameter()]
    [ValidateSet('PerGB2018', 'CapacityReservation', 'LACluster')]
    [string]$SkuName
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
if (-not $parameters.resources.ContainsKey('logAnalytics')) {
    Write-Error ("Parameters file '{0}' is missing required key 'resources.logAnalytics'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile)
    return
}
foreach ($key in @('name', 'retentionInDays', 'skuName')) {
    if (-not $parameters.resources.logAnalytics.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'resources.logAnalytics.{1}'. Reference: docs/adr/0012-environment-parameters-file.md." -f $ParametersFile, $key)
        return
    }
}

# Resolution order per ADR 0012: explicit CLI parameter wins; otherwise read
# the value from the parameters file.
if (-not $ResourceGroupName) { $ResourceGroupName = [string]$parameters.resourceGroupName }
if (-not $Location)          { $Location          = [string]$parameters.location }
if (-not $WorkspaceName)     { $WorkspaceName     = [string]$parameters.resources.logAnalytics.name }
if ($null -eq $RetentionInDays) { $RetentionInDays = [int]$parameters.resources.logAnalytics.retentionInDays }
if (-not $SkuName)           { $SkuName           = [string]$parameters.resources.logAnalytics.skuName }

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue

#endregion

#region Module path resolution

$moduleBicep = Join-Path $repoRoot 'infra/modules/law.bicep'
if (-not (Test-Path -LiteralPath $moduleBicep)) {
    Write-Error "Bicep module not found at $moduleBicep. Expected path: <repo>/infra/modules/law.bicep."
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
# `az` returns the JSON body as a string[] (one element per line) in pwsh 7+;
# join before passing to ConvertFrom-Json.
$account = ($accountJson -join "`n") | ConvertFrom-Json
Write-Information ("Subscription: {0} ({1})" -f $account.name, $account.id) -InformationAction Continue

# Reference: https://learn.microsoft.com/en-us/cli/azure/group#az-group-show
$rgJson = az group show --name $ResourceGroupName -o json --only-show-errors 2>$null
if (-not $rgJson) {
    Write-Error ("Resource group '{0}' was not found in subscription '{1}'. Create it first with `az group create -n {0} -l {2}` or verify you are in the right subscription." -f $ResourceGroupName, $account.id, $Location)
    return
}

#endregion

#region Idempotency probe

# Reference: https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-show
$existingJson = az resource show `
    --resource-type 'Microsoft.OperationalInsights/workspaces' `
    --name $WorkspaceName `
    --resource-group $ResourceGroupName `
    -o json `
    --only-show-errors 2>$null

$alreadyExists = [bool]$existingJson
if ($alreadyExists) {
    $existing = ($existingJson -join "`n") | ConvertFrom-Json
    Write-Information ("NoChange probe: workspace '{0}' already exists in '{1}' (resource id: {2})." -f $WorkspaceName, $ResourceGroupName, $existing.id) -InformationAction Continue
    Write-Information 'Proceeding with Bicep deployment so the module reconciles any drift in SKU, retention, cap, or network access.' -InformationAction Continue
}
else {
    Write-Information ("Create probe: workspace '{0}' does not exist in '{1}'. A full deployment will run." -f $WorkspaceName, $ResourceGroupName) -InformationAction Continue
}

#endregion

#region Deployment

# Use a deterministic deployment name so re-runs update the same deployment
# record rather than fan out 500 entries in the resource group history.
$deploymentName = "law-$WorkspaceName"

$parameterArgs = @(
    "workspaceName=$WorkspaceName",
    "location=$Location",
    "skuName=$SkuName",
    "retentionInDays=$RetentionInDays"
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

$target = "workspace '$WorkspaceName' in resource group '$ResourceGroupName'"
$action = 'Deploy Log Analytics workspace via infra/modules/law.bicep'

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
$workspaceId = $outputs.workspaceId.value
$customerId = $outputs.customerId.value

Write-Information '' -InformationAction Continue
Write-Information ('workspaceId  : {0}' -f $workspaceId) -InformationAction Continue
Write-Information ('customerId   : {0}' -f $customerId) -InformationAction Continue
Write-Information ("workspaceName: {0}" -f $outputs.workspaceName.value) -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'Done. Feed `workspaceId` into Wave 0 #5a (`scripts/New-AutomationKeyVault.ps1`) as the diagnostic-settings target.' -InformationAction Continue

#endregion
