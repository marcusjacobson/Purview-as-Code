---
description: "Secure-by-design rules for PowerShell helper scripts that call the Purview REST APIs."
applyTo: "scripts/**/*.ps1"
---

# PowerShell script secure-by-design rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md), including the **Microsoft Learn is the central source of truth** rule.

## Grounding — PowerShell, Az CLI, and REST calls must be verified against Microsoft Learn

Before adding or modifying any cmdlet, `az` command, REST URI, or request/response shape:

- Verify cmdlet signature, parameters, and output against the current Learn reference: [Az PowerShell module reference](https://learn.microsoft.com/en-us/powershell/module/?view=azps-latest), [Microsoft.PowerShell.* modules](https://learn.microsoft.com/en-us/powershell/module/).
- Verify `az` CLI commands against [Azure CLI reference](https://learn.microsoft.com/en-us/cli/azure/reference-index). Do not invent flags or use deprecated ones remembered from training data.
- Verify Purview data-plane REST endpoints, paths, request bodies, and API versions against [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/) and the auth flow in [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).
- PowerShell language features and style: [PowerShell documentation](https://learn.microsoft.com/en-us/powershell/scripting/overview), [about_CommonParameters](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_commonparameters).
- Every non-trivial cmdlet, `az` invocation, or `Invoke-RestMethod` call must carry a nearby comment with the Learn URL used to author it.
- If a command, parameter, or endpoint is not documented on Learn, do not silently emit it. Note the gap, cite the closest adjacent Learn page, and mark `# TODO: not-on-Learn` for human review.

## Authentication

- Always acquire tokens via `az account get-access-token --resource <audience>` (works with OIDC in Actions and `az login` locally). Never call `Connect-AzAccount -ServicePrincipal -Credential` with a hard-coded secret.
- Do not pass `-AsPlainText` to `ConvertTo-SecureString` on literal strings. Convert from input parameters or environment variables only.
- Token resources: `https://management.azure.com` for ARM; `https://purview.azure.net` for Purview data plane. Source: [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane).
- Never log, `Write-Host`, `Write-Output`, or echo a bearer token, client secret, or access key. Mask at the boundary.

## Runtime: pwsh 7.4+ only, and the `Connect-IPPSSession` auth constraint

This repo is **PowerShell 7.4+ (`pwsh`) only**. Windows PowerShell 5.1 is out of scope per [`docs/project-plan.md`](../../docs/project-plan.md) §7. Scripts must not carry 5.1 compatibility shims and CI runners install `pwsh` explicitly. Reference: [What's new in PowerShell 7.4](https://learn.microsoft.com/en-us/powershell/scripting/whats-new/what-s-new-in-powershell-74).

Every `Deploy-*.ps1` / `Grant-*.ps1` script header must declare:

```powershell
#Requires -Version 7.4
```

### `Connect-IPPSSession` / `Connect-ExchangeOnline` are app-only-auth only, via Key Vault-signed access tokens

Scripts in this repo call [`Connect-IPPSSession`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) and [`Connect-ExchangeOnline`](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-exchangeonline) **only** via the `-AccessToken` path, where the token is acquired through the Key Vault-side JWT signing helper [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1). The same `https://outlook.office365.com/.default` token works for both endpoints. The local-PFX `-CertificateThumbprint` path is **superseded** by [ADR 0011 Decision #3 supersession addendum](../../docs/adr/0011-certificate-lifecycle.md) — the lab's automation cert is non-exportable (`keyProperties.exportable = false`), so its private key cannot be loaded into a local cert store. Reference: [App-only authentication for unattended scripts in Exchange Online / Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2).

Pick the endpoint by cmdlet surface, not by perceived category:

- `Connect-ExchangeOnline -AccessToken …` for `Set-AdminAuditLogConfig`, mailbox / recipient cmdlets, and any cmdlet documented in the Exchange Online module (`/powershell/module/exchange/`).
- `Connect-IPPSSession -AccessToken …` for `Get-RoleGroupMember`, eDiscovery, retention / DLP / sensitivity-label cmdlets, and any cmdlet documented in the Exchange Online (Security & Compliance) module (`/powershell/module/exchangepowershell/`).
- Per [Turn auditing on or off](https://learn.microsoft.com/en-us/purview/audit-log-enable-disable), `Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled` runs in Exchange Online PowerShell. `Get-AdminAuditLogConfig` is exposed by both endpoints; `Set-` is EXO-only — empirically verified 2026-04-24.

```powershell
$tok = & "$PSScriptRoot/Get-PurviewIPPSAccessToken.ps1" `
    -VaultName       $vaultName `
    -CertificateName $certificateName `
    -AppId           $appId `
    -TenantId        $tenantId
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline `
    -AccessToken  $tok.AccessToken `
    -Organization $tenantDomain `
    -ShowBanner:$false `
    -ErrorAction  Stop
```

`Connect-ExchangeOnline -AccessToken` requires `ExchangeOnlineManagement` v3.7.0+; `Connect-IPPSSession -AccessToken` requires v3.8.0-Preview1+ (install with `-AllowPrerelease` until GA).

Do not use interactive auth (the parameterless `Connect-ExchangeOnline` / `Connect-IPPSSession`) in any committed script. Interactive auth relies on the Web Account Manager (WAM) runtime, which loads `msalruntime.dll`; that binary is bundled for Windows PowerShell 5.1 but not reliably resolvable from pwsh 7 in every environment. Unattended CI and local contributor runs must both go through the app-only access-token path.

### Local-cert fast path for the dev loop (ADR 0028)

The token helper [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) supports two signing transports, picked at runtime per [ADR 0028](../../docs/adr/0028-co-equal-local-cert-credential.md):

1. **Local cert (`Cert:\CurrentUser\My`)** — selected when either `-LocalCertThumbprint` is passed or `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` is set. The script signs the JWT in-process via RSA-PSS / SHA-256 from the local private key. No Key Vault call, so **no KV unlock window is required**. Used for interactive runs from the lab owner's workstation; provisioned via [`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1).
2. **Key Vault sign (`kv-contoso-lab-01`)** — the original ADR 0011 path, selected when neither the parameter nor the env var is set. Signs the JWT digest via `az keyvault key sign --algorithm PS256`. Every CI workflow uses this transport because hosted GitHub runners have no `Cert:\CurrentUser\My`.

Consumer scripts do **not** need any code change to pick the local path. The token helper resolves the env var transparently, so an interactive run that has `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` set takes the local-cert path automatically; a CI run that does not have it set takes the KV path. See [`docs/runbooks/local-cert-provisioning.md`](../../docs/runbooks/local-cert-provisioning.md) for provisioning, verification, rotation, and revocation.

When the local path is requested but cannot be used (thumbprint missing, no private key, expired), the token helper throws with a named reason — it never silently falls back to KV. This is intentional: a silent fallback would mask a real configuration error and cost the operator a surprise KV-unlock prompt minutes later.

### Session re-use across cmdlet calls

A single script invocation that issues multiple S&C / EXO cmdlets must re-use the existing remote session rather than reconnecting. Open once, call many, disconnect once:

```powershell
$existing = Get-PSSession | Where-Object {
    ($_.ComputerName -like '*compliance.protection.outlook.com*' -or
     $_.ComputerName -like '*outlook.office365.com*') -and
    $_.State -eq 'Opened'
}
if (-not $existing) {
    $tok = & "$PSScriptRoot/Get-PurviewIPPSAccessToken.ps1" `
        -VaultName       $vaultName `
        -CertificateName $certificateName `
        -AppId           $appId `
        -TenantId        $tenantId
    Import-Module ExchangeOnlineManagement
    Connect-ExchangeOnline -AccessToken  $tok.AccessToken `
                           -Organization $tenantDomain `
                           -ShowBanner:$false -ErrorAction Stop
}

try {
    # ... one or many cmdlets ...
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
```

Cold-connect latency is seconds per invocation; a fan-out reconnect pattern turns a one-second drift reconcile into a minute-long CI job.

### Prohibited

- `Connect-ExchangeOnline` / `Connect-IPPSSession` with no parameters (interactive / device-code / WAM).
- `Connect-IPPSSession -Credential $cred` (basic auth deprecated; also fails against modern tenants).
- `-CertificateThumbprint …` or `-Certificate <X509Certificate2>` against the lab automation cert. The cert is non-exportable in Key Vault per ADR 0011 §1; its private key cannot be reconstituted on a runner. Use the `-AccessToken` path described above.
- Any suggestion in a script comment, `.NOTES` block, or README to "run this in Windows PowerShell 5.1 to work around pwsh 7 WAM issues." The workaround for this repo is **always** app-only access-token auth, not a 5.1 downgrade.

## Secrets

- Secrets required at runtime must come from:
  1. GitHub Actions secret injected as an environment variable (`$env:MY_SECRET`), or
  2. Azure Key Vault via `az keyvault secret show` or `Get-AzKeyVaultSecret`.
- Read secrets once into a local `SecureString` / `[System.Net.NetworkCredential]` and drop the plaintext variable as soon as possible.
- Do not persist secrets to disk, temp files, or transcripts. If `Start-Transcript` is used, ensure `Write-*` cmdlets never receive secret values.

## Input validation

- All script parameters that drive API paths (`-AccountName`, `-CollectionName`, `-DataSourceName`, etc.) must have `[ValidateNotNullOrEmpty()]` and, where the Purview resource has a documented name pattern, `[ValidatePattern()]`.
- Never build a URI by string-concatenating unvalidated user input without encoding. Use `[System.Uri]::EscapeDataString()` for path/query segments.
- Do not use `Invoke-Expression`. Do not use the call operator `&` on a variable whose value is user-controlled.

## HTTPS-only, TLS 1.2+

- All REST calls must be `https://`. Never use `http://`.
- If the script overrides `[System.Net.ServicePointManager]::SecurityProtocol`, it must OR-in `Tls12` / `Tls13` — never remove them.
- Do not disable certificate validation (`-SkipCertificateCheck`, `[ServerCertificateValidationCallback] = { $true }`).

## Drift and reconciliation discipline

The `Deploy-*.ps1` scripts reconcile the YAML under `data-plane/**` (desired state) against the live Purview account (current state). The rules below are non-negotiable.

### Default behavior is non-destructive

- Scripts create objects present in YAML but missing in Purview.
- Scripts update objects whose YAML differs from Purview.
- Scripts **do not** delete objects that exist in Purview but not in YAML, unless the caller explicitly opts in.
- Scripts **do not** silently overwrite objects that were last modified by a principal other than the current deploy principal, unless the caller explicitly opts in.

### Required `-ParametersFile` switch on every orchestrator

Every `New-*.ps1` (control-plane imperative primitive) and every `Deploy-*.ps1` (data-plane reconciler) that creates or reconciles an Azure resource or a Purview catalog object must accept a `-ParametersFile <path>` parameter, defaulting to `infra/parameters/lab.yaml` resolved relative to the repo root. This is the source-of-truth contract defined by [ADR 0012](../../docs/adr/0012-environment-parameters-file.md).

Rules:

- The script loads the YAML via `powershell-yaml`'s `ConvertFrom-Yaml` and hard-errors if the file is missing, empty, or missing a required key, naming the missing key in the error message.
- Value resolution order for any single environment-varying value is: **explicit CLI parameter → value read from `-ParametersFile` → hard error**. The script must not ship hardcoded defaults for resource names, resource group, region, or tags.
- Values that are security or compliance invariants set by an ADR (for example [ADR 0011](../../docs/adr/0011-certificate-lifecycle.md) §2's 90-day soft-delete, purge-protection, 2048-bit cert, 12-month validity) stay hardwired in the Bicep module or the orchestrator and are **not** read from `-ParametersFile`. Changing them changes the ADR.
- Subscription ID, tenant ID, and any secret value must not be read from `-ParametersFile`. Those flow via `az account set` locally and GitHub Environment secrets in CI per [ADR 0010](../../docs/adr/0010-automation-identity-subject-model.md) and the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../copilot-instructions.md).
- A second environment is added by dropping a new `infra/parameters/<env>.yaml` file and invoking the orchestrator with `-ParametersFile infra/parameters/<env>.yaml`. No code change is required.

A script that hardcodes a resource name, resource group, region, or tag default — or reads a secret / subscription ID / tenant ID from `-ParametersFile` — is rejected by review.

### Required switches on every `Deploy-*.ps1`

| Switch | Default | Effect |
|---|---|---|
| `-WhatIf` | off | Produce the drift report; make no writes. Built into `[CmdletBinding(SupportsShouldProcess)]`. |
| `-PruneMissing` | `$false` | Allow deletion of objects that are in Purview but not in YAML. Without it, orphans are reported and skipped. |
| `-Force` | `$false` | Allow overwriting objects whose `lastModifiedBy` is not the current deploy principal. Without it, such conflicts are reported and skipped. |
| `-ExportCurrentState` | off | Read the live tenant and write its current state into the corresponding `data-plane/**` YAML. Makes no writes to Purview. Used to bootstrap a YAML file from an existing tenant so the first reconciler run does not look like drift. Must fail if the YAML already has non-empty managed content, unless `-Force` is also specified. |

A script that does not expose these four switches is rejected by review.

### Direction-policy contract (ADR 0029)

Every `scripts/Deploy-<Domain>.ps1` that backs a `.github/workflows/deploy-<domain>.yml` MUST expose the source-of-truth direction policy parameters defined in [ADR 0029](../../docs/adr/0029-source-of-truth-direction-policy.md). Reference implementation: [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) (PR [#458](https://github.com/contoso/Purview-as-Code-Generic/pull/458)). The workflow-side surface lives in [`github-actions.instructions.md`](github-actions.instructions.md#direction-policy-contract-adr-0029).

| Parameter | Type | Default | Effect |
|---|---|---|---|
| `-DirectionPolicy` | `[ValidateSet('audit', 'portal-wins', 'repo-wins')] [string]` | `'portal-wins'` | Arbitrates shared-property drift on `Update` plan entries. `audit` short-circuits before any write. `portal-wins` skips drifted shared labels and emits a SKIP marker per skip. `repo-wins` overwrites tenant fields with YAML values and emits a `Write-Warning` per overwrite. |
| `-SkipNames` | `[string[]]` | `@()` | Explicit deterministic skip list, threaded in by the workflow's portal-wins apply pass to match the enumerate pass's decisions exactly. Ignored in `audit` mode. |

Required script-side behaviour:

- **Pure helper — import the shared module.** The decision function `Resolve-DirectionPolicyAction` lives in [`scripts/modules/DirectionPolicy.psm1`](../../scripts/modules/DirectionPolicy.psm1) (extracted in PR [#473](https://github.com/contoso/Purview-as-Code-Generic/pull/473)). Each consumer imports it via `Import-Module (Join-Path $PSScriptRoot 'modules/DirectionPolicy.psm1') -Force -Scope Local -ErrorAction Stop` in its `#region Module dependencies` block. Do **not** re-inline a fourth copy of the function in a new reconciler — extend or test the shared module instead. The function maps `(Policy, SkipList, DisplayName, HasDrift)` to a `Skip`/`Update` decision plus a human-readable reason; it is pure so it is unit-testable without a tenant connection.
- **Audit short-circuit.** When `-DirectionPolicy audit`, after the plan is computed and before Phase 2 (session refresh) or Phase 3 (writes), empty the plan and orphan lists and emit a single `[ADR0029-AUDIT] DirectionPolicy=audit — no writes would have fired. Plan above is read-only.` marker via `Write-Information -InformationAction Continue`. Do NOT use `return` to exit early — the script's post-finally output handling depends on the normal control flow completing.
- **Skip markers.** When `-DirectionPolicy portal-wins` (or `repo-wins`, harmlessly) skips a shared label, emit `[ADR0029-SKIP] <displayName>` via `Write-Information -InformationAction Continue` — one line per skipped object, exact format `^\[ADR0029-SKIP\] (.+)$` so the workflow's `Select-String` parse is reliable. The skip list is also emitted as `Skip` rows in the plan-summary table.
- **Overwrite warnings.** When `-DirectionPolicy repo-wins` overwrites a shared label, emit `Write-Warning ("repo-wins overwriting tenant on label '{0}' fields: {1}" -f $displayName, $fieldsText)` so every overwrite is named in the run log alongside the drifted field set.
- **No CI-layer concerns.** Do NOT enforce `confirm_overwrite` inside the script — that gate lives in the workflow's pre-flight step per ADR 0029. The script trusts that any caller passing `-DirectionPolicy repo-wins` already cleared the workflow gate.
- **Pester coverage.** Test the helper by importing the same module (`Import-Module (Join-Path $PSScriptRoot '..' '..' 'scripts' 'modules' 'DirectionPolicy.psm1') -Force -ErrorAction Stop` in `BeforeAll`) so the consumer-side test file covers all three policy branches (portal-wins skip / repo-wins write / SkipList match), the SKIP-marker emission shape (source-text assertion against the consumer script), and the AUDIT-marker short-circuit (source-text assertion against the consumer script). Reference: [`tests/scripts/Deploy-Labels.Tests.ps1`](../../tests/scripts/Deploy-Labels.Tests.ps1) (16 ADR 0029 cases added in PR [#458](https://github.com/contoso/Purview-as-Code-Generic/pull/458), refactored to import the shared module in PR [#473](https://github.com/contoso/Purview-as-Code-Generic/pull/473)).

A backing script that does not expose `-DirectionPolicy` and `-SkipNames` with the shapes above — or that re-inlines `Resolve-DirectionPolicyAction` instead of importing it from `scripts/modules/DirectionPolicy.psm1` — is rejected by review.

### Per-write `ShouldProcess` is mandatory

Declaring `[CmdletBinding(SupportsShouldProcess = $true)]` is necessary but not sufficient. Every state-changing call inside the script must be individually gated by `$PSCmdlet.ShouldProcess(...)` so that `-WhatIf` skips it and `-Confirm` prompts on it:

```powershell
if ($PSCmdlet.ShouldProcess($target, $action)) {
    # New-Label / Set-Label / Remove-Label
    # New-RoleGroup / Update-RoleGroupMember / Remove-RoleGroup
    # Invoke-RestMethod -Method PUT / PATCH / DELETE against any Purview / Graph endpoint
}
```

Where `$target` is the human-readable identity of the object being changed (the label name, the collection path, the data source `displayName` — never the access token, request body, or response headers), and `$action` is a short imperative verb phrase (`'Create label'`, `'Update label policy'`, `'Remove orphan classification'`).

A script that wraps the *outer* loop in `ShouldProcess` but lets individual writes fall through is rejected by review — `-WhatIf` then runs every API write while only suppressing the loop banner. Reference: [Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).

### Deterministic `-ExportCurrentState` round-trip

`-ExportCurrentState` is the contract that lets the same operator re-bootstrap from the live tenant after a drift event without producing churn diffs. The export must satisfy all three rules below or it is rejected by review:

1. **Stable key order.** Top-level and nested mapping keys serialize in a fixed, documented order (alphabetical within each nesting level is acceptable; a per-resource canonical order is preferred when the schema implies one). The order is documented in a comment near the export function so a future contributor can reproduce it.
2. **Omitted-field preservation.** Fields that the tenant returns but that the schema treats as omittable (defaults, computed metadata, system-generated identifiers) are *not* serialized into the YAML. A round-trip Apply against the exported YAML must produce zero `Update` rows in the drift report.
3. **Re-import idempotency.** `Deploy-<Domain>.ps1 -ExportCurrentState` → `git diff` (zero diff if no tenant change since the last export) → `Deploy-<Domain>.ps1 -WhatIf` (only `NoChange` rows). Any deviation from this triangle is a bug in the export, not the YAML.

A `-WhatIf` smoke run that exercises this triangle is required in the PR description for any change that touches an export path.

### Reference implementation and known gaps

[`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) is the reference implementation for the full-circle reconciler contract (the four switches above plus per-write `ShouldProcess`, deterministic export, and the per-object plan table format below). [`scripts/Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1) and [`scripts/Deploy-EntraDirectoryRoles.ps1`](../../scripts/Deploy-EntraDirectoryRoles.ps1) also conform.

The following scripts have known gaps tracked under epic [#172](https://github.com/contoso/Purview-as-Code-Generic/issues/172):

- [#165](https://github.com/contoso/Purview-as-Code-Generic/issues/165) — `Deploy-AdministrativeUnits.ps1` (missing `-ExportCurrentState`).
- [#166](https://github.com/contoso/Purview-as-Code-Generic/issues/166) — `Deploy-Classifications.ps1` (all four).
- [#167](https://github.com/contoso/Purview-as-Code-Generic/issues/167) — `Deploy-Collections.ps1` (`ShouldProcess` + export).
- [#168](https://github.com/contoso/Purview-as-Code-Generic/issues/168) — `Deploy-DataSources.ps1` (all four).
- [#169](https://github.com/contoso/Purview-as-Code-Generic/issues/169) — `Deploy-Glossary.ps1` (all four).
- [#171](https://github.com/contoso/Purview-as-Code-Generic/issues/171) — `Deploy-Scans.ps1` (all four).

New `Deploy-*.ps1` scripts authored in any wave must ship full-circle from day one. Retrofitting after the fact is not an acceptable plan.

### First-run-against-an-existing-tenant contract

A reconciler's first run on a tenant that already has live state (existing collections, glossary terms, classifications, scans, policies, role-group members, etc.) **must not** destructively reconcile an empty or skeleton YAML against that live state. The safe-by-default workflow is:

1. Run `./scripts/Deploy-<Domain>.ps1 -ExportCurrentState` to hydrate the YAML from the live tenant.
2. Open the resulting diff as a pull request, review, and merge.
3. Only then run `-WhatIf` → `-Apply` (or `-Apply -PruneMissing` once the managed state matches reality).

This contract is why `-ExportCurrentState` is required on every `Deploy-*.ps1`, not optional. A reconciler that lacks it forces the operator into either hand-editing the YAML (error-prone) or running `-Apply -PruneMissing` against a skeleton (destructive). Neither is acceptable.

### Drift report format

Every `-WhatIf` run must emit a categorized report. The five categories, in order:

1. **Create** — in YAML, not in Purview.
2. **Update** — in both; content differs.
3. **NoChange** — in both; content identical.
4. **Orphan** — in Purview, not in YAML. Would be deleted only with `-PruneMissing`.
5. **Conflict** — in both; last modified by a non-deploy principal. Would be overwritten only with `-Force`.

**Per-object rows, not aggregate counts.** The report is one `PSCustomObject` per object with the columns `Category`, `Kind`, `Name`, `Reason`, emitted as a pipeline (not `Write-Host`) so the caller can pipe it to `Format-Table`, `Out-File`, `ConvertTo-Json`, or `>> $GITHUB_STEP_SUMMARY`. A short summary banner (`Plan: 3 Create, 1 Update, 12 NoChange`) may follow the table but never replaces it. A reconciler that only prints a banner and a short-circuit message is rejected — `-WhatIf` must enumerate every object it would touch.

### Rules for the agent

- When authoring or modifying a `Deploy-*.ps1`, keep the GET → diff → decide → act → record flow. Do not short-circuit to `PUT` without the diff.
- Never set `-PruneMissing` or `-Force` as a script default. They must be explicit at every call site.
- Never catch-and-suppress errors from write operations. Surface them with the resource name and HTTP status.
- Never emit the access token, request body with secrets, or response headers to the drift report.

Reference: [Microsoft Purview Data Map REST APIs](https://learn.microsoft.com/en-us/rest/api/purview/), [Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).

## Idempotency and safety

- Apply scripts must be idempotent: GET current state, compute a diff, then PUT/PATCH.
- Any delete / prune operation must be gated behind an explicit `-PruneMissing` (or equivalent) switch that defaults to `$false` and emits a confirmation prompt unless `-Force` is also set.
- `$ErrorActionPreference = 'Stop'` at the top of every script so REST failures don't silently pass.
- Honour `-WhatIf` for every mutating call (`[CmdletBinding(SupportsShouldProcess)]` when appropriate).

## Logging

- Write informational lines via `Write-Host` or `Write-Information`. Never include headers or request bodies that contain `Authorization`, keys, or tokens.
- Use `Write-Error` for failures; let them surface the API response status plus a redacted body.

## Module supply chain

- Install modules with explicit scope: `Install-Module <name> -Scope CurrentUser -Force`.
- Prefer publishers signed by Microsoft (`powershell-yaml`, `Az.*`, `Microsoft.PowerShell.*`). Do not `Install-Module` from arbitrary third-party feeds.
- Pin the version (`-RequiredVersion` or `-MinimumVersion`) in CI-critical scripts.

## PSScriptAnalyzer

- Scripts must pass `Invoke-ScriptAnalyzer -Severity Warning` on every PR. Treat `PSAvoidUsingPlainTextForPassword`, `PSAvoidUsingConvertToSecureStringWithPlainText`, `PSAvoidUsingInvokeExpression`, `PSUsePSCredentialType` as errors.

## Purview REST API version selection

Every `Invoke-RestMethod` call against a Purview data-plane endpoint must pin an explicit `api-version` query parameter. The rules below are non-negotiable.

### Choose the newest GA version that supports the operation

- Use GA whenever the endpoint and fields the script needs are GA on [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/).
- Only use a `-preview` `api-version` when a preview-only endpoint or field is required. Add a comment immediately above the call:

  ```powershell
  # api-version justification: the policy endpoint is preview-only as of YYYY-MM-DD.
  # Reference: https://learn.microsoft.com/en-us/rest/api/purview/
  Invoke-RestMethod -Uri "$base/policyStore/metadataPolicies?api-version=2022-11-01-preview" ...
  ```

### One version per endpoint family across the repo

- All scripts that call the Data Map (Atlas v2) endpoints must agree on one `api-version`. Same for Scanning, Account, and Policy Store.
- A workspace-wide grep (`grep -R "api-version=" scripts/`) should return a small, coherent set. Cross-script drift is a review-blocker.

### Deprecation triggers migration

- When the Learn page for an `api-version` this repo uses is marked retired or scheduled for retirement, the next PR that touches a script using it must migrate or open a tracking issue, same rule as Bicep (see [`bicep.instructions.md`](bicep.instructions.md)).
- Never hard-code a date in a fallback ("if 2023-09-01 fails, try 2022-02-01"). Pin one, fail loudly, and migrate.

### Prohibited

- Dynamic version discovery via string interpolation from non-literal sources (`?api-version=$($env:API_VER)`).
- Omitting `api-version` to "let the service pick" — the service returns `400` in most cases and unpredictable behavior in others.

Reference: [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/), [Azure REST API versioning](https://learn.microsoft.com/en-us/azure/architecture/best-practices/api-design#versioning-a-restful-web-api).

## Pre-commit checklist — `scripts/**` changes

Run before opening a PR that touches `scripts/**`. Paste the output of each command into the PR description. See [`pre-commit.instructions.md`](pre-commit.instructions.md) for the cross-cutting checklist that applies to every PR.

- [ ] `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning -EnableExit` exits 0
- [ ] Every touched `Deploy-*.ps1` exposes `-WhatIf`, `-PruneMissing`, `-Force`, and `-ExportCurrentState`
- [ ] Every state-changing call in the touched script is individually wrapped in `$PSCmdlet.ShouldProcess(...)`
- [ ] `-WhatIf` emits a per-object plan table (Create / Update / NoChange / Orphan / Conflict rows), not just a summary banner
- [ ] If `-ExportCurrentState` was touched, the round-trip triangle (export → `git diff` empty → `-WhatIf` only `NoChange`) is captured in the PR description
- [ ] No destructive operation (delete, prune) runs without an explicit opt-in switch that defaults to `$false`
