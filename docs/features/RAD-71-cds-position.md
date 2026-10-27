# RAD-71: Import the CDS position of each SNV consequence

## Story

- **Link:** [RAD-71](https://ferlab-crsj.atlassian.net/browse/RAD-71) (parent: [RAD-70](https://ferlab-crsj.atlassian.net/browse/RAD-70), automatic ACMG classification)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-71-cds-position`

## Chosen approach

**Summary:** the ETL reads VEP's `CDS_position` from the CSQ of each SNV VCF and stores it in two new nullable integer columns of `snv__consequence`: `cds_start` and `cds_end`. In every environment, a migration adds the columns in place and a re-import from the VCFs fills the consequences already loaded, with no downtime for users. Nothing reads the columns yet: the ACMG classifier (RAD-70) will.

| Module | Approach |
|---|---|
| etl | • **Source:** the SNV post-processing pipeline already lists `CDS_position` in the VEP CSQ fields. The ETL's CSQ extraction does not read it today.<br>• **Values:** VEP's [`CDS_position`](https://www.ensembl.org/info/docs/tools/vep/vep_formats.html) is a position or a range, counted on the coding sequence from the first base of the start codon. It is split into two columns:<br>&nbsp;&nbsp;◦ `123` (SNV) gives `cds_start` = `cds_end` = 123.<br>&nbsp;&nbsp;◦ `123-125` (indel) gives 123 and 125.<br>&nbsp;&nbsp;◦ `?-125` or `123-?` (indel partly outside the CDS) keeps the known end; the other one is NULL.<br>&nbsp;&nbsp;◦ An empty value (intron, UTR, non-coding transcript, intergenic) gives NULL and NULL.<br>• **Insertions:** VEP gives the two bases on each side of the insertion point, not the inserted bases (a 1-base dup reads `7235-7236`). Each column has a StarRocks comment that says so.<br>• **Extraction:** the field joins the CSQ columns resolved once per file, with the same case-insensitive lookup. A VCF whose header has no `CDS_position` loads with NULL values. A value of any other shape gives NULL and is counted in one warning per file, like the unclassified transcript sources. It never fails an import. Germline and somatic share the extraction, so both get the columns.<br>• **Iceberg:** two optional integer fields in the `snv_consequence` schema. The Iceberg writer takes its schema from the live table, so the table must be recreated before the new code runs: a manual run of the Init Iceberg Tables DAG drops and recreates the Iceberg tables. Their content is temporary, so nothing loaded is lost. Against the old table, the values are dropped with no error and the StarRocks load then fails on the missing column.<br>• **StarRocks:** `cds_start` and `cds_end` (`INT NULL`) are appended at the end of `snv__consequence`, after `dna_change`. The import from Iceberg and the weekly re-annotation (`reannotate_open_data`) are both positional inserts, so both add the two columns at the end. The re-annotation reads the columns back from the table itself.<br>• **Migration:** a manual migration script in `radiant/dags/sql/radiant/migrations/` (`RAD-71_snv_consequence_add_cds_position.sql`: `ALTER TABLE … ADD COLUMN`, one column at a time, each placed explicitly after the previous one) adds the columns in place on the shared database. It is a metadata-only change: existing rows read NULL, and users see no change. The init DDL gets the same columns for new deployments. Dropping and recreating the table is not an option: the init DDL is `CREATE TABLE IF NOT EXISTS`, and a full reload of a production takes 1 to 2 weeks.<br>• **Re-import:** a re-import of every experiment fills the existing rows. `snv__consequence` is a primary-key table, so each consequence is replaced in place, with its values unchanged except the two new columns.<br>• **Duplicates:** a transcript listed twice for one locus in a VCF carries the same value, and the primary key keeps one row. Across VCFs annotated with different VEP versions, the last import wins. This is accepted. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | SNV CSQ extraction (germline and somatic), Iceberg `snv_consequence` schema, StarRocks `snv__consequence` DDL and migration, consequence import and re-annotation statements, unit and integration tests, data QA (dbt) | modified |

The portal backend and the MCP read `snv__consequence`, but neither needs a change. The backend selects named columns only, and the MCP runs free SQL.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Import the CDS position | etl | CSQ parsing of `CDS_position`, Iceberg schema, two columns in the StarRocks DDL, migration script `RAD-71_snv_consequence_add_cds_position.sql`, both positional inserts, unit and integration tests, dbt tests on the new columns | — | yes (new nullable columns, no reader yet) |

No Labels or UX task: nothing changes on screen.

## Merge and rollout order

1. etl: merge task 1.

Then in each environment, QA first, then production:

2. Iceberg: run the Init Iceberg Tables DAG by hand, with no import running, to drop and recreate the Iceberg tables. If skipped, the values are dropped at extraction and the StarRocks load fails.
3. StarRocks: run the migration on the shared database, then deploy the ETL right after, with no import or re-annotation running. Both inserts are positional: between the two steps, an old insert fails against the new table, and a new insert fails against the old one.
4. Trigger a re-import of every experiment. In production it takes 1 to 2 weeks, so it is planned with CHOP. Until a locus is re-imported, its consequences have NULL in both columns. Nothing reads the columns yet, so users see no change. During the backfill, data QA does not fail the run because of the new columns: `snv_consequence__should_not_contain_only_null` skips `cds_start` and `cds_end` (`except:` in `snv_consequence.yml`), and `snv_consequence__validate_cds_position_on_coding_terms_RAD-71` reports the rows not yet re-imported as known errors.
5. Once every environment is re-imported, open a follow-up PR in the etl that removes `cds_start` and `cds_end` from that `except:` list and the `_RAD-71` suffix from the coding-terms test, so both tests guard the columns again.

No feature flag. The re-import is the backfill.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1, AC3:** unit tests on the extraction, with the existing test VCFs (germline, somatic, merged Ensembl/RefSeq): a coding consequence gets its position; an intronic, UTR or non-coding one gets NULL.<br>• **AC2:** unit tests on every shape of the value, plus indel, insertion and duplication records copied from a VEP 114 merged VCF of NA12878 (public reference sample).<br>• **AC4:** a VCF whose CSQ header has no `CDS_position` imports, with NULL in both columns.<br>• **AC1, AC6:** the existing StarRocks integration test of the consequence import checks that the columns arrive in the right positions. The re-annotation render test still passes. |
| etl (dbt) | • **AC5:** every consequence with a coding SO term (missense, synonymous, stop gained or lost, start lost, frameshift, inframe, protein altering, coding sequence variant…) has a `cds_start` or a `cds_end`.<br>• `cds_start <= cds_end` when both are set.<br>• NULL on consequences with only intronic, UTR, up/downstream or intergenic terms. |
| QA (manual) | • **AC5:** after the QA re-import, 100 consequences (SNVs and indels, Ensembl and RefSeq) compared with `CDS_position` read directly from their VCF.<br>• **AC6:** after the migration, and again after the re-import, the variant page's consequence section shows the same data as before. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: new VEP field | The value is copied from VEP as is, with no derivation. Deriving it from `dna_change` was ruled out: VEP 3'-shifts HGVSc by default ([`--shift_hgvs`](https://www.ensembl.org/info/docs/tools/vep/script/vep_options.html)), as [HGVS requires](https://hgvs-nomenclature.org/stable/recommendations/general/) ([den Dunnen et al. 2016, doi:10.1002/humu.22981](https://doi.org/10.1002/humu.22981)), but not `CDS_position`. On a sample VCF, 38 of 46 coding indels disagree (e.g. `c.194del` vs `184`). The dbt coverage test and the QA comparison check the result. |
| Genomic formats or data: backfill of the existing consequences | A re-import from the VCFs, the same code path as a normal import, in place and with no downtime. Every VCF, in QA and in production, already carries `CDS_position`. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • The PVS1 computation and the rest of the ACMG classifier (RAD-70).<br>• Other VEP fields (`Protein_position`, `Amino_acids`). `aa_change` already holds the HGVSp.<br>• Any change to the SNV post-processing pipeline. |
| etl | • No CDS position in the `snv__consequence_filter*` tables.<br>• No check that all VCFs were annotated with the same VEP version.<br>• The raw VEP string is not kept. |
| portal (backend) | • No API field. Its hand-made copies of the `snv__consequence` DDL (test schema, seed schema) stay without the new columns until a story reads them. |
| mcp | • No change to the agent prompts: they do not describe `snv__consequence` columns today. |

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
