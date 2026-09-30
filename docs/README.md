# Radiant docs

Cross-module documentation. If a doc concerns one module only, keep it in that module's repo, next to the code, so it gets reviewed with the code (e.g. `etl/design/SJRA-*.md`).

| Folder | What goes there |
|---|---|
| [`architecture/`](architecture/) | How the system fits together: components, data flow, deployment topology. |
| [`contracts/`](contracts/) | The interfaces between modules: who writes, who reads, what must stay in sync. **Update these whenever a boundary changes.** |
| [`adr/`](adr/) | Architecture decisions that affect more than one module. |
| [`stories/`](stories/story-template.md) | The Jira story template, filled in at grooming. |
| [`features/`](features/) | Specs for features that span several modules, one per SJRA ticket. |

Diagrams are Mermaid inside the Markdown, so they diff and review like text.
