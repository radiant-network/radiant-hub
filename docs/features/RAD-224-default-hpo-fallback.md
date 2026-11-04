# RAD-224: Default HPO fallback for probands without observed sign

## Story

- **Link:** [RAD-224](https://ferlab-crsj.atlassian.net/browse/RAD-224)
- **Assigned reviewer:** Jeremy Costanza
- **Status:** Draft
- **Branch (all repos):** `feat/rad-224-default-hpo-fallback`

## Chosen approach

**Summary:** when hybrid (`clin-qlin-me-hybrid`, the QLIN backend that bridges prescriptions to Radiant) sends a case whose proband has no observed clinical sign, it adds one generic HPO phenotype, `HP:0000118` (Phenotypic abnormality, the root of the phenotype branch), as a positive observation of the proband. Radiant's ETL then has a term to run Exomiser on. The code is configurable and the whole fallback can be turned off. Radiant itself does not change.

Why the gap exists: the hybrid API requires at least one observed sign on the proband of every prescription it creates or updates. The prescriptions imported before that, by the legacy batch import of the CLIN pipelines, never had that rule: they carry the affected status of the patient and no HPO term. When one of them is synced to Radiant, its proband arrives with an empty phenotype list. Radiant's ETL runs Exomiser on every germline case and writes a phenopacket with no phenotypic feature, and the Exomiser run fails. The last somatic sync on QA hit it through the normal side of a tumor-normal pair: that germline case is synced first, and it was a legacy prescription.

### hybrid

- **Rule:** the proband gets the default phenotype when none of its signs is observed. A proband with no clinical block, an empty list, or only negative signs is in that case. The negative signs are kept and the default is appended. A proband with at least one observed sign is untouched. The other family members never get it: Exomiser ranks on the proband's terms only.
- **Shape:** the observation is a `phenotype` of coding system `HPO`, value `HP:0000118`, interpretation `positive`, onset `unknown`, the same shape as a real sign.
- **Prenatal cases:** the proband's signs travel on the fetus, so the default lands on the fetus observations and the mother keeps none.
- **Where:** in the mapper that turns a QLIN prescription into a Radiant case. It is the single point for the three paths that send a case (create, update, manual sync), so the normal side of a tumor-normal sync is covered too.
- **Configuration:** `RADIANT_DEFAULT_HPO_CODE`, default `HP:0000118`. An empty value turns the fallback off.
- **Logging:** each application logs a warning with the analysis id and the patient id. Writes to Radiant are fire-and-forget, so the logs are the only place that shows which cases received the default.
- **Later real signs:** once a prescriber adds signs in QLIN, the next sync sends the real list and no default. Radiant's `PUT /{tenant}/cases/batch` replaces the whole observation list of the case, so the default disappears from Radiant.

### etl

- **No change.** Exomiser runs only for germline cases; somatic cases skip it. The phenopacket leaves out the phenotypic features when the proband has none, and the run is launched anyway. A guard (skip Exomiser, or fail early with a clear reason) is an open question.

### portal (backend)

- **No change.** The case batches accept a proband without phenotype: each observation is checked for its fields, the list may be empty. The update batch rewrites the observations of the case from the body, which is what makes the later replacement work.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| hybrid (clin-qlin-me-hybrid) | Radiant case mapper, configuration, unit tests, README and agent docs | modified |
| etl | none | … |
| portal (backend) | none | … |

The frontend shows the phenotype like any other HPO term. The MCP reads the observation tables as they are.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Default HPO fallback in the Radiant mapper | hybrid (Jira component `api`) | Configuration knob, fallback rule for the proband and the fetus, warning log, unit tests, docs | … | yes |

No Labels task: `HP:0000118` is an existing HPO term with its own label. No UX task: nothing new is shown.

## Merge and rollout order

1. hybrid: merge and deploy task 1 on QA, then production. Nothing breaks if it waits: legacy cases keep failing Exomiser until it ships.
2. QA: re-sync one legacy germline prescription already in Radiant with the manual sync endpoint, check the warning in the hybrid logs, then check that the Exomiser task of the case succeeds.

No migration, no feature flag beyond the environment variable, no backfill. Cases already in Radiant get the default only when they are synced again.

## Test strategy

| Module | How the story is proven |
|---|---|
| hybrid | • **AC1 (default added, warning logged):** unit test of the mapper on a proband with no clinical block: one phenotype observation `HP:0000118`, positive, onset unknown, and one warning naming the analysis.<br>• **AC2 (observed sign present):** unit test on a proband with one observed and one negative sign: no default, no warning.<br>• **AC3 (negatives only):** unit test: the negative sign is kept, the default is appended.<br>• **AC4 (non-proband):** unit test on a mother without sign: nothing added to her, the proband gets it.<br>• **AC5 (prenatal):** unit test: the default is on the fetus, not on the mother.<br>• **AC6 (update batch):** unit test on the update body: the default is there too.<br>• **AC7 (turned off):** unit test with an empty code: no default. |
| QA (manual) | • One legacy germline prescription re-synced: the warning is in the hybrid logs, the case in Radiant shows `HP:0000118` on the proband, and its Exomiser task succeeds.<br>• **AC8 (replacement):** add a real sign to that prescription in QLIN, sync again: Radiant shows the real sign and no `HP:0000118`. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Clinical rules or interpretation: a synthetic phenotype reaches Exomiser | `HP:0000118` is the root of the phenotype branch, so it ranks no gene over another. It is positive on purpose: Exomiser scores on observed terms only, and the goal is a run, not a ranking. The warning log tells which cases carry it. The clinical team can check the term (open question). |
| Interoperability: hybrid to Radiant payload | The observation has the shape of a real sign, accepted today by the case batches. The replacement on a later sync relies on the update batch rewriting the whole list, verified in the portal worker. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No backfill of the cases already in Radiant: a manual re-sync per case.<br>• No change to the hybrid API validation or to the legacy batch import. |
| hybrid | • No default for family members.<br>• No onset other than unknown. |
| etl | • No guard when the proband has no phenotype (open question, separate ticket if agreed). |
| portal (backend) | • No validation requiring a phenotype on a germline proband. |

## Open questions

| Module | Questions |
|---|---|
| story / product | • Does the clinical team want another term than `HP:0000118`? Proposal: keep it, it is the root of the phenotype branch and ranks nothing. |
| etl | • Should the ETL skip Exomiser, or fail with a clear reason, when a germline proband has no observed phenotype? Proposal: yes, in a separate ticket, so a case from another source than hybrid does not fail the same way. |
| portal (backend) | • Does an update batch on a case already annotated trigger a new Exomiser run? Not verified. |

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
