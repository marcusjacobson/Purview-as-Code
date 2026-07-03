# 0045 — Template kickoff and spin-off consumption model with a no-push-back guard

- **Status:** Proposed <!-- Proposed | Accepted | Superseded by NNNN | Deprecated -->
- **Date:** 2026-07-03
- **Gates:** Cross-cutting; no [`project-plan.md`](../project-plan.md) §5 / §8 row. Tracks #4.
- **Deciders:** contoso

## Context

This repository is a **tenant-neutral template**. Its `README.md` banner tells a consumer to
clone it and run the [`@operator-tenant`](../../.github/agents/operator-tenant.agent.md) Tenant
Intake agent, which tailors a fresh clone *in place* — it swaps placeholder values into
`infra/parameters/lab.yaml` and the identity-boundary statements. `@operator-tenant` answers
"what tenant values go into this copy?" It does **not** answer two questions that come first:

1. **Where does the consumer's copy live?** Some adopters want a private, local-only working
   tree to manage their own Microsoft Purview tenant with no GitHub backing (or one they will
   add by hand later). Others want their own GitHub repository from the start.
2. **How is the consumer's copy severed from this template?** A copy that still has this
   template's repository set as its `origin` (or as a push-capable remote) can accidentally —
   or deliberately — push commits or open pull requests back into the canonical source repo
   (`contoso/Purview-as-Code-Generic`). The lab owner requires that a consumer's copy be
   **unable to contribute content back** to the source template repository.

There is no guided front door for either question today, and no enforced boundary preventing
push-back. Prose in the README ("please tailor your own copy") is guidance, not a control.

GitHub already distinguishes two ways to derive a repository from another. A **fork** "shares
code" with an upstream and exists precisely so that "changes from forks can be merged back into
the upstream repository via pull requests." A repository created from a **template** is
different: it "starts with a single commit" and its branches "have unrelated histories, which
means you cannot create pull requests or merge between the branches." The template path is
therefore the GitHub-native mechanism that structurally prevents push-back — a template copy is
not a fork and cannot open a pull request to the source. This ADR decides how the repository's
kickoff experience uses that distinction, plus local-git controls, to enforce the boundary.

## Decision

We will add a new **kickoff front-door agent** and define a layered **no-push-back guard**.
Specifically:

1. **New agent, not an extension.** We will add `@operator-kickoff`
   (`.github/agents/operator-kickoff.agent.md`) as a sibling of `@operator-tenant`. It runs
   once, before tenant tailoring, owns the "where does this copy live and how is it severed"
   decision, then hands off to `@operator-tenant` for the tenant-value tailoring. Keeping it
   separate preserves single responsibility and least-privilege tool scoping per
   [`agents.instructions.md`](../../.github/instructions/agents.instructions.md); `@operator-tenant`
   stays focused on tenant values.

2. **Two consumption modes.** `@operator-kickoff` presents a selectable menu (per
   [`INTERACTION-MENUS.md`](../../.github/agents/INTERACTION-MENUS.md)) with two modes:
   - **Mode A — Local workspace.** For a consumer who wants a local-only working tree with no
     GitHub backing. Mechanics: remove the source `origin`
     (`git remote remove origin`) and re-initialize history from a single fresh commit
     (`git init` then an initial commit), so there is neither a push path nor a shared
     commit graph back to the source. The consumer may add their own private remote later, by
     hand.
   - **Mode B — Spin-off GitHub repository.** For a consumer who wants their own GitHub repo.
     The **preferred** path is the GitHub-native template mechanism — "Use this template" in
     the UI, or `gh repo create <owner>/<repo> --template <source>` — because a
     template-generated repository starts from a single commit with unrelated history and
     therefore cannot open a pull request back to the source. When a consumer has *already*
     cloned, the agent instead creates a fresh repository and repoints `origin`
     (`gh repo create <owner>/<repo> --private --source=. --remote=origin --push`).

3. **The no-push-back guard is defense-in-depth (four layers).** No single layer is
   sufficient, so `@operator-kickoff` enforces all of the following on the consumer's copy:
   1. **Origin severance.** After kickoff, `origin` must never resolve to the canonical
      source-template URL. Mode A removes it; Mode B repoints it at the consumer's repo.
   2. **Push-URL disablement for a retained upstream.** If the consumer opts to keep the source
      as a read-only `upstream` remote (to *pull* future template updates), the agent disables
      its push URL with `git remote set-url --push upstream DISABLE`, setting a non-resolvable
      sentinel so `git push upstream` fails fast while `git fetch upstream` still works.
   3. **`pre-push` hook (best-effort backstop).** The agent installs a `pre-push` hook that
      aborts any push whose destination URL matches the canonical source-template URL. This is
      explicitly best-effort — hooks are not guaranteed present on a re-clone and are bypassable
      with `--no-verify` — so it backstops but does not replace layers 1–2.
   4. **Agent-level refusal.** `@operator-kickoff` refuses to configure any remote whose URL
      matches the canonical source-template URL, and self-checks that it is not running *inside*
      the source template repository itself, so the guard cannot be turned against the source.

   The canonical source-template URL is **detected at kickoff** from the pre-severance `origin`,
   not hardcoded, so the guard travels correctly with any renamed template.

4. **Verification gate.** Before reporting success, `@operator-kickoff` asserts: (a)
   `git remote get-url origin` does not match the canonical source URL (or `origin` is absent in
   Mode A); (b) any `upstream` push URL is the `DISABLE` sentinel; (c) a residual scan of git
   config finds no push-capable remote pointing at the source. Any failure is a hard stop.

5. **History handling.** Mode A **discards** git history (fresh `git init`) — clean severance is
   the priority for a local-only workspace, and a personal lab has no source-provenance
   requirement. Mode B via the template mechanism **starts from a single commit** by GitHub's
   design; the clone-and-repoint fallback preserves the consumer's local history but its new
   `origin` is the consumer's own repo. We accept losing source commit history on the template
   path as the intended, strongest guarantee against push-back.

Source-side controls remain the owner's responsibility on the canonical repo and are documented,
not enforced by the consumer's copy: keep the source marked as a GitHub template repository
(steering consumers to "Use this template" over "Fork"), and keep branch protection on the
source `main`.

## Consequences

- **Unblocked follow-on items** (each ships as its own agent-led item once this ADR is
  Accepted): (1) author `@operator-kickoff` plus the guard scripts / `pre-push` hook; (2) rewrite
  the README quick-start, [`docs/tenant-onboarding.md`](../tenant-onboarding.md), and
  [`.github/agents/README.md`](../../.github/agents/README.md) to lead with the kickoff → tenant
  intake flow; (3) mark the source repository as a GitHub template.
- **Easier:** a consumer gets a guided, one-time choice between a local workspace and a spin-off
  repo, and the "no content back to the source" boundary becomes an enforced control rather than
  a request.
- **Harder / accepted trade-offs:** Mode A intentionally discards history and drops the easy
  upstream-update path (the consumer re-integrates template changes manually). Severance is
  deliberately hard to reverse, which is the point; `@operator-kickoff` therefore refuses to
  re-run on an already-severed copy without an explicit override.
- **Security principles upheld** (per
  [`security.instructions.md`](../../.github/instructions/security.instructions.md)): least
  privilege for the new agent's tool list; no secrets or real identifiers introduced (the source
  URL is detected at runtime, never committed). Principle 9 (idempotent, reversible, auditable) is
  *relaxed with justification*: severance is intentionally one-directional so a consumer copy
  cannot re-attach a push path to the source.
- **No `docs/project-plan.md` §5 row changes** — this is cross-cutting template plumbing, not a
  Microsoft Purview feature adoption.

## Alternatives considered

**Alternative A: Extend `@operator-tenant` to also do kickoff.** Reject. It mixes the one-time
"where does this copy live / how is it severed" decision with the repeatable tenant-value
tailoring, bloats one agent's tool scope, and weakens the least-privilege boundary that
[`agents.instructions.md`](../../.github/instructions/agents.instructions.md) requires.

**Alternative B: Rely solely on GitHub source-side controls (branch protection, no external
PRs).** Reject. Source-side settings do not cover the local-workspace mode at all, and do not stop
a consumer with write access from pushing to the source; the guard must also live on the
consumer's copy.

**Alternative C: Do nothing — keep only `@operator-tenant` and ask consumers in prose not to push
back.** Reject. Prose is not a control, the status quo offers no kickoff choice, and it leaves the
push-back boundary unenforced, which is the explicit requirement this ADR exists to satisfy.

## Citations

Microsoft Learn does not currently document GitHub template-repository behavior or git-remote
push-URL plumbing as of 2026-07-03. Per the grounding precedence in
[`copilot-instructions.md`](../../.github/copilot-instructions.md), the authoritative sources for
these claims are the official GitHub and git references below (official Microsoft / canonical-tool
properties).

- **[Creating a repository from a template](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template)**
  Fetch date: 2026-07-03
  > "Branches created from a template have unrelated histories, which means you cannot create pull requests or merge between the branches."
- **[About forks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/about-forks)**
  Fetch date: 2026-07-03
  > "changes from forks can be merged back into the upstream repository via pull requests, similar to a branch."
- **[git-remote](https://git-scm.com/docs/git-remote)**
  Fetch date: 2026-07-03
  > "set-url ... With `--push`, push URLs are manipulated instead of fetch URLs." (canonical git reference; no Microsoft Learn page covers git remote plumbing)
- **[githooks](https://git-scm.com/docs/githooks)**
  Fetch date: 2026-07-03
  > "Hooks are programs you can place in a hooks directory to trigger actions at certain points in git's execution."
- **[gh repo create](https://cli.github.com/manual/gh_repo_create)**
  Fetch date: 2026-07-03
  > "Make the new repository based on a template repository" (`--template`); "Specify path to local repository to use as source" (`--source`).
- [Custom agents in VS Code](https://code.visualstudio.com/docs/agent-customization/custom-agents)
