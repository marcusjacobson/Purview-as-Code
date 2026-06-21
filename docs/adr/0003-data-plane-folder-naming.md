# 0003 — Rename `datamap/` folder to `data-plane/`

- **Status:** Accepted
- **Date:** 2026-04-18
- **Gates:** Wave 0 CI/CD hygiene (prerequisite to every Wave 1 / 2 / 3b / 4 folder creation under the data-plane root). Not a numbered §8 Q-item.
- **Deciders:** @contoso

## Context

The top-level folder for data-plane desired state has been `datamap/` since the repo was scaffolded. That name is misleading for three reasons:

1. **"Data Map" is a specific Microsoft Purview product area.** It covers collections, glossary, classifications, data sources, scans, and data-plane policies, per the [Microsoft Purview Data Map REST APIs reference](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/). Those six areas are Wave 3a in [docs/project-plan.md](../project-plan.md). Every other wave — Wave 1 Information Protection, Wave 2 DLP / Audit / IRM / Records / Communication Compliance / eDiscovery, Wave 3b Unified Catalog, Wave 4 DSPM — ships YAML into sibling folders under the same top-level directory but is **not** part of the Data Map product area.

2. **The folder already holds non-Data-Map content.** [ADR 0002](0002-administrative-units.md) landed Microsoft Entra administrative units under `datamap/administrative-units/`. Entra AUs are [Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit) directory objects, not a Data Map REST entity.

3. **The naming mismatch will compound.** Every Wave 1 / 2 commit would add more non-Data-Map YAML under a folder called `datamap/`. Renaming now is cheap; renaming once Wave 1 has landed label taxonomies, label policies, auto-label policies, and a SIT catalog is expensive.

The workflow that orchestrates the folder was renamed from `deploy-datamap.yml` to `deploy-data-plane.yml` in [PR #6](https://github.com/contoso/Purview-as-Code-Generic/pull/6) (commit `0a43622`) for exactly this reason. This ADR completes the rename at the folder level so the workflow name, folder name, and two-plane vocabulary in [`AGENTS.md`](../../AGENTS.md) all say the same thing.

## Decision

We will rename the `datamap/` folder to `data-plane/` via `git mv`, preserving file history.

We will also rename the companion instruction file `.github/instructions/datamap-yaml.instructions.md` to `data-plane-yaml.instructions.md` and update its `applyTo:` glob from `datamap/**/*.yaml,datamap/**/*.yml` to `data-plane/**/*.yaml,data-plane/**/*.yml`. Instruction-file names continue to match the folder they describe.

All repo-internal references to the `datamap/` path are updated in the same PR, including:

- Every `Deploy-*.ps1` default `$Path` parameter and docstring.
- Every `applyTo:` glob in `.github/instructions/*.instructions.md`.
- Every project-layout row and change-routing bullet in `.github/copilot-instructions.md`.
- Every Wave-1 / Wave-2 / Wave-3 / Wave-4 path reference in [docs/project-plan.md](../project-plan.md).
- The planes table in [`README.md`](../../README.md), [`AGENTS.md`](../../AGENTS.md), and [`docs/architecture.md`](../architecture.md).
- `.github/CODEOWNERS`, PR template, issue templates, and all prompt files.

We will **not** rename:

- Microsoft REST URL path segments (`https://<acct>.purview.azure.com/datamap/api/atlas/v2`, `learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/...`). Those are Microsoft's product strings, not our folder name.
- The `/deploy-datamap` chat-prompt invocation name in `.github/copilot-instructions.md` (intentional per the Item A decision that produced PR #6; prompt body is scoped to the 6-domain Data Map orchestration only).
- The illustrative `operator-datamap.agent.md` example in `.github/instructions/agents.instructions.md`. That is a worked example of the naming pattern for custom agents; a real future agent targeting the Data Map subset would be named consistently with the example.
- The existing commit-message scope tokens (`collections`, `glossary`, `classifications`, `data-sources`, `scans`, `policies`) in [`commit-message.instructions.md`](../../.github/instructions/commit-message.instructions.md). Only the right-hand "When to use" column is updated from `datamap/collections/**` to `data-plane/collections/**`. No scope is added, renamed, or removed.

## Consequences

**Easier**

- Adding Wave 1 `data-plane/information-protection/`, Wave 2 `data-plane/dlp/`, Wave 3b `data-plane/unified-catalog/`, and Wave 4 `data-plane/dspm/` folders without the recurring "why is this under `datamap/` if it isn't Data Map?" question in every review.
- Cross-referencing the two planes. `infra/` is the control plane; `data-plane/` is the data plane. Reviewer cognitive load drops.
- Aligning the commit-message convention. The repo-wide scope token `data-plane` (for cross-cutting changes under `data-plane/**`) can be added in a later PR without also having to rename the folder it targets.

**Harder**

- External systems that pin to the old path break silently. No such systems are known in this repo today. If one is discovered post-merge, a follow-up PR or symlink is the remediation.
- Any in-flight branch (none exist at time of writing beyond the branch this ADR lives on) will need to rebase and hand-merge the rename.
- Browser bookmarks, local notes, and chat transcripts that reference `datamap/<x>.yaml` become stale. Acceptable cost given the Wave 1 timing.

**Security posture**

- Unchanged. This is a pure rename. No identity, secret, role assignment, endpoint, public-network-access setting, or permission is altered. The [non-negotiable security principles](../../.github/instructions/security.instructions.md) stand as written; only the folder-name substring inside those principles shifts.

## Alternatives considered

1. **Do nothing — keep `datamap/`.** Rejected because (a) Wave 1 will land ~8 new non-Data-Map YAML files under `datamap/information-protection/`, making the misnomer permanent and visible in every PR diff for months, and (b) [ADR 0002](0002-administrative-units.md) has already added non-Data-Map content (administrative units) and that mismatch is already on `main`.

2. **Rename to something else (`solutions/`, `policies/`, `catalog/`).** Rejected. `solutions/` collides with Microsoft's marketing term for Purview Solutions (a superset of what this repo covers). `policies/` is a collision with the existing `data-plane/policies/` subfolder (Purview DevOps / data owner policies). `catalog/` is a collision with Wave 3b's Unified Catalog. `data-plane/` is the term already used throughout [`AGENTS.md`](../../AGENTS.md), [`README.md`](../../README.md), [`docs/architecture.md`](../architecture.md), and the renamed [`deploy-data-plane.yml`](../../.github/workflows/deploy-data-plane.yml) workflow.

3. **Defer until Wave 1 starts.** Rejected. The incremental cost of renaming grows with every new file committed under the old name. Wave 1 is the largest single wave in the plan (four YAML files plus four deploy scripts plus four Draft-07 schemas); renaming once those are in place doubles the edit surface.

## Citations

- [Microsoft Purview Data Map REST APIs](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/) — establishes "Data Map" as a bounded Microsoft product area.
- [What is Microsoft Purview?](https://learn.microsoft.com/en-us/purview/purview) — positions Data Map, Information Protection, DLP, IRM, and related solutions as peer solution areas.
- [ADR 0002 — Entra administrative units in this repo](0002-administrative-units.md) — first non-Data-Map content added to the folder.
- Related PRs: [#6 — rename `deploy-datamap.yml` → `deploy-data-plane.yml`](https://github.com/contoso/Purview-as-Code-Generic/pull/6), [#7 — add AU step to `deploy-data-plane.yml`](https://github.com/contoso/Purview-as-Code-Generic/pull/7).
