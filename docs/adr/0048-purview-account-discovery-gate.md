# 0048 — Purview account discovery-and-confirmation gate before tenant tailoring writes an account name

- **Status:** Accepted <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-07-06
- **Gates:** Complements [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) (which decided classic/unified *reconcile-time* coexistence); builds on [ADR 0012](0012-environment-parameters-file.md) (the `infra/parameters/<env>.yaml` source of truth), [ADR 0045](0045-template-kickoff-spinoff-model.md), and [ADR 0046](0046-tenant-placeholder-manifest.md) (the `@operator-kickoff` → `@operator-tenant` tailoring flow and its placeholder manifest). No pre-existing [`docs/project-plan.md`](../project-plan.md#8-open-question-adrs) §8 open-question row exists for this gap (the template ships §8 empty); this ADR itself creates the follow-up gate. Unblocks the discovery follow-up items — a `@operator-tenant` discover-and-confirm step, a `/discover-purview-account` prompt (or a `/deploy-datamap` precondition), and an optional read-only `scripts/Find-PurviewAccount.ps1` helper — each of which branches only after this ADR is Accepted.
- **Deciders:** @contoso

## Context

The tenant-tailoring flow is `@operator-kickoff` (decouple the copy, per [ADR 0045](0045-template-kickoff-spinoff-model.md)) → `@operator-tenant` (write tenant values, per [ADR 0046](0046-tenant-placeholder-manifest.md)). `@operator-tenant` Step 1 Q8 collects the **Purview account name** as free text and, on confirmation, writes it into every `purviewAccountName` surface named by [`tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml): [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml) (the [ADR 0012](0012-environment-parameters-file.md) source of truth), [`infra/main.bicepparam`](../../infra/main.bicepparam), the [`collections.yaml`](../../data-plane/collections/collections.yaml) `rootCollection`, and the onboarding docs. The value is also the account the [`/deploy-datamap`](../../.github/prompts/deploy-datamap.prompt.md) prompt reads back and feeds to [`scripts/Connect-Purview.ps1`](../../scripts/Connect-Purview.ps1) and every `Deploy-*.ps1` reconciler.

The current Q8 assumes the name the owner types (a) resolves to a real Microsoft Purview account and (b) is a **classic Data Map** account the shipped reconcilers — which target `{account}.purview.azure.com` — can drive. Against a real tenant, that assumption broke three ways at once:

1. **The governance account isn't discoverable via ARM.** The deploying identity's visible subscription contained no `Microsoft.Purview/accounts` governance resource. The account the owner actually governs was either the tenant-level Unified Catalog at `purview.microsoft.com` — which Microsoft Learn describes as a SaaS, single-tenant experience and does **not** document as a `Microsoft.Purview/accounts` ARM resource as of 2026-07-06 (see §Citations) — or a classic account in a different subscription/tenant the sign-in can't enumerate.
2. **A pay-as-you-go metering resource is a decoy.** In the motivating tenant, the one `Microsoft.Purview/accounts` resource that *was* discoverable was a pay-as-you-go billing meter in its own resource group and region — not the governance target, but the only thing a naïve `az resource list --resource-type Microsoft.Purview/accounts` scan of the default subscription returns. Naïve discovery therefore points the whole repo at the wrong resource.
3. **There is no classic-vs-unified branch.** Even once the right account is identified, tailoring has no step to determine whether it is classic Data Map or unified. The shipped reconcilers cannot drive a unified account ([ADR 0047](0047-unified-catalog-preview-api-coexistence.md)), and Q8 never surfaces this, so the owner is left with green infra params pointing at an account the tooling silently can't reconcile.

Net effect: tailoring "completes successfully" while `purviewAccountName` points at either a non-existent name or the billing meter, with **no signal to the owner** that the real target is unconfirmed.

### Relationship to ADR 0047 — a different gap, not a duplicate

[ADR 0047](0047-unified-catalog-preview-api-coexistence.md) decided that the classic Data Map track and a new unified track **coexist**, and that a deploy run selects a track by an *account-shape probe* at **reconcile time** (ADR 0047 §Decision items 3 and 10d, deferred to the reconciler follow-up). It does **not** address which account, of which type, in which subscription the *tailoring* step should target in the first place — the value that lands in `infra/parameters/lab.yaml` long before any reconciler runs. This ADR closes that earlier gap. The two are complementary: ADR 0047 routes an already-identified account to the right reconciler; this ADR identifies and confirms the account (and records its type) before a name is ever committed.

## Decision

We will **require `@operator-tenant` to run a read-only discovery-and-confirmation gate for the Purview account target before it writes `purviewAccountName` into any file**, and we will never write a guessed account name. Specifically:

1. **Discovery is mandatory; Q8 becomes discover-then-confirm, not free-text-guess.** `@operator-tenant` must attempt discovery and present the result for the owner to confirm before writing. A hand-typed name is accepted only as an explicit override the owner confirms against the discovery result, never as an unverified default.

2. **Enumerate across every visible subscription, read-only.** Discovery runs `az account list` to enumerate the subscriptions the signed-in identity can see, then `az resource list --resource-type Microsoft.Purview/accounts` **per subscription** — not just the default subscription. Both are GA, read-only Azure CLI commands (see §Citations). The exact per-subscription iteration mechanism (for example the CLI `--subscription` argument or `az account set`) is a follow-up implementation detail, not fixed here. This obeys the read-only-default in the [MCP and tool-usage policy](../../.github/instructions/mcp-tool-usage.instructions.md); no write, no deploy. Discovery output echoed into chat or written to any file must redact real subscription/tenant/resource IDs to the zero-GUID placeholder per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md).

3. **Classify each hit; warn that a PAYG meter is not a governance target.** For each discovered `Microsoft.Purview/accounts` resource, `@operator-tenant` presents name, resource group, region, and `sku` so the owner can distinguish a governance account from a pay-as-you-go billing meter. **Microsoft Learn does not document a programmatic property that reliably distinguishes a governance account from a pay-as-you-go metering resource under `Microsoft.Purview/accounts` as of 2026-07-06** — the [ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts) exposes `sku.name` (`Free` / `Standard`) and `tenantEndpointState` but no billing-meter discriminator. Discovery therefore **falls back to explicit owner confirmation** and must state the warning verbatim: a pay-as-you-go metering resource is **not** a governance target and must not be selected as `purviewAccountName`. Because Learn documents no property to make this call automatically, it is an owner-confirmed determination, not a repo-invented heuristic.

4. **Handle "not found in ARM" as a first-class outcome, not an error.** When enumeration returns no governance account (or only a metering resource), `@operator-tenant` does not fail and does not guess. It prompts the owner to record which situation applies:
   - (a) the tenant-level Unified Catalog at `purview.microsoft.com` (not an ARM resource);
   - (b) a classic account in another subscription or tenant the current sign-in can't see; or
   - (c) not yet created.

   The owner's answer is recorded and drives routing (item 5) and the placeholder decision (item 6).

5. **Route on account type.** Once the target is identified, `@operator-tenant` records whether it is classic or unified and routes accordingly:
   - **Classic** (answers on the Atlas Data Map host `{account}.purview.azure.com`) → proceed; the shipped `Deploy-*.ps1` reconcilers and the `/deploy-datamap` export-first onboarding flow apply.
   - **Unified** (tenant-level, or a new account that exposes only the unified data plane) → **flag that classic `Deploy-*.ps1` onboarding is blocked** pending the [ADR 0047](0047-unified-catalog-preview-api-coexistence.md) unified reconcilers, and do **not** imply the `/deploy-datamap` export-first flow will work against it. Reuse of the ADR 0047 reconcile-time account-shape probe is permitted **once that probe exists**, but discovery must not block on it — the classic/unified answer may come from the owner (item 4) until the probe ships.

   Consistent with ADR 0047, **Microsoft Learn does not document a procedure for programmatically detecting whether an account exposes the classic Data Map data plane or the unified data plane as of 2026-07-06**; the classic-vs-unified determination is therefore owner-confirmed (or, later, probe-assisted), never inferred from a hard-coded host string. This ADR does not itself implement endpoint probing — the host names above are definitional descriptors of each track, and until ADR 0047's probe ships the account shape is recorded from owner confirmation only.

6. **Never write a guessed account name.** If the target is unconfirmed after items 2–5, `@operator-tenant` leaves the shipped placeholder (`purview-contoso-lab`) in place, adds a clearly-marked "account unconfirmed — owner action required" note at the `purviewAccountName` surface, and stops short of claiming tailoring is complete for that field. It never commits a name that resolves to nothing or to a metering resource. This is the account-target analogue of the existing zero-GUID "unset" convention the manifest already uses for unresolved principals. The `purviewAccountName` outcome per discovery result is:

   | Discovery outcome | `purviewAccountName` action | Also record |
   |---|---|---|
   | Confirmed classic governance account (item 5) | Write the confirmed name to all `purviewAccountName` surfaces | Proceed with classic `Deploy-*.ps1` / `/deploy-datamap` export-first onboarding |
   | Confirmed classic account in a subscription/tenant the current sign-in can't enumerate | Write the owner-confirmed name | Deploy precondition: the deploy identity must be able to reach that subscription/tenant before onboarding |
   | Confirmed unified (tenant-level Unified Catalog, or a new account exposing only the unified data plane) | Leave the placeholder; do **not** write a classic account name | Classic `Deploy-*.ps1` onboarding blocked pending the ADR 0047 unified reconcilers |
   | Only a pay-as-you-go metering resource discovered | Treat as not-found; leave the placeholder | Never select the meter as `purviewAccountName` |
   | Not yet created | Leave the placeholder | Owner action: create the account, then re-run discovery |

7. **Scaffolding is follow-up work, gated on this ADR being Accepted.** This ADR decides and enumerates only. The gate is delivered as separate `@idea-intake` items, one at a time: (a) the `@operator-tenant` discover-and-confirm step (revised Q8 + a discovery sub-step) and the matching updates to [`tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml) notes; (b) a `/discover-purview-account` prompt, or a discovery **precondition** added to [`/deploy-datamap`](../../.github/prompts/deploy-datamap.prompt.md); (c) an optional read-only `scripts/Find-PurviewAccount.ps1` helper that wraps the item-2 enumeration and item-3 classification with identifier redaction. None branch before this ADR is Accepted, per the repo's "the ADR must ship as its own item first" rule.

## Consequences

**Easier**

- Tailoring can no longer silently commit an account name that resolves to nothing or to a billing meter; the owner gets an explicit confirmation gate and a clear "unconfirmed" state instead of a false green.
- The classic-vs-unified answer is captured at tailoring time, so a unified-only tenant is told up front that classic `Deploy-*.ps1` onboarding is blocked pending the ADR 0047 reconcilers — rather than discovering it as a wall of `Orphan`/connection failures on first deploy.
- The discovery contract is read-only and reuses commands the repo already relies on; it adds no new credential and no write surface.
- It dovetails with ADR 0047: the reconcile-time account-shape probe, once built, becomes an optional accelerator for item 5 rather than a prerequisite.

**Harder**

- `@operator-tenant` Q8 gains a discovery sub-step and branch logic; the tailoring interview is no longer a pure free-text pass. The follow-up item that implements it must keep the read-only-default and Step-4 confirmation guarantees intact.
- Discovery depends on the signed-in identity's subscription visibility. An identity that cannot see the governance account's subscription still lands in the item-4 "not found in ARM" path — the gate surfaces the ambiguity honestly rather than hiding it, but it cannot resolve a cross-tenant account the sign-in can't reach.
- A pay-as-you-go metering resource cannot be filtered out programmatically today (item 3), so the owner remains in the loop for that call until Microsoft documents a discriminator.

**Security posture** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md))

- **#1 (no secrets in source)** and **#10 (OWASP-aware, no token logging)** — upheld. Discovery is read-only and its output is identifier-redacted before it reaches chat or any file.
- **#9 (idempotent, reversible, auditable)** — strengthened. Refusing to write a guessed name, and marking an unconfirmed target explicitly, keeps the tailoring diff honest and reviewable.
- The gate introduces no new identity, role, or network surface; it only reads what the signed-in identity can already enumerate.

## Alternatives considered

1. **Do nothing — keep Q8 as free text.** Rejected. This is exactly the status quo that produced the three failure modes in §Context: a green tailoring that points at a non-existent name or a billing meter with no owner signal.

2. **Auto-pick the first `Microsoft.Purview/accounts` hit in the default subscription.** Rejected. The default subscription may contain only the pay-as-you-go metering resource (§Context item 2), so auto-pick actively selects the decoy. It also ignores accounts in other visible subscriptions and the tenant-level unified account that isn't an ARM resource at all.

3. **Programmatically classify governance vs metering from the ARM payload and skip owner confirmation.** Rejected as not grounded. Microsoft Learn documents no `Microsoft.Purview/accounts` property that reliably makes this distinction as of 2026-07-06 (item 3); inventing a heuristic from `sku` or name shape would violate the [Microsoft Learn grounding rule](../../.github/copilot-instructions.md) and could silently mis-select.

4. **Fold discovery into the ADR 0047 reconcile-time account-shape probe and do nothing at tailoring time.** Rejected. The probe runs at deploy time against an already-chosen account; by then `purviewAccountName` is committed to `infra/parameters/lab.yaml`. The gap this ADR closes is *before* a name is written. The probe is complementary (item 5), not a substitute.

5. **Block tailoring entirely until a governance account exists.** Rejected. It is legitimate to tailor a copy before the account is created (§Context item 4c) — e.g. provisioning infra first. A hard block would break that flow; the item-6 "unconfirmed, owner action required" marker preserves it while staying honest.

## Citations

- [az account](https://learn.microsoft.com/en-us/cli/azure/account) — fetched 2026-07-06. `az account list` is GA and returns "a list of subscriptions for the logged in account"; grounds the per-subscription enumeration in §Decision item 2.
- [az resource](https://learn.microsoft.com/en-us/cli/azure/resource) — fetched 2026-07-06. `az resource list` ("List resources.") is GA; grounds the `--resource-type Microsoft.Purview/accounts` enumeration in §Decision item 2.
- [Microsoft.Purview/accounts — Bicep, ARM template & Terraform AzAPI reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts) — fetched 2026-07-06. Documents `sku.name` (`Free` / `Standard`) and `tenantEndpointState` (`Disabled` / `Enabled` / `NotSpecified`) and exposes no governance-vs-metering discriminator; grounds the §Decision item 3 fall-back-to-owner-confirmation stance.
- [Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview) — fetched 2026-07-06. States Unified Catalog is "a software as a service (SaaS) experience based on a single-tenant model"; grounds the §Context statement that the tenant-level unified experience is not an ARM resource.
- [ADR 0047 — Unified Catalog preview API coexistence](0047-unified-catalog-preview-api-coexistence.md) — the reconcile-time classic/unified routing decision this ADR complements; records that Learn documents no programmatic account-shape detection procedure as of 2026-07-06.
- [ADR 0012 — Environment parameters file](0012-environment-parameters-file.md) — establishes `infra/parameters/lab.yaml` as the single source of truth for `purviewAccountName`.
- [ADR 0045 — Template kickoff and spin-off model](0045-template-kickoff-spinoff-model.md) and [ADR 0046 — Tenant placeholder manifest](0046-tenant-placeholder-manifest.md) — the `@operator-kickoff` → `@operator-tenant` tailoring flow and the manifest that maps `purviewAccountName` into its surfaces.
- [`.github/instructions/mcp-tool-usage.instructions.md`](../../.github/instructions/mcp-tool-usage.instructions.md) — the read-only-default the discovery gate obeys.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Grounding — Microsoft Learn is the central source of truth" and "Environment and identifier boundaries" (identifier redaction) applied throughout.

## References

- **[az account](https://learn.microsoft.com/en-us/cli/azure/account)**
  Fetch date: 2026-07-06
  > "az account list — Get a list of subscriptions for the logged in account. By default, only 'Enabled' subscriptions from the current cloud is shown."
- **[az resource](https://learn.microsoft.com/en-us/cli/azure/resource)**
  Fetch date: 2026-07-06
  > "az resource list — List resources." (Core, GA)
- **[Microsoft.Purview/accounts — Bicep, ARM template & Terraform AzAPI reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts)**
  Fetch date: 2026-07-06
  > AccountSku `name`: "Gets or sets the sku name." Value: `'Free'` `'Standard'`. AccountProperties `tenantEndpointState`: "Gets or sets the state of tenant endpoint." Value: `'Disabled'` `'Enabled'` `'NotSpecified'`.
- **[Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview)**
  Fetch date: 2026-07-06
  > "Unified Catalog is a searchable catalog of your scanned data … The catalog is a software as a service (SaaS) experience based on a single-tenant model."
