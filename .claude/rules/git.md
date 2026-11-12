# Git

- **Branch:** `feat/rad-xxxx-<slug>` for a story or a task, `fix/rad-xxxx-<slug>` for a bug, in lowercase. Choose it before the first push: GitHub cannot change the branch of a PR, so a rename means a new PR.
- **Work in the module's own checkout,** switched to the task's branch, so that the user sees the files in the IDE. No `git worktree` unless the user asks. When the checkout is on another branch or has uncommitted changes, ask before you switch.
- **Commit message:** `<type>(<scope>): RAD-XXXX <subject>`, the scope optional. Write the subject in lowercase, with no `,`, `(`, `)` or `:`: the portal's commitlint rejects them with misleading errors. One line when it is enough, otherwise one sentence and a short list of the changes. No `Co-Authored-By` trailer.
- **Each write needs its own go-ahead:** `git commit` (and `--amend`), `git push`, `gh pr create|edit|merge`. Approving the code is not approving the commit, the commit not the push, one push not the next. Silence or an ambiguous answer is not a go-ahead.
- **Show before you write:** the diff and message of a commit, the history that a force-push rewrites, the full title and body of a PR.
- **Stage only the task's files** (`git add <file>`, never `-A` or `.`).
- **Never `--no-verify`.** When a hook fails, fix the cause and make a new commit. Do not `--amend` the failed one.
- **Rewriting pushed history** needs `push --force-with-lease`, with its own go-ahead. Never `rebase --skip` without asking.
- **A PR body describes only what the diff changes,** concisely, with no `Generated with Claude Code` line.
