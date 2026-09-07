<!--
  SERVICE SPEC TEMPLATE
  =====================
  Copy to `NN-{service}.md` at the workspace root (NN and {service} come from
  `scripts/bootstrap.sh plan`). The numeric prefix sets reading order.

  SPEC-GUIDELINES.md §2 is the checklist for WHAT each section must contain;
  this file is the scaffold. When the plan says "split", this same section
  list is distributed over `NN-{service}/00-core.md` (Overview → Authentication,
  Cross-Cutting Concerns, Key Design Notes), `01-conventions.md` (Environment
  Variables, Enumerations & Constants, shared shapes) and one `{module}.md` per
  module (Data Models + Endpoints/Views of that module); `NN-{service}.md` becomes
  the index (templates/SPEC-INDEX-TEMPLATE.md).

  Determinism contract (the bootstrap-specs skill enforces it):
    D1  Keep every heading below, in this order, verbatim. A section that does
        not apply keeps its heading and reads "Not applicable — {one-line reason}."
    D2  Every table row and list item comes from the fact sheet or from a file
        the fact sheet names. Nothing from memory, nothing from other repos.
    D3  Sorting: modules alphabetical; endpoints grouped by module (alphabetical),
        source order within a module; schema fields in source order; env vars
        alphabetical.
    D4  Identifiers verbatim from source: file names, class/DTO names, route
        strings, env var names, state slice names.
    D5  Prose is at most two sentences per section introduction. No adjectives,
        no recommendations, no history.
    D6  Anything unresolved goes to "Known Issues & Gaps" as one line — never
        inline as if it were implemented.
  Delete this comment block and every <!-- guidance --> note before committing.
-->

# {Service Name} — Specification

> One sentence: what this service is and the single responsibility it owns.

**Service identifier:** `{service}`  <!-- the `name` column of spechub.conf -->
**Last updated:** {YYYY-MM-DD} — {one line naming the latest change only; history lives in CHANGELOG.md}

---

## Table of Contents

1. [Overview](#overview)
2. [Tech Stack](#tech-stack)
3. [Architecture](#architecture)
4. [Authentication](#authentication)
5. [Data Models](#data-models)
6. [Endpoints](#endpoints)  <!-- frontends: "Views & Routes" -->
7. [Endpoint Summary](#endpoint-summary)
8. [Environment Variables](#environment-variables)
9. [Cross-Cutting Concerns / Patterns](#cross-cutting-concerns--patterns)
10. [Key Design Notes](#key-design-notes)
11. [Known Issues & Gaps](#known-issues--gaps)

---

## Overview

- **Purpose:** what the service does and why it exists.
- **Owns:** the data and responsibilities that live here and nowhere else.
- **Does not own:** related responsibilities that belong elsewhere (link the spec that owns them).
- **Depends on:** other services it calls (by service identifier), or "none".

---

## Tech Stack

| Concern        | Choice                                   |
| -------------- | ---------------------------------------- |
| Language       | {from fact sheet §2}                     |
| Framework      | {from fact sheet §2}                     |
| Datastore      | {from dependencies + config, or "none"}  |
| Default port   | {from fact sheet §1}                     |
| Start command  | `{from fact sheet §1}`                   |
| Hosting        | {from README/config, or "unknown"}       |

---

## Architecture

Internal module layout: a tree of the source root with one line per module (fact sheet §4), then how a request flows through it (entry point → router/controller → service → datastore).

```text
{service}/
├── {source root}/
│   ├── {module}/            ← {one-line role}
│   └── {entry point}
```

### Bootstrap
<!-- Global middleware, interceptors, filters, pipes, CORS, validation, registered app-wide — from the entry point file. -->

---

## Authentication

- **Strategy:** {e.g. JWT bearer validated locally / delegated to `{service}` / session cookie / none}.
- **Guard(s) / middleware:** {names, where applied}.
- **Public vs protected:** which endpoint groups require auth.
- **Tenant / scope claims:** how isolation is enforced from the token, if any.

---

## Data Models

Field-by-field definition of every schema / entity / model this service owns (fact sheet §6). One table per entity, entities alphabetical, fields in source order.

### {EntityName} (`{table or collection}`)

| Field        | Type     | Required | Default | Notes / Index            |
| ------------ | -------- | -------- | ------- | ------------------------ |
| `id`         | {type}   | yes      | auto    | PK                       |
| `{field}`    | {type}   | {y/n}    | {value} | {meaning, constraints}   |

<!-- Frontends: replace with "Data Models" of the UI (state shape, view models) when they differ from the backend contracts. -->

---

## Endpoints

Grouped by module (alphabetical), **Public** before **Protected** within each group. For each endpoint: method, path, guard, request shape / DTO, response shape, validation and side effects.

### {Module}

#### `GET /{path}` — {what it does}

- **Guard:** none | `{GuardName}`
- **Request:** {params / query / body or DTO name}
- **Response:**

  ```json
  { "example": "response" }
  ```

- **Notes:** {validation, side effects, error cases}

<!--
  FRONTEND SPECS: this section is "Views & Routes". For each route: path, view/page component,
  data it loads (which endpoint / payload), state it reads and writes, loading / empty / error states.
-->

---

## Endpoint Summary

| Method | Path            | Auth | Module     | Purpose            |
| ------ | --------------- | ---- | ---------- | ------------------ |
| GET    | `/{path}`       | —    | {module}   | {summary}          |

<!-- Frontends: "Route Summary" — | Route | View | Data source | Auth |. -->

---

## Environment Variables

| Variable        | Required | Default | Controls                       |
| --------------- | -------- | ------- | ------------------------------ |
| `PORT`          | no       | {value} | listen port                    |

<!-- Every name in fact sheet §7, alphabetical. Values come from the environment, never from this file. -->

---

## Cross-Cutting Concerns / Patterns

- **Request/response envelope:** {standard success/error shape}.
- **Validation:** {global pipes, DTO/schema validation, form validation}.
- **Error handling:** {filters, error mapping, retry}.
- **Logging:** {what, where}.
- **Client layer (frontends):** {base request module, base URL resolution, auth header injection}.
- **State (frontends):** {store shape, slice names, action naming, loading pattern}.

---

## Key Design Notes

- {ID generation strategy}
- {Lifecycle / status rules}
- {Cross-service delegation}
- {Caching, jobs, side effects}

---

## Known Issues & Gaps

- {One line per unresolved item, caveat, or legacy behaviour found in the source.}
