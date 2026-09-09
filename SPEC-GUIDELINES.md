# Specification Guidelines

This document describes what belongs in the central architecture overview (`00-architecture-overview.md`) and what belongs in each service-level spec (`NN-{service}.md`). It is the canonical checklist for writing and updating specs — Step 0 (`bootstrap-specs`) generates them against it, Steps 2 and 4 edit them against it.

> **Structure rules.**
>
> 1. Shared conventions live in `CONVENTIONS.md`; the feature status table lives in `STATUS.md`. Write convention/status content there, never into the overview.
> 2. A service with more than 8 source modules (`scripts/bootstrap.sh plan`) gets a **split spec**: `NN-{service}.md` is an index; the content lives in `NN-{service}/` — `00-core.md` (shared architecture plus every shared layer in fact sheet §4b), `01-conventions.md` (env, constants, shared shapes) and one `{module}.md` per module. The file set is `scripts/bootstrap.sh plan --manifest`, exactly — never fold two modules into one file, never drop one for being "shared", never add one the manifest does not list. Keep module files under 400 lines; if one outgrows that, check whether it is really two modules. There is no minimum length — the file set comes from the manifest, so a module with two source files yields a short file. Never pad one to reach a length, and never merge two modules to avoid a short file.
> 3. A single-file spec that grows past ~1,000 lines is split the same way at the next close-out.
> 4. **Header rule.** The `Last updated` line is one line of at most ~200 characters naming the latest change only. Never chain `Prior (...)` entries into it — history lives in `CHANGELOG.md`.

---

## 1. Architecture Overview File (`00-architecture-overview.md`)

The overview is the entry point for the whole platform. It documents the system at a high level and routes to the service specs. Template: `templates/ARCHITECTURE-OVERVIEW-TEMPLATE.md`.

### Required sections

1. **Version and Last Updated** — `Version:` and a single `Last Updated:` line.
2. **Table of Contents** — numbered, covering every section below.
3. **Product Summary** — one paragraph: product, audience, problem solved.
4. **System Components** — every deployable unit grouped as client applications / backend services / data layer, with service identifier, tech stack, default port, purpose, hosting.
5. **High-Level Architecture Diagram** — Mermaid `graph LR`: one node per service in `spechub.conf` order, one edge per dependency, subgraphs by group. Never hand-drawn ASCII — a free-form drawing differs on every run and cannot be diffed.
6. **Tenancy and Data Isolation** — how tenants/accounts/workspaces are resolved and isolated; "Not applicable" for single-tenant systems.
7. **Authentication and Authorization** — strategy across services, token flow, delegation, roles.
8. **Service Communication** — who calls whom, public vs authenticated, shared headers, events.
9. **Hosting and Deployment** — where each service runs; CI/CD facts found in the repos.
10. **Shared Conventions** — pointer to `CONVENTIONS.md`.
11. **Spec Document Index** — one row per spec file; split specs marked as indexes.
12. **Cross-Service Mechanisms** — one entry per artifact named by two or more services (path template, header, JSON file, queue): producer, consumers, the verbatim contract, and the `service:file:line` evidence on both sides. Built from the writers' `SHARED ARTIFACTS` report lines; never invented. *One entry per artifact* is literal — do not bundle related artifacts under a thematic title, do not emit an entry whose producer and consumer are the same service, and do not emit one evidenced from only one side. `scripts/verify.sh mechanisms` enforces this, and `scripts/verify.sh diff` compares the resulting seam set across runs.
13. **Known Gaps and Technical Debt** — consolidated from the service specs, grouped Security / Data Integrity / Operational.
14. **Open Questions Log** — one table, one row per open architectural question.
15. **Pending Features** — pointer to `STATUS.md`.

### Style and purpose

- High level, not implementation detail: explain the platform shape, not every endpoint.
- May name a pattern a service implements, but never duplicates the service spec's detail.
- First stop for understanding system shape and service relationships.

### What not to include

- Endpoint-level API reference, DTO schemas, state slice names, per-module detail — those belong in the service specs.

---

## 2. Service Spec Files (`NN-{service}.md`)

Each service spec describes that service's architecture, contracts, and **current implemented state**. It reads like a stable design doc, not a scratchpad. Template: `templates/SERVICE-SPEC-TEMPLATE.md` (split: `SPEC-INDEX-TEMPLATE.md` + `MODULE-TEMPLATE.md`).

### Common structure (every service, in this order)

1. **Header** — title, one-sentence description, `Service identifier`, `Last updated`.
2. **Table of Contents**.
3. **Overview** — purpose; owns / does not own; depends on.
4. **Tech Stack** — language, framework, datastore, port, start command, hosting.
5. **Architecture** — module tree, request flow, bootstrap (global middleware, interceptors, filters, pipes, CORS, validation).
6. **Authentication** — strategy, guards/middleware, public vs protected, tenant/scope claims.
7. **Data Models** — field-by-field for every schema / entity / model the service owns: type, required, default, index. One table per entity, entities alphabetical, fields in source order.
8. **Endpoints** (backends) / **Views & Routes** (frontends) — grouped by module; for each endpoint: method, path, guard, request shape/DTO, response shape, validation and side effects; for each route: path, view, data source, state, loading/empty/error states.
9. **Endpoint Summary** / **Route Summary** — one quick-reference table.
10. **Environment Variables** — every referenced name, alphabetical, with what it controls.
11. **Cross-Cutting Concerns / Patterns** — envelope, validation, error handling, logging; frontends add the client layer and state conventions.
12. **Key Design Notes** — ID strategy, lifecycle rules, delegation, caching, jobs.
13. **Known Issues & Gaps** — one line per unresolved item; the only place for anything not confirmed in source.

### Frontend specs — additional expectations

- Application architecture (`UI → state → client layer → APIs`).
- Base request layer: base URL resolution, auth header injection, error handling.
- Authentication flow and token storage.
- Resource client modules and the endpoint contracts they consume.
- State store structure and slice/store names; action naming; loading pattern.
- Enumerations and constants used by the UI.
- Views / pages overview and the create/edit patterns.
- UI data models where they differ from backend contracts.
- i18n layout, when present.

### Backend specs — additional expectations

- Module composition and how feature modules are registered.
- Auth strategy and token lifecycle (or delegation to the service that owns it).
- Endpoint reference for every resource and public contract.
- Integration patterns with other services (calls made, files written, events emitted).
- Data flow summary for the main write paths.
- Environment variables and bootstrap configuration.

### Documentation tone and rules

- Describe the implemented state, not the idea or a design draft.
- Exact names: file names, class/DTO names, route strings, env var names, verbatim from source.
- Tables and request/response examples over prose.
- No speculation: unresolved items go to **Known Issues & Gaps**.
- Determinism contract D1–D6 (in the template header) applies to every edit, not only to Step 0.

---

## 3. Relationship Between Overview and Service Specs

- The overview describes platform structure, relationships, and system-wide patterns.
- Service specs describe the implementation details of each service.
- The overview links to service specs; it does not duplicate endpoint detail.
- Keep the overview light enough for a quick architecture review, and the service specs detailed enough for implementation and prompt generation.

### When to update which file

- A designed feature is cascaded into the relevant service spec(s) as `PENDING` and gets a `STATUS.md` row (Step 2).
- When implemented, the service spec(s) are reconciled against the code first, `PENDING` markers removed, then `STATUS.md` is flipped and `CHANGELOG.md` gets its one entry (Step 4).
- The overview changes only when system-wide architecture changes.
- `CONVENTIONS.md` and `repo-instructions/` change only when a shared convention changes (Step 4g).

---

## 4. Checklist

### `00-architecture-overview.md`

- [ ] Version and last-updated line present, one line.
- [ ] Table of Contents complete.
- [ ] Product summary present (or explicitly marked as not documented).
- [ ] Every service in `spechub.conf` appears in System Components with stack, port, purpose.
- [ ] Diagram has one box per service and one arrow per dependency.
- [ ] Tenancy, auth and service communication described.
- [ ] Hosting/deployment listed (unknowns marked).
- [ ] Spec document index lists every spec file.
- [ ] Known gaps consolidated; open questions logged.

### Service specs

- [ ] `Last updated` one line, latest change only.
- [ ] Every template heading present, in order.
- [ ] Data models field by field, source order; every persisted entity tabled, every DTO tabled or fully described under its endpoint's Request key.
- [ ] Every route in the fact sheet appears in Endpoints / Views & Routes.
- [ ] Environment Variables is exactly fact sheet §7a — same names, no more, no fewer.
- [ ] Every endpoint/route record carries every key of its record type.
- [ ] Cross-cutting patterns spelled out.
- [ ] Known issues captured; nothing speculative inline.
- [ ] Split specs: the file set equals `scripts/bootstrap.sh plan --manifest`; index File Map has one row per file; no module content in the index.
- [ ] `scripts/verify.sh all` passes.

---

## 5. Naming

- Service identifiers: the `name` column of `spechub.conf`.
- Spec files: `NN-{service}.md`; split content in `NN-{service}/`.
- Feature files: `Features/FEATURE-{kebab-name}.md`. Prompt files: `Prompts/PROMPT-{service}-{feature}.md`.
- Fact sheets: `bootstrap/facts/{service}.md`.

---

## 6. How to Use These Guidelines

1. Read `WORKFLOW.md` first to understand the lifecycle (Steps 0–4).
2. Use this document when creating or updating the overview or any service spec.
3. Keep the overview high level and the service specs implementation-specific.
4. When in doubt, move detailed contract information into the service spec rather than the overview.
5. Keep all service specs consistent in structure and level of detail — the templates are the structure.
