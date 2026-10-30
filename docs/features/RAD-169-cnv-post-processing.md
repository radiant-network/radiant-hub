# RAD-169: Show the transmission mode, parental origin and parent calls of germline CNVs

## Story

- **Link:** [RAD-169](https://ferlab-crsj.atlassian.net/browse/RAD-169)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-169-cnv-post-processing`

## Chosen approach

**Summary:** the ETL loads the proband's records of the slivar VCF of each `radiant_germline_cnv_annotation` task as a CNV occurrence set of its own, under that task's id, in `germline__cnv__occurrence`. The DRAGEN occurrences of the alignment task stay. Unlike germline SNVs, only the proband gets a slivar set: the parents and the siblings keep their DRAGEN set only. The proband always keeps both sets, whether the two tasks are loaded in the same import or in different ones: the DRAGEN list (alignment task) and the slivar list (annotation task), with the parent calls, the parental origin and the transmission mode. The proband's CNV task selector lists both tasks and opens the newest. This choice may be revisited later.

### bioinfo

- **Original call ID:** cnv-post-processing writes each sample's DRAGEN record ID in a new FORMAT field `OID`, set before the per-sample collapse and carried to the slivar VCF. At the pinned revision, no field keeps it: FORMAT holds DRAGEN's fields only, and the merged and collapsed record has one ID for all samples. The bioinfo team owns the change; the ETL then bumps `CNV_PIPELINE_REV` and `ANNOTATION_PIPELINE` together.

### etl

- **Source:** cnv-post-processing at the pinned revision (`cad99b4`) writes `slivar/<family>.cnv.slivar.vcf.gz`: one family VCF with every member's FORMAT fields, after a per-sample and a family [truvari collapse](https://github.com/ACEnglish/truvari/wiki/collapse) and a depth refinement of missing genotypes. slivar adds 14 mode tags (one per family, valued with the family's affected members) and 8 `po_*` tags (one per child) ([output doc](https://github.com/Ferlab-Ste-Justine/cnv-post-processing/blob/cad99b4e0b7e39f5d88dfbd028d426df693dee4e/docs/output.md), [rules](https://github.com/Ferlab-Ste-Justine/cnv-post-processing/blob/cad99b4e0b7e39f5d88dfbd028d426df693dee4e/assets/cnv-slivar-functions.js)). The CNV post-processing DAG already registers it (`gcnv`, `vcf`).
- **Staging:** the staging view admits the slivar VCF of a `radiant_germline_cnv_annotation` task in `cnv_vcf_filepath`, one row per member. Today it admits no output of this task. The SJRA-1928 design note already lists this change.
- **Task model:** a CNV annotation task model, with the experiment, family role and affected status of every member, read with the germline SNV pedigree (father, mother, progenies). The CNV import and its gate in `import_part` accept it next to the alignment task.
- **Occurrences:** one row per record that the proband carries, under the proband's sequencing. A record with `0/0` or `./.` for the proband gives no row. The parents' and the siblings' records give no row: their CNVs stay the DRAGEN set of their alignment task. The positions, type and FORMAT fields are the slivar record's, so they can differ from the proband's DRAGEN calls.
- **Parent fields:** on the proband's rows when the task has at least one parent: the mother's and the father's FORMAT values of the same record, typed like the proband's own columns. The slivar VCF keeps DRAGEN's FORMAT fields (`GT`, `CN`, `BC`, `PE`, `SM`), plus `OID` after the bioinfo change: at the pinned revision, the merge, collapse and refinement steps add no FORMAT field, and VEP and slivar write INFO tags only. To confirm on the header of one QA slivar VCF before task 2.
  - `mother_calls`, `father_calls` (`ARRAY<INT>`, from `GT`, as the SNV `*_calls`)
  - `mother_cn`, `father_cn` (`INT`, copy number)
  - `mother_bc`, `father_bc` (`INT`, number of bins)
  - `mother_pe`, `father_pe` (`ARRAY<INT>`, improperly paired reads at the two breakpoints)
  - `mother_sm`, `father_sm` (`FLOAT`, segment mean)
  - `mother_name`, `father_name` (`STRING`, from the new `OID`): the parent's DRAGEN call ID, equal to `name` on the parent's alignment-task row. When the per-sample collapse merged several calls of a parent, it is the ID of the call that was kept. A slivar VCF made before the bioinfo change has no `OID`: both columns stay `NULL`.
  - The depth refinement sets a missing `GT` to `0/0` and leaves `CN` empty, so a parent's calls can show `0/0` with no copy number.
- **Parental origin:** on the proband's rows, the proband's `po_*` value → the SNV values, one to one, with the mapping the germline SNV import already uses (`DENOVO`, `MOTHER`, `FATHER`, `BOTH`, `AMBIGUOUS`, `POSSIBLE_DENOVO`, `POSSIBLE_MOTHER`, `POSSIBLE_FATHER`). The CNV pipeline uses the SNV tag names.
- **Transmission mode:** on the proband's rows, the CNV mode tag that lists the proband, stored under its own name in `transmission_mode`. The CNV rules look at the child and its parents only, not at dominance or at who is affected, so no tag maps to an SNV value. The 14 tags give 13 new values: `denovo`, `denovo_suspect`, `possible_denovo`, `inherited_maternal`, `inherited_paternal`, `possible_inherited_maternal`, `possible_inherited_paternal`, `recessive`, `recessive_lowconf`, `inheritance_unresolved`, `mendelian_inconsistent`, `unknown_cn`, `x_linked_denovo`. `x_linked_recessive` already exists and keeps its label.
- **Empty values:** the alignment-task rows, a task with no parent in the VCF, and a record with no tag keep the new columns `NULL`.
- **Schema:** the new columns go at the end of `germline__cnv__occurrence` and of the Iceberg germline CNV occurrence table. The occurrence insert is positional and the copy step is `SELECT *`, so both keep their order. The re-annotation statement lists its columns: it carries the new ones.
- **Two sets per sequencing:**
  - The copy step keeps the rows of the tasks not in the run, keyed on `task_id` as for germline SNVs. Today it keys on `seq_id`, and the run's `seq_id`s are those of every member of its tasks: a run with only the annotation task would drop the DRAGEN rows of every member.
  - The cytoband, gene, SNV-count and gnomAD steps of the insert and of the re-annotation join on `(seq_id, name)`. They also join on `task_id`, because both sets of one sequencing can hold the same call name.
- **Cohort frequencies:** the slivar intervals become intervals of the RAD-120 frequency table. A patient counts once per interval (`COUNT(DISTINCT patient_id)`), so carrying a CNV in both sets does not count twice.
- **Data QA:** the 13 new values in the transmission mode dictionary; a new parental origin dictionary (none exists today); a test that every annotation-task row belongs to the case's proband.

### portal (backend)

- **Task list:** the CNV occurrence type selects the `alignment_germline_variant_calling` task of the case and sequencing, plus the `radiant_germline_cnv_annotation` task when the sequencing is the case's proband's. The annotation task is attached to every member's sequencing, and the task list reads the task attachments, not the occurrences: without this rule, a parent's selector would list a task with no rows. The task selector takes one task type today. The list stays ordered newest first.
- **Fields:** on the germline CNV occurrence table: `transmission_mode` and `parental_origin` (selectable, filterable, aggregatable), and each `mother_*` and `father_*` column (selectable and sortable like the member's own; `mother_name` and `father_name` selectable). `transmission_mode` uses the existing facet dictionary; `parental_origin` has none, as for SNVs. No join.
- **Dictionaries:** the 13 new mode values join the transmission mode facet dictionary and the hard-coded mode list of the variant page's case filters. The SNV facet then lists them too, with a count of 0.
- **Contract:** new optional, nullable fields on the germline CNV list, count, aggregation and statistics; `tasks_with_occurrences` returns one more task type for `germline_cnv`. Additive. Swagger, TS and Python clients regenerated.

### portal (frontend)

- **Task selector:** no change. It lists the tasks the backend returns and opens the first one, the newest: the proband's slivar set when it exists. The parents and the siblings see their DRAGEN set only.
- **Columns:** transmission mode (the `TransmissionModeBadge` of the variant page and the SNV slider), parental origin, mother and father calls, copy numbers and DRAGEN call IDs in the CNV table. Each one can be hidden or shown in the column settings. Default visibility deferred to grooming.
- **Query builder:** transmission mode (with dictionary) and parental origin facets in a parental analysis group of the germline CNV config, as in the SNV config, in the radiant, include and qlin portal configs.
- **Labels:** the transmission mode, parental origin and CNV FORMAT column labels (`cn`, `bc`, `sm`, `pe`) already exist and are reused. Only the keys that do not exist yet are added, in EN/FR: the mother and father column labels, `common.facets.values.parental_origin` (today the SNV slider shows the raw value in title case), and a label and an abbreviation for each of the 13 new mode values (the existing ones cover the SNV values only). The uncertain ones (`denovo_suspect`, `possible_*`, `recessive_lowconf`) say so in their label and abbreviation; the clinical team validates them.

### mcp

- **Clinical agent prompt:** a case can now have two `germline_cnv` keys for one sequencing. The prompt says to take the annotation task's key when there is one, and to read `transmission_mode` and `parental_origin` there instead of comparing the proband's CNVs with the parents' by hand. To show a parent's own DRAGEN call, it reads the parent's alignment-task key where `name` equals `mother_name` or `father_name`. No code change.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| bioinfo | cnv-post-processing: per-sample `OID` FORMAT field | modified |
| etl | pipeline pin (`CNV_PIPELINE_REV`, `ANNOTATION_PIPELINE`), staging sequencing experiment view, CNV annotation task model, CNV import (slivar records, parent fields, `po_*` and mode tags) and its gate, Iceberg and StarRocks germline CNV occurrence schema, occurrence insert, copy and re-annotation statements, StarRocks migration, data QA dictionaries and tests, CNV post-processing DAG doc and SJRA-1928 note | modified / new |
| portal (backend) | CNV task selection, germline CNV occurrence fields, facet dictionary, variant case filters list, swagger, generated TS and Python clients, test DDL and fixtures, seed schema | modified |
| portal (frontend) | germline CNV table settings and cells, germline CNV query builder config (three portals), EN/FR translations | new / modified |
| mcp | clinical agent prompt (CNV key and inheritance columns) | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Keep each sample's DRAGEN call ID | bioinfo | `OID` FORMAT field set before the per-sample collapse, pipeline tests, release; owned by the bioinfo team | — | yes |
| 2 | Load the slivar VCF as CNV occurrences | etl | Pipeline pin bump, staging view branch, task model and import gate, slivar extraction (proband's carrier records, parent fields and call IDs, `po_*` and mode tags), schema (Iceberg, DDL, migration), copy keyed on `task_id`, insert and re-annotation joins on `task_id`, data QA, unit tests on slivar VCF fixtures, integration tests | Task 1 release, for the pin bump only | yes: the portal lists no annotation task for CNVs until task 3 |
| 3 | Expose the slivar CNV set | portal (backend) | Task selection with both task types, fields, dictionaries, test DDL and fixtures, swagger and clients (2nd commit), integration tests | Task 2 migration run in each environment | yes once the migration has run |
| 4 | Show the CNV inheritance | portal (frontend) | Columns, cells, facets, column settings, missing EN/FR keys (mother and father columns, parental origin values, the 13 new mode values) | Task 3 | yes once task 3 is deployed |
| 5 | Agent prompt | mcp | CNV key rule, inheritance columns, link to the parent's DRAGEN call | Task 3 deployed | yes once task 3 is deployed |

No UX task: the task selector, the columns and the facets reuse existing components. No separate Labels task: most labels exist, the few missing keys go with task 4.

## Merge and rollout order

1. bioinfo: task 1 released. Before it, the slivar VCFs have no `OID`, and the parent call IDs stay `NULL`.
2. etl: task 2. In each environment, before the new DAGs run and with no import running:
   - add the columns to `germline__cnv__occurrence` in every `{tenant}_tenant` database (`ALTER TABLE … ADD COLUMN`). Otherwise the positional insert fails and every CNV import breaks;
   - run only the germline CNV occurrence init task, which recreates the Iceberg table with the new schema. Each import overwrites this table, so nothing is lost;
   - drop the two staging views and run `radiant-init-starrocks-base-tables` (the views are created with `IF NOT EXISTS`, as in RAD-116). Otherwise the slivar VCFs stay invisible.
3. etl: the next `radiant-import` loads every slivar VCF already registered: their staging rows are new, so the delta view selects them. No manual backfill. The VCFs made before step 1 load with no parent call IDs; a new post-processing run fills them.
4. portal backend: task 3, after step 2 in each environment. Before the migration, a query on a new column fails.
5. portal frontend: task 4. mcp: task 5.

No feature flag. Until task 3, the portal lists only the alignment tasks, so the slivar sets stay hidden.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1 (parent calls):** unit tests on slivar VCF fixtures (trio, duo, singleton, two siblings): the proband's rows carry each FORMAT field of the mother and the father from the same record, and their `OID` as `mother_name` and `father_name`; a fixture with no `OID` gives `NULL`.<br>• **AC3, AC4 (origin and mode values):** one fixture per `po_*` tag and per mode tag; a `possible_*` or `*_suspect` tag never gives a confirmed value.<br>• **AC6 (DRAGEN list kept):** integration test: a part run with only the annotation task keeps the alignment-task rows of every member unchanged, and a run with both tasks gives each set its own cytobands, genes and gnomAD values.<br>• **Proband only:** a trio's slivar VCF gives rows to the proband only, for the records it carries; no row for a `0/0` or `./.` record, none for the parents or a sibling.<br>• **AC7 (empty values):** the alignment-task rows and a singleton's rows have no parent, origin or mode value. |
| portal (backend) | • **AC2 to AC5:** integration tests (testcontainers): `tasks_with_occurrences` returns both CNV tasks, newest first, for the proband, and only the alignment task for a parent or a sibling; new fields in the list; filter on transmission mode and parental origin in list and count; aggregation; nulls on alignment-task rows. |
| portal (frontend) | • **AC4, AC7:** Vitest on the new cells: badge per mode, parental origin label, `-` when empty. |
| QA (manual) | • Two trios: one with both CNV tasks loaded in the same import, one with the annotation task loaded in a later import. Each proband shows both CNV tasks, the slivar set by default, and each parent shows its DRAGEN set only; a few de novo and inherited CNVs read by hand in the slivar VCF match the table, and their parent call IDs match a call of the parent's DRAGEN set; EN/FR labels and column settings (AC8).<br>• The MCP agent answers a de novo question on that case from the slivar key. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: CNV mode tags must keep their meaning (`denovo_suspect`, `possible_denovo` never shown as a confirmed de novo) | Each CNV tag is stored under its own name: no tag is folded into an SNV value or into a confirmed one. The labels of the uncertain values say so, and the clinical team validates them (task 4). One test per tag pins its value. Parental origin keeps the separate `POSSIBLE_*` values. |
| Genomic formats or data: the slivar records are merged and collapsed, so their positions differ from the DRAGEN calls | The slivar set is a separate task: its positions are shown as the pipeline wrote them, and the DRAGEN set stays unchanged next to it. No record is matched or guessed across files: the link to a parent's DRAGEN call comes from the pipeline's `OID`. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • The VEP CSQ annotation of the slivar VCF.<br>• A CNV detail panel and the CNV interpretation form.<br>• Somatic CNVs.<br>• The Exomiser CNV results (separate story).<br>• Keeping both sets is a first choice: no merge of the two lists, no rule to hide the DRAGEN set. |
| bioinfo | • No pipeline change other than `OID`. |
| etl | • No change to the CNV post-processing DAG or to the files it registers. |
| portal (backend) | • One transmission mode dictionary for SNVs and CNVs: no CNV-specific dictionary. The SNV facet lists the CNV values with a count of 0, and the CNV facet lists the SNV values the same way. |
| portal (frontend) | • Notes and flags stay per task: a note on a DRAGEN CNV does not show on the slivar set.<br>• The SNV slider keeps its raw parental origin display. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **Several affected children:** a mode tag lists the family's affected members, not the child the call is about. With an affected sibling, the proband can be listed under a tag that the sibling's calls gave. Proposal: keep only the tags that agree with the proband's own `po_*` value (both come from the same rule row); if several remain, pick by a fixed precedence. |
| story / product | • **Default visibility** of the new columns (deferred to grooming).<br>• **Story wording:** "the list of proband CNVs and their positions do not change" holds for the DRAGEN set. The slivar set is a second list, with the pipeline's positions. Proposal: reword the AC. |

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
