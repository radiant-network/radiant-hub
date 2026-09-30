# Contract: Portal API

**Owner:** portal backend.
**Source of truth:** `portal/backend/docs/swagger.yaml`, generated from swaggo annotations with `make doc` in `backend/`.

## Consumers

| Consumer | How | Regenerate after an API change |
|---|---|---|
| Portal frontend | Generated TS client in `portal/frontend/api/` (never edit by hand) | `make generate-client-typescript` in `portal/` |
| MCP | Generated `radiant_python` client (`portal/cli/python/`), caller's JWT as Bearer | `make generate-client-python` in `portal/`, then bump it in `mcp/` |
| ETL | Hand-written client in `etl/radiant/tasks/nextflow/portal.py`: `PATCH /{tenant}/cases/batch` and a poll on the batch | Manual. Check `etl/radiant/tasks/nextflow/batch.py` builds a body the API still accepts |

## Known coupling

- The MCP hard-codes the case search filter and sort aliases (`CASE_SEARCH_FILTER_FIELDS` / `CASE_SEARCH_SORT_FIELDS`), which mirror `CanBeFiltered` / `CanBeSorted` in the backend's `CasesFields`.
- The MCP looks up `part` in StarRocks until the API returns `part` per task. Once it does, remove `_lookup_parts()`.
- The ETL's service account needs portal permissions for the batch PATCH. A valid token alone still returns 403.
