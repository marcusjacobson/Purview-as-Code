# 0023 — Identifier resolution for data-plane reconcilers: three categories, three mechanisms

- **Status:** Accepted
- **Date:** 2026-05-24
- **Gates:** Cross-cutting foundation. Directly unblocks [#305](../../issues/305) (Wave 4a-ii) and [#83](../../issues/83) (Wave 4b). Establishes the binding pattern that every future data-plane reconciler MUST follow when it needs to reference an Entra principal, a tenant/subscription identifier, or a resource ID at deploy time. Does not appear in [`docs/project-plan.md`](../project-plan.md) §8 Open-question ADRs — this is implementation-pattern scaffolding, not a wave-blocking question.
- **Deciders:** @contoso

## Context

Every state-changing reconciler in this repository eventually needs to send one of three kinds of value to Microsoft Purview, Microsoft Entra, or Azure Resource Manager: a secret (a SQL password, a SAS token, a client secret), an Azure topology identifier (tenant ID, subscription ID, resource ID), or an Entra principal object ID (the `objectId` of a group, user, or service principal). The Purview-as-Code repo's standing rules treat all three as values that must not appear in source:

- [`security.instructions.md`](../../.github/instructions/security.instructions.md) rule #1 forbids secrets in source.
- The "Environment and identifier boundaries" section of [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) forbids real tenant IDs, subscription IDs, principal object IDs, and resource IDs in source, mandating the zero-GUID placeholder `00000000-0000-0000-0000-000000000000` for samples.

Today the repo handles the first category cleanly — [`data-plane/data-sources/data-sources.yaml`](../../data-plane/data-sources/data-sources.yaml) references SQL credentials by `vaultName` + `secretName`, and [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) resolves them at deploy time via `az keyvault` calls. The other two categories are unresolved. The placeholder zero-GUID appears verbatim in `data-sources.yaml` (`resourceId: /subscriptions/00000000-0000-0000-0000-000000000000/...`), which means the YAML cannot currently round-trip through an actual `PUT` against the live lab without per-run substitution.

The blocking question surfaced in [#305](../../issues/305) (Wave 4a-ii). DevOps policies authored against the `policystoredataplane` REST surface bind to an Entra principal via `objectId`:

> Reference: [Get policies under data plane (Microsoft Purview REST)](https://learn.microsoft.com/en-us/rest/api/purview/policystoredataplane/policies)
> Reference: [Concept — Microsoft Purview DevOps policies](https://learn.microsoft.com/en-us/purview/concept-policies-devops)

A `Deploy-Policies.ps1` reconciler that consumes [`data-plane/policies/policies.yaml`](../../data-plane/policies/policies.yaml) cannot emit a real `objectId` unless the YAML carries one — and the YAML cannot carry one without violating the identifier-boundaries rule. The same problem surfaces for scan ownership in [#305](../../issues/305), for Unified Catalog object ownership in [#83](../../issues/83), and for any future reconciler that grants or scopes by principal.

The naive responses each fail an existing rule:

- **Commit the real GUIDs anyway** — violates the identifier-boundaries rule and turns a public repo into a reconnaissance surface (object IDs disclose group membership, MI identity, service principal scope).
- **Store every identifier in Azure Key Vault and resolve at deploy time** — overgeneralizes the secrets pattern. Object IDs and resource IDs are not secrets; storing them in Key Vault pays for cryptographic isolation that adds no defence, dilutes the audit value of Key Vault read events, and conflates the threat model. A user with `Key Vault Secrets User` would gain de-facto read access to the tenant's principal directory.
- **Hard-code per environment in a gitignored override file** — works locally but defeats reproducibility. Every contributor and every CI runner needs the same map. The map itself becomes an undocumented secret-shaped artifact with no rotation story.
- **Skip the work** — blocks [#305](../../issues/305), [#83](../../issues/83), and every future principal-aware reconciler.

The three categories want three different mechanisms because they have three different sensitivity profiles, three different rotation cadences, and three different sources of truth.

## Decision

**We will treat secrets, Azure topology identifiers, and Entra principal object IDs as three distinct categories of value, each with its own resolution mechanism. Every data-plane reconciler that ships from this ADR forward MUST use the mechanism named for the category it needs.**

### Category 1 — Secrets

**No change.** Secrets remain in Azure Key Vault, referenced from YAML by `vaultName` + `secretName`, resolved at deploy time via `az keyvault secret show` (read-only metadata) or `az keyvault secret download` (value, when the reconciler must include it in a downstream payload — currently no reconciler does this; payloads always pass a Key Vault reference URI instead).

This is the pattern already established by [`Deploy-DataSources.ps1`](../../scripts/Deploy-DataSources.ps1) per [Credentials for source authentication (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/data-map-data-scan-credentials). It does not change with this ADR.

### Category 2 — Tenant / Subscription / Resource IDs (Azure topology)

**YAML carries `${env:VAR}` tokens. A new helper script [`Resolve-EnvTokens.ps1`](../../scripts/Resolve-EnvTokens.ps1) substitutes them at deploy time from an explicit allow-list of environment variable names. The reconciler MUST fail fast if any token is unresolved.**

The lab owner populates the source-of-truth values as **GitHub Variables** (not Secrets) on the `lab` environment, per [Variables in GitHub Actions](https://docs.github.com/en/actions/learn-github-actions/variables). Variables are not masked in logs, which is appropriate — these values are not secret in the cryptographic sense and a masked log makes troubleshooting harder for non-secret values. The same names are exported locally by contributors who need to run the reconcilers interactively.

The initial allow-list this ADR commits to (additions require a follow-up PR that amends `Resolve-EnvTokens.ps1`'s allow-list and this section):

| Variable | Lab value | Used by |
|---|---|---|
| `AZURE_TENANT_ID` | the lab tenant ID | reconcilers calling Microsoft Graph or Entra APIs |
| `AZURE_SUBSCRIPTION_ID` | the lab subscription ID | reconcilers emitting Azure resource IDs into Purview payloads |
| `PURVIEW_ACCOUNT_NAME` | `purview-contoso-lab` | every reconciler |
| `PURVIEW_RG` | `rg-purview-lab` | reconcilers that interact with the control plane |
| `DATABRICKS_METASTORE_ID` | the Unity Catalog metastore GUID for the lab Databricks workspace | `Deploy-DataSources.ps1` (Databricks Unity Catalog source registration). Added 2026-06-14 under [#370](../../issues/370) v2 §5.5 row 2 Phase 2 — extends the allow-list to keep the real metastore GUID out of source. |

YAML usage example (illustrative — actual migration of existing YAMLs is out of scope for this ADR):

```yaml
resourceId: /subscriptions/${env:AZURE_SUBSCRIPTION_ID}/resourceGroups/${env:PURVIEW_RG}/providers/Microsoft.Sql/servers/contosolabsql01
```

`Resolve-EnvTokens.ps1` rejects any `${env:VAR}` whose `VAR` is not on the allow-list, preventing accidental exfiltration via a typo (e.g., `${env:AZURE_CLIENT_SECRET}` is rejected by name even if such a variable existed).

### Category 3 — Entra principal object IDs (groups, users, service principals)

**YAML carries the principal's `displayName`. A new helper script [`Get-EntraPrincipalIdByDisplayName.ps1`](../../scripts/Get-EntraPrincipalIdByDisplayName.ps1) resolves it to an object ID at deploy time via Microsoft Graph. The reconciler MUST fail fast if the lookup returns zero or more than one match.**

The Graph call is, per [Get groups (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/group-list):

```text
GET https://graph.microsoft.com/v1.0/groups?$filter=displayName eq '<name>'&$select=id,displayName
```

with `Group.Read.All` (application) consent for the automation identity. For users and service principals the equivalent endpoints are [List users](https://learn.microsoft.com/en-us/graph/api/user-list) and [List servicePrincipals](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list); the helper script accepts a `-Kind` parameter of `Group` (default), `User`, or `ServicePrincipal` and dispatches to the matching endpoint.

The helper caches resolved (`Kind`, `DisplayName`) → `objectId` pairs in a script-scope hashtable for the duration of one PowerShell session so a reconciler that references the same principal across many YAML entries pays the Graph cost once. The cache is **not** persisted to disk — every fresh reconciler run re-validates against the live directory.

YAML usage example (illustrative — Wave 4a-ii [#305](../../issues/305) is the first consumer):

```yaml
policies:
  - name: sql-devops-reader
    kind: DevOpsPolicy
    attributes:
      role: SqlPerformanceMonitor
      dataSource: contosolabsql01
      principals:
        - kind: Group
          displayName: sg-purview-devops-sql-readers
```

Display names follow the existing [`naming.instructions.md`](../../.github/instructions/naming.instructions.md) convention; uniqueness within the tenant is enforced by the fail-fast on multi-match. If the lab owner ever recreates a group, the object ID changes but the display name does not — the next reconciler run picks up the new ID transparently, with no YAML edit and no rotation of a Key Vault secret.

### Why not Key Vault for categories 2 and 3

Both expanded in §Context above; the short form: object IDs and resource IDs are not secrets, Key Vault charges per read, and storing them in Key Vault would make the principal directory de-facto readable to any `Key Vault Secrets User` — a privilege escalation against the least-privilege rule in [`security.instructions.md`](../../.github/instructions/security.instructions.md) #4.

### Why not commit the GUIDs

Object IDs disclose tenant topology (which groups exist, which MIs are scoped where). Subscription and resource IDs anchor every Azure resource path in the lab. Either committed to a public repo is a reconnaissance gift. The repo's standing rule (per [`copilot-instructions.md`](../../.github/copilot-instructions.md)) already forbids this; this ADR documents the alternative the repo will use instead.

## Consequences

**Easier:**

- **YAMLs become committable.** [`data-plane/policies/policies.yaml`](../../data-plane/policies/policies.yaml), and every future principal-aware data-plane YAML, can ship real semantic content (`displayName: sg-purview-devops-sql-readers`, `resourceId: /subscriptions/${env:AZURE_SUBSCRIPTION_ID}/...`) instead of a zero-GUID placeholder. Reviewers see intent; the reconciler resolves to the real value at deploy.
- **[#305](../../issues/305) unblocks** with a `policies.yaml` that round-trips against the live `purview-contoso-lab` account.
- **[#83](../../issues/83) inherits the pattern.** Unified Catalog item ownership uses the same `displayName` shape with no additional ADR.
- **Resilience to principal recreation.** If the lab owner deletes and recreates `sg-purview-devops-sql-readers`, the next reconciler run resolves to the new object ID with no source change.
- **Audit alignment.** Microsoft Graph requests are logged in Entra audit; Key Vault reads are logged in the lab's existing diagnostic settings. The audit story for each category is the one the platform already provides.

**Harder:**

- **Two new failure modes.** A reconciler can now fail because `Resolve-EnvTokens.ps1` rejected an unresolved `${env:VAR}` (variable not set in the GitHub environment or the local shell) or because `Get-EntraPrincipalIdByDisplayName.ps1` returned zero or multiple matches. Both surface as clear, actionable errors; both are exercised by the Pester tests this ADR commits to. Neither is a silent corruption.
- **One new managed dependency.** The automation identity requires `Group.Read.All` application consent before [#305](../../issues/305) ships its first non-empty `policies.yaml`. The grant lives in a follow-up PR ([out-of-scope item in #325](../../issues/325)); the helper script itself ships first and is unit-tested with mocked Graph responses so the grant gap does not block this ADR or its companion PR.
- **Migration debt on existing YAMLs.** Today's [`data-plane/data-sources/data-sources.yaml`](../../data-plane/data-sources/data-sources.yaml) carries a literal zero-GUID for the subscription portion of its `resourceId`. Migrating it to `${env:AZURE_SUBSCRIPTION_ID}` is intentionally deferred to its own follow-up issue so this scaffolding PR stays narrow. The migration is mechanical and low-risk; the deferral is about PR shape, not technical debt.
- **Lab owner action required before [#305](../../issues/305) deploys.** Four GitHub Variables (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `PURVIEW_ACCOUNT_NAME`, `PURVIEW_RG`) must be set on the `lab` environment before any reconciler that uses `Resolve-EnvTokens.ps1` can run end-to-end. The scaffolding PR documents this requirement; populating the variables is a lab-owner action, not an automation step.

**Security principles** (from [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md)):

- **#1 (no secrets in source).** Strengthened. The new helpers make a non-Key-Vault path for non-secret values explicit, removing the temptation to repurpose Key Vault as a generic identifier store.
- **#2 (managed identity ordering).** Unchanged. The automation identity remains a workload-identity-federated app per [ADR 0010](0010-automation-identity-subject-model.md) and [ADR 0011](0011-certificate-lifecycle.md); the only new Graph permission introduced is `Group.Read.All`, the minimum needed to resolve the chosen principal kinds.
- **#4 (least privilege).** Upheld. The `Resolve-EnvTokens.ps1` allow-list is the narrowest set of variables the current reconcilers need; adding a variable is an explicit PR amendment, not a silent permission expansion.
- **#9 (idempotent, reversible, auditable).** Upheld. Both helpers are pure functions in effect — no tenant writes, no caching to disk, no side effects beyond a single Graph read or a single environment lookup. Re-running a reconciler resolves identifiers freshly each time.

## Alternatives considered

1. **Azure Key Vault for all three categories** (uniform store). Rejected. Conflates secrets with non-secrets, pays for cryptographic isolation that adds no defence for object IDs and resource IDs, and gives any `Key Vault Secrets User` de-facto read access to the principal directory — a least-privilege regression.

2. **Commit the real GUIDs to a private repo.** Rejected. The repo is structured to be promotable to public/shared at any time (the security and identifier-boundary rules already assume this). Coupling the resolution model to repo visibility makes the rule fragile.

3. **Hard-code each value in a gitignored `.env.local`-style file.** Rejected. Works locally but requires every CI runner to have the same map, with no rotation or audit story. Becomes an undocumented secret-shaped artifact.

4. **Convert `Connect-Purview.ps1` into a PowerShell module and add the helpers as exported functions.** Rejected for this ADR. The module refactor is a larger blast-radius change (every existing `Deploy-*.ps1` switches from `& path.ps1` invocation to `Import-Module`); deferring it keeps this scaffolding PR small. A future ADR may revisit the module question if the helper count grows past 4–5 standalone scripts.

5. **Do nothing — keep [#305](../../issues/305) blocked behind a permanently-empty `policies.yaml`.** Rejected. The repo's stated purpose is to manage Purview as code; an entire category of catalog content (principal-bound policies) becoming unauthorable defeats that purpose.

## Citations

- [Variables in GitHub Actions](https://docs.github.com/en/actions/learn-github-actions/variables) — basis for the §Decision Category 2 mechanism.
- [Get groups (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/group-list) — basis for the §Decision Category 3 group-resolution endpoint.
- [List users (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/user-list) — user-resolution endpoint.
- [List servicePrincipals (Microsoft Graph)](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list) — service principal resolution endpoint.
- [Get policies under data plane (Microsoft Purview REST)](https://learn.microsoft.com/en-us/rest/api/purview/policystoredataplane/policies) — the consuming surface that motivated this ADR.
- [Concept — Microsoft Purview DevOps policies](https://learn.microsoft.com/en-us/purview/concept-policies-devops) — principal-binding model for DevOps policies.
- [Credentials for source authentication (Microsoft Purview)](https://learn.microsoft.com/en-us/purview/data-map-data-scan-credentials) — basis for §Decision Category 1 (Key Vault, unchanged).
- [`.github/copilot-instructions.md`](../../.github/copilot-instructions.md) — "Environment and identifier boundaries" section, the rule this ADR's mechanisms preserve.
- [`.github/instructions/security.instructions.md`](../../.github/instructions/security.instructions.md) — secret-management, MI ordering, least-privilege, idempotency rules referenced in §Consequences.
- [ADR 0010](0010-automation-identity-subject-model.md), [ADR 0011](0011-certificate-lifecycle.md) — automation identity decisions this ADR does not modify.

