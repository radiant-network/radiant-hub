# Contracts

A contract is anything one module produces and another consumes. Each contract doc lists, per item, the **owner** (writer), the **readers**, and the **source of truth** in code.

| Contract | Owner | Readers |
|---|---|---|
| [StarRocks schema](starrocks-schema.md) | etl | portal backend, mcp |
| [Portal API](portal-api.md) | portal backend | portal frontend, mcp, etl |

Rule: a PR that changes a contract updates its doc here, and the spec (`docs/features/…`) lists the change under "Contract changes".
