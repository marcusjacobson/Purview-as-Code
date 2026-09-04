# Insider Risk Management — policies

Operational guide for [`scripts/Deploy-IRMPolicies.ps1`](../../../scripts/Deploy-IRMPolicies.ps1) — the reconciler that materializes [`data-plane/irm/policies.yaml`](../../../data-plane/irm/policies.yaml) against the [Microsoft Purview Insider Risk Management](https://learn.microsoft.com/en-us/purview/insider-risk-management) surface. Pairs with [`audit-log.md`](audit-log.md) (the tenant-scope ingestion source IRM depends on).

## Purpose

Reconciles the [`Get/New/Set/Remove-InsiderRiskPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskpolicy) cmdlet family against a declared list of IRM policy entries. Emits Create / Update / NoChange / Orphan / Skipped / Blocked / Failed decisions per policy. `Blocked` is a difference the service cannot satisfy in place — today that means `InsiderRiskScenario`, which is set-once on `New-InsiderRiskPolicy`, so no direction policy can ever apply it. Orphan policies (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline.

The IRM model is documented at [Insider Risk Management overview](https://learn.microsoft.com/en-us/purview/insider-risk-management):

- Each policy carries a `Name` (string), `InsiderRiskScenario` (template enum), and optional `Comment` and `Enabled` flag.
- `Priority` is a read-only field on `Get-InsiderRiskPolicy` — neither `New-` nor `Set-InsiderRiskPolicy` accept a `-Priority` parameter (verified in issue #267), so the reconciler does not track it.
- The Microsoft service synthesises one per-tenant `IRM_Tenant_Setting_<guid>` policy of scenario `TenantSetting` to back the global IRM configuration. Microsoft Learn documents no path to delete or scope-out this entry; [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) ratifies it as a permanent declared orphan.

## Default state

Both operator branches ship a **populated** desired state: `lab` tracks 6 policies, `dev` tracks 7 (lab's set plus one dev-only policy). Issue [#177](../../../../../issues/177) codified the four operator-authored `IRM Lab — *` policies and two live `DSPM for AI - *` policies that no automation had ever recorded, so a reconcile run now reports `NoChange` for them rather than `Orphan` or `Skipped`.

Two consequences worth knowing before reading the rest of this page:

- **The ADR 0036 skip baseline is functionally inert for plan behaviour.** A codified policy reads `NoChange` whether or not `-SkipNames` names it. The baseline still exists in both workflows' input defaults and is still byte-locked between them; retiring it is an [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) decision nobody has taken, and [`scripts/Invoke-IRMSmokeTest.ps1`](../../../scripts/Invoke-IRMSmokeTest.ps1) still asserts `Skipped` rows that exist only because `-SkipNames` forces them.
- **The public template still ships this file empty** (`policies: []`) per [ADR 0056](../../adr/0056-template-ships-empty-desired-state.md). The populated state is operator-branch only, and the two branches differ from each other on purpose — a promotion must never carry one branch's `policies.yaml` across to the other.

## Authentication

Same Key Vault-side JWT signing path as every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate''s underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/irm/policies.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant policies. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-SkipSchemaValidation` | switch — bypass the JSON Schema gate (emergency only) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `Get-InsiderRiskPolicy`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No writes under any circumstance.** Skip-baseline bypass intentional — see live tenant raw vs YAML. |
| `-WhatIf` (default `portal-wins`) | Reads `Get-InsiderRiskPolicy`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Skipped rows. No writes. |
| (default) | Same read, then per-row `New-`, `Set-`, or `Remove-InsiderRiskPolicy` for Create / Update / (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_irm='overwrite portal'` token. |

## Schema

YAML conforms to [`data-plane/irm/policies.schema.json`](../../../data-plane/irm/policies.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Insider Risk Management` (or `Compliance Administrator`) | Tenant |
| Caller''s identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow''s `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network).

## Smoke test

```pwsh
# Audit mode — read-only view of the raw live tenant vs YAML.
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy audit
```

Expected output tail on a converged tenant. Every tracked policy reads `NoChange`, the four `IRM Lab — *` names included — they are codified now, so they are no longer tenant-only:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
Category Name                                                    Reason
-------- ----                                                    ------
NoChange DSPM for AI - Detect risky AI usage                     In sync with YAML.
NoChange DSPM for AI - Detect when users visit AI sites          In sync with YAML.
NoChange IRM Lab — Data leaks by priority users                  In sync with YAML.
NoChange IRM Lab — Data theft by departing users                 In sync with YAML.
NoChange IRM Lab — General data leaks                            In sync with YAML.
NoChange IRM Lab — Risky AI usage                                In sync with YAML.
NoChange IRM_Tenant_Setting_<guid>                               System-managed tenant policy; not reconciled by this script.
```

For the noise-free `portal-wins` view (matches what CI runs):

```pwsh
./scripts/Deploy-IRMPolicies.ps1 -WhatIf -DirectionPolicy portal-wins `
  -SkipNames @(
    'IRM Lab — Data leaks by priority users',
    'IRM Lab — Data theft by departing users',
    'IRM Lab — General data leaks',
    'IRM Lab — Risky AI usage')
```

Expected: 4 `Skipped` rows, plus one `NoChange` row for every other
tracked policy and one for the system-managed
`IRM_Tenant_Setting_<guid>` (classified by the reconciler's name-prefix
wildcard, not by `-SkipNames`). Note what this now demonstrates: because
those four names are codified, `-SkipNames` is **overriding a
`NoChange`** rather than suppressing an `Orphan`.

For an end-to-end live-tenant smoke (Create → Get → Plan-shape assert → Delete → Get-gone) against a throwaway `e2e-irm-smoke-*` policy, follow [`docs/runbooks/irm-end-to-end-smoke.md`](../../runbooks/irm-end-to-end-smoke.md). **The wrapper below is stale and currently reaches neither tenant** — it hard-codes `lab.yaml`, authenticates only through Key Vault (so it cannot reach the governance-locked lab tenant at all), and asserts a plan shape that predates the codified desired state. Rebuild tracked as [#192](../../../../../issues/192):

```pwsh
./scripts/Invoke-IRMSmokeTest.ps1
```

## CI wiring

[`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml) is the **only**
forward apply path. A monolithic step once existed but never executed;
see [The retired monolithic step](#the-retired-monolithic-step) below.

Reverse drift has **three** producers, and telling them apart matters
when reviewing a pull request that edits `policies.yaml`:

| Producer | Trigger | Opens | Branch |
|---|---|---|---|
| [`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml) two-pass apply | push or dispatch, `portal-wins`, when the apply skipped something | a drift-back **pull request** | `auto/irm-portal-wins-drift-<env>` |
| [`scripts/Invoke-LocalIrmDriftSync.ps1`](../../../scripts/Invoke-LocalIrmDriftSync.ps1) | operator, interactively | a drift-back **pull request** | `auto/irm-drift-sync-<env>` |
| [`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml) | daily schedule or dispatch | a drift-detection **issue** | none |

The three never share a branch. The local tool exists because a
governance-locked tenant (lab, under
[ADR 0060](../../adr/0060-governance-locked-kv-local-cert-apply.md)) has no
CI path to its own tenant at all: the scheduled sync no-ops at the ADR 0060
gate, and `deploy-irm.yml` carries no such gate so it runs and dies at the
first Key Vault read — which also means its drift-back job, gated on a
successful apply, can never fire there.

### Isolated forward workflow — `deploy-irm.yml` (preferred)

[`.github/workflows/deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
runs the reconciler on its own — one `apply` job, one idempotent apply
pass — so IRM can be applied in isolation without re-touching (and
red-lighting) every other data-plane surface the monolith runs in the same
job. It is the **forward twin** of the reverse companion
[`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml)
and mirrors the [`deploy-dlp.yml`](../../../.github/workflows/deploy-dlp.yml)
precedent. Triggers on `workflow_dispatch` plus `push` to `main`, `dev`
and `lab` under `data-plane/irm/policies.yaml`,
`data-plane/irm/policies.schema.json`, `scripts/Deploy-IRMPolicies.ps1`,
`scripts/Get-PurviewIPPSAccessToken.ps1`,
`scripts/modules/DirectionPolicy.psm1`, `infra/parameters/*.yaml`, and the
workflow file itself. **Four** `workflow_dispatch` inputs thread the
ADR 0029 and ADR 0057 contracts:

- `environment` — `lab` (default) / `dev`. Push and schedule runs map
  branch `dev` — `dev` and every other branch — `lab`
  ([ADR 0057](../../adr/0057-multi-environment-and-branch-model.md)). On a
  dispatch the declared default wins over that branch fallback, so
  **`-f environment=dev` is mandatory** when targeting dev; `--ref dev`
  alone binds the **lab** environment. The `dev` GitHub Environment also
  rejects a dispatch from any ref but `dev`.
- `irm_direction_policy` — `audit` / `portal-wins` (default) / `repo-wins`.
- `confirm_overwrite_irm` — typed `overwrite portal` token, gates `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md).
- `skip_names_irm` — comma list passed through to `-SkipNames`; defaults to the 4-name [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) baseline. This default is byte-matched against [`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml) — a **two-way** lockstep. It was a three-way lockstep until [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) retired the monolithic `deploy-data-plane.yml`, whose copy was the third leg (and was dead code that never once ran).

A fail-fast `Validate dispatch inputs` step runs before Azure login and
rejects a `repo-wins` dispatch without the typed token. Workflow-scope
`permissions: {}`; the `apply` job holds only `id-token: write` +
`contents: read`, and the separate `drift-back-pr` job holds
`contents: write` + `pull-requests: write` and no Azure credentials at all.

The workflow runs **two passes** under `portal-wins`:

1. **Enumerate** — the reconciler runs read-only and its
   `[ADR0029-SKIP] <name>` markers are parsed into a drift-derived skip
   list. This pass deliberately runs **without** `-SkipNames`: the same
   marker is emitted for a static ADR 0036 baseline name and for real
   drift, so folding the baseline in would make every run look like drift.
2. **Apply** — the baseline and the drift-derived set are unioned and
   passed as `-SkipNames`. Only the enumerate pass feeds `skip_count`.

When the apply skipped something, a re-export runs and the `drift-back-pr`
job opens a pull request on `auto/irm-portal-wins-drift-<env>`. **Review it
before merging.** If the YAML side was the intended one, close the PR and
reconcile the tenant instead — merging a drift-back PR whose YAML was
already correct is what went wrong on the sibling DLP surface in #170 and
#172.

One consequence is easy to misread as a bug: **under `portal-wins`,
`Resolve-DirectionPolicyAction` converts every `Update` row to `Skipped`**.
A merge-triggered run can therefore prove a `Create` but can never prove an
`Update`. The only CI path that calls `Set-InsiderRiskPolicy` is a
`repo-wins` dispatch with the typed token.

```bash
# lab (the input default) -- note the branch/ref pairing
gh workflow run deploy-irm.yml --ref lab -f environment=lab

# dev -- `-f environment=dev` is MANDATORY; `--ref dev` alone binds lab
gh workflow run deploy-irm.yml --ref dev -f environment=dev

# repo-wins: the only CI path that performs an Update
gh workflow run deploy-irm.yml --ref dev -f environment=dev \
  -f irm_direction_policy=repo-wins -f "confirm_overwrite_irm=overwrite portal"
```

### The retired monolithic step

[`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml) is the **only**
forward-apply path for IRM policies. The monolithic `deploy-data-plane.yml`,
which once carried a `Deploy IRM policies` step threading the same three
ADR 0029 inputs (it had no `environment` input; ADR 0057's branch model
postdates it), was retired by
[ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md):
it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap, so
it failed at startup and **never once executed** (90 runs, 0 successes, 0 jobs
scheduled). There is no "apply the whole data plane together" entry point, and a
`deploy-all.yml` orchestrator is explicitly deferred as greenfield
`workflow_call` work.

This surface is in fact ADR 0051's own Evidence 3: `deploy-irm.yml` exists
*because* a single-job monolith cannot apply one surface in isolation and goes
red on surfaces whose prerequisites are absent, destroying the forward-apply
evidence for the surface you actually wanted.

## Reverse drift-detection (issue, not PR — by choice)

The forward apply leg above is paired with a reverse companion,
[`.github/workflows/sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml),
that watches for portal-only edits to the IRM policy surface. It runs
daily (08:00 UTC) plus on demand.

`Deploy-IRMPolicies.ps1` **does** expose `-ExportCurrentState`, so a
re-export pull request is technically possible here. This leg opens a
GitHub **issue** anyway, deliberately, because it is not the only producer
on this surface: the two above are each caused by a human who is present,
while this one fires unattended on a daily cron. A third producer racing
the other two for the same file, with nobody watching, buys no coverage
they lack. The workflow declares `permissions: issues: write` and no
`pull-requests` scope.

One asymmetry any future conversion would have to handle: this job
post-filters the ADR 0036 baseline out of its drift rows, whereas the
exporter captures every tenant policy except `IRM_Tenant_Setting_*`. An
export-and-diff would need to re-apply that filter to the exported YAML
before diffing, or it would propose changes this job deliberately ignores.

How it detects drift, without the pitfalls of the retired generic
`drift-detection.yml`:

- **Audit mode, always.** The reconciler is invoked with
  `-DirectionPolicy audit`, which forces `$WhatIfPreference` so every
  `New-`/`Set-`/`Remove-InsiderRiskPolicy` short-circuits to its
  "Would …" branch. No write fires ([ADR 0029](../../adr/0029-source-of-truth-direction-policy.md)).
  It does **not** use `portal-wins -WhatIf`, which would mask an
  `Update` as a `Skip`.
- **Object-based, not text-scraped.** It captures the reconciler's
  returned `[pscustomobject]` rows from the success stream (stream 1)
  and filters on `.Category` / `.Name` / `.Reason`. Drift is any row
  whose `Category` is `Create`, `Update`, `Orphan`, `Failed`, or
  `Blocked`. It never greps stdout/stderr and never relies on `2>&1`.
- **Skip baseline is a post-filter.** `-SkipNames` is inert in audit
  mode (the audit short-circuit runs before the ADR 0029 skip pass),
  so the workflow does **not** pass `-SkipNames`. It removes the
  [ADR 0036](../../adr/0036-irm-tenant-setting-immovable.md) baseline
  names from the returned rows after the fact. The `skip_names_irm`
  input default mirrors the [`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
  default verbatim — the surviving two-way byte-lockstep.
- **Self-provisioned labels.** `gh issue create --label <name>` fails
  the whole call if a referenced label is missing (a fresh fork lacks
  `drift-detected`), so the issue step reads the existing label set and
  creates only the missing labels before creating the issue. The issue
  carries `drift-detected`, `needs-review`, and
  `squad:automation-engineer`.
- **Idempotent.** If an open IRM drift issue already exists, the run
  adds a refresh comment instead of opening a duplicate.
- **Known gap: the open-issue search carries no environment filter.** The
  issue title names the environment, but the search does not, so an open
  **lab** drift issue would absorb **dev**'s drift as a comment on it
  rather than opening its own. Check for an open issue on the other
  environment before trusting a quiet run. The refresh comment also says
  "scheduled" even on a manual dispatch.

```bash
gh workflow run sync-irm-from-tenant.yml --ref dev -f environment=dev
```

A `fanout-dev` job re-dispatches this workflow against `dev` after each
scheduled run, because a `schedule` trigger fires only on the default
branch (`lab`). It carries no `needs:` on the detect job, so it fans out
even when lab's own detect step no-ops at the ADR 0060 gate. The shared
`vars.DEV_SCHEDULED_SYNC_ENABLED` repository variable pauses the dev leg
without touching lab's schedule.

## Related ADRs and runbooks

- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0036 — IRM tenant-setting immovable](../../adr/0036-irm-tenant-setting-immovable.md)
- [Runbook — IRM end-to-end smoke](../../runbooks/irm-end-to-end-smoke.md)
- [Runbook — Local IRM drift sync](../../runbooks/irm-local-drift-sync.md)
- [Runbook — IRM end-to-end synchronisation test](../../runbooks/irm-sync-loop-e2e.md)
- Forward companion workflow (preferred): [`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)
- Reverse companion workflow: [`sync-irm-from-tenant.yml`](../../../.github/workflows/sync-irm-from-tenant.yml)
- Sibling solution: [`records-management.md`](records-management.md)

## Follow-ups

- [#196](../../../../../issues/196) — **open bug.** `New-InsiderRiskPolicy` ignores `-Enabled:$false`, so a
  policy codified as `enabled: false` is created **enabled**; `Set-` honours the flag. Reproduced on both
  tenants, so it is cmdlet-level. Until it is fixed, do not assume a codified `enabled: false` is in effect
  without reading the tenant back.
- [#192](../../../../../issues/192) — rebuild `Invoke-IRMSmokeTest.ps1` (stale; see the Smoke test section).
  This also gates retiring the ADR 0036 skip baseline, which the wrapper is the last thing depending on.
- [#605](../../../../../issues/605) — Author lab IRM policy in YAML (post-#603 decision)
- [#604](../../../../../issues/604) — **satisfied** by [#177](../../../../../issues/177): the four
  `IRM Lab — *` policies were adopted into desired state on both branches.
- [#606](../../../../../issues/606) — **superseded** by
  [ADR 0064](../../adr/0064-irm-entity-lists-are-microsoft-managed.md): the entity-list surface is
  Microsoft-managed tenant configuration, `Deploy-IRMEntityLists.ps1` is parked, and
  `data-plane/irm/entity-lists.yaml` stays empty permanently.