# RAD-41 / RAD-42: transcript report, QLIN vs Radiant field mapping

Companion of [`RAD-41-transcript-report.md`](RAD-41-transcript-report.md). One row per column of the QLIN report (clin-arranger, state after CLIN-5734), with its source in Radiant. Status values: `available` (plain read), `live join` (computed at generation from an open-data table), `replaced identifier` (different id in Radiant), `ETL needed` (none today), `dropped` (QLIN no longer prints it).

**Conclusion:** no ETL change for v1. Every column is reachable at generation time from StarRocks and Postgres. Denormalising later is a performance option only.

## Identifiers (file name, sheet name, columns I and J)

| Item | QLIN source | Radiant source | Status | Note |
|---|---|---|---|---|
| File name `<patient>_<request>_<timestamp>.xlsx` | FHIR `patient_id`, `service_request_id` (list endpoint; only the single-variant endpoint adds `rsnumber`) | case `submitter_patient_id` (MRN), `case_id` | replaced identifier | MRN decided 2026-10-07. PII, masked views apply. Verified on a QLIN file 2026-10-07: header Arial 9 bold 63.75 high, data rows fixed 150, A and K left, rest centered, all wrapped, autofilter A1:K1 |
| Sheet name | ES `hgvsg` | `snv__variant.hgvsg` | available | Excel illegal characters replaced, same rule |
| Numéro requête CQGC | `service_request_id` | `case_id` | replaced identifier | |
| Numéro échantillon | `sample_id` | `submitter_sample_id` of the proband sequencing | replaced identifier | Via the case entity |
| Genome build in header | ES `donor.genome_build` | task `genome_build` | available | GRCh38 only in v1 |

## Germline sheet (11 columns)

| Column | QLIN source (ES `variant_centric`) | Radiant source | Status | Note |
|---|---|---|---|---|
| Variation nucléotidique: hgvsg, gene, NM list, HGVSc, AA change, exon | `hgvsg`, `consequences[].symbol`, `refseq_mrna_id`, `hgvsc`, `aa_change`, `exon.rank/total` | `snv__variant.hgvsg`; `snv__consequence` rows of the locus: `symbol`, `hgvsc`, `aa_change`, `exon_rank`, `exon_total`; NM from the RefSeq rows (`source = RefSeq`, `transcript_id` + `transcript_version`) paired by `mane_pair_transcript_id` | available | Row = MANE Select Ensembl transcript, plus the interpreted transcript when it is another one (no row when the locus has neither). `exon_rank` type to confirm (VARCHAR in prod DDL) |
| Zygosité (origine parentale) | `donors[].zygosity`, `parental_origin`, `father_zygosity`, `mother_zygosity`, `transmission` | `germline__snv__occurrence.zygosity`, `parental_origin`, `father_zygosity`, `mother_zygosity`, `transmission_mode` | available | Formatter ported with its 10 cases. Parent zygosity value domain not verified |
| Fréquence allélique¹ (gnomAD af, ac, an, hom) | `external_frequencies.gnomad_joint_4` | `gnomad_genomes_v3.af`, `ac`, `an`, `hom` by `locus_id` | live join | Table name misleading: loaded from the gnomAD v4 joint set, same source as QLIN. The occurrence API only exposes `gnomad_v3_af` today |
| Prédiction in silico² (REVEL, CADD) | `consequences[].predictions.revel_score`, `cadd_phred` | `snv__consequence.revel_score`, `cadd_phred` | available | |
| ClinVar (significance, id) | `clinvar.clin_sig`, `clinvar.clinvar_id` | `snv__variant.clinvar_interpretation`, `clinvar_name` | available | `clinvar_name` is the ClinVar variation id, already joined as such by the ClinVar RCV reader |
| OMIM et PMID³ | `genes[].omim[]` (name, id, inheritance), interpretation PubMed | `omim_gene_panel` by symbol (`omim_id`, `name`, `inheritance_code`); PubMed from the Postgres interpretation | available | Inheritance code separator (`", "` vs `","`) to confirm |
| Interprétation⁴ (classification) | radiant-api germline interpretation | Postgres germline interpretation (`classification`) for case, sequencing, locus, transcript | available | Shown on the interpreted transcript row only, as today |
| MANE (Select, Plus, canonical) | `consequences[].mane_select`, `mane_plus`, `canonical`, ids | `snv__consequence.mane_select`, `mane_plus`, `is_canonical`, `transcript_id`, `mane_pair_transcript_id` | available | |
| Numéro requête CQGC | see identifiers | | replaced identifier | |
| Numéro échantillon | see identifiers | | replaced identifier | |
| Citations | interpretation `pubmed[].citation` | Postgres interpretation `pubmed[]` | available | Postgres stores the ids only; the interpretation repository already fetches the citation text live from PubMed (cached). Fallback on failure is an open question in the spec |

## Somatic sheet (13 columns, RAD-42)

| Column | QLIN source | Radiant source | Status | Note |
|---|---|---|---|---|
| Variation nucléotidique | as germline | as germline | available | |
| Fréquence allélique du variant [VAF] (reads) | `donor.ad_ratio`, `ad_alt`, `ad_total` | `somatic__snv__occurrence.tumor_ad_ratio`, `tumor_ad_alt`, `tumor_ad_total` | available | Normal side available too (`normal_*`) if the template wants it |
| Origine du variant | `donor.all_analyses` contains `TN` | `somatic__snv__occurrence.normal_seq_id` not null = tumor-normal | available | QLIN prints "Somatique" for TN, "Non déterminée" otherwise |
| Fréquence allélique population¹ | `gnomad_joint_4` | `gnomad_genomes_v3` | live join | As germline |
| Nombre de cas rapportés (COSMIC)² | `cmc.sample_mutated`, `cosmic_id` | `cosmic_mutation_set.cosmic_id`, `sample_mutated`, `tier` by `locus_id` | live join | Table in the shared DB, absent from the backend test schema today. RAD-15 denormalises `cmc_*` counts but not `cosmic_id` |
| Impact fonctionnel (REVEL) | `predictions.revel_score` | `snv__consequence.revel_score` | available | |
| Niveau de signification clinique⁵ | somatic interpretation `clinical_utility` | Postgres somatic interpretation `clinical_utility` | available | |
| Oncogénicité | somatic interpretation `oncogenicity` | Postgres somatic interpretation `oncogenicity` | available | |
| Transcrit MANE Select (Oui/Non) | `mane_select` | `snv__consequence.mane_select` | available | |
| Numéro requête CQGC, Numéro échantillon | see identifiers | | replaced identifier | |
| Publication PubMed, Citations | interpretation `pubmed[]` | Postgres somatic interpretation | available | |

## Dropped by CLIN-5734 (not ported)

SIFT prediction, Exomiser ACMG class, gene biotype, consequence names. Their arranger formatters stay out of the Go port.
