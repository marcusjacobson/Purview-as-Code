# 0031 — DLP AdvancedRule YAML shape: flattened groups, not verbatim JSON

- **Status:** Accepted
- **Date:** 2026-06-01
- **Gates:** Unblocks issue [#514](../../issues/514) PR A2 (schema + reconciler implementation). Follows [`docs/project-plan.md`](../project-plan.md) §5.3 DLP closure (PR #516, issue [#362](../../issues/362)). Implemented in [#514](../../issues/514) PR A2.
- **Deciders:** @contoso

## Context

[`scripts/Deploy-DLPPolicies.ps1`](../../scripts/Deploy-DLPPolicies.ps1) reconciles Microsoft Purview DLP policies against [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml). It models rule predicates via the per-SIT `sensitiveInfoTypes:` field and the per-label `sensitivityLabels:` field, both of which target the `-ContentContainsSensitiveInformation` parameter of [`New-DlpComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule).

Microsoft also ships rules whose predicate is carried in the cmdlet''s **other** predicate parameter, `-AdvancedRule`. The wire shape `Get-DlpComplianceRule` returns for these rules has `IsAdvancedRule = True` and an `AdvancedRule` JSON string body. As of the v2 §5.3 DLP review (PR #516, issue [#362](../../issues/362)), 11 of 16 tenant rules carry that body and round-trip through the export as inert `notes:` markers:

| Policy | Rule | `IsAdvancedRule` |
|---|---|:---:|
| `Default Office 365 DLP policy` | `Content matches U.S HIPAA Enhanced Default Rule` | True |
| `Default Office 365 DLP policy` | `Content matches Source Code Default Rule` | True |
| `Default Office 365 DLP policy` | `Content Contains Intellectual Property` | True |
| `Default policy for Teams` | `Teams Content matches U.S HIPAA Enhanced Default Rule` | True |
| `Default policy for Teams` | `Teams Content matches Source Code Default Rule` | True |
| `Default policy for Teams` | `Teams Content Contains Intellectual Property` | True |
| `Default policy for devices` | `EndpointDevices Content matches U.S HIPAA Enhanced Default Rule` | True |
| `Default policy for devices` | `EndpointDevices Content matches Source Code Default Rule` | True |
| `Default policy for devices` | `EndpointDevices Content Contains Intellectual Property` | True |
| `Fabric PII Detection - CoA Demo Workspace` | `Detect PII and Financial Data` | True |
| `Default DLP policy - Protect sensitive M365 Copilot interactions` | `Default DLP policy - Protect sensitive M365 Copilot interactions` | True |

The HIPAA Enhanced rule''s wire shape, captured during the [#362](../../issues/362) probe, is representative:

```json
{
  "Version": "1.0",
  "Condition": {
    "Operator": "And",
    "SubConditions": [
      {
        "ConditionName": "ContentContainsSensitiveInformation",
        "Value": [
          {
            "Groups": [
              {
                "Name": "PII Identifiers",
                "Operator": "Or",
                "Sensitivetypes": [
                  { "Name": "U.S. Social Security Number (SSN)", "Id": "a44669fe-0d48-453d-a9b1-2cc83f2cba77", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "Medium", "Minconfidence": 75, "Maxconfidence": 100 },
                  { "Name": "Drug Enforcement Agency (DEA) Number", "Id": "9a5445ad-406e-43eb-8bd7-cac17ab6d0e4", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "High", "Minconfidence": 85, "Maxconfidence": 100 },
                  { "Name": "U.S. Physical Addresses", "Id": "44aa44f2-63d1-41df-af0d-970283ac41e2", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "Medium", "Minconfidence": 75, "Maxconfidence": 100 }
                ]
              },
              {
                "Name": "ICD-9/10 code descriptions",
                "Operator": "Or",
                "Sensitivetypes": [
                  { "Name": "International Classification of Diseases (ICD-10-CM)", "Id": "3356946c-6bb7-449b-b253-6ffa419c0ce7", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "High", "Minconfidence": 85, "Maxconfidence": 100 },
                  { "Name": "International Classification of Diseases (ICD-9-CM)", "Id": "fa3f9c74-ee07-4c52-b5f2-085d6b2c0ec4", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "High", "Minconfidence": 85, "Maxconfidence": 100 },
                  { "Name": "All Medical Terms And Conditions", "Id": "065bdd91-ef07-40d3-b8a4-0aea722eaa49", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "High", "Minconfidence": 85, "Maxconfidence": 100 }
                ]
              },
              {
                "Name": "Names",
                "Operator": "And",
                "Sensitivetypes": [
                  { "Name": "All Full Names", "Id": "50b8b56b-4ef8-44c2-a924-03374f5831ce", "Mincount": 1, "Maxcount": -1, "Confidencelevel": "Medium", "Minconfidence": 75, "Maxconfidence": 100 }
                ]
              },
              {
                "Name": "Trainable Classifiers",
                "Operator": "Or",
                "Sensitivetypes": [
                  { "Name": "dcbada08-65bf-4561-b140-25d8fee4d143", "Id": "dcbada08-65bf-4561-b140-25d8fee4d143", "Classifiertype": "MLModel" }
                ]
              }
            ],
            "Operator": "And"
          }
        ]
      }
    ]
  }
}
```

The structural shape across all 11 captured rules is consistent:

- A two-level outer wrapper (`Condition.SubConditions[0].Value[0]`) that always nests exactly one `ContentContainsSensitiveInformation` predicate at depth 2.
- One **outer-group operator** (`And` or `Or`) that joins **named groups**.
- Each named group has its own operator and a flat list of `Sensitivetypes`.
- A `Sensitivetypes` entry is either (a) a built-in SIT (`Name` = human-readable, `Id` = GUID, `Mincount`/`Maxcount`/`Confidencelevel`/`Minconfidence`/`Maxconfidence`) or (b) a trainable classifier (`Name` = GUID, `Id` = same GUID, `Classifiertype: MLModel`, no count fields).

The question this ADR resolves: **how do we represent that shape in `data-plane/dlp/policies.yaml` such that the reconciler can (a) round-trip it deterministically, (b) diff it field-by-field for drift, and (c) emit it back to `-AdvancedRule` on apply?** Issue [#514](../../issues/514) names two candidates: **(a) verbatim JSON-as-YAML**; **(b) flattened `groups: [{name, operator, sensitiveInfoTypes:[]}]`**.

## Decision

We will adopt **Option B — flattened `groups` shape**, with one minor extension to handle trainable classifiers. The new schema field on `dlpRule`:

```yaml
advancedRule:
  outerOperator: And     # And | Or — joins the entries in `groups:`
  groups:
    - name: PII Identifiers
      operator: Or       # And | Or — joins the entries in `sensitiveInfoTypes:` / `trainableClassifiers:`
      sensitiveInfoTypes:
        - guid: a44669fe-0d48-453d-a9b1-2cc83f2cba77
          minCount: 1
          maxCount: -1
          confidenceLevel: Medium
          minConfidence: 75
          maxConfidence: 100
        - guid: 9a5445ad-406e-43eb-8bd7-cac17ab6d0e4
          minCount: 1
          confidenceLevel: High
          minConfidence: 85
          maxConfidence: 100
    - name: Trainable Classifiers
      operator: Or
      trainableClassifiers:
        - guid: dcbada08-65bf-4561-b140-25d8fee4d143
```

A rule that declares `advancedRule:` cannot also declare `sensitiveInfoTypes:` or `sensitivityLabels:` at the rule level — they are mutually exclusive predicate shapes. The existing `notes:` pass-through stays in the schema for any future Microsoft-shipped predicate shape we have not yet modeled.

The reconciler''s apply path serializes `advancedRule:` back into the wire JSON shown in the Context section and passes it to `-AdvancedRule` on [`New-DlpComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule) / [`Set-DlpComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancerule). The export path inverts the same transform when ingesting a rule with `IsAdvancedRule = True`.

### Why Option B (flattened groups) over Option A (verbatim JSON-as-YAML)

| Concern | Option A — verbatim JSON-as-YAML | Option B — flattened groups |
|---|---|---|
| Schema author burden | Mirror the entire JSON tree (`Condition`, `SubConditions`, `Value`, `Groups`, capitalized keys) in JSON Schema. Two unused wrapper levels (`Condition.SubConditions[0].Value[0]`) appear in every rule. | One new object with three named fields (`outerOperator`, `groups`, plus per-group `name` / `operator` / `sensitiveInfoTypes` / `trainableClassifiers`). |
| Operator visibility | Reader scans down five indent levels to find the `Operator` that actually matters. Two siblings of `Value[0]` are named `Operator` and trip the reader. | Operator is at depth 1 (`outerOperator`) or depth 2 (per-group `operator`). |
| Field-name casing | Microsoft mixes capitalized (`Sensitivetypes`, `Mincount`, `Maxcount`, `Confidencelevel`, `Minconfidence`) with normal-case (`Operator`, `Groups`, `Name`). The repo''s YAML uses lowerCamelCase throughout. Mirroring Microsoft''s casing breaks the convention; renaming on read+write is required either way. | One transform at the export/apply boundary maps the wire casing to lowerCamelCase. The YAML stays consistent with [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml) (`sensitiveInfoTypes`, `minCount`, `confidenceLevel`). |
| Diff vocabulary | Drift surfaces as JSON-path strings (`Condition.SubConditions[0].Value[0].Groups[1].Sensitivetypes[2].Maxcount`). Hard to read in a plan table; harder to write Pester equality for. | Drift surfaces as `advancedRule.groups[1].sensitiveInfoTypes[2].maxCount`. Reuses existing `Compare-DlpRule` vocabulary. |
| Trainable classifiers | Same flat `Sensitivetypes` list with a `Classifiertype` discriminator. Schema cannot easily express "this object is one of two shapes" without an `oneOf` per array element. | First-class `trainableClassifiers:` sibling field on each group. Schema is a simple union of two arrays. |
| `Mincount` / `Maxcount` / `Confidence` semantics | Carried as-is. `-1` sentinel for unbounded is preserved per [ADR 0029](0029-source-of-truth-direction-policy.md) ``portal-wins`` rule and the existing schema rule that already accepts `maxCount: -1` (PR #516). | Same — these fields map 1:1 across the boundary. |
| Round-trip stability against the same tenant | Stable if we preserve every wire field byte-for-byte, including the two unused wrappers. Any cosmetic change (key reorder, whitespace normalization) breaks the round-trip. | Stable because the export is deterministic (the transform is total and lossless for the captured shape). The wire wrappers are reconstructed at apply time. |
| Pester coverage cost | Test fixtures are the verbatim Microsoft JSON. Equality checks are deep `ConvertFrom-Json` comparisons. | Test fixtures are hand-authored YAML matching the schema. Equality checks reuse the existing `Compare-DlpRule` helpers extended for `advancedRule:`. |
| Future Microsoft schema drift | Any new key Microsoft adds inside the JSON tree fails schema validation until the schema is extended. No graceful degradation. | Any new key Microsoft adds inside the JSON tree is captured at the transform boundary; the export can either model it (schema extension) or surface it via the existing `notes:` pass-through (graceful degradation). |
| Documentation cost | The YAML *is* the documentation — the wire shape is what the YAML shows. | One section in the `dlpRule` schema description explaining the flattened mapping. |

Option B wins on every criterion except "the YAML literally matches what `Get-DlpComplianceRule` returns" — which Option A does not actually win either, because the wire response uses capitalized keys that diverge from the repo''s convention.

### Lossless-transform claim

The transform from wire JSON to YAML must be **total** (every captured field maps to a YAML field or is a known-constant wrapper) and **lossless** (round-tripping wire → YAML → wire produces a byte-identical wire shape under Microsoft''s `Get-/Set-DlpComplianceRule` equality semantics).

Captured-field coverage across the 11 [#362](../../issues/362) rules:

| Wire field | YAML field | Notes |
|---|---|---|
| `Version` | constant `"1.0"` reconstructed at apply | Every captured rule has `Version: "1.0"`. If a future rule reports a different value, the exporter falls back to `notes:` pass-through. |
| `Condition.Operator` | constant `"And"` reconstructed at apply | Every captured rule has `Condition.Operator = "And"`. Same fallback rule as `Version`. |
| `Condition.SubConditions[0].ConditionName` | constant `"ContentContainsSensitiveInformation"` reconstructed at apply | Only value observed; falls back to `notes:` for any other. |
| `Condition.SubConditions[0].Value[0].Operator` | `advancedRule.outerOperator` | Direct map, casing normalized. |
| `Condition.SubConditions[0].Value[0].Groups[].Name` | `advancedRule.groups[].name` | Direct map. |
| `Condition.SubConditions[0].Value[0].Groups[].Operator` | `advancedRule.groups[].operator` | Direct map, casing normalized. |
| `Sensitivetypes[].Name` (when not == `Id`) | `sensitiveInfoTypes[].name` | Direct map; optional human-readable name preserved. |
| `Sensitivetypes[].Id` | `sensitiveInfoTypes[].guid` or `trainableClassifiers[].guid` | Routed by presence of `Classifiertype`. |
| `Sensitivetypes[].Mincount` | `sensitiveInfoTypes[].minCount` | Direct map. |
| `Sensitivetypes[].Maxcount` | `sensitiveInfoTypes[].maxCount` | `-1` preserved per PR #516. |
| `Sensitivetypes[].Confidencelevel` | `sensitiveInfoTypes[].confidenceLevel` | Direct map. |
| `Sensitivetypes[].Minconfidence` | `sensitiveInfoTypes[].minConfidence` | Direct map. |
| `Sensitivetypes[].Maxconfidence` | `sensitiveInfoTypes[].maxConfidence` | Direct map. |
| `Sensitivetypes[].Classifiertype` | implicit (entry goes to `trainableClassifiers:` instead) | Discriminator, not surfaced as a YAML field. |

Any wire field outside this list triggers the same `notes:` pass-through fallback that PR #516 introduced. The exporter logs the unrecognized field at INFO so the next [`/build-item`](../../.github/prompts/build-item.prompt.md) run surfaces the drift.

### Foreign-key resolution

Trainable-classifier GUIDs are tenant-resolvable identifiers. Microsoft ships a documented set of [built-in trainable classifiers](https://learn.microsoft.com/en-us/purview/trainable-classifiers-definitions) that are present in every tenant; the [#362](../../issues/362) `dcbada08-65bf-4561-b140-25d8fee4d143` GUID came from a Microsoft-shipped default policy and is one of those built-ins. Customers may additionally publish their own trained models, which surface the same way. The reconciler resolves all trainable classifiers by GUID only — no name lookup, no [`data-plane/classifications/`](../../data-plane/classifications/) cross-reference. A rule that names an unknown classifier GUID errors on apply with the Microsoft response, surfaced verbatim in the plan row's `Reason` column. This matches the existing pattern for built-in SITs in `sensitiveInfoTypes:`.

### Apply-path direction policy

The `advancedRule:` round-trip honors [ADR 0029](0029-source-of-truth-direction-policy.md):

- **`portal-wins`** for the existing 11 [#362](../../issues/362) rules: PR A2''s first export writes their `advancedRule:` body into [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml) and removes the `notes:` markers.
- **`repo-wins`** for any future edit to a rule''s `advancedRule:` body in the YAML: the reconciler emits a `Set-DlpComplianceRule -AdvancedRule '<json>'` call.

## Consequences

### Positive

- The 11 rules captured by [#362](../../issues/362) become fully drift-managed (closes exit criterion 1 of [#514](../../issues/514)).
- The reconciler schema stays close to the existing `sensitiveInfoTypes:` style — readers do not learn a second predicate vocabulary.
- Pester coverage extends the existing helpers (`Compare-DlpRule`, `ConvertTo-DesiredDlpRuleHash`, `ConvertTo-TenantDlpRuleHash`) rather than introducing a parallel test scaffolding.
- The `notes:` pass-through remains as the graceful-degradation fallback for any Microsoft-shipped predicate shape we have not yet modeled (e.g. document-property predicates, document-fingerprint predicates).

### Negative

- The transform introduces a maintenance burden: any new wire field Microsoft adds inside the captured shape is invisible to the schema until the transform is extended. Mitigation: the exporter logs unrecognized fields at INFO and the `notes:` fallback prevents silent data loss.
- The reconstructed wire JSON uses normal-case keys (`Operator`, `Groups`, `Name`, `Sensitivetypes`, `Mincount`, `Maxcount`, `Confidencelevel`, `Minconfidence`, `Maxconfidence`, `Classifiertype`) — i.e., the exact casing Microsoft returns. The cmdlet accepts this casing per the [`New-DlpComplianceRule`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule) reference. Mitigation: the apply path emits a fresh `-WhatIf` against the live tenant during PR A2 validation and confirms zero drift.
- This ADR commits to one specific shape of the `ContentContainsSensitiveInformation` predicate (the only one observed across 11 rules). Other predicate types (`ExceptIfContentContainsSensitiveInformation`, `DocumentMatchesAtLeastOneOf`, etc.) fall through to `notes:` until a future ADR extends the model. Mitigation: this is the explicit "graceful degradation" path, not silent data loss.

### Neutral

- The schema gains one new field (`advancedRule`) and one new `anyOf` clause on `dlpRule`. The existing `sensitiveInfoTypes:` and `sensitivityLabels:` predicates remain.
- PR A2 must extend Pester coverage for: (a) export round-trip of the captured 11-rule sample, (b) apply-path emission of valid `-AdvancedRule` JSON, (c) the mutual-exclusion check between `advancedRule:` and `sensitiveInfoTypes:` / `sensitivityLabels:`, (d) the `Classifiertype` discriminator routing.

## Alternatives considered

### Option A — verbatim JSON-as-YAML

Mirror Microsoft''s wire shape directly:

```yaml
advancedRule:
  Version: "1.0"
  Condition:
    Operator: And
    SubConditions:
      - ConditionName: ContentContainsSensitiveInformation
        Value:
          - Groups:
              - Name: PII Identifiers
                Operator: Or
                Sensitivetypes:
                  - Name: U.S. Social Security Number (SSN)
                    Id: a44669fe-0d48-453d-a9b1-2cc83f2cba77
                    Mincount: 1
                    Maxcount: -1
                    Confidencelevel: Medium
                    Minconfidence: 75
                    Maxconfidence: 100
            Operator: And
```

Rejected because: (a) two-level wrapper noise (`Condition.SubConditions[0].Value[0]`), (b) casing diverges from the repo convention regardless of the wire format, (c) JSON-path diff vocabulary is hostile to plan readers, (d) the schema must encode the unused wrapper levels explicitly.

### Option C — escape hatch: stringified JSON in YAML

Carry the wire JSON as a single quoted string under `advancedRule: |`. Rejected because: drift surfaces as a single opaque string diff with no per-field locality, the schema cannot validate the JSON''s shape, and Pester equality checks degenerate to string comparison.

### Option D — defer indefinitely; keep `notes:` pass-through forever

Rejected because: the 11 rules remain unmanaged in [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml), [#362](../../issues/362) exit criterion 1 stays open indefinitely, and any portal-side edit to one of these rules goes undetected.

## References

- **[Create, test, and tune a DLP policy](https://learn.microsoft.com/en-us/purview/dlp-test-dlp-policies)**
  Fetch date: 2026-06-01 (HTTP 200)
  Background on the DLP rule predicate model the `AdvancedRule` body encodes.
- **[New-DlpComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancerule)**
  Fetch date: 2026-06-01 (HTTP 200)
  Defines the `-AdvancedRule` parameter and its accepted JSON shape. The cmdlet accepts the normal-case keys (`Operator`, `Groups`, `Sensitivetypes`, etc.) that Microsoft''s own `Get-DlpComplianceRule` returns.
- **[Get-DlpComplianceRule](https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancerule)**
  Fetch date: 2026-06-01 (HTTP 200)
  Source of the `IsAdvancedRule` and `AdvancedRule` properties this ADR transforms.
- **[Data Loss Prevention policy reference](https://learn.microsoft.com/en-us/purview/dlp-policy-reference)**
  Fetch date: 2026-06-01 (HTTP 200)
  Canonical reference for the conditions and exceptions vocabulary the `AdvancedRule` body encodes.
- **[Data Loss Prevention overview](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp)**
  Fetch date: 2026-06-01 (HTTP 200)
  Background on DLP policies and rules.
- [ADR 0029 — Source-of-truth direction policy](0029-source-of-truth-direction-policy.md)
  Governs the `portal-wins` direction for the initial sync of the 11 captured rules.
- Surfaced by PR #516 (issue [#362](../../issues/362)).
