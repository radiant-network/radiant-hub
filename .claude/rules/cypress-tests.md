---
paths: ["portal/**"]
---

# Cypress tests

The developers own the Cypress specs (`portal/cypress/`). When a change can alter what a spec checks (a displayed value, a column, a route, an API response), update the spec, its test data or its POM in the same PR. A new behaviour that no spec covers gets one, or a proposal in the PR. The specs run against QA: report the ones you changed as not run unless you ran them. Without the `cypress` label, the Ferlease runs no Cypress. The team adds it once the PR is approved, so that Cypress runs only on validated code: remind the user then, but never add or remove it yourself, `gh pr create --label` included. To run or triage them, use the `cypress-tests` skill.

QA data is shared. The nightly and the Ferleases run at the same time, each with its own account from the pool (`portal/.github/scripts/cypress-account.sh`), a run's shards run in parallel under its account, and a stopped run never reaches its `after()`. So a spec that writes data that other specs or runs read (a case's assignees, an interpretation, the account's saved filters) sets that state in its setup, writes the same state whatever the run or the account, asserts on what it reads back rather than on what it wrote, and does not count on `after()` to restore it. When that state must hold the run's own account (a case assigned to it), the setup adds the account to what is there instead of replacing it: once every pool account is in, all runs write the same set. That setup goes in `setupOnce` (`portal/cypress/support/setupOnce.ts`): Cypress never retries a failed `before()`.
