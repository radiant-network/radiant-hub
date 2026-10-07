# RAD-40: Filter CNVs by gene panels

## Story

- **Link:** [RAD-40](https://ferlab-crsj.atlassian.net/browse/RAD-40)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** In review
- **Branch (all repos):** `feat/rad-40-filter-cnv-by-gene-panels`

## Chosen approach

**Summary:** reuse the tenant gene panels of [RAD-10](RAD-10-filtered-variants-by-gene-panels.md): same Postgres tables, same per-tenant MV, same SQON field `tenant_gene_panel`. The CNV queries already join the public panel tables on the CNV symbols, so the new field plugs into that join. The overlapping genes window gets a Panels column, fed by the existing `genes_overlap` endpoint.

- **portal (backend)**
  - **Filter:** add the existing field `tenant_gene_panel` (merged with RAD-10, SNV only today) to the germline and somatic CNV fields, like `omim_gene_panel`. Its MV is already in the list of gene panel tables that the SNV and CNV queries share, so the CNV query joins it with no new code: a CNV matches when its symbols contain the panel symbol.
    - The CNV list, count and aggregate already count each CNV once when it overlaps several genes of one panel.
    - A unit test now asserts that the CNV fields exclude `tenant_gene_panel`. This story reverses it.
  - **Same gene names everywhere:** the CNV symbols, the genes of the window and the panel symbols are all `ensembl_gene` names. The ETL fills the CNV symbols from the `ensembl_gene` rows that overlap the CNV. The panel upload resolves each input (symbol or Ensembl ID) against `ensembl_gene` and stores the gene name. So an exact symbol join is enough.
  - **Panels shown:** only the panels of the last uploaded file. The upload is the only writer of panel genes, and it clears the genes of every panel that the file does not name. A catalog panel shows only when the file names its code, under its catalog name. No change to the MV.
  - **Overlapping genes:** the germline and somatic `genes_overlap` endpoints return, for each gene, the names of the tenant panels that contain it. New field on `CNVGeneOverlap`: `tenant_gene_panels` (array of panel names, empty when none). Source: the MV `{tenant}_tenant.gene_panel_mv`, joined on the gene symbol.
    - **Access:** the same identity as the other CNV reads: the root pool, or the user through mysql-proxy when `STARROCKS_PROXY_READ_ENABLED` is on. The existing Ranger policy `sr_access_<code>_mvs` gives the tenant role SELECT on every MV of the tenant database. No new grant.
    - Public panels (OMIM, HPO, …) in the window: not decided yet (see open questions).
- **portal (frontend)**
  - **Facet:** `tenant_gene_panel` in the germline CNV "gene" group, next to the public panel facets, with the same multiselect config.
  - **Panels column:** new column in the overlapping genes window. It shows the panel names of the gene.
  - **Panel filter in the window:** the user picks one or more panels, and the window keeps only their genes. The CNV list does not change. It runs in the browser, because the window already loads all genes in one call. It reuses the data table's filter bar and the filter buttons of the files table. Its options are the panels of the loaded genes.
- **mcp**
  - No change. The new SQON field and response field are visible after the next client bump.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | germline and somatic CNV fields, CNV genes overlap query and response type, OpenAPI spec, generated clients | modified |
| portal (frontend) | germline CNV facet config, overlapping genes window (columns, filter), EN/FR translations | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | CNV SQON field | portal (backend) | `tenant_gene_panel` on germline and somatic CNV (filter, count, aggregate); reverse the exclusion test; integration tests | — (RAD-10 backend merged) | yes (additive) |
| 2 | Panels in overlapping genes | portal (backend) | `tenant_gene_panels` on `CNVGeneOverlap`, join on the tenant MV; OpenAPI + clients; integration tests | — (RAD-10 backend merged) | yes (additive) |
| 3 | Labels | portal (frontend) | EN/FR labels for the Panels column and its filter. The facet reuses the `tenant_gene_panel` labels of RAD-10 | RAD-10 labels task | yes |
| 4 | CNV facet | portal (frontend) | Facet `tenant_gene_panel` in the germline CNV gene group | Tasks 1, 3 | yes once 1 is deployed |
| 5 | Panels column | portal (frontend) | Panels column and its panel filter (browser side) in the overlapping genes window | Tasks 2, 3 | yes once 2 is deployed |

No UX task: the panel filter reuses the existing filter bar and filter buttons.

## Merge and rollout order

1. portal backend: tasks 1 and 2. The RAD-10 backend (MV, Ranger policy, SNV field) is already deployed, and `refresh-tenants` has run in each environment.
2. portal frontend: tasks 3 to 5, after step 1 in each environment.

No migration, no backfill. No feature flag: the facet and the column are empty until a panel is loaded. Like RAD-10, the plan needs tenant-scoped reads. This becomes the default when the migration flag `TENANT_VIEWS_READ_ENABLED` is removed. Until then, the flag must be on.

## Test strategy

| Module | How the story is proven |
|---|---|
| portal (backend) | • **AC1 (facet):** StarRocks integration tests on the CNV fixtures, as for `omim_gene_panel`: filter on one and several panels, count, aggregate without duplicates when a CNV spans several genes of one panel. Germline and somatic.<br>• **AC2 (window):** `genes_overlap` test: a gene in two panels returns both names, a gene in no panel returns an empty list, no duplicate rows. |
| portal (frontend) | • **AC3 (panel filter):** Vitest unit test on the filter logic: selecting a panel keeps only its genes; the CNV list is not touched. The case app has no unit test yet, so this adds the first one. |
| QA (manual) | • Load a panel on QA, filter a germline CNV case with the facet (AC1).<br>• Open the window on a CNV with many genes, check the Panels column and its filter (AC2, AC3). |

## Risks and coverage

The story checks no particular business risk. Tenant isolation comes from RAD-10 (MV per tenant); the backend tests use the tenant-qualified MV.

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No change to panel loading or storage: RAD-10 owns them.<br>• No change to SNV. |
| portal (frontend) | • Somatic CNV: no UI. The frontend has no somatic CNV tab today (its facet config is empty, and the somatic page shows SNV only). The backend field is ready for it.<br>• No change to the CNV list columns (no Panels column in the main table).<br>• No link from a panel in the window to the CNV query: the AC1 facet already filters the CNV list. |
| mcp | • No client bump, no new tool. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • **Window panels:** show only the tenant panels, or also the public panels (OMIM, HPO, Orphanet, DDD, COSMIC)? Proposal: tenant panels only, as the story says "custom gene panels". |

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
