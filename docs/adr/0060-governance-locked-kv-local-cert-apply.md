# 0060 — In a governance-locked tenant the CI Key Vault open fails; data-plane apply runs owner-driven on the ADR 0028 local cert

- **Status:** Proposed <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-07-18
- **Gates:** Unblocks the standing failure of `sync-*-from-tenant.yml` and `deploy-*.yml` in a governance-locked operator tenant (the daily red `sync-labels-from-tenant.yml`). Relates to [ADR 0011](0011-certificate-lifecycle.md) (KV-signed credential), [ADR 0028](0028-co-equal-local-cert-credential.md) (co-equal local cert), [ADR 0054](0054-tenant-touching-workflow-skip-gate.md) (onboarding skip gate), and [ADR 0057](0057-multi-environment-and-branch-model.md) (per-environment operator branches).
- **Deciders:** @marcusjacobson

## Context

Every data-plane workflow authenticates to Security & Compliance PowerShell with a Key-Vault-signed JWT ([ADR 0011](0011-certificate-lifecycle.md)): the runner temporarily opens the automation Key Vault's public network endpoint, signs the `client_assertion` with `az keyvault key sign`, then re-locks the vault. This "temp-open → sign → re-lock" dance is load-bearing for `deploy-labels.yml`, every `sync-*-from-tenant.yml`, and the other `Connect-IPPSSession`-bearing reconcilers.

Some operator tenants are subject to a **managed-tenant governance Azure Policy** — for example an MCAPS-style `modify` policy on Key Vault `publicNetworkAccess` — that **force-disables** public network access on every write. In such a tenant, `az keyvault update --public-network-access Enabled` is a silent no-op: the API returns `Disabled` immediately, with no resource lock or private endpoint involved. The temp-open step reports success but the vault never actually opens, so the runner's certificate read fails with `ForbiddenByConnection` ("Public network access is disabled…") and the workflow fails. This is observed daily on the operator `lab` tenant's scheduled `sync-labels-from-tenant.yml`. No `Start-Sleep` / poll tuning helps, because the setting never actually changes — the pattern is simply incompatible with the policy.

The repo already ships a local, Key-Vault-free auth path: [ADR 0028](0028-co-equal-local-cert-credential.md)'s co-equal local certificate, selected by `-LocalCertThumbprint` / `$env:PURVIEW_LOCAL_CERT_THUMBPRINT`, which signs the JWT in-process and never touches Key Vault. It works from the operator's workstation regardless of the vault's network policy. Not every operator tenant is governance-locked — a personal / non-managed tenant permits the temp-open, so the CI path continues to work there (verified: a non-governed operator tenant's `sync-labels-from-tenant.yml` opened its vault and exported successfully).

## Decision

We will treat the CI Key-Vault-open pattern as **available only where tenant governance permits it**, and make the ADR 0028 local-cert path the **sanctioned data-plane apply/sync route for governance-locked tenants**:

1. **CI is not the guaranteed data-plane path.** In a governance-locked tenant, `deploy-*.yml` and `sync-*-from-tenant.yml` cannot authenticate from a hosted runner and are **expected to fail** at the certificate read. That failure is a property of the tenant's policy, not a repo defect, and must be documented as such so it is not mistaken for a regression.
2. **The owner-driven local-cert path ([ADR 0028](0028-co-equal-local-cert-credential.md)) is the sanctioned route** for apply/export in a governance-locked tenant: run the reconciler locally with `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` set. Provision/rotate the credential with `scripts/New-LocalAutomationCertificate.ps1`.
3. **Non-governed tenants keep the CI path unchanged.** Where the policy is absent — verified with `az policy state list` showing no `modify`/`deny` effect force-disabling the vault — the temp-open pattern works and remains the default. If a governance exemption is later granted for a locked tenant, its CI path is restored automatically with no code change.
4. **A governance-locked tenant's scheduled `sync-*` cron is quieted, not left failing daily** — see the follow-up in Consequences.

## Consequences

**Easier / clarified:**

- The daily red `sync-labels-from-tenant.yml` runs on the governed tenant are explained and stop reading as an unexplained breakage — signal erosion this repo avoids everywhere else.
- Operators have one documented, working route ([ADR 0028](0028-co-equal-local-cert-credential.md)) for tenant apply/export under governance; it was used to bootstrap the label baselines and to adopt the taxonomy across tenants.

**Harder / accepted:**

- Data-plane apply/sync in a governance-locked tenant is **manual** (owner-driven local run), not push-button CI. Auditability shifts from the CI run log to the operator's local `-Verbose` output.
- Provisioning the local cert is a production Entra `keyCredential` change ([ADR 0028](0028-co-equal-local-cert-credential.md) §4) and cannot be automated in CI.

**Security posture is unchanged.** No identity, secret, or tenant surface changes. The local-cert path is already governed by [ADR 0028](0028-co-equal-local-cert-credential.md)'s threat model; this ADR only records *when* to prefer it. If anything it upholds least-privilege by not standing up long-lived network exposure to work around the policy.

**Follow-ups (not decided here):** whether to gate the scheduled `sync-*` crons behind a per-environment "CI data-plane enabled" variable so a governed tenant stops firing failing runs; and whether a private-endpoint + self-hosted-runner path is ever worth building (rejected below on cost).

## Alternatives considered

1. **Do nothing / keep status quo.** Reject. The scheduled syncs fail daily on the governed tenant and the apply path is silently unusable there; an unexplained standing red is exactly the signal-erosion this repo eliminates elsewhere.
2. **Request a governance policy exemption for the automation Key Vault.** Reject as the default; keep as an option. A managed-tenant governance policy is typically not operator-exemptable without a formal exception, is slow, and is outside the operator's control. Decision item 3 already restores the CI path automatically if an exemption ever lands.
3. **Private endpoint + self-hosted runner on the vault VNet.** Reject on cost. It would reintroduce a CI path but requires standing self-hosted-runner and networking infrastructure disproportionate to a single-operator lab, and adds a long-lived runner holding vault access — a materially worse threat model than the on-demand local cert.

## Citations

- [Azure Key Vault network security / `publicNetworkAccess`](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security) — the property the governance policy pins to `Disabled`.
- [Azure Policy `modify` effect](https://learn.microsoft.com/en-us/azure/governance/policy/concepts/effect-modify) — how the setting is force-reverted on every write.
- [Connect to Security & Compliance PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/connect-to-scc-powershell) — the session the vault-signed (or locally-signed) JWT authenticates.
- [ADR 0028 — co-equal local-cert credential](0028-co-equal-local-cert-credential.md) — the Key-Vault-free path this decision routes governance-locked apply/sync onto.
- [ADR 0057 — multi-environment and branch model](0057-multi-environment-and-branch-model.md) — the per-environment operator model this applies within.
