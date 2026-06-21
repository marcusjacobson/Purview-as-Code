# 0034 — Microsoft Purview adaptive scope schema: JSON-string `filterConditions`, allowed-attribute set per `LocationType`, no client-side canonicalisation

- **Status:** Accepted
- **Date:** 2026-06-05
- **Gates:** Issue [#551](../../issues/551); unblocks [#550](../../issues/550) (the `scripts/Deploy-AdaptiveScopes.ps1` reconciler + `data-plane/adaptive-scopes/scopes.yaml` schema). Not on [`docs/project-plan.md`](../project-plan.md) §5 (off-arc work follow-up to PR #549).
- **Deciders:** @contoso

## Context

Microsoft Purview adaptive policy scopes ([Microsoft Learn](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes)) are filter expressions evaluated server-side to bind a retention / DLP / IRM / sensitivity-label policy to a dynamically-resolved set of users, groups, or sites. The lab's existing `scripts/Deploy-DLPPolicies.ps1` reconciler already consumes adaptive-scope **references** by name via `Get-AdaptiveScope` at apply time (see [`ConvertTo-AdaptiveScopeRef`](../../scripts/Deploy-DLPPolicies.ps1)). The lab does **not** yet have a desired-state surface for adaptive scopes themselves — there is no `data-plane/adaptive-scopes/` folder, no reconciler, and no schema.

PR #549 shipped [`scripts/New-AdaptiveScope.ps1`](../../scripts/New-AdaptiveScope.ps1) as a one-shot helper to unblock umbrella [#548](../../issues/548) exit criterion 6 (provision at least one lab-tenant adaptive scope so the existing `Deploy-DLPPolicies.ps1` reconciler can exercise one of the 10 new `adaptiveScopes.*` buckets end-to-end). That helper deliberately accepts `-FilterConditions` as an opaque `[hashtable]` pass-through; PR #549''s `.NOTES` block records that validating its shape per `-LocationType` is "the schema-shape question that future ADR will answer." This ADR answers it.

Issue [#550](../../issues/550) is the reconciler-shaped follow-up — `data-plane/adaptive-scopes/scopes.yaml` + JSON-Schema validation + `scripts/Deploy-AdaptiveScopes.ps1` matching the pattern of the 19 existing `Deploy-*.ps1` reconcilers. [`@idea-intake`](../../.github/agents/idea-intake.agent.md) gated [#550](../../issues/550) on this ADR existing at `Status: Accepted` because the YAML shape (`filterConditions` as a string vs a structured object), the JSON-Schema validation rules, and the Pester contract all encode this ADR''s decisions directly.

### Schema-shape probe (2026-06-05, against `contoso.onmicrosoft.com`)

The empirical findings from the [#548](../../issues/548) provisioning attempt that motivate this ADR — without them, the schema would be authored against the Microsoft Learn-published example, which is **wrong** in three places. Recorded here so the schema and Pester decisions have an audit trail.

The probe attempted to provision a single `lab-as-mailbox-marcus` `User`-scope adaptive scope filtered to one mailbox via `New-AdaptiveScope` directly (bypassing `New-AdaptiveScope.ps1` to isolate the cmdlet''s validation surface). Six iterations were required to characterise the validator''s behaviour:

| Attempt | `-FilterConditions` shape | Cmdlet response | Inference |
|---|---|---|---|
| 1 | PS hashtable, doubly-nested `Conditions[]` per Learn example, `Property` key on leaf | `Invalid filter conditions. Context: at depth 1. Error: Unexpected value type for key 'Conditions'. Expected type: System.Object[]` | Hashtable input rejected at outer wrapper; `Object[]` check fails on what is already `Object[]` in PowerShell. |
| 2 | Flat hashtable (single-level `Conditions[]`), `Property` key | same depth-1 error | Confirms outer wrapper rejection is not nesting-related. |
| 3 | `[object[]]@(…)` force-typed inner, `Conjunction = 'And'` added to outer | `Invalid filter conditions. Context: at depth 1. Error: Unexpected value type for key 'Conditions'. Expected type: System.Object[]` | Type coercion of inner array doesn''t help — hashtable input rejected wholesale. |
| 4 | Doubly-nested hashtable with `Conjunction` at every level | same depth-1 error | Hashtable input is rejected regardless of shape. |
| 5 | **JSON string** (single-level wrapper, `Property` key on leaf) | `Invalid filter conditions. Context: at depth 2. Error: Hashtable is missing 'Name' key.` | Past depth-1 — JSON-string input is the working transport. Leaf shape is wrong: cmdlet wants `Name` not `Property`. |
| 6 | JSON string, leaf with `Name = 'UserPrincipalName'` | `'UserPrincipalName' is an invalid attribute name.` | Past depth-2 — schema-valid shape but `Name` rejected. Attribute-name allowlist is gated. |

A subsequent probe iterated through 11 candidate `Name` values to characterise the `User`-scope attribute allowlist. Results: **5 attributes pass the cmdlet''s schema check** (`Alias`, `Department`, `Title`, `Office`, `City`); **6 are rejected** as `<attribute> is an invalid attribute name` (`Mail`, `PrimarySmtpAddress`, `UserPrincipalName`, `WindowsLiveID`, `State`, `Country`, `CompanyName` — Microsoft Learn does not publish the allowlist; it has to be probed). All 5 schema-valid attributes return a server-side `Object reference not set to an instance of an object` when the cmdlet actually attempts the tenant write. The lab tenant was confirmed at 0 adaptive scopes after the probe completed — no test artifacts persisted.

The probe is documented in the [#548](../../issues/548) provisioning attempt thread (chat-only; not committed). Re-run the probe before this ADR ships if the cmdlet''s validator behaviour shifts.

### The Microsoft Learn published example is wrong in three places

The [Microsoft Purview adaptive policy scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes) and [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope) pages publish PowerShell hashtable examples for `-FilterConditions`. The 2026-06-05 probe demonstrates three divergences from cmdlet behaviour:

1. **Input transport.** Learn shows `-FilterConditions @{…}`. Cmdlet rejects hashtable; accepts JSON string only.
2. **Leaf key.** Learn shows `@{ Property = '...'; Operator = 'Equals'; Value = '...' }`. Cmdlet wants `Name` (not `Property`).
3. **Allowed attribute set.** Learn implies `UserPrincipalName` works for User scopes. Cmdlet rejects it; the actual `User`-scope allowlist is `Alias` / `Department` / `Title` / `Office` / `City`. The allowlist for `Group` and `Site` scopes is not yet probed (deferred per Decision §2).

A naive schema author would copy the Learn example and produce a YAML shape that fails at apply time. Recording this divergence is the primary reason this ADR exists separately from [#550](../../issues/550)''s implementation work.

### Three candidate shapes for the YAML / cmdlet boundary

- **(a) Structured YAML, reconciler builds the JSON.** YAML declares `filterConditions:` as a nested map per Learn-style shape; the reconciler walks the map and emits the JSON string. **Rejected.** Would force the schema to model the cmdlet''s actual quirks (the `Name`/`Property` divergence, the implicit `Conjunction` requirement at every level, the type-coercion gymnastics from probe attempts 1–4). When Microsoft changes any quirk, the schema and the reconciler both have to change in lockstep. Reviewer reading the YAML would also see a shape that does not match any Learn page.
- **(b) JSON-string passthrough.** YAML declares `filterConditions:` as a string containing a JSON document. Reconciler validates it is well-formed JSON with `Test-Json -Json $body` and passes it through to `New-AdaptiveScope -FilterConditions` / `Set-AdaptiveScope -FilterConditions` unchanged. Cmdlet enforces the actual schema; reconciler is decoupled from cmdlet quirks. **Accepted.** Trade-off: YAML readability is lower than a structured map (the string contains punctuation and quoting), but the YAML matches the cmdlet''s actual contract and degrades gracefully when Microsoft fixes the quirks.
- **(c) Defer the schema; use the `New-AdaptiveScope.ps1` one-shot only.** Drop [#550](../../issues/550) entirely; rely on the imperative helper for every adaptive-scope provision. **Rejected.** The lab already has 19 declarative reconcilers; adaptive scopes are the only catalog domain with no desired-state surface. The reconciler-shaped pattern is what makes drift detectable and reviewable across the rest of the catalog.

## Decision

We will:

### Decision 1 — YAML / cmdlet boundary: `filterConditions` is a JSON string

In `data-plane/adaptive-scopes/scopes.yaml`, each `scopes[]` entry declares `filterConditions` as a **string** containing a JSON document. The reconciler does NOT parse, transform, or canonicalise the JSON body beyond a single `Test-Json -Json $body` call to confirm well-formed JSON. The string is passed through to `New-AdaptiveScope -FilterConditions` / `Set-AdaptiveScope -FilterConditions` unchanged.

Rationale: probe attempts 1–4 showed the cmdlet rejects every hashtable shape; probe attempt 5 confirmed the JSON-string transport works. The Microsoft Learn-published hashtable examples are incorrect against the current cmdlet (verified 2026-06-05). Adopting JSON-string passthrough decouples our schema from the cmdlet''s quirks: when Microsoft fixes the validator to accept hashtables (or updates Learn to match the validator), our YAML keeps working unchanged.

JSON-Schema validation in `data-plane/adaptive-scopes/scopes.schema.json` declares `filterConditions: { type: string, minLength: 2 }` (the minimum well-formed JSON is `{}`). The reconciler''s `Test-Json -Json` call is the second validation layer — the schema check confirms the field is present and a string; the `Test-Json` check confirms it is well-formed JSON. The cmdlet itself is the third layer (depth-1 wrapper, depth-2 leaf, depth-2 attribute-name).

Reference: [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope), [`Test-Json`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json).

### Decision 2 — Allowed `Name` attribute set per `LocationType`

The `User`-scope leaf `Name` attribute allowlist is exactly: `Alias`, `Department`, `Title`, `Office`, `City` (probed 2026-06-05). The reconciler does NOT enforce this allowlist client-side — the cmdlet is the source of truth, and the reconciler treats `<attribute> is an invalid attribute name` from the cmdlet as the operator''s signal to either pick a different attribute or open an issue to re-probe.

The `Group`-scope and `Site`-scope attribute allowlists are **NOT probed yet**. The ADR explicitly marks them as `TODO: probe required`. When the first `Group`-scope or `Site`-scope entry lands in [`data-plane/adaptive-scopes/scopes.yaml`](../../data-plane/adaptive-scopes/scopes.yaml), the implementing PR re-probes the cmdlet for that `LocationType` and amends this ADR in place with the discovered allowlist (dated update note pattern from [ADR 0033](0033-dlp-rule-tracked-field-expansion.md) §3).

Rationale: client-side allowlist enforcement would replicate cmdlet behaviour that may change without notice (Microsoft has not published the allowlist on Learn; the only way to discover it is by probing). Mirroring server-side validation client-side would create a class of bug where the schema rejects values the cmdlet accepts, or accepts values the cmdlet rejects. The cmdlet error message is already actionable.

Reference: [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope), [Microsoft Purview adaptive policy scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes).

### Decision 3 — Round-trip stability: no client-side JSON canonicalisation

The reconciler does NOT canonicalise the `filterConditions` JSON string on `-ExportCurrentState`. Round-trip stability comes from the tenant''s own canonical output — `Get-AdaptiveScope` returns the field as a string, and the reconciler writes that string back to YAML unchanged. The reconciler''s drift comparator compares the two strings byte-for-byte.

Rationale: the tenant produces a canonical form; the reconciler preserves it. Two consequences follow:

1. If a human edits `filterConditions:` in YAML by hand and the resulting JSON is byte-equivalent but key-order-different from the tenant''s canonical form, the next `-WhatIf` will report drift and `apply` will rewrite the tenant to the YAML form. This is the same drift detection pattern every other reconciler uses and the operator sees the rewrite in the `-WhatIf` plan before it happens.
2. If Microsoft changes the canonical form server-side between two `-ExportCurrentState` runs (e.g. adds whitespace, changes key order), every committed scope will drift back. **If this surfaces during [#550](../../issues/550) implementation, this ADR is amended in place** and a canonicaliser is added (the same `ConvertTo-Normalized…Json` sorted-keys pattern used by [`ConvertTo-NormalizedAdaptiveScopesJson`](../../scripts/Deploy-DLPPolicies.ps1) and [`ConvertTo-NormalizedAdvancedRuleJson`](../../scripts/Deploy-DLPPolicies.ps1) per [ADR 0031](0031-dlp-advancedrule-yaml-shape.md)). Until then, the simpler byte-for-byte comparator wins.

Reference: [`Get-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope), [`Set-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-adaptivescope).

### Decision 4 — Known blocker carry-forward: server-side NRE

`New-AdaptiveScope` returns `Object reference not set to an instance of an object` after the cmdlet schema check passes, on all 5 schema-valid `User`-scope attributes (probed 2026-06-05). The probe did not isolate the cause; probable candidates (in order of decreasing plausibility):

1. **SKU prerequisite.** Adaptive scopes are gated on Microsoft Purview / Microsoft 365 E5 or specific compliance add-ons; the lab tenant may be missing a required SKU. Microsoft Learn does not currently document the SKU matrix for adaptive scopes by `LocationType` as of 2026-06-05.
2. **Exchange recipient cache miss.** The cmdlet may need a recipient cache warm-up before the first scope can be created against a tenant with no prior adaptive-scope activity.
3. **Tenant-config gap.** A one-time enable step (analogous to `Enable-OrganizationCustomization` for some EXO cmdlets) may be required.

This ADR documents the blocker as a **tenant-side gap**, not a reconciler design problem. [#550](../../issues/550) ships with its `-WhatIf` and `-ExportCurrentState` paths unaffected — both are read-only and work against a zero-scope tenant. The first `apply` against a real scope in the lab is gated on resolving this NRE separately (out of scope for [#550](../../issues/550) and for this ADR; file a new issue if you want it actioned).

Reference: [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope), [Microsoft Purview adaptive policy scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes), [App-only authentication for Exchange Online / S&C PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2).

## Consequences

**Easier:**

- **[#550](../../issues/550) becomes implementable.** The YAML field shape, the JSON-Schema validation rules, and the reconciler''s drift comparator are all specified by Decisions 1 and 3. [`@idea-intake`](../../.github/agents/idea-intake.agent.md) for [#550](../../issues/550) does not have to re-derive any of them.
- **PR #549''s `.NOTES` placeholder gets resolved.** The script comment that says "the schema-shape question that future ADR will answer" gets a concrete back-reference to this ADR.
- **The Microsoft Learn divergence is documented once.** Future contributors who read the Learn pages and try to author a structured YAML schema find this ADR''s probe table before they spend an afternoon iterating against `Invalid filter conditions` errors.
- **The cmdlet stays the source of truth.** Client-side allowlist enforcement is rejected (Decision 2), so when Microsoft adds a new attribute or `LocationType`, the YAML / reconciler / schema do not need a coordinated update — only the optional re-probe-and-amend cycle.

**Harder:**

- **YAML readability is lower than a structured map.** A reader of `scopes.yaml` sees `filterConditions: '{"Conjunction":"And","Conditions":[...]}'` instead of a nested YAML block. Mitigation: each entry in the shipped `scopes.yaml` carries a YAML comment above `filterConditions:` describing its intent in prose, and the reconciler emits a pretty-printed `-WhatIf` summary with the JSON parsed back out for human inspection.
- **The `Group` / `Site` allowlists are TODO.** The first `Group`-scope or `Site`-scope entry in `scopes.yaml` will trigger a re-probe and an amend-in-place update to this ADR. The implementing PR''s `@idea-intake` Step 0 must surface the TODO as a gate.
- **The server-side NRE blocker carries forward.** The first `apply` against a real scope in the lab is gated on tenant-side investigation that is not in scope for [#550](../../issues/550) or this ADR. [#548](../../issues/548) EC6 remains blocked.

**Security principles (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):**

- **#4 (least privilege).** Adaptive scopes the reconciler creates are bounded by the `Name`-based filter in `filterConditions`; the operator''s YAML edit is the only authoring surface (Decision 1) and the reconciler does not introduce new dynamic-membership patterns.
- **#9 (idempotent and reversible).** The JSON-string passthrough means a scope can be removed with `-PruneMissing` and re-created from the same YAML byte-for-byte; round-trip stability (Decision 3) is the property that lets the reconciler''s `-WhatIf` accurately predict the apply.
- **#10 (OWASP-aware).** The reconciler does not interpret `filterConditions` content client-side, so there is no class of bug where the schema accepts a JSON payload the cmdlet would have rejected as malformed — `Test-Json` plus cmdlet-side validation is the layered defence.

**Project-plan items:**

- Unblocks: [#550](../../issues/550) (the reconciler PR).
- Does not affect: any [`docs/project-plan.md`](../project-plan.md) §5 row. [#548](../../issues/548), [#549](../../issues/549), [#550](../../issues/550), and this ADR are all off-arc follow-ups to the DLP `adaptiveScopes.*` work shipped with PR #526.

## Alternatives considered

- **Structured YAML, reconciler builds the JSON.** Rejected per Context §"three candidate shapes" (a). Forces the schema to encode cmdlet quirks that may change without notice; couples our schema to a cmdlet contract Microsoft has not stabilised on Learn.
- **Defer the schema entirely; use only the [`New-AdaptiveScope.ps1`](../../scripts/New-AdaptiveScope.ps1) one-shot.** Rejected per Context §"three candidate shapes" (c). Leaves adaptive scopes as the only catalog domain without a desired-state surface; drift across other reconcilers'' `adaptiveScopes.*` references becomes invisible.
- **Client-side allowlist enforcement of `Name` per `LocationType`.** Rejected per Decision 2 rationale. Mirroring cmdlet behaviour client-side creates a class of bug where the schema and the cmdlet disagree about allowed values; the cmdlet''s error message is already actionable.
- **Client-side JSON canonicalisation (sorted keys, compact form).** Rejected per Decision 3 rationale. Adds reconciler complexity for a property the tenant already provides via its canonical output. If round-trip drift surfaces during [#550](../../issues/550) implementation, this ADR is amended in place to add a canonicaliser (the [ADR 0031](0031-dlp-advancedrule-yaml-shape.md) `ConvertTo-Normalized…Json` precedent). The simpler default wins until proven insufficient.
- **Wait for Microsoft to fix the cmdlet validator or document the actual contract on Learn.** Rejected because the wait-time is unbounded and [#550](../../issues/550) is ready to ship now against the validator''s actual current behaviour. If Microsoft fixes the validator later, Decision 1''s JSON-string passthrough still works (the JSON string is a valid input for a hashtable-accepting cmdlet too, via the same `ConvertFrom-Json` deserialization Microsoft would presumably use internally).
- **Investigate the server-side NRE blocker in the same ADR / PR.** Rejected per Decision 4 rationale. The NRE is a tenant-side gap, not a reconciler design problem; conflating the two would block [#550](../../issues/550) on tenant-config investigation that is independent of the schema decisions.

## Citations

- [`New-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-adaptivescope) — the cmdlet whose validator behaviour Decisions 1, 2, and 4 are all based on. The PowerShell hashtable example on this page is what the 2026-06-05 probe contradicts.
- [`Get-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-adaptivescope) — the read-back cmdlet that Decision 3 relies on for round-trip stability.
- [`Set-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-adaptivescope) — the update cmdlet that obeys the same `-FilterConditions` schema as `New-AdaptiveScope`.
- [`Remove-AdaptiveScope`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-adaptivescope) — the delete cmdlet used by `-PruneMissing` in the [#550](../../issues/550) reconciler.
- [Microsoft Purview adaptive policy scopes](https://learn.microsoft.com/en-us/purview/purview-adaptive-scopes) — the concept page whose published example shape is what Decision 1 contradicts.
- [`Test-Json`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) — the well-formed-JSON validator used in Decision 1''s second validation layer.
- [App-only authentication for Exchange Online / S&C PowerShell](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2) — the auth model the [#550](../../issues/550) reconciler inherits from [`scripts/Deploy-AutoLabelPolicies.ps1`](../../scripts/Deploy-AutoLabelPolicies.ps1) and PR #549''s [`scripts/New-AdaptiveScope.ps1`](../../scripts/New-AdaptiveScope.ps1).
- [ADR 0016 — Auto-labeling policy shape](0016-auto-label-policy-shape.md) — closest reconciler-shape precedent (IPPS-based, YAML/cmdlet boundary documented up-front).
- [ADR 0029 — Source-of-truth direction policy for data-plane reconcilers](0029-source-of-truth-direction-policy.md) — the contract the [#550](../../issues/550) reconciler''s `-DirectionPolicy` / `-SkipNames` switches obey.
- [ADR 0031 — DLP `AdvancedRule` YAML shape](0031-dlp-advancedrule-yaml-shape.md) — precedent for the `ConvertTo-Normalized…Json` canonicaliser this ADR''s Decision 3 defers.
- [ADR 0033 — DLP rule tracked-field expansion](0033-dlp-rule-tracked-field-expansion.md) — precedent for the dated update-note pattern referenced by Decisions 2 and 3.
- [`scripts/Deploy-DLPPolicies.ps1`](../../scripts/Deploy-DLPPolicies.ps1) — existing consumer of adaptive-scope references (`ConvertTo-AdaptiveScopeRef`, `Resolve-AdaptiveScopeMap`, `ConvertTo-NormalizedAdaptiveScopesJson`).
- [`scripts/New-AdaptiveScope.ps1`](../../scripts/New-AdaptiveScope.ps1) — the PR #549 one-shot helper whose `.NOTES` placeholder this ADR resolves.
