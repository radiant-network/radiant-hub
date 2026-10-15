# RAD-xxxx: Serve labels in the user's language

## Story

- **Link:** **[ticket]**
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** `feat/rad-xxxx-label-localization`

## Chosen approach

**Summary:** the frontend sends the app language in `Accept-Language`. The API returns each label in that language, with an English fallback. The response shape does not change.

| Module | Approach |
|---|---|
| portal (backend) | • **Today:** labels come from `name_en` only. `ancestry`, `consanguinity`, `exam`, `role` and `action` already store a `name_fr` that nothing reads.<br>• **Locale:** a middleware binds `fr` or `en` to the request context, like the tenant. Default `en`. Responses carry `Vary: Accept-Language`.<br>• **Label helper:** returns `name_fr`, or `name_en` when empty. Every read in scope goes through it.<br>• **Raw codes:** six case entity fields return only a code. Each gets a `*_name` field (additive). |
| portal (frontend) | • **Header:** set from the app language, not the browser's.<br>• **Cache:** the SWR keys ignore the language, so a language switch revalidates every cached request.<br>• **Kept in i18n:** status, priority, affected status, case type, exam interpretation. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | request middleware, label helper, case entity, role and action reads, list facets, value-set migrations, OpenAPI spec, generated clients | new / modified |
| portal (frontend) | API client, i18n setup, case page, case preview, admin, translations | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Locale parameter | portal (backend) | Middleware, helper, `Vary`. First use: ancestry, consanguinity, exam names. Proven in Postman | — | yes (default `en`) |
| 2 | Language in the frontend | portal (frontend) | Header and SWR revalidation. Visible on the case page | Task 1 | yes |
| 3 | French value-set labels | portal (backend) | `name_fr` on 12 value sets (below), validated by the clinical team. Case category and task type through the helper. `*_name` for onset, sex, life status, sample type, histology, strategy. Proven in Postman | Task 1 | yes (additive) |
| 4 | Labels instead of codes | portal (frontend) | Case page and preview show the task 3 fields, onset badge included. Also fixes the raw `sex = unknown` key in the preview | Tasks 2, 3, UX on the onset badge | yes once 3 is deployed |
| 5 | Bilingual admin | portal (backend and frontend) | Role and action names and descriptions through the helper, shown in the admin screens | Tasks 1, 2 | yes |
| 6 | Family relationships (CLIN-6235) | portal (backend and frontend) | Complete `family_relationship` (7 codes, while the CLIN bridge writes up to 29) with `name_fr`. Foreign key from family history. `family_member_name` replaces the hard-coded frontend labels | Tasks 1, 2 | yes |
| 7 | French facets | portal (backend) | Case list, document and variant facets through the helper. Adds `name_fr` to `data_type` and `file_format`, the only facet tables without it. Proven in Postman | Tasks 1, 3, 6 | yes |

Task 3 value sets: `onset`, `sex`, `life_status`, `sample_type`, `histology_type`, `experimental_strategy`, `case_category`, `case_type`, `priority`, `affected_status`, `status`, `task_type`. The clinical review of the labels is part of task 3. Task 1 is cross-cutting: give it to an experienced developer, or pair on it.

## Merge and rollout order

1. Backend: task 1, then task 3. Without a header, the API answers in English, as today.
2. Frontend: task 2, then task 4, each after its backend task.
3. Tasks 5 and 6, after task 2. Task 7 after tasks 3 and 6. Before the task 6 foreign key, check on QA and prod that every stored family history code is in the table. Otherwise the migration fails and the API does not start.

No backfill. No feature flag.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **Tasks 1, 3, 5, 7:** integration tests on the case entity, the role list and the facets, with and without the header: French label, English fallback, English for an unknown language.<br>• **Task 6:** a code outside `family_relationship` is rejected. |
| portal (frontend) | • **Task 2:** unit test, the header follows the app language. |
| QA (manual) | • **Tasks 2, 4, 6:** in French, the case page shows no raw code and no English value-set label. A language switch updates it without a reload.<br>• **Task 5:** same check on the admin screens.<br>• **Task 7:** in French, the case list and document filters show French labels. |

## Risks and coverage

The story checks no business risk. The clinical wording is reviewed in task 3.

## Frozen scope

| Module | Not covered |
|---|---|
| all | • **HPO in French:** a follow-up story. A French HPO exists ([Gargano et al., 2024](https://doi.org/10.1093/nar/gkad1005)); our loader downloads only the English file (not verified).<br>• **MONDO:** stays in English. |
| portal (backend) | • **`GET /value_sets/:type`:** stays in English. Its only reader today is the organization category list in the admin.<br>• Other `name_en` reads: sequencing experiments.<br>• Instance entities (organizations, projects, panels, analysis catalog). |
| mcp | • No change: no header, English labels. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **Radiant team agreement**, before task 1: this reverses the rule "store both languages, return English". |
| portal (backend) | • Does the StarRocks JDBC catalog see a new `name_fr` column without a metadata refresh? Check on QA. |
| Labels | • Fill `name_fr` for the three value sets that the frontend translates (status, priority, affected status)? Nothing reads it in this story. Proposal: yes, for consistency.<br>• "Affecté" or "Atteint" for `affected_status`? |
| portal (frontend) | • **Onset badge:** the French labels are long. Short label with the full one in a tooltip? |

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
