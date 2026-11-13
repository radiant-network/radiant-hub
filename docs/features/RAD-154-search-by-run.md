# RAD-154: Search the case list by run

## Story

- **Link:** [RAD-154](https://ferlab-crsj.atlassian.net/browse/RAD-154)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch:** one branch per task, `feat/rad-xxxx-<slug>` after its Jira sub-task. The backend and frontend tasks are both in the portal repo, so they cannot share one branch name. If the frontend ferlease preview still drops the text after the ticket number (fixed by [RAD-274](https://ferlab-crsj.atlassian.net/browse/RAD-274)), the frontend branch goes without a slug, as in RAD-243.
- **Acceptance criteria (AC),** as the story numbers them; the test strategy follows this numbering:
  1. **AC1:** the search bar placeholder references run instead of sequencing.
  2. **AC2:** typing a run value in the search bar returns the matching cases.
  3. **AC3:** the auto-suggest dropdown shows run suggestions with the run icon and label, no more « sequencing ».
- **PO decisions (Jean-Philippe Thibert, 2026-11-13, RAD-154 comment):**
  - the search matches the runs of **every member** of the case: the labs know their run ID and often search by it;
  - the Run column keeps showing the proband's runs only (RAD-108), even when a case is found through a relative's run;
  - `run_name` only, not `run_alias`;
  - French label: « Lot ».
- **Run ID typed by the labs:** the exact `run_name` value (confirmed by the team, 2026-11-13). In the test fixture it is the number (`1617`); the Illumina-style value (`A00516_0169`) is the `run_alias`, which is not searched.

## Chosen approach

**Summary:** a new `run_name` filter on the case search, applied as a semi-join on the runs of every sequencing linked to the case (`c.id IN (…)`), and the case autocomplete suggests run names instead of sequencing IDs. The semi-join is a new, reusable kind of filter field. The frontend swaps the sequencing icon, label and placeholder for run ones. The MCP's `search_cases` routes the new suggestion type to the new filter and describes it.

### portal (backend)

- **Run:** `sequencing_experiment.run_name`. There is no run table: a run is the set of sequencings that share a `run_name`. The column is optional free text (at most 100 characters, no format), not unique across labs, and stored as `''` when a batch leaves it out. The batch reads it as `TrimmedString`, so stored values have no leading or trailing space.
- **Case ↔ run:** `case_has_sequencing_experiment` (`case_id`, `sequencing_experiment_id`), then `sequencing_experiment.run_name`. No join to `sample`: every sequencing of the case counts, whatever the member (proband, parents, siblings, fetus) or the sample (normal or tumoral).
- **Semi-join field (new, in the filter code):**
  - Today a criterion becomes `alias.column <op> ?` (`ComparisonNode.ToSQL`, `types/filter.go`), on a table that `prepareQuery` joins. That cannot express a sub-query: its table names depend on the tenant (`TenantQualifiedName(ctx)`), which `ToSQL` does not receive, and `Field.CustomOp` is unused.
  - A table is marked as a semi-join source: its rows hold the case key (`case_id`) and the filtered column. The repository, which has the request context, gives the filter the SQL of these rows with the tenant's table names (built by a `Joiner` method). The exact signature is decided in the task 1 PR.
  - The criterion becomes a condition on `c.id`, never a join, so the case list and count need no `DISTINCT` and no aggregate:

    | Operator | Generated condition |
    |---|---|
    | `in` | `c.id IN (SELECT case_id FROM <rows> WHERE run_name IN (?))` (`= ?` for one value) |
    | `not-in` | `c.id NOT IN (SELECT case_id FROM <rows> WHERE run_name IN (?))` |
    | other (`contains`…) | `c.id IN (SELECT case_id FROM <rows> WHERE <the operator on run_name>)` |

    `not-in` excludes a case as soon as one of its runs matches, which a join on rows cannot do (a case with runs A and B would pass `not-in A` through its row B). `case_id` is `NOT NULL` in the junction, so `NOT IN` is safe.
  - Reusable: the Sample filter can move onto it later and drop its always-on aggregate join (follow-up ticket, see frozen scope).
- **New filter field** `run_name` (alias), in `CasesFields`: `CanBeFiltered` only (not selectable, not sortable), on the semi-join table `case_member_run`, whose rows are:

  ```sql
  SELECT chseq.case_id, s.run_name
  FROM <tenant>_tenant.case_has_sequencing_experiment chseq
  JOIN <tenant>_tenant.sequencing_experiment s ON s.id = chseq.sequencing_experiment_id
  ```

  `prepareQuery` joins nothing for it.
- **Search** (`POST /{tenant}/cases/search`), criterion sent by the frontend when a run suggestion is picked, and the condition it gives:

  ```json
  { "search_criteria": [ { "field": "run_name", "value": ["1617"] } ] }
  ```

  ```sql
  WHERE c.id IN (SELECT chseq.case_id
                 FROM <tenant>_tenant.case_has_sequencing_experiment chseq
                 JOIN <tenant>_tenant.sequencing_experiment s ON s.id = chseq.sequencing_experiment_id
                 WHERE s.run_name = ?)
  ```

  The `run_name` condition is meant to reach Postgres through the federation, so only the run's sequencings come back. Checked with `EXPLAIN` in the task 1 PR.
- **Run column unchanged:** `run_names` (`case_run`) stays select-only, proband only, joined after the count. A run filter with the Run column shown reads two different sources, so they cannot collide.
- **Autocomplete** (`CasesRepository.SearchById`, `GET /{tenant}/cases/autocomplete`):
  - new sub-query: `"run_name" as type, run_name as value` from `sequencing_experiment` joined to `case_has_sequencing_experiment` (a run with no case is not suggested), `LOWER(run_name) LIKE lower(prefix) || '%'`, empty values left out. The `UNION` already removes duplicates, so a run shared by many cases is suggested once;
  - the `sequencing_experiment_id` sub-query is removed;
  - `CaseSequencingExperimentIdField` stays filterable: the MCP lists it among its filters.

  ```sql
  SELECT 'run_name' AS type, s.run_name AS value
  FROM <tenant>_tenant.sequencing_experiment s
  JOIN <tenant>_tenant.case_has_sequencing_experiment chseq ON chseq.sequencing_experiment_id = s.id
  WHERE LOWER(s.run_name) LIKE ? AND s.run_name <> ''
  ```

- **Access:** unchanged. The tables are read through the tenant views, as the Sample filter and the Run column already do.
- **Contract:** the response shapes do not change. A new value of the autocomplete `type` (`run_name`) replaces `sequencing_experiment_id`, and a new filter field is accepted. The OpenAPI spec lists neither the autocomplete types nor the filter fields, so it does not change: no client regeneration, and no bump of the MCP's pinned Python client.

### portal (frontend)

- **Placeholder** (`case_exploration.filters_group.search_placeholder`): EN « Case, run, patient, or MRN », FR « Cas, lot, patient ou MRN ».
- **Suggestions:** in `getTypeIcon` (`data-table-filter-search.tsx`), `sequencing_experiment_id` is replaced by `run_name` with the run icon. The label comes from `common.table.filters.search.run_name`, which the Files page autocomplete already uses: EN « Run Name » → « Run », FR « Nom du lot » → « Lot ».
- **Selection:** no change. A picked suggestion becomes the criterion `{ field: <type>, value: [<value>] }` (`data-table-filters.tsx`), its value trimmed (`data-table-filter-search.tsx`). Stored run names are already trimmed (see backend), so the trimmed value matches.
- **Saved filters:** the case list keeps its filters in `localStorage` (`usePersistedFilters`), not in the URL. A saved `sequencing_experiment_id` filter keeps working: its value shows in the search box and Clear removes it. Only picking a new sequencing ID from the dropdown goes away.

### mcp

- **Today:** `search_cases` (`radiant_mcp/tools/cases.py`) resolves a free-text query through the case autocomplete, then runs one search per match type: `case_id`, `patient_id` and `sequencing_experiment_id` (`_AUTOCOMPLETE_INT_FIELDS`), `proband_submitter_sample_ids` (`_AUTOCOMPLETE_TEXT_FIELDS`). Any other type is taken for a submitter patient ID and sent to the `mrn` filter, so a `run_name` match would look for an MRN and find nothing.
- **Routing:** `run_name` added to `_AUTOCOMPLETE_TEXT_FIELDS`. `sequencing_experiment_id` stays in `_AUTOCOMPLETE_INT_FIELDS`: if the MCP is deployed before the portal, sequencing ID matches keep their filter instead of falling to `mrn`; once the portal stops returning the type, the entry is unused.
- **Field list:** `run_name` added to `CASE_FILTER_FIELDS` (`radiant_mcp/api_fields.py`). `sequencing_experiment_id` stays: it is still a filter.
- **Descriptions:** FastMCP publishes the text before `Args:` as the tool description and each `Args:` entry as the description of its parameter. Both are updated: the `query` entry matches run names and no longer internal sequencing IDs (`seq_id`), the `filters` entry lists `run_name`, and `docs/tools.md` lists the run among the identifiers.
- **Coupling:** `tests/unit/test_api_fields.py` compares `CASE_FILTER_FIELDS` with `CasesFields` of portal `main`, which the MCP's CI checks out. The MCP CI fails from the merge of task 1 until task 3 is merged, and task 3's CI fails before task 1 is merged (see merge order).

### Alternatives considered

- **Array of every member's runs per case** (the `caseWithArray` pattern of the Sample filter and the Run column): correct, but it aggregates every case of the tenant, read through the federation, before the count, to test one value. Not kept after review.
- **Join on `(case_id, run_name)` rows with `DISTINCT`** (as the `case_group` filter): cheap, but wrong for `not-in`, since a case passes through any of its other runs.
- **Proband runs only** (reuse `run_names` of the Run column as the filter): not kept, the PO wants every member (a run with only the father's sample must find the trio).
- **Keep `sequencing_experiment_id` in the autocomplete:** not kept, the story replaces it: the labs search by their run ID, not by Radiant's internal sequencing ID.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | filter code (semi-join field), case types (`run_name` field and its semi-join table), `Joiner` (run rows), case autocomplete, Postman | new / modified |
| portal (frontend) | case search placeholder, suggestion icon map, EN/FR labels | modified |
| portal (cypress) | API specs and fixture of the case autocomplete and search | modified |
| mcp | `search_cases` autocomplete routing (`tools/cases.py`), case filter field list (`api_fields.py`), docstring and its `Args:`, `docs/tools.md` | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Run filter and autocomplete | portal (backend) | Semi-join field in the filter code, `run_name` field and its rows, run sub-query in `SearchById`, sequencing sub-query removed, tests, Cypress API specs (`Autocomplete/SequencingExperiment` → `Autocomplete/Run`, new `Search/Run`), Postman | — | yes: the current frontend shows run suggestions with the default icon and the « Run Name » label |
| 2 | Run in the case search bar | portal (frontend) | Placeholder, icon, EN/FR labels, Cypress mock fixture `AutocompleteCase.json` | Task 1 | yes, once task 1 is deployed |
| 3 | Run in `search_cases` | mcp | `run_name` routing, `run_name` in `CASE_FILTER_FIELDS`, docstring and `Args:`, `docs/tools.md`, unit tests | Task 1 merged | yes, once task 1 is deployed; its CI needs task 1 on portal `main` |

No UX task: the change reuses the existing search bar; only the run icon is needed (open question). No Labels task: the labels come from the PO's answers and ship with task 2.

## Merge and rollout order

1. portal backend: task 1.
2. portal frontend: task 2, after step 1 in the same environment. Between the two, the dropdown already shows run suggestions, with the default icon and the « Run Name » / « Nom du lot » label, and the placeholder still says sequencing.
3. mcp: task 3, merged right after task 1 is merged on portal `main`: its CI compares the MCP field list with portal `main`, so it fails before task 1 is merged, and every MCP PR fails from the merge of task 1 until task 3 is in. Until task 3 is deployed, a free-text MCP query on a run returns nothing and a query on a sequencing ID no longer matches.

No migration, no backfill, no feature flag, no ETL change: `run_name` already exists.

## Test strategy

### portal (backend)

- **Semi-join field:** unit tests of the generated condition: `in` with one and several values, `not-in`, another operator, and the tenant's table names in the sub-query.
- **AC2:** StarRocks integration tests (testcontainers) on the clinical fixture, where case 1 is a trio whose proband, mother and father are on runs 1617, 1618 and 1619:
  - the proband's run finds the case; the father's run also finds it (every member);
  - a somatic case is found by its normal sample's run;
  - a prenatal case is found by the fetus's run;
  - an unknown run finds no case, not an error;
  - several runs find the cases of each, each case once;
  - `not-in` a run excludes every case with a sequencing in it, and keeps a case with no run;
  - the count matches the list;
  - the run filter together with the Run column selected returns the proband's runs in `run_names`.
- **AC3:** `SearchById` integration tests: a run prefix returns `run_name` suggestions, case-insensitive, each run once, never an empty value; a sequencing ID no longer returns `sequencing_experiment_id`.
- Handler tests on `/cases/autocomplete` and `/cases/search` with the `run_name` field.

### portal (frontend)

- **AC1, AC3:** no component or render test (team norm). Checked by the Cypress mock of the suggestion list and on the ferlease.

### portal (cypress)

- **AC2, AC3:** `Autocomplete/Run` replaces `Autocomplete/SequencingExperiment`, and a new `Search/Run` covers the run filter, on a run of the QA data. `Search/SequencingExperiment` stays: it is the only end-to-end test of the `sequencing_experiment_id` filter, which stays.

### mcp

- Unit tests of `search_cases` with the fake portal API (`FakeApi`): a `run_name` match is searched with the `run_name` filter, a `sequencing_experiment_id` match still with its own filter, an unknown type still with `mrn`.
- `test_registration.py` checks the published `Args:` entries; `test_api_fields.py` passes against portal `main` with task 1 merged.

### QA (manual)

- **AC1 to AC3:** on the ferlease, type the start of a run of a trio: the dropdown shows « Run » / « Lot » with the run icon; picking it lists the case. Then a run that holds only a parent's sample: the case is listed, and its Run column shows the proband's run. Screenshots in the PR.
- **Response time:** on the largest QA tenant, recorded in the task 1 PR: `POST /cases/search` with a `run_name` filter, with the `EXPLAIN` showing whether the `run_name` condition reaches the federated scan, and `GET /cases/autocomplete` with a run prefix (one more sub-query on every keystroke, a `LIKE` on a column Postgres does not index).

## Risks and coverage

| Risk | How it is covered |
|---|---|
| A case found through a relative's run looks like a wrong result, since its Run column shows the proband's run | PO accepted it (2026-11-13); QA manual check |
| The `run_name` condition is not pushed to Postgres, so the sub-query reads every sequencing of the tenant | `EXPLAIN` and measurement in the task 1 PR; a gap goes to the deviation log |
| Cost of the run sub-query added to the autocomplete, run on every keystroke | Measurement in the task 1 PR |
| The semi-join field changes the filter code shared by every search | Unit tests of the generated condition; existing fields keep their path (no change unless a table is marked as a semi-join source) |
| Run names are not unique across labs: a run name reused by two labs of a tenant finds both labs' cases | Accepted: the user sees the cases and their lab in the list. Tenant isolation is unchanged |
| A run name stored with spaces around it, outside the batch, is suggested but not matched after the frontend trims it | The batch trims on input; only direct database writes could store one |
| The MCP sends the new `run_name` match to the `mrn` filter and finds nothing | Task 3 |
| The MCP CI breaks on every PR once task 1 is merged | Task 3 merged right after task 1 (merge order) |
| `common.table.filters.search.run_name` is shared with the Files page autocomplete: its label changes there too | Open question |

## Frozen scope

### all

- `run_alias` and `run_date`: not searchable.
- Sample in the placeholder and its icon: RAD-101 / [RAD-162](https://ferlab-crsj.atlassian.net/browse/RAD-162).
- A run facet in the filter bar.

### portal (backend)

- No change to the Run column (`run_names`): proband only, select only.
- `sequencing_experiment_id` stays a filter; only its suggestion goes.
- Moving the Sample filter onto the semi-join field, which drops its always-on aggregate join: follow-up ticket, to create.
- `not-in` on the `sequencing_experiment_id` and `case_group` filters: they join rows, so a case with several sequencings or groups probably passes `not-in` through another row (read in the code, not tested). Separate ticket, to create; they can move onto the semi-join field.

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
