# SJRA-xxxx: Title

> Written by the developer before the first line of code. Approved by the assigned reviewer in fifteen minutes at most. May be generated with AI: the developer is accountable for it.
>
> Required for **Standard** and **Complex** stories. Optional for **Small** ones.

## Story

- **Link:** **[ticket]**
- **Assigned reviewer:** **[Name]**
- **Status:** Draft | In review | Approved | In progress | Done
- **Branch (all repos):** `feat/sjra-xxxx-<slug>`

## Chosen approach

Five to ten lines. How we are going to do it, and why this approach rather than another. If an alternative was ruled out, name it in one line with the reason.

- Approach: …
- Rejected alternative: … because …

## Modules impacted

The areas of the code that will change. The reviewer uses this to know where to focus and to spot out-of-plan changes in the PRs.

| Module | Area | Kind of change |
|---|---|---|
| etl | … | new / modified / removed |
| portal (backend) | … | … |
| portal (frontend) | … | … |
| mcp | … | … |
| infra | … | … |

## Tasks

A story has a single plan. The plan splits the work into tasks, each carrying a single intent and staying reviewable. A task usually yields one PR; each PR links back to its task and to this plan, which gives the reviewer the full context even when they only see one component at a time.

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | … | e.g. etl | … | — | yes / no |
| 2 | … | e.g. portal (backend) | … | Task 1 | yes / no |
| 3 | … | e.g. portal (frontend) | … | Task 2 | yes / no |

A task that is not shippable alone must say what protects it in production (feature flag, deployment order). Tasks are created in the tracker under the story once the plan is approved.

Some needs become tasks of their own, so they don't get absorbed along the way:

- **Specific UX**: if the story requires interface design work (new screen, new interaction, mockup to validate), create a UX task.
- **Specific labels**: if the story introduces user-visible text that needs validation (clinical terms, error messages, translations), create a Labels task.

## Contract changes

Data, schema or API changes. Write "none" if that is the case. Otherwise list every change to a boundary (StarRocks table/column, enum value, API endpoint/field) with its writer, its readers, and the matching update to `docs/contracts/`. Cover migration, compatibility with existing data, API versioning, and impact on consuming systems.

| Contract | Change | Writer | Readers | Migration / compatibility |
|---|---|---|---|---|
| … | … | … | … | … |

## Merge and rollout order

1. etl: …
2. portal backend: …
3. portal frontend / mcp: …

Migrations, backfills, feature flags, and what breaks if the order is not respected.

## Test strategy

Three to five lines. We don't list the tests; we say how we will prove the story is delivered. The details come with the code.

- **How each acceptance criterion is proven:** at which level (unit, integration, end-to-end) and on which data.
- **What is not tested automatically, and why:** …

## Risks and coverage

Take each business risk checked in the story and say how the plan covers it.

| Risk (from the story) | How it is covered |
|---|---|
| … | … |

## Frozen scope

What this plan does not cover. Restates and sharpens the story's "out of scope" section. Anything that is neither in the plan nor listed here is a deviation.

- …

## Open questions

- …

## Approval

| | |
|---|---|
| Reviewer | **[Name]** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

Filled in during implementation, every time an out-of-plan need shows up. Two possible outcomes, no others.

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
