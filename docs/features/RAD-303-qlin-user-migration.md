# RAD-303: Migrate the QLIN users and their access to RADIANT

## Story

- **Link:** [RAD-303](https://ferlab-crsj.atlassian.net/browse/RAD-303) (sub-tasks RAD-305, RAD-306, RAD-307)
- **Assigned reviewer:** to assign
- **Status:** In review
- **Branch (all repos):** `feat/rad-303-qlin-user-migration` (hub only, this spec)

## Chosen approach

**Summary:** a one-off, scripted import creates each QLIN user in RADIANT through the portal's existing "add user" endpoint, with the `geneticist` role at the user's own organizations. No module code changes. The scripts and the user lists stay on the operator's machine, because they hold practitioner names and emails.

The numbers below come from the prod legacy systems on 2026-11-23. They are the rules to validate before the import.

### Sources

- **Who is migrated:** the accounts of the legacy QLIN Keycloak realm. An account exists there for every person who can log in.
- **Organizations:** the practitioner roles of the QLIN practitioner sheet, matched on the practitioner id stored on the legacy account. For an account that the sheet does not know, the hospital and laboratory groups of the legacy account.
- **Cross-check:** the legacy Keycloak user list kept as code. It agrees with the sheet for 148 of the 149 accounts both know.
- **The sheet's active flag is not used.** Unwanted users are removed in the admin console after the import.

### Selection rules

| Step | Rule | Accounts |
|---|---|---|
| Start | Every account of the legacy realm (none is disabled) | 211 |
| Left out | Internal team accounts, by email domain | 25 |
| Left out | Test accounts, listed one by one | 4 |
| Left out | No organization in any source (internal team accounts created by hand) | 19 |
| **Migrated** | Organizations from the sheet: 145. From the legacy groups: 18 | **163** |

- 104 migrated users have one organization, 43 have two, 16 have three or more.
- 7 practitioners of the sheet have no legacy account. They are not migrated.

### Role mapping

- **Every migrated user:** `member` on the whole tenant (the portal adds it), and the default `geneticist` role at each of their organizations. No `*` grant, no custom role.
- **Effect:** the user searches every case of the tenant. Patient names and identifiers are readable only at the user's organizations, or for a case whose diagnosis laboratory is one of them. This is the legacy behaviour.

| Legacy role | Migrated users holding it | RADIANT |
|---|---|---|
| `clin_genetician` | 79 | `geneticist` at their organizations |
| `clin_prescriber` without `clin_genetician` | 80 | `geneticist` at their organizations (see open questions) |
| Neither | 4 | `geneticist` at their organizations |
| `clin_administrator`, `clin_importer`, `clin_approver`, `clin_qlin_me` | 7, 4, 1, 7 | Not mapped. `tenant_admin` and `data_manager` are granted by hand |

### Organization mapping

- The 12 legacy organization codes (6 hospitals, 6 laboratories) are the RADIANT codes of the `qlin` tenant, unchanged.
- One legacy group is named `LDM-CUSM`. It maps to the organization `LDM-CHUSM`.
- `CQGC` gets no user.

### Login after the migration

- The import creates the Keycloak account with the legacy email and no password. The RADIANT realm refuses a Microsoft login that matches no existing account, so the account must exist first.
- **127 users** have an email of the Microsoft tenant: they log in with the Microsoft button. All 163 use a password today, so this is their first Microsoft login.
- **36 users** have another email domain: they set a password with "Forgot password".
- "Forgot password" works for every account. The communication gives both routes to everyone.
- Passwords are not migrated.

### portal (backend)

- **Integration point:** `POST /{tenant}/users`, one call per user, with the operator's own token (`can_manage_user`). It creates the Keycloak account, the StarRocks login, the grants and the Ranger membership. No code change.
- **Re-run:** a user already in the tenant answers 409 and is skipped. A user left half created is completed.

### Scripts (local, not committed)

- **Export:** reads the legacy accounts with their groups, roles and login method. Read-only.
- **Build:** applies the rules above and writes the import list and the list of accounts left out.
- **Import:** validates every row against the tenant (organization exists, role exists, email, duplicates), then creates the users. Dry-run by default. Writes one report per run.
- They print counts only.

## Modules impacted

| Module | Area | Kind of change |
|---|---|---|
| hub | this spec | new |
| portal, etl, mcp, infra | none | — |

## Tasks

| # | Task | Component | Content | Depends on | Shippable alone? |
|---|---|---|---|---|---|
| 1 | Migration rules | hub | This spec, validated with the QLIN team | — | yes |

No UX or Labels task: no interface change. The import itself is an operation (see the rollout order).

## Merge and rollout order

1. Validate the rules of this spec and the import list with the QLIN team (RAD-305). Skipped: users get access nobody agreed to.
2. Create the missing organizations in the admin console (RAD-306). QA lacks `LDM-CHUSM`. Skipped: the dry-run refuses the rows that use it.
3. QA: dry-run, then import of a few users, then login and PII checks, then the full list (RAD-307).
4. Prod: dry-run, then import, then the report goes to the QLIN team.
5. Communication to the users: the two login routes.
6. Remove the read permission given to the legacy service account for the export, and delete the local lists once the report is accepted.

No backfill, no feature flag. The import can run again at any time.

## Test strategy

### QA (manual)

- **AC1 (every user can log in):** one Microsoft-domain user logs in with the Microsoft button. One user of another domain sets a password with "Forgot password" and logs in.
- **AC2 (role and organization):** the import report shows no failed row, and the tenant user list holds every migrated user with `geneticist` at the expected organizations.
- **AC4 (PII per organization):** one migrated user reads names and identifiers for a patient of their organization, and masked values for a patient of another one. Same check for a user with two organizations.
- **AC5 (validated lists):** the QLIN team signs off the import list and the list of accounts left out.

## Risks and coverage

| Risk (from the story) | How it is covered |
|---|---|
| A prescriber saw patient names system-wide in QLIN | Names are limited to the user's organizations and to cases their laboratory diagnoses. Accepted by the story (AC4) |
| The prescriber role has no RADIANT equivalent until the case form exists | Prescribers get `geneticist` at their organizations, so they are not blocked (see open questions for the over-grant) |
| A user cannot log in after the migration | Account created with the legacy email. Two login routes, both tested on QA before prod |
| A user is migrated with the wrong organization | Three sources compared (sheet, user list as code, live groups). Dry-run refuses an unknown organization |

## Frozen scope

### all

- No change to the portal, the ETL, the MCP or the infrastructure.
- No bulk endpoint and no file upload in the admin console.
- No password migration.
- No prescriber role, no custom role (see open questions).
- No update of a user who is already in the tenant: the import skips them.
- No removal of legacy accounts.
- The 48 accounts left out are created by hand in the admin console if they need access.

## Open questions

### story / product

- **`geneticist` for the 80 prescriber-only users:** it lets them interpret, comment, flag, download files and edit cases at their organizations, which QLIN did not. Options:
  - keep `geneticist` for everyone (current rule): no extra work, wider rights;
  - a custom role holding only `can_read_pii` for these 80: one role to create in the admin console, one more column in the import list.
- **Microsoft login never used by the 127 users:** it works only if the Microsoft account email equals the legacy email. To check on QA with real users before prod. "Forgot password" stays the fallback.
- **Three practitioner ids are shared by several legacy accounts:** each account becomes a RADIANT user. To review in the import list.
- **Real practitioner accounts on QA:** import the full list on QA, or only a subset.

## Approval

| | |
|---|---|
| Reviewer | to assign |
| Date | … |
| Plan review duration | … min |
| Decision | … |
| Comments | … |

## Deviation log

| Date | Need found | Option A: new ticket (link) | Option B: re-approval (by whom, when) |
|---|---|---|---|
| … | … | … | … |
