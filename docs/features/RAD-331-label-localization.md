# RAD-331: Serve labels in the user's language

## Story

- **Link:** [RAD-331](https://ferlab-crsj.atlassian.net/browse/RAD-331)
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch:** one branch per task, `feat/rad-xxxx-<slug>` after its Jira sub-task: most tasks are in the portal repo, so they cannot share one branch name. This spec lives on `feat/rad-331-label-localization` in the hub.
- **Acceptance criteria (AC),** as the story numbers them:
  1. **AC1:** in French, the case page, the case list, the variant list, the files and the admin show no English label and no raw code.
  2. **AC2:** a language switch changes the labels without a reload.
  3. **AC3:** without `Accept-Language`, the API answers in English and the response shape is unchanged.
  4. **AC4:** a filter returns the same results in both languages.
  5. **AC5:** at the end, the closed and growing vocabulary tables hold only their code.

## Chosen approach

**Summary:** two mechanisms, split by who knows the values. The labels of instance and user-created vocabularies live in the data, and the API serves them in the language the frontend sends. The closed and growing vocabularies are translated by the frontend from the code, and their label columns are dropped at the end.

### portal (backend)

- **Today:** labels come from `name_en` or `name` only. `ancestry`, `consanguinity`, `exam`, `role` and `action` already store a `name_fr` that nothing reads.
- **In the data:** `exam`, `ancestry`, `analysis_catalog`, `panel`, `role`, `action`. Their values differ per instance or are created in the admin, so the frontend cannot know them at build time.
- **In the frontend:** the closed vocabularies (`sex`, `life_status`, `affected_status`, `consanguinity`, `case_type`, `case_category`, `onset`, `histology_type`, `priority`, `experimental_strategy`, `sequencing_read_technology`, `platform`, `data_category`, `observation`, `obs_interpretation`) and the growing ones (`task_type`, `data_type`, `sample_type`, `file_format`, `status`, `panel_type`, `family_relationship`, `organization_category`). Their codes are set by migrations and known at build time.
- **Locale:** a middleware reads `Accept-Language` and binds `fr` or `en` to the request context, like the tenant. Default `en`.
  - It runs on every authenticated route, `/actions` included, so it never fails: an unknown or malformed header gives `en`.
  - Responses carry `Vary: Accept-Language`.
- **Label helper:** returns `name_fr`, or `name_en` when `name_fr` is empty, in the existing `name` field. The response shape does not change. Example: with `Accept-Language: fr`, a case returns ancestry `{"code": "CA-FR", "name": "Canadien français"}`.
- **Reads through the helper:** only these. Every other route ignores the header and answers as before.
  - case entity `GET /{tenant}/cases/{case_id}`: ancestry and exam names (task 1);
  - `GET /actions`, `GET /{tenant}/roles`, `GET /{tenant}/roles/{code}`, `GET /{tenant}/users`: role and action names and descriptions (task 5). The role response also gets `name_en`, `name_fr`, `description_en` and `description_fr` (additive), so the role form edits both languages without reading the translated `name`;
  - analysis catalog and panel names in the case search, the case filters, the case entity, the variant interpreted cases and their filters, and the patient genomics tab (task 7).
- **Panels and analysis catalog:** `name` becomes `name_en` + `name_fr`. The code is the value in every query: the tenant gene panel MV, the `tenant_gene_panel` filter and the CNV gene overlap move to it, and the « My Network » facet shows the panel name as its label. The panel import fills `name_en` with the code, as it fills `name` today.
  - Names are entered directly in the database until an admin page exists. For QLIN, whose names are French, they move by hand to `name_fr` and the English names are added.
  - A one-off script converts the saved filters on `tenant_gene_panel` from names to codes, with a dry run and a report of the values it cannot map.
- **Family relationships:** the QLIN bridge sends 25 codes that `family_relationship` (7 codes) does not hold. Task 6 adds them, kept as sent (typo `daugther` included), with `name_en` filled until the cleanup.
  - The case batch validates `family_member_code` against the table, as it does for `relation_to_proband_code`.
  - A foreign key from `family_history` keeps the gap from reopening.
- **Cleanup:** once the frontend translates every closed and growing vocabulary, their `name`, `name_en` and `name_fr` columns are dropped. The API then returns their code only: facets, value sets, case category, task type, strategy, read technology and organization category names, consanguinity on the case entity.
  - Two steps, because migrations run when the API starts and old pods would still read the columns during a rolling deploy: first the API stops reading them, then a later release drops them.
  - The organization categories, shown by the admin from `name_en` today, get frontend keys in the first step.
- **Filters:** always on the code. The translated label is for display only.

### portal (frontend)

- **Header:** a request interceptor on the shared API client sets `Accept-Language` from the app language, not the browser's. Every generated client goes through it.
- **Cache:** the SWR keys ignore the language, so a language switch revalidates every cached request.
- **Value sets:** translated from the code with `common.<value set>.<code>` keys, on the case page and its preview (task 3) and in the facets (task 4).
- **Family relationships:** keep their `common.relationships` keys, which already cover the 25 new codes.
- **New value-set codes:** no check. The portal's backend and frontend guides say, in one generic line, that a new value-set code comes with its English and French translations.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | request middleware, label helper, case entity, case search and filters, role, action and user reads, variant interpreted cases, patient genomics tab, family relationship value set, case batch validation, panel and analysis catalog migrations, gene panel MV and filter, value-set label columns, facets, value sets endpoint, OpenAPI spec, migration guide | new / modified / removed |
| portal (frontend) | API client, language switch, case page, case preview, facets, admin, translations, translation guide, generated client | new / modified |
| portal (cypress) | case batch fixtures | modified |
| etl | test copy of the clinical DDL (task 8) | modified |
| mcp | case context task type, clinical prompt (task 8) | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Locale parameter ([RAD-332](https://ferlab-crsj.atlassian.net/browse/RAD-332)) | portal (backend) | Middleware, label helper, `Vary`. First use: ancestry and exam names on the case entity. Postman examples | — | yes (default `en`) |
| 2 | Language in the frontend ([RAD-333](https://ferlab-crsj.atlassian.net/browse/RAD-333)) | portal (frontend) | Request interceptor, SWR revalidation on a language switch | Task 1, for the visible effect | yes (the API ignores the header before task 1) |
| 3 | Value sets on the case page ([RAD-334](https://ferlab-crsj.atlassian.net/browse/RAD-334)) | portal (frontend) | Keys instead of a raw code or `name_en` on the case page, its preview, the bioinformatics card and the sequencing information dialog: onset (badge), sex, life status, consanguinity, sample type, histology, strategy, read technology, platform, case category, task type, relationship of the task patients. Adds the missing `common.sex.unknown` | UI/UX confirmation of the onset badge and the strategy tooltip | yes |
| 4 | Value-set facets ([RAD-335](https://ferlab-crsj.atlassian.net/browse/RAD-335)) | portal (frontend) | Facets translated from their key: case list (case type, life status, case category), variant uninterpreted cases (sex), documents (relationship). Status, priority, data type and format are already translated | Task 3 (its keys) | yes |
| 5 | Bilingual admin ([RAD-336](https://ferlab-crsj.atlassian.net/browse/RAD-336)) | portal (backend and frontend) | Role and action names and descriptions through the helper in `GET /actions`, `GET /{tenant}/roles`, `GET /{tenant}/roles/{code}`, `GET /{tenant}/users`. The role form gets an English and a French name and description, prefilled from new raw fields of the role response | Tasks 1, 2; UI/UX validation of the role form | yes |
| 6 | Family relationships, CLIN-6235 ([RAD-338](https://ferlab-crsj.atlassian.net/browse/RAD-338)) | portal (backend) | 25 codes added to `family_relationship`, `family_member_code` validated by the case batch, foreign key from `family_history`, Cypress batch fixtures | — | yes, once QA and prod hold no unlisted code |
| 7 | Panels and analysis catalog (separate story [RAD-339](https://ferlab-crsj.atlassian.net/browse/RAD-339)) | portal (backend and frontend) | `name` renamed `name_en`, `name_fr` added, both read through the helper; the code is the value in every query: gene panel MV, `tenant_gene_panel` filter (its facet shows the panel name), CNV gene overlap; panel import; script converting the saved panel filters from names to codes. Names entered directly in the database until an admin page exists | Tasks 1, 2 | yes, with the MV rebuild, the saved filter script and the QLIN names entered |
| 8 | Drop the value-set label columns (separate story [RAD-340](https://ferlab-crsj.atlassian.net/browse/RAD-340)) | portal (backend and frontend), mcp | Step 1: the API stops reading the label columns and returns codes only, organization categories translated by the frontend, the MCP stops relying on the removed fields, OpenAPI and generated clients. Step 2, a later release: the label columns are dropped | Tasks 3, 4, 6 | yes: step 1 alone; step 2 with `refresh-tenants` in the same deploy |

No separate Labels task: each task ships its own keys or `name_fr`, and the clinical team reviews them in that task (3, 4, 7). No separate UX task: the UI/UX team validates the onset badge and the strategy tooltip (task 3) and the bilingual role form (task 5) before their frontend work.

## Merge and rollout order

1. **portal backend, task 1:** without a header, the API answers in English, as today.
2. **portal frontend, task 2:** at any time; the API ignores the header until task 1 is deployed.
3. **portal frontend, tasks 3 and 4:** at any time, task 4 after task 3; they read codes the API already returns.
4. **portal backend, task 6:** at any time. Before the deploy, check on QA and prod that every stored `family_member_code` is in the table; the Cypress batch tests wrote `Cypress` on QA. Otherwise the migration fails and the API does not start.
5. **tasks 5 and 7:** after task 2. Task 7, in one deploy: the migration, `refresh-tenants` (it rebuilds the gene panel MV on every tenant), then the saved filter script after its dry run. The QLIN names are entered by hand right after the migration, in QA then in prod.
6. **task 8, step 1:** last, after tasks 3, 4 and 6 are deployed. The API, the frontend and the MCP stop using the label columns; the columns stay.
7. **task 8, step 2:** in a later release, the migration drops the columns, with `refresh-tenants` in the same deploy: the tenant views list their columns, so every read of a changed table fails until they are rebuilt. Dropping the columns before step 1 is deployed everywhere breaks the old pods during the rolling deploy.

No backfill. No feature flag.

## Test strategy

### portal (backend)

- **AC1, AC3:** integration tests on the case entity, the role, action and user lists, and the case facets, with `fr`, `en`, no header and an unknown language: French label, English fallback (tasks 1, 5, 7).
- **AC4:** the gene panel filter works on the panel code (task 7).
- **AC5:** after the task 8 migration, the facets, the value sets and the case entity answer with codes.
- **Interoperability (task 6):** a case batch with an unlisted family member code fails validation; a direct insert is refused by the foreign key.

### portal (frontend)

- **AC2:** unit tests: the header follows the app language, and a language switch revalidates the cache (task 2).
- **AC1:** unit tests of the task 3 fields and the task 4 facets: the label comes from the code, and the code or the API label shows when no key exists.

### portal (cypress)

- **Interoperability (task 6):** the case batch API specs pass with a listed family member code.

### QA (manual)

- **AC1, AC2:** in French, the case page, its preview, the case list, the variant list, the files and the admin show no raw code and no English label; a language switch updates them without a reload.
- **Task 6:** before the release, every distinct `family_member_code` of QA and prod is in the table.

## Risks and coverage

| Risk | How it is covered |
|---|---|
| Interoperability (story): the case batch rejects a family history code that is not in `family_relationship` | Task 6 adds the 25 codes the QLIN bridge sends before the validation; QA and prod checked before the foreign key; Cypress fixtures updated |
| A French label is clinically wrong | The clinical team approves the French labels in tasks 3, 4 and 7 |
| A new value-set code ships without its keys | Not checked: the guides say so; a check will be added if this becomes a problem |
| The middleware breaks every request | It never fails: an unknown or malformed header gives `en`; unit tests |
| Task 8 breaks the tenant views or an API reader | Two steps (stop reading, then drop); `refresh-tenants` in the same deploy as the drop; OpenAPI and clients regenerated; MCP updated |

## Frozen scope

### all

- **HPO in French:** a separate story, [RAD-341](https://ferlab-crsj.atlassian.net/browse/RAD-341). The ETL downloads Orphanet's official French translation ([Gargano et al., 2024](https://doi.org/10.1093/nar/gkad1005)), fills a new `name_fr` column of `hpo_term`, and the portal reads it through the label helper.
- **MONDO in French:** no French source is available yet; no story for now.
- **Public gene panel filters** (OMIM, HPO, Orphanet, DDD, COSMIC) work on the panel name. Moving them to an identifier is a follow-up in the ETL; DDD and COSMIC have none.
- **Open points of the analysis:** default language per environment, language preference in the user profile, facets from external sources (ClinVar…).

### portal (backend)

- **Value sets endpoint:** `GET /value_sets/:type` stays in English until task 8 drops its labels. Its only reader today is the organization category list in the admin.
- **Organizations and projects** keep a single `name`.
- **Relation to proband:** `relation_to_proband_code` reads the same value set as the family history, so it accepts the 25 new codes too. Not restricted here.
- **`daugther`:** kept as the CLIN referential sends it.
- **Documents Relationship facet:** it keeps listing every code of `family_relationship`, so 32 options after task 6, not only the relationships found in the documents.

### portal (frontend)

- **Translation key check:** no test or CI check that every value-set code has its keys.
- **Panel and catalog names in the admin:** no page to edit them; they are entered directly in the database (a separate story).

### mcp

- No header: the MCP keeps English labels. Its only change is in task 8.

## Open questions

### story / product

- **Task 7 content:** who provides the English names of the QLIN panels and catalog entries, and who enters them in the database, in QA then in prod?

### portal (backend)

- Does the StarRocks JDBC catalog see a new `name_fr` column without a metadata refresh? Check on QA.

### portal (frontend)

- **Bilingual role form:** to validate with UI/UX; the current mockup has a single name field. **Proposal:** a name and a description in English (name required) and in French (optional, the English one is used when empty).
- **Query bar (task 7):** a selected panel shows as a code in the query bar pill. **Proposal:** show the panel name, like the facet.
- **Onset badge and strategy tooltip:** to confirm with UI/UX. **Proposal:** the onset badge shows its label without the age range, removed by a regex so the translations are not duplicated, and the full label on hover; the strategy badge keeps the code, with its translated name on hover.

## Approval

| | |
|---|---|
| Reviewer | **[Name]** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
