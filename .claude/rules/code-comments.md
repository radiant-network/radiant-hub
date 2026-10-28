---
paths:
  - "**/*.{go,ts,tsx,js,jsx,mjs,cjs,py,r,R,sql,sh,bash,mk,tf,tfvars,hcl,yaml,yml,toml,conf,config,tmpl,css,nf,groovy,dockerfile}"
  - "**/Makefile"
  - "**/Dockerfile*"
---

# Code comments

Comment only what the code cannot say: a hidden constraint, an order that matters, a lossy mapping, a trap for the next reader. Before you write one, try a clearer name or a smaller function.

- **Do not describe what the code or a name already says.**
- **No pointer outside the code:** no ticket key (`RAD-123`, `SJRA-123`), no spec or doc path, no Jira, Notion or Figma link. A pointer to code (a function, a type) is fine.
- **No history or status:** no "was X, now Y", "for now", "until X lands". The commit or the PR holds it.
- **State each fact once,** where it matters.
- **Match the file.** A public symbol does not need a doc comment, and a new symbol is no reason to start doc comments in a file that has none.
- **Keep it as short as possible:** one line, two at most. Up to five lines only as an exception, for a block that is really complex. A `TODO:` takes one line and gives its reason.
- **After each edit, re-read the diff.** Remove each comment that breaks this rule, and each comment that your change made false, even an old one.
