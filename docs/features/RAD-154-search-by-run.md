# RAD-154: Search the case list by run

## Story

- **Link:** [RAD-154](https://ferlab-crsj.atlassian.net/browse/RAD-154)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch:** one branch per task, `feat/rad-xxxx-<slug>` after its Jira sub-task. The backend and frontend tasks are both in the portal repo, so they cannot share one branch name. If the frontend ferlease preview still drops the text after the ticket number (fixed by [RAD-274](https://ferlab-crsj.atlassian.net/browse/RAD-274)), the frontend branch goes without a slug, as in RAD-243.
- **Acceptance criteria (AC),** as the story numbers them:
  1. **AC1:** the search bar placeholder references run instead of sequencing.
  2. **AC2:** typing a run value in the search bar returns the matching cases.
  3. **AC3:** the auto-suggest dropdown shows run suggestions with the run icon and label, no more « sequencing ».
- **PO decisions (Jean-Philippe Thibert, 2026-11-13, RAD-154 comment):**
  - the search matches the runs of **every member** of the case: the labs know their run ID and often search by it;
  - the Run column keeps showing the proband's runs only (RAD-108), even when a case is found through a relative's run;
  - `run_name` only, not `run_alias`;
  - French label: « Lot ».
- **Run ID typed by the labs:** the exact `run_name` value (confirmed by the team, 2026-11-13), not the `run_alias`.

## Chosen approach

**Summary:** a new `run_name` filter on the case search, matching the runs of every sequencing of the case, and the case autocomplete suggests run names instead of sequencing IDs. The frontend swaps the sequencing icon, label and placeholder for run ones. The MCP's `search_cases` routes the new suggestion type to the new filter. The change is rolled out in two phases, add then remove, so the MCP always knows every suggestion type the API returns (see merge and rollout order).

### portal (backend)

- **Run:** there is no run table. A run is the set of sequencings that share a `sequencing_experiment.run_name`: optional free text, not unique across labs, trimmed by the batch.
- **Filter `run_name`:** new filter-only field of the case search. It matches every sequencing linked to the case, whatever the member (proband, parents, siblings, fetus) or the sample (normal or tumoral).
- **Semi-join, not a join:** the filter keeps the cases that have at least one sequencing on the run (`case IN (…)`), instead of joining the run rows to the cases. So:
  - no duplicate cases, no `DISTINCT`, no per-case aggregate computed on every case;
  - `not-in` excludes a case as soon as one of its runs matches.
  - This is a new, reusable kind of filter field in the shared filter code, since the sub-query reads the tenant's tables. The Sample filter can move onto it later (frozen scope).
- **Operators:** the field accepts `in`, `not-in` and `contains` with one value. Any other is refused with a 400 instead of failing with a 500. The frontend and the MCP only send `in`.
- **Where the field exists:** case search only. The variant interpreted cases reuse the case fields; `run_name` is left out there.
- **Run column unchanged:** proband only, select only (RAD-108).
- **Autocomplete:** run names replace sequencing IDs among the suggestions: prefix match, case-insensitive, each run once, empty values left out, only runs linked to a case. In two steps: the run suggestions are added first, next to the sequencing ID ones; the sequencing ID suggestions are removed once the MCP knows the run. `sequencing_experiment_id` stays a filter (the MCP uses it).
- **Order of the suggestions:** today the suggestions are sorted by value and cut at 10, so a numeric run name can be pushed out by case and patient IDs that share its prefix. New order: exact matches first, then every type that matches gets a place in the list. A run typed in full always comes first. This also changes the order for the other types.
- **Access:** unchanged, the tables are read through the tenant views.
- **Contract:** response shapes unchanged; a new suggestion type and a new filter field. The OpenAPI spec lists neither, so no client regeneration.

### portal (frontend)

- **Placeholder:** EN « Case, run, patient, or MRN », FR « Cas, lot, patient ou MRN ».
- **Suggestions:** the sequencing icon is replaced by a run icon. The label is the one the Files page autocomplete already uses for runs, renamed EN « Run Name » → « Run », FR « Nom du lot » → « Lot ».
- **Selection:** no change, a picked run becomes a `run_name` criterion.
- **Saved filters:** a saved sequencing ID filter keeps working; only picking a new sequencing ID from the dropdown goes away.

### mcp

- **Today:** `search_cases` sends any unknown suggestion type to the `mrn` filter, so a run suggestion would find nothing.
- **Routing:** `run_name` is routed to its filter, before the API returns run suggestions. The `sequencing_experiment_id` route is removed only after the API stops suggesting sequencing IDs.
- **Field list:** `run_name` added to the case filter fields once the backend is merged: the MCP CI requires this list to equal the filterable fields of portal `main`. `sequencing_experiment_id` stays in the list, since it stays a filter.
- **Descriptions:** the tool and parameter descriptions and `docs/tools.md` mention the run instead of the sequencing ID.

### Alternatives considered

- **Array of every member's runs per case** (as the Sample filter): correct, but computed on every case of the tenant before the count, to test one value. Dropped after review.
- **Join on the run rows with `DISTINCT`** (as the case group filter): cheap, but wrong for `not-in`: a case passes through any of its other runs.
- **Proband runs only** (reuse the Run column): the PO wants every member.
- **Keep sequencing IDs in the autocomplete:** the story replaces them; labs search by their run ID.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | shared filter code (semi-join field), case fields, case autocomplete, Postman | new / modified |
| portal (frontend) | case search placeholder, suggestion icon, EN/FR labels | modified |
| portal (cypress) | case autocomplete and search API specs | modified |
| mcp | `search_cases` routing, case filter field list, descriptions | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Route run suggestions in `search_cases` | mcp | `run_name` routed to its filter, nothing else | — | yes: unused until task 2 is deployed |
| 2 | Run filter and run suggestions | portal (backend) | Semi-join field, `run_name` filter, run suggestions next to the sequencing ID ones, order of the suggestions, tests, Cypress API specs, Postman | Task 1 deployed | yes |
| 3 | Run in the case filter fields | mcp | `run_name` in the field list, descriptions, `docs/tools.md`, tests | Task 2 merged | yes; its CI needs task 2 on portal `main` |
| 4 | Run in the case search bar | portal (frontend) | Placeholder, icon, EN/FR labels, Cypress mock | Task 2 deployed | yes |
| 5 | Remove the sequencing ID suggestions | portal (backend) | Sequencing ID sub-query removed from the autocomplete (the filter stays), tests, Cypress API spec | Tasks 3 and 4 deployed | yes |
| 6 | Remove the sequencing ID route | mcp | `sequencing_experiment_id` route removed (the field stays in the list), tests | Task 5 deployed | yes; optional, the route is dead code after task 5 |

No UX task: the change reuses the existing search bar; only the run icon is needed (open question). No Labels task: the labels come from the PO's answers and ship with task 2.

## Merge and rollout order

Two phases, add then remove: at every step, each suggestion type the API returns has a route in the MCP.

1. **mcp, task 1:** run routing, deployed before the backend.
2. **portal backend, task 2:** run filter and run suggestions; sequencing ID suggestions kept. Until task 4, the dropdown shows runs with the default icon and the « Run Name » label, next to sequencing IDs.
3. **mcp, task 3:** merged right after task 2: the MCP CI compares its field list with portal `main`, so every MCP PR fails between the two merges.
4. **portal frontend, task 4:** after task 2 is deployed.
5. **portal backend, task 5:** sequencing ID suggestions removed, after tasks 3 and 4 are deployed.
6. **mcp, task 6:** sequencing ID route removed, after task 5 is deployed. Removing it before task 5 would send sequencing ID suggestions to the `mrn` filter.

No migration, no backfill, no feature flag, no ETL change: `run_name` already exists.

## Test strategy

### portal (backend)

- **AC2:** integration tests on the clinical fixture: a case is found by the run of any member (proband, parent, fetus, normal sample); `not-in`, several runs, refused operators, count matching the list.
- **AC3:** integration tests of the autocomplete: run suggestions and a run not pushed out by IDs sharing its prefix (task 2), sequencing IDs gone (task 5).

### portal (frontend)

- **AC1, AC3:** no render test (team norm); Cypress mock of the suggestion list and the ferlease.

### portal (cypress)

- **AC2, AC3:** API specs of the run autocomplete and the run search on QA data. The sequencing ID search spec stays, since the filter stays.

### mcp

- Unit tests of `search_cases`: a run match uses the run filter (task 1); a sequencing ID match no longer has a route (task 6).

### QA (manual)

- **AC1 to AC3:** on the ferlease, type a run of a trio, then a run holding only a parent's sample: the case is listed, its Run column shows the proband's run. Screenshots in the PR.
- **Response time:** run search and run autocomplete measured on the largest QA tenant, in the task 2 PR.

## Risks and coverage

| Risk | How it is covered |
|---|---|
| A case found through a relative's run looks like a wrong result, since its Run column shows the proband's run | PO accepted it (2026-11-13); QA manual check |
| The run filter or the run suggestions are slow (federated tables, no index on `run_name`) | Measured in the task 2 PR; a gap goes to the deviation log |
| The semi-join field changes the filter code shared by every search | Existing fields keep their path; tests |
| A numeric run name is pushed out of the 10 suggestions by IDs | New order of the suggestions; test |
| A run name reused by two labs of a tenant finds both labs' cases | Accepted: the lab shows in the list; tenant isolation unchanged |
| The MCP CI breaks once the backend's run filter is merged | Task 3 merged right after task 2 |
| An MCP free-text query on a run or a sequencing ID finds nothing during the rollout | Add then remove: run route deployed before the run suggestions, sequencing ID route removed after the sequencing ID suggestions |
| The run label is shared with the Files page | Open question |

## Frozen scope

### all

- `run_alias` and `run_date`: not searchable.
- Sample in the placeholder and its icon: RAD-101 / [RAD-162](https://ferlab-crsj.atlassian.net/browse/RAD-162).
- A run facet in the filter bar.

### portal (backend)

- No change to the Run column.
- `sequencing_experiment_id` stays a filter; only its suggestion goes.
- Follow-up tickets, to create:
  - move the Sample filter onto the semi-join field;
  - `not-in` on the sequencing ID and case group filters, probably wrong for a case with several sequencings or groups;
  - operators that produce invalid SQL (500) on the existing filter fields;
  - the Sample filter inherited by the variant interpreted cases, which probably breaks there.

### portal (frontend)

- No sort on the Run column, no change to the case entity page.

## Open questions

### story / product

- **Run icon:** which icon? **Proposal:** a lucide icon (e.g. `Layers`) until design gives one.
- **Shared label:** « Run » / « Lot » also replaces « Run Name » / « Nom du lot » in the Files page autocomplete. **Proposal:** keep one label for both pages.

### portal (frontend)

- **Placeholder and RAD-162:** both change the same text. **Proposal:** this ticket writes « Case, run, patient, or MRN »; RAD-162 adds sample.

## Approval

| | |
|---|---|
| Reviewer | Jeremy Costanza |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

Filled in during implementation, every time an out-of-plan need shows up. Two possible outcomes, no others.

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
