# RAD-1: transcript report, decision log

Companion of [`RAD-41-transcript-report.md`](RAD-41-transcript-report.md) and [`RAD-41-transcript-report-field-mapping.md`](RAD-41-transcript-report-field-mapping.md). Records when and why each axis of the design was decided, so a later reader knows which options were on the table. The spec holds the result only.

## Context

clin-arranger generates the "rapport de transcrits" XLSX that geneticists paste into SoftPath: one request, up to 100 variants, one worksheet per variant, germline or somatic column layout, French labels (state after CLIN-5734), data from the Elasticsearch variant index plus the interpretation fetched from radiant-api. Epic [RAD-1](https://ferlab-crsj.atlassian.net/browse/RAD-1) asks for the same report in Radiant, where the data lives in StarRocks and Postgres.

Brainstorm Yann and Jeremy Costanza, 2026-10-02, no code:

- UI: Radiant has no multi-select on variants (QLIN has). V1 is a "Report" button for one variant, multi-select to discuss with UI/UX. Rename "CHUSJ report" to "Report".
- Backend: the endpoint always takes a list of variants, hard cap 100. Two reports (germline, somatic), one tab per variant. Template per tenant like the notification emails. Keep XLSX, pick the library, find how to templatise. A possible third Go entity "occurrence report" exposed to any template. No TSV export.
- Data: list the columns QLIN has that Radiant lacks, with a feasibility proposal per gap (live computation at generation vs ETL).
- Process: the team formalises its way of working on radiant-hub. The Jira story is the "what", `docs/features/RAD-xxxx-<slug>.md` the "how". Markdown is the source of truth.

## Decisions

| Date | Topic | Decision |
|---|---|---|
| 2026-10-02 | Scope | Germline and somatic, one tab per variant, XLSX only, no TSV |
| 2026-10-02 | Endpoint | Server side in radiant-api, list of loci, 1 to 100 enforced by the backend, action `can_search_case` |
| 2026-10-02 | UI v1 | One "Report" button on the current variant. Multi-select is a UI/UX discussion, out of this spec |
| 2026-10-02 | Templates | One template per tenant, mounted directory loaded at boot like the notification emails. The tenant implies labels and language, so no language parameter |
| 2026-10-02 | COSMIC | `cosmic_id` read live from `cosmic_mutation_set` (RAD-15 does not denormalise it) |
| 2026-10-02 | Reviewer, class | Jeremy Costanza, Complex |
| 2026-10-07 | Stories | Two stories under RAD-1: germline ([RAD-41](https://ferlab-crsj.atlassian.net/browse/RAD-41)) carries the report object, template loader, rendering engine, proxy passthrough and button; somatic ([RAD-42](https://ferlab-crsj.atlassian.net/browse/RAD-42)) is an increment. No placeholder story for multi-select |
| 2026-10-07 | Rows | One row per Ensembl transcript, MANE Select first, RefSeq NM shown from the MANE pair, RefSeq-only genes keep their row. No Ensembl/RefSeq duplicate. Rejected: one row per consequence as arranger does (duplicates since VEP merged), Ensembl rows only (loses RefSeq-only genes) |
| 2026-10-20 | Rows | MANE Select transcripts plus any transcript carrying an interpretation; a locus with neither renders an empty sheet (tech lead review of RAD-49, Yann). Deviation from arranger, which listed every transcript with MANE Select first |
| 2026-10-20 | Labels | No French in Go code or tests (RAD-49 review). Wording per tenant in `transcripts_<tenant>.json` deployed with the templates, English default embedded in the API as fallback with a warning. Keys lower case except codes |
| 2026-10-07 | Patient identifier | MRN (`submitter_patient_id`), what QLIN prints today. Masked views apply. Rejected: the Radiant patient id (meaningless to the CQGC) |
| 2026-10-07 | Templating, after the three-pane mock | Excel file as template, one per tenant and report type. Row 1 header styled in Excel, row 2 placeholder row repeated per transcript, cells hold Go text/template expressions over the report object with a `**bold**` / `_italic_` run markup, sheet tab name templated. Boot: open, locate the repeat row, parse every expression, dry-run on a sample object; failure takes the template down for that tenant only, reported in the status endpoint. Formulas, merged cells and conditional formatting rejected in the repeat row. Rejected: a YAML template per tenant (own DSL, styles limited to its schema), a Go layout per report type with a per-tenant label file (every layout change is a release), a thin third-party xlsx templater (no rich text runs, low activity) |
| 2026-10-07 | Report object | Fixed Go struct, tenant-independent superset of every field a report can show. Templates select from it, never extend it. Helpers (zygosity, gnomAD, ClinVar, MANE, OMIM and PMID, citations) are the arranger formatters ported to Go |
| 2026-10-07 | Endpoints | Two GETs, not an Accept switch: `.../{locus_id}/report` returns the raw report object as JSON (kept deployed, contract for template authors and QA diff against arranger); `.../reports/transcripts?locus_ids=a,b,c` returns the xlsx |
| 2026-10-07 | Slice order | Template-first: 1 report object and JSON endpoint, 2 Excel template engine, 3 xlsx endpoint and qlin germline template, 4 infra mounts, 5 frontend. Somatic: object and endpoints, template and mount, button. Rejected: a first slice with the qlin layout hardcoded in Go, thrown away by the template slice |
| 2026-10-07 | File name | `<MRN>_<case id>_<UTC timestamp>.xlsx`, the arranger list-endpoint rule. Only its single-variant endpoint adds the rsnumber |

Three-pane mock (report object, Excel template vs YAML template, rendered sheet): https://claude.ai/artifact/B7XgLeuNxup4e8NAS9cFGF

## Facts verified in code

- Radiant has no XLSX or CSV code and no spreadsheet library; the only download today is a presigned S3 URL. The frontend `/api/*` proxy re-encodes every response as JSON and forwards no header, so a binary response with `Content-Disposition` needs a passthrough.
- In arranger a row is a consequence. Since VEP runs merged (SJRA-1820), `snv__consequence` also holds RefSeq rows (`source`, `transcript_version`, `mane_pair_transcript_id`; `mane_select` is the versioned paired NM on the Ensembl MANE row). The backend test schema lacks these three columns.
- Every QLIN field has a Radiant source reachable live at generation, none needs ETL: gnomAD ac/an/af/hom in `gnomad_genomes_v3` (loaded from the gnomAD v4 joint set, same source as arranger), ClinVar id in `snv__variant.clinvar_name`, OMIM in `omim_gene_panel`, COSMIC in `cosmic_mutation_set` (absent from the backend test schema), parental origin and parent zygosities in `germline__snv__occurrence`, VAF and `normal_seq_id` (null means tumor-only) in `somatic__snv__occurrence`, interpretations and PubMed ids in Postgres, citations fetched live from PubMed with a cache. Case context (proband, sample, MRN) comes from the case entity, the genome build from the task.
- Identifier changes: `service_request_id` becomes `case_id`, `sample_id` becomes `submitter_sample_id`, the FHIR patient id becomes the MRN. Columns arranger no longer renders since CLIN-5734 (SIFT, Exomiser class, biotype, consequence names) are not ported.
- The occurrence details panel shows exon, HGVSc, AA change, rsnumber, predictions, frequencies, OMIM and parental origin, but not the RefSeq ids, parent zygosities, ClinVar id or citations. The report object is built server side anyway.
- Go XLSX libraries checked: excelize (maintained, rich text runs, styles, row duplication, no template engine) and a Handlebars-style xlsx templater (no rich text runs, low activity). No mature Go xlsx template engine exists.
- Arranger layout, verified on a workbook from the QLIN generator on 2026-10-07: header Arial 9 bold, 63.75 high; data rows fixed at 150; columns A and K left aligned, the rest centered, all wrapped; autofilter on the header row; rich text in the variation, OMIM and ClinVar cells; no merged cell, no conditional formatting; the superscripts in the headers are text only, no legend row.
