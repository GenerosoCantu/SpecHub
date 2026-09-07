<!--
  CONVENTIONS TEMPLATE → `CONVENTIONS.md`
  Written by the bootstrap-specs skill (Step 0) from the service specs, updated in Step 4g when
  a feature changes a shared convention. Only conventions that hold across TWO OR MORE services
  belong here (all of them for a single-service project); service-specific ones stay in that
  service's spec. Every statement must be observed in the source — write "as implemented",
  not "as intended". Keep the section order; "Not applicable" is a valid section body.
-->

# {Project Name} — Shared Conventions

> **Source of truth for cross-service conventions.** Read this file (instead of the full overview) for API naming, domain entities, storage, env vars, logging, and code organization. System-wide questions still belong to `00-architecture-overview.md`.

### 1. API Naming (as implemented)

- Resource paths: {plural nouns? version prefix? casing?} — examples verbatim from the routes
- Singleton resources: {…}
- API docs: {Swagger/OpenAPI path, or none}
- CORS: {policy as configured}

### 2. Domain Entities

| Entity | Owned by | ID strategy | Paginated | Lifecycle / statuses |
|--------|----------|-------------|-----------|----------------------|
| **{Entity}** | `{service}` | {e.g. server UUID v4} | {yes/no} | {status values} |

**Common list query parameters:** {names + defaults, verbatim}.

**Paginated response shape:**

```json
{ "example": "shape used by every list endpoint" }
```

### 3. Storage and Files

{Datastores, schema/table naming, file/object storage layout, snapshot or cache files. Directory trees where they exist.}

### 4. Environment Variables

| Variable | Used by | Purpose |
|----------|---------|---------|
| `{NAME}` | `{service}`, `{service}` | {one line} |

Rules: {prefix conventions, where `.env.example` lives, what is never committed}.

### 5. Logging and Error Handling

- **Logging:** {library, format, levels, correlation ids}
- **Error envelope:** {shape, status code mapping}
- **Validation errors:** {shape}

### 6. Code Organization

```text
{the per-module layout every service of the same stack follows, verbatim file names}
```

- {Naming rules for files, classes, DTOs, state slices, components}
- {Test placement and naming}
- {Lint / format commands — and the rule to lint only changed files}
