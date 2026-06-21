---
description: "Walk through a control-plane Bicep deployment for this repo: lint → build → what-if → confirm → create."
mode: agent
---

# Deploy infrastructure (control plane)

Follow these steps in order. Do not skip steps. Do not proceed past a step that emits an error or a warning.

## Preconditions

1. Confirm the user is logged in: run `az account show` and echo the `name` and `id` (redact the subscription ID per the "Environment and identifier boundaries" rule — show only the first 8 characters).
2. Confirm the target resource group: `rg-purview-lab` in `eastus`. If `az group show -n rg-purview-lab` returns 404, ask whether to create it; do not create it silently.
3. Confirm the active branch is a feature branch (not `main`). If it is `main`, stop and ask the user to create a feature branch.

## Step 1 — Lint

```pwsh
az bicep lint --file infra/main.bicep
```

If exit code is non-zero, stop. Paste the full output and ask the user how to proceed.

## Step 2 — Build

```pwsh
az bicep build --file infra/main.bicep --outfile infra/main.json
```

If exit code is non-zero, stop. The emitted `infra/main.json` is a build artifact — do not commit it.

## Step 3 — What-if

```pwsh
az deployment group what-if `
  -g rg-purview-lab `
  -f infra/main.bicep `
  -p infra/main.bicepparam
```

- Paste the full what-if output into the chat.
- Categorize the changes: `Create`, `Modify`, `Delete`, `NoChange`, `Ignore`.
- If any `Delete` line appears, stop and explicitly ask the user whether this PR is labeled `destructive` per the pre-commit checklist. Do not proceed without a typed `confirm delete` reply.
- If only `Create` / `Modify` / `NoChange` lines appear, summarize what will change and ask for a plain `apply` confirmation.

## Step 4 — Apply (only after explicit confirmation)

```pwsh
az deployment group create `
  -g rg-purview-lab `
  -f infra/main.bicep `
  -p infra/main.bicepparam
```

- Do not run this step until the user has typed `apply` (or `confirm delete` for destructive changes) in the current turn.
- After the deployment completes, echo `provisioningState` and `correlationId` from the response.
- Do not echo any resource URL, managed identity `principalId`, or tenant / subscription ID in full. Redact per the "Environment and identifier boundaries" rule.

## Step 5 — Record evidence

- Paste the final what-if output and the `provisioningState` line into the PR description per the pre-commit checklist in [`copilot-instructions.md`](../copilot-instructions.md).
- Remind the user to delete the build artifact: `Remove-Item infra/main.json`.

## Rules for the agent

- Do not combine steps into a single command.
- Do not run any `az` command with `--yes`, `--force`, or `--no-prompt` flags.
- If a step fails, diagnose before retrying. Do not retry the same command with different flags hoping for a different outcome.
- Never print secrets, tokens, or connection strings that appear in the deployment output.

Reference: [Deploy Bicep files with Azure CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-cli), [What-if operation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if).
