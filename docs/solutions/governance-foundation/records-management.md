# Records Management — retention labels and file plan

Operational guide for [`scripts/Deploy-FilePlan.ps1`](../../../scripts/Deploy-FilePlan.ps1) — the reconciler that materializes [`data-plane/records/file-plan.yaml`](../../../data-plane/records/file-plan.yaml) against the Microsoft Purview Records Management surface (retention labels + six kinds of file plan property objects). Pairs with [`data-lifecycle.md`](data-lifecycle.md) (the policy/rule surface that consumes the labels defined here).

## Purpose

Reconciles two cmdlet families:

- [`*-ComplianceTag`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag) — retention labels.
- `*-FilePlanProperty<Kind>` — file plan property objects across six kinds: [Authority](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertyauthority), [Category](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertycategory), [Citation](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertycitation), [Department](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertydepartment), [ReferenceId](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertyreferenceid), [SubCategory](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertysubcategory).

Emits Create / Update / NoChange / DriftWarn / Orphan / Skipped decisions per object. Labels support the full Create / Update lifecycle via `Set-ComplianceTag`. File plan property objects have **no `Set-*` cmdlet** — drift on an existing property surfaces as `DriftWarn` only; the reconciler cannot in-place update a property and never attempts to. The operator must remove and recreate the property by hand after detaching dependent labels (which itself requires removing every label that references it).

The records model is documented at [Learn about records management](https://learn.microsoft.com/en-us/purview/records-management):

- A retention label may be a **plain label** (default), a **record label** (`isRecordLabel: true`), or a **regulatory record label** (`regulatory: true`). Both flags are **irreversible** once any content has been tagged.
- `retentionAction` is one of `Keep` / `Delete` / `KeepAndDelete`.
- `retentionType` is one of `ModificationAgeInDays` / `CreationAgeInDays` / `TaggedAgeInDays` / `EventAgeInDays`. The schema currently rejects `EventAgeInDays` pending the event-type bootstrap in [#82](../../../../issues/82).
- A label may bind to a file plan property object by `name` (resolved at apply time). The schema enforces referential integrity between `subCategories[*].parentCategory` and a declared category.

## Default state

The shipped YAML declares empty lists across all six property kinds plus `retentionLabels: []`. With no labels declared, no records-management retention is enforced. The reconciler reports `Tenant labels : 0` and exits without writes. Add the first declaration only when an explicit records requirement applies.

### Microsoft seed content (immovable)

Every Microsoft 365 tenant ships **31 Microsoft File Plan Manager seed property objects** that cannot be deleted via any documented IPPS surface (3 authorities, 13 categories, 5 citations, 10 departments — full per-kind list in [ADR 0035 §The 31 seed names](../../adr/0035-records-seed-content-immovable.md)). The reconciler reports these as `Orphan` rows by default; the CI workflow baseline supplies the 29 unique seed names via `skip_names_records` so every dispatch is noise-free. See [§CI wiring](#ci-wiring) below.

## Authentication

Same Key Vault-side JWT signing path as every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT (header `alg=PS256`, `x5t#S256`) and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate's underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/records/file-plan.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch — DESTRUCTIVE: removes orphan tenant labels and property objects (the 31 Microsoft seeds reject `Remove-*` regardless; pair with `-SkipNames` per [ADR 0035](../../adr/0035-records-seed-content-immovable.md)) |
| `-Force` | switch — with `-ExportCurrentState`, allow overwriting a non-empty YAML |
| `-ExportCurrentState` | switch — write tenant state back into YAML (round-trip) |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` — ADR 0029 source-of-truth direction policy |
| `-SkipNames` | string array — workflow-supplied pre-computed skip list; applies to both labels and property rows by bare `Name` (case-insensitive); ignored in `audit` mode |
| `-SkipSchemaValidation` | switch — bypass the JSON Schema gate (emergency only) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | Reads `Get-ComplianceTag` plus one `Get-FilePlanProperty<Kind>` per kind; prints planned Create / Update / NoChange / DriftWarn / Orphan / Skipped rows. No writes. |
| (default) | Same read, then per-row `New-` / `Set-ComplianceTag` for label Create / Update, and `New-FilePlanProperty<Kind>` for property Create. Property Update is never attempted (no `Set-*` cmdlet exists). Orphans skipped unless `-PruneMissing`. Every write is gated by `$PSCmdlet.ShouldProcess`. |

## Schema

YAML conforms to [`data-plane/records/file-plan.schema.json`](../../../data-plane/records/file-plan.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work. Validation includes the `subCategories[*].parentCategory` referential check.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Compliance Administrator` (or `Records Management` role group) | Tenant |
| Caller's identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow's `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network). The same pattern applies.

## Smoke test

```pwsh
# Phase 1 / drift report. Safe to run before any change. Default state
# expects the 31 Microsoft seeds to appear as Skipped (with the workflow
# baseline -SkipNames) or as Orphan (without it).
./scripts/Deploy-FilePlan.ps1 -WhatIf
```

Expected output tail when YAML is the default empty list and `-SkipNames` is omitted:

```text
Tenant props    : authorities=3, categories=13, citations=5, departments=10, referenceIds=0, subCategories=0
Tenant labels   : 0
DirectionPolicy : portal-wins
```

…followed by 31 `Orphan` rows for the Microsoft seeds. Pass `-SkipNames` with the 29 baseline names (see [ADR 0035](../../adr/0035-records-seed-content-immovable.md)) to render those rows as `Skipped` and emit the matching `[ADR0029-SKIP] <Name>` markers.

For an end-to-end live-tenant smoke (Baseline → Create category → Create label → Idempotency → Update → DriftWarn → Orphan → Prune label → Prune category → Baseline lifecycle), follow [`docs/runbooks/records-end-to-end-smoke.md`](../../runbooks/records-end-to-end-smoke.md).

## CI wiring

The `Deploy file plan` step in [`.github/workflows/deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) runs the reconciler inside the shared `kv-open` / `kv-close` window, immediately after `Deploy retention policies`. Three `workflow_dispatch` inputs thread the ADR 0029 contract through to the reconciler, mirroring the DLM and DLP step shapes:

- `records_direction_policy` — `audit` / `portal-wins` (default) / `repo-wins`.
- `confirm_overwrite_records` — typed `overwrite portal` token, gates `repo-wins` per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md).
- `skip_names_records` — comma list passed through to `-SkipNames`. **Default carries the 29 unique seed names** (covering all 31 Microsoft File Plan Manager seed property objects, since `Legal` and `Procurement` each appear under two kinds) ratified as immovable in [ADR 0035](../../adr/0035-records-seed-content-immovable.md). The default ensures every dispatch is noise-free without operator intervention.

The `Validate records dispatch inputs` pre-flight step fails the run cheap when `repo-wins` is selected without the typed-confirmation token. With desired state empty and the seed baseline in place, the apply itself is a Skipped-only no-op; the inputs are scaffolding for the day the first operator-authored label or property is declared. If Microsoft ever shrinks or grows the seed list in a service revision, update the workflow default, [ADR 0035](../../adr/0035-records-seed-content-immovable.md)'s source-of-truth table, and the [runbook](../../runbooks/records-end-to-end-smoke.md) together.

## ADR 0029 source-of-truth direction policy

The reconciler honours the [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy via the shared decision helper at [`scripts/modules/DirectionPolicy.psm1`](../../../scripts/modules/DirectionPolicy.psm1):

| Mode | Behaviour for shared-property drift |
|---|---|
| `audit` | Emits the `[ADR0029-AUDIT]` marker, flips `$WhatIfPreference = $true`, and lets every `ShouldProcess` call fall into its `Would …` branch. No writes under any condition. The SkipNames pass is bypassed by design (matches DLM precedent). |
| `portal-wins` (default) | Skips every label whose tracked fields differ; emits a `Skip` plan row plus a `[ADR0029-SKIP] <name>` marker per skipped object for the upstream workflow to collect into an auto-PR. Property rows participate via SkipNames only (no Set-* surface to arbitrate). |
| `repo-wins` | Applies the full plan including label drift; emits one `Write-Warning` per overwritten label naming the drifted field set. Property rows still surface as `DriftWarn` (no Set-* cmdlet exists). Typed-confirmation (`overwrite portal`) is enforced at the CI layer. |

`Create`, `NoChange`, `DriftWarn`, and `Orphan` plan rows are unaffected by the direction-policy drift arbitration. Orphan removal is gated by `-PruneMissing`, not by the direction-policy contract. The `-SkipNames` switch matches case-insensitively against the bare `Name` field — kind disambiguation is not required because the IPPS surface forbids duplicate `Name` values across the six property kinds within a tenant.

## ADR 0035 — Microsoft File Plan Manager seed content immovability

Every Microsoft 365 tenant carries 31 Microsoft-shipped seed property objects (3 authorities, 13 categories, 5 citations, 10 departments) that `Remove-FilePlanProperty*` rejects via every documented identity form (`Name`, `Guid`, `CN=<guid>`) with `ErrorRuleNotFoundException`. [ADR 0035](../../adr/0035-records-seed-content-immovable.md) ratifies treating these as permanent declared orphans, skipped via the `skip_names_records` workflow baseline. The full verbatim 31-name table lives in the ADR; the workflow default in [`deploy-data-plane.yml`](../../../.github/workflows/deploy-data-plane.yml) is the operational copy. **Never `-PruneMissing` without `-SkipNames`** against `contoso.onmicrosoft.com` — the seed prune will produce 31 `Failed` rows per the [#582](../../../../issues/582) post-mortem.

Watch-list re-open triggers (any of these flips ADR 0035 to superseded):

- The [Remove-FilePlanPropertyAuthority](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyauthority) reference page (or any sibling) gains a `-Policy` parameter or any other parameter targeting the Microsoft-managed seed policy scope.
- A `filePlanProperty`, `recordLabel`, or similar resource lands under [Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/resources/) with a `DELETE` endpoint.
- [Records management overview](https://learn.microsoft.com/en-us/purview/records-management) or [File plan manager](https://learn.microsoft.com/en-us/purview/file-plan-manager) gains a programmatic seed-removal section.
- A Microsoft reference repo ships a sample that deletes seeded properties against a non-test tenant via a documented surface.
- The portal-only removal path is verified end-to-end against `contoso.onmicrosoft.com`.

## Pester coverage

Unit tests for the AST-extractable helper functions live at [`tests/scripts/Deploy-FilePlan.Tests.ps1`](../../../tests/scripts/Deploy-FilePlan.Tests.ps1) and cover hashtable normalization (`ConvertTo-Desired*Hash`, `ConvertTo-Tenant*Hash`), drift detection on labels (split into Mutable vs Immutable buckets via `Compare-RetentionLabel`) and properties (`Compare-PropertyField`), splat-building for `New-` and `Set-` cmdlet forms (`Get-ComplianceTagSplat`, `Get-PropertyCreateSplat`), label↔property binding resolution, and the ADR 0029 direction-policy contract (audit short-circuit, SkipNames mutation, repo-wins warnings). Synthetic inputs only; no live-tenant calls.

## References

- [Learn about records management](https://learn.microsoft.com/en-us/purview/records-management)
- [File plan manager](https://learn.microsoft.com/en-us/purview/file-plan-manager)
- [`New-ComplianceTag`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-compliancetag)
- [`Get-ComplianceTag`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-compliancetag)
- [`Set-ComplianceTag`](https://learn.microsoft.com/en-us/powershell/module/exchange/set-compliancetag)
- [`Remove-ComplianceTag`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-compliancetag)
- [`New-FilePlanPropertyAuthority`](https://learn.microsoft.com/en-us/powershell/module/exchange/new-fileplanpropertyauthority) (and sibling `New-FilePlanProperty*` cmdlets for Category, Citation, Department, ReferenceId, SubCategory)
- [`Get-FilePlanPropertyAuthority`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-fileplanpropertyauthority) (and siblings)
- [`Remove-FilePlanPropertyAuthority`](https://learn.microsoft.com/en-us/powershell/module/exchange/remove-fileplanpropertyauthority) (and siblings)
- [Records management permissions](https://learn.microsoft.com/en-us/purview/get-started-with-records-management#permissions-required-to-create-and-manage-retention-labels)
- [`docs/runbooks/records-end-to-end-smoke.md`](../../runbooks/records-end-to-end-smoke.md) — operator-driven E2E lifecycle smoke.
- [ADR 0010 — Automation identity subject model](../../adr/0010-automation-identity-subject-model.md)
- [ADR 0011 — Certificate lifecycle](../../adr/0011-certificate-lifecycle.md)
- [ADR 0029 — Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0035 — Microsoft File Plan Manager seed content immovability](../../adr/0035-records-seed-content-immovable.md)