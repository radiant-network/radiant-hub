---
name: jira-story
description: Write a Radiant user story with the team's story template (intent, acceptance criteria, out of scope, business risks, classification, reviewer, Definition of Ready) and create it in the RAD Jira project. Use when the user wants to write, groom, draft or create a story or ticket in Jira.
---

# Jira story

The template is `docs/stories/story-template.md`. Read it first: its sections and wording are the source of truth, this skill only says how to fill it and create the ticket.

## Jira target

Issue type `Story`. Site, project, MCP server and components: see the `jira` rule.

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
- **Components:** see the `jira` rule.

If the scope clearly exceeds one implementation plan, say so and propose splitting into several stories.

Read the module code only when it helps write sharper criteria or detect impacted modules. Don't design the solution here: that belongs in the implementation plan.

## 2. Definition of Ready

Check each item of the template's Definition of Ready against the draft. List the ones that fail. A story can still be created as a draft, but say plainly that it is not ready for the sprint.

## 3. Preview and confirm

Show the full description (Markdown, template section order, the "Definition of Ready" checklist with the boxes that pass checked), the summary and the components. Don't include the template's instructions (the italic guidance lines), only the filled content.

Formatting in the description:

- **Acceptance criteria:** one checkbox per criterion, no bullet list. In the preview write them as `- [ ]` lines. In Jira they must be an ADF `taskList` (see step 4): the Markdown converter does not create checkboxes, it turns `- [ ]` into a bullet with a literal `[ ]`.
- **Business risks and Definition of Ready:** plain bullets prefixed with ✅ (applies / passes) or ⬜ (does not), not checkboxes.

## 4. Create

Call `createJiraIssue` with:

- `cloudId`, `projectKey: "RAD"`, `issueTypeName: "Story"`
- `summary`: the title
- `description`: the approved content as an ADF document, `contentFormat: "adf"`. Headings are `heading` (level 2), lists are `bulletList`. The acceptance criteria are a `taskList` (`attrs.localId`, e.g. `"ac"`) of `taskItem`s (`attrs: {"localId": "ac-1", "state": "TODO"}`), each holding inline `text` nodes directly, with no `paragraph`. Bold is a `strong` mark.
- `parent`: the epic key, if the user gave one
- `additional_fields`: `{"components": [{"name": "api"}, {"name": "ui"}]}` with the approved components.

Keep the reviewer in the description. Don't set them as assignee unless the user asks.

Give the user the ticket key and link (`https://ferlab-crsj.atlassian.net/browse/RAD-xxxx`).

## 5. Next step

- **Small:** nothing else.
- **Standard / Complex:** an implementation plan is required before coding. Offer to start it from `docs/features/0000-template.md`. When the story spans several modules, use the `cross-module-feature` skill with the new ticket key.
