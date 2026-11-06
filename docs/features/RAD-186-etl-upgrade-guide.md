# RAD-186: Upgrade guide between two ETL releases

## Story

- **Link:** [RAD-186](https://ferlab-crsj.atlassian.net/browse/RAD-186) (depends on [RAD-184](RAD-184-etl-release-conventional-commits.md), release PR and tags; sibling: ETL QA auto-deploy, independent)
- **Assigned reviewer:** TBD
- **Status:** Draft
- **Branch (all repos):** `feat/rad-186-etl-upgrade-guide`

## Chosen approach

**Summary:** each PR that needs an operator action adds one upgrade note file to the ETL repo. One command reads the notes on `main`, finds the release of each note from the RAD-184 tags, and prints the guide between two versions. The RAD-184 release job runs the same command to keep the guide of the next release in a comment on the release PR, and to add an "Upgrade guide" section to each GitHub release. A required PR check asks for a note when a PR changes a migration or has a breaking change.

### etl

- **Note storage:** one YAML file per PR in an `upgrade-notes/` folder at the repo root, named after the ticket (`RAD-171.yaml`; a suffix when a ticket has two PRs). Preliminary lean, see Options considered. The notes stay on `main`, so a correction is a new PR that edits the file.
- **Note format:** a list of actions. Each action has:
  - `when`: `before` or `after` the deploy;
  - `do`: what to do;
  - `preconditions`: for example "no import running";
  - `refs`: the migration file or the DAG it refers to;
  - `check`: how to check that the action worked.

  A pydantic model (pydantic is already an ETL dependency) validates each note. The migration SQL files keep their WHERE / WHEN header; the note refers to the file and does not copy its SQL.
- **Release of a note:** the commit that added the note file is the PR's squash commit. Its release is the first `vX.Y.Z` tag that contains this commit. The merge order is the order of these commits on `main`. The text always comes from the current `main`, so a corrected note reaches the guide.
- **Guide command:** a small Python CLI outside the `radiant` package (not shipped in the images), run as `make upgrade-guide FROM=<vA> TO=<vB>`. It prints one Markdown guide:
  - the releases after vA up to vB included, in release order;
  - in each release, the actions grouped into "Before the deploy" and "After the deploy", each with its version and PR, in merge order;
  - "No upgrade action" for a release with no note.

  It fails with an error that names the version when vA is not older than vB, or when a version is not a tag. When vA is older than the first tag that contains `upgrade-notes/`, it prints a warning that the actions of the earlier releases are not listed.
- **Manual workflow:** a `workflow_dispatch` workflow with the inputs `from` and `to` runs the same CLI and writes the guide to the job summary. It needs the full history and the tags.
- **Release PR comment:** a new step in the RAD-184 release job, after release-please. It runs the CLI from the last tag to `main`, and creates or updates one comment on the open release PR. A hidden marker identifies the comment. The step finds the release PR by its label or branch: the action's `pr` output is "unset if no release was created" ([action outputs](https://github.com/googleapis/release-please-action)), so it can be empty on a run that only updates the PR. The release-please PR body is not edited, because each run rebuilds it.
- **Release section:** when the action reports `release_created`, a step appends the "Upgrade guide" section of that release to the GitHub release named by `tag_name`.
- **PR check:** a new job in a required PR workflow (on `pull_request`, read-only token). It fails when:
  - the PR adds or changes a file under `radiant/dags/sql/**/migrations/` and adds or changes no note;
  - the PR title has `!` after the type, or the PR description has a `BREAKING CHANGE:` footer, and the PR adds no note;
  - a note does not match the format;
  - a note holds an IP address, a URL whose host is not on a short public allowlist (github.com, the tools' docs), a 12-digit cloud account number, or an `s3://` path whose bucket is not a `<placeholder>`;
  - the PR deletes a note;
  - the PR adds a note and its type is hidden (`chore`, `docs` …): such a PR opens no release PR in RAD-184, so its note would wait for the next user-facing release (see open questions).
- **PR template:** a new "Upgrade" section: add a note in `upgrade-notes/` for an operator action (a new environment variable, Airflow connection or variable, a DAG to run once, a re-import, a Nextflow pipeline revision, a migration), or write "No upgrade action".
- **Docs:** the README and the ETL CLAUDE.md say when a PR needs a note, give the format with one example, and give the command and the workflow for the guide between two versions.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| etl | `upgrade-notes/` folder and note model, guide CLI and `make` target, manual guide workflow, PR check workflow, RAD-184 release workflow (two steps), PR template, README, CLAUDE.md | new / modified |

The portal, the MCP and the infra repos do not change.

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Note format and guide command | etl | Note model, guide CLI, `make upgrade-guide`, manual workflow, unit tests, README and CLAUDE.md | RAD-184 tags | yes |
| 2 | Require a note | etl | PR check job, PR template section, unit tests of the rules | Task 1 | yes (not required until the rollout step) |
| 3 | Guide in the release PR and the release | etl | Two steps in the release job: release PR comment, release section | Task 1, RAD-184 task 2 | yes |

No Labels or UX task: nothing is shown to users of the portal.

## Merge and rollout order

1. RAD-184 is rolled out: release job, GitHub App, first release. If not, there is no tag to build the guide from.
2. etl: merge task 1. The command works from the first tag that contains `upgrade-notes/`.
3. etl: merge task 2, then mark the check as required on `main`. If not required, a migration can merge with no note and its action is missing from the guide.
4. etl: merge task 3. The next run of the release job adds the comment to the open release PR.

No migration, no feature flag. No backfill: the releases before this story have no notes (excluded edge case of the story).

## Test strategy

| Module | How the story is proven |
|---|---|
| etl | • **AC1 (note format):** unit tests of the note model on a valid note and on notes with a missing field or a wrong `when`.<br>• **AC5, AC6, AC7 (guide between two versions):** unit tests of the CLI on a temporary git repo with tags and notes: release order, before/after grouping, version and PR on each action; an error that names the version for vA ≥ vB and for an unknown tag; the warning for a vA before the first note; a note edited after its release shows the new text.<br>• **AC2, AC8 (PR check):** unit tests of the rules on lists of changed files and PR titles: a migration with no note, a `!` with no note, a deleted note, a note with an IP, a host, an account number or a bucket.<br>• **AC3, AC4 (no action, release section):** the CLI prints "No upgrade action" for a release with no note (unit test). |
| QA (manual) | • **AC4:** after task 3, the open release PR has one comment with the guide, updated by the next merge; the merged release has the "Upgrade guide" section.<br>• **AC5:** the manual workflow run with two real tags writes the guide to the job summary.<br>• **AC2:** a test PR that changes a migration with no note cannot merge.<br>• **AC9 (docs):** reviewed in the PR. |

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Traceability and audit | Each note is tied to its PR and, through the tags, to its release. The guide between vA and vB lists every note of the skipped releases, in order, and the required check makes a migration without a note fail. The release PR comment shows the actions before anyone releases. |
| Patient or identifying data | The notes are public. The PR check rejects IPs, unknown hosts, account numbers and real bucket names; placeholders follow the migration files (`<shared_db>`). The guide holds only the notes, so the job summary of a public workflow shows nothing else. Patient data in an example query cannot be detected by a pattern: the PR template and the docs forbid it, and the review checks it. |

## Frozen scope

| Module | Not covered |
|---|---|
| all | • Running the actions automatically (no migration runner).<br>• A downgrade or rollback guide.<br>• The portal and MCP upgrade guides. |
| etl | • No notes for the releases before this story, and no note for the existing migration files.<br>• No change to the migration files or to their headers.<br>• A tag created by hand gets no "Upgrade guide" section; the command still covers its range.<br>• No check that a non-migration action (environment variable, connection) has a note: the PR template asks for it, and the review checks it. |

## Open questions

| Module | Questions |
|---|---|
| etl | • **`BREAKING CHANGE:` footer and the squash message:** RAD-184 sets the squash message to the PR title only, so a footer in the PR description never reaches the commit, and release-please sees only the `!` ([squash settings](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/configuring-commit-squashing-for-pull-requests)). Proposal: use `!` in the title for every breaking change, and say so in the docs; the check still reads the footer in the description. The other choice is the "title and description" squash message, which puts the whole PR template in each commit.<br>• **A note in a hidden-type PR:** fail the check (proposal above), or let the note wait for the next `fix` or `feat`? |
| story / product | • **Who writes and reviews the notes?** Proposal: the PR author writes the note; the PR reviewer checks it against the operator's view (preconditions, check). |

## Options considered

**Note storage**

| Option | Behaviour | Main pro | Main con | Effort |
|---|---|---|---|---|
| N1 YAML file per PR in `upgrade-notes/` | Fields validated by a model; the CLI groups the actions by `when`. | Strict format, simple grouping; a correction is a reviewed PR. | YAML is less pleasant to write than Markdown. | S |
| N2 Markdown file per PR, with a front matter per action | Same storage; free text under each action. | Easy to read and write. | Several actions per file need a parser for several front matters. | M |
| N3 "Upgrade" section in the PR description | The CLI reads the PR descriptions through the GitHub API. | Nothing new in the repo. | A correction edits a merged PR body, with no review and no history in git; the CLI needs a token. | M |

Preliminary lean: **N1**. It is the only option where the check can validate each field and a correction goes through review.

**Guide runner**

| Option | Behaviour | Main pro | Main con | Effort |
|---|---|---|---|---|
| G1 CLI with a `make` target, and a manual workflow that runs it | The operator runs it from a clone, or from the Actions tab. | Works with or without a clone; one implementation for the comment, the release and the operator. | Two entry points to document. | S |
| G2 Manual workflow only | The operator runs it from the Actions tab. | One entry point. | No offline use; slower to test by hand. | S |

Preliminary lean: **G1**.

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
