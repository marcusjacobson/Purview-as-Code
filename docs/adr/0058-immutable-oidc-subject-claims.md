# 0058 — Federated-credential subjects support GitHub's immutable (ID-embedded) OIDC format

- **Status:** Accepted
- **Date:** 2026-07-17
- **Gates:** Cross-cutting; no [`project-plan.md`](../project-plan.md) §5 / §8 row. Amends [ADR 0010](0010-automation-identity-subject-model.md) decision #2 by extension: the single expected subject becomes a two-format contract (classic + immutable), with the immutable format preferred wherever GitHub mints it. Complements [ADR 0057](0057-multi-environment-and-branch-model.md) §9's repository-migration threat analysis — the immutable format is a platform-level defence against exactly the dead-repo-resurrection attack that section reasons about. Gates every future spin-off created after GitHub's 2026-07-15 cutoff: without this decision, `New-AutomationEntraApp.ps1` / `New-KvUnlockEntraApp.ps1` either provision credentials that can never pass `azure/login` or hard-refuse every reconcile.
- **Deciders:** marcusjacobson

## Context

GitHub Actions OIDC tokens historically carried a name-based subject claim,
`repo:<org>/<repo>:environment:<env>`, and [ADR 0010](0010-automation-identity-subject-model.md)
decision #2 pinned this repository's entire federated-credential contract to that exact string:
the provisioning scripts (`scripts/New-AutomationEntraApp.ps1`,
`scripts/New-KvUnlockEntraApp.ps1`) build it from `automation.githubOrg` / `automation.githubRepo`
/ the environment name in the parameters file, create it verbatim, and **hard-refuse** any
reconcile where the existing credential's subject differs (the ADR 0010 decision #4
never-silently-reconcile rule).

On 2026-04-23 GitHub introduced
[immutable subject claims](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/):
the default `sub` claim now embeds the numeric owner and repository IDs using `@` as a delimiter
(legal because `@` cannot appear in a GitHub username or repository name):

```text
classic:   repo:octo-org/octo-repo:environment:kv-unlock
immutable: repo:octo-org@123456/octo-repo@456789:environment:kv-unlock
```

The rollout contract, per the changelog and the
[OIDC reference](https://docs.github.com/en/actions/reference/security/oidc):

- **Repositories created after 2026-07-15** mint the immutable format **by default**.
- **Existing repositories keep the classic format** unless (a) they are renamed or transferred
  after the cutoff, or (b) an admin opts in via the repository/organization OIDC settings (UI or
  API).
- The change is github.com-only (no GHES impact).

The point of the feature is precisely the threat [ADR 0057](0057-multi-environment-and-branch-model.md)
§9 reasons about for repository migration: a name-based subject is **resurrectable** — delete the
repo (or the org), let someone re-register the same names, and their workflows mint tokens whose
subject matches the old federated credential. Numeric IDs are never reused, so an ID-embedded
subject dies with the repository that owned it.

Observed live during the first downstream tenant wiring (operations repo created after the
cutoff): `azure/login` failed with `AADSTS700213` (no matching federated identity record),
presenting an immutable-format subject while the app carried the classic credential the template
scripts had built. Because the scripts also hard-refuse a subject mismatch on reconcile, the
operator could not converge from inside the tooling in either direction — classic credentials
fail every `azure/login`, corrected (immutable) credentials fail every reconcile. All six
federated credentials were updated by hand, outside the scripts. That is the gap this ADR closes.

Constraints:

- ADR 0010's security invariants must survive intact: exactly one federated credential per app,
  environment-scoped subject, no `ref:`/`pull_request` subjects, loud failure on anomalies.
- The template cannot know at authoring time which format a spin-off will mint — that depends on
  the consumer repository's creation date, rename/transfer history, and opt-in state.
- The provisioning scripts run on operator machines. GitHub API access is normally available
  there (`gh` is required by the kickoff flow) but must not become a hard dependency for
  pre-cutoff repositories that never needed it.

## Decision

1. **The template supports both subject formats, and prefers the immutable format wherever
   GitHub mints it.** The immutable format is a strict security improvement (it defeats
   dead-repo resurrection at the identity-provider layer), so the template never asks an
   operator to downgrade; the downstream decision to keep the immutable format is ratified as
   the intended posture for post-cutoff repositories.

2. **The provisioning scripts resolve the repository's numeric identity at runtime and compute
   both candidate subjects.** One `GET /repos/{owner}/{repo}` call (via `gh api` when the CLI is
   available and authenticated, falling back to an unauthenticated
   `https://api.github.com/repos/{owner}/{repo}` request, which suffices for public
   repositories) yields the owner ID, repository ID, and creation date. From these the scripts
   build the classic subject and — when the IDs resolved — the immutable subject.

3. **Format selection is automatic, with an explicit override.** Both scripts gain a
   `-SubjectFormat auto|classic|immutable` parameter (default `auto`):
   - `auto` — prefer the immutable subject when the repository was created on or after
     2026-07-15T00:00:00Z (GitHub's default-format cutoff); otherwise prefer classic. When the
     repository identity cannot be resolved (offline, unauthenticated against a private repo),
     warn and fall back to classic — the pre-cutoff behaviour.
   - `immutable` — for pre-cutoff repositories that opted in, or were renamed/transferred after
     the cutoff (both invisible to the creation-date heuristic). Repository-identity resolution
     failure is a hard error here, never a silent downgrade.
   - `classic` — pins today's behaviour and skips GitHub API resolution entirely (air-gapped
     escape hatch).
   The **preferred** format is what a freshly created credential gets.

4. **Verification accepts either format; everything else still fails loudly.** An existing
   single credential whose subject equals either candidate passes reconcile (transition
   acceptance — a hand-migrated credential, like downstream's, reconciles cleanly). When the
   numeric IDs could not be resolved, a subject that matches the immutable *pattern* for the
   right `<org>/<repo>` and environment (`repo:<org>@<digits>/<repo>@<digits>:environment:<env>`)
   is accepted with a warning naming what could not be verified. Any other subject remains the
   same hard refusal as before — ADR 0010 decision #4's single-credential invariant and
   never-silently-reconcile rule are unchanged in both scripts.

5. **A classic credential on a repository that mints immutable subjects draws a loud, actionable
   warning** (it is dormant: `azure/login` can never match it). The cutover is the ADR 0010
   bounded procedure: delete the credential and re-run the provisioning script (which then mints
   the immutable subject), or follow ADR 0057 §7's add-verify-remove window when zero-downtime
   matters. The scripts do not auto-rewrite the credential — never-silently-reconcile holds.

6. **Documentation ships the two-format contract.** `docs/getting-started.md` §1's subject table
   and hand-rolled `az ad app federated-credential create` example gain the immutable format and
   the two `gh api` ID-resolution commands; the multi-environment section inherits the same rule
   (the format is per-repository, so `dev` / `kv-unlock-dev` credentials follow whatever format
   the repository mints).

## Consequences

- **Spin-offs created after 2026-07-15 work out of the box.** The scripts detect the
  post-cutoff creation date, mint immutable-format credentials, and `validate-oidc-auth` passes
  without hand-editing — previously impossible from inside the tooling.
- **Existing single-environment deployments are untouched.** Pre-cutoff repositories resolve to
  classic under `auto`; every already-provisioned credential still matches its candidate set;
  no operator action is required on upgrade.
- **The downstream hand-migration is now a supported state**, not an anomaly: reconciles accept
  the immutable subject and the scripts would have produced the same string.
- **A renamed or transferred repository needs the override** (`-SubjectFormat immutable`) or a
  hand-cutover, because the creation-date heuristic cannot see rename/transfer events and
  GitHub's OIDC settings expose no read API for the effective format at the time of this ADR.
  The failure mode is a warning plus a dormant credential — identical to what any consumer hits
  today, but now with named guidance instead of a dead end.
- **The GitHub API becomes a soft dependency** of the provisioning scripts. Soft only: `classic`
  skips it, `auto` degrades to classic with a warning, and only `immutable` treats resolution
  failure as fatal — deliberate, because in that mode a wrong guess bricks `azure/login`.
- Security posture per [`security.instructions.md`](../../.github/instructions/security.instructions.md):
  upheld — least-privilege identity contract is unchanged, and the preferred format strictly
  narrows what can satisfy the trust relationship (name **and** immutable numeric identity
  instead of name alone).

## Alternatives considered

1. **Do nothing (keep classic-only).** Every post-cutoff spin-off fails `azure/login` out of
   the box and the scripts refuse to reconcile the fix. Rejected — this is the live defect.
2. **Immutable-only (drop classic).** Cleanest security story, but it breaks every existing
   pre-cutoff deployment on next reconcile (their credentials are classic and GitHub keeps
   minting classic subjects for them — forcing immutable credentials there bricks *their*
   `azure/login`), and it makes the GitHub API a hard dependency. Rejected: the format must
   follow what GitHub actually mints per repository.
3. **Store the numeric IDs in the parameters file instead of resolving at runtime.** Adds two
   hand-maintained identifier fields to `infra/parameters/*.yaml` (ADR 0012 surface), which can
   silently go stale after a transfer and would still need a resolution path to seed them.
   Runtime resolution derives them from the same source of truth GitHub uses to mint the token.
   Rejected; revisitable if an air-gapped consumer ever needs `immutable` without API access.
4. **Detect opt-in via the OIDC customization API instead of the creation date.**
   `GET /repos/{owner}/{repo}/actions/oidc/customization/sub` describes *customized* claim
   templates, not the immutable-format state, and reading it requires admin-scoped tokens the
   provisioning scripts otherwise never need. Rejected until GitHub documents a read API for
   the effective subject format; the `-SubjectFormat immutable` override covers the gap.

## Citations

- [Immutable subject claims for GitHub Actions OIDC tokens (GitHub changelog, 2026-04-23)](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)
- [OpenID Connect reference — GitHub Actions security](https://docs.github.com/en/actions/reference/security/oidc)
- [Configuring OpenID Connect in Azure](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure)
- [Configure an app to trust an external identity provider (Microsoft Entra workload ID)](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust)
- [az ad app federated-credential](https://learn.microsoft.com/en-us/cli/azure/ad/app/federated-credential)
