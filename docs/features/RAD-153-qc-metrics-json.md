# RAD-153: Register the per-sample metrics.json of the QC pipeline

## Story

- **Link:** [RAD-153](https://ferlab-crsj.atlassian.net/browse/RAD-153) (reader: [RAD-152](https://ferlab-crsj.atlassian.net/browse/RAD-152), Quality Control tab)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-153-qc-metrics-json`

## Chosen approach

**Summary:** the QC cases DAG registers each member's `metrics.json` as a third kind of output document of the case's `quality_control_metrics` task, with the existing `aggqc` data type and the `json` format. The portal hides the `aggqc` / `json` documents from the files list and from the lab manifest, the way it hides index files, so the JSON stays an internal input of the ETL.

| Module | Approach |
|---|---|
| etl | • **Source:** quality-control-pipeline v2.0.0 publishes one `multiqc/CA<case id>/qc_json/<aliquot>.metrics.json` per sample, next to the family's report and archive ([publish rule](https://github.com/Ferlab-Ste-Justine/quality-control-pipeline/blob/v2.0.0/conf/modules.config), [file name](https://github.com/Ferlab-Ste-Justine/quality-control-pipeline/blob/v2.0.0/modules/local/multiqc_python/resources/usr/bin/multiqc_report.py)). No pipeline change and no pin bump.<br>• **Expected files:** the output collection expects, per case, the report, the archive, and one JSON per aliquot of the case's members. The file names are built from the case's own aliquots, so a JSON of any other sample under the same folder (a family member who is not in the case) is never registered.<br>• **Content:** each JSON holds its own sample's metrics and verdicts (sex check, pedigree validation) and names no other sample.<br>• **Document row:** file name, S3 URL, size from the listing, data category `genomic`, data type `aggqc`, format `json`. These are the fields of the report and archive rows today; `aggqc` and `json` already exist in the clinical reference tables.<br>• **Missing file:** a missing JSON is one more missing output. The run fails with the existing "incomplete set of outputs" error and registers nothing, as for a missing report.<br>• **Batch body:** unchanged shape. The JSON documents join the task's `output_documents` through `PATCH /{tenant}/cases/batch`.<br>• **Docs and seeds:** the QC cases DAG doc and the module docstring list the JSON as registered (they say today it is left out on purpose). The clinical seeds add one JSON document per member of the seeded QC task. The SJRA-1879 design note gets a "registered since RAD-153" line. |
| portal (backend) | • **Files list:** the existing index-file exclusion of the document search also excludes the documents with data type `aggqc` **and** format `json`. It applies to the list, its count and the name/id autocomplete, which share it. The report (`html`) and archive (`zip`) stay listed. The JSON stays downloadable by id, like the index files.<br>• **Filter values:** the documents filters endpoint lists formats and data types from the reference tables, not from the documents. "JSON File" is already listed in the format filter today and stays, so nothing changes for users.<br>• **Lab manifest:** `POST /{tenant}/case_groups/{name}/notify` lists a case group's documents from Postgres, with its own query, which keeps the index files on purpose. That query excludes the `aggqc` / `json` pair only. The document count of the email report follows.<br>• **API contract:** no new field or endpoint. No swagger or client change. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | QC output collection (expected files per case), QC cases DAG doc, clinical seeds, unit tests, SJRA-1879 design note | modified |
| portal (backend) | document search exclusion (list, count, autocomplete), case-group document listing for the lab manifest, integration tests and their fixtures | modified |

The frontend needs no change: it shows what the search returns. The MCP needs no change: it runs free SQL, and the JSON rows are visible to it with the same tenant access as the archive.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Hide the QC JSON from the files list and the manifest | portal (backend) | `aggqc` / `json` excluded from the document search, its count and autocomplete, and from the case-group document listing; integration tests with a `metrics.json` document in the fixtures | — | yes (no such document exists yet) |
| 2 | Register the per-sample `metrics.json` | etl | Expected JSON per member in the output collection, unit tests (complete set, missing JSON, JSON of a sample outside the case), DAG doc, docstring, seeds, design note | Task 1 deployed | no: needs task 1 in production first (see Merge and rollout order) |

No Labels or UX task: nothing new is shown to users.

## Merge and rollout order

1. portal backend: merge task 1 and deploy it on QA, then production.
2. etl: merge task 2 only once task 1 runs in production, then deploy on QA, then production. If the ETL ships first, every QC run adds one JSON per member to the files list and to the next manifest emailed to the labs.

No migration, no feature flag. No backfill: cases whose QC already ran keep their two documents, and a QC re-run registers a second task with the JSON. RAD-110 changes the same DAG (inputs, not outputs); whichever merges second rebases.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1, AC2:** unit test of the output collection on a listing with the report, the archive and one JSON per member: the collected documents hold the JSON rows with their name, URL, size, `genomic`, `aggqc`, `json`. The batch body test checks they are in the task's `output_documents`.<br>• **AC3:** a listing missing one member's JSON fails with the missing-outputs error, and nothing is collected for the run.<br>• **AC4:** a listing with an extra `metrics.json` of a family member who is not in the case: it is not collected.<br>• **AC5:** the DAG doc and the seeds are reviewed in the PR. |
| portal (backend) | • **AC6:** integration tests on the document search with an `aggqc` / `json` fixture document: absent from the list, the count and the autocomplete; the `aggqc` / `html` and `zip` documents still listed.<br>• **AC7:** integration test of the case-group document listing: the JSON is absent and the `crai` index stays (existing test kept).<br>• **AC8:** proven by the rollout order, not by a test. |
| QA (manual) | • One QC run on a trio in QA: three JSON documents on the `quality_control_metrics` task, none in the case's files list, none in the manifest of a test `notify` sent to a test address. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data: sex check and relatedness can reveal a non-paternity | No new exposure. The JSON holds a subset of what the MultiQC report and archive already show (per-sample sex check and pedigree verdict, no pair-level relatedness), under the same tenant and access. Unlike them, it is hidden from the files list and the lab manifest (tests in task 1, and the portal ships first). Each case gets only its own members' JSON. |
| Traceability and audit | Each JSON is an output document of the case's `quality_control_metrics` task, with the pipeline name and version of that task. |
| Interoperability: the lab manifest | The manifest query excludes only the `aggqc` / `json` pair; its columns and its other rows (index files included) do not change. The existing manifest tests stay green. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Loading the JSON into StarRocks (RAD-152, ETL story).<br>• DRAGEN capture coverage and gVCF sections in the JSON (RAD-152, nextflow story).<br>• Any change to the QC pipeline or its pin.<br>• No backfill for cases whose QC already ran.<br>• Old QLIN cases and their `QC_report.json`. |
| etl | • No new data type: the JSON reuses `aggqc`.<br>• No change to how the report and archive are registered. |
| portal (backend) | • No change to the filter values (formats and data types come from the reference tables).<br>• The JSON stays downloadable by id, like the index files.<br>• No frontend change. |

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
