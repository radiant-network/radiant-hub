# RAD-93: Take parental origin and transmission mode from slivar in germline SNV imports

## Story

- **Link:** [RAD-93](https://ferlab-crsj.atlassian.net/browse/RAD-93)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-93-slivar-inheritance`

## Chosen approach

**Summary:** the ETL reads `parental_origin` and `transmission_mode` from the slivar tags of the germline VCF when its header declares them (pipeline `8ad7c95` or later), and keeps its own calculation for every other VCF. The portal learns one new value, `uniparental_disomy`. The empirical comparison on a trio and a duo is in the [comparison doc](https://claude.ai/code/artifact/1314766f-533e-41a7-988c-4b6f5c3dc057).

### etl

- **Method per VCF:** the germline SNV processing reads the VCF header once. When it declares the full set of new inheritance tags (`po_*`, the mode tags named after `transmission_mode` values, `unknown_*_genotype`, `non_carrier_proband`, `uniparental_disomy`, `candidate`), every occurrence of that VCF takes its values from the tags. Otherwise the current calculation runs, unchanged. A partial set is treated as absent and logged. Not decided yet: the exact list required (see open questions).
- **Slivar rules:** the selection rules of the story, applied per progeny sample: modes first (de novo > recessive > dominant > `uniparental_disomy`), the others in `other_transmission_modes`; genotype tags otherwise; a mode wins over `unknown_father_genotype` / `unknown_mother_genotype`; no tag → empty. `po_*` maps one to one to `parental_origin`.
- **New occurrence columns:** `other_transmission_modes` (list of strings), `transmission_mode_candidate` (boolean), `inheritance_source` (`slivar` or `etl`). Written to the Iceberg germline occurrence table, then appended at the end of `germline__snv__occurrence` (positional insert, `SELECT *` copy).
  &nbsp;&nbsp;◦ The Iceberg occurrence table has no schema evolution: how it gets the new fields is not decided yet (see options).
  &nbsp;&nbsp;◦ RAD-39 (in progress) also appends two columns to `germline__snv__occurrence`. Both migrations must keep the order of the create-table DDL: RAD-93's columns go after RAD-39's.
- **Siblings in the PED:** the PED the ETL writes for the pipeline gives every progeny (proband, brothers, sisters) the case's father and mother when they are sequenced. Today only the proband is linked, so siblings would get no `po_*` tag and no trio-based tag. Exomiser's phenopacket pedigree is built separately and does not change.
- **Pipeline revision:** the launcher image pin (`PIPELINE_REV`) and the annotation task's pipeline version move together to a revision that writes the new tags. The target revision depends on the open question on `impactful`.
- **Data QA:** `uniparental_disomy` joins the transmission mode dictionary. New tests: values of `other_transmission_modes` in the same dictionary, `inheritance_source` in (`slivar`, `etl`), `transmission_mode_candidate` not null when `inheritance_source = 'slivar'`.
- **Readers:** the portal reads `transmission_mode` and `parental_origin` as today. The three new columns have no reader yet (story: not exposed). The MCP sees them through SQL; its prompt is not updated.

### portal (backend)

- **Dictionary:** `uniparental_disomy` is added to the transmission mode facet dictionary and to the hard-coded transmission mode list of the variant page's case filters. No new field, no API shape change: the value already flows as a string.

### portal (frontend)

- **Display:** the transmission mode badge and the EN/FR translations get `uniparental_disomy`, with a label that says "compatible with" (the story's clinical risk) and an abbreviation. The facet uses the backend dictionary, so it needs no config change.

### infra

- **Nextflow config:** the QA and prod `nextflow-snv-cfg` ConfigMaps are written for revision `b535f27` and say to bump them with the pin. They must be checked against the new revision (new `skip_ped_validation` parameter, process names) before the pin moves.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | germline SNV VCF processing (header detection, slivar rules, new fields), Iceberg germline occurrence schema, germline occurrence DDL, insert and migration, Nextflow PED builder (siblings linked to their parents), launcher image pin and annotation pipeline version, data QA dictionary and tests | modified / new |
| portal (backend) | transmission mode facet dictionary, variant case filters list, their tests | modified |
| portal (frontend) | transmission mode badge, EN/FR translations | modified |
| infra | QA and prod Nextflow SNV config, checked against the new pipeline revision | modified (if needed) |
| bioinfo | slivar pre-filter and X-linked fixes (open questions), owned by the bioinfo team | outside this plan |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Read inheritance from slivar tags | etl | Header detection, slivar rules, three new fields (Iceberg schema, DDL, migration, insert), data QA, unit and integration tests on slivar VCF fixtures (trio, duo, solo, old tag names) | RAD-39 task 2 merged (column order) | yes: no VCF carries the new tags until task 3 |
| 2 | Link siblings to their parents in the PED | etl | PED builder and its tests | — | yes |
| 3 | Bump the SNV post-processing revision | etl (+ infra) | Launcher pin and annotation pipeline version; infra Nextflow config re-synced if needed | Task 1, pipeline revision decided | no: turns slivar on for every new import |
| 4 | Labels | portal (frontend) | EN/FR label and abbreviation for `uniparental_disomy`, validated by the clinical team | — | yes |
| 5 | Show `uniparental_disomy` | portal (backend + frontend) | Backend dictionaries and tests, badge, translations | Task 4 | yes |

No UX task: the badge and the facet reuse the existing components.

## Merge and rollout order

1. portal: tasks 4 and 5, first. Otherwise the first `uniparental_disomy` shows as a raw value and the facet misses it.
2. etl: tasks 1 and 2. Run the migration on every `{tenant}_tenant` database, and create the new Iceberg fields (per the chosen option), **before** the DAGs are deployed. Otherwise the positional occurrence insert fails and every `import_part` breaks.
3. infra: re-sync the Nextflow SNV config if the check finds a gap (QA, then prod).
4. etl: task 3, the pin bump, last, once the pipeline revision is decided. From then on, every new case gets the slivar values.

No feature flag: the header decides per VCF. No backfill: loaded cases keep the ETL values until they are re-imported, and `inheritance_source` stays empty for them.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • Unit tests on the slivar rules with VCF fixtures: trio, duo with an affected parent, solo, several modes on one sample, `uniparental_disomy` alone and with a dominant, `candidate` (AC 4 to 9).<br>• A VCF with old tag names, and one without tags, give exactly the current values (AC 3).<br>• Integration test: the three new columns land in StarRocks with `inheritance_source` set (AC 2, 10).<br>• Data QA on the dictionaries (AC 12). |
| portal (backend) | • Facet dictionary and case filters include `uniparental_disomy` (AC 11, 12). |
| portal (frontend) | • Badge renders the new value and its abbreviation (AC 11). |
| QA (manual) | • Re-run CA307 (trio) and CA330 (duo) on QA after task 3 and compare with the comparison doc's figures (AC 1, 2).<br>• One case with `uniparental_disomy` shown in the facet and badge (AC 11). |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data: depends on the tag names in the header and on the pipeline revision | The header check requires the full tag set and logs a partial one. The fixtures pin the tag names of the chosen revision. `inheritance_source` shows which method ran. |
| Clinical rules or interpretation: stricter modes, empty values outside the pre-filter, single-variant UPD | The pin bump waits for the `impactful` decision. The comparison doc quantifies the change for the geneticists before release. The UPD label says "compatible with". |
| Traceability and audit: both methods in one tenant | `inheritance_source` on every progeny occurrence imported after task 1. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No exposure of `other_transmission_modes`, `transmission_mode_candidate` or `inheritance_source` in the API, UI or MCP prompt.<br>• No re-import or backfill of loaded cases.<br>• Compound heterozygotes (RAD-39). Somatic occurrences. |
| etl | • The current calculation keeps its known bugs (sex passed as `male`/`female` while its X/Y tables expect `Male`/`Female`; X ploidy taken from the GT). A separate ticket will fix them.<br>• No per-variant fallback inside a slivar VCF. |
| bioinfo | • No change to slivar's rules in this plan; the needs are listed in open questions. |

## Open questions

| Module | Questions |
|---|---|
| bioinfo | • **`impactful` pre-filter:** without its removal, ~92 % of carrier rows of a slivar case lose both values (CA307). Proposal: remove it from `--info`, keep it on the compound-het sides and on a dedicated de novo side for `compound-hets` (~4 config lines). The pin bump (task 3) waits for this.<br>• **X-linked modes:** exclude the PAR, check unaffected parents' quality in the X de novo rule, settle father-alt / mother-unknown for a son (`POSSIBLE_FATHER`).<br>• **Dominant in a duo with an affected parent:** 67,012 rows on CA330, never `candidate`. Flag it `candidate`, or keep it? |
| etl | • **Required tag set** for the header check: every new tag, or only `po_*` + the mode tags? Proposal: every tag of the chosen revision.<br>• **Sibling hom-alt with an affected hom-alt mother:** rule 1 keeps recessive over dominant. Keep? |
| story / product | • **Reviewer:** TBD.<br>• **Unaffected progenies:** slivar gives them no mode. Acceptable?<br>• **Proband affected status** of CA307 and CA330 was assumed in the comparison. |

## Options considered

| Axis | Option | Behaviour | Pro / con | Effort |
|---|---|---|---|---|
| **A. New fields in the Iceberg occurrence table** | A1: recreate the table | Run only the germline occurrence init task before the deploy, as SJRA-1820 and SJRA-1833 did for other tables. | + existing practice. − the Iceberg occurrence history is lost (only the occurrence insert reads it, for the tasks being imported); an import running during the switch fails. | S |
| | A2: add the fields in place | A one-off schema update adds the three fields to the existing table. | + no data loss, no window. − a new mechanism, never used in this ETL. | M |

Preliminary lean: **A1** (existing practice, the lost history has no reader).

## Approval

| | |
|---|---|
| Reviewer | TBD |
| Date | … |
| Plan review duration | … min |
| Decision | Approved / Approved with adjustments / Rework needed |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
