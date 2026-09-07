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
10. [Known Gaps and Technical Debt](#10-known-gaps-and-technical-debt)
11. [Open Questions Log](#11-open-questions-log)
12. [Pending Features](#12-pending-features) → `STATUS.md`

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

```text
{ASCII diagram: clients → backend services → datastores, with the direction of each call.
 One box per service id from spechub.conf; one arrow per dependency named in a spec's "Depends on".}
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

{Where each service runs, process manager, CI/CD facts found in the repos (workflows, Dockerfiles). "Unknown" is a valid value.}

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

## 10. Known Gaps and Technical Debt

{Consolidated from every service spec's "Known Issues & Gaps", grouped Security / Data Integrity / Operational. One line each.}

---

## 11. Open Questions Log

| # | Question | Section | Status |
|---|----------|---------|--------|
| OQ-1 | {question} | {§} | Open |

---

## 12. Pending Features

Moved to [`STATUS.md`](STATUS.md) — the live feature status board. Do not re-add the table here.
