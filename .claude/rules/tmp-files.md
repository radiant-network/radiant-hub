# Working files

Put every working file (dump, query result, scratch JSON, draft, token) in `tmp/<topic>/` at the hub root. Git ignores `tmp/`.

- **Nowhere else:** not in `/tmp/`, `~/Downloads/`, the hub root or a flat `tmp/`, and never in a module: its `.gitignore` may not cover the file, which could then be committed.
- **Topic:** kebab-case, named after the subject, with the ticket first when there is one (`tmp/rad-22-snv-hom-af/`). A subtask goes in its parent's folder (`tmp/rad-22-…/rad-31-…/`).
- **`tmp/tokens/`** is reserved for token files, one per environment and role (`<env>_<role>.json`). See the `confidentiality` rule.
- **At the end of a task,** ask whether to delete or keep the working files, and name their paths.
