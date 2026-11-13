# RAD-154: Search the case list by run

## Story

- **Link:** [RAD-154](https://ferlab-crsj.atlassian.net/browse/RAD-154)
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** one branch per task, named after its Jira sub-task (`feat/rad-xxxx`).
- **Acceptance criteria (AC),** as the story numbers them; the test strategy follows this numbering:
  1. **AC1:** the search bar placeholder references run instead of sequencing.
  2. **AC2:** typing a run value in the search bar returns the matching cases.
  3. **AC3:** the auto-suggest dropdown shows run suggestions with the run icon and label, no more « sequencing ».
- **PO decisions (Jean-Philippe Thibert, 2026-11-13, RAD-154 comment):**
  - the search matches the runs of **every member** of the case: the labs know their run ID and often search by it;
  - the Run column keeps showing the proband's runs only (RAD-108), even when a case is found through a relative's run;
  - `run_name` only, not `run_alias`;
  - French label: « Lot ».

## Chosen approach

**Summary:** a new `run_name` filter on the case search, built from the runs of every sequencing linked to the case, and the case autocomplete suggests run names instead of sequencing IDs. The frontend swaps the sequencing icon, label and placeholder for run ones. The MCP routes the new suggestion type to the new filter.

### portal (backend)

- **Run:** `sequencing_experiment.run_name`. There is no run table: a run is the set of sequencings that share a `run_name`. The column is optional free text (at most 100 characters, no format), not unique across labs, and stored as `''` when a batch leaves it out.
- **Case ↔ run:** `case_has_sequencing_experiment` (`case_id`, `sequencing_experiment_id`), then `sequencing_experiment.run_name`. No join to `sample`: every sequencing of the case counts, whatever the member (proband, parents, siblings, fetus) or the sample (normal or tumoral).
- **New filter field** `run_name` (alias), in `CasesFields`:
  - array field (`IsArray`), `CanBeFiltered` only: not selectable, not sortable;
  - its own table, `case_member_run`: per case, the array of the distinct non-empty `run_name` of all its sequencings, built with the existing `caseWithArray` helper (the one behind the Sample filter and the Run column). The filter goes through `array_contains`, as the Sample filter does;
  - `prepareQuery` joins it only when the query uses the field. The field is filter-only, so that means only when it is filtered, and the join is in place before the count.
- **Run column unchanged:** `run_names` (`case_run`) stays select-only, proband only, joined after the count. The two are separate tables with separate aliases, so they never collide when a user filters by run with the Run column shown.
- **Autocomplete** (`CasesRepository.SearchById`, `GET /{tenant}/cases/autocomplete`):
  - new sub-query: `"run_name" as type, run_name as value` from `sequencing_experiment` joined to `case_has_sequencing_experiment` (a run with no case is not suggested), `LOWER(run_name) LIKE lower(prefix) || '%'`, empty values left out. The `UNION` already removes duplicates, so a run shared by many cases is suggested once;
  - the `sequencing_experiment_id` sub-query is removed;
  - `CaseSequencingExperimentIdField` stays filterable: the MCP and saved queries use it.

  ```sql
  SELECT 'run_name' AS type, s.run_name AS value
  FROM <tenant>_tenant.sequencing_experiment s
  JOIN <tenant>_tenant.case_has_sequencing_experiment chseq ON chseq.sequencing_experiment_id = s.id
  WHERE LOWER(s.run_name) LIKE ? AND s.run_name <> ''
  ```

- **Search** (`POST /{tenant}/cases/search`), criterion sent by the frontend when a run suggestion is picked:

  ```json
  { "search_criteria": [ { "field": "run_name", "value": ["A00516_0169"] } ] }
  ```

  ```sql
  LEFT JOIN (
    SELECT c.id AS case_id,
           array_filter(x -> x IS NOT NULL AND x <> '', array_agg(runs.run_name ...)) AS run_names
    FROM <tenant>_tenant.cases c
    LEFT JOIN (SELECT DISTINCT chseq.case_id, s.run_name
               FROM case_has_sequencing_experiment chseq
               JOIN sequencing_experiment s ON s.id = chseq.sequencing_experiment_id) runs
      ON runs.case_id = c.id
    GROUP BY c.id
  ) case_member_run ON case_member_run.case_id = c.id
  WHERE array_contains(case_member_run.run_names, ?)
  ```

- **Access:** unchanged. The tables are read through the tenant views, as the Sample filter and the Run column already do.
- **Contract:** the response shapes do not change. A new value of the autocomplete `type` (`run_name`) replaces `sequencing_experiment_id`, and a new filter field is accepted. Swagger description updated, TS and Python clients regenerated.

### portal (frontend)

- **Placeholder** (`case_exploration.filters_group.search_placeholder`): EN « Case, run, patient, or MRN », FR « Cas, lot, patient ou MRN ».
- **Suggestions:** in `getTypeIcon` (`data-table-filter-search.tsx`), `sequencing_experiment_id` is replaced by `run_name` with the run icon. The label comes from `common.table.filters.search.run_name`, which the Files page autocomplete already uses: EN « Run Name » → « Run », FR « Nom du lot » → « Lot ».
- **Selection:** no change. A picked suggestion becomes the criterion `{ field: <type>, value: [<value>] }` (`data-table-filters.tsx`), so `run_name` reaches the backend filter as is.

### mcp

- `search_cases` resolves a free-text query through the case autocomplete and sends every match type it does not know to the `mrn` filter. A `run_name` match would therefore look for an MRN and find nothing. The same already happens to `proband_submitter_sample_ids` since RAD-101.
- Change: route `run_name` and `proband_submitter_sample_ids` to their own filters, add `run_name` and `proband_submitter_sample_ids` to `CASE_SEARCH_FILTER_FIELDS`, and update the docstrings: the free-text query no longer matches internal sequencing IDs, and it now matches run names and sample IDs. The explicit `sequencing_experiment_id` filter still works.

### Alternatives considered

- **Proband runs only** (reuse `run_names` of the Run column as the filter): not kept, the PO wants every member (a run with only the father's sample must find the trio).
- **Row join with `DISTINCT`** (as the `case_group` filter): joins `(case_id, run_name)` rows and makes the list and count `DISTINCT`. Not kept: it changes the shape of the whole query for one filter, while the array join is already the pattern of the Sample filter.
- **Keep `sequencing_experiment_id` in the autocomplete:** not kept, the story replaces it; nobody outside Radiant knows the internal sequencing ID.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | case types (`run_name` filter field and its table), case search joins, case autocomplete, swagger, generated TS and Python clients | new / modified |
| portal (frontend) | case search placeholder, suggestion icon map, EN/FR labels | modified |
| portal (cypress) | API specs and fixture of the case autocomplete and search | modified |
| mcp | `search_cases` autocomplete routing, filter field list, docstrings | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Run filter and autocomplete | portal (backend) | `run_name` filter field and `case_member_run` join, run sub-query in `SearchById`, sequencing sub-query removed, tests, swagger and clients, Cypress API specs (`Autocomplete` and `Search`: `SequencingExperiment` → `Run`), Postman | — | yes: the current frontend shows run suggestions with the default icon and the « Run Name » label |
| 2 | Run in the case search bar | portal (frontend) | Placeholder, icon, EN/FR labels, Cypress mock fixture `AutocompleteCase.json` | Task 1 | yes, once task 1 is deployed |
| 3 | Run and sample in `search_cases` | mcp | Routing of `run_name` and `proband_submitter_sample_ids`, field list, docstrings, tests | Task 1 | yes, once task 1 is deployed |

No UX task: the change reuses the existing search bar; only the run icon is needed (open question). No Labels task: the labels come from the PO's answers and ship with task 2.

## Merge and rollout order

1. portal backend: task 1.
2. portal frontend: task 2, after step 1 in the same environment. Before it, the dropdown shows no sequencing suggestion and no run suggestion of the right icon.
3. mcp: task 3, after step 1. Before it, a free-text MCP query on a run returns nothing.

No migration, no backfill, no feature flag, no ETL change: `run_name` already exists.

## Test strategy

### portal (backend)

- **AC2:** StarRocks integration tests (testcontainers) on the clinical fixture, where case 1 is a trio whose proband, mother and father are on runs 1617, 1618 and 1619:
  - the proband's run finds the case; the father's run also finds it (every member);
  - a somatic case is found by its normal sample's run;
  - a prenatal case is found by the fetus's run;
  - an unknown run finds no case, not an error;
  - the count matches the list;
  - the run filter together with the Run column selected returns the proband's runs in `run_names` (no alias collision);
  - an empty `run_name` is never matched.
- **AC3:** `SearchById` integration tests: a run prefix returns `run_name` suggestions, case-insensitive, each run once, never an empty value; a sequencing ID no longer returns `sequencing_experiment_id`.
- Handler tests on `/cases/autocomplete` and `/cases/search` with the `run_name` field.

### portal (frontend)

- **AC1, AC3:** no component or render test (team norm). Checked by the Cypress mock of the suggestion list and on the ferlease.

### portal (cypress)

- **AC2, AC3:** the `Autocomplete/Run` and `Search/Run` API specs replace the `SequencingExperiment` ones, on a run of the QA data.

### mcp

- Unit tests of the routing: a `run_name` match goes to the `run_name` filter, a sample match to the sample filter, an unknown type still to `mrn`.

### QA (manual)

- **AC1 to AC3:** on the ferlease, type the start of a run of a trio: the dropdown shows « Run » / « Lot » with the run icon; picking it lists the case. Then a run that holds only a parent's sample: the case is listed, and its Run column shows the proband's run. Screenshots in the PR.
- **Response time:** the time of `POST /cases/search` with a `run_name` filter on the largest QA tenant, recorded in the task 1 PR (the run join is an aggregate over every case of the tenant, read through the federation).

## Risks and coverage

| Risk | How it is covered |
|---|---|
| A case found through a relative's run looks like a wrong result, since its Run column shows the proband's run | PO accepted it (2026-11-13); QA manual check |
| Cost of the run aggregate over every case, read from Postgres through the JDBC federation, before the count | Joined only when the run filter is used; measurement in the task 1 PR, a gap goes to the deviation log |
| Run names are not unique across labs: a run name reused by two labs of a tenant finds both labs' cases | Accepted: the user sees the cases and their lab in the list. Tenant isolation is unchanged |
| The MCP sends the new `run_name` match to the `mrn` filter and finds nothing | Task 3 |
| `common.table.filters.search.run_name` is shared with the Files page autocomplete: its label changes there too | Open question |

## Frozen scope

### all

- `run_alias` and `run_date`: not searchable.
- Sample in the placeholder and its icon: RAD-101 / [RAD-162](https://ferlab-crsj.atlassian.net/browse/RAD-162).
- A run facet in the filter bar.

### portal (backend)

- No change to the Run column (`run_names`): proband only, select only.
- `sequencing_experiment_id` stays a filter; only its suggestion goes.

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
