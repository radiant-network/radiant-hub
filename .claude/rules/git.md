# Git

- **Branch:** one per task, with the same name in every repo it touches. `feat/rad-xxxx-<slug>` for a story or a task, `fix/rad-xxxx-<slug>` for a bug, `design/rad-xxxx-<slug>` for a hi-fi design prototype (a draft PR that is never merged), keyed by the task's Jira sub-task when the story has some, else by the story. In lowercase, 37 characters at most after the `/`: the portal's Ferlease names its Kubernetes objects `radiant-portal-ui-release-<that part>`, capped at 63, and never deploys a longer one. Choose it before the first push: GitHub cannot change the branch of a PR, so a rename means a new PR.
- **Work in the module's own checkout,** switched to the task's branch, so that the user sees the files in the IDE. No `git worktree` unless the user asks. When the checkout is on another branch or has uncommitted changes, ask before you switch.
- **Commit message:** `<type>(<scope>): RAD-XXXX <subject>`, the scope optional. Write the subject in lowercase, with no `,`, `(`, `)` or `:`: the portal's commitlint rejects them with misleading errors. One line when it is enough, otherwise one sentence and a short list of the changes. No `Co-Authored-By` trailer.
- **Each write needs its own go-ahead:** `git commit` (and `--amend`), `git push`, `gh pr create|edit|merge`, `gh api -X PATCH`. Approving the code is not approving the commit, the commit not the push, one push not the next. Silence or an ambiguous answer is not a go-ahead.
- **Show before you write:** the diff and message of a commit, the history that a force-push rewrites, the full title and body of a PR.
- **Stage only the task's files** (`git add <file>`, never `-A` or `.`).
- **Never `--no-verify`.** When a hook fails, fix the cause and make a new commit. Do not `--amend` the failed one.
- **Rewrite history only on a private branch** (no PR, nobody else on it): `rebase`, `--amend` of a pushed commit and `push --force-with-lease`, each with its own go-ahead. Never `rebase --skip` without asking.
- **On a shared branch** (PR open, or QA or someone else on it), add commits: QA's Cypress commits must never be lost. Sync with `git merge origin/main`, committed as `chore(merge): RAD-XXXX merge main onto feat-rad-xxxx`: the portal's commitlint rejects a `/` in the subject.
- **Merge to `main`** with Squash and merge, never Rebase and merge. The squash commit takes the PR title: write it in the commit message format.
- **A PR body describes only what the diff changes,** concisely, with no `Generated with Claude Code` line.
