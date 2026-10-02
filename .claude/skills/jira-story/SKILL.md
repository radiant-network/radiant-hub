---
name: jira-story
description: Write a Radiant user story with the team's story template (intent, acceptance criteria, out of scope, business risks, classification, reviewer, Definition of Ready) and create it in the RAD Jira project. Use when the user wants to write, groom, draft or create a story or ticket in Jira.
---

# Jira story

The template is `docs/stories/story-template.md`. Read it first: its sections and wording are the source of truth, this skill only says how to fill it and create the ticket.

## Jira target

- Site: `ferlab-crsj.atlassian.net`, cloudId `eab895fe-1598-42e6-8ca8-eaa6fa501dfe`
- Project: `RAD` (replaces `SJRA` on d3b.atlassian.net since 2026-10-01; older tickets keep their SJRA key)
- Issue type: `Story`. Jira itself only requires the summary, but the team requires **at least one component**.
- Components (team rule, at least one): `api` (portal backend), `ui` (portal frontend), `etl`, `mcp`, `nextflow`, `keycloak`. The list may change: when in doubt, check `allowedValues` of `components` with `getJiraIssueTypeMetaWithFields` (project `RAD`, issue type `Story`, `requiredFieldsOnly: false`).

Use the Atlassian MCP tools (`createJiraIssue`, `searchJiraIssuesUsingJql`, `lookupJiraAccountId`, `getJiraIssue`) of a server that has access to `ferlab-crsj` (the `plugin:engineering:atlassian` server, `mcp__plugin_engineering_atlassian__*`, if the claude.ai connector only has d3b). Load them with ToolSearch if they are deferred.

## 1. Gather

Start from whatever the user gave you (a sentence, notes, a parent epic, an existing ticket). Ask only for what is missing, grouped in one round where possible:

- **Title:** a verb and an object.
- **Intent:** role, capability, observable benefit.
- **Context:** where the need comes from, known constraints, links (parent epic, docs).
- **Acceptance criteria:** Given / When / Then, each one verifiable. Push back on vague adjectives ("fast", "user-friendly") and propose a measurable version.
- **Out of scope:** required. Propose candidates from the context if the user has none.
- **Business risks:** check the ones that apply, one line of detail each.
- **Class:** Small / Standard / Complex, using the template's criteria. Propose one and say why. More than one module touched (etl, portal, mcp) is a sign of Complex.
- **Assigned reviewer:** a name.
- **Components:** at least one. Propose them from the impacted modules (portal backend → `api`, portal frontend → `ui`, `etl`, `mcp`, `nextflow`, `keycloak`) and let the user adjust.

If the scope clearly exceeds one implementation plan, say so and propose splitting into several stories.

Read the module code only when it helps write sharper criteria or detect impacted modules. Don't design the solution here: that belongs in the implementation plan.

## 2. Definition of Ready

Check each item of the template's Definition of Ready against the draft. List the ones that fail. A story can still be created as a draft, but say plainly that it is not ready for the sprint.

## 3. Preview and confirm

Show the full description (Markdown, template section order, the "Definition of Ready" checklist with the boxes that pass checked), the summary and the components. Don't include the template's instructions (the italic guidance lines), only the filled content. **Create nothing until the user approves the preview.**

## 4. Create

Call `createJiraIssue` with:

- `cloudId`, `projectKey: "RAD"`, `issueTypeName: "Story"`
- `summary`: the title
- `description`: the approved Markdown, `contentFormat: "markdown"`
- `parent`: the epic key, if the user gave one
- `additional_fields`: `{"components": [{"name": "api"}, {"name": "ui"}]}` with the approved components. Never create a story without one.

Keep the reviewer in the description. Don't set them as assignee unless the user asks.

Give the user the ticket key and link (`https://ferlab-crsj.atlassian.net/browse/RAD-xxxx`).

## 5. Next step

- **Small:** nothing else.
- **Standard / Complex:** an implementation plan is required before coding. Offer to start it from `docs/features/0000-template.md`. When the story spans several modules, use the `cross-module-feature` skill with the new ticket key.
