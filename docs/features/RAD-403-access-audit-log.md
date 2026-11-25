# RAD-403: Access audit log

## Story

- **Link:** [RAD-403](https://ferlab-crsj.atlassian.net/browse/RAD-403) (epic), stories [RAD-404](https://ferlab-crsj.atlassian.net/browse/RAD-404) to [RAD-409](https://ferlab-crsj.atlassian.net/browse/RAD-409)
- **Assigned reviewer:** Yann Marcou
- **Status:** Draft
- **Branch (all repos):** portal only, one branch per story: `feat/rad-<story>-<slug>` (see Tasks)

## Chosen approach

**Summary:** a Postgres trigger copies every change of the six access tables into an append-only `auth_audit_log`, the API sets who made the change inside the transaction, and the admin section reads it through one search endpoint and one CSV export.

### portal (backend)

- **Table:** new `auth_audit_log` in Postgres. One row per changed row: time, transaction id, tenant, table, operation (insert, update, delete, snapshot), row key, actor, request id, old row and new row as jsonb. The jsonb copy keeps working when a table gains a column, unlike the positional copy of the interpretation history.
- **Capture:** one `AFTER INSERT OR UPDATE OR DELETE` row trigger on `users`, `tenant`, `organization`, `role`, `role_action` and `user_role`. Cascades (deleting a role removes its actions and grants) and direct SQL fire it like any API write. A `BEFORE TRUNCATE` statement trigger on the same six tables writes one delete entry per row about to go. An update that changes no value writes nothing, so re-provisioning an unchanged user (a `create-user` or `update-user` re-run) leaves no trace.
- **Append only:** a guard trigger refuses `UPDATE`, `DELETE` and `TRUNCATE` on `auth_audit_log`. It protects against mistakes and manual fixes, not against a malicious database administrator: a table owner can still disable a trigger.
- **Initial history:** the migration that creates the table and the triggers also writes one snapshot entry per existing row, with the actor `migration`, in the same transaction. No change can fall between the snapshot and the first recorded change.
- **Later migrations:** every migration that writes one of the six tables (as the action seeds of 000041 and 000042 did) sets `app.actor` to `migration`. Migrations run at API startup with the API's database account, so without it their entries would read `db:<session_user>`, like a manual psql session or a write path that forgot the actor.
- **Actor and request id:** each write path sets `app.actor` and `app.request_id` with `set_config(…, true)` at the start of its transaction. The trigger reads them; with nothing set, it records `db:<session_user>`. Formats: `user:<sub>` for an API call (the caller's Keycloak id, the same value `granted_by` holds today), `cmd:<binary>` for the toolbox commands, `migration`. The request id is stored for support only: the API reuses an inbound `X-Request-ID`, so a caller can send the same id twice, and nothing is grouped on it.
- **Commands:** `update-user` runs the `create-user` binary with `-sub`, so both record `cmd:create-user`. `create-tenant` writes the `tenant` row and the default roles of a new tenant, and records `cmd:create-tenant`. `refresh-tenants` adds the default role actions a tenant is missing (RAD-147), and records `cmd:refresh-tenants`. Its inserts skip existing rows, so a re-run writes nothing.
- **Write paths:** removing a member runs in a transaction. Provisioning writes the user and all its grants in one transaction, so a failed grant leaves no half-created member. Editing a role writes only the actions added or removed, instead of deleting and re-inserting the whole set.
- **Permission:** new tenant action `can_see_auth_audit_log`, grantable (a custom "auditor" role can hold it alone). The migration grants it to `tenant_admin` in every tenant, and it joins the `tenant_admin` defaults for new tenants.
- **Search:** `GET /{tenant}/access_logs`, gated by `requireAction(can_see_auth_audit_log)` and listed in the tenant route guard. Criteria: member, role, actor, type of change, date range. Pagination by page index and page size with the total count, as the tenant users list does. Sorted from the most recent operation.
- **Operations:** entries are grouped by transaction id. Each access write path is one transaction, and direct SQL and migrations have one too. Pagination and the total count apply to operations, not to entries. Each change is returned as the fields that differ (update), or the added or removed item.
- **Types of change:** members (grants of the `member` role), role grants (the other grants), role definitions (`role`, `role_action`), organizations (`organization`).
- **Tenant isolation:** every read filters on the requested tenant. `users` and `tenant` entries are never returned: they belong to no tenant, or say when a tenant was created. A member's name and email come from `users` at read time.
- **Export:** `GET /{tenant}/access_logs/export`, same criteria, permission and isolation. One CSV row per change, with the columns of RAD-407, streamed from the database. Values that start like a spreadsheet formula get a `'` prefix. UTF-8 with a byte order mark, file name `access-log-<tenant>-<date>.csv`.

### portal (frontend)

- **History section:** a new entry in the admin section navigation, shown with `can_see_auth_audit_log`. The action joins the admin actions, so a user who holds only that action reaches the admin section and sees only History.
- **Table:** the portal data table with server pagination, as the Users section uses. One row per operation; columns and filters as listed in RAD-408, without the request id column.
- **Request id:** not shown, since it means nothing to most admins (designer decision). It stays in `auth_audit_log`, in the API response and in the CSV export, for support.
- **Deep links:** a user row and a role row link to the History section with the member or role filter in the URL, the same way the Roles section opens Users filtered on a role today.
- **Export button:** calls the export with the current filters and saves the file with the existing download helper.
- **Labels:** EN and FR for the section, the columns, the filters, the types of change and the actor kinds.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| portal (backend) | Postgres migration (table, triggers, snapshot, action), access write paths, default tenant roles, access log search and export, routes and route guard, swagger, generated clients | new / modified |
| portal (frontend) | admin section navigation, History section, Users and Roles row links, tenant actions, translations | new / modified |
| portal (cypress) | new Admin specs and page object | new |
| etl, mcp, infra, bioinfo | none (the Python client is regenerated, the MCP pin is not bumped) | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | RAD-404 Audit log, initial history, new action | portal (backend) | Migration: `auth_audit_log`, row, truncate and guard triggers, snapshot, `can_see_auth_audit_log` seeded and granted; default roles updated; test that no migration leaves a `db:` actor | — | yes (records changes, nothing reads them yet) |
| 2 | RAD-405 Actor and request id | portal (backend) | Actor and request id set in each access write path; member removal in a transaction, provisioning (user and grants) in one transaction; role edit by difference; toolbox commands | 1 | yes |
| 3 | RAD-406 Search access logs | portal (backend) | `GET /{tenant}/access_logs`, grouping, pagination, isolation; swagger and clients | 1 | yes |
| 4 | RAD-407 CSV export | portal (backend) | `GET /{tenant}/access_logs/export`; swagger and clients | 3 | yes |
| 5 | RAD-408 History section | portal (frontend), cypress | Navigation entry, table, filters, deep links, labels, Admin specs | 3 | yes once 3 is deployed |
| 6 | RAD-409 Export button | portal (frontend), cypress | Button, loading and error states, download spec | 4, 5 | yes once 4 is deployed |

No UX task: the prototype on the admin section set the layout. Labels are part of tasks 5 and 6 (no clinical term to validate).

## Merge and rollout order

1. Task 1. The migration runs at API startup and records from that moment. Each environment that deploys it later loses nothing, since the snapshot holds its state on that day.
2. Task 2. Until it ships, API changes are recorded with the actor `db:<session_user>`. Ship it in the same release as task 1 if possible.
3. Tasks 3 and 4, then 5 and 6. The frontend needs the backend in the same environment: without it the History section fails its first read.
4. QA: check that the Cypress pool accounts hold `can_see_auth_audit_log` in the tenant the specs use (`tenant_admin` gets it from the migration).

No backfill beyond the snapshot. No feature flag: the History entry only appears with the new action.

## Test strategy

### portal (backend)

- **RAD-404:** repository tests on a Postgres container: one test per audited table and operation, `TRUNCATE` on an audited table, the role delete cascade, the no-op update, the `db:` fallback, the guard on `UPDATE`, `DELETE` and `TRUNCATE`, the rollback. A migration test checks the snapshot count and the new grant, and that after every migration has run no entry has a `db:` actor (it fails when a later migration forgets `app.actor`).
- **RAD-405:** a test per access write path asserts the actor and request id of its entry; one test runs a request end to end through the router and checks the `X-Request-ID` value. Provisioning: a grant that fails leaves neither the user row nor any grant. Role edit: one added and one removed action give two entries.
- **RAD-406:** repository tests on two tenants: isolation, each criterion, grouping by transaction (two requests sent with the same `X-Request-ID` stay two operations), pagination and total count, sort. Handler tests with JSON comparison, route guard test.
- **RAD-407:** handler test comparing the file with the search for the same criteria; unit tests for the formula prefix, the RFC 4180 quoting and the byte order mark.

### portal (frontend)

- **Cypress (RAD-408, RAD-409):** the components are tested end to end only, by new Admin specs on QA: History entry, columns, each filter, pagination, links from Users and Roles, download of the export. The specs write no access change. Other specs and people add entries on QA at any time, so each spec filters on a fixed member or role and asserts on its rows, never on a count or on the first rows.
- **Cypress (RAD-408), rendering:** the snapshot holds only additions, so one spec stubs the access log response with a fixture that holds an addition, a removal, an update and each actor kind, and checks how each one is shown.

### QA (manual)

- **RAD-404:** after the deploy on QA, delete a test role with members and check its grants appear as removed, then run a direct SQL change and check its `db:` entry.
- **RAD-407:** open the export in Excel and check accents and a value that starts with `=`.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| Patient or identifying data (names and emails of members and actors) | Tenant filter in every read, `users` and `tenant` entries never returned, two-tenant isolation tests on the search and the export |
| Traceability and audit (no change may escape, log cannot be rewritten) | Row and truncate triggers on every audited table, cascade, direct SQL and truncate tests, guard trigger tests, actor tested on every write path and on every migration. Not covered: a database administrator who disables a trigger |
| False answer from a wrong grouping or rendering | Grouping by transaction (not by the caller-supplied request id) with its tests, export compared with the search, Cypress rendering spec on every kind of change |

## Frozen scope

### portal (backend)

- Six tables only: no gene panels, no clinical tables, no interpretation history change.
- No API read of `users` and `tenant` entries, and no cross-tenant view.
- No sort parameter, no export size limit (open questions).
- No purge, no erasure of personal data (future account deletion feature).
- No service account actor: none writes the access tables today.

### portal (frontend)

- No history panel in the Users and Roles sections (open question).
- No request id in the History table.
- No automatic refresh of the table, no column choice in the export.

## Open questions

### portal (backend)

- **Sort:** should the search accept another sort than the most recent first (RAD-406)?
- **Export size:** a maximum number of rows or date range (RAD-407)? Proposal: none, the export is streamed and a tenant's access log stays small.

### portal (frontend)

- **History panel:** a side panel on a user or role row instead of a link to the filtered History section (RAD-408)?

## Approval

| | |
|---|---|
| Reviewer | Yann Marcou |
| Date | … |
| Plan review duration | … min |
| Decision | … |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
