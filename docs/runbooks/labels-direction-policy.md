# Runbook: Dispatch deploy-labels.yml with an ADR 0029 direction policy

Use this runbook when you need to reconcile the Microsoft Purview /
Microsoft 365 sensitivity-label taxonomy in the lab tenant and the
default behaviour (portal-wins on `push`) is not what you want — for
example, to push a YAML-first correction back into the tenant, or to
run a read-only compliance audit of the live taxonomy.

The capability is the `direction_policy` and `confirm_overwrite`
`workflow_dispatch` inputs on
[`.github/workflows/deploy-labels.yml`](../../.github/workflows/deploy-labels.yml),
shipped per
[ADR 0029](../adr/0029-source-of-truth-direction-policy.md). The
script contract that these inputs thread through lives in
[`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1)
(`-DirectionPolicy`, `-SkipNames`). For the orthogonal destructive-prune
ceremony see
[`labels-prune-dispatch.md`](labels-prune-dispatch.md).

## The three modes

| Mode | Tenant effect | When to use |
|---|---|---|
| `audit` | Read-only. Emits the plan table; no `New-` / `Set-` / `Remove-Label` call fires under any condition. | Periodic compliance evidence; pre-flight sanity before a real apply. |
| `portal-wins` (default) | Creates labels declared in YAML but missing from the tenant. Applies non-conflicting updates. **Skips** shared labels whose tracked fields differ. If any label was skipped, opens (or refreshes) an auto-PR re-importing the tenant values for review. | Day-to-day push-to-`main`. Safe by construction: never overwrites a portal-only edit. |
| `repo-wins` | DESTRUCTIVE. Overwrites tenant fields with YAML values for every shared-label property drift. Each overwrite emits a Write-Warning naming the label and fields. Gated by `confirm_overwrite='overwrite portal'`. | YAML-first correction. Use when the YAML is authoritative and the tenant has drifted (a portal admin made an unintended edit, or a prior auto-PR was merged in error). |

## How the workflow expresses each mode

The workflow's `apply` job branches by `direction_policy`:

- **`audit`** — one script invocation:
  `Deploy-Labels.ps1 -DirectionPolicy audit -WhatIf:$false`. The script
  short-circuits before any write phase and emits the
  `[ADR0029-AUDIT]` marker so the run log makes the read-only intent
  unambiguous.
- **`portal-wins`** — two script invocations:
  1. **Enumerate pass** (read-only). Runs
     `Deploy-Labels.ps1 -DirectionPolicy portal-wins -WhatIf`. The
     direction-policy pass executes (it is gated only by
     `DirectionPolicy -ne 'audit'`, not by `WhatIfPreference`) and
     emits one `[ADR0029-SKIP] <displayName>` line per label the
     policy would skip. The write phase is gated by ShouldProcess and
     does not fire.
  2. **Apply pass.** The workflow parses the `[ADR0029-SKIP]` markers
     into a deterministic `-SkipNames` list and re-invokes the script
     with `-DirectionPolicy portal-wins -SkipNames @(...)`. Threading
     the explicit skip list makes the apply pass's skip decisions
     identical to the enumerate pass's, even if tenant state shifted
     between the two calls.
- **`repo-wins`** — two script invocations:
  1. **Audit pass** for plan visibility (read-only; same shape as
     `audit` mode).
  2. **Apply pass.** Runs
     `Deploy-Labels.ps1 -DirectionPolicy repo-wins`. No skip list.
     Each shared-label overwrite emits a `Write-Warning` so the run
     log lists every overwrite that fired.

The audit pass for `repo-wins` is symmetry, not policy: it costs one
read cycle and makes every dispatch's first action a read-only plan,
so the operator can scan the plan before the destructive apply.

## Typed-confirmation ceremony for `repo-wins`

`repo-wins` is destructive: it overwrites tenant fields. The workflow
demands a typed confirmation token to gate the dispatch. The token is
the literal string `overwrite portal` — lower-case, two words, exactly
one space. Mirrors the existing `confirm prune` ceremony per
[`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md)
§"Destructive writes require typed confirmation".

```pwsh
gh workflow run deploy-labels.yml `
  --ref main `
  --field direction_policy=repo-wins `
  --field 'confirm_overwrite=overwrite portal'
```

The `Validate dispatch inputs` step runs **before** Azure login,
**before** the Key Vault unlock window, and **before** any data-plane
call. A missing or mistyped token fails the job here with:

```text
::error::direction_policy=repo-wins requires confirm_overwrite to
equal the literal string 'overwrite portal' (case-sensitive, two
words separated by one space). Re-dispatch with the correct token.
See docs/runbooks/labels-direction-policy.md.
```

No tenant mutation, no Key Vault firewall toggle, no IPPS session.
Re-dispatch with the correct token.

## Compose with `prune_missing`

The two axes are orthogonal. See
[`labels-prune-dispatch.md`](labels-prune-dispatch.md#compose-with-direction_policy)
for the five-row truth table from ADR 0029. The most destructive
shape this workflow supports is
`direction_policy=repo-wins prune_missing=true`, which requires both
typed-confirmation tokens:

```pwsh
gh workflow run deploy-labels.yml `
  --ref main `
  --field direction_policy=repo-wins `
  --field 'confirm_overwrite=overwrite portal' `
  --field prune_missing=true `
  --field 'confirm_prune=confirm prune'
```

Typing one token does not unlock the other.

## Drift-back PR flow (portal-wins auto-PR)

When a `portal-wins` dispatch (or push to `main`) skips at least one
shared label, the workflow re-exports the live tenant state into
`data-plane/information-protection/labels.yaml`, uploads it as a
short-lived artifact, and the `drift-back-pr` job opens (or refreshes)
a pull request on the branch `auto/labels-portal-wins-drift` titled
**chore(data-plane): drift-back sync labels skipped under portal-wins**.

The PR is the operator's decision point:

- **If the tenant value is the intended one** — merge the PR. The next
  push run on `main` passes cleanly on the new SHA.
- **If the YAML value is the intended one** — close the PR and
  re-dispatch with `direction_policy=repo-wins` and
  `confirm_overwrite='overwrite portal'` to push the YAML to the tenant.

### `GITHUB_TOKEN` workaround for bot-opened PRs

The drift-back PR is opened by
[`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request)
under the `GITHUB_TOKEN`. GitHub Actions does **not** trigger workflows
from events authored by `GITHUB_TOKEN`, so
[`validate.yml`](../../.github/workflows/validate.yml) and other
PR-event workflows do not fire automatically. To run validation,
**close and reopen the PR** (which re-fires the `pull_request` event
under the closer's identity) or push an empty commit to the
`auto/labels-portal-wins-drift` branch:

```pwsh
git fetch origin auto/labels-portal-wins-drift
git switch auto/labels-portal-wins-drift
git commit --allow-empty -m "ci: trigger validation"
git push
```

Source:
[GitHub Docs — Triggering a workflow from a workflow](https://docs.github.com/en/actions/using-workflows/triggering-a-workflow#triggering-a-workflow-from-a-workflow).

### Distinct from the scheduled drift-back PR

The companion workflow
[`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
opens its drift-back PR on a different branch
(`auto/labels-drift-sync`) so a scheduled sync and an apply-time
skip cannot fight over the same PR. The two PRs may exist
simultaneously when both detect drift; merging either re-syncs the
repo to the tenant.

## Transitional note — first run after sub-issue C merges

Merging this workflow into `main` triggers a `push` run with the
default `direction_policy=portal-wins`. PR #453's outstanding
five-label divergence on the `contoso.onmicrosoft.com` tenant (External,
External (Restricted), Internal, Partner, Partner (Restricted)) will
be **skipped** by the apply pass, and an auto-PR will open re-importing
the tenant's (inaccurate) comment values.

**Do not merge that auto-PR.** Close it. Then dispatch with
`direction_policy=repo-wins` and
`confirm_overwrite='overwrite portal'` (scenario 3 of the post-merge
acceptance plan on issue #459) to push the YAML's corrected comments
into the tenant. After that run converges, subsequent push-event
applies will pass cleanly and the auto-PR will not re-open.

## See also

- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md)
  — the binding contract this runbook describes.
- [`labels-prune-dispatch.md`](labels-prune-dispatch.md) — the orthogonal
  `prune_missing` ceremony and the five-row composition truth table.
- [`deploy-labels.yml`](../../.github/workflows/deploy-labels.yml) — the
  workflow itself.
- [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) —
  the `-DirectionPolicy` and `-SkipNames` contract this workflow threads
  values through (shipped in PR #458 / sub-issue B).
- [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
  — scheduled drift-back companion (different branch / PR title).
- [`kv-temp-unlock.md`](kv-temp-unlock.md) — Key Vault firewall toggle
  recipe used by both `apply` and the re-export step.
- [`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md)
  §"Destructive writes require typed confirmation" — source rule for
  the `overwrite portal` token shape.
- [Set-Label (Exchange / Security & Compliance PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label)
  — the cmdlet a `repo-wins` apply ultimately calls.
- [Manage sensitivity labels (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/create-sensitivity-labels)
  — bi-directional admin model this contract aligns with.
