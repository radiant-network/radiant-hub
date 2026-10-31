# RAD-181: Show the Exomiser result of germline CNVs

## Story

- **Link:** [RAD-181](https://ferlab-crsj.atlassian.net/browse/RAD-181)
- **Assigned reviewer:** [Name]
- **Status:** Draft
- **Branch (all repos):** `feat/rad-181-cnv-post-processing-exomiser`

## Chosen approach

**Summary:** the ETL loads the CNV Exomiser report (`variants.tsv`) of each `radiant_germline_cnv_annotation` task into a staging table of its own, and the germline CNV occurrence insert copies its values onto the rows of the same task: the proband's slivar set of RAD-169. The DRAGEN set of the alignment task gets no Exomiser value. The portal exposes the six Exomiser columns on the CNV table, as for SNVs. This plan assumes RAD-116 (Exomiser files on the annotation task) and RAD-169 (slivar set, proband only) are deployed.

### etl

- **Source:** since RAD-116, the CNV post-processing DAG registers `exomiser/CA<id>.exomiser.variants.tsv` as an output of the `radiant_germline_cnv_annotation` task, with data type `exomiser_cnv`. The pipeline runs Exomiser in family mode on the family VCF after the depth refinement, and slivar on the VEP annotation of that same VCF ([workflow at `cad99b4`](https://github.com/Ferlab-Ste-Justine/cnv-post-processing/blob/cad99b4e0b7e39f5d88dfbd028d426df693dee4e/workflows/cnv_post_processing.nf), `exomiser_start_from_vep = false`). The Exomiser rows and the slivar records come from the same records: no matching across files is needed.
- **Staging:** the staging view admits the `exomiser_cnv` `variants.tsv` of a `radiant_germline_cnv_annotation` task in the existing `exomiser_filepath` column, on the proband's row only, as for the SNV report. The task type tells the two reports apart: no new column in the staging table.
- **Load:** the Exomiser load also reads the CNV annotation tasks, into a new shared staging table, `raw_exomiser_cnv`, with the same columns as `raw_exomiser` plus the TSV's `VCF_ID`. A table of its own, not a shared one: the SNV and CNV reports can then change format apart, and no CNV row sits where the SNV Exomiser insert reads. It keeps only the contributing variants and tags the rows with the proband's `seq_id` and the task id, as the SNV load does. The copy step keeps the rows of the tasks not in the run.
- **Join to the occurrences:** the germline CNV occurrence insert joins `raw_exomiser_cnv` on `(part, seq_id, task_id)` and on `VCF_ID` = `name`, the key the insert already uses for each CNV record. When a record has several Exomiser rows (one per gene or mode of inheritance), the row with the highest gene combined score wins, as the SNV `variant_rank = 1` rule does. To confirm on one QA TSV before task 1: `VCF_ID` holds the VCF record ID, and is unique per task.
- **Columns:** six columns at the end of `germline__cnv__occurrence`, named and typed as on `germline__snv__occurrence`, plus the rank:
  - `exomiser_rank` (`INT`, the `#RANK` column of the TSV). New: the SNV occurrences do not carry it.
  - `exomiser_variant_score`, `exomiser_gene_combined_score` (`FLOAT`)
  - `exomiser_moi` (`VARCHAR`)
  - `exomiser_acmg_classification` (`VARCHAR`, lower case as for SNVs)
  - `exomiser_acmg_evidence` (`ARRAY<VARCHAR>`)
- **Schema:** the insert is positional and the copy step is `SELECT *`, so the columns go last. The re-annotation reads them back from the StarRocks table. The Iceberg CNV occurrence table does not change: the values come from StarRocks.
- **Empty values:** the alignment-task rows, a CNV that Exomiser did not rank, and a case with no CNV post-processing keep the six columns `NULL`.
- **SNV kept apart:** the SNV load reads `radiant_germline_annotation` tasks only, and the SNV occurrence insert and the portal ACMG counts read `exomiser` only. No CNV row can reach them.
- **Data QA:** the ACMG classification dictionary on the CNV column; a test that the Exomiser columns are empty on the alignment-task rows.

### portal (backend)

- **Fields:** the six columns on the germline CNV occurrence table, with the flags of their SNV twins: classification, evidence and MOI selectable, filterable, sortable and aggregatable; scores selectable, filterable and sortable (decimal). `exomiser_rank` selectable, filterable and sortable. No join.
- **Default sort:** unchanged (`seq_id`).
- **Contract:** new optional, nullable fields on the germline CNV list, count, aggregation and statistics. Additive. Swagger, TS and Python clients regenerated.

### portal (frontend)

- **Columns:** the SNV table's Exomiser score and ACMG cells are reused for `exomiser_gene_combined_score` and `exomiser_acmg_classification`. New columns for the rank, the variant score, the MOI and the ACMG evidence. Each can be shown or hidden in the column settings. Default visibility deferred to grooming.
- **Query builder:** a pathogenicity group in the germline CNV config, with the Exomiser divider, score, ACMG classification and evidence facets of the SNV config, in the radiant, include and qlin portal configs.
- **Labels:** the score, classification and evidence labels exist and are reused. EN/FR header and tooltip are added for the rank, the variant score, the MOI and the evidence column.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | staging sequencing experiment view, Exomiser load (CNV annotation task), `raw_exomiser_cnv` DDL and copy step, germline CNV occurrence insert, StarRocks migration and staging backfill, data QA, CNV post-processing DAG doc | new / modified |
| portal (backend) | germline CNV occurrence fields, swagger, generated TS and Python clients, test DDL and fixtures, seed schema | modified |
| portal (frontend) | germline CNV table settings and cells, germline CNV query builder config (three portals), EN/FR translations | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Load the CNV Exomiser report | etl | Staging view branch, load of CNV annotation tasks, `raw_exomiser_cnv` DDL and copy, occurrence insert join and columns, migration and staging backfill, data QA, unit tests, integration tests on a CNV Exomiser TSV fixture | — | yes: the portal does not read the columns until task 2 |
| 2 | Expose the CNV Exomiser fields | portal (backend) | Fields, test DDL and fixtures, swagger and clients (2nd commit), integration tests | Task 1 migration run in each environment | yes once the migration has run |
| 3 | Show the CNV Exomiser result | portal (frontend) | Columns, cells, facets, column settings, missing EN/FR keys | Task 2 | yes once task 2 is deployed |

No UX task: the columns and facets reuse the SNV components. No separate Labels task: most labels exist, the few missing keys go with task 3.

## Merge and rollout order

1. etl: task 1. In each environment, with no import running:
   - add the six columns to `germline__cnv__occurrence` in every `{tenant}_tenant` database (`ALTER TABLE … ADD COLUMN`). Otherwise the positional insert fails and every CNV import breaks;
   - drop the two staging views, then run `radiant-init-starrocks-base-tables` with the `udf_release_version` in use, as in RAD-116: it creates `raw_exomiser_cnv` and the views with the new definition. Otherwise the CNV reports stay invisible;
   - backfill the CNV annotation tasks already loaded: copy the `exomiser_filepath` from the external view to the proband's `radiant_germline_cnv_annotation` row of `staging_sequencing_experiment`, and set `ingested_at` to `NULL` on every staging row of these tasks. The delta view selects only new or updated rows, so without this step the existing cases get no Exomiser value until their next case change.
2. etl: the next `radiant-import` re-imports the marked parts and loads the reports.
3. portal backend: task 2, after step 1 in each environment. Before the migration, a query on a new column fails.
4. portal frontend: task 3.

No feature flag.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1:** integration test with a CNV annotation task, its slivar VCF and Exomiser TSV fixtures: each ranked record gets the rank, scores, MOI, ACMG classification and evidence of its best row; a record with several rows takes the highest gene combined score.<br>• **AC3:** the alignment-task rows, an unranked record and a case with no CNV annotation task have empty Exomiser columns.<br>• **Risk:** a CNV TSV never reaches `raw_exomiser` or `exomiser`, and an SNV TSV never reaches `raw_exomiser_cnv`; the SNV Exomiser values of the same case stay unchanged.<br>• Two runs of one sequencing: each task keeps its own Exomiser values. |
| portal (backend) | • **AC1, AC2:** integration tests (testcontainers): the six fields in the list, sort on `exomiser_rank`, filter on `exomiser_acmg_classification` in list and count, aggregation on the classification; nulls on alignment-task rows. |
| portal (frontend) | • **AC1, AC3:** Vitest on the new cells: value shown, `-` when empty. |
| QA (manual) | • One trio and one singleton after post-processing: a few CNVs read by hand in the Exomiser TSV match the table; the DRAGEN set shows empty Exomiser values; sort and filter (AC2); EN/FR labels and column settings (AC4).<br>• One backfilled case shows its Exomiser values after the re-import. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: the Exomiser ACMG classification of a CNV must be attached to the right CNV and must not reach an SNV | • Right CNV: the Exomiser rows and the slivar records come from the same family VCF, and the join uses the record ID within the same task and sequencing. No position matching, no guess across files. The QA check of the TSV key comes before task 1.<br>• No SNV: CNV reports load only from CNV annotation tasks, into their own staging table, read only by the CNV occurrence insert. Tests pin both directions. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Somatic CNVs.<br>• The Exomiser HTML and JSON reports, `genes.tsv` and the Exomiser VCF.<br>• A CNV detail panel and the CNV interpretation form.<br>• Exomiser values on the DRAGEN set. |
| etl | • No change to the CNV post-processing pipeline or DAG.<br>• No per-tenant CNV Exomiser table: the occurrence columns are its only reader. |
| portal (backend) | • No Exomiser ACMG counts per CNV, like the SNV variant page has.<br>• No `exomiser_rank` on SNVs. |
| mcp | • The clinical agent prompt does not mention the CNV Exomiser columns. A separate ticket will add them if needed. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **Record key:** the plan joins on `VCF_ID` = `name`. To check on one QA TSV: `VCF_ID` is filled, equals the slivar record ID, and is unique per task. Fallback if not: join on chromosome, start, end and alternate, after checking how Exomiser writes the start of a symbolic allele. |
| story / product | • **Matching rule:** the story defers whether the RAD-169 matching rule fits the Exomiser rows. RAD-169 has no matching rule: it loads the slivar records as a set of their own. The Exomiser rows join that set on the record key above. Proposal: drop the dependency from the story.<br>• **Singletons:** AC3 says a singleton shows empty values. The DAG sends singletons through the pipeline's family route, so they get a slivar set and an Exomiser report, as SNV singletons do. Proposal: reword AC3 to show their values.<br>• **Rank:** "as SNVs do" does not hold for the rank: the SNV occurrences carry no Exomiser rank. Proposal: keep `exomiser_rank` for CNVs only.<br>• **Default visibility** of the new columns (deferred to grooming). |

## Approval

| | |
|---|---|
| Reviewer | [Name] |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
