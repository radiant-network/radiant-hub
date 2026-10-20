# RAD-110: Pass DRAGEN metrics to the QC pipeline through the samplesheet `dragenMetrics` column

## Story

- **Link:** [RAD-110](https://ferlab-crsj.atlassian.net/browse/RAD-110)
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** `feat/rad-110-qc-dragen-metrics-samplesheet`
- **Supersedes in part:** `etl/design/SJRA-1879-nextflow-quality-control-automation.md` (the S3 search and the grouping by metrics directory)

## Chosen approach

quality-control-pipeline BIOINFO-235 ([#51](https://github.com/Ferlab-Ste-Justine/quality-control-pipeline/pull/51)) removes `--dragen_metrics_dir` and reads a per-sample `dragenMetrics` column (a directory or a tarball) from the samplesheet. Each sample is then handled on its own, so the ETL no longer needs to search S3 for the metrics, group cases by directory, or start one run per directory.

- **The tarball comes from the clinical model, not from S3.** `pending_quality_control_select.sql` gets a `dragen_metrics` CTE built like `cram`: the alignment task's output document with `data_type_code = 'ssup'` and `format_code = 'tgz'`, with a count of matching documents. The query then returns one row per member instead of one per alignment output document. That fan-out only existed to feed the S3 search.
- **Fallback:** a member with no tarball gets the directory of its CRAM (the parent of `file1`). It is not checked before the run (see Open questions).
- **One pipeline run per DAG run:** `locate_metrics` and `group_cases` are removed. `generate_inputs`, `run_pipeline` and `collect_outputs` are no longer mapped tasks; each runs once for all the cases.
- **The scheduler follows:** `case_scheduler` counts QC work with `select_cases` alone, exactly what the cases DAG will run, with no S3 search.
- **No more command-line flag:** the QC driver script passes only `--input` / `--outdir`, like the CNV one. The manual DAG loses its `dragen_metrics_dir` param.
- **The pin is bumped once, in both places:** `QC_PIPELINE_REV` in `Dockerfile.nextflow.launcher` and `QC_PIPELINE` in `radiant/tasks/nextflow/qc/batch.py`, to the tag bioinfo releases.
- Rejected alternative: keep the one-row-per-document query and pick the tarball in `fold_rows`, because the fan-out existed only for the S3 search. Picking in SQL matches how `cram` / `crai` are picked and lets SQL flag an ambiguous tarball the same way it flags `ambiguous_cram`.
- Rejected alternative: keep a lighter S3 search for the fallback members only. The story removes the search. The risk it covered is handled in Risks and coverage.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | `radiant/dags/sql/clinical/pending_quality_control_select.sql` | modified: `dragen_metrics` CTE, `ambiguous_dragen_metrics` reason, one row per member |
| etl | `radiant/tasks/nextflow/qc/model.py` | modified: `DocumentRow` → member row with `dragen_metrics_url`; `document_urls`, `metrics_dir_s3` and `MetricsGroup` removed |
| etl | `radiant/tasks/nextflow/qc/resolve.py` | modified: `fold_rows` simplified; the S3-search reasons (`no_dragen_metrics`, `metrics_not_on_workspace`, `metrics_dir_split`) replaced by `ambiguous_dragen_metrics` |
| etl | `radiant/tasks/nextflow/qc/inputs.py` | modified: `dragenMetrics` column (tarball, or CRAM directory), never empty |
| etl | `radiant/tasks/nextflow/qc/metrics.py` | removed |
| etl | `radiant/tasks/nextflow/qc/batch.py` | modified: `QC_PIPELINE` version; the tarball added to the QC task's `input_documents` when used |
| etl | `radiant/dags/nextflow_quality_control_cases.py` | modified: `locate_metrics` / `group_cases` removed, `generate_inputs` → `run_pipeline` → `collect_outputs` no longer mapped |
| etl | `radiant/dags/nextflow_quality_control.py`, `radiant/dags/operators/k8s.py` | modified: `dragen_metrics_dir` param, env var and flag removed |
| etl | `radiant/tasks/nextflow/case_status.py`, `radiant/dags/case_scheduler.py` | modified: `s3_qc_locator` and the `locate_qc` argument removed; `NEXTFLOW_INPUTS_ROOT` no longer read by the scheduler |
| etl | `Dockerfile.nextflow.launcher` | modified: `QC_PIPELINE_REV` |
| etl | `radiant/dags/docs/{nextflow_quality_control,nextflow_quality_control_cases,case_scheduler}.md`, `CLAUDE.md`, `design/SJRA-1879-*.md` | modified: describe the column and the single run; SJRA-1879 gets a "superseded by RAD-110" note on §4 and the S3 search |
| etl | `tests/unit/nextflow/qc/`, `tests/unit/nextflow/test_case_status.py`, `tests/unit/dags/test_nextflow_quality_control*.py`, `tests/unit/dags/operators/k8s/test_nextflow_quality_control_k8s_operator.py`, `tests/unit/dags/test_clinical_qc_sql_render.py`, `tests/integration/dags/sql/test_qc_case_resolution.py` | modified / `test_metrics.py` removed |
| infra | `infra/qlin-{qa,prod}/kubernetes-manifests/apps/nextflow/qc/nextflow.config` + `README.md` | modified only if `UNTAR` cannot pull (see Merge and rollout order): `withName: 'UNTAR'` container through the ECR cache, and the comments no longer refer to `dragen_metrics_dir` |
| bioinfo | quality-control-pipeline | none on our side: a release tag containing BIOINFO-235 is a prerequisite |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 0 | Release a QC pipeline tag containing BIOINFO-235 | bioinfo (not ours) | Asked of the bioinfo team. `#51` is under `Unreleased` in their CHANGELOG; the last tag is `v2.0.0`. It is breaking, so it will likely be `v3.0.0`. | — | n/a |
| 1 | Read DRAGEN metrics from the samplesheet and run once | etl | Everything in the etl rows above, in one PR: the pin bump, the column and the removal of the flag must ship together (see Merge and rollout order). | Task 0 | no: needs the new pipeline tag in the launcher image (same PR) |

Task 1 stays one PR: it is mostly removals, and splitting off the cleanup would leave dead code in `main` for no reviewer gain. The infra change is not a task: it is a one-block config change that may not be needed at all, and it is tracked as a rollout prerequisite instead. No UX or Labels task: nothing user-visible changes.

## Merge and rollout order

1. **bioinfo** publishes the tag (Task 0).
2. **Prerequisite, qlin-qa:** before the first QA run with a tarball, make sure the `UNTAR` pod can pull its image (`community.wave.seqera.io/...`). That name is fully qualified, so `docker.registry` does not rewrite it to the quay ECR cache, and no ECR cache exists for that registry. If it cannot pull, override the image in the QC `nextflow.config` with one the ECR cache can serve, the way somalier is pinned. Infra PR on explicit request only.
3. **etl** (Task 1), deployed on QA, then verified end to end (Test strategy).
4. **Prerequisite, qlin-prod:** the same `UNTAR` check or override, then the etl release to prod.

What breaks if the order is not respected:

- **New ETL with the `v2.0.0` image:** the pipeline gets no `--dragen_metrics_dir` and ignores `dragenMetrics`, so it silently runs a full BAM_QC / VCF_QC recompute (hours of worker pods). That is why the pin is in the same PR.
- **New image with the old ETL:** the pipeline gets a flag it no longer has, and nothing reads the metrics.
- **No `UNTAR` override:** a run with a tarball sits in `ErrImagePull` on qlin-eks.

No migration, no backfill. Cases already QC'd keep their `quality_control_metrics` task. The new run tag drops the `-gN` suffix, so a retry of a DAG run started before the deploy does not reuse its old launch directory. That only costs the `-resume` cache.

## Test strategy

- **Unit (each acceptance criterion):**
  - SQL render: the `ssup`/`tgz` CTE and the `ambiguous_dragen_metrics` reason.
  - `resolve`: a member with a tarball, a member without one, an ambiguous member.
  - `inputs`: `dragenMetrics` holds the tarball's pod path or the CRAM directory, and is never empty.
  - DAG structure: no `locate_metrics` / `group_cases`; one `run_pipeline`, not mapped.
  - k8s operator: no `--dragen_metrics_dir` and no `NXF_DRAGEN_METRICS_DIR`.
  - `case_status`: QC work is `select_cases` alone.
  - `batch`: the pipeline version and the tarball listed as an input document.
- **Integration:** `test_qc_case_resolution.py` gets clinical fixture rows with an `ssup`/`tgz` output on the alignment task. The codes already exist in `tests/resources/clinical/create_clinical_tables.sql`. Cases cover one tarball, none, and two.
- **End to end on QA:** the cases DAG, then the scheduler, on a family with tarballs and one using the CRAM-directory fallback. We check one child run, filled alignment and coverage sections in each family's MultiQC report, and one `quality_control_metrics` task per case.
- **Not automated:** pulling the `UNTAR` image and how the pipeline itself behaves with `dragenMetrics`. Both are external (infra, bioinfo) and only provable on the cluster, by the QA run above.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic data: with no S3 search, a fallback directory with no metrics gives a green run with an empty report | The fallback is the rare path (most samples have a tarball). `generate_inputs` logs each fallback member at WARNING with its directory, and the DAG doc says so. The pipeline drops another sample's files with a `log.warn` (`dragenFileMatchesSample`). Whether to add a check after the run is an open question. |
| Genomic data: two `ssup`/`tgz` documents on one alignment | The SQL counts them like CRAMs; the case is excluded as `ambiguous_dragen_metrics` (it fails when the run was requested with `task_ids`). |
| Traceability: the pipeline revision changes | The tag is set explicitly in `Dockerfile.nextflow.launcher` and `qc/batch.py` in the same commit, so the registered `pipeline_version` is the one that ran. The tarball is recorded as an input document of the QC task, so the task says which metrics it was built from. |
| Interoperability: input contract owned by bioinfo | Hard dependency on Task 0. The ETL PR is not merged until the tag exists. The `UNTAR` image is checked on each environment before its first run with a tarball (rollout prerequisites). |

## Frozen scope

- No standard-recompute mode: every row the cases DAG writes has a non-empty `dragenMetrics`. An empty value would trigger a full recompute, which the DAG never asks for.
- No tarball built or uploaded by the ETL. Only existing `ssup`/`tgz` documents, or the CRAM directory.
- No S3 check before the run, for tarballs or for the fallback.
- No change to the quality-control-pipeline repo.
- No change to the portal: the batch PATCH body keeps its shape; only one more URL appears in `input_documents`.
- Unchanged: a tarball outside the workspace bucket fails `generate_inputs` (`to_mount`), as a CRAM outside it does today.

## Open questions

- **Check after the run for the fallback?** Recommendation: not in this story. Log the fallback members, and open a ticket if QA shows empty reports in practice.
- **A single run fails as a whole.** One bad case now fails every case of the DAG run, where before only its directory group failed. Retries and `-resume` limit the cost. Should the cases DAG cap the number of cases per run?
- **QA data:** does the 1000 Genomes DRAGEN 4.4.7 dataset have `ssup`/`tgz` documents on its alignment tasks, or must some be registered for the end-to-end test?
- **Tag name and date** from the bioinfo team (Task 0).

## Approval

| | |
|---|---|
| Reviewer | **[Name]** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
