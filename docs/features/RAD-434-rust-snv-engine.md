# RAD-434: Opt-in Rust engine for the SNV extraction

## Story

- **Link:** [RAD-434](https://ferlab-crsj.atlassian.net/browse/RAD-434) (story: [`../stories/rust-snv-engine.md`](../stories/rust-snv-engine.md), Story 1)
- **Assigned reviewer:** TBD (should read Rust, or pair with someone who does)
- **Status:** Draft
- **Branch (all repos):** `feat/rad-434-rust-snv-engine` (from the POC branch `poc/rewrite`, ETL, local)

## Chosen approach

**Summary:** a Python extension written in Rust (`rust/radiant_vcf`) replaces the slow half of the germline and somatic SNV extraction: VCF decoding, row building and Parquet writing. Python keeps the rest: task setup, sample checks, the S3 upload and the Iceberg commit. One environment variable, `RADIANT_SNV_ENGINE` (`python` by default, or `rust`), selects the engine in each `process_task`. The POC proved the approach: identical Iceberg rows, 5–9× faster.

### Why this step, and why Rust

- **Where the time goes:** the htslib decode (cyvcf2, iterate only) takes about 1.0 s of a 24.1 s germline benchmark (`rust/radiant_vcf/README.md`, "Benchmark"). The rest is the Python per-row work: one dict per row, then the `TableAccumulator` conversion to Arrow.
- **Rust removes that cost** and keeps the same C decoder: `rust-htslib` bundles htslib, the library cyvcf2 wraps. The rows go straight into Arrow builders, then to Parquet with the arrow-rs `parquet` crate, without the GIL.
- **The Iceberg contract does not change:** `add_files` reads each file footer (schema, statistics, partition values). The files only need the table's Arrow schema without field ids, as the Python writer gives. iceberg-rust is not used.

### etl

- **Crate `rust/radiant_vcf`** (PyO3 0.29, abi3 for Python ≥ 3.12, maturin; arrow and parquet 60.1; rust-htslib 1.0.2; release profile with fat LTO). One Rust file per Python module it ports; each function names the Python or cyvcf2 code it ports:

  | file | ports |
  |---|---|
  | `src/snv.rs` | the shared part: record checks, `process_common`, `InfoKeys`, genotype and AD views, `process_variant`, the `snv_variant` / `snv_consequence` builders |
  | `src/germline.rs` | germline `process_occurrence` (pedigree, parental origin, transmission mode), `process_comphet` |
  | `src/somatic.rs` | somatic `process_occurrence` (tumor and normal columns, `read_hotspot`, `adjust_somatic_calls_and_zygosity`) |
  | `src/consequence.rs` | `process_consequence`, `parse_csq_header`, `resolve_source`, `parse_cds_position` |
  | `src/genotype.rs`, `src/hts.rs` | the cyvcf2 v0.31.1 properties the Python code reads, on the htslib buffers |
  | `src/inheritance.rs`, `src/tables.rs` | the ETL and slivar inheritance rules; `tables.rs` is generated from `occurrence.py` by `gen_tables.py` |
  | `src/parquet_sink.rs` | the Parquet half of `_write_file` |
  | `src/lib.rs` | the Python classes `GermlineSnvReader` and `SomaticSnvReader` |

- **Parity with cyvcf2, quirks included:** `strict_gt` genotype types, the C `int` sum of `AD` (wraps), the `gt_phases` read, the INFO scalar rules, raw `FORMAT/SQ` values. The goal is the same rows, not better rows: the pre-existing bugs stay (see Frozen scope).
- **Engine switch:** `radiant/tasks/vcf/snv/rust_engine.py::snv_engine` reads `RADIANT_SNV_ENGINE` on each call, after `load_catalog`. `python` or unset: the Python path, unchanged. `rust`: `process_task_rust` / `process_somatic_task_rust`. Other value: `ValueError` that names the variable. The extension is imported only on the Rust path, so an image without it fails with an import error and never falls back to Python in silence.
- **Parquet writing (Rust):** `sink_config` gives each table the writer options of `_write_file` (`_get_parquet_writer_kwargs`: codec, level, page and dictionary sizes, page row limit; row-group limit; target file size). Two flush rules differ on purpose, the rows do not:
  - a row group also closes at `RADIANT_PARQUET_FILE_SIZE_MB` of encoded data (the memory bound of the Python path);
  - a file closes at `write.target-file-size-bytes` of Parquet bytes (Python bins on Arrow bytes), so fewer, larger files.
- **Upload and commit (Python, unchanged contract):** `upload_files` copies each local file through `PyArrowFileIO` to `location_provider.new_data_location` (`00000-<n>-<uuid>.parquet`, partition path from `partition_key`; `None` for an unpartitioned table). The function returns the same `PartitionCommit` lists as the Python path, so `merge_commits` and `commit_partitions` (`tx.delete` + `tx.add_files`) do not change.
- **Batch size:** `RUST_BATCH_RECORDS = 1_000` records between two writes. On the real trio, the reader peaks at 381 MB with 1 000 and at 763 MB with 10 000, in the same time (some records carry thousands of CSQ blocks).
- **Somatic sample checks** move into `somatic/process.py::check_samples`, called by both engines, so the errors are the same.
- **Engine in the pods:** the SNV operators (`operators/k8s.py`, `operators/ecs.py`) pass `RADIANT_SNV_ENGINE` from the Airflow environment, as they pass `RADIANT_PARQUET_FILE_SIZE_MB` (empty = the image default). The rollout then needs no image rebuild. The POC only had the image build argument.
- **Image:** `Dockerfile.radiant.operator` gets a `rust-builder` stage that builds the abi3 wheel with maturin. The final stage installs it and sets `ENV RADIANT_SNV_ENGINE=python` (build argument, default `python`). The POC stage cross-compiles from an arm64 host; on the amd64 runner it builds natively, with a pinned toolchain (`RUST_TOOLCHAIN=1.91.0`) and a pinned rustup installer.
- **CI:** a new job in `test.yml` installs the Rust toolchain, runs `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, `maturin develop --release`, then the three Rust test files. An environment variable in this job turns the `importorskip` of the parity tests into a failure.
- **Make targets:** `rust-develop`, `rust-test`, `rust-bench`.
- **Docs:** `rust/radiant_vcf/README.md` (layout, use, parity, benchmark, known differences, pre-existing bugs); the ETL CLAUDE.md (source layout, engine switch, `make` targets); one upgrade note.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | `rust/radiant_vcf/` crate, `bench.py`, `gen_tables.py`, README | new |
| etl | `radiant/tasks/vcf/snv/rust_engine.py` | new |
| etl | `radiant/tasks/vcf/snv/germline/process.py` (switch), `somatic/process.py` (switch, `check_samples`) | modified |
| etl | `radiant/dags/operators/k8s.py`, `ecs.py` (pass `RADIANT_SNV_ENGINE`) | modified |
| etl | `Dockerfile.radiant.operator`, `.dockerignore`, `Makefile` | modified |
| etl | `.github/workflows/test.yml` (Rust job), security workflows if the open question needs it | modified |
| etl | `tests/unit/vcf/test_rust_engine.py`, `tests/unit/vcf/{germline,somatic}/test_rust_engine_parity.py`, Rust variant of `test_process_task_error` | new |
| etl | `upgrade-notes/RAD-434.yaml`, CLAUDE.md | new / modified |

The portal, the MCP, the bioinfo pipelines and the StarRocks SQL do not change. Infra: no change in this story; see the open question on the ECS ephemeral storage.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Rust engine behind the switch | etl | Rebase the POC on `main`, drop the two seed commits. Crate, `rust_engine.py`, the two switches, `check_samples`, parity and engine tests, Rust variant of the htslib error test, README | — | yes: default `python` |
| 2 | Engine variable in the operators | etl | `RADIANT_SNV_ENGINE` passed by the K8s and ECS SNV operators, unit test of the pod environment | Task 1 | yes: empty = image default |
| 3 | Image build | etl | `rust-builder` stage, native amd64 build on the runner, pinned toolchain and installer, smoke check `import radiant_vcf` in the build | Task 1 | yes |
| 4 | CI and security gates | etl | Rust CI job (fails when the parity tests skip); Cargo dependencies in the security checks | Task 1 | yes |
| 5 | Docs and upgrade note | etl | ETL CLAUDE.md, `upgrade-notes/RAD-434.yaml` | Tasks 1–3 | yes |

One branch and one PR for the story; the tasks are the review order inside the PR. No UX task and no Labels task: nothing changes for the users of the portal.

## Merge and rollout order

1. etl: merge the PR. The default engine stays `python` in every environment, so a deploy changes nothing.
2. Operators: nothing to do. The upgrade note says that `RADIANT_SNV_ENGINE` exists, that it is optional, and gives the memory guidance (SNV pod limit ≥ 1.5 Gi for a genome-wide trio; the K8s default of 4 Gi request, 6 Gi limit, is enough).
3. The switch to `rust` in QA, then in prod, is the follow-up story "Run the Rust engine in QA, then in prod".

No migration, no backfill, no Iceberg schema change. The two engines write the same rows, so an environment can switch back and forth between two imports; a re-import of a task with the other engine replaces its partitions as today (`tx.delete` + `tx.add_files`).

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1 (Python unchanged):** the whole ETL test suite passes with the variable unset (CI as today).<br>• **AC2 (parity):** `tests/unit/vcf/{germline,somatic}/test_rust_engine_parity.py` run the real `process_task` through both engines and compare the rows row by row (NaN equals NaN), with the Iceberg Arrow schema. Germline: every germline test VCF under several pedigrees, the files both engines must reject, 6 × 3 000 random trio records. Somatic: the tumor-normal VCF (experiments in both orders), the tumor-only VCF, the five sample-check errors, a missing CSQ line, 2 × 3 000 random records. `test_tables_are_current` fails when `tables.rs` is stale.<br>• **AC3 (unknown value):** `tests/unit/vcf/test_rust_engine.py`.<br>• **AC4 (no fallback):** unit test: with `rust` and the import of `radiant_vcf` blocked, `process_task` raises `ImportError`.<br>• **AC5 (CI):** the Rust job, with the skip turned into a failure.<br>• **AC6 (image):** the image build runs `python -c "import radiant_vcf"` and checks the default `RADIANT_SNV_ENGINE`.<br>• **AC8 (htslib error):** a Rust variant of `test_process_task_error`. The Python test injects the error through `TableAccumulator.write_files`, which the Rust path does not call, so the variant gives a VCF that htslib cannot parse.<br>• **AC9 (Docker integration):** `tests/integration/test_process_{germline,somatic}_snv_vcf.py` with `RADIANT_SNV_ENGINE=rust` (upload, `add_files` commit, read back), in the Rust CI job.<br>• **Operators:** unit test that the SNV pod environment carries `RADIANT_SNV_ENGINE`. |
| QA (manual) | • **AC10 (speed):** `make rust-bench` in the PR, at least 4× on the 100 000-record germline benchmark with the same row counts. POC: 24.1 s → 4.5 s germline, 17.3 s → 3.0 s somatic (macOS arm64). Not in CI: timings on shared runners are not stable.<br>• **AC7 (security gates):** a check in the PR that the Cargo dependencies show in the dependency graph and that the gate reports them (see the open question).<br>• **AC11 (upgrade note):** reviewed in the PR; the `upgrade-note` check validates its format.<br>• **Sandbox A/B (done in the POC, repeated on the rebased branch):** tasks 63, 65, 67, 68, 69 and the CA1000019 trio, once per engine; row count and two order-independent hashes per table and task, through StarRocks, must be equal. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Genomic formats or data | The Rust decoder ports the cyvcf2 v0.31.1 properties the Python code reads, on the same htslib. The parity tests run in CI on every PR, on the test VCFs and on random records that hit every genotype, phase, AD, INFO and CSQ shape the generators produce. POC evidence: identical rows on the real trio (20 713 149 occurrences, 6 904 383 variants, 77 706 459 consequences, 1 084 comphet rows) and identical Iceberg checksums on the sandbox. The unsafe htslib calls are limited to `hts.rs` and the decoder in `snv.rs`, named for the review. |
| Clinical rules or interpretation | Zygosity (germline and somatic), parental origin, transmission mode and compound-het pairs are covered by the same parity tests. The inheritance lookup tables are generated from the Python source, and `test_tables_are_current` fails when they differ. The somatic sample rules stay in Python (`check_samples`), shared by both engines. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • No environment switches to `rust` (follow-up story).<br>• No change to the Iceberg tables, the StarRocks loads or the portal. |
| etl | • The CNV extractions stay in Python.<br>• No S3 write and no Iceberg commit from Rust (`object_store`, iceberg-rust).<br>• The four pre-existing bugs stay, in both engines, so the parity holds: `rsnumber` split into characters, ETL transmission mode null on X/Y (`Male`/`male` key), missing somatic `SQ` stored as NaN, `INFO/CAL` dropped. Each one is a follow-up story that fixes both engines.<br>• Known differences, accepted: two germline experiments with the same `seq_id` (Python merges them, Rust raises); `FORMAT/DP` or `GQ` declared `Float`, `FORMAT/SQ` declared `Integer` (Rust raises); per-record debug lines replaced by end-of-file counters; fewer, larger Parquet files.<br>• The POC seed commits (`seeds.sql` on the CA1000019 trio) and the sandbox data (follow-up story). |

## Open questions

| Module | Questions |
|---|---|
| etl | • **Cargo dependencies in the security gates:** `release-gate.yml` reads the open Dependabot alerts of every ecosystem, and `trivy.yml` scans the three images and the Dockerfiles. Is `rust/radiant_vcf/Cargo.lock` in the dependency graph (Dependabot alerts, `dependency-review.yml`), and does Trivy see the crates inside the compiled extension? Proposal: check both on the PR; if Trivy does not see them, add a Trivy filesystem scan of `Cargo.lock` to `trivy.yml` and to the release gate.<br>• **Disk of the SNV pods:** the Rust path writes the Parquet files on local disk before the upload, about 2.3 GB for a genome-wide trio, next to the 1.5 GB VCF. The K8s SNV resources set no `ephemeral-storage` (`_snv_container_resources`). Proposal: add an optional `RADIANT_TASK_OPERATOR_SNV_EPHEMERAL_STORAGE`, as the COSMIC and IGV profiles do, in the rollout story; this story only documents the need in the upgrade note.<br>• **Operator variable vs image default:** proposal above (operators pass the Airflow value, empty = image default). The other choice is two images, which doubles the build and the scans. |
| infra | • **ECS ephemeral storage of the SNV task definition:** enough for the local Parquet files of a trio? To check in the infra repo before the rollout story; no change here. |
| story / product | • **Reviewer:** who reads Rust? Proposal: one ETL reviewer plus one Rust-literate pair for `hts.rs` and the decoder in `snv.rs`.<br>• **Two engines to maintain:** until the follow-up story removes the Python path, a change to the SNV rules goes into both engines, and the parity tests fail if one is forgotten. Proposal: accept it for the rollout period and say so in the ETL CLAUDE.md. |

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
