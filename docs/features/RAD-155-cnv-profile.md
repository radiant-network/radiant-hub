# RAD-155: Show the CNV profile of a germline sequencing

## Story

- **Link:** [RAD-155](https://ferlab-crsj.atlassian.net/browse/RAD-155) (tasks [RAD-156](https://ferlab-crsj.atlassian.net/browse/RAD-156) backend, [RAD-157](https://ferlab-crsj.atlassian.net/browse/RAD-157) frontend)
- **Assigned reviewer:** to be assigned
- **Status:** In progress (written after the implementation; the backend PR is open)
- **Branch (all repos):** one branch per task in the portal: `feat/rad-156-cnv-profile-api`, then `feat/rad-157-cnv-profile-ui`

## Chosen approach

**Summary:** the portal backend reads the DRAGEN CNV files of the case's variant calling task from S3 and the reference tables from StarRocks, and serves them as one profile. The frontend draws them as stacked tracks with Plotly. No ETL change: every source exists today.

### Track → source

| Track | Source | Served by |
|---|---|---|
| Copy ratio (dots) | DRAGEN `*.tn.bw` (tangent-normalised log2 coverage), shown as 2^log2, capped at 6.5 | `GET …/cnv/{case_id}/{seq_id}/{task_id}/profile`, plus `…/profile/region` for a genome |
| BAF (dots) | DRAGEN `*.baf.bw` (B-allele frequency of each SNV) | same as copy ratio |
| CNVs (segments drawn over the copy ratio) | StarRocks `germline__cnv__occurrence` of the task, with the note and flag marks from `occurrence_note` and `occurrence_flag` (Postgres, through `radiant_jdbc`) | `…/profile` |
| ROH | DRAGEN `*.roh.bed` (optional: the track stays empty without it) | `…/profile` |
| Cytobands (ideogram, top) | StarRocks `cytoband` | `…/profile` |
| Genes and exons | StarRocks `ensembl_gene` and `ensembl_exon_by_gene` (exons of the transcript with the most exons), `omim_gene_panel` (inheritance, conditions), `gnomad_constraint` (pLI, LOEUF) | `GET /{tenant}/genes/track` (region ≤ 20 Mb, or one symbol) |
| CNV details: overlapping genes | CNV gene overlap of the CNV table, now with the biotype, strand, OMIM inheritance, pLI and LOEUF of each gene, and `nb_exons` counted on the same transcript as the gene track | existing `…/{cnv_id}/genes_overlap` |
| CNV details: flag, comments | existing occurrence flags and notes | existing flag and note endpoints |
| Gene search | existing gene autocomplete | existing `GET /{tenant}/genes/autocomplete` |

### By module

| Module | Approach |
|---|---|
| portal (backend) | • **Files:** found like the IGV case tracks: the `igv` documents (`bw`, `bed`) that the `alignment_germline_variant_calling` task wrote for the sequencing. Only the task of the URL is read, the one the CNVs come from, so every track is from the same run.<br>• **Access check:** the case must have the sequencing and the task must have analysed it (404 otherwise). The routes use the `ActionSearchCase` permission, like the other CNV occurrence routes. S3 is read with the API's own credentials; the browser never gets a file URL.<br>• **Exome (`wxs`):** both bigWigs are read whole (about 7 MB, capped at 64 MB) and every point is returned.<br>• **Genome (`wgs`):** the bigWigs are tens of MB. The API reads them by S3 ranges and returns an overview: a regular sample of at most 200,000 points per track, with its stride. The overview is cached in memory (20 entries, 30 min). The region endpoint returns every point of a region of at most 10 Mb.<br>• **bigWig reader:** a small in-house reader of the [UCSC bigWig format](https://genome.ucsc.edu/goldenPath/help/bigWig.html): chromosomes and full-resolution data, by region, reading only the blocks a query needs.<br>• **Chromosomes:** the union of the chromosomes of both files (DRAGEN can leave chrY out of one), in genome order. CNVs and cytobands are sorted in the same order.<br>• **Exon count:** one rule for the gene track and `genes_overlap`: a gene's exons are those of its transcript with the most exons (ties: the smallest transcript id). Ensembl keeps one exon per set of bounds, so the old `nb_exons` (distinct exon ids over all transcripts) counted the variants of an exon apart. Merging the transcripts was dropped too: a retained intron fuses canonical exons (NF1: 64 merged blocks, 59 exons on one transcript). Interim rule until [RAD-159](https://ferlab-crsj.atlassian.net/browse/RAD-159) counts on the MANE Select (or canonical) transcript.<br>• **API change:** `genes_overlap` (germline and somatic) gains optional `biotype`, `strand`, `omim_inheritance_code`, `gnomad_pli`, `gnomad_loeuf`, ignored by the MCP client. Its `nb_exons` keeps its name and type but gets smaller where a gene has alternative exon bounds: the `# Exons` of the CNV overlapping-gene table changes with it.<br>• **Errors:** 404 with `detail.missing` (`copy_ratio`, `baf`) when a bigWig is absent from S3; 400 for a region on an unknown chromosome; 422 for another strategy or a file too large. A missing or unreadable ROH file gives an empty ROH track and a warning in the logs. |
| portal (frontend) | • **Entry points:** a "CNV profile" button on the CNV tab (disabled outside WXS and WGS), and a CNV of the CNV table or of its overlapping genes, which opens the profile focused on that CNV.<br>• **Chart:** Plotly, loaded only when the dialog opens. Tracks top to bottom: cytoband ideogram, copy ratio with the CNVs, BAF, ROH, genes. Whole-genome view and chromosome view, zoom by drag or region search, fullscreen.<br>• **Rendering:** the dot clouds are WebGL (thousands of points). CNVs are layout shapes drawn above WebGL, at their exact span. Genes, ROH and cytobands are SVG. WebGL lines lose precision at genome coordinates, so nothing that must be exact uses them.<br>• **Genome zoom:** below 10 Mb, the region endpoint replaces the overview dots of the view. Genes are listed below 20 Mb, exons drawn below 2 Mb.<br>• **Details panels:** CNV (calls, overlapping genes, ClinGen and Franklin links, flag, comments) and gene (OMIM, pLI, LOEUF, exons, CNVs overlapping it). The selected CNV, gene or exon is highlighted on every track.<br>• **Sync:** a flag or comment changed in the profile refreshes the CNV table. |

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | CNV profile and region routes, gene track route, bigWig reader, CNV profile tracks, CNV profile repository, gene repository, S3 store (ranged reads), OpenAPI spec, generated TS and Python clients, Postman collection | new / modified |
| portal (frontend) | CNV tab (button), CNV table (open on a CNV or gene; the `# Exons` of the overlapping genes changes through the API), new CNV profile dialog, chart, panels and hooks, EN/FR translations | new / modified |
| etl, mcp, infra, bioinfo | none (the MCP Python client is regenerated but its pinned SHA is not bumped) | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | [RAD-156](https://ferlab-crsj.atlassian.net/browse/RAD-156) Serve the CNV profile in the API | portal (backend) | Profile, region and gene track routes, bigWig reader, tests and fixtures; 2nd commit: spec and generated clients ([#1819](https://github.com/radiant-network/radiant-portal/pull/1819)) | — | yes (additive routes, no caller yet) |
| 2 | [RAD-157](https://ferlab-crsj.atlassian.net/browse/RAD-157) Show the CNV profile in the case CNV tab | portal (frontend) | Dialog, chart, panels, entry points, translations, unit tests | Task 1 | yes once 1 is deployed |

No UX task: the layout follows the CQGC CNV plot. No Labels task: the new texts are track names, field names already used in the CNV table, and error messages.

## Merge and rollout order

1. portal backend (task 1). Needs no migration: it reads existing tables and files.
2. portal frontend (task 2), after the backend is deployed. Otherwise the profile button opens a dialog that fails on a 404 route.

No backfill. No feature flag: the button is disabled when the sequencing has no profile.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • Unit tests of the bigWig reader and of the tracks on generated bigWig fixtures (copy ratio, BAF, ROH, union of chromosomes, sampling). AC 1, 4<br>• Handler tests: exome, genome overview and cache, region, missing file, wrong strategy, sequencing not in the case, genome order. AC 1–4<br>• Integration tests (StarRocks and MinIO containers): profile, region and gene track on seeded data. AC 1, 4, 6 |
| portal (frontend) | • Unit tests of the chart logic: traces, hit areas, gene lanes, region, focus, overlaps. AC 5, 6 |
| QA (manual) | • Exome and genome cases on QA: open from the tab and from the table, zoom, region loading, panels, flag and comment synced to the table, fullscreen. AC 1–8 |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data (DRAGEN bigWig and BED, GRCh38) | The reader follows the UCSC format and is tested on files written by `pyBigWig`. Chromosome names are normalised (`chr` prefix dropped). The union of chromosomes covers files that differ. All tracks come from one task. |
| Patient or identifying data | Files are read on the server only. The routes check that the case, the sequencing and the task go together, under the case search permission. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Somatic sequencings (tumour/normal).<br>• Editing CNV calls.<br>• Cohort CNV frequencies ([RAD-120](https://ferlab-crsj.atlassian.net/browse/RAD-120)). |
| portal (backend) | • Exon count on the MANE Select (or canonical) transcript ([RAD-159](https://ferlab-crsj.atlassian.net/browse/RAD-159)): today it uses the transcript with the most exons, which can hold an exon the reference transcript lacks.<br>• pLI/LOEUF on the reference transcript: today the constraint takes the most constrained transcript of the gene.<br>• gnomAD constraint v4.1.1 ([RAD-161](https://ferlab-crsj.atlassian.net/browse/RAD-161)): `gnomad_constraint` is still v2.1.1, so the LOEUF threshold stays 0.35.<br>• bigWig zoom levels: the genome overview samples the full-resolution data.<br>• Faster genome zoom (cached file index, parallel reads, single-flight overview): a separate ticket if the latency is an issue. |
| portal (frontend) | • Export of the chart as an image. |

## Open questions

| Module | Questions |
|---|---|
| portal (backend) | • Genome zoom latency: each region request reopens both files over S3 (about a dozen ranged reads in sequence). Proposal: measure on prod-size files, then cache the file index if needed. |
| story / product | • Reviewer to assign. |

## Approval

| | |
|---|---|
| Reviewer | to be assigned |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
