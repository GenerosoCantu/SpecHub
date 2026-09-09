<!--
  MODULE FILE TEMPLATE — one per module of a SPLIT service spec (`NN-{service}/{module}.md`).
  Up to 400 lines. If it outgrows that, check whether it is really two modules. There is no minimum:
  the file set comes from the manifest, so a module with two source files yields a short file. Never
  pad one to reach a length, and never merge two modules to avoid a short file.

  The file set is `scripts/bootstrap.sh plan --manifest`, exactly: one file per row of fact sheet
  §4, named by its "Module file" column. Never fold two modules into one file, never drop one for
  being "shared" or "not a real module", never add one the manifest does not list. The shared
  layers in fact sheet §4b are NOT modules — they are documented in `00-core.md` / `01-conventions.md`.

  Same determinism contract as SERVICE-SPEC-TEMPLATE.md (D1–D17): the heading set below is CLOSED
  and in this order, identifiers verbatim, fields in source order, unresolved items in "Known Issues
  & Gaps" of 00-core.md. Never invent a heading for content that does not fit — put it under the
  closest heading below.

  Which heading set applies is the `Group` field of fact sheet §1, never a judgment call, and it
  applies to every module file of the service at once:
    group=frontend      → Views & Routes, State, Action Types, Error Codes, Business Logic, Files
    every other group   → Schema, Endpoints, Request / Response Shapes, Business Logic, Files
  Keep the headings of the set that applies, all of them, in order; a heading with nothing to say
  reads "Not applicable — {one-line reason}." Delete the other set and this comment block.
-->

> Part of the {Service Name} spec (`NN-{service}.md`). Read `NN-{service}/00-core.md` for shared patterns, auth, and conventions.

# {Module}

{One or two sentences: what the module manages and which other modules or services it touches.}

<!-- ============ BACKEND SET (every group except frontend) ============ -->

#### Schema

<!-- One table per entity this module owns, entities alphabetical, fields in source order. A request
     DTO is tabled only when its endpoint's "Request" key does not describe it in full; an embedded
     type is a labelled sub-table under its parent. Every entity and DTO in fact sheet §6 appears in
     exactly one module file (D9). "Not applicable — {reason}." when the module owns none. -->

| Field | Type | Required | Default | Notes / Index |
|-------|------|----------|---------|---------------|
| `id` | {type} | yes | {auto} | PK |
| `{field}` | {type} | {yes/no} | {value or none} | {meaning, constraints, index} |

#### Endpoints

<!-- Paths absolute and composed: controller prefix + method path (D11). -->

| Method | Path | Guard | Description |
|--------|------|-------|-------------|
| GET | `/{path}` | {guard, `imperative: …`, or none} | {one line} |

Then one record per endpoint, every key in this order, `none` where it does not apply (D12):

##### `GET /{path}` — {what it does}

- **Guard:** `{GuardName}` | `imperative: {function} ({file:line})` | none
- **Request:** {params / query / body or DTO name} | none
- **Response:** {shape or DTO name}
- **Status codes:** `200` {when} · `4xx` `{ExceptionName}` {when} — mark a framework default `implicit` (D16)
- **Notes:** {validation, side effects} — each claim followed by `file:line`

#### Request / Response Shapes

<!-- DTO / payload names verbatim; one JSON example per non-trivial shape, with real field names. -->

```json
{ "example": "response" }
```

#### Business Logic

- **Create:** {what happens, side effects}
- **Update:** {…}
- **Delete:** {…}
- **Errors:** {status codes / exceptions and when}

#### Files

```text
{source root}/{module}/{file}   ← {role}
```

<!-- ============ FRONTEND SET (group=frontend) ============ -->

#### Views & Routes

<!-- Grouped by the guard+layout the routes inherit, in the route table's declaration order.
     A module with no routes keeps the heading and reads "Not applicable — {reason}." (D1).
     A server-side API route inside a frontend repo (Next.js `pages/api/*`, a Nuxt server route) is
     an endpoint, not a view: use the BACKEND endpoint record for it, under this heading. -->

| Route | Component | Data source | Guard |
|-------|-----------|-------------|-------|
| `/{path}` | `{path/to/View}` | {endpoint or payload} | {guard or none} |

Then one record per route, every key in this order, `none` where it does not apply (D12):

##### `/{path}` — {what the view is for}   <!-- path only, no method (D15) -->

- **Component:** `{path/to/View}`
- **Guard / Layout:** `{GuardName}` / `{LayoutName}` | none
- **Loads:** {endpoint or payload it reads} | none
- **State:** {slice names it reads and writes} | none
- **States:** loading / empty / error behaviour
- **Notes:** {validation, side effects} — each claim followed by `file:line`

#### State

<!-- The store slice(s) this module owns: shape, in source order. Shared store plumbing (root shape,
     loading pattern, pagination metadata) belongs in 00-core.md, not here. A slice used by more
     than one module is owned by the module that dispatches its actions and is documented in full
     there; every other module names it and links, never re-tabling it. -->

| Field | Type | Initial | Set by |
|-------|------|---------|--------|
| `{field}` | {type} | {value} | `{action}` |

#### Action Types

<!-- Verbatim from source, in declaration order. -->

```text
@{module}/{action}
```

#### Error Codes

<!-- The per-operation error code prefixes this module passes to the shared request layer, verbatim.
     "Not applicable — the request layer takes no error code." when the codebase has no such convention. -->

| Operation | Prefix |
|-----------|--------|
| `{method}` | `{prefix}` |

#### Business Logic

- **Load:** {what happens, side effects}
- **Save:** {…}
- **Delete:** {…}
- **Errors:** {what the view shows and when}

#### Files

```text
{module root}/{module}/{file}   ← {role}
```

---
