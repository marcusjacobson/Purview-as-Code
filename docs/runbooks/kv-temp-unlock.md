# Runbook: Temporarily unlock `kv-contoso-lab-01`

Use this runbook when you need to open the lab Key Vault firewall briefly
to perform a task that cannot complete against the steady-state
`publicNetworkAccess: Disabled` posture (for example: a one-off
`Get-AzKeyVaultSecret` call from your workstation while preparing a new
deploy script).

For day-to-day deploys, prefer:

- The per-solution deploy workflows (`deploy-labels.yml`,
  `deploy-label-policies.yml`, `deploy-auto-label-policies.yml`,
  `deploy-dlp.yml`, `deploy-irm.yml`) and their `sync-*-from-tenant.yml`
  reverse companions, which already handle their own unlock window via
  the `validate-oidc-auth.yml` pattern: each temp-opens the Key Vault
  public endpoint for the duration of its own apply and re-locks via an
  `if: always()` step.

  > **Surfaces without a per-solution workflow have no CI unlock window,
  > because they have no CI apply at all.** Purview role groups is the
  > notable case: its Key Vault firewall bracket used to live in the
  > monolithic `deploy-data-plane.yml`, which
  > [ADR 0051](../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md)
  > retired (it never once executed, so that bracket never actually ran).
  > Applying role groups today means running
  > [`scripts/Deploy-PurviewRoleGroups.ps1`](../../scripts/Deploy-PurviewRoleGroups.ps1)
  > **locally**, which is precisely the case this runbook's temporary
  > unlock exists to serve. Backfill of the per-solution workflows is
  > tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).
- The temporary unlock recipe documented in the user-memory note
  `deploy-labels-prune-pitfalls.md` if you are running locally with an
  interactive Az CLI session.

The workflow described here exists for **owner-approved**, **audited**
unlocks where a local recipe is not appropriate (CI demos, recovery
windows, supplier walk-throughs).

## Plan caveat -- `Required reviewers` is gated by GitHub plan

GitHub deployment **protection rules** (the `Required reviewers` and
`Wait timer` settings on a GitHub Environment) are only available on
public repositories or on private repositories with GitHub Pro / Team /
Enterprise. See
<https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#deployment-protection-rules>.

This repository is private on GitHub Free, so the `kv-unlock`
environment **cannot** carry a required-reviewer rule today. The
`environment: kv-unlock` declaration in the workflow remains in place
so the gate activates automatically if the repository is later made
public or the account is upgraded; on Free it is a no-op approval and
the job proceeds without an interactive prompt.

The compensating controls below cover the same threat model for the
single-operator lab:

| Control | Where it lives |
|---|---|
| Only the lab owner has `Actions: write` on this private repo | GitHub repository roles |
| Workflow runs only from `main` | `kv-unlock` environment, `Deployment branches: Selected branches -> main` |
| Workflow file can only be changed via PR | Branch protection on `main` + `CODEOWNERS` pin on `kv-temp-unlock.yml` |
| Duration hard-capped at 30 minutes | `kv-temp-unlock.yml` step `Validate duration and compute hold seconds` |
| Guaranteed re-lock | `if: always()` re-lock step + post-cleanup state assertion |
| OIDC subject scoped to `environment:kv-unlock` | `gh-oidc-purview-kv-unlock` Entra app federated credential |
| RBAC scope for the unlock identity | Custom role `Purview-Lab-KV-Firewall-Toggler` (read + `Microsoft.KeyVault/vaults/write`) at the `kv-contoso-lab-01` vault scope only |
| Audit trail | GitHub Actions run log + Azure Activity Log |

What is **lost** on the Free plan: the interactive MFA / passkey
challenge at the moment of approval. Owner sign-in to GitHub is still
MFA-backed, so an attacker would need to compromise a live owner
session, not just a single point-in-time approval click. If that
threat model is unacceptable, the mitigation is to upgrade to GitHub
Pro (cheapest path) or make the repository public; nothing in the
workflow YAML needs to change.



- You need the vault open from a hosted GitHub runner for a manual
  follow-up task that is not already covered by a deploy workflow.
- You need a fully-audited unlock event in the GitHub Actions log and
  Azure Activity Log -- not just a local terminal session.
- You explicitly want a second pair of eyes (the `kv-unlock` environment
  required-reviewer gate) before the vault opens, even though you are
  the only operator.

## When NOT to use this workflow

- You are running an existing deploy workflow. Those already manage
  their own unlock window inline; piggy-backing on this workflow would
  double-unlock the vault.
- You need to open the vault from your local workstation. Use the
  ad-hoc `az keyvault update` recipe in the user-memory note instead.
  The local path is intentionally not wrapped in this workflow (see PR
  description for #244).
- The required window is longer than 30 minutes. The workflow hard-caps
  `duration_minutes` at 30. If you genuinely need longer, raise an
  issue and reconsider the underlying task; long unlock windows are a
  smell.

## How to dispatch

1. Navigate to **Actions** -> **kv-temp-unlock** in the repository.
2. Click **Run workflow** (on `main`).
3. Fill in:
   - **reason** -- one-line description of what the unlock is for.
     This lands in the run summary and is the only freeform field you
     should treat as your audit trail entry.
   - **duration_minutes** -- integer between 1 and 30. Default is 10.
4. Click **Run workflow**.

On GitHub Pro / Team / Enterprise (or if the repo is public) the
workflow then moves to the `Waiting` state on the `kv-unlock`
environment and posts an approval prompt; approve from the GitHub UI
and the second job proceeds.

On GitHub Free with a private repo (current configuration), the
`kv-unlock` environment has no protection rule so the run proceeds
directly. The compensating controls listed in the "Plan caveat"
section above remain in force.

## What the run does

1. **Job `approval`** -- gated by the `kv-unlock` environment. Records
   the invoker, approver, reason, and requested duration into the run
   summary. No Azure credentials are minted on this job.
2. **Job `unlock`** -- runs under `environment: kv-unlock` so the
   `gh-oidc-purview-kv-unlock` Entra app's OIDC federated credential
   subject (`repo:<owner>/<repo>:environment:kv-unlock`) matches.
   Steps:
   - Validate that `duration_minutes` is in `[1, 30]`.
   - `azure/login@v2` (OIDC, no client secret).
   - **Pre-unlock state guard** -- `az keyvault show` reads the current
     posture and the step fails the job if `publicNetworkAccess` is not
     `Disabled` or `defaultAction` is not `Deny`. This aborts before any
     change is made, so a vault left open by a prior failed run, a
     manual portal change, or a concurrent firewall-toggling workflow
     cannot be silently "opened" and then re-locked, masking drift.
   - `az keyvault update --public-network-access Enabled
     --default-action Allow` to open the firewall, followed by a 10s
     settle window.
   - `sleep` for `duration_minutes * 60` seconds.
   - `if: always()` re-lock to `publicNetworkAccess: Disabled
     --default-action Deny`.
   - Assert the final state matches the locked posture; fail the job
     if it does not.

If the run is cancelled, fails, or times out mid-hold, the `if:
always()` re-lock and assertion still execute. There is no path in this
workflow that leaves the vault open.

## How to verify after the run

The job summary in the Actions UI shows the outcome of every step. As
an independent check:

```pwsh
az keyvault show `
    --name kv-contoso-lab-01 `
    --resource-group rg-purview-lab `
    --query "{pna:properties.publicNetworkAccess,da:properties.networkAcls.defaultAction}" `
    -o tsv
```

Expected output: `Disabled<TAB>Deny`.

If the output is anything else, treat it as a security incident:
re-lock the vault manually with `az keyvault update
--public-network-access Disabled --default-action Deny` and capture
the failed run URL in a follow-up issue.

## Reading the audit trail

- **GitHub side.** The run page lists invoker (`github.actor`),
  approver (under the Environment approval entry), reason, and step
  outcomes.
- **Azure side.** Filter the Activity Log on
  `rg-purview-lab` -> `Microsoft.KeyVault/vaults/write` to see the
  two firewall changes (open and re-lock). Each event names the
  service principal that issued the change (the `gh-oidc-purview-kv-unlock`
  Entra app).

### Diagnostic logs (Log Analytics)

The vault streams `AuditEvent`, `AzurePolicyEvaluationDetails`, and
`AllMetrics` to the `log-contoso-lab` Log Analytics workspace via the
`Microsoft.Insights/diagnosticSettings` resource declared in
[`infra/modules/keyvault.bicep`](../../infra/modules/keyvault.bicep).
[Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)
describes what each category records.

To review what happened inside the most recent unlock window, set
`startTime` and `endTime` to the workflow run's start and end timestamps
from the Actions UI (UTC), then run the following query against the
`log-contoso-lab` workspace ([Tutorial: Get started with Kusto
queries](https://learn.microsoft.com/en-us/azure/data-explorer/kusto/query/tutorials/learn-common-operators)):

```kusto
let startTime = datetime(2026-05-15T18:00:00Z);
let endTime   = datetime(2026-05-15T18:30:00Z);
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where Resource =~ "kv-contoso-lab-01"
| where TimeGenerated between (startTime .. endTime)
| project TimeGenerated, OperationName, ResultType, CallerIPAddress,
          identity_claim_appid_g, identity_claim_oid_g,
          requestUri_s
| order by TimeGenerated asc
```

The `identity_claim_appid_g` column is the Entra app (client) ID that
issued the call; cross-reference it with the workflow's federated
credential subject to confirm the call came from the expected identity.

## Identity scope

The `unlock` job runs under a purpose-specific Microsoft Entra ID
application, **not** the control-plane Entra app used elsewhere in this
repo. The identity exists for one reason: to toggle
`publicNetworkAccess` on `kv-contoso-lab-01`. Nothing else.

| Element | Value | Provisioned by |
|---|---|---|
| Entra app display name | `gh-oidc-purview-kv-unlock` | [`scripts/New-KvUnlockEntraApp.ps1`](../../scripts/New-KvUnlockEntraApp.ps1) |
| Federated credential subject | `repo:contoso/Purview-as-Code-Generic:environment:kv-unlock` | [`scripts/New-KvUnlockEntraApp.ps1`](../../scripts/New-KvUnlockEntraApp.ps1) |
| GitHub repo secret | `AZURE_CLIENT_ID_KV_UNLOCK` (stores the app's `appId`) | Operator (manual, one-time) |
| Custom RBAC role | `Purview-Lab-KV-Firewall-Toggler` (actions: `Microsoft.KeyVault/vaults/read`, `Microsoft.KeyVault/vaults/write`) | [`infra/modules/role-definitions.bicep`](../../infra/modules/role-definitions.bicep) (D1) |
| Role assignment | [`infra/modules/kv-unlock-rbac.bicep`](../../infra/modules/kv-unlock-rbac.bicep) scoped to `/subscriptions/<sub>/resourceGroups/rg-purview-lab/providers/Microsoft.KeyVault/vaults/kv-contoso-lab-01` | [`scripts/New-KvUnlockRbac.ps1`](../../scripts/New-KvUnlockRbac.ps1) |

This follows the least-privilege guidance in [Azure custom
roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles):
the role enumerates exactly the operations needed to flip the firewall,
and the assignment is scoped to the single vault. The unlock identity
cannot list secrets, cannot read keys, cannot modify any other Key
Vault, and cannot touch any non-Key-Vault resource in the subscription.
If an attacker compromised the GitHub OIDC token exchange path, the
blast radius is bounded to flipping one boolean on one vault.

To verify the assignment at any time:

```pwsh
az role assignment list `
    --assignee-object-id <kv-unlock-sp-object-id> `
    --assignee-principal-type ServicePrincipal `
    --scope /subscriptions/<sub>/resourceGroups/rg-purview-lab/providers/Microsoft.KeyVault/vaults/kv-contoso-lab-01 `
    --query "[].{role:roleDefinitionName,scope:scope}" -o table
```

Expected output: exactly one row, `Purview-Lab-KV-Firewall-Toggler` at
the vault scope. Anything more is drift; anything less and the
workflow will fail at the `Pre-unlock state guard` step with an
`AuthorizationFailed` error.

## References

- GitHub Environment required reviewers:
  <https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#required-reviewers>
- Azure Login with OpenID Connect:
  <https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect>
- Key Vault network security:
  <https://learn.microsoft.com/en-us/azure/key-vault/general/network-security>
- `az keyvault update`:
  <https://learn.microsoft.com/en-us/cli/azure/keyvault#az-keyvault-update>
- Azure custom RBAC roles:
  <https://learn.microsoft.com/en-us/azure/role-based-access-control/custom-roles>
