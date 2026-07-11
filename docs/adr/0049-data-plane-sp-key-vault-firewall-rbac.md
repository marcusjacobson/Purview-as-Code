# 0049 — Data-plane automation SP holds Key Vault Contributor for the firewall toggle

- **Status:** Proposed
- **Date:** 2026-07-11
- **Gates:** Bootstrap defect — unblocks every data-plane workflow that toggles the lab Key Vault firewall (`deploy-labels`, `sync-labels-from-tenant`, `deploy-label-policies`, `sync-label-policies-from-tenant`, `deploy-auto-label-policies`, `sync-auto-label-policies-from-tenant`, `deploy-data-plane`, `drift-detection`, `kv-temp-unlock`).
- **Deciders:** @marcusjacobson

## Context

The lab Key Vault (`kv-contoso-lab-01`) sits at `publicNetworkAccess: Disabled` in steady
state. A GitHub-hosted runner has no private-link or trusted-service path to it, so every
data-plane workflow that reads the automation certificate must briefly open the vault
firewall, do its work, and re-lock. Those workflows log in **once** as the data-plane OIDC
service principal (`gh-oidc-purview-data-plane`, [ADR 0010](0010-automation-identity-subject-model.md))
and run:

```text
az keyvault update --name <vault> --public-network-access Enabled --default-action Allow
```

That is a management-plane `Microsoft.KeyVault/vaults/write` operation. The bootstrap RBAC
([`scripts/New-AutomationRbac.ps1`](../../scripts/New-AutomationRbac.ps1) →
[`infra/modules/automation-rbac.bicep`](../../infra/modules/automation-rbac.bicep)) grants the
data-plane SP only `Key Vault Crypto User`, which is a data-plane `keys/sign` role
([ADR 0011](0011-certificate-lifecycle.md) §3 supersession) and does **not** include
`vaults/write`. So the toggle fails with an authorization error on
`Microsoft.KeyVault/vaults/write`.

Only [`validate-oidc-auth.yml`](../../.github/workflows/validate-oidc-auth.yml) works today,
because it uses a three-login dance: the **control-plane** SP (which holds `Contributor` on
`rg-purview-lab` via the same bootstrap module) opens and closes the firewall, and the
data-plane SP only signs. The other ~9 workflows assume the data-plane SP can manage its own
firewall — an assumption the bootstrap never satisfied.

This decision picks how to close that gap while honouring the least-privilege principle in
[`security.instructions.md`](../../.github/instructions/security.instructions.md) rule 4.

## Decision

We will grant the data-plane automation SP the built-in **`Key Vault Contributor`** role
(`f25e0fa2-a7c8-4377-a976-54943a77a395`), scoped to the lab Key Vault resource, in the
bootstrap. Specifically:

1. [`infra/modules/automation-rbac.bicep`](../../infra/modules/automation-rbac.bicep) declares
   a second data-plane assignment — `Key Vault Contributor` at vault scope — alongside the
   existing `Key Vault Crypto User` grant, using the same deterministic
   `guid(vault.id, principalId, roleDefinitionId)` name so re-runs stay idempotent.
2. [`scripts/New-AutomationRbac.ps1`](../../scripts/New-AutomationRbac.ps1) surfaces the new
   assignment ID in its output. No new parameters — the SP and vault are already resolved.
3. The automation-identity guide ([`docs/solutions/governance-foundation/automation-identity.md`](../solutions/governance-foundation/automation-identity.md))
   records the grant and its rationale.

`Key Vault Contributor` is management-plane only. Per the Learn role definition its
`dataActions` are empty, so it **cannot** read secrets, keys, or certificates, and it does not
include `Microsoft.Authorization/*/write`, so it **cannot** assign RBAC. It is the narrowest
built-in role that includes `Microsoft.KeyVault/vaults/write`, which is exactly the permission
the firewall toggle needs. The data-plane SP's ability to read the certificate remains gated by
its separate data-plane grants (`Key Vault Crypto User` for `keys/sign`, and the cert-scoped
grants owned by `New-AutomationCertificate.ps1`), which this decision does not widen.

## Consequences

**Easier:**

- Every listed data-plane workflow can open and re-lock the vault firewall under its own
  single data-plane login. No control-plane client ID needs to be threaded into ~9 workflows.
- The change is low-churn and internally consistent with the existing single-login workflow
  fleet.

**Harder / trade-offs:**

- The data-plane SP now holds a management-plane role on the vault in addition to its
  data-plane role. This is a deliberate, bounded widening: `vaults/write` lets the SP change
  vault *configuration* (including the firewall and, under the access-policy model, access
  policies). Because the vault runs the **RBAC** permission model (not access policies), the
  access-policy self-grant escalation that Learn warns about for `Key Vault Contributor` does
  not apply here — RBAC restricts permission management to `Owner` / `User Access Administrator`.
- **Idempotency caveat.** If a tenant already carries a hand-created, random-named role
  assignment for the same (data-plane SP, `Key Vault Contributor`, vault) tuple, a
  deterministic-name Bicep re-run collides with `RoleAssignmentExists`. Remove the
  random-named assignment first, then let the module create the `guid()`-named one.

**Security principle:** upholds least privilege
([`security.instructions.md`](../../.github/instructions/security.instructions.md) rule 4) by
choosing the narrowest built-in role that covers the operation and scoping it to the single
vault resource rather than the resource group. Steady-state vault posture
(`publicNetworkAccess: Disabled`, rule 5) is unchanged; the firewall is opened only for the
duration of a run and re-locked with `if: always()`.

## Alternatives considered

**Alternative A: Refactor all ~9 workflows to the control-plane three-login firewall pattern
used by `validate-oidc-auth.yml`, keeping the data-plane SP at `Key Vault Crypto User` only.**
Reject. Strictest least-privilege, but high churn: each workflow gains two extra `azure/login`
steps and a dependency on the control-plane client ID, multiplying the OIDC surface and the
re-lock failure modes across the fleet for a marginal privilege reduction over a
management-plane-only, data-read-incapable role.

**Alternative B: Grant the data-plane SP `Contributor` on the resource group (as the
control-plane SP has).** Reject. Far broader than needed — it authorizes writes to every
resource in `rg-purview-lab`, not just the vault, violating least privilege.

**Alternative C: Do nothing / keep the status quo.** Reject. The status quo leaves ~9
data-plane workflows permanently broken at their firewall-toggle step; the data plane cannot
be deployed or drift-checked through CI.

## Citations

- **[Azure built-in roles for Security — Key Vault Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security#key-vault-contributor)**
  Fetch date: 2026-07-11
  > "Manage key vaults, but does not allow you to assign roles in Azure RBAC, and does not allow you to access secrets, keys, or certificates."
- **[Azure Key Vault security features — RBAC permission model](https://learn.microsoft.com/en-us/azure/key-vault/general/rbac-guide)**
  Fetch date: 2026-07-11
  > "RBAC restricts permission management to only the 'Owner' and 'User Access Administrator' roles."
- [az keyvault update](https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-update)
- [Assign Azure roles using Bicep](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-bicep)
- [ADR 0010 — Automation identity subject model](0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](0011-certificate-lifecycle.md)
