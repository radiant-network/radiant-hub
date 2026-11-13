# RAD-243: Search by variant in the Variant facet

## Story

- **Link:** [RAD-243](https://ferlab-crsj.atlassian.net/browse/RAD-243) (epic [RAD-5](https://ferlab-crsj.atlassian.net/browse/RAD-5))
- **Assigned reviewer:** Jeremy Costanza
- **Status:** In review
- **Branch (all repos):** portal only, one branch per task, named after its Jira sub-task (`feat/rad-xxxx`, no suffix, for the frontend ferlease preview).
- **Acceptance criteria (AC),** as the story numbers them; the test strategy follows this numbering:
  1. **AC1:** a value matching a variant exactly on any of the listed fields (locus, HGVSg, dbSNP ID, ClinVar ID) returns that variant in the results table.
  2. **AC2:** matching is case-insensitive: `RS341` and `rs341` return the same result.
  3. **AC3:** a value with no exact match returns an empty result set, not an error. *Deviation:* a value absent from the run adds no value to the pill and the table stays unchanged, with « not found in this run » under the input (open question).
  4. **AC4:** the submitted value appears in the query pill as `Variant ID = <locus>`, whichever identifier was typed. *Deviation:* the pill holds the HGVSg, as the « Variant » column shows it (open question).
  5. **AC5:** a second submit adds its value to the same query pill, OR'd with the existing values, without replacing them.
  6. **AC6:** the input is cleared and focused after each submit.
  7. **AC7:** clicking the query pill opens no dropdown; deleting the query pill removes all its variants and the filter.

## Chosen approach

**Summary:** the story's method, scoped to the run on screen. The user types one full identifier (locus, HGVSg, rsID or ClinVar ID) in a `Search by variant` input of the Variant facet and submits. The backend looks it up with an exact match among the variants of the run (case, sequencing, task). Each variant found adds its HGVSg to a `Variant ID` pill on the existing `hgvsg` filter. A value absent from the run adds nothing and shows « not found in this run ». An autocomplete on the whole tenant was studied at the PO's request and is not kept (see alternatives considered and the appendix).

### portal (backend)

- **Accepted identifiers:** locus, HGVSg, dbSNP ID (rsID) and ClinVar ID, as listed in the story.
- **Source:** `<tenant>_tenant.snv__variant_partitioned`, joined to the run's occurrences (tech lead's proposal).
  - It is a copy of `snv__variant`, column for column, cut into variant parts: variant part `n` holds the variants that have an occurrence in the occurrence parts `10n` to `10n + 9` (`PARTS_PER_VARIANT_PART = 10` in the ETL). Filtering on the run's variant part reads a fraction of the tenant's variants, which matters most on the large production tenants (CHOP).
  - It holds the four identifiers: `locus`, `hgvsg`, `rsnumber`, `clinvar_name`.
  - `locus` is `chrom-pos-ref-alt`, without `chr` (e.g. `8-43159045-G-A`).
  - `hgvsg` is the VEP HGVSg of the picked consequence (e.g. `chr7:g.140753336A>T`). VEP shifts indels to the right, so an indel's HGVSg and locus differ in position: on QA, `chr1:g.30004963_30004966dup` is the locus `1-30004947-C-CAAAA`. The input is compared with `hgvsg` as typed, never rebuilt from a locus.
  - `rsnumber` holds one rsID per variant, taken from dbSNP allele by allele, not per site. On QA, of the 162,354 multi-allelic sites with an rsID, 64,227 have an allele that dbSNP gives no rsID and 51,643 have a different rsID per allele. An rsID therefore finds the alleles dbSNP links to it, not every allele of the site.
  - `clinvar_name` holds the ClinVar variation ID (e.g. `13961`).
  - The portal reads this table for the first time. The ETL rewrites only the variant part of the imported batch; the other parts keep their content until the next re-annotation, which rewrites them all. The identifiers only change at a re-annotation, so they should match `snv__variant`, which the pill filters (deduced from the ETL SQL, to confirm, see open questions).
- **Route:** `POST /{tenant}/occurrences/{germline|somatic}/snv/{case_id}/{seq_id}/{task_id}/search`, next to the run's `list`, `count` and `aggregate` routes, with the same middleware and action (`ActionSearchCase`). In somatic, `seq_id` is the tumor sequencing, as in the other somatic routes. Body: `{ "input": "rs334" }`.
- **Format detection,** on the trimmed input, case-insensitive:
  - `rs` then digits → rsID, on `rsnumber`;
  - digits only → ClinVar ID, on `clinvar_name` (all ClinVar IDs are numeric on QA);
  - a chromosome, `:`, `g.`, a position or a range (`100` or `100_102`) then a change: `A>T`, `del`, `ins`, `dup`, `inv` or `delins`, with bases where HGVS allows them → HGVSg, on `hgvsg`. A text that starts like an HGVSg but has no valid change (`7:g.hello`) is `unrecognized_format`. Every HGVSg of the sandbox (625,459) has this form;
  - a chromosome, `-` or `:`, a position, a reference and an alternate → locus, on `locus`;
  - anything else, an empty or missing input, or an input longer than 2,000 characters (the size of `hgvsg`) → `unrecognized_format`, no query. Only a malformed JSON body returns `400`.
- **Normalisation:**
  - rsID: lower-case prefix (`RS334` → `rs334`);
  - chromosome: `1` to `22`, `X`, `Y`, `M`; `MT` is accepted and turned into `M`, the form the tables store;
  - locus: optional `chr` removed, `:` separators turned into `-` (`8:43159045:G:A` → `8-43159045-G-A`), upper-case;
  - HGVSg: `chr` added when missing (`7:g.140753336A>T` → `chr7:g.140753336A>T`); `chr`, `g.` and the keywords `del`, `ins`, `dup`, `inv` lower-case; chromosome name upper-case (`X`, `Y`, `M`: `chrx:g.…` → `chrX:g.…`); bases upper-case (`CHR1:G.30004963_30004966DUP` → `chr1:g.30004963_30004966dup`);
  - ClinVar: the variation ID only, digits (PO decision).
- **Lookup:** an exact match (`=`) on the detected column, bound as a query parameter. The input is never used as a regular expression or a `LIKE` pattern; the gene search fails on an input such as `(`.

  ```sql
  -- :part from radiant.staging_sequencing_experiment (GetSequencingPart), as the other occurrence routes
  SELECT v.hgvsg, v.locus, v.rsnumber, v.clinvar_name, v.symbol, v.aa_change
  FROM <tenant>_tenant.snv__variant_partitioned v
  LEFT SEMI JOIN <tenant>_tenant.germline__snv__occurrence o
    ON  o.locus_id = v.locus_id
    AND o.part = :part AND o.seq_id = :seq_id AND o.task_id = :task_id
  WHERE v.part = :part DIV 10
    AND v.<column> = :value
  ORDER BY v.locus_id
  LIMIT 100;
  ```

  In somatic, `somatic__snv__occurrence` with `tumor_seq_id`. The two tables are in the same colocate group (except germline on `qlin_tenant`, see risks), so the join stays local to each tablet. `ORDER BY locus_id` follows the genomic order. The limit is a guard: an rsID or a locus finds one variant per allele, and a run rarely carries more than two at a site.
- **Response:** `200 OK` in every case, never an error for an unknown value (story AC3).

  | Field | Always set | Content | Frontend use |
  |---|---|---|---|
  | `status` | yes | `found`, `not_found_in_run` or `unrecognized_format` | Message under the input; a later ticket adds values (see frozen scope) without changing the route |
  | `matched_field` | when the format is recognised | `locus`, `hgvsg`, `rsnumber` or `clinvar_id` | Message wording (dbSNP, ClinVar…) |
  | `normalized_input` | when the format is recognised | the value looked up (`rs334`) | Message wording |
  | `variants` | yes, empty unless `found` | the variants of the run found | Pill values and confirmation |

  Fields of each variant, all from the same row of `snv__variant_partitioned`:

  | Field | Column | Always set | Frontend use |
  |---|---|---|---|
  | `hgvsg` | `hgvsg` | yes | Pill value |
  | `locus` | `locus` | yes | Confirmation, tells the alleles of a site apart |
  | `rsnumber` | `rsnumber` | no (84 % on QA) | Confirmation |
  | `clinvar_id` | `clinvar_name` | no (0.8 % on QA) | Confirmation. Named after its content, the ClinVar variation ID |
  | `symbol` | `symbol` | no (intergenic variants) | Confirmation (`HBB`) |
  | `aa_change` | `aa_change` | no | Confirmation (`p.Glu7Val`); searching by `p.` stays out of scope |

  Unset optional fields are omitted. On QA every variant has an HGVSg and no two variants share one, so a pill value designates exactly one variant.
- **Response time:** see the QA check below. One query per submit, not per keystroke.
- **Access:** the lookup runs with the same identity as the occurrence queries. The Ranger access policy of a tenant covers all its tables (`*`, `ranger_masking.go`), so `snv__variant_partitioned` needs no new policy.
- **Contract:** additive. Swagger, TS client and Python client regenerated.

**Checked on QA (2026-11-12).**

- The query plan joins `snv__variant_partitioned` to the run's occurrences locally on each tablet (`LEFT SEMI JOIN (COLOCATE)`) and reads only the run's variant part (`partitions=1/2` on `radiant_tenant`). Join checked in germline on `radiant_tenant` and in somatic on `cbtn_tenant`.
- On QA, the variant part of a run holds almost the whole tenant: 16,255,810 of the 16.3 million variants of `radiant_tenant`, whose runs sit in only two occurrence parts. The QA times are therefore a worst case; as an order of magnitude, an exact lookup on the whole `snv__variant` takes 6 to 34 ms (appendix). The gain of the variant parts shows only on tenants with many parts, as in production.
- The response time is checked during task 1: one measurement on the ferlease with a real run, recorded in the PR. A gap goes to the deviation log.

Example, with tenant `radiant` (made-up data):

```http
POST /radiant/occurrences/germline/snv/1226/1047/1000061/search
{ "input": "RS334" }

200 OK
{
  "status": "found",
  "matched_field": "rsnumber",
  "normalized_input": "rs334",
  "variants": [
    {
      "hgvsg": "chr11:g.5227002T>A",
      "locus": "11-5227002-T-A",
      "rsnumber": "rs334",
      "clinvar_id": "15333",
      "symbol": "HBB",
      "aa_change": "p.Glu7Val"
    }
  ]
}
```

A value of a known format absent from the run, `rs999999999`, returns `200 OK` with `"status": "not_found_in_run"` and `"variants": []`. An input such as `BRAF` returns `"status": "unrecognized_format"`.

### portal (frontend)

- **Facet:** a `Search by variant` label, an input and a submit button at the top of the existing `variant` group, as the gene search sits at the top of the `gene` group, and as in the story's Figma. No suggestions, no debounce.
  - A new filter type (e.g. `FilterTypes.SEARCH_BY_VARIANT`) with the key `search_by_hgvsg`: `FacetList` renders every `FilterTypes.SEARCH_BY` item as the gene search, and the `search_by_<field>` convention gives the pill field `hgvsg`.
  - The run comes from the facet config: facets reach their data through `useFacetConfig()` (`builderFetcher`), which the occurrence pages provide. The germline and somatic pages add a search function to it, bound to the case, sequencing and task on screen; the facet itself knows no run.
- **Submit:** Enter or the button calls the run's `search` route (germline or somatic tab, case, sequencing and task of the page).
  - `found`: the HGVSg values are appended to the `Variant ID` pill, OR'd with the existing values, without duplicates (story AC5). A confirmation line under the input names what was added (`rs334 → chr11:g.5227002T>A · HBB p.Glu7Val`). When several variants are found (alleles of one site), all are added and the line says so (`2 variants added: chr11:g.5227002T>A, chr11:g.5227002T>G`).
  - `not_found_in_run`: no pill; the line reads « rs334 not found in this run ».
  - `unrecognized_format`: no pill; the line lists the accepted formats.
  - The button and Enter are disabled while a search is pending, so a double submit sends one request.
  - The input is cleared and focused after each submit (story AC6).
  - The message line is a polite live region (`aria-live="polite"`) linked to the input (`aria-describedby`), so screen readers announce it (`frontend/docs/accessibility.md`).
- **Pill:** field `hgvsg`, operator `in`, one HGVSg per value, as the « Variant » column of the tables shows it. `hgvsg` is already a filter of the germline and somatic SNV occurrences, so the list, count and aggregate apply it as is:

  ```json
  { "op": "and", "content": [
    { "op": "in", "content": { "field": "hgvsg",
      "value": ["chr11:g.5227002T>A"] } } ] }
  ```

- **No dropdown:** clicking the pill opens nothing; deleting it removes all its variants and the filter (story AC7).
- **Values already in the pill:** their label is the value itself, the HGVSg. No call when the page opens.
- **Run change:** the pill stays when the user switches run (another member or analysis), like the rest of the query (PO decision). Its HGVSg values filter the new run.
- **Config:** the `variant` group of the germline SNV occurrences in the four portal configs (`radiant`, `qlin`, `include`, `kf`), and of the somatic SNV occurrences in the three that have somatic filters (`radiant`, `qlin`, `include`; `kf` has none). Tumor-normal and tumor-only share that config. SNV tab only.
- **Labels:** EN and FR for the facet title, the placeholder, the tooltip (accepted formats), the submit button's accessible name, the three messages and the pill label, in the same task as the facet.

### Alternatives considered

- **Autocomplete on the whole tenant** (studied at the PO's request, measurements in the appendix): suggestions of the tenant's variants whose identifier starts with the typed text. Not kept:
  - a prefix lookup reads the whole column on every keystroke (no page skipped by the zone maps), and its time grows with the table (×1.5 to 1.8 when the table doubles on QA). The production tables are much larger than QA's, and prefix search on variants needed custom structures on other projects, even with Elasticsearch (tech lead);
  - on rsIDs and ClinVar IDs a prefix brings mostly noise (`rs33` → `rs330`, `rs3300001`…); users paste a full identifier from a report;
  - what helped the use case was seeing the variants found before filtering, which the confirmation line keeps.
- **Exact search on the whole tenant** (`snv__variant`, without the run): not kept for V1. It would tell « unknown to the project » from « absent from this patient » and keep a pill for segregation from a non-carrier, at the cost of a second lookup on the whole tenant table, which reads the whole `rsnumber` column for an rsID. The run search answers the main question (« does this patient carry this variant? »); telling the two empty cases apart is a later ticket (see frozen scope).
- **Hybrid** (exact for rsID and ClinVar, prefix for locus and HGVSg): dropped with the autocomplete.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | germline and somatic SNV occurrence `search` route, format detection and normalisation, swagger, generated TS and Python clients | new |
| portal (frontend) | `Search by variant` input in the variant facet, SNV facet config of the four portals, EN/FR labels | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Search API | portal (backend) | Germline and somatic `search` routes, exact lookup on `snv__variant_partitioned` joined to the run's occurrences, format detection, normalisation, response with `status`, swagger and clients, test fixture for `snv__variant_partitioned` (none in `backend/test/data/sql/` today), tests | — | yes (no caller yet) |
| 2 | Variant search input | portal (frontend) | New `search_by_hgvsg` filter type, `Search by variant` input and submit button in the `variant` group, search function in the facet config of the germline and somatic pages, messages, `hgvsg` search pill, EN/FR labels | Task 1 | yes, once task 1 is deployed |

No UX task: the story links the Figma. No Labels task: the labels ship with the facet that uses them.

## Merge and rollout order

1. portal backend: task 1.
2. portal frontend: task 2, after step 1 in the same environment. Without the route, the search finds nothing.

No migration, no backfill, no feature flag: the ETL already loads every column used.

## Test strategy

AC numbers follow the order of the story's acceptance criteria.

### portal (backend)

- **AC1:** StarRocks integration tests on a fixture: an exact value of each identifier type returns its variant, germline and somatic; a variant of another run of the same case is not returned; an rsID returns every allele of the run dbSNP links to it; each variant carries the fields of the response.
- **AC2:** unit tests of the format detection and of the normalisation, one per identifier format, including `RS341` and `rs341`, a locus with `chr` or `:` separators, an HGVSg without `chr` and an indel HGVSg typed in upper case (`CHR1:G.30004963_30004966DUP`).
- **AC3:** a value of a known format absent from the run returns `200` with `not_found_in_run` and no variant; an input of no known format, or made of regular-expression characters such as `(`, returns `200` with `unrecognized_format`, never an error.
- **AC4, AC5:** the `hgvsg` filter with several values returns each variant.

### portal (frontend)

- **AC4, AC5:** unit tests of the pure mapping from a response to the pill values (appended, OR'd, no duplicate, several variants) and to the message. No component or render tests (team norm).

### QA (manual)

- **AC1 to AC7:** on the ferlease, on a germline case and a somatic case: one submit per identifier type, one value absent from the run, one invalid value, several submits into the same pill, the input cleared and focused, a run change with the pill kept, then the pill deleted. Screenshots of the input, the messages and the pill in the PR, as the story asks.

## Risks and coverage

| Risk | Coverage |
|---|---|
| `snv__variant_partitioned` out of step with `snv__variant` between two re-annotations, so a found HGVSg would not match the pill filter | Tech lead to confirm (open questions); AC1 integration test on the fixture; manual check on QA after an import |
| New coupling of the portal to `snv__variant_partitioned` and to the ETL's `PARTS_PER_VARIANT_PART = 10` | The constant is named once in the backend, next to `GetSequencingPart`; a change of the ETL constant breaks the search silently |
| Production times unknown: the QA tables are much smaller, and a QA variant part holds almost the whole tenant | Plan checked on QA; one query per submit; a measurement on the ferlease in the task 1 PR |
| rsID lookup reads the whole `rsnumber` column of the variant part (no link with the position, no index) | Limited to one variant part; measured in the task 1 PR |
| Pill value `hgvsg` instead of the story's `locus` (AC4) | Open question to the PO |
| On `qlin_tenant` (QA), `germline__snv__occurrence` is outside the colocate group, while `snv__variant_partitioned` is in it: the germline search join is not colocated there. `snv__variant` is outside the group too, so the existing germline occurrence queries are not colocated either | Same results, extra exchange cost; somatic is colocated. Reported to the tech lead; the fix belongs to the ETL |

## Frozen scope

### all

- Gene symbol, gene alias, AA change, Ensembl and RefSeq IDs.
- Variant list upload, removing one variant from the pill (story's out of scope).
- Autocomplete (story's out of scope, confirmed by the study).
- CNV tab.
- Telling apart, when the run has no match, « unknown identifier » (dbSNP, ClinVar), « known to the project but absent from this patient » and keeping a pill for that case (segregation from a non-carrier): later ticket, to create. The `status` field lets it add values without changing the route.

### portal (backend)

- Secondary rsIDs: a variant is found by the rsID kept in `snv__variant`, not by the other rsIDs dbSNP gives it. In `radiant_tenant`, 3,405 variants have more than one rsID in dbSNP, so 4,635 rsIDs cannot be found. The ETL keeps one of them with no ordering rule, so the kept rsID may change at a reload (read in the ETL code, not verified on data). An exact lookup in the shared `dbsnp` table answers in about 190 ms from memory and 500 ms from local disk on QA; it belongs to the later ticket.
- No new query field and no change to the occurrence list, count or aggregate.
- ClinVar accession (`VCV000013961`).

## Open questions

### story / product

- **Pill value (AC4):** the story asks `Variant ID = <locus>`; the spec uses `hgvsg`, an existing filter of the occurrences, as the « Variant » column shows it. `locus` would need a new query field. **Proposal:** HGVSg in the pill.
- **Value absent from the run (AC3):** the story asks for an empty result set. Here no value is added to the pill, so the table stays unchanged and shows the whole run, with « not found in this run » under the input. Telling a typo from a variant unknown to the project goes to a later ticket. **To confirm with the PO.**

### tech (tech lead)

- **`snv__variant_partitioned` freshness:** do its identifiers always match `snv__variant` between two re-annotations?
- **Production size:** row counts of `snv__variant` and `snv__variant_partitioned` on the largest production tenant (CHOP), to put a figure on the decision.

## Approval

| | |
|---|---|
| Reviewer | Jeremy Costanza |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

Filled in during implementation, every time an out-of-plan need shows up. Two possible outcomes, no others.

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |

## Appendix: autocomplete study (QA, 2026-11-10)

Measured at the PO's request, before the autocomplete was dropped. Every query reads the whole `snv__variant` of the tenant, without any run filter.

- **Tables:** `snv__variant` of `radiant_tenant`, 16.3 million variants (1.5 GB), and of `cypress_tenant`, 8.1 million (0.7 GB), to see how time grows with size. The two other QA tenants are too small to tell anything (173,412 and 302 variants). In `radiant_tenant`, every variant has an HGVSg, 84 % have an rsID (13,726,071) and 0.8 % a ClinVar ID (124,886).
- **Queries:** one per identifier type, on the whole table, without any run filter.
  - Search on submit (exact match, the story's original method): `=` on `locus`, `hgvsg`, `rsnumber`, `clinvar_name` (an ID present in the tenant); and an exact rsID through the shared `dbsnp` table, joined to `snv__variant` on `locus_id`, which also finds secondary rsIDs.
  - Autocomplete: `LIKE '<prefix>%'` on the same columns, ordered by length then value, limited to 25. A short prefix (`rs6`) and longer ones (`rs642`, `chr1:g.3`, `1-3000`, `139`).
  - The same `hgvsg` and `locus` prefixes as a range of values, and the shortest ranges studied (`chr1:g.`, `1-3`).
- **Protocol:** each query run three times with the memory cache off, then three times with it on, in the same window, with the `mysql` client on the StarRocks frontend node. The times are the server times the client prints: they leave out the network, the API and the proxy. The read counters come from the query profiles.
- **Caches:** the compute nodes keep table data at two levels, a memory page cache and a local disk cache in front of the object store.
  - Memory: both levels on, as in normal use; every page comes from memory.
  - Local disk: memory cache off for the measuring session only (`use_page_cache = false`, `skip_page_cache = true`, `populate_datacache_mode = 'never'`). The profiles show every page read from the local disk cache and 0 bytes from the object store; `enable_scan_datacache = false` has no effect on these tables.
  - Object store (true cold, after a restart or an eviction from both levels): not measured. It cannot be measured on QA without writing to the cluster, which is ruled out.
- **Rows and bytes read (profiles, `radiant_tenant`):**
  - A prefix lookup (`LIKE 'x%'`) reads all 16.3 million rows, whatever the column: no page is skipped by the zone maps, the short key index or a bloom filter.
  - An exact lookup on `hgvsg` or `locus` reads only 8 % of the rows: the zone maps skip the other 92 %. The table is sorted by `locus_id`, which follows the genomic order, so the `hgvsg` and `locus` values of a page are close to each other. An exact lookup on `rsnumber` reads everything: rsIDs have no link with the position.
  - The same prefix written as a range (`hgvsg >= 'chr1:g.3' AND hgvsg < 'chr1:g.4'`) returns the same rows and lets the zone maps work on `hgvsg` and `locus`.

| Query | Rows read | Rows skipped by zone maps | Rows matched | Bytes read (uncompressed / compressed) |
|---|---|---|---|---|
| exact locus (SNV) | 1,419,631 | 14,836,194 | 1 | 35 MB / 24 MB |
| exact locus (indel) | 1,285,668 | 14,970,157 | 1 | 32 MB / 22 MB |
| exact HGVSg (SNV) | 1,364,618 | 14,891,207 | 1 | 45 MB / 28 MB |
| exact HGVSg (indel) | 1,361,950 | 14,893,875 | 1 | 45 MB / 28 MB |
| exact rsID | 16,255,825 | 0 | 1 | 209 MB / 155 MB |
| exact ClinVar | 1,623,443 | 0 | 1 | 34 B / 1.3 MB |
| prefix `rs6` | 16,255,825 | 0 | 1,019,254 | 591 MB / 359 MB |
| prefix `chr1:g.3` | 16,255,825 | 0 | 58,265 | 391 MB / 204 MB |
| prefix `1-3000` | 16,255,825 | 0 | 82 | 321 MB / 203 MB |
| prefix `139` | 16,255,825 | 0 | 99 | 1.3 MB / 4.2 MB |
| range `chr1:g.3` | 1,419,361 | 14,836,464 | 58,265 | 46 MB / 29 MB |
| range `1-3000` | 1,285,668 | 14,970,157 | 82 | 32 MB / 23 MB |
| range `chr1:g.` (shortest HGVSg) | 2,406,860 | 13,848,965 | 1,267,751 | 69 MB / 41 MB |
| range `1-3` (shortest locus) | 1,320,754 | 14,935,071 | 58,265 | 74 MB / 51 MB |

Times of the ranges, from local disk then from memory: `chr1:g.3` 17 and 13 ms, `1-3000` 15 and 14 ms, `chr1:g.` 21 and 15 ms, `1-3` 20 and 14 ms. With `LIKE`, `chr1:g.3` takes 34 and 16 ms. In the profiling run, `rs642` took 44 ms from local disk and 25 ms from memory.

- **Query plan:** one source, `snv__variant`, with no join. The filter applies while the table is read, in parallel on its 10 tablets. Each tablet sorts its matches by length then value and keeps its best 25 (local top-N); one node merges these lists into the final 25, which is exact because each list is already sorted. No Ranger row filter or mask applies to this table: the portal sends the query unchanged.

| Query | Tenant | Local disk (3 executions) | Memory (3 executions) | Disk / memory |
|---|---|---|---|---|
| exact locus | radiant | 16 / 9 / 9 ms | 7 / 7 / 7 ms | 1.3 |
| exact HGVSg | radiant | 10 / 10 / 9 ms | 7 / 6 / 6 ms | 1.7 |
| exact rsID | radiant | 27 / 26 / 26 ms | 14 / 14 / 14 ms | 1.9 |
| exact ClinVar | radiant | 34 / 20 / 19 ms | 19 / 19 / 20 ms | 1.1 |
| exact rsID through `dbsnp` | radiant | 510 / 496 / 501 ms | 187 / 189 / 254 ms | 2.7 |
| prefix `rs6` | radiant | 65 / 63 / 62 ms | 30 / 31 / 31 ms | 2.0 |
| prefix `rs642` | radiant | 38 / 39 / 38 ms | 21 / 21 / 21 ms | 1.8 |
| prefix `chr1:g.3` | radiant | 34 / 34 / 34 ms | 16 / 16 / 16 ms | 2.1 |
| prefix `1-3000` | radiant | 34 / 34 / 34 ms | 16 / 16 / 18 ms | 2.1 |
| prefix `139` | radiant | 23 / 24 / 23 ms | 22 / 22 / 22 ms | 1.0 |
| prefix `rs6` | cypress | 35 / 35 / 34 ms | 18 / 18 / 19 ms | 1.9 |
| prefix `chr1:g.3` | cypress | 21 / 21 / 21 ms | 12 / 11 / 11 ms | 1.9 |

The ratio compares the medians of the three executions.

- **Reading:**
  - On QA, both methods answer well under a 300 ms debounce on `snv__variant`, from memory or from local disk; the difference shows in the rows read, which grow with the table for a prefix. Only the `dbsnp` lookup is slower: about 190 ms from memory, 500 ms from local disk.
  - Reading from local disk instead of memory doubles the time of a prefix lookup (ratio 1.8 to 2.1), except on ClinVar: 99 % of its values are empty, so the column weighs about 4 MB and its read time hardly counts.
  - The local-disk times are a floor for a true cold read, not an estimate of it: a cold prefix lookup reads 155 to 359 MB compressed from the object store, at a cost not measured here. Written as a range, a prefix on `hgvsg` or `locus` reads 7 to 9 times fewer compressed bytes (23 to 29 MB instead of 203 to 204 MB).
  - Cache misses may come more often than after a restart. The compute nodes share their caches with every occurrence query, and `rsnumber` and `clinvar_name` are rarely read elsewhere, so they are probably among the first columns evicted (deduced, not measured). In production, an rsID lookup may often read from local disk (under 45 ms on QA at the minimum length) or from the object store (not measured).
  - Doubling the table (cypress to radiant) multiplies the prefix time by 1.5 to 1.8, from memory or from local disk. If a production table were four times larger than QA's (a hypothesis: the production size is not known here), the costliest lookup measured (`rs6`, below the minimum length) would take about 100 ms from memory and 200 ms from local disk.
