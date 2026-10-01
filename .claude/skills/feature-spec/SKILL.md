---
name: feature-spec
description: Write or rework a cross-module feature spec in docs/features/ from a ticket (Jira/Linear text, story, acceptance criteria). Explores the modules, lists the options, records the decisions, and grounds every claim in project files or online docs. Use when the user pastes a work item and asks to "design the feature", "write the spec", "document the options", or to rework an existing docs/features/*.md. Step 1 ("Spec") of the cross-module-feature skill.
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
  7. Linked PRs (etl, portal, mcp)
- The header has only **Status** and **Branch**.
- Put extra content in **appendices after Linked PRs**:
  - Appendix A: options considered.
  - Appendix B: risks.
  - Appendix C: references.
- Put the content that the template has no section for here:
  - The target flow and the integration point go in **Context**. The integration point is one or two sentences, with a `path:line` reference, that name the existing code the feature plugs into.
  - The decision log goes at the end of **Appendix A**, after the options.
  - Diagrams, the data model and the API go in the matching **Per-module plan** subsection.
- Keep the template's intro sentence in **Contract changes**.
- **Merge and rollout order** has two parts: numbered steps, then notes. The notes cover migrations, backfills, feature flags, and what breaks if the order is not respected.
- Check the result:

  ```sh
  diff <(grep -E '^## ' docs/features/0000-template.md) <(grep -E '^## ' docs/features/<spec>.md)
  ```

  Only the appendices may differ.

## 4. Write for humans

- **Use tables with bulleted lists inside the cells.**
  - This applies to the structured content: decisions, modules impacted, contract changes, API routes, DAG params and tasks, tests, rollout notes, open questions, risks and options.
  - In a cell, write `• item<br>`, and `&nbsp;&nbsp;◦ sub-item<br>` for sub-items. Do not write prose in a cell.
  - Use the template's columns where it has a table, for example `| Module | Impact |` and `| Contract | Change | Writer | Readers |`.
  - Keep as plain lists only: the numbered rollout steps, Linked PRs and References.
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
  - rollout order.
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
- List the online sources in Appendix C. Add the date when you checked the project files.

## 6. Record the decisions

- When the user decides, add a row to the **Decision log** (`### Decision log`, at the end of Appendix A, after the options): `| Date | Decision | Consequence |`.
  - Do not put the decisions at the top of Context. Without the options, readers cannot understand them. Context has only a one-line link to the log.
- Mark the chosen option in Appendix A (✅).
- Remove the decided items from Open questions.
- Update all the sections that depend on the decision:
  - modules impacted;
  - contract changes;
  - per-module plan;
  - rollout order (a decision can reverse the usual ETL → portal order);
  - risks.
- When the user rejects a sub-option, remove everything that belongs to it: diagrams, table columns, candidate rows, and references that only it used.

## 7. Before each edit

- Read the file again before you edit it. The user can rename or change it between turns. If the path is gone, find the new file with `ls docs/features/`.
- Check that the ticket ID is the same in the file name, the title and the branch. Ask the user before you change any of them.
- Look for conventions that the ID breaks. For example, the portal's CommitLint requires `SJRA-###`.

## 8. Report

- Give a short summary in chat: what changed, decisions recorded, claims corrected, and the points that are still open or not verified.
- Do not paste the document into chat.
- Next step, after the user approves: run the `cross-module-feature` skill from step 2 (contracts).
