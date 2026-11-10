# RAD-243: Search by variant in the Variant facet

## Story

- **Link:** [RAD-243](https://ferlab-crsj.atlassian.net/browse/RAD-243) (epic [RAD-5](https://ferlab-crsj.atlassian.net/browse/RAD-5))
- **Assigned reviewer:** **[Name]**
- **Status:** Draft
- **Branch (all repos):** portal only, one branch per task, named after its Jira sub-task (`feat/rad-xxxx`, no suffix, for the frontend ferlease preview).

## Chosen approach

**Summary:** an autocomplete in the Variant facet suggests the variants known to the tenant whose locus, HGVSg, rsID or ClinVar ID starts with the typed text. Each picked variant adds its HGVSg to a `Variant ID` pill on the existing `hgvsg` filter, which then filters the run on screen. The PO asked for this autocomplete after the grooming, in place of the search on submit of the story (see open questions).

### portal (backend)

- **Accepted identifiers:** locus, HGVSg, dbSNP ID (rsID) and ClinVar ID, as listed in the story.
- **Source:** the ETL already stores the four values on each row of `<tenant>_tenant.snv__variant`: `locus`, `hgvsg`, `rsnumber`, `clinvar_name`. The table holds one row per distinct variant of the tenant, germline and somatic. It is a base table, not a view. The lookup reads only this table, with no join (see the query plan below).
  - `locus` is `chrom-pos-ref-alt`, without `chr` (e.g. `8-43159045-G-A`).
  - `hgvsg` is the VEP HGVSg of the picked consequence (e.g. `chr7:g.140753336A>T`). VEP shifts indels to the right, so an indel's HGVSg and locus differ in position: on QA, `chr1:g.30004963_30004966dup` is the locus `1-30004947-C-CAAAA`. The input is compared with `hgvsg` as typed, never rebuilt from a locus.
  - `rsnumber` holds one rsID per variant, taken from dbSNP allele by allele, not per site. On QA, of the 162,354 multi-allelic sites with an rsID, 64,227 have an allele that dbSNP gives no rsID and 51,643 have a different rsID per allele. An rsID therefore finds the alleles dbSNP links to it, not every allele of the site. Every stored rsID is one that dbSNP gives the variant (no exception on QA).
  - `clinvar_name` holds the ClinVar variation ID (e.g. `13961`).
- **Route:** `GET /{tenant}/variants/snv/autocomplete?prefix=…&limit=…`, the shape of the gene autocomplete (`GET /genes/autocomplete`). No case, sequencing or task: one route for germline and somatic, tumor-normal and tumor-only.
- **Format detection,** on the trimmed input, case-insensitive:
  - `rs` then digits → rsID, on `rsnumber`;
  - digits only → ClinVar ID, on `clinvar_name` (all ClinVar IDs are numeric on QA);
  - a chromosome, `:` then `g` → HGVSg, on `hgvsg`;
  - a chromosome, `-` or `:`, then a digit → locus, on `locus`;
  - anything else → no suggestion.
  One flow for the four identifiers: no separate exact search.
- **Normalisation:**
  - rsID: lower-case prefix (`RS334` → `rs334`);
  - locus: optional `chr` removed, `:` separators turned into `-` (`8:43159045:G:A` → `8-43159045-G-A`), upper-case;
  - HGVSg: `chr` added when missing (`7:g.140753336A>T` → `chr7:g.140753336A>T`), `chr` and `g.` lower-case, nucleotides upper-case;
  - ClinVar: the variation ID only, digits (PO decision).
- **Lookup:**
  - rsID and ClinVar ID: `LIKE` on the prefix. The detected input holds only `rs` and digits, so it has no wildcard to escape.
  - Locus and HGVSg: a range of values, from the prefix up to the prefix with its last character incremented (`chr1:g.3` → `chr1:g.4`). It returns the same rows as `LIKE`, lets the zone maps skip pages (7 to 9 times fewer bytes read, measured below) and treats `_` as a plain character; 14 % of HGVSg contain one.
  - The input is never used as a regular expression; the gene search fails on an input such as `(`.
- **Minimum length, per format:**
  - rsID: `rs` and 3 digits (`rs642`). `rs6` matched 1 million variants and read 359 MB;
  - ClinVar ID: 3 digits;
  - locus: the chromosome, the separator and the first digit of the position (`1-3`);
  - HGVSg: the chromosome, `:g.` and the first digit of the position (`chr1:g.3`).
- **Order and limit:** by the length of the matched value, then the value, so the exact match comes first and `rs642002` comes before `rs6420001`. 25 suggestions by default, as for genes.
- **Response:** the `highlight` / `source` shape of the gene, HPO and MONDO autocompletes, with a variant type in `source` and no `highlight`: the backend sends no HTML, and the frontend bolds the typed prefix in `matched` itself. The fields of `source`, all read from the same row of `snv__variant`:

  | Field | Column | Always set | Frontend use |
  |---|---|---|---|
  | `hgvsg` | `hgvsg` | yes | Pill value, and the second line of the suggestion, which shows the conversion |
  | `matched` | the column that matched | yes | First line of the suggestion, with the typed prefix in bold |
  | `matched_field` | — | yes: `locus`, `hgvsg`, `rsnumber` or `clinvar_id` | Translated prefix of the first line (dbSNP, ClinVar…); the frontend does not detect the format again |
  | `locus` | `locus` | yes | Tells the alleles of a site apart, and an indel whose HGVSg is shifted |
  | `rsnumber` | `rsnumber` | no (84 % on QA) | Shown when the variant was found by locus or HGVSg |
  | `clinvar_id` | `clinvar_name` | no (0.8 % on QA) | Same. Named after its content, the ClinVar variation ID; the column keeps its name |
  | `symbol` | `symbol` | no (intergenic variants) | Reading context (`HBB`) |
  | `aa_change` | `aa_change` | no | Reading context (`p.Glu7Val`); searching by `p.` stays out of scope |
  | `locus_id` | `locus_id` | yes | Unused in V1. Kept for a later "present in this run" marker, so the contract does not change. A string, as in the occurrence types: an int64 does not fit a JavaScript number |

  Left out: `hgvsc`, `hgvsp` and `transcript_id` (they depend on the picked consequence), `chromosome`, `start`, `reference` and `alternate` (in `locus`), frequencies and pathogenicity (they need joins). Unset optional fields are omitted. Variants without HGVSg are not suggested. On QA every variant has an HGVSg and no two variants share one, so a pill value designates exactly one variant. An empty list when nothing matches, never an error.
- **Scope:** every variant known to the tenant, not only the run on screen. A suggested variant can be absent from the run: once picked, the pill filters the run and the list is empty, which answers « this case does not carry this variant ».
- **Response time, measured on QA:** on the largest QA tenant (16.3 million variants), a lookup at the minimum length answers in 13 to 22 ms with the data in memory and 15 to 44 ms when it comes from the compute nodes' local disk cache. With the frontend's 300 ms debounce, the suggestions show in under 0.4 s. A read from the object store (true cold) was not measured. Methodology and figures below.

**Response time measurement (QA, 2026-11-10).**

- **Tables:** `snv__variant` of `radiant_tenant`, 16.3 million variants (1.5 GB), and of `cypress_tenant`, 8.1 million (0.7 GB), to see how time grows with size. The two other QA tenants are too small to tell anything (173,412 and 302 variants). In `radiant_tenant`, every variant has an HGVSg, 84 % have an rsID (13,726,071) and 0.8 % a ClinVar ID (124,886).
- **Queries:** one per identifier type, on the whole table, without any run filter.
  - Search on submit (exact match, the story's original method): `=` on `locus`, `hgvsg`, `rsnumber`, `clinvar_name` (an ID present in the tenant); and an exact rsID through the shared `dbsnp` table, joined to `snv__variant` on `locus_id`, which also finds secondary rsIDs.
  - Autocomplete: `LIKE '<prefix>%'` on the same columns, ordered by length then value, limited to 25. A short prefix (`rs6`) and longer ones (`rs642`, `chr1:g.3`, `1-3000`, `139`).
  - The same `hgvsg` and `locus` prefixes as a range of values (this spec), and the shortest ranges the minimum length allows (`chr1:g.`, `1-3`).
- **Protocol:** each query run three times with the memory cache off, then three times with it on, in the same window, with the `mysql` client on the StarRocks frontend node. The times are the server times the client prints: they leave out the network, the API and the proxy. The read counters come from the query profiles.
- **Caches:** the compute nodes keep table data at two levels, a memory page cache and a local disk cache in front of the object store.
  - Memory: both levels on, as in normal use; every page comes from memory.
  - Local disk: memory cache off for the measuring session only (`use_page_cache = false`, `skip_page_cache = true`, `populate_datacache_mode = 'never'`). The profiles show every page read from the local disk cache and 0 bytes from the object store; `enable_scan_datacache = false` has no effect on these tables.
  - Object store (true cold, after a restart or an eviction from both levels): not measured. It cannot be measured on QA without writing to the cluster, which is ruled out.
- **Rows and bytes read (profiles, `radiant_tenant`):**
  - A prefix lookup (`LIKE 'x%'`) reads all 16.3 million rows, whatever the column: no page is skipped by the zone maps, the short key index or a bloom filter.
  - An exact lookup on `hgvsg` or `locus` reads only 8 % of the rows: the zone maps skip the other 92 %. The table is sorted by `locus_id`, which follows the genomic order, so the `hgvsg` and `locus` values of a page are close to each other. An exact lookup on `rsnumber` reads everything: rsIDs have no link with the position.
  - The same prefix written as a range (`hgvsg >= 'chr1:g.3' AND hgvsg < 'chr1:g.4'`) returns the same rows and lets the zone maps work on `hgvsg` and `locus`. The spec uses it for these two columns.

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
  - Both methods (prefix autocomplete and search on submit, see alternatives considered) answer well under the 300 ms debounce on `snv__variant`, from memory or from local disk; cost does not decide between them. Only the `dbsnp` lookup is slower: about 190 ms from memory, 500 ms from local disk.
  - Reading from local disk instead of memory doubles the time of a prefix lookup (ratio 1.8 to 2.1), except on ClinVar: 99 % of its values are empty, so the column weighs about 4 MB and its read time hardly counts.
  - The local-disk times are a floor for a true cold read, not an estimate of it: a cold prefix lookup reads 155 to 359 MB compressed from the object store, at a cost not measured here. Written as a range, as the spec does, a prefix on `hgvsg` or `locus` reads 7 to 9 times fewer compressed bytes (23 to 29 MB instead of 203 to 204 MB).
  - Cache misses may come more often than after a restart. The compute nodes share their caches with every occurrence query, and `rsnumber` and `clinvar_name` are rarely read elsewhere, so they are probably among the first columns evicted (deduced, not measured). In production, an rsID lookup may often read from local disk (under 45 ms on QA at the minimum length) or from the object store (not measured).
  - Doubling the table (cypress to radiant) multiplies the prefix time by 1.5 to 1.8, from memory or from local disk. If a production table were four times larger than QA's (a hypothesis: the production size is not known here), the costliest lookup measured (`rs6`, below the minimum length) would take about 100 ms from memory and 200 ms from local disk.
- **Access:** the lookup runs with the same identity as the occurrence queries, on tables they already read.
- **Contract:** additive. Swagger, TS client and Python client regenerated.

Example, with tenant `radiant` (made-up data):

```http
GET /radiant/variants/snv/autocomplete?prefix=RS334&limit=25

200 OK
[
  {
    "source": {
      "locus_id": "-4611686018427387904",
      "hgvsg": "chr11:g.5227002T>A",
      "locus": "11-5227002-T-A",
      "rsnumber": "rs334",
      "clinvar_id": "15333",
      "matched_field": "rsnumber",
      "matched": "rs334",
      "symbol": "HBB",
      "aa_change": "p.Glu7Val"
    }
  },
  {
    "source": {
      "locus_id": "-4611686018427387903",
      "hgvsg": "chr11:g.5227002T>G",
      "locus": "11-5227002-T-G",
      "rsnumber": "rs334",
      "matched_field": "rsnumber",
      "matched": "rs334",
      "symbol": "HBB",
      "aa_change": "p.Glu7Ala"
    }
  },
  {
    "source": {
      "locus_id": "-6917529027641081856",
      "hgvsg": "chr3:g.1201A>C",
      "locus": "3-1201-A-C",
      "rsnumber": "rs3340",
      "matched_field": "rsnumber",
      "matched": "rs3340"
    }
  }
]
```

A prefix absent from the tenant, `rs999999999`, returns `200 OK []`.

### portal (frontend)

- **Facet:** the gene search component (multi-select with suggestions, 300 ms debounce, empty state), at the top of the existing `variant` group, in the slot of the gene search. The component becomes configurable: its suggestion source and the label of a suggestion depend on the field.
- **Suggestion source:** the tenant route, the same for the germline and somatic tabs. The suggestions do not depend on the run on screen.
- **Suggestion label:** the identifier that matched, with the typed prefix in bold, then the HGVSg (`rs334 → chr11:g.5227002T>A`), from `source.matched` and `source.hgvsg`. The bold is built by the frontend from the typed prefix, not parsed from HTML. `symbol` and `aa_change`, when set, complete the second line.
- **Input:** the picked variants show as HGVSg badges in the input, as genes do (team decision).
- **Pill:** field `hgvsg`, operator `in`, one HGVSg per value, as the « Variant » column of the tables shows it. `hgvsg` is already a filter of the germline and somatic SNV occurrences, so the list, count and aggregate apply it as is. With the two `rs334` suggestions picked, they send:

  ```json
  { "op": "and", "content": [
    { "op": "in", "content": { "field": "hgvsg",
      "value": ["chr11:g.5227002T>A", "chr11:g.5227002T>G"] } } ] }
  ```

- **No dropdown:** the pill is the existing search pill, as for genes. Deleting it removes the filter. Values are OR'd.
- **Values already in the pill:** their label is the value itself, the HGVSg. No call when the page opens, unlike genes, which rebuild their labels from the gene autocomplete.
- **Run change:** the pill stays when the user switches run (another member or analysis), like the rest of the query (PO decision). Its HGVSg values filter the new run.
- **Config:** the `variant` group of the germline SNV occurrences in the four portal configs (`radiant`, `qlin`, `include`, `kf`), and of the somatic SNV occurrences in the three that have somatic filters (`radiant`, `qlin`, `include`; `kf` has none). Tumor-normal and tumor-only share that config. SNV tab only.
- **Labels:** EN and FR for the facet title, the placeholder, the tooltip (accepted formats and the minimum length of each) and the pill label, in the same task as the facet.

### Alternatives considered

- **Search on submit (the story's original method):** the user types the full identifier and presses Enter; the backend looks it up with `=`. Measured on QA, it costs about the same as the autocomplete: both answer well under the 300 ms debounce on `snv__variant` (exact 6 to 34 ms, prefix 11 to 65 ms, from memory or local disk). It is not kept because it shows nothing before the filter applies. The user cannot pick the allele of an rsID or check the conversion, and an empty table does not tell a typo from a variant unknown to the tenant or absent from the run. The autocomplete keeps its strength: ordering by length puts the exact match first. An exact lookup in the shared `dbsnp` table remains the fallback for secondary rsIDs (see frozen scope).
- **Hybrid** (exact match for rsID and ClinVar, prefix for locus and HGVSg): not kept, to keep one flow for the four identifiers. It remains an option if prefix noise on numeric IDs bothers users.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | tenant SNV variant `autocomplete` route, input normalisation, swagger, generated TS and Python clients | new |
| portal (frontend) | gene search component made configurable, variant facet, SNV facet config of the four portals, EN/FR labels | new / modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Autocomplete API | portal (backend) | Tenant `autocomplete` route, prefix lookup on `snv__variant` (range for locus and HGVSg), format detection, normalisation, minimum length per format, order and limit, swagger and clients, tests | — | yes (no caller yet) |
| 2 | Variant facet | portal (frontend) | Gene search component made configurable, variant facet in the `variant` group, `hgvsg` search pill, EN/FR labels | Task 1 | yes, once task 1 is deployed |

No UX task: the facet is the gene search component in its existing slot. No Labels task: the labels ship with the facet that uses them.

## Merge and rollout order

1. portal backend: task 1.
2. portal frontend: task 2, after step 1 in the same environment. Without the route, the facet suggests nothing.

No migration, no backfill, no feature flag: the ETL already loads every column used.

## Test strategy

AC numbers follow the order of the story's acceptance criteria, once the story is updated for the autocomplete (see open questions). The story must be updated before this plan is approved: until then, AC1 to AC7 point to its old criteria.

### portal (backend)

- **AC1:** StarRocks integration tests on a fixture: a prefix of each identifier type returns its variants, germline and somatic; an rsID returns every allele dbSNP links to it; the shortest match comes first; no more than the limit; each suggestion carries the fields of the response, `locus_id` as a string.
- **AC2:** unit tests of the format detection and of the normalisation, one per identifier format, including a locus with `chr` or `:` separators and an HGVSg without `chr`; unit tests of the range bounds, with `_` matched as a plain character.
- **AC3:** a prefix absent from the tenant, below the minimum length of its format, of no known format, or made of regular-expression characters such as `(`, returns an empty list, never an error.
- **AC4, AC5:** the `hgvsg` filter with several values returns each variant.

### portal (frontend)

- **AC1:** unit tests of the pure mapping from a suggestion to its label and pill value. No component or render tests (team norm).

### QA (manual)

- **AC1 to AC7:** on the ferlease, on a germline case and a somatic case: one search per identifier type, several variants picked, then the pill deleted. The gene search is checked too, since its component changes. Screenshots of the suggestions and the pill in the PR, as the story asks.

## Risks and coverage

The story checks no risk.

## Frozen scope

### all

- Gene symbol, gene alias, AA change, Ensembl and RefSeq IDs.
- Variant list upload, removing one variant from the pill (story's out of scope).
- CNV tab.
- « Present in this run » marker on the suggestions: V2, in a ticket to create. Measured on QA, it adds 11 ms from memory and 45 ms from local disk to the `rs6` lookup, by checking the 25 suggestions against the run's occurrences. It needs the run (case, sequencing, task) as optional route parameters.

### portal (backend)

- Secondary rsIDs: a variant is found by the rsID kept in `snv__variant`, not by the other rsIDs dbSNP gives it. In `radiant_tenant`, 3,405 variants have more than one rsID in dbSNP, so 4,635 rsIDs cannot be found. The ETL keeps one of them with no ordering rule, so the kept rsID may change at a reload (read in the ETL code, not verified on data). An exact lookup in the shared `dbsnp` table stays the fallback if these rsIDs are needed; it answers in about 190 ms from memory and 500 ms from local disk on the whole tenant, too slow for every keystroke.
- No new query field and no change to the occurrence list, count or aggregate.
- ClinVar accession (`VCV000013961`).

## Open questions

### story / product

- **The story still describes a search on submit:** no autosuggest, exact matching, the input cleared after each submit (AC6), `Variant ID = <locus>` in the pill (AC4). **Proposal:** update it to the autocomplete, the HGVSg in the pill, the minimum length per format and a suggested variant absent from the run giving an empty list.

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
