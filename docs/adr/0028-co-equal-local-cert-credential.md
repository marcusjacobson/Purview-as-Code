# 0028 — Co-equal local-cert credential on the data-plane Entra app for the interactive dev loop, alongside the canonical Key-Vault-signed credential

- **Status:** Accepted
- **Date:** 2026-05-29
- **Gates:** Cross-cutting dev-loop infrastructure for every IPPS-authenticated script (`Connect-IPPSSession`-bearing reconcilers under [`scripts/`](../../scripts/)). Unblocks the in-workflow `-PruneMissing` path tracked separately (post-#436 Items 2a / 2b for orphan-label cleanup) and any future interactive lab run that today requires a Key Vault firewall toggle.
- **Deciders:** @contoso

## Context

[ADR 0011](0011-certificate-lifecycle.md) defines the canonical Connect-IPPSSession credential for this lab: a non-exportable RSA-2048 certificate stored in `kv-contoso-lab-01`, with the JWT `client_assertion` signed by [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) via `az keyvault key sign --algorithm PS256`. The private key never leaves Key Vault. ADR 0011 §3 (post-supersession) and `scripts/New-AutomationCertificate.ps1` ship that path, and every CI workflow under [`.github/workflows/`](../../.github/workflows/) consumes it.

The lab Key Vault sits at `publicNetworkAccess: Disabled` / `defaultAction: Deny` by design. Every IPPS run from the lab owner's workstation therefore costs:

- A firewall toggle to allow the runner IP (interactive `az keyvault update` from the local recipe in [`docs/runbooks/kv-temp-unlock.md`](../runbooks/kv-temp-unlock.md), or the audited [`kv-temp-unlock.yml`](../../.github/workflows/kv-temp-unlock.yml) workflow).
- A `Start-Sleep -Seconds 25` propagation wait.
- A re-lock step (`if: always()` in workflows; manual in local terminals).

There are seventeen `Connect-IPPSSession`-bearing scripts in the suite (`Deploy-Labels.ps1`, `Deploy-LabelPolicies.ps1`, `Deploy-AutoLabelPolicies.ps1`, `Deploy-DLPPolicies.ps1`, `Deploy-RetentionPolicies.ps1`, `Deploy-FilePlan.ps1`, `Deploy-IRMPolicies.ps1`, `Deploy-CommunicationCompliance.ps1`, `Deploy-EntraDirectoryRoles.ps1`, `Deploy-PurviewRoleGroups.ps1`, `Grant-PurviewRoleGroup.ps1`, `Enable-UnifiedAuditLog.ps1`, `Set-AuditRetentionPolicy.ps1`, `Sync-SITCatalog.ps1`, `Export-ContentExplorerData.ps1`, `Test-DSPMPosture.ps1`, `Test-DSPMforAIPosture.ps1`), and any iteration on any of them — author the change, smoke it locally, iterate — pays that cost again.

The KV-signed path is correct for CI: hosted GitHub runners are ephemeral, have no persistent local cert store to inherit from, and CI is exactly where "private key in HSM, signed remotely" is worth its operational cost. It is heavyweight for the interactive dev loop.

### What changed since ADR 0011

ADR 0011 (2026-04-19) and its 2026-04-24 supersession addendum chose Key Vault signing specifically because the Decision §3 attempt to import the KV-served PFX into `Cert:\CurrentUser\My` and call `Connect-IPPSSession -CertificateThumbprint` failed: `keyProperties.exportable = false` instructs Key Vault to never serve a usable PFX through its `secrets` endpoint, so the imported cert had `HasPrivateKey: False`. The supersession was correct for the credential ADR 0011 owns.

This ADR is not about importing the KV-served credential to the local machine. It is about **provisioning a separate, second credential** whose private key is generated locally with [`New-SelfSignedCertificate`](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate) directly into `Cert:\CurrentUser\My` with `KeyExportPolicy NonExportable`. The local cert and the KV cert are different objects with different lifecycles and different threat models; they coexist as co-equal `keyCredentials` on the same data-plane Entra app per [keyCredential](https://learn.microsoft.com/en-us/graph/api/resources/keycredential).

### Threat-model framing

| Property | KV-signed (ADR 0011) | Local cert (this ADR) |
|---|---|---|
| Private key location | `kv-contoso-lab-01` HSM-backed | `Cert:\CurrentUser\My`, DPAPI-protected |
| Exportable | No (`exportable = false`) | No (`KeyExportPolicy NonExportable`) |
| Bound to | Network reachability + Key Vault RBAC | One Windows user account on one machine |
| Compromise vector | KV firewall breach + RBAC escalation | Lab owner's signed-in Windows session |
| CI usable | Yes | No (no `Cert:\CurrentUser\My` on a hosted runner) |
| Dev-loop usable | Yes (with KV unlock) | Yes (no KV unlock) |

The two credentials defend against different attacks, so a single credential covering both surfaces would be strictly weaker. They are co-equal, not redundant.

### Microsoft Learn coverage as of 2026-05-29

- **[New-SelfSignedCertificate](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate).** Documents `-KeyExportPolicy NonExportable`, `-KeyAlgorithm`, `-KeyLength`, `-HashAlgorithm`, `-KeyUsage`, `-NotAfter`, `-CertStoreLocation 'Cert:\CurrentUser\My'`. Verified.
- **[X509KeyStorageFlags](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.x509keystorageflags) / [RSA.SignData](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.signdata) / [RSASignaturePadding.Pss](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsasignaturepadding).** Document the in-process RSA-PSS / SHA-256 signing path used by [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) when the local-cert path is selected. Verified.
- **[Microsoft identity platform certificate credentials](https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials).** Documents the JWT header shape (`alg: PS256`, `x5t#S256`) that both transports emit. Verified — unchanged from ADR 0011.
- **[keyCredential resource](https://learn.microsoft.com/en-us/graph/api/resources/keycredential) and [Update application](https://learn.microsoft.com/en-us/graph/api/application-update).** Document the Graph PATCH shape used to upload the local public cert as an *additional* keyCredential alongside the existing KV-signed credential. Verified — the operation is a property update on `keyCredentials` and accepts an array, so an additive merge is the documented behavior.

## Decision

We add a **co-equal** local-machine certificate credential to the data-plane Entra app `gh-oidc-purview-data-plane`, owned by the lab owner's interactive Windows account, alongside the existing KV-signed credential.

1. **Storage: `Cert:\CurrentUser\My`, no PFX on disk.** The private key is generated in-place via [`New-SelfSignedCertificate -KeyExportPolicy NonExportable -CertStoreLocation 'Cert:\CurrentUser\My'`](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate) and bound to the operator's Windows DPAPI key. No `.pfx`, `.p12`, `.key`, or `.pem` is produced on the documented happy path. `.gitignore` carries defensive patterns for all four extensions in case a contributor ever generates one out-of-band — this is belt-and-braces, not the primary control.

2. **Cert shape.** RSA-2048, SHA-256, 24-month validity, `KeyUsage = DigitalSignature, KeyEncipherment`, `Subject = CN=gh-oidc-purview-data-plane-local-<user>-<machine>`. The subject CN is deterministic on `($env:USERNAME, $env:COMPUTERNAME)` so a future audit of the data-plane app's `keyCredentials` listing can trace every public key back to the operator workstation that uploaded it. The cert shape is intentionally aligned with ADR 0011 §1's key algorithm and hash so signature verification on the Microsoft identity platform side is identical for both credentials.

3. **Provisioning script: [`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1).** Idempotent on the subject CN: a non-expired matching cert is reused (`NoChange`). `-RemoveExisting` revokes the local cert and re-issues. The script supports `-WhatIf` per repo convention.

4. **Graph upload: additive only.** The new public `.cer` is appended to `keyCredentials` on `gh-oidc-purview-data-plane` via `PATCH https://graph.microsoft.com/v1.0/applications/{id}` ([Update application](https://learn.microsoft.com/en-us/graph/api/application-update)). The KV-signed credential and every other existing credential are preserved. Dedup on `customKeyIdentifier` (`SHA-256(cert.RawData)`) per [keyCredential](https://learn.microsoft.com/en-us/graph/api/resources/keycredential) so a re-run with the same cert is a no-op. `scripts/New-LocalAutomationCertificate.ps1` is not allowed to call Graph `application: removeKey` or to issue a `keyCredentials = @($onlyTheNewOne)` PATCH — the merge helper rejects any path that would drop the KV credential.

5. **Token-helper auth resolution: parameter > env var > KV fallback.** [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) gains an optional `-LocalCertThumbprint` parameter and reads `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` when the parameter is omitted. If either resolves to a value, the script takes the local-cert path: resolves the thumbprint in `Cert:\CurrentUser\My`, validates `HasPrivateKey = $true` and `NotAfter > Get-Date`, signs the JWT digest in-process via [`RSA.SignData(..., HashAlgorithmName.SHA256, RSASignaturePadding.Pss)`](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.signdata), and skips Key Vault entirely. If neither is set, the original ADR 0011 path runs unchanged.

6. **No silent fallback when the local path is requested.** If `-LocalCertThumbprint` (or `$env:PURVIEW_LOCAL_CERT_THUMBPRINT`) is set but the thumbprint does not resolve, has no private key, or is expired, [`Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) throws with a named reason. We do not auto-fall-back to KV because doing so would mask a real configuration error and cost the operator a surprise KV-unlock prompt minutes later.

7. **No consumer-script wiring required.** Because resolution lives in [`Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) and reads the env var transparently, none of the seventeen `Connect-IPPSSession` callers need a code change today. Every script that does not pass `-LocalCertThumbprint` to the helper picks up the local cert when the env var is set and the KV path when it isn't. Individual consumers may add an explicit `-LocalCertThumbprint` pass-through parameter in a future PR if they want a per-call override; this ADR does not require it.

8. **CI workflows unchanged.** Hosted runners have no `Cert:\CurrentUser\My`, and no `kv-unlock` workflow run on a hosted runner sets `PURVIEW_LOCAL_CERT_THUMBPRINT`. Every CI invocation of [`Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) therefore falls through to the KV path. ADR 0011 stays in force for CI.

9. **Per-operator persistence is out of scope.** The script prints the thumbprint and the env-var line the operator should add to their shell profile (`[Environment]::SetEnvironmentVariable('PURVIEW_LOCAL_CERT_THUMBPRINT', '<value>', 'User')`). The repo never carries the thumbprint in `infra/parameters/lab.yaml` or any other committed source, because the value is per-user and per-machine — committing it would step on every other contributor.

10. **Revocation.** [`docs/runbooks/local-cert-provisioning.md`](../runbooks/local-cert-provisioning.md) documents the revocation flow: remove the public `keyCredential` from the data-plane app via Graph (`PATCH /applications/{id}` with the local cert's `customKeyIdentifier` excluded) and `Remove-Item Cert:\CurrentUser\My\<thumbprint>`. The KV credential keeps CI working unchanged.

### What this ADR does NOT change

- **ADR 0011 stands in full.** The KV-signed cert, its 12-month rotation cadence under human approval, the four-layer out-of-band detection, the data-plane-only asymmetry, and the Key Vault RBAC grants on the data-plane app's service principal are unchanged.
- **Connect-IPPSSession contract.** Both transports produce a JWT with `alg: PS256`, `x5t#S256` over the corresponding public cert, exchanged at the v2.0 token endpoint per [client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow). `Connect-IPPSSession -AccessToken $tok.AccessToken` consumes either identically.
- **Control-plane app posture.** `gh-oidc-purview-control-plane` is untouched. ADR 0011 §5 forbids attaching any certificate to it.
- **`-PruneMissing` semantics.** The orphan-prune capability for `Deploy-Labels.ps1` and similar reconcilers is intentionally not part of this ADR; it ships separately. This ADR's value to that work is removing the KV unlock as a precondition for any future local prune run.

## Consequences

**Easier:**

- **Interactive runs of every IPPS reconciler in the suite no longer require a KV unlock window.** A 25-second sleep, two `az keyvault update` calls per run, and the risk of leaving the vault open on a failed `if: always()` (local recipe) all go away for the dev loop.
- **The two-credential model gives a clean compromise-recovery story.** If the lab owner's laptop is compromised, revoke the local cert via Graph and re-issue; CI keeps working. If KV is compromised, the local cert keeps the dev loop working while ADR 0011's rotation runs.
- **The token helper is now testable.** [`tests/scripts/Get-PurviewIPPSAccessToken.Tests.ps1`](../../tests/scripts/Get-PurviewIPPSAccessToken.Tests.ps1) exercises the cert-resolution helper and the in-process signing path against a throwaway in-memory cert; before this ADR the helper had no unit tests because the KV-sign path required `az login`.

**Harder:**

- **One more credential to inventory.** The four-layer out-of-band detection from ADR 0011 §6 now has to allow for *two* expected `keyCredentials` per data-plane app, not one. The matching layer-3 invariant in [`scripts/New-AutomationCertificate.ps1`](../../scripts/New-AutomationCertificate.ps1) ("abort if app carries a different single thumbprint") needs a follow-up ADR or addendum before that script is next run, because today it treats anything other than one matching thumbprint as an anomaly. **This ADR explicitly defers that change** — it is captured in §6 below as a re-open trigger so [`New-AutomationCertificate.ps1`](../../scripts/New-AutomationCertificate.ps1) does not silently regress this ADR.
- **`customKeyIdentifier` per-operator listings are visible to anyone with read access to the data-plane Entra app.** The deterministic subject CN includes the operator's Windows username and machine name. Treat the listing as roughly equivalent to who has SSH-keyed an org server: useful, not secret, not catastrophic.
- **No CI enforcement that the local path is taking effect on a dev-loop run.** The token helper emits a `Write-Verbose` line on each call indicating which transport was used; the operator can confirm in a `-Verbose` log but there is no machine-checked invariant.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Reinforced. The defensive `.gitignore` additions (`*.p12`, `*.pem`) ensure that even if a contributor generates a PFX out-of-band, it cannot be committed by accident. The thumbprint itself is a public-key fingerprint, not a secret, but it is per-user and never goes in committed source either.
- **#2 (managed identity > service principal > key-based auth).** Same posture as ADR 0011 — both credentials are certificate-backed; neither is a password or shared secret. The local cert's private key is `NonExportable` so it cannot be repackaged into a portable artifact.
- **#4 (least privilege).** Unchanged. The local-cert credential authenticates *to* the same data-plane app whose RBAC scope is already minimised. The new credential adds no new permissions and grants no new operations.
- **#9 (idempotent, reversible, auditable).** Reinforced. Cert provisioning is idempotent on the subject CN; rotation via `-RemoveExisting` is explicit; revocation via the documented Graph PATCH is reversible; every step prints what it will do under `-WhatIf` before writing.
- **#10 (OWASP-aware).** Token-helper input validation rejects malformed thumbprints (`^[0-9A-F]{40}$`) and emits structured exceptions rather than silently failing.

## Alternatives considered

1. **Keep the status quo (KV-signed only).** Rejected. The cost of every dev-loop iteration on any of the seventeen IPPS scripts is a KV firewall toggle, and the friction has already shaped earlier design decisions (for example the original Item 2 brief that triggered #436 assumed a manual KV-unlock window for the orphan-label prune run). The cost compounds across the script suite.

2. **Replace the KV-signed credential with the local cert.** Rejected. The local cert cannot live on hosted GitHub runners (no persistent `Cert:\CurrentUser\My`), so CI would lose its certificate path. Replacement also forfeits the property that the KV credential's private key is in an HSM. ADR 0011 picked KV signing for documented reasons that have not changed.

3. **PFX file on disk under `~/.purview-as-code-lab/` (storage model B).** Rejected in the 2026-05-29 design discussion. PFX-on-disk is what people do when they need to share the key across machines, which the lab owner does not. A non-exportable in-store cert achieves the same operational goal with no file to gitignore by accident, no file to back up, and no file that an `Out-File -Encoding ascii ~/cert.pfx` typo could leak.

4. **Pass `-LocalCertThumbprint` explicitly through every one of the seventeen consumer scripts in this PR.** Rejected. The original issue body undercounted consumers at 5; the real number is 17, and wiring all of them was the original scope. The transparent env-var path inside the token helper makes consumer wiring unnecessary for the value this ADR delivers. Individual consumers can add an explicit override parameter in a future PR if a specific call site needs it; the helper-side env-var fallback is the single point of truth.

5. **Persist the thumbprint in `infra/parameters/lab.yaml` under `automation.apps.dataPlane.localCertThumbprint`.** Rejected. The thumbprint is per-user and per-machine — committing it would step on every other contributor's value. The environment variable is the documented per-operator persistence boundary.

6. **Use the [Microsoft.Identity.Client](https://learn.microsoft.com/en-us/entra/msal/dotnet/) (MSAL) `WithCertificate` builder instead of hand-rolling the JWT.** Rejected for this iteration. The hand-rolled JWT in [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) is shared with the KV-sign path, so adopting MSAL would mean either (a) two parallel auth code paths, doubling the surface area, or (b) re-implementing the KV-sign path on top of MSAL's `WithSignedAssertionDelegate`, which is a larger and orthogonal change. Worth revisiting if MSAL Connect-IPPSSession integration improves.

## Re-open triggers

This ADR is to be re-opened with a follow-up ADR or addendum if any of the following becomes true:

- **The four-layer detection invariant in [`scripts/New-AutomationCertificate.ps1`](../../scripts/New-AutomationCertificate.ps1) needs to be re-run.** That script aborts on "more than one keyCredential" today, which is exactly the steady state this ADR introduces. Before its next run, an addendum to ADR 0011 (or a new ADR) must record that two keyCredentials is the new expected baseline.
- **A second lab operator joins.** The deterministic subject CN includes one operator's username; a second operator implies multiple local credentials, which fits the additive merge model but raises new questions about revocation when one operator leaves.
- **CI ever needs the local-cert path.** Today hosted runners have no `Cert:\CurrentUser\My`. If a self-hosted runner is ever introduced, the env-var resolution would let it pick up a runner-local cert, but the threat model of a long-lived runner with a cert in its user store is materially different and warrants a new decision.
- **A new IPPS-authenticated script is added to the suite.** The env-var resolution path makes it work automatically; nothing about this ADR needs to change. This trigger is recorded only so future contributors don't assume per-script wiring is needed.

## Citations

- **[New-SelfSignedCertificate](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate)**
  Fetch date: 2026-05-29
  Reference for the local cert generation parameters: `-KeyExportPolicy NonExportable`, `-CertStoreLocation 'Cert:\CurrentUser\My'`, `-KeyAlgorithm RSA`, `-KeyLength 2048`, `-HashAlgorithm SHA256`, `-KeyUsage DigitalSignature, KeyEncipherment`, `-NotAfter`. Cited in Decision §2-§3.
- **[X509KeyStorageFlags](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.x509keystorageflags)**
  Fetch date: 2026-05-29
  Reference for the `NonExportable` storage semantic that ADR 0028 §1 relies on. Cited in Decision §1 and the threat-model table.
- **[RSA.SignData](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsa.signdata) / [RSASignaturePadding.Pss](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.rsasignaturepadding)**
  Fetch date: 2026-05-29
  Reference for the in-process PS256 signing call inside [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1)'s `ConvertTo-LocalJwtSignature` helper. Cited in Decision §5.
- **[Microsoft identity platform certificate credentials](https://learn.microsoft.com/en-us/entra/identity-platform/certificate-credentials)**
  Fetch date: 2026-05-29
  Reference for the JWT header (`alg: PS256`, `x5t#S256` thumbprint format) emitted by both transports. Same page cited by ADR 0011.
- **[Microsoft identity platform OAuth 2.0 client credentials flow](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow)**
  Fetch date: 2026-05-29
  Reference for the token-endpoint exchange (`client_assertion_type=...:jwt-bearer`) shared between transports. Same page cited by ADR 0011.
- **[keyCredential resource](https://learn.microsoft.com/en-us/graph/api/resources/keycredential) and [Update application](https://learn.microsoft.com/en-us/graph/api/application-update)**
  Fetch date: 2026-05-29
  Reference for the additive PATCH on the data-plane app's `keyCredentials` array used by [`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1).
- **[Connect-IPPSSession -AccessToken](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession)**
  Fetch date: 2026-05-29
  Reference for the IPPS connection cmdlet that consumes the access token both transports produce. Same page cited by ADR 0011.
- [ADR 0010](0010-automation-identity-subject-model.md) — defines the Entra apps and federated credential subjects this ADR's data-plane app is the second credential of.
- [ADR 0011](0011-certificate-lifecycle.md) — defines the canonical KV-signed credential this ADR is co-equal to. Not superseded.
- [ADR 0012](0012-environment-parameters-file.md) — defines `infra/parameters/lab.yaml`. Cited in Alternative 5.
- [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../scripts/Get-PurviewIPPSAccessToken.ps1) — the auth-path resolver.
- [`scripts/New-LocalAutomationCertificate.ps1`](../../scripts/New-LocalAutomationCertificate.ps1) — the local cert provisioning helper.
- [`docs/runbooks/local-cert-provisioning.md`](../runbooks/local-cert-provisioning.md) — operator-facing procedures: provision, verify, rotate, revoke.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" rule applied throughout.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — principles cited in Consequences.
