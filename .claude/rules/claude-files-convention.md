# Authoring CLAUDE.md, rules, skills and agents

Claude loads `CLAUDE.md` and `.claude/rules/` on every turn, and a skill or agent prompt on every use. The text is written once and read in every session. Write the strict minimum.

- **Add a line only if Claude would act differently without it.** Do not write what the code shows, what a convention implies, or what one `grep` finds.
- **Do not repeat.** No intro, no recap. When a point lives in another file, name that file (`see the impact skill`). Do not copy it.
- **Give the reason in one short clause,** and only when it prevents a mistake.
- **Use a table or bullets for parallel cases.** Give one example, or none.
- **Edit, do not append.** For a new case, rewrite the sentence so that it covers the case. Do not add a caveat under it.
- **Delete what became false or unused** in the same change.
- **Write each new point as high as it holds.** It goes in the hub, unless it is specific to one module. A module keeps only what is specific to it, in the highest folder where it holds. Points specific to `bioinfo/*` and `infra/*` also go in the hub, which does not own those repos. Agents and settings go in the hub only: Claude Code ignores a module's `.claude/agents/` and `.claude/settings.json`. A personal skill, agent or rule takes a `local-` prefix: git ignores it.
- **Scope a rule or a skill to the files it concerns** with a `paths:` list of globs (e.g. `paths: ["portal/backend/**/*.go"]`). A scoped file loads only when Claude reads, writes or edits a matching file. So leave it unscoped when it must apply before any file is read, or to an action run through Bash (commit, push). Rule globs are relative to the folder that holds its `.claude/`, and skill globs to the session's working directory (the hub root). Agents have no `paths:`.
- **Keep team knowledge in versioned files.** A fact that a teammate or the next session needs (a module trap, a command, a convention) goes in a `CLAUDE.md`, a rule or a skill, not in your auto-memory, which stays on one machine.

A file that grew past its use is a bug: compress it.
