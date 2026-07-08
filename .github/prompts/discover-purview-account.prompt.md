---
description: "Read-only ADR 0048 discovery-and-confirmation gate for the Purview account named in infra/parameters/lab.yaml: enumerate, classify, and stop before deploy if the target is unconfirmed, a metering decoy, or unified."
mode: agent
---

# Discover Purview account (ADR 0048 deploy-time gate)

Run this on demand — and as a `/deploy-datamap` precondition — to confirm that the
`purviewAccountName` in [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml) resolves to a
**confirmed classic governance account** before [`scripts/Connect-Purview.ps1`](../../scripts/Connect-Purview.ps1)
and the `Deploy-*.ps1` reconcilers run against it. It implements the read-only discovery-and-confirmation
gate ratified by [ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md), applied at deploy
time rather than tailoring time (the tailoring-time gate is `@operator-tenant` Step 1a).

This gate **never deploys, never writes, and never mutates the account or the parameters file.** The
read-only-default of the [MCP and tool-usage policy](../instructions/mcp-tool-usage.instructions.md) holds
throughout — it introduces no write, deploy, or new tool surface. All output is identifier-redacted to the
zero-GUID placeholder per the "Environment and identifier boundaries" section of
[`copilot-instructions.md`](../copilot-instructions.md).

## Preconditions

1. Confirm the user is signed in: `az account show`. If not, stop and ask them to run `az login` — discovery
   cannot enumerate subscriptions without a signed-in identity.
2. Read the candidate `purviewAccountName` from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml)
   — the single source of truth per [ADR 0012](../../docs/adr/0012-environment-parameters-file.md). Echo the
   **name** only; never echo full resource IDs.
3. If the value is still the shipped `purview-contoso-lab` placeholder, tell the owner the target was left
   unconfirmed by tailoring (`@operator-tenant` Step 1a) and that this gate will confirm resolution before
   any deploy proceeds.

## Step 1 — Enumerate (read-only, across every visible subscription)

Discovery enumerates the subscriptions the signed-in identity can see, then checks whether the candidate name
resolves to a `Microsoft.Purview/accounts` resource in any of them — **not just the default subscription**.
Prefer the shipped read-only helper, filtered to the candidate name:

```pwsh
./scripts/Find-PurviewAccount.ps1 -Name <purviewAccountName>
```

The helper wraps exactly this enumeration with identifier redaction and a conservative classification. It
returns one object per hit (`Name`, `ResourceGroup`, `Location`, `Sku`, `SubscriptionName`, `Classification`,
`Note`); the real `SubscriptionId` stays the zero-GUID placeholder unless the caller opts in. An **empty
result** means the candidate name does not resolve in ARM — the ADR 0048 "unconfirmed target" signal (Step 3).
Do not modify the helper; this prompt only calls it.

If the helper cannot run (a minimal harness with no `pwsh` / `az`), fall back to the raw GA, read-only Azure
CLI commands it wraps — never guess:

```pwsh
# Enumerate subscription NAMES only — never echo the real subscription ID into
# chat or any file (identifier redaction, below):
az account list --query "[].name" -o tsv
# then, per subscription the sign-in can see (the subscription ID is passed to
# --subscription for targeting but must not be pasted anywhere a human reads):
az resource list --subscription <subscription-id> --resource-type Microsoft.Purview/accounts `
  --query "[].{name:name, rg:resourceGroup, region:location, sku:sku.name}" -o table
```

References: [az account list](https://learn.microsoft.com/en-us/cli/azure/account#az-account-list),
[az resource list](https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-list). The exact
per-subscription iteration mechanism (`--subscription` vs `az account set`) is an implementation choice
([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md) §Decision item 2).

**Redaction:** echo discovery output into chat only after redacting real subscription / tenant / resource IDs to
the zero-GUID placeholder. Confirm the target with the owner by `SubscriptionName` and account name, never by a
GUID.

## Step 2 — Present each hit; warn that a PAYG meter is not a governance target

For every discovered `Microsoft.Purview/accounts` hit, present **name, resource group, region, and `sku`**, and
state this warning **verbatim**:

> A pay-as-you-go metering resource is **not** a governance target and must not be selected as
> `purviewAccountName`.

Microsoft Learn documents no property under `Microsoft.Purview/accounts` that reliably distinguishes a
governance account from a pay-as-you-go metering resource as of 2026-07-06 — the
[ARM schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts) exposes `sku.name`
and `tenantEndpointState` but no billing-meter discriminator. Classification therefore **falls back to explicit
owner confirmation**; do not invent a heuristic from `sku` or name shape
([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md) §Decision item 3).

## Step 3 — Handle "not found in ARM" as a first-class outcome, not an error

When the candidate name returns an empty result (or the subscriptions hold only a metering resource), **do not
fail and do not guess.** Ask the owner (single-select) which situation applies, and record the answer:

- (a) the tenant-level **Unified Catalog** at `purview.microsoft.com` — a SaaS single-tenant experience that
  Learn does **not** document as a `Microsoft.Purview/accounts` ARM resource
  ([data governance overview](https://learn.microsoft.com/en-us/purview/data-governance-overview));
- (b) a **classic account in another subscription or tenant** the current sign-in can't enumerate;
- (c) **not yet created.**

**Optional confirmation for (a):** offer to run the read-only, opt-in Unified Catalog tenant-reachability probe:

```pwsh
./scripts/Find-PurviewAccount.ps1 -ProbeUnifiedCatalog
```

This runs a single GET against the Unified Catalog preview data-plane `businessdomains` enumerate endpoint
([Business Domain - Enumerate](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate)).
It is tenant-scoped (no `-Name`/`-SubscriptionId` effect) and returns a `Classification` of
`UnifiedCatalogTenantReachable`, `UnifiedCatalogUnauthorized`, `UnifiedCatalogProbeIndeterminate`,
`UnifiedCatalogUnreachable`, or `UnifiedCatalogProbeSkipped`. `UnifiedCatalogTenantReachable` (HTTP 200) is a
**diagnostic reachability signal only** — it confirms the tenant exposes a reachable unified data plane, but it
is **not** proof that a specific account is unified, **not** proof that no classic account exists elsewhere, and
**not** the [ADR 0047](../../docs/adr/0047-unified-catalog-preview-api-coexistence.md) reconcile-time routing
decision. Its emitted `Name` (`unified-catalog (tenant default)`) must **never** be written to
`purviewAccountName`. Use the result to corroborate the owner's answer to (a), not to replace their confirmation
(ADR 0048 Addendum, 2026-07-08).

The answer drives Step 4 (routing) and the Step 5 stop decision
([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md) §Decision item 4).

## Step 4 — Confirm account type and route (classic vs unified)

Once the target is identified, record whether it is **classic** or **unified** and route:

- **Classic** (answers on the Atlas Data Map host `{account}.purview.azure.com`) → the shipped `Deploy-*.ps1`
  reconcilers and the [`/deploy-datamap`](deploy-datamap.prompt.md) export-first onboarding apply. This gate
  passes only for a **confirmed classic governance account**.
- **Unified** (tenant-level, or a new account exposing only the unified data plane) → **stop.** Flag that classic
  `Deploy-*.ps1` onboarding is blocked pending the
  [ADR 0047](../../docs/adr/0047-unified-catalog-preview-api-coexistence.md) unified reconcilers, and do not imply
  the `/deploy-datamap` export-first flow will work against it.

Learn documents no procedure for programmatically detecting classic vs unified as of 2026-07-06, so this is an
**owner-confirmed** determination (or, later, probe-assisted once the ADR 0047 reconcile-time account-shape probe
ships) — never inferred from a host string
([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md) §Decision item 5).

## Step 5 — Report the outcome and stop when unconfirmed

Report the ADR 0048 outcome-matrix result for the candidate name
([ADR 0048](../../docs/adr/0048-purview-account-discovery-gate.md) §Decision item 6):

| Discovery outcome | Gate result | Owner action |
|---|---|---|
| Confirmed classic governance account | **Pass** — safe to proceed to `/deploy-datamap` | Continue with classic `Deploy-*.ps1` export-first onboarding |
| Confirmed classic account in a sub/tenant the sign-in can't enumerate | **Stop** | The deploy identity must be able to reach that subscription/tenant before onboarding; re-run this gate once it can |
| Confirmed unified (tenant-level, or unified-only account) | **Stop** | Classic `Deploy-*.ps1` onboarding is blocked pending the ADR 0047 unified reconcilers |
| Only a pay-as-you-go metering resource discovered | **Stop** | Never select the meter as `purviewAccountName`; find the governance account |
| Not yet created | **Stop** | Create the account, then re-run this gate |

On any **Stop** outcome, surface the matching owner-action guidance above and **do not proceed to
`Connect-Purview.ps1` or any reconciler.** This gate reports and stops; it never edits
`infra/parameters/lab.yaml` and never runs a deploy.

## Rules for the agent

- Read-only only. Never run a write, deploy, `-PruneMissing`, or `-Force` command from this gate.
- Never modify [`scripts/Find-PurviewAccount.ps1`](../../scripts/Find-PurviewAccount.ps1) — this prompt calls it.
- Never edit [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml) — this gate reports; it does not
  rewrite the parameters file. Correcting an unconfirmed name is the owner's action (or `@operator-tenant`).
- Never echo a real subscription, tenant, or resource ID. Redact to `00000000-0000-0000-0000-000000000000`;
  confirm the target by `SubscriptionName` and account name.
- Never invent a governance-vs-metering or classic-vs-unified determination. Both are owner-confirmed
  (ADR 0048 §Decision items 3 and 5).
- If `-ProbeUnifiedCatalog` is run, never write its `unified-catalog (tenant default)` diagnostic label to
  `purviewAccountName` — it is a tenant-level reachability signal, not a confirmed account name (ADR 0048
  Addendum, 2026-07-08).
- On a **Stop** outcome, do not proceed to onboarding, even if asked to "continue" — the owner must resolve the
  target first.

Reference: [ADR 0048 — Purview account discovery-and-confirmation gate](../../docs/adr/0048-purview-account-discovery-gate.md),
[Microsoft.Purview/accounts](https://learn.microsoft.com/en-us/azure/templates/microsoft.purview/accounts),
[az account list](https://learn.microsoft.com/en-us/cli/azure/account#az-account-list),
[az resource list](https://learn.microsoft.com/en-us/cli/azure/resource#az-resource-list),
[Learn about data governance with Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-governance-overview),
[Business Domain - Enumerate](https://learn.microsoft.com/en-us/rest/api/purview/purview-unified-catalog/business-domain/enumerate).
