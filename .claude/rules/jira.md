# Jira

- **Target:** site `ferlab-crsj.atlassian.net`, cloudId `eab895fe-1598-42e6-8ca8-eaa6fa501dfe`, project `RAD`. Tickets created before 2026-10-01 live in `SJRA` on `d3b.atlassian.net` and keep that key. Use an Atlassian MCP server that can reach `ferlab-crsj` (the `plugin:engineering:atlassian` server if the claude.ai connector only has d3b).
- **Read a ticket in full:** request the `comment`, `issuelinks` and `subtasks` fields and `expand: changelog`. They hold the reproduction details, the QA defects and the open questions.
- **Detect a QA bounce:** a move to `QA` later reverted to an in-progress status means that QA rejected the work. Read the comments posted after it, the `Defect` subtasks and the linked defects, and summarise the QA findings before you propose anything.
- **Each write needs its own go-ahead:** create, edit, comment, transition, link. Show the full content first (summary, type, components, description, or the comment body) and wait. Silence or an ambiguous answer is not a go-ahead.
- **Before you create a ticket,** look for one that already covers the need (a RAD ticket, or a spec in `docs/features/`). Complete it rather than open a second one.
- **Each new ticket has at least one component:** `api` (portal backend), `ui` (portal frontend), `etl`, `mcp`, `nextflow`, `keycloak`. Propose them from the modules impacted and let the user adjust. If the list looks stale, check `allowedValues` of `components` with `getJiraIssueTypeMetaWithFields`.
- Write in English.
