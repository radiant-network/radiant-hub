---
paths:
  - "**/*_test.go"
  - "**/*.{test,spec}.{ts,tsx,js,jsx}"
  - "**/test_*.py"
---

# Tests

Cover every behaviour that matters with the fewest tests, and keep the suite fast. A function is covered when a test exercises it, not only when a new test is written for it.

- **Test a generic helper once,** where it lives (a validator, a mapper, a formatter). Its callers get one wiring test, shared by the callers of the same shape (two text validators, one test). It asserts what tells them apart (error code, path), not the helper's message again.
- **A limit gets two tests:** one at the max, one just past it, and only when the helper's tests do not have them.
- **Match the sibling code:** a new field gets the tests its neighbour field has, plus those its own behaviour needs. Do not build a test full of mocks only to prove a one-line call.
- **Before you add a test, look for one that already asserts it,** an integration test included. Extend a test rather than add one, above all a serial or container test: it slows every CI run.
- **One concept per test,** named for it, with no more setup than it needs.
