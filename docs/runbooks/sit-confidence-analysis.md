# Runbook: SIT confidence analysis

Use this runbook when you want to decide which Microsoft Purview
Sensitive Information Types (SITs) in this lab are actually paying
their way -- driving real matches in Microsoft 365 workloads -- and
which are noise that should be retuned or retired.

The workflow is two stages:

1. `scripts/Export-ContentExplorerData.ps1` captures the live Content
   Explorer view for every SIT (and label) listed in `data-plane/dspm/`
   and writes timestamped JSON under `verify-dspm-export-output/`. This
   step calls Microsoft Purview. Cadence and retention rules live in
   [ADR 0021](../adr/0021-dspm-content-explorer-cadence.md).
2. `scripts/Invoke-SITConfidenceAnalysis.ps1` reads the export's
   `manifest.json` + per-pair JSON files, cross-references them against
   `data-plane/classifications/sit-catalog.yaml`, and writes a paired
   Markdown + CSV report under `verify-sit-confidence-output/`. **This
   step is local-only -- zero tenant calls.**

Treat the report as the recommended starting point for a tuning
conversation, not as an automated retire-list. Nothing in this
workflow modifies or deletes a SIT.

## Prerequisites

- PowerShell 7.4 or newer (`#Requires -Version 7.4`).
- The `powershell-yaml` module (`Install-Module powershell-yaml
  -Scope CurrentUser`). The script installs it for you on first run.
- A fresh `Export-ContentExplorerData.ps1` run under
  `verify-dspm-export-output/<timestamp>/` containing `manifest.json`
  plus the per-pair JSON files. See the
  [exporter section in ADR 0021](../adr/0021-dspm-content-explorer-cadence.md)
  for how to produce one.
- The desired-state SIT catalog at
  `data-plane/classifications/sit-catalog.yaml`. This is already in
  the repo; only the `type` column matters to the analyzer (`Custom`
  vs everything else).

No Azure, Microsoft Graph, or Microsoft Purview RBAC role is required
to run the analyzer itself.

## Run the analyzer

### Newest run, default thresholds

```pwsh
./scripts/Invoke-SITConfidenceAnalysis.ps1
```

The script picks the lexicographically newest subdirectory under
`verify-dspm-export-output/`, runs the analysis, and writes
`sit-confidence-report.md` + `sit-confidence-report.csv` to a fresh
timestamped folder under `verify-sit-confidence-output/`.

### Specific run, tighter Retain threshold

```pwsh
./scripts/Invoke-SITConfidenceAnalysis.ps1 `
    -RunDirectory ./verify-dspm-export-output/2026-05-17-1200 `
    -MinHits 10
```

`-MinHits` is the inclusive lower bound that separates `Review` from
`Retain` for a `Custom` SIT. Default is 5; raise it when you want
stricter signal.

### Dry-run (no files written)

```pwsh
./scripts/Invoke-SITConfidenceAnalysis.ps1 -WhatIf
```

The cmdlet honours `-WhatIf` and returns the resolved report rows on
the pipeline without touching disk. Pipe to `Format-Table` or
`Where-Object` to triage interactively.

### Custom SITs only

```pwsh
./scripts/Invoke-SITConfidenceAnalysis.ps1 -CustomOnly
```

Filters out Microsoft built-ins from the written report. Built-in SITs
are not actionable from this repo and are documented under
[SIT entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions);
including them adds noise without giving you anything to act on.

## Interpret the report

The report rows are one-per-SIT:

| Column | Meaning |
|---|---|
| `Name` | SIT display name as seen by Content Explorer. |
| `Id` | SIT GUID from `sit-catalog.yaml`. Empty when the SIT is not in the catalog. |
| `Type` | Catalog `type` (`Custom`, `Entity`, `Credential`, etc.). `Unknown` for SITs not in the catalog. |
| `IsCustom` | `$true` only for `Custom` SITs -- lab-published, in scope for tuning. |
| `Hits` | Total Content Explorer records matched, summed across every successful workload pull. |
| `WorkloadsWithHits` | Distinct workloads where `Hits > 0`. |
| `WorkloadsScanned` | Distinct workloads attempted for this SIT in the run. |
| `Signal` | `None` (zero hits), `Isolated` (hits in one workload), `Broad` (hits in 2+ workloads). |
| `Recommendation` | See below. |

### Recommendation column

| Value | Trigger | Suggested next step |
|---|---|---|
| `Reference` | `IsCustom = $false` -- Microsoft built-in. | No action -- not editable from this repo. |
| `Retire` | `IsCustom = $true` and `Hits = 0`. | Decommission via the SIT lifecycle path. Captures candidates for the next `data-plane/classifications/` PR. |
| `Review` | `IsCustom = $true` and (`Hits < MinHits` or `Signal = Isolated`). | Investigate why the volume is low: workload misconfiguration, scope filter, or genuine niche use. |
| `Retain` | `IsCustom = $true`, `Hits >= MinHits`, `Signal = Broad`. | Keep as-is. Consider raising the protective action (DLP / IP) attached to it. |

Microsoft Purview does **not** return a per-record confidence score
from `Get-ContentExplorerData`; the helper therefore reads "confidence"
as signal-volume (count x workload coverage), not as the regex
confidence value that Content Explorer renders interactively. See
[Get-ContentExplorerData](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata)
for the exact returned shape.

## Sample-data hygiene reminder

The exporter writes raw Content Explorer rows to disk. Those files may
contain real tenant content. Before pasting any analyzer output into
an issue, PR, or chat:

- Redact tenant identifiers per the `Environment and identifier
  boundaries` section of `.github/copilot-instructions.md`.
- Apply the synthetic substitutes in
  `.github/instructions/sample-data.instructions.md` if you need to
  share an example.
- Never commit anything under `verify-dspm-export-output/` or
  `verify-sit-confidence-output/`; both are gitignored.

## References

- [Content Explorer overview](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)
- [Get-ContentExplorerData (Exchange Online PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata)
- [Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions)
- [Learn about sensitive information types](https://learn.microsoft.com/en-us/purview/sit-learn-about-sensitive-information-types)
- [Get started with custom sensitive information types](https://learn.microsoft.com/en-us/purview/sit-get-started-with-custom-sensitive-information-types)
- [`scripts/Export-ContentExplorerData.ps1`](../../scripts/Export-ContentExplorerData.ps1)
- [`scripts/Invoke-SITConfidenceAnalysis.ps1`](../../scripts/Invoke-SITConfidenceAnalysis.ps1)
- [ADR 0021 -- DSPM Content Explorer cadence + retention](../adr/0021-dspm-content-explorer-cadence.md)
