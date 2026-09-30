# Contract: StarRocks schema

**Owner:** etl. DDL in `etl/radiant/dags/sql/{clinical,open_data,radiant}/init/`. Table-name mapping in `etl/radiant/tasks/data/radiant_tables.py`.
**Readers:** portal backend (`portal/backend/internal/repository/starrocks/`), mcp (arbitrary SQL under the user's JWT, plus `_lookup_parts()`).

## Databases

- **Shared DB**: open data, the clinical model and cross-tenant tables.
- **Per-tenant DB** `{tenant}_tenant` (template `RADIANT_TENANT_DB_TEMPLATE`): the tables in `STARROCKS_RADIANT_PER_TENANT_MAPPING`:
  `exomiser`, `germline__snv__occurrence`, `germline__cnv__occurrence`, `germline__snv__variant_frequency`, `snv__variant`, `snv__variant_partitioned`, `somatic__snv__occurrence`, `somatic__cnv__occurrence`, `somatic__snv__variant_frequency`.

Readers must resolve the tenant DB the same way the ETL does. Moving a table between shared and per-tenant is a breaking change for every reader.

## Partitioning

- Occurrence tables, `exomiser` and `snv__consequence_filter_partitioned` use `PARTITION BY (part)`.
- `snv__variant_partitioned` uses `PARTITION BY (variant_part)`, where `variant_part = part // 10` (`compute_part` in `etl/radiant/dags/import_part.py`).
- The MCP mirrors this computation in `radiant_api_tools.py`. Changing the `10` breaks it.

## Enum dictionaries: three copies that must stay in sync

| Where | Role |
|---|---|
| `etl/radiant/data_qa/macros/dictionaries.sql` | Data QA "Values Contained In Dictionary" tests. They fail when upstream data brings a new value. |
| `portal/backend/internal/repository/starrocks/facets.go` | Facet values the backend exposes. |
| `portal/frontend/translations` | Labels for those values. |

Adding a value means changing all three in the same feature.

| Dictionary | Values | Column |
|---|---|---|
| `dict_cosmic_tier` / `cmc_tier` | `'1'`, `'2'`, `'3'`, `'Other'` | `snv__variant.cmc_tier`, from `cosmic_mutation_set[_hgvs].tier` (SJRA-1990) |

## Tables

TODO: for each table read by the portal or the MCP, record its key columns, owner DAG and readers. Start with the tables touched by the next cross-module feature rather than documenting everything up front.

### `cosmic_mutation_set`, `cosmic_mutation_set_hgvs` (shared DB)

- **Owner DAG:** `import_cosmic_mutation_set` (DDL `open_data/init/cosmic_mutation_set*_create_table.sql`). A broker load from S3, not an Iceberg source: `reannotate_open_data` cannot detect a refresh, so a forced re-annotation is needed after each import.
- **Keys:** `cosmic_mutation_set` on `locus_id`, one row per locus. `cosmic_mutation_set_hgvs` on `(transcript_id, cds_change)`, transcript without its version, for the mutations that coordinates cannot place. The two never overlap.
- **Readers:** etl only, `snv_staging_variant_insert.sql` and `snv_staging_variant_reannotate.sql` (SJRA-1990). The portal reads the denormalised `cmc_*` columns of the variant tables, not these tables.
- **Columns read:** `locus_id` / `transcript_id` + `cds_change` (join keys), `mutation_url`, `sample_mutated`, `sample_ratio`, `tier`. Not read: `shared_aa`, `cosmic_id`, `sample_tested`.

### `snv__staging_variant` (shared DB), `snv__variant`, `snv__variant_partitioned` (per tenant): CMC columns

Appended at the end of the three tables by SJRA-1990 (manual migration `etl/radiant/dags/sql/radiant/migrations/SJRA-1990_snv_variant_add_cmc.sql`). The column order must stay identical: `snv_variant_part_insert_part.sql` copies `v.*`.

| Column | Type | Source | Readers (API alias) |
|---|---|---|---|
| `cmc_mutation_url` | VARCHAR(255) | `mutation_url` | portal backend (`cmc_mutation_url`) |
| `cmc_sample_mutated` | INT | `sample_mutated` ("CMC") | portal backend (`cmc_sample_mutated`) |
| `cmc_sample_ratio` | DOUBLE | `sample_ratio` (`sample_mutated / sample_tested`) | portal backend (`cmc_sample_ratio`) |
| `cmc_tier` | VARCHAR(8) | `tier`, dictionary `dict_cosmic_tier` | portal backend (`cmc_tier`) |

Rule: from `cosmic_mutation_set` when the locus is there; otherwise all four from `cosmic_mutation_set_hgvs`, matched on `(v.transcript_id, v.dna_change)` of the picked consequence (broadcast join); otherwise `NULL`.
