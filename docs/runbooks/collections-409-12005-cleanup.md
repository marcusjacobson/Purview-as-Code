# Runbook: Resolve HTTP 409 / 12005 during collection prune

Use this runbook when `scripts/Deploy-Collections.ps1 -PruneMissing -Force`
reports a row in its Failed table with:

```text
HTTP 409 / code 12005 / "<friendly> is being referenced by other resources and can't be deleted."
```

This is the most common prune failure in this lab. PR #307 cycle 3 saw 17 of
19 prune failures land here; the reconciler classifies them correctly and the
deploy aborts cleanly, but a human has to decide what to do with the
referencing resources before the next run can complete the delete.

## Symptom

`Deploy-Collections.ps1 -PruneMissing -Force` finishes with a Failed table
similar to the example below. Names are illustrative — substitute the values
from your own run.

```text
Result : Failed
Friendly: marketing
Reason  : HTTP 409 / code 12005 / "marketing is being referenced by other resources and can't be deleted."
```

The script does not delete anything else after it hits this row for that
collection; the prune for unrelated orphan collections still attempts in the
same run because each delete is issued independently.

Reference (service error shape):
[Purview accountdataplane collections — error response model](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections/create-or-update-collection#errorresponsemodel).

## Root cause

Microsoft Purview blocks deletion of a collection that still has registered
resources attached to it. A collection can be referenced by:

- **Data sources** registered into the collection
  ([Manage data sources in Microsoft Purview](https://learn.microsoft.com/en-us/purview/manage-data-sources)).
- **Scans** defined under those data sources
  ([Scans — REST reference](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans)).
- **Data-use-management or DevOps policies** scoped at the collection
  ([About data policies in Microsoft Purview](https://learn.microsoft.com/en-us/purview/concept-data-owner-policies)).
- **Role assignments** on the collection itself
  ([Permissions in Microsoft Purview](https://learn.microsoft.com/en-us/purview/catalog-permissions))
  — these do not produce 12005 on their own, but they are listed here for
  completeness because operators often see them while triaging the portal
  view.

[Create a collection in Microsoft Purview](https://learn.microsoft.com/en-us/purview/quickstart-create-collection)
documents the lifecycle requirement: detach or move child resources before
the parent collection can be removed.

## Decision tree

For each Failed row, decide one of the following before re-running the
reconciler. The right choice depends on whether the referenced resources
should keep existing, just under a different parent, or whether they are
obsolete.

```text
Failed row for collection <friendly>
│
├─ Are the referenced resources still needed?
│  │
│  ├─ Yes ─ should they live under a different collection?
│  │   │
│  │   ├─ Yes → A. Re-parent the references, then re-run prune.
│  │   └─ No  → C. Keep the collection (revert the YAML delete intent).
│  │
│  └─ No  → B. Delete the references, then re-run prune.
```

The three options are detailed below. Pick exactly one per Failed
collection.

## Option A — Re-parent the references

Use when the referenced data sources / scans / policies should keep working,
but the parent collection in
[`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml)
has changed for governance reasons.

1. **Identify the referencing data sources.** In the Microsoft Purview
   portal open **Data Map** → **Collections** → select the doomed
   collection → **Sources** tab. The same view is available via the
   scanning data plane REST API
   ([Data Sources](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources)):

   ```pwsh
   $token = (az account get-access-token --resource https://purview.azure.net --query accessToken -o tsv)
   $base  = 'https://purview-contoso-lab.purview.azure.com'
   Invoke-RestMethod -Method GET `
     -Uri "$base/scan/datasources?api-version=2023-09-01" `
     -Headers @{ Authorization = "Bearer $token" } |
     Select-Object -ExpandProperty value |
     Where-Object { $_.properties.collection.referenceName -eq '<doomed-friendly-name>' } |
     Select-Object name, kind, @{n='collection';e={$_.properties.collection.referenceName}}
   ```

   The `properties.collection.referenceName` value is the collection's
   friendlyName. Save the list — you will reuse it in step 3.

2. **Identify the referencing scans.** For each data source in step 1,
   list its scans
   ([Scans](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans)):

   ```pwsh
   Invoke-RestMethod -Method GET `
     -Uri "$base/scan/datasources/<data-source-name>/scans?api-version=2023-09-01" `
     -Headers @{ Authorization = "Bearer $token" }
   ```

   Scans inherit the collection of their parent data source, so re-parenting
   the data source moves the scans with it. You only re-parent the data
   source itself.

3. **Move each data source to the new parent collection.** In the portal,
   open the data source → **Edit** → change **Collection** → save. Via REST,
   PUT the data-source document with the new `properties.collection.referenceName`
   (the **Create Or Replace** operation under
   [Data Sources](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources)).
   The new collection must already exist; if it does not, file a YAML
   edit through `@idea-intake` first and let the reconciler create it.

4. **Re-run** `Deploy-Collections.ps1 -PruneMissing -WhatIf`. The Failed row
   should now show the collection as eligible for deletion. If a child
   collection still references it, repeat the steps for that child first
   (the script always processes children before parents).

5. **Apply** by re-running without `-WhatIf`. Capture the run log in the
   PR description of whatever change triggered the prune.

## Option B — Delete the references

Use when the referenced resources are themselves obsolete.

1. **List the data sources** as in Option A step 1.

2. **Delete each scan** under those data sources (the **Delete** operation
   under [Scans](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans)).
   This is destructive — confirm the scan really should be removed before
   issuing the call.

   ```pwsh
   Invoke-RestMethod -Method DELETE `
     -Uri "$base/scan/datasources/<data-source-name>/scans/<scan-name>?api-version=2023-09-01" `
     -Headers @{ Authorization = "Bearer $token" }
   ```

3. **Delete each data source** (the **Delete** operation under
   [Data Sources](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources)):

   ```pwsh
   Invoke-RestMethod -Method DELETE `
     -Uri "$base/scan/datasources/<data-source-name>?api-version=2023-09-01" `
     -Headers @{ Authorization = "Bearer $token" }
   ```

4. **Check for collection-scoped policies.** Data owner / DevOps policies
   that bind a role at the collection scope keep the collection alive even
   after the data sources are gone
   ([Manage data owner policies](https://learn.microsoft.com/en-us/purview/how-to-data-owner-policies-storage)).
   In the portal: **Data policy** → **Data policies** (or **DevOps policies**)
   → filter by collection. Unpublish or delete the offending policy before
   re-running prune.

5. **Re-run** `Deploy-Collections.ps1 -PruneMissing -WhatIf`, confirm the
   collection is now eligible, then apply.

## Option C — Keep the collection

Use when the YAML edit that triggered the prune was wrong, or when the
references make the collection load-bearing for an ongoing workstream.

1. Revert the deletion in
   [`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml)
   — re-add the entry so the desired state once again contains the
   collection.

2. Open a PR through the normal `@idea-intake` → `@artifact-resolver`
   flow with the rationale (1–2 sentences) in the PR description. Cite
   this runbook so the reviewer sees why the prune intent is being
   reverted.

3. Re-run `Deploy-Collections.ps1 -PruneMissing -WhatIf` after the PR
   merges. The Failed row should be gone because the collection is no
   longer an orphan.

If the collection is system-managed (the script flags it as `Protected`
and the service returns Purview `code 1006`), add it to the optional
top-level `protected:` allow-list in
[`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml).
That path is reserved for collections like `root` that the service
itself manages and is not the right answer for ordinary content
collections that produce `12005`.

## What not to do

- ⚠️ Do not run `-Force` against the live Purview account without first
  running `-WhatIf` and reading the Failed table. The script is
  idempotent, but each option above changes the data plane (re-parenting,
  deleting scans, deleting data sources), and those changes are not
  themselves rolled back if you revert the collection YAML.
- ⚠️ Do not delete `root` or any other system-managed collection. Those
  surface as `1006` errors rather than `12005`, but the operational
  conclusion is the same: leave them alone and rely on the protected
  allow-list.
- ⚠️ Do not assume "the script said Removed" means the collection is
  gone. Re-run the reconciler and confirm the Failed table is empty
  before closing the runbook.

## See also

- [`scripts/Deploy-Collections.ps1`](../../scripts/Deploy-Collections.ps1)
  — the reconciler that emits the Failed table.
- [`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml)
  — the desired-state file edited by `@idea-intake`.
- [Create a collection in Microsoft Purview](https://learn.microsoft.com/en-us/purview/quickstart-create-collection)
  — the canonical Microsoft Learn page for collection lifecycle.
- [Permissions in Microsoft Purview](https://learn.microsoft.com/en-us/purview/catalog-permissions)
  — RBAC required to read and modify data sources, scans, and policies
  during cleanup.
