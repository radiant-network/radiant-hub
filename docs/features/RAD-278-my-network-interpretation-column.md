# RAD-278: Show the My Network interpretation classification in the variant table

## Story

- **Link:** [RAD-278](https://ferlab-crsj.atlassian.net/browse/RAD-278)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-278-my-network-interpretation-column`

### Acceptance criteria

Copied from the story on 2026-11-12.

- **AC1:** a germline variant interpreted in the network shows its `ACMG/AMP Classification` in the column.
- **AC2:** a somatic variant interpreted in the network shows its `Oncogenicity ClinGen/CGC/VICC` value.
- **AC3:** a variant carrying several distinct classifications across the network shows one badge for each.
- **AC4:** a variant with no network interpretation shows a dash.
- **AC5:** badge labels and colours match the `Interpretations — My Network` block in the variant panel.
- **AC6:** the header and tooltip render in English and in French.
- **AC7:** the API response carries the count per classification, even though the cell does not render it.

## Chosen approach

**Summary:** the germline and somatic SNV occurrence lists return, per variant, the same `interpretation_classification_counts` map that the variant panel already shows. The case variant tables render it as one abbreviated badge per classification, without the count, in a new column after ClinVar.

### portal (backend)

- **Source:** the existing My Network counts of the variant panel. Germline counts group `interpretation_germline.classification` by locus and map the LOINC code to a label. Somatic counts group `interpretation_somatic.oncogenicity` and map every stored form (the LOINC code, or the older key such as `oncogenic` in any case, with spaces read as `_`) to that key, so one classification gives one badge. Both are scoped to the active tenant, so "My Network" is the tenant, as in the panel. The counts include the current case's own interpretation.
- **Read path:** after the list query, the list handler reads the counts of the page's loci in one grouped PostgreSQL query per list call, scoped like the panel query. The StarRocks list query is unchanged. If the counts query fails, the list is still returned, without counts, and the error is logged.
- **Empty or unknown classification:** the list skips it, so one bad row never fails the page. An unknown value logs a warning; an empty one (a form saved without classification) does not. A variant whose interpretations carry no known classification shows a dash.
- **API field:** `interpretation_classification_counts` (object, classification → count, omitted when the variant has none) on each item of `POST /{tenant}/occurrences/germline/snv/{case_id}/{seq_id}/{task_id}/list` and its somatic twin. Same name and shape as on the expanded occurrence and the variant overview, so the frontend reuses its type. Not filterable, not sortable.
- **Contract:** additive. Readers: the portal frontend (TS client) and the MCP's occurrence tools (Python client). The Python client is regenerated. The MCP pins an older client, which reads only the fields it knows, so it ignores the new field until its pin is bumped.

### portal (frontend)

- **Column:** a new `my_network_interpretation` column right after ClinVar, in the germline and the somatic SNV tables, visible by default. Header `My Network` / `Mon réseau`, header tooltip `My Network interpretations` / `Interprétations de mon réseau`.
- **Cell:** a new cell in the tables' cells folder. It renders one abbreviated classification badge per key, the same badge as the variant panel, without the count, and the empty cell (dash) when the map is empty or missing. In the somatic table it renders the somatic labels (`O`, `LO`), as the story asks. There it deviates from the variant panel, which shows some oncogenicity codes as `P` or `LP`.
- **Labels:** badge abbreviations stay the existing English ones in both locales.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | germline and somatic SNV occurrence list handlers, interpretation counts repository, swagger, generated TS and Python clients | modified |
| portal (frontend) | germline and somatic SNV table settings, new My Network cell, EN/FR translations | new / modified |
| portal (cypress) | germline and somatic SNV table page objects | modified |
| etl, mcp, infra, bioinfo | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Return the My Network counts in the SNV occurrence lists | portal (backend) | Batch counts per locus for germline and somatic, merged into the list items, swagger, TS and Python clients, repository and handler tests | — | yes (additive field) |
| 2 | My Network column | portal (frontend) | Column and cell in both tables, header and tooltip EN/FR, cell unit tests, Cypress SNV table page objects (new column, positions after ClinVar shifted), PR label `cypress` | Task 1 | yes once task 1 is deployed |

No Labels task: the story gives the exact EN/FR header and tooltip. No UX task: the cell reuses the variant panel's badge.

## Merge and rollout order

1. portal backend: task 1. Otherwise the new column shows a dash on every row.
2. portal frontend: task 2.

No migration, no backfill, no feature flag: the counts are read live from the interpretation tables.

## Test strategy

### portal (backend)

- **AC1, AC2, AC3, AC7:** repository integration tests (testcontainers) with germline and somatic interpretations on several loci of one page: one locus with two distinct classifications, one with none, one in another tenant (not counted).
- **AC4:** a locus whose only interpretation has a null or unknown classification is left out of the counts, and the list still answers.
- **AC7:** handler test, JSON compared to the expected list body with `interpretation_classification_counts`.

### portal (frontend)

- **AC3, AC4, AC5:** Vitest on the cell: one badge per key, no count shown, dash on an empty or missing map, germline and somatic labels.
- **AC1, AC4, AC6 (Cypress):** the germline and somatic SNV table specs, updated in task 2, cover the column's order, default visibility and tooltip, and its badges or dash on QA data. Without the update, the column order specs fail: they expect each column at a fixed position.

### sandbox (local)

- **AC1 to AC7:** on the sandbox, interpret one germline and one somatic variant twice with different classifications through the API, then check the list response and both tables in EN and FR.

### QA (manual)

- **AC5, AC6:** compare the column with the variant panel on a few interpreted variants, and the header and tooltip in both locales. Visual, so checked by hand. On somatic variants, the column shows `O`/`LO` where the panel may show `P`/`LP`: expected.

## Risks and coverage

The story checks no business risk.

## Frozen scope

### all

- No icon for an interpretation that carries no classification, and no modal on the case and form content (story out of scope, separate ticket).
- No filter, facet or sort on the new column.
- SNV only: no change to the CNV tables.
- No count in the cell (the API returns it for later use).
- No change to the variant entity page.

### portal (backend)

- The variant panel keeps its handling of null and unknown classifications (germline fails, somatic returns an empty key). A separate ticket will align it with the list if needed.

### portal (frontend)

- The somatic variant panel keeps its badges: it shows an oncogenicity code such as `LA6668-3` as `P`, not `O`, and a stored `Likely Oncogenic` as a "no data" badge, not `LO`. The column shows the somatic labels in both cases, so it deviates from the panel there (AC5). A separate ticket will fix the panel.

## Open questions

None.

## Approval

| | |
|---|---|
| Reviewer | TBD |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
