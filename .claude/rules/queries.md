---
paths:
  - "**/*.{sql,go,py}"
---

# Queries

Design a query to read each table once: share one join or derived table between a filter, a column and a count, rather than reading the same table again in a subquery, unless the result needs it. Reviewers ask for it even when the gain is small. Other optimizations wait for a measured problem.
