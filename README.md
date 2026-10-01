# radiant-hub

The single place for Radiant's cross-module documentation and for driving features that span several repos, with people or with an agent like Claude Code.

The hub tracks only `docs/` and the agent setup. The module repos are checked out *inside* it, but git ignores them here. Each one stays a normal, independent repo: you branch, commit, push and open PRs in it as usual.

```
radiant-hub/
├── CLAUDE.md          system map + cross-module rules for agents
├── docs/              architecture, contracts, ADRs, feature specs
├── repos.conf         which repos the hub knows about
├── etl/               → radiant-portal-pipeline   (own .git)
├── portal/            → radiant-portal            (own .git)
├── mcp/               → radiant-mcp               (own .git)
└── infra/             → optional infra repos      (own .git each)
```

## Getting started

```sh
git clone <this repo> radiant-hub && cd radiant-hub
make bootstrap                      # clones etl, portal, mcp; asks about each infra repo
make bootstrap INFRA=none           # no prompt, no infra
make link WORKSPACE=~/workspace     # already have clones? symlink them instead of re-cloning
make status                         # branch / dirty / ahead-behind of every repo
make pull                           # fast-forward every clean repo
```

Bootstrap is idempotent. Re-run it at any time to add a repo you skipped (e.g. an infra repo). Paths that already exist are never touched.

## Working on a cross-module feature

Example: *"Add COSMIC information on variant"* touches the ETL and the portal.

1. **Analyse in the hub.** Copy `docs/features/0000-template.md` to `docs/features/RAD-xxxx-cosmic-on-variant.md`. Fill in the modules impacted and the contract changes, and update `docs/contracts/`. Open a hub PR for review.
2. **Implement in each module**, using the same branch name everywhere:
   ```sh
   git -C etl    switch -c feat/rad-xxxx-cosmic-on-variant
   git -C portal switch -c feat/rad-xxxx-cosmic-on-variant
   ```
3. **Deliver one PR per repo**, run from inside the module (`cd etl && gh pr create`), each linking to the spec. Merge in dependency order: ETL/schema first, then the portal.

With Claude Code, start `claude` at the hub root and ask it to work on the feature. The `cross-module-feature` skill follows these steps.

## Adding a repo

Add a line to `repos.conf` (`<path> <git url> <core|infra>`) and to `.gitignore`, then run `make bootstrap`.
