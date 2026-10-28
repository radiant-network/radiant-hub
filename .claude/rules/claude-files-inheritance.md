# Claude files: hub and modules

The hub's `CLAUDE.md`, `.claude/rules/` and `.claude/skills/` apply to every module. A module's own Claude files add to them for that module.

- **Before you change files in a module,** read the `CLAUDE.md` and the `.claude/rules/` of each folder from the module root down to those files (e.g. `portal/`, then `portal/backend/`). Claude Code loads them on demand, but not always in a subagent or through a symlink.
- **A lower file adds to the files above it. It does not replace them.** Apply all of them. When two disagree, the one closest to the code wins: `portal/backend/` over `portal/`, `portal/` over the hub.
- **Skills with the same name:** when you work on a module's files, invoke them from the highest level to the lowest. Apply all of them, with the same precedence.