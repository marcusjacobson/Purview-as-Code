---
description: "Walk through a Unified Catalog deploy for this repo: account-shape gate, first-run export-first check, then concepts and grant/revoke-aware policies, each its own -WhatIf -> confirm -> apply cycle."
mode: agent
---

# Deploy Unified Catalog (data plane)

Follow these steps in order. This prompt targets accounts that expose the Microsoft Purview
**Unified Catalog** data plane (ADR 0047), not the classic Data Map — see the account-shape gate
below before proceeding.

> **The Purview account name comes from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml)**
> — the single source of truth per [ADR 0012](../../docs/adr/0012-environment-parameters-file.md).
> Read `purviewAccountName` from that file and substitute it for the `<purviewAccountName>` token
> below. Never hardcode a tenant-specific account name in this prompt — a tailored copy changes it.

## Preconditions

1. Confirm the user is logged in: `az account show`.
2. Read the target Purview account (`purviewAccountName`) from
   [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml). Echo the value but do not echo
   full resource IDs.
3. **Confirm the account is a real, owner-confirmed governance target before probing its shape.**
   Run the read-only [`/discover-purview-account`](discover-purview-account.prompt.md) gate
   ([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md)) for that `purviewAccountName`.
   Proceed only on a **Pass** whose outcome is **a confirmed unified account** (tenant-level, or an
   account exposing only the unified data plane — row 3 of that prompt's Step 5 matrix). On any
   **Stop** outcome — a pay-as-you-go metering decoy, not-found-in-ARM / unconfirmed, not yet
   created, or a confirmed classic account in a subscription or tenant the sign-in cannot reach —
   stop here and follow that prompt's owner-action guidance; do not continue to the Step 1
   account-shape gate or any unified reconciler. If the gate passes as a **confirmed classic**
   account, this is the wrong track: redirect to [`/deploy-datamap`](deploy-datamap.prompt.md).
4. Confirm the active branch is a feature branch (not `main`).

> **The two gates layer; they do not duplicate.** This ADR 0048 precondition answers *"is this a
> real, owner-confirmed, non-decoy governance target?"* by enumerating ARM and confirming with the
> owner. The Step 1 ADR 0047 gate below answers a different question — *"which data plane does this
> account speak?"* — by issuing two data-plane GETs. `Get-PurviewAccountShape.ps1` never touches
> ARM, so it structurally cannot detect a pay-as-you-go metering decoy or an unconfirmed
> `purview-contoso-lab` placeholder. Run both, in this order.

## Step 1 — Account-shape gate (fail closed)

Run the read-only, account-shape detector before touching any unified reconciler:

```pwsh
./scripts/Get-PurviewAccountShape.ps1 -AccountName <purviewAccountName>
```

Route on the returned `Shape`:

- **`Unified`** — proceed to Step 2.
- **`Classic`** — stop. Tell the owner this account speaks the classic Atlas Data Map, not the
  unified data plane, and redirect them to [`/deploy-datamap`](deploy-datamap.prompt.md) instead.
- **`Ambiguous`** — both the classic and unified probes succeeded. This can legitimately happen
  (the caller may have access to both data planes). Stop and ask the owner to confirm which track
  this specific account is meant to run before proceeding — do not guess.
- **`Indeterminate`** — neither probe reached a conclusion, or an auth/permission error prevented
  one. **Never** treat this as `Unified` by default. Stop, surface the probe's `Note` field
  verbatim, and ask the owner to resolve the ambiguity (check sign-in scope, retry, or confirm the
  account manually) before re-running this gate.

This gate never writes and never mutates `infra/parameters/lab.yaml`.

## Step 2 — First run against an existing tenant?

If the account already holds live Unified Catalog state and `data-plane/unified-catalog/**` has
not yet been bootstrapped from it, stop and export first — otherwise every live object surfaces as
an `Orphan`:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName <purviewAccountName> -ExportCurrentState -Force
./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName <purviewAccountName> -ExportCurrentState -Force
```

The `-Force` overwrites the shipped sample YAML **on disk only** — never Purview. Review the diff,
open a PR, and merge it before continuing. See
[`docs/getting-started.md` §4a](../../docs/getting-started.md#4a-export-the-live-tenant-into-the-yaml-bootstrap-once-per-domain)
and the
[first-run contract](../instructions/powershell.instructions.md#first-run-against-an-existing-tenant-contract).

## Step 3 — Pass 1: concepts (business domains, data products, OKRs, critical data elements, terms)

`Deploy-UnifiedCatalog.ps1` reconciles all five concepts in a single pass — unlike the classic
track, there is no per-domain cycle here.

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName <purviewAccountName> -WhatIf
```

- Paste the drift report (`Create`, `Update`, `NoChange`, `Orphan`, `Conflict` counts) into the
  chat.
- If `Orphan` count is non-zero, stop. Do not propose `-PruneMissing`. Remind the user that pruning
  requires a `destructive`-labeled PR and a typed `confirm delete` reply.
- If `Conflict` count is non-zero, stop. Portal-edited content is in the way; ask the user whether
  to merge the change manually or overwrite with `-Force` (destructive).
- If only `Create` / `Update` / `NoChange` are non-zero, ask for a typed `apply concepts`
  confirmation.

Only after confirmation, run the apply:

```pwsh
./scripts/Deploy-UnifiedCatalog.ps1 -AccountName <purviewAccountName>
```

Capture the per-concept summary and report it in the chat. Do not proceed to Step 4 until this
pass reports zero failures.

## Step 4 — Pass 2: data access policies (grant/revoke-aware — stricter gating)

Run this pass only after Step 3 succeeds. Per
[ADR 0047 §Decision item 9](../../docs/adr/0047-unified-catalog-preview-api-coexistence.md#decision),
a policy `Create`/`Update` can **grant or revoke real tenant access**, so it gets the same
destructive-equivalent treatment as a delete, even when `-PruneMissing` is off.

```pwsh
./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName <purviewAccountName> -WhatIf
```

- The plan **must** show an explicit per-policy diff for every `Create`/`Update` that changes a
  subject or permission — treat any policy row in the plan the same way you would treat a prune:
  do not summarize it away, show the full per-policy detail in chat.
- If `Orphan` (revoke) count is non-zero, this is a permission **revocation**. Stop. Do not propose
  `-PruneMissing` without the same `destructive`-labeled PR and typed `confirm delete` reply the
  classic track requires.
- If `Conflict` count is non-zero, stop. A policy was last modified by a different principal; ask
  the user whether to merge manually or overwrite with `-Force` (destructive).
- For every remaining `Create`/`Update` (a grant), ask for an explicit typed `apply policies`
  confirmation — never infer consent from an earlier "apply concepts" confirmation in Step 3.

Only after confirmation, run the apply:

```pwsh
./scripts/Deploy-UnifiedCatalogPolicies.ps1 -AccountName <purviewAccountName>
```

Capture the per-policy summary (which subject gained or lost which role, on which policy) and
report it in the chat.

## Record evidence

- After both passes apply, paste every drift report and apply summary into the PR description per
  the pre-commit checklist in [`copilot-instructions.md`](../copilot-instructions.md).
- Remind the user that no `-PruneMissing` or `-Force` switches appear in any workflow file unless
  the PR is labeled `destructive`.

## Rules for the agent

- Do not run Step 4 (policies) if Step 3 (concepts) reported any failure.
- Do not invoke `-PruneMissing` or `-Force` without a typed destructive confirmation in the current
  turn, for either script.
- Do not treat a Step 3 `apply concepts` confirmation as consent for Step 4's policy grants/revokes
  — they are separate confirmations.
- Never coerce an `Ambiguous` or `Indeterminate` account-shape result into `Unified`. Stop and ask.
- Do not echo the bearer token, `Authorization` header, or response bodies that contain
  credentials.
- Do not invent script parameter names. If a script rejects a parameter, stop and surface the
  error.

Reference: [ADR 0047 — Unified Catalog preview REST API coexistence](../../docs/adr/0047-unified-catalog-preview-api-coexistence.md),
[Purview Unified Catalog REST API](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/),
[Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane),
[Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).
