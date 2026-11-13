---
name: cypress-tests
description: Triage a failing Cypress run of the Radiant portal (nightly or Ferlease). Reads pasted errors, the JUnit XML, mochawesome HTML or JSON, or screenshots, checks the code that ran, groups the failures by root cause and proposes a fix for each, then updates the specs on go-ahead. Use whenever the user shares Cypress failures, a nightly report or a Ferlease Cypress result.
argument-hint: "[nightly | ferlease <PR#>] [<report path>]"
---

# QA: Cypress triage

Report in the user's language, headings included.

## 1. Identify the run

| Run | Workflow (`portal/.github/workflows/`) | Slack links |
|---|---|---|
| Nightly | `cypress-nightly.yml`, weekdays 07:00 UTC, against QA (main deployed) | screenshots zip, HTML report, `combined-results.xml` (every test) |
| Ferlease | `ferlease-pr.yml`, job `cypress`, against the PR's preview | screenshots zip of the new failures, one HTML report per shard, `combined-results.xml` (every failure, tagged ones included) |

Ask when neither the user nor the report says which run it is.

- `retries.runMode: 2`: a definitive failure has an « (attempt 3) » screenshot. Slack's « new fails » are the failures whose title has no `RAD-`, `SJRA-` or `CLIN-` tag.
- A green GitHub job proves nothing: the result is the aggregator's Slack post.
- Ferlease: the specs come from the PR merged with main, the app from the branch head, so they only match once the branch is rebased (otherwise Slack posts « Launch Attempt Failed »). The shards wait until `/version.txt` serves the pushed SHA. To rerun without a push, remove and re-add the `cypress` label.

## 2. Collect the failures without opening a report

Reports hold secrets in clear: request bodies with the test account and `client_secret` when `getToken` fails, presigned S3 URLs. Never `Read`, `cat` or `grep` one. Put the files in `tmp/<rad-xxxx|nightly>-cypress/`.

| Input | How |
|---|---|
| Pasted errors | Use as is. Flag any secret they contain without repeating it |
| Slack report link | Ask for the downloaded file instead: a presigned URL carries temporary AWS credentials. Already pasted: flag it, download it with `curl -s -o <file>` (prints nothing), never repeat it |
| JUnit XML, mochawesome JSON or HTML | `python3 -I .claude/skills/cypress-tests/scripts/report_summary.py <file>`: totals, run window (UTC), failures by spec, redacted messages and `cypress/` stack lines |
| Screenshot | Last resort, for a failure that the message cannot explain. Ask before you open each one: its command log shows presigned URLs, never copy one |

## 3. Read the code that ran

From inside `portal/`:

| Run | App under test | Specs that ran |
|---|---|---|
| Nightly | last `origin/main` commit before the run start: `git rev-list -1 --before=<start> origin/main` | same commit |
| Ferlease | PR head: `gh pr view <n> --json headRefName,headRefOid` | the head merged with main |

Read through `git show <sha>:<path>`, never the checkout (it may sit on another branch), and check that the stack-trace line matches. Then find what changed since the last green run (the previous weekday nightly, or `git diff origin/main...<head>` for a PR), limited to the spec, its POM, the component and the API that it touches, and whether that PR ran Cypress (`cypress` label). Also check the open PRs that may already fix it (`gh pr list --search`) and recent reference-data or ETL changes.

## 4. Group by root cause

One theme = one cause = one fix, whatever the number of specs.

| Signature | Cause | Fix |
|---|---|---|
| Title tagged `[RAD-…]`, `[SJRA-…]` or `[CLIN-…]` | Known bug, left red on purpose | None: list it, don't diagnose |
| Value assertion fails, a backend or ETL change in the window | Product change the specs didn't follow | Test data or POM |
| Value assertion fails, no code change | QA data changed (reference reload, ETL) | Test data, after reading the new value |
| `Expected <x> not to exist`, the list grew | Feature shipped ahead of the specs | POM |
| `"X" should be > "X"` in a sort check | Tie in the data, the sort works | Data with distinct values |
| `cy.wait` timeout, « No request ever occurred » | The front no longer calls the intercepted route, or the action didn't fire | Compare the intercept with the front code |
| 401 in series after passing tests, ~0.1 s each | API token expired mid-spec | Token renewal in `cypress/support/` |
| Isolated 502, 503 or 504, < 1 s, neighbours green | Gateway blip | Retry in the API command (improvement) |
| A whole spec red behind one `before` | One setup failure cascading | Diagnose the first failure only |
| None of the above, code changed in the area | **Regression** | Product fix, not a spec change |

- Cypress stops at the first false assertion of an `it`: the later values were never checked.
- Never guess a QA value: tell the user where to read it. Find candidates with a facet on the QA portal's `/cypress/case/entity/<case>?tab=variants&seq_id=<seq>` (a `>` filter also drops empty values), then read them on `/cypress/variants/entity/<locus_id>`. QA data is synthetic, so the value may come back in the chat.
- Reading them needs access to the `cypress` tenant. Someone with `can_manage_user` grants it on `/cypress/admin`, or the toolbox runs `create-user -sub <sub> -grant cypress::member -grant 'cypress:*:geneticist'` on QA (see `infra/qlin-qa` for how the toolbox runs): prepare the command, the user runs it. A `user_role` insert is not enough: QA reads StarRocks through Ranger, which needs the tenant's Ranger role.

Test data traps (`cypress/pom/shared/Data.ts`):

- `variantGermline` (ADGRV1) fills every tab and drives ~60 specs: never swap it. A value that it lacks gets a dedicated entry, like `variantPredictionScores`.
- `null` = expected hidden (`-` or absent).
- Labels are asserted in English. Map a value read in another UI language through `frontend/translations/common/en.json` (« Délétère » is `Damaging` for FATHMM, SIFT and PolyPhen-2, but `Deleterious` for LRT).
- Variants are catalogued per tenant: a test variant missing from `cypress` gets a 404 page.
- Gene-level values (gnomAD LOEUF, pLI, CNV `# Exons` counted on the reference transcript) change when a reference is reloaded, with the variant unchanged.
- Tables always multi-sort (`isMultiSortEvent: () => true` in `frontend/components/base/data-table/data-table.tsx`): a later sort only breaks the ties of the earlier ones.
- igv.js renders in a shadow root of `#igvContainer`: go through `.shadow().find()`. A plain `cy.get` finds nothing, and `should('not.exist')` then passes vacuously.

## 5. Report

Concise without losing information. One `##` block per theme, largest first:

```
# Radiant Nightly: <YYYY-MM-DD> (<k> failures)   |   # Radiant Ferlease: <branch without prefix, e.g. rad-271> (<k> failures)
<summary: run window, commit that ran, failed/total, number of causes, new vs tagged failures>

## <N>. <cause in a few words> - <k> failure(s)
- [<spec> › <test>](https://github.com/radiant-network/radiant-portal/blob/<sha that ran>/<path>#L<it line>) — <short message>
### Confidence
confirmed | to check, and what it rests on
### Cause
why, with the commit or PR and file:line
### Fix
one per failure when they differ, plus what the user must check or read in QA
### Improvement
what the evidence supports (robustness, coverage, reports), or « Nothing to propose. »
```

## 6. Fix

On go-ahead, theme by theme:

- Where to commit: a Ferlease → on its PR's branch. A nightly → a fix ticket, proposed first (`jira-story` skill, component `cypress`), then a branch for it. Branch, commits and PR follow the `git` rule.
- Keep the reference test data: add a dedicated entry for what it cannot cover rather than swapping it.
- Before you propose the commit, rerun the touched specs from `portal/`. Cypress reads `.env` itself, never read it. Filter its output so that no token reaches the context. From VS Code, `env -u ELECTRON_RUN_AS_NODE` is required, otherwise `MODULE_NOT_FOUND`:
  ```sh
  env -u ELECTRON_RUN_AS_NODE npx cypress run --spec "<glob>" 2>&1 \
    | sed -E 's/\x1b\[[0-9;]*m//g; s/(password|client_secret|access_token|refresh_token|id_token)([=":]+ *)[^&", ]+/\1\2<redacted>/gI; s/Bearer [A-Za-z0-9._-]+/Bearer <redacted>/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<jwt>/g' \
    | tail -70
  ```
- Then run `npm run format:cypress:check` and `npm run type-check:cypress`, and compare with main: errors may pre-exist. `cypress.config.ts` is outside `cypress/tsconfig.json`, so check it separately.
- Edit this skill when a triage taught something non-obvious. Add a signature row when a new pattern recurs.
