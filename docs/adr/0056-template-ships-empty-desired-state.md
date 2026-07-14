# 0056 — The template ships empty desired state; a populated root list under `data-plane/**` is a loaded gun pointed at the consumer's tenant

- **Status:** Accepted
- **Date:** 2026-07-14
- **Gates:** Cross-cutting security control. **Amends [ADR 0046](0046-tenant-placeholder-manifest.md) again** — ADR 0046's two configuration classes (tenant-surface values that must be replaced; intentional sample content that must not) do not cover a **third** class that turns out to be the dangerous one: **shipped desired state**, which is neither a value to replace nor a sample to keep, but an *instruction to a reconciler*. Also **amends [ADR 0055](0055-identifier-shaped-residual-scan.md) by supersession on one point**: ADR 0055 §Decision-2 narrowed the blanket `:!data-plane` exclusion to four files it called "the genuinely sample-content files". **Those four were not sample content.** They were the four carrying the owner's live lab config. The exclusions are removed, not re-scoped. Empties the root list of 11 `data-plane/**` YAMLs; relocates the worked content to a scrubbed [`examples/`](../../examples/) tree that no workflow, script, or schema reads; deletes the enforcing SSN auto-label policy outright; and generalises [`tests/data-plane/ShippedDesiredState.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.Tests.ps1) from two files to **all** of them. No [`docs/project-plan.md`](../project-plan.md) §5 / §8 row: this is repo-safety infrastructure, following the ADR 0046 / ADR 0050 / ADR 0055 precedent.
- **Deciders:** @marcusjacobson

## Context

This repository is a **PUBLIC, tenant-neutral template** ([ADR 0045](0045-template-kickoff-spinoff-model.md)), and it stays public. A consumer clicks *Use this template*, runs `@operator-kickoff` and `@operator-tenant` exactly as designed, and dispatches the deploy workflows.

Until this ADR, what they got was **the owner's live lab governance objects, created in their own tenant.**

The worst of them, `data-plane/information-protection/auto-label-policies.yaml`:

```yaml
- name: Lab-AutoLabel-SSN
  mode: Enable                     # not TestWithoutNotifications
  applyLabel: Confidential/Partner
  exchangeLocation: [All]          # every mailbox
```

A **live, enforcing, tenant-wide auto-labeling policy** that stamps an **encrypted** sensitivity label on any mail containing a U.S. Social Security Number, across every mailbox in the tenant. Not a sample. Not a simulation. A working control, in a public template, wired to a deploy workflow, aimed at whoever ran it next.

**The policy immediately above it, in the same file, is `mode: TestWithoutNotifications`.** Simulation mode was known. It was available. It was used for credit cards and not for SSNs. That is not an oversight in the tooling — it is a **per-file, per-entry judgment call that went wrong**, and it is the single most important fact in this document, because it tells you what the fix has to be.

### These files are exports, not authored samples — and the evidence is decisive

`data-plane/**` is the owner's real lab, **string-substituted**. [ADR 0055](0055-identifier-shaped-residual-scan.md) established the mechanism (genericization replaced `contoso`-shaped *tokens*; anything that was not token-shaped survived). What survived is not subtle:

- **`collections/collections.yaml`** — collections named `c8iacz`, `chfb1r`, `cqyzoe`, `85cv3o`, `euvfmr`, `ev04jw`, `jprasm`. These are **Purview's auto-generated 6-character collection IDs**, minted by the service when you create a collection in the portal. **Nobody hand-authors those.**
- **`scans/scans.yaml`** — a real Databricks workspace URL, a real SQL-warehouse path, a real Dataverse organization endpoint, the lab's own managed-VNet and integration-runtime names.
- **`scans/scans.yaml` line 179** — `name: Scan-DataLakeModerninzation`. **A typo.** The correctly-spelled `Scan-DataLakeModernization` sits two entries above it. **No curated sample ships a misspelling.** The typo is the tell, and it is worth more than any of the identifiers: it proves provenance in a way a GUID cannot.
- **`information-protection/labels.yaml`** — three `Pilot — … (Lab)` labels whose own `comment:` fields read *"Remove during lab teardown."* and which name a real Entra security group as a rights holder.
- **`information-protection/labels.yaml`** — `user@contoso.com` repeated **five times inside one label's `rightsDefinitions`**, each occurrence with a **different** rights string. That is not a sample; that is a **genericization collapse**: five real principals, substituted to one synthetic token, destroying the only thing the block was trying to express.
- **`data-plane/**` cites issue numbers from a *different repository*** — `#307`, `#360`, `#367`, `#521`, `#548`. This repo has reached ~#100.

### Why the existing controls could not see it — three of them, each blind in its own way

1. **`tenantSurfaces` never looks here.** The manifest's Step-5 edit list — the one thing kickoff walks the operator through — has 14 entries and **zero** under `data-plane/`. The kickoff agent never opens a data-plane file. It cannot fix what it does not read.

2. **`intentionalSamples` explicitly *asserted* these files were safe.** It carried four exclusions naming exactly the contaminated files, with comments like `# sample source names` and `# sample scan targets`. **The comment described why the line was added and not what the line did** — the identical failure mode ADR 0055 diagnosed in the blanket `:!data-plane` one layer up, reproduced *inside the fix for it*. ADR 0055 narrowed the exclusion to "the genuinely sample-content files" and the four survivors turned out to be **precisely the files that most needed scanning.**

3. **The ADR 0055 identifier scan passes clean — and it is right to.** It is **GUID-shaped by design** and it **structurally cannot see** `c8iacz`, a Databricks workspace URL (`adb-<16 digits>.<n>.azuredatabricks.net`), `Scan-DataLakeModerninzation`, or `Lab-AutoLabel-SSN`. None of those is a GUID. **A green ADR 0055 run is not, and never was, evidence of a clean data plane** — and it is being read as one. That misreading is the reason this section exists.

> Three scans, three shapes, three blind spots. ADR 0046's token scan cannot see a GUID. ADR 0055's identifier scan cannot see a *name*. And **neither of them can see a `mode:` field**, which is where the actual weapon was. The lesson is not "add a fourth scan for names" — a name blocklist catches the instance you already found. The lesson is that **content-shaped checks keep losing to content you did not anticipate, and the way out is a *structural* rule instead.**

## Decision

### 1. THE RULE: the template ships nothing deployable. Every root list under `data-plane/**` is EMPTY

Eleven files are emptied: `collections`, `data-sources`, `scans` (both lists), `dlp/policies`, `information-protection/{auto-label-policies (both lists), label-policies, labels}`, `irm/policies`, `glossary`, `classifications` (both lists), `adaptive-scopes`. They join the 15 that already shipped empty. **26 of 29 desired-state files, one rule, no exceptions but the three named in Decision 3.**

**Why an EMPTY ROOT LIST specifically, and not `[]` on a listed object.** This is [#96](https://github.com/marcusjacobson/Purview-as-Code/pull/96)'s shape decision, generalised, and it is load-bearing:

> **"Not listed" is the only shape that means "not managed".** A role group *listed* with `members: []` means *"this role group must have zero members"* — and under `-Apply -PruneMissing` the reconciler **revokes every existing assignment.** A populated list is deployable desired state. Only an **empty root list** is a true no-op, and the reconcilers pre-flight on exactly that.

**Why the rule is UNIFORM, including for files that disclosed nothing.** `glossary.yaml` (Customer, PII, RevenueRecognition), `classifications.yaml` (`EMP-####`), and `adaptive-scopes/scopes.yaml` (`lab-as-mailbox-example`) were **already generic or already synthetic**. They are emptied anyway, and refusing to make an exception for them is the entire point:

> **A per-file "is this one safe enough to ship?" call is exactly how the enforcing SSN policy shipped.** Somebody looked at that file, saw the CreditCards policy at `TestWithoutNotifications`, and shipped the SSN one at `Enable`. A uniform, mechanically-checkable rule cannot be eroded by judgment, because it does not admit judgment.

And "harmless because it is synthetic" is not the same as "harmless because it does nothing". A synthetic adaptive scope still **creates a real adaptive scope in the consumer's tenant**, bound to a filter matching nothing they meant, which other policies then bind to. Only the empty root list is the second thing.

### 2. The four `intentionalSamples` data-plane exclusions are REMOVED, not re-scoped

They asserted "these are samples". They were not. `:!data-plane/**/*.schema.json` stays (JSON-Schema `$id` namespace URIs are genuinely not tenant surfaces). With the root lists empty, there is **no sample content left in the tree to exclude** — the need for the exclusion is removed at the root rather than argued about.

### 3. Three carve-outs. Each named. Each with its reason WRITTEN DOWN. Each pinned by a test

> **A carve-out whose reason is recorded is a rule. A carve-out without one is the erosion this ADR exists to prevent.**

| File | Ruling | Reason |
|---|---|---|
| `classifications/sit-catalog.yaml` | **STAYS POPULATED** | **Reference data, and emptying it would BREAK label deploys.** All 327 entries are `publisher: Microsoft Corporation` — Microsoft built-in SIT definitions, identical in every tenant, tenant-**independent**. **Nothing reconciles it:** there is no `Deploy-SITs.ps1`, and the only script calling `New-`/`Set-`/`Remove-DlpSensitiveInformationType` is `Sync-SITCatalog.ps1`, the **exporter that generates this file**. Every other consumer only READS it. **Decisive:** [`Deploy-Labels.ps1:1262`](../../scripts/Deploy-Labels.ps1) **errors and returns** when a label's `autoApplicationOf.sitId` is absent from the catalog. An empty catalog converts a working reference into a deploy-breaking one. **This carve-out makes the repo safer, which is the only kind this rule admits.** |
| `records/seed-skip-names.yaml` | **STAYS POPULATED** | **A safety input with INVERTED POLARITY — emptying it makes things LESS safe.** `seedSkipNames` is a **skip** list: 31 names `Deploy-FilePlan.ps1` must **not** touch ([ADR 0035](0035-records-seed-content-immovable.md) Decision 3). A populated entry **removes** an object from the plan. Emptying it does not make the reconciler do nothing — it **adds 31 objects back into every `-PruneMissing` run**. Those 31 are Microsoft-provisioned File Plan seed content and are **undeletable** on the documented IPPS surface, so the result is 31 `Failed` rows on every prune: noise that trains operators to ignore prune output, which is how a *real* deletion gets waved through. The names are Microsoft's, identical in every tenant, and disclose nothing. |
| `information-protection/labels.autoApplicationOf.fixture.yaml` | **EXEMPT** | **A test fixture** ([ADR 0017](0017-label-auto-application-shape.md)), named for what it is. **No reconciler reads it:** `Deploy-Labels.ps1` defaults `-Path` to `labels.yaml` on both the Apply and the Export path, and no workflow passes this file to anything. Two synthetic entries; two Microsoft built-in SIT IDs. |

The guard test **pins the carve-out list to exactly these three, by name**, requires each to carry a `Reason` string, and **verifies each reason against the source** rather than trusting it — it greps `scripts/` to confirm no SIT writer exists, greps `scripts/` and `.github/workflows/` to confirm nothing reads the fixture, and asserts the seed-skip baseline is still 31. A fourth carve-out requires editing that test in a reviewed PR. It is a rule, not an escape hatch.

### 4. Config mappings are OUT of the empty-root-list rule — stated, not assumed vacuous

`dspm/dspm-config.yaml` and `dspm-ai/dspm-ai-config.yaml` have root keys that are **mappings** (`scope`, `export`, `posture`), not lists. "Every root list is empty" is therefore **vacuously true** for them — and **a rule that is vacuously satisfied is the bug class this repo keeps hitting.** So the ruling is made explicit and *checked*:

1. **They are not desired state.** There is no `Deploy-DSPM*.ps1`. Their only consumers are read-only verifiers (`Test-DSPMPosture.ps1`, `Test-DSPMforAIPosture.ps1`) and a read-only exporter (`Export-ContentExplorerData.ps1`). [ADR 0022](0022-dspm-for-ai-authoring-surface.md) records that Microsoft Learn documents **no programmatic authoring API** for DSPM for AI at all. **Zero tenant writes** — so there is nothing for a consumer's first dispatch to create. That is the entire hazard, and these files do not carry it.
2. **They carry no tenant-specific values.** Their contents are repo-relative file paths, Microsoft-published workload and role-group names, and numeric knobs.

Both properties are **asserted by the guard test**, which also proves the ruling is not vacuous by checking that these files carry **no root list at all** — so if someone later adds one, the uniform rule in Decision 1 bites automatically. They are not *exempt* from the rule; they simply give it nothing to hold today.

### 5. `collections.yaml`'s `rootCollection` scalar ships UNSET

Emptying `collections:` does not clear the sibling scalar `rootCollection: purview-contoso-lab` — the **Purview account name**. It ships as `null`.

`Deploy-Collections.ps1:852` treats the key as **optional and informational**; the real account binding always comes from `-PurviewAccountName` / `infra/parameters/lab.yaml`, the single source of truth per ADR 0046. When the key *is* present it is a **copy-paste guard**: the reconciler errors if it disagrees with the target account. With `collections: []` there is nothing to root, so a shipped value would be **pure disclosure with zero function**. A spin-off that populates the list should set it to its own account name to re-arm the guard; the template cannot, because the template has no account.

**No `tenantSurfaces` entry is added for any `data-plane/**` file, and that is a decision, not an omission** ([AC 3](https://github.com/marcusjacobson/Purview-as-Code/issues/100) offered either). **An empty root list has no tenant surface to tailor.** The object names that were surfaces (`Scan-DataLakeModernization`, `AzureBlob-SampleData`, collection slugs) no longer ship. They reappear only when a spin-off populates its own desired state from its own tenant via `-ExportCurrentState` — at which point they are **the spin-off's values, authored by the spin-off, and not the template's to walk anyone through**. Adding `tenantSurfaces` rows for files that ship empty would give kickoff 11 rows of nothing to do, which is worse than none: it trains the operator to skip steps.

### 6. The worked content moves to `examples/` — and moving it RELOCATES the disclosure, it does not remove it

The lab content is the only worked example of a populated Purview data plane in the repo, and deleting it outright is a real loss. It moves to [`examples/`](../../examples/) — a tree that **no workflow, script, or schema reads** (asserted by the guard test, which greps `scripts/` and `.github/workflows/` for any path reference into it).

**In-file comments were considered and rejected.** A commented-out enforcing SSN policy still sits in the exact file a reconciler opens: **the fix is a `#`, and the regression is deleting one character.** A directory boundary makes restoring it a deliberate copy across a boundary. It also lets the guard test be **blunt** — *every root list under `data-plane/**` is empty* — and a test that has to parse YAML comments to tell "commented example" from "live entry" is a test that can be fooled.

**And the caveat is the important half.** The repo is public. Relocation without scrubbing would move the disclosure one directory over and call it a fix. So:

- **Every example is scrubbed to synthetic values.** Auto-generated collection IDs → readable slugs. The Databricks workspace, SQL warehouse, and Dataverse org → zero-filled synthetic endpoints. The managed-VNet / integration-runtime names → `contoso` equivalents. The five collapsed `user@contoso.com` rights holders → five **distinct** synthetic groups, which is both honest and what production should look like (bind rights to groups, never to individuals).
- **`examples/**` is IN SCOPE for BOTH scans.** It is deliberately **not** added to `intentionalSamples`, and the ADR 0055 identifier scan has no path exclusions and therefore reads it like everything else. *A path exclusion is the mechanism that hid the last disclosure; relocating content behind one would simply move the blind spot.* Verified non-vacuously: the scan reports **14 GUID occurrences in `examples/**`, all `Allow`ed by `catalogKeys`** — so it demonstrably read the tree.
- **The relocated Microsoft built-in SIT / trainable-classifier IDs need their `catalogKeys` rule to follow them.** Two `(file, key)` pairs are added for `examples/data-plane/dlp/policies.yaml` (`guid`) and `examples/.../auto-label-policies.yaml` (`sitId`). **This is the same rule, not a new escape hatch:** still anchored to `<key>: <guid>` as the whole value, so a bare sequence item under `members:` remains unacquittable in those files and every non-catalog GUID in `examples/**` still **fails closed**.
- **Anything whose only value was as a lab artifact is DELETED, not relocated.** The three `Pilot — … (Lab)` labels ("Remove during lab teardown"). The duplicate `Scan-Scenario1…4`. The typo'd scan. **And `Lab-AutoLabel-SSN`, which does not survive as an example in any form** — a public template has no business carrying a definition of an enforcing tenant-wide SSN auto-labeling policy, in a deploy path or out of one. The guard test hunts for a YAML **definition** of it (an uncommented `name:` binding) across `data-plane/**` and `examples/**`, and separately asserts **no** auto-label policy anywhere in either tree ships at `mode: Enable`. Blocking the *name* is a blocklist and only catches the instance already found; blocking the *shape* is the control.

### 7. The guard test is the deliverable. Everything else is the diff it enforces

[`tests/data-plane/ShippedDesiredState.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.Tests.ps1) is generalised from two hard-coded files to **every root list in the tree**, with the carve-outs named and reasoned. This is what makes "clean" a **build check instead of a claim**.

**It is verified against the broken state, because a guard that passes on the broken state is worthless.** Run against `main` (`9bea348`) it **FAILS**, and the failure message names all 11 files and all 14 populated root lists:

```
Violations: data-plane/adaptive-scopes/scopes.yaml :: scopes has 1 entry(ies);
data-plane/classifications/classifications.yaml :: rules has 1; ... classifications has 1;
data-plane/collections/collections.yaml :: collections has 5;
data-plane/data-sources/data-sources.yaml :: dataSources has 11;
data-plane/dlp/policies.yaml :: policies has 5;
data-plane/glossary/glossary.yaml :: terms has 3;
data-plane/information-protection/auto-label-policies.yaml :: rules has 2; ... policies has 2;
data-plane/information-protection/label-policies.yaml :: labelPolicies has 2;
data-plane/information-protection/labels.yaml :: labels has 13;
data-plane/irm/policies.yaml :: policies has 1;
data-plane/scans/scans.yaml :: scanRulesets has 1; ... scans has 17
```

This is the [ADR 0055](0055-identifier-shaped-residual-scan.md) §Decision-7 lesson applied to its own successor: *verify the check against a planted positive, or you have verified nothing.* The positive here is not planted — it is `main`.

### 8. The no-op is PROVEN, and so is the fact that the fix does something

[`tests/data-plane/ShippedDesiredState.NoOp.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.NoOp.Tests.ps1) drives the reconcilers' **own** desired-state derivation functions (lifted from the scripts by AST, so the top-level bodies that connect to a tenant never run) against the real YAML on disk, and proves two things — **no tenant is contacted**:

- **Claim 1, the fix works.** Shipped YAML ⇒ **zero** desired entries. `Deploy-Labels` and `Deploy-AutoLabelPolicies` then hit an early-return guard that the AST proves precedes **every** tenant write *and* every Apply-path tenant read. `Deploy-Collections` has no early guard (it GETs the tenant first), so the proof is **containment**: every `Invoke-RestMethod -Method PUT` lives inside the `Create` or `Update` clause of the plan switch, and the only producer of those rows is `foreach ($d in $desiredOrdered)`. Zero desired entries, zero iterations, no such row, no PUT. The `DELETE` lives in the `Orphan` clause behind an `if (-not $PruneMissing.IsPresent) { … continue }` gate.
- **Claim 2, the fix was NEEDED.** The same builders, fed a **populated** file, plan **creates** — 10 labels, 16 collections, policies and rules. **A test that only proved claim 1 would also pass against a reconciler that does nothing at all.**

The "populated" input is the **scrubbed `examples/`**, not the pre-change file. Committing the pre-change YAML under `tests/` as a fixture would re-land the disclosure one directory over — Decision 6's mistake, performed inside its own proof. Same shape, synthetic values; shape is all Claim 2 needs.

## Consequences

**Easier.**

- **A consumer's first dispatch is now a no-op.** That is the whole point, and it is now the *default*, not a thing they have to notice.
- **"Is this file safe to ship?" is no longer a question anyone has to answer.** It is answered structurally, for every file, forever. The judgment call that produced `mode: Enable` no longer exists as a step.
- **The rule is mechanically checkable and it is checked**, on every PR, and it is red against the broken state.
- **The knowledge is not destroyed with the data.** `examples/` keeps the only worked Purview data plane in the repo, scrubbed, behind a boundary that makes copying it a deliberate act.
- **`intentionalSamples` is honest again.** It no longer asserts anything false about `data-plane/**`, because there is nothing left in `data-plane/**` to assert about.

**Harder.**

- **A spin-off that adopts a solution must populate its own list AND edit the guard test.** Intended, not incidental — same contract ADR 0055 §Decision-9 set for role groups, now extended to every surface. Adopting a deployable governance surface should cost one deliberate, reviewed edit to the test that guards it.
- **`-ExportCurrentState` is now genuinely mandatory, not merely recommended.** With nothing shipped, the first-run bootstrap is the *only* path to a populated file. That is the correct order of operations and it was always the documented one; it is now the only one.
- **`examples/` is a maintained artefact.** It can drift from the schemas. `yamllint` covers it in `validate.yml`, and the guard test asserts every emptied file has an example to point at — but nothing forward-validates the examples against the reconcilers, and nothing should: the moment something reads `examples/`, it is a deploy path again.
- **A new SIT-bearing example file needs a `catalogKeys` entry.** Same bounded cost ADR 0055 priced; the failure is loud and names the fix.

**Security posture.** Closes the disclosure *and* the misdeployment. The disclosure half (real Databricks / Dataverse / Entra-group / collection identifiers in a public repo) is reconnaissance-grade tenant topology, and it is removed from the tip — the history purge remains [#93](https://github.com/marcusjacobson/Purview-as-Code/issues/93)'s. The misdeployment half is the more serious one and it had no precedent in this repo's threat model: **a public template that creates the author's enforcing governance controls in a stranger's tenant** is not a leak, it is an *action* taken in someone else's environment without their knowledge. Upholds [`security.instructions.md`](../../.github/instructions/security.instructions.md) #1 by removing the material rather than scanning for it, which is the only control that cannot rot.

## Alternatives considered

1. **Comment the content out in place, inside `data-plane/**`.** **Rejected, and it is the most tempting wrong answer** because it looks like it preserves everything at no cost. A commented-out enforcing SSN policy sits in the exact file a reconciler opens; **the fix is a `#` and the regression is deleting one character**. It also forces the guard test to reason about YAML comments to tell a commented example from a live entry — and a test that parses comments to decide what is live is a test that can be fooled. Directory boundary or nothing.

2. **Empty only the *dangerous* files (`auto-label-policies`, `dlp`, `labels`, `label-policies`, `irm`) and keep the harmless ones (`glossary`, `classifications`, `adaptive-scopes`).** **Rejected, emphatically. This is the failure mode, restated as a proposal.** It asks exactly the question — *"is this one safe enough to ship?"* — that produced `Lab-AutoLabel-SSN`, and it asks it of the same person, in the same file, with the same confidence. The value of the rule is that it is **uniform**; a rule with a judgment-shaped hole in it is a suggestion.

3. **Add a name blocklist / a "no `mode: Enable` in `data-plane`" lint and keep the content.** Rejected as the *primary* control (the `mode: Enable` shape check ships anyway, as a second line). A blocklist catches the instance you already found. The token scan could not see a GUID; the identifier scan cannot see a name; a name scan cannot see the *next* thing. **The content is the hazard. Remove the content.**

4. **Move `data-plane/**` into `examples/` wholesale and have the reconcilers read from a new, empty tree.** Rejected. It relocates 29 files, breaks every workflow input default, every script `-Path` default, and every schema `$id`, to achieve exactly what emptying 11 root lists achieves. The blast radius is not justified by the benefit, and a large mechanical diff is where a real change hides.

5. **Delete the lab content outright; write no examples.** Rejected. The worked data plane is genuinely valuable and it is the only one in the repo. **But it is rejected only *because* the content could be scrubbed** — and the parts that could not be (the `Pilot — … (Lab)` teardown fixtures, the typo'd scan, the SSN policy) *were* deleted rather than shipped. "Delete rather than ship" is the tiebreak whenever scrubbing leaves nothing meaningful behind.

6. **Add `:!examples` to `intentionalSamples`.** Rejected, though the issue itself proposed it as "an honest, defensible exclusion" now that the boundary is structural — and it *would* only affect the token scan, never the identifier scan (which cannot have exclusions and is pinned that way). It is still rejected: **a path exclusion is the mechanism that hid the last two disclosures**, the content behind this one was carrying real lab identifiers three days ago, and the cost of not excluding it is that a kickoff operator confirms some expected `contoso` matches. That is a cheap price for keeping the tree in every scan. If the noise proves unbearable, re-open this — but re-open it *deliberately*, in an ADR, and not by adding a line to a list.

7. **Make the repository private.** Explicitly ruled out by the owner. The repo is a template and stays public. Every decision here is downstream of that.

8. **Rely on the kickoff wizard to walk the operator through `data-plane/**`.** Rejected. It would mean adding 11 `tenantSurfaces` entries whose instruction is *"review the author's governance policies and decide which of them you want"* — a security control implemented as a wall of text at the exact moment a new user is least equipped to read it. **The safe default must be safe without being read.** See Decision 5.

## Citations

- [Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically) — Fetch date: 2026-07-14. Documents the `mode` vocabulary (`TestWithoutNotifications` / `TestWithNotifications` / `Enable`) and the simulation-first promotion path that `Lab-AutoLabel-SSN` bypassed.
- [`New-AutoSensitivityLabelPolicy`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-autosensitivitylabelpolicy) — Fetch date: 2026-07-14. The cmdlet the reconciler drives; `-ExchangeLocation All` is the tenant-wide scope the shipped policy used.
- [U.S. Social Security Number (SSN) entity definition](https://learn.microsoft.com/en-us/purview/sit-defn-us-social-security-number) — Fetch date: 2026-07-14. The built-in SIT the enforcing policy matched on.
- [Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions) — Fetch date: 2026-07-14. Establishes built-in SIT IDs as universal Microsoft catalog identifiers, identical in every tenant — the premise the `sit-catalog.yaml` carve-out (Decision 3) and the `catalogKeys` rule both rest on.
- [Encryption in sensitivity labels](https://learn.microsoft.com/en-us/purview/encryption-sensitivity-labels) — Fetch date: 2026-07-14. What `applyLabel: Confidential/Partner` actually does to the mail the shipped policy matched.
- [Microsoft Purview File Plan Manager](https://learn.microsoft.com/en-us/purview/file-plan-manager) — Fetch date: 2026-07-14. The seed content behind the `seed-skip-names.yaml` carve-out (Decision 3).
- [Placeholder examples (Microsoft Writing Style Guide)](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples) — Fetch date: 2026-07-14. The `contoso` / `fabrikam` / `adatum` convention every `examples/**` value was scrubbed to.
- [ADR 0045](0045-template-kickoff-spinoff-model.md) — **the template / spin-off model this defect exploits.** The authority for "this repo is a PUBLIC, tenant-neutral template", and therefore for the fact that the consumer's *first dispatch* — before they have read anything — is the dangerous one.
- [ADR 0046](0046-tenant-placeholder-manifest.md) — **the manifest this amends again.** Its two configuration classes (tenant surfaces to replace; intentional samples to keep) do not cover **shipped desired state**, which is neither. That gap is this ADR.
- [ADR 0055](0055-identifier-shaped-residual-scan.md) — **the identifier scan that passes clean and cannot see this.** It is GUID-shaped by design and structurally cannot match `c8iacz`, a Databricks workspace URL, or `Lab-AutoLabel-SSN`. **A green ADR 0055 run is not evidence of a clean data plane** — say it out loud, or the next reader makes this exact mistake again. This ADR also supersedes its §Decision-2 claim that the four remaining `data-plane` exclusions were "genuinely sample-content files": they were the four carrying the lab config.
- [ADR 0035](0035-records-seed-content-immovable.md) — the 31-name seed-skip baseline behind carve-out 2, and the source of the inverted-polarity reasoning that makes emptying a *skip* list actively unsafe.
- [ADR 0017](0017-label-auto-application-shape.md) — the `autoApplicationOf` shape, and the fixture behind carve-out 3.
- [ADR 0016](0016-auto-label-policy-shape.md) — the auto-label policy shape, its `mode` vocabulary, and the rule that promotion to `Enable` requires the `destructive` PR label. `Lab-AutoLabel-SSN` shipped at `Enable` without one.
- [ADR 0022](0022-dspm-for-ai-authoring-surface.md) — establishes that DSPM for AI has **no programmatic authoring API**, which is the load-bearing fact behind the config-mapping ruling (Decision 4): no authoring API, no reconciler, no desired state.
- [ADR 0023](0023-identifier-resolution.md) — principals are named by `displayName`, never a raw object ID. The `examples/` rights-definition scrub follows it.
- [ADR 0052](0052-destructive-confirmation-gate-at-script-layer.md) / [ADR 0053](0053-overwrite-foreign-author-switch.md) — the destructive-operation contract the empty lists feed, and the house model for template-aware reasoning this ADR follows.
- [ADR 0050](0050-machine-generated-adr-index.md) — why this ADR does **not** add its own row to [`README.md`](README.md)'s "Current ADRs" table: it is generated by `docs-regen.yml` from the H1 / `Status:` / `Gates:` lines above, and no PR — including the one landing a new ADR — hand-edits it.
- [#96](https://github.com/marcusjacobson/Purview-as-Code/pull/96) — **the empty-root-list shape this ADR generalises**, and the source of the `members: []`-means-revoke-everything reasoning that makes "not listed" the only safe default.
- [#93](https://github.com/marcusjacobson/Purview-as-Code/issues/93) — the git-history purge. Independent and out of scope: this ADR makes the **tip** clean; the history is a separate, sequenced decision.
