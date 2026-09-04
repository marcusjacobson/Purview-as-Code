# 0062 — Extend the ADR 0025 Entra-backing naming rule to directory-role backing groups

- **Status:** Accepted
- **Date:** 2026-07-22
- **Gates:** [#53](../../issues/53) — the fifth per-feature convergence pass (role-surfaces convergence): the new `data-plane/entra-directory-roles/role-assignments.yaml` desired-state population (reconciler `scripts/Deploy-EntraDirectoryRoles.ps1`). Does not gate any `docs/project-plan.md` §8 open question.
- **Deciders:** @marcusjacobson
- **Related:** [ADR 0025](0025-role-group-entra-backing-naming.md) (this ADR extends its mechanical slug-derivation rule to a second, previously-uncovered RBAC surface; ADR 0025 itself is unchanged and remains in effect for its original scope), [ADR 0002](0002-administrative-units.md) (directory-wide scope only, unaffected by this decision), [ADR 0023](0023-identifier-resolution.md) (the `displayName:` resolution category this file already uses for its `members:` entries).

## Context

[data-plane/entra-directory-roles/role-assignments.yaml](../../data-plane/entra-directory-roles/role-assignments.yaml) is the desired-state file for Microsoft Entra ID **directory-role** assignments — a tenant-scoped RBAC surface administered through the Microsoft Graph unified RBAC API (`/roleManagement/directory/roleAssignments`), and explicitly documented in the file's own header as **a different RBAC surface** than the Microsoft 365 / Microsoft Purview **portal role groups** tracked in [data-plane/purview-role-groups/role-groups.yaml](../../data-plane/purview-role-groups/role-groups.yaml) — "mixing the two breaks least privilege."

[ADR 0025](0025-role-group-entra-backing-naming.md) established a mandatory, mechanically-derivable naming pattern (`sg-purview-<slug>`) for the Entra security groups that back **portal role groups**. That ADR's Context, Decision, and Citations sections are scoped entirely to `role-groups.yaml` and `scripts/Deploy-RoleGroupBackingEntraGroups.ps1`; it never mentions Entra directory roles or `role-assignments.yaml`. No ADR covers the naming of Entra groups that back **directory-role** assignments — a gap confirmed during `@idea-intake` triage of [#53](../../issues/53) before this ADR was opened.

During live execution of [#53](../../issues/53) Phase 2.1–2.2 (owner-authorized, PIM-elevated writes against the lab tenant), three new role-assignable Entra security groups were created to back the three in-scope directory roles (Compliance Administrator, Compliance Data Administrator, Information Protection Administrator), applying ADR 0025's mechanical rule verbatim to the canonical directory-role display name: `sg-purview-compliance-administrator` and `sg-purview-compliance-data-administrator`.

**This produced a real, live naming collision, not a hypothetical one.** Both slugs were already in use on the lab tenant as of 2026-05-28 — they back the **Purview portal role groups** `ComplianceAdministrator` / `ComplianceDataAdministrator` via `scripts/Deploy-RoleGroupBackingEntraGroups.ps1` under ADR 0025's own rule. Reusing those exact display names for directory-role backing groups would have collapsed the two RBAC surfaces onto the same Entra objects — precisely the "mixing the two breaks least privilege" failure mode `role-assignments.yaml`'s header warns against: a principal added to one group for directory-role purposes would silently also hold the unrelated portal role-group grant, and vice versa. The Information Protection Administrator slug (`sg-purview-information-protection-administrator`) did not collide, but the naming rule must be uniform across all three roles rather than colliding on two and coincidentally clean on the third.

## Decision

We will:

1. **Extend ADR 0025's mechanical slug-derivation rule to `data-plane/entra-directory-roles/role-assignments.yaml`, under a disambiguated prefix.** The naming pattern for a directory-role backing group is:

   ```text
   sg-purview-directory-role-<slug>
   ```

   where `<slug>` is derived from the canonical Microsoft-published directory-role display name (e.g. "Compliance Administrator") by:
   - Replacing spaces with dashes.
   - Applying the same camelCase-boundary insertion rule ADR 0025 §Decision 2 already defines (`insert '-' before any uppercase letter preceded by a lower-case letter or digit, or before any uppercase letter that begins a new word inside a run of capitals`) — stated here for consistency even though none of the three in-scope canonical directory-role names (`Compliance Administrator`, `Compliance Data Administrator`, `Information Protection Administrator`) contains an internal PascalCase run, so this clause is a no-op today.
   - Lowercasing the result.

   | Directory role (canonical name) | Backing Entra group display name |
   |---|---|
   | `Compliance Administrator` | `sg-purview-directory-role-compliance-administrator` |
   | `Compliance Data Administrator` | `sg-purview-directory-role-compliance-data-administrator` |
   | `Information Protection Administrator` | `sg-purview-directory-role-information-protection-administrator` |

   The slug is also the `mailNickname`. All groups are `securityEnabled: true`, `mailEnabled: false`, `isAssignableToRole: true` — the last property is mandatory for a group to be eligible for a Microsoft Entra directory-role assignment at all, per [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept), and is not a property portal role-group backing groups carry.

2. **The `directory-role` segment is the load-bearing difference from ADR 0025's bare `sg-purview-<slug>` form, and exists specifically to prevent the collision described in Context.** ADR 0025's naming space and this ADR's naming space are two disjoint namespaces by construction from this point forward: no directory-role backing group name can ever collide with a portal role-group backing group name, because the two prefixes (`sg-purview-<slug>` vs. `sg-purview-directory-role-<slug>`) cannot produce the same string for any input. This is a permanent naming rule, not a one-time workaround — `role-assignments.yaml`'s header example (previously the non-ADR-conformant `sg-purview-compliance-admins`) is corrected to this form in the same PR that adds this ADR, and no future directory-role backing group may use the bare `sg-purview-<slug>` form.

3. **Group description (mandatory), mirroring ADR 0025 §Decision 3's convention:** `Backs the Microsoft Entra directory role '<RoleName>'. Created via scripts/New-RoleAssignableEntraGroup.ps1 and bound via scripts/Grant-EntraDirectoryRole.ps1. See docs/adr/0062-directory-role-entra-backing-naming.md.`

4. **Ownership and lifecycle** follow the same pattern ADR 0025 §Decision 4/5 already establishes for portal role-group backing groups, adapted to this surface's actual primitives: the lab-owner principal is added as the initial member (`scripts/New-RoleAssignableEntraGroup.ps1`, delegated `az` session — not app-only, since directory-role-assignable group creation is a sensitive, owner-supervised action per [#53](../../issues/53)'s hard constraint that `-PruneMissing` is never passed anywhere in this program). Binding to the directory role is performed by `scripts/Grant-EntraDirectoryRole.ps1` (also delegated, primitive-first route). Membership is otherwise managed in Entra directly; neither script manages ongoing membership of the backing group beyond the initial owner add.

5. **This ADR does not reopen or restate ADR 0025's decision for portal role groups.** ADR 0025 remains `Accepted` and unchanged for `role-groups.yaml`; this ADR only closes the gap for the sibling surface ADR 0025 never covered. This is an **extension**, not a supersession: no prior decision is reversed, and ADR 0025's own naming space (`sg-purview-<slug>`, no `directory-role` segment) is unaffected and continues to govern `role-groups.yaml` exactly as written.

## Consequences

**Easier**

- `role-assignments.yaml` now has a mandatory, mechanically-derivable naming rule for its backing groups, closing the same "no judgement call per group" gap ADR 0025 closed for portal role groups.
- The two RBAC surfaces (directory roles vs. portal role groups) are permanently namespace-disjoint at the Entra-group level, structurally preventing the collision class this ADR was written to resolve — not just for the three groups created in [#53](../../issues/53), but for any directory role added to this file's in-scope allowlist in the future.
- A future reviewer auditing `sg-purview-*` groups in the tenant can immediately distinguish "backs a directory role" (`sg-purview-directory-role-*`) from "backs a portal role group" (`sg-purview-*` without that segment) without cross-referencing either YAML file.

**Harder**

- Directory-role backing group names are one segment longer than the bare ADR 0025 form, which the reserved-collision Context makes necessary rather than cosmetic.
- Three groups were created live on the lab tenant (Phase 2.1–2.2 of [#53](../../issues/53)) using this naming before this ADR was formally written; this ADR documents that decision after the fact rather than gating it in advance. This is consistent with how this ADR file is being authored — as a record of an owner-confirmed live decision, not a proposal — and does not require any rename, since the names chosen live already match the rule this ADR ratifies.

**Security posture**

- Strengthened. Preventing the two RBAC surfaces from sharing a backing-group name upholds the least-privilege boundary both `role-assignments.yaml`'s and `role-groups.yaml`'s own headers already assert in prose; this ADR makes that boundary structurally enforced by the naming convention rather than relying on an author noticing the collision by hand each time.
- No secrets are introduced. Group creation uses the same delegated `az` primitives ADR 0025's portal role-group flow uses conceptually, adapted to the directory-role-assignable group requirement (`isAssignableToRole: true`).

## Alternatives considered

1. **Adopt lab's pre-existing non-standard group names as the managed set (`GRP-Entra-Compliance-Administrators`, `Beast-Mode`, etc.) instead of creating new ADR-conformant groups.** Rejected during [#53](../../issues/53) Phase 1 (owner decision F3/D2): those names are not mechanically derivable, would need to be recreated by hand on dev to keep the two tenants convergent, and would drag inconsistent naming into the codified baseline going forward. The pre-existing groups remain live, untouched, unmanaged assignments on the role (visible in the export as ordinary member rows) — this ADR does not require removing or renaming them.
2. **Reuse the bare ADR 0025 `sg-purview-<slug>` form and accept the collision by treating the shared group as intentionally dual-purpose.** Rejected. Explicitly contradicts both files' own header warnings against mixing the two RBAC surfaces, and would mean adding a member to a group for one purpose silently grants the unrelated surface's access too — the exact anti-pattern ADR 0025 itself was written to eliminate for the portal-role-group case.
3. **Do nothing — leave `role-assignments.yaml`'s backing-group naming ungoverned by any ADR.** Rejected. Directory-role assignments are tenant-wide, high-privilege grants; an ungoverned naming space for their backing groups is inconsistent with how every other Entra-group-backed desired-state surface in this repo (portal role groups, per ADR 0025) is governed, and was the literal gap [#53](../../issues/53) intake identified.

## Citations

- [Permissions in the Microsoft Purview portal](https://learn.microsoft.com/en-us/purview/purview-permissions) — establishes the three in-scope directory roles as the Purview-relevant subset of the broader Entra directory-role catalog.
- [Use Microsoft Entra groups to manage role assignments](https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/groups-concept) — the `isAssignableToRole` requirement for a group to be eligible for directory-role assignment, and the reason directory-role backing groups cannot simply reuse a non-role-assignable portal role-group backing group even where no name collision exists.
- [Create group — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/group-post-groups) — the Graph endpoint `scripts/New-RoleAssignableEntraGroup.ps1` invokes, including the `isAssignableToRole` creation-time-only property.
- [List roleAssignments — Microsoft Graph v1.0](https://learn.microsoft.com/en-us/graph/api/rbacapplication-list-roleassignments) — the read surface `Deploy-EntraDirectoryRoles.ps1 -ExportCurrentState` uses to capture the backing groups as `displayName:` rows.
- [ADR 0025 — Entra security-group backing for Purview portal role groups](0025-role-group-entra-backing-naming.md) — the mechanical slug-derivation rule this ADR extends, and the ADR whose naming space this ADR is disambiguated against.
- [ADR 0023 — Identifier resolution in data-plane YAML](0023-identifier-resolution.md) — the `displayName:` resolution category `role-assignments.yaml`'s `members:` field already uses.
