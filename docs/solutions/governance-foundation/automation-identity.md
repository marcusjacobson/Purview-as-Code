# Automation identity

The lab uses two OIDC-federated Microsoft Entra applications as workload identities for GitHub Actions. This page documents the four imperative primitives that provision them and the supporting Azure resources (Key Vault, certificate, RBAC). Ratified by [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md), [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md), and [ADR 0012 — Environment parameters file](../../adr/0012-environment-parameters-file.md).

## Two apps, one per plane

| Plane | Entra app display name (lab) | Federated subject | Call surface |
|---|---|---|---|
| Control | `gh-oidc-purview-control-plane` | `repo:<org>/<repo>:environment:lab` | Azure ARM (`az deployment group ...`) |
| Data | `gh-oidc-purview-data-plane` | `repo:<org>/<repo>:environment:lab` | Microsoft Graph + Exchange / S&C PowerShell via Key Vault-signed JWT |

Per [ADR 0010 §1](../../adr/0010-automation-identity-subject-model.md), one app per workflow file. Per [ADR 0010 §4](../../adr/0010-automation-identity-subject-model.md), each app holds **exactly one** federated credential with the expected subject — any second credential or mismatched field is treated as an anomaly and fails the bootstrap loudly. The single-subject invariant is the anchor for the detection signals cited in the ADR's Consequences section.

Per [ADR 0011 §5](../../adr/0011-certificate-lifecycle.md), only the **data-plane** app carries a certificate (for the Key Vault-signed JWT path). The control-plane app is cert-free; its only call surface is Azure ARM, serviceable by the OIDC federated token alone.

## Provisioning sequence

Run these in order. Each is idempotent and re-runnable.

| Step | Script | Owns |
|---|---|---|
| 5.0 | [`New-LogAnalyticsWorkspace.ps1`](log-analytics.md) | LAW that backs the KV audit sink |
| 5a | [`New-AutomationKeyVault.ps1`](../../../scripts/New-AutomationKeyVault.ps1) | Key Vault with RBAC mode, 90-day soft-delete, purge protection, `AuditEvent` sink |
| 5b | [`New-AutomationEntraApp.ps1`](../../../scripts/New-AutomationEntraApp.ps1) | One Entra app + service principal + federated credential per plane |
| 5c | [`New-AutomationCertificate.ps1`](../../../scripts/New-AutomationCertificate.ps1) | Data-plane self-signed certificate in Key Vault + `keyCredentials` upload to the data-plane app + per-cert / per-vault KV RBAC |
| 5d | [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1) | Azure RBAC the apps need at deploy time (`Contributor` on RG for control plane; `Key Vault Crypto User` for `keys/sign` and `Key Vault Contributor` for the firewall toggle on the vault for data plane) |

Each script is a thin orchestrator around a Bicep module or an `az ad` call. The four-switch reconciler contract (`-PruneMissing` / `-Force` / `-ExportCurrentState`) does **not** apply — these are imperative primitives, not catalog reconcilers.

## 5a — Key Vault

Module: [`infra/modules/keyvault.bicep`](../../../infra/modules/keyvault.bicep). Script: [`New-AutomationKeyVault.ps1`](../../../scripts/New-AutomationKeyVault.ps1).

Ships with the required security settings from [ADR 0011 §2](../../adr/0011-certificate-lifecycle.md):

- RBAC auth mode (no access policies).
- 90-day soft-delete.
- Purge protection.
- `AuditEvent` diagnostics streamed to the LAW from step 5.0.

What 5a does **not** do (kept for 5c):

- Creating the certificate.
- Granting per-cert / per-vault Key Vault RBAC to the data-plane Entra app (the app OID does not exist until 5b has run).

## 5b — Entra apps

Script: [`New-AutomationEntraApp.ps1`](../../../scripts/New-AutomationEntraApp.ps1). Run twice — once with `-Plane control`, once with `-Plane data`.

Behaviour:

1. Validate the parameters file ([ADR 0012](../../adr/0012-environment-parameters-file.md)).
2. Resolve the target display name and the expected federated credential subject from the file.
3. `az ad app list` probe — create the app if missing (single-tenant, no reply URLs, no redirect URIs).
4. `az ad sp show` probe — create the service principal if missing.
5. `az ad app federated-credential list` probe — create `gh-env-<env>` if missing; verify every field matches the ADR 0010 expected shape; **fail loudly** on any second credential or any mismatched field.

Forbidden by ADR 0010 §4: client secrets, `ref:` subjects, `pull_request:` subjects, `job_workflow_ref:` subjects.

## 5c — Data-plane certificate

Script: [`New-AutomationCertificate.ps1`](../../../scripts/New-AutomationCertificate.ps1).

Generates a self-signed certificate in the lab Key Vault, uploads its public key to the data-plane Entra app as a `keyCredential`, and assigns two Key Vault RBAC roles. Matches [ADR 0011](../../adr/0011-certificate-lifecycle.md) decisions §1, §2, and §5:

- Self-signed, RSA 2048, SHA-256, 12-month validity, **non-exportable** private key, subject `CN=<data-plane app display name>`, key usage `digitalSignature` + `keyEncipherment`. Each value is an ADR invariant and stays hardwired.
- Private key stays inside Key Vault — creation is server-side via [`az keyvault certificate create`](https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate). The PFX never hits the caller's disk.
- Initial upload to the Entra app uses [`PATCH /applications/{id}`](https://learn.microsoft.com/en-us/graph/api/application-update) with a single-entry `keyCredentials` array because [`application: addKey`](https://learn.microsoft.com/en-us/graph/api/application-addkey) requires an existing valid certificate on the app to sign the proof. Rotation (ADR 0011 §4, shipped by a later `Rotate-*` PR) uses `addKey`.
- RBAC grants on the data-plane app's service principal:
  - `Key Vault Certificate User` scoped to `{vault}/certificates/{name}` — least-privilege read for every deploy run.
  - `Key Vault Certificates Officer` scoped to the vault — needed by the rotation workflow so the same identity can create the next cert version.

Anomalies that abort the script:

- App already carries a *different* single thumbprint — abort. The script never silently overwrites; this is the startup-invariant surface of ADR 0011 §6 layer 3.
- App carries two or more thumbprints (rotation overlap) — abort. The rotation script, not this bootstrap, owns that state.

## 5d — Azure RBAC

Module: [`infra/modules/automation-rbac.bicep`](../../../infra/modules/automation-rbac.bicep). Script: [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1).

Reconciles the role assignments required by the two OIDC apps whose target resources exist at Bicep deploy time:

- Control-plane SP → `Contributor` at the resource group. Required by [ADR 0010 §5](../../adr/0010-automation-identity-subject-model.md); without it, `azure/login@v2` succeeds but `az account show` reports `No subscriptions found for ***`. This was the Wave 0 #15 smoke failure observed on 2026-04-25.
- Data-plane SP → `Key Vault Crypto User` at vault scope. Required by [ADR 0011 §3 supersession](../../adr/0011-certificate-lifecycle.md). The `Connect-IPPSSession` path signs an RFC 7523 JWT assertion against the cert's underlying RSA key via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) — that is the `keys/sign` data-plane operation this role grants.
- Data-plane SP → `Key Vault Contributor` at vault scope. Required by [ADR 0049](../../adr/0049-data-plane-sp-key-vault-firewall-rbac.md). Every single-login data-plane workflow briefly opens the vault firewall via [`az keyvault update --public-network-access Enabled`](https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-update) — a management-plane `Microsoft.KeyVault/vaults/write` operation that `Key Vault Crypto User` does not include. `Key Vault Contributor` is the narrowest built-in that covers `vaults/write`; it is [management-plane only](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-contributor) (empty `dataActions`), so it cannot read secrets/keys/certs and cannot assign RBAC.

Bicep role-assignment names are derived from `guid(scope, principalId, roleDefinitionId)` in [`rbac.bicep`](../../../infra/modules/rbac.bicep), so a re-run is a no-op once the assignment matches.

> **Idempotency caveat (ADR 0049).** If a tenant already carries a hand-created, random-named role assignment for the same (data-plane SP, `Key Vault Contributor`, vault) tuple, a deterministic-name Bicep re-run collides with `RoleAssignmentExists`. Remove the random-named assignment first, then re-run so the module creates the `guid()`-named one.

Out of scope (intentionally owned by 5c): `Key Vault Certificate User` at cert scope and `Key Vault Certificates Officer` at vault scope on the data-plane SP. These live in `New-AutomationCertificate.ps1` because the certificate object only exists at the time that script runs; Bicep cannot resolve `{vault}/certificates/{name}` ahead of time.

## OIDC validation

The workflow [`.github/workflows/validate-oidc-auth.yml`](../../../.github/workflows/validate-oidc-auth.yml) exercises both apps end-to-end:

- Control-plane: `azure/login@v2` + `az account show` against the lab subscription.
- Data-plane: `azure/login@v2` + temporary Key Vault firewall toggle + Key Vault-signed JWT mint + `Connect-IPPSSession -AccessToken` + `Get-AdminAuditLogConfig` + `Disconnect-ExchangeOnline` + firewall restore.

The Key Vault firewall toggle (5e) is documented in the workflow itself and in [`docs/runbooks/kv-temp-unlock.md`](../../runbooks/kv-temp-unlock.md) for manual operations.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Bootstrap operator running 5a–5d locally | `Owner` (or `Contributor` + `User Access Administrator`) on the resource group | RG |
| Same operator (5b only) | Microsoft Graph delegated `Application.ReadWrite.All` (creates apps + federated credentials) | Tenant |
| Same operator (5c only) | `Key Vault Certificates Officer` on the vault + Graph `Application.ReadWrite.OwnedBy` (PATCH `keyCredentials`) | Vault / tenant |

Reference: [Workload identity federation overview](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation), [Configure an app to trust an external IdP](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust), [Configuring OpenID Connect in Azure (GitHub side)](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure).

## References

- [Microsoft.KeyVault/vaults](https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/vaults)
- [Key Vault RBAC guide](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)
- [Key Vault soft-delete](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)
- [Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)
- [Certificate policy in Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-policy)
- [Create a certificate in Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/certificates/create-certificate)
- [`az keyvault certificate`](https://learn.microsoft.com/en-us/cli/azure/keyvault/certificate)
- [`az keyvault key`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key)
- [Update `application` (Graph)](https://learn.microsoft.com/en-us/graph/api/application-update)
- [`keyCredential` resource](https://learn.microsoft.com/en-us/graph/api/resources/keycredential)
- [`application: addKey`](https://learn.microsoft.com/en-us/graph/api/application-addkey)
- [`az ad app`](https://learn.microsoft.com/en-us/cli/azure/ad/app)
- [`az ad app federated-credential`](https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential)
- [OIDC subject claim formats (GitHub)](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [Add or remove Azure role assignments using Bicep](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep)
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
- [ADR 0012 — Environment parameters file](../../adr/0012-environment-parameters-file.md)
