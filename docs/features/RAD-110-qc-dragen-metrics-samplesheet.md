# RAD-110: Pass DRAGEN metrics to the QC pipeline through the samplesheet `dragenMetrics` column

## Story

- **Link:** [RAD-110](https://ferlab-crsj.atlassian.net/browse/RAD-110)
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** `feat/rad-110-qc-dragen-metrics-samplesheet`
- **Supersedes in part:** `etl/design/SJRA-1879-nextflow-quality-control-automation.md` (the S3 search and the grouping by metrics directory)

## Chosen approach

**Summary:** quality-control-pipeline BIOINFO-235 ([#51](https://github.com/Ferlab-Ste-Justine/quality-control-pipeline/pull/51)) removes `--dragen_metrics_dir` and reads a per-sample `dragenMetrics` column (a directory or a tarball) from the samplesheet. Each sample is then handled on its own, so the ETL no longer needs to search S3 for the metrics, group cases by directory, or start one run per directory. The ETL takes each member's DRAGEN metrics tarball from the clinical model, writes it in the samplesheet, and starts a single pipeline run per DAG run.

```text
clinical  alignment task
            └─ outputs: CRAM + CRAI, DRAGEN metrics tarball (ssup, tgz)
                 │ pending QC query: one row per member, tarball picked like the CRAM
ETL       samplesheet: dragenMetrics = tarball, or the CRAM directory when there is none
                 │ one pipeline run per DAG run (no S3 search, no grouping)
bioinfo   quality-control-pipeline (tag with BIOINFO-235): UNTAR, then reads the metrics per sample
                 │ collect outputs, PATCH /{tenant}/cases/batch
portal    quality_control_metrics task per case, tarball listed in input_documents
```

### etl

- **Pending detection:** the tarball comes from the clinical model, not from S3. The pending QC query picks it the way it picks the CRAM: the alignment task's output document with `data_type_code = 'ssup'` and `format_code = 'tgz'`, with a count of matching documents. The query then returns one row per member instead of one per alignment output document; that fan-out only existed to feed the S3 search. A member with two tarballs excludes its case as `ambiguous_dragen_metrics`, as `ambiguous_cram` does today. The exclusion reasons tied to the S3 search (`no_dragen_metrics`, `metrics_not_on_workspace`, `metrics_dir_split`) go away.
- **Samplesheet:** a new `dragenMetrics` column per member, never empty. It holds the tarball's pod path, or, when the member has no tarball, the directory of its CRAM. The fallback is not checked before the run (see Open questions): each fallback member is logged at WARNING with its directory. A tarball outside the workspace bucket fails input generation, as a CRAM outside it does today.
- **Cases DAG:** the metrics search and the grouping by directory are removed. Input generation, the pipeline run and output collection are no longer mapped: each runs once for all the cases of the DAG run. The run tag drops its per-group suffix.
- **Manual DAG and launcher:** the `dragen_metrics_dir` param, its env var and the `--dragen_metrics_dir` flag are removed. The QC driver script passes only `--input` / `--outdir`, like the CNV one.
- **Case scheduler:** it counts QC work with the case selection alone, exactly what the cases DAG will run, with no S3 search. It no longer needs the Nextflow inputs root.
- **Registration:** unchanged batch body, except that the tarball is added to the QC task's `input_documents` when it is used, so the task records which metrics it was built from.
- **Pipeline pin:** bumped once, in both places (launcher image and QC batch module), to the tag bioinfo releases, in the same PR as the column (see Merge and rollout order).
- **Docs:** the QC and scheduler DAG docs and the ETL `CLAUDE.md` describe the column and the single run. SJRA-1879 gets a "superseded by RAD-110" note on its S3 search and grouping.

Rejected alternatives:

- Keep the one-row-per-document query and pick the tarball in the Python fold of the rows. The fan-out existed only for the S3 search. Picking in SQL matches how the CRAM and CRAI are picked and lets SQL flag an ambiguous tarball the same way it flags an ambiguous CRAM.
- Keep a lighter S3 search for the fallback members only. The story removes the search. The risk it covered is handled in Risks and coverage.

### infra

- **`UNTAR` image, only if needed:** the pipeline's `UNTAR` step pulls a fully qualified `community.wave.seqera.io/...` image, which the registry rewrite does not send to the ECR cache. If the pod cannot pull it, the QC Nextflow config overrides that process's container with one the ECR cache serves, the way somalier is pinned, and its comments stop referring to `dragen_metrics_dir`. QA, then prod. Infra PR on explicit request only.

### bioinfo

- No change on our side. A release tag containing BIOINFO-235 is a prerequisite (Task 0).

### portal (backend)

- No change. The batch PATCH body keeps its shape; only one more URL appears in `input_documents`.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | pending QC query (tarball per member), QC samplesheet (`dragenMetrics` column), QC cases DAG (single run, S3 search and grouping removed), manual QC DAG and launcher (flag removed), case scheduler (QC work count), QC batch body (tarball as input document), pipeline pin, DAG docs | modified / removed |
| infra | QC Nextflow config: `UNTAR` image override, only if it cannot be pulled (QA, then prod) | modified, conditional |
| bioinfo | none on our side (release tag with BIOINFO-235) | — |
| portal (backend) | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 0 | Release a QC pipeline tag containing BIOINFO-235 | bioinfo (not ours) | Asked of the bioinfo team. `#51` is under `Unreleased` in their CHANGELOG; the last tag is `v2.0.0`. It is breaking, so it will likely be `v3.0.0`. | — | n/a |
| 1 | Read DRAGEN metrics from the samplesheet and run once | etl | Everything in the etl section above, in one PR: the pin bump, the column and the removal of the flag must ship together (see Merge and rollout order). | Task 0 | no: needs the new pipeline tag in the launcher image (same PR) |

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
