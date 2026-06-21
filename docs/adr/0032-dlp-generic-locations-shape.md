# 0032 — DLP generic Locations YAML shape and policyTemplateInfo defensive pattern

- **Status:** Accepted
- **Date:** 2026-06-02
- **Gates:** Unblocks issue [#515](../../issues/515) and closes it on merge. Surfaces three follow-up issues for the larger DLP gap discovered during the cross-check: [#519](../../issues/519) (exception buckets), [#520](../../issues/520) (adaptive scopes), [#521](../../issues/521) (rule field expansion umbrella).
- **Deciders:** @contoso

## Context

[`scripts/Deploy-DLPPolicies.ps1`](../../scripts/Deploy-DLPPolicies.ps1) reconciles Microsoft Purview DLP policies against [`data-plane/dlp/policies.yaml`](../../data-plane/dlp/policies.yaml). Through PR #516 (drift closure, ADR 0029 `portal-wins`), PR #518 (ADR 0031 `AdvancedRule` modeling), and the live-tenant cross-check during this PR, three properties on `Get-DlpCompliancePolicy` came into focus that the schema did not model:

1. **`Locations`** — a generic JSON-formatted parameter on `New-DlpCompliancePolicy` carrying `[{ Workload, Location, LocationDisplayName, LocationSource, LocationType, Inclusions, Exclusions }]`. The Microsoft-shipped "Default DLP policy - Protect sensitive M365 Copilot interactions" uses this with `Workload=Applications, Location=Copilot.M365`. PR #516 deferred handling via a `notes:` marker; this ADR ratifies the structured shape.
2. **`EnforcementPlanes`** — a string parameter on `New-/Set-DlpCompliancePolicy`. The Copilot policy sets it to `CopilotExperiences`. Dropping it on round-trip would change the enforcement target on apply.
3. **`PolicyTemplateInfo`** — an object property returned by `Get-DlpCompliancePolicy` that identifies the policy's Microsoft template (the Copilot policy carries `Id=DlpPolicyTemplatesCustom`). Mutating this field via the cmdlet on apply could re-type the policy (e.g. flip a Microsoft-shipped policy to user-authored, breaking Microsoft's distribution-status invariants).

These three properties **must** all be handled together — modeling only `genericLocations:` without `enforcementPlanes:` and `policyTemplateInfo:` would surface drift on the Copilot policy the moment the `notes:` marker came off.

## Decision

### `genericLocations:` shape

We adopt a flattened YAML shape that mirrors the wire JSON one-for-one, with lowerCamelCase keys per repo convention:

```yaml
genericLocations:
  - workload: Applications
    location: Copilot.M365
    locationDisplayName: null    # optional; Microsoft may return null
    locationSource: Unknown      # optional; round-tripped verbatim
    locationType: Unknown        # optional; round-tripped verbatim
    inclusions:
      - type: Tenant
        identity: All
        displayName: All         # optional; preserved for fidelity
        name: All                # optional; preserved for fidelity
    exclusions: []               # optional; same shape as inclusions
```

The `workload` and `location` fields are required; the 3 metadata fields (`locationDisplayName`, `locationSource`, `locationType`) and the `inclusions` / `exclusions` arrays are optional. Three helper functions transform between this YAML and the wire JSON:

- `ConvertFrom-GenericLocationsWire` — parses the wire JSON string from `$Policy.Locations` into a `[object[]]` of normalized entries.
- `ConvertTo-NormalizedGenericLocations` — takes a YAML hash and returns the canonical `[object[]]` shape.
- `ConvertTo-GenericLocationsWire` — emits the JSON string for `-Locations`.
- `ConvertTo-NormalizedGenericLocationsJson` — canonical key-sorted JSON string for `Compare-DlpPolicy` equality.

### `enforcementPlanes:` shape

Modeled as a simple top-level string on `dlpPolicy`. Maps 1:1 to `-EnforcementPlanes` on both `New-` and `Set-DlpCompliancePolicy`.

### `policyTemplateInfo:` defensive pattern

This is the unusual one. The field is **exporter-write / applier-skip**:

- **Schema:** accepts it as an opaque object with `additionalProperties: true`.
- **Exporter** (`Invoke-DlpExport` and `ConvertTo-TenantDlpPolicyHash`): writes the field to YAML so round-trips are byte-equal.
- **Apply path** (`Get-DlpPolicySplat`): **never** emits `-PolicyTemplateInfo` to the cmdlet. The field is preserved in YAML for fidelity but not propagated to mutation calls.
- **Comparator** (`Compare-DlpPolicy`): skips the field entirely. Drift on `policyTemplateInfo` is silently ignored to prevent accidental `Update` operations that could re-type the policy.

Rationale: Microsoft uses this field to identify its built-in policy templates. The PR-#516 cross-check identified the Copilot policy as `DlpPolicyTemplatesCustom`. Mutating this value via the cmdlet has unpredictable consequences (in the worst case, breaking Microsoft's distribution and statistics pipelines). The defensive pattern preserves the field for reader visibility without ever risking it on apply.

### Reconstructed-wire-keys policy

The wire JSON uses PascalCase keys (`Workload`, `Location`, `LocationDisplayName`, etc.). The YAML uses lowerCamelCase (`workload`, `location`, `locationDisplayName`). The transform layer maps between the two casings — the cmdlet accepts the reconstructed PascalCase exactly as Microsoft returns it.

## Consequences

### Positive

- The Microsoft 365 Copilot policy fully round-trips via `genericLocations:` (closes exit criterion 1 of #515).
- The reconciler can now manage policies that use the generic `-Locations` parameter for any future workloads Microsoft ships through that surface (e.g. third-party connectors).
- The `policyTemplateInfo:` defensive pattern prevents the worst-case "re-type a Microsoft-shipped policy" failure mode without requiring the operator to opt-in to skip mode.

### Negative

- The `genericLocations:` transform commits to one specific shape (the one Microsoft returns today). Any new field Microsoft adds inside the wire JSON is captured at the transform boundary; we either model it explicitly or surface it via the existing `notes:` pass-through fallback. The exporter logs unrecognized shapes via the reason field returned by `ConvertFrom-GenericLocationsWire`.
- The `policyTemplateInfo:` exporter-write/applier-skip pattern is unusual — most fields are either fully managed or fully ignored. Operators reading the YAML may be confused by a field that has no apply behavior. Mitigation: the schema description explicitly documents the defensive pattern, and the reconciler header points at this ADR.
- The wire round-trip currently models 3 of ~62 writable cmdlet parameters on `New-DlpCompliancePolicy`. The remaining gap is split across follow-ups #519 (exception buckets), #520 (adaptive scopes), and #521 (rule field expansion umbrella). See the cross-check note on issue #515 for the full inventory.

### Neutral

- The schema gains 3 new top-level fields on `dlpPolicy` (`genericLocations`, `enforcementPlanes`, `policyTemplateInfo`) and 4 new definitions (`genericLocation`, `genericLocationInclusion`, `genericLocationExclusion`, `policyTemplateInfo`).
- Pester coverage extends to: `genericLocations` round-trip (4 contexts), `enforcementPlanes` round-trip (1 context), `policyTemplateInfo` defensive pattern (1 context: schema accepts + splat omits).

## Alternatives considered

### Alternative 1 — keep the PR-#516 `notes:` marker forever

Rejected. The Copilot policy stays inert on apply; any portal-side edit goes undetected; the §5.3 DLP row's drift-closure story stays incomplete.

### Alternative 2 — model `genericLocations:` only, defer `enforcementPlanes` + `policyTemplateInfo`

Rejected. The moment `genericLocations:` lands and the `notes:` marker comes off, `Compare-DlpPolicy` starts comparing every modeled field on the Copilot policy. Without `enforcementPlanes:`, the comparator would surface drift on a field the reconciler can't author cleanly (because it was never read from YAML). Without `policyTemplateInfo:` defensive handling, future Microsoft mutations to the Copilot template could silently re-type the policy on the next apply. The three fields are coupled and must ship together.

### Alternative 3 — model `policyTemplateInfo:` as a fully-managed field (read AND write)

Rejected. The field is tenant-set and Microsoft-controlled; the reconciler has no contract for what's safe to mutate. The defensive exporter-write/applier-skip pattern is the minimum-risk shape that still gives operators full visibility into the policy's template identity.

### Alternative 4 — verbatim PascalCase keys in YAML (skip the case transform)

Rejected. Every other field in `data-plane/dlp/policies.yaml` uses lowerCamelCase per repo convention. Mixing casings inside one schema would break consistency and require operators to learn a second naming convention specific to `genericLocations:`.

## References

- [`New-DlpCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-dlpcompliancepolicy) — defines the `-Locations`, `-EnforcementPlanes`, and `-PolicyTemplateInfo` parameters.
- [`Set-DlpCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-dlpcompliancepolicy) — mutation surface for the apply path.
- [`Get-DlpCompliancePolicy`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-dlpcompliancepolicy) — source of the wire shape this ADR transforms.
- [Microsoft Purview DLP overview](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp) — product context.
- [Data Loss Prevention policy reference](https://learn.microsoft.com/en-us/purview/dlp-policy-reference) — canonical reference for the policy fields modeled here.
- [ADR 0029 — Source-of-truth direction policy](0029-source-of-truth-direction-policy.md) — governs the `portal-wins` direction for the initial sync.
- [ADR 0031 — DLP AdvancedRule YAML shape](0031-dlp-advancedrule-yaml-shape.md) — sibling ADR for the rule predicate transform; this ADR follows the same shape.
- Surfaced by PR for [#515](../../issues/515).
