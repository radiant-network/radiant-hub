# RAD-243: Search by variant in the Variant facet

## Story

- **Link:** [RAD-243](https://ferlab-crsj.atlassian.net/browse/RAD-243) (epic [RAD-5](https://ferlab-crsj.atlassian.net/browse/RAD-5))
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** portal only, one branch per task, named after its Jira sub-task (`feat/rad-xxxx`, no suffix, for the frontend ferlease preview).

## Chosen approach

**Summary:** a new portal endpoint looks up the typed identifier among the variants of the run on screen. The frontend adds the HGVSg of each match to a `Variant ID` pill, which filters on the existing `hgvsg` field. The occurrence list, count and aggregate do not change.

### portal (backend)

- **Accepted identifiers:** locus, HGVSg, dbSNP ID (rsID) and ClinVar ID, as listed in the story.
- **Lookup:** the ETL already stores the four values on each row of `<tenant>_tenant.snv__variant`. The endpoint matches the input against `locus`, `hgvsg` and `clinvar_name` there, and against `rsnumber` in the shared `dbsnp` table.
  - `locus` is `chrom-pos-ref-alt`, without `chr` (e.g. `8-43159045-G-A`).
  - `hgvsg` is the VEP HGVSg of the picked consequence (e.g. `chr7:g.140753336A>T`). An indel is written in [HGVS notation](https://hgvs-nomenclature.org/stable/recommendations/DNA/deletion/) (`del`, `ins`, `dup`, without the VCF anchor base), so the input is matched against `hgvsg` as a whole string.
  - `clinvar_name` holds the ClinVar variation ID (e.g. `13961`).
- **Every variant of an rsID:** `dbsnp` holds every `(locus_id, rsnumber)` pair, so a multi-allelic rsID returns all its variants, and a variant with several rsIDs is found by any of them. `snv__variant.rsnumber` keeps one rsID per variant.
- **Routes:** `POST /{tenant}/occurrences/germline/snv/{case_id}/{seq_id}/{task_id}/search` and the same under `somatic/snv`, for tumor-normal and tumor-only. Body `{ "value": "rs334" }`: an HGVS holds `>` and `:`, so the value goes in the body, as for the gene search.
- **Response:** every match, no limit, each with its `hgvsg` (for the pill) and `locus` (to name a match without HGVSg, see open questions). An empty list when nothing matches, never an error.
- **Scope:** the run on screen. The lookup starts from the run's occurrences, with the same filters as the occurrence list: sequencing (the tumor sequencing for somatic), task and partition. It then joins `snv__variant` and `dbsnp` on `locus_id`.
- **Cost:** `dbsnp` holds the whole of dbSNP and is distributed by `locus_id`, colocated with the occurrences. The join from the run's loci stays local and reads only those loci.
- **Case-insensitive:** the endpoint normalises the input, so the columns are compared as stored:
  - rsID: lower-case prefix (`RS334` → `rs334`);
  - locus: optional `chr` removed, upper-case;
  - HGVSg: `chr` and `g.` lower-case, nucleotides upper-case;
  - ClinVar: the variation ID only, digits (PO decision).
- **Access:** the lookup runs with the same identity as the occurrence queries: the calling user when per-user StarRocks reads are on (`STARROCKS_PROXY_READ_ENABLED`, Ranger applies), the portal's own connection otherwise. This is the first portal read of `dbsnp` (see rollout order).
- **Contract:** additive. Swagger, TS client and Python client regenerated.

### portal (frontend)

- **Facet:** a new filter type at the top of the existing `variant` group: a text input and a submit button, no autosuggest. It sits in the same slot as the gene search. The input is cleared and keeps the focus after each submit.
- **Config:** the `variant` group of the germline SNV occurrences in the four portal configs (`radiant`, `qlin`, `include`, `kf`), and of the somatic SNV occurrences in the three that have somatic filters (`radiant`, `qlin`, `include`; `kf` has none). Tumor-normal and tumor-only share that config. SNV tab only.
- **Pill:** field `hgvsg`, operator `in`, one HGVSg per value. The pill shows the HGVSg, as the « Variant » column of the tables does (team decision). `hgvsg` is already a filter of the germline and somatic SNV occurrences, so the list, count and aggregate apply it as is.
- **No dropdown:** the pill uses the existing search pill, as the gene search does. Deleting it removes the filter.
- **Append:** the pill update replaces its values, so the facet reads the current values, adds the new HGVSg values without duplicates and sends the full list, as the gene search does. Values are OR'd.
- **Run change:** the pill stays when the user switches run (another member or analysis), like the rest of the query (PO decision). Its HGVSg values filter the new run.
- **Labels:** EN and FR for the facet title, the placeholder, the tooltip (accepted formats) and the pill label, in the same task as the facet.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | `search` routes for germline and somatic SNV, `dbsnp` table definition, input normalisation, swagger, generated TS and Python clients | new |
| portal (frontend) | new facet type, search pill routing, SNV facet config of the four portals, EN/FR labels | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Search API | portal (backend) | Germline and somatic `search` routes, run-scoped lookup on `snv__variant` and `dbsnp`, input normalisation, swagger and clients, tests | — | yes (no caller yet) |
| 2 | Facet and pill | portal (frontend) | Input and submit facet in the `variant` group, append to one `hgvsg` pill, no dropdown, clear and focus after submit, EN/FR labels | Task 1 | yes, once task 1 is deployed |

No UX task: the facet uses the slot of the gene search, and the pill is the existing search pill. No Labels task: the labels ship with the facet that uses them.

## Merge and rollout order

1. portal backend: task 1. In each environment where per-user reads are on, check that a user account reads `dbsnp` (Ranger policy), as it reads the other shared tables. Without it, every rsID search fails.
2. portal frontend: task 2, after step 1 in the same environment. Without the route, every submit fails.

No migration, no backfill, no feature flag: the ETL already loads every column used.

## Test strategy

AC numbers follow the order of the story's acceptance criteria.

### portal (backend)

- **AC1:** StarRocks integration tests on a fixture with one variant per identifier type, germline and somatic. A multi-allelic rsID returns all its variants. A variant of another run of the case is not returned.
- **AC2:** unit tests of the normalisation, one per identifier format.
- **AC3:** an unknown value returns an empty list.
- **AC4, AC5:** the `hgvsg` filter with several values returns each variant.

### portal (frontend)

- **AC5:** unit tests of the append logic (merge, no duplicates). No component or render tests (team norm).

### QA (manual)

- **AC1 to AC7:** on the ferlease, on a germline case and a somatic case: one search per identifier type, a second search, then the pill deleted. Screenshots of the input and the pill in the PR, as the story asks.

## Risks and coverage

The story checks no risk.

## Frozen scope

### all

- Gene symbol, gene alias, AA change, Ensembl and RefSeq IDs.
- Search across several runs of the case: another ticket if needed.
- Variant list upload, autosuggest, removing one variant from the pill (story's out of scope).
- CNV tab.

### portal (backend)

- No new query field and no change to the occurrence list, count or aggregate.
- Locus with `:` separators (`8:43159045:G:A`).
- ClinVar accession (`VCV000013961`).

## Open questions

### story / product

- **AC4 and the scope of the story say `Variant ID = <locus>`.** **Proposal:** update them to the HGVSg, the team's decision.
- **What the input shows.** The team said the HGVSg shows « in the pill and in the input of the facet », but AC6 clears the input after each submit. **Proposal:** keep AC6; the HGVSg shows in the pill.
- **Matches without HGVSg.** `hgvsg` can be empty, and such a match cannot go into the pill. **Proposal:** skip it and name its locus in a message. To confirm with a count on QA data (not verified).

## Approval

| | |
|---|---|
| Reviewer | **[Name]** |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

Filled in during implementation, every time an out-of-plan need shows up. Two possible outcomes, no others.

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
