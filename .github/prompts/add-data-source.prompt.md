---
description: "Interview the user for a new Purview data source, enforce credential and naming rules, then append blocks to data-sources.yaml and scans.yaml."
mode: agent
---

# Add a data source

Gather the fields below one at a time. Validate each answer before moving on. Do not write to any YAML file until every field passes validation.

## Fields to collect

1. **Kind.** One of: `AzureDataLakeStorageGen2`, `AzureBlobStorage`, `AzureSqlDatabase`, `AzureSynapseAnalytics`, `MicrosoftFabric`, `AmazonS3`, `AzureDataExplorer`, `PowerBI`. If the user names another kind, verify it is in [Supported data sources](https://learn.microsoft.com/en-us/purview/sources-and-scans) before accepting.
2. **Endpoint / resource ID.** The fully-qualified Azure resource ID for Azure-native sources, or the canonical endpoint for others. Enforce the [`sample-data.instructions.md`](../instructions/sample-data.instructions.md) rule: if the endpoint looks like a real production hostname, stop and ask for the `contoso-lab` synthetic equivalent.
3. **Display name.** Used in the Purview portal. Lowercase, hyphen-separated, derived from the Azure resource per the "Naming convention" in [`copilot-instructions.md`](../copilot-instructions.md).
4. **Parent collection.** Must be the `name` of a collection already declared in [`data-plane/collections/collections.yaml`](../../data-plane/collections/collections.yaml). If the parent doesn't exist, stop and tell the user to add it first.
5. **Authentication method.** Ask in this order and accept the first that works:
   1. `ManagedIdentity` — the Purview account's system-assigned MI has access. Preferred.
   2. `UserAssignedManagedIdentity` — a user-assigned MI. Emit the resource ID reference, never the client ID as a literal.
   3. `ServicePrincipal` — with a federated credential against an Entra app. Never a client secret.
   4. `AccountKey` / `SqlAuthentication` / `BasicAuth` — only when the source does not support MI or SP. Credential must be a Key Vault reference.
6. **Credential reference.** If method is 3 or 4, ask for the Key Vault name and secret name. Never ask for the secret value. Reject any answer that contains a literal secret and cite [`copilot-instructions.md`](../copilot-instructions.md) principle #1.
7. **Scan frequency.** `OnDemand`, `Weekly`, or `Monthly`. Default `Weekly`. Used for the matching scan stub.
8. **Scan ruleset.** `System.Default` or the name of a custom ruleset. Default `System.Default`.

## Derive names

- Data source `name`: lowercase, hyphen-separated, matches the underlying Azure resource per the "Naming convention" section.
- Scan `name`: `scan-<datasource-name>-<purpose>`, e.g. `scan-contosolabsrc01-full`.

## Write the YAML

Append to both files. The blocks must look like:

```yaml
# data-plane/data-sources/data-sources.yaml
- name: <datasource-name>
  kind: <kind>
  properties:
    resourceId: <azure-resource-id>
    collection:
      referenceName: <parent-collection-name>
  credential:
    kind: <auth-method>
    # For ManagedIdentity, no further fields.
    # For ServicePrincipal, reference the Entra app resource ID (no secret).
    # For AccountKey / BasicAuth, reference Key Vault:
    #   vault: <kv-name>
    #   secretName: <secret-name>
  # Reference: https://learn.microsoft.com/en-us/purview/manage-credentials
```

```yaml
# data-plane/scans/scans.yaml
- name: scan-<datasource-name>-<purpose>
  dataSource: <datasource-name>
  ruleset: <ruleset>
  trigger:
    kind: <scan-frequency>
  # Reference: https://learn.microsoft.com/en-us/purview/concept-scans-and-ingestion
```

- Preserve existing YAML indentation and list ordering.
- Do not reformat unrelated entries.
- Run `yamllint` per the pre-commit checklist and surface any errors.

## Confirm before writing

Before either file is modified, paste the full YAML blocks you're about to append into the chat and ask for a typed `apply` confirmation. Do not write on implicit approval.

## Post-write

- Remind the user to run `./scripts/Deploy-DataSources.ps1 -AccountName <purviewAccountName> -WhatIf` followed by `./scripts/Deploy-Scans.ps1 -AccountName <purviewAccountName> -WhatIf` (reading `purviewAccountName` from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml), never a hardcoded account name) and paste both drift reports into the PR.
- Remind the user that if the authentication method is not `ManagedIdentity`, the PR description must explain why, per [`data-plane-yaml.instructions.md`](../instructions/data-plane-yaml.instructions.md).

## Rules for the agent

- Never accept a literal account key, connection string, SAS token, or client secret. If the user pastes one, stop and cite [`copilot-instructions.md`](../copilot-instructions.md) principle #1.
- Never invent the Entra app object ID or the Key Vault name — ask the user.
- Never default the authentication method to `AccountKey` to avoid asking a question.
- Never emit a scan block without a corresponding data source block, or vice versa.

Reference: [Supported data sources](https://learn.microsoft.com/en-us/purview/sources-and-scans), [Credentials for source authentication](https://learn.microsoft.com/en-us/purview/manage-credentials), [Credential management — recommended options](https://learn.microsoft.com/en-us/purview/data-gov-classic-security-best-practices#credential-management).
