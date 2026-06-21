# 0021 — Content Explorer export cadence for DSPM: weekly automated + on-demand

- **Status:** Accepted
- **Date:** 2026-05-17
- **Gates:** Resolves Q5 in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs. Unblocks Wave 3a / [#74](../../issues/74) (`data-plane/dspm/` policies + deploy script). Does not gate any other item.
- **Deciders:** @contoso

## Context

Wave 3a ([#74](../../issues/74)) ships the `data-plane/dspm/` folder and its `Deploy-*.ps1`. The DSPM dashboard itself is an aggregator that Microsoft renders in the Microsoft Purview portal — the lab does not author the dashboard, it authors the **signal sources** DSPM consumes and (separately) the **evidence artifacts** that demonstrate the lab is exercising those signals over time.

The signal sources DSPM consumes — sensitivity labels (Wave 1), Sensitive Information Types (Wave 1), DLP policies (Wave 2b), Insider Risk Management signals (Wave 2d), and the unified audit log (Wave 0) — are already live per [Get started with Data Security Posture Management](https://learn.microsoft.com/en-us/purview/dspm-get-started). What is not yet decided is how the lab will **harvest Content Explorer data** so that the Wave 3a deploy script has a defensible posture snapshot to validate against and an evidence trail to attach to the next quarterly review.

[Content Explorer](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer) is the labels-and-SITs surface inside the Microsoft Purview portal that shows where labeled and classified content lives across Microsoft 365. The portal exposes interactive browse + manual CSV export. The programmatic surface is the [`Get-ContentExplorerData`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata) cmdlet in the Security & Compliance PowerShell module. The cmdlet returns up to 100 rows per call, supports paging via `-PageSize` / `-PageCookie`, filters by `-Tag` (label) or `-TagName` (SIT) and `-Workload` (Exchange, SharePoint, OneDrive, Teams), and requires the **Content Explorer List Viewer** or **Content Explorer Content Viewer** role per the Microsoft Purview role-group model.

Three cadence shapes were on the table for the lab:

1. **Daily** — over-sampled relative to the underlying refresh rate. Microsoft Learn ([Content Explorer](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)) documents that newly labeled or newly classified items can take **up to seven days** to appear in Content Explorer; daily pulls would produce mostly identical snapshots and burn the `Get-ContentExplorerData` quota.
2. **Weekly** — matches the documented refresh ceiling, produces a tidy trend timeline, and stays well inside service throttling.
3. **On-demand only** — manual; no trend timeline, no unattended evidence trail, no demonstration that the lab can run the export under workload identity. Useful as a complement, not as the primary cadence.

The lab is single-owner, pay-as-you-go, with no production SLA. The audit retention policy in [`data-plane/audit/retention-policies.yaml`](../../data-plane/audit/retention-policies.yaml) standardizes on **90 days** per [Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies); aligning the Content Explorer export retention with that window keeps governance horizons consistent and avoids inventing a second retention horizon for the lab to defend.

## Decision

**We will run the Content Explorer export on a weekly automated cadence plus on-demand**, scoped and persisted as follows:

1. **Primary cadence — weekly.** A GitHub Actions workflow (filed in Wave 3a / [#74](../../issues/74), not in this ADR) runs `scripts/Export-ContentExplorerData.ps1` on a `schedule:` cron of `0 7 * * 1` (Mondays, 07:00 UTC). Weekly aligns with the documented Content Explorer refresh ceiling of seven days.
2. **Secondary cadence — on-demand.** The same workflow also exposes `workflow_dispatch` so the lab owner (or a future contributor) can pull a fresh snapshot after a material change to labels, SITs, DLP, or scope without waiting for the next Monday.
3. **Scope per run.** Each run iterates the union of (a) every published sensitivity label in [`data-plane/information-protection/labels.yaml`](../../data-plane/information-protection/labels.yaml) and (b) every custom SIT in [`data-plane/classifications/classifications.yaml`](../../data-plane/classifications/classifications.yaml), querying `Get-ContentExplorerData` once per `(item, Workload)` pair across Exchange, SharePoint, OneDrive, and Teams.
4. **Identity.** The workflow authenticates with the workload identity already federated for `deploy-data-plane.yml` (no stored client secret) and assumes the **Content Explorer List Viewer** role under the existing `Content Explorer List Viewer (Lab)` group, per Microsoft Purview role-group guidance. The role assignment itself ships in Wave 3a, not in this ADR.
5. **Output format and location.** Each run writes one JSON file per `(item, Workload)` pair plus a single `manifest.json` summarizing the run, into `verify-dspm-export-output/<YYYY-MM-DD-HHmm>/`. That folder is added to `.gitignore` in Wave 3a — exports never land in source. The workflow uploads the folder as a GitHub Actions **artifact** with a 90-day retention to mirror the audit retention horizon set in [`data-plane/audit/retention-policies.yaml`](../../data-plane/audit/retention-policies.yaml).
6. **Throttling and failure handling.** The deploy script enforces a 1-second delay between `Get-ContentExplorerData` calls, retries on transient 429s with exponential backoff (max three retries), and aborts the run with a non-zero exit code if any `(item, Workload)` pair fails after retries. Partial runs are not committed to the artifact upload.
7. **No Azure Storage account in the lab phase.** The lab keeps exports in GitHub Actions artifact storage. If, in a future wave, the lab adopts an Azure Storage account for DSPM evidence (e.g., to feed a Log Analytics workspace), that move ships as its own ADR.

## Consequences

**Easier:**

- **Wave 3a unblocks.** [#74](../../issues/74) loses its Q5 gate and becomes the next ready item (subject to the apply-path-hardening chain [#267](../../issues/267) / [#271](../../issues/271) tracked separately).
- **Evidence is reproducible.** Every Monday produces a dated, machine-readable posture snapshot. The Tester/Validator persona can diff snapshots to demonstrate that the DSPM signal flow is alive.
- **No new retention horizon to defend.** Reusing the 90-day audit horizon keeps the lab's governance story single-source.

**Harder:**

- **Weekly is coarse.** Material changes inside a Monday-to-Monday window are not captured until the following Monday unless someone fires the on-demand path. The on-demand path is the documented mitigation.
- **GitHub Actions artifact retention is the only durable store.** If GitHub Actions artifacts age out before a posture-review cycle, the lab loses the older snapshots. Aligning to 90 days makes the loss horizon explicit; a future Azure Storage move (separate ADR) would extend it.
- **`Get-ContentExplorerData` quota.** Per-`(label, SIT) × Workload` iteration scales linearly with the published-label and SIT count. The lab currently sits at a small enough count to fit comfortably; if either set grows past ~25 entries, the run wall-clock crosses the 6-hour GitHub Actions job ceiling and the script will need a paging-per-workload partition. That re-architecting is out of scope here.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Upheld. Workload identity, no stored client secret.
- **#4 (least privilege).** Upheld. Content Explorer List Viewer is the minimum role that satisfies `Get-ContentExplorerData`; the broader Content Viewer role is not requested.
- **#9 (idempotent, reversible, auditable).** Upheld. Each run is a read-only enumeration; the artifact folder is dated and immutable; deleting an artifact does not affect Purview state.

## Alternatives considered

1. **Daily automated export.** Rejected. Microsoft Learn documents a Content Explorer refresh ceiling of up to seven days; daily would produce mostly duplicate snapshots, spend `Get-ContentExplorerData` quota with no posture benefit, and offer no signal-to-noise improvement for the lab's quarterly review.
2. **Monthly automated export.** Rejected. Monthly snapshots produce too few data points to show a trend across a wave's worth of work, and an out-of-cycle change would sit invisible for up to four weeks even with on-demand available, because the on-demand artifact would not be inside the scheduled trend series.
3. **On-demand only (no schedule).** Rejected. The lab loses the unattended evidence trail and the demonstration that the workload identity can execute the export without a human in the loop. The Tester/Validator persona has no fixed checkpoint to validate against.
4. **Status quo — do not export at all; rely on the Purview portal Content Explorer UI.** Rejected. The portal view is interactive and ephemeral; it produces no machine-readable trend artifact and no proof that the lab's automation identity actually has the role to read Content Explorer. Both of those properties are part of why the lab exists.
5. **Export to an Azure Storage account from day one.** Rejected as premature. The lab does not yet have a DSPM-evidence storage account, and standing one up would add scope to Wave 3a (resource group provisioning, RBAC, lifecycle management) that the weekly artifact-store approach satisfies for free. If the storage account becomes necessary, a follow-up ADR can introduce it without breaking this one.

## Citations

- **[Content Explorer in Microsoft Purview](https://learn.microsoft.com/en-us/purview/data-classification-content-explorer)**
  Fetch date: 2026-05-17
  > "Items in content explorer may take up to seven days to appear after they have been labeled or classified."
- **[Get-ContentExplorerData (Security & Compliance PowerShell)](https://learn.microsoft.com/en-us/powershell/module/exchange/get-contentexplorerdata)**
  Fetch date: 2026-05-17
  Documents the cmdlet surface (`-Tag`, `-TagName`, `-Workload`, `-PageSize`, `-PageCookie`), the 100-row page size, and the Content Explorer List Viewer / Content Viewer role-group requirement.
- **[Get started with Data Security Posture Management](https://learn.microsoft.com/en-us/purview/dspm-get-started)**
  Fetch date: 2026-05-17
  Confirms the DSPM signal inputs (sensitivity labels, Sensitive Information Types, DLP, Insider Risk Management, unified audit log) and grounds the choice to drive the export off the published label + custom SIT lists already in the repo.
- **[Permissions in the Microsoft Purview compliance portal](https://learn.microsoft.com/en-us/purview/microsoft-365-compliance-center-permissions)**
  Fetch date: 2026-05-17
  Defines the Content Explorer List Viewer and Content Explorer Content Viewer role groups; supports the least-privilege choice in Decision item 4.
- **[Manage audit log retention policies](https://learn.microsoft.com/en-us/purview/audit-log-retention-policies)**
  Fetch date: 2026-05-17
  Grounds the 90-day retention horizon reused for the Content Explorer export artifacts in Decision item 5.
- **[GitHub Actions — schedule events](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#schedule)**
  Fetch date: 2026-05-17
  Grounds the `schedule:` cron syntax and the `workflow_dispatch` on-demand trigger choice in Decision items 1 and 2.
