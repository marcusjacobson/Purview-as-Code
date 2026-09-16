# Runbook: IRM end-to-end synchronisation test

This runbook proves that every synchronisation direction on the Insider
Risk Management (IRM) policy surface actually works, against live tenants,
and leaves both tenants and both branches exactly as it found them.

It is not the lifecycle smoke test. [`irm-end-to-end-smoke.md`](irm-end-to-end-smoke.md)
proves the *cmdlets* work on one tenant. This runbook proves the *plumbing
between the tenant and the repo* works, in both directions, on both
tenants, and that a `dev` → `lab` promotion preserves the fact that the
two tenants hold deliberately different desired state.

Run it after any change to `Deploy-IRMPolicies.ps1`, `deploy-irm.yml`,
`sync-irm-from-tenant.yml`, or `Invoke-LocalIrmDriftSync.ps1`.

**Run history.**

- **Run 1** — issue [#190](../../../../issues/190). Found
  [#194](../../../../issues/194) (export not order-stable) and
  [#196](../../../../issues/196) (create ignores `enabled: false`), plus the
  unscoped drift-issue search fixed as #207.
- **Run 2** — issue [#214](../../../../issues/214). **All four fixes confirmed
  live**, both tenants back to baseline, net-zero. #196 **still reproduces at
  the cmdlet level on both tenants** — Microsoft has not fixed
  `New-InsiderRiskPolicy`; what changed is that the reconciler now detects it
  and converges with a follow-up `Set-`. Three drift-back PRs were exercised
  with three *different* correct dispositions (close / merge / close), which is
  the point of Legs F, C1 and C2. Found three new defects, none of them IRM:
  [#215](../../../../issues/215) (the `az`-context trap below),
  [#224](../../../../issues/224) and [#225](../../../../issues/225).
- **Run 5** — issue [#273](../../../../issues/273), 2026-09-08. **The cron
  run.** Leg E uncompressed for the first time since run 2, and the first run
  to close every schedule-only item: **#245** and **#167** observed on all five
  scheduled surfaces, and **#207 proved through the real cron path** — the dev
  run that had to pass the decoy test was started by lab's 08:00 UTC schedule
  via `fanout-dev`, not by hand. **#224 proved live three ways**, the strongest
  being that `sync-label-policies-from-tenant` had failed against dev on three
  consecutive days at the exact `Test-ExportDiffMeaningful` line and succeeded
  here for the first time ever. That success immediately exposed
  [#299](../../../../issues/299) — the label-policies exporter emits Purview's
  slug `Name` instead of `displayName`, so every scheduled dev run now opens a
  drift-back PR that would corrupt the file if merged. Legs 0-D and G/H green;
  no IRM defect found.
- **Run 4** — issue [#277](../../../../issues/277), 2026-09-08. Cron-free.
  First live exercise of [#274](../../../../issues/274)'s pre-pull-request
  export validation. **Not clean**: Leg F was blocked outright by
  [#279](../../../../issues/279) — `--force-with-lease` reads the
  remote-tracking ref, and *this runbook's own Leg F* deletes that branch, so
  run N+1 on the same workstation dies with `stale info` **after** the tenant
  read and the commit. Fixed inside the run; run 5's Leg F then hit the same
  condition naturally and sailed through.
- **Run 3** — issue [#255](../../../../issues/255), 2026-09-07. Run against a
  path on which **every file had been rewritten that same day** by the fixes
  for #215, #224, #225 and #231. Green on every leg; both tenants and both
  branches net-zero. #196 **still reproduces on both tenants** for the third
  run running. Found and fixed [#258](../../../../issues/258) (both local
  drift-sync scripts recorded `desiredPolicies: null` on every sync run, which
  the operations console renders as `Desired: —` on exactly the records written
  when a surface has drifted), and corrected #38's diagnosis. **Leg E was
  compressed to dev dispatches by owner decision**, so the cron fan-out (#167)
  and #245's skip announcement were *not* exercised — see the trap on #245
  below for why a dispatch cannot reach them.

## What this proves, and what only a live run can prove

Static tests already pin the shape of every workflow and script involved.
What they cannot pin is behaviour that only exists when a real tenant, a
real GitHub Environment, and a real reviewer decision are in play:

- that a portal edit actually produces a `[ADR0029-SKIP]` marker, that the
  marker actually reaches the apply pass, and that the re-export actually
  differs by exactly the edited field;
- that the drift-back pull request is openable, mergeable, and closeable,
  and that the *next* run reports zero skips after a merge;
- that the `repo-wins` dispatch is reachable at all — its typed
  confirmation token has never been exercised in CI;
- that the scheduled leg's fan-out reaches `dev` and opens an issue there;
- that a governance-locked tenant can still be reconciled locally.

## The one behaviour that surprises everyone

**Under `portal-wins`, an `Update` row is always converted to `Skipped`.**
`Resolve-DirectionPolicyAction` does this by design: the portal wins, so
the repo does not write. A merge-triggered CI run can therefore prove
`Create`, but it can **never** prove `Update` — the only CI path that
calls `Set-InsiderRiskPolicy` is a `repo-wins` dispatch with the typed
token. Leg C2 exists for exactly that reason. If you find yourself
wondering why an obvious YAML edit did not apply, this is why.

## Preconditions

| Item | Check |
|---|---|
| Both tenants reachable | `az account show` switches cleanly between both subscriptions; a local certificate is registered on **each** tenant's data-plane app (ADR 0028, [`local-cert-provisioning.md`](local-cert-provisioning.md)). |
| Clean board | No open pull request touching `data-plane/irm/**`; no `auto/irm-*` branch on the remote. |
| No open drift issue | `gh issue list --state open --search 'IRM policy drift in:title'` is empty. Since #207, the search matches the full environment-qualified title as an exact phrase, so an open issue for one environment can no longer absorb another environment's drift — but an open issue for the **same** environment still would, so this check stays. |
| Branches converged | `git diff origin/lab origin/dev -- scripts tests .github` is empty. |
| Baseline audits clean | Both tenants audit all-`NoChange`, zero orphans, before anything starts. |
| `gh auth status` | Authenticated with write access. |

## Conventions

- **Test object:** one policy per tenant named `e2e-irm-sync-<yyyyMMdd>`,
  scenario `LeakOfInformation`, `enabled: false`, carrying a
  `description`. The prefix is deliberately distinct from the smoke
  wrapper's `e2e-irm-smoke-`.
- **`description` is the drift field.** It maps to the cmdlet's
  `-Comment`. `Compare-IRMPolicy` only diffs fields the YAML declares, so
  a test policy without a description cannot demonstrate drift at all.
- **`enabled` stays `false` throughout.** Toggling it to `true` would
  start live insider-risk scoring on the tenant.
- **Never `-PruneMissing`.** Banned on this surface. Deletions happen only
  through a prefix-asserted `Remove-InsiderRiskPolicy`.
- **Who runs what.** Every tenant write and every GitHub state change is
  operator-run. Read-only audits between legs may be run by anyone or
  anything. Each leg below is marked.
- **Evidence.** Record the run id, PR/issue number, and the row counts by
  category for each leg on the tracking issue as you go.

Restore the default `az` context (`az account set --subscription
"contoso-lab.cloud"`) when you finish, and after any leg that switched it.

## Traps this test hit, in the order they will bite you

Every one of these was hit for real on a live run. None is a defect in
the repo; each will waste an hour if you meet it cold.

- **The reconciler disconnects your session.** `Deploy-IRMPolicies.ps1`
  calls `Disconnect-ExchangeOnline` in its `finally` block, so it tears
  down the caller's session too. A script that holds an IPPS session
  across a reconciler call finds its next `Get-InsiderRiskPolicy` failing
  with *"not recognized as a name of a cmdlet"*, which reads like a
  missing module rather than a closed session. **Reconnect after every
  reconciler invocation**, or never hold a session across one.

- **Deletes are eventually consistent.** An audit run immediately after
  `Remove-InsiderRiskPolicy` still reported the policy as an `Orphan`
  against a stale tenant count. The delete had succeeded. Poll until the
  policy is actually absent before auditing;
  [`Invoke-IRMSmokeTest.ps1`](../../scripts/Invoke-IRMSmokeTest.ps1)
  already allows 60 seconds for this.

- **The `az` context not matching the parameters file used to go unchecked**,
  and it was hard to see: `Deploy-IRMPolicies.ps1` took `tenantId` from
  `az account show` and `appId` from `az ad app list`, so the `az` context
  decided which tenant was read regardless of what `-ParametersFile` said —
  `-ParametersFile` only supplied the `TenantDomain` passed to
  `Connect-IPPSSession`, and the token's tenant won on a mismatch. The header
  would print `Environment : dev` while the session was actually lab. This
  cost an hour on run 2 and produced a convincing false "a codified policy was
  deleted" alarm — the tells at the time were the `Subscription :` line and
  the system-managed `IRM_Tenant_Setting_<tenant-guid>` row, whose GUID
  differs per tenant.

  **Fixed in [#215](../../../../issues/215):** `Deploy-IRMPolicies.ps1` now
  calls `Assert-TenantContextMatchesParametersFile`
  (`scripts/modules/TenantContextGuard.psm1`, [#234](../../../../pull/234) /
  [#236](../../../../pull/236)) immediately after `az account show`, and
  fails loudly — naming both the observed and expected tenant — before any
  tenant read or write. `Invoke-LocalIrmDriftSync.ps1` and
  `Invoke-LocalDlpDriftSync.ps1` carried this check first and are what the
  shared module was extracted from. Still worth running `az account show`
  yourself before a tenant-touching command out of habit; the guard is a
  safety net, not a reason to stop checking.

  **Coverage is now complete.** [#235](../../../../issues/235), which
  tracked the nine reconcilers resolving tenant identity through auth paths
  the first cut did not reach, is **closed**: all **22** `Deploy-*.ps1`
  reconcilers plus the two local drift-sync scripts import the module and
  call the guard — 24 call sites, none importing without calling. Run 3
  verified this against the source rather than trusting the issue state.

- **The guard warns instead of throwing in CI, and that is correct.**
  Locally you will see one line per reconciler invocation:

  ```
  az context OK: Contoso Subscription -> contoso.onmicrosoft.com
  ```

  In CI you will see this instead, on **every** tenant-touching job:

  ```
  WARNING: Could not verify the az context against 'contoso.onmicrosoft.com': the
  ARM tenants list returned no verified-domain data for the current tenant (typical for
  a service principal / OIDC login). Continuing unverified.
  ```

  **Do not "fix" it.** ARM's `/tenants` endpoint answers a service
  principal with no domain data, and the first version of the guard read
  that silence as a mismatch — which broke every CI data-plane run for
  about two hours on 2026-09-07. [#242](../../../../pull/242) makes the
  guard distinguish *no evidence* (warn and continue) from *contrary
  evidence* (throw). Both branches were exercised live on run 3: four
  local `az context OK:` lines across both tenants, and the warning on
  every CI job, with the `IRM_Tenant_Setting_<tenant-guid>` row confirming
  each run still reached the tenant it meant to.

- **A skipped tenant-touching job now announces itself, and only on a
  schedule.** Since [#245](../../../../issues/245) all 13 gated workflows
  emit a `::warning::` and write a job summary reading
  `## NOT VERIFIED -- the tenant was not contacted` when their
  tenant-touching job is skipped. **Expect this on lab**, whose scheduled
  `sync-irm-from-tenant` runs skip by design at the ADR 0060
  `CI_DATA_PLANE_ENABLED=false` gate — that is the point, because a
  skipped run used to be indistinguishable from a verified one, and the
  run still concludes `success` in the run list because GitHub gives a
  normal job no neutral conclusion.

  **You cannot reach it by dispatch.** The ADR 0060 branch of the
  preflight is guarded `EVENT_NAME -eq 'schedule'`, so a
  `workflow_dispatch` on lab passes preflight and then dies red at the Key
  Vault read instead. Do not provoke that to see the message; wait for the
  08:00 UTC schedule, or cite an existing red run.

- **`ExportDiffFilter`'s array-input fix ([#224](../../../../issues/224))
  is not on this surface, whatever a handoff may tell you.** Both IRM
  callers pre-join their `git diff` capture — `Invoke-LocalIrmDriftSync.ps1`
  line 458 has ended in a `-join` since the script was created in #191, and
  `git log -L 458,458` shows the #224 fix never touched it — and
  `sync-irm-from-tenant.yml` never imports the module at all, because it
  opens an issue rather than diffing an export. The callers that genuinely
  passed arrays are `sync-dlp-from-tenant.yml`,
  `sync-label-policies-from-tenant.yml` and
  `sync-auto-label-policies-from-tenant.yml`. **No leg in this runbook can
  prove #224 live.** Legs B and F do exercise `Get-ExportDiffSummary` and
  `Test-ExportDiffMeaningful` on a real multi-line diff through the string
  path, which is worth having; do not report it as more than that.

  **An uncompressed Leg E can still catch it, on a sibling surface.** Run 5
  did, three ways in one 06:00-07:00 window, because the fan-out reaches
  those three workflows against dev:

  1. a real `git diff` array classified **cosmetic-only** (auto-label
     policies) — the function was reached, since that notice sits *after* the
     `if (-not $diff) { return }` guard that kept #224 latent for so long;
  2. a real array classified **meaningful**, opening a drift-back PR
     (label-policies) — the other branch of the same function;
  3. strongest of the three: `sync-label-policies-from-tenant` had failed
     against dev on **2026-09-05, -06 and -07**, every time at
     `$meaningful = Test-ExportDiffMeaningful -DiffText $diff`, and succeeded
     for the first time ever on 09-08. The failure #224 caused is in the run
     history and the fix removed it.

  So: still not provable from an IRM leg, but **do check the fan-out's dev
  runs before concluding a run left #224 unproved.** Note also that
  `git diff` output is structurally multi-line — five header lines before any
  content — so any non-empty capture is an array, never a string.

- **A drift-back pull request carries no CI — and leaves a red run behind
  saying so badly.** `gh pr checks` on an
  `auto/irm-portal-wins-drift-<env>` PR returns *"no checks reported"*:
  `peter-evans/create-pull-request` opens the PR as `github-actions[bot]`
  using `GITHUB_TOKEN`, and GitHub's loop prevention will not run
  workflows for it. So this repo's standing "run `gh pr checks <n>` before
  calling any PR ready" rule returns an empty result on this one class of
  PR, and an empty result here means **no CI exists**, not *CI passed*.
  The YAML is first validated by the merge's own push run, after the fact.

  **The confusing part is what the Actions tab shows.** GitHub still
  creates a `validate` run for the `pull_request` event, runs **zero
  jobs** in it, and concludes it **`failure`** — with no check-runs
  attached to the head commit, which is why `gh pr checks` sees nothing.
  Auditing a session with `gh run list` therefore turns up entries like

  ```
  failure  validate  [auto/irm-portal-wins-drift-dev]
  ```

  that are **not** validation failures and have nothing to diagnose:
  `gh api repos/<owner>/<repo>/actions/runs/<id>/jobs` reports
  `total_count: 0` and the run's actor is `github-actions[bot]`. It is
  longstanding and not IRM-specific — the same zero-job red runs exist for
  `auto/labels-drift-sync-dev` and back through run 2's drift-back PRs.
  Contrast `auto/irm-drift-sync-lab`, opened by
  `Invoke-LocalIrmDriftSync.ps1` with the operator's own token, whose
  `validate` runs are real and green. **Before chasing a red run on an
  `auto/*` branch, check its job count.**

- **Deletes take longer to propagate than you will want to wait.** Run 3
  measured **25 seconds** on lab and **35 seconds** on dev between a
  successful `Remove-InsiderRiskPolicy` and the policy actually
  disappearing from `Get-InsiderRiskPolicy` — five and seven consecutive
  5-second polls still returning it. Audit inside that window and you get
  a convincing false `Orphan`.

- **GitHub's search index lags the issue state.** Immediately after
  closing a drift issue, `gh issue list --state open --search '…'` still
  listed it as open for over a minute, while `gh issue view <n> --json
  state` and a label-filtered `gh issue list` (neither of which goes
  through the search index) correctly reported `CLOSED`. The precondition
  check below is the `--search` form, so confirm a surprising result with
  `gh issue view` before chasing it. Note the workflow's own idempotency
  guard uses the same search API; run 3 did not observe it misfire (a
  dispatch two minutes later found the issue correctly), but its
  correctness does rest on index latency staying shorter than the gap
  between runs.

- **Nothing checks the desired-state file against the parameters file.**
  Running `Deploy-IRMPolicies.ps1 -ParametersFile infra/parameters/lab.yaml`
  from a `dev` checkout silently compares **dev's** YAML to **lab's**
  tenant and reports confident nonsense — in the first run, a `Create` row
  for a policy that only exists in dev's desired state. There is no guard.
  [`Invoke-LocalIrmDriftSync.ps1`](../../scripts/Invoke-LocalIrmDriftSync.ps1)
  cannot make this mistake, because it checks out a worktree from
  `origin/<branch>` and enforces the ADR 0057 branch-to-environment
  mapping. **Prefer the tool over calling the reconciler by hand**, and if
  you must call it directly, pass `-Path` explicitly.

---

## Leg 0 — static gate and export round-trip · *anyone, read-only*

```powershell
$env:GITHUB_BASE_REF = 'dev'; ./tests/Run-Pester.ps1
./scripts/Test-IdentifierResidue.ps1 -FailOnReview
./scripts/Update-LandingPageEmbeds.ps1 -Check
```

> **The suite no longer cares which `bash` it finds.**
> `tests/workflows/KeyVaultOpenVerify.Tests.ps1` replays a workflow's shell
> block through whatever `bash` is on `PATH`, and it used to hand that shell
> a Windows temp path plus a process environment — neither of which survives
> `bash` resolving to the WSL shim at
> `AppData/Local/Microsoft/WindowsApps/bash.exe`, which is the **default** on
> a Windows 11 box with WSL installed. Run 3 lost its first Leg 0 to the
> resulting **8 failures at `exit 127`**, none of them related to any change
> under test. Fixed in [#38](../../../../issues/38): the replay inlines its
> values into the script text and writes it to `bash -s` on stdin, so nothing
> but the script itself crosses the boundary. Measured on the same box with
> **no `PATH` workaround**: **3550 passed / 0 failed / 31 skipped** under the
> WSL shim, and identical under Git Bash.
>
> Note #38's title says the tests fail "on Windows Git Bash". They never did
> — they passed there and failed under WSL. If you hit an unexplained
> `exit 127` from a shell replay anywhere else in this repo, that inversion
> is the thing to check first.

Then, per environment, export to a scratch path and diff it against the
committed file:

```powershell
./scripts/Deploy-IRMPolicies.ps1 -ExportCurrentState -Force -Path <scratch>.yaml `
  -ParametersFile infra/parameters/<env>.yaml -Confirm:$false
```

**Compare the policy entries, not the whole files.** The exporter emits the
`policies:` block only, while every committed file carries a long explanatory
comment header — so a whole-file `git diff --no-index` is *never* empty and
tells you nothing. Extract and compare the entry fields instead:

```powershell
$fields = '^\s*- name:|^\s*scenario:|^\s*enabled:|^\s*description:'
$a = Select-String -Path <scratch>.yaml -Pattern $fields | ForEach-Object Line
$b = Select-String -Path data-plane/irm/policies.yaml -Pattern $fields | ForEach-Object Line
Compare-Object $a $b -SyncWindow 0
```

**Expected.** Suites green. Residue scan reports zero unclaimed. The entry
comparison is **empty** on both tenants.

**STOP** if that comparison is non-empty. Every drift-back PR later in
this runbook would carry that noise, and you would not be able to tell it
apart from the drift you meant to create.

> When reading a committed file out of git in PowerShell, set
> `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` first and
> confirm the result still matches `[char]0x2014`. The policy names
> contain an em-dash, and the default console decoding silently corrupts
> it, which reads as drift that is not there.

---

## Leg A — forward apply on dev, via merge-triggered CI · *operator merges*

Open a PR against `dev` adding the test policy to
`data-plane/irm/policies.yaml`. Merge it.

**Expected** in the resulting `deploy-irm` run: enumerate reports
`Desired policies: N+1` and `Tenant policies : N+1` with **no**
`[ADR0029-SKIP]` line and `skip_count=0`; apply reports **`Created 1`**
and `NoChange` for everything else; the summary says `Skipped objects: 0`;
the `drift-back-pr` job is skipped. Since #196, the create path reads the
policy back immediately: if the tenant honoured `enabled: false` as
declared, the `Created` row's reason is unremarkable; if it did not
(reproduced on both tenants prior to the fix), the log carries a
`WARNING: Create did not honour enabled on IRM policy '…' (issue #196);
converging with Set-InsiderRiskPolicy.` and the `Created` row's reason
ends `Create did not honour enabled; converged with a follow-up Set-
(issue #196).` Either way, `Get-InsiderRiskPolicy` immediately afterwards
must return `Enabled: False` — no second manual pass. A follow-up audit
reports every row `NoChange`.

**STOP** on any `Failed` row, or any non-`NoChange` row naming a policy
other than the test one.

---

## Leg B — forward apply on lab, locally · *operator-run*

Lab has no CI path to its own tenant: `sync-irm-from-tenant.yml` no-ops at
the ADR 0060 gate, and `deploy-irm.yml`, which has no such gate, fails at
the Key Vault certificate read on every qualifying push. Do not provoke a
red run to prove this; cite an existing one.

Build a scratch YAML from `origin/lab`'s file plus the test policy, then:

```powershell
./scripts/Deploy-IRMPolicies.ps1 -Path <scratch>.yaml `
  -ParametersFile infra/parameters/lab.yaml -Confirm:$false          # Created 1
./scripts/Deploy-IRMPolicies.ps1 -Path <scratch-v2>.yaml -DirectionPolicy repo-wins `
  -ParametersFile infra/parameters/lab.yaml -Confirm:$false          # Updated 1
```

where the v2 scratch changes only the test policy's `description`.

**Expected.** `Created 1` then `Updated 1`, the latter accompanied by an
overwrite warning naming the `description` field. Since #196, the create
step itself reads `enabled` back and converges it if the cmdlet did not
honour it — `Get-InsiderRiskPolicy` should return `Enabled: False`
directly after the create, with no separate corrective pass needed.
Audits between the two report all-`NoChange` against the scratch file.

Audit the scratch file with an explicit `-Path`, never the default, or
you will be comparing the wrong branch's desired state (see Traps).

---

## Leg F — lab's reverse leg, via the local tool · *operator runs, anyone audits*

With the test policy live on lab and **absent** from `origin/lab`'s
tracked YAML:

```powershell
./scripts/Invoke-LocalIrmDriftSync.ps1 -BaseBranch lab
```

**Expected.** The export diff is exactly the test policy's block; the
script commits to `auto/irm-drift-sync-lab`, pushes, and opens a PR; an
audit record appears at `.copilot-tracking/audit/irm-lab.json` with
`mode: sync` and `drift.detected: true`, and the operations console's
tenant-audit panel lists it.

**Then close that PR** — the YAML side is intended here, because the
tenant object is a throwaway. Delete the branch. Remove the test policy
from lab with a prefix-asserted `Remove-InsiderRiskPolicy`, **poll until
it is actually gone**, and re-run with `-AuditOnly`: all rows `NoChange`,
`driftRowCount` zero.

**STOP** if the PR diff touches any policy but the test one. See
[`irm-local-drift-sync.md`](irm-local-drift-sync.md) for the guards this
script enforces and for the review checklist.

---

## Leg C1 — push-time drift-back, reviewer **merges** · *operator-run*

Edit the tenant, not the repo:

```powershell
Set-InsiderRiskPolicy -Identity 'e2e-irm-sync-<yyyyMMdd>' -Comment '<a new value>'
```

An audit now reports exactly one `Update` row. Then dispatch the forward
workflow — a dispatch is enough, because the drift-back job carries no
event filter:

```bash
gh workflow run deploy-irm.yml --ref dev -f environment=dev
```

`-f environment=dev` is mandatory: the input's declared default (`lab`)
beats the branch fallback, and the `dev` Environment rejects a dispatch
from any ref but `dev`.

**Expected.** Enumerate emits `[ADR0029-SKIP] e2e-irm-sync-<yyyyMMdd>` and
`skip_count=1`; apply reports `Skipped 1`; the re-export uploads
`irm-policies-drift-back-<run_id>`; a PR opens on
`auto/irm-portal-wins-drift-dev` whose diff is **exactly the one
`description` line**.

Read the diff before acting on it. Then **merge** the PR — the tenant
value is the intended one in this leg. The merge's own push run must
report `skip_count=0` and no new PR. Delete the branch afterwards;
`delete-branch` is `false` by design.

**STOP** if the diff carries anything beyond the single description line.

---

## Leg C2 — push-time drift-back, reviewer **closes**, then `repo-wins` · *operator-run*

Open a PR against `dev` changing the test policy's `description` to a new
value, and merge it.

**Expected.** The push run reports `skip_count=1` and `Skipped 1`, and
re-creates the drift-back PR — whose diff now *reverts* your edit back to
the tenant's value, because the tenant won under `portal-wins`.

**Close that PR.** The YAML side is the intended one here. Merging it
would silently undo the change you just made, which is exactly what went
wrong on the sibling surface in #170 and #172.

The repo now has to win, and only one CI path can do that:

```bash
gh workflow run deploy-irm.yml --ref dev -f environment=dev \
  -f irm_direction_policy=repo-wins -f "confirm_overwrite_irm=overwrite portal"
```

The token is a case-sensitive literal: two words, one space, no trailing
whitespace.

**Expected.** The dispatch-input validation passes and warns that
`repo-wins` was confirmed; the enumerate step is skipped entirely (it runs
only under `portal-wins`); the apply reports **`Updated 1`** with a warning
naming the overwritten `description` field; `Skipped objects: 0`; no
drift-back job. A follow-up audit reports all-`NoChange`. Delete the
`auto/irm-portal-wins-drift-dev` branch again.

**STOP** if the token is rejected — check the literal before assuming the
gate is broken — or on any `Failed` row.

---

## Leg D — the `Blocked` row · *anyone, `-WhatIf` only, never applied*

Copy the tracked YAML to a scratch file and change **only** the test
policy's `scenario`. Run an audit against the scratch file.

**Expected.** One `Blocked` row, reason `Immutable field drift: scenario
(YAML '<x>', tenant '<y>'). Set-InsiderRiskPolicy cannot change
InsiderRiskScenario…`. Re-run under `portal-wins` with the test policy in
`-SkipNames`: the row reads `Skipped`, and the `Blocked` row disappears —
a skip baseline can mask an unresolvable difference.

Discard the scratch file. **Never commit a scenario mismatch.** It cannot
be applied by any direction policy, and because `Blocked` counts as drift,
it would raise the scheduled issue every single day until someone deleted
and recreated the tenant policy.

---

## Leg E — the scheduled leg, the dev fan-out, and the #207 environment scoping · *observe, then operator-run*

Before the first dev dispatch below, prove the #207 fix rather than just
trusting it: open a throwaway **decoy** issue titled exactly `IRM policy
drift detected in the lab environment tenant`, labelled `drift-detected`
and `squad:automation-engineer` (the issue search filters on both). Prior
to #207, the search matched any environment's title as a bare substring,
so this decoy would have silently absorbed dev's drift as a comment
instead of dev getting its own issue.

Leave the test policy on the dev tenant and remove it from `dev`'s tracked
YAML (a PR, merged). The push run reports `Orphan 1` and `skip_count=0`,
opens nothing, and deletes nothing — there is no `-PruneMissing`.

Now wait for the daily schedule. A cron fires only on the default branch,
so the sequence is: lab's scheduled run no-ops at the ADR 0060 gate but
its `fanout-dev` job still dispatches `dev` (that job has no `needs:`),
and the dev run does the real work.

**Expected** in the dev run: an `[ADR0029-AUDIT]` banner, a drift table
with exactly one `Orphan` row for the test policy, and a **new** issue
titled `IRM policy drift detected in the dev environment tenant`,
labelled `drift-detected` / `needs-review` / `squad:automation-engineer`
— **not** a comment on the decoy issue. That is the proof of #207.

Dispatch the workflow a second time: the same **dev** issue gains a
refresh comment rather than a duplicate issue being opened, and the
decoy issue still shows no activity. Close the decoy issue by hand once
this is confirmed.

Remove the test policy from the dev tenant with a prefix-asserted
`Remove-InsiderRiskPolicy`, then dispatch a third time: the run reports no
drift and opens nothing. Close the issue by hand — a cleared drift does
not auto-close it.

**STOP** if more than one drift row appears, or if the issue lands under
the wrong environment.

---

## Legs G and H — promotion and the final gate · *operator merges*

Promote `dev` → `lab` in the usual way. The promotion must carry the
tooling and documentation changes and **nothing** from
`data-plane/irm/policies.yaml`: the two tenants hold different desired
state on purpose. Drop that hunk if it appears.

**Expected afterwards.** `git diff origin/lab origin/dev -- scripts tests
.github` empty; the two branches' policy files differ by exactly the
dev-only policy; `entity-lists.yaml` empty on both (parked, ADR 0064).
Re-run Leg 0's gate with `GITHUB_BASE_REF=lab`.

**Definition of done.** Both tenants audit all-`NoChange` with zero
orphans; no `e2e-irm-sync-*` object survives on either tenant; no
`auto/irm-*` branch survives; every leg has its evidence on the tracking
issue.

---

## Known gaps

- **Lab's CI legs cannot be exercised at all**, by construction. Legs A,
  C1, C2 and E are dev-only; lab's equivalents are Legs B and F, run
  locally. This is the ADR 0060 condition, not a defect.
- **The scheduled leg's refresh comment says "scheduled"** even when the
  run was a manual dispatch.
- **The console's audit panel renders a `Rules:` line** that IRM records
  do not populate, so it reads as not applicable.
- **`Invoke-IRMSmokeTest.ps1` is stale** and is not used by this runbook.
  Tracked as [#192](../../../../issues/192).
- **Two things only a scheduled run can prove, and run 5 proved them.** The
  `fanout-dev` job (`if: github.event_name == 'schedule'`) and #245's
  `NOT VERIFIED` announcement on lab are both unreachable from a
  `workflow_dispatch` — a lab dispatch passes preflight and dies red at the
  Key Vault read instead, which this runbook forbids provoking. A run that
  compresses Leg E therefore leaves both unproved and **must say so**.

  Run 5 ([#273](../../../../issues/273), 2026-09-08) ran Leg E uncompressed
  and observed both on **all five** scheduled surfaces in one window. Take the
  evidence from the check-run annotations API rather than by scraping logs:

  ```
  gh api repos/<owner>/<repo>/check-runs/<preflight-job-id>/annotations
    [warning] vars.CI_DATA_PLANE_ENABLED is 'false' ... skipping this scheduled
              tenant-touching run.                                        <- #245
    [notice]  Dispatched <workflow>.yml against ref 'dev' (environment=dev).
                                                                          <- #167
  ```

  Note what is **not** retrievable: `$GITHUB_STEP_SUMMARY` content is not
  exposed through the REST API — `check-runs/<id>` returns
  `output.summary: null` for every job. The `NOT VERIFIED` summary is
  established by the annotation plus the fact that the same preflight branch
  writes both with no condition between them; the rendered text itself is
  visible only on the run page.

## Fixed since the first run — confirmed live on runs 2 to 5

- **The create path now honours `enabled: false`.** `New-InsiderRiskPolicy`
  used to ignore `-Enabled:$false` and create the policy enabled anyway,
  on both tenants. Fixed in [#196](../../../../issues/196):
  `Deploy-IRMPolicies.ps1` now reads the policy back immediately after a
  create and issues a follow-up `Set-InsiderRiskPolicy` for any tracked
  field the service did not honour, reporting `Failed` if that follow-up
  write does not take either. Legs A and B above assert the read-back
  directly rather than working around it. **Run 2 confirmed the underlying
  cmdlet defect still reproduces on both tenants** — the fix detects and
  converges it every time, but do not assume `New-InsiderRiskPolicy` has been
  repaired upstream.
- **The drift-issue search is environment-scoped.** Fixed in
  [#207](../../../../issues/207): the search now matches the full
  environment-qualified issue title as an exact phrase, so an open issue
  for one environment can no longer absorb another environment's drift as
  a refresh comment. An open issue for the *same* environment still
  would — see the precondition table above. **Run 2 proved this through the
  real scheduled path**: a decoy carrying lab's exact title and both search
  labels ended with zero comments while dev opened its own issue. The
  pre-fix search string was verified beforehand to match that decoy, so the
  test was a genuine discriminator rather than a formality.

## See also

- [`irm-local-drift-sync.md`](irm-local-drift-sync.md) — the local tool Legs B and F use.
- [`irm-end-to-end-smoke.md`](irm-end-to-end-smoke.md) — the cmdlet lifecycle test this one deliberately does not duplicate.
- [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md) — the sibling surface's contract smoke, whose structure this runbook follows.
- [ADR 0029](../adr/0029-source-of-truth-direction-policy.md) — the direction policy that makes Leg C2 necessary.
- [ADR 0057](../adr/0057-multi-environment-and-branch-model.md) — the branch/environment model Legs G and H assert.
- [ADR 0060](../adr/0060-governance-locked-kv-local-cert-apply.md) — why lab is local-only.
