# RAD-41: Download the transcript report (XLSX) for a germline SNV variant of a case

## Story

- **Link:** [RAD-41](https://ferlab-crsj.atlassian.net/browse/RAD-41), epic [RAD-1](https://ferlab-crsj.atlassian.net/browse/RAD-1). Somatic follow-on: [RAD-42](https://ferlab-crsj.atlassian.net/browse/RAD-42)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-41-transcript-report`

## Chosen approach

**Summary:** radiant-api builds one "report object" per locus from StarRocks and Postgres, fills the tenant's Excel template with it, and streams the workbook. The frontend adds a Report button on the germline occurrence sheet. No ETL change: every QLIN column has a live source in Radiant (see [`RAD-41-transcript-report-field-mapping.md`](RAD-41-transcript-report-field-mapping.md)).

| Module | Approach |
|---|---|
| portal (backend) | • **Report object:** one Go struct per locus, tenant-independent superset of what any report can show: variant (hgvsg, rsnumber, ClinVar id, gnomAD ac/an/af/hom), occurrence (zygosity, parental origin, parent zygosities, AD), genes with OMIM, all Ensembl transcripts with the MANE pair (RefSeq NM, exon, HGVSc, AA change, REVEL, CADD), interpretation with PubMed, case context (MRN, submitter sample id, proband, genome build). Reads are batched for N loci. Exon rank and total are carried as text (VARCHAR in production). A PubMed id the client cannot resolve keeps an empty citation: the report does not fail on PubMed, unlike the interpretation endpoints.<br>• **JSON endpoint:** `GET /{tenant}/occurrences/germline/snv/{case_id}/{seq_id}/{task_id}/{locus_id}/report` returns the raw object. Kept deployed: contract for template authors, QA diff against the QLIN report.<br>• **XLSX endpoint:** `GET /{tenant}/occurrences/germline/snv/{case_id}/{seq_id}/{task_id}/reports/transcripts?locus_ids=a,b,c`, 1 to 100 ids, action `can_search_case`, one sheet per locus named after `hgvsg`, `Content-Disposition` file name `<MRN>_<case id>_<UTC timestamp>.xlsx` (the QLIN list endpoint rule, no rsnumber). 400 outside the cap, 404 when a locus is not an occurrence of the case.<br>• **Rows:** one row per Ensembl transcript, MANE Select first, RefSeq NM taken from the MANE pair, RefSeq-only genes keep their row.<br>• **Template:** an Excel file per tenant and report type (`transcripts_germline_<tenant>.xlsx`) in `REPORT_TEMPLATE_DIR`, same loader shape as the notification emails. Row 1 is the header styled in Excel, row 2 the placeholder row repeated per transcript, cells hold Go text/template expressions over the report object with a `**bold**` / `_italic_` run markup, sheet tab name templated. Loaded at boot: locate the repeat row, parse every expression, dry-run on a sample object; a bad file takes that tenant's report down only, reported in the status endpoint, request answers an explicit error. Formulas, merged cells and conditional formatting in the repeat row are rejected.<br>• **Rendering:** excelize. Copy the template sheet per locus, duplicate the placeholder row per transcript, fill cells as rich text runs with the template cell's font. Static styling (widths, fills, wrap, heights) comes from the file untouched.<br>• **Helpers:** the clin-arranger formatters (zygosity and parental origin, gnomAD, ClinVar, OMIM and PMID, MANE, classification, citations) ported to Go and registered for the templates, with their test cases.<br>• **Boundaries:** the two endpoints are additive; readers are the frontend (TS client) and the MCP (Python client, not bumped). New StarRocks readers, no DDL change: `snv__consequence` (`source`, `transcript_version`, `mane_select`, `mane_pair_transcript_id`), `gnomad_genomes_v3` (`ac`, `an`, `hom`), `snv__variant.clinvar_name`, `omim_gene_panel`, the parental columns of `germline__snv__occurrence`; renaming any of them breaks the report. New config `REPORT_TEMPLATE_DIR`: a missing directory means no report for any tenant, the API still boots. New status field `report_templates`, same shape as `notification_templates`, additive. |
| portal (frontend) | • **Proxy:** the `/api/*` proxy passes a binary response through with its `Content-Type` and `Content-Disposition` instead of re-encoding JSON.<br>• **Button:** "Report" on the germline occurrence sheet, current variant only, downloads the xlsx through the proxy, file name from the header. Error toast when the tenant has no template.<br>• **Labels:** EN/FR button, tooltip, error. |
| mcp | • Python client regenerated, not bumped. |
| infra | • Template mount: ConfigMap for `qlin` (QA, prod), compose volume for localstack. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | new report package (object, repositories, template loader, renderer, helpers), germline SNV occurrence routes and handlers, status endpoint, config, swagger and generated clients, test schema (`snv__consequence` gains `source`, `transcript_version`, `mane_pair_transcript_id`; `cosmic_mutation_set` added for RAD-42), golden fixtures | new / modified |
| portal (frontend) | API proxy, germline occurrence sheet (action bar), download helper, translations | new / modified |
| infra | template ConfigMap and mounts | new |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Report object + JSON endpoint | portal (backend) | Struct, batched StarRocks and Postgres reads, rows rule, test schema columns, StarRocks fixture (Ensembl/RefSeq twins, RefSeq-only gene, null source, intergenic, part and task exclusion), `/report` route, swagger, clients | — | yes (read-only endpoint) |
| 2 | Excel template engine | portal (backend) | Loader (`REPORT_TEMPLATE_DIR`, locate the repeat row, parse every cell expression, dry-run on a sample object, failure isolated per tenant, `report_templates` status field), excelize renderer (sheet copy per locus, row duplication per transcript, rich text runs with the template cell font, `**bold**` / `_italic_` markup), arranger formatters ported as template helpers with their test cases (zygosity and parental origin, gnomAD, ClinVar, OMIM and PMID, MANE, classification, citations). Tested on a minimal fixture template; nothing exposed yet | 1 | yes (status field only) |
| 3 | XLSX endpoint and qlin germline template | portal (backend) | `transcripts_germline_qlin.xlsx` reproducing the QLIN layout, `/reports/transcripts` route with cap, 404, headers, file name, missing template error; golden workbook tests on the arranger mock cases (cells, rich text, widths, heights, autofilter, sheet names, the zygosity cases) | 2 | yes, once task 4 has mounted the template in that environment |
| 4 | Template mounts | infra | ConfigMap and volume for `qlin` on QA and prod, localstack compose volume | 3 (file) | yes |
| 5 | Frontend: proxy, button, labels | portal (frontend) | Binary passthrough, download helper, Report button on the germline sheet, EN/FR labels, Vitest on helper and button states | 3 and 4 deployed | yes |

Jira sub-tasks (created 2026-10-07): task 1 [RAD-48](https://ferlab-crsj.atlassian.net/browse/RAD-48), task 2 [RAD-49](https://ferlab-crsj.atlassian.net/browse/RAD-49), task 3 [RAD-50](https://ferlab-crsj.atlassian.net/browse/RAD-50), task 4 [RAD-51](https://ferlab-crsj.atlassian.net/browse/RAD-51), task 5 [RAD-52](https://ferlab-crsj.atlassian.net/browse/RAD-52). Somatic increment under RAD-42: object and endpoints [RAD-53](https://ferlab-crsj.atlassian.net/browse/RAD-53), template and mount [RAD-54](https://ferlab-crsj.atlassian.net/browse/RAD-54), button [RAD-55](https://ferlab-crsj.atlassian.net/browse/RAD-55).

Labels task: folded into task 5 (three strings, validated with the CQGC). UX task: none, the button reuses the sheet action bar; multi-select is a separate story.

## Merge and rollout order

1. portal backend: tasks 1 and 2. Nothing depends on them yet; without a mounted template the status endpoint reports no `qlin` template, nothing else changes.
2. infra task 4 then portal backend task 3, per environment. A deploy of task 3 without the mounted template makes every `qlin` report fail explicitly (visible in the status endpoint). Mount first.
3. portal frontend: task 5, after the backend is deployed in the environment, otherwise the button gets a 404.

No migration, no backfill, no feature flag.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1, AC2 (file name, sheet, layout, values):** golden workbook tests on the four germline arranger mock cases: every cell, rich text fonts, widths, heights, autofilter, sheet names, file name.<br>• **AC3, AC4 (rows, interpretation):** repository tests on a StarRocks fixture: twins, RefSeq-only gene, legacy null source, interpretation on one transcript only.<br>• **AC5 to AC8 (cap, 404, 403, missing template):** handler tests: 1 and 100 ids pass, 0 and 101 answer 400, foreign locus 404, missing action 403, missing template error.<br>• **AC8 (missing template):** loader tests: missing directory, bad file, unknown field in a cell, unknown tenant, status field. |
| portal (frontend) | • **AC1, AC8, AC9 (download, error, translations):** Vitest: proxy JSON vs binary, download helper reads the file name, button states, error toast, EN/FR labels. |
| QA (manual) | • **AC2 (same values as QLIN):** open the same variant in QLIN and Radiant on QA, compare the two workbooks cell by cell for one HET maternal, one HOM, one de novo and one RefSeq-only case.<br>• Not automated: the look in Excel itself (fonts, wrapped heights), checked by eye on the QA diff. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data | MRN and case id only reach the file through the tenant route and `can_search_case`; nothing is stored or logged server side; masked views untouched. Handler tests on 403 and 404 |
| Genomic formats or data | Transcript rule and GRCh38 pinned by the StarRocks fixture and the golden workbooks; sheet name sanitising tested on illegal characters |
| Clinical rules or interpretation | Formatters ported with the arranger test cases (zygosity, parental origin, ClinVar, OMIM, classification); French labels live in the qlin template, validated by the CQGC on the QA diff |

## Frozen scope

| Module | Not covered |
|---|---|
| all | Somatic report (RAD-42), CNV and SV, TSV, PDF, SoftPath integration, report storage or audit, MCP tool, multi-variant selection, changing QLIN columns or wording, genome builds other than GRCh38 |
| portal (backend) | Template hot reload, per-tenant helpers or language in helpers, denormalising COSMIC (RAD-15) |
| portal (frontend) | Selection column in the occurrences table |

## Open questions

| Module | Questions |
|---|---|
| portal (backend) | • Parent zygosity value domain (`WT`, `UNK`, NULL) in `father_zygosity` and `mother_zygosity`: not verified, needed by the parental origin formatter. Check on QA data in task 2. |
| story / product | • Who edits `transcripts_germline_qlin.xlsx` after v1: CQGC directly or dev on request. Decides how much validation the loader needs. |

## Approval

| | |
|---|---|
| Reviewer | Jeremy Costanza |
| Date | … |
| Plan review duration | … min |
| Decision | … |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
