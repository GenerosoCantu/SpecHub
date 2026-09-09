<!--
  SERVICE SPEC TEMPLATE
  =====================
  Copy to `NN-{service}.md` at the workspace root (NN and {service} come from
  `scripts/bootstrap.sh plan`). The numeric prefix sets reading order.

  SPEC-GUIDELINES.md §2 is the checklist for WHAT each section must contain;
  this file is the scaffold. When the plan says "split", this same section
  list is distributed over `NN-{service}/00-core.md` (Overview → Authentication,
  Cross-Cutting Concerns, Key Design Notes, plus every shared layer in fact sheet
  §4b), `01-conventions.md` (Environment Variables, Enumerations & Constants,
  shared shapes) and one `{module}.md` per module (Data Models + Endpoints/Views of
  that module); `NN-{service}.md` becomes the index (templates/SPEC-INDEX-TEMPLATE.md).
  The module file set is `scripts/bootstrap.sh plan --manifest`, exactly — one file
  per row of fact sheet §4, named by its "Module file" column. Never fold two
  modules into one file, never drop one for being "shared" or "not a real module",
  never add one the manifest does not list.

  Backend or frontend is the `Group` field of fact sheet §1, never a judgment call:
  `group=frontend` uses "Views & Routes" and "Route Summary" everywhere this file
  says "Endpoints" and "Endpoint Summary"; every other group uses "Endpoints".
  Applies to the whole spec at once — never per module.

  Determinism contract (the bootstrap-specs skill enforces it). Two writers given the same fact
  sheet must produce the same tables; only prose wording may differ.
    D1  Keep every heading below, in this order, verbatim. A section that does
        not apply keeps its heading and reads "Not applicable — {one-line reason}."
        The heading set is CLOSED: never add, rename, merge or drop a heading, and
        never invent a new one for content that does not fit — put that content
        under the closest existing heading.
    D2  Every table row and list item comes from the fact sheet or from a file
        listed in fact sheet §12. Nothing from memory, nothing from other repos.
    D3  Sorting: modules alphabetical; endpoints grouped by module (alphabetical),
        and within a module Public before Protected, source order within each half;
        schema fields in source order; env vars alphabetical. Every table whose rows
        are services is in spechub.conf order.
    D4  Identifiers verbatim from source: file names, class/DTO names, route
        strings, env var names, state slice names.
    D5  Prose is at most two sentences per section introduction. No adjectives,
        no recommendations, no history.
    D6  Anything unresolved goes to "Known Issues & Gaps" as one line — never
        inline as if it were implemented.
    D7  Table "Notes"/"Purpose"/"Controls" cells lead with the verbatim source
        artifact — the decorator as written (`@Matches(/regex/)`, not "must match
        /regex/"), the guard or method name, the config key — then at most one
        clause of explanation. Never paraphrase a decorator into prose, and never
        merge two decorators into one note.
    D8  Hosting cell: take the first that exists, in this order — `ecosystem.config.js`,
        a deploy script in the manifest, a CI/deploy workflow file, the repo's own
        instruction file. Name the evidence in the cell. "unknown" only when none
        of the four exists. A script counts as a deploy script only when it names a
        process manager, host or platform (`pm2 start ...`, `serverless deploy`,
        `az webapp up`); a bare mode switch (`NODE_ENV=production npm start`) does
        not — fall through to the next source.
    D9  Data Models: every persisted entity always gets a field table. A request DTO
        gets its own table only when its endpoint's "Request" key does not already
        describe it in full — otherwise it is named there and not tabled twice.
        When the service persists no entities the section is still not "Not
        applicable": table every request DTO, since those are then its only typed
        contracts. An embedded/sub-document type is a labelled sub-table under its
        parent entity, not a heading of its own. In a split spec every entity and
        DTO appears in exactly one module file; none may be dropped for being
        "shared", "internal" or "trivial".
    D10 Environment Variables table: exactly the names in fact sheet §7a, one row
        each, alphabetical — no additions, no filtering, no judgment. "Required" is
        `yes` when the source fails fast without it (a throw, a process exit, a
        validation schema that rejects it), otherwise `no` — never a dash, and never
        "yes" merely because the service misbehaves without it. "Default" is the
        literal fallback in code (e.g. `4100` from `process.env.PORT || 4100`) or
        `none`; never reproduce a placeholder value from `.env.example`.
    D11 Endpoint paths are absolute and composed: the controller-level prefix plus
        the method-level path, one leading slash, no trailing slash, parameters in
        the source's own syntax (`:id`, `{id}`, `[id]`). Never document a path
        relative to its controller.
    D12 Every endpoint record carries every key in the fixed list under "Endpoints",
        in that order, with `none` where the key does not apply. A missing key is a
        defect, not brevity.
    D13 Endpoint grouping: one group per fact sheet §4 module, alphabetical. A
        controller that sits outside every §4 module (an app-root controller, a
        health file) goes in a group named for its own file, ordered with the rest.
        Never invent a thematic group, and never leave a route ungrouped.
    D14 The "Guard" key names the framework guard/middleware class applied to the
        route. When the route is protected by a check the framework does not model —
        written in the controller method, or in any service it calls on the request
        path — write `imperative: {function} ({file:line})`, naming the function
        wherever it lives. A route may carry both (`{GuardName}` + `imperative: …`)
        when a guard authenticates and a later check authorises. `none` means no
        check of either kind — never use it for auth the framework does not model.
    D15 Heading shape, by record type:
          entity    ``### {Name} (`{file or collection}`)``
          endpoint  ``#### `{METHOD} {path}` — {at most 8 words}``
          route     ``#### `{path}` — {at most 8 words}``  — no method: a view is
                    reached by navigation, not by a verb. A server-side API route
                    inside a frontend repo is an endpoint and keeps its method.
        A module-file heading is the bare heading from the template. Anything longer
        belongs in the record body, not the heading.
    D16 Status codes: state the code the framework actually returns, including its
        implicit default when the handler sets none (e.g. NestJS returns `201` for
        `POST` without `@HttpCode`). Mark such a value `implicit`. Never omit the
        row because the source has no explicit decorator.
    D17 "Depends on" and the report's `DEPENDS ON` take a service identifier only
        when a file you read names that service. A dependency reached through a
        base-URL environment variable and nothing else is NOT a `DEPENDS ON` entry:
        report it under `SHARED ARTIFACTS` with the variable name, and let the
        assembling session resolve the identity across services. Guessing which
        service sits behind a URL is the one inference this contract forbids.
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
6. [Endpoints](#endpoints)  <!-- group=frontend: "Views & Routes" -->
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

Field-by-field definition of every schema / entity / model this service owns (fact sheet §6). One table per entity, entities alphabetical, fields in source order. Embedded/sub-document types are labelled sub-tables under their parent, not headings of their own. Request DTOs are tabled here only when their endpoint's "Request" key does not already describe them in full (D9).

### {EntityName} (`{table or collection}`)

| Field        | Type     | Required | Default | Notes / Index            |
| ------------ | -------- | -------- | ------- | ------------------------ |
| `id`         | {type}   | yes      | auto    | PK                       |
| `{field}`    | {type}   | {y/n}    | {value} | {meaning, constraints}   |

<!-- group=frontend: the state slice / view model shape this module owns; the backend contract it mirrors stays in that service's spec. -->

---

## Endpoints

Grouped by module (alphabetical), **Public** before **Protected** within each group. A controller outside every fact sheet §4 module gets a group named for its own file (D13). For each endpoint: method, path, guard, request shape / DTO, response shape, validation and side effects.

### {Module}

#### `GET /{path}` — {what it does}

<!-- Every key below, in this order, on every endpoint. `none` where it does not apply (D12). -->

- **Guard:** `{GuardName}` | `imperative: {function} ({file:line})` | none
- **Request:** {params / query / body or DTO name} | none
- **Response:**

  ```json
  { "example": "response" }
  ```

- **Status codes:** `200` {when} · `4xx` `{ExceptionName}` {when} — success first, then each error path; mark a framework default `implicit` (D16)
- **Notes:** {validation, side effects, error cases} — each claim followed by `file:line`

<!--
  group=frontend: this section is "Views & Routes", and every route record carries these keys in
  this order, `none` where a key does not apply (D12):
  - **Component:** `{path/to/View}`
  - **Guard / Layout:** `{GuardName}` / `{LayoutName}` | none
  - **Loads:** {endpoint or payload it reads} | none
  - **State:** {slice names it reads and writes} | none
  - **States:** loading / empty / error behaviour
  - **Notes:** {validation, side effects} — each claim followed by `file:line`
  Group routes by the guard+layout they inherit, in the route table's declaration order.
  A server-side API route inside a frontend repo (Next.js `pages/api/*`, a Nuxt server route) is an
  endpoint, not a view: use the backend endpoint record for it, under this same heading.
-->

---

## Endpoint Summary

| Method | Path            | Auth | Module     | Purpose            |
| ------ | --------------- | ---- | ---------- | ------------------ |
| GET    | `/{path}`       | —    | {module}   | {summary}          |

<!-- group=frontend: "Route Summary", columns exactly | Route | Component | Data source | Guard |. -->

---

## Environment Variables

| Variable        | Required | Default | Controls                       |
| --------------- | -------- | ------- | ------------------------------ |
| `PORT`          | no       | {value} | listen port                    |

<!-- Exactly the names in fact sheet §7a, alphabetical (D10). Values come from the environment, never from this file. -->

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
