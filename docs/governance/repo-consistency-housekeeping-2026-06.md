# Repo consistency housekeeping — 2026-06

> Read-only consistency scan of the Purview-as-Code repo captured on 2026-06-18.
> Records the findings and sequences the corrective split pull requests. This
> document performs no fixes; each corrective change ships as its own branch and
> pull request per the roadmap below. Tracking issue: #668.

## Run metadata

| Field | Value |
|---|---|
| Date | 2026-06-18 |
| Branch | `docs/repo-consistency-housekeeping-plan` |
| Tracking issue | #668 |
| Scope | Documentation and meta plane only (`docs/**`, `.github/**`, `README.md`) |
| Trigger | Accumulated drift after the DevOps-policies reconciler retirement ([ADR 0038](../adr/0038-devops-policies-reconciler-retirement.md)) and ongoing v2 feature work |

> **No behavior change.** This sweep touches documentation, instruction files, and
> the top-level README only. No `infra/` or `data-plane/` change is in scope.

## Summary

| Bucket | Concern | Disposition |
|---|---|---|
| A | Stale references to the retired DevOps-policies surface | Fix — Item 2 |
| B | ADR index out of sync | Fix — Item 3 |
| C | Top-level README stale | Fix — Item 4 |
| D | Minor / no-action observations | Documented only |

## Bucket A — stale DevOps-policies references

[ADR 0038](../adr/0038-devops-policies-reconciler-retirement.md) retired the DevOps-policies
reconciler and deleted `scripts/Deploy-Policies.ps1`, `data-plane/policies/`, and
`tests/scripts/Deploy-Policies.Tests.ps1`, and removed the `Deploy policies` workflow step.
Eight references to the deleted artifacts remain and now resolve to nothing.

| # | Location | Problem |
|---|---|---|
| A1 | [`docs/project-plan.md`](../project-plan.md) section 3 feature inventory | DevOps-policies row points at deleted `data-plane/policies/policies.yaml` and `Deploy-Policies.ps1` |
| A2 | [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) project-layout table | Lists `data-plane/policies/` folder with a dead `policies.yaml` link |
| A3 | [`README.md`](../../README.md) repository-layout tree | Shows deleted `policies/` folder and `Deploy-Policies.ps1` |
| A4 | [`.github/instructions/build-deploy.instructions.md`](../../.github/instructions/build-deploy.instructions.md) | Canonical command runs the deleted `./scripts/Deploy-Policies.ps1 -WhatIf` |
| A5 | [`.github/instructions/data-plane-yaml.instructions.md`](../../.github/instructions/data-plane-yaml.instructions.md) | DevOps / data-owner guidance references `data-plane/policies/policies.yaml` |
| A6 | [`.github/instructions/commit-message.instructions.md`](../../.github/instructions/commit-message.instructions.md) | `policies` allowed-scope row maps to the deleted `data-plane/policies/**` |
| A7 | [`.github/instructions/powershell.instructions.md`](../../.github/instructions/powershell.instructions.md) | References the deleted `Deploy-Policies.ps1` |
| A8 | [`.github/prompts/deploy-datamap.prompt.md`](../../.github/prompts/deploy-datamap.prompt.md) | Deploy step 6 still names `Policies` as a Data Map deploy stage |

Fix direction: annotate the section 3 inventory row as retired (cite ADR 0038) rather than
delete it, so the historical mapping stays legible; remove or correct the remaining seven
references. Immutable history (ADR 0003, archived v1 plan) is excluded — see below.

## Bucket B — ADR index out of sync

[`docs/adr/README.md`](../adr/README.md) "Current ADRs" table lists 16 ADRs, but `docs/adr/`
holds 38 numbered ADRs (`0001`–`0042`, with an intentional `0004`–`0007` gap). 22 ADRs are
absent from the index despite the README's own process rule ("On merge, update the table
above in the same PR").

Missing from the index: `0013`, `0014`, `0015`, `0016`, `0020`, `0021`, `0022`, `0024`,
`0027`, `0028`, `0029`, `0030`, `0031`, `0032`, `0033`, `0035`, `0036`, `0038`, `0039`,
`0040`, `0041`, `0042`.

Fix direction: rebuild the "Current ADRs" table from the files actually present, with correct
status (`Accepted` / `Superseded by NNNN` / `Deprecated`) and gates.

## Bucket C — top-level README stale

| Location | Problem |
|---|---|
| [`README.md`](../../README.md) Status section | Reads "Scaffolding only" — inaccurate; v1 shipped Waves 0–4b and v2 is in flight |
| [`README.md`](../../README.md) repository-layout tree | Omits ~14 of the 18 `data-plane/` folders and most `scripts/`; still lists the deleted `policies/` folder |
| [`README.md`](../../README.md) planes table | Advertises "DevOps & protection policies" as managed (DevOps policies are retired) |

Fix direction: refresh the Status, layout tree, and planes table to current reality. The
README tree change (A3) is folded into this item so the tree is rewritten once.

## Bucket D — minor / no-action observations

- **ADR numbering gap `0004`–`0007`.** No files exist for these numbers; the gap is consistent
  with reserved / withdrawn numbers from v1. No action beyond an optional one-line note in the
  ADR index (folded into Item 3).
- **`testResults.xml` at repo root.** Local Pester output. Confirmed gitignored and untracked
  (`.gitignore` "Build / logs" section). No action.
- **`.squad/memory/context.md` staleness.** "Current phase" still reads "Wave 0" with a
  2026-05-04 timestamp. This file is Scribe-owned and edited only through the Scribe handoff
  workflow per [`.github/instructions/squad-memory.instructions.md`](../../.github/instructions/squad-memory.instructions.md);
  it is out of scope for these docs pull requests and is flagged here for a separate Scribe update.

## Out of scope — immutable history

These contain accurate references for the time they were written and must not be edited:

- [`docs/adr/0003-data-plane-folder-naming.md`](../adr/0003-data-plane-folder-naming.md) — ADRs are immutable once accepted.
- [`docs/archive/project-plan-v1.md`](../archive/project-plan-v1.md) — archived v1 plan.

## Corrective roadmap

Items run one at a time through `@idea-intake` per the section 5 cadence; each is its own
branch and pull request. Item 1 is this document.

| Item | Branch | Type / scope | Covers |
|---|---|---|---|
| 1 | `docs/repo-consistency-housekeeping-plan` | `docs` | This plan doc (#668) |
| 2 | `docs/retire-devops-policies-stale-refs` | `docs` | Bucket A |
| 3 | `docs/adr-index-refresh` | `docs` | Bucket B (and the Bucket D ADR-gap note) |
| 4 | `docs/readme-refresh-v2-state` | `docs` | Bucket C |
