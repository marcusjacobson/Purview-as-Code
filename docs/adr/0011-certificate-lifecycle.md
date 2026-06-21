# 0011 — Certificate lifecycle for the automation identity: Key Vault storage, 12-month self-signed cert, automated rotation under human approval, four-layer out-of-band detection

- **Status:** Accepted
- **Date:** 2026-04-19
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q4; paired with [ADR 0010](0010-automation-identity-subject-model.md) unblocks Wave 0 [`scripts/New-AutomationIdentity.ps1`](../../scripts) (#5). Once `New-AutomationIdentity.ps1` lands, this ADR + ADR 0010 together transitively unblock Wave 0 `scripts/Grant-PurviewRoleGroup.ps1` (a.1), `scripts/Deploy-PurviewRoleGroups.ps1` (a.3), `scripts/Grant-M365ComplianceRoles.ps1` (#3), `scripts/Enable-UnifiedAuditLog.ps1` (#4), and §8 Q6 OIDC validation (#8).
- **Deciders:** @contoso

## Context

[ADR 0010](0010-automation-identity-subject-model.md) pinned the automation identity's *subject shape*: two Entra application registrations (`gh-oidc-purview-control-plane` and `gh-oidc-purview-data-plane`), each bound to the `lab` GitHub Environment via a `repo:…:environment:lab` federated credential subject, with the Environment configured for `main`-only deployment and required reviewer approval. That ADR explicitly deferred the *credential material* for the data-plane app — because [ADR 0009](0009-portal-role-group-api-ship-order.md) requires that path to authenticate through Security & Compliance PowerShell (`Connect-IPPSSession`), which only supports certificate-based app-only auth per [App-only authentication for unattended scripts in the Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2). The control-plane app has no such constraint — its calls are Azure ARM, and a federated OIDC token is sufficient.

This ADR answers §8 Q4: how does that certificate get issued, stored, consumed, rotated, and audited? The project plan's Q4 blueprint pointer names the sibling [`Azure-Deployment-Pipelines`](https://github.com/contoso/Azure-Deployment-Pipelines) repo's `SharePoint/SharePoint-File-Labeling/Scripts/` four-step setup (`New-ConfidentialClientApp.ps1` → `New-KeyVault.ps1` → `New-AppCertificate.ps1` → `Add-AppPermissions.ps1`) as the canonical reference that the future [`scripts/New-AutomationIdentity.ps1`](../../scripts) must consume. The fifth sibling script, `Enable-GraphMeteredApiBilling.ps1`, is not required on this repo's S&C PowerShell path (see [ADR 0009](0009-portal-role-group-api-ship-order.md) addendum).

### Reviewer concerns framing this ADR

The deciders called out three certificate-specific concerns that this ADR must answer concretely. They are reproduced verbatim so every decision below can be traced to the concern it addresses:

1. **Credential storage must be done most securely.** The cert and its private key must never land in source, never land on a long-lived runner filesystem, and never be readable by a principal outside the narrow automation identity's scope.
2. **Rotation must be automatable but stay under human administrative control.** Fully-hands-off rotation loses the audit moment that catches a mistake; fully-manual rotation is missed and expires. The answer has to be *both*.
3. **Detection for out-of-band rotations.** Any certificate (or other credential) added to either Entra app outside this repo's automation — whether by an admin clicking in the portal, by another script, or by an attacker — must be detectable with a clear, nameable signal, not by staring at logs.

The single-subject invariant from ADR 0010 decision #4 is the *prerequisite* that makes concern #3 tractable: with one federated credential per app and no secret fallback, the baseline is a single active `keyCredentials` entry per app, and *any* deviation is anomalous. This ADR adds the mechanics to detect deviations.

### Environment constraints

- **Single environment** (`lab`, in the `contoso.onmicrosoft.com` tenant) per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). Production / CA-backed certificate posture is out of scope per [§7 of the project plan](../project-plan.md#7-out-of-scope) and will require a follow-up ADR if a second environment is added.
- [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #1 forbids secrets in source; rule #2 permits a certificate-in-Key-Vault credential when the downstream surface does not support managed identity; rule #5 recommends private endpoints on Key Vault; rule #6 accepts Microsoft-managed keys for non-prod; rule #9 requires changes to be reversible, auditable, and pull-request-gated.

### Addendum — implementation split into three scripts (2026-04-19, editorial)

Per the delivery cadence rule in [`docs/project-plan.md`](../project-plan.md) ("one item per PR; if a diff starts growing beyond the scoped item, stop and split") and the sibling-repo reference pattern named in the Context section, the implementation of this ADR's decisions will ship as three distinct Wave 0 items rather than the single `scripts/New-AutomationIdentity.ps1` originally enumerated in the Gates line:

- **5a. `scripts/New-AutomationKeyVault.ps1`** — lab Key Vault bootstrap with the required settings from Decision §2 (RBAC, soft-delete, purge-protection, `AuditEvent` diagnostics). Azure-only; no Entra touch.
- **5b. `scripts/New-AutomationEntraApp.ps1`** — Entra application registration plus the `repo:…:environment:lab` federated credential per [ADR 0010](0010-automation-identity-subject-model.md). Runs twice, once per plane. Entra-only; no Azure-resource touch.
- **5c. `scripts/New-AutomationCertificate.ps1`** — data-plane certificate in Key Vault per Decision §1, upload to the data-plane Entra app via [Graph `application: addKey`](https://learn.microsoft.com/en-us/graph/api/application-addkey), plus the Key Vault RBAC grants described in Decision §2. Depends on 5a and on 5b having run once for the data-plane app. The control-plane app intentionally gets no certificate per Decision §5.

The fourth sibling script (`Add-AppPermissions.ps1`) is **not** ported as a standalone step: per-workload permission grants (Purview data-map roles, Exchange `View-Only Recipients`, Graph application permissions) belong with the build PR of each consumer (a.1 `Grant-PurviewRoleGroup.ps1`, a.3 `Deploy-PurviewRoleGroups.ps1`, #3 `Grant-M365ComplianceRoles.ps1`, #4 `Enable-UnifiedAuditLog.ps1`) so each consumer can cite its own Learn page for its own required role set. The Key Vault RBAC that 5c needs is the only cross-boundary permission and is kept with 5c because it is strictly a cert-upload prerequisite.

Nothing in the Decision / Scope / Consequences / Alternatives / Citations sections changes. The certificate shape, storage, consumption, rotation, asymmetry, and four-layer detection all stand. This addendum records only the implementation decomposition.

### Addendum — Decision #3 supersession: Key Vault-side JWT signing replaces local PFX import (2026-04-24, technical correction)

Decision §3 step 2 ("re-fetched inline via `az keyvault secret show`") and step 3 ("`Import-PfxCertificate -CertStoreLocation Cert:\CurrentUser\My`" then `Connect-IPPSSession … -CertificateThumbprint`) **cannot work as written** with the cert shape mandated by Decision §1. `keyProperties.exportable = false` instructs Key Vault to never serve a usable PFX through its `secrets` endpoint — the returned blob has `HasPrivateKey: False` when loaded into `X509Certificate2`. Empirically verified against `kv-contoso-lab-01/gh-oidc-purview-data-plane` on 2026-04-24. The decision either had to weaken cert posture (`exportable = true`, contradicting reviewer concern #1) or change the consumption pattern. We chose the latter.

**Replaces Decision §3 steps 2–3.** New consumption sequence for any `Connect-IPPSSession` call (Security & Compliance PowerShell — the only surface this asymmetry affects, per Decision §5):

1. `azure/login@v2` federates the runner identity to the data-plane Entra app via OIDC (unchanged).
2. [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT (`alg: PS256`, `x5t#S256` over the public cert), SHA-256 digests the signing input, and calls [`az keyvault key sign --algorithm PS256`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key#az-keyvault-key-sign) against the certificate's underlying RSA key. The private key never leaves Key Vault. Reference: [Microsoft identity platform — certificate credentials](https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials).
3. The signed assertion is exchanged at the v2.0 token endpoint for an access token in scope `https://outlook.office365.com/.default`. Reference: [Microsoft identity platform — client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow).
4. [`Connect-IPPSSession -AccessToken $tok -Organization contoso.onmicrosoft.com`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) (added in `ExchangeOnlineManagement` v3.8.0-Preview1+) consumes the token directly. No PFX, no local keystore, no `post`-step cleanup of certificate material — there is no certificate material to clean up.

**Two new Entra grants are required** for the access-token path that the `-CertificateThumbprint` path did not document explicitly (Connect-IPPSSession's certificate path implicitly relied on the same two but they were folded into "the cert is on the app"):

1. App-role assignment **`Office 365 Exchange Online > Exchange.ManageAsApp`** (application) on the data-plane app's service principal — populates the `roles` claim that S&C reads. Reference: [App-only auth — manifest permissions](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2#step-1-register-the-application-in-microsoft-entra-id).
2. Entra directory role **`Compliance Administrator`** (`17315797-102d-40b4-93e0-432062caca18`) at `directoryScopeId = /` on the same SP — least-privilege role for S&C; Exchange Administrator is *not* sufficient. Reference: [App-only auth — supported roles](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2#supported-roles), [Built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference#compliance-administrator).

Both grants are applied idempotently by [`scripts/Grant-ExchangeManageAsApp.ps1`](../../scripts/Grant-ExchangeManageAsApp.ps1) (`-WhatIf` produces a drift report; re-runs are NoChange). Wave 0 #3 [`scripts/Grant-M365ComplianceRoles.ps1`](../../scripts) will subsume the Compliance Administrator grant when it lands.

**Caller RBAC additions on the lab Key Vault** (extend Decision §2's grant list):

- `Key Vault Crypto User` (`12338af0-0e69-4776-bea7-57ae8d297424`) on the `lab` Environment's federated workload identity — grants the `keys/sign` operation. Reference: [Key Vault RBAC roles](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide).
- `Key Vault Certificate User` on the same identity — already present per Decision §2; required to read the public cert to compute `x5t#S256`.

`Key Vault Certificates Officer` and the `secrets get` permission used by the now-superseded download path are no longer needed by `Connect-IPPSSession` callers. They remain required by the rotation workflow (Decision §4) and are unchanged.

**No change to** Decision §1 (cert shape), Decision §2 (vault settings), Decision §4 (rotation cadence), Decision §5 (control-plane asymmetry), Decision §6 (four-layer detection). The four detection signals all read the Entra app's `keyCredentials` and Key Vault's `AuditEvent` log; neither is sensitive to whether the consumer reads the secret or signs against the key.

**Why this is more secure, not less.** The original Decision §3 path moved the private key out of Key Vault into a runner-temp PFX file for the duration of the cmdlet call — even if ephemeral and audited, the key briefly existed outside Key Vault. The new path means the key is *never* outside Key Vault. Every signing operation is a discrete, individually-audited `KeySign` event in Key Vault's `AuditEvent` log (visible in Log Analytics per Decision §2). This satisfies reviewer concern #1 ("must be done most securely") strictly more strongly than the path it replaces.

### Addendum — Log Analytics workspace prerequisite (2026-04-19, editorial)

Decision §2 below requires the automation Key Vault to stream the `AuditEvent` category to a Log Analytics workspace. The lab does not yet have a Log Analytics workspace, and the [Azure diagnostic settings resource](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/diagnostic-settings) requires the target workspace's resource ID at deployment time. Per the cadence rule (one item per PR, no bundled scope), the workspace ships as its own atomic Wave 0 item **5.0** ahead of 5a:

- **5.0. `infra/modules/law.bicep` + `scripts/New-LogAnalyticsWorkspace.ps1`** — lab Log Analytics workspace. Declarative Bicep module (`Microsoft.OperationalInsights/workspaces`) orchestrated by a thin PowerShell script (`az deployment group create` + idempotency check). Grounded in [Microsoft.OperationalInsights/workspaces](https://learn.microsoft.com/en-us/azure/templates/microsoft.operationalinsights/workspaces) and [Log Analytics workspace overview](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-workspace-overview). Outputs the `workspaceId` that 5a feeds into the KV diagnostic settings. No sibling blueprint exists in the [`Azure-Deployment-Pipelines`](https://github.com/contoso/Azure-Deployment-Pipelines) repo, so 5.0 is built from Learn alone.

The Wave 0 automation-identity cluster is therefore **5.0 → 5a → 5b → 5c**, shipping as four PRs. Nothing in the Decision / Scope / Consequences / Alternatives / Citations sections changes.

## Decision

We will issue a self-signed X.509 certificate, store it only in the lab Key Vault, consume it from GitHub Actions through an OIDC-authenticated runtime download, rotate it every 11 months through a PR-gated automation, and instrument four independent detection layers for out-of-band changes.

### 1. Certificate shape

- **Self-signed**, 2048-bit RSA, SHA-256, 12-month validity.
- **Key usage:** `digitalSignature`, `keyEncipherment` (the minimum that `Connect-IPPSSession` requires per [App-only authentication for unattended scripts in the Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2)).
- **Subject:** `CN=gh-oidc-purview-data-plane` (matches the Entra app display name from ADR 0010).
- **Issued to:** the data-plane app only. The control-plane app gets **no certificate** — its credential is the OIDC federated credential from ADR 0010, and attaching a cert would create an unused credential surface that violates the single-credential invariant.
- **Private key marked non-exportable** in the Key Vault certificate policy (`keyProperties.exportable = false` per [Certificate policy](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-policy)).
- **Why self-signed for the lab.** [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 allows certificate-in-Key-Vault when managed identity is not viable; self-signed is acceptable for non-production per the same rule's precedence order. A CA-backed cert requires an internal PKI that does not exist in `contoso.onmicrosoft.com`; adding one for a single-tenant lab is overkill. Concrete mitigation: rotation cadence (decision #4) and four-layer detection (decision #6) make the cert's compromise window short and its misuse detectable.

### 2. Storage in the lab Key Vault

- **Only the lab Key Vault** holds the certificate. No runner filesystem, no GitHub secret, no local machine, no email, no wiki.
- The lab Key Vault is created / validated by the `New-AutomationIdentity.ps1` build PR with these required settings:
  - `enableRbacAuthorization: true` per [Azure role-based access control for Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide).
  - `enableSoftDelete: true` + `softDeleteRetentionInDays: 90` per [Key Vault soft-delete overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview).
  - `enablePurgeProtection: true` per the same document.
  - **Diagnostic settings** on, `AuditEvent` category streamed to a Log Analytics workspace, per [Monitor Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/logging).
  - `publicNetworkAccess: 'Disabled'` with private-endpoint wiring is **recommended** (rule #5) but deferred to a follow-on PR so this ADR does not block on a networking change. The certificate path works identically with or without private endpoint.
- **RBAC scopes (narrow).**
  - Runtime read (every deploy): the data-plane app gets `Key Vault Certificate User` scoped to the single certificate (per [Built-in roles for Key Vault data plane](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide#azure-built-in-roles-for-key-vault-data-plane-operations)).
  - Rotation write (rare, PR-gated): the data-plane app additionally gets `Key Vault Certificates Officer` scoped to the Key Vault. The same app wears both hats because rotation is the same identity performing a controlled write; this keeps the RBAC surface flat and avoids introducing a third Entra app. The admin separation comes from the GitHub Environment reviewer gate (ADR 0010 decision #3), not from an RBAC split.

### 3. Consumption from GitHub Actions

Each `deploy-data-plane.yml` run, *inside the `environment: lab` block* (so the OIDC subject matches):

1. `azure/login@v2` federates the runner identity to the data-plane Entra app. OIDC per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).
2. `az keyvault certificate download --vault-name … --name … --file $RUNNER_TEMP/app.pem --encoding PEM` writes the public certificate to the ephemeral runner temp directory. The private key is re-fetched inline via `az keyvault secret show --vault-name … --name …` (Key Vault serves the PFX through the `secrets` endpoint per [Get certificate secrets](https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate#az-keyvault-certificate-download)).
3. A pwsh step loads the PFX into the ephemeral session's certificate store only (`Import-PfxCertificate -CertStoreLocation Cert:\CurrentUser\My`), then calls `Connect-IPPSSession -AppId … -CertificateThumbprint … -Organization contoso.onmicrosoft.com` per [Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-ippssession) and the `Runtime: pwsh 7.4+ only, and the Connect-IPPSSession auth constraint` section of [`powershell.instructions.md`](../../.github/instructions/powershell.instructions.md).
4. A `post` step removes the temp file + the ephemeral cert-store entry regardless of job outcome. The GitHub-hosted runner is also destroyed at the end of the job per [About GitHub-hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners) — the temp file is doubly-ephemeral.

**No thumbprint secret is stored in GitHub.** The thumbprint is fetched at runtime from Key Vault. This removes one of the two GitHub secrets that would otherwise drift out of sync on rotation.

### 4. Rotation cadence: automated at 11 months, gated by a PR

- **Trigger.** A scheduled workflow `rotate-automation-cert.yml` runs monthly (`schedule: cron`) and checks both apps' `keyCredentials.endDateTime`. If any active credential is within 45 days of expiry, the workflow dispatches the rotation job.
- **Rotation job (under the data-plane app's existing RBAC, no new identity).**
  1. Generates a new self-signed cert directly in Key Vault via `New-AzKeyVaultCertificate` + [Certificate creation](https://learn.microsoft.com/en-us/azure/key-vault/certificates/create-certificate) (the private key never leaves Key Vault during generation).
  2. Fetches the new cert's public key and uploads it as a *second* `keyCredentials` entry on the target Entra app via [`application: addKey`](https://learn.microsoft.com/en-us/graph/api/application-addkey).
  3. Opens a PR updating any rotation-metadata file with the new expiry date and the new cert name. The PR does **not** modify any secret value (see decision #3 — no thumbprint secret exists).
  4. Waits for the typed `approve merge` token plus the `lab` Environment's required reviewer approval per ADR 0010 decision #3. This is the administrative-control surface for reviewer concern #2.
- **Overlap window.** After merge, the old cert stays valid for 30 days to cover any straggler run that stamped against the old thumbprint. During the overlap, *both* certs are expected on the Entra app — the invariant check (decision #6c) tolerates exactly 2 credentials when a rotation run is registered in the rotation-metadata file, and exactly 1 otherwise. No other state is valid.
- **Retirement.** A second scheduled workflow `retire-automation-cert.yml` runs daily and removes the old `keyCredentials` entry via [`application: removeKey`](https://learn.microsoft.com/en-us/graph/api/application-removekey) once the overlap ends. The retirement PR is auto-opened with the specific thumbprint to remove and, like rotation, requires human merge.

### 5. Control-plane app: no certificate

The control-plane app (`gh-oidc-purview-control-plane`) has **only** its OIDC federated credential from ADR 0010. No certificate is attached. The control-plane workflow's only call surface is Azure ARM, which is fully serviceable by the OIDC token. Attaching a cert to this app would create an unused credential surface that a compromised `applications` role could misuse; the absence is a security property, not an omission.

### 6. Out-of-band detection: four independent layers

Each layer fires on a different signal and a different timescale. They are additive; an attack or operator error must evade all four to stay silent.

1. **Key Vault near-expiry Event Grid (proactive, days-before scale).** Key Vault emits `Microsoft.KeyVault.CertificateNearExpiry` 30, 15, and 1 days before expiry per [Key Vault event schema](https://learn.microsoft.com/en-us/azure/event-grid/event-schemas-key-vault). The `New-AutomationIdentity.ps1` build PR wires a system topic + a subscription that posts to a GitHub webhook, which auto-opens an issue labeled `cert-rotation-due`. If the scheduled rotation workflow has already processed the cert by then the issue is auto-closed by the rotation PR; if not, it stays open and blocks the deploy pipeline.
2. **Entra audit log on `keyCredentials` mutations (reactive, minutes-scale).** Any addition or removal of a certificate on either Entra app emits an audit event in the `ApplicationManagement` category per [Microsoft Entra audit log events](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-audit-logs). A Sentinel analytic rule (future ops PR — this ADR pins the shape, not the KQL) filters for `operationName in ("Add certificate and secret configuration", "Update application – Certificates and secrets management")` on either app's `appId` and joins against the rotation-metadata file; any event without a matching rotation run is an incident. Rule reference: [Create custom analytics rules to detect threats](https://learn.microsoft.com/en-us/azure/sentinel/detect-threats-custom).
3. **Pipeline-startup invariant (reactive, every deploy).** The first step of every `deploy-data-plane.yml` run calls `Get-MgApplication -ApplicationId …` per [Get application](https://learn.microsoft.com/en-us/graph/api/application-get) and asserts: exactly 1 active `keyCredentials` entry when no rotation is in progress, or exactly 2 (matching the two most recent rotation run records) during an overlap window. Any other count fails the job closed and opens a GitHub issue labeled `automation-identity-anomaly`. This is the last-line guard that catches anything layers 1–2 missed; it runs before any destructive data-plane write.
4. **Key Vault diagnostic logs (retrospective, hours-to-days).** The `AuditEvent` category on the Key Vault streams every `CertificateCreate`, `CertificateImport`, `CertificateDelete`, and `SecretGet` against the automation identity cert to Log Analytics per [Monitor Key Vault — log categories](https://learn.microsoft.com/en-us/azure/key-vault/general/logging#interpret-key-vault-logs). A scheduled KQL query — run nightly from the same Sentinel workspace — correlates these against the rotation workflow's run history; uncorrelated events are flagged. This is the layer that catches an admin with Key Vault write access performing a manual certificate operation outside the automation.

These four layers together answer reviewer concern #3 with concrete, separately-failing controls. No single layer is the safety net.

## Scope — what this ADR does *not* decide

Matching the narrow-ADR pattern of [ADR 0009](0009-portal-role-group-api-ship-order.md) and [ADR 0010](0010-automation-identity-subject-model.md):

- **The exact Bicep of the Key Vault module + its diagnostic settings + its Event Grid system topic.** Those land in [`scripts/New-AutomationIdentity.ps1`](../../scripts) and an accompanying `infra/modules/keyvault.bicep` in the build PR, with Learn citations inline.
- **The exact PowerShell of `Rotate-AutomationCertificate.ps1`, `rotate-automation-cert.yml`, and `retire-automation-cert.yml`.** Future build PRs after `New-AutomationIdentity.ps1` lands.
- **The exact Sentinel analytic rule KQL** for detection layer #2 and the retrospective query in layer #4. Future ops PR. The ADR pins the signal source and filter shape.
- **Private endpoint on the lab Key Vault.** Recommended (rule #5), deferred to a follow-on PR. The cert path works identically either way.
- **Conditional Access on the workload identity.** Already deferred by ADR 0010; still deferred.
- **CA-backed cert / production cert posture.** Out of scope per [§7 of the project plan](../project-plan.md#7-out-of-scope). Will require a new ADR when / if a second environment appears.

## Consequences

**Easier.**

- **Reviewer concern #1 (storage) is answered concretely.** Private key materialized only inside Key Vault, RBAC-scoped to the single cert for runtime reads, soft-delete + purge-protection on, diagnostic logs flowing, and a clear path to private endpoint. No runner-filesystem persistence, no secret-based surface, no GitHub secret that can drift.
- **Reviewer concern #2 (automatable with admin control) is answered by the PR-gated rotation.** The script runs, the cert lands in Key Vault, the Entra app gets a second `keyCredentials` entry, and a PR opens with the rotation metadata. The `approve merge` token plus the `lab` Environment reviewer are the two administrative gates; without both, no token is minted against the new cert in any subsequent run. Rotation runs on a cron but only *takes effect* under human approval.
- **Reviewer concern #3 (detection) is answered by four independent layers.** Each layer fires on a different signal at a different timescale, so the detection surface is robust to partial failures — a misconfigured Event Grid subscription does not disable the startup invariant, a lag in Sentinel does not stop the near-expiry issue.
- **The single-credential invariant from [ADR 0010](0010-automation-identity-subject-model.md) decision #4 is now operational.** That decision pinned the invariant; this decision's detection stack is what makes it enforceable.
- **Wave 0 #5 (`New-AutomationIdentity.ps1`) is unblocked.** Paired with ADR 0010, every design choice the script needs is pinned: identity shape, cert shape, storage, rotation boundary, detection wiring. The build PR can start.
- **Transitive unblock.** With `New-AutomationIdentity.ps1` unblocked, Wave 0 a.1 (`Grant-PurviewRoleGroup.ps1`), a.3 (`Deploy-PurviewRoleGroups.ps1`), #3 (`Grant-M365ComplianceRoles.ps1`), #4 (`Enable-UnifiedAuditLog.ps1`), and #8 (OIDC validation) all become viable.

**Harder.**

- **More moving parts.** Key Vault with diagnostic settings, Event Grid subscription, GitHub webhook, Sentinel analytic rule, scheduled rotation workflow, scheduled retirement workflow, pipeline invariant check. Each lands in its own PR with its own Learn citations; this ADR pins only their existence and their shape.
- **Overlap-window state.** Every rotation creates a ~30-day window where 2 certs are valid. The invariant check in detection layer #3 has to tolerate exactly 2 credentials during that window, which means a rotation-metadata file must record the start of each overlap. Flagged as explicit PR review for the `New-AutomationIdentity.ps1` build: the metadata file is part of the repo (no secrets — just thumbprints and dates) so the invariant check is self-describing.
- **Control-plane / data-plane asymmetry.** The control-plane app has no cert; the data-plane app does. The build PR's script header must explain that asymmetry so nobody "helpfully" attaches a cert to the control-plane app during a future edit.
- **Self-signed carries a documented-cadence obligation.** [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 requires the rotation cadence to be documented when self-signed is used; this ADR + the rotation workflow's schedule are that documentation.

**Security principle posture.** This ADR *upholds*:

- [`security.instructions.md`](../../.github/instructions/security.instructions.md) **rule #1** — no cert or thumbprint in source; Key Vault is the only credential store. The rotation-metadata file contains only public thumbprints + dates.
- **Rule #2** — bounded: managed identity is not viable for the S&C PowerShell path (ADR 0009), so certificate-in-Key-Vault is the correct fallback per the rule's own precedence list. Self-signed is acceptable for non-prod; rotation cadence is documented (decision #4).
- **Rule #3** — upstream OIDC login is unchanged; the cert is consumed *after* the OIDC-authenticated `az keyvault certificate download` call.
- **Rule #5** — private endpoint on Key Vault is recommended and scoped as a follow-on PR, not a blocker.
- **Rule #6** — Microsoft-managed keys on Key Vault are accepted per the rule's non-prod default; CMK deferred per [§7](../project-plan.md#7-out-of-scope).
- **Rule #9** — rotation and retirement both require a merged PR; the cert is not changed by any silent automation. The invariant check is the reversibility / auditability enforcement at runtime.

## Alternatives considered

- **Client secret on the data-plane app instead of a certificate.** Rejected. Forbidden by [`security.instructions.md`](../../.github/instructions/security.instructions.md) rules #1 and #2; also incompatible with `Connect-IPPSSession`, which requires certificate-based app-only auth per [App-only authentication for unattended scripts in the Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2). A client secret would be the simplest primitive but is a non-starter on both axes.
- **Cert stored in a GitHub Environment secret as base64.** Rejected. No rotation audit trail (Entra does not see the secret-update event), no soft-delete, no purge-protection, no Event Grid near-expiry signal, no Private Endpoint. The thumbprint would also have to be kept in sync manually across every rotation — exactly the kind of drift ADR 0010 decision #6 is designed to eliminate.
- **Cert written to the runner filesystem from a GitHub secret per run.** Rejected. Same problems as the previous alternative, plus a window where the private-key PFX sits on disk in a shared runner image. Ephemeral temp download *from Key Vault after OIDC login* (decision #3) is strictly safer: the identity that can download the PFX is scoped by the OIDC subject, the event is audited by Key Vault, and the private key never sits in a GitHub-controlled store.
- **CA-backed cert from an internal PKI.** Rejected *for the lab*. No internal PKI exists in `contoso.onmicrosoft.com`; adding one for a single-tenant lab is overkill and would introduce its own rotation story. Deferred to a follow-up ADR if / when the repo extends to a production environment.
- **Managed identity + `Key Vault Certificate Officer` on the MI.** Rejected. GitHub Actions runners are not managed identities; they are GitHub-hosted workload identities that federate to an Entra app per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect). Rule #2 explicitly treats federated workload identities (tier 3 of the precedence list) as the correct primitive for this path.
- **Never rotate — issue a 10-year cert.** Rejected. Violates rule #9 (every change is reviewable / auditable; a single 10-year cert has no natural review cadence). Also collapses three of the four detection layers: near-expiry Event Grid rarely fires, the retirement workflow has no work to do, and the rotation-metadata file is static — which means the invariant check can't distinguish a real rotation from an attacker-inserted cert.
- **Do nothing — keep the status quo (manual-dispatch workflows, shared secret placeholder).** Rejected. Blocks Wave 0 #5 and every downstream Wave 0 item, and leaves reviewer concerns #1, #2, and #3 unaddressed.

## Citations

- [About Azure Key Vault certificates](https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates) — certificate object model.
- [Certificate policy](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-policy) — `keyProperties.exportable`, issuer, key usage, lifetime actions.
- [Create a certificate in Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/certificates/create-certificate) — server-side generation; private key never leaves Key Vault.
- [Azure role-based access control for Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide) — `Key Vault Certificate User`, `Key Vault Certificates Officer`, data-plane scoping.
- [Key Vault soft-delete overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview) — soft-delete and purge-protection.
- [Monitor Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/logging) — `AuditEvent` diagnostic category, Log Analytics sink.
- [Azure Event Grid schema for Key Vault events](https://learn.microsoft.com/en-us/azure/event-grid/event-schemas-key-vault) — `Microsoft.KeyVault.CertificateNearExpiry`.
- [App-only authentication for unattended scripts in the Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) — certificate auth requirement that forces decision #1.
- [Connect-IPPSSession](https://learn.microsoft.com/en-us/powershell/module/exchange/connect-ippssession) — `-AppId` + `-CertificateThumbprint` + `-Organization` invocation.
- [Get application (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/application-get) — startup invariant (layer 3).
- [keyCredential resource type](https://learn.microsoft.com/en-us/graph/api/resources/keycredential) — certificate attachment on Entra apps.
- [application: addKey](https://learn.microsoft.com/en-us/graph/api/application-addkey) + [application: removeKey](https://learn.microsoft.com/en-us/graph/api/application-removekey) — rotation and retirement.
- [Microsoft Entra audit log events](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-audit-logs) — `ApplicationManagement` category (layer 2).
- [Create custom analytics rules to detect threats — Microsoft Sentinel](https://learn.microsoft.com/en-us/azure/sentinel/detect-threats-custom) — analytic-rule mechanics for layer 2.
- [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — upstream authentication unchanged from ADR 0010.
- [About GitHub-hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners) — runner ephemerality supports decision #3.
- Sibling repo blueprint: `SharePoint/SharePoint-File-Labeling/Scripts/New-AppCertificate.ps1` + `New-KeyVault.ps1` in [`contoso/Azure-Deployment-Pipelines`](https://github.com/contoso/Azure-Deployment-Pipelines) — named as canonical by [`docs/project-plan.md`](../project-plan.md) §8 Q4.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — rules #1, #2, #3, #5, #6, #9.
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — "Runtime: pwsh 7.4+ only, and the Connect-IPPSSession auth constraint" section (added in PR #20) that decision #3 depends on.
- [ADR 0009](0009-portal-role-group-api-ship-order.md) — pinned the data-plane auth surface to S&C PowerShell with certificate app-only auth.
- [ADR 0010](0010-automation-identity-subject-model.md) — pinned the subject shape, the `lab` Environment reviewer gate, and the single-credential invariant that this ADR's detection stack operationalizes.
