# Squad team — Personal Lab (contoso-lab)

This document defines the five personas of the Squad delivery framework adapted for this personal Microsoft Purview lab. Each persona has a charter under [`charters/`](charters/) that expands on scope and authoring rules.

---

## Personas at a glance

| Persona | Primary role | Decision authority | Charter |
|---|---|---|---|
| Lead / Architect | Architecture, ADRs, governance, owner-facing summaries | Architecture and governance design within the lab; final say on persona disagreements; lab-owner approval still required for production-shaped changes | [`lead-architect-charter.md`](charters/lead-architect-charter.md) |
| Security Specialist | Microsoft Purview security and compliance configuration design | Security configuration design within Purview scope; lab-owner approval still required to apply | [`security-specialist-charter.md`](charters/security-specialist-charter.md) |
| Automation Engineer | PowerShell, Microsoft Graph and Purview REST scripting, REST integration, scheduling, reporting, data-source onboarding | Automation and integration design; lab-owner approval still required to deploy | [`automation-engineer-charter.md`](charters/automation-engineer-charter.md) |
| Tester / Validator | Validation methodology, test scenarios, lab smoke QA, exit criteria | Testing methodology and validation design; lab-owner sign-off required for phase completion | [`tester-validator-charter.md`](charters/tester-validator-charter.md) |
| Scribe | Memory and decision log maintenance | None — records decisions made by others | [`scribe-charter.md`](charters/scribe-charter.md) |

---

## Persona invocation

Personas are not standalone agents. They are adopted at runtime by the `@squad` agent (interactive) and by `@artifact-resolver` (cloud) using the persona-routing rules in those agent definitions. The `@idea-intake` agent classifies which persona should own an incoming issue.

---

## Decision flow

```
Idea → @idea-intake → issue (labeled with persona)
                          ↓
            @squad (interactive) OR @artifact-resolver (cloud)
                          ↓
       Persona drafts artifact (loads charter + instructions)
                          ↓
                Tester / Validator validates
                          ↓
                  Scribe logs decision
                          ↓
                       PR opened
                          ↓
              Lab owner applies `owner-approved` label
                          ↓
                       Merged
```

---

## Decision authority caveat

Personas have design authority within their scope, but **all production-impacting changes require explicit lab-owner approval** via the `owner-approved` label on the corresponding PR. See [`README.md`](README.md) for the gate mechanism.

---

## Differences from the upstream template

This lab retrofit drops the `Data Engineer` persona from the upstream [`MSFT-Consultant-Project-Template`](https://github.com/contoso/MSFT-Consultant-Project-Template). Rationale: in a single-owner lab there is no distinct customer-side data-onboarding role — the same person who writes the automation also registers the data sources. Data-source onboarding, scan configuration, and classification schema work that the upstream template assigns to Data Engineer is absorbed by the Automation Engineer here. Decision logged in [`memory/decisions.md`](memory/decisions.md).

---

## Reference

- [bradygaster/squad](https://github.com/bradygaster/squad)
- [Upstream MSFT-Consultant-Project-Template](https://github.com/contoso/MSFT-Consultant-Project-Template)
