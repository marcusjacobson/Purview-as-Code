# 0046 — Tenant placeholder manifest for template tailoring

- **Status:** Accepted <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
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

A follow-up dev-tenant dry run surfaced three further coupled defects the first pass missed:

- **Operational prompts embedded functional tenant literals.** [`deploy-infra.prompt.md`](../../.github/prompts/deploy-infra.prompt.md), [`deploy-datamap.prompt.md`](../../.github/prompts/deploy-datamap.prompt.md), [`add-classification.prompt.md`](../../.github/prompts/add-classification.prompt.md), [`add-data-source.prompt.md`](../../.github/prompts/add-data-source.prompt.md), and [`build-item.prompt.md`](../../.github/prompts/build-item.prompt.md) are excluded from tailoring as `intentionalSamples`, yet they carried copy-paste operational commands with a hardcoded resource group, region, Purview account name, and tenant domain — wrong on any tailored copy.
- **Two tenant surfaces only the residual scan caught.** The [`.github/CODEOWNERS`](../../.github/CODEOWNERS) line-1 header slug `(contoso-lab)` (the entry listed only `codeownersHandle`), and the bare `contoso` in the [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) Squad hard-rules "lab owner identity" bullet (which sits outside the declared env-boundary `block`), were absent from the Step 5 edit list — so an operator following only Step 5 (not the Step 6 scan) would ship them unreplaced.

## Decision

We will add a single-source, machine-readable **tenant placeholder manifest** at [`.github/agents/tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml), co-located with the operators and the [`INTERACTION-MENUS.md`](../../.github/agents/INTERACTION-MENUS.md) contract it resembles. Both operators consume it. Specifically:

1. **`tokens`** — an ordered, longest-match-first list of placeholder strings. Each token names the Step 1 interview field that supplies its replacement (never a literal real value). The order guarantees `purview-contoso-lab` is replaced before `contoso-lab`, which is replaced before the bare `contoso`, so a short token can never corrupt a longer one.

2. **`tenantSurfaces`** — the authoritative Step 5 edit list. Every file whose placeholders must be replaced for the copy to deploy, including the previously-missed module tag defaults, with per-file notes for MIXED files (`.github/copilot-instructions.md`, `README.md`, `naming.instructions.md`, `getting-started.md`) that hold both a tenant surface and intentional convention prose. `infra/main.json` is flagged `regenerate: true` — rebuilt by `az bicep build`, never hand-edited.

3. **`intentionalSamples`** — git pathspec excludes for the Step 6 residual scan. Scanning everything *except* these paths means any remaining match is a genuine missed tenant surface, not sample-data noise. `scripts/**` is excluded (its `contoso` refs are `.EXAMPLE` blocks, `.PARAMETER` text, and the intentional `RedactedIdentityPattern`); `.github/workflows/**` is excluded from the *broad* scan because cosmetic prose dominates, and its few functional values are verified by a separate targeted `functionalWorkflowScan` instead.

4. **`deTemplate`** — the literal banner/comment markers that become misleading on a tailored repo. [`operator-tenant`](../../.github/agents/operator-tenant.agent.md) strips them in Step 5; [`operator-kickoff`](../../.github/agents/operator-kickoff.agent.md) uses their *presence* to confirm a copy is still an un-tailored template (replacing the fragile "grep for `contoso`" heuristic).

5. **Operational prompts read functional tenant values from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml).** Rather than embed a resource group, region, account name, or tenant domain, the deploy/add prompts instruct the reader to read `resourceGroupName`, `location`, `purviewAccountName`, and `automation.tenantDomain` from the single source of truth ([ADR 0012](0012-environment-parameters-file.md)) and substitute a `<token>`. This keeps `.github/prompts/**` a genuine `intentionalSamples` exclusion: after this change the prompts hold only synthetic examples, so **no** `functionalPromptScan` is needed — in contrast to the `.github/workflows/**` surface, which legitimately retains functional literals and is therefore covered by the targeted `functionalWorkflowScan`.

6. **`tenantSurfaces` closes the two scan-only surfaces.** The [`.github/CODEOWNERS`](../../.github/CODEOWNERS) entry gains `ownerSlug` (the line-1 header slug), and the [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) entry gains `githubOrg` with its `block` widened to name the Squad hard-rules owner-identity line. Step 5 and the Step 6 residual scan now agree — after tailoring, the only expected `copilot-instructions.md` matches are the intentional identifier-convention-table rows.

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

## Amendment — 2026-07-05 (operator hardening)

Two follow-up loose ends from the manifest work were closed together (they are coupled — the first removes a surface the second scans for):

1. **The `idea-intake-autoadd.yml` owner-login gate is now data-driven, not a tenant surface.** It previously hardcoded `if: github.event.issue.user.login == 'contoso'`, which Problem #2 above listed as a functional workflow surface the operator had to replace. It now reads the `OWNER_APPROVAL_LOGIN` repository variable — the same variable [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) already uses — via a least-privilege two-job split (a no-write `gate` job computes owner-match; the `issues: write` labelling job runs only when the gate passes). On an unset variable it emits a `::warning::` and skips rather than failing, because the workflow fires on every issue open (a hard failure would litter a public template's timeline). Consequences: the manifest's `.github/workflows/**` surface no longer lists `githubOrg`, and `functionalWorkflowScan.pattern` no longer includes the `user\.login == .contoso` clause. Reference: [Store information in variables](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables), [Understanding the risk of script injections](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections).

2. **The Step 6 scan commands are single-sourced from the manifest.** The residual/functional `git grep` commands were hardcoded in [`operator-tenant.agent.md`](../../.github/agents/operator-tenant.agent.md) Step 6, duplicating `intentionalSamples` and free to drift from it. The manifest now carries structured `residualScan: { pattern }` and `functionalWorkflowScan: { pattern, pathspec }` blocks (previously prose comments), and `schemaVersion` is bumped `1 → 2`. A new read-only generator, [`scripts/Get-TenantResidualScanCommand.ps1`](../../scripts/Get-TenantResidualScanCommand.ps1), assembles the ready-to-run commands from those fields plus `intentionalSamples`; it asserts `schemaVersion >= 2` and fails loudly otherwise. Step 6 now runs the generator (with a manifest-based fallback for harnesses that cannot run it — never a re-pasted list), and a drift-guard Pester test ([`tests/scripts/Get-TenantResidualScanCommand.Tests.ps1`](../../tests/scripts/Get-TenantResidualScanCommand.Tests.ps1)) asserts the emitted commands stay faithful to the manifest. This makes the "Harder" consequence above (the manifest must stay in sync with its consumers) structurally enforced for the scan rather than relying on a hand-copied list.

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
