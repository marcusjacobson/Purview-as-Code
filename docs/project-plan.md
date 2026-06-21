# Purview-as-Code — project plan

> [!IMPORTANT]
> **This is a template.** It ships empty. Populate the §3 feature inventory, the §5
> progress checklist, the §6 dependency matrix, and the §8 open-question ledger as you
> adopt Microsoft Purview features into as-code governance for *your* tenant. Nothing
> below is prescriptive about order — it is your roadmap to fill in.

> [!NOTE]
> This document is a **plan**, not an implementation. Every code or YAML change lands
> through its own approved item, with its own Microsoft Learn citations and its own
> pre-commit evidence per [`.github/instructions/pre-commit.instructions.md`](../.github/instructions/pre-commit.instructions.md).
> The Squad agents (`@idea-intake`, `@artifact-resolver`, `@owner-approval`) own the
> lifecycle per [ADR 0014](adr/0014-agents-as-default-entry-point.md).

> [!IMPORTANT]
> **Two artifacts, one source of truth per concern.**
>
> - **This file** is the *strategic plan*: scope, principles, feature inventory, dependency
>   matrix, out-of-scope, the per-feature **progress checklist**, and the open-question ADR ledger.
> - **GitHub Issues** are the *tactical work items*: per-feature acceptance criteria, exit
>   criteria, Learn citations, ADR gates, and persona routing. Filed and curated by the Squad agents.
>
> If the per-item details below ever drift from the linked issue, **the issue wins**.

## Table of contents

- [1. Scope and constraints](#1-scope-and-constraints)
- [2. Guiding principles](#2-guiding-principles)
- [3. Feature inventory](#3-feature-inventory)
- [4. Per-feature lifecycle](#4-per-feature-lifecycle)
- [5. Progress checklist](#5-progress-checklist)
- [6. Dependency matrix](#6-dependency-matrix)
- [7. Out of scope](#7-out-of-scope)
- [8. Open-question ADRs](#8-open-question-adrs)

## 1. Scope and constraints

Define the boundaries for your adoption: the single deployment environment (this template
targets one, per the "Environment and identifier boundaries" section of
[`copilot-instructions.md`](../.github/copilot-instructions.md)), the tenant, the region,
and any features explicitly excluded (record those in §7).

## 2. Guiding principles

1. **Microsoft Learn is the source of truth.** Every resource, cmdlet, REST endpoint, and
   action version cites a current Learn page.
2. **One feature at a time.** Walk the §5 checklist top to bottom — no batching.
3. **Agent-led lifecycle.** `@idea-intake` → `@artifact-resolver` → `@owner-approval`.
4. **Secure-by-design.** No secrets, no real identifiers; least privilege; OIDC for CI.
5. **Idempotent, reversible, auditable.** Every change is a reconciler-backed, reviewable PR.

## 3. Feature inventory

List the Microsoft Purview solution surface you intend to govern as code. One row per feature.

| Feature | Data-plane folder | Reconciler | Notes |
|---|---|---|---|
| _e.g._ Sensitivity labels | `data-plane/information-protection/` | `scripts/Deploy-Labels.ps1` | |
| | | | |

## 4. Per-feature lifecycle

For each feature: **review** current tenant state → **close drift** between tenant and YAML →
**harden** (security, naming, Learn citations) → **tick** the §5 checklist row when its exit
criteria are verified.

## 5. Progress checklist

One row per feature from §3. Tick when the feature's exit criteria (on its linked issue) are met.

| # | Feature | Status | Issue |
|---|---|---|---|
| 5.1 | _populate_ | ☐ | |

## 6. Dependency matrix

Mark (●) where a feature's row depends on another feature shipping first. `@idea-intake`
enforces this: every ● prerequisite must already be ticked in §5 before the dependent item
may branch. An empty matrix means no cross-feature prerequisites.

| Feature ↓ depends on → | _(add columns)_ |
|---|---|
| _populate_ | |

## 7. Out of scope

Record features or capabilities you have deliberately excluded, with a one-line rationale.

## 8. Open-question ADRs

Open design questions that gate one or more §5 rows. Each becomes its own ADR item that must
ship before the gated row may start. **The template ships with none** — add rows as questions arise.

| ID | Question | Gates row(s) | Status |
|---|---|---|---|
| _(none)_ | | | |
