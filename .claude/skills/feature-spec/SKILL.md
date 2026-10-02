---
name: feature-spec
description: Write or rework a cross-module feature spec in docs/features/ from a ticket (Jira/Linear text, story, acceptance criteria). Explores the modules, lists the options, records the decisions, grounds every claim in project files or online docs, and breaks the work into Jira subtasks (one PR each). Use when the user pastes a work item and asks to "design the feature", "write the spec", "document the options", or to rework an existing docs/features/*.md. Step 1 ("Spec") of the cross-module-feature skill.
---

# Feature spec

The output is one Markdown file in `docs/features/`. It follows `docs/features/0000-template.md`. It is written for humans who review it before any code is written.

Do not write code. Do not create branches. Do not edit `docs/contracts/*` until the user has made the decisions. Do not commit unless the user asks.

## 1. Collect the facts

- Run `make status`. Do not assume that a module is checked out.
- Read the `CLAUDE.md` of each module that the feature can touch.
- Read `docs/architecture/overview.md` and `docs/contracts/*.md`.
- Search for existing work first. Find the code that already does part of the feature, and the data models that already exist but are not used. Do the search with `grep`.
- If the scope is not clear, use up to 3 Explore agents in parallel, one per module (for example etl, portal backend, portal frontend + mcp). Ask each agent for `file:line` and short quotes, not for opinions.
- **Before you cite an agent result, check it yourself** (`sed -n`, `grep`). Agents give wrong paths and wrong line numbers.

## 2. First draft: the options, not a decision

- The first version lists the options. It does not choose one, unless the user already decided.
- Split the design into independent axes. For example: storage and ingestion, client, filter mechanics, facet values, file format, update semantics, validation, scope.
- For each option, give the behaviour, the modules it touches, pros and cons, and the effort (S/M/L).
- You can mark one option as "preliminary lean". Say why.
- Put the open choices in **Open questions**, each with its proposed option.

## 3. Follow the template exactly

- Use the template sections, with the same names, in the same order:
  1. Context
  2. Modules impacted
  3. Contract changes
  4. Per-module plan (`### etl`, `### portal`, `### mcp`)
  5. Merge and rollout order
  6. Open questions
- The header has only **Status** and **Branches** (`one per subtask, feat/<KEY>-<slug>`, with a link to the task breakdown).
- **No appendices.** They make the doc too heavy. Do not add "Risks", "References" or "Feasibility review" appendices.
- Before the decisions, the options go in a temporary `## Options considered` section after Open questions. Remove it when the user decides (see section 6).
- Put the content that the template has no section for here:
  - The target flow and the integration point go in **Context**. The integration point is one or two sentences, with a `path:line` reference, that name the existing code the feature plugs into.
  - The decisions table goes in **Context** (see section 6).
  - Diagrams, the data model and the API go in the matching **Per-module plan** subsection.
  - A risk goes in the row of the component that it affects (for example the MV table of the portal plan), or in the rollout notes. There is no separate risks table.
- Keep the template's intro sentence in **Contract changes**.
- **Merge and rollout order** has four parts:
  1. a Mermaid `gantt` chart of the task dependencies (`after a b`). The bars show the order, not durations; hide the axis dates (`axisFormat " "`);
  2. a steps table: `| Step | Module | Prerequisites | Content |`, bullets in the cells;
  3. a notes table. The notes cover migrations, backfills, feature flags, the checks and operations (version check, deploy, QA checks), and what breaks if the order is not respected;
  4. `### Task breakdown` (see section 7).
- Check the result:

  ```sh
  diff <(grep -E '^## ' docs/features/0000-template.md) <(grep -E '^## ' docs/features/<spec>.md)
  ```

  Only the temporary `## Options considered` may differ, before the decisions.

## 4. Write for humans

- **Use tables with bulleted lists inside the cells.**
  - This applies to the structured content: decisions, modules impacted, contract changes, API routes, DAG params and tasks, tests, rollout notes, task breakdown, open questions and options.
  - In a cell, write `• item<br>`, and `&nbsp;&nbsp;◦ sub-item<br>` for sub-items. Do not write prose in a cell.
  - Use the template's columns where it has a table, for example `| Module | Impact |` and `| Contract | Change | Writer | Readers |`.
  - The rollout steps are a table, not a numbered list (see section 3).
  - Check that every row of a table has the same number of columns. A `|` inside a cell breaks the table.
- **Do not add a "facts" dump table.** Cite each fact inline, where the doc uses it.
- Be concise. Use short sentences, active voice, and one idea per bullet (ASD-STE100 style).
- Use Mermaid diagrams for flows that cross systems. Useful diagrams:
  - current state: only when the feature changes that part of the system. Do not draw the parts that the feature does not touch;
  - target flow;
  - write/load sequence (`sequenceDiagram`, with `alt` for errors);
  - read/query sequence;
  - data model (`erDiagram`);
  - DR or replay;
  - rollout order (`gantt`);
  - subtask dependencies (`flowchart LR`, one subgraph per module).
- Validate each diagram before you write it into the doc. Extract the blocks to the scratchpad, then run:

  ```sh
  npx -y @mermaid-js/mermaid-cli -i dN.mmd -o dN.svg
  ```

## 5. Ground every claim

- Each fact about the code has a `path:line` reference that you checked.
- Each claim about an external tool, standard or service has a link to its official documentation. Examples: an RFC, AWS docs, StarRocks docs, uv/pip docs.
- For genomics claims, cite a paper with its DOI or PubMed ID.
- If you cannot verify a claim, say so in the doc ("not verified", "check"). Do not guess.
- When the user asks for a review, check every claim again. Correct the claims that are wrong, and add the missing references.
- Cite each online source inline, where the doc uses it. There is no reference list.

## 6. Record the decisions

- When the user decides, add a row to the **Decisions** table in **Context**: `| Topic | Decision | Alternative not chosen |`, with the date in the table title (for example `**Decisions (2026-10-01):**`).
  - `Topic` is a plain name (Storage, Read path, Facet values, …), not an option code.
  - The "Alternative not chosen" column keeps the fallback, so that readers understand the decision without the options (for example "Federated view. It is the fallback.").
- When all the decisions are made, remove the temporary `## Options considered` section. Then remove the option codes (A4, B4, H2, …) from the whole doc: readers can no longer find them. Write the topic name or the plain words. Check:

  ```sh
  grep -n -o -E '\b[A-H][0-9](-[a-z])?\b' docs/features/<spec>.md
  ```
- Remove the decided items from Open questions.
- Update all the sections that depend on the decision:
  - modules impacted;
  - contract changes;
  - per-module plan;
  - rollout order (a decision can reverse the usual ETL → portal order);
  - task breakdown.
- When the user rejects a sub-option, remove everything that belongs to it: diagrams, table columns, candidate rows, and references that only it used.

## 7. Task breakdown

- Each row is **one Jira subtask and one PR**. List only the changes to code, IaC and docs (for example `docs/contracts/` in the hub).
- Do not list the checks or the operations (version check, deploy, `refresh-tenants`, QA checks, first load). They go in the rollout steps and notes.
- Start with a `flowchart LR` of the dependencies, one subgraph per module (infra, portal backend, etl, …).
- Table columns: `| ID | Jira | Subtask | Repo | Scope | Depends on | Done when | PR |`.
  - `ID`: `ST1`, `ST2`, … After a change, renumber and update every reference (diagram, "Depends on", scope, merge-order note).
  - `Jira` and `PR`: `—`. The user fills them in.
  - `Done when`: a code result (tests pass, Terraform defines X, clients regenerated). Not a runtime check.
  - If a subtask can need no code in one environment (for example no IAM change in QA), say so in its scope.
- Add a table `| Item | Rule |` for branches, commits and PRs:
  - Branch: `feat/<KEY>-<slug>`, with the key **in capitals**. Jira links a branch only when its name includes the key, and the key is case-sensitive ([Reference work items in your development work](https://support.atlassian.com/jira-software-cloud/docs/reference-issues-in-your-development-work/)).
  - Commit: the subtask key in each commit. In `portal`: `type(scope): RAD-42 message` (see section 8).
  - PR: the subtask key in the title. The body links the spec, the parent ticket and the PRs of the dependencies.
  - Merge order: follow "Depends on". Say which subtasks change the same files and must rebase.
  - Hub rule: the hub `CLAUDE.md` asks for one PR per repo on one shared branch. Say that the breakdown uses one PR per subtask instead.

## 8. Before each edit

- Read the file again before you edit it. The user can rename or change it between turns. If the path is gone, find the new file with `ls docs/features/`.
- Check that the ticket ID is the same in the file name, the title and the branch. Ask the user before you change any of them.
- Look for conventions that the ID breaks:
  - the portal's CommitLint requires a key that matches `^\w+-\d+$` in `type(scope): KEY-123 message` (`portal/frontend/commitlint.config.cjs`);
  - Jira does not link a lowercase key (`rad-11`) in a branch name or a commit.

## 9. Report

- Give a short summary in chat: what changed, decisions recorded, claims corrected, and the points that are still open or not verified.
- Do not paste the document into chat.
- Next step, after the user approves: run the `cross-module-feature` skill from step 2 (contracts).
