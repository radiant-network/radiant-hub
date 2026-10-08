# RAD-1: Transcript report (XLSX) in Radiant, draft spec + brainstorm deliverables

## Context

clin-arranger (Node/Express/exceljs) generates the "rapport de transcrits" XLSX that geneticists paste into SoftPath: `POST /report/transcripts/:serviceRequestId`, up to 100 variants, one worksheet per variant, germline or somatic column layout, French labels (CLIN-5734 state), data from the ES `variant_centric` index plus the interpretation fetched from radiant-api. Jira epic **RAD-1 "Rapport CHUSJ (xlsx rapport institutionnel)"** asks for the same report in Radiant, where the data lives in StarRocks + Postgres.

Yann brainstormed with the tech lead (2026-10-02). Outcome, all **draft, no code**:

- UI: Radiant has no multi-select checkbox on variants (QLIN has). V1 = a "Report" button for **one variant** (details panel), multi-select to discuss with UI/UX. Check whether the details panel content is sufficient. Rename "CHUSJ report" to "Report".
- Backend: endpoint always takes a **list** of variants, hard cap **100**. Two reports (germline, somatic), one tab per variant, rows = ? (one per transcript? similar rows today). **Template per tenant** like the notification emails, so 2 templates per tenant? Keep XLSX, pick the lib, find how to templatise (unknown what templating can satisfy germline + somatic, tabs + rows + fields). Abstraction code/template. A possible **third Go entity "occurrence report"** (beyond occurrence + occurrence details) exposed to any template. No TSV export.
- Data: columns QLIN has that Radiant lacks (e.g. allele frequency ac/an/hom) must be listed, with a feasibility proposal per gap (live StarRocks computation at generation vs Airflow/ETL).
- Process: the team formalises its way of working on `radiant-hub` (umbrella repo, cloned at `/home/yann/CHU/clin/radiant-hub`): `jira-story` skill writes the "what" (Jira story), `docs/features/RAD-xxxx-<slug>.md` is the "how". **Markdown is the source of truth** (no HTML artifact), AI-generated but human-readable. Yann must give feedback on the hub skill + template, and answer "do existing docs move to the hub?".

Reference material read: hub `CLAUDE.md`, `docs/features/0000-template.md`, approved `RAD-15-cosmic-cmc-snv.md`, `docs/stories/story-template.md`, `jira-story` skill, `feature-spec` skill + `RAD-10` draft on hub branch `origin/rad-11` (not merged: module tables, `• item<br>` cells, no file paths / SQL / Go names, temporary `## Options considered` after Open questions, 100-150 lines). Notification template precedent: `clin-localstack/services/radiant-portal/backend/internal/notification/template.go` (fork branch `feat/clin-6231`): `NOTIFICATION_TEMPLATE_DIR`, `manifest_<tenant>.tmpl`, loaded at boot, bad file = warning, missing tenant = error at request time, `TemplateData` struct = contract.

## Decisions already taken (Yann + tech lead), recorded in the spec as decided

| Topic | Decision |
|---|---|
| Scope | Germline + somatic, one tab per variant, XLSX only, no TSV |
| Endpoint | Server side in radiant-api, list of loci in the body, 1 to 100 enforced by the backend, auth `can_search_case` |
| UI v1 | One "Report" button on the current variant (details panel), calls the list endpoint with one locus. Multi-select = UI/UX discussion, out of this spec |
| Templates | One template per tenant, mounted directory + boot load like the notification emails. Tenant implies labels and language, so no `lang` param |
| COSMIC | `cosmic_id` read live from `cosmic_mutation_set` (RAD-15 does not denormalise it) |
| Reviewer / class | Jeremy Costanza / Complex |
| Deliverables | Markdown only, story preview then Jira creation on approval (changed 2026-10-07), spec named after the epic `RAD-1` until the story exists |
| Stories (2026-10-07) | Two stories under RAD-1: germline report first (carries the report model, template loader, rendering engine, proxy passthrough, button), somatic report as an increment. No placeholder story for multi-select |
| Rows, axis C (2026-10-07) | One row per Ensembl transcript, MANE Select first, RefSeq NM shown from the MANE pair, RefSeq-only genes keep their row. No Ensembl/RefSeq duplicate |
| Patient identifier, axis E (2026-10-07) | MRN (`submitter_patient_id`), what QLIN prints today. Masked views apply |
| Templating, axis A (2026-10-07, decided after the three-pane mock) | **A3, Excel file as template**, one per tenant and report type. Row 1 header styled in Excel, row 2 placeholder row repeated per transcript, cells = Go text/template over the report object with a `**bold**` / `_italic_` run markup, sheet tab name templated. excelize keeps the file's static styling; filled cells re-apply the template cell font per run. Boot: open, locate repeat row, parse every expression, dry-run on a sample object; failure = template down for that tenant only, reported in the status endpoint (new field), request answers an explicit error. Validation rejects formulas, merged cells, conditional formatting in the repeat row |
| Report object (2026-10-07) | Fixed Go struct, tenant-independent superset of every field a report can show. Templates select from it, never extend it. Helpers (zygosity, gnomAD, ClinVar, MANE, OMIM/PMID, citations) = arranger formatters ported to Go, registered in the template funcmap |
| Endpoints (2026-10-07, refines the endpoint row) | Two GETs, not an Accept switch: `GET .../snv/{case_id}/{seq_id}/{task_id}/{locus_id}/report` returns the raw report object as JSON (kept deployed, contract for template authors and QA diff vs arranger); `GET .../snv/{case_id}/{seq_id}/{task_id}/reports/transcripts?locus_ids=a,b,c` returns the xlsx (clickable through the proxy, 1 to 100 ids) |
| Slice order (2026-10-07, reordered same day) | Germline: 1 report object + JSON endpoint, 2 Excel template engine (loader, renderer, helpers, status field), 3 xlsx endpoint + qlin germline template, 4 infra mounts, 5 frontend (proxy passthrough, button on germline sheet, labels). Somatic: 6 somatic object + endpoints, 7 somatic template + mount, 8 somatic button. Template-first: the earlier "qlin layout hardcoded in Go" slice was dropped, it would have been thrown away by the template slice |

Three-pane mock (report object, A3 template vs A2 YAML, rendered sheet): https://claude.ai/artifact/B7XgLeuNxup4e8NAS9cFGF

## Facts that drive the design (verified in code)

- Radiant has no XLSX/CSV/export code and no spreadsheet lib; the only download is a presigned S3 URL. Frontend `/api/*` proxy (`frontend/portals/radiant/app/api/proxy.ts`) is JSON-only (`JSON.stringify(response.data)`, no header forwarding): binary + `Content-Disposition` need a passthrough. CORS has no `ExposeHeaders`.
- Row = consequence in arranger: `germlineMakeRows` maps every `consequences[]` entry (MANE Select first). "Similar rows" = several transcripts of one gene, and since VEP `--merged` (SJRA-1820) StarRocks `snv__consequence` also holds **RefSeq rows** (`source` = Ensembl | RefSeq, `transcript_version`, `mane_pair_transcript_id`; `mane_select` = versioned paired `NM_x.y` on the Ensembl MANE row). Backend test DDL lacks these 3 columns.
- Every QLIN field has a Radiant source reachable **live at generation**, none needs ETL: gnomAD ac/an/af/hom in `gnomad_genomes_v3` (table name misleading, loaded from `iceberg_gnomad_joint` = gnomAD v4 joint, same as arranger's `gnomad_joint_4`; the occurrence API only exposes `gnomad_v3_af`, hence "Radiant has no allele frequency"), ClinVar id = `snv__variant.clinvar_name` (already joined as id in `repository/clinvar_rcv.go:43`), OMIM in `omim_gene_panel`, COSMIC in `cosmic_mutation_set` (pipeline SJRA-1946, not in backend DDL), parental origin + parent zygosities + ad_* in `germline__snv__occurrence` (mandatory `part`), VAF + `normal_seq_id` (null = tumor-only) in `somatic__snv__occurrence`, interpretations + PubMed citations in Postgres (`FirstGermline/FirstSomatic`, keyed by case/seq/locus/transcript strings), proband / sample / patient from `CasesRepository.GetCaseEntity`, genome build from `TaskRepository.GetTaskById`. RefSeq NM list per gene = RefSeq rows of the same locus + symbol.
- Identifier changes: `service_request_id` becomes `case_id`, `sample_id` becomes `submitter_sample_id`, FHIR `patient_id` becomes Radiant `patient.id` (or MRN, to decide). Arranger maps no longer rendered since CLIN-5734 (SIFT, Exomiser class, biotype, consequence names) are not ported.
- Details panel (`occurrence-expand-transcript.tsx` + expanded occurrence) shows exon, dna_change, aa_change, rsnumber, predictions, frequencies, OMIM conditions, parental origin: it is the natural host for the v1 button, but it lacks RefSeq ids, parent zygosities, ClinVar id, PubMed citations. The report object must be built server side anyway.
- Go XLSX options checked: `github.com/xuri/excelize/v2` (maintained, rich text runs, styles, `DuplicateRow` with the documented caveat that references are only partially updated, no template engine); `github.com/ivahaev/go-xlsx-templater` (Handlebars placeholders + `{{range}}` row repetition on tealeg/xlsx, 90 stars, low activity, no rich text runs). No mature Go "xlsx template engine" exists.

## Deliverables (files only, nothing committed, nothing created in Jira)

### 1. `radiant-hub/docs/features/RAD-1-transcript-report.md` (draft spec)

From `0000-template.md`, following the `feature-spec` skill rules. Status Draft, branch `feat/rad-1-transcript-report`. Chosen approach rows say "not decided yet (see Options considered)" for undecided axes; a temporary `## Options considered` section after Open questions lists each axis with one row per option (behaviour, modules, pro, con, effort S/M/L, preliminary lean). Target 120-180 lines in draft (options are removed after the decisions).

**Chosen approach, summary:** one list endpoint per variant type builds an "occurrence report" object per locus from StarRocks + Postgres, renders it through the tenant's template into an XLSX with one tab per variant, and streams it; v1 UI is a "Report" button on the current variant.

| Module | Approach (decided parts) |
|---|---|
| portal (backend) | • **Endpoints:** `POST /{tenant}/occurrences/germline/snv/{case_id}/{seq_id}/{task_id}/reports/transcripts` and `.../somatic/snv/...`, body `locus_ids` (1 to 100, 400 above), action `can_search_case`, response `.xlsx` + `Content-Disposition`, 404 when no occurrence matches.<br>• **Occurrence report object:** third read model per locus (variant, all consequences with source and MANE pair, occurrence/donor, external frequencies with ac/an/hom, ClinVar id, OMIM, COSMIC, interpretation + citations, case context: case id, sample, proband, genome build). Batched reads for N loci.<br>• **Templates:** one directory `REPORT_TEMPLATE_DIR`, one file per tenant and report type, loaded at boot (bad file = warning, missing = error at request), same loader shape as the notification templates. Rendering engine: not decided yet.<br>• **Rows:** not decided yet. |
| portal (frontend) | • **Proxy:** binary passthrough on `/api/*`.<br>• **Button "Report":** in the occurrence details panel, current variant only, blob download named from `Content-Disposition`.<br>• **Labels:** EN/FR button, tooltip, error. |
| etl | • None in v1. Optional later: denormalise `cmc_cosmic_id` with RAD-15. |
| mcp | • Python client regenerated, not bumped. |

**Options considered (axes):**

| Axis | Options (lean marked) |
|---|---|
| A. Templating | **Decided 2026-10-07: A3** (see Decisions). History: A1 Go layout per report type + per-tenant **label/column file** (YAML: labels, footnotes, column order, widths). Exact styles, new column = code. S-M.<br>A2 **Declarative YAML template** per tenant and type: columns with header, width, alignment, cell expression (Go text/template over the report object), light markup for bold/italic runs; engine owns tabs, rows, fonts, borders, autofilter. New column = template edit, reviewable diff, testable. Own small DSL to maintain. M. **Lean.**<br>A3 **XLSX file as template** (layout designed in Excel, placeholders in a row cloned per transcript with excelize, Handlebars-style or Go template). Clinicians own the look; binary in git/ConfigMap, rich text runs and row cloning fragile, hard to diff/test. M-L.<br>A4 Reuse `go-xlsx-templater`: A3 with a thin lib, no rich text, low activity. Not recommended. |
| B. Report object exposure | **Decided 2026-10-07: B2**, JSON endpoint kept deployed. |
| C. Row semantics | **Decided 2026-10-07: C2**, one row per Ensembl transcript, MANE Select first, NM from the MANE pair, RefSeq-only genes keep their row. |
| D. Templates count | D1 two files per tenant (`transcripts_germline_<tenant>`, `transcripts_somatic_<tenant>`). **Lean.** D2 one file with two sections. |
| E. Patient identifier | **Decided 2026-10-07: E2**, MRN (`submitter_patient_id`), masked views apply. |
| F. Multi-variant UI | F1 details panel button only (v1). F2 selection column + toolbar button (data-table supports `enableRowSelection`, no `getRowId`, needs UI/UX). Out of this spec. |

**Tasks** (one PR each, portal repo), written so they hold whatever A/C decide:

| # | Task | Component | Depends on | Shippable alone? |
|---|---|---|---|---|
| 1 | Occurrence report read model + batched repositories + test DDL (`source`, `transcript_version`, `mane_pair_transcript_id`, `cosmic_mutation_set`) + fixture folder | portal (backend) | — | yes |
| 2 | Template loader (dir, per tenant and type, boot load, status) + rendering engine + excelize + golden tests from the arranger fixtures | portal (backend) | A decided | yes |
| 3 | Germline endpoint, route/action tests, swagger, clients, CORS expose header, integration test | portal (backend) | 1, 2 | yes |
| 4 | Somatic endpoint (VAF, TN/TO origin, COSMIC join, clinical utility / oncogenicity) | portal (backend) | 3 | yes |
| 5 | Proxy binary passthrough + download helper + tests | portal (frontend) | — | yes |
| 6 | Labels EN/FR (button, tooltip, errors) | portal (frontend) | — | yes |
| 7 | "Report" button in the details panel, germline then somatic | portal (frontend) | 3/4 deployed, 5, 6 | yes |
| 8 | QLIN templates (germline, somatic) for the `qlin` tenant + infra mount (ConfigMap, localstack) | infra / templates | 2 | yes |

Story mapping (2026-10-07): tasks 1, 2, 3, 5, 6, 7, 8 belong to the germline story; the somatic story holds task 4, the somatic template and the somatic branch of the button.

UX task: none in this spec (v1 reuses the panel); multi-select is the UI/UX discussion. Labels task = 6.

**Contract changes:** API (two POST endpoints, additive; optional JSON report endpoint); StarRocks new readers: `cosmic_mutation_set` (`cosmic_id`, `sample_mutated`, `tier`), `snv__consequence` (`source`, `transcript_version`, `mane_select`, `mane_pair_transcript_id`), `gnomad_genomes_v3` (`ac`, `an`, `hom`); no DDL change; new config `REPORT_TEMPLATE_DIR`; new template file format (owner portal backend, writers = tenants). Hub `docs/contracts/portal-api.md` + `starrocks-schema.md` rows written in the same change (decisions made for the data side).

**Rollout:** backend tasks 1-4 before frontend 7 in each environment (else 404); templates mounted before first call (missing template = error, like notify); proxy with any frontend release; no migration/backfill/flag.

**Test strategy:** golden workbook tests from the arranger mock data (every cell, rich text fonts, widths, heights, autofilter, sheet names, the 10 zygosity cases, gnomAD/ClinVar/COSMIC edge cases); repo tests on a `transcript_report` StarRocks fixture (Ensembl/RefSeq twins, RefSeq-only gene, legacy null source, intergenic, part/task exclusion, TN vs TO) + seed interpretations; handler tests (400/404/headers); one integration test opening the workbook; template loader tests (missing dir, bad file, unknown tenant); frontend vitest (download helper, button states, proxy JSON vs binary); QA manual diff against `clin-arranger/before_after/*.xlsx` (G1-G4, S1).

**Risks and coverage:** patient data (ids in file and filename, tenant + action gate, masked views untouched); genomic formats (RefSeq rule and GRCh38 pinned by fixtures); clinical rules (formatters ported verbatim with arranger test cases; FR labels live in the QLIN template, validated by the CQGC).

**Frozen scope:** CNV/SV, TSV export, PDF/SoftPath, report storage/audit, MCP tool, multi-select UI, changing QLIN wording, `cmc_*` denormalised columns (RAD-15), template hot reload.

**Open questions:** parent zygosity value domain (`WT`/`UNK`/NULL) in `father_zygosity` **not verified**; PubMed latency on 100 loci (dedupe ids, best-effort fallback `PMID : id`); OMIM inheritance codes `", "` vs `","`; `exon_rank` VARCHAR in prod DDL vs int in backend; is the details panel enough for v1 (it lacks RefSeq ids, parent zygosities, ClinVar id, citations: the JSON report endpoint B2 answers this); hg38 only.

### 2. `radiant-hub/docs/features/RAD-1-transcript-report-field-mapping.md` (companion, the QLIN vs Radiant diff the tech lead asked for)

One table per sheet (germline 11 columns, somatic 13 columns) plus filename/sheet-name identifiers. Columns: Report column · QLIN source (ES field) · Radiant source (table.column or Postgres) · Status (`available` / `live computation at generation` / `ETL needed` / `replaced identifier` / `dropped by CLIN-5734`) · Note. Highlights: gnomAD ac/an/hom live join (table naming trap), ClinVar id = `clinvar_name`, RefSeq NM list from RefSeq rows of the same gene, MANE NM from `mane_select`, COSMIC via `cosmic_mutation_set`, VAF from tumor fields, origin from `normal_seq_id`, proband from case members, genome build from the task, identifiers replaced (case id, submitter sample id, patient id option). Conclusion line: no ETL change required for v1; optional ETL denormalisation later only for performance. Referenced from the spec (one line) and flagged in the process feedback as a doc type the template has no slot for.

### 3. Stories (chat preview + `scratchpad/RAD-1-stories.md`), created in Jira under RAD-1 after approval (2026-10-07)

Created 2026-10-07: **RAD-41** (germline) and **RAD-42** (somatic), epic RAD-1 description filled. Spec and field-mapping docs become `RAD-41-*` (germline carries the shared infra), somatic plan references RAD-42. Both from the hub story template, components `api` + `ui`, reviewer the tech lead, class Complex, sub-tasks created 2026-10-07 before the formal plan review, at Yann's call: RAD-48 to RAD-52 under RAD-41, RAD-53 to RAD-55 under RAD-42, one per spec task. Original single-story preview below kept for the wording.

Template order: Title "Download the transcript report (XLSX) for a variant of a case"; Intent (geneticist, download the Excel transcript report for a variant to paste into the institutional report); Context (QLIN arranger today, data in Radiant, germline/somatic, CLIN-5734 wording, per-tenant template, list endpoint capped at 100); AC (button on the variant details panel for germline and somatic SNV; one tab per variant with the tenant layout; interpretation on the interpreted transcript row; 404 when the variant is not an occurrence of the case; cap 100 enforced; filename pattern; tenant without template = explicit error); Out of scope (multi-select, CNV/SV, TSV, PDF, storage, MCP, wording changes); Business risks checked: patient data, genomic formats, clinical rules; Class Complex; Reviewer Jeremy Costanza; components `api`, `ui`; parent RAD-1; DoR all checked.

### 4. Process feedback `scratchpad/radiant-hub-process-feedback.md` (Yann decides where it lands: hub issue/PR comment)

Points to write, each with a one-line proposal:

1. No slot for data-gap / field-mapping analysis although the tech lead asks for it: allow a companion `RAD-xxxx-<slug>-<topic>.md` or a "Data mapping" sub-table under Contract changes.
2. `feature-spec` skill forbids file paths, approved RAD-15 uses them in Modules impacted: pick one (paths allowed only in Modules impacted, or none).
3. "Linked PRs" exists in RAD-15, skill says no extra section: add it to the template or drop it.
4. Options are deleted once decided: keep a 3-line "Decision log" (date, who, why) so later readers know the rejected options.
5. Story template lacks Jira-required bits the skill knows (components, parent epic) and a "UX design needed?" flag (the multi-select question).
6. `docs/features/README.md` needs an index table with status (specs will pile up), like `clin-localstack/project-tasks/radiant-migration/README.md`.
7. Markdown is the source of truth: keep diagrams as mermaid in the md (GitHub renders them), generate an HTML page only on demand for a meeting.
8. Cross-cutting choices made inside features (per-tenant templates now used by emails and reports, template dir conventions) deserve an ADR in `docs/adr/`.
9. 15-minute review target vs a draft with options: cap the options table (one line per option) and review the options section in a separate 15 min.
10. Existing docs: per hub `CLAUDE.md`, module-internal docs stay in modules (`etl/design/*`, `portal/design/*`), cross-module go to the hub; CLIN/QLIN-side docs (`clin-localstack/project-tasks/radiant-migration/*`) stay on the CLIN side and are linked from the hub when relevant. Proposal: no move, add links; move only specs that are cross-module and still live (e.g. manifest notification if it gets Radiant-side follow-ups).

### 5. Memory (after approval, outside plan mode)

- `project` RAD team process (hub repo, templates, skills incl. rad-11 feature-spec, Jira RAD cloudId, components rule, markdown source of truth, no artifact unless asked, hub main checkout = no commit).
- `project` Radiant report data facts (gnomAD table holds joint v4, `clinvar_name` = ClinVar id, `mane_select` = versioned NM pair, RefSeq rows via `source`, `cosmic_mutation_set` missing from backend DDL, proxy JSON-only, notification template loader as per-tenant precedent).
- `user` team docs in English, CQGC-facing docs in French; brainstorm first with tech lead, drafts only.
- `MEMORY.md` index updated.

Not touched: clin-arranger, radiant-portal, radiant-portal-pipeline, clin-localstack (no code, no commits, no Jira writes).

## Verification

1. `diff <(grep -E '^## ' radiant-hub/docs/features/0000-template.md) <(grep -E '^## ' radiant-hub/docs/features/RAD-1-transcript-report.md)` shows only the extra `## Options considered`.
2. `wc -l` spec within 120-180 (draft with options); `grep -nE '\.go\b|\.tsx?\b|:[0-9]{2,}' ` finds no code paths in the spec; every table row has the same column count (`awk -F'|' '{print NF}'` per table).
3. Field-mapping doc: every arranger column (11 germline + 13 somatic + filename parts) present, each with a status value from the fixed list.
4. `git -C /home/yann/CHU/clin/radiant-hub status --short` lists only the two new docs; nothing committed; Jira unchanged (`getJiraIssue RAD-1` has no children).
5. Memory files have frontmatter and are indexed.
