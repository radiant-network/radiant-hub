# RAD-315: Load the gene coverage of germline and tumor-only alignments into StarRocks

## Story

- **Link:** [RAD-315](https://ferlab-crsj.atlassian.net/browse/RAD-315) (part of [RAD-152](https://ferlab-crsj.atlassian.net/browse/RAD-152), Quality Control tab)
- **Assigned reviewer:** Jeremy
- **Status:** Draft
- **Branch (all repos):** `feat/rad-315-gene-coverage`

## Chosen approach

**Summary:** `import_part` loads the DRAGEN `coverage_by_gene` CSV (`covgene` document) of each current alignment of the part into a new per-tenant table `gene_coverage`, with the same parsing and gene name rule as QLIN. The import finds the file through the existing current-alignment view, and StarRocks reads it with a broker load, as for Exomiser.

### etl

- **Source:** the `covgene` output document of the experiment's `alignment_germline_variant_calling` or `alignment_somatic_variant_calling` task. The `covgene` data type already exists in the clinical reference tables. In tumor-normal, the tumor has no alignment task of these two types (its calling task is `somatic_variant_calling`), so only the normal gets rows.
- **Discovery:** `import_part` takes the experiments of the part, finds the newest alignment of each type in the `current_alignment` view, and its `covgene` document. No change to the staging view, the delta or the task model: the proband with a slivar VCF and the tumor-normal normal outside a germline case keep their coverage. A re-alignment replaces the old coverage.
- **Load:** the operator reads the header line from S3, then a StarRocks broker load with the column list of that format writes into a new shared staging table `raw_gene_coverage`, tagged with the tenant. A per-tenant insert then applies the gene name rule, with a join on `ensembl_gene`. This is the model of the Exomiser load.
- **Two DRAGEN formats:** the header tells them apart, as in QLIN ([`CoverageByGene.scala`](https://github.com/Ferlab-Ste-Justine/clin-variant-etl/blob/master/src/main/scala/bio/ferlab/clin/etl/normalized/CoverageByGene.scala)): 14 columns with `type` in the new format, 13 without it in the old one. New format: only the `type = CDS` rows are kept. Old format: every row is CDS.
- **Gene name rule:** as in the story. `_chrX` / `_chrY` suffix gives `symbol` without the suffix and `chromosome` `X` / `Y`. An `ENSG…` name gives `symbol` = `ensembl_gene.name` matched on `gene_id`, else the ENSG id. A plain symbol keeps its name, with `chromosome` from `ensembl_gene` matched on `name`. `gene` keeps the raw name. `ensembl_gene.chromosome` has no `chr` prefix (the CNV inserts join it on the VCF chromosome without `chr`).
- **New table `gene_coverage`** (per tenant): the story's columns, plus `part` for the partition swap. One row per (`seq_id`, `task_id`, `symbol`, `chromosome`). No reader today: the API story will add it.
- **Idempotence:** the load replaces the rows of each alignment task it loads, through the partition swap of the part (copy the other tasks' rows, then insert), as for Exomiser. An alignment shared by two cases is loaded once per task, not once per case.
- **No file:** an alignment without `covgene` is skipped and the run stays green.
- **Unreadable file:** one bad file does not stop the others. The load goes on with the next file, and the part gets the rows of every file that loaded. The alignment of a bad file has no rows until a later run loads it. After the inserts, the gene coverage task fails and lists the S3 path and the error of each bad file. The gene coverage tasks are not upstream of the other loads of `import_part`, so their failure blocks no other data.
- **Migration:** a new migration file creates `raw_gene_coverage` in the base database and `gene_coverage` in each tenant database, with an upgrade note. No change to an existing table.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | `import_part` DAG and its doc, StarRocks load of the coverage file, per-tenant table mapping, init DDL and migration, upgrade note, clinical seeds, tests | new / modified |

The portal and the MCP need no change. No reader of `gene_coverage` exists yet: in the portal and the MCP, `covgene` is only a document data type.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Load the gene coverage of each alignment | etl | DDL and migration, file discovery, two-format load, gene name rule, partition swap in `import_part`, DAG doc, upgrade note, seeds (one `covgene` document per format), unit and integration tests | — | yes (new table, no reader) |

No Labels or UX task: nothing is shown to users.

## Merge and rollout order

1. etl: run the migration in each tenant database, then deploy. Without the table, every part with a `covgene` file fails.
2. etl: QA check on the dev cases with the old format (16774..16776, 21305, 25354), re-submitted by hand.

No feature flag. No backfill: cases already loaded are re-submitted by hand (out of scope).

## Test strategy

### etl

- **AC1, AC2 (germline and tumor-only loaded):** integration test of `import_part` on seeded alignment tasks of both types, each with a synthetic `covgene` CSV: one row per CDS gene.
- **AC3 (tumor-normal):** seeded tumor-normal case: rows for the normal's alignment only.
- **AC4 (both formats):** one synthetic file per format; the new-format file also holds UTR and lncRNA rows, which are not loaded.
- **AC5, AC6 (PAR and ENSG names):** fixture rows `SHOX_chrX`, `SHOX_chrY`, a known ENSG id and an unknown one, against seeded `ensembl_gene` rows.
- **AC7 (no duplicates):** an alignment shared by two cases, and the same part imported twice: same row count.
- **AC8 (missing and unreadable file):** an alignment without `covgene` gives no row and a green run; in a part with one good file and one file with a broken header, the good file's rows are loaded, the other loads of the part succeed, and the gene coverage task fails with the bad file's S3 path in the error.

### QA (manual)

- **AC4 (real files):** one old-format case in dev. The new format exists only in QLIN case 50859 (not in dev): check it once QLIN sends a new-format file to QA.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: two DRAGEN formats, PAR and ENSG gene names | The format is read from the header of each file, never from a batch. The integration tests cover both formats, the PAR suffix and the ENSG resolution. |

## Frozen scope

### all

- API and UI (separate stories).
- Exon-level coverage and QC metrics (RAD-153).

### etl

- Non-CDS rows (UTR, lncRNA, clinvar…).
- No correction of PAR genes in the old format (one row, capped at 50%).
- No RefSeq coordinates (QLIN PR #579 adds them; the story leaves them out).
- No backfill of cases already loaded.
- The symbol is resolved at load time: an Ensembl refresh does not re-resolve rows already loaded.

## Open questions

### etl

- **Plain symbol on more than one chromosome in `ensembl_gene`:** the match on `name` can return several rows (not verified on the current release). Proposal: keep one row, the first by `chromosome`, like the QLIN dedup.
- **Delta trigger:** an alignment's `covgene` loads only when its experiment is in the import delta. A file added later to an already loaded alignment waits for the next change of the experiment. Proposal: accept (backfill is out of scope).

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
