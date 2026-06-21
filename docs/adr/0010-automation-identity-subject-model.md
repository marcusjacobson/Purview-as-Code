# 0010 — Automation identity subject model: one Entra app per workflow, bound to a GitHub Environment

- **Status:** Accepted
- **Date:** 2026-04-19
- **Gates:** [`docs/project-plan.md`](../project-plan.md) §8 Q3; paired with §8 Q4 (ADR pending) unblocks Wave 0 [`scripts/New-AutomationIdentity.ps1`](../../scripts). Once `New-AutomationIdentity.ps1` lands, this ADR transitively unblocks Wave 0 `scripts/Grant-PurviewRoleGroup.ps1` (a.1), `scripts/Deploy-PurviewRoleGroups.ps1` (a.3), `scripts/Grant-M365ComplianceRoles.ps1` (#3), `scripts/Enable-UnifiedAuditLog.ps1` (#4), and §8 Q6 OIDC validation (#8).
- **Deciders:** @contoso

## Context

The repo targets one environment (`lab`, the `contoso-lab` Microsoft Purview account in the `contoso.onmicrosoft.com` tenant) per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md). Today both deployment workflows — [`deploy-infra.yml`](../../.github/workflows/deploy-infra.yml) (control plane, Bicep) and [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) (data plane, PowerShell against Purview REST, Microsoft Graph, and Security & Compliance PowerShell) — authenticate to Azure through a single shared `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` secret triple, using [`azure/login@v2`](https://github.com/Azure/login) with OpenID Connect (OIDC). That identity does not yet exist — both workflows are marked "Manual-dispatch only until Wave 0 ships OIDC federated credentials." This ADR decides how that identity is shaped.

The project plan framed §8 Q3 as *"One federated credential per workflow file, or a single shared subject?"* — i.e., which value appears in the `sub` claim of the GitHub Actions OIDC token that Entra validates before issuing an access token. Per [Configure an app to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust) and [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure), GitHub Actions exposes several well-defined subject shapes:

1. **Repository-wide:** `repo:<org>/<repo>:ref:refs/heads/<branch>` — every workflow running on that branch can mint a token. Broad; no separation by workflow file or workflow purpose.
2. **Per-workflow-file:** `repo:<org>/<repo>:job_workflow_ref:<workflow-file-path>@<ref>` — only jobs reusing that exact workflow file can mint a token. Narrow; a compromised unrelated workflow in the same repo cannot impersonate.
3. **Environment-bound:** `repo:<org>/<repo>:environment:<env-name>` — only jobs that declared `environment: <env-name>` can mint a token, which means any GitHub Environment protection rules (branch restriction, required reviewers, wait timer) also run. Narrow; adds GitHub-side enforcement on top of the federation.
4. **Pull-request:** `repo:<org>/<repo>:pull_request` — PR-triggered runs. Never used for production-effecting writes.

The repo's posture is stricter than a typical lab because the explicit project intent is that **this repo is the source of truth for Microsoft Purview and should be able to overwrite configuration that was changed through the Purview portal**. That is a high-impact write authority. The identity that exercises it must not be reusable by any unrelated code path, must be independently rotatable, and must leave a clean per-plane audit trail.

Two further constraints from existing decisions:

- [ADR 0009](0009-portal-role-group-api-ship-order.md) pinned the data plane's portal-role-group path to Security & Compliance PowerShell with certificate-based app-only auth — so the data-plane identity is *already* certificate-bound, not managed-identity-bound (per the bounded relaxation of [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #2 documented there).
- The control plane is pure ARM (Bicep) and needs only a federated OIDC token → no certificate material attached to the control-plane identity.

These two surfaces have *different* credential types today: OIDC-only for the control plane; OIDC + certificate for the data plane. A single shared app would be forced to carry both, which is overprivileged for either single use.

### Reviewer concerns that frame this ADR

The deciders explicitly called out three concerns that this ADR and §8 Q4 must jointly satisfy:

1. **Credential storage must be as secure as possible.** No secrets in source, no long-lived passwords, Key Vault for the cert (§8 Q4), GitHub OIDC with federation for the token exchange.
2. **Pipeline authentication must work end-to-end.** CI must be able to reach Azure ARM, Microsoft Graph, Purview REST, and Security & Compliance PowerShell without any human step.
3. **Certificate / credential rotation must be automatable but stay under human administrative control, with detection for out-of-band changes.** A cert rotated outside the repo's control is a signal that something is wrong.

This ADR handles concerns 1 and 2 at the *subject / identity shape* layer. Concern 3's certificate-rotation mechanics are the direct scope of §8 Q4. However, this ADR also shapes the **detection surface** for concern 3 — because detection depends on having narrowly-scoped, per-purpose app principals whose normal call patterns are distinctive enough for anomalies to stand out.

## Decision

1. **We will create two Microsoft Entra application registrations**, one per workflow file:

   | App (Entra display name) | Workflow file | Scope of action |
   |---|---|---|
   | `gh-oidc-purview-control-plane` | [`.github/workflows/deploy-infra.yml`](../../.github/workflows/deploy-infra.yml) | Azure Resource Manager against the `rg-purview-lab` resource group. |
   | `gh-oidc-purview-data-plane` | [`.github/workflows/deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) | Microsoft Purview REST, Microsoft Graph, Security & Compliance PowerShell. |

   [`.github/workflows/validate.yml`](../../.github/workflows/validate.yml) gets **no** app. It performs only offline linting and never calls Azure; `azure/login` is not invoked there.

2. **Each app binds to a GitHub Environment named `lab` via an `environment` subject.** The federated credential on each app uses the subject:

   ```text
   repo:contoso/Purview-as-Code-Generic:environment:lab
   ```

   per [Configuring OpenID Connect in Azure — Entity-type examples](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-cloud-providers#example-subject-claims). Each workflow job that calls `azure/login` **must** declare `environment: lab` so the OIDC token carries the matching `sub` claim. The `lab` Environment in GitHub Settings is the enforcement point for branch restrictions and required reviewers (see below).

3. **The `lab` GitHub Environment is configured with protection rules** per [Managing environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/managing-environments-for-deployment):
   - **Deployment branches: selected branches only → `main`.** PR branches cannot mint a `lab`-subject OIDC token. Combined with the `environment:lab` subject on the federation, this gives a two-layer guard: GitHub refuses to dispatch the job if the branch isn't `main`, and Entra refuses to mint an access token if (somehow) the wrong subject claim arrives.
   - **Required reviewers: @contoso** (or a single-member Entra group, interchangeable). Every deploy run requires manual approval. That approval is the administrative control surface called out in the "Certificate / credential rotation must be automatable but stay under human administrative control" concern above: no token is minted without a human click.
   - **Wait timer: 0** for the lab. The timer exists if the user later needs a cooling-off window between approval and token minting.

4. **No additional federated credential subjects are added to either app.** In particular, no `ref:refs/heads/main` subject, no `pull_request` subject, no `job_workflow_ref:...` subject, no PAT fallback, no client secret fallback. Every alternate credential path is an out-of-band attack surface. The single-subject invariant is the anchor for detection (see Consequences).

5. **Each app gets its own least-privilege role assignment set.** [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #4 applies; the exact role assignments are the scope of the `scripts/New-AutomationIdentity.ps1` build PR. The invariant this ADR pins is that the control-plane app never gets a data-plane role and vice versa.

6. **Secret names in GitHub are split per app**, matching the per-app shape:

   | Current shared secret | Replaced by |
   |---|---|
   | `AZURE_CLIENT_ID` | `AZURE_CLIENT_ID_CONTROL_PLANE`, `AZURE_CLIENT_ID_DATA_PLANE` |
   | `AZURE_TENANT_ID` | unchanged (same tenant) |
   | `AZURE_SUBSCRIPTION_ID` | unchanged (same subscription for the lab) |

   The secret rename lands in the `New-AutomationIdentity.ps1` build PR alongside the matching workflow edits. This ADR does not ship that edit.

## Scope — what this ADR does *not* decide

Matching the narrow-ADR pattern used by [ADR 0008](0008-portal-role-group-api.md) and [ADR 0009](0009-portal-role-group-api-ship-order.md), the following adjacent decisions stay out of scope:

- **Certificate issuance, storage, and rotation cadence.** Decided by §8 Q4 (next ADR). That ADR will pin: Key Vault as the cert store, self-signed vs issuer-backed, validity period, rotation trigger, automation boundary, and the detection controls for out-of-band rotation called out in reviewer concern #3. This ADR pins only the *subject / identity shape* that the cert gets attached to.
- **The exact ARM / Graph / Purview / Exchange role assignments** each app receives. Those are part of the `scripts/New-AutomationIdentity.ps1` module header and will cite each permission to Learn inline.
- **Entra Conditional Access policies that gate each app's interactive surface.** Workload identities support Conditional Access via [workload identities Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity); recommended posture is noted in Consequences but scoped out of this ADR.
- **Migration of the existing shared-secret `AZURE_CLIENT_ID`** in the two workflow files. The rename is trivial but ships with the build PR to keep this ADR docs-only.

## Consequences

**Easier.**

- **Blast-radius reduction.** A compromise of one app (or its cert) only exposes one plane. If a cert rotates outside this repo's control (the scenario flagged in reviewer concern #3), only the affected plane is dead until remediated — not the entire deployment surface.
- **Clean per-plane detection.** Entra sign-in logs and app-credential audit events are filterable by `appId`. An app ever signing in from a non-GitHub-Actions IP, or outside a `main`-branch push, or in a time window when no GitHub run exists, is a single-line Kusto / Sentinel alert. Per [Entra sign-in logs](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins) and [Entra audit log events](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-audit-logs).
- **Credential-addition detection.** Because the single-subject invariant in decision #4 is deliberate, the *presence* of any additional federated credential, client secret, or certificate on either app is itself an anomaly signal. Two mechanisms apply:
  - **Entra Audit Log** emits `Add credentials to application` events that a [Microsoft Sentinel analytic rule](https://learn.microsoft.com/en-us/azure/sentinel/detect-threats-built-in) can fire on.
  - **Microsoft Graph change notifications** on the `applications` resource (see [Change notifications for Entra ID applications](https://learn.microsoft.com/en-us/graph/api/resources/webhooks)) can stream the same events in near-real-time to a SIEM or to a GitHub issue via a webhook.
  These mechanisms assume a single-subject baseline — they work because decision #4 keeps that baseline clean. This is concrete detection for reviewer concern #3 even though the cert itself is shaped by §8 Q4.
- **Independent rotation.** Either cert (or either OIDC credential) can be rotated without touching the other plane. Rotation cadences do not have to be synchronized.
- **Reviewer gate for every deploy.** The required-reviewer rule on the `lab` Environment means no OIDC token is minted without a human click on a specific run against a specific commit on `main`. This is the "administrative control" surface called out in reviewer concern #3.

**Harder.**

- **Two Entra apps to bootstrap, rotate, and track.** The `New-AutomationIdentity.ps1` build PR (§8 Q4-gated) will run twice — once per app — and its idempotency / drift-report contract has to handle the two-app shape. Additional ~30 minutes of build effort; no new category of work.
- **Two sets of GitHub Secrets.** `AZURE_CLIENT_ID_CONTROL_PLANE` and `AZURE_CLIENT_ID_DATA_PLANE` replace the single `AZURE_CLIENT_ID`. The `lab` Environment holds both as environment-scoped secrets per [GitHub Environments secrets](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#environment-secrets).
- **Workflow edits** in both `deploy-infra.yml` and `deploy-data-plane.yml` to reference the correct per-plane secret. Trivial (`${{ secrets.AZURE_CLIENT_ID_CONTROL_PLANE }}`); handled by the build PR.
- **The required-reviewer rule adds a manual click to every lab deploy.** Acceptable for this repo's posture. If it becomes painful, the reviewer rule can be relaxed in a later ADR; the OIDC subject shape stays.

**Unblocks (once paired with §8 Q4 ADR).**

- Wave 0 #5 `scripts/New-AutomationIdentity.ps1` — the script's input parameters (app display name, target workflow file, subject shape) are all decided here.
- Indirectly, every held Wave 0 item that depends on the automation identity: a.1 `Grant-PurviewRoleGroup.ps1`, a.3 `Deploy-PurviewRoleGroups.ps1`, #3 `Grant-M365ComplianceRoles.ps1`, #4 `Enable-UnifiedAuditLog.ps1`, and #8 OIDC validation.

**Does not unblock what it did not unblock before.** The §8 Q4 ADR must still land before the build PR for `New-AutomationIdentity.ps1` can start. Q3 + Q4 together are the unblock; Q3 alone pins only the subject.

**Security principle posture.** This ADR *upholds*:

- [`security.instructions.md`](../../.github/instructions/security.instructions.md) **rule #1** ("No secrets in source") — OIDC federation, no client secret anywhere.
- **Rule #2** ("Managed identity > service principal > key-based auth") — bounded: workload identities federated to GitHub are the recommended pattern for GitHub Actions → Azure per [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect); a GitHub Actions runner is not an Azure workload, so a managed identity is not the right primitive. The data-plane app's certificate-based app-only credential is inherited from ADR 0009 and is cited there.
- **Rule #3** ("OIDC federated credentials for CI/CD") — central to the decision.
- **Rule #4** ("Least privilege") — pinned by the per-workflow app split; exact scopes deferred to build PR.
- **Rule #9** ("Idempotent, reversible, auditable") — reviewer-gated environment, per-app audit trail.

## Alternatives considered

- **Single shared app with a broad `ref:refs/heads/main` subject.** Rejected — one breach, two planes down. No per-plane audit trail. Rotation of the cert (needed by the data plane per ADR 0009) also rotates the control-plane credential, coupling two unrelated release pipelines. Fails the reviewer-concern-#1 "blast radius" test.
- **Single shared app with an `environment:lab` subject.** Rejected — same blast-radius problem as above. Adding the environment gate is a real improvement over `ref:` only, but it doesn't fix the cross-plane privilege sprawl inherent to one app doing everything.
- **Per-workflow `job_workflow_ref:` subject instead of `environment:` subject.** Rejected — `job_workflow_ref` works, but it offloads all enforcement to Entra. Pairing with a GitHub Environment gives a second enforcement point (branch restriction + required reviewer) that fires *before* the OIDC token is even minted. That redundancy is valuable for a source-of-truth repo.
- **Three apps, one per workflow file, including validate.yml.** Rejected — `validate.yml` does not call Azure. Giving it an Entra app is overhead with no security gain and one more credential to rotate and detect.
- **Keep the status quo (manual-dispatch, shared secret placeholder).** Rejected — blocks Wave 0 #5 indefinitely, and the manual-dispatch guard is not a security control, it's a placeholder.

## Citations

- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation) — Entra concept overview.
- [Configure an app to trust an external identity provider](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust) — the federated credential object.
- [Use Azure Login with OpenID Connect](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect) — the GitHub Actions → Azure pattern this ADR adopts.
- [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure) — GitHub-side setup.
- [Security hardening your deployments — OIDC subject claims](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect#understanding-the-oidc-token) — canonical subject formats.
- [Managing environments for deployment](https://docs.github.com/en/actions/deployment/targeting-different-environments/managing-environments-for-deployment) — branch restrictions, required reviewers, wait timers.
- [Using environments for deployment — environment secrets](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#environment-secrets) — per-environment GitHub Secrets scope.
- [Workload identities Conditional Access](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity) — deferred but noted.
- [Entra sign-in logs](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-sign-ins) and [Entra audit log events](https://learn.microsoft.com/en-us/entra/identity/monitoring-health/concept-audit-logs) — detection surface.
- [Microsoft Sentinel analytics rules](https://learn.microsoft.com/en-us/azure/sentinel/detect-threats-built-in) — detection mechanics for credential-addition anomalies.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries" (single-env `lab` posture).
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — rules #1, #2, #3, #4, #9.
- [`.github/instructions/github-actions.instructions.md`](../../.github/instructions/github-actions.instructions.md) — workflow authoring rules the build PR will follow.
- [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) — drift-report contract the `New-AutomationIdentity.ps1` script will follow; the `Runtime: pwsh 7.4+ only, and the Connect-IPPSSession auth constraint` section (added in PR #20) governs the data-plane app's certificate-auth invocation.
- [ADR 0001](0001-m365-licensing-verification.md), [ADR 0002](0002-administrative-units.md), [ADR 0009](0009-portal-role-group-api-ship-order.md) — adjacent ADRs.
