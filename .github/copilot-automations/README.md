# Copilot cloud-agent automations

This folder holds the **canonical prompts** for the repository's scheduled GitHub Copilot
cloud-agent automations. A [Copilot automation](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations)
runs the cloud agent on a schedule (or on a repository event) and is configured in the **GitHub UI**,
not as an Actions workflow. The files here are the version-controlled source of truth for each
automation's prompt; the live automation is wired up in the UI from these prompts.

This is distinct from the other Copilot primitives in this repo:

- `../prompts/` — `/`-invoked Chat prompt templates (task sequences run by a human in Copilot Chat).
- `../agents/` — custom agents (personas with scoped tools).
- `../skills/` — on-demand loadable knowledge.
- **here** — prompts pasted into a scheduled cloud-agent automation that runs unattended.

## Automations

### feature-currency-watch

| Field | Value |
|---|---|
| Purpose | Recurring Microsoft Purview "what's new" review (Slice 13, decided by [ADR 0044](../../docs/adr/0044-currency-watch-loops.md)). Opens a `feature-currency` issue when net-new features or newly-as-code surfaces appear. |
| Prompt | [`feature-currency-watch.md`](feature-currency-watch.md) |
| Trigger | Weekly schedule |
| Model | A **reasoning-tier** model per [ADR 0043](../../docs/adr/0043-model-tier-policy.md) |
| Tools | **Issue creation / commenting only** — no pull request, no code edit, no deploy |
| Output | One deduplicated issue in the review queue (open issues bearing the loop's marker label) |

## Creating an automation in the GitHub UI

1. **Confirm the repository is private or internal.** Copilot automations are unavailable in public
   repositories. See [About Copilot automations — availability](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations).
2. Open the repository's **Agents** tab, click **Automations** in the sidebar (or use the
   **Automations** tab in the GitHub Copilot app), then click **Create new**.
   See [Creating automations with Copilot cloud agent](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-automations).
3. **Name:** `feature-currency-watch`.
4. **Prompt:** paste the contents of [`feature-currency-watch.md`](feature-currency-watch.md) verbatim.
5. **Trigger:** select **On a schedule**, then choose **Weekly** (the schedule cadence options are
   hourly, daily, or weekly).
6. **Model:** select a reasoning-tier model per [ADR 0043](../../docs/adr/0043-model-tier-policy.md).
7. **Tools:** restrict to **issue creation / commenting only**. Do **not** grant pull-request,
   code-edit, or deploy tools — the issue-only scope is what keeps the automation inside the "loops
   produce issues only" invariant.
8. Click **Create automation** to save.

## Keeping the prompt in sync

The UI copy and the prompt file must match. When you change a prompt, update the file **and** re-paste
it into the UI in the same pull request, so the committed source of truth never drifts from the live
automation.

## References

- **[About GitHub Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent)**
- **[About Copilot automations](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-automations)**
- **[Creating automations with Copilot cloud agent](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-automations)**
- [ADR 0044 — Code- and feature-currency watch loops](../../docs/adr/0044-currency-watch-loops.md)
