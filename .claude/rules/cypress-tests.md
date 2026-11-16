---
paths: ["portal/**"]
---

# Cypress tests

The developers own the Cypress specs (`portal/cypress/`). When a change can alter what a spec checks (a displayed value, a column, a route, an API response), update the spec, its test data or its POM in the same PR. A new behaviour that no spec covers gets one, or a proposal in the PR. The specs run against QA: report the ones you changed as not run unless you ran them. Without the `cypress` label, the Ferlease runs no Cypress: tell the user that the PR needs it, but never add or remove it yourself, `gh pr create --label` included. To run or triage them, use the `cypress-tests` skill.
