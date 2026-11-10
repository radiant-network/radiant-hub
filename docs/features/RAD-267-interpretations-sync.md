# RAD-267: Sync QLIN variant interpretations into Radiant

## Story

- **Link:** [RAD-267](https://ferlab-crsj.atlassian.net/browse/RAD-267), sub-tasks [RAD-268](https://ferlab-crsj.atlassian.net/browse/RAD-268) (roles and configuration), [RAD-269](https://ferlab-crsj.atlassian.net/browse/RAD-269) (variant lookup endpoint), [RAD-270](https://ferlab-crsj.atlassian.net/browse/RAD-270) (hybrid sync endpoint)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-269-variants-lookup` (portal), `feat/rad-270-interpretations-sync` (hybrid), `feat/rad-268-interpretations-sync-config` (localstack)

## Chosen approach

**Summary:** hybrid (`clin-qlin-me-hybrid`, the QLIN backend that bridges prescriptions to Radiant) gets a manual endpoint `POST /api/v1/radiant/sync/interpretations` that replays, per analysis, the interpretations stored in the on-prem `radiant-api` v1.1.4 into Radiant through its public API. The legacy rows are keyed by QLIN ids (ServiceRequest id, locus string); Radiant keys an interpretation by `(case_id, sequencing_id, locus_id, transcript_id)` with its own `seq_id` and a numeric `locus_id` that lives only in StarRocks. Hybrid resolves the first two through FHIR and the existing case endpoints. The numeric `locus_id` needs one new Radiant endpoint, `POST /{tenant}/variants/lookup`, that maps locus strings to ids from the tenant's `snv__variant` table. The content of each row (classification, criteria, modes, text, pubmed, metadata, author names, timestamps) is copied as is through the existing v2 interpretation upsert.

A restore of the legacy Postgres dump was ruled out: the key changed, `locus_id` cannot be computed outside StarRocks (long indels fall back to a lookup table), and the dump sits on the on-prem S3 that the AWS cluster cannot reach.

### portal (backend)

- **Variant lookup:** `POST /{tenant}/variants/lookup`, body `{"loci": [...]}`, 1 to 100 loci after dedupe. A locus is `chr-pos-ref-alt`; a `chr` prefix and lowercase bases are accepted. The response is an array in request order; a known locus carries its `locus_id` (as a string, like every id of the API), an unknown one has none. One malformed locus fails the whole batch with 400. The match is exact on chromosome, start, reference and alternate in the tenant's `snv__variant`, the same table the variant pages read. It is guarded by the `search_case` action like the other `/variants` routes.
- **Author names on import:** the v2 interpretation POST sets `created_by` and `updated_by` from the token subject and today overwrites the names with the token's `name` claim. A service account carries no name: in that case the names of the body are kept. A user token still overrides them, nothing changes for the portal.
- **Readers:** the lookup has one consumer, hybrid. The Swagger, TypeScript and Python clients and the Postman collection are regenerated with it.

### hybrid

- **Endpoint:** `POST /api/v1/radiant/sync/interpretations`, body `{"analysis_ids": [...]}`, query `dry-run=true` optional, answers 202 and runs on the Radiant executor pool with the same in-flight dedup as the existing case sync. Restricted to the `clin_system` role. 503 when the Radiant bridge is off.
- **Legacy read:** one new config `RADIANT_LEGACY_URL`. Hybrid calls `GET /interpretations/germline?analysis_id=` and `/somatic` on the legacy API with the caller's token forwarded verbatim. The legacy API gates on the realm role `clin_genetician`, so the controller refuses a token that lacks it before any call.
- **Key resolution, once per analysis:** the FHIR analysis gives the sample of each sequencing ServiceRequest; the case search on `submitter_case_id` gives the `case_id`; the case detail gives the `seq_id` of each sample; the variant lookup gives the `locus_id` of each distinct locus. A row whose key is not fully resolved is never posted: it is listed in the run report with its reason and the other rows of the analysis still land.
- **Upsert:** the existing v2 `POST /{tenant}/interpretations/v2/{germline|somatic}/{case}/{seq}/{locus}/{transcript}`. The body copies the legacy content and its metadata (QLIN analysis, patient and variant hash ids, kept for tracing), the author display names, and the timestamps re-emitted in UTC. Author ids become the hybrid service account. The upsert is idempotent, a second run updates in place.
- **Report:** per analysis, counts of germline, somatic, upserted and skipped rows, plus one line per skipped row, in the same run report as the case sync. The dry run does every lookup and logs the resolved target of each row without writing.

### infra

- **Keycloak (CLIN realm):** temporary realm role `clin_genetician` on the `clin-system` service account, plus the role mapper the client needs because it has full scope disabled. Terraform in the pre-prod (qa, staging) and prod service-configuration repos. Reverted after the migration.
- **Radiant auth_db (qlin-qa, qlin-prod):** role `geneticist` on organization `*` for the `hybrid_system` account, because the v2 POST requires `can_interpret_variant`, carried by that role only. Set through the Radiant users admin, not versioned.
- **Kubernetes:** `RADIANT_LEGACY_URL` on the hybrid ConfigMap of qa, staging and prod, pointing to the on-prem radiant-api of the environment.
- **Localstack:** the same two grants in the realm import and the Radiant seed, a WireMock stub of the legacy API with one hit and one miss fixture, and the URL in the hybrid env.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | variants repository and handler, interpretation handler, route table, generated clients, Postman | new / modified |
| hybrid | Radiant controller and routes, legacy radiant-api client, variant lookup client, interpretation mapper and sync service, run report, configuration, docs | new / modified |
| infra | CLIN Keycloak Terraform (qa, staging, prod), Radiant auth_db grants, hybrid ConfigMaps (qa, staging, prod) | modified |
| localstack | Keycloak realm import, Radiant seed, legacy API stub, hybrid env | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Roles and configuration (RAD-268) | infra, localstack | Keycloak grant, auth_db grant, ConfigMaps, localstack stub and seeds | … | yes: inert until the endpoints exist |
| 2 | Variant lookup endpoint (RAD-269) | portal (backend) | Locus parsing, StarRocks lookup, handler, author-name rule on the v2 POST, clients, tests | … | yes |
| 3 | Hybrid sync endpoint (RAD-270) | hybrid | Legacy client, key resolution, mapper, sync service, report, controller, config, tests, docs | Task 2 for a real run | yes: the endpoint answers 503 or reports every row as unresolved until Radiant has the lookup |

No UX task: nothing is shown. No Labels task: no new user-visible text, the report is an operator log.

## Merge and rollout order

1. portal (backend): merge task 2, deploy on qlin-qa then qlin-prod. Without it hybrid reports every row as "variant lookup failed".
2. infra: apply the Keycloak grant per environment, grant `geneticist` to `hybrid_system` in the auth_db, apply the ConfigMaps. Without the Keycloak grant the legacy API answers 403 to hybrid; without the auth_db grant Radiant refuses the upsert with 403.
3. hybrid: merge task 3, deploy on qa, staging, prod. After the portal PR merges, refresh the vendored Radiant spec in hybrid and replace the hand-written lookup client with the generated one (same PR or a follow-up).
4. Run: extract the distinct analysis ids from the legacy database, run the case sync on the ids not yet in Radiant, then the interpretation sync in dry-run on a chunk of about 50 ids, read the report, run for real. Chunks stay under the token lifetime (5 minutes). Re-run the skipped ids once their variants are in the tenant's `snv__variant`.
5. Revert the Keycloak grant once the migration is accepted.

No migration, no feature flag beyond the existing Radiant bridge mode. No backfill: the run is the backfill.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1 (lookup):** repository test on the StarRocks fixture: hits, a miss, a near miss on the alternate not resolved, empty input. Handler tests: `chr` and lowercase normalised, duplicates collapsed, empty or over 100 or malformed input is a 400, repository error is a 500. Integration test on the exact JSON of a mixed batch.<br>• **AC7 (author names):** handler tests, one with a user token that overrides the names, one with a service token that keeps them. |
| hybrid | • **AC2, AC3 (content and idempotence):** unit tests of the mapper (every field, key as strings, timestamps normalised or dropped) and of the sync service with mocked FHIR, legacy and Radiant clients.<br>• **AC4 (unresolved rows):** sync service tests for a missing case, a ServiceRequest absent from the analysis, an unmatched sample, a locus miss, a refused upsert: only that row is skipped, the report names it.<br>• **AC5 (dry run):** sync service test: lookups done, no upsert.<br>• **AC6 (role):** controller tests: 403 without `clin_system`, 403 when the token lacks `clin_genetician`, 503 when the bridge is off. |
| QA (manual) | • One analysis with legacy interpretations synced as a case: dry run shows the resolved targets, the real run writes the rows, the Radiant case shows them with the QLIN author name, a second run changes nothing.<br>• One analysis with a locus unknown to Radiant: the row is in the report, the others landed. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data | Interpretation text and QLIN ids transit through hybrid in memory only. Logs carry analysis ids and the resolved key, never the text. The legacy API is read with the caller token, so access stays what it is today. |
| Clinical rules or interpretation | Classification, criteria, transmission modes, oncogenicity and text are copied without transformation. A row on a transcript other than the one Radiant picked for the occurrence is stored and visible on the variant page, not flagged on the occurrence row (open question). |
| Traceability and audit | Author display names and original timestamps are preserved on the Radiant row. Author ids are the hybrid service account; the legacy database keeps the original ids. |
| Interoperability | Four systems in one run: legacy radiant-api, FHIR, Radiant case and interpretation endpoints, the new lookup. Each failure is reported per row with its origin and status, nothing is written on a partial key. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No continuous sync: interpretations edited in QLIN after the run need another run on the same ids.<br>• No author id mapping between the CLIN and Radiant realms. |
| portal (backend) | • No lookup by variant hash, by `MT` naming or by structural variants.<br>• No import route with author passthrough. |
| hybrid | • No upper bound on the number of ids per call beyond the executor pool, same as the case sync.<br>• No validation of PubMed ids before the upsert: Radiant checks them against NCBI and a stale id fails that row, reported for a manual fix. |
| infra | • The Keycloak grant is temporary; its removal is a rollout step, not a ticket. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • A QLIN interpretation on a transcript that is not Radiant's pick for the occurrence is stored but not flagged on the occurrence row. Is that acceptable, or should the dry-run report count them so the team decides? Proposal: count them in the report first. |
| portal (backend) | • Keep the lookup endpoint after the migration? Proposal: yes, it is small, generic and useful to any importer. |
| infra | • Who grants `geneticist` to `hybrid_system` in qlin-prod, and when? Proposal: the data manager through the users admin, right before the run. |

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
