# RAD-39: Show compound heterozygous variants for germline SNV occurrences

## Story

- **Link:** [RAD-39](https://ferlab-crsj.atlassian.net/browse/RAD-39)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-39-comphet`

## Chosen approach

**Summary:** the ETL reads the pairs that slivar already wrote in the VCF (`slivar_comphet`), stores them in a new per-tenant table `germline__snv__comphet`, and adds a per-gene summary to each occurrence. The portal shows the summary in the variant table, adds a boolean facet, and lists the partners of a variant on click.

### Data model

**Iceberg.** The VCF pass writes one new table next to the occurrences. The Iceberg occurrence table does not change: its init drops and recreates it, so the summary columns live in StarRocks only.

```text
 germline_snv_occurrence  (existing, unchanged)       + germline_snv_comphet  (new)
 ┌──────────────────────────────────────┐             ┌──────────────────────────────────────┐
 │ part, task_id         (partitions)   │             │ part, task_id         (partitions)   │
 │ seq_id, aliquot, tenant_code         │             │ seq_id, tenant_code   sample, tenant │
 │ locus_hash            the variant    │◀────────────│ locus_hash            the variant    │
 │ zygosity, calls, …                   │             │ partner_locus_hash    other variant  │
 └──────────────────────────────────────┘             │ symbol                gene of pair   │
                                                      └──────────────────────────────────────┘
          │ existing occurrence insert                          │ new pair insert
          │ locus_hash → locus_id (snv_tmp_variant)             │ both hashes → locus_id (snv_tmp_variant)
          ▼                                                     ▼
       StarRocks                                            StarRocks
```

- Same partitions as the occurrences (`part`, `task_id`), so a re-imported task overwrites its pairs in the same commit step as its occurrences.
- Hashes, not ids: `locus_id` is assigned in StarRocks. The partner hash uses the same locus key as every other source.
- `tenant_code` lets the per-tenant insert keep only its tenant's rows, as the occurrence and Exomiser inserts do.

**StarRocks.** New table and new columns (`+`), in each `{tenant}_tenant` database:

```text
 germline__snv__occurrence  (existing, one row per sample × variant)
 ┌───────────────────────────────────────────────┐
 │ part, seq_id, task_id, locus_id   (key)       │
 │ zygosity, symbol, …               (existing)  │
 │ + has_comphet     BOOLEAN                     │  facet
 │ + comphet_genes   [{symbol, nb}]              │  "BRCA2 (2)" in the table
 └───────────────────────────────────────────────┘
          │ same part, seq_id, task_id
          │ locus_id = the variant
          ▼
 + germline__snv__comphet  (new, one row per sample × variant × partner × gene)
 ┌───────────────────────────────────────────────┐
 │ part, seq_id, task_id   same sample and task  │
 │ locus_id                the variant           │
 │ partner_locus_id        the other variant     │  click on "2" lists these
 │ symbol                  gene of the pair      │
 └───────────────────────────────────────────────┘
```

Example: the proband (`seq_id` 7) carries V1, V2 and V3 in BRCA2. Slivar pairs V1 with V2 and with V3.

| Table | Rows |
|---|---|
| `germline__snv__comphet` | (7, V1, V2, BRCA2), (7, V2, V1, BRCA2), (7, V1, V3, BRCA2), (7, V3, V1, BRCA2) |
| `germline__snv__occurrence` | V1: `has_comphet` true, `comphet_genes` [BRCA2 (2)]. V2 and V3: true, [BRCA2 (1)] |

Each pair is stored in both directions, because slivar tags both variants. A `comphet_genes` count is the number of rows of the pair table for that variant and gene.

### etl

- **Source:** the INFO tag `slivar_comphet` of the germline SNV VCF. Each value names the sample, the gene and the partner variant (`sample/gene/pair_id/chrom/pos/ref/alt`, see the [slivar wiki](https://github.com/brentp/slivar/wiki/compound-heterozygotes)). The partner locus is the other variant of the pair.
- **Parsing:** during the existing VCF pass, which already writes three tables. Keep the entries of each progeny sample. Hash the partner with the same locus key as every other source.
- **Pairs:** a new Iceberg table `germline_snv_comphet` (see the data model), written by the same pass. Then a new per-tenant StarRocks table `germline__snv__comphet` (`part`, `seq_id`, `task_id`, `locus_id`, `partner_locus_id`, `symbol`). The partner `pos` is the 1-based VCF POS and the chromosome carries the `chr` prefix (checked on a real trio VCF), so the partner is hashed exactly like a record. Both locus ids are resolved through `snv_tmp_variant`, as the occurrence and Exomiser inserts do. Loaded with the partition swap used for Exomiser, keyed by task like the occurrences.
- **Summary on the occurrence:** two nullable columns appended to `germline__snv__occurrence`: `has_comphet` (BOOLEAN: true with a pair, false without, NULL for occurrences imported before the migration) and `comphet_genes` (`ARRAY<STRUCT<symbol VARCHAR(200), nb INT>>`, one entry per gene, ordered by symbol, NULL without a pair). They are filled by the occurrence insert, which left-joins the per-variant, per-gene partner counts of the StarRocks pair table, as it already left-joins Exomiser. The pair table is therefore loaded before the occurrences, and the count is built from the same rows the click lists. The Iceberg occurrence table does not change.
- **No candidate column.** Confirmed vs candidate is derived from the family structure (story decision).
- **Data QA:** both variants of every pair exist in the tenant's occurrences of the same sample and task. No check of the `comphet_genes` counts: it would recompute the insert's own aggregation on the same table; the integration test pins the counts.
- **Readers:** the portal backend (new). The mcp sees both through SQL; its clinical agent prompt is not updated.

### portal (backend)

- **Fields:** `has_comphet` is selectable, filterable and aggregatable, like the somatic `hotspot` boolean. `comphet_genes` is selectable, returned in the list.
- **Partner filter:** a new filterable sqon field on the pair table (for example `comphet_of`). Its value is the `locus_id` of the clicked variant. The backend keeps the occurrences whose `locus_id` is a `partner_locus_id` of that variant for the same sample. No locus conversion is needed. The field (`comphet_of`) is an array: a LEFT JOIN of the sample's pairs grouped by partner (`array_agg(locus_id)`, one row per occurrence, so nothing is duplicated) and the filter `array_contains(ch.comphet_of, ?)`. A second semi-join was not possible: the whole sqon is rendered in the consequence semi-join `ON` clause. The same join is added in the list, count, aggregate and statistics queries, so the facets follow the filter.
- **Gene:** the existing `symbol` filter (a consequence in that gene).
- **Contract:** additive. OpenAPI, TS and Python clients regenerated. The test DDL copies, the local docker DDL and the multi-tenant test loader get the new columns and table.

### portal (frontend)

- **Column:** a new germline SNV column that lists `GENE (n)`, reusing the existing list cells.
- **Click on `n`:** opens a **new query** in the query bar, with two pills: the existing `symbol` pill with the gene, and the new partner pill. The partner pill sends the clicked variant's `locus_id` (already on the row) and shows its locus (`1-1000-A-G`, truncated, full value in the tooltip) through the pill's existing display override (`overrideValuesName`). The backend ignores that display field. The active query is left unchanged. The query builder can add an empty query, but has no action that adds a pre-filled one; a small one is added.
- **Facet:** `has_comphet` in the Occurrence group, the first boolean facet of the occurrence pages.
- **Status:** the column shows the pairs as candidates when the case is not a complete trio. The rule is computed from the case entity already loaded by the page: the proband's mother and father both have a sequencing experiment. No trio helper exists today; one is added.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | germline SNV VCF processing, new Iceberg table and its init task, table mappings, new StarRocks table (DDL, insert, copy-partition), occurrence DDL and insert, `import_part` task order, migration script, data QA | new / modified |
| portal (backend) | germline SNV occurrence fields and type, new partner field and its join in the SNV occurrence query builders, OpenAPI spec, generated TS and Python clients, test DDL and fixtures, local docker DDL | new / modified |
| portal (frontend) | germline SNV table settings and a new cell, germline SNV aggregations config, trio helper, EN/FR translations | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Load the compound-het pairs | etl | Parse `slivar_comphet`, new Iceberg table and its init, new StarRocks table with insert and copy-partition, `import_part` wiring, data QA on the pairs, tests | — | yes (new tables, no reader) |
| 2 | Compound-het summary on the occurrence | etl | `has_comphet`, `comphet_genes` (DDL, migration), occurrence insert joins the pair counts, pair insert ordered before the occurrence insert in `import_part`, data QA on the counts, tests | Task 1 | yes, once the migration has run |
| 3 | Expose compound hets in the API | portal (backend) | Two occurrence fields, partner sqon field (`locus_id` of the clicked variant, join on the pair table in the four query paths), OpenAPI, clients, test DDL and fixtures, tests | Task 2 | yes (additive), but see rollout |
| 4 | Labels | portal (frontend) | EN/FR: column header and tooltip, facet label, candidate vs confirmed wording. Validated by the clinical team | — | yes |
| 5 | Compound-het column, facet and click | portal (frontend) | Column and cell, boolean facet, trio helper, click opens a new query with the `symbol` and partner pills, partner pill label | Tasks 3, 4 | yes once 3 is deployed |

A UX task is needed: how the cell shows several genes and the candidate status, and how the partner pill reads.

## Merge and rollout order

1. etl: task 1, then run **only** the init task of the new Iceberg table. The other init tasks drop and recreate their tables. Without it, the VCF processing fails on a missing table. The new StarRocks table is created per tenant by the next `import_radiant` run.
2. etl: task 2. Run the migration (`ALTER TABLE … ADD COLUMN`, every `{tenant}_tenant`) **before** the DAGs are deployed. Otherwise the positional occurrence insert fails and every `import_part` breaks.
3. portal backend: task 3, after step 2 in each environment. Otherwise every germline SNV occurrence query fails on an unknown column.
4. portal frontend: tasks 4, then 5.

No feature flag and no backfill: cases imported before step 2 have no compound hets until they are re-imported (story out of scope). Their `has_comphet` is empty, so the facet ignores them.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • Unit tests on the tag parsing with a slivar VCF fixture: trio, duo, solo, two genes for one variant, no tag, other sample's entries ignored (AC 1, 7).<br>• StarRocks integration tests: pair table filled with resolved ids, summary counts per gene, re-import of a task replaces its pairs (AC 1, 8).<br>• Data QA: every variant and partner of a pair is an occurrence of the same sample (AC 8). |
| portal (backend) | • Integration tests: `comphet_genes` in the list, `has_comphet` aggregation and filter, partner filter alone returns exactly the partners of the variant, with `symbol` exactly those of the gene; it also narrows count and aggregations; a `locus_id` with no pair returns no row (AC 2, 3, 4). |
| portal (frontend) | • Vitest: cell rendering (several genes, empty), trio helper (trio, duo, solo), click opens a new query with both pills, the partner pill sends the `locus_id` and shows the locus (AC 2, 3, 5, 6). |
| QA (manual) | • One trio and one duo on QA: counts, click results, candidate wording (AC 2 to 6).<br>• One real case compared with QLIN, shared with the geneticists (story risk). |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: dependency on the `slivar_comphet` format and on its gene symbol | The parser tests pin the format on a real pipeline output. A malformed entry is logged and skipped, not fatal. The partner is joined on the shared locus key, so a key mismatch shows up in the data QA (orphan partner). Slivar takes the gene from the VEP `SYMBOL` (checked in task 1). |
| Clinical rules or interpretation: fewer compound hets than QLIN, different confirmed/candidate rules | The candidate wording is validated in the Labels task. The QLIN comparison on a real case is a release gate (QA row). The frequency filters slivar applies are an open question to the bioinfo team. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No change to the pipeline or to slivar's filters.<br>• No backfill or re-import of loaded cases.<br>• No compound hets in the variant entity page, the side panel, the expanded occurrence or the MCP prompt.<br>• No sort by number of compound hets.<br>• Somatic and CNV occurrences. |
| etl | • No change to the transmission mode or the parental origin (separate story). |

## Open questions

| Module | Questions |
|---|---|
| etl | • ~~**Gene field**~~: answered in task 1, slivar writes the VEP `SYMBOL` (checked on a real trio VCF).<br>• ~~**Sample names**~~: answered in task 1, the slivar sample is the VCF sample column, i.e. the aliquot the pedigree maps. |
| portal (backend) | • ~~**`comphet_genes` shape**~~: answered in task 3, the driver returns JSON that `JsonArray[ComphetGene]` reads (tested on a real `ARRAY<STRUCT>` column). |
| portal (frontend) | • **Saved filters:** the partner pill shows the locus only if a saved filter keeps the pill's display override. Otherwise a reloaded filter shows the raw `locus_id`. Check in task 5. |
| story / product | • **Reviewer:** TBD. The story is not ready for the sprint without one.<br>• **Frequency filters in slivar** (open question in the story, for the bioinfo team).<br>• **Facet values:** boolean (story) or none / confirmed / candidate? |

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
