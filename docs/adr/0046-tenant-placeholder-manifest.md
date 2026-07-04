# 0046 — Tenant placeholder manifest for template tailoring

- **Status:** Proposed <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-07-04
- **Gates:** Unblocks reliable `@operator-tenant` tailoring runs (the clone → tailor flow ratified by [ADR 0045](0045-template-kickoff-spinoff-model.md)). No `docs/project-plan.md` Progress-checklist row — this is template-maintenance infrastructure.
- **Deciders:** @marcusjacobson

## Context

This repository ships as a tenant-neutral template. The [`@operator-tenant`](../../.github/agents/operator-tenant.agent.md) agent tailors a fresh copy by replacing Microsoft's documented fictitious placeholders (`contoso`, `contoso.onmicrosoft.com`, `contoso-lab`, zero-GUID) with a consumer's real values, per the "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) and [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md).

A dev-tenant dry run of the operators surfaced three coupled problems that all trace back to the tailoring being defined only as prose inside the agent body:

1. **`contoso-lab` is overloaded.** It is simultaneously the owner/workload slug (`tags.owner`), embedded in the Purview account name (`purview-contoso-lab`), the Key Vault (`kv-contoso-lab-01`), and Log Analytics (`log-contoso-lab`), and it appears in prose. A naive find/replace corrupts the compound names. A hyphenless `contosolab` variant also exists in data-plane sample resource names (`stcontosolabblob`, `sql-contosolab-demo`). Correct tailoring requires **context-sensitive, longest-match-first** replacement, which the agent previously had to hand-craft on every run.

2. **No machine-readable placeholder inventory.** The [`operator-tenant`](../../.github/agents/operator-tenant.agent.md) Step 5 edit list was an inline bullet list. It omitted real tenant surfaces — the `owner: 'contoso-lab'` default tags in [`infra/main.bicep`](../../infra/main.bicep), [`infra/modules/law.bicep`](../../infra/modules/law.bicep), and [`infra/modules/keyvault.bicep`](../../infra/modules/keyvault.bicep); the compiled [`infra/main.json`](../../infra/main.json); and the **functional** workflow values (the `KEY_VAULT_NAME` / `TENANT_DOMAIN` `env:` defaults in `deploy-data-plane.yml`, `kv-temp-unlock.yml`, `validate-oidc-auth.yml`, and the hardcoded owner-login gate in `idea-intake-autoadd.yml`). Missed surfaces mean a copy that still carries the template's identity after tailoring — a data-plane deploy that targets the wrong Key Vault, or an auto-add gate that never matches the real owner.

3. **The residual scan floods.** Step 6 ran `git grep -nEi 'contoso|onmicrosoft\.com|OWNER-PLACEHOLDER'` excluding only `docs/adr` and `CHANGELOG.md`. Because `contoso` appears in ~150 files — nearly all intentional sample data, rule docs, and template onboarding guides — the scan could not distinguish a genuine *missed tenant surface* from *intentional fictitious sample data*, so it surfaced dozens of false positives the owner had to triage by hand.

The template also leaves misleading banners after tailoring: the README "tenant-neutral template" blockquote and the `infra/parameters/lab.yaml` "TEMPLATE — replace the placeholder values below" header comment both remain, now false on a tailored repo.

## Decision

We will add a single-source, machine-readable **tenant placeholder manifest** at [`.github/agents/tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml), co-located with the operators and the [`INTERACTION-MENUS.md`](../../.github/agents/INTERACTION-MENUS.md) contract it resembles. Both operators consume it. Specifically:

1. **`tokens`** — an ordered, longest-match-first list of placeholder strings. Each token names the Step 1 interview field that supplies its replacement (never a literal real value). The order guarantees `purview-contoso-lab` is replaced before `contoso-lab`, which is replaced before the bare `contoso`, so a short token can never corrupt a longer one.

2. **`tenantSurfaces`** — the authoritative Step 5 edit list. Every file whose placeholders must be replaced for the copy to deploy, including the previously-missed module tag defaults, with per-file notes for MIXED files (`.github/copilot-instructions.md`, `README.md`, `naming.instructions.md`, `getting-started.md`) that hold both a tenant surface and intentional convention prose. `infra/main.json` is flagged `regenerate: true` — rebuilt by `az bicep build`, never hand-edited.

3. **`intentionalSamples`** — git pathspec excludes for the Step 6 residual scan. Scanning everything *except* these paths means any remaining match is a genuine missed tenant surface, not sample-data noise. `scripts/**` is excluded (its `contoso` refs are `.EXAMPLE` blocks, `.PARAMETER` text, and the intentional `RedactedIdentityPattern`); `.github/workflows/**` is excluded from the *broad* scan because cosmetic prose dominates, and its few functional values are verified by a separate targeted `functionalWorkflowScan` instead.

4. **`deTemplate`** — the literal banner/comment markers that become misleading on a tailored repo. [`operator-tenant`](../../.github/agents/operator-tenant.agent.md) strips them in Step 5; [`operator-kickoff`](../../.github/agents/operator-kickoff.agent.md) uses their *presence* to confirm a copy is still an un-tailored template (replacing the fragile "grep for `contoso`" heuristic).

The manifest contains only fictitious placeholders and interview-field references — never a real tenant value — so it is safe to commit and upholds the no-real-identifiers rule.

## Consequences

**Easier.**

- Tailoring is deterministic: the agent applies a fixed token order and a fixed surface list instead of re-deriving both on every run. Two runs on the same inputs produce the same diff.
- The residual scan becomes actionable — near-zero false positives, so a leftover match is a real signal.
- Previously-missed surfaces (module tag defaults, `main.json`) are now closed, so a tailored copy no longer silently retains `contoso-lab` in its resource tags.
- `operator-kickoff`'s "is this still a template?" check has a stable marker (`deTemplate`) instead of a `contoso` grep that a partially-tailored copy could fool.

**Harder.**

- The manifest is a new artifact that must stay in sync with the surfaces it lists. If a future PR adds a new tenant-specific value (a new resource name, a new identity), it must add the token and surface here, or tailoring will miss it. This ADR makes the manifest the single place that has to change, which is strictly better than the prior state where the knowledge was scattered across agent prose.

**Security posture.** Upholds [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #1 (no secrets/real identifiers in source) — the manifest holds only fictitious placeholders and field names. Reinforces the "Environment and identifier boundaries" rule by making the tenant-surface vs intentional-sample distinction explicit and enforceable rather than implicit.

## Alternatives considered

**Alternative A: Keep the inline prose edit list in the agent body.** Reject. It is exactly what produced the missed surfaces and the flooding scan; prose is not machine-readable, so ordering and exclusions are re-derived (and re-mis-derived) every run.

**Alternative B: A generated `sed`/PowerShell replace script instead of a declarative manifest.** Reject. A script hides the ordering and surface decisions inside imperative code, is harder to review in a diff, and tempts a repo-wide blind replace — the corruption failure mode this ADR exists to prevent. A declarative manifest keeps the operator's read-only-by-default, preview-first discipline (MCP/tool-usage policy) intact.

**Alternative C: Do nothing / keep the status quo.** Reject. The status quo demonstrably produced a corrupt-prone replace order, missed tenant surfaces, and a residual scan the owner could not trust — all reported from a real dev-tenant run.

## Citations

- **[Create a parameters file for Bicep deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files)**
  Fetch date: 2026-07-04
  > "Learn how to create Bicep parameters files instead of passing parameters as inline values in your script."
- **[gitglossary — pathspec](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-pathspec)**
  Fetch date: 2026-07-04
  > "Pattern used to limit paths in Git commands."
- [Placeholder examples (Microsoft Writing Style Guide)](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples)
- [ADR 0045 — Template kickoff and spin-off consumption model](0045-template-kickoff-spinoff-model.md)
- [ADR 0010 — Automation identity subject model](0010-automation-identity-subject-model.md)
- [ADR 0012 — Environment parameters file](0012-environment-parameters-file.md)
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries".
- [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) — synthetic-data rule.
