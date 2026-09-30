# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working from the Radiant hub.

## What this repo is

The hub tracks **only** cross-module docs (`docs/`) and the agent setup (`.claude/`). The modules are separate git repos checked out inside it by `make bootstrap` (clone) or `make link` (symlink to existing clones). They are gitignored here and each keeps its own `.git`, branches, remote and PRs. The layout mirrors the planned monorepo: when ETL, portal and MCP merge, the hub becomes its root.

Run `make status` to see which modules are checked out and on which branch. **Never assume a module is present**, `infra/*` in particular is optional. Check before reading.

## Modules

Each module has its own `CLAUDE.md`, loaded when you work in that folder. It is the reference for commands, tests and internals. Read it before changing that module.

| Path | Repo | What it is |
|---|---|---|
| `etl/` | radiant-portal-pipeline | Airflow ETL: VCF → Iceberg → StarRocks. Owns the StarRocks schema (DDL in `radiant/dags/sql/**/init/`) and data QA (dbt, `radiant/data_qa/`). Python. |
| `portal/` | radiant-portal | Go REST API (`backend/`) + React 19 frontend monorepo (`frontend/`) + Cypress + Docusaurus. Reads StarRocks. Owns the OpenAPI spec (`backend/docs/swagger.yaml`). |
| `mcp/` | radiant-mcp | MCP server wrapping upstream `mcp-server-starrocks`. Runs queries under the caller's JWT; optional tools call the portal API. Python. |
| `infra/qlin-qa`, `infra/qlin-prod` | Ferlab-Ste-Justine/qlin-*-infra | QA / prod infrastructure as code (Terraform, k8s manifests). Optional. |
| `infra/deployment` | radiant-portal-deployment | Deployment modules. Optional. |

## How modules connect

See `docs/architecture/overview.md` for the diagram. The boundaries are written down in `docs/contracts/`:

- **StarRocks schema** (`docs/contracts/starrocks-schema.md`): the ETL writes it. The portal backend and the MCP read it.
- **Portal API** (`docs/contracts/portal-api.md`): the portal defines it. Consumers are the frontend (generated TS client), the MCP (generated `radiant_python` client) and the ETL (`PATCH /{tenant}/cases/batch`).
- **Identity**: Keycloak issues the JWTs used by the portal, the MCP, and StarRocks itself (the MCP passes the JWT through).

Most cross-module bugs happen at these boundaries. When a change touches one, update the contract doc in the same piece of work.

## Cross-module work

For any feature that touches more than one module, use the `cross-module-feature` skill. The rules:

- The spec lives in `docs/features/SJRA-xxxx-<slug>.md` (from `docs/features/0000-template.md`).
- Use the **same branch name in every impacted repo**: `feat/sjra-xxxx-<slug>`.
- Run git and gh **inside the module**: `git -C etl …`, `cd portal && gh pr create`, or `gh --repo radiant-network/<repo>`. Running `gh pr create` at the hub root targets the hub.
- Open **one PR per repo**. Each links to the spec and to the sibling PRs.
- Merge in dependency order: schema / ETL → portal backend → frontend and MCP.
- Follow each repo's own conventions. The portal enforces CommitLint `type(scope): SJRA-### message` and its `.github/pull_request_template.md`.

## Docs placement

- **Module-internal** (how the ETL fans out writers, a DAG's design, a React component): stays in the module (e.g. `etl/design/SJRA-*.md`) and is reviewed with the code.
- **Cross-module** (architecture, contracts, ADRs, specs spanning modules): `docs/` here.

## Safety

- Never read `.env` files or secrets in any module (the portal's CLAUDE.md forbids it explicitly).
- Infra repos describe real QA/prod environments. Read them freely, but never apply, plan against or push anything there without an explicit request.
