# Bash commands

Permissions match the start of a command, and each segment of `|`, `&&`, `;` or a redirection on its own. Shape each command so that an allow-list entry can match it.

- **`<tool> <subcommand> <flags>`:** `npm run build --silent`, not `npm --silent run build`.
- **Work in a module from inside it:** `cd <module>` in its own call, then the bare command (`cd portal/backend`, then `make test`). Do not use `git -C`, `make -C` or `gh --repo` on a module that is checked out.
- **Guard each write in the same command.** The shell's working directory can reset to the hub root between calls, and the hub is a git repo too. Before a command that changes a repo or GitHub (commit, push, branch creation or deletion, rebase, reset, `gh pr create|edit|merge`), check the directory, and the branch when the command acts on it: `[ "$(pwd)" = "<abs path>" ] && [ "$(git branch --show-current)" = "<branch>" ] && git push origin <branch>`. A `pwd` in a separate call does not protect: the reset happens between calls.
- **Otherwise, one command per call:** no `|`, `&&`, `;` or `$(...)`, except in the guard above and to load a secret inside the command that uses it (see the `confidentiality` rule). Pass a value from one call's output to the next.
- **Long output:** narrow the command (`git log -n 20`) or read the file with the Read tool. Do not pipe it to `grep` or `tail`.
