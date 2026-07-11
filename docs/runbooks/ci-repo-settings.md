# Runbook: Non-default GitHub repo settings this repo depends on

This runbook documents repo-level settings on
[`contoso/Purview-as-Code-Generic`](https://github.com/contoso/Purview-as-Code-Generic)
that **differ from GitHub defaults** and are required for the
Squad-agent lifecycle (per [ADR 0014](../adr/0014-agents-as-default-entry-point.md))
or the scheduled drift-sync workflows to function end-to-end.

Document everything **non-default** here. Defaults that this repo
accepts as-is do not belong on this list. If a future change adds a
new dependency on a non-default setting, append a row in the same PR
that introduces the dependency.

## Settings inventory

| Setting | Value | Set via | Why this repo needs it | Verify command |
|---|---|---|---|---|
| Allow GitHub Actions to create and approve pull requests | enabled (`can_approve_pull_request_reviews: true`) | [`Settings → Actions → General → Workflow permissions`](https://github.com/contoso/Purview-as-Code-Generic/settings/actions) or `gh api -X PUT repos/{owner}/{repo}/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true` | [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml) (and any future `sync-*-from-tenant.yml`) and [`drift-detection.yml`](../../.github/workflows/drift-detection.yml) open a drift-back PR using `peter-evans/create-pull-request`. Without this setting the workflow fails with `GitHub Actions is not permitted to create or approve pull requests.` | `gh api repos/{owner}/{repo}/actions/permissions/workflow --jq '.can_approve_pull_request_reviews'` → `true` |
| Default workflow permissions | `read` (read-only `GITHUB_TOKEN` by default; workflows opt into `write` per-job) | Same `gh api` PUT or UI | Least-privilege default per [security.instructions.md](../../.github/instructions/security.instructions.md) rule 4. Each workflow that needs write access opts in via an explicit `permissions:` block. | `gh api repos/{owner}/{repo}/actions/permissions/workflow --jq '.default_workflow_permissions'` → `read` |
| Squash-merge commit title | `COMMIT_OR_PR_TITLE` | `Settings → General → Pull Requests` | [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml) merges with `gh pr merge --squash`. The squash commit must carry the Conventional Commits subject from the original commit (or PR title) so the merged history on `main` stays parseable by tooling. | `gh api repos/{owner}/{repo} --jq '.squash_merge_commit_title'` → `COMMIT_OR_PR_TITLE` |
| Squash-merge commit message | `COMMIT_MESSAGES` | Same panel | Preserves the per-commit body (and any Microsoft Learn citations) on `main` after the squash. | `gh api repos/{owner}/{repo} --jq '.squash_merge_commit_message'` → `COMMIT_MESSAGES` |

## Settings that are GitHub defaults and *not* documented here

The following are GitHub-default values that this repo accepts unchanged
and therefore do **not** appear in the inventory above:

- `allow_merge_commit: true`, `allow_rebase_merge: true` (defaults). The
  squash-merge path is what [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml)
  uses; the other two are not used by any workflow but stay enabled
  for human merges in unusual cases.
- `delete_branch_on_merge: false` (GitHub default). The auto-merge
  workflow passes `--delete-branch` explicitly, so the repo-level
  default does not matter.
- `web_commit_signoff_required`, branch-protection rules. The lab is a
  single-owner private repo on GitHub Free; required-reviewer and
  signed-commit rules are not in scope (see
  [`kv-temp-unlock.md`](kv-temp-unlock.md) "Plan caveat" section for
  the equivalent rationale).

## How to verify all settings at once

```pwsh
$repo = 'contoso/Purview-as-Code-Generic'
gh api "repos/$repo/actions/permissions/workflow"
gh api "repos/$repo" --jq '{squash_merge_commit_title, squash_merge_commit_message, allow_squash_merge}'
```

Expected output:

```json
{
  "default_workflow_permissions": "read",
  "can_approve_pull_request_reviews": true
}
{
  "squash_merge_commit_title": "COMMIT_OR_PR_TITLE",
  "squash_merge_commit_message": "COMMIT_MESSAGES",
  "allow_squash_merge": true
}
```

If any value drifts from the expected, re-apply via the `gh api` commands
in the inventory table above (or via the GitHub Settings UI) and open
an issue documenting why the drift occurred.

## References

- **[Managing GitHub Actions settings for a repository — Preventing GitHub Actions from creating or approving pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#preventing-github-actions-from-creating-or-approving-pull-requests)**
  Fetch date: 2026-05-29
  > "By default, GitHub Actions cannot create or approve pull requests. Allowing workflows, or any other automation, to create or approve pull requests could be a security risk if the pull request is merged without proper oversight."
- **[REST API endpoints for GitHub Actions permissions — Get default workflow permissions for a repository](https://docs.github.com/en/rest/actions/permissions#get-default-workflow-permissions-for-a-repository)**
  Fetch date: 2026-05-29
- **[REST API endpoints for repositories — Update a repository](https://docs.github.com/en/rest/repos/repos#update-a-repository)**
  Fetch date: 2026-05-29
- [ADR 0014 — Agents as the default entry point](../adr/0014-agents-as-default-entry-point.md)
- [`pr-auto-merge.yml`](../../.github/workflows/pr-auto-merge.yml)
- [`sync-labels-from-tenant.yml`](../../.github/workflows/sync-labels-from-tenant.yml)
