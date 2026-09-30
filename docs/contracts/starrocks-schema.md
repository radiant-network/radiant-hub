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

## Tables

TODO: for each table read by the portal or the MCP, record its key columns, owner DAG and readers. Start with the tables touched by the next cross-module feature rather than documenting everything up front.
