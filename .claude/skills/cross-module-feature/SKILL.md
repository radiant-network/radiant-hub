---
name: cross-module-feature
description: Drive a feature that spans several Radiant modules (etl, portal, mcp) from the hub — spec, contract updates, same-named branches, per-module implementation, linked PRs in merge order. Use when a request touches more than one module, or names a RAD (or older SJRA) ticket whose scope crosses modules.
---

# Cross-module feature

Follow these steps in order. Don't skip the contract step: that's where cross-module features break.

## 1. Spec

- Run `make status` to see which modules are checked out. If one you need is missing, ask the user to run `make bootstrap`.
- If `docs/features/RAD-xxxx-*.md` exists, read it. Otherwise copy `docs/features/0000-template.md` and fill it in with the user.
- Read the `CLAUDE.md` of every impacted module before planning its part.

## 2. Contracts first

- List every boundary the feature crosses: StarRocks tables/columns, enum values, API endpoints/fields.
- Update `docs/contracts/*.md` to describe the **target** state, and record who writes and who reads each item.
- Write the contract changes into the spec's "Contract changes" section. Each module's implementation must match them.

## 3. Branches

Create the same branch in every impacted repo:

```sh
git -C <module> fetch origin
git -C <module> switch -c feat/rad-xxxx-<slug> origin/main
```

If a module has uncommitted changes, stop and ask. Don't stash the user's work.

## 4. Implement module by module, in dependency order

The usual order is ETL (schema, data) → portal backend → frontend → MCP. For each module:

- Follow its own `CLAUDE.md`: commands, tests, conventions (e.g. the portal regenerates API clients after changing the backend spec).
- Run that module's tests before moving on.
- Commit inside the module using its commit convention.

## 5. Check both sides of each contract

For every item in "Contract changes", check that the writer and the reader agree: column names and types in the DDL vs the backend query, enum values across `etl/radiant/data_qa/macros/dictionaries.sql` ↔ `portal/backend/internal/repository/starrocks/facets.go` ↔ `portal/frontend/translations`, and API fields in `swagger.yaml` vs the consumers. List any mismatch to the user.

## 6. PRs

- Only push and open PRs when the user asks.
- Run `gh pr create` **inside each module** (or pass `--repo radiant-network/<repo>`), never at the hub root.
- Open them in merge order. Each description links to the spec and to the sibling PRs. Once all PRs exist, add their links to the spec's "Linked PRs" section.
- Use the module's PR template where one exists (the portal requires `.github/pull_request_template.md`).
