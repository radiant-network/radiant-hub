# RAD-267: Sync QLIN variant interpretations into Radiant

## Story

- **Link:** [RAD-267](https://ferlab-crsj.atlassian.net/browse/RAD-267), sub-tasks [RAD-268](https://ferlab-crsj.atlassian.net/browse/RAD-268) (roles and configuration), [RAD-270](https://ferlab-crsj.atlassian.net/browse/RAD-270) (hybrid sync endpoint), [RAD-314](https://ferlab-crsj.atlassian.net/browse/RAD-314) (author names kept on the interpretation POST). [RAD-269](https://ferlab-crsj.atlassian.net/browse/RAD-269) (variant lookup endpoint) is cancelled: the search by variant of [RAD-284](https://ferlab-crsj.atlassian.net/browse/RAD-284) covers it
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-314` (portal), `feat/rad-270-interpretations-sync` (hybrid), `feat/rad-268-interpretations-sync-config` (localstack)

## Chosen approach

**Summary:** hybrid (`clin-qlin-me-hybrid`, the QLIN backend that bridges prescriptions to Radiant) gets a manual endpoint `POST /api/v1/radiant/sync/interpretations` that replays, per analysis, the interpretations stored in the on-prem `radiant-api` v1.1.4 into Radiant through its public API. The legacy rows are keyed by QLIN ids (ServiceRequest id, locus string); Radiant keys an interpretation by `(case_id, sequencing_id, locus_id, transcript_id)` with its own `seq_id` and a numeric `locus_id` that lives only in StarRocks. Hybrid resolves the first two through FHIR and the existing case endpoints. The numeric `locus_id` comes from the search by variant of the run (RAD-284, already in the portal), which returns the `locus_id` of each variant found. No new Radiant endpoint. The content of each row (classification, criteria, modes, text, pubmed, metadata, author names, timestamps) is copied as is through the existing v2 interpretation upsert.

A restore of the legacy Postgres dump was ruled out: the key changed, `locus_id` cannot be computed outside StarRocks (long indels fall back to a lookup table), and the dump sits on the on-prem S3 that the AWS cluster cannot reach.

### portal (backend)

- **Variant search (existing, RAD-284):** `POST /{tenant}/occurrences/{germline|somatic}/snv/{case_id}/{seq_id}/{task_id}/search`, body `{"input": "<locus>"}`. It looks one identifier up, with an exact match, among the variants of one run (case, sequencing, task), and answers 200 in every case with a `status`: `found`, `not_found_in_run` or `unrecognized_format`. Each variant found carries its `locus_id` as a string (a signed 64-bit hash, to be kept opaque). In somatic, `seq_id` is the tumor sequencing. A wrong `seq_id` or `task_id` answers `not_found_in_run` like an absent variant does. Nothing to build here.
- **Author names on import (RAD-314):** the v2 interpretation POST sets `created_by` and `updated_by` from the token subject and today overwrites the names with the token's `name` claim. A service account carries no name: in that case the names of the body are kept. A user token still overrides them, nothing changes for the portal. On an update the repository keeps the creator of the existing row, so a row first written before this change keeps an empty creator name: the change must be deployed before the first run.
- **Readers:** no contract change. The request and response of the interpretation POST keep their shape.

### hybrid

- **Endpoint:** `POST /api/v1/radiant/sync/interpretations`, body `{"analysis_ids": [...]}`, answers 202 and runs on the Radiant executor pool with the same in-flight dedup as the existing case sync. Restricted to the `clin_system` role. 503 when the Radiant bridge is off. No dry run: every call writes, and the upsert makes a replay harmless.
- **Legacy read:** one new config `RADIANT_LEGACY_URL`. Hybrid calls `GET /interpretations/germline?analysis_id=` and `/somatic` on the legacy API with the caller's token forwarded verbatim. The legacy API gates on the realm role `clin_genetician`, so the controller refuses a token that lacks it before any call.
- **Key resolution:**
  - Once per analysis: the FHIR analysis gives the sample of each sequencing ServiceRequest; the case search on `submitter_case_id` gives the `case_id`; the case detail gives the `seq_id` of each sample and the tasks of the case.
  - Task: the search reads the variants of one task. Hybrid keeps the `radiant_germline_annotation` or `radiant_somatic_annotation` tasks of the case (registered by the Radiant pipeline, never sent by hybrid), newest first, and tries them in that order. A case with none has not been through the Radiant pipeline: its rows are reported and no search runs.
  - Once per variant of a sequencing: the variant search gives the `locus_id` of the locus string.
  - A row whose key is not fully resolved is never posted: it is listed in the run report with its reason and the other rows of the analysis still land.
- **Upsert:** the existing v2 `POST /{tenant}/interpretations/v2/{germline|somatic}/{case}/{seq}/{locus}/{transcript}`. The body copies the legacy content and its metadata (QLIN analysis, patient and variant hash ids, kept for tracing), the author display names, and the timestamps re-emitted in UTC. Author ids become the hybrid service account. The upsert is idempotent, a second run updates in place.
- **Report:** per analysis, counts of germline, somatic, upserted and skipped rows, plus one line per skipped row, in the same run report as the case sync (hybrid logs only). A row not found names the case, sequencing and tasks searched, since a wrong id and an absent variant look the same.
- **Radiant spec:** the vendored copy of the portal OpenAPI spec is refreshed to get the search route. The refresh also brings an unrelated change: `status_code` of the sequencing experiment batch went from an enum to a string, adapted in the mapper with the same value on the wire.

### infra

- **Keycloak (CLIN realm):** temporary realm role `clin_genetician` on the `clin-system` service account, plus the role mapper the client needs because it has full scope disabled. Terraform in the pre-prod (qa, staging) and prod service-configuration repos. Reverted after the migration.
- **Radiant auth_db (qlin-qa, qlin-prod):** role `geneticist` on organization `*` for the `hybrid_system` account, because the v2 POST requires `can_interpret_variant`, carried by that role only. Set through the Radiant users admin, not versioned.
- **Kubernetes:** `RADIANT_LEGACY_URL` on the hybrid ConfigMap of qa, staging and prod, pointing to the on-prem radiant-api of the environment.
- **Localstack:** the same two grants in the realm import and the Radiant seed, a WireMock stub of the legacy API with one hit and one miss fixture, and the URL in the hybrid env. Localstack runs no Radiant pipeline, so a case synced by hybrid has no annotation task there: the found path needs a task and an occurrence added by hand, or QA.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | interpretation handler (author names) | modified |
| hybrid | Radiant controller and routes, legacy radiant-api client, vendored Radiant spec, interpretation mapper and sync service, run report, configuration, docs | new / modified |
| infra | CLIN Keycloak Terraform (qa, staging, prod), Radiant auth_db grants, hybrid ConfigMaps (qa, staging, prod) | modified |
| localstack | Keycloak realm import, Radiant seed, legacy API stub, hybrid env | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Roles and configuration (RAD-268) | infra, localstack | Keycloak grant, auth_db grant, ConfigMaps, localstack stub and seeds | … | yes: inert until the endpoints exist |
| 2 | Author names kept on the interpretation POST (RAD-314) | portal (backend) | Author-name rule on the v2 POST, tests | … | yes |
| 3 | Hybrid sync endpoint (RAD-270) | hybrid | Legacy client, key resolution through the variant search, mapper, sync service, report, controller, config, tests, docs | Task 2 before the first run (author names) | yes: the endpoint answers 503 while the bridge is off |

No UX task: nothing is shown. No Labels task: no new user-visible text, the report is an operator log.

## Merge and rollout order

1. portal (backend): merge task 2, deploy on qlin-qa then qlin-prod. Without it the rows land with empty author names, and a replay does not repair a row already created (see the author-name rule).
2. infra: apply the Keycloak grant per environment, grant `geneticist` to `hybrid_system` in the auth_db, apply the ConfigMaps. Without the Keycloak grant the legacy API answers 403 to hybrid; without the auth_db grant Radiant refuses the upsert with 403.
3. hybrid: merge task 3, deploy on qa, staging, prod.
4. Run: extract the distinct analysis ids from the legacy database, run the case sync on the ids not yet in Radiant, wait for the Radiant pipeline to annotate those cases, then run the interpretation sync on chunks of about 50 ids and read the report in the hybrid logs. Chunks stay under the token lifetime (5 minutes). Re-run the skipped ids once their case has an annotation task and their variants are in the run.
5. Revert the Keycloak grant once the migration is accepted.

No migration, no feature flag beyond the existing Radiant bridge mode. No backfill: the run is the backfill.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1 (locus resolution):** covered by the tests of the search by variant (RAD-284), which assert the `locus_id` of each variant found, germline and somatic.<br>• **AC7 (author names):** handler tests, one with a user token that overrides the names, one with a nameless token that keeps them in germline, one in somatic. |
| hybrid | • **AC1 (locus resolution):** service tests on the variant search: germline and somatic routes, `locus_id` kept as a string (negative value), older tasks tried when the newest misses, no task carrying the locus, a value Radiant does not recognize. Service tests on the case detail: `seq_id` per sample, annotation tasks newest first, a case never annotated.<br>• **AC2, AC3 (content and idempotence):** unit tests of the mapper (every field, key as strings, timestamps normalised or dropped) and of the sync service with mocked FHIR, legacy and Radiant clients.<br>• **AC4 (unresolved rows):** sync service tests for a missing case, a ServiceRequest absent from the analysis, an unmatched sample, a case without annotation task, a locus absent from the run, a failed search, a refused upsert: only that row is skipped, the report names it.<br>• **AC5 (dry run):** dropped, see the open questions.<br>• **AC6 (role):** controller tests: 403 without `clin_system`, 403 when the token lacks `clin_genetician`, 503 when the bridge is off. |
| QA (manual) | • One analysis with legacy interpretations, synced as a case and annotated by the Radiant pipeline: the run writes the rows, the Radiant case shows them with the QLIN author name, a second run changes nothing.<br>• One analysis with a locus absent from the run: the row is in the report with the case, sequencing and tasks searched, the others landed.<br>• One analysis whose case is not annotated yet: every row is reported, nothing is written. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data | Interpretation text and QLIN ids transit through hybrid in memory only. Logs carry analysis ids and the resolved key, never the text. The legacy API is read with the caller token, so access stays what it is today. |
| Clinical rules or interpretation | Classification, criteria, transmission modes, oncogenicity and text are copied without transformation. A row on a transcript other than the one Radiant picked for the occurrence is stored and visible on the variant page, not flagged on the occurrence row (open question). |
| Traceability and audit | Author display names and original timestamps are preserved on the Radiant row, provided RAD-314 is deployed before the first run. Author ids are the hybrid service account; the legacy database keeps the original ids. |
| Interoperability | Four systems in one run: legacy radiant-api, FHIR, Radiant case and interpretation endpoints, the variant search. Each failure is reported per row with its origin and status, nothing is written on a partial key. The search answers "not found" for a wrong sequencing or task id as for an absent variant: hybrid takes both ids from the case detail and the report names them. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No continuous sync: interpretations edited in QLIN after the run need another run on the same ids.<br>• No author id mapping between the CLIN and Radiant realms. |
| portal (backend) | • No new endpoint: the search by variant is used as it is, one identifier per call, scoped to a run.<br>• No search by variant hash or on structural variants.<br>• No import route with author passthrough beyond the names. |
| hybrid | • No dry run.<br>• An interpretation whose variant is in no annotation task of its sequencing is not written, even if the tenant knows the variant elsewhere.<br>• No upper bound on the number of ids per call beyond the executor pool, same as the case sync.<br>• No validation of PubMed ids before the upsert: Radiant checks them against NCBI and a stale id fails that row, reported for a manual fix. |
| infra | • The Keycloak grant is temporary; its removal is a rollout step, not a ticket. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • A QLIN interpretation on a transcript that is not Radiant's pick for the occurrence is stored but not flagged on the occurrence row. Is that acceptable, or should the report count them so the team decides? Proposal: count them in the report first.<br>• The story's AC5 asks for a dry run. It is dropped: the upsert is idempotent and the report already lists every row not written. To confirm, and to amend in the story. |
| portal (backend) | • Several annotation tasks on one case (re-annotation, tumor-only and tumor-normal on the same tumor): hybrid tries them all, newest first. Is the newest always the one the portal shows? Proposal: keep trying them all, it costs calls only on a miss. |
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
