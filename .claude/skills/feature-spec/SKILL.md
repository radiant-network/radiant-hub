---
name: feature-spec
description: Write or rework a cross-module feature spec in docs/features/ from a ticket (Jira/Linear text, story, acceptance criteria). Explores the modules, lists the options, records the decisions, grounds every claim in project files or online docs, and splits the work into tasks (one PR each). Use when the user pastes a work item and asks to "design the feature", "write the spec", "document the options", or to rework an existing docs/features/*.md. Step 1 ("Spec") of the cross-module-feature skill.
---

# Feature spec

The output is one Markdown file in `docs/features/`. It follows `docs/features/0000-template.md`. A human reviewer approves it in **fifteen minutes at most**, before any code is written. Write for that reader.

**Level of detail:** use `docs/features/RAD-15-cosmic-cmc-snv.md` as the reference (about 110 lines). A spec says *what* changes and *why*. The *how* (SQL, Go types, DAG task internals, error codes per route) comes with the code and is reviewed in the PRs.

Do not write code. Do not create branches. Do not edit `docs/contracts/*` until the user has made the decisions. Do not commit unless the user asks.

## 1. Collect the facts

- Run `make status`. Do not assume that a module is checked out.
- Read the `CLAUDE.md` of each module that the feature can touch.
- Read `docs/architecture/overview.md` and `docs/contracts/*.md`.
- Search for existing work first: the code that already does part of the feature, and the data models that exist but are not used. Use `grep`.
- If the scope is not clear, use up to 3 Explore agents in parallel, one per module. Ask each agent for `file:line` and short quotes, not for opinions.
- **Before you cite an agent result, check it yourself** (`sed -n`, `grep`). Agents give wrong paths and wrong line numbers.
- You research in depth. The doc keeps only the conclusions. Do not paste the research into the doc.
- **Reuse before you add.** Before you propose a new table, column, endpoint, permission or role, look for an existing one. Then check that it really fits:
  - its scope (for example a permission that applies to one organization, or to the whole tenant);
  - its constraints (required columns, keys, unique rules) against the data you plan to write;
  - its other readers and writers. A new writer can change what they show.
- **Copy the existing mechanism exactly.** When the feature adds something that already exists in another form (a new filter next to existing filters, a new import next to existing imports), read how the existing one works end to end: data model, API field, UI config, labels. Use the same mechanism. Do not invent a parallel one (an extra endpoint, a label map, a new naming rule).
- **Every new component needs a consumer.** Drop an endpoint, column or table that nothing in the story reads. List it in **Frozen scope**.
- **Check the access path of each read and write.** For each call to a data store, name the identity that runs it:
  - the service's own privileged connection (schema changes, refreshes, provisioning, reads of public reference data);
  - or the caller's identity. Then check every layer that authorizes the caller (for example the API permission **and** the data store's own access rules). One layer does not imply the other.
  - When a feature makes an account do something it never did before (for example the first data-store read by a service account), check that the account is set up for it in every environment. Put the setup in the rollout order.

## 2. First draft: the options, not a decision

- The first version lists the options. It does not choose one, unless the user already decided.
- Split the design into independent axes (for example storage, client, read path, file format, validation, scope).
- For each option: behaviour, modules touched, main pro and con, effort (S/M/L). One short table row per option.
- You can mark one option as "preliminary lean". Say why in one line.
- Put the options in a temporary `## Options considered` section after **Open questions**. Remove it when the user decides (see section 6).
- Design defaults (use them unless the user says otherwise):
  - put validation and parsing in the component that owns the data. Clients send the raw input, so a later client (a UI, a script) can use the same entry point;
  - keep pipeline jobs thin: they move the input and call the owner;
  - keep the first version small: leave out update, delete and recovery paths unless the story asks for them, and list them in **Frozen scope**;
  - match the HTTP method to the semantics: `POST` creates, `PUT` replaces a whole resource or set (safe to retry), `PATCH` changes part of it;
  - when an operation replaces a whole set, check what else lives in the same store and must not be deleted (the delete scope), and make the input carry the complete set (for example one file per run);
  - keep an existing behaviour that has a known quirk. Do not fix it in passing: note it in **Frozen scope** ("a separate ticket will fix it if needed").

## 3. Follow the template exactly

- Use the template sections, with the same names, in the same order. Check:

  ```sh
  diff <(grep -E '^## ' docs/features/0000-template.md) <(grep -E '^## ' docs/features/<spec>.md)
  ```

  Only the temporary `## Options considered` may differ, before the decisions.
- Remove the template's guidance text (the quotes and the explanation paragraphs under each heading). Keep only your content.
- **No appendices, no Linked PRs, no extra sections.** Content that the template has no section for usually does not belong in the spec.
- Section by section:
  - **Story:** link, reviewer, status, one branch `feat/rad-xxxx-<slug>` for all repos.
  - **Chosen approach:** a one-line **Summary**, then a module table (see section 4). Per module: the approach and the integration point (the existing component it plugs into, by name). No rejected alternatives section.
  - **Modules impacted:** one row per module. The areas (components, not file paths) in one cell, comma-separated.
  - **Tasks:** the template table. One task = one intent = usually one PR. Code, IaC and docs only. Operations (deploy, scripts to run, account setup, QA checks, first load) go in the rollout order. Add a Labels or UX task when the story needs one, or say why not in one line.
  - **Contract changes:** one row per boundary, with the migration and compatibility note.
  - **Pipeline job input:** when the story adds a job, give its run config in the module row of **Chosen approach**: each param with its type, whether it is required, its use, and one example. Follow the param names of the existing jobs.
  - **Merge and rollout order:** a short numbered list, as in the template. For each step: what, and what breaks if it is skipped. Then one line on backfill and feature flags.
  - **Test strategy:** module table `| Module | How the story is proven |`. Tag each bullet with the AC it proves. Add a `QA (manual)` row for the checks by hand.
  - **Risks and coverage:** one row per business risk of the story. If the story checks none, say so in one line.
  - **Frozen scope:** module table `| Module | Not covered |`. Use an `all` row for cross-module items.
  - **Open questions:** module table `| Module | Questions |`, each question with its proposal when you have one. Use a `story / product` row for questions that no module owns.

## 4. Write for humans

- Short sentences, active voice, one idea per sentence (ASD-STE100 style).
- **Scope lists by module, in tables.** Prefer a two-column table over a bullet list: the left column is the module (`portal (backend)`, `etl`, `portal (frontend)`, `mcp`, `infra`), the right column holds the bullets for that module.
  - In a cell, write `• item<br>`, and `&nbsp;&nbsp;◦ sub-item<br>` for a sub-item. Bold the label at the start of a bullet (`• **Storage:** …`).
  - Omit a module row when it has nothing to say.
  - Check that every row has the same number of columns. A `|` inside a cell breaks the table.
- Each bullet is one or two short sentences.
- **Do not include:**
  - references to code files: no file paths, no `path:line`, no function, type or variable names. Name the component in plain words instead (for example "the existing gene search", not the function name and its file). Keep the names that are part of a contract: tables, columns, endpoints, query fields, permissions, job names, config flags;
  - SQL, Go, Python or DDL snippets;
  - per-route error-code lists, DAG param tables, task-by-task behaviour;
  - source-code analysis of third-party tools;
  - test lists (say how the AC is proven, not each test case);
  - "facts" dump tables;
  - negative justifications ("X cannot be used because …"). Write what the plan does, not what it does not use;
  - concerns that do not matter at the real scale (for example the cost of reading a small table).
- Diagrams are optional. Add at most one, only when a flow across systems is hard to follow in words. Validate it before you write it:

  ```sh
  npx -y @mermaid-js/mermaid-cli -i d1.mmd -o d1.svg
  ```
- Target length: about 100 to 150 lines. If the doc is longer, move the detail to the PRs or to module docs (`etl/design/…`).

## 5. Ground every claim

- Check each fact about the code in the code itself (`grep`, `sed -n`) before you write it. Do not put the `path:line` in the doc (see section 4). Give it in chat if the user asks for the source.
- Each claim about an external tool, standard or service has a link to its official documentation, inline.
- For genomics claims, cite a paper with its DOI or PubMed ID.
- If you cannot verify a claim, say so ("not verified", "check on QA"). Do not guess.
- When the user asks for a review, check every claim again and correct the wrong ones.
- When the user says a claim is wrong, check it again in the source before you agree or disagree: the project code, or the upstream source at the version that is deployed. Give the evidence in chat. Then let the user decide what the doc says.

## 6. Record the decisions

- When the user decides, write the decision into the row of the module in **Chosen approach**. Drop the options that are not chosen; mention one only when it stays a fallback ("It stays the fallback if …").
- When all the decisions are made, remove `## Options considered` and every option code (A4, B1, …). Check:

  ```sh
  grep -n -o -E '\b[A-H][0-9](-[a-z])?\b' docs/features/<spec>.md
  ```
- Remove the decided items from **Open questions**.
- When the user does not know yet, do not choose for them. In **Chosen approach**, write "not decided yet (see open questions)". In **Open questions**, list the options as sub-bullets, each with its cost in a few words. Do not ask the same question again in chat.
- Update the sections that depend on the decision: modules impacted, tasks, contract changes, rollout order (a decision can reverse the usual merge order).
- When the user rejects a sub-option, remove everything that belongs to it.

## 7. Before each edit

- Read the file again before you edit it. The user can change it between turns. If the path is gone, find it with `ls docs/features/`.
- Check that the ticket ID is the same in the file name, the title and the branch. Ask the user before you change any of them.
- Look for conventions that the ID breaks: the portal's CommitLint requires `type(scope): KEY-123 message` with a key that matches `^\w+-\d+$` (`portal/frontend/commitlint.config.cjs`).

## 8. Report

- Give a short summary in chat: what changed, decisions recorded, claims corrected, points still open or not verified.
- Do not paste the document into chat.
- Next step, after the user approves: run the `cross-module-feature` skill from step 2 (contracts).
