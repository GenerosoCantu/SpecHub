---
name: bootstrap-specs
description: Step 0 — generate the whole spec hub from the fact sheets in bootstrap/facts/ (one spec per service, the architecture overview, CONVENTIONS.md, STATUS.md, repo-instructions/). Use when the user says "bootstrap", "generate the specs", "step 0", "document the repos", or after running scripts/bootstrap.sh init on a new or existing codebase.
---

> **Session rule:** this step runs on a **Standard-tier** model in a fresh session (switch the model before invoking). It is transcription from fact sheets, not design. When the files are on disk, **end the session**: the first feature (Step 1) starts a new one. Request from the user: **$ARGUMENTS** (empty: every service in `spechub.conf`; a list of service ids: only those).

# Bootstrap the Specs (Step 0)

Write the service specs, the architecture overview, the shared conventions, the empty status board and the canonical repo-instruction files from the **fact sheets** that `scripts/bootstrap.sh` extracted mechanically from the repos. The fact sheets are the only input; the source files they name are the only thing read beyond them. That is what makes a second run land on the same tables.

## 0. Required reads — in this order, nothing more

1. `spechub.conf` — project name, base branch, the services table (order = spec numbering)
2. The output of `scripts/bootstrap.sh plan` — number, spec file, module count and shape (single / split) per service
3. `SPEC-GUIDELINES.md` — §1 (overview) and §3 (what goes where); §2 is read by the writers
4. `templates/ARCHITECTURE-OVERVIEW-TEMPLATE.md`, `templates/CONVENTIONS-TEMPLATE.md`, `templates/STATUS-TEMPLATE.md`

Do NOT read the fact sheets, the service repos, or `WORKFLOW.md` in this session — the writers read the sheets; you assemble from their reports.

## 1. Preconditions

- `spechub.conf` exists and `bootstrap/facts/{service}.md` exists for every non-static service (`scripts/bootstrap.sh plan` says "no fact sheet yet" otherwise — run `scripts/bootstrap.sh facts`, then continue).
- The fact sheets are current: if `git -C <repo> rev-parse --short HEAD` differs from the `@ sha` in a sheet's header, regenerate that sheet first (`scripts/bootstrap.sh facts <service>`).
- **Brownfield hub:** if a target spec file already exists and the user did not ask to regenerate it, skip that service and say so. Regeneration overwrites; the user's git history is the undo.

## 2. Write the service specs — one `spec-writer` per service, all in parallel

For every service in the plan (skipping static servers), launch a `spec-writer` subagent (Claude Code: Agent tool, `subagent_type: spec-writer`; Copilot: the `spec-writer` custom agent; a tool without subagents: one fresh session per service, given `.claude/agents/spec-writer.md` as its instructions) **all at once so they run concurrently**, with this prompt — identical wording for every service, only the values change:

```
Write the spec for service `{service}` (number {NN}, shape: {single|split}).
Fact sheet: bootstrap/facts/{service}.md
Target: {NN-{service}.md}  {— split into NN-{service}/00-core.md, 01-conventions.md, one file per module, plus the index}
Templates: templates/SERVICE-SPEC-TEMPLATE.md {, templates/SPEC-INDEX-TEMPLATE.md, templates/MODULE-TEMPLATE.md}
Repo instructions target: repo-instructions/{service}.md (template: repo-instructions/_TEMPLATE.md)
Project: {PROJECT_NAME}. Base branch: {BASE_BRANCH}. Today: {YYYY-MM-DD}.
Follow your agent instructions and the template's determinism contract exactly. Report in the fixed format only.
```

Wait for every writer. Each returns the fixed 12-field report; keep them — they are the input for §3–§5. If a writer fails, relaunch that one service with the same prompt; do not write its spec yourself.

## 3. Assemble `00-architecture-overview.md`

Fill `templates/ARCHITECTURE-OVERVIEW-TEMPLATE.md` **only from the writer reports and `spechub.conf`**, keeping every heading in order:

- §2 tables: one row per service, in `spechub.conf` order, values from `STACK`, `PURPOSE`, `HOSTING`; static servers from `spechub.conf` go in §2.3.
- §3 diagram: one box per service id; one arrow per `DEPENDS ON` entry. ASCII, services in plan order left to right.
- §4–§6: summarise `AUTH`, `DEPENDS ON` / `CALLED BY` across services in bullets. Tenancy: "Not applicable — single-tenant." unless a report shows tenant resolution.
- §9: one row per spec file written (index rows say "**index**; per-module specs in `NN-{service}/`").
- §10: every `GAPS` line, grouped Security / Data Integrity / Operational, prefixed with the service id.
- §11: one `Open` row per ambiguity the writers reported; empty table otherwise.
- §1 Product Summary: from the README heads the writers used, via their `PURPOSE` lines; if nothing describes the product, write `Not documented in the repos — fill in.`

## 4. Write `CONVENTIONS.md`

From `templates/CONVENTIONS-TEMPLATE.md` and the writers' `CONVENTIONS` / `ENV` / `OWNS` lines. A convention goes in only when **two or more services** report the same one (all of them for a single-service project); otherwise it stays in the service spec. Write it as implemented, not as it should be. The Domain Entities table lists every `OWNS` entity with its owning service.

## 5. Write `STATUS.md` and check `AGENTS.md`

- `STATUS.md` from `templates/STATUS-TEMPLATE.md` with the project name and **empty** In Flight / Shipped tables (drop the example row).
- `AGENTS.md`: the services table between `<!-- services:start -->` / `<!-- services:end -->` was written by `scripts/bootstrap.sh`; run `scripts/bootstrap.sh services` if `spechub.conf` changed since. Do not edit `AGENTS.md` otherwise.
- `repo-instructions/`: the writers wrote one file per service. Remind the user to copy each into its repo as `AGENTS.md` (with `CLAUDE.md` containing `@AGENTS.md` and `.github/copilot-instructions.md` pointing at it) — the hub copy is canonical from now on.

## 6. Determinism check (cheap, do it)

Pick the smallest service and run its writer a second time into a scratch path (`/tmp/spechub-check/NN-{service}.md`, same prompt with the target changed). `diff` the two: tables must be identical; only prose wording may differ. If a table differs, the fact sheet or a template rule is ambiguous — fix the template rule or record the ambiguity in the report; do not hand-edit the spec.

## 7. Finish

Report (under 40 lines): spec files written with sizes and shape per service; overview / conventions / status written; repo-instruction files written and the copy instruction; the determinism diff result; every gap the writers flagged that needs a human answer. Suggest the commit: `git add -A && git commit -m "spec hub: bootstrap specs for {PROJECT_NAME}"`.

Then tell the user, in one line: **"Step 0 is done — commit, then start a new session on an Advanced-tier model for the first feature (Step 1, `Features/FEATURE-{name}.md`)."** Do not design anything in this session.
