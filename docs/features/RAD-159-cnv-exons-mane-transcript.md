# RAD-159: Show the MANE Select RefSeq transcript of each gene in the CNV overlapping genes

## Story

- **Link:** [RAD-159](https://ferlab-crsj.atlassian.net/browse/RAD-159)
- **Assigned reviewer:** Karl Ritchie
- **Status:** Draft
- **Branch (all repos):** `feat/rad-159-cnv-exons-mane-transcript`

### Acceptance criteria

Copied from the story on 2026-11-10, so that `AC1`… below still mean the same thing if the story is renumbered. Case 1000032 (qlin, exome 25354), gain chr9:114,323,130-114,330,584.

- **AC1:** the ORM1 row of the overlapping genes shows `NM_000607.4`.
- **AC2:** ORM1 shows # Exons 6, counted on `NM_000607.4`, in the table and in the CNV profile gene panel. *The gene panel part is deferred.*
- **AC3:** a gene with no MANE Select transcript shows `-` as its RefSeq transcript, in the table or in the track. *The track part is deferred.*
- **AC4:** with MANE 1.4 and Ensembl 114 loaded, the data QA finds every Ensembl 114 MANE Select transcript with its RefSeq id (no transcript version mismatch).

## Chosen approach

**Summary:** OpenDataLake publishes the NCBI MANE summary as a new contract table. From it and the Ensembl transcripts, the ETL builds one StarRocks table that gives each gene its reference transcript, as the story defines it: MANE Select, else Ensembl canonical. The portal counts the overlapped exons on that transcript and shows its RefSeq id in the CNV overlapping-genes table. The CNV profile gene track (RAD-156, RAD-157) is out of this story: see the deviation log.

### opendatalake (radiant-open-datalake)

- **Source:** the MANE summary file of a release, `MANE.GRCh38.v<release>.summary.txt.gz` ([release 1.4](https://ftp.ncbi.nlm.nih.gov/refseq/MANE/MANE_human/release_1.4/)). One row per MANE transcript, `MANE Select` or `MANE Plus Clinical` ([README](https://ftp.ncbi.nlm.nih.gov/refseq/MANE/MANE_human/release_1.4/README.txt)).
- **Release match:** MANE 1.4 is built on Ensembl 114 ([README_versions](https://ftp.ncbi.nlm.nih.gov/refseq/MANE/MANE_human/release_1.4/README_versions.txt)). MANE is a manual source, like Ensembl: the download is triggered with `version=1.4`.
- **Contract:** new table `mane_v1`, faithful to the file: one row per MANE transcript, both statuses kept. The versioned ids (`ENST00000263100.8`, `NM_130786.4`) are split into id and version, so they join `ensembl_transcript_v1` on `transcript_id` and `version`. The RefSeq id is also kept whole, as cited in a report.
- **Integration point:** a new contract in the contract registry, with its release notes, next to the four Ensembl contracts.

### etl

- **Sources:** two new contract sources in `import_open_data`, in the gene group: `ensembl_transcript_v1` (already published, carries `is_canonical` and `is_mane_select` from the GFF3 tags, see its [release notes](https://github.com/radiant-network/radiant-open-datalake/blob/main/spark/doc/release-notes/ensembl_transcript/v1.md)) and `mane_v1`. Both follow the import gates of the other contract sources. No pre-contract table: held back, they read nothing, as `clinvar_rcv`. They are read from the Iceberg catalog and not copied to StarRocks: only the table below has a reader.
- **Reference transcript:** a new shared table `gene_reference_transcript`, one row per Ensembl gene: `ensembl_gene_id`, `ensembl_transcript_id`, `ensembl_transcript_version`, `is_mane_select`, `refseq_transcript_id`. The transcript is the MANE Select one, else the Ensembl canonical one. `refseq_transcript_id` comes from the `mane_v1` row with the same transcript id and version and the status `MANE Select`; it stays NULL otherwise. In the [Ensembl 114 GFF3](https://ftp.ensembl.org/pub/release-114/gff3/homo_sapiens/), every gene has exactly one canonical transcript, and each of the 19,276 MANE Select transcripts is the canonical one of its gene; all of them have a MANE 1.4 row with the same version. ORM1: `ENST00000259396.9`, 6 exons, `NM_000607.4`.
- **Rebuild:** the table is rebuilt in full (insert overwrite) after the import of either source, in the gene group of `import_open_data`. The portal reads only this table, so the rule lives in one place.
- **Data QA:** two dbt tests on `gene_reference_transcript`. One fails when a row has `is_mane_select` true and no `refseq_transcript_id`: it catches a MANE release that does not match the Ensembl release. The other fails when an `ensembl_gene` gene has no row: it catches an Ensembl release with a gene that has no canonical transcript.
- **No re-annotation:** the data is gene-level and read at query time. No occurrence table changes.

### portal (backend)

- **Integration point:** the exon lookup of `genes_overlap` (`cnvGenesOverlapSQL`, germline and somatic) joins `gene_reference_transcript` on `ensembl_gene_id` and keeps the exons whose `transcript_ids` hold the reference transcript. It builds on `main`, with no dependency on RAD-156.
- **Exon count:** `nb_exons` counts the exons of the reference transcript that the CNV overlaps. It replaces today's count of every distinct exon over all the gene's transcripts (ORM1: 10, then 6).
- **No reference transcript:** a gene with no row in `gene_reference_transcript` gets `nb_exons` 0. No gene of Ensembl 114 is in that case, and the data QA reports one if a later release brings it.
- **New field:** `refseq_transcript_id` (string, nullable, versioned, e.g. `NM_000607.4`) on the `genes_overlap` rows. Null when the gene has no MANE Select transcript.
- **Contract:** additive optional field. Swagger, TS client and Python client regenerated. The `nb_exons` value changes; it stays a required integer.

### portal (frontend)

- **Overlapping genes table:** a RefSeq column next to # Exons, `-` when the gene has no MANE Select transcript. The # Exons tooltip says it counts on the MANE Select transcript, else on the Ensembl canonical one.
- **Labels:** EN and FR for the column and the tooltip.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| opendatalake | MANE source config and download, `mane_v1` normalizer, contract registry, release notes | new |
| etl | open-data import (two new sources), `gene_reference_transcript` table and build, data QA | new / modified |
| portal (backend) | CNV gene overlap, test fixtures, seed schema, swagger, generated TS and Python clients | modified |
| portal (frontend) | CNV overlapping-genes table, EN/FR labels | modified |
| mcp | none: no tool reads the gene overlap | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | MANE contract | opendatalake (Jira `etl`) | Manual source with version, `mane_v1` normalizer, contract entry, release notes, unit spec | — | yes (no reader yet) |
| 2 | Reference transcript of each gene | etl | Two contract sources, `gene_reference_transcript` DDL and build, data QA test, integration tests | Task 1 | yes, once `mane_v1` is published |
| 3 | Exon count and RefSeq on the reference transcript | portal (backend) | `genes_overlap` on the reference transcript, `refseq_transcript_id`, fixtures, seed schema, swagger and clients, tests | Task 2 | yes, once task 2 has loaded |
| 4 | RefSeq in the overlapping genes | portal (frontend) | RefSeq column, # Exons tooltip, EN/FR labels, unit tests | Task 3 | yes, once task 3 is deployed |

No Labels task: one short label and one tooltip, validated in the task 4 PR. No UX task: the column follows the existing ones.

## Merge and rollout order

1. opendatalake: merge task 1, then trigger the MANE download and import with `version=1.4`, QA then prod. Without `mane_v1`, the ETL has nothing to load and every RefSeq stays empty.
2. etl: check that the ETL's StarRocks account can read `ensembl_transcript_v1` and `mane_v1` in the OpenDataLake catalog, in each environment: no ETL job reads them today, and Ranger refuses them to a user account on QA. Otherwise the build fails. Then merge task 2. Run `init_starrocks_tables` (new table), then `import_open_data`. Then run the data QA. Before this step, the backend of step 3 fails on the missing table.
3. portal backend: deploy task 3 after step 2 in the same environment.
4. portal frontend: deploy task 4 after step 3.

No migration of an existing table, no backfill, no feature flag. A later Ensembl release must come with its matching MANE release; the data QA reports a mismatch.

## Test strategy

### opendatalake

- **AC4:** unit spec of the normalizer on sample summary rows: ids and versions split, both statuses kept.

### etl

- **AC1, AC3:** StarRocks integration test of the `gene_reference_transcript` build on fixtures: a gene with a MANE Select transcript gets its RefSeq id; a gene with only an Ensembl canonical transcript gets that transcript and no RefSeq.
- **AC4:** same fixtures with a MANE row of another transcript version: no RefSeq id, and the first dbt test fails. A fixture gene without a canonical transcript fails the second one. Both run on QA after the load and pass with MANE 1.4 and Ensembl 114.

### portal (backend)

- **AC1, AC2:** integration test of `genes_overlap` on an ORM1-like fixture: a non-reference transcript adds exons, `nb_exons` counts only those of the reference transcript, `refseq_transcript_id` is returned.
- **AC3:** a gene without MANE Select returns a null `refseq_transcript_id`.

### portal (frontend)

- **AC1, AC3:** unit tests of the RefSeq cell: the id, or `-` when empty.

### QA (manual)

- **AC1, AC2:** case 1000032 (qlin, exome 25354), gain chr9:114,323,130-114,330,584: ORM1 shows `NM_000607.4` and # Exons 6 in the overlapping genes table.
- **AC3:** one overlapping gene without MANE Select (a non-coding gene) shows `-`.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: the MANE version must match the Ensembl release (1.4 ↔ 114) | The join uses the Ensembl transcript id and version, so a mismatched release gives no RefSeq id rather than a wrong one. The dbt test reports every MANE Select transcript left without one. |
| Interoperability: a new external source through OpenDataLake | MANE follows the Ensembl mechanism: manual source with a typed release, versioned raw prefix, contract table with release notes, import gates in the ETL. |

## Frozen scope

### all

- RefSeq ids of transcripts outside MANE.
- Display of MANE Plus Clinical (kept in `mane_v1`, not shown).
- Link to the NCBI page of the transcript (deferred).
- RefSeq in the SNV tables (deferred).
- The CNV profile gene track (deferred, see the deviation log): the RefSeq id in the gene details on hover or selection, the gene panel part of AC2 and the track part of AC3. Backend side, `GET /{tenant}/genes/track` draws the exons of the reference transcript.
- An Ensembl release without its matching MANE release: the RefSeq id stays empty and the data QA reports it.

### portal (frontend)

- No somatic CNV view: the portal has none.

## Open questions

### etl

- Which Ensembl release does prod load? QA loads `ensembl_gene_v1` and `ensembl_exon_by_gene_v1` at release 114 (`open_data_release`, 2026-11-03). Prod is not verified: check its `open_data_release` before the MANE download.

## Approval

| | |
|---|---|
| Reviewer | Karl Ritchie |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| 2026-11-10 | The gene track (`GET /{tenant}/genes/track`, RAD-156) exists only in an open draft PR, behind `main`, and RAD-157 has no PR: tasks 3 and 4 could not ship. Scope cut to the overlapping genes table and `genes_overlap`. Deferred: the RefSeq id in the gene details (removed from the story), the gene panel part of AC2 and the track part of AC3. When RAD-156 lands, its gene track should count on `gene_reference_transcript` instead of the transcript with the most exons. | Follow-up ticket for the gene track (to create) | Karl Ritchie, … |
