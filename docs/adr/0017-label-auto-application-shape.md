# 0017 — Per-label client-side auto-application shape (recommendation / automatic conditions on labels.yaml)

- **Status:** Accepted
- **Date:** 2026-05-13
- **Gates:** Stress-test campaign on Information Protection ([#208](../../issues/208)). Predecessor for the taxonomy rewrite issue tracked in the stress-test brief.
- **Deciders:** @contoso
- **Related:** [ADR 0015](0015-label-policy-shape.md) (publishing policies), [ADR 0016](0016-auto-label-policy-shape.md) (service-side auto-labeling policies).

## Context

Sensitivity labels (#65) carry metadata that, in addition to content marking and encryption, can declare **client-side auto-labeling conditions** — recommend-mode and auto-apply-mode rules surfaced by Office apps (Word, Excel, PowerPoint, Outlook) when a user is editing content. These are distinct from the service-side auto-labeling policies covered by [ADR 0016](0016-auto-label-policy-shape.md): the latter run inside Exchange / SharePoint / OneDrive against data at rest and in flight, do not require an editing user, and live in a separate cmdlet family (`*-AutoSensitivityLabelPolicy` / `*-AutoSensitivityLabelRule`). Client-side conditions are a property of the **label itself**, configured through `Set-Label`, and surface to end users through the Office client at edit time.

Wave 1 [#65](../../issues/65) / [#68](../../issues/68) shipped `labels.yaml` and its schema without any block for client-side auto-application because the placeholder taxonomy did not exercise the feature. The Information Protection stress-test campaign (see brief `main-20260513-2350-stress-test-info-prot-taxonomy.md`) now needs to rebuild the taxonomy to Microsoft Learn best practice, which means encoding recommend / automatic conditions directly on the relevant sublabels (e.g., "Highly Confidential / Financial — recommend when 1+ Credit Card Number detected"). The schema and the YAML shape have to land first so the taxonomy rewrite has a valid place to put the conditions.

[ADR 0016](0016-auto-label-policy-shape.md) §4 already established the SIT-reference shape used by service-side auto-labeling rules — `sitId` (GUID, present in `sit-catalog.yaml`), `minCount` (integer ≥ 1, default 1), `minConfidence` (integer 0-100, default 75). This ADR adopts the same shape on the client-side surface to keep the two YAMLs consistent for review and so the future reconciler can share validation helpers.

The exact `Set-Label` cmdlet plumbing for client-side conditions is **Learn-silent at the published-parameter level**: the public cmdlet reference at [`Set-Label`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label) does not enumerate a `-AutoApplicationOf` parameter, and the [Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically) doc covers the feature behaviorally rather than at the cmdlet-argument level. Per the "When Learn is silent or contradicts training data" rule in [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md), this ADR commits to a **YAML shape** sourced from the user-facing concepts that Learn does document, and explicitly defers the cmdlet-arg translation to the reconciler PR that follows the taxonomy rewrite. The shape is therefore versioned here even though the wire format is not.

## Decision

1. **Field is optional and additive.** `autoApplicationOf` is an optional property on each `labels[]` entry in `labels.yaml`. Omitting it is unambiguously "this label has no client-side condition." Adding it is a no-op for the current `Deploy-Labels.ps1` (the script ignores unknown-to-it fields when normalizing entries); a future reconciler PR will read it. Existing `labels.yaml` files are unaffected by the schema change; `Test-Json` continues to pass without modification.

2. **Shape — `mode`, `policyTip`, `sensitiveInformationTypes`.** When present, the block declares:
   - `mode` (string, required) — enum `Recommend` | `Automatic`. The two end-user behaviors documented at [Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically#how-to-configure-auto-labeling-for-office-apps): `Recommend` prompts the user; `Automatic` applies without prompting.
   - `policyTip` (string, optional, ≤280 chars) — text shown to the user when the condition matches. 280-char ceiling chosen to match the existing `tooltip` field on the same label and the Office client constraint cited there.
   - `sensitiveInformationTypes` (array, required when block present, `minItems: 1`) — list of SIT-based conditions. Each entry uses `sitId` / `minCount` / `minConfidence` exactly as [ADR 0016](0016-auto-label-policy-shape.md) §4 defines them, so SIT references look the same across `labels.yaml` and `auto-label-policies.yaml`.

3. **No grouping operator, no per-condition workload, no advanced settings — first cut.** The schema does **not** accept:
   - `groupingOperator` (multi-SIT AND/OR logic). Learn does not document the cmdlet plumbing for client-side grouping; defer per [ADR 0016](0016-auto-label-policy-shape.md) §4's identical decision for the service-side rule.
   - Per-condition workload scope. Office apps decide which clients evaluate the condition; the schema does not pretend to override that.
   - An `advancedSettings:` map. Empty allowlist by default, same gating principle as [ADR 0015](0015-label-policy-shape.md) §3 and [ADR 0016](0016-auto-label-policy-shape.md) §5.

   Any of these can be added in a future ADR follow-up with a Microsoft Learn citation. The schema's `additionalProperties: false` on the block makes the rejection a schema-validation error, not silent acceptance.

4. **SIT reference shape — `sitId` GUID + bounded count + bounded confidence.** Each `sensitiveInformationTypes[]` entry MUST carry a `sitId` whose value is a 36-char GUID pattern. The reconciler that lands after this ADR is responsible for verifying that the GUID is present in `data-plane/classifications/sit-catalog.yaml`; the schema cannot do that cross-file check. `minCount` defaults to 1 (minimum-viable trigger). `minConfidence` defaults to 75 (Microsoft Learn's recommended "high-confidence" threshold for the SIT entity-definition pages where a number is given); the schema bounds it 0-100 inclusive.

5. **Round-trip strategy — deferred to the reconciler PR.** This ADR does not change `Deploy-Labels.ps1`. The reconciler PR that follows the taxonomy rewrite will:
   - Add `autoApplicationOf` to the normalized hashtable produced by `ConvertTo-LabelHash` and `ConvertTo-TenantLabelHash`, with a sort + canonicalization step on `sensitiveInformationTypes` to make hash-equality round-trip-stable.
   - Translate the YAML block to whatever `Set-Label` parameter(s) Microsoft ships for this surface (Learn-silent today; the reconciler PR commits the translation against the lab tenant and cites the verified-on date).
   - Emit the block back in `-ExportCurrentState` so an Export → Apply round-trip diffs clean.

   This split keeps the schema PR free of speculative cmdlet plumbing.

6. **Fixture file accompanies the schema, lives next to it.** `data-plane/information-protection/labels.autoApplicationOf.fixture.yaml` ships in this PR. It exercises one `Recommend` and one `Automatic` entry against synthetic SIT references taken from `sit-catalog.yaml` (Credit Card Number `50842eb7-edc8-4019-85dd-5a5c1f2bb085` and U.S. Social Security Number (SSN) `a44669fe-0d48-453d-a9b1-2cc83f2cba77`, both published by Microsoft). The file is not referenced by any deploy workflow (path filters are exact: `data-plane/information-protection/labels.yaml`), is not the default `-Path` of `Deploy-Labels.ps1`, and serves only as a permanent `Test-Json` smoke-test target for future contributors. It carries a top-of-file comment marking it as a fixture.

7. **Branding and identifier hygiene.** The fixture uses Microsoft-published built-in SIT GUIDs (already vendored in `sit-catalog.yaml` from [#80](../../issues/80)). No real tenant, subscription, principal, customer, or PII identifiers appear in this PR. Per [`sample-data.instructions.md`](../../.github/instructions/sample-data.instructions.md), the Microsoft-published SIT GUIDs are reference identifiers, not customer data.

## Consequences

**Easier:**

- Stress-test taxonomy rewrite unblocks: each sublabel can carry its recommend / automatic conditions inline.
- Schema review surface is narrow: two new `$defs` (`autoApplicationOfBlock`, `sensitiveInformationTypeCondition`) and one `$ref` slot on `label.properties.autoApplicationOf`.
- SIT references look identical on both YAMLs; the future reconciler can reuse the same validation helper across `labels.yaml` and `auto-label-policies.yaml`.
- Round-trip discipline preserved: future Export emits the block exactly as the YAML declared it, modulo the canonicalization specified in §5.

**Harder:**

- The reconciler PR that follows is non-trivial: it has to verify the cmdlet plumbing against the lab tenant, cite the verified-on date in code comments, and add a tracked-fields entry so drift is detected. None of that work belongs in the schema PR.
- A schema that accepts a field the reconciler currently ignores is a footgun. The taxonomy-rewrite PR must NOT populate `autoApplicationOf` until the follow-up reconciler PR has landed; otherwise an Apply would silently skip the user's intent. The stress-test campaign sequencing already accounts for this — schema first (this PR), reconciler-translation next, taxonomy rewrite that uses the block last.
- `Test-Json` does not enforce the cross-file SIT-GUID-exists-in-catalog check. The reconciler PR has to add that check explicitly and emit a clear error message; a follow-up issue tracking that check should be filed alongside the reconciler PR.

**Security principles (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#1 (no secrets).** The block is metadata; nothing in it carries credentials or keys.
- **#9 (idempotent, reversible, auditable).** Adding a recommend-mode condition is non-destructive (user can decline). Adding an automatic-mode condition is destructive in the sense that it labels content without user action — the taxonomy-rewrite PR that introduces the first `Automatic` entry must carry the `destructive` PR label per [`pre-commit.instructions.md`](../../.github/instructions/pre-commit.instructions.md).
- **#10 (OWASP-aware).** `policyTip` strings are surfaced to users by the Office client; the schema bounds them at 280 chars to limit injection-via-policy-tip surface.

## References

- **[Apply a sensitivity label to content automatically](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)**
  Fetch date: 2026-05-13
  > "When you create a sensitivity label, you can automatically assign that label to content when it matches conditions that you specify."
- **[Set-Label](https://learn.microsoft.com/en-us/powershell/module/exchange/set-label)**
  Fetch date: 2026-05-13
  Microsoft Learn does not currently document a top-level `-AutoApplicationOf` parameter as of this fetch date. The reconciler PR will commit the verified parameter shape against the lab tenant.
- **[Sensitive information type entity definitions](https://learn.microsoft.com/en-us/purview/sensitive-information-type-entity-definitions)**
  Fetch date: 2026-05-13
  Built-in SIT GUIDs (Credit Card Number, U.S. Social Security Number) sourced via `data-plane/classifications/sit-catalog.yaml` from issue [#80](../../issues/80).
- [ADR 0015](0015-label-policy-shape.md) — sibling shape decision for sensitivity-label publishing policies.
- [ADR 0016](0016-auto-label-policy-shape.md) — sibling shape decision for service-side auto-labeling policies (SIT reference shape reused verbatim).