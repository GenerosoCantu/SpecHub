# Task: {imperative description of the implementation}

> **Target repo:** {absolute local path of the service repo — the `dir` of spechub.conf, resolved}
> **Branch:** feature/{kebab-name}
> **Prerequisites:** {PROMPT-file(s) this one depends on — sets verification and merge order, or "none"}
> **Status:** Generated   <!-- Generated → Applied → Verified -->
> **Recommended model:** {Light | Standard | Advanced} — {one-line reason}

<!-- Size budget: ≤ 8 KB for an enhancement, ≤ 12 KB for a new module. Contract tables are COPIED from the cascaded spec (extract them mechanically with sed/awk into this file), never retyped or paraphrased. No narrative beyond Context. No spec-hub paths in the body: the implementing session cannot see this workspace. -->

## Context

{2–5 sentences: what this adds and why, including any cross-service background the implementer needs (e.g. the endpoint of another service it calls).}

## Relevant Existing Files to Study Before Implementing

```text
{path}   ← Reference: {pattern it demonstrates}
{path}   ← UPDATE: {what changes}
```

## New Files to Create

```text
{path}
```

## Schema Contract

{Field | Type | Default | Description table — verbatim from the spec.}

## Endpoints

{Method | Path | Guard | Request/Response — verbatim from the spec.}

## Naming Rules

{Class/DTO names, state slice/actions, route strings, component names — verbatim from the spec.}

## {Backend only} Validation, Errors, Tests

{Input validation constraints, guard behavior, error/status semantics, required test updates.}

## {Frontend only} Views, State, UX States, Acceptance Criteria

{Routes/views/components, state-management updates, loading/empty/error/permission states, acceptance criteria.}

## Build, Test, Lint

{The repo's build and test commands; lint ONLY the changed files (e.g. `npx eslint <files>`, `ruff check <files>`, `./mvnw -q spotless:apply -DspotlessFiles=<files>`), never a repo-wide fix.}
