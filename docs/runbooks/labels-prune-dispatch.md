# Runbook: Dispatch destructive prune of sensitivity-label orphans

Use this runbook when you need to remove an orphan Microsoft 365 sensitivity
label from the lab tenant — a label that exists in IPPS / Microsoft Purview
but is *not* declared in
[`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml).

The capability is the `prune_missing` + `confirm_prune` `workflow_dispatch`
inputs on [`.github/workflows/deploy-labels.yml`](../../.github/workflows/deploy-labels.yml),
shipped in [PR #439](https://github.com/contoso/Purview-as-Code-Generic/pull/439).
The first operational dispatch of this capability — Item 2b, removing the
orphan `Smoke-Parent` left over from PR #428's smoke test — is the worked
example in this runbook.

> The `prune_missing` axis is **orthogonal** to the ADR 0029 `direction_policy`
> axis introduced for `deploy-labels.yml`. For the direction-policy ceremony,
> mode definitions, and the auto-PR drift-back flow, see
> [`labels-direction-policy.md`](labels-direction-policy.md). The composition
> rules are summarised in the "Compose with `direction_policy`" section
> below.

## When to use this runbook

Use it when **all** of the following are true:

- The default `deploy-labels.yml` push trigger or a `prune_missing=false`
  dispatch reports an orphan label (Plan-table `NoOp` row with reason
  "Tenant label not in YAML; skipped (use -PruneMissing to remove).").
- You have confirmed via the Microsoft Purview portal
  ([Information Protection — Labels](https://learn.microsoft.com/en-us/purview/sensitivity-labels))
  that the orphan label is genuinely present and not just a phantom from a
  stale read (see "Phantom orphan" below and [#441](https://github.com/contoso/Purview-as-Code-Generic/issues/441)).
- You have confirmed the orphan should be deleted, not added to
  [`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml).
  Adding it back is the alternative path — file a drift-back PR via
  [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
  instead of pruning.

## Pre-dispatch evidence (required)

Capture the current state before invoking the destructive dispatch. Run
locally — the local-cert IPPS path shipped in
[PR #437](https://github.com/contoso/Purview-as-Code-Generic/pull/437)
skips the Key Vault unlock window.

```pwsh
# Hydrate the local-cert thumbprint if you started this pwsh session before
# Item 0 provisioning landed:
$env:PURVIEW_LOCAL_CERT_THUMBPRINT = [Environment]::GetEnvironmentVariable(
    'PURVIEW_LOCAL_CERT_THUMBPRINT','User')

./scripts/Deploy-Labels.ps1 -WhatIf -InformationAction Continue
```

Expect a Plan-table row of the form:

```text
NoOp     Label                     <Orphan-Label-Name>
...
NoOp     Label <Orphan-Label-Name>      Tenant label not in YAML; skipped (use -PruneMissing to remove).
```

If you do not see the orphan, stop — there is nothing to prune.

**Cross-check the portal.** Open the
[Microsoft Purview portal](https://purview.microsoft.com) →
**Information Protection** → **Sensitivity labels**, and confirm the orphan
is actually present. The `-WhatIf` plan can return a phantom for a few
minutes after a recent prune (see "Phantom orphan after a prune" below).

## Destructive dispatch

The workflow demands a typed-confirmation token to gate the prune. The
token is the literal string `confirm prune` — lower-case, two words,
exactly one space. Per `.github/instructions/mcp-tool-usage.instructions.md`
§"Destructive writes require typed confirmation".

```pwsh
gh workflow run deploy-labels.yml `
  --ref main `
  --field prune_missing=true `
  --field 'confirm_prune=confirm prune'
```

Watch the run from the actions tab or via:

```pwsh
gh run list --workflow=deploy-labels.yml --limit 1
gh run watch <run-id>
```

### What each step does on the prune path

1. **Validate dispatch inputs.** Fails fast (`exit 1`) unless
   `confirm_prune -ceq 'confirm prune'`. Case-sensitive. Prints
   `::warning::Destructive prune confirmed.` on success.
2. **Azure login (OIDC).** `azure/login@v2` with the existing federated
   subject `gh-oidc-purview-data-plane`. No change to identity.
3. **Temporarily allow Key Vault public access.** Opens `kv-contoso-lab-01`
   for the duration of the apply, then re-locks via the
   `if: always()` Restore step. Documented in
   [`kv-temp-unlock.md`](kv-temp-unlock.md).
4. **Conflict guard (B-strict).** Exports the live tenant via
   `Deploy-Labels.ps1 -ExportCurrentState`, then runs the structural diff:
   - Allows orphan-row diffs (tenant labels not in YAML — the rows being
     pruned).
   - Rejects property drift on any shared label.
   Reports `Shared labels (must match): N`,
   `Orphan tenant labels (will be pruned): M [<names>]`,
   `YAML-only labels (will be created): K [<names>]`.
5. **Apply labels.** Runs `Deploy-Labels.ps1 -PruneMissing`. The script
   emits `Removed label '<Orphan-Label-Name>'` per pruned label. This is
   the authoritative record of the destructive action.
6. **Restore Key Vault network defaults.** Re-locks the vault. Runs even
   if a prior step failed.

## Post-dispatch convergence proof

Two authoritative sources, in order:

1. **Workflow run log.** The `Apply labels` step logs
   `Removed label '<Orphan-Label-Name>'` and the overall run conclusion is
   `success`. This is the canonical record. Copy the run URL into your PR
   description or runbook entry.
2. **Microsoft Purview portal.** Refresh
   **Information Protection** → **Sensitivity labels** and confirm the
   pruned label is gone.

A third probe — re-running `Deploy-Labels.ps1 -WhatIf` locally — is
*expected* to converge but is unreliable in the minutes immediately after
the prune. See the next section.

### Phantom orphan after a prune — fixed in #450

Observed during the first run of this runbook (Item 2b, 2026-05-29):
`Deploy-Labels.ps1 -WhatIf` continued to report the just-pruned label as
a `NoOp` orphan for ≥10 minutes after the workflow logged
`Removed label`. The portal had already converged.

**Root cause (live-tenant probes, 2026-05-29; closes
[#441](https://github.com/contoso/Purview-as-Code-Generic/issues/441),
fixed in [#450](https://github.com/contoso/Purview-as-Code-Generic/issues/450)):**
the staleness is not staleness at all.
[`Remove-Label`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-label)
transitions a sensitivity label into `Mode = PendingDeletion` rather
than hard-deleting it. The Microsoft Purview portal hides
`PendingDeletion` labels (operator sees the label as gone), but
[`Get-Label`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-label)
returns them by default. A direct probe ≈14 hours after the prune
returned the pruned label with `Mode = PendingDeletion`, `IsValid = True`,
and a `WhenChanged` timestamp matching its last edit — truthful service
state, not a stale read replica. (PR #447 originally framed this as
service-side staleness based on a code review that ruled out a
client-side cache but did not interrogate the `Mode` property; that
framing was wrong and this section supersedes it.)

**Fix.** [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1)
now applies `Where-Object { $_.Mode -ne 'PendingDeletion' }` to both
the Apply read path and the `-ExportCurrentState` read path. Pruned
labels no longer appear as `NoOp` orphans in plan tables and cannot
be re-imported into committed YAML by
[`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml).

**Defense-in-depth.** Even with the filter, the "Phantom-orphan check"
bullet on the `sync-labels-from-tenant.yml` drift-back PR body remains
in place. A reviewer should still portal-verify any newly re-added
label name in a drift-back diff against the recent prune history; that
guards against any future service-side regression that re-exposes a
soft-deleted label without the `PendingDeletion` marker.

**Do not treat a stale `-WhatIf` row as a failed prune** *if you are
running an older `Deploy-Labels.ps1` checkout*. If the workflow run
log shows `Removed label '<Orphan-Label-Name>'` and the portal
confirms the deletion, the prune is done. Pull `main` to pick up
the filter and re-run `-WhatIf`; the row will be gone. A second
destructive dispatch against a phantom would be a no-op against the
tenant (the label is already in `PendingDeletion`) but it would still
consume a destructive-confirmation gate and add noise to the run
history.

## Worked example: Item 2b, removing `Smoke-Parent`

| Phase | Timestamp (UTC) | Command / observation | Result |
|---|---|---|---|
| Pre-dispatch local `-WhatIf` | 2026-05-29T22:37 | `./scripts/Deploy-Labels.ps1 -WhatIf` on `DESKTOP-PLK8MN2` | `Read 11 label(s) from tenant`; Plan-table `NoOp Label Smoke-Parent` row present |
| Destructive dispatch | 2026-05-29T22:40:08 | `gh workflow run deploy-labels.yml --field prune_missing=true --field 'confirm_prune=confirm prune'` | Run [26665832827](https://github.com/contoso/Purview-as-Code-Generic/actions/runs/26665832827) created |
| Validate dispatch inputs | 2026-05-29T22:40:25 | step log | `prune_missing = 'true'`, `confirm_prune = <provided>`, `::warning::Destructive prune confirmed.` |
| Conflict guard (B-strict) | 2026-05-29T22:41:09 | step log | `Shared labels (must match): 10`; `Orphan tenant labels (will be pruned): 1 [Smoke-Parent]`; `YAML-only labels (will be created): 0 []`; guard passed |
| Apply labels | 2026-05-29T22:41:48 | step log | `Removed label 'Smoke-Parent'` |
| Restore KV defaults | 2026-05-29T22:41:48 | step log | `--public-network-access Disabled --default-action Deny` |
| Run conclusion | 2026-05-29T22:41:56 | `gh run view 26665832827` | `status: completed`, `conclusion: success` |
| Portal verification | 2026-05-29T22:55 | Lab owner opens [Microsoft Purview portal](https://purview.microsoft.com) → **Information Protection** → **Sensitivity labels** | `Smoke-Parent` no longer present — convergence confirmed |
| Phantom-orphan `-WhatIf` | 2026-05-29T22:44 – 22:52 | Three consecutive `Deploy-Labels.ps1 -WhatIf` runs | Each reported `Smoke-Parent` as `NoOp` orphan despite portal showing it removed; root cause was `Mode = PendingDeletion` (live-tenant probes 2026-05-29). Fixed in [#450](https://github.com/contoso/Purview-as-Code-Generic/issues/450) by filtering `PendingDeletion` rows from the `Get-Label` reads. Closes [#441](https://github.com/contoso/Purview-as-Code-Generic/issues/441). |

## If something goes wrong

- **`Validate dispatch inputs` fails with `prune_missing=true requires confirm_prune to equal 'confirm prune'`.**
  You typed the wrong token. Re-dispatch with the exact literal
  `confirm prune` (case-sensitive, two words, one space). No tenant
  mutation occurs on this failure.
- **`Conflict guard` fails with `Property drift on shared label '<name>'`.**
  The tenant has been edited outside the YAML for one of the shared
  labels. Do **not** force the prune. Reconcile drift first via
  [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
  (issue #143 flow) before retrying.
- **`Apply labels` fails partway through with `Remove-Label` errors.**
  The script aborts that label's removal but continues for unrelated
  orphans. Read the per-label result table at the bottom of the step.
  Common cause: an active retention or auto-apply policy still references
  the label. Resolve by detaching policies in the portal, then re-dispatch.
- **The `if: always()` Restore step did not run** (extremely rare —
  runner timeout / kill). The KV firewall is still open. Manually re-lock:

  ```pwsh
  az keyvault update --name kv-contoso-lab-01 `
    --public-network-access Disabled `
    --default-action Deny `
    --only-show-errors
  ```

## Compose with `direction_policy`

The `prune_missing` axis is **orthogonal** to the ADR 0029
`direction_policy` axis. The two compose into a five-row truth table
— every meaningful dispatch shape is named, nothing is implicit. The
table below is reproduced from
[ADR 0029 §Orthogonality with prune_missing](../adr/0029-source-of-truth-direction-policy.md#orthogonality-with-prune_missing):

| `direction_policy` | `prune_missing` | Tokens required | Shared-drift behavior | Orphan-tenant behavior |
|---|---|---|---|---|
| `audit` | n/a (ignored) | none | report only | report only |
| `portal-wins` (default) | `false` (default) | none | skip + auto-PR | report only |
| `portal-wins` | `true` | `confirm_prune='confirm prune'` | skip + auto-PR | `Remove-Label` |
| `repo-wins` | `false` | `confirm_overwrite='overwrite portal'` | `Set-Label` overwrites tenant | report only |
| `repo-wins` | `true` | both confirmation tokens | `Set-Label` overwrites tenant | `Remove-Label` |

A `direction_policy=repo-wins prune_missing=true` dispatch is the most
destructive shape this workflow supports: both shared-label property
drift AND orphan tenant labels are written / removed in one run. The
two confirmation tokens are independent — typing one does not unlock
the other.

```pwsh
gh workflow run deploy-labels.yml `
  --ref main `
  --field direction_policy=repo-wins `
  --field 'confirm_overwrite=overwrite portal' `
  --field prune_missing=true `
  --field 'confirm_prune=confirm prune'
```

A dispatch with only one token (or with either token mistyped) is
rejected by the `Validate dispatch inputs` step **before** Azure login
and **before** the Key Vault unlock window. No tenant mutation occurs
on a failed gate.

See [`labels-direction-policy.md`](labels-direction-policy.md) for the
full direction-policy ceremony, the auto-PR drift-back flow that fires
under `portal-wins`, and the `GITHUB_TOKEN` workaround for the
bot-opened drift-back PR.

## See also

- [`deploy-labels.yml`](../../.github/workflows/deploy-labels.yml) — the workflow itself.
- [`scripts/Deploy-Labels.ps1`](../../scripts/Deploy-Labels.ps1) — `-PruneMissing` switch lives here.
- [`labels-direction-policy.md`](labels-direction-policy.md) — the orthogonal ADR 0029 direction-policy ceremony.
- [ADR 0029 — Source-of-truth direction policy](../adr/0029-source-of-truth-direction-policy.md) — the binding contract that defines `direction_policy` and the composition with `prune_missing`.
- [`kv-temp-unlock.md`](kv-temp-unlock.md) — Key Vault firewall toggle recipe.
- [`local-cert-provisioning.md`](local-cert-provisioning.md) — local-cert IPPS auth path shipped in PR #437.
- [`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) §"Destructive writes require typed confirmation" — the source rule for the `confirm prune` token shape.
- [#441](https://github.com/contoso/Purview-as-Code-Generic/issues/441) — phantom-orphan investigation (closed by #450).
- [#450](https://github.com/contoso/Purview-as-Code-Generic/issues/450) — PendingDeletion filter fix in `Deploy-Labels.ps1`.
