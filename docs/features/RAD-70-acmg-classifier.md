# RAD-70: In-house germline ACMG/AMP classification of SNVs

## Story

- **Link:** [RAD-70](https://ferlab-crsj.atlassian.net/browse/RAD-70) (epic). Stories: [RAD-71](https://ferlab-crsj.atlassian.net/browse/RAD-71) (task 2), [RAD-72](https://ferlab-crsj.atlassian.net/browse/RAD-72) (task 5).
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-70-acmg-classifier`

## Chosen approach

**Summary:** the ETL computes an automatic ACMG/AMP classification of each germline SNV from the annotations already in StarRocks. It stores the triggered criteria, the points and the class. The portal shows them next to the Exomiser classification. Several choices are still open (see **Options considered**).

### etl

- **Framework:** [ACMG/AMP 2015](https://doi.org/10.1038/gim.2015.30) (PMID 25741868) criteria, refined by the [ClinGen SVI](https://clinicalgenome.org/working-groups/sequence-variant-interpretation/) recommendations. The criteria are combined with the Bayesian points system ([Tavtigian 2018](https://doi.org/10.1038/gim.2017.210), PMID 29300386; [Tavtigian 2020](https://doi.org/10.1002/humu.24088), PMID 32720330). A point sum is a plain SQL expression and handles the strength modifiers (`_Supporting`, `_Moderate`, `_Strong`).
- **Criteria:**
  - **Frequency, BA1, BS1, PM2_Supporting:** gnomAD grpmax filtering allele frequency (new, see below), which leaves out the founder populations. BA1 follows [Ghosh 2018](https://doi.org/10.1002/humu.23642) (PMID 30311383): frequency above 5 % in a population of at least 2,000 observed alleles, and the variant is not on the ClinGen BA1 exception list.
  - **Computational evidence, PP3 and BP4 at calibrated strengths:** REVEL ([Pejaver 2022](https://doi.org/10.1016/j.ajhg.2022.10.013), PMID 36413997) and SpliceAI ([Walker 2023](https://doi.org/10.1016/j.ajhg.2023.06.002), PMID 37352859). Both are already stored per transcript in `snv__consequence`.
  - **Null variants, PVS1:** the LoF consequence, the NMD prediction (the variant escapes NMD when its premature stop falls in the last exon or within the last 50 nt of the penultimate exon; computed from the CDS position, the frameshift length in `aa_change`, and the exon structure in `ensembl_exon_by_gene`), the disease mechanism (see open questions) and gnomAD constraint (`gnomad_loeuf`, `gnomad_pli`), following the [Abou Tayoun 2018](https://doi.org/10.1002/humu.23626) tree (PMID 30192042).
  - **NMD escape flags:** two more escape routes of [NMDetective](https://doi.org/10.1038/s41588-019-0517-5) (Lindeboom 2019) are stored in the PVS1 evidence as `nmd_escape_reason`, without changing the points: `start_proximal` (premature stop in the first ~150 coding nt) and `long_exon` (premature stop in an exon longer than ~400 nt). Only `last_exon` and `penultimate_50nt` mean no NMD. The exact cut-offs go in the design doc.
  - **Other variant-level criteria:** PM4 (in-frame indel or stop-loss; no repeat-region check, see **Frozen scope**), BP7 (synonymous with low SpliceAI).
  - **Hotspot, PM1:** a minimum count of ClinVar P/LP missense variants near the variant, with no B/LB variant in the same window. It reads `clinvar` by position. PM1 plus PP3 never exceed 4 points ([Pejaver 2022](https://doi.org/10.1016/j.ajhg.2022.10.013)).
  - **Missense mechanism, PP2 and BP1:** per gene, the share of missense and of LoF among the ClinVar P/LP variants (ClinVar molecular consequence `mc`), and the share of benign missense. A small gene-level table, rebuilt when ClinVar changes.
  - **Healthy homozygotes, BS2:** the gnomAD homozygote count (`gnomad_genomes_v3.hom`, loaded but not copied to the variant tables), read against the OMIM inheritance of the gene.
  - **Same codon, PS1 and PM5:** a join on the protein change, (transcript, protein position, reference amino acid), between the patient's consequence and the ClinVar P/LP missense variants. Same alternate amino acid gives PS1, a different one gives PM5. The patient side already exists: `snv__consequence.aa_change` holds the VEP HGVSp (`p.Arg100Trp`) per transcript. The ClinVar variant with the patient's own `locus_id` is left out of the join: PS1 needs a different nucleotide change (ACMG 2015), and without this the variant matches itself, which brings back PP5 as a Strong criterion. PS1 and PM5 are mutually exclusive.
  - **Strength by ClinVar stars:** the strength of the ClinVar-based criteria (PS1, PM5) follows the review status of the ClinVar variant (`clinvar.clnrevstat`, mapped to stars). For example, PS1 is Strong from 2 stars and Moderate at 1 star; the exact map goes in the design doc.
  - Window sizes, counts and ratios are set in the rule design doc (task 1).
- **Cohort criteria (per tenant):** Radiant sees every case of a tenant, so some criteria count across cases. They are computed per tenant only, never across tenants. The counts go through the frequency pipeline, with the same mechanism as RAD-22 `hom` (per part, summed per tenant, copied to `snv__variant`). The family columns needed already exist (`family_id`, `family_role`, `affected_status` on the sequencing experiments).
  - **De novo, PS2 and PM6 summed across probands:** the distinct affected probands whose `transmission_mode` is a de novo mode from slivar (`autosomal_dominant_de_novo`, `x_linked_dominant_de_novo`, `x_linked_recessive_de_novo`, with `transmission_mode_source = 'slivar'`, RAD-93), scored with the [ClinGen SVI de novo](https://clinicalgenome.org/working-groups/sequence-variant-interpretation/) points table. The slivar mode already checks the genotype quality of the whole trio (GQ, depth, allele balance), needs both parents in the family and both parents not affected, which is the "no family history" condition of PS2. `parental_origin = DENOVO` alone is a plain genotype lookup with no quality check (a homozygous proband with two 0/0 parents is `DENOVO`), so it does not count; neither does `POSSIBLE_DENOVO`. A proband whose maternity and paternity are confirmed (see **Parentage check**) counts as confirmed de novo (PS2 points); any other proband counts as assumed de novo (PM6 points). A proband whose parentage is contradicted does not count. SVI row by default: phenotype consistent with the gene but not highly specific (the classifier does not read the phenotype outside PP4).
  - **De novo genotype with an affected parent:** a proband with a good-quality de novo genotype (`parental_origin = DENOVO`) but no slivar de novo mode because a parent is affected gets no points and a `de_novo_genotype_affected_parent` flag in the evidence, so that a wrong or unrelated affected status can be reviewed.
  - **Unrelated probands, PS4:** the number of unrelated affected probands (one per family) carrying a variant that meets PM2. Parents are never used as controls: they are selected through their child, so they carry the child's variants more often.
  - **Segregation, PP1 and BS4:** scored with the ClinGen points of [Biesecker 2024](https://doi.org/10.1016/j.ajhg.2023.11.009) (PMID 38103548): points per affected carrier relative, by inheritance, and BS4 for an affected relative who does not carry the variant. A not-affected carrier never gives BS4, since penetrance is unknown. PP1 shares the +5 points cap of the same paper with a later PP4.
  - **Local frequency:** the not-affected frequency and homozygote count of the tenant (`germline_pf_*_not_affected`, `germline_hom_*_not_affected`). Above a minimum cohort size, a carrier frequency over the threshold cancels PM2, and not-affected homozygotes give BS2 in recessive genes. The local frequency never gives BA1 or BS1: the not-affected individuals are mostly parents, so recessive disease variants are over-represented among them.
  - A class can change after the import of an unrelated case. The evidence shows the counts, so the change can be explained.
- **Parentage check (Somalier):** the QC pipeline already runs [Somalier](https://github.com/brentp/somalier) and publishes, per family, a `pairs.tsv` (relatedness, IBS0, IBS2 per sample pair) and a `samples.tsv` (sex check, depth). The QC DAG registers only the MultiQC report and archive today.
  - The QC DAG also collects `pairs.tsv` and `samples.tsv`, and fails the case when they are missing, as for the MultiQC files.
  - A new per-tenant table holds one row per parent–child pair of a case: the two sequencing experiments, relatedness, IBS0 and a `parentage_confirmed` flag. The samples are mapped back through the aliquot, which the QC samplesheet already uses as sample name.
  - Confirmed means a relatedness near 0.5 and an IBS0 near 0 (a parent and child always share an allele). The cut-offs are set on known QA trios and go in the design doc.
  - With `cohort_mode = true`, one file covers every family; the loader keeps the pairs of the case's samples.
  - The QC run can finish after the variants are imported. A new or changed parentage result triggers the reclassification of the case's de novo variants.
- **CDS position:** a new column `cds_position` in `snv__consequence`, filled from the VEP `CDS_position` field that the SNV pipeline already outputs. The VCF extraction, the Iceberg consequence table and the StarRocks DDL carry it. Backfill of the existing rows: not decided yet (see open questions).
- **gnomAD grpmax:** new columns in `gnomad_genomes_v3` for the grpmax allele frequency, the filtering allele frequency (FAF 95 %) and the allele number of the grpmax population, loaded by the gnomAD import. The source must carry them (see open questions).
- **BA1 exception list:** the variants ClinGen keeps out of BA1 although they are common (9 in Ghosh 2018, for example HFE p.Cys282Tyr and GJB2 p.Val37Ile). A small shared table loaded from a TSV with their GRCh38 coordinates (taken from ClinVar), joined on `locus_id`. It is checked against the ClinGen web page at each ruleset version.
- **ClinVar annotated by our VEP:** ClinVar has no protein change, so its variants go through the same VEP version and cache as the patients' VCFs. This gives the same transcript IDs on both sides of the join.
  - The output lands in a new shared table `clinvar_consequence` (locus, transcript, consequences, `aa_change`), parsed by the existing consequence extraction.
  - It runs again for each new ClinVar snapshot, before the classification.
  - Who runs VEP: not decided yet (see **Options considered**).
- **Phenotype, PP4 (per case):** follows the ClinGen definition of [Biesecker 2024](https://doi.org/10.1016/j.ajhg.2023.11.009): PP4 measures the diagnostic yield of the patient's phenotype for the gene, not a plain similarity. Two steps:
  - **Gate, phenotype match:** an ontology similarity between the patient's HPO terms and the HPO annotations of the gene's diseases (information content of the most specific shared ancestor, best-match average). Excluded terms (`interpretation_code = 'negative'`) lower the match. The patient's terms come from the clinical observations, already read by the ETL for the phenopackets.
  - **Points, diagnostic yield:** a curated table (disease, gene, diagnostic yield), maintained by the clinical team as a TSV and loaded by an import DAG. The yield gives the points through the conversion table of the paper. No PP4 under about 20 % yield, and PP1 + PP4 capped at +5 points.
  - **New sources:** the HPO ontology with its parent links (`hpo_term` holds only id and name) and the HPO disease annotations (`phenotype.hpoa`, `genes_to_disease`).
  - **Case class:** PP4 depends on the patient, so the final class is per occurrence: the tenant class plus PP4. It is stored on `germline__snv__occurrence`, like the `exomiser_*` columns, and recomputed when the case's phenotype or the variant class changes.
  - **Tenant class without PP4:** the tenant point sum and class (every criterion but PP4, PP1 not capped by the PP1 + PP4 rule) stay in their own columns, with the points of each criterion. A consumer that must not count the phenotype twice, such as phenovar, reads these columns, never the case class minus the PP4 points (the cap makes that subtraction wrong).
  - Where the similarity runs: not decided yet (see **Options considered**).
- **Gene-specific rules (ClinGen VCEP):** for genes with an expert panel, the [CSpec registry](https://cspec.clinicalgenome.org/) specifications override the generic rules: frequency thresholds, criteria that do not apply, adjusted strengths. They live in a gene-rule table, loaded from CSpec and reviewed by the clinical team. The generic rules apply to every other gene.
- **Audit trail:** each criterion is stored with its value, its source, the threshold that fired and its points, under a ruleset version. The open-data snapshots used (`open_data_release`) are recorded with the run. A class can be explained and reproduced at any date.
- **Class history and reclassification:** a per-tenant history table keeps every change of class (old class, new class, ruleset version, date). A variant whose class changed after the date of a clinician's interpretation (`interpretation_germline.updated_at`) is flagged on its occurrences.
- **Clinician feedback loop:** a per-tenant view compares the automatic class and criteria with `interpretation_germline` (classification and `classification_criterias`). It measures concordance per class and per criterion, on the tenant's own variants. The clinical team reads it through SQL or the MCP; it also feeds the threshold reviews of the design doc.
- **Independent of Exomiser:** no Exomiser output (class, evidence, scores) is an input. Exomiser stays a separate, parallel classification.
- **Criteria left out:** see **Frozen scope**.
- **Values:** the class uses the five snake_case values that the portal classification badge already displays (`pathogenic` … `benign`). The criteria are written as code plus strength (`PM2_Supporting`, `PP3_Strong`). Only the display format is shared with Exomiser, not its results.
- **Location, granularity, storage, recompute trigger, VEP runner:** not decided yet (see **Options considered**).
- **Rule reference:** the rule-by-rule table (thresholds, consequence lists, PVS1 branches) goes in a module design doc (`etl/design/`), reviewed with the code.
- **Readers:** the portal backend (new fields) and the MCP (arbitrary SQL, no change).

### portal (backend)

- **Fields:** `acmg_classification`, `acmg_evidence` and `acmg_points` (the case class, PP4 included) on the germline SNV occurrence `list`, `count`, `aggregation`, `statistics` and `expanded` responses. They use the same mechanism as the existing `exomiser_acmg_*` fields. The classification and the evidence can be aggregated; the points support min/max statistics.
- **Disagreement and reclassification:** two flags on the germline SNV occurrences, filterable and aggregatable: `acmg_disagrees_with_interpretation` (automatic class differs from the clinician's) and `acmg_changed_since_interpretation` (the class changed after the interpretation). The interpretation is already joined in the list query.
- **Audit detail:** the `expanded` occurrence returns the detail of each criterion (value, source, threshold, points) and the ruleset version.
- **Contract:** additive. The OpenAPI descriptions say the class is computed automatically and is not a clinical interpretation. The TS and Python clients are regenerated.

### portal (frontend)

- **Display:** an "ACMG" column next to "ACMG Exo." in the germline SNV table, using the existing classification cell. Two facets in the Pathogenicity group, next to the Exomiser facets. One row in the side panel classification block.
- **Disagreement and reclassification:** two facets and a badge in the ACMG cell ("differs from interpretation", "changed since interpretation").
- **Criterion detail:** the side panel lists each criterion with its value and threshold.
- **Interpretation form pre-fill:** when no interpretation exists, the form opens with the automatic class and criteria pre-selected, marked as suggestions. The clinician confirms or changes them; nothing is saved without a click.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | QC DAG output collection (Somalier files) and parentage table (new), CSpec gene-rule table and import (new), class history table and concordance view (new), HPO ontology and disease annotation import (new), diagnostic-yield table and its import DAG (new), PP4 step and case-class columns on `germline__snv__occurrence`, germline frequency queries (cohort counts), `snv__variant` and frequency DDL, VCF consequence extraction and `snv__consequence` DDL (`cds_position`), gnomAD import and `gnomad_genomes_v3` DDL (grpmax), ClinVar VEP annotation job and `clinvar_consequence` table (new), ACMG SQL step (new), its DDL and migration, `import_part` and `reannotate_open_data` wiring, data QA dictionaries and tests, StarRocks integration tests, design doc of the rules | new / modified |
| portal (backend) | germline SNV occurrence fields and types (class, criteria detail, disagreement and reclassification flags), expanded query, OpenAPI spec, generated TS and Python clients, test DDL copies and fixtures | modified |
| portal (frontend) | germline SNV table settings, Pathogenicity facets, side panel prediction card, germline interpretation form (pre-fill), EN/FR translations | modified |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Rule design doc | etl | Criteria, thresholds, sources and point weights, one row per criterion; reviewed by a clinical geneticist before the SQL | — | yes (doc only) |
| 2 | CDS position in the consequences | etl | VEP `CDS_position` in the extraction, the Iceberg consequence schema and `snv__consequence`, migration, backfill of the existing rows, tests | — | yes, once the migration has run (no reader yet) |
| 3 | gnomAD grpmax and BA1 exceptions | etl | grpmax AF, FAF 95 % and grpmax allele number in the gnomAD import and `gnomad_genomes_v3`, migration; BA1 exception table, its TSV and load; tests | Source carries the fields | yes (no reader yet) |
| 4 | ClinVar VEP annotation | etl | Sites-only VCF of the ClinVar variants, VEP run with the pinned version and cache, `clinvar_consequence` DDL and load, run on each new ClinVar snapshot, DAG and integration tests | — | yes (no reader yet) |
| 5 | Parentage from Somalier | etl | Collect the Somalier `pairs.tsv` and `samples.tsv` in the QC DAG, parentage table DDL and load, mapping of the samples to the sequencing experiments, tests on per-family and cohort outputs | — | yes (no reader yet) |
| 6 | Cohort counts | etl | De novo (confirmed and assumed), unrelated-proband and segregation counts in the germline frequency queries, columns in the frequency tables and the variant tables, migration, integration tests | Task 5 | yes, once the migration has run (no reader yet) |
| 7 | HPO ontology and disease annotations | etl | Import of the HPO parent links and of the disease annotations, DDL, tests | Source available (see open questions) | yes (no reader yet) |
| 8 | Diagnostic-yield table | etl | TSV format, import DAG, DDL, first version of the table curated by the clinical team | — | yes (no reader yet) |
| 9 | ACMG classification in StarRocks | etl | DDL and migration, classification SQL, wiring into `import_part` and `reannotate_open_data`, data QA (class in dictionary, points consistent with class), integration tests on fixture variants | Tasks 1 to 6 | yes, once the migration has run (no reader yet) |
| 10 | PP4 and case class | etl | Phenotype similarity, PP4 points, case-class columns on `germline__snv__occurrence`, migration, wiring into `import_part`, tests | Tasks 7 to 9 | yes, once the migration has run (no reader yet) |
| 11 | Gene-specific rules | etl | Gene-rule table, CSpec import, first review by the clinical team, rules wired as overrides, tests | Task 9 | yes (overrides only) |
| 12 | Audit, history and feedback loop | etl | Criterion detail and ruleset version, open-data snapshot record, class history table, concordance view on `interpretation_germline`, tests | Tasks 9, 10 | yes, once the migration has run |
| 13 | Expose the classification on the germline SNV occurrences | portal (backend) | Fields, criterion detail, disagreement and reclassification flags, expanded query, OpenAPI descriptions, TS and Python clients, test DDL copies and fixtures, integration tests | Tasks 10, 12 | yes (additive), but see rollout |
| 14 | Labels | portal (frontend) | EN/FR labels and tooltips for "ACMG", the disclaimer ("automatic, not a clinical interpretation"), the two flags and the "suggested" marker of the form, validated by the clinical team | — | yes |
| 15 | UX of the pre-fill | portal (frontend) | Mock-up of a suggested criterion in the form and how the clinician confirms it, validated by the clinical team | — | yes (design only) |
| 16 | ACMG column, facets and side panel | portal (frontend) | Column next to "ACMG Exo.", facets (class, evidence, two flags), side panel with the criterion detail, unit tests | Tasks 13, 14 | yes once 12 is deployed |
| 17 | Interpretation form pre-fill | portal (frontend) | Pre-selected class and criteria with a "suggested" marker when no interpretation exists, unit tests | Tasks 13 to 15 | yes once 12 is deployed |

Task 15 is the UX task: how a suggested criterion looks and is confirmed in the form. The column, facets and badge reuse the Exomiser ones.

## Merge and rollout order

1. etl: merge tasks 2 and 3. Run their migrations **before** the DAGs are deployed (otherwise the consequence and gnomAD inserts fail). Then backfill `cds_position` and reload gnomAD. Without them, PVS1 misses the NMD rule and the frequency criteria have no grpmax, with no error.
2. etl: merge and run task 4 on the current ClinVar snapshot (QA, then prod). Without it, PS1 and PM5 never fire, with no error.
3. etl: merge tasks 5 and 6. Run their migrations before the DAGs are deployed. Load the Somalier results of the QC runs already done (their files are on S3); without them, every existing de novo stays assumed (PM6). Then run `reannotate_open_data` with `{"recompute_frequencies": true}` to fill the counts of the existing cases.
4. etl: merge tasks 7 and 8, run the HPO import and load the first diagnostic-yield table.
5. etl: merge tasks 9 to 12. Run their migrations on every database that holds the new columns or tables (QA, then prod) **before** the DAGs are deployed. Otherwise the inserts fail and every `import_part` breaks. Load the reviewed gene rules.
6. etl: run `reannotate_open_data` with `force_reannotation` (QA, then prod) to classify the existing variants and occurrences. This run writes the first history rows; the reclassification flags are meaningful only from the next change on. Until then, nothing has a class; new imports already get one.
7. portal backend: task 13 after step 5 in each environment. Otherwise every germline SNV occurrence query fails on an unknown column.
8. portal frontend: tasks 14 and 15, then 16 and 17, after the backend is deployed.

No feature flag. A later rule change, a new version of the diagnostic-yield table or of the gene rules, needs a forced re-annotation, as for COSMIC.

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • StarRocks integration tests on a fixture set with one variant per criterion and per strength, plus the edges of each threshold. BA1 fixtures: above 5 % with 2,000 alleles or more, above 5 % in a smaller population (no BA1), HFE p.Cys282Tyr (on the exception list, no BA1). PS1 and PM5 fixtures: same amino acid by another nucleotide change, another amino acid at the same position, same position on another transcript (no match), and one per star level.<br>• Cohort fixtures: two unrelated de novo probands, one with confirmed parentage (PS2 points) and one without a parentage result (PM6 points), one with contradicted parentage (no points), one `POSSIBLE_DENOVO`, one `DENOVO` without a slivar de novo mode (no points), one with an affected parent (no points, `de_novo_genotype_affected_parent` flag), two probands of the same family (count once), an affected carrier relative and an affected non-carrier relative, a not-affected homozygote, a cohort under the minimum size.<br>• PVS1 fixtures: stop in the last exon, in the penultimate exon within and beyond 50 nt of the junction, frameshift whose new stop falls in each zone, stop within the first 150 coding nt and stop in an exon over 400 nt (points unchanged, `nmd_escape_reason` set).<br>• PS1 fixture: the patient's own variant is ClinVar P (no PS1). PM1 fixture: missense with REVEL 0.95 in a hotspot (4 points, not 6).<br>• Tenant class without PP4: PP1 4 points plus PP4 2 points gives a capped case class and an uncapped tenant class.<br>• PP4 fixtures: a patient whose terms match a gene with a curated yield (points from the table), the same patient on a gene with no curated yield (no PP4), a poor match (no PP4), an excluded term, PP1 + PP4 over the cap.<br>• Gene rules: a gene with a VCEP override (threshold changed, criterion disabled, strength adjusted) against the same variant in a gene without one.<br>• History and audit: a ClinVar refresh that changes a class writes one history row; an unchanged class writes none; each criterion detail carries its value, threshold and ruleset version.<br>• Concordance: fixture interpretations that agree, disagree on the class, and disagree on one criterion.<br>• Parentage: Somalier outputs of a real QA trio, per family and in cohort mode, load one row per parent–child pair mapped to the right sequencing experiments; a swapped sample gives `parentage_confirmed = false`.<br>• ClinVar annotation: a small ClinVar VCF goes through the VEP run; its `aa_change` matches the one of the same variant in `snv__consequence`.<br>• A truth set of ClinVar variants with expert-panel review (3 or 4 stars): the share of P/LP and B/LB classes that match is measured and recorded in the PR. Pathogenic called benign (or the reverse) is investigated case by case.<br>• Data QA: class in the dictionary, class consistent with the point sum. |
| portal (backend) | • Integration tests with the new columns in the fixtures: list, filter, sort, aggregation and `expanded` return the class, the evidence, the points and the criterion detail.<br>• Both flags: an interpretation that agrees, one that disagrees, a class change before and after the interpretation date. |
| portal (frontend) | • Vitest on the column and the side panel (badge per class, evidence chips, flags, empty value).<br>• Vitest on the form: pre-filled when no interpretation exists, untouched when one exists, nothing saved without a click. |
| QA (manual) | • After the backfill: 20 variants already interpreted by the clinical team, automatic class against the manual one.<br>• The class distribution per tenant looks plausible (most variants VUS or benign). |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: an automatic class can be read as a clinical conclusion | The rules are reviewed by a clinical geneticist (task 1). The UI and the OpenAPI descriptions label the class as automatic. The ClinVar truth set measures the error rate before release, and the concordance view measures it on the tenant's own interpretations. |
| Clinical rules or interpretation: a pre-filled form can bias the clinician toward the automatic result | The pre-fill only applies when no interpretation exists, each criterion is marked as suggested, and nothing is saved without a click. The concordance view tracks whether clinicians simply accept the suggestions. |
| Clinical rules or interpretation: PP4 needs a complete clinical evaluation, which the pipeline cannot check | PP4 shows the matched terms and the yield in the evidence. The yield table is curated and signed by the clinical team. A patient with few HPO terms gets a weak match, so no PP4. |
| Data confidentiality: cohort criteria read other cases of the tenant | Counts only, per tenant, never patient identifiers. No count crosses tenants. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Germline SNV only. No somatic classification (it uses the [AMP/ASCO/CAP](https://doi.org/10.1016/j.jmoldx.2016.10.002) framework, PMID 27993330), no CNV ([Riggs 2020](https://doi.org/10.1038/s41436-019-0686-8) framework).<br>• No notifications (email, in-app) on reclassification: the flags and facets only.<br>• No portal page for the concordance: SQL or the MCP only.<br>• No MCP change.<br>• Criteria that need data not loaded today: BP3 and the repeat-region exception of PM4 (repeat regions), PS3 and BS3 (functional studies). PP5 and BP6 are left out, following ClinGen SVI.<br>• No input from Exomiser.<br>• No evidence across tenants.<br>• No PM3 and BP2 (phase, after RAD-39).<br>• No AI in the scoring. No HPO extraction from free-text notes.<br>• No input from [AI-MARRVEL](https://github.com/LiuzLab/AI_MARRVEL) ([Mao 2024](https://doi.org/10.1056/AIoa2300009)). It ranks the causal variants of a case from the VCF and the HPO terms, like Exomiser, and gives no ACMG criteria. Adding it as a second prioritization next to Exomiser is a separate story.<br>• No internal diagnostic yield in the points (see open questions). |
| etl | • PVS1: no alternative start codon rule and no critical-region rule.<br>• No strength by ClinVar stars for PM1, PP2 and BP1 (they count variants, with a minimum star level set in the design doc). |
| portal (frontend) | • No change to the variant entity page. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **gnomAD grpmax source:** the OpenDataLake `gnomad_joint` contract test data has no grpmax or FAF column. Check the contract itself; if the fields are missing, the contract owner must add them before task 3 (gnomAD v4 publishes them).<br>• **`cds_position` backfill:** the existing consequences come from VCFs already extracted. Option 1: parse it from `dna_change` (the `c.` notation holds the CDS position), no re-import. Option 2: re-extract every VCF. Proposal: option 1, checked against VEP on a sample.<br>• **PVS1 and the disease mechanism:** PVS1 applies only where LoF is a known disease mechanism. gnomAD constraint (`gnomad_loeuf`, `gnomad_pli`) measures heterozygous LoF intolerance, so it misses recessive genes. Proposal: the mechanism is established by P/LP LoF variants of the gene in ClinVar (data already loaded); a low LOEUF only supports dominant genes. ClinGen Dosage Sensitivity can replace the ClinVar count later. To be validated in task 1.<br>• **VEP on a sites-only VCF:** can the SNV post-processing pipeline start at its `annotation` step with `tools=vep` on a VCF with no samples (not verified)? To check with the bioinfo team.<br>• **HPO sources:** the OpenDataLake HPO contracts (`hpo_terms_v1`, `hpo_genes_v1`) carry no parent links and no disease annotations. Add contracts upstream, or load the HPO release files directly? Proposal: new OpenDataLake contracts, like the other open data.<br>• **Internal diagnostic yield:** the solved cases of the tenant (`interpretation_germline`, P/LP) could give a local yield per (disease, gene). Proposal: compute and show it to the clinical team to update the curated table, but do not score it in v1 (small numbers, and the denominator needs a phenotype definition).<br>• **CSpec format:** how much of the CSpec specifications is machine-readable (thresholds, applicability, strengths) and how much is free text (not verified)? Proposal: import the structured fields, curate the rest by hand in the gene-rule table.<br>• **Somalier of past QC runs:** the files of the QC runs already done should be on S3 under each run's outdir (not verified). Proposal: a one-off load of these files; rerun the QC only for the cases where they are missing.<br>• **Parentage cut-offs:** relatedness and IBS0 limits for a confirmed parent–child pair, on WGS and WXS. Proposal: measure them on the known QA trios before task 6.<br>• **De novo from the legacy ETL calculation:** a VCF without slivar tags gets its `transmission_mode` from the ETL (`transmission_mode_source = 'etl'`), with no quality check of the parents. Proposal: no PS2/PM6 from it; these cases need a re-run of the post-processing pipeline to count.<br>• **Repeat regions for PM4 and BP3:** an in-frame indel in a poly-Ala or poly-Gln tract gets PM4 today. Load RepeatMasker (`Simple_repeat`, `Low_complexity`, every overlapping element) as a shared table, so PM4 is skipped there and BP3 applies? Proposal: yes, as a later task; it moves PM4's repeat exception and BP3 out of **Frozen scope**.<br>• **Thresholds as data or as code:** SQL constants with a ruleset version column, or a config table that the clinical team can edit? Proposal: generic thresholds as constants plus version; gene-specific ones in the gene-rule table. |
| portal (frontend) | • **Pre-fill and strength:** the form's criteria list has no strength modifiers (`PM2`, not `PM2_Supporting`). Proposal: add the modifiers to the list, so the pre-fill keeps the strength; otherwise the strength is lost in the saved interpretation. |
| story / product | • **Exomiser phenotype score as the PP4 gate:** load the Exomiser gene phenotype score (in the Exomiser output, not loaded today; `gene_combined_score` also holds the variant score, so it would count PP3 and PM2 twice) and use it in place of our own HPO similarity. The diagnostic-yield table still gives the points. Pro: drops task 7 and the similarity step. Con: the classifier then depends on Exomiser having run on the case, and the score also counts animal-model matches. Proposal: keep our own similarity; the clinical owner decides.<br>• **Size of the epic:** 17 tasks; two have a story so far (RAD-71, RAD-72). Proposal: one story per task or group of tasks (core classifier; cohort and PP4; audit, history and feedback loop; gene rules), created when each gets ready.<br>• **PP4 without a curated yield:** no PP4 (strict ClinGen), or PP4_Supporting on a strong match (closer to Exomiser)? Proposal: no PP4; the clinical owner decides.<br>• **Reviewer:** not assigned yet, for the epic and its stories.<br>• **Clinical owner:** who signs the rules (task 1) and the truth-set results? |

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

## Options considered

| Axis | Option | Behaviour | Modules | Pro / con | Effort |
|---|---|---|---|---|---|
| Where the rules run | A1 | One SQL step in StarRocks after the variant and consequence loads | etl | + data already there, set-based, no new image; − PVS1 tree is verbose in SQL | M |
| | A2 | Python step in the radiant-operator image, reads StarRocks, writes back | etl | + PVS1 tree readable and unit-tested; − row export, a new task type, slower | L |
| | A3 | SQL for everything but PVS1, which is precomputed in Python during VCF extraction (it only needs the consequence) | etl | + each rule where it reads best; − two places to change a rule | L |
| Granularity | B1 | One class per (locus, transcript), keyed like `snv__consequence` (shared DB) | etl, portal | + matches the interpretation key (`locus_id`, `transcript_id`); − more rows | M |
| | B2 | One class per locus, on the picked transcript only | etl, portal | + simplest, one row per variant; − wrong when the picked transcript is not the disease one | S |
| Storage and read path | C1 | Variant-level criteria in a new shared table; cohort criteria and the final class per tenant, the picked class on `snv__variant` and `snv__variant_partitioned` (RAD-15 pattern) | etl, portal | + list filters read plain variant columns; the tenant split follows the data; − migration of the per-tenant tables | M |
| | C2 | Columns on `snv__consequence` only; the backend joins the picked row | etl, portal | + no new table; − list and facets need a new join on the consequence table | M |
| Where the phenotype similarity runs | G1 | SQL, with a precomputed ancestor table and an information-content table per HPO term | etl | + same engine as the rest; − the best-match average is verbose in SQL | M |
| | G2 | Python step in the radiant-operator image, per case, writes PP4 back to StarRocks | etl | + readable, unit-tested, standard ontology libraries; − a new task type in `import_part` | M |
| Who runs VEP on ClinVar | F1 | The ETL launches the pinned SNV post-processing pipeline (`step=annotation`, `tools=vep`) on a ClinVar VCF it exports, like the existing Nextflow launchers | etl | + same VEP version and cache by construction (one pin); − one more Nextflow run per ClinVar snapshot | M |
| | F2 | The OpenDataLake publishes a VEP-annotated ClinVar contract table | OpenDataLake, etl | + every consumer gets it; − another team, and its VEP version can drift from ours | M |
| | F3 | VEP in the radiant-operator image | etl | + no Nextflow; − a second VEP install and cache to keep in sync with the pipeline | L |
| Recompute trigger | E1 | New `acmg` branch in `reannotate_open_data`, opened when the `snv_variant` or `snv_consequence` gate opens | etl | + always fresh after an open-data refresh; − one more branch | S |
| | E2 | Only on import and on `force_reannotation` | etl | + nothing to add; − stale after a ClinVar or gnomAD refresh | S |

Preliminary lean: **A1** (PVS1 in its simplified form fits in a `CASE`), **B1** (same key as the interpretations), **C1** (same read path as RAD-15; the class is per tenant since the cohort criteria are), **E1**, **F1** (the version match is what makes the join exact), **G2** (the similarity is per case and reads best in Python).
