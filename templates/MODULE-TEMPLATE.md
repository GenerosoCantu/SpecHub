<!--
  MODULE FILE TEMPLATE — one per module of a SPLIT service spec (`NN-{service}/{module}.md`).
  50–400 lines. If it outgrows that, check whether it is really two modules.
  Same determinism contract as SERVICE-SPEC-TEMPLATE.md: headings in this order, identifiers
  verbatim, fields in source order, unresolved items in "Known Issues & Gaps" of 00-core.md.
  Frontends: "Endpoints" becomes "Views & Routes" (route, view component, data source, state,
  loading / empty / error states); "Schema" becomes the view model / state slice shape.
-->

> Part of the {Service Name} spec (`NN-{service}.md`). Read `NN-{service}/00-core.md` for shared patterns, auth, and conventions.

# {Module}

{One or two sentences: what the module manages and which other modules or services it touches.}

#### Schema

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `id` | {type} | {auto} | Unique identifier |
| `{field}` | {type} | — | {meaning, constraints, index} |

#### Endpoints

| Method | Path | Guard | Description |
|--------|------|-------|-------------|
| GET | `/{path}` | {guard or —} | {one line} |

#### Request / Response Shapes

<!-- DTO / payload names verbatim; one JSON example per non-trivial shape. -->

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

---
