# RAD-313: Tell the user when a searched variant exists elsewhere in the project

## Story

- **Link:** [RAD-313](https://ferlab-crsj.atlassian.net/browse/RAD-313), follow-up of [RAD-243](https://ferlab-crsj.atlassian.net/browse/RAD-243) and [RAD-284](https://ferlab-crsj.atlassian.net/browse/RAD-284)
- **Assigned reviewer:** to be assigned
- **Status:** Draft
- **Branch (all repos):** `feat/rad-313-variant-elsewhere-in-project`

## Chosen approach

**Summary:** when the run search finds nothing, the backend looks the identifier up in a new per-tenant lookup table (identifier → `locus_id`), filled by the import, and the UI links to the existing variant page, which already lists the cases that carry the variant.

### etl

- **New table:** `snv__variant_identifier` in each `<tenant>_tenant` database. One row per identifier of a variant: its `locus`, its `hgvsg`, and its `rsnumber` and `clinvar_name` when set, with the `locus_id`. About 2 to 4 rows per variant. Keyed, sorted and distributed by identifier, so a lookup reads one bucket and stays fast whatever the size (16.3 million variants on QA today, more than 40 millions expected in production).
- **Values:** copied as stored in `snv__variant`. They already have the form that the search normalises its input to (locus without `chr`, VEP HGVSg, lower-case `rs`, numeric ClinVar ID), so the ETL normalises nothing.
- **Import:** a new step right after the variant part of `snv__variant_partitioned` is written. It adds the identifiers of the variants of that part only (upsert on the key), so the cost follows the batch, not the table. Rerunning it changes nothing.
- **Re-annotation:** `reannotate_open_data` rebuilds the whole table of each tenant after it rewrites `snv__variant`, since a new dbSNP or ClinVar release can change or remove rsIDs and ClinVar IDs.
- **First load:** a migration only creates the empty table in each tenant database, applied by hand as the other migrations. One run of `reannotate_open_data` with `force_reannotation` then fills it for every tenant at once. The next imports only add the identifiers of their new variants.
- **Data integrity checks:** each `locus_id` of `snv__variant` has at least its locus and HGVSg rows.

### portal (backend)

- **Search route:** unchanged (`POST /{tenant}/occurrences/{germline|somatic}/snv/{case_id}/{seq_id}/{task_id}/search`). The run lookup of RAD-284 runs first, as today.
- **Project lookup:** only when the run lookup finds nothing and the format is recognised. It reads `snv__variant_identifier`, then confirms each hit on `snv__variant` (primary key access on `locus_id`, same column must still hold the identifier), so a stale row never yields a wrong answer.
- **Owner:** the variants repository, which already owns `snv__variant` and the variant page queries.
- **Response:** additive, no new status. `not_found_in_run` keeps its meaning. A new `in_project` flag tells whether the variant exists in the tenant, and a new `project_variants` list gives `locus_id`, `hgvsg` and `locus` of each match (same limit as the run search). RAD-285 keeps working unchanged.
- **Access path:** reads run as the calling user through the proxy. The tenant access policy already grants SELECT on every table of `<tenant>_tenant`, so the new table needs no Ranger change.
- **"Who carries it":** no new route. The germline variant page already lists the interpreted and uninterpreted cases of a `locus_id`.

### portal (frontend)

- **Message:** the line under the search input shows three cases: found in this run (unchanged), not in this run but in the project, unknown to the project.
- **Link:** when the variant is in the project, the line links to the variant page, Cases tab (`/variants/entity/{locus_id}?tab=patients`), the same link the variant overview cards use. One link per variant when an identifier matches several alleles.
- **Somatic runs:** the Cases tab lists germline cases only. In a somatic run, the message says the variant is in the project, without a link, until somatic case routes exist (see frozen scope).
- **Pill:** unchanged. A variant absent from the run adds nothing to the pill.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | per-tenant schema, import DAG (variant step), re-annotation DAG, migration, data integrity checks | new / modified |
| portal (backend) | variant search (handler, variants repository, response type), test schema and seed, swagger and generated clients, Postman collection | modified |
| portal (frontend) | variant search message in the Variant facet, labels | modified |
| mcp | none (the new table is visible to its SQL, nothing reads it) | — |
| infra | none | — |
| bioinfo | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Variant identifier lookup table | etl | Table, migration creating it, import step, re-annotation rebuild, integrity check | — | yes (nothing reads it yet) |
| 2 | Look the variant up in the project | portal (backend) | Project lookup in the search, `in_project` and `project_variants` in the response, test fixture, swagger and clients, Postman | Task 1 (table in the test schema) | yes once task 1 is migrated (additive response) |
| 3 | Message and link to the variant page | portal (frontend) | Three-way message, link per variant to the Cases tab, EN/FR labels validated by the clinical team | Task 2 | yes once task 2 is deployed |

No UX task: the message reuses the line under the search input that RAD-285 adds, with a plain link.
## Merge and rollout order

1. etl: task 1 merged, migration run on every tenant database (QA, then prod), before the DAGs are deployed. Without the table, the new import step fails and every import breaks.
2. etl: one `reannotate_open_data` run with `force_reannotation` fills the table for every tenant. Until it runs, the table is empty and every search answers "unknown to the project".
3. etl: the next imports keep the table current by adding their new variants.
4. portal backend: task 2, only after steps 1 and 2 in the same environment. Deployed before step 2, it reports existing variants as unknown.
5. portal frontend: task 3, after the backend.

No feature flag. The backfill is the forced re-annotation of step 2.

## Test strategy

### etl

- **AC2, AC4:** integration test on the sandbox data: after an import, each identifier of a variant of the batch resolves to its `locus_id`; an unknown one resolves to nothing.
- **AC6:** integration test: after a re-annotation that removes an rsID, the old rsID no longer resolves.

### portal (backend)

- **AC1:** existing run-search tests unchanged; response time measured on QA with a real run, recorded in the PR.
- **AC2, AC4, AC5:** repository and API integration tests on a fixture with a variant in the tenant but not in the run, and an identifier unknown to the tenant.
- **AC6:** repository test with a lookup row whose identifier no longer matches `snv__variant`: no match.

### portal (frontend)

- **AC2, AC3, AC4, AC5:** Cypress spec on the case variants page: a variant of another case of the cypress tenant shows the project message and its link opens the Cases tab listing that case; an unknown rsID shows the unknown message.
- **AC7:** labels present in both translation files.

### QA (manual)

- **AC3:** from a germline run, the Cases tab lists the expected cases on QA data; from a somatic run, the message shows without a link.
- **AC1:** response time on a large QA run.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data | The search returns only variant data (no case, no patient). The cases appear on the existing variant page, under its existing access rules. Whether those rules restrict cases to the user's organisations is an open question. |
| Genomic formats or data | The lookup is rebuilt at each re-annotation, and the backend confirms every hit on `snv__variant`, so a removed or changed identifier is never returned. |

## Frozen scope

### etl

- Full rewrite of `snv__variant` at each import: its cost grows with the table (more than 40 million variants expected in production), separate ticket.
- Secondary rsIDs of dbSNP and ClinVar accessions (`VCV…`) in the lookup.

### portal (backend)

- A somatic equivalent of the variant page case routes (only germline exists today), separate ticket if the product asks for it.
- A list or count of carrying cases in the search response.

### portal (frontend)

- Showing the carrying cases under the search input.

### all

- CNVs, search by protein change (`p.`).

## Open questions

### story / product

- Is a link to the variant page enough to answer "who carries it", or should the cases show under the search input? Proposal: the link, since the page already exists.
- Must the cases on the variant page be limited to the user's organisations? Proposal: check how the existing page behaves on QA first, and file a separate ticket if it must change.

### etl

- Number of buckets of `snv__variant_identifier` for the production volume. Proposal: start like `snv__variant` (10) and revisit with the pipeline team.

### portal (backend)

- For a locus or the HGVSg of an SNV, the `locus_id` can be computed directly (variant ID encoding) instead of read from the lookup. Proposal: always use the lookup, one code path; keep the direct computation only if the measures ask for it.

## Approval

| | |
|---|---|
| Reviewer | **to be assigned** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
