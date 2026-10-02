# RAD-10: Filter variants by gene panels

## Story

- **Link:** [RAD-10](https://ferlab-crsj.atlassian.net/browse/RAD-10)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-10-filtered-variants-by-gene-panels`

## Chosen approach

**Summary:** the portal API owns the tenant panels, in the existing Postgres `panel` tables. The ETL attaches the clinician's `.tsv` to one upload call. A per-tenant StarRocks MV feeds a new SNV facet.

| Module | Approach |
|---|---|
| portal (backend) | • **Storage:** reuse the existing Postgres tables `panel` and `panel_has_genes`. No new table, no migration.<br>&nbsp;&nbsp;◦ `panel` is already tenant-scoped, with a unique code per tenant (case-insensitive).<br>&nbsp;&nbsp;◦ `panel_has_genes` requires an Ensembl ID for each gene (part of its primary key).<br>• **Upload endpoint:** `POST /{tenant}/gene_panels` takes the `.tsv` file as a `multipart/form-data` attachment. The API parses the file, checks it, then creates **new panels** for all the panels of the file, in one transaction.<br>• It never changes an existing panel: a code that already exists in the tenant gives 409, and nothing is written.<br>• **Why an attachment:** all the parsing and checks are in one place, the API. Later, a user can upload the same file from the browser to the same endpoint, with no S3 step.<br>• **Checks:** a bad layout, a bad `panel_code`, an empty or a duplicate symbol give 400.<br>• **Symbols:** the API resolves each symbol to its Ensembl ID against `ensembl_gene`, with the gene search that the "upload a gene list" facet already uses. Unmatched symbols are returned as warnings and skipped. `strict=true` rejects the file (422).<br>&nbsp;&nbsp;◦ **Access:** the lookup runs as the caller, with the existing ETL role (see open questions). Not with the admin connection.<br>• **Authorization:** a tenant-scoped action, not decided yet (see open questions).<br>• **Read endpoint:** `GET /{tenant}/gene_panels` returns the code and name of each panel, for the facet labels.<br>• **StarRocks MV:** a per-tenant async MV `{tenant}_tenant.gene_panel_mv(code, name, symbol)` over `panel` and `panel_has_genes`, through the existing `radiant_jdbc` catalog. The API refreshes the MV after each write.<br>&nbsp;&nbsp;◦ **Access:** the API creates and refreshes the MV with the portal's admin StarRocks connection (root pool), never with the caller's JWT. The backend already does this to create StarRocks users. So the caller (ETL account or user) needs no StarRocks privilege on the MV.<br>• **Filter:** a new SQON field `tenant_gene_panel` plugs into the existing gene panel join on the consequence symbol, like HPO and OMIM. One table and one field, no new query code. Germline and somatic SNV. |
| etl | • **Load path:** the operator puts the clinician's `.tsv` in an S3 prefix. A new Airflow DAG `import_tenant_gene_panel` reads the file and attaches it, unchanged, to **one `POST` per file**.<br>• **Client:** the generated `radiant_python` client, pinned to a portal SHA. It supports `multipart/form-data`.<br>• The DAG does not parse or check the file. It logs the warnings that the API returns.<br>• **Retries:** `POST` is not idempotent. If the API commits the panels but fails to refresh the MV, a retry gets 409. The DAG fails on 409 and does not retry it. The operator checks the panels with `GET /gene_panels`. |
| portal (frontend) | • **Facet:** lists only the panels with hits in the case, from the existing aggregate. No dictionary padding for this facet.<br>• **Labels:** the facet shows the panel name (from `GET /gene_panels`) and sends the code. |
| mcp | • Bump the client SHA. The new MV is visible to its SQL. |
| infra | • S3 prefix with Airflow read access.<br>• QA Airflow runtime for `radiant_python` (see open questions). |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | new DAG `import_tenant_gene_panel` and its runbook, `radiant_python` dependency, Airflow connection to the portal API | new |
| portal (backend) | panel repository, TSV parser, `gene_panels` routes, tenant MV and its Ranger policy, SNV gene panel fields, OpenAPI spec, generated clients | new / modified |
| portal (frontend) | germline and somatic SNV facet config, multiselect facet (code → name labels), EN/FR translations | modified |
| mcp | client SHA bump, prompt doc | modified |
| infra | S3 prefix + Airflow read access, QA Airflow runtime for `radiant_python` | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | MV and Ranger | portal (backend) | MV per tenant over `panel` / `panel_has_genes` (at tenant creation and with `refresh-tenants`), refresh after write, both with the admin connection; Ranger read policy on the MV | — | yes |
| 2 | Upload and read API | portal (backend) | `POST` with the file attachment (tenant-scoped action, see open questions), TSV parser and checks, symbol resolution, body size limit, create all panels in one transaction (409 on an existing code); `GET /gene_panels`; OpenAPI + clients | Task 1 | yes (additive) |
| 3 | SQON field | portal (backend) | `tenant_gene_panel` for germline and somatic SNV (filter and aggregate), accepted only with `TENANT_VIEWS_READ_ENABLED=true` | Task 1 | yes (additive) |
| 4 | Infra | infra | S3 prefix + Airflow read access, QA Airflow runtime (see open questions) | — | yes |
| 5 | DAG | etl | Read each file from S3, attach it to one `POST`, log the warnings, `radiant_python` pinned to the merged task 2 SHA, runbook | Tasks 2, 4 | yes once 2 is deployed |
| 6 | Labels | portal (frontend) | EN/FR facet label and tooltip, validated by the clinical team | — | yes |
| 7 | Facet | portal (frontend) | Facet `tenant_gene_panel` in germline and somatic, code → name labels | Tasks 2, 3, 6 | yes once 2 and 3 are deployed |
| 8 | MCP | mcp | Bump client SHA, prompt doc | Tasks 2, 3 | yes |

No specific UX task: the facet reuses the existing multiselect facet.

## Contract changes

| Contract | Change | Writer | Readers | Migration / compatibility |
|---|---|---|---|---|
| API: `/{tenant}/gene_panels` | New `POST` (`multipart/form-data`, one `.tsv` file part, `strict` param; creates the panels of the file, 409 if a code exists; tenant-scoped action to decide). New `GET` (code, name, gene count) | portal backend | etl (`radiant_python`, pinned SHA), portal frontend, mcp | Additive. First file upload endpoint of the API. ETL consumer row in `portal-api.md` changes |
| Postgres `panel`, `panel_has_genes` | New writer: the upload endpoint. No DDL change | portal backend | portal backend (case filters, analysis catalog), MV | Insert only. Existing rows, prescription panels included, never change |
| Gene panel file format | TSV, UTF-8, header row. Columns `panel_code`, `panel_name`, `symbol`, optional `ensembl_id`. One row per gene, many panels per file | clinicians (via the operator) | portal backend (parser) | New contract doc. The API owns the format |
| API: germline and somatic SNV `list`, `count`, `aggregate` | New SQON field `tenant_gene_panel`, values are panel codes | portal backend | portal frontend, mcp | Additive |
| StarRocks `{tenant}_tenant.gene_panel_mv` | New per-tenant async MV `(code, name, symbol)` over `radiant_jdbc` | portal backend | portal backend, mcp | Created by `refresh-tenants` for existing tenants. A later change to the MV needs a drop and a re-create |

## Merge and rollout order

1. infra: S3 prefix and Airflow read access. Check the prod StarRocks version (QA runs 4.0.11).
2. portal backend: tasks 1 to 3. Then run `refresh-tenants` with Ranger credentials, so that every tenant has its MV and policy. Without the MV, the filter fails with "unknown table".
3. ops: provision the ETL account in StarRocks and Ranger with `create-user -sub` (see open questions). Without it, the upload fails at the symbol lookup.
4. etl: task 5, pinned to the merged backend SHA. **Reverse of the usual order**: the ETL calls the API, so the API comes first.
5. portal frontend and mcp: tasks 6, 7, 8, after step 2 in each environment.

No migration, no backfill. No feature flag: the facet is empty until a panel is loaded. Keep `TENANT_VIEWS_READ_ENABLED=true` where the field is exposed.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1 (load):** tests on the parser and on a multipart upload: each check, one transaction per file, unmatched symbols skipped and reported, 409 on an existing code with nothing written.<br>• **AC2 (filter):** StarRocks integration tests on a fixture: one and several codes, combined with a public panel, `not-in`, a panel with no hit is absent from the facet, unknown code gives 0 rows. Germline and somatic.<br>• **AC3 (persistence):** tenant isolation tests. |
| etl | • DAG unit test: the file is attached unchanged. |
| QA (manual) | • Load a panel, filter on two cases (AC2, AC3).<br>• MV query plan, two parallel uploads for one tenant.<br>• The panel filter plan has the same shape as the OMIM filter. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| A panel visible to another tenant | Panels are tenant-scoped, MV per tenant, route checks the tenant. Isolation tests |
| A file loads partly | One `POST` per file, one transaction. Test: a failure on panel N writes no panel |
| A file changes an existing panel (prescription panels included) | `POST` only creates. An existing code gives 409. Test on a prescription panel code |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • SNV only: no CNV filtering.<br>• No disaster recovery: no versioned S3 archive, no replay of the archived files. Recovery relies on the Postgres backup only.<br>• No self-service panel management. |
| portal (backend) | • No panel update or delete: no `PATCH`, `PUT` or `DELETE` route. A new version of a panel needs a new code.<br>• No change to the `panel` and `panel_has_genes` tables.<br>• No alias resolution: a previous HGNC symbol stays unmatched until the operator fixes the file. |
| portal (frontend) | • No browser upload in this story. The endpoint is ready for it, but there is no UI.<br>• No UI to browse panels, no download of the `.tsv` files. |
| etl | • No delete or replay mode in the DAG.<br>• The hand-written ETL portal client does not change. Moving it to `radiant_python` is a separate ticket. |
| mcp | • No new MCP tool. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **Story rule on S3:** the story asks the operator to archive the raw `.tsv` in S3 for DR. With DR out of scope, the S3 file is only the DAG input. Update the story?<br>• **Panel file:** is there a sample file? Do clinicians already use stable panel codes?<br>• **Ownership:** who maintains the panels, and how often? Facet label in EN/FR?<br>• **Panel versions:** with no update, a changed panel needs a new code (for example `EPILEPSY_V3`). Old versions stay in the facet. Is this acceptable until an update or delete story? |
| portal (backend) | • **Unmatched symbols:** `panel_has_genes` requires an Ensembl ID, so a symbol that is not in `ensembl_gene` is skipped. Accept this, or add a migration to keep all symbols? Proposal: skip and report.<br>• **Panel type:** which type (`virtual` or `physical`) do uploaded panels get? Proposal: `virtual`.<br>• **Case filters:** the case list panel filter lists all panels of the tenant. Uploaded panels will show there too. Is this wanted?<br>• **Authorization:** which tenant-scoped action protects the upload? It must cover the ETL account now and users who upload from the browser later. Options:<br>&nbsp;&nbsp;◦ new action `can_manage_gene_panel` in the existing `tenant_admin` role (seed, backfill for existing tenants, grant to the ETL account);<br>&nbsp;&nbsp;◦ reuse `can_manage_org` (no migration, but it mixes two permissions);<br>&nbsp;&nbsp;◦ new action in a new role.<br>• **OpenAPI:** this is the first file upload route. Check that the OpenAPI generator writes a `multipart/form-data` body, and that the generated TS and Python clients send the file.<br>• **Symbol lookup access:** the ETL's existing portal role (Postgres) protects the API routes only. It gives no StarRocks access. With proxy read on, the lookup logs in to StarRocks as the ETL account, which needs a StarRocks JWT user and the Ranger role `{tenant}_user` (this role can read the shared DB, so `ensembl_gene`). The ETL batch calls never query StarRocks, so nothing proves today that the account has them. Proposal: provision the ETL account with `create-user -sub <etl sub> -grant <tenant>:<org>:<existing role>` in each environment (idempotent). Check that the StarRocks JWT issuer and audience accept the service account token. |
| portal (frontend) | • **`not-in`:** it also drops loci that are in no panel (SQL `NULL` logic), as for the public panels. Proposal: hide `not-in` for this facet. |
| infra | • **S3:** which bucket and prefix?<br>• **QA Airflow runtime:** QA runs stock Airflow 3.2.1 with no extra packages. Where does `radiant_python` run? Proposal: a pod in the radiant-task-operator image.<br>• **D3b:** prod StarRocks version, and is `TENANT_VIEWS_READ_ENABLED` on? |

## Approval

| | |
|---|---|
| Reviewer | Jeremy Costanza |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
