# RAD-163: Show gnomAD SV frequencies on CNVs in the portal

## Story

- **Link:** [RAD-163](https://ferlab-crsj.atlassian.net/browse/RAD-163)
- **Assigned reviewer:** Karl RITCHIE
- **Status:** In review
- **Branch (all repos):** `feat/rad-163-cnv-gnomad-sv-frequencies`

## Chosen approach

**Summary:** the ETL adds `gnomad_ac` to the two CNV occurrence tables, from the gnomAD SV call it already matches. The API exposes `gnomad_af` and `gnomad_ac` next to `gnomad_sc` and `gnomad_sf`. The germline CNV table in the case page gets AF, AC and SC columns, and the SF tooltip is corrected.

| Module | Approach |
|---|---|
| etl | • **Column:** `gnomad_ac` (INT, NULL) on `germline__cnv__occurrence` and `somatic__cnv__occurrence`, appended after the last gnomAD column. Both tables are per tenant.<br>• **Value:** `ac` of the gnomAD SV call that the CNV already matches (same chromosome, DEL / DUP from the CNV type, 80% reciprocal overlap, best call by AF then SF). QA and prod read the same `gnomad_sv_v1`, which publishes `ac` (filled on QA, checked on 2026-10-30; same source in prod, confirmed by Karl RITCHIE). No new join: the existing gnomAD SV join of the ingest and re-annotation statements carries one more column.<br>• **No match:** the CNV keeps NULL in all the gnomAD columns. This is already the behaviour for AF, SC and SF; the tests pin it for AC.<br>• **Migration:** a manual add-column script for every `{tenant}_tenant` database, in the existing migrations folder. The occurrence inserts are positional, so the column order must match the create statements.<br>• **Backfill:** the re-annotation statements fill `gnomad_ac` on the existing partitions when the CNV branch of `reannotate_open_data` runs. Its gates watch the open-data sources, not the code, and gnomAD SV does not move with this story: one manual run with `force_reannotation` opens it, once per environment. This is the documented use of the param after a statement change, and it needs no code. It rebuilds every branch of every tenant and holds the import lock for the whole run: no `import_part` runs meanwhile, so the run is planned at a time when no import is expected. |
| portal (backend) | • **Fields:** `gnomad_af` (decimal) and `gnomad_ac` (integer) on the germline and somatic CNV occurrence endpoints. Selectable, sortable and filterable, with the same flags as the existing `gnomad_sc` and `gnomad_sf`.<br>• **Not default fields:** AF and AC stay out of the default selection. The API selects only the default fields plus the ones the client asks for, and the CNV endpoints have no select-all path and no export. So a backend deployed before the migration breaks only a request that shows, sorts or filters AC, not the whole CNV table.<br>• **Integration point:** the CNV occurrence field lists. The columns are on the occurrence table, so no join is added.<br>• **Contract:** additive optional response fields. Swagger, TS client and Python client are regenerated. |
| portal (frontend) | • **Columns:** gnomAD AF, AC and SC in the germline CNV table, next to the existing SF column. Hidden columns are fetched only when shown, through the existing column settings.<br>• **Visibility:** SF stays visible by default; AF, AC and SC hidden by default (to confirm in grooming).<br>• **Labels:** EN and FR label and tooltip for each column. The SF tooltip says « site frequency » / « fréquence de site » instead of « Allele Frequency ».<br>• **Saved column settings:** the settings a user saved replace the defaults when they load. A column they do not know is then shown at the end of the table, empty (its value is not requested from the API), with its box unchecked. The shared data table completes the saved settings with the defaults: a column they do not know takes its default visibility and position. This fixes every table of the portal, for this story and the next new column. The user reset of the column settings stays the fallback.<br>• **Somatic:** no view, the portal has no somatic CNV table. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | CNV occurrence create statements, ingest and re-annotation statements (germline and somatic), migration script, CNV integration tests | modified / new |
| portal (backend) | germline and somatic CNV occurrence fields, test DDL copies and fixtures, seed schema, swagger, generated TS and Python clients | modified |
| portal (frontend) | germline CNV table settings, EN/FR labels, shared data table (loading of saved column settings) | modified |
| mcp | none: the clinical agent reads `gnomad_sf` by SQL; an added column does not change its queries | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Store gnomAD SV AC on CNV occurrences | etl | `gnomad_ac` in the two create statements and the four ingest / re-annotation statements, migration script, integration tests | — | yes, once the migration has run (new column, no reader yet) |
| 2 | Expose gnomAD SV AF and AC on CNV occurrences | portal (backend) | Two fields on the germline and somatic CNV endpoints, test DDL copies, fixtures and seed schema, swagger and generated clients, integration tests | Task 1 migrated in the environment | yes (additive), but see rollout |
| 3 | Saved column settings take new columns at their default | portal (frontend) | Shared data table: when a user's saved column settings load, a column they do not know takes its default visibility and its default position. Unit tests. | — | yes (no visible change on the existing tables) |
| 4 | gnomAD SV columns in the germline CNV table | portal (frontend) | AF, AC and SC columns and settings, EN/FR labels and tooltips, SF tooltip fix | Tasks 2 and 3 | yes, once tasks 2 and 3 are deployed |

No Labels or UX task: the columns follow the existing SF column, and the four labels are short and listed in the story. Product validates them in the task 4 PR.

## Merge and rollout order

1. etl: merge task 1. Run the migration in every tenant database (QA, then prod) **before** the DAGs are deployed. Otherwise the positional inserts fail and every `import_part` with CNVs breaks.
2. etl: run the backfill (one manual run of `reannotate_open_data` with `force_reannotation`), QA then prod, at a time when no import is expected. Until then, `gnomad_ac` is NULL on the existing CNVs, even when they match a gnomAD call.
3. portal backend: deploy task 2 after the migration of step 1 in the same environment. Before that, a query that selects `gnomad_ac` fails on the missing column.
4. portal frontend: deploy task 3 at any time, then task 4 after step 3. Without task 3, users with saved column settings see AF, AC and SC empty at the end of the table.

Tasks 2, 3 and 4 can be developed in parallel with task 1: only their deploy waits.

No feature flag. No table is dropped.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • StarRocks integration test of the germline ingest on fixture CNVs: a CNV that matches a gnomAD SV call gets its `ac`; a CNV with no match gets NULL in AF, AC, SC and SF, not 0. (AC 1, 3)<br>• Same fixtures through the somatic ingest. (AC 2)<br>• Same checks on the re-annotation statements, which do the backfill. (AC 4)<br>• Migration: run on QA in every tenant database, no table dropped. (AC 4) |
| portal (backend) | • Integration tests (testcontainers) on both CNV endpoints: AF and AC in the list, sort ascending and descending, numerical filter. (AC 5) |
| portal (frontend) | • Column settings list AF, AC, SC and SF with the agreed visibility; EN and FR keys exist. (AC 6)<br>• Shared data table: saved settings that do not know a column give that column its default visibility and position, and a hidden one is not requested from the API. (AC 6) |
| QA (manual) | • On QA after the backfill: for a few CNVs, `gnomad_ac` matches `ac` of the gnomAD SV call found by hand.<br>• In the case page: show and hide the four columns, sort on each, read the tooltips in EN and FR. |

## Risks and coverage

The story checks no business risk.

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Somatic CNV view in the portal.<br>• gnomAD exome CNV callset (`gnomad_cnv_v1`) and its SC / SF fields.<br>• Change of the matching rule (overlap, type mapping, choice of the best call). |
| etl | • `gnomad_sn`, `gnomad_sc_hom` and `gnomad_sc_het` stay as they are. |
| portal (frontend) | • New filters for AF and AC in the query builder. The existing SF and SC filters stay as they are, labels included.<br>• `gnomad_sn` column. |

## Open questions

| Module | Questions |
|---|---|
| portal (frontend) | • **Default visibility:** SF visible, AF, AC and SC hidden (story proposal, to confirm in grooming). |

## Approval

| | |
|---|---|
| Reviewer | Karl RITCHIE |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
