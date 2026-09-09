<!--
  ARCHITECTURE OVERVIEW TEMPLATE → `00-architecture-overview.md`
  Written once by the bootstrap-specs skill (Step 0) from the service specs' Overview /
  Tech Stack sections, then touched only when system-wide architecture changes (Step 4c).
  High level only: no endpoint lists, no DTOs, no state slice names — those live in the
  service specs. Shared conventions live in CONVENTIONS.md, feature state in STATUS.md.
  Keep every heading, in this order; a section that does not apply reads "Not applicable — {reason}."
-->

# {Project Name} — Architecture Overview

**Version:** 1.0
**Last Updated:** {YYYY-MM-DD} — {one line naming the latest change only}. History lives in `CHANGELOG.md`.

---

## Table of Contents

1. [Product Summary](#1-product-summary)
2. [System Components](#2-system-components)
3. [High-Level Architecture Diagram](#3-high-level-architecture-diagram)
4. [Tenancy and Data Isolation](#4-tenancy-and-data-isolation)
5. [Authentication and Authorization](#5-authentication-and-authorization)
6. [Service Communication](#6-service-communication)
7. [Hosting and Deployment](#7-hosting-and-deployment)
8. [Shared Conventions](#8-shared-conventions) → `CONVENTIONS.md`
9. [Spec Document Index](#9-spec-document-index)
10. [Cross-Service Mechanisms](#10-cross-service-mechanisms)
11. [Known Gaps and Technical Debt](#11-known-gaps-and-technical-debt)
12. [Open Questions Log](#12-open-questions-log)
13. [Pending Features](#13-pending-features) → `STATUS.md`

---

## 1. Product Summary

{One paragraph: what the product is, who uses it, the main problem it solves. From the repos' READMEs; if none say, write "Not documented in the repos — fill in." rather than guessing.}

---

## 2. System Components

### 2.1 Client Applications

| Component | Service id | Tech Stack | Default Port | Purpose | Hosting |
|-----------|-----------|-----------|-------------|---------|---------|
| **{Label}** | `{service}` | {framework} | {port} | {one line} | {or unknown} |

### 2.2 Backend Services

| Component | Service id | Tech Stack | Default Port | Purpose | Hosting |
|-----------|-----------|-----------|-------------|---------|---------|
| **{Label}** | `{service}` | {framework} | {port} | {one line} | {or unknown} |

### 2.3 Data Layer

| Component | Technology | Owned by | Notes |
|-----------|-----------|----------|-------|
| **{Datastore}** | {e.g. PostgreSQL 15} | `{service}` | {isolation model, shared or dedicated} |

---

## 3. High-Level Architecture Diagram

<!--
  Mermaid, not hand-drawn ASCII: a free-form drawing is different every time it is generated, so it
  cannot be diffed between runs. This block is mechanical — one node per service in spechub.conf
  order, one edge per "Depends on" entry, nothing else. No layout choices, no extra nodes, no
  annotations beyond the edge labels below.
    - node id   = the service identifier with `-` replaced by `_`
    - node text = `{service}<br/>{framework} :{port}`
    - subgraphs = the `group` column of spechub.conf, in first-appearance order
    - edge      = `A --> B` for each of A's "Depends on" entries, A in spechub.conf order
    - edge label = the one-word reason (`auth`, `config`, `publish`) only when a writer reported one
-->

```mermaid
graph LR
  subgraph {group}
    {service_id}["{service}<br/>{framework} :{port}"]
  end
  {service_id} --> {other_service_id}
```

---

## 4. Tenancy and Data Isolation

{How tenants / accounts / workspaces are resolved and isolated, per service. "Not applicable — single-tenant." when so.}

---

## 5. Authentication and Authorization

{Auth strategy across services: token type, issuer, validation pattern, delegation, roles. Summarise; details stay in each service spec's Authentication section.}

---

## 6. Service Communication

{Who calls whom, public vs authenticated APIs, shared headers, event/queue usage. One bullet per edge in the diagram.}

---

## 7. Hosting and Deployment

<!-- One row per service, in spechub.conf order. The Hosting cell follows D8 of the service spec
     template: first evidence that exists wins, in the order `ecosystem.config.js`, a
     `start:dist`/deploy script, a `.github/workflows/*` file, the repo's instruction file — and the
     Evidence cell names it. "Unknown" only when none of the four exists. -->

| Service | Hosting | Evidence |
|---------|---------|----------|
| `{service}` | {target or Unknown} | `{file}` |

---

## 8. Shared Conventions

Moved to [`CONVENTIONS.md`](CONVENTIONS.md) — that file is the source of truth for cross-service conventions; do not re-add them here.

---

## 9. Spec Document Index

| # | Document | Scope |
|---|----------|-------|
| 00 | `00-architecture-overview.md` | This file — system map, shared decisions |
| — | `CONVENTIONS.md` | Shared conventions |
| — | `STATUS.md` | Live feature status board |
| {NN} | `{NN}-{service}.md` | {one line}{ — **index**; per-module specs in `{NN}-{service}/`} |

---

## 10. Cross-Service Mechanisms

<!--
  The contracts that live between services and therefore in no single service spec: a shared file
  path layout, a publish/consume pipeline, a token flow that spans three services, a cache both
  sides of which are owned elsewhere. Nothing here is invented — every mechanism is built from the
  SHARED ARTIFACTS lines of two or more writer reports, and exists only when two or more services
  name the same artifact (a path template, a header, a JSON file, a queue). "None — no artifact is
  named by more than one service." when nothing groups.

  Granularity is fixed, not a judgment call: ONE `### 10.x` PER ARTIFACT, alphabetical by title.
  Do not bundle several artifacts under one thematic entry — three CDN path templates are three
  entries, not one "Published CDN artifacts". Bundling is the single largest source of run-to-run
  drift measured so far: two runs of the same repos produced 13 entries and 8, and the bundled run
  silently lost five service-to-service seams.

  Every entry must satisfy, and `scripts/verify.sh mechanisms` enforces:
    - all four keys present: Producer, Consumer(s), Contract, Evidence
    - two or more DIFFERENT services from `spechub.conf` named across Producer + Consumer(s).
      A service that both writes and reads its own artifact is not a mechanism — drop the entry.
      "Consumers of {ENV_VAR}" is not a consumer; name the service or drop the entry.
    - Evidence cites at least two different services: the producer side AND the consumer side.
      Evidence that only cites the consumer is the most common failure — it means nobody checked
      the producing repo, and the entry is a guess.

  This section is the one thing a per-service pass cannot produce: each writer sees one repo, so a
  path template written by one service and read by another is invisible to both. Without it the
  hub documents eight services and none of the seams between them.
-->

### 10.1 {Mechanism}

- **Producer:** `{service}` — {what it writes, verbatim path/header/name}
- **Consumer(s):** `{service}` — {what it reads}
- **Contract:** {the shared artifact, verbatim: path template, header name, file name}
- **Evidence:** `{service}:{file:line}`, `{service}:{file:line}`

---

## 11. Known Gaps and Technical Debt

{Consolidated from every service spec's "Known Issues & Gaps", grouped Security / Data Integrity / Operational. One line each.}

---

## 12. Open Questions Log

| # | Question | Section | Status |
|---|----------|---------|--------|
| OQ-1 | {question} | {§} | Open |

---

## 13. Pending Features

Moved to [`STATUS.md`](STATUS.md) — the live feature status board. Do not re-add the table here.
