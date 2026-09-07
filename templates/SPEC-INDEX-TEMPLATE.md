<!--
  SPEC INDEX TEMPLATE — for a SPLIT service spec.
  Copy to `NN-{service}.md`; the content lives in `NN-{service}/`:
    00-core.md          Overview, Tech Stack, Architecture, Authentication, Cross-Cutting
                        Concerns, Key Design Notes, Known Issues & Gaps (service-wide)
    01-conventions.md   Environment Variables, Enumerations & Constants, shared request/
                        response shapes, state conventions (frontends), i18n
    {module}.md         one per module (templates/MODULE-TEMPLATE.md), alphabetical
  Keep this file short: it routes, it does not describe. Never re-add module content here.
-->

# {Service Name} — Specification

> **Last updated:** {YYYY-MM-DD} — {one line naming the latest change only}. History lives in `CHANGELOG.md`.

---

## What this file is

This file is the **index** for the `{service}` spec. The full content is split into per-module files under [`NN-{service}/`](NN-{service}/). **The split files are the source of truth** — this index only routes you to them.

{Two sentences: what the service is. Full overview: [`NN-{service}/00-core.md`](NN-{service}/00-core.md).}

## File Map

| File | Contents |
|------|----------|
| [`00-core.md`](NN-{service}/00-core.md) | Overview, tech stack & bootstrap, architecture, authentication, cross-cutting patterns, key design notes, known issues |
| [`01-conventions.md`](NN-{service}/01-conventions.md) | Environment variables, enumerations & constants, shared shapes{, state conventions} |
| [`{module}.md`](NN-{service}/{module}.md) | {Module} module — {one-line scope} |

## Reading Guidance

For any task: read this index, `NN-{service}/00-core.md`, and the relevant module file(s). Read `01-conventions.md` when the task touches env/config, constants or shared shapes.

Do **not** read every module file for a single-module task — the split exists so a session loads only the index + core + the 1–2 relevant files.

## Maintenance

- The files under `NN-{service}/` are the source of truth for this spec; do not re-inline them here.
- A new module gets its own file in `NN-{service}/` plus one row in the File Map above.
- Cross-cutting changes go in `00-core.md`; env/config and shared-shape changes go in `01-conventions.md`.
