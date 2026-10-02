# Story template

> Filled in together during grooming. A story does not enter the sprint until the Definition of Ready is checked. Copy the sections below into the Jira story description.

## Title

A verb and an object. Example: "Show variants filtered by gene in the clinical report".

## Intent

A single sentence that says for whom and why.

> As a **[role]**, I want **[capability]** so that **[observable benefit]**.

## Context

Three to five lines at most. What the developer and the reviewer need to know to understand the request without searching elsewhere: where the need comes from, known constraints, link to the documentation or the parent ticket.

## Acceptance criteria

Each criterion can be verified by a test or an observation. No vague adjectives ("fast", "user-friendly").

- [ ] Given **[initial state]**, when **[action]**, then **[observable result]**.
- [ ] Given …, when …, then ….
- [ ] Given …, when …, then ….

## Out of scope

Required, even if it seems obvious. What we choose not to do in this story, and the edge cases we deliberately exclude.

- Does not handle: …
- Excluded edge case: …
- Deferred to another ticket: … (link)

## Business risks

Check what applies and add one line of detail. The implementation plan must say how each checked risk is covered.

- [ ] Patient or identifying data (confidentiality, access, logging)
- [ ] Genomic formats or data (VCF, annotations, coordinates, reference versions)
- [ ] Clinical rules or interpretation (thresholds, classifications, recommendations)
- [ ] Traceability and audit (who did what, when, on which version)
- [ ] Interoperability (external APIs, exchange formats, third-party systems)
- [ ] No particular business risk

## Classification

We no longer estimate the effort of writing the code. We classify the complexity of analysis and verification.

| Class | Criteria | What it triggers |
|---|---|---|
| **Small** | Obvious scope, no business risk checked, a single component touched | No formal plan, light review |
| **Standard** | Clear scope, one or two risks checked | Implementation plan approved before coding |
| **Complex** | Several components touched (ETL, API, UI…), multiple business risks, uncertainty about the approach | Pair analysis, implementation plan split into several PRs |

Chosen class: **[Small / Standard / Complex]**

## Assigned reviewer

**[Name]**. Assigned now, not when the PR is opened. They approve the implementation plan and review the PR.

## Definition of Ready

- [ ] The intent fits in one sentence
- [ ] Each acceptance criterion is verifiable
- [ ] The "out of scope" section is written
- [ ] Business risks are checked and detailed
- [ ] The story is classified
- [ ] The scope fits in a single implementation plan
- [ ] A reviewer is assigned
