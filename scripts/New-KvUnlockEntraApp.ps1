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
         `automation.apps.kvUnlock.githubEnvironment`. Per ADR 0058 the
         subject is a two-format contract: the classic
         `repo:<org>/<repo>:environment:<env>` form and GitHub's immutable
         (ID-embedded) form
         `repo:<org>@<ownerId>/<repo>@<repoId>:environment:<env>`.
         Repositories created on or after 2026-07-15 (and repos
         renamed/transferred/opted-in after that date) mint the immutable
         form; the script resolves the numeric IDs at runtime (gh CLI,
         falling back to api.github.com) and prefers whichever format the
         repository mints. See -SubjectFormat.
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
      Immutable subject claims (ADR 0058):
        https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
        https://docs.github.com/en/actions/reference/security/oidc
      Get a repository (numeric owner/repo IDs):
        https://docs.github.com/en/rest/repos/repos#get-a-repository
      az ad app:
        https://learn.microsoft.com/en-us/cli/azure/ad/app
      az ad app federated-credential:
        https://learn.microsoft.com/en-us/cli/azure/ad/ad-app-federated-credential
      az ad sp:
        https://learn.microsoft.com/en-us/cli/azure/ad/sp

.PARAMETER ParametersFile
    Path to the environment parameters YAML file (ADR 0012). Defaults to
    `infra/parameters/lab.yaml` resolved relative to the repo root.
    When the parameter is omitted, the PURVIEW_PARAMETERS_FILE environment
    variable (ADR 0057) takes precedence over the lab default.

.PARAMETER DisplayName
    Override the Entra app display name. When omitted (the default), the
    name is read from `automation.apps.kvUnlock.displayName:` in the
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
        [string]$DisplayNameOverride,

        # ADR 0058: numeric GitHub owner/repo IDs (from
        # Resolve-GitHubRepoIdentity). When both are present the immutable
        # (ID-embedded) subject candidate is computed alongside the classic
        # one; when absent, verification falls back to a shape-only pattern
        # for immutable-format credentials.
        [Parameter()]
        [string]$OwnerId,

        [Parameter()]
        [string]$RepoId,

        # Prefer the immutable subject for credential CREATION. Requires
        # OwnerId + RepoId. Verification always accepts both formats.
        [Parameter()]
        [switch]$PreferImmutableSubject
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
    # ADR 0058 widens this to a two-format contract: classic
    # (name-based) and immutable (numeric-ID-embedded; the '@' delimiter is
    # legal because it cannot appear in a GitHub username or repo name).
    # Reference: https://docs.github.com/en/actions/reference/security/oidc
    $subjectClassic = 'repo:{0}/{1}:environment:{2}' -f $githubOrg, $githubRepo, $githubEnv
    $subjectImmutable = $null
    if ($OwnerId -and $RepoId) {
        $subjectImmutable = 'repo:{0}@{1}/{2}@{3}:environment:{4}' -f $githubOrg, $OwnerId, $githubRepo, $RepoId, $githubEnv
    }
    if ($PreferImmutableSubject -and -not $subjectImmutable) {
        throw "PreferImmutableSubject requires the numeric OwnerId and RepoId (ADR 0058). Resolve them first (gh api repos/$githubOrg/$githubRepo) or drop the preference."
    }

    $subjects = @($subjectClassic)
    if ($subjectImmutable) { $subjects += $subjectImmutable }

    # Shape-only fallback for verification when the numeric IDs are not
    # available (offline / unauthenticated against a private repo): an
    # immutable-format subject for the RIGHT org/repo/environment is
    # accepted with a warning rather than hard-refused (ADR 0058
    # decision #4). Never built when the IDs resolved -- then only the
    # exact candidates match.
    $subjectPattern = $null
    if (-not $subjectImmutable) {
        $subjectPattern = '^repo:{0}@[0-9]+/{1}@[0-9]+:environment:{2}$' -f `
            [regex]::Escape($githubOrg), [regex]::Escape($githubRepo), [regex]::Escape($githubEnv)
    }

    return [ordered]@{
        DisplayName      = $resolvedDisplayName
        FcName           = "gh-env-$githubEnv"
        Subject          = if ($PreferImmutableSubject) { $subjectImmutable } else { $subjectClassic }
        SubjectClassic   = $subjectClassic
        SubjectImmutable = $subjectImmutable
        Subjects         = $subjects
        SubjectPattern   = $subjectPattern
        Issuer           = 'https://token.actions.githubusercontent.com'
        Audiences        = @('api://AzureADTokenExchange')
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
    $nameMismatch = $false
    if ($fc.name -ne $Expected.FcName) {
        $nameMismatch = $true
    }
    if ($fc.issuer -ne $Expected.Issuer) {
        $mismatches += "issuer: expected '$($Expected.Issuer)', actual '$($fc.issuer)'"
    }
    # ADR 0058: either subject format passes verification -- the classic
    # candidate, the exact immutable candidate (when the numeric IDs
    # resolved), or, only when they did not, an immutable-format subject
    # matching the org/repo/environment shape (accepted with a warning).
    $acceptedSubjects = @($Expected['Subjects'] | Where-Object { $_ })
    if ($acceptedSubjects.Count -eq 0) { $acceptedSubjects = @($Expected['Subject']) }
    $subjectOk = $acceptedSubjects -contains $fc.subject
    if (-not $subjectOk -and $Expected['SubjectPattern'] -and $fc.subject -match $Expected['SubjectPattern']) {
        $subjectOk = $true
        Write-Warning ("Application '$DisplayName' federated credential subject '$($fc.subject)' matches the immutable-format shape for this repo/environment, but the numeric owner/repo IDs could not be resolved for exact verification (offline, or unauthenticated against a private repo). Authenticate gh (gh auth login) and re-run to verify the IDs exactly (ADR 0058).")
    }
    if (-not $subjectOk) {
        $mismatches += "subject: expected '$($acceptedSubjects -join "' or '")', actual '$($fc.subject)'"
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

    if ($nameMismatch) {
        Write-Warning ("Application '$DisplayName' federated credential name is '$($fc.name)' (expected canonical name '$($Expected.FcName)'). Subject/issuer/audiences match -- continuing. To canonicalize: delete the credential and re-run this script (ADR 0057 section 7).")
    }

    return $fc
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

# First pass validates the parameters file shape and yields the classic
# candidates; a second pass below folds in the numeric repo identity when
# the selected -SubjectFormat calls for it (ADR 0058).
$expected = Get-KvUnlockExpectedShape -Parameters $parameters -DisplayNameOverride $DisplayName
$DisplayName = $expected.DisplayName

$preferImmutable = $false
if ($SubjectFormat -ne 'classic') {
    $repoIdentity = Resolve-GitHubRepoIdentity -Org ([string]$parameters.automation.githubOrg) -Repo ([string]$parameters.automation.githubRepo)
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
    if ($repoIdentity) {
        $expected = Get-KvUnlockExpectedShape -Parameters $parameters -DisplayNameOverride $DisplayName `
            -OwnerId $repoIdentity.OwnerId -RepoId $repoIdentity.RepoId -PreferImmutableSubject:$preferImmutable
    }
}

Write-Information ("Parameters file: {0}" -f $ParametersFile) -InformationAction Continue
Write-Information ("Environment: {0}" -f $parameters.environment) -InformationAction Continue
Write-Information ("App display name: {0}" -f $DisplayName) -InformationAction Continue
Write-Information ("Federated credential name: {0}" -f $expected.FcName) -InformationAction Continue
Write-Information ("Subject format: {0} (preferred: {1})" -f $SubjectFormat, $(if ($preferImmutable) { 'immutable' } else { 'classic' })) -InformationAction Continue
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
    if ($preferImmutable -and $existingFc.subject -eq $expected.SubjectClassic) {
        # ADR 0058 decision #5: valid shape, but dormant -- this repository
        # mints immutable subjects, so azure/login can never match a
        # classic credential. Never silently rewritten (ADR 0010).
        Write-Warning ("Application '{0}' carries the CLASSIC subject '{1}', but this repository mints IMMUTABLE subjects -- azure/login will fail with AADSTS700213 until the credential is cut over. Cutover: delete the credential and re-run this script (it will mint '{2}'), or follow the bounded add-verify-remove window in ADR 0057 section 7. ADR 0058." -f $DisplayName, $existingFc.subject, $expected.SubjectImmutable)
    }
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
