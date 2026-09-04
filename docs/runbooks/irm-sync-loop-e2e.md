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
`sync-irm-from-tenant.yml`, or `Invoke-LocalIrmDriftSync.ps1`. First run:
issue [#190](../../../../issues/190).

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
| No open drift issue | `gh issue list --state open --search 'IRM policy drift in:title'` is empty. The scheduled leg's issue search carries **no environment filter**, so an open `lab` issue would absorb `dev`'s drift as a comment instead of opening its own. |
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
"marcusj-lab.cloud"`) when you finish, and after any leg that switched it.

## Traps this test hit, in the order they will bite you

Every one of these was hit for real on the first run. None is a defect in
the repo; all three will waste an hour if you meet them cold.

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

Then, per environment, export to a scratch path and diff it against the
committed file:

```powershell
./scripts/Deploy-IRMPolicies.ps1 -ExportCurrentState -Force -Path <scratch>.yaml `
  -ParametersFile infra/parameters/<env>.yaml -Confirm:$false
git diff --no-index <scratch>.yaml <committed copy of origin/<env>'s file>
```

**Expected.** Suites green. Residue scan reports zero unclaimed. Export
diff **empty** on both tenants.

**STOP** if the export diff is non-empty. Every drift-back PR later in
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
the `drift-back-pr` job is skipped. A follow-up audit reports every row
`NoChange`.

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
overwrite warning naming the `description` field. Audits between the two
report all-`NoChange` against the scratch file.

Check `enabled` after the create rather than trusting it — see
[#196](../../../../issues/196) in Known gaps. Audit the scratch file with
an explicit `-Path`, never the default, or you will be comparing the
wrong branch's desired state (see Traps).

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

## Leg E — the scheduled leg and the dev fan-out · *observe, then operator-run*

Leave the test policy on the dev tenant and remove it from `dev`'s tracked
YAML (a PR, merged). The push run reports `Orphan 1` and `skip_count=0`,
opens nothing, and deletes nothing — there is no `-PruneMissing`.

Now wait for the daily schedule. A cron fires only on the default branch,
so the sequence is: lab's scheduled run no-ops at the ADR 0060 gate but
its `fanout-dev` job still dispatches `dev` (that job has no `needs:`),
and the dev run does the real work.

**Expected** in the dev run: an `[ADR0029-AUDIT]` banner, a drift table
with exactly one `Orphan` row for the test policy, and a new issue titled
`IRM policy drift detected in the dev environment tenant`, labelled
`drift-detected` / `needs-review` / `squad:automation-engineer`.

Dispatch the workflow a second time: the same issue gains a refresh
comment rather than a duplicate issue being opened. (The comment says
"scheduled" even on a manual dispatch — cosmetic, recorded in #190.)

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
- **The drift-issue search has no environment filter**, so a `lab` drift
  issue left open would absorb `dev`'s drift as a comment. The
  precondition table checks for this; it is otherwise unguarded.
- **The scheduled leg's refresh comment says "scheduled"** even when the
  run was a manual dispatch.
- **The console's audit panel renders a `Rules:` line** that IRM records
  do not populate, so it reads as not applicable.
- **`Invoke-IRMSmokeTest.ps1` is stale** and is not used by this runbook.
  Tracked as [#192](../../../../issues/192).
- **A policy declared `enabled: false` is created enabled.**
  `New-InsiderRiskPolicy` ignores `-Enabled:$false`; `Set-` honours it.
  Reproduced on both tenants, so it is a cmdlet-level defect rather than a
  per-tenant quirk. Tracked as [#196](../../../../issues/196). Until it is
  fixed, a leg that creates a disabled policy must converge `enabled`
  with a follow-up `repo-wins` pass and check it, rather than assuming
  the declared value took effect.

## See also

- [`irm-local-drift-sync.md`](irm-local-drift-sync.md) — the local tool Legs B and F use.
- [`irm-end-to-end-smoke.md`](irm-end-to-end-smoke.md) — the cmdlet lifecycle test this one deliberately does not duplicate.
- [`dlp-end-to-end-smoke.md`](dlp-end-to-end-smoke.md) — the sibling surface's contract smoke, whose structure this runbook follows.
- [ADR 0029](../adr/0029-source-of-truth-direction-policy.md) — the direction policy that makes Leg C2 necessary.
- [ADR 0057](../adr/0057-multi-environment-and-branch-model.md) — the branch/environment model Legs G and H assert.
- [ADR 0060](../adr/0060-governance-locked-kv-local-cert-apply.md) — why lab is local-only.
