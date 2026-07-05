---
description: "Walk through a data-plane Purview deployment for this repo: per-domain -WhatIf → confirm → apply, in dependency order."
mode: agent
---

# Deploy data map (data plane)

Follow these steps in order. Each domain has its own `-WhatIf` → confirm → apply cycle. Do not batch the confirmations.

> **The Purview account name comes from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml)**
> — the single source of truth per [ADR 0012](../../docs/adr/0012-environment-parameters-file.md).
> Read `purviewAccountName` from that file and substitute it for the `<purviewAccountName>` token
> below. Never hardcode a tenant-specific account name in this prompt — a tailored copy changes it.

## Preconditions

1. Confirm the user is logged in: `az account show`.
2. Read the target Purview account (`purviewAccountName`) from [`infra/parameters/lab.yaml`](../../infra/parameters/lab.yaml). Echo the value but do not echo full resource IDs.
3. Confirm the active branch is a feature branch (not `main`).
4. Acquire a data-plane token once via `./scripts/Connect-Purview.ps1 -AccountName <purviewAccountName>` and keep it in memory. Do not write the token to disk. Do not echo it.
5. **First run against an existing tenant?** If the account already holds live state and the `data-plane/**` YAML has not yet been bootstrapped, stop and run the export-first step first: `./scripts/Deploy-<Domain>.ps1 -AccountName <purviewAccountName> -ExportCurrentState -Force` for each domain (the `-Force` overwrites the shipped sample YAML on disk only — never Purview), then review, PR, and merge that diff. Skipping this surfaces every live object as an `Orphan`. See [`docs/getting-started.md` §4a](../../docs/getting-started.md#4a-export-the-live-tenant-into-the-yaml-bootstrap-once-per-domain) and the [first-run contract](../instructions/powershell.instructions.md#first-run-against-an-existing-tenant-contract).

## Domain order

The domains must run in this order — each depends on the previous:

1. `Collections` — creates the collection tree referenced by later domains.
2. `Glossary` — terms are attached to collections.
3. `Classifications` — custom rules referenced by scan rulesets.
4. `DataSources` — data sources are placed in collections; they must exist before scans.
5. `Scans` — scans target data sources and use classification rulesets.

## Per-domain cycle

For each of the five domains, run:

```pwsh
./scripts/Deploy-<Domain>.ps1 -AccountName <purviewAccountName> -WhatIf
```

Then:

- Paste the drift report (`Create`, `Update`, `NoChange`, `Orphan`, `Conflict` counts) into the chat.
- If `Orphan` count is non-zero, stop. Do not propose `-PruneMissing`. Remind the user that pruning requires a `destructive`-labeled PR and a typed `confirm delete` reply.
- If `Conflict` count is non-zero, stop. Portal-edited content is in the way; ask the user whether to merge the change manually or overwrite with `-Force` (destructive).
- If only `Create` / `Update` / `NoChange` are non-zero, ask for a typed `apply <domain>` confirmation.

Only after confirmation, run the apply:

```pwsh
./scripts/Deploy-<Domain>.ps1 -AccountName <purviewAccountName>
```

Capture `provisioningState` / HTTP status per object and report the summary in the chat. Do not proceed to the next domain until the previous domain reports zero failures.

## Record evidence

- After all five domains apply, paste every drift report and apply summary into the PR description per the pre-commit checklist in [`copilot-instructions.md`](../copilot-instructions.md).
- Remind the user that no `-PruneMissing` or `-Force` switches appear in any workflow file unless the PR is labeled `destructive`.

## Rules for the agent

- Do not run apply for domain N+1 if domain N reported any failure.
- Do not invoke `-PruneMissing` or `-Force` without a typed destructive confirmation in the current turn.
- Do not echo the bearer token, `Authorization` header, or response bodies that contain credentials.
- Do not invent script parameter names. If a script rejects a parameter, stop and surface the error.

Reference: [Microsoft Purview Data Map REST APIs](https://learn.microsoft.com/en-us/rest/api/purview/datamapdataplane/), [Authenticate for Purview APIs](https://learn.microsoft.com/en-us/purview/data-gov-api-rest-data-plane), [Everything about ShouldProcess](https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/everything-about-shouldprocess).
