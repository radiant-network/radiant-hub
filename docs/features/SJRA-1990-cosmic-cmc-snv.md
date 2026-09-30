# SJRA-1990: Filter and display COSMIC CMC fields in the SNV variants page

## Story

- **Link:** [SJRA-1990](https://d3b.atlassian.net/browse/SJRA-1990)
- **Assigned reviewer:** **To be decided at grooming**
- **Status:** Draft
- **Branch (all repos):** `feat/sjra-1990-cosmic-cmc-snv`

## Chosen approach

- Approach: **denormalise the CMC fields into the variant tables in the ETL**, as already done for gnomAD, TOPMed, 1000 Genomes, ClinVar, dbSNP and OMIM. Four columns (`cmc_mutation_url`, `cmc_sample_mutated`, `cmc_sample_ratio`, `cmc_tier`) are added to `snv__staging_variant`, `snv__variant` and `snv__variant_partitioned`, and are filled by `snv_staging_variant_insert.sql` and `snv_staging_variant_reannotate.sql`.
- Two COSMIC sources, one value set per variant:
  - `cosmic_mutation_set`, a LEFT JOIN on `locus_id` (colocated, same as the other open-data joins).
  - `cosmic_mutation_set_hgvs`, a `LEFT JOIN [BROADCAST]` on `(transcript_id, cds_change) = (v.transcript_id, v.dna_change)`. The table is small (only the mutations that could not be placed by coordinates). `v.transcript_id` is already stored without its version, like `cosmic_mutation_set_hgvs.transcript_id`, and `v.dna_change` is the `c.` part of `hgvsc`, like `cds_change`.
  - Fallback rule: when there is no `cosmic_mutation_set` row for the locus (`cms.locus_id IS NULL`), **all four** columns come from `cosmic_mutation_set_hgvs`. A `CASE WHEN cms.locus_id IS NOT NULL` is used rather than a per-column `COALESCE`, so the fields of a variant never mix two COSMIC rows.
- `snv_variant_insert.sql` (explicit column list) and `snv_variant_part_insert_part.sql` (`v.*`) carry the columns through. The columns are appended at the end of all three tables so the positional inserts stay aligned.
- The backend then only declares four new fields on the variant table (`v`), with no new join. Tier becomes a dictionary facet (`'1'`, `'2'`, `'3'`, `'Other'`, as published by COSMIC). CMC and CMC Ratio are numeric range facets (the existing min/max statistics).
- The Franklin link is built in the frontend (like `cnv-name-cell.tsx`) from `chromosome`, `start`, `reference`, `alternate`. The somatic list does not return `reference`/`alternate` today, so the backend exposes them.
- Rejected alternative: a query-time LEFT JOIN in the backend (`topmed_bravo` pattern), because it has to be added to both levels of the TOP-N list query, count, aggregation and statistics, and the HGVS fallback on the picked transcript would be expensive to express there. Denormalising keeps the rule in one SQL statement and the portal reads plain columns.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | `radiant/dags/sql/radiant/init/snv_{staging_variant,variant,variant_partitioned}_create_table.sql`, `snv_staging_variant_insert.sql`, `snv_staging_variant_reannotate.sql`, `snv_variant_insert.sql`, new migration `migrations/SJRA-1990_snv_variant_add_cmc.sql`, `radiant/data_qa/macros/dictionaries.sql` + QA tests, `docs/import_cosmic_mutation_set.md` | new / modified |
| portal (backend) | `internal/types/variant.go`, `germline_snv_occurrence.go`, `somatic_snv_occurrence.go`, `internal/repository/starrocks/facets.go`, `docs/swagger.yaml`, generated clients `frontend/api/` and `cli/python/` | modified |
| portal (frontend) | `portals/radiant/config/radiant.ts` (germline and somatic SNV aggregations), `apps/case/src/entity/variants/{germline,somatic}-occurrence/table/*-table-settings.tsx`, new cells (CMC Tier, COSMIC link), `translations/common/{en,fr}.json` | new / modified |
| mcp | none (new columns are visible to its SQL, the Python client is regenerated but its pinned SHA is not bumped) | — |
| infra | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Denormalise CMC into the variant tables | etl | DDL (4 columns at the end of the 3 tables), migration, both COSMIC joins with the HGVS fallback in the insert and reannotate statements, `snv_variant_insert.sql`, `dict_cosmic_tier` + QA tests (tier in dictionary, ratio in [0, 1]), note in `import_cosmic_mutation_set.md` on the forced re-annotation | — | yes (new nullable columns, no reader yet) |
| 2 | Backfill | etl (ops) | Run the migration on each tenant DB and the shared DB, then `reannotate_open_data` with `force_reannotation=True` on QA, then prod | Task 1 | yes |
| 3 | Expose CMC fields in the SNV occurrence API | portal (backend) | Fields `cmc_sample_mutated`, `cmc_sample_ratio`, `cmc_tier`, `cmc_mutation_url` on `VariantTable`, added to the germline and somatic SNV fields (filter, sort, aggregation); `cmc_tier` dictionary in `facets.go`; `reference`/`alternate` in the somatic list; swagger + TS/Python clients; integration tests | Task 1 (columns must exist in the test schema) | yes (additive) |
| 4 | Labels | portal (frontend) | EN/FR labels and tooltips: "Oncology" divider, "CMC", "CMC Ratio", "CMC Tier", tier values, validated by the clinical team | — | yes |
| 5 | CMC facets and columns | portal (frontend) | Oncology divider + 3 facets in the Pathogenicity group (germline and somatic); somatic columns Tier / CMC / CMC Ratio visible by default; germline columns CMC / CMC Ratio hidden by default; Tier cell (colour + Franklin link), COSMIC link cells, scientific notation via `toExponentialNotation` | Tasks 3, 4 | yes once 3 is deployed |

No specific UX task: the colours are set by the story (1 red, 2 orange, 3 yellow, Other grey), and the cells reuse the existing badge and `AnchorLinkCell` components.

## Contract changes

| Contract | Change | Writer | Readers | Migration / compatibility |
|---|---|---|---|---|
| StarRocks `snv__staging_variant` (shared DB), `snv__variant`, `snv__variant_partitioned` (per tenant) | 4 new nullable columns appended at the end: `cmc_mutation_url VARCHAR(255)`, `cmc_sample_mutated INT`, `cmc_sample_ratio DOUBLE`, `cmc_tier VARCHAR(8)` | etl | portal backend (new), mcp (arbitrary SQL) | Manual migration `SJRA-1990_snv_variant_add_cmc.sql` (`ALTER TABLE … ADD COLUMN`, not re-runnable). Existing rows stay `NULL` until the forced re-annotation (task 2) |
| StarRocks `cosmic_mutation_set`, `cosmic_mutation_set_hgvs` (shared DB) | New reader: the variant staging insert and re-annotate statements. No DDL change | etl (`import_cosmic_mutation_set`) | etl (variant staging) | Renaming their columns now breaks the variant load |
| Enum `cmc_tier` | New dictionary `'1'`, `'2'`, `'3'`, `'Other'` in the three synced copies | etl (upstream COSMIC) | portal backend (`facets.go`), frontend translations | New dictionary, no existing data affected |
| API: germline and somatic SNV occurrence list, count, aggregation, statistics | New optional response fields `cmc_sample_mutated` (int), `cmc_sample_ratio` (float), `cmc_tier` (string), `cmc_mutation_url` (string), all nullable; same aliases accepted in filters and sort (`cmc_mutation_url` not filterable). Somatic list also returns `reference` and `alternate` | portal backend | portal frontend (TS client), mcp (Python client, not bumped) | Additive, no versioning needed |

## Merge and rollout order

1. etl: task 1 merged, migration run on every database (QA, then prod) **before** the DAGs are deployed. Otherwise `snv_staging_variant_insert.sql` fails on the missing columns and every import breaks.
2. etl: task 2, forced re-annotation. Until it runs, existing variants have no CMC values (new imports already get them).
3. portal backend: task 3. Deploying it before the migration makes every SNV occurrence query fail (unknown column), so it must wait for step 1 in each environment.
4. portal frontend: tasks 4 then 5, after the backend is deployed.

No feature flag. Each COSMIC refresh later requires a forced `reannotate_open_data` (see open questions).

## Test strategy

- **ETL:** a StarRocks integration test in `tests/integration/dags/sql/` with fixture rows covering: a locus found in `cosmic_mutation_set`; a locus absent from it but found in `cosmic_mutation_set_hgvs` on the picked transcript; a locus in both (the locus row wins); a locus in neither (all `NULL`). The same fixtures run through the insert and the re-annotate statements. Data QA covers tier values and `cmc_sample_ratio` in [0, 1].
- **Backend:** integration tests (testcontainers) with CMC values in the `snv__variant` fixtures: filter on each field, sort by CMC and CMC Ratio with `NULL` rows, tier aggregation, min/max statistics.
- **Frontend:** Vitest unit tests on the Tier cell (colour per value, Franklin URL, `-` when empty) and on the COSMIC link cell.
- **End to end:** manual check on QA after the re-annotation, on one somatic TO case, one TN case and one germline case.
- **Not tested automatically:** that the Franklin and COSMIC pages actually resolve (third-party sites). Checked manually on one SNV, one insertion and one deletion, and on one variant filled through the HGVS fallback.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: Franklin link from chrom/pos/ref/alt in hg38; COSMIC matched by locus or by HGVS | The URL format is pinned by a unit test on the story's example (`chr22-19524402-G-A-hg38`). Indels are checked manually against Franklin. The HGVS fallback matches only the picked transcript, without its version; the ETL fixtures pin that match and the "locus wins" rule. |
| Clinical rules or interpretation: Tier colour | Colours fixed by the story, pinned by a unit test. Labels validated by the clinical team (task 4). |
| Interoperability: links to Franklin and COSMIC | COSMIC uses `cmc_mutation_url` as-is. The Franklin format is isolated in one function. Both open in a new tab with `rel="noopener noreferrer"`. |

## Frozen scope

- SNV only: no change to the CNV and SV tabs.
- Case page only (occurrence tables and facets): no change to the variant entity page or to the side panel, even though the columns become available to them.
- No change to the COSMIC import itself (`import_cosmic_mutation_set`), apart from its documentation.
- No automatic re-annotation gate for COSMIC (see open questions).
- Franklin link in hg38 only.
- No CMC in the MCP (no tool change, no client bump).
- `shared_aa`, `cosmic_id` and `sample_tested` are not denormalised.

## Open questions

- **Re-annotation after a COSMIC refresh:** COSMIC is a broker load from S3, not an Iceberg source, so `reannotate_open_data` cannot see that it changed (same case as cytoband, `radiant/tasks/data/open_data.py` `REANNOTATION_SOURCES`). Proposal for this story: document a forced run after each COSMIC import. A dedicated gate (e.g. recording the COSMIC load in `open_data_release`) would be a separate ticket.
- **Sorting nulls:** does the backend sort already put `NULL` last in both directions? If not, task 3 adds `NULLS LAST` for the CMC fields.
- **CMC Ratio facet precision:** the range slider needs an `intervalDecimal` for values close to 0 (e.g. `1e-4`). Range entered as a decimal or in scientific notation?

## Approval

| | |
|---|---|
| Reviewer | **To be decided at grooming** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |

## Linked PRs

- etl: …
- portal: …
