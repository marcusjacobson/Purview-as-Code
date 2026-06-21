---
description: "Non-negotiable security principles for every file in this repository, grounded in Microsoft Learn."
applyTo: "**"
---

# Non-negotiable security principles

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md). Applies to every file. Domain-specific elaborations live in [`bicep.instructions.md`](bicep.instructions.md), [`data-plane-yaml.instructions.md`](data-plane-yaml.instructions.md), [`powershell.instructions.md`](powershell.instructions.md), [`github-actions.instructions.md`](github-actions.instructions.md), and [`sample-data.instructions.md`](sample-data.instructions.md).

All generated or modified content in this repo must conform to these principles. They are grounded in Microsoft Learn guidance.

1. **No secrets in source.** Never write a credential, connection string, access key, client secret, SAS token, PAT, or certificate into any file (`.bicep`, `.bicepparam`, `.yaml`, `.ps1`, `.md`, `.json`, workflow, `.env`). Reference secrets via Azure Key Vault or GitHub Actions secrets. Source: [Microsoft Purview credential management](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management), [Azure security — secrets](https://learn.microsoft.com/en-us/security/benchmark/azure/security-controls-v3-identity-management).

2. **Managed identity > service principal > key-based auth**, always in that order. Prefer in order of preference:
   1. Microsoft Purview account managed identity (system-assigned).
   2. User-assigned managed identity.
   3. Service principal (client credentials with federated credential / OIDC only — never a client secret in storage).
   4. Account keys / SQL auth / basic auth only when the source doesn't support MI or SP; the credential must live in Azure Key Vault.
   Source: [Credential management — recommended credential options](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management).

3. **OIDC federated credentials for CI/CD.** GitHub Actions must authenticate to Azure via `azure/login@v2` with `client-id` + `tenant-id` + `subscription-id` from GitHub Secrets and a federated credential on an Entra app or user-assigned managed identity. Do not use `creds:` JSON blobs, publish profiles, or stored client secrets. Source: [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect).

4. **Least privilege.** Every role assignment must be scoped as narrowly as possible:
   - Control plane: prefer `Contributor` on a dedicated resource group, never subscription-wide.
   - Data plane: assign Purview roles (`Collection Admin`, `Data Curator`, `Data Source Administrator`, `Policy Author`) at the **lowest** collection that still works — never at the root unless explicitly required.
   Assign to Entra groups or workload identities, not individual user accounts. Source: [Define Least Privilege model](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#define-least-privilege-model), [Access control in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-gov-classic-permissions).

5. **Private endpoints whenever network isolation is in play.** If any new resource (Purview, data source, Key Vault, storage, SHIR) is intended to be non-public, generate it with `publicNetworkAccess: 'Disabled'` and include the private endpoint + private DNS zone wiring. Do not leave public endpoints open as a convenience default for "prod-shaped" resources. Source: [Deploy private endpoints for Microsoft Purview accounts](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#deploy-private-endpoints-for-microsoft-purview-accounts), [Use private endpoints for your Microsoft Purview account](https://learn.microsoft.com/en-us/purview/catalog-private-link).

6. **Encryption and TLS.** Assume TLS 1.2+ everywhere. Never disable TLS, never pin to deprecated protocols, never set `minTlsVersion` below `1.2`. Keep encryption-at-rest defaults (Microsoft-managed keys) unless customer-managed keys are explicitly requested. Source: [Information protection and encryption](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#information-protection-and-encryption).

7. **Multifactor authentication and Conditional Access for humans.** Any human role assignment documented in this repo must note the MFA / Conditional Access expectation for privileged Purview roles. Source: [Use multifactor authentication and conditional access](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#use-multifactor-authentication-and-conditional-access).

8. **Resource locks on production.** Any production Purview account or resource group must document a `CanNotDelete` lock. Source: [Prevent accidental deletion of Microsoft Purview accounts](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#prevent-accidental-deletion-of-microsoft-purview-accounts).

9. **Idempotent, reversible, auditable.** Every change goes through a pull request. Destructive operations (delete collection, drop glossary term, remove scan) must be opt-in behind an explicit flag and never enabled by default in CI.

10. **OWASP-aware.** Validate external input, avoid shell injection in PowerShell (`Invoke-Expression`, string-concatenated commands), avoid logging tokens or secrets, and prefer parameterized API calls.

## What to do when a request conflicts with these principles

- State the conflict explicitly.
- Refuse the insecure path.
- Offer the secure alternative, grounded in the Learn citation above.
