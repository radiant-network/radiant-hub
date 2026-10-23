# RAD-120: Compute in-cohort CNV frequencies and expose them in the CNV occurrence API

## Story

- **Link:** [RAD-120](https://ferlab-crsj.atlassian.net/browse/RAD-120) (epic [RAD-8](https://ferlab-crsj.atlassian.net/browse/RAD-8))
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-120-cnv-cohort-frequency`

## Chosen approach

**Summary:** the ETL computes, for each distinct CNV interval of a tenant, how many patients carry a CNV that matches it at 80% reciprocal overlap, and stores the result in two new per-tenant tables keyed on `cnv_id`. The portal joins these tables to the CNV occurrences and exposes every frequency field in the list, the filters, the sort and the statistics, as it already does for the SNV frequencies.

### Matching rule

- Two CNVs match when they are on the same chromosome, in the same class, and their overlap covers at least **80% of each one's length**. This is the rule of the existing gnomAD-SV join (SJRA-779), so the platform has one definition of "the same CNV".
- Classes: `GAIN` and `GAINLOH` form one class (copy number up in both, the same pooling as the gnomAD-SV join). `LOSS` and `CNLOH` are each their own class.
- The frequency is per distinct interval (`cnv_id`), not per cluster. The relation is not transitive, so two overlapping intervals can carry slightly different frequencies. This is expected.
- Segments are compared one by one. A caller event split in several adjacent segments is not merged. Measured on qlin prod (538 samples, 78 983 segments): 0.9% of segments are candidates (same class, same copy number, both PASS, less than 10 kb apart).
- Exact-coordinate matching is not used: on a 7 151-sample DRAGEN WES set, it labels about 4 CNVs per patient as rare (<1%) when they are in ≥5% of the cohort (pre-analysis, see below).

### Data model

New tables in each `{tenant}_tenant` database, one row per distinct `cnv_id` of the matching occurrence table:

```text
 germline__cnv__occurrence / somatic__cnv__occurrence  (existing, unchanged)
          │ cnv_id
          ▼
 + germline__cnv__variant_frequency          + somatic__cnv__variant_frequency
 ┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
 │ cnv_id                     (key)     │    │ cnv_id                     (key)     │
 │ pc_wgs, pn_wgs, pf_wgs               │    │ pc_to_wgs, pn_to_wgs, pf_to_wgs      │
 │ pc_wgs_affected, … _not_affected     │    │ pc_to_wxs, pn_to_wxs, pf_to_wxs      │
 │ pc_wxs, … (same 9 for wxs)           │    └──────────────────────────────────────┘
 └──────────────────────────────────────┘
```

- `pc`: patients with at least one PASS CNV that matches the interval. `pn`: patients with at least one CNV occurrence (any filter) for that analysis type and strategy. `pf` = `pc / pn`, NULL when `pn` is 0.
- Germline: 18 columns, WGS / WXS × all / affected / not affected, with the column names of `germline__snv__variant_frequency`. No `hom` columns.
- Somatic: the `_to_` (tumor-only) columns of `somatic__snv__variant_frequency`. All somatic CNV occurrences come from tumor-only tasks today. The `_tn_` columns are added with `ALTER TABLE … ADD COLUMN` when tumor-normal CNV is ingested.
- Every interval has a row, also when none of its occurrences passes the filter (`pc` = 0). Same rule as the SNV frequencies since RAD-57.

### etl

- **Computation:** one `INSERT OVERWRITE` per table and per tenant, over all the tenant's parts. A part cannot be counted alone: a patient in one part can match an interval in another part. So there is no per-part staging table, unlike SNV.
- **Join cost:** the self-join is an equi-join on a length bucket and a position bin (9 probe keys per interval), with the overlap test as a residual. It is lossless at the 80% threshold (proven and checked against brute force in the pre-analysis). Measured: 5.4 s on 5.76 M calls from 8 464 samples.
- **Placement:** two new tasks in `import_part`, after `insert_germline_cnv_occurrences` and `insert_somatic_cnv_occurrences`, mapped per tenant like them. They are skipped with their occurrence task when the part has no CNV task. `import_part` runs one at a time, so the full recompute never runs twice at once.
- **Tables:** declared in the per-tenant table mapping. `import_radiant` creates them in each tenant database before the parts run.
- **Data QA:** dbt tests on both tables: `pf ≤ 1`, `pc ≤ pn`, and every CNV occurrence joins to exactly one frequency row.
- **Pre-analysis:** branch `docs/sjra-1786-cnv-freq`, `design/SJRA-1786-cnv-cohort-frequencies.md`. The ETL PR moves a short version of it to `design/RAD-120-cnv-cohort-frequency.md`.

### portal (backend)

- **Read path:** a `LEFT JOIN` of the frequency table on `cnv_id`, added only when the query selects, filters or sorts on a frequency field. This is the mechanism the CNV queries already use for the gene panel tables.
- **Fields:** all frequency columns, on both the germline and the somatic CNV occurrence endpoints. Each one can be selected, filtered (numerical, operator and value), sorted, and has min/max statistics. Same flags as the SNV `germline_pf_wgs*` fields.
- **Contract:** new optional response fields on the germline and somatic CNV list. Additive: swagger, TS client and Python client are regenerated.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | per-tenant table mapping, DDL of the two frequency tables, frequency insert statements, `import_part` DAG and its doc, data QA | new / modified |
| portal (backend) | CNV occurrence types and query, swagger, generated TS and Python clients, test data and seed schema | new / modified |
| mcp | none (the new tables are reachable by SQL; the prompt is not updated) | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Compute CNV cohort frequencies | etl | Table mapping and DDL, germline and somatic insert statements, two tasks in `import_part`, data QA, short design doc | — | yes (new tables, no reader yet) |
| 2 | Expose CNV frequencies in the API | portal (backend) | Frequency table and fields, conditional join, test data and seed schema, swagger and generated clients (2nd commit), integration tests | Task 1 (tables must exist in each environment) | yes once task 1 is deployed and the tables are filled |

No Labels or UX task: the frontend is out of scope.

## Merge and rollout order

1. etl: task 1 merged and deployed. The next `import_radiant` creates the tables and the next `import_part` with CNVs fills them for the tenants of that run.
2. etl (ops): fill the tables once for every tenant that has CNVs, without waiting for new data (see open questions). Until then, the frequencies are NULL in the API.
3. portal backend: task 2, after step 1 in each environment. Before that, a query that uses a frequency field fails on the missing table.

No feature flag. No migration: the occurrence tables do not change.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • StarRocks integration test of the germline insert on fixture CNVs: a match at exactly 80%, a miss just under it, a GAIN matching a GAINLOH, a LOSS not matching a GAIN, two intervals in two parts, a non-PASS carrier, a patient with two matching segments counted once (AC 1, 2, 4, 6)<br>• Same fixtures through the somatic insert (AC 3)<br>• Denominators: a patient whose CNVs all fail the filter stays in `pn`; a patient with SNVs but no CNV does not (AC 5)<br>• Data QA tests run on QA (AC 11) |
| portal (backend) | • Integration tests (testcontainers) with frequency fixtures: fields in the list, sort ascending and descending, numerical filter on list and count, min/max statistics, on germline and somatic (AC 7 to 10) |
| QA (manual) | • On qlin QA after the first fill: the known common CNVs of the cohort have a high `pf`, and the `pf` of a few CNVs is recounted by hand |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data | The gate is `filter = 'PASS'` exactly, the rule used for SNV and in the MCP prompt. The class pooling reuses the gnomAD-SV mapping. The ETL test pins both. |
| Clinical rules or interpretation | The 80% threshold and the pooling are in the story, in this plan, and pinned by boundary tests (80% matches, just under does not). |
| Interoperability | Additive fields only. Clients regenerated in the same PR. The MCP pinned client is not bumped. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Frontend (facets, columns, sort in the UI)<br>• Tumor-normal somatic CNV frequency (`_tn_` columns)<br>• Gene-level and cytoband-level CNV frequencies<br>• Merge of fragmented segments per patient<br>• gnomAD-SV frequencies unchanged |
| etl | • No quality gate beyond `filter = 'PASS'` (no `bc` floor)<br>• No split by WXS capture kit<br>• No colocation of the frequency tables with the occurrence tables (the occurrence tables are not bucketed on `cnv_id`) |
| mcp | • No tool or prompt change, no client bump |

## Open questions

| Module | Questions |
|---|---|
| etl | • **First fill:** how to compute the frequencies of the existing data without a new import? Proposal: a toolbox task that runs the two insert statements for the given tenants. Re-running `import_part` on an old part also works but swaps its partitions again. |
| story / product | • **Reviewer:** to assign. |

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
