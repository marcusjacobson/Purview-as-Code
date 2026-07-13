# Insider Risk Management - entity lists

Operational guide for [`scripts/Deploy-IRMEntityLists.ps1`](../../../scripts/Deploy-IRMEntityLists.ps1) -- the reconciler that materializes [`data-plane/irm/entity-lists.yaml`](../../../data-plane/irm/entity-lists.yaml) against the [Microsoft Purview Insider Risk Management](https://learn.microsoft.com/en-us/purview/insider-risk-management) entity-list surface. Pairs with [`insider-risk-management.md`](insider-risk-management.md) (the IRM policy reconciler).

## Purpose

Reconciles the [`Get/New/Set/Remove-InsiderRiskEntityList`](https://learn.microsoft.com/en-us/powershell/module/exchange/get-insiderriskentitylist) cmdlet family against a declared list of IRM entity-list entries. Emits Create / Update / NoChange / Orphan / Skipped decisions per entity list. Orphan lists (live in tenant, absent from YAML) are reported and skipped unless `-PruneMissing` is supplied AND the name is not on the `-SkipNames` baseline.

Entity lists are named, typed collections of users, groups, or sites used to scope IRM policies:

- `UserType` -- holds user principal names (UPNs) for priority user groups.
- `GroupType` -- holds distribution group or Microsoft 365 group identifiers.
- `SiteType` -- holds SharePoint or Microsoft Teams site URLs.

Tracked fields: `displayName`, `description`, `entities` (full replace). `type` is immutable after creation -- changing type requires deleting and recreating the list. See [ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md).

## Default state

The shipped YAML declares an empty `entityLists: []` list (issue [#606](../../../../../issues/606)). The `IRM-Lab-Priority-Users` entity list (backing the `IRM Lab -- Data leaks by priority users` policy) is under the #603 hard rule (no mutation during active testing) and is carried in the CI skip baseline per [ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md).

## Authentication

Same Key Vault-side JWT signing path as every other Security & Compliance reconciler in this repo:

1. Resolves the data-plane Entra app by display name (per [ADR 0010](../../adr/0010-automation-identity-subject-model.md)).
2. Calls [`scripts/Get-PurviewIPPSAccessToken.ps1`](../../../scripts/Get-PurviewIPPSAccessToken.ps1) which builds an [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) `client_assertion` JWT and signs the SHA-256 digest via [`az keyvault key sign`](https://learn.microsoft.com/en-us/cli/azure/keyvault/key) against the certificate''s underlying RSA key. The private key never leaves Key Vault.
3. Calls [`Connect-IPPSSession -AccessToken`](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/connect-ippssession) with `-ShowBanner:$false`.

## Inputs

| Parameter | Default source in `lab.yaml` |
|---|---|
| `-Path` | `data-plane/irm/entity-lists.yaml` |
| `-ParametersFile` | defaults to `infra/parameters/lab.yaml` |
| `-VaultName` | `resources.keyVault.name:` |
| `-CertificateName` | `automation.apps.dataPlane.certificateName:` |
| `-DataPlaneAppDisplayName` | `automation.apps.dataPlane.displayName:` |
| `-TenantDomain` | `automation.tenantDomain:` |
| `-PruneMissing` | switch -- DESTRUCTIVE: removes orphan tenant entity lists. Names on `-SkipNames` are never removed. |
| `-DirectionPolicy` | `audit` / `portal-wins` (default) / `repo-wins` -- [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md) source-of-truth direction policy |
| `-SkipNames` | string array -- workflow-supplied pre-computed skip list; ignored in `audit` mode |
| `-SkipSchemaValidation` | switch -- bypass the JSON Schema gate (emergency only) |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-DirectionPolicy audit` | Reads `Get-InsiderRiskEntityList`; prints `[ADR0029-AUDIT]` marker plus the categorized plan rows. **No writes under any circumstance.** |
| `-WhatIf` (default `portal-wins`) | Reads `Get-InsiderRiskEntityList`; applies the skip baseline; prints Create / Update / NoChange / Orphan / Skipped rows. No writes. |
| (default) | Same read, then per-row `New-`, `Set-`, or `Remove-InsiderRiskEntityList` for Create / Update / (Orphan + `-PruneMissing`). Every write is gated by `$PSCmdlet.ShouldProcess`. |
| `-DirectionPolicy repo-wins` | Apply Update rows even on shared-property drift. Emits one `Write-Warning` per overwrite. CI gates this on the typed `confirm_overwrite_irm_entity_list='overwrite portal'` token. |

## Schema

YAML conforms to [`data-plane/irm/entity-lists.schema.json`](../../../data-plane/irm/entity-lists.schema.json) (JSON Schema Draft-07). Schema is validated at script start via [`Test-Json -Schema`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/test-json) before any reconcile work.

## Required roles

| Caller | Role | Scope |
|---|---|---|
| Data-plane OIDC service principal (workload identity) | Microsoft Purview `Insider Risk Management` (or `Compliance Administrator`) | Tenant |
| Caller''s identity in Azure | `Key Vault Crypto User` on the data-plane app cert key | Key Vault (granted by [`New-AutomationRbac.ps1`](../../../scripts/New-AutomationRbac.ps1)) |

Reference: [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions).

## Local-dev runs from outside the Key Vault network

CI runs app-only via the workflow''s `kv-open` / `kv-close` firewall window. For local-dev runs from a workstation outside the approved network, see [`audit-log.md` §Local-dev runs from outside the Key Vault network](audit-log.md#local-dev-runs-from-outside-the-key-vault-network).

## Audit mode - read-only view of the raw live tenant vs YAML

```pwsh
./scripts/Deploy-IRMEntityLists.ps1 -WhatIf -DirectionPolicy audit
```

Expected output when YAML is the default empty list and the lab tenant carries `IRM-Lab-Priority-Users`:

```text
[ADR0029-AUDIT] DirectionPolicy=audit - no writes will fire. Plan below is read-only.
Category Name                    Reason
-------- ----                    ------
Orphan   IRM-Lab-Priority-Users  Tenant-only; skipped (no -PruneMissing).
```

For the noise-free `portal-wins` view (matches what CI runs by default):

```pwsh
./scripts/Deploy-IRMEntityLists.ps1 -WhatIf -DirectionPolicy portal-wins `
  -SkipNames @('IRM-Lab-Priority-Users')
```

Expected: 1 `Skipped` row, zero anything else.

## CI wiring

> **No automated apply path yet.** IRM *policies* have a per-solution workflow ([`deploy-irm.yml`](../../../.github/workflows/deploy-irm.yml)); IRM **entity lists** do **not**. Merging `data-plane/irm/entity-lists.yaml` applies nothing on its own. **Interim apply path: run [`scripts/Deploy-IRMEntityLists.ps1`](../../../scripts/Deploy-IRMEntityLists.ps1) locally.** The monolithic `deploy-data-plane.yml` that once carried a `Deploy IRM entity lists` step (inputs `irm_entity_list_direction_policy`, `confirm_overwrite_irm_entity_list`, `skip_names_irm_entity_list`) was retired by [ADR 0051](../../adr/0051-per-solution-workflow-unit-of-data-plane-apply.md) — it declared 32 `workflow_dispatch` inputs against GitHub's 25-property cap and therefore **never once executed** (90 runs, 0 successes, 0 jobs scheduled), so that step never applied anything. Nothing was lost. Backfilling a `deploy-irm-entity-lists.yml` is tracked in [#80](https://github.com/marcusjacobson/Purview-as-Code/issues/80).

The script-side contract is unaffected and remains the live surface:

- `-DirectionPolicy` -- `audit` / `portal-wins` (default) / `repo-wins`, per [ADR 0029](../../adr/0029-source-of-truth-direction-policy.md).
- `-SkipNames` -- pass `IRM-Lab-Priority-Users` per [ADR 0039](../../adr/0039-irm-entity-list-tracked-fields.md). **This was a workflow input default; with the workflow gone it is no longer applied for you** — supply it explicitly on the command line, or the declared orphan will surface as drift.

**The typed `overwrite portal` confirmation that gated `repo-wins` was a workflow pre-flight step, not a script parameter** — locally, `-DirectionPolicy repo-wins` is destructive with no prompt. Preview with `-DirectionPolicy audit` first.

## Related ADRs and runbooks

- [ADR 0029 -- Source-of-truth direction policy](../../adr/0029-source-of-truth-direction-policy.md)
- [ADR 0036 -- IRM tenant-setting immovable](../../adr/0036-irm-tenant-setting-immovable.md)
- [ADR 0039 -- IRM entity-list tracked fields](../../adr/0039-irm-entity-list-tracked-fields.md)
- Sibling solution: [`insider-risk-management.md`](insider-risk-management.md)

## Follow-ups

- [#604](../../../../../issues/604) -- Adopt live IRM Lab pilot policies into desired state (post-testing-window)
- [#606](../../../../../issues/606) -- this item (entity-list reconciler coverage)