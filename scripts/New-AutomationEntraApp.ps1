#Requires -Version 7.4
<#
.SYNOPSIS
    Create (or reconcile) one of the two automation Entra apps per ADR 0010.

.DESCRIPTION
    Wave 0 item #5b of docs/project-plan.md. Creates one Microsoft Entra
    application registration + service principal + federated credential for
    a single plane, per decision #1-#4 of
    [ADR 0010](../docs/adr/0010-automation-identity-subject-model.md):

      * One app per workflow file. This script runs twice -- once with
        `-Plane control`, once with `-Plane data`.
      * Federated credential subject is
        `repo:<org>/<repo>:environment:<env>`, pulled from
        `automation.githubOrg / automation.githubRepo /
        automation.githubEnvironment` in `infra/parameters/lab.yaml`.
        Per ADR 0058 this is a two-format contract: repositories created
        on or after 2026-07-15 (or renamed/transferred/opted-in after
        that date) mint GitHub's immutable (ID-embedded) subject
        `repo:<org>@<ownerId>/<repo>@<repoId>:environment:<env>` instead.
        The script resolves the numeric IDs at runtime (gh CLI, falling
        back to api.github.com), prefers whichever format the repository
        mints for creation, and accepts either on verification. See
        -SubjectFormat.
      * Single-subject invariant (ADR 0010 decision #4): the app MUST have
        exactly one federated credential with exactly the expected subject,
        issuer, and audiences. The script treats any second credential or
        any mismatched field as an anomaly and fails loudly -- it never
        silently reconciles, because that invariant is the anchor for the
        detection signals cited in the ADR's Consequences section.

    What this script does:

      1. Load and validate the parameters file (ADR 0012).
      2. Resolve the target display name and the expected federated
         credential subject from the file.
      3. `az ad app list` probe for the display name. Create the app if
         missing (single-tenant, no reply URLs, no redirect URIs).
      4. `az ad sp show` probe for the service principal. Create if missing.
      5. `az ad app federated-credential list` probe. Create the
         `gh-env-<env>` credential if missing; verify every field matches
         the ADR 0010 expected shape; fail on any second credential.

    What this script does NOT do (scoped out per project plan 5b):

      * No role assignments (Azure RM, Graph app roles, Purview RBAC). Those
        ship with the scripts that need them -- 5c for the data-plane Key
        Vault RBAC, and later Wave 0 items (3, 4, a.1) for the M365 /
        Purview scopes. This script's only output is an authenticatable
        identity.
      * No certificate. 5c (`scripts/New-AutomationCertificate.ps1`) adds
        the data-plane certificate credential; the control-plane app stays
        cert-free per ADR 0011 decision #5.
      * No client secret, no `ref:` subject, no `pull_request` subject, no
        `job_workflow_ref:` subject. ADR 0010 decision #4 forbids every one
        of them.
      * No idempotent `Deploy-*.ps1` reconciler contract. This is an
        imperative primitive matching 5a's shape, so the four-switch
        contract (`-WhatIf` / `-PruneMissing` / `-Force` / `-ExportCurrentState`)
        in .github/instructions/powershell.instructions.md does not apply.

    References (Learn):
      Workload identity federation overview:
        https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation
      Configure an app to trust an external IdP:
        https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust
      Configuring OpenID Connect in Azure (GitHub side):
        https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure
      OIDC subject claim formats:
        https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect
      Immutable subject claims (ADR 0058):
        https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
        https://docs.github.com/en/actions/reference/security/oidc
      Get a repository (numeric owner/repo IDs):
        https://docs.github.com/en/rest/repos/repos#get-a-repository
      az ad app:
        https://learn.microsoft.com/en-us/cli/azure/ad/app
      az ad app federated-credential:
        https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential
      az ad sp:
        https://learn.microsoft.com/en-us/cli/azure/ad/sp

.PARAMETER Plane
    Which automation app to reconcile. `control` targets
    `automation.apps.controlPlane.displayName`; `data` targets
    `automation.apps.dataPlane.displayName`. Mandatory -- the script is
    single-app-per-invocation by design (ADR 0010 decision #1).

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER DisplayName
    Override the Entra app display name. When omitted (the default), the
    name is read from `automation.apps.<plane>Plane.displayName:` in the
    parameters file. Override only for experimental or non-lab runs.

.PARAMETER SubjectFormat
    Which OIDC subject format to prefer for the federated credential
    (ADR 0058). `auto` (default) resolves the repository's numeric
    identity and creation date at runtime and prefers the immutable
    (ID-embedded) format when the repository was created on or after
    GitHub's 2026-07-15 cutoff, falling back to classic with a warning
    when the identity cannot be resolved. `immutable` forces the
    ID-embedded format (for pre-cutoff repositories that opted in, or
    were renamed/transferred after the cutoff -- both invisible to the
    creation-date heuristic); identity-resolution failure is then a hard
    error. `classic` pins the name-only format and skips GitHub API
    resolution entirely. Verification accepts either format regardless of
    the preference; the preference decides what a newly created
    credential gets.

.EXAMPLE
    ./scripts/New-AutomationEntraApp.ps1 -Plane control -WhatIf

    Prints the planned Entra writes for the control-plane app without
    creating anything.

.EXAMPLE
    ./scripts/New-AutomationEntraApp.ps1 -Plane control
    ./scripts/New-AutomationEntraApp.ps1 -Plane data

    Creates (or reconciles) both automation apps in a single lab session.

.NOTES
    Caller role requirement: an Entra role that permits creating
    application registrations -- `Application Administrator` or
    `Cloud Application Administrator`, per [Least privileged roles by task](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/delegate-by-task#application-registrations).
    `Application Developer` is insufficient because this script also
    creates the service principal and the federated credential.

    Output: prints the app's `appId`, the service principal's `objectId`,
    and the federated credential's `id`. These values are intentionally
    printed rather than captured to a file -- 5c and the workflow edits that
    consume them need to be deliberate about how they flow through GitHub
    Secrets. No credential material is printed because none is created.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('control', 'data')]
    [string]$Plane,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ParametersFile,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9\-]{1,62}[A-Za-z0-9]$')]
    [string]$DisplayName,

    [Parameter()]
    [ValidateSet('auto', 'classic', 'immutable')]
    [string]$SubjectFormat = 'auto'
)

$ErrorActionPreference = 'Stop'

#region Helpers (AST-extractable for unit tests)

# ADR 0058: GitHub's default-format cutoff. Repositories created on or
# after 2026-07-15 mint immutable (ID-embedded) OIDC subjects by default;
# older repositories keep the classic format unless renamed, transferred,
# or explicitly opted in. Pure function so the cutoff is test-pinned.
# Reference: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
function Test-ImmutableSubjectDefault {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [datetime]$CreatedAt
    )

    $cutoffUtc = [datetime]::SpecifyKind([datetime]'2026-07-15T00:00:00', [System.DateTimeKind]::Utc)
    return ($CreatedAt.ToUniversalTime() -ge $cutoffUtc)
}

# Resolve the repository's numeric owner and repository IDs (plus the
# creation date the auto-detection heuristic needs) from the GitHub API.
# Prefers the gh CLI (honors its authentication, so private repositories
# work); falls back to an unauthenticated api.github.com request, which
# suffices for public repositories. Returns $null (with a warning) on any
# failure -- callers decide whether that is fatal (ADR 0058: fatal only
# under -SubjectFormat immutable).
# Reference: https://docs.github.com/en/rest/repos/repos#get-a-repository
function Resolve-GitHubRepoIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Org,

        [Parameter(Mandatory)]
        [string]$Repo
    )

    $json = $null
    $ghCmd = Get-Command -Name 'gh' -ErrorAction SilentlyContinue
    if ($ghCmd) {
        $raw = & $ghCmd api "repos/$Org/$Repo" 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $json = ($raw -join "`n") | ConvertFrom-Json
        }
    }
    if (-not $json) {
        try {
            # Reference: https://docs.github.com/en/rest/repos/repos#get-a-repository
            $json = Invoke-RestMethod -Uri "https://api.github.com/repos/$Org/$Repo" -Method Get `
                -Headers @{ Accept = 'application/vnd.github+json' } -ErrorAction Stop
        }
        catch {
            Write-Warning ("Could not resolve the GitHub repository identity for '{0}/{1}' via gh or api.github.com: {2}" -f $Org, $Repo, $_.Exception.Message)
            return $null
        }
    }
    if (-not $json -or -not $json.id -or -not $json.owner -or -not $json.owner.id) {
        Write-Warning ("GitHub API response for '{0}/{1}' did not carry the numeric owner/repo IDs; cannot compute the immutable OIDC subject." -f $Org, $Repo)
        return $null
    }
    return [ordered]@{
        OwnerId   = [string]$json.owner.id
        RepoId    = [string]$json.id
        CreatedAt = [datetime]$json.created_at
    }
}

# ADR 0058 two-format subject contract for one org/repo/environment. Pure
# function: computes the classic candidate, the immutable candidate (when
# the numeric IDs are known), the acceptance set for verification, and --
# only when the IDs are NOT known -- a shape-only pattern that lets an
# immutable-format credential for the right names pass with a warning.
# Reference: https://docs.github.com/en/actions/reference/security/oidc
function Get-AutomationExpectedSubject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Org,

        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$Environment,

        [Parameter()]
        [string]$OwnerId,

        [Parameter()]
        [string]$RepoId,

        [Parameter()]
        [switch]$PreferImmutableSubject
    )

    $subjectClassic = 'repo:{0}/{1}:environment:{2}' -f $Org, $Repo, $Environment
    $subjectImmutable = $null
    if ($OwnerId -and $RepoId) {
        $subjectImmutable = 'repo:{0}@{1}/{2}@{3}:environment:{4}' -f $Org, $OwnerId, $Repo, $RepoId, $Environment
    }
    if ($PreferImmutableSubject -and -not $subjectImmutable) {
        throw "PreferImmutableSubject requires the numeric OwnerId and RepoId (ADR 0058). Resolve them first (gh api repos/$Org/$Repo) or drop the preference."
    }

    $subjects = @($subjectClassic)
    if ($subjectImmutable) { $subjects += $subjectImmutable }

    $subjectPattern = $null
    if (-not $subjectImmutable) {
        $subjectPattern = '^repo:{0}@[0-9]+/{1}@[0-9]+:environment:{2}$' -f `
            [regex]::Escape($Org), [regex]::Escape($Repo), [regex]::Escape($Environment)
    }

    return [ordered]@{
        Subject          = if ($PreferImmutableSubject) { $subjectImmutable } else { $subjectClassic }
        SubjectClassic   = $subjectClassic
        SubjectImmutable = $subjectImmutable
        Subjects         = $subjects
        SubjectPattern   = $subjectPattern
    }
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

# Validate the automation block's shape up-front. Every missing key is a
# named, actionable failure -- never a downstream null-reference crash.
if (-not $parameters.ContainsKey('automation')) {
    Write-Error ("Parameters file '{0}' is missing required top-level key 'automation'. Reference: docs/adr/0012-environment-parameters-file.md and docs/adr/0010-automation-identity-subject-model.md." -f $ParametersFile)
    return
}
$automation = $parameters.automation
foreach ($key in @('githubOrg', 'githubRepo', 'githubEnvironment', 'apps')) {
    if (-not $automation.ContainsKey($key)) {
        Write-Error ("Parameters file '{0}' is missing required key 'automation.{1}'. Reference: docs/adr/0010-automation-identity-subject-model.md decision #2." -f $ParametersFile, $key)
        return
    }
}
$planeKey = if ($Plane -eq 'control') { 'controlPlane' } else { 'dataPlane' }
if (-not $automation.apps.ContainsKey($planeKey)) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.{1}'. Reference: docs/adr/0010-automation-identity-subject-model.md decision #1." -f $ParametersFile, $planeKey)
    return
}
if (-not $automation.apps[$planeKey].ContainsKey('displayName')) {
    Write-Error ("Parameters file '{0}' is missing required key 'automation.apps.{1}.displayName'. Reference: docs/adr/0010-automation-identity-subject-model.md decision #1." -f $ParametersFile, $planeKey)
    return
}

# Resolve values. Explicit CLI parameter wins per ADR 0012.
$githubOrg = [string]$automation.githubOrg
$githubRepo = [string]$automation.githubRepo
$githubEnv = [string]$automation.githubEnvironment
if (-not $DisplayName) { $DisplayName = [string]$automation.apps[$planeKey].displayName }

# Expected federated credential shape per ADR 0010 decision #2, widened
# to the ADR 0058 two-format contract. The preferred format decides what
# a freshly created credential gets; verification accepts either.
$preferImmutable = $false
$repoIdentity = $null
if ($SubjectFormat -ne 'classic') {
    $repoIdentity = Resolve-GitHubRepoIdentity -Org $githubOrg -Repo $githubRepo
    if ($SubjectFormat -eq 'immutable') {
        if (-not $repoIdentity) {
            Write-Error 'SubjectFormat immutable requires the numeric GitHub owner/repo IDs, and they could not be resolved (see the warning above). Authenticate gh (gh auth login) or restore network access, then re-run. ADR 0058.'
            return
        }
        $preferImmutable = $true
    }
    elseif ($repoIdentity) {
        # auto: prefer the format the repository actually mints. Created on
        # or after GitHub's 2026-07-15 cutoff -> immutable by default.
        $preferImmutable = Test-ImmutableSubjectDefault -CreatedAt $repoIdentity.CreatedAt
    }
    else {
        Write-Warning 'Could not resolve the GitHub repository identity; assuming the classic OIDC subject format. If this repository was created on or after 2026-07-15, or was renamed/transferred/opted in to immutable subject claims, re-run with -SubjectFormat immutable once gh is authenticated (ADR 0058).'
    }
}

$expectedShape = if ($repoIdentity) {
    Get-AutomationExpectedSubject -Org $githubOrg -Repo $githubRepo -Environment $githubEnv `
        -OwnerId $repoIdentity.OwnerId -RepoId $repoIdentity.RepoId -PreferImmutableSubject:$preferImmutable
}
else {
    Get-AutomationExpectedSubject -Org $githubOrg -Repo $githubRepo -Environment $githubEnv
}
$expectedSubject = $expectedShape.Subject
$expectedIssuer = 'https://token.actions.githubusercontent.com'
$expectedAudiences = @('api://AzureADTokenExchange')
$expectedFcName = "gh-env-${githubEnv}"

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("Plane: {0}" -f $Plane) -InformationAction Continue
Write-Information ("App display name: {0}" -f $DisplayName) -InformationAction Continue
Write-Information ("Federated credential name: {0}" -f $expectedFcName) -InformationAction Continue
Write-Information ("Subject format: {0} (preferred: {1})" -f $SubjectFormat, $(if ($preferImmutable) { 'immutable' } else { 'classic' })) -InformationAction Continue
Write-Information ("Federated credential subject: {0}" -f $expectedSubject) -InformationAction Continue

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
    Write-Error ("Found {0} Entra applications with display name '{1}'. ADR 0010 decision #1 mandates a single app per display name. Remove the duplicates manually (preserve the one with a federated credential matching subject '{2}') and re-run." -f $appList.Count, $DisplayName, $expectedSubject)
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

$target = "Entra application '$DisplayName' + service principal + federated credential '$expectedFcName'"
$action = "Ensure plane '$Plane' automation identity per ADR 0010"

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
    Write-Information '' -InformationAction Continue
    Write-Information '-WhatIf specified. Planned writes:' -InformationAction Continue
    if (-not $app) {
        Write-Information ("  + Create application '{0}' (single-tenant, no redirect URIs)." -f $DisplayName) -InformationAction Continue
        Write-Information ("  + Create service principal for the new app.") -InformationAction Continue
        Write-Information ("  + Create federated credential '{0}' with subject '{1}'." -f $expectedFcName, $expectedSubject) -InformationAction Continue
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

# Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential#az-ad-app-federated-credential-list
$fcListJson = az ad app federated-credential list --id $appObjectId -o json --only-show-errors
if ($LASTEXITCODE -ne 0) {
    Write-Error "az ad app federated-credential list failed with exit code $LASTEXITCODE."
    return
}
$fcList = @()
if ($fcListJson) {
    $fcList = @(($fcListJson -join "`n") | ConvertFrom-Json)
}

# ADR 0010 decision #4 single-subject invariant: the app must carry
# exactly zero (then we create one) or exactly one credential -- and that
# one must match the expected shape. Any second credential is an anomaly.
if ($fcList.Count -gt 1) {
    $names = ($fcList | ForEach-Object { $_.name }) -join ', '
    Write-Error ("Application '{0}' has {1} federated credentials ({2}). ADR 0010 decision #4 mandates a single-subject invariant. Remove extra credentials manually and re-run; the presence of any additional credential is itself an anomaly signal called out in the ADR's Consequences section." -f $DisplayName, $fcList.Count, $names)
    return
}

if ($fcList.Count -eq 1) {
    $fc = $fcList[0]

    # Verify every expected field. Any mismatch is a named failure -- the
    # script refuses to mutate a credential whose shape differs from the
    # ADR. Operator must reconcile by hand.
    $mismatches = @()
    $nameMismatch = $false
    if ($fc.name -ne $expectedFcName) {
        $nameMismatch = $true
    }
    if ($fc.issuer -ne $expectedIssuer) {
        $mismatches += "issuer: expected '$expectedIssuer', actual '$($fc.issuer)'"
    }
    # ADR 0058: either subject format passes verification -- the classic
    # candidate, the exact immutable candidate (when the numeric IDs
    # resolved), or, only when they did not, an immutable-format subject
    # matching the org/repo/environment shape (accepted with a warning).
    $subjectOk = $expectedShape.Subjects -contains $fc.subject
    if (-not $subjectOk -and $expectedShape.SubjectPattern -and $fc.subject -match $expectedShape.SubjectPattern) {
        $subjectOk = $true
        Write-Warning ("Application '{0}' federated credential subject '{1}' matches the immutable-format shape for this repo/environment, but the numeric owner/repo IDs could not be resolved for exact verification (offline, or unauthenticated against a private repo). Authenticate gh (gh auth login) and re-run to verify the IDs exactly (ADR 0058)." -f $DisplayName, $fc.subject)
    }
    if (-not $subjectOk) {
        $mismatches += "subject: expected '$($expectedShape.Subjects -join "' or '")', actual '$($fc.subject)'"
    }
    $actualAudiences = @($fc.audiences)
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
        Write-Error ("Application '{0}' has a federated credential whose shape does not match ADR 0010 decision #2. Mismatches: {1}. Refusing to mutate; reconcile manually." -f $DisplayName, ($mismatches -join '; '))
        return
    }

    if ($nameMismatch) {
        # ADR 0057 repository-migration cutover: a temporary credential may
        # carry a non-canonical name (for example gh-env-lab-ops) while the
        # issuer/subject/audiences already match. The name is advisory; only
        # subject/issuer/audiences are security-critical. Canonicalize later
        # by deleting the credential and re-running this script (ADR 0057 section 7).
        Write-Warning ("Application '{0}' federated credential name is '{1}' (expected canonical name '{2}'). Subject/issuer/audiences match -- continuing. To canonicalize: delete the credential and re-run this script." -f $DisplayName, $fc.name, $expectedFcName)
    }

    if ($preferImmutable -and $fc.subject -eq $expectedShape.SubjectClassic) {
        # ADR 0058 decision #5: valid shape, but dormant -- this repository
        # mints immutable subjects, so azure/login can never match a
        # classic credential. Never silently rewritten (ADR 0010).
        Write-Warning ("Application '{0}' carries the CLASSIC subject '{1}', but this repository mints IMMUTABLE subjects -- azure/login will fail with AADSTS700213 until the credential is cut over. Cutover: delete the credential and re-run this script (it will mint '{2}'), or follow the bounded add-verify-remove window in ADR 0057 section 7. ADR 0058." -f $DisplayName, $fc.subject, $expectedShape.SubjectImmutable)
    }

    Write-Information ("  = Federated credential matches ADR 0010 (id: {0})." -f $fc.id) -InformationAction Continue
    $fcId = $fc.id
}
else {
    # Create the credential. `--parameters` expects an inline JSON string or
    # `@file.json`; inline is easier to audit here and avoids temp files.
    # Reference: https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential#az-ad-app-federated-credential-create
    $fcBody = [ordered]@{
        name        = $expectedFcName
        issuer      = $expectedIssuer
        subject     = $expectedSubject
        description = "ADR 0010: repo:${githubOrg}/${githubRepo} environment:${githubEnv}"
        audiences   = $expectedAudiences
    }
    $fcBodyJson = $fcBody | ConvertTo-Json -Compress -Depth 4

    # Write to a temp file to avoid quoting hell in pwsh -> az CLI hand-off.
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
    Write-Information ("  + Created federated credential '{0}' (id: {1})." -f $expectedFcName, $fcId) -InformationAction Continue
}

#endregion

#region Output

Write-Information '' -InformationAction Continue
Write-Information ('appId                   : {0}' -f $appId) -InformationAction Continue
Write-Information ('application objectId    : {0}' -f $appObjectId) -InformationAction Continue
Write-Information ('servicePrincipal objectId: {0}' -f $sp.id) -InformationAction Continue
Write-Information ('federatedCredential id  : {0}' -f $fcId) -InformationAction Continue
Write-Information '' -InformationAction Continue

if ($Plane -eq 'control') {
    Write-Information 'Next: `./scripts/New-AutomationEntraApp.ps1 -Plane data` to create the data-plane app, then Wave 0 #5c (`scripts/New-AutomationCertificate.ps1`) to attach the data-plane certificate.' -InformationAction Continue
}
else {
    Write-Information 'Next: Wave 0 #5c (`scripts/New-AutomationCertificate.ps1`) attaches the certificate credential to this data-plane app and assigns the required Key Vault RBAC.' -InformationAction Continue
}

#endregion
