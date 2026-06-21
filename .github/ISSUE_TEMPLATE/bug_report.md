---
name: Bug report
about: Report a defect in the infra (control plane), data-plane (data plane), scripts, or workflows.
title: "bug: <short summary>"
labels: ["bug", "triage"]
---

## Plane and scope

- [ ] `infra/**` (control plane, Bicep)
- [ ] `data-plane/**` (data plane, YAML)
- [ ] `scripts/**` (PowerShell apply logic)
- [ ] `.github/workflows/**` (CI/CD)
- [ ] `docs/**` or `README.md`

## What happened

<!-- Describe the observed behavior. Paste the exact command and its output. -->

## What you expected

<!-- Describe the expected behavior, with a Microsoft Learn citation if the expectation is grounded in docs. -->

## Reproduction

<!-- Minimal steps. Include the branch, commit SHA, and the full command. Redact real tenant/subscription/object IDs per .github/copilot-instructions.md "Environment and identifier boundaries". -->

## Environment

- Repo branch / commit:
- OS and shell:
- `az --version`:
- `pwsh --version`:

## Security note

- [ ] This report contains no secrets, keys, tokens, or real identifiers (tenant / subscription / object / UPN).

<!-- If the bug involves a security-sensitive behavior, use the Security policy instead: see SECURITY.md. -->
