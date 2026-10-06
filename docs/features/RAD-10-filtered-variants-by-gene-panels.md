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
| portal (backend) | • **Storage:** reuse the existing Postgres tables `panel` and `panel_has_genes`. No new table, no migration.<br>&nbsp;&nbsp;◦ `panel` is already tenant-scoped, with a unique code per tenant (case-insensitive).<br>&nbsp;&nbsp;◦ `panel_has_genes` requires an Ensembl ID for each gene (part of its primary key).<br>• **Upload endpoint:** `PUT /{tenant}/gene_panels` takes the `.tsv` file as a `multipart/form-data` attachment. The API parses the file, checks it, then **replaces the tenant's gene panels with the content of the file**: it deletes the tenant's existing gene panels and creates every panel of the file, in one transaction. The file is the full list of the tenant's panels.<br>&nbsp;&nbsp;◦ The delete covers only the uploaded gene panels. The panels of the analysis catalog (prescriptions) are in the same table and stay unchanged (see open questions).<br>&nbsp;&nbsp;◦ The same file sent twice gives the same result, so a retry is safe.<br>• **Why an attachment:** all the parsing and checks are in one place, the API. Later, a user can upload the same file from the browser to the same endpoint, with no S3 step.<br>• **Checks:** a bad layout, a bad `panel_code`, two panels with the same `panel_name`, an empty or a duplicate symbol give 400. The name must be unique, because the facet filters on it.<br>• **Symbols:** the API resolves each symbol to its Ensembl ID against `ensembl_gene`, with the gene search that the "upload a gene list" facet already uses. Unmatched symbols are returned as warnings and skipped. `strict=true` rejects the file (422).<br>&nbsp;&nbsp;◦ **Access:** the lookup uses the portal's admin StarRocks connection (root pool), like the MV refresh. `ensembl_gene` is public reference data, so this is not a security issue. The caller needs no StarRocks access.<br>• **Authorization:** a tenant-scoped action, not decided yet (see open questions).<br>• **StarRocks MV:** a per-tenant async MV `{tenant}_tenant.gene_panel_mv(panel, symbol)`, with `panel` = the panel name, like the columns of the public panel tables (`hpo_gene_panel`, `omim_gene_panel`, …), over `panel` and `panel_has_genes`, through the existing `radiant_jdbc` catalog. The API refreshes the MV after each write.<br>&nbsp;&nbsp;◦ **Access:** the API creates and refreshes the MV with the portal's admin StarRocks connection (root pool), never with the caller's JWT. The backend already does this to create StarRocks users. So the caller (ETL account or user) needs no StarRocks privilege on the MV.<br>• **Filter:** a new SQON field `tenant_gene_panel` on the MV column `panel`, defined like the public panel fields. It plugs into the existing gene panel join on the consequence symbol. One table and one field, no new query code. Germline and somatic SNV.<br>&nbsp;&nbsp;◦ The filter values and the facet buckets are panel names, as for HPO and OMIM. |
| etl | • **Load path:** the operator puts the clinician's `.tsv` in an S3 prefix. A new Airflow DAG `import_tenant_gene_panel` reads the file and attaches it, unchanged, to **one `PUT`**.<br>• **Input:** the operator triggers the DAG by hand with a run config. Same style as the other import DAGs (`*_filepath` params):<br>&nbsp;&nbsp;◦ `tenant` (string, required): the tenant code, used in the `PUT /{tenant}/gene_panels` path;<br>&nbsp;&nbsp;◦ `gene_panel_filepath` (S3 URI, required): the `.tsv` file with **all** the tenant's panels. One file per run, because each upload replaces the previous one;<br>&nbsp;&nbsp;◦ `strict` (boolean, default `false`): sent to the API; `true` rejects a file with unmatched symbols.<br>&nbsp;&nbsp;◦ Example: `{"tenant": "radiant", "gene_panel_filepath": "s3://<bucket>/gene_panels/radiant/gene_panels.tsv", "strict": false}`.<br>• **Client:** the generated `radiant_python` client, pinned to a portal SHA. It supports `multipart/form-data`.<br>• The DAG does not parse or check the file. It logs the warnings that the API returns.<br>• **Retries:** the upload replaces the full set, so the DAG can retry it safely, for example when the MV refresh fails after the commit. |
| portal (frontend) | • **Facet:** lists only the panels with hits in the case, from the existing aggregate. No dictionary padding for this facet.<br>• **Labels:** same mechanism as the public panel facets. The bucket key is the panel name. The facet looks up a translation for it and, if there is none, shows the key in lower case with `_` replaced by spaces. No label map, no extra API call.<br>• **`not-in`:** same behaviour as the public panel facets (HPO, OMIM). No change in this story. |
| mcp | • Bump the client SHA. The new MV is visible to its SQL. |
| infra | • S3 prefix with Airflow read access.<br>• QA Airflow runtime for `radiant_python` (see open questions). |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | new DAG `import_tenant_gene_panel` and its runbook, `radiant_python` dependency, Airflow connection to the portal API | new |
| portal (backend) | panel repository, TSV parser, `PUT /gene_panels` route, tenant MV and its Ranger policy, SNV gene panel fields, OpenAPI spec, generated clients | new / modified |
| portal (frontend) | germline and somatic SNV facet config, EN/FR translations (facet title and tooltip) | modified |
| mcp | client SHA bump, prompt doc | modified |
| infra | S3 prefix + Airflow read access, QA Airflow runtime for `radiant_python` | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | MV and Ranger | portal (backend) | MV per tenant over `panel` / `panel_has_genes` (at tenant creation and with `refresh-tenants`), refresh after write, both with the admin connection; Ranger read policy on the MV | — | yes |
| 2 | Upload API | portal (backend) | `PUT` with the file attachment (tenant-scoped action, see open questions), TSV parser and checks, symbol resolution, body size limit, replace the tenant's gene panels in one transaction; OpenAPI + clients | Task 1 | yes (additive) |
| 3 | SQON field | portal (backend) | `tenant_gene_panel` for germline and somatic SNV (filter and aggregate), accepted only with `TENANT_VIEWS_READ_ENABLED=true` | Task 1 | yes (additive) |
| 4 | Infra | infra | S3 prefix + Airflow read access, QA Airflow runtime (see open questions) | — | yes |
| 5 | DAG | etl | Run config (`tenant`, `gene_panel_filepath`, `strict`), read the file from S3, attach it to one `PUT`, log the warnings, `radiant_python` pinned to the merged task 2 SHA, runbook | Tasks 2, 4 | yes once 2 is deployed |
| 6 | Labels | portal (frontend) | EN/FR facet label and tooltip, validated by the clinical team | — | yes |
| 7 | Facet | portal (frontend) | Facet `tenant_gene_panel` in germline and somatic, same config as the public panel facets | Tasks 3, 6 | yes once 2 and 3 are deployed |
| 8 | MCP | mcp | Bump client SHA, prompt doc | Tasks 2, 3 | yes |

No specific UX task: the facet reuses the existing multiselect facet.

## Contract changes

| Contract | Change | Writer | Readers | Migration / compatibility |
|---|---|---|---|---|
| API: `/{tenant}/gene_panels` | New `PUT` (`multipart/form-data`, one `.tsv` file part, `strict` param; replaces all the tenant's gene panels with the panels of the file; tenant-scoped action to decide) | portal backend | etl (`radiant_python`, pinned SHA) | Additive. First file upload endpoint of the API. ETL consumer row in `portal-api.md` changes |
| Postgres `panel`, `panel_has_genes` | New writer: the upload endpoint. No DDL change | portal backend | portal backend (case filters, analysis catalog), MV | Each upload deletes and re-creates the tenant's gene panels, so their IDs change. Prescription panels stay unchanged. Saved filters use the panel name, so they still work while the name does not change |
| Gene panel file format | TSV, UTF-8, header row. Columns `panel_code`, `panel_name`, `symbol`, optional `ensembl_id`. One row per gene, many panels per file | clinicians (via the operator) | portal backend (parser) | New contract doc. The API owns the format |
| API: germline and somatic SNV `list`, `count`, `aggregate` | New SQON field `tenant_gene_panel`, values are panel names | portal backend | portal frontend, mcp | Additive |
| StarRocks `{tenant}_tenant.gene_panel_mv` | New per-tenant async MV `(panel, symbol)` over `radiant_jdbc` | portal backend | portal backend, mcp | Created by `refresh-tenants` for existing tenants. A later change to the MV needs a drop and a re-create |

## Merge and rollout order

1. infra: S3 prefix and Airflow read access. Check the prod StarRocks version (QA runs 4.0.11).
2. portal backend: tasks 1 to 3. Then run `refresh-tenants` with Ranger credentials, so that every tenant has its MV and policy. Without the MV, the filter fails with "unknown table".
3. etl: task 5, pinned to the merged backend SHA. **Reverse of the usual order**: the ETL calls the API, so the API comes first.
4. portal frontend and mcp: tasks 6, 7, 8, after step 2 in each environment.

No migration, no backfill. No feature flag: the facet is empty until a panel is loaded. Keep `TENANT_VIEWS_READ_ENABLED=true` where the field is exposed.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1 (load):** tests on the parser and on a multipart upload: each check, one transaction per file, unmatched symbols skipped and reported; a second upload removes the panels that are not in the new file; prescription panels stay unchanged.<br>• **AC2 (filter):** StarRocks integration tests on a fixture: one and several codes, combined with a public panel, `not-in`, a panel with no hit is absent from the facet, unknown code gives 0 rows. Germline and somatic.<br>• **AC3 (persistence):** tenant isolation tests. |
| etl | • DAG unit test: the file is attached unchanged. |
| QA (manual) | • Load a panel, filter on two cases (AC2, AC3).<br>• MV query plan, two parallel uploads for one tenant.<br>• The panel filter plan has the same shape as the OMIM filter. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| A panel visible to another tenant | Panels are tenant-scoped, MV per tenant, route checks the tenant. Isolation tests |
| A file loads partly | One `PUT`, one transaction. Test: a failure on panel N keeps the previous panels |
| An upload deletes prescription panels | The delete covers only the uploaded gene panels. Test: a prescription panel stays after an upload |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • SNV only: no CNV filtering.<br>• No disaster recovery: no versioned S3 archive, no replay of the archived files. Recovery relies on the Postgres backup only.<br>• No self-service panel management. |
| portal (backend) | • No read endpoint for the panels (`GET /gene_panels`): the facet does not need it.<br>• No route to update or delete one panel. The operator changes or removes a panel by uploading a new full file.<br>• No change to the `panel` and `panel_has_genes` tables.<br>• No alias resolution: a previous HGNC symbol stays unmatched until the operator fixes the file. |
| portal (frontend) | • No browser upload in this story. The endpoint is ready for it, but there is no UI.<br>• No UI to browse panels, no download of the `.tsv` files.<br>• No change to the `not-in` behaviour. If it causes a problem, a separate ticket will fix it. |
| etl | • No delete or replay mode in the DAG.<br>• The hand-written ETL portal client does not change. Moving it to `radiant_python` is a separate ticket. |
| mcp | • No new MCP tool. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **Story rule on S3:** the story asks the operator to archive the raw `.tsv` in S3 for DR. With DR out of scope, the S3 file is only the DAG input. Update the story?<br>• **Panel file:** is there a sample file? Do clinicians already use stable panel codes?<br>• **Ownership:** who maintains the panels, and how often? Facet label in EN/FR? |
| portal (backend) | • **Unmatched symbols:** `panel_has_genes` requires an Ensembl ID, so a symbol that is not in `ensembl_gene` is skipped. Accept this, or add a migration to keep all symbols? Proposal: skip and report.<br>• **Delete scope:** the upload must delete only the uploaded gene panels, not the prescription panels of the analysis catalog (same `panel` table). How do we tell them apart? Options:<br>&nbsp;&nbsp;◦ a new `panel_type` value for uploaded panels (seed migration);<br>&nbsp;&nbsp;◦ the existing `virtual` type, if no prescription panel uses it;<br>&nbsp;&nbsp;◦ skip the panels that the analysis catalog references.<br>• **Case filters:** the case list panel filter lists all panels of the tenant. Uploaded panels will show there too. Is this wanted?<br>• **Authorization:** which tenant-scoped action protects the upload? It must cover the ETL account now and users who upload from the browser later. Options:<br>&nbsp;&nbsp;◦ new action `can_manage_gene_panel` in the existing `tenant_admin` role (seed, backfill for existing tenants, grant to the ETL account);<br>&nbsp;&nbsp;◦ reuse `can_manage_org` (no migration, but it mixes two permissions);<br>&nbsp;&nbsp;◦ new action in a new role.<br>• **OpenAPI:** this is the first file upload route. Check that the OpenAPI generator writes a `multipart/form-data` body, and that the generated TS and Python clients send the file. |
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
| 2026-10-05 | Task 5 (etl): the DAG does not use the generated `radiant_python` client. It sends the `PUT /{tenant}/gene_panels` with the hand-written ETL portal client (`radiant/tasks/nextflow/portal.py`, `requests`), with the same `radiant_api_conn` connection as the other portal calls. Reason: the client is too much for one call, and it must be installed and pinned in each Airflow runtime (local image, MWAA Airflow 2 and 3, QA). Effects: the frozen-scope rule "The hand-written ETL portal client does not change" no longer applies; there is no `radiant_python` pin in the ETL; infra task 4 does not need a QA Airflow runtime for `radiant_python`, only S3 read access for the worker. Moving the ETL to `radiant_python` stays a separate ticket. | — | Pending: Jeremy Costanza |
