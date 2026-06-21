---
description: "Secure-by-design rules for data-plane YAML manifests under data-plane/."
applyTo: "data-plane/**/*.yaml,data-plane/**/*.yml"
---

# Data-plane YAML secure-by-design rules

Extends [`.github/copilot-instructions.md`](../copilot-instructions.md), including the **Microsoft Learn is the central source of truth** rule. These rules apply to collections, glossary, classifications, data sources, scans, and policies manifests.

## Grounding — Data-plane manifests must be verified against Microsoft Learn

These YAML files are a human-friendly projection of the Purview data-plane REST API. Every field name, enum value, and structural nesting must map to a documented REST shape:

- Collections: [Accounts Data Plane — Collections](https://learn.microsoft.com/en-us/rest/api/purview/accountdataplane/collections), concept docs under [Manage collections](https://learn.microsoft.com/en-us/purview/how-to-create-and-manage-collections).
- Glossary: [Data Map Data Plane — Glossary](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/glossary), concept: [Business glossary](https://learn.microsoft.com/en-us/purview/concept-business-glossary).
- Classifications & rules: [Data Map — Type](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/type), [Scanning — Classification Rules](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/classification-rules), [Create a custom classification and rule](https://learn.microsoft.com/en-us/purview/create-a-custom-classification-and-classification-rule).
- Data sources: [Scanning — Data Sources](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/data-sources), [Supported data sources](https://learn.microsoft.com/en-us/purview/data-map-data-sources).
- Scans & rulesets: [Scanning — Scans](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scans), [Scan rule sets](https://learn.microsoft.com/en-us/rest/api/purview/scanningdataplane/scan-rulesets).
- Policies: [Microsoft Purview REST API reference](https://learn.microsoft.com/en-us/rest/api/purview/), [DevOps policies concepts](https://learn.microsoft.com/en-us/purview/concept-policies-devops).

Rules:

- Do not invent field names, enum values, or `kind` values from AI training recall. Every such value must be traceable to one of the REST API pages above.
- Each top-level YAML file must carry a header comment with the Learn URL(s) that govern its schema.
- If Learn does not document a field you want to use, do not silently add it. Cite the gap in a `# note:` comment and flag for human review.

## Zero secrets in YAML

- Never embed a credential, access key, SAS token, connection string, password, or bearer token in any `data-plane/**` file.
- Data source registrations reference credentials **by Key Vault connection + secret name only**. Concrete example for a SQL data source:

  ```yaml
  credential:
    referenceName: purview-kv-connection
    credentialType: SqlAuth
    properties:
      secretName: finance-sql-password  # resolved from Azure Key Vault at scan time
  ```

  Source: [Credentials for source authentication](https://learn.microsoft.com/en-us/purview/data-map-data-scan-credentials).

## Prefer managed identity

- For Azure PaaS sources that support it (ADLS Gen2, Azure SQL, Synapse, Cosmos DB, Storage, Power BI), prefer the Microsoft Purview account's managed identity. The YAML should declare `authType: ManagedIdentity` and omit any credential reference. Source: [Credential management — recommended options](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management).
- Use service principal / SQL auth / account keys only when MI is not supported for the source kind; document why in a `# note:` comment above the entry.

## Collections and least privilege

- Collection role assignments expressed in YAML (if added later) must target Entra groups or workload identities, not individual user UPNs. Source: [Define Least Privilege model](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#define-least-privilege-model).
- Never assign data-plane roles at the root collection when a child collection would suffice.

## Classifications and glossary

- Classification rule regexes must be anchored and bounded (`\b…\b`, explicit length) to avoid catastrophic backtracking on large datasets.
- Do not paste real customer data, real PII samples, or production identifiers into `description`, `longDescription`, or `columnPatterns` fields. Use synthetic examples (`EMP-1234`, `contoso@example.com`).

## Scans

- Scans must specify a `collection` reference. Do not default scans to the root collection.
- Triggers must not run more aggressively than the source's documented scan cadence; default weekly for lab, never sub-hourly.

## Identifier resolution in YAML

Per [ADR 0023](../../docs/adr/0023-identifier-resolution.md), `data-plane/**` YAML files that need to carry real Azure topology or Entra principal identifiers MUST use one of two resolution mechanisms; never paste raw values.

- **Tenant / subscription / resource IDs.** Use `${env:VAR}` tokens. Only the allow-listed variables in [`scripts/Resolve-EnvTokens.ps1`](../../scripts/Resolve-EnvTokens.ps1) are accepted (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `PURVIEW_ACCOUNT_NAME`, `PURVIEW_RG`). Expanding the allow-list requires a paired PR that amends the script and the ADR. Example:

  ```yaml
  resourceId: /subscriptions/${env:AZURE_SUBSCRIPTION_ID}/resourceGroups/${env:PURVIEW_RG}/providers/Microsoft.Sql/servers/contosolabsql01
  ```

- **Entra principal object IDs.** Use `displayName`. Reconcilers resolve via Microsoft Graph at deploy time. Display name must be unique in the tenant or the resolution fails fast. Example:

  ```yaml
  principals:
    - kind: Group           # Group | User | ServicePrincipal
      displayName: sg-purview-devops-sql-readers
  ```

- **Secrets.** Unchanged. Reference Azure Key Vault by `vaultName` + `secretName` per the "Zero secrets in YAML" section above.

Reviewer obligation: reject any PR diff under `data-plane/**` that contains a 32-character hex/GUID pattern that is neither the zero-GUID placeholder nor a Learn-documented role-definition GUID. The diff must use one of the three mechanisms above instead.

## Review discipline

- Any PR that adds or modifies a data source, scan, or policy requires review by at least one person with the `Collection Admin` role on the target collection.
- Destructive changes (deleting a collection, glossary term, classification, source, scan) must be in a dedicated PR with the `destructive` label and approved explicitly; CI will not prune by default.

## Pre-commit checklist — `data-plane/**` changes

Run before opening a PR that touches `data-plane/**`. Paste the output of each command into the PR description. See [`pre-commit.instructions.md`](pre-commit.instructions.md) for the cross-cutting checklist that applies to every PR.

- [ ] `yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable}}' data-plane/` exits 0
- [ ] For each touched domain, the matching `Deploy-*.ps1 -WhatIf` has been run against the target account and its output pasted into the PR description
- [ ] No credentials, keys, connection strings, or real tenant/subscription/object IDs appear in the YAML
- [ ] If a data source is added: credential is referenced by Key Vault, not inline; managed identity is preferred per the "Zero secrets in YAML" and "Prefer managed identity" sections above
- [ ] Drift report from the latest `-WhatIf` run is pasted into the PR description, with non-zero counts in `Orphan` or `Conflict` categories called out explicitly
- [ ] PR does not pass `-PruneMissing` or `-Force` in any workflow file unless it is labeled `destructive` and has the rollback plan required by [`pre-commit.instructions.md`](pre-commit.instructions.md)
