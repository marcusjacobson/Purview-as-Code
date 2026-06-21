# Administrative units

Operational guide for [`scripts/Deploy-AdministrativeUnits.ps1`](../../../scripts/Deploy-AdministrativeUnits.ps1) — the idempotent reconciler for Microsoft Entra administrative units (AUs). Pairs with the governance doc [`docs/governance/administrative-units.md`](../../governance/administrative-units.md) (boundary statement, operating procedure, default-state rationale) and is ratified by [ADR 0002](../../adr/0002-administrative-units.md).

This page documents the reconciler behaviour. See the governance doc for the broader story (why AUs exist, how Purview consumes them, the operating procedure for creating and removing one).

| Artifact | Path |
|---|---|
| Desired-state YAML | [`data-plane/administrative-units/administrative-units.yaml`](../../../data-plane/administrative-units/administrative-units.yaml) |
| Reconciler script | [`scripts/Deploy-AdministrativeUnits.ps1`](../../../scripts/Deploy-AdministrativeUnits.ps1) |

## Scope boundary

AUs are an [Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/) construct, not a Microsoft Purview construct. Purview integrates with AUs as a *consumer* — six [Microsoft Purview solutions](https://learn.microsoft.com/en-us/purview/purview-admin-units#supported-solutions) (DLP, IRM, Communication Compliance, DLM, Records Management, Sensitivity Labeling) accept AU-scoped role-group assignments and policy targeting.

The reconciler manages **object lifecycle only** (create, update, delete). Member reconciliation is intentionally out of scope; the YAML's `members:` field seeds initial membership only and is ignored on subsequent runs.

## YAML schema

```yaml
administrativeUnits:
  - displayName: au-<purpose>                # required, unique in tenant
    description: <one sentence>              # optional, string
    visibility: Public                       # optional, "Public" | "HiddenMembership", default "Public"
    members: []                              # optional, list of Entra OIDs; seed only, not reconciled
```

Default steady state is an empty list per [ADR 0002 §2](../../adr/0002-administrative-units.md#decision). Naming follows [`naming.instructions.md`](../../../.github/instructions/naming.instructions.md).

## Behaviour

Drift contract:

1. `GET /v1.0/directory/administrativeUnits` (paged).
2. Diff against the YAML.
3. Emit categorized drift report: `Create`, `Update`, `NoChange`, `Orphan`, `Conflict`.
4. Act only on categories the caller has authorized via `-WhatIf` / `-PruneMissing` / `-Force`.

| Category | Meaning |
|---|---|
| `Create` | In YAML, not in tenant. Always written. |
| `Update` | In both; differs on `description` or `visibility`. Written unless `Conflict`. |
| `NoChange` | In both; shape matches. |
| `Orphan` | In tenant, not in YAML. Deleted only with `-PruneMissing`. |
| `Conflict` | `lastModifiedBy` is not the current principal. Skipped unless `-Force`. |

## What `-WhatIf` shows vs apply

| Mode | Behaviour |
|---|---|
| `-WhatIf` | Live read; no writes. Prints the drift report. |
| (default) | Applies `Create` and `Update` rows. Leaves `Orphan` rows untouched. Skips `Conflict`. |
| `-PruneMissing` | As default, plus deletes `Orphan` rows via [Delete administrativeUnit](https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete). PR must carry the `destructive` label. |
| `-Force` | Overrides `Conflict` rows. Use with caution. |

## Required roles

| Caller | Role / permission | Source |
|---|---|---|
| Interactive user running the script | `Privileged Role Administrator` or `Global Administrator` | [Manage administrative units — permissions](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/admin-units-manage#permissions-required) |
| Workload identity (delegated) | Graph delegated scope `AdministrativeUnit.ReadWrite.All` | [`administrativeUnit` resource — permissions](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit#permissions) |
| Workload identity (application) | Graph application permission `AdministrativeUnit.ReadWrite.All` | same |
| Caller assigning a Purview role group to an AU scope | `Compliance Administrator` + an AU-scoped Purview role group | [Administrative units in Microsoft Purview — permissions](https://learn.microsoft.com/en-us/purview/purview-admin-units#permissions) |

## References

- [`administrativeUnit` resource (Graph)](https://learn.microsoft.com/en-us/graph/api/resources/administrativeunit)
- [List `administrativeUnits`](https://learn.microsoft.com/en-us/graph/api/directory-list-administrativeunits)
- [Create `administrativeUnit`](https://learn.microsoft.com/en-us/graph/api/directory-post-administrativeunits)
- [Update `administrativeUnit`](https://learn.microsoft.com/en-us/graph/api/administrativeunit-update)
- [Delete `administrativeUnit`](https://learn.microsoft.com/en-us/graph/api/administrativeunit-delete)
- [Administrative units in Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/administrative-units)
- [Administrative units in Microsoft Purview](https://learn.microsoft.com/en-us/purview/purview-admin-units)
- [ADR 0002 — Administrative units](../../adr/0002-administrative-units.md)
- [`docs/governance/administrative-units.md`](../../governance/administrative-units.md)
