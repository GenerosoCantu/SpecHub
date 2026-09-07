# FEATURE — {Name}

**Status:** Pending (design)
**Scope:** {affected service identifiers, from spechub.conf}
**Implementation order:** {service → service → service, or "single service"}

> **Size budget:** contracts and decisions only. Target ≤ 8 KB for an enhancement, ≤ 15 KB for a new module. Rationale is at most a few lines per decision — the spec gets the contract, the prompt gets the instructions, this file gets the *why*, briefly. Code reconnaissance should be delegated to an `Explore` subagent that returns a summary; do not paste source files here.

## Description

{What the feature does from the user's perspective.}

## Data Model

{New/changed fields, types, defaults, indexes — per entity, per service.}

## API Shape

{Endpoint paths, methods, guards, request/response shape.}

## Frontend Contract (when applicable)

{Views/routes affected, component/state ownership, loading/empty/error states, responsive behavior.}

## Backend Contract (when applicable)

{Module boundaries, schema/index changes, validation/auth rules, side effects (file writes, events, jobs), failure semantics.}

## Confirmed design decisions

1. {…}

## Open design decisions

- {Must be empty before Step 2 — prompts are never generated over open questions.}

## Recommended model tier (per service)

- {service}: {Light | Standard | Advanced} — {one-line reason}

## Outstanding work (checklist)

- [ ] Cascade into {spec / module file(s)} as PENDING (Step 2a)
- [ ] Add row to STATUS.md
- [ ] Generate Prompts/PROMPT-{service}-{feature}.md (per service, in implementation order — Step 2b, same session)
