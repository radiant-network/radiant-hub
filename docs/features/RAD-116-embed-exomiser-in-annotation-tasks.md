# RAD-116: Embed the Exomiser files in the annotation tasks

## Story

- **Link:** [RAD-116](https://ferlab-crsj.atlassian.net/browse/RAD-116)
- **Assigned reviewer:** Céline Pelletier, Jeremy Costanza
- **Status:** Draft
- **Branch:** `feat/rad-116-embed-exomiser-in-annotation-tasks`

## Chosen approach

**Summary:** the Exomiser files become outputs of `radiant_germline_annotation` (SNV) and `radiant_germline_cnv_annotation` (CNV). The `exomiser` and `exomiser_cnv` task types are removed. The CNV Exomiser report gets its own data type, `exomiser_cnv`, so users can tell it from the SNV report. The StarRocks Exomiser tables get a `task_id`, so each run of a sequencing keeps its own Exomiser results, as the occurrences already do.

The change ships as one release per environment, inside a data freeze. No legacy task can appear during the freeze, so the ETL and the portal switch to the new model in one step, with no period where both models live together. All environments are migrated, Qlin prod included.

The data freeze covers:
- `radiant-case-scheduler` paused. It is the only scheduled DAG of case processing (`@daily`): it triggers the four case DAGs and `radiant-import`, and changes case statuses;
- `radiant-import` paused (this also stops the `radiant-import-part` runs it triggers);
- `radiant-nextflow-snv-postprocessing-cases` and `radiant-nextflow-cnv-postprocessing-cases` paused;
- no case batch sent by hand (`POST`, `PATCH`, `PUT /{tenant}/cases/batch`).

Portal reads stay open, except while the API restarts during its deploy.

### etl

- **Read the new shape only:** the staging view loses its `exomiser` branch and gains the new one. The `exomiser_filepath` of a `radiant_germline_annotation` task is set only on the proband's row, from its `variants.tsv` output with `data_type_code = 'exomiser'`, because this task holds the aliquots of all family members. The germline annotation task model then carries the Exomiser file, and the Exomiser load tags the rows with the proband's `seq_id`. The legacy Exomiser task model goes away.
- **View redeploy:** the init DAG `radiant-init-starrocks-base-tables` creates the staging views with `CREATE VIEW IF NOT EXISTS`, so a code deploy does not change them in an existing environment. During the freeze, the operators drop `staging_external_sequencing_experiment` and `staging_sequencing_experiment_delta`, then run the init DAG, which re-creates them from the new definition.
- **Write the new shape:** the SNV and CNV post-processing case DAGs send one task per case. The Exomiser TSV, HTML and JSON go in the `output_documents` of the annotation task. The SNV files keep `data_type_code = 'exomiser'`. The CNV files use `exomiser_cnv`.
- **Exomiser per task:** today the Exomiser tables are keyed by `seq_id` only. When a sequencing gets a second annotation task (for example a duo that becomes a trio), the import of the new task replaces the Exomiser rows of the first one. When both tasks are imported again together (after a `PUT` or a case status change, which both change `cases.updated_on`), both files load and the duo and trio occurrences get mixed Exomiser values. Now that the Exomiser file sits on the annotation task, its task id is the occurrence `task_id`, so the tables follow the occurrence model:
  - `exomiser` gets `task_id INT NOT NULL` as its third column, in its duplicate key: `(part, seq_id, task_id, locus_id, id)`. This is the order of `germline__snv__occurrence` (`part, seq_id, task_id, locus_id` first, in its key), so the occurrence insert joins and filters on a key prefix. The [prefix index](https://docs.starrocks.io/docs/table_design/indexes/Prefix_index_sort_key/) keeps at most three fields, so it becomes `part, seq_id, task_id` and `locus_id` leaves it. The portal ACMG counts filter on `locus_id` alone, so they never used this index.
  - The `exomiser` inserts are positional (`INSERT INTO … SELECT` with no column list): the insert lists `task_id` third. The copy step selects `*` from the same table, so it needs no change.
  - `raw_exomiser` gets `task_id INT` appended last, outside its key. Nothing joins on it: the insert only filters it by the run's tasks. Its copy step lists its columns positionally, so `task_id` goes last there too.
  - The load sets `task_id` from the annotation task.
  - The Exomiser rank is computed per `(locus_hash, seq_id, task_id)`.
  - The copy steps keep the rows of the tasks not in the run (`task_id NOT IN` the run's tasks and deleted tasks), and the insert reads the run's tasks, as for `germline__snv__occurrence`.
  - The germline SNV occurrence insert joins `exomiser` on `task_id` as well as `seq_id` and `locus_id`.
  - Data QA: `task_id` gets the same not-null test as the other key columns.
- **CNV Exomiser:** `radiant_germline_cnv_annotation` is not read by the staging view, and the new branch accepts only the `exomiser` data type. These two guards keep the CNV report out of the SNV `exomiser` table, as today.
- **StarRocks migration:** a manual migration, like the existing ones of the ETL, run once per environment during the freeze, after the PostgreSQL migration and before `radiant-import` resumes. In this order:
  1. `staging_sequencing_experiment`: copy the `exomiser_filepath` to the proband's `radiant_germline_annotation` row, and delete the `exomiser` rows.
  2. `raw_exomiser` (shared DB): add `task_id`, with no backfill. The old rows keep a `NULL` `task_id`: the insert never reads them (it selects the run's tasks), and the next copy step of their part drops them (`NULL NOT IN …` is never true).
  3. `exomiser` (each tenant DB): rebuild and swap with `task_id`, the method SJRA-1850 used for a change it could not make in place. The backfill cannot update the rows: [a Duplicate Key table accepts appends but no change to existing rows](https://docs.starrocks.io/docs/table_design/table_types/duplicate_key_table/). A `seq_id` with exactly one proband annotation row carrying an `exomiser_filepath` gives its rows that task id. Steps and checks in [appendix B](#b-rebuild-and-swap-of-exomiser-with-task_id).
  4. A `seq_id` with several such rows (re-runs) cannot tell which file its rows come from: its rows are left out of the rebuild, and `ingested_at` is set to `NULL` on every staging row of its annotation tasks, for every family member. The import then picks them again (it selects the rows where `updated_at >= COALESCE(ingested_at, …)`) and loads each task's own file. All rows are needed: a part builds each task only from the rows its select returns.
  - **Check first (fail fast):** read-only queries run before any write. The operators stop and fix the data if one of them returns a row:
    - an `exomiser` staging row with no proband `radiant_germline_annotation` row of the same `case_id` and `seq_id`, or with several;
    - an `exomiser` row whose `seq_id` has no proband annotation row with an `exomiser_filepath` once step 1 is done (rows that no task can own).
  - A last query lists the `seq_id`s of step 4, for the counts and the re-import check.
  - **Why before `radiant-import` resumes:** the import marks as deleted every staging row whose task is no longer in the clinical DB. The next part import then drops the Exomiser rows of that `seq_id`, here the proband's. Once the migration has deleted these staging rows, nothing is left to mark.
  - `staging_sequencing_experiment` is a Primary Key table, so it accepts [`UPDATE … FROM`](https://docs.starrocks.io/docs/sql-reference/sql-statements/table_bucket_part_index/UPDATE/) (StarRocks 3.0 or later). When several rows of the join match one target row, StarRocks uses one at random, so the join gives exactly one legacy row per proband annotation row.
- **Contract:**
  - `PATCH /{tenant}/cases/batch`: no new field. The current API already accepts Exomiser outputs on an annotation task: its only document rule per task type is for `clinical_report`. It accepts only the data types of the `data_type` table, so the DAGs send `exomiser_cnv` only after the portal migration, in the same freeze.
  - `staging_sequencing_experiment`: same columns. The mcp reads every row of a case, but keeps only the tasks that the API lists for occurrences (annotation, alignment, tumor-only calling). It never uses an `exomiser` row.
- **StarRocks schema and configuration:** `raw_exomiser` and `exomiser` get a `task_id` column. No other table changes. Details per object in [appendix A](#a-starrocks-schema-and-configuration-impact).

### portal (backend)

- **Data migration:** one golang-migrate migration, in one transaction. First, it adds the `exomiser_cnv` data type (EN `Exomiser CNV Report`), and gives it to the output documents of the `exomiser_cnv` tasks. Then each legacy task is matched to its annotation task, its output documents move to the annotation task, then its inputs, contexts and the task itself are deleted. Last, the `exomiser` and `exomiser_cnv` rows of `task_type` are deleted. If the data breaks one of the checks below, the migration raises an error and the transaction changes nothing.
  - **Matching rule:** the annotation task whose output is the legacy task's input (the slivar VCF, as the post-processing DAGs register it). Fallback: the only annotation task of the matching type on the same case that holds the proband's sequencing.
  - **Data checks (fail fast):** the migration raises an error, and changes nothing, on the first legacy task that breaks one of these rules:
    - it has exactly one `task_context` row, as the API creates for a single-aliquot task;
    - it has exactly one matched annotation task;
    - that annotation task has a `task_context` row with the same `case_id` and `sequencing_experiment_id`, so the Exomiser file stays on the proband's sequencing;
    - no other legacy task matches the same annotation task.
  - **When it runs:** at the start of the new API, during the deploy. With several pods, golang-migrate takes a PostgreSQL advisory lock, so one pod applies it and the others wait.
  - **Pre-check:** a read-only query with the same matching rule and the same data checks, run in each environment during the freeze, before the deploy. It lists every legacy task that breaks a check, with the check it breaks. They are fixed by hand until it returns nothing. The freeze keeps new legacy tasks out between the pre-check and the deploy.
  - **If the migration still fails:** the API exits and the schema version stays dirty, so the pods do not start. Recovery: fix the data, `migrate force` to the previous version, restart. Portal reads are down for that time, inside the freeze.
- **Rejection of the old types:** once the `task_type` rows are gone, the case validation, which reads its valid codes from that table, rejects both types with TASK-001 in `POST`, `PATCH` and `PUT` batches. No extra code.
- **Hard-coded rules:** the two types are removed from the case-related, input-required and single-aliquot task lists of the case validation, and from the task type constants.
- **Reads:** the case tasks list, the documents search and the Exomiser endpoints do not filter on the task type. The occurrence lists read the Exomiser values from the occurrence columns, which are already per task.
- **ACMG classification counts per locus:** they read the `exomiser` table and count one row per sequencing today. With `task_id`, a sequencing can have rows for several tasks, so the count becomes a count of distinct `seq_id` per classification. A duo and a trio run of one sequencing that classify a variant differently count once in each class.
- **Test copies:** the StarRocks test DDL and fixtures of `exomiser` get the `task_id` column.
- **Contract:**
  - the `task_type` enum loses two values. Its readers are the case validation, the ETL staging view and task model, and the case DAGs. All of them change in the same freeze.
  - the `data_type` enum gains `exomiser_cnv`. Its readers are the case validation and the documents filter (both read the table), the frontend labels and the lab manifest (its `data_type` column holds the code). The ETL staging view reads only `exomiser`.

### portal (frontend)

- **Labels:** `exomiser_cnv` joins `common.data_type_code` in EN (`Exomiser CNV Report`) and FR (`Rapport Exomiser CNV`), as SJRA-1963 did for its data types. In the files tab and the file archive, the data type badge shows the code (`exomiser_cnv`) and its tooltip shows the label. The data type filter reads the `data_type` table, so it needs no change.
- **Storybook:** only the mocks list an `exomiser` task. They are updated.

### mcp

- **Clinical agent prompt:** its rule for the `exomiser` table says to filter by `seq_id` and `part` ("no task_id"). It now filters by `seq_id`, `task_id` and `part`, like the occurrence tables. No code change: the tools run the SQL the agent writes.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | staging sequencing experiment view, germline annotation task model, legacy Exomiser task model, SNV and CNV post-processing case DAGs (batch body, CNV output data type), Exomiser load, rank, copy and insert (per task), germline SNV occurrence insert (join on `task_id`), `raw_exomiser` and `exomiser` DDL, data QA, QA clinical seeds and test fixtures, StarRocks manual migration | modified / removed / new |
| portal (backend) | PostgreSQL data migration (task types, `exomiser_cnv` data type), pre-check query, case batch validation (hard-coded lists), task type constants, ACMG classification counts, test data (clinical fixtures, worker scenarios, init clinical data, StarRocks `exomiser` DDL and fixtures) | modified / new |
| portal (frontend) | data type labels (EN/FR), Storybook mocks | modified |
| mcp | clinical agent prompt (`exomiser` query rule) | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Read the Exomiser file from the annotation task | etl | Staging view (annotation branch, proband only, `exomiser` branch removed), task model, Exomiser load, legacy task model removed, seeds and fixtures, tests | — | no: deployed in the freeze with tasks 2, 3, 4 and 6 |
| 2 | Register Exomiser as annotation output | etl | SNV and CNV batch bodies send one task, CNV outputs use `exomiser_cnv`, tests | — | no: same freeze |
| 3 | StarRocks migration | etl | Manual migration: staging rows, `raw_exomiser` column, `exomiser` rebuild with `task_id`, re-import marks, check queries, run procedure | Task 6 | no: same freeze |
| 4 | Migrate the tasks and remove the types | portal | Data migration (with the `exomiser_cnv` data type), pre-check query, hard-coded lists, constants, ACMG counts on distinct `seq_id`, test data and StarRocks test DDL, Storybook mocks | — | no: same freeze |
| 5 | Labels | portal (frontend) | EN/FR labels for `exomiser_cnv`, validated by the clinical team | — | yes: an unused label |
| 6 | Exomiser per task | etl | `task_id` in the `raw_exomiser` and `exomiser` DDL, load, rank, copy and insert per task, occurrence join on `task_id`, data QA, tests | Task 1 | no: same freeze |
| 7 | Agent prompt | mcp | `exomiser` query rule with `task_id` | Task 6 deployed | yes once task 6 is deployed |

The tasks can merge in any order: none of them acts on data until the environment is frozen and deployed. No UX task: the new label uses the existing badge and tooltip.

## Merge and rollout order

Merge tasks 1 to 6. They act on no data until an environment is frozen and deployed.

**Operator checklist**, per environment (QA first, then CHOP and Qlin prod). Do the steps in order. Do not end the freeze until step 8 passes. Task 7 (mcp) ships after the freeze.

**1. Freeze.** Skip it, and a legacy task created after the pre-check makes the migration fail and stops the API.
- [ ] Pause `radiant-case-scheduler` first: it triggers the case DAGs and `radiant-import` every day.
- [ ] Pause `radiant-import` (this also stops `radiant-import-part`).
- [ ] Pause `radiant-nextflow-snv-postprocessing-cases` and `radiant-nextflow-cnv-postprocessing-cases`.
- [ ] Tell the data managers: no case batch (`POST`, `PATCH`, `PUT /{tenant}/cases/batch`) until the end of the freeze.
- [ ] Check that no run of these DAGs is still in progress.

**2. Backup and counts before.**
- [ ] Back up `task`, `task_context`, `task_has_document`, `task_type`, `document` and `data_type` in PostgreSQL.
- [ ] Back up `staging_sequencing_experiment` and `raw_exomiser` (shared DB), and `exomiser` in each tenant DB, in StarRocks.
- [ ] Note the counts: legacy tasks (`exomiser`, `exomiser_cnv`), Exomiser documents (outputs of `exomiser` tasks and of `exomiser_cnv` tasks, apart), `staging_sequencing_experiment` rows with `task_type = 'exomiser'`, `exomiser` rows per `seq_id` in each tenant DB.
- [ ] Save the list of legacy Exomiser documents with the `sequencing_experiment_id` of their task (used in step 7).
- [ ] Note the `udf_release_version` in use in the environment (needed in step 4).

**3. Pre-check.** Skip it, and the migration can fail at API start.
- [ ] Run the pre-check query.
- [ ] Fix each listed task by hand, then run the query again, until it returns nothing.

**4. ETL.** Skip the view step, and each later re-import of an annotation task drops its proband's Exomiser rows.
- [ ] Deploy the ETL release (tasks 1, 2, 3 and 6).
- [ ] Drop the views `staging_external_sequencing_experiment` and `staging_sequencing_experiment_delta`.
- [ ] Run `radiant-init-starrocks-base-tables` with the `udf_release_version` noted in step 2.
- [ ] Check that both views exist again and that the external view has the annotation branch.

**5. Portal.** If the API does not start, see "If the migration fails" below.
- [ ] Deploy the portal release (tasks 4 and 5). The migration runs at API start.
- [ ] Check that the API pods are ready, and that `schema_migrations` shows the new version with `dirty = false`.

**6. StarRocks migration.** Skip it, and the next part import drops the proband's Exomiser rows of every migrated case.
- [ ] Run the StarRocks check queries. They must return nothing. If one returns rows, stop and fix the data.
- [ ] Save the list of `seq_id`s with several Exomiser annotation tasks (for step 8).
- [ ] Run the StarRocks migration (task 3): staging rows, `raw_exomiser` column, `exomiser` rebuild in each tenant DB ([appendix B](#b-rebuild-and-swap-of-exomiser-with-task_id), steps 0 to 6), re-import marks. Keep the old `exomiser` tables until step 9.

**7. Counts after.**
- [ ] Legacy tasks: 0. `task_type` rows `exomiser` and `exomiser_cnv`: 0.
- [ ] Exomiser documents: same number as before, all outputs of an annotation task. Former `exomiser_cnv` outputs: data type `exomiser_cnv`, on a `radiant_germline_cnv_annotation` task. Former `exomiser` outputs: data type `exomiser`, on a `radiant_germline_annotation` task.
- [ ] `staging_sequencing_experiment` rows with `task_type = 'exomiser'`: 0. Proband `radiant_germline_annotation` rows with an `exomiser_filepath`: the number of `staging_sequencing_experiment` rows with `task_type = 'exomiser'` noted before (the data checks allow one legacy task per annotation task).
- [ ] Each Exomiser document of the list saved in step 2 is an output of an annotation task that has the same `sequencing_experiment_id`.
- [ ] `exomiser` rows per `seq_id`: same as before, all with a `task_id`, except the `seq_id`s saved in step 6, which have none yet.
- [ ] On QA only: unpause `radiant-nextflow-snv-postprocessing-cases`, trigger it with `task_ids` set to one alignment task, wait for the end, pause it again. Same for `radiant-nextflow-cnv-postprocessing-cases`. Each case gets one annotation task with the Exomiser outputs, and no legacy task.
- [ ] Open one migrated trio case in the portal: the Exomiser files show under the annotation task, and the files tab shows the badges `exomiser` and `exomiser_cnv`, with the tooltips `Exomiser Report` and `Exomiser CNV Report`.

**8. Re-import the re-run sequencings.** Skip it, and these sequencings show no Exomiser counts until their next import.
- [ ] If step 6 saved any `seq_id`: trigger `radiant-import` once by hand (the case scheduler stays paused) and wait for its parts to end.
- [ ] Each saved `seq_id` has `exomiser` rows again, one set per annotation task, and its occurrences show the values of their own task.

**9. End the freeze.**
- [ ] Resume `radiant-import` and the two post-processing DAGs, then `radiant-case-scheduler` last.
- [ ] Tell the data managers that case batches are open again.
- [ ] Drop the old `exomiser` table kept in each tenant DB ([appendix B](#b-rebuild-and-swap-of-exomiser-with-task_id), step 7).

**If the migration fails at API start.** The pods do not start, and `schema_migrations` stays dirty.
- [ ] Keep the freeze.
- [ ] Find the task in the API logs and fix the data by hand, or restore the PostgreSQL backup.
- [ ] Run `migrate force` to the previous version, then restart the API.

**Rollback**, at any step before the end of the freeze.
- [ ] Restore the PostgreSQL and StarRocks backups. For `exomiser`, swap back with the old table kept in each tenant DB ([appendix B](#b-rebuild-and-swap-of-exomiser-with-task_id), step 7).
- [ ] Redeploy the previous ETL and portal releases. Drop the two staging views and run the init DAG again, with the same `udf_release_version`.

No feature flag. The Exomiser rows stay in place, except for the sequencings with several annotation tasks, which are re-imported in step 8.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • Unit tests on the SNV and CNV batch bodies: one annotation task with the Exomiser outputs, no legacy task, the CNV files typed `exomiser_cnv` (AC 1, 3).<br>• Integration test on the staging view with a trio: the `exomiser_filepath` is on the proband's row only, and a CNV Exomiser TSV is ignored, on a CNV annotation task and on a germline annotation task with the `exomiser_cnv` data type (AC 5).<br>• Integration test of the Exomiser load from an annotation task: rows tagged with the proband's `seq_id` and the task id (AC 6).<br>• Integration test with two annotation tasks on one sequencing (duo, then trio): each task keeps its own Exomiser rows, and each task's occurrences get their own Exomiser values, imported apart or together (AC 7).<br>• Integration test of the StarRocks migration on fixture rows: the file path moves to the proband's annotation row with the same `seq_id`, the `exomiser` staging rows are gone, the `exomiser` rows get the task id of their sequencing's only Exomiser annotation task, and a sequencing with two loses its rows and has its annotation rows marked for re-import (AC 4, 5, 7). The check queries list a staging row with no proband annotation row or with two, and an `exomiser` row that no task can own (AC 4). |
| portal (backend) | • Migration test on fixtures: each document moves to the matched annotation task, no legacy task and no legacy type remain. The outputs of `exomiser_cnv` tasks get the `exomiser_cnv` data type, the others keep `exomiser`. Each moved document stays on the same `sequencing_experiment_id` (AC 4, 5).<br>• One fixture per data check (no context, two contexts, no match, two matches, match without the proband's sequencing, annotation task matched twice): the migration fails and changes nothing, and the pre-check lists the task with the check it breaks (AC 4, 5).<br>• Worker tests: a `POST`, `PATCH` or `PUT` batch with `exomiser` or `exomiser_cnv` is rejected. A batch with Exomiser outputs on the annotation task passes, with the `exomiser_cnv` data type on a CNV annotation task (AC 1, 2).<br>• ACMG counts test: a sequencing with two tasks counts once per classification (AC 7). |
| QA (manual) | • Before and after counts per environment: Exomiser documents, legacy tasks, `exomiser` rows per `seq_id` and their `task_id` (AC 4, 5).<br>• Each re-imported sequencing has one set of Exomiser rows per annotation task (AC 7).<br>• One SNV and one CNV post-processing run on QA, before the freeze ends (AC 3).<br>• One migrated trio case in the UI: the Exomiser files show under the annotation task, the SNV and CNV reports show different data types, and the Exomiser scores stay on the variants (AC 6). |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic data: the migration can corrupt or lose data in PostgreSQL and StarRocks | • The freeze fixes the set of tasks to migrate, and keeps the import from running between the PostgreSQL and the StarRocks steps.<br>• The data checks fail fast: the pre-check lists every task that breaks one before any write, and the migration raises an error on the first one, in one transaction, so nothing changes. They keep each Exomiser file on the proband's sequencing.<br>• The `exomiser` rebuild keeps every row a single task can own, and the check queries stop the migration on rows that no task can own. The rows of re-run sequencings, whose origin is unknown, are not guessed: they are re-imported from each task's own file, inside the freeze. The StarRocks migration runs before `radiant-import` resumes, so no Exomiser row is dropped by the import.<br>• A backup (including `raw_exomiser` and each tenant's `exomiser`) and counts before and after, per environment. Rollback restores the backups inside the freeze.<br>• A failed migration stops the API, inside the freeze only. The recovery steps are in the run procedure. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No change to the Nextflow pipelines or their outputs.<br>• No rolling transition: this release needs the freeze. The new ETL and the new portal do not support legacy tasks.<br>• The SNV and CNV Exomiser reports keep the same file names, in different S3 locations (`…/snv/<run>/exomiser/` and `…/cnv/<run>/exomiser/`). The new data type tells them apart in the portal, but `radiant-client download`, which saves by name, still keeps only one of them when both are in one manifest. This is true today. A separate ticket will fix it if needed (distinct names). |
| etl | • The CNV Exomiser report stays unloaded in StarRocks, as today.<br>• The input lineage stays as the DAGs record it now (gVCFs, CNV VCFs, CRAMs). The slivar VCF stops being a recorded input.<br>• No re-import beyond the sequencings with several annotation tasks. The occurrences of the other tasks keep the Exomiser values they got at their import. |
| portal (backend) | • No new validation that requires Exomiser outputs on an annotation task.<br>• No down migration. Rollback uses the backups. |
| mcp | No tool change. Only the agent prompt changes. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **CHOP:** does it mean the d3b deployment? Proposal: yes, migrated like the Qlin environments. |
| etl | • **StarRocks version:** `UPDATE … FROM` needs StarRocks 3.0 or later. The version of each cluster is not verified. Proposal: check it on each cluster before the freeze. If one is older, the migration needs another form, to define then. The SJRA-1850 migration notes say it was verified against StarRocks 4.0.11, without naming the cluster. |

## Approval

| | |
|---|---|
| Reviewer | Céline Pelletier, Jeremy Costanza |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |

## Appendix

### A. StarRocks schema and configuration impact

Two tables get a `task_id` column: `raw_exomiser` and `exomiser`. One view changes its definition, one table gets a one-off data change, and one insert changes its join. Nothing else changes.

| Object | Where | Schema | Deploy or config | Data | Why |
|---|---|---|---|---|---|
| `staging_external_sequencing_experiment` | view, shared DB | definition changes, same columns | dropped by hand, then re-created by `radiant-init-starrocks-base-tables`, once per environment, during the freeze | none | The annotation branch (proband row only) replaces the `exomiser` branch. The init DAG uses `CREATE VIEW IF NOT EXISTS`, so a code deploy leaves the old view in place. |
| `staging_sequencing_experiment_delta` | view, shared DB | none | dropped and re-created with the external view (same definition) | none | Its first step selects `sse.*` from the external view, and its final select names the columns one by one. The external view keeps every one of them. |
| `staging_sequencing_experiment` | Primary Key table, shared DB | none | manual migration, once per environment, before `radiant-import` resumes | one-off: `exomiser_filepath` copied to the proband's annotation row, `exomiser` rows deleted | Primary Key table, so [`UPDATE … FROM`](https://docs.starrocks.io/docs/sql-reference/sql-statements/table_bucket_part_index/UPDATE/) works (StarRocks 3.0 or later). When several join rows match one target row, StarRocks uses one at random, so the join gives exactly one match. |
| `raw_exomiser` | duplicate-key table, shared DB | new `task_id INT`, appended last, outside the key | manual migration (`ADD COLUMN`), once per environment | none: old rows keep a `NULL` `task_id`, are never read, and are dropped by the next copy step of their part | The load sets `part`, `seq_id`, `tenant_code` and now `task_id`. The `seq_id` comes from the proband's experiment of the annotation task, as it does today from the single experiment of the legacy task. The copy step keeps the rows of the tasks not in the run. |
| `exomiser` | per tenant | new `task_id INT NOT NULL`, third column, key becomes `(part, seq_id, task_id, locus_id, id)` | manual rebuild and swap in each tenant DB, the SJRA-1850 method | backfill: `task_id` from the only Exomiser annotation task of the `seq_id`. Sequencings with several such tasks: rows left out and re-imported | Key `(part, seq_id, locus_id, id)` today, so two runs of one sequencing overwrite or mix each other. The new key follows `germline__snv__occurrence`, which the occurrence insert joins on. The backfill is a rebuild: [a Duplicate Key table accepts appends but no change to existing rows](https://docs.starrocks.io/docs/table_design/table_types/duplicate_key_table/). The rank, the copy and the insert work per task. The portal ACMG counts become a count of distinct `seq_id`. The mcp prompt filters by `task_id`. |
| `germline__snv__occurrence` (`exomiser_*` columns) | per tenant | none | none | re-imported for the sequencings with several annotation tasks | The occurrence insert now joins `exomiser` on `task_id` too, so each task's occurrences get their own task's Exomiser values. |
| Clinical tables in the JDBC catalog (`task`, `task_type`, `task_context`, `task_has_document`, `document`, `data_type`) | catalog over PostgreSQL | none | none | rows change in PostgreSQL (including the new `exomiser_cnv` data type and the CNV documents that use it) | The ETL reads them through the catalog named by `RADIANT_CLINICAL_CATALOG` (default `radiant_jdbc`). No PostgreSQL column changes. StarRocks reads the rows live. |
| Portal tenant views (`{code}_tenant.task`, `task_type`, …) | per tenant views | none | no refresh | none | `create-tenant` and `refresh-tenants` build each view as `CREATE OR REPLACE VIEW … AS SELECT <columns>`, with the columns read from the PostgreSQL `information_schema`. The columns stay the same, so the views stay valid. |
| Configuration | etl + portal | none | `udf_release_version` set on the init DAG run | none | The init DAG run replaces the two UDFs with the version it is given. No new table or view, so no new table mapping key and nothing new for the Ranger policies to cover. No new Airflow variable. The data QA tests the `exomiser` content, gets a not-null test on `task_id`, and has no test on task types. The portal's StarRocks test DDL and fixtures of `exomiser` get `task_id`. |

### B. Rebuild and swap of `exomiser` with `task_id`

**Why a rebuild.** `ALTER TABLE … ADD COLUMN task_id` alone would leave every existing row with `task_id = NULL`, and the new occurrence join on `task_id` would never match them. Filling the column means rewriting the rows, and [a Duplicate Key table accepts appends but no change to existing rows](https://docs.starrocks.io/docs/table_design/table_types/duplicate_key_table/). `raw_exomiser` needs no rebuild: its old rows are never read again and the next copy step of their part drops them.

**The method.** Build a new table with the column already filled, then exchange the names in one atomic step. This is the method of the SJRA-1850 migration (`snv__consequence_filter_partitioned`, "Verified against StarRocks 4.0.11"). The steps below adapt it to `exomiser`. They run in each tenant DB, during the freeze, after the staging step of the StarRocks migration.

**0. Counts before.** Count the rows per `(part, seq_id)`. Steps 3 and 5 compare against them.

**1. Replacement table.** Identical to the new init DDL of task 6: `task_id INT NOT NULL` is the third column, after `seq_id`, and the key is `DUPLICATE KEY(part, seq_id, task_id, locus_id, id)`, the key columns first as in `germline__snv__occurrence`. The rest stays as today's DDL: `PARTITION BY (part)`, `DISTRIBUTED BY HASH(locus_id) BUCKETS 10` and `colocate_with = <namespace>.query_group`. Partitions, buckets and colocation group must match: otherwise the swap takes the table out of the colocation group that the occurrence joins use (the SJRA-1850 warning).

**2. Copy with `task_id`.** The mapping comes from `staging_sequencing_experiment` after the staging step: the proband `radiant_germline_annotation` rows with an `exomiser_filepath`, for the `seq_id`s with exactly one such task.

```sql
INSERT INTO exomiser_task_id
SELECT e.part, e.seq_id, m.task_id, e.locus_id, e.id, e.locus_hash, e.moi,
       e.variant_score, e.gene_combined_score, e.variant_rank, e.rank, e.symbol,
       e.acmg_classification, e.acmg_evidence
FROM exomiser e
JOIN (
    SELECT seq_id, MIN(task_id) AS task_id
    FROM <shared_db>.staging_sequencing_experiment
    WHERE task_type = 'radiant_germline_annotation'
      AND family_role = 'proband'
      AND exomiser_filepath IS NOT NULL
      AND NOT deleted
      AND tenant_code = '<tenant>'
    GROUP BY seq_id
    HAVING COUNT(DISTINCT task_id) = 1
) m ON m.seq_id = e.seq_id;
```

- The insert is positional, so the select lists every column in the new order, with `task_id` third. The list is today's `exomiser` columns: check it against `DESC exomiser` before the run.
- The inner join leaves out, on purpose, the re-run sequencings (several tasks), which are re-imported from each task's own file (checklist step 8), and the rows that no task can own, which the fail-fast check query has already stopped on.

**3. Checks before the swap**, while undoing is free:
- the rows per `(part, seq_id)` equal step 0 for every kept sequencing;
- the re-run sequencings have 0 rows;
- no `task_id` is `NULL`;
- `DESC exomiser_task_id` shows `task_id` as the third column, and `SHOW CREATE TABLE exomiser_task_id` shows the new key.

**4. Swap.** `ALTER TABLE exomiser SWAP WITH exomiser_task_id;` is an atomic name exchange. From then on, `exomiser` holds the new column and `exomiser_task_id` holds the old table.

**5. Checks after the swap:** `SHOW CREATE TABLE exomiser` (key `(part, seq_id, task_id, locus_id, id)`, same buckets and `colocate_with`), the counts of step 3, and `SHOW PROC '/colocation_group'` (the group must be healthy).

**6. Re-import marks.** `staging_sequencing_experiment` is a Primary Key table, so `UPDATE … SET ingested_at = NULL` works on it: every staging row of the re-run sequencings' annotation tasks, for all family members.

**7. Old table.** Unlike SJRA-1850, which drops it right after the checks, keep `exomiser_task_id` (the old table) until the end of the freeze. A rollback is then a second swap, with no restore. Drop it at checklist step 9.

**Cost and safety.**
- One full copy of `exomiser` per tenant. For comparison, SJRA-1850 copied about 44.5M rows in QA "in a few minutes". The size of `exomiser` is not verified.
- The swap is atomic: readers see the old table or the new one, never a half-filled table.
- No import may write during the copy: SJRA-1850 notes that a concurrent part import is lost by the swap. The freeze keeps `radiant-import` paused.
