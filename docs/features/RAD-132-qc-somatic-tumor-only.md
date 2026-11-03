# RAD-132: Run the QC pipeline on somatic tumor-only cases

## Story

- **Link:** [RAD-132](https://ferlab-crsj.atlassian.net/browse/RAD-132) (after [RAD-110](https://ferlab-crsj.atlassian.net/browse/RAD-110))
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branches:** `feat/rad-132-qc-somatic-tumor-only` (hub, this spec), `feat/rad-213-qc-placeholder-vcf` (infra, Task 1), `feat/rad-214-qc-somatic-tumor-only` (etl, Task 2)

## Chosen approach

**Summary:** the QC cases DAG also selects the somatic tumor-only cases. Each one adds one row to the same samplesheet: the tumor sample, declared as a `VCF` row that points at a shared empty placeholder VCF, with its DRAGEN metrics in `dragenMetrics`. In DRAGEN mode the pipeline only checks that a VCF row's file exists, and runs somalier on `CRAM` / `BAM` rows only, so the tumor gets its DRAGEN sections and no somalier. Germline rows do not change. This is the widening that SJRA-1879 decision 6 planned.

### etl

- **Selection:** the pending QC query also returns the somatic cases (not draft or revoked) and the current `alignment_somatic_variant_calling` task of their tumor experiment. Same supersession policy as germline: newest completed experiment, newest alignment per experiment. Same anti-join: no `quality_control_metrics` task on that (case, experiment). It stays one query: the case CTE takes both case types, and the experiment and alignment CTEs pick the tumor experiment and its alignment task for somatic cases, so the DAG and the scheduler keep one source.
- **Tumor-only:** a somatic case is a candidate only when it holds no normal experiment. Tumor-normal cases are never returned, and nothing is logged for them.
- **Inputs from the alignment:** the CRAM, its index and the `ssup` / `tgz` tarball, picked exactly as for germline. A somatic case with no tarball is excluded as `no_metrics` and logged. It has no CRAM-directory fallback: that fallback gives a green run with an empty report.
- **Samplesheet row:** `fileType = VCF`, `file1` = the placeholder, no `file2`, `status = 1`, `familyId = CA<case id>`, `relationship_to_proband = Proband`, `dragenMetrics` = the tarball. The other columns come from the case as for germline.
- **Placeholder path:** a new env var, `NEXTFLOW_QC_PLACEHOLDER_VCF`, holds its pod path. It is a pod path, not an S3 URI, because the file lives on the reference mount, not under the inputs bucket. Default: `/workspace/reference/qc/placeholder.vcf.gz`.
- **Single run:** germline and somatic rows go into the one samplesheet and the one launcher run that RAD-110 introduced.
- **Check after the run:** output collection reads the `<aliquot>.metrics.json` of each somatic aliquot (registered since RAD-180). The pipeline writes it even when it found no DRAGEN mapping metrics, with every `qc_metrics.aln_metrics` field null, so at least one non-null field is required. A case that fails is not registered and is logged at ERROR; the other cases of the run are registered. That case stays pending, so it runs again each night until its data is fixed.
- **Registration:** unchanged batch body. One `quality_control_metrics` task per somatic case, bound to the tumor aliquot, with the CRAM, its index and the tarball as `input_documents`. The placeholder is in no clinical document, so it never appears there.
- **Targeted rerun:** `task_ids` also accepts `alignment_somatic_variant_calling` ids.
- **Pipeline pin:** bumped from `v2.1.0-beta.1` to commit `77d819e` of `main`, which contains BIOINFO-243 (the DRAGEN CNV table of the report); no tag contains it yet. The launcher image takes the full SHA (`77d819e5cc141b9920511d16ba6f03010e6cf527`) and the QC batch module the short one, as for the SNV and CNV pipelines, so the tasks record `77d819e` as `pipeline_version`. A comment next to the pin says that the somatic rows rely on VCF rows not being read in DRAGEN mode.
- **Case scheduler:** no code change. It counts QC work with the QC selection, so somatic cases waiting for QC now move to `processing` like germline ones.
- **Docs:** the QC cases DAG doc (somatic path, placeholder, `no_metrics`, `task_ids`), the case scheduler doc ("QC is germline only" goes), the ETL `CLAUDE.md` line on QC, and SJRA-1879 decision 6 ("widened by RAD-132", and why the row is a placeholder VCF).

### infra

- **Placeholder file:** an empty `placeholder.vcf.gz` (0 bytes, no index) in the reference bucket at `qc/placeholder.vcf.gz`. The `prewarm-reference` CronJob copies `/workspace/reference` generically, so it needs no change. QA, then prod.
- **QC README:** lists the placeholder as a prerequisite, next to `somalier_sites`. Infra PR on explicit request only.

### bioinfo

- No change to the pipeline.
- The bioinfo team is told that we rely on the DRAGEN-mode VCF row not being read.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | pending QC query (somatic cases, tumor experiment, `no_metrics`), QC case selection (somatic rules), QC output collection (somatic metrics check), QC samplesheet (somatic `VCF` row, placeholder env var), QC cases DAG (`task_ids` doc), pipeline pin, clinical seeds, unit and integration tests, DAG docs, ETL `CLAUDE.md`, SJRA-1879 design | modified |
| infra | reference bucket (placeholder file), QC config README | new / modified |

The portal and the MCP need no change: the batch PATCH body keeps its shape, and the report is an `aggqc` document like the germline ones.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Provision the placeholder VCF | infra | Empty `placeholder.vcf.gz` in the reference bucket, README prerequisite. QA, then prod. | — | yes (nothing reads it yet) |
| 2 | Select and run somatic tumor-only cases | etl | Everything in the etl row above, in one PR: query, selection, samplesheet, env var, pin bump, seeds, tests, docs. | Task 1 | no: needs the placeholder on the mount (see Merge and rollout order) |

No UX or Labels task: nothing new is shown to users; the report is the pipeline's.

## Merge and rollout order

1. **infra** puts the placeholder on QA (Task 1). Without it, the pipeline's launch check fails on the missing `file1`, and the whole run fails, germline cases included.
2. **QA test data:** register one somatic tumor-only test case (an `alignment_somatic_variant_calling` task with a CRAM and a DRAGEN tumor-only `ssup` / `tgz` tarball, no normal experiment on the case). QA has none today: on 2026-11-03, every somatic case of the `cbtn`, `cypress` and `radiant` tenants also held a normal experiment. Without it, AC4 and AC7 cannot be checked.
3. **etl** (Task 2), deployed on QA, then checked end to end (Test strategy).
4. **infra** puts the placeholder on prod, then the etl release goes to prod.

No migration, no feature flag. No backfill: the somatic cases already in the clinical model are all pending, and the first nightly run picks them up. That first run can be large; a targeted rerun with `task_ids` on QA first bounds the risk.

## Test strategy

### etl

- **AC1:** integration test of the pending QC query on seeded somatic cases: a tumor-only case with a current alignment is selected; a draft or revoked case, a superseded alignment, a tumor-normal case, and a case that already has a `quality_control_metrics` task are not.
- **AC2:** unit test of the samplesheet: the somatic row has `VCF`, the placeholder from the env var, no `file2`, `status = 1`, `CA<case id>` and the tarball.
- **AC5 (germline part):** the same test holds a germline family; its rows are byte-identical to the RAD-110 output.
- **AC6:** unit test of the batch body: the somatic task is bound to the tumor aliquot, and its inputs hold the CRAM, the index and the tarball, never the placeholder.
- **AC8:** unit test of the selection: a somatic case without a tarball is excluded as `no_metrics`, and the reason is logged.
- **Genomic risk:** unit test of output collection with a metrics.json whose alignment metrics are all null for one somatic aliquot: that case is not collected and is logged; the other cases are.
- **AC9:** the docs are reviewed in the PR.

### QA (manual)

- **AC3:** the placeholder is on the pipeline's mount.
- **AC4, AC5:** one nightly run with a germline family and a somatic tumor-only case. The execution trace has no `SOMALIER_EXTRACT` / `SOMALIER_RELATE` task for the tumor sample, and has them for the family.
- **AC7:** the somatic report shows the DRAGEN mapping, variant calling and CNV sections, and General Status shows Aln Quality and Contamination with pass or fail.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic data: the placeholder belongs to no sample, and a missing or misplaced metrics file gives a green run with an empty report | **Missing:** a somatic case with no tarball is excluded as `no_metrics` (no fallback). **Misplaced** (a tarball without files named after the aliquot): the check after the run finds only null alignment metrics in the aliquot's metrics.json, so the case is not registered and is logged at ERROR. The placeholder is never registered, so no case document points at it. |
| Interoperability: we rely on undocumented pipeline behaviour (a DRAGEN-mode VCF row is never read and skips somalier) | A comment next to the pin and a section of the DAG doc say so. Each pin bump re-runs the QA check of AC4 (no somalier task for the tumor in the trace). The bioinfo team is told of the dependency. |

## Frozen scope

### all

- Tumor-normal cases (CRAM rows for both samples, somalier between them), including those that also carry a tumor-only analysis. Another ticket.
- Calling tasks (`tumor_only_variant_calling`, `somatic_variant_calling`) as the source of QC inputs.
- Somatic-specific QC thresholds.
- The "na" coverage status on WES (BIOINFO-245).
- A "na" sex check on an aneuploid tumor: expected, not a bug.
- Any change to the quality-control-pipeline repo.

### etl

- No CRAM-directory fallback for somatic rows.
- No check after the run for germline rows: their fallback stays logged only.
- No change to the germline rows, the germline exclusion reasons or the CRAM-directory fallback of germline members.
- No change to how outputs are registered, other than the somatic cases they now cover.

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
