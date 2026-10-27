---
name: review
description: Review a Radiant feature against its RAD ticket and its spec in docs/features/, across every module that carries the ticket's branch, before its PRs or once they are open. Checks the acceptance criteria, out-of-plan changes, the boundaries between modules, code quality, PR comments and QA defects. Read-only.
argument-hint: "<RAD-XXXX> [module]"
---

# Review

Deliver only the review: no narration of the steps, no recap of what you fetched. Ask one short question only when a step cannot go on. Never edit, commit, push, or comment on a PR or a ticket.

## 1. Find the branch

- Run `make status`. In each checked-out module, or only in the one given as argument: `cd <module>`, `git fetch origin`, then `git branch --list -a -i "*rad-xxxx*"`. Old tickets use `sjra-xxxx`.
- The same branch in several modules is one feature: review them together. No branch found: ask for it.

## 2. Gather the context

- **Ticket:** read it as the `jira` rule says, QA bounce check included. If it comes from a prod incident, ask before you read its description and comments (`confidentiality` rule).
- **Story:** its acceptance criteria and its out of scope.
- **Spec:** `docs/features/RAD-xxxx-*.md` if it exists: Chosen approach, Modules impacted, Tasks, Test strategy, Frozen scope, Deviation log. A Small story may have none: say so.
- **Diff, per module,** from inside it and one call each: `git merge-base origin/main <branch>`, then `git diff <sha> <branch>`. Use `origin/<branch>` when there is no local branch. For lock files and generated files (API clients, swagger output), check only that they were regenerated.
- **Module rules:** the `CLAUDE.md` and `.claude/rules/` of each folder that the diff touches.
- **Boundaries:** for each StarRocks table or column, enum value, or API endpoint or field that the diff changes, run the `impact` skill on the branches.
- **Open PRs,** in each module: `gh pr list --head <branch>`, then per PR `gh pr view <n> --json reviews,comments` and `gh api repos/<owner>/<repo>/pulls/<n>/comments` for the inline comments.

## 3. Report

Use these sections, in this order. Omit a section that has nothing to say, title included.

1. **Acceptance criteria:** each criterion of the story: covered, partly covered or missing, with what proves it (the spec's Test strategy).
2. **Fit:** does the change resolve the ticket, and follow the spec's Chosen approach? Flag what is insufficient or over-engineered.
3. **Out of plan:** changes outside the spec's Modules impacted and Tasks, or inside its Frozen scope, that the Deviation log does not record. Without a spec: changes unrelated to the ticket.
4. **Boundaries:** each boundary item changed, its writer and its readers, and whether they agree. Silent readers first. Then the merge order that the PRs need.
5. **Regression risks:** existing behaviour or consumers that the change can break.
6. **Code quality:** the hub and module rules, error handling, security (injection, exposed data), dead code, leftover TODOs.
7. **Docs:** what to update (a module `CLAUDE.md`, the user docs, the spec, the Postman collection of a changed endpoint).
8. **Manual tests** for QA: `**Scenario** — goal`, steps, expected result. The golden path and the likely edge cases, nothing outside the ticket.
9. **PR feedback:** per human comment, a summary, then addressed, partly addressed or not addressed on the branch, and what remains. Bot comments only when still relevant. End with a table `Reviewer | Verdict | Addressed | Pending`.
10. **QA feedback,** only after a QA bounce: per defect, still relevant (yes, no, debatable, with a reason), addressed, partly addressed or not addressed, and what remains. End with a table `Defect | Relevant | Status | Remaining`.

Redact the personal data that you quote (`<patient>`, `<user>`, `<sample>`).
