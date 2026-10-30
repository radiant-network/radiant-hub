# RAD-169: Show the transmission mode, parental origin and parent calls of germline CNVs

## Story

- **Link:** [RAD-169](https://ferlab-crsj.atlassian.net/browse/RAD-169)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-169-cnv-post-processing`

## Chosen approach

**Summary:** the ETL loads the slivar VCF of each `radiant_germline_cnv_annotation` task as a CNV occurrence set of its own, under that task's id, in `germline__cnv__occurrence`. The DRAGEN occurrences of the alignment task stay. A case always keeps both sets, whether the two tasks are loaded in the same import or in different ones: the DRAGEN list (alignment task) and the slivar list (annotation task), with the parent calls, the parental origin and the transmission mode. The case page's CNV task selector lists both tasks and opens the newest. This choice may be revisited later.

### etl

- **Source:** cnv-post-processing at the pinned revision (`cad99b4`) writes `slivar/<family>.cnv.slivar.vcf.gz`: one family VCF with every member's FORMAT fields, after a per-sample and a family [truvari collapse](https://github.com/ACEnglish/truvari/wiki/collapse) and a depth refinement of missing genotypes. slivar adds 14 mode tags (one per family, valued with the family's affected members) and 8 `po_*` tags (one per child) ([output doc](https://github.com/Ferlab-Ste-Justine/cnv-post-processing/blob/cad99b4e0b7e39f5d88dfbd028d426df693dee4e/docs/output.md), [rules](https://github.com/Ferlab-Ste-Justine/cnv-post-processing/blob/cad99b4e0b7e39f5d88dfbd028d426df693dee4e/assets/cnv-slivar-functions.js)). The CNV post-processing DAG already registers it (`gcnv`, `vcf`).
- **Staging:** the staging view admits the slivar VCF of a `radiant_germline_cnv_annotation` task in `cnv_vcf_filepath`, one row per member. Today it admits no output of this task. The SJRA-1928 design note already lists this change.
- **Task model:** a CNV annotation task model, with the experiment, family role and affected status of every member, read with the germline SNV pedigree (father, mother, progenies). The CNV import and its gate in `import_part` accept it next to the alignment task.
- **Occurrences:** as for germline SNVs, one row per member in the VCF and per record that this member carries. A member with `0/0` or `./.` on a record gets no row for it. The extraction reads each record once for all members, as the SNV import does: the current CNV extraction loops over the file once per member, and the file can be read only once, so every member after the first would get no row. The positions, type and FORMAT fields are the slivar record's, so they can differ from the member's DRAGEN calls.
- **Parent fields:** as for germline SNVs, on the rows of every progeny (proband, brother, sister, sibling) when the task has at least one parent: the mother's and the father's FORMAT values of the same record, typed like the member's own columns. The slivar VCF keeps DRAGEN's FORMAT fields (`GT`, `CN`, `BC`, `PE`, `SM`): the pipeline's merge, collapse and refinement steps add none, and VEP and slivar write INFO tags only. To confirm on the header of one QA slivar VCF before task 1.
  - `mother_calls`, `father_calls` (`ARRAY<INT>`, from `GT`, as the SNV `*_calls`)
  - `mother_cn`, `father_cn` (`INT`, copy number)
  - `mother_bc`, `father_bc` (`INT`, number of bins)
  - `mother_pe`, `father_pe` (`ARRAY<INT>`, improperly paired reads at the two breakpoints)
  - `mother_sm`, `father_sm` (`FLOAT`, segment mean)
  - The depth refinement sets a missing `GT` to `0/0` and leaves `CN` empty, so a parent's calls can show `0/0` with no copy number.
- **Parental origin:** on the progenies' rows, each progeny's `po_*` value → the SNV values, one to one, with the mapping the germline SNV import already uses (`DENOVO`, `MOTHER`, `FATHER`, `BOTH`, `AMBIGUOUS`, `POSSIBLE_DENOVO`, `POSSIBLE_MOTHER`, `POSSIBLE_FATHER`). The CNV pipeline uses the SNV tag names.
- **Transmission mode:** on the progenies' rows, the CNV mode tag that lists the progeny, stored under its own name in `transmission_mode`. The CNV rules look at the child and its parents only, not at dominance or at who is affected, so no tag maps to an SNV value. The 14 tags give 13 new values: `denovo`, `denovo_suspect`, `possible_denovo`, `inherited_maternal`, `inherited_paternal`, `possible_inherited_maternal`, `possible_inherited_paternal`, `recessive`, `recessive_lowconf`, `inheritance_unresolved`, `mendelian_inconsistent`, `unknown_cn`, `x_linked_denovo`. `x_linked_recessive` already exists and keeps its label.
- **Empty values:** the alignment-task rows, the parents' rows, a task with no parent in the VCF, and a record with no tag keep the new columns `NULL`.
- **Schema:** the new columns go at the end of `germline__cnv__occurrence` and of the Iceberg germline CNV occurrence table. The occurrence insert is positional and the copy step is `SELECT *`, so both keep their order. The re-annotation statement lists its columns: it carries the new ones.
- **Two sets per sequencing:**
  - The copy step keeps the rows of the tasks not in the run, keyed on `task_id` as for germline SNVs. Today it keys on `seq_id`, and the run's `seq_id`s are those of every member of its tasks: a run with only the annotation task would drop the DRAGEN rows of every member.
  - The cytoband, gene, SNV-count and gnomAD steps of the insert and of the re-annotation join on `(seq_id, name)`. They also join on `task_id`, because both sets of one sequencing can hold the same call name.
- **Cohort frequencies:** the slivar intervals become intervals of the RAD-120 frequency table. A patient counts once per interval (`COUNT(DISTINCT patient_id)`), so carrying a CNV in both sets does not count twice.
- **Data QA:** the 13 new values in the transmission mode dictionary; a new parental origin dictionary (none exists today); a test that the parent, origin and mode columns are empty on the parents' rows.

### portal (backend)

- **Task list:** the CNV occurrence type selects the `alignment_germline_variant_calling` and the `radiant_germline_cnv_annotation` tasks of the case and sequencing, as the SNV type selects the annotation tasks for every member. The task selector takes one task type today. The list stays ordered newest first.
- **Fields:** on the germline CNV occurrence table: `transmission_mode` and `parental_origin` (selectable, filterable, aggregatable), and each `mother_*` and `father_*` column (selectable and sortable like the member's own). `transmission_mode` uses the existing facet dictionary; `parental_origin` has none, as for SNVs. No join.
- **Dictionaries:** the 13 new mode values join the transmission mode facet dictionary and the hard-coded mode list of the variant page's case filters. The SNV facet then lists them too, with a count of 0.
- **Contract:** new optional, nullable fields on the germline CNV list, count, aggregation and statistics; `tasks_with_occurrences` returns one more task type for `germline_cnv`. Additive. Swagger, TS and Python clients regenerated.

### portal (frontend)

- **Task selector:** no change. It lists the tasks the backend returns and opens the first one, the newest: the member's slivar set when it exists.
- **Columns:** transmission mode (the `TransmissionModeBadge` of the variant page and the SNV slider), parental origin, mother and father calls and copy numbers in the CNV table. Each one can be hidden or shown in the column settings. Default visibility deferred to grooming.
- **Query builder:** transmission mode (with dictionary) and parental origin facets in a parental analysis group of the germline CNV config, as in the SNV config, in the radiant, include and qlin portal configs.
- **Labels:** EN/FR label and tooltip per new column. Parental origin values have no translation today (the SNV slider shows the raw value in title case): this story adds `common.facets.values.parental_origin`. Each of the 13 new mode values gets a label and an abbreviation in the transmission mode badge. The uncertain ones (`denovo_suspect`, `possible_*`, `recessive_lowconf`) say so in their label and abbreviation.

### mcp

- **Clinical agent prompt:** a case can now have two `germline_cnv` keys for one sequencing. The prompt says to take the annotation task's key when there is one, and to read `transmission_mode` and `parental_origin` there instead of comparing the proband's CNVs with the parents' by hand. No code change.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | staging sequencing experiment view, CNV annotation task model, CNV import (slivar records, parent fields, `po_*` and mode tags) and its gate, Iceberg and StarRocks germline CNV occurrence schema, occurrence insert, copy and re-annotation statements, StarRocks migration, data QA dictionaries and tests, CNV post-processing DAG doc and SJRA-1928 note | modified / new |
| portal (backend) | CNV task selection, germline CNV occurrence fields, facet dictionary, variant case filters list, swagger, generated TS and Python clients, test DDL and fixtures, seed schema | modified |
| portal (frontend) | germline CNV table settings and cells, germline CNV query builder config (three portals), EN/FR translations | new / modified |
| mcp | clinical agent prompt (CNV key and inheritance columns) | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Load the slivar VCF as CNV occurrences | etl | Staging view branch, task model and import gate, slivar extraction (carrier records per member, parent fields on progenies, `po_*` and mode tags), schema (Iceberg, DDL, migration), copy keyed on `task_id`, insert and re-annotation joins on `task_id`, data QA, unit tests on slivar VCF fixtures, integration tests | — | yes: the portal lists no annotation task for CNVs until task 2 |
| 2 | Expose the slivar CNV set | portal (backend) | Task selection with both task types, fields, dictionaries, test DDL and fixtures, swagger and clients (2nd commit), integration tests | Task 1 migration run in each environment | yes once the migration has run |
| 3 | Labels | portal (frontend) | EN/FR labels and tooltips of the new columns, parental origin values, the 13 new mode values and their abbreviations; validated by the clinical team | — | yes |
| 4 | Show the CNV inheritance | portal (frontend) | Columns, cells, facets, column settings | Tasks 2, 3 | yes once task 2 is deployed |
| 5 | Agent prompt | mcp | CNV key rule and inheritance columns | Task 2 deployed | yes once task 2 is deployed |

No UX task: the task selector, the columns and the facets reuse existing components.

## Merge and rollout order

1. etl: task 1. In each environment, before the new DAGs run and with no import running:
   - add the columns to `germline__cnv__occurrence` in every `{tenant}_tenant` database (`ALTER TABLE … ADD COLUMN`). Otherwise the positional insert fails and every CNV import breaks;
   - run only the germline CNV occurrence init task, which recreates the Iceberg table with the new schema. Each import overwrites this table, so nothing is lost;
   - drop the two staging views and run `radiant-init-starrocks-base-tables` (the views are created with `IF NOT EXISTS`, as in RAD-116). Otherwise the slivar VCFs stay invisible.
2. etl: the next `radiant-import` loads every slivar VCF already registered: their staging rows are new, so the delta view selects them. No manual backfill.
3. portal backend: task 2, after step 1 in each environment. Before the migration, a query on a new column fails.
4. portal frontend: tasks 3 then 4. mcp: task 5.

No feature flag. Until task 2, the portal lists only the alignment tasks, so the slivar sets stay hidden.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1 (parent calls):** unit tests on slivar VCF fixtures (trio, duo, singleton, two siblings): each progeny's rows carry each FORMAT field of the mother and the father from the same record.<br>• **AC3, AC4 (origin and mode values):** one fixture per `po_*` tag and per mode tag; a `possible_*` or `*_suspect` tag never gives a confirmed value.<br>• **AC6 (DRAGEN list kept):** integration test: a part run with only the annotation task keeps the alignment-task rows of every member unchanged, and a run with both tasks gives each set its own cytobands, genes and gnomAD values.<br>• **Rows per member:** a trio's slivar VCF gives each member the records it carries, and no row for a `0/0` or `./.` record.<br>• **AC7 (empty values):** the alignment-task rows, the parents' rows and a singleton's rows have no parent, origin or mode value. |
| portal (backend) | • **AC2 to AC5:** integration tests (testcontainers): `tasks_with_occurrences` returns both CNV tasks, newest first, for the proband and for a parent; new fields in the list; filter on transmission mode and parental origin in list and count; aggregation; nulls on alignment-task rows. |
| portal (frontend) | • **AC4, AC7:** Vitest on the new cells: badge per mode, parental origin label, `-` when empty. |
| QA (manual) | • Two trios: one with both CNV tasks loaded in the same import, one with the annotation task loaded in a later import. Each case shows both CNV tasks, the slivar set by default; a few de novo and inherited CNVs read by hand in the slivar VCF match the table; EN/FR labels and column settings (AC8).<br>• The MCP agent answers a de novo question on that case from the slivar key. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: CNV mode tags must keep their meaning (`denovo_suspect`, `possible_denovo` never shown as a confirmed de novo) | Each CNV tag is stored under its own name: no tag is folded into an SNV value or into a confirmed one. The labels of the uncertain values say so, and the clinical team validates them (task 3). One test per tag pins its value. Parental origin keeps the separate `POSSIBLE_*` values. |
| Genomic formats or data: the slivar records are merged and collapsed, so their positions differ from the DRAGEN calls | The slivar set is a separate task: its positions are shown as the pipeline wrote them, and the DRAGEN set stays unchanged next to it. No record is matched or guessed across files. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • The VEP CSQ annotation of the slivar VCF.<br>• A CNV detail panel and the CNV interpretation form.<br>• Somatic CNVs.<br>• The Exomiser CNV results (separate story).<br>• Keeping both sets is a first choice: no merge of the two lists, no rule to hide the DRAGEN set. |
| etl | • No change to the CNV post-processing pipeline, its DAG or its outputs. |
| portal (backend) | • One transmission mode dictionary for SNVs and CNVs: no CNV-specific dictionary. The SNV facet lists the CNV values with a count of 0, and the CNV facet lists the SNV values the same way. |
| portal (frontend) | • Notes and flags stay per task: a note on a DRAGEN CNV does not show on the slivar set.<br>• The SNV slider keeps its raw parental origin display. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **Several affected children:** a mode tag lists the family's affected members, not the child the call is about. With two affected children, each one can be listed under the other's tag. Proposal: per progeny, keep only the tags that agree with its own `po_*` value (both come from the same rule row); if several remain, pick by a fixed precedence. |
| story / product | • **Default visibility** of the new columns (deferred to grooming).<br>• **Story wording:** "the list of proband CNVs and their positions do not change" holds for the DRAGEN set. The slivar set is a second list, with the pipeline's positions. The story also speaks of the proband only, while the plan follows SNVs: every member gets a slivar set, and siblings get the parent values too. Proposal: reword the ACs. |

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
