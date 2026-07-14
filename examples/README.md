# `examples/` — worked, non-deployable reference content

> **Nothing in this tree is read by any workflow, reconciler, script, or schema.**
> It is documentation that happens to be valid YAML. Copying a file out of here into
> `data-plane/**` is a **deliberate act**, and it is the only way this content can ever
> reach a tenant.

## Why this directory exists

[ADR 0056](../docs/adr/0056-template-ships-empty-desired-state.md) makes one rule
uniform across the whole repository:

> **The template ships nothing deployable. Every root list under `data-plane/**` is empty.**

`data-plane/**` is a **deploy path**. A reconciler opens those exact files and turns
whatever it finds there into Create / Update / Delete operations against a live Microsoft
Purview tenant. Before ADR 0056, this repository — a **public template** — shipped a
string-substituted export of the owner's live lab in that path, including
`Lab-AutoLabel-SSN`: a policy at `mode: Enable` with `exchangeLocation: [All]` that
stamps an encrypted label on any mail containing a U.S. Social Security Number, across
every mailbox. A consumer who clicked *Use this template*, ran kickoff exactly as
designed, and dispatched the deploy workflow got it **created and enforcing in their own
tenant**.

The content that had genuine teaching value moved here. The content whose only value was
as a lab artifact was **deleted**, not relocated — `Lab-AutoLabel-SSN` above all. It does
not survive as an example in any form.

## Why a directory, and not comments in the original files

Commenting the content out inside `data-plane/**` was considered and **rejected**. A
commented-out enforcing SSN policy still sits in the exact file a reconciler opens; the
"fix" is a `#`, and the regression is deleting one character. A directory boundary makes
restoring it a deliberate copy across a boundary, and it lets the guard test
([`tests/data-plane/ShippedDesiredState.Tests.ps1`](../tests/data-plane/ShippedDesiredState.Tests.ps1))
be blunt: *every root list under `data-plane/**` is empty*. A test that has to parse YAML
comments to tell "commented example" from "live entry" is a test that can be fooled.

## Every identifier in here is synthetic

Moving content **relocates a disclosure; it does not remove one** — and this repository is
public. Everything here was scrubbed on the way over, to Microsoft's fictitious-company
convention (`contoso` / `fabrikam` / `adatum`, RFC 2606 `example.com`, zero-GUID) per
[`sample-data.instructions.md`](../.github/instructions/sample-data.instructions.md):

| Was (real lab) | Is now (synthetic) |
|---|---|
| Purview auto-generated collection IDs (`c8iacz`, `chfb1r`, `cqyzoe`, …) | readable slugs (`non-prod`, `platform-data`, `dataverse`, …) |
| a real Databricks workspace URL and SQL-warehouse path | `adb-0000000000000000.0.azuredatabricks.net`, `/sql/1.0/warehouses/0000000000000000` |
| a real Dataverse organization endpoint | `org00000000.crm.dynamics.com` |
| the lab's managed-VNet / integration-runtime names | `ManagedVnet-Contoso-EastUS`, `IntegrationRuntime-Contoso-EastUS` |
| a real Entra group named as a label rights holder | deleted with the label that carried it |
| `user@contoso.com` repeated five times with five different rights sets (a genericization collapse of five real principals) | five distinct synthetic groups, one per rights tier |
| `Scan-DataLakeModerninzation` (a typo — the tell that this was an export, not authored content) | deleted |
| lab-teardown label fixtures ("Remove during lab teardown") | deleted |
| an enforcing tenant-wide SSN auto-label policy | **deleted** |

`examples/**` is **in scope** for both residual scans — the token-shaped `residualScan`
and the identifier-shaped [ADR 0055](../docs/adr/0055-identifier-shaped-residual-scan.md)
`identifierScan`. It is deliberately **not** added to `intentionalSamples`. A path
exclusion is the mechanism that hid the last disclosure; relocating content behind one
would simply move the blind spot.

The only GUIDs here are Microsoft built-in Sensitive Information Type and
trainable-classifier IDs — identical in every tenant, published by Microsoft, and
acquitted by the `identifierScan.catalogKeys` rule under the specific keys (`guid`,
`sitId`) that carry them.

## Simulation first

Where the original content was `mode: Enable`, the examples that survive are documented
with the promotion path, not presented as a starting point. A new policy lands at
`mode: TestWithoutNotifications`; promotion to `Enable` is a `destructive`-labelled PR.
See [`docs/project-plan.md`](../docs/project-plan.md) guiding principle 3 and
[ADR 0016](../docs/adr/0016-auto-label-policy-shape.md).

## How to use this

1. Read the example next to the empty file it corresponds to.
2. Run the matching reconciler's **`-ExportCurrentState`** against your own tenant first
   (the mandatory first-run bootstrap in
   [`powershell.instructions.md`](../.github/instructions/powershell.instructions.md)).
   That writes *your* state into `data-plane/**`, which is what you actually want — not
   someone else's.
3. Use the example to understand the **shape**: which fields exist, how they nest, what
   the reconciler tracks for drift.
4. Review the drift report in a pull request, then merge, then `-Apply`.

Do not copy an example into `data-plane/**` and dispatch a deploy. That is the failure
this directory exists to prevent, performed by hand.
