# 0055 — The residual scan must be identifier-shaped and fail closed; a token-shaped scan cannot verify the absence of a GUID

- **Status:** Accepted
- **Gates:** Cross-cutting security control. **Amends [ADR 0046](0046-tenant-placeholder-manifest.md) by supersession** — its §Decision-3 claim that "scanning everything *except* these paths means any remaining match is a genuine missed tenant surface" is **unsound and is withdrawn**, and its `intentionalSamples` blanket `:!data-plane` exclusion is narrowed to the sample-content paths it was actually written for. ADR 0046 remains `Accepted`; only that claim and that exclusion are amended. Ships the [`scripts/Test-IdentifierResidue.ps1`](../../scripts/Test-IdentifierResidue.ps1) scanner, the `identifierScan` manifest block (`schemaVersion` 2 → 3), the `identifier-residue` job in [`validate.yml`](../../.github/workflows/validate.yml), and the first Pester tests in this repository that read a **shipped** `data-plane/**` YAML ([`tests/data-plane/ShippedDesiredState.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.Tests.ps1)). Enforces the [ADR 0023](0023-identifier-resolution.md) Category-3 principal shape mechanically for the first time. Complementary to, and independent of, the `HEAD` scrub (merged), the history purge ([#93](https://github.com/marcusjacobson/Purview-as-Code/issues/93)), and the `displayName` migration ([#95](https://github.com/marcusjacobson/Purview-as-Code/issues/95)) — this is the **control**; those are the **cleanup**. No [`docs/project-plan.md`](../project-plan.md) §5 / §8 row: this is repo-safety infrastructure, following the ADR 0046 and ADR 0050 precedent.
- **Deciders:** @marcusjacobson

## Context

This repository is a **PUBLIC, tenant-neutral template** ([ADR 0045](0045-template-kickoff-spinoff-model.md)). Consumers create a copy, and the kickoff wizard tailors it to a real tenant. Everything below follows from that: a defect in the template is not one lab's defect, it is every downstream copy's defect, and the template's own contents are world-readable the entire time.

Real Entra security-group object IDs — **15 distinct**, in **active** desired-state rows, each annotated with the group's purpose, including the owner's break-glass PIM group and the group wrapping the CI service principal — sat committed in `data-plane/purview-role-groups/role-groups.yaml` and `data-plane/entra-directory-roles/role-assignments.yaml`, in `origin/main`, in a public repo, for weeks. They are scrubbed at `HEAD`. That is not what this ADR is about.

**This ADR is about the fact that nothing noticed.**

The repo had the right rule. It had the right convention. It had the right alternative design. And it shipped the identifiers anyway:

- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) "Environment and identifier boundaries" forbids real principal object IDs in source and mandates the zero-GUID placeholder.
- [ADR 0023](0023-identifier-resolution.md) §Decision Category 3 already decided the alternative: an Entra principal is carried in YAML by its stable `displayName` and resolved to an object ID at deploy time by [`Get-EntraPrincipalIdByDisplayName.ps1`](../../scripts/Get-EntraPrincipalIdByDisplayName.ps1). A raw object ID under `members:` was a violation of a decision made **before those files were written**.
- [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) restates the boundary in prose.
- `copilot-instructions.md` line 150 goes further and literally **specifies the grep**: *"Reject any PR diff that contains a 32-character hex or GUID pattern that does not match the zero-GUID placeholder. Grep: `grep -E '[0-9a-f]{8}-...'`"*.

**The policy was not missing. The policy was not even vague. It was written as a shell command — and no machine ever ran it.** That is the whole lesson, and it is the reason this document exists rather than a fourth restatement of the rule.

### Why ADR 0046's scan could not see it — two independent failures, either fatal alone

[ADR 0046](0046-tenant-placeholder-manifest.md) §Decision-3 committed to this claim:

> "Scanning everything *except* these paths means any remaining match is a genuine missed tenant surface, not sample-data noise."

**The claim is false**, and it fails twice over.

**Failure 1 — the blanket path exclusion.** [`tenant-placeholders.yaml`](../../.github/agents/tenant-placeholders.yaml) `intentionalSamples` carried:

```yaml
  - ":!data-plane"     # sample catalog content (stcontosolabblob, sql-contosolab-demo, sample UPNs)
```

The exclusion was written for one concern — sample storage-account names and sample UPNs in the catalog content — and it silently swallowed another: it excluded **the entire tree that holds the desired state**, including the two files carrying live privileged group OIDs. The comment on the line is an accurate description of *why it was added* and a completely inaccurate description of *what it does*. An exclusion justified by one file's contents was applied to a directory.

**Failure 2 — the pattern is token-shaped and cannot match a GUID.** Even with the exclusion deleted, `residualScan.pattern` is:

```yaml
  pattern: 'contoso|onmicrosoft\.com|OWNER-PLACEHOLDER'
```

A raw GUID contains no `contoso`, no `onmicrosoft.com`, no `OWNER-PLACEHOLDER`. **This pattern would not have matched a single one of the 15 object IDs even if it had been pointed directly at the files.** Removing the path exclusion, on its own, would have fixed nothing.

The two failures are independent. Fixing either one alone still ships the leak.

### How the identifiers got in — the durable lesson, and the part worth remembering

This is the provenance, and it generalises far beyond this repo.

`data-plane/**` is the owner's **real lab, string-substituted**. The desired-state files were not authored as fiction; they were **exported from a live tenant** (`-ExportCurrentState`), then genericized for publication as a template. Genericization was a **token substitution**: `contoso` for the real org, `contoso.onmicrosoft.com` for the real domain, `purview-contoso-lab` for the real account.

Then the verification scan looked for **exactly the tokens that substitution had produced**.

> **Genericization replaced tokens. The verification scan looked for tokens. GUIDs are not tokens — so they survived the substitution *and* they survived the verification, and they landed in the one directory the scan was configured to ignore.**

The scan was not weak. It was **circular**. It verified the thing that was easy to verify, which was precisely the thing the transform had already handled. It had no purchase at all on the class of data the transform did not touch — and that class is exactly the class that is dangerous, because a value that survives genericization unchanged is, by definition, a value that is still real.

The generalisable rule, for the next reader and the next ADR:

> **A verification that shares its model of the world with the transform it verifies is not a verification. If a transform is token-shaped, its check must be *shape*-agnostic — it must ask "is anything here still real?", not "did I replace the strings I know about?".**

ADR 0046 asked the second question and reported the answer to the first.

### Why more reconciler tests would NOT have caught this — the hazard is in the DATA

The reflex fix is "add test coverage". It would not have worked, and the reason is worth pinning.

[`Deploy-PurviewRoleGroups.Tests.ps1`](../../tests/scripts/Deploy-PurviewRoleGroups.Tests.ps1) already carries ~20 `It` blocks, several of which pin *revoke-everything-on-empty-members* as a **required contract**. The reconciler was correct. Its tests were correct. And the shipped `role-groups.yaml` carried ~50 `members: []` rows **and** 10 real object IDs anyway.

The reason is structural: **before this ADR, zero tests in this repository loaded a shipped `data-plane/**` YAML.** Every test builds its own in-memory fixture and asserts against that. So the code that consumes the data was tested exhaustively and the data itself was tested not at all — while the hazard lived entirely in the data.

> **A defect in a shipped artefact can only be caught by a test that reads the shipped artefact.** Fixture-based tests, however thorough, are structurally blind to it.

## Decision

**We will add a second, IDENTIFIER-shaped residual scan that FAILS CLOSED, runs on every PR, and has no path exclusions of any kind.**

### 1. The ADR 0046 soundness claim is withdrawn

ADR 0046 §Decision-3's "any remaining match is a genuine missed tenant surface" is **amended by supersession**. It is true only of the *token* surface, and only for the paths it scans. It was never a statement about identifier-shaped data, and it must not be read as one. `residualScan` keeps its job — finding un-substituted tokens — and the manifest now says so in terms:

> *This pattern is TOKEN-shaped. It is NOT, and never was, a check that the repo is free of real tenant identifiers.*

Two scans, two shapes, two jobs. Neither substitutes for the other.

### 2. The blanket `:!data-plane` exclusion is narrowed to the sample content it was written for

`intentionalSamples` no longer excludes the tree. It now excludes only the genuinely sample-content files (`data-sources.yaml`, `scans.yaml`, `labels.yaml`, `collections.yaml`) and the JSON-Schema `$id` namespace URIs. The desired-state files are **scanned** by the token scan again, and the ~8 header-comment matches this surfaces across `data-plane/**` are real stale-after-tailoring prose an operator *should* confirm.

### 3. The identifier scan has NO path exclusions. None. Not for `tests/`, not for `docs/`, not for `data-plane/`

**This is the load-bearing decision and it is not negotiable by convenience.** A path exclusion is the mechanism that caused the disclosure. Re-introducing one — for any directory, for any reason, however well-commented — recreates it. The manifest's `identifierScan` block therefore has no exclusion key at all, and [a Pester test asserts that it never grows one](../../tests/scripts/Test-IdentifierResidue.Tests.ps1), so adding one requires re-litigating this ADR in review rather than slipping a line into a diff.

### 4. Fail closed: every non-zero GUID is guilty until a rule acquits it

The scanner walks **every tracked file** and treats every GUID-shaped token as a `Finding` unless one of four manifest rules claims it. A new real object ID, in a new file, under a new key, **fails** — because no rule enumerates it. That is the entire point:

> **A scan that only knows about the places we already looked would have missed this leak too.**

### 5. The allow-list is the hard part, and it is shape-aware, not path-aware

There are **~385 distinct non-zero GUIDs** in this repo and almost all of them are legitimate, tenant-**independent** Microsoft constants. **A scan that cries wolf 385 times gets disabled, which is worse than no scan.** Getting the allow-list right *is* the work. Four rules, in precedence order:

| # | Rule | Acquits by | Covers |
|---|---|---|---|
| 1 | `syntheticShapes` | **shape** | The zero GUID; the reserved fixture namespace `00000000-0000-0000-0000-<counter>`; repeated-nibble fixtures (`aaaaaaaa-…`); two named synthetic literals. |
| 2 | `catalogKeys` | **(file, key)** | Microsoft catalog identifiers: ~330 built-in SIT + rule-pack IDs under `sit-catalog.yaml` `id:`/`rulePackId:`, trainable-classifier + SIT IDs under `dlp/policies.yaml` `guid:`, `sitId:` in the two auto-label YAMLs. |
| 3 | `microsoftConstants` | **exact value** | The 10 constants with no enclosing key to hang a rule on: Entra role `templateId`s, Azure RBAC role-definition IDs, Microsoft first-party app / app-role IDs. |
| 4 | `reviewRequired` | **SHA-256 of the value** | Quarantine. Identifiers of *unresolved provenance*. Reported as `Review`, not `Finding`. |

**Rule 1 replaces a `tests/**` path exclusion, and that substitution is the design in miniature.** Fixtures are acquitted for **looking synthetic**, never for **living in `tests/`**. A real object ID pasted into `tests/` still fails — as it must, because `tests/` is exactly where a "harmless" copy-paste of live tenant output goes. (This is not hypothetical: the scan's first run against the post-scrub tree found a live-looking sensitivity-label GUID in a `Deploy-LabelPolicies` fixture, sitting next to a synthetic sibling. It is replaced with a synthetic in this PR.)

**Rule 2 is keys, not values, and the reasoning is about human behaviour, not machines.** Enumerating ~330 SIT IDs by value would work, and it would fail closed. It is still the wrong choice: it makes **every SIT-catalog refresh an allow-list PR**, which trains reviewers to rubber-stamp allow-list additions — and *a reviewer in the habit of rubber-stamping allow-list additions is precisely how a real object ID gets waved through*. The allow-list's job is to be **read**. Four reviewable `(file, key)` pairs are safer than a 330-line value list nobody reads. Rule 3 enumerates by value only where structure gives us nothing to hold: a Bicep `var`, a PowerShell literal, a GUID in prose.

**Rule 2 is still fail-closed, and the disclosure is the proof.** The match is anchored to `<key>: <guid>` as the **whole value**. The leak was a **bare YAML sequence item**:

```yaml
    members:
      - <raw object id>   # sg-purview-...
```

That carries **no key**. It cannot be acquitted by rule 2 in any file, including an allow-listed one — and a Pester test plants an object ID under a *new* key inside `sit-catalog.yaml` to prove the allow-listing of that file is `(file, key)`-scoped and not a safe harbour for the whole file. Per ADR 0023, no legitimate key ever carries a raw principal ID, so there is nothing for a future rule to be tempted to add.

**Residual risk, stated rather than glossed:** a real object ID written into `sit-catalog.yaml` under `id:` *would* be acquitted. That file is machine-generated by `Sync-SITCatalog.ps1 -ExportCurrentState` from the SIT catalog API, which cannot return a group object ID, so there is no code path that produces this. It is a real hole and it is the price of not training reviewers to rubber-stamp. It is recorded here so the next reader can re-price it rather than rediscover it.

### 6. `reviewRequired` is a quarantine, not an escape hatch

The scan's first run found two GUIDs in [ADR 0035](0035-records-seed-content-immovable.md) pasted verbatim from an interactive `Get-FilePlanPropertyDepartment` probe **against the owner's live tenant**. ADR 0035 argues the seed properties are Microsoft-managed — and therefore that these are Microsoft constants — but that is an **inference, not a verified fact**, and ADRs are immutable so the redaction decision is the owner's. Severity is low: a records-management property GUID discloses no admin topology.

The tempting move is to file them under `microsoftConstants` and go green. **That is laundering, and it is the exact failure this design exists to prevent** — it would convert "we don't know" into "Microsoft says so" with no evidence, in the allow-list, permanently. So instead:

- They are `Review` rows: loud warnings and CI annotations, but not a build break.
- They are keyed by **SHA-256, never by value** — the manifest does not restate an identifier whose provenance is in doubt.
- **The list is pinned by a Pester test.** It cannot grow without editing that test, which is a deliberate, visible review signal.

A quarantine that can be extended silently is an escape hatch. This one cannot be.

### 7. The scan reads tracked **and untracked-not-ignored** files — and the reason is the same mistake, one level down

The first cut enumerated `git ls-files` only. That is defensible on the threat model ("what is committed is what leaks") and it is **wrong in practice**, because it makes a brand-new file invisible until it is staged. A contributor writes a file holding a real object ID, runs the scan, is told **PASS**, commits — and finds out in CI.

**A local PASS that a later commit turns into a FAIL is worse than no local run at all, because it is trusted.**

This is not a hypothetical, and it is too instructive to leave out: **this scanner's own test file slipped past this scanner's own local run** for exactly this reason. It was untracked, so `git ls-files` did not list it, so the scan did not read it, so it reported clean — and CI failed on the first push. The scan was, for one commit, blind in precisely the way this ADR was written to condemn: *it could not see the thing it was checking.* The fix is `git ls-files` **+** `git ls-files --others --exclude-standard`, and a Pester test now pins it.

Gitignored files stay out, deliberately: they never reach the remote, and they are where local tenant exports legitimately land ([ADR 0021](0021-dspm-content-explorer-cadence.md)'s exporter artifact directory).

### 8. It runs on every PR, because an onboarding-only scan cannot catch a regression

The ADR 0046 scan ran only in the `@operator-tenant` Step 6 onboarding flow. The object IDs entered via a scaffold commit and **nothing looked at them again**. The `identifier-residue` job in [`validate.yml`](../../.github/workflows/validate.yml) runs on every pull request and every push to `main`. The manifest gains the identifier pass too, so the kickoff wizard's Step 6 inherits it — but CI, not onboarding, is where the control actually lives.

### 9. The shipped data is tested, not just the code that reads it

[`tests/data-plane/ShippedDesiredState.Tests.ps1`](../../tests/data-plane/ShippedDesiredState.Tests.ps1) is the first test in this repo to load a **shipped** `data-plane/**` YAML. It asserts:

1. **Template-only:** `roleGroups: []` and `directoryRoles: []` ship empty. Not merely a privacy default — a **safety** default. *Not listed* is the only shape that means *not managed*: a role group **listed** with `members: []` means "this role group must have zero members", and under `-Apply -PruneMissing` the reconciler revokes every existing assignment. The empty **root** list hits a pre-flight no-op that returns before any tenant read or write. A tailored spin-off that adopts these solutions will populate the lists and this assertion will fail — **intentionally**. Adopting a tenant-wide role-grant surface should require a deliberate edit to the test that guards it.
2. **Every copy, forever:** no raw GUID appears under any principal key (`members`, `principals`, `owners`, …) in any shipped `data-plane/**` YAML. This is [ADR 0023](0023-identifier-resolution.md) Category 3, enforced mechanically for the first time since it was accepted in May. It survives tailoring and must stay green in every spin-off.

[`tests/Run-Pester.ps1`](../../tests/Run-Pester.ps1) is widened from `tests/scripts` to `tests/` so `tests/data-plane/` is actually discovered — it would otherwise have been a file that never ran, which is its own kind of theatre.

## Consequences

**Easier.**

- **The disclosure class is now mechanically impossible to ship silently.** Verified, not asserted: run against the pre-scrub commit with today's manifest, the scan **fails and flags exactly the 15 object IDs**, while correctly acquitting the three Microsoft role `templateId`s sitting in the same file. A scan that cannot catch the leak it was built for is theatre; this one catches it.
- **`copilot-instructions.md` line 150 finally has a machine behind it.** The rule stops being a grep command written in prose that nobody runs.
- **[ADR 0023](0023-identifier-resolution.md) is enforced instead of merely decided.** Category 3 has been the rule since 2026-05-24 and was violated in the shipped data for weeks.
- **Every downstream consumer inherits the control on day one.** A spin-off's first `-ExportCurrentState` pulls real object IDs out of *their* tenant into *their* YAML. The scan is the thing standing between that and their first `git push` — and per [ADR 0053](0053-overwrite-foreign-author-switch.md)'s template reasoning, the local path is the one that actually works in a fresh copy, so a repo-local, credential-free check is exactly the right shape of defence.
- **The token scan's honesty is restored.** It now says what it is: a token scan.

**Harder.**

- **The allow-list is a maintained artefact.** A new Microsoft constant, or a new catalog file, needs a manifest entry with a name and a citation, or CI goes red. This is the cost, it is deliberate, and it is bounded: 10 value entries and 4 `(file, key)` pairs cover ~385 GUIDs.
- **A new SIT-bearing data-plane file needs a `catalogKeys` entry.** The failure is loud, the message names the fix, and adding a `(file, key)` pair is a reviewable one-line diff.
- **Test fixtures must use the reserved synthetic namespace.** Pasting a GUID from a real tenant into a fixture now fails the build. That is the feature.
- **A tailored spin-off that adopts role groups must edit `ShippedDesiredState.Tests.ps1`.** Stated in Decision 9; intended, not incidental.
- **The scan is O(tracked files).** ~2s locally on this repo. Not a concern; noted so nobody has to re-measure.

**Security posture.** Upholds [`security.instructions.md`](../../.github/instructions/security.instructions.md) #1 (no secrets/real identifiers in source) by making it **enforceable** rather than aspirational — the first time any mechanism in this repo has verified it. Object IDs are identifiers, not credentials: there is nothing to rotate, and this ADR does not pretend otherwise. What they are is **reconnaissance-grade tenant topology** in a public repo — they disclose which privileged groups exist and which tenant-wide roles they hold — which is why the control matters even though the incident has no rotation story. The scanner is read-only, makes no tenant calls, needs no credential, and **redacts every identifier it reports to its first 8 hex characters**, because CI logs on a public repo are public and a scanner that publishes the leak it found would be self-defeating.

## Alternatives considered

1. **Fix only the `:!data-plane` exclusion and keep the token pattern.** Rejected — it fixes nothing. The pattern cannot match a GUID. This is the single most tempting wrong answer, because the exclusion is the *visible* bug and it is the one the incident report leads with. Failure 2 is the one that actually kills you.

2. **Fix only the pattern (add a GUID regex) and keep the blanket exclusion.** Rejected — symmetrically useless. A GUID regex that never looks at `data-plane/` is a GUID regex that never looks at the desired state. Either fix alone still ships the leak; this pairing is why the ADR insists both failures are named.

3. **Path-based allow-list: skip `tests/`, `docs/`, `data-plane/classifications/`.** **Rejected, emphatically — this is the thing that caused the incident.** It is also the easiest design to reach for, because it makes the false-positive count go to zero in about ten minutes. Every path exclusion is a standing promise that nothing dangerous will ever be written under that path, and the disclosure is the proof that such promises are not kept: `:!data-plane` was written in good faith, for a real reason, by someone who was right about the files they were looking at. Shape-aware and value-aware rules cannot decay this way, because they do not encode a promise about a *place*.

4. **Enumerate all ~385 GUIDs by value.** Rejected. It fails closed and it would work — the objection is human, not technical. It makes every SIT-catalog refresh an allow-list PR, and a reviewer who approves allow-list additions weekly is a reviewer who will approve the one that matters. See Decision 5.

5. **Entropy / heuristic detection ("does this GUID look tenant-real?").** Rejected. GUIDs are opaque by construction; a v4 SIT ID and a v4 group object ID are statistically indistinguishable. Any such heuristic is a coin flip dressed as a control, and it would fail *open* on exactly the values that matter.

6. **Secret-scanning tooling (GitHub secret scanning, `gitleaks`, `trufflehog`).** Rejected as the primary control, though complementary. Those tools hunt **credentials** — high-entropy strings with issuer-specific formats and a revocation story. An Entra group object ID is a bare v4 GUID with no distinguishing format and nothing to revoke; it is indistinguishable from the ~385 legitimate GUIDs this repo ships on purpose. The discrimination this problem needs is **repo-specific semantic knowledge** (which keys, in which files, mean what) and that knowledge lives in the manifest, not in a generic scanner. A tool that cannot tell a Credit Card SIT ID from a break-glass group OID would either flag all 385 or none.

7. **Block only on `data-plane/**` and warn elsewhere.** Rejected. It is a path exclusion wearing a severity label, and it re-imports Alternative 3's failure mode through the back door. The label-GUID that this scan found in a `tests/` fixture is the direct counter-example: a warn-only `tests/` would have printed it and moved on.

8. **Run it only in the kickoff/onboarding flow, as ADR 0046 did.** Rejected. An onboarding-only scan cannot catch a regression, and the disclosure is the proof: the object IDs entered by a scaffold commit and nothing looked at them again. See Decision 7.

9. **Add the two ADR 0035 GUIDs to `microsoftConstants` and go green.** Rejected. Their provenance is a live-tenant probe and their Microsoft-managed status is an inference. Filing an unverified identifier under "Microsoft constant" is laundering, and doing it *inside the ADR that exists to stop exactly this* would be indefensible. See Decision 6.

10. **Edit ADR 0035 to redact them, in this PR.** Rejected. ADRs are immutable ([`README.md`](README.md) line 5), the redaction is out of this issue's scope, and the `HEAD`-scrub-vs-history-purge sequencing is the owner's to manage ([#93](https://github.com/marcusjacobson/Purview-as-Code/issues/93)). Quarantined instead, with the required owner decision recorded in the manifest entry itself (ownerDecision:) and ready-to-file issue text handed over in the PR that lands this ADR.

11. **Do nothing; rely on the existing prose rules.** Rejected. The prose rules existed, were correct, were specific, and were restated in four files — one of which spelled out the exact grep. The repo shipped 15 real object IDs to a public repository anyway, and for weeks. **The gap was never policy. It was that nothing mechanically verified the policy.**

## Citations

- [Placeholder examples (Microsoft Writing Style Guide)](https://learn.microsoft.com/en-us/style-guide/a-z-word-list-term-collections/term-collections/placeholder-examples) — Fetch date: 2026-07-13. The zero-GUID placeholder convention that `syntheticShapes` rule 1 ratifies and extends into the reserved fixture namespace.
- [Microsoft Entra built-in roles](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference) — Fetch date: 2026-07-13. Source of the three directory-role `templateId` constants in `microsoftConstants`; documents that role template IDs are tenant-independent, which is what makes them safe to commit and safe to allow-list by value.
- [Azure RBAC built-in roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles) — Fetch date: 2026-07-13. Source of the five role-definition GUID constants (Contributor, Key Vault Crypto User, Key Vault Contributor, Key Vault Certificate User, Key Vault Certificates Officer) used in `infra/modules/automation-rbac.bicep` and `New-AutomationCertificate.ps1`.
- [Verify first-party Microsoft applications in sign-in reports](https://learn.microsoft.com/en-us/troubleshoot/entra/entra-id/governance/verify-first-party-apps-sign-in) — Fetch date: 2026-07-13. Source of the Office 365 Exchange Online first-party application ID constant.
- [App-only authentication for unattended scripts (Exchange Online PowerShell)](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) — Fetch date: 2026-07-13. Source of the `Exchange.ManageAsApp` app-role ID constant.
- [Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sit-sensitive-information-type-entity-definitions) — Fetch date: 2026-07-13. Establishes that built-in SIT IDs are universal Microsoft catalog identifiers, identical in every tenant — the premise the `catalogKeys` rule rests on.
- [Microsoft Entra groups — role-assignable groups](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept) — Fetch date: 2026-07-13. The group-object-ID surface that was disclosed.
- [gitglossary — pathspec](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-pathspec) — the `:!` exclude syntax whose blanket use in `intentionalSamples` is narrowed by Decision 2.
- [ADR 0046](0046-tenant-placeholder-manifest.md) — **the ADR this one amends by supersession.** Its §Decision-3 soundness claim is withdrawn and its `:!data-plane` exclusion narrowed; the manifest and the `residualScan` / `functionalWorkflowScan` blocks otherwise stand.
- [ADR 0045](0045-template-kickoff-spinoff-model.md) — **the template / kickoff spin-off model.** The authority for "this repo is a PUBLIC, tenant-neutral template", which is why a committed object ID is every downstream copy's problem and not just one lab's, and why the control must ship *in the template* rather than be added per-consumer.
- [ADR 0023](0023-identifier-resolution.md) — **the principal-shape decision the leaked data violated.** Category 3: an Entra principal is carried by `displayName` and resolved at deploy time; a raw object ID in YAML was already forbidden when these files were written. This ADR is the first mechanism that enforces it.
- [ADR 0053](0053-overwrite-foreign-author-switch.md) — the house model for template-aware reasoning, and the source of the two-configuration-classes distinction (`lab` Environment tenant config, absent by design; `OWNER_APPROVAL_LOGIN` repo-governance config, present and correctly *not* a tenant surface). This ADR does not conflate them.
- [ADR 0050](0050-machine-generated-adr-index.md) — why this ADR does **not** add its own row to [`README.md`](README.md)'s "Current ADRs" table: the table is generated by `docs-regen.yml` from the H1 / `Status:` / `Gates:` lines above, and no PR — including the PR that lands a new ADR — hand-edits it.
- [ADR 0035](0035-records-seed-content-immovable.md) — holds the two GUIDs of unresolved provenance quarantined by Decision 6. Immutable; the redaction decision is the owner's, recorded as the ownerDecision: field on each quarantine entry.
- [#93](https://github.com/marcusjacobson/Purview-as-Code/issues/93) — the git-history purge. Independent of this ADR: this is the control that stops the next one, that is the cleanup of the last one. The scan deliberately reads the **working tree**, not history, so it neither depends on nor blocks the purge.
- [#95](https://github.com/marcusjacobson/Purview-as-Code/issues/95) — the `displayName` migration, which moves the desired-state files onto the ADR 0023 Category-3 shape this scan enforces. Complementary: #95 makes the data right, this ADR makes it stay right.
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries", and line 150, which specified this scan as a grep command and was never executed by anything.
- [`.github/instructions/sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md) — the prose assertion that built-in SIT GUIDs are schema/reference identifiers and not tenant-real. Decision 5 rule 2 makes that prose machine-enforceable.
