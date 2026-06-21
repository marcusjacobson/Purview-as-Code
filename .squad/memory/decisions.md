# Decision log

> **Maintained by:** Scribe persona
> **Last updated:** 2026-05-04
> **Update workflow:** Scribe appends a new row after every session that produces a decision. Existing rows are never modified. See [`../charters/scribe-charter.md`](../charters/scribe-charter.md).

---

## Log format

| Date | Decision | Rationale | Approved By | Reference |
|---|---|---|---|---|
| YYYY-MM-DD | One-sentence description of what was decided | Brief rationale | Lab owner / persona name | ADR-NNN or #PR |

---

## Decision log

| Date | Decision | Rationale | Approved By | Reference |
|---|---|---|---|---|
| 2026-04-25 | Adopt the Squad agent framework from `MSFT-Consultant-Project-Template` as the collaboration and workflow backbone for this lab repo. | Reuses an opinionated, validated multi-persona pattern; reduces ad hoc prompting; keeps memory and decisions in version control alongside the artifacts they govern. | contoso | Squad-retrofit PR |
| 2026-04-25 | Drop the `Data Engineer` persona from the upstream template. Five personas only (Lead/Architect, Security Specialist, Automation Engineer, Tester/Validator, Scribe). | Single-owner lab — there is no distinct customer-side data-onboarding role. Data-source registration, scan configuration, and classification schema work fold into the Automation Engineer charter. | contoso | Squad-retrofit PR |
| 2026-04-25 | Rename the approval label from `consultant-approved` to `owner-approved`, and the routing label from `needs-consultant-review` to `needs-review`. | Solo lab does not have a separate consultant role; the lab owner is the only approver. | contoso | Squad-retrofit PR |
| 2026-04-25 | Skip retrofitting `solution-config/`, `governance/`, `runbooks/`, `backlog/`, and `docs/assessment/` instructions and folders from the upstream template. | These template artifacts target customer-facing deliverables. The lab uses `infra/`, `data-plane/`, `scripts/`, and `docs/adr/` instead, already governed by existing instructions files. | contoso | Squad-retrofit PR |
| 2026-05-04 | Squad agents own intake and governance; the prompt pipeline owns build of project-plan checklist items. Both tracks share `/build-item` and finish at `owner-approved`. | The two tracks were ambiguous and enforced different gates. Naming the split lets `/start-item`'s §6/§8 gating protect Wave delivery without extending it to ADRs and instruction edits where it is irrelevant. | contoso | ADR-0013 / #90 |
| 2026-05-04 | Gate only `idea-intake-autoadd.yml` to `actor.login == 'contoso'`. `issue-triage.yml`, `pr-owner-gate.yml`, and `pr-stacked-retarget.yml` are intentionally ungated. | `needs-review` signals owner-readiness for merge and must not be auto-applied to outside-contributor issues. The other three workflows produce triage signal or run on already-merged PRs and benefit from running for any actor. Documented inline in each workflow. | contoso | #92 |
| 2026-05-04 | Promote the three meta-agents (`@idea-intake`, `@artifact-resolver`, `@owner-approval`) to the default repo entry point; reserve `@squad` for content-creation interviews. Delete `/start-item` and `/new-checkin`; their best practices are folded into the agents per the redundancy table in ADR-0014. `/build-item` remains the shared validation engine. | The two-track split named in ADR-0013 became drift-prone redundancy once the agents had been used in anger. Lifecycle work is persona behavior (scoped tools, handoffs, stop-on-confirmation) per the four-primitive model. Supersedes-in-part ADR-0013 §1 (the two-track split); preserves ADR-0013 §2 (`/build-item` as the shared validation engine). | contoso | ADR-0014 / #102 |

---

## Notes

- Decisions are immutable once logged — do not edit past rows.
- To supersede a decision, add a new row that references the original.
- All production-impacting decisions must reference an `owner-approved` PR.
