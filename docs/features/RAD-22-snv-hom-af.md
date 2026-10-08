# RAD-22: Add homozygous count and approximate allele frequency to SNV occurrence frequencies

## Story

- **Link:** [RAD-22](https://ferlab-crsj.atlassian.net/browse/RAD-22)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-22-snv-hom-af`

## Chosen approach

**Summary:** the ETL counts homozygous patients next to `pc`, in the same frequency queries, and computes `af` in the variant table. The portal exposes the new columns, plus the existing `pc`/`pn`/`pf` that are not exposed yet, as plain variant fields on the SNV occurrence endpoints.

New columns along the pipeline (`+` = added, `all/aff/not` = all, affected, not affected):

```text
 germline_snv_occurrence (zygosity)               somatic_snv_occurrence (tumor_zygosity)
              │ per part                                       │ per part
              ▼                                                ▼
 germline__snv__staging_variant_frequency_part    somatic__snv__staging_variant_frequency_part    base DB
   + hom_{wgs,wxs} × all/aff/not   (6)              + hom_{tn,to}_{wgs,wxs}   (4)
              │ sum across parts                               │ sum across parts
              ▼                                                ▼
 germline__snv__variant_frequency                 somatic__snv__variant_frequency                 {tenant}_tenant
   + same 6 hom columns                             + same 4 hom columns
              └───────────────────────┬────────────────────────┘
                                      ▼ af = (pc + hom) / (2 * pn)
                      snv__variant                                                                {tenant}_tenant
                        + germline_hom_*, germline_af_*   (12)
                        + somatic_hom_*,  somatic_af_*    (8)    = 20
                                      │ v.* per variant part
                                      ▼
                      snv__variant_partitioned   + same 20 columns                                {tenant}_tenant
                                      │
                                      ▼
                      portal API, SNV occurrences: 50 fields
                        (20 new hom/af + 30 existing pc/pn/pf, of which 9 already exposed)
```

### etl

- **Count:** the two per-part frequency queries (germline and somatic) count `hom` next to `pc`: the distinct patients with zygosity `HOM` or `HEM`, with the same filters and the same cohorts as `pc`.
  - Germline: WGS and WXS × all, affected, not affected. Somatic: TN and TO × WGS and WXS, from `tumor_zygosity`.
  - The count is distinct per patient, so a patient `HOM` in one sample and `HET` in another counts once as homozygous. No extra rule.
- **Roll-up:** the two tenant frequency queries sum `hom` across parts, as they do for `pc`.
- **AF:** the variant insert computes `af = (pc + hom) / (2 * pn)` (0 when `pn = 0`), next to `pf`. Only `hom` is stored in the intermediate tables.
- **Columns:**
  - `hom` in the 4 frequency tables (6 germline, 4 somatic columns).
  - `hom` and `af` in `snv__variant` and `snv__variant_partitioned` (20 columns each).
  - Named like the existing ones: `germline_hom_wgs_affected`, `germline_af_wxs`, `somatic_hom_to_wgs`, `somatic_af_tn_wxs`.
  - Appended at the end of each table, as RAD-15 did, so the positional inserts and the `v.*` copy into `snv__variant_partitioned` stay aligned.
- **Migration:** a manual `ALTER TABLE … ADD COLUMN` script, not re-runnable. It covers the 2 staging frequency tables in the base database and the 4 other tables in every `{tenant}_tenant` database.
- **Data QA:** `af` in [0, 1] and `hom <= pc`.
- **Readers:** the portal backend (new fields) and the mcp (arbitrary SQL; its prompt is not updated).
- **Backfill:** a new optional branch in `reannotate_open_data`.
  - It reruns the per-part frequency queries for every (tenant, part), then the tenant roll-ups, before the existing `snv__variant` and variant-part rebuild.
  - The (tenant, part) list comes from the listing the DAG already uses for the variant parts.
  - **Run config:** new param `recompute_frequencies` (boolean, optional, default `false`). It also opens the `snv_variant` and `cnv_occurrence` rebuilds, so `force_reannotation` is not needed. Example: `{"recompute_frequencies": true}`.
  - Reusable for any later change to the frequency SQL.
  - Until it runs, `hom` is 0 for existing rows and `af` is too low, with no error.

### portal (backend)

- **Fields:** variant fields for the 6 cohorts and the 5 metrics (`pc`, `pn`, `pf`, `hom`, `af`), with the splits of the story. 41 are new; 9 already exist and are reused.
- **Mechanism:** the same as the existing frequency fields.
  - Selectable, filterable, sortable and numeric, so `statistics` returns their min/max.
  - Not aggregatable. Not in the default list columns.
- **Endpoints:** all 50 fields on the germline and somatic SNV `list`, `count` and `statistics`, and all 50 values in both `expanded` responses.
- **Shape of `expanded`:** flat fields with the same names as the filter fields (`germline_af_wgs_affected`, …), like the existing frequency fields. One name per value everywhere.
- **Contract:**
  - Additive, except the never-filled `af` (TODO) of the germline expanded occurrence, which is removed.
  - The OpenAPI descriptions say that `af` is approximate and that the somatic `af` is not biologically meaningful.
  - The TS and Python clients are regenerated.
- **Test copies:** the hand-made `snv__variant` DDL copies and fixtures get the new columns.
- **Unchanged:** `/variants/germline/{locus_id}/internal_frequencies` and `/global`.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | germline and somatic frequency queries (per part and per tenant), variant insert, DDL of the 6 tables, migration script, data QA on `snv__variant`, frequency integration tests, `reannotate_open_data` (new `recompute_frequencies` branch) | modified / new |
| portal (backend) | variant field definitions, germline and somatic SNV occurrence fields and types, expanded queries, OpenAPI spec, generated TS and Python clients, test DDL copies and fixtures | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Homozygous count and AF in the variant tables | etl | `hom` in the 4 frequency queries, `af` in the variant insert, DDL of the 6 tables, migration script, data QA, integration tests | — | yes, once the migration has run (new columns, no reader yet) |
| 2 | Frequency recompute branch | etl | `recompute_frequencies` param and branch in `reannotate_open_data`, DAG test, runbook line for the RAD-22 backfill | Task 1 | yes (off by default) |
| 3 | Expose the frequencies on the SNV occurrences | portal (backend) | 41 new variant fields on the germline and somatic occurrence field lists, `expanded` queries and types, removal of the unused `af`, OpenAPI descriptions, TS and Python clients, test DDL copies and fixtures, integration tests | Task 1 | yes (additive), but see rollout |

No UX task and no Labels task: the story has no UI change. The OpenAPI field descriptions are the only user-visible text.

## Merge and rollout order

1. etl: merge task 1. Run the migration on the base database and on every tenant database (QA, then prod) **before** the DAGs are deployed. Otherwise the positional inserts fail and every `import_part` breaks.
2. etl: deploy task 2, then run `reannotate_open_data` with `{"recompute_frequencies": true}` (QA, then prod). The same run backfills RAD-57. Until then, `af` is too low for existing variants.
3. portal backend: deploy task 3 after step 1 (otherwise every SNV occurrence query fails on an unknown column) and after step 2 (otherwise the API serves a wrong `af`).
4. frontend and mcp: nothing to deploy. The TS client is regenerated in task 3; the MCP pin is not bumped.

No feature flag. Later imports compute `hom` and `af` as part of `import_part`.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • StarRocks integration tests on the frequency queries, with fixtures: `HOM`, `HEM`, `HET` patients; one patient `HOM` in one sample and `HET` in another; affected and not affected; somatic TN and TO, WGS and WXS (AC 1, 2, 3).<br>• Same tests check `af = (pc + hom) / (2 * pn)`, `af = 0` when `pn = 0`, and the roll-up across parts (AC 4).<br>• The existing assertions on `pc`, `pn`, `pf` stay unchanged and pass (AC 5).<br>• Data QA: `af` in [0, 1], `hom <= pc` (AC 4). |
| portal (backend) | • Integration tests with the new columns in the fixtures: `expanded` returns the 50 values for germline and somatic (AC 7).<br>• Filter, sort and min/max statistics on a sample of the new fields, for both occurrence types (AC 8).<br>• The OpenAPI diff shows only added fields plus the removed `af`; clients regenerate (AC 9).<br>• The existing `internal_frequencies` tests pass unchanged (AC 10). |
| QA (manual) | • After the backfill: the query of AC 6 (homozygous occurrence passing the filters but `hom = 0`) returns no row, and `snv__variant_partitioned` matches `snv__variant` on the new columns.<br>• Spot check on one variant: `hom` and `af` against a manual count on the occurrences. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: the AF is an approximation; the somatic AF is not biologically meaningful | The formula, the `HEM` rule and the filters are pinned by the ETL tests. The OpenAPI description of every `af` field says it is approximate (diploid assumption), and the somatic ones say they do not account for purity, copy number or loss of heterozygosity. The UI story must carry the same warning. |
| Interoperability: 41 fields added to the API contract, clients regenerated | The change is additive except the `af` field, which was never filled and has no consumer (no frontend or MCP usage). The OpenAPI diff is reviewed in the PR. The MCP keeps its pinned client until a later bump. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No UI change and no MCP change (tools, prompt, client pin). The MCP prompt still lists only `pc`/`pn`/`pf`; the new columns are visible to its SQL.<br>• No exact sex-aware AF on chrX/chrY: `HEM` counts as 2 alleles.<br>• No `ac`/`an` columns or fields (derivable from `pc`, `hom`, `pn`).<br>• SNV only, no CNV. |
| etl | • No affected / not affected split for somatic.<br>• The existing per-patient counting is kept as is (by `patient_id`; mother and fetus are not split). A separate ticket will align it with the portal if needed. |
| portal (backend) | • `/variants/germline/{locus_id}/internal_frequencies` and `/global` are unchanged, including their on-the-fly `hom` that ignores `HEM`.<br>• The new fields are not aggregatable and not in the default list columns. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **Migration duration:** the `ALTER` on `snv__variant_partitioned` and on the staging frequency tables may rewrite data. Check its duration on QA before prod. |
| story / product | • **Reviewer:** still TBD. The story is not ready for the sprint without one.<br>• **Classification line in the story** says "three risks checked"; two are checked now. |

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
| 2026-10-08 | Task 2: `force_reannotation` would also rerun the staging-variant re-annotation and the consequences, which the backfill does not need. `recompute_frequencies` opens the `snv_variant` rebuild by itself, and the CNV rebuild too (`nb_snv` counts `snv__variant` rows, and RAD-57 changed that row set and the thresholds). | — | User, 2026-10-08 |
