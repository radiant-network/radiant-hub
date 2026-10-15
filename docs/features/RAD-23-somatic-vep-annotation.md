# RAD-23: Annotate somatic VCFs received from QLIN in Radiant

## Story

- **Link:** [RAD-23](https://ferlab-crsj.atlassian.net/browse/RAD-23)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-23-somatic-vep-annotation`

## Chosen approach

**Summary:** the ETL annotates the raw somatic SNV VCF of each calling task with the same VEP as germline, registers a `radiant_somatic_annotation` task on the case through `PATCH /{tenant}/cases/batch`, and the existing import loads it. It copies the germline post-processing automation, and runs the same Nextflow pipeline as germline from its normalization step: split multi-allelic records, then VEP.

```text
QLIN   somatic_variant_calling | tumor_only_variant_calling | alignment_somatic_variant_calling
         └─ output: raw VCF (ssnv, vcf + tbi)
                │ pending somatic annotation (case scheduler, daily)
ETL    snv-post-processing, step normalize: split multi-allelics, then VEP v114 --merged --mane
         └─ annotated VCF (ssnv, vcf + tbi)
                │ PATCH /{tenant}/cases/batch
portal radiant_somatic_annotation   input: raw VCF   output: annotated VCF
                │ existing import (unchanged)
StarRocks somatic SNV occurrences, variants, consequences
```

### etl

- **Pending detection:** a new pending query, next to the germline and CNV ones. The unit of work is the calling task, not the case. A calling task is pending when it has an output VCF with `data_type_code = ssnv` and no `radiant_somatic_annotation` task already uses that VCF as input. So a TN call and a TO call on the same tumor sample are both annotated. Only the `ssnv` VCF is selected: the `scnv` VCF of the same task is ignored. As for germline, only `completed` sequencing experiments are candidates.
- **Cases DAG:** a new cases DAG with the same steps as the germline SNV one (discover, select, generate inputs on S3, run the pipeline, collect outputs, register), without phenotypes and Exomiser. It is a separate DAG, as CNV already is, so the germline pending rule and batch body stay untouched. It has no schedule of its own: the case scheduler discovers its pending cases, moves them to `processing` and triggers it.
- **Import dependency:** the scheduled import waits for this DAG, as it already waits for the germline SNV one, success or not. The import loads the annotation task this DAG registers. Without the dependency, the import can run first, and the variants of the case only arrive with the next daily run. The CNV DAG stays outside this chain: the import does not read its outputs.
- **Run config:** the same params as the other cases DAGs. `task_ids` (array of int, optional, restricts the run to these calling tasks, e.g. `[70]`), `excluded_tenants` (array of str, optional, default `$RADIANT_ETL_EXCLUDED_TENANTS`), `dry_run` (boolean, optional, default `false`, validates the batch without persisting).
- **Annotation engine:** `snv-post-processing`, through the existing Nextflow launcher, with `step = normalize` and `tools = vep`. The run splits multi-allelic records and left-aligns indels on the reference, as for germline, then runs VEP. No genotyping, slivar or Exomiser. The loader skips multi-allelic records, so without the split those variants would be lost.
  - Same pipeline revision as germline, so the same VEP image, cache, flags and CSQ fields: v114, merged cache, `--merged --mane`. The launcher image pins the revision, and a pipeline bump applies to both.
  - Samplesheet: one row per calling task, with the raw VCF in the `vcf` column. The calling task id is the pipeline's `familyId`, so it names the output `ensemblvep/variants.<id>.snv.vep.vcf.gz` and its `.tbi`.
  - The launcher reads a second params set for this run (see infra). The germline params are not touched.
- **Registration:** one `radiant_somatic_annotation` task per calling task.
  - Aliquots: the same as the calling task (tumoral, plus normal for tumor-normal). The portal derives `task_context` from them, so the TO/TN classification of the import and of the portal is unchanged. An annotation from `alignment_somatic_variant_calling` is always tumor-only: the portal accepts one aliquot on that task type.
  - `input_documents`: the raw `ssnv` VCF. `output_documents`: the annotated VCF and its index, `ssnv`, `vcf` and `tbi`. The loader reads the `.tbi` next to the VCF.
  - `pipeline_name` / `pipeline_version`: `snv-post-processing` and its revision, as for germline. The revision pins the VEP version.
- **Import:** no change. It already loads the `vcf` output of a `radiant_somatic_annotation` task. The CSQ parser is shared with germline and already handles the merged cache and MANE.
- **Seeds:** the somatic seeds follow the new contract: calling tasks with a raw `ssnv` VCF output, no QLIN annotation task, and `completed` somatic experiments (they are `submitted` today).

### infra

- **Params set:** a second SNV params ConfigMap, next to the germline one, for the somatic run: `step = normalize`, `tools = vep`, and the same reference, VEP cache, cache version, genome and `vep_annotation = merged` values as germline. QA, then prod.
- The VEP cache and the pipeline image already exist on the Nextflow file system and in the registry mirror. Nothing else is added.

### portal (backend)

- No change. The batch PATCH only adds tasks to an existing case, accepts two aliquots on `radiant_somatic_annotation`, and accepts an input document that is already in the database. The case's task picker already defaults to the newest somatic annotation task.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | pending somatic annotation query, new cases DAG, Nextflow launcher (choice of params set), batch body and expected outputs for somatic, case scheduler (discovery, trigger, import order), clinical seeds, DAG docs | new / modified |
| infra | Nextflow SNV params: a second params set for the somatic run (QA, then prod) | new |
| bioinfo | none (existing `normalize` step) | — |
| portal (backend) | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Somatic params set | infra | Second SNV params ConfigMap (`step = normalize`, `tools = vep`, germline VEP values), QA then prod | — | yes (nothing uses it yet) |
| 2 | Somatic annotation cases DAG | etl | Pending query, cases DAG, launcher run with the somatic params, somatic batch body and outputs, seeds on the new contract, DAG docs | Task 1 | yes (manual trigger only) |
| 3 | Schedule it | etl | Case scheduler: discovery of pending somatic cases, trigger, the import waits for it (like germline SNV), rediscovery | Task 2 | yes |

No Labels or UX task: nothing user-visible changes in the portal.

## Merge and rollout order

1. infra: task 1 on QA. Without the somatic params set, the DAG fails on its first run.
2. etl: tasks 2 and 3, deployed to QA. From then on, a somatic case with a raw `ssnv` VCF and no annotation is annotated by the next daily run.
3. QLIN: stops sending `radiant_somatic_annotation`, types the raw VCF `ssnv`, and adds it to `alignment_somatic_variant_calling`. If QLIN changes before step 2, new somatic cases have no annotation and no variants.
4. QA backfill, by hand: the QLIN annotation tasks of existing cases are removed. The portal has no delete endpoint, so this is done in SQL on the clinical database. The cleanup of the old data is already handled outside this plan.
5. Same steps on prod.

No feature flag. The somatic pending query only matches the new contract, so cases sent the old way are left as they are.

## Test strategy

| Acceptance criterion (from the story) | How it is proven |
|---|---|
| **AC1:** a case with a somatic calling task that has an `ssnv` VCF output and no `radiant_somatic_annotation` task is detected as pending. | etl: integration test of the pending query on the clinical seeds. A TN and a TO calling task with an `ssnv` VCF are pending. |
| **AC2:** when the annotation completes, a `radiant_somatic_annotation` task is registered with the raw VCF as input, the annotated VCF and its index as outputs (`ssnv`, `vcf` + `tbi`), and the annotation pipeline name and revision in `pipeline_name` and `pipeline_version`, as for germline. | etl: unit tests of the batch body (input, outputs, data types, pipeline name and revision). |
| **AC3:** with several VCF outputs (`ssnv` and `scnv`), only the `ssnv` VCF is annotated. | etl: same integration test as AC1. The `scnv` VCF of the TO calling task is never selected. |
| **AC4:** the variants loaded into StarRocks come from the annotated VCF of the task registered by Radiant. | etl: the existing somatic import tests, with a fixture annotated by VEP v114 merged.<br>QA (manual): one TN and one TO case through the scheduler, variants loaded. |
| **AC5:** a variant in a germline case and in a somatic case annotated by Radiant has the same transcripts (Ensembl + RefSeq, MANE) and consequences. | QA (manual): one shared variant compared in StarRocks. |
| **AC6:** the annotation task carries the same samples as the calling task, so the TO/TN classification is unchanged; an annotation from `alignment_somatic_variant_calling` is tumor-only. | etl: unit tests of the batch body (aliquots copied from the calling task, one aliquot for `alignment_somatic_variant_calling`).<br>QA (manual): the TN and TO cohorts of the somatic frequencies are the same before and after the backfill. |
| **AC7:** a case that already has a `radiant_somatic_annotation` task is not annotated a second time. | etl: same integration test as AC1. A calling task whose VCF is already the input of an annotation task is not pending. |
| **AC8:** a calling task with no `ssnv` VCF, or whose VCF cannot be found, creates no annotation task and an error names the task and the URL. | etl: integration test of the pending query (exclusion reason for a calling task without `ssnv` VCF) and unit test of output collection (missing output fails the run, nothing registered). |

The manual QA checks run on the `cypress` tenant. Its somatic tasks are reorganized to the new contract (calling tasks with a raw `ssnv` VCF, no QLIN annotation task), then reprocessed.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data | Same VEP version, cache and CSQ fields as germline: the run uses the same pipeline revision. Checked by AC5 on QA. Multi-allelic records are split before VEP, as for germline. The split also drops records with no alternate allele in any genotype: the record counts before and after are compared on QA. |
| Clinical rules or interpretation | Consequences may change for variants already interpreted on QA. The backfill is manual and case by case, on QA first. |
| Traceability and audit | The registered task links the raw VCF (input) to the annotated VCF (output), and carries the engine and its version. |
| Interoperability | The QLIN contract change is a rollout step, after the ETL is deployed. Old-style cases are not touched. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Automatic backfill of existing cases.<br>• Somatic CNV, SV and fusions.<br>• Rejecting `radiant_somatic_annotation` tasks still sent by QLIN.<br>• Tumor-normal on `alignment_somatic_variant_calling` (single aliquot in the portal). |
| etl | • No change to the import or the CSQ parser.<br>• No re-annotation when the VEP version changes later. |
| portal | • No change to the API, the validation or the UI. No delete endpoint for tasks. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **Reviewer:** not assigned yet. |

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
