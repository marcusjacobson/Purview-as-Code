# Runbook: Local IRM drift sync (ADR 0060 local equivalent)

Use this runbook when you need to capture a manual Microsoft Purview portal
edit on the Insider Risk Management (IRM) policy surface into
`data-plane/irm/policies.yaml`, and CI cannot reach the tenant because of a
Key Vault governance lock. See
[ADR 0060](../adr/0060-governance-locked-kv-local-cert-apply.md) for the
gate's design rationale and
[ADR 0028](../adr/0028-co-equal-local-cert-credential.md) for the
local-certificate transport this runbook relies on.

> [!IMPORTANT]
> `scripts/Invoke-LocalIrmDriftSync.ps1` is exclusively for interactive
> runs from the lab owner's workstation. It never runs in CI.

## Two producers write to this surface, and this script is a third

Read this before reviewing any PR the script opens.

| Producer | Trigger | What it opens | Branch |
|---|---|---|---|
| `deploy-irm.yml` | push or dispatch, `portal-wins`, when the apply pass skipped something | a drift-back **pull request** carrying the re-export | `auto/irm-portal-wins-drift-<env>` |
| `sync-irm-from-tenant.yml` | daily schedule (08:00 UTC) or dispatch | a drift-detection **issue**, never a PR | none |
| This script | operator, interactively | a drift-back **pull request** | `auto/irm-drift-sync-<env>` |

The three never share a branch. The forward workflow re-exports as a side
effect of applying; this script exists because on a governance-locked
tenant that workflow cannot run at all, and because the reverse workflow
deliberately stops at an issue rather than proposing YAML.

## When to use this runbook

- Lab's daily `sync-irm-from-tenant.yml` schedule reports its `sync` job as
  **skipped**, not failed — the ADR 0060 gate
  (`vars.CI_DATA_PLANE_ENABLED = 'false'`) is doing exactly what it is
  supposed to, and this runbook is the intended local fallback. Lab has
  been in that state since 2026-08-16.
- `deploy-irm.yml` failed on lab at the Key Vault step. That workflow
  carries **no** ADR 0060 gate, so a qualifying push still runs it and it
  still dies at the first certificate read. Its drift-back PR job cannot
  fire from a failed apply, so nothing reaches the repo that way either.
- You made (or suspect someone made) a manual IRM policy edit in the
  Purview portal and want to confirm whether the repo has drifted, without
  waiting for the next owner-supervised reconcile.
- You want a read-only tenant audit (`-AuditOnly`). Use it in particular to
  see any `Blocked` row: that reports an immutable `scenario` difference,
  which no export and no apply can resolve — the tenant policy has to be
  deleted and recreated, because `InsiderRiskScenario` is set-once on
  `New-InsiderRiskPolicy`.

Unlike the DLP equivalent there is no standing reason to prefer
`-AuditOnly` over a real export on this surface. The exporter skips the
system-managed `IRM_Tenant_Setting_*` policies (ADR 0036), and the four
`IRM Lab — *` names that ADR 0036 kept out of the tracked YAML have been
codified since #187, so a round-trip no longer silently loses anything.

## When NOT to use this runbook

- You are running CI. `sync-irm-from-tenant.yml` and `deploy-irm.yml` are
  the CI paths; this script has no workflow equivalent and is not called
  from any workflow.
- You want to **apply** a repo change to the tenant (create, update, or
  remove a policy). That is `scripts/Deploy-IRMPolicies.ps1` directly
  (`-DirectionPolicy repo-wins`), not this script — this script only ever
  reads the tenant and, if it finds drift, opens a PR for a human to
  review before anything is applied back.
- Key Vault is reachable from CI for this tenant, as it is for dev. Use the
  scheduled workflow or a `workflow_dispatch` run instead; this script
  exists specifically for the governance-locked case.

## Prerequisites

1. A provisioned local certificate for the target tenant (see
   [`local-cert-provisioning.md`](local-cert-provisioning.md)).
2. `az login` against the target tenant's subscription, matching the
   environment you intend to sync
   (`az account set --subscription <name>`).
3. `gh auth status` showing an authenticated session with write access
   to this repository (the script opens/updates PRs via `gh api`).
4. PowerShell modules `powershell-yaml` and `ExchangeOnlineManagement`
   installed (same prerequisites as `Deploy-IRMPolicies.ps1`).

## Selecting the environment (dev or lab)

Nothing in the repo selects the tenant for you — there is no
`-Environment` switch. Three operator-set values have to agree, and the
script's guards (below) refuse to run when they do not:

| Value | lab | dev |
|---|---|---|
| `az account set --subscription` | `"marcusj-lab.cloud"` | `"Visual Studio Enterprise Subscription"` |
| `$env:PURVIEW_PARAMETERS_FILE` | `infra/parameters/lab.yaml` | `infra/parameters/dev.yaml` |
| `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` | thumbprint registered on **lab's** data-plane app | thumbprint registered on **dev's** data-plane app |
| Base branch (ADR 0057) | `lab` (or any non-`dev` checkout) | `dev` checkout, or `-BaseBranch dev` |

Notes that save a re-derivation:

- **`az account show` decides the tenant, not `-ParametersFile`.** Every
  `Deploy-*.ps1` authenticates against whatever `az` currently points at
  and only reads the parameters file for names. Both subscriptions are
  normally already in the local `az` cache, so switching is
  `az account set` (by subscription **name** — setting by tenant GUID
  fails), not a fresh `az login`; `az login --tenant <domain>` is needed
  only after the cached token has expired.
- **The thumbprint is per-machine, not per-tenant** (ADR 0028 §9): the
  local cert's subject CN is scoped to app display name + user + machine,
  and both parameters files use the same
  `automation.apps.dataPlane.displayName`, so one workstation typically
  has ONE cert whose public key is registered as a keyCredential on
  *each* tenant's app. Registration is per tenant even when the thumbprint
  is the same — run
  `./scripts/New-LocalAutomationCertificate.ps1 -ParametersFile infra/parameters/dev.yaml`
  once for dev (that script defaults to `lab.yaml` and does **not** read
  `PURVIEW_PARAMETERS_FILE`). The env var does not persist between shells;
  set it every session.
- **The two tenants hold different desired state, deliberately.** `lab`
  tracks 6 policies and `dev` tracks 7 (lab's set plus one dev-only
  policy). A sync run against the wrong branch would propose deleting the
  difference; the branch/environment guard is what stops it.
- **Restore the default context when you are done** —
  `az account set --subscription "marcusj-lab.cloud"`. A stale `dev`
  context in the next session is the #41 trap in the other direction.

The blocks below are written for lab; for dev substitute the three dev
values from the table and run from a `dev` checkout (or add
`-BaseBranch dev`).

## Read-only audit (always safe)

```powershell
az account set --subscription "marcusj-lab.cloud"
$env:PURVIEW_LOCAL_CERT_THUMBPRINT = '<lab cert thumbprint>'
$env:PURVIEW_PARAMETERS_FILE       = 'infra/parameters/lab.yaml'

./scripts/Invoke-LocalIrmDriftSync.ps1 -AuditOnly -WhatIf
```

This runs `Deploy-IRMPolicies.ps1 -DirectionPolicy audit -WhatIf` against
an isolated git worktree checked out from `origin/<branch>` (your own
working-tree checkout is never touched), prints the plan, and writes a
JSON audit record to `.copilot-tracking/audit/irm-<environment>.json`
(gitignored) that the operations console's tenant-audit panel reads.
Nothing is committed, pushed, or opened as a PR — `-AuditOnly` never
reaches that code path regardless of `-WhatIf`.

Expect one `NoChange` row per tracked policy plus one for the tenant's
system-managed `IRM_Tenant_Setting_*` policy, which is reported rather
than reconciled. The audit record's counts show `desiredPolicies` and
`tenantPolicies` only; this surface has no rules, so the console's
`Rules:` line reads as not applicable.

## Full drift sync (opens a PR on meaningful drift)

```powershell
az account set --subscription "marcusj-lab.cloud"
$env:PURVIEW_LOCAL_CERT_THUMBPRINT = '<lab cert thumbprint>'
$env:PURVIEW_PARAMETERS_FILE       = 'infra/parameters/lab.yaml'

./scripts/Invoke-LocalIrmDriftSync.ps1
```

This exports the live tenant's IRM policies into the worktree's copy of
`data-plane/irm/policies.yaml`, classifies the diff via
`scripts/modules/ExportDiffFilter.psm1` (the same cosmetic-only filter the
sibling sync workflows use), and — only if the diff is meaningful —
commits to `auto/irm-drift-sync-<environment>`, pushes, and opens or
updates a PR. Run `-WhatIf` first to preview without committing/pushing.

The PR's title, labels and review checklist are owned by this script, not
copied from a workflow: `sync-irm-from-tenant.yml` opens an issue rather
than a PR, so there is no CI shape to match. `tests/scripts/Invoke-LocalIrmDriftSync.Tests.ps1`
pins them instead.

## Guards this script enforces automatically

- **Tenant-match guard (the "#41 incident").** The script resolves the
  current `az account show` tenant ID against the ARM tenants list and
  refuses to proceed unless it matches the parameters file's
  `automation.tenantDomain`. A stale `az` context silently hitting the
  wrong tenant is exactly what burned PR #41.
- **Branch/environment guard (ADR 0057).** The target branch must map to
  the parameters file's declared environment (`dev` -> `dev`, everything
  else -> `lab`). Pass `-BaseBranch` explicitly if you need to sync a
  branch other than your current checkout.
- **Local-cert requirement.** The script refuses to run if
  `$env:PURVIEW_LOCAL_CERT_THUMBPRINT` is unset — it never falls back to
  the Key Vault transport, since that is precisely the path this runbook
  exists to avoid.

## After the PR opens

Work the checklist in the PR body. Three items are specific to this
surface and cannot be judged from the diff alone:

- **No `IRM_Tenant_Setting_*` row may appear.** Those policies are
  system-managed (ADR 0036) and the exporter excludes them, so one showing
  up means the export path changed, not that the tenant did.
- **Identifiers have to be caught by eye.** The ADR 0055 residue scan is
  GUID-shaped only, so a UPN, group name, or site URL in a policy name or
  description passes it silently.
- **No `scenario` value may change.** A scenario difference can never be
  applied; it reports `Blocked` on every subsequent run until the tenant
  policy is deleted and recreated.

If the YAML side was the intended one all along, **close the PR** rather
than merging it, and reconcile the tenant instead — merging a drift-back
PR whose YAML was already correct is what went wrong in #170 and #172 on
the sibling surface. On dev, merging fires `deploy-irm.yml`'s push
trigger as normal; on a governance-locked tenant that run will fail at Key
Vault, and the tenant is already in the merged state anyway.

## See also

- [`docs/solutions/governance-foundation/insider-risk-management.md`](../solutions/governance-foundation/insider-risk-management.md)
  — the general IRM-as-code workflow.
- [`local-cert-provisioning.md`](local-cert-provisioning.md) — cert setup.
- [`irm-end-to-end-smoke.md`](irm-end-to-end-smoke.md) — the manual
  lifecycle smoke test for this surface.
- [`dlp-local-drift-sync.md`](dlp-local-drift-sync.md) — the sibling
  surface's equivalent, whose script this one was cloned from.
