# Radiant docs

Cross-module documentation. If a doc concerns one module only, keep it in that module's repo, next to the code, so it gets reviewed with the code (e.g. `etl/design/SJRA-*.md`).

| Folder | What goes there |
|---|---|
| [`architecture/`](architecture/) | How the system fits together: components, data flow, deployment topology. |
| [`adr/`](adr/) | Architecture decisions that affect more than one module. |
| [`stories/`](stories/story-template.md) | The Jira story template, filled in at grooming. |
| [`features/`](features/) | Specs for features that span several modules, one per RAD ticket. |
| [`ci/`](ci/) | CI shared by several repos: [security checks](ci/security-checks.md) (what runs, what blocks a merge, what notifies). |

Diagrams are Mermaid inside the Markdown for flows, so they diff and review like text, SVG files in an `img/` folder next to the doc for geometry (what must align or keep its proportions), and monospace blocks for aligned sequences. The `doc-writing` skill holds the rules and the palette.
