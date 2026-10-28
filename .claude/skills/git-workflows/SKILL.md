---
name: git-workflows
description: Step-by-step git procedures in the hub and its modules - rebase a branch on main, fold a fix into an earlier commit, pass a PR body from a file, clean up merged branches and their working files. Use when the user asks for one of them.
---

# Git workflows

Run each command from inside the module, one per call, with each write guarded (`bash-commands` rule). Each write needs its own go-ahead (`git` rule).

## Rebase on main

1. `git status`, then `git stash list`. If there is uncommitted work, ask before you stash it: `git stash push -u -m "rebase <branch>"`.
2. `git fetch origin`, then `git rebase origin/main`.
3. On a conflict: resolve it, `git add` the files, then `git rebase --continue`. If both sides changed the same logic on purpose, stop and show both sides. `git rebase --abort` restores the branch.
4. Pop the stash by its explicit ref (`git stash pop stash@{N}`): the index shifts when other entries exist. A pop that conflicts keeps the entry: drop it only once the user validates the resolution.
5. The history changed: the push needs `--force-with-lease`, with its own go-ahead.

## Fold a fix into an earlier commit

Keeps one commit per concern after a review fix. It rewrites history.

1. `git branch backup/<branch>-pre-fold`, a safety ref.
2. `git add <files>`, then `git commit --fixup=<target sha>`, one per target commit. Commit hooks such as commitlint ignore `fixup!` subjects: `--no-verify` is never needed.
3. `git config sequence.editor true`, then `git rebase -i --autosquash origin/main`, then `git config --unset sequence.editor`. Without `-i`, `--autosquash` does nothing and still reports success.
4. Check that `git log --oneline origin/main..HEAD` shows no `fixup!`, and that `git show --stat <target>` holds the files. Then delete the backup branch.

## PR body from a file

Backticks and quotes break `--body "…"`. Write the body to `tmp/<topic>/pr-body.md` and pass `--body-file`. Delete the file once the last `gh pr create|edit` succeeds. When the PR is open, ask the user to tell you when it is merged, for the cleanup below.

## Clean up merged branches

In the hub and in each checked-out module:

1. `git fetch origin --prune`, then `git branch -vv --merged origin/main`.
2. `git branch -d <branch>` for each one, except `main`.
   - `-d` refuses a branch that `--merged` listed, because it compares with HEAD and the upstream. Confirm with `git merge-base --is-ancestor <branch> origin/main` (exit 0), then use `-D`.
   - Git does not see a squash-merged branch as merged, and an upstream marked `gone` is no proof. Compare the branch's diff with what landed on `main` before you use `-D`.
   - For an old unmerged branch, check its ticket first: a cancelled ticket also leaves a branch behind.
   - A `backup/*` branch can go once its ticket is merged.
3. For each deleted branch, look for its working files (`tmp/*<ticket>*`). Propose to delete them. Never delete them yourself.
4. `find tmp -name '*token*' -type f`: a token file outside `tmp/tokens/` is an anomaly to delete, a file inside it is a slot to empty (`confidentiality` rule).
