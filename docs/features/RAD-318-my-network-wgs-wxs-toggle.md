# RAD-318: WGS/WXS toggle on the My Network card of the variant Frequency tab

## Story

- **Link:** [RAD-318](https://ferlab-crsj.atlassian.net/browse/RAD-318) (related: [RAD-31](https://ferlab-crsj.atlassian.net/browse/RAD-31), the same WGS/WXS split in the case pages)
- **Assigned reviewer:** Karl Ritchie
- **Status:** Draft
- **Branch (all repos):** `feat/rad-318`

### Acceptance criteria

Copied from the story on 2026-11-19. AC1, AC2, AC5 and AC6 follow a decision with Jean-Philippe Thibert of the same day, not yet in the story: WXS on load, and no empty state, since the story removed its Empty state section.

- **AC1:** the My Network card header shows a WGS | WXS toggle, with WXS selected on load.
- **AC2:** switching the type re-renders the global row, the `Frequency` and `Homozygotes` columns and the tooltips, for the selected type only.
- **AC3:** the selection persists across the Primary Condition / Project / Analysis split tabs.
- **AC4:** frequencies render as `pc / pn` in both modes.
- **AC5:** removed: no empty state.
- **AC6:** the toggle labels and the tooltips render in EN and FR.

## Chosen approach

**Summary:** both My Network endpoints take an optional sequencing type, `wgs` by default, and return the same shape for that type only. The card adds a toggle that sets this type on both calls, for every split tab.

### portal (backend)

- **Global row:** `GET /{tenant}/variants/germline/{locus_id}/internal_frequencies/global` reads the WXS columns of `snv__variant` (`germline_pc_wxs`, `germline_pn_wxs`, `germline_pf_wxs` and their `_affected` / `_not_affected` twins) when the type is `wxs`. The ETL already fills them, with the same quality gate as WGS. No ETL change.
- **Split tables:** `GET /{tenant}/variants/germline/{locus_id}/internal_frequencies` filters the sequencings on the requested type. Today the split query keeps WGS sequencings only. The rest of the query (quality gate, dedup per patient and fetus, affected status) is unchanged.
- **API field:** a new optional query param `sequencing_type` on both routes, values `wgs` and `wxs`, default `wgs`. Any other value returns 400, like an unknown `split`. Response shapes are unchanged.
- **Contract:** additive. Readers: the portal frontend (TS client) and the MCP variant details tool (global route, no param). The MCP keeps its WGS answer through the default and its pinned client. Swagger, TS and Python clients are regenerated.

### portal (frontend)

- **Toggle:** a `ToggleGroup` (WGS | WXS) in the My Network card header, WXS selected on load. The frontend always sends the type, so the API default plays no part. The state lives in the card, above the split tabs, so it persists when the user switches tabs. It is not saved across page loads.
- **Data:** the selected type is part of the cache key and the request of the global call and of the split call. Switching the type refetches; switching back hits the cache.
- **Cells:** the existing frequency cell keeps the `pc/pn` display, with the frequency in brackets, in both modes.
- **No carrier:** a type with no carrier shows the global row and the table with `0 / N`, as the card does today.
- **Tooltips:** every tooltip of the card names the selected type: the three global row labels and the `Frequency` and `Homozygotes` column headers (new header tooltips). One translation key per type. The texts come from the mockup; the WGS global row tooltips, which the mockup lacks, take the WXS text with WGS.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | germline variant internal frequencies handlers and repository, swagger, generated TS and Python clients, Postman collection | modified |
| portal (frontend) | variant entity My Network card and its table settings, EN/FR translations | modified |
| portal (cypress) | variant entity Frequency My Network specs and page object | modified |
| etl, mcp, infra, bioinfo | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | [RAD-371](https://ferlab-crsj.atlassian.net/browse/RAD-371) Sequencing type on the My Network endpoints | portal (backend) | Optional `sequencing_type` on both routes, WXS columns for the global row, type filter in the split query, validation, swagger, TS and Python clients, Postman, repository and handler tests | — | yes (additive, default keeps today's answer) |
| 2 | [RAD-372](https://ferlab-crsj.atlassian.net/browse/RAD-372) Labels | portal (frontend) | EN/FR toggle labels and tooltips, WGS and WXS tooltips of the global row and the two column headers, validated by the clinical team | — | yes |
| 3 | [RAD-373](https://ferlab-crsj.atlassian.net/browse/RAD-373) WGS/WXS toggle | portal (frontend) | Toggle with WXS on load, type in both calls, tooltips per type, Vitest, Cypress My Network specs and page object | Tasks 1, 2 | yes once task 1 is deployed |

No UX task: the mockup in the story gives the layout and the wording.

## Merge and rollout order

1. portal backend: task 1. Otherwise the card opens on WXS with the WGS frequencies, since the backend ignores an unknown query param.
2. portal frontend: tasks 2 then 3.

No migration, no backfill, no feature flag: the WXS columns are already filled by the ETL.

## Test strategy

### portal (backend)

- **AC2:** repository integration tests (testcontainers) on fixtures with WGS and WXS sequencings: the global row and each split return the counts of the requested type only, and `wgs` by default matches today's answer.
- **AC2:** a locus with carriers of one type only returns `pc = 0` for the other type.
- **Validation:** handler tests, JSON compared to the expected body, and 400 on an unknown type.

### portal (frontend)

- **AC1, AC2, AC3:** Vitest on the card: WXS on load, the type sent on both calls, the type kept across tab switches, `0 / N` on an answer with no carrier.
- **AC1, AC2, AC3, AC6 (Cypress):** the My Network specs, updated in task 3, check the toggle, WXS on load, a WGS switch and the tooltips on QA data. The value, column and tooltip specs fail without the update, since the card now opens on WXS. Check first that the specs' QA variants have WXS carriers.

### sandbox (local)

- **AC1 to AC4, AC6:** on the sandbox, call both routes with each type through the API, then check the card in EN and FR on one variant with WXS carriers and one without. Check first that the sandbox holds WXS sequencings; if not, report it.

### QA (manual)

- **AC4, AC6:** compare the WXS global row with the case page values of RAD-31 on a few variants, and read the tooltips in both locales. Visual, so checked by hand.

## Risks and coverage

The story checks no business risk.

## Frozen scope

### all

- Somatic variant entity page (`Freq. TN`, `Freq. TO`): story out of scope.
- The WXS denominator is cohort-wide, not coverage-aware: a variant outside the capture region reads `0 / N` exomes. No capture-interval filter (story's coverage caveat).
- No MCP change: its variant details keep the WGS frequencies. WXS in the MCP would be a separate ticket.
- The `Public Cohorts` card is unchanged.

### portal (backend)

- The global route keeps its name. It returns the tenant's cohort, not the network's (known follow-up in the backend docs).
- The split counts dedupe per patient and fetus, the global row per patient (ETL). The known gap stays, for both types.

### portal (frontend)

- The tooltips keep saying "network" and "Filter = PASS and GQ ≥ 20", although the cohort is the tenant and the gate also requires `ad_alt ≥ 3`. A separate ticket will fix the wording if needed.
- The selected type is not saved in the URL or the user preferences.
- No empty state: a type with no carrier shows `0 / N` (story's Empty state section removed).

## Open questions

None.

## Approval

| | |
|---|---|
| Reviewer | Karl Ritchie |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
