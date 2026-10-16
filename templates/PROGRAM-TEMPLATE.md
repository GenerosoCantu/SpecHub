# PROGRAM — {Name}

**Status:** Designing (UX) | Polished (ready to derive features) | In progress ({n} of {m} features closed) | Done
**Scope:** {affected service identifiers, from spechub.conf}
**Features derived:** {none yet | `FEATURE-a`, `FEATURE-b`, … in implementation order}

> **What this file is.** A program is a body of work too large for one feature file: several features across several services that only make sense together. This file holds the shared design — the user experience, the vocabulary, the page inventory, the architecture decisions every derived feature must respect, and the feature breakdown with its order. It is **never cascaded** into a spec and **never generates a prompt**; only the derived `FEATURE-*.md` files do. Target ≤ 35 KB. Wireframes are ASCII and small; code reconnaissance goes to an `Explore` subagent, never pasted here.

## Problem

{What is hard or impossible for the user today, in a paragraph. Name the existing modules/specs this builds on.}

## Vocabulary

| Term | Meaning | Lives in |
|---|---|---|
| {term} | {one line} | {service / collection / file} |

## User journeys

### {Actor} — {journey name}
1. {step — one line each; name the page in the inventory}

## Page inventory

| # | Page | Route | Service | Who | Purpose |
|---|---|---|---|---|---|
| 1 | {name} | `{route}` | {service} | {role} | {one line} |

### {Page needing a wireframe}
```text
{ASCII wireframe, ≤ 25 lines}
```
{Behavior notes: states, actions, what happens on save.}

## Architecture decisions

{Numbered. Each: the decision, two or three lines of why, and the alternative rejected. These bind every derived feature.}

## Feature breakdown

| # | Feature file | Services | Depends on | Tier | Summary |
|---|---|---|---|---|---|
| 1 | `FEATURE-{name}` | {services} | — | {Light/Standard/Advanced} | {one line} |

**Implementation order:** {1 → 2 → (3 ∥ 4) → 5}

## Open decisions

- {Must be empty before the program is marked Polished and the first feature is derived.}

## Lifecycle

- [ ] UX polished with the product owner (status → Polished)
- [ ] First feature derived (each derived feature file carries `**Program:** PROGRAM-{name}` and is re-validated against the current specs when written)
- [ ] All derived features closed → move this file to `Features/Implemented/`
