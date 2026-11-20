# RAD-109: Filter the case list by exact case type (family germline, solo germline, somatic)

## Story

- **Link:** [RAD-109](https://ferlab-crsj.atlassian.net/browse/RAD-109)
- **Assigned reviewer:** not assigned yet
- **Status:** Draft
- **Branch (all repos):** `feat/rad-109`

### Acceptance criteria

Translated from the story (French) on 2026-11-20.

- **AC1:** the case list `Type` filter offers three values, Family germline, Solo germline and Somatic, in place of today's Germline and Somatic.
- **AC2:** selecting Family germline shows only family germline cases (no solo germline case).
- **AC3:** selecting Solo germline shows only solo germline cases (no family germline case).
- **AC4:** selecting Somatic behaves as today.
- **AC5:** the filter labels and its behaviour match exactly the values shown in the `Type` column of the case list.
- **AC6:** several values can still be selected at once (e.g. Family germline and Solo germline).
- **AC7:** the other case list filters are unchanged.

## Chosen approach

**Summary:** the case search gets a new filterable field `case_type`, computed with the same rule as the `Type` column. The `Type` filter of the case list switches to it, with the column's labels.

### portal (backend)

- **Rule:** the `Type` column already returns `case_type`, computed per case: `somatic` for a somatic case, `germline` for a germline case with one member (patient or fetus), `germline_family` otherwise. The filter reuses this rule as is, so the column and the filter cannot disagree (AC5). That includes a germline case with no family row: its member count is empty, not 1, so both read it as `germline_family`.
- **Filter mechanism:** `case_type` is a field of a derived table that gives each case its type, from the same member count as today. A case has exactly one type, so a plain join is right for `in` and `not-in`. The search joins it on demand, like the other optional case joins: before the count when `case_type` is filtered, after it otherwise, as today. The column reads the same join, so each query reads `family` once.
- **Filter values:** `GET /{tenant}/cases/filters` returns a new `case_type` entry with the three codes `germline`, `germline_family`, `somatic`. Its `case_type_code` entry, read only by the case list filter, is removed once the frontend reads `case_type`.
- **Contract:** two steps, each safe alone. First additive: the new search field and the new filters entry. Then, after the frontend switch, the removal of the `case_type_code` filters entry, which no reader uses by then. `case_type_code` stays a filterable search field, unchanged: the MCP `search_cases` tool filters on it (germline/somatic) and keeps working with its pinned client. Swagger, TS and Python clients are regenerated at each step.

### portal (frontend)

- **Filter:** the `Type` filter of the case list sends `case_type` instead of `case_type_code`. Multi-select stays (AC6). The options keep the story's order: Family germline, Solo germline, Somatic, not sorted by label.
- **Labels:** the options take the column's labels (`case_exploration.analysis_type_code`), so the filter reads exactly like the column tooltip (AC5). Today the options show the API's English names, untranslated.
- **FR labels:** the screens disagree today (case list "Germinal seul" / "Lignée Germinale Familiale", patient genomic cases tab "Germinal solo" / "Germinal familial"). The clinical team picks one pair in the labels task, used on every screen.
- **Persisted filters:** the case list keeps its filters in the browser. The persisted filters drop the keys the list no longer declares, so a stored `case_type_code` selection is dropped once, with no error.

### mcp

- **Field list:** `case_type` joins the MCP's list of filterable case fields. Its CI compares that list with the portal's `main`, so it fails from the merge of task 1 until this change.
- **Tool:** the `search_cases` description and its user doc offer `case_type` (`germline`, `germline_family`, `somatic`) next to `case_type_code`, so the agent can tell solo from family cases. The tool passes the field as a plain criterion: no client bump.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | case search fields and repository, case filters endpoint, swagger, generated TS and Python clients | new / modified |
| portal (frontend) | case list filters, EN/FR translations | modified |
| portal (cypress) | case list filters page object and filter specs | modified |
| mcp | case search field list, `search_cases` description, tools doc | modified |
| etl, infra, bioinfo | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Filter cases by computed type | portal (backend) | `case_type` field on the per-case type join, shared by the filter and the column, new `case_type` entry in the filters response, swagger, TS and Python clients, repository and handler tests | — | yes (additive) |
| 2 | Case type in the case search tool | mcp | `case_type` in the filterable case fields, `search_cases` description, tools doc, unit test | Task 1 merged | yes once task 1 is deployed |
| 3 | Labels | portal (frontend) | EN/FR labels of the three types, aligned between the case list, the case header and the patient genomic cases tab, validated by the clinical team | — | yes |
| 4 | Type filter on the computed type | portal (frontend) | Filter key `case_type`, translated options, Vitest, Cypress filter page object and specs | Tasks 1, 3 | yes once task 1 is deployed |
| 5 | Remove the old type filter values | portal (backend) | `case_type_code` entry removed from the filters response, swagger, TS and Python clients, handler test | Task 4 | yes once task 4 is deployed |

No UX task: the filter keeps its look, only its values change.

## Merge and rollout order

1. portal backend: task 1. Otherwise the frontend and the MCP send an unknown field and the case search returns 400.
2. mcp: task 2, right after task 1 merges, since the MCP's CI fails until then. Deploy it after task 1.
3. portal frontend: tasks 3 then 4.
4. portal backend: task 5, once task 4 is deployed in each environment. Earlier, the deployed case list hides its `Type` filter, since the filters response no longer has `case_type_code`.

No migration, no backfill, no feature flag.

## Test strategy

### portal (backend)

- **AC2, AC3, AC4, AC6:** repository integration tests (testcontainers) on fixtures with a somatic case, a solo germline case, a family germline case and a prenatal case with a fetus: each value, two values together, and `not-in`.
- **AC5:** for every fixture case, the `case_type` returned by the list equals the value the filter matches it on.
- **AC7:** the existing case search tests still pass, `case_type_code` included.
- **Single read:** a query test checks that a search filtered on `case_type` reads `family` once in the count and once in the list.
- **Validation:** handler tests, JSON compared to the expected body, for the filters endpoint.

### portal (frontend)

- **AC1, AC5, AC6:** Vitest on the filter options: three options in the story's order, the column's labels, several selected.
- **AC1 to AC6 (Cypress):** the case list filter specs and page object, updated in task 4, apply each type on QA and check the `Type` column of the rows. Check first that QA holds a case of each type.

### mcp

- **Field list:** the existing unit test compares the list with the portal's backend fields. A tool test checks that a `case_type` filter reaches the API as an `in` criterion.

### sandbox (local)

- **AC1 to AC6:** on the sandbox, call the case search with each value through the API, then check the filter and the column in EN and FR. Check first that the sandbox holds a family germline case; if not, report it.

### QA (manual)

- **AC5, AC7:** read the labels in both locales, and apply the type filter with another filter. Visual, so checked by hand.

## Risks and coverage

The story checks no business risk.

## Frozen scope

### all

- No stored case type: the type stays computed at read time. A case whose members change changes type.
- MCP: only `search_cases` gains the filter. The other tools keep reading the case type as today.

### portal (backend)

- `case_type_code` stays a filterable field of the case search, with its germline/somatic values.
- The type rule is unchanged, a germline case with no family row included. A separate ticket will change it if needed.
- The patient genomic cases tab and the variant entity case tables keep their filters.

### portal (frontend)

- The `Type` column keeps its icons and is still not sortable.

## Open questions

None.

## Approval

| | |
|---|---|
| Reviewer | … |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
