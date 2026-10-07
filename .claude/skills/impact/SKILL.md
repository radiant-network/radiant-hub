---
name: impact
description: Find everything that depends on a cross-module item (StarRocks table or column, enum value, portal API endpoint or field, partitioning rule, JWT claim) and what breaks if it changes. Use for "what are the impacts of renaming / removing / changing X?", and during feature analysis (feature-spec, cross-module-feature) to check that no boundary between modules breaks.
---

# Impact

The dependencies between modules are not written down anywhere: they are computed from the code each time, so they cannot go stale. This skill lists **where** each module declares them. Update it only when a module changes where it declares them (a new folder, a new generated client), not for each feature.

Do not change code. The output is a report.

## 1. Pin down the item and the change

- **Item:** a table, a column, an enum value, an API endpoint or field, the partitioning rule, a JWT claim or permission.
- **Change:** rename, remove, type change, new value, or a change of meaning (what `NULL` means, a unit, a ratio vs a percentage). A change of meaning breaks nothing at compile time: say so.

## 2. Search every module

- Run `make status`. A module that is not checked out goes in the report as **not checked**. Never report "no impact" for it.
- `make status` also shows each module's branch. Search what is checked out, then say whether the hits are on `main` or only on an open branch (`git -C <module> grep … origin/main`, `gh pr list`): changing an item that is not merged yet is cheaper, because nothing is deployed.
- Search every spelling: `snake_case` (SQL, JSON, Python), `CamelCase` (Go), `camelCase` (TS). For `cmc_tier`: `cmc_tier`, `CmcTier`, `cmcTier`.
- Use `git -C <module> grep -n -I -e … -- ':!*.lock' ':!*lock.json'`. It skips `node_modules` and build output.
- For a wide search, use one Explore agent per module. Check every `file:line` yourself before you report it.

Where each module declares each kind of dependency:

### StarRocks table or column (writer: etl)

| Module | Where | Note |
|---|---|---|
| etl | `radiant/dags/sql/**/init/*_create_table.sql` | The DDL. Search all of it: a column is often copied down a chain of tables (`snv__staging_variant` → `snv__variant` → `snv__variant_partitioned`, which copies `v.*` and needs the same column order). |
| etl | `radiant/dags/sql/**/*.sql` | Writers and readers, through `{{ mapping.starrocks_<table> }}`. |
| etl | `radiant/tasks/data/radiant_tables.py` | Table names, and the shared vs per-tenant split. |
| etl | `radiant/dags/sql/radiant/migrations/` | Tables that already exist need a manual migration, run on the shared DB and on every `{tenant}_tenant` DB. |
| etl | `radiant/data_qa/sources/*.yml`, `macros/dictionaries.sql`, `tests/` | Data QA and tests. |
| portal backend | `backend/internal/types/*.go` | `Table{Name: …}` (with `PerTenant`) and `Field{Name: …}`: the columns the API reads. `Field.Name` is the column, `Field.Alias` (defaults to `Name`) is the name the API filters, sorts and aggregates on, and the struct's `json` tag is the response field. Setting `Alias` lets a column change name without changing the API. |
| portal backend | `backend/internal/repository/starrocks/*.go` | Queries, `facets.go`. |
| portal backend | `backend/test/data/sql/<table>.sql`, `backend/test/data/*/<table>.tsv`, `backend/scripts/init-sql/init_starrocks.sql` | **Hand-made copies of the ETL DDL** and fixtures. They don't fail when the ETL changes: they drift. |
| mcp | `radiant_mcp/*.py` | SQL written in code. |
| mcp | `librechat-local/agent-*.md`, `README.md`, `docs/` | **LLM prompts that describe tables and columns.** A rename breaks the agent's SQL without any error. |

When the column is exposed by the API, continue with the API section.

### Enum value

Three copies must stay in sync: `etl/radiant/data_qa/macros/dictionaries.sql` ↔ `portal/backend/internal/repository/starrocks/facets.go` ↔ `portal/frontend/translations/common/{en,fr}.json`. Also check the MCP prompts.

### Portal API endpoint or field (owner: portal backend)

The swaggo annotations generate `portal/backend/docs/swagger.yaml` (`make doc`). Consumers:

| Consumer | Where | Caught by |
|---|---|---|
| frontend | Generated `frontend/api/api.ts` (`make generate-client-typescript`), then the usages in `frontend/apps/**` and `frontend/components/**`. Field names also appear as string literals (filter lists, table settings) and as translation keys. | TS compile for typed usages, nothing for the string literals. |
| mcp | `radiant_python` is pinned to a portal commit in `mcp/pyproject.toml`; usages in `radiant_mcp/radiant_api_tools.py`; `CASE_SEARCH_FILTER_FIELDS` / `CASE_SEARCH_SORT_FIELDS` copy the backend's `CanBeFiltered` / `CanBeSorted`. | Nothing until the pin is bumped. |
| etl | Hand-written client `radiant/tasks/nextflow/portal.py` and `batch.py` (`PATCH /{tenant}/cases/batch`). | Nothing. |
| other | `cypress/`, `postman/`, user docs `docs/` (Docusaurus). | Cypress only. |

### Partitioning and tenant split

- `variant_part = part // 10`: `compute_part` in `etl/radiant/dags/import_part.py` ↔ `_VARIANT_PART_DIVISOR` in `mcp/radiant_mcp/radiant_api_tools.py`.
- A table moving between the shared DB and `{tenant}_tenant`: `STARROCKS_RADIANT_PER_TENANT_MAPPING` (etl) ↔ `PerTenant` in the portal types ↔ the MCP prompts.

### Nextflow pipeline output (writer: bioinfo)

A file or field produced by `bioinfo/snv-post-processing`, `bioinfo/cnv-post-processing` or `bioinfo/quality-control-pipeline`, or a pipeline revision bump. Readers: the ETL operators and tasks (`etl/radiant/dags/operators/k8s.py`, `etl/radiant/tasks/nextflow/**`). The revision is pinned twice: `*_PIPELINE_REV` in `etl/Dockerfile.nextflow.launcher` and `ANNOTATION_PIPELINE` in `etl/radiant/tasks/nextflow/{,cnv/}batch.py`. If the `bioinfo/*` repo is not checked out, say so and read the pinned revision on GitHub (`gh --repo Ferlab-Ste-Justine/<repo>`).

### Identity

Keycloak claims, roles and permissions: portal backend (authorization), MCP (passes the JWT through), StarRocks (validates the JWT), and `infra/*` if checked out (read only).

## 3. Classify each hit

1. **Breaks:** fails at compile time or at runtime.
2. **Silent:** nothing fails, but the result is wrong: LLM prompts, DDL copies and fixtures, the hand-written ETL client, string literals, translations, the pinned client. List these first: that is where boundaries break without anyone noticing.
3. **Must change with it:** tests, fixtures, migrations, docs.
4. **History only:** merged specs in `docs/features/`, changelogs. Don't edit.

Then list what the search cannot see: modules not checked out, SQL built by string concatenation, `SELECT *` / `v.*` that depend on column order, and deployed state (existing rows, the frontend and the MCP running an older version during rollout).

## 4. Report

1. One line: the change, the modules impacted, the number of silent impacts.
2. One table per module: `file:line` | what | category (1–4).
3. The order of changes and the rollout: migration on each DB, then ETL → portal backend → regenerated clients → frontend and MCP. Say what breaks between two steps, and whether the change needs a compatibility window (e.g. keep the old column or field until the readers move).
4. Not checked.

Add a Mermaid diagram (writer → item → readers) when more than two modules are impacted, or when the user asks for one.

In a feature analysis (`feature-spec`), run this for each boundary item the spec changes. The results feed the spec's **Modules impacted**, **Merge and rollout order** and **Risks and coverage** sections. Don't paste the full report into the spec.
