---
name: cross-module-feature
description: Drive a feature that spans several Radiant modules (etl, portal, mcp) from the hub — spec, same-named branches, per-module implementation, PRs in merge order. Use when a request touches more than one module, or names an SJRA ticket whose scope crosses modules.
---

# Cross-module feature

Follow these steps in order. Don't skip the boundary check (step 4): that's where cross-module features break.

## 1. Spec

- Run `make status` to see which modules are checked out. If one you need is missing, ask the user to run `make bootstrap`.
- If `docs/features/RAD-xxxx-*.md` exists, read it. Otherwise copy `docs/features/0000-template.md` and fill it in with the user.
- Read the `CLAUDE.md` of every impacted module before planning its part.

## 2. Branches

Create the same branch in every impacted repo:

```sh
git -C <module> fetch origin
git -C <module> switch -c feat/rad-xxxx-<slug> origin/main
```

If a module has uncommitted changes, stop and ask. Don't stash the user's work.

## 3. Implement module by module, in dependency order

The usual order is ETL (schema, data) → portal backend → frontend → MCP. For each module:

- Follow its own `CLAUDE.md`: commands, tests, conventions (e.g. the portal regenerates API clients after changing the backend spec).
- Run that module's tests before moving on.
- Commit inside the module using its commit convention.

## 4. Check both sides of each boundary

For every boundary that the spec changes (StarRocks tables/columns, enum values, API endpoints/fields), check that the writer and the reader agree: column names and types in the DDL vs the backend query, enum values across `etl/radiant/data_qa/macros/dictionaries.sql` ↔ `portal/backend/internal/repository/starrocks/facets.go` ↔ `portal/frontend/translations`, and API fields in `swagger.yaml` vs the consumers. List any mismatch to the user.

## 5. PRs

- Only push and open PRs when the user asks.
- Run `gh pr create` **inside each module** (or pass `--repo radiant-network/<repo>`), never at the hub root.
- Open them in merge order. Each description links to the spec and to the sibling PRs.
- Use the module's PR template where one exists (the portal requires `.github/pull_request_template.md`).
